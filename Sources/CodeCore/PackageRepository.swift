import SwiftUI
import Combine
import RealmSwift
import BigSyncKit
import RealmSwiftGaps
import SwiftGit2

public class PackageRepository: Object, UnownedSyncableObject, ObjectKeyIdentifiable  {
    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var repositoryURL = ""
//    @Persisted public var name = ""
//    @Persisted public var version = ""
//    @Persisted public var packageDescription = ""
//    @Persisted public var repositoryType: String? = nil
//    @Persisted var repositoryDirectory: String? = nil
    
//    @Persisted var packageJSONDirectory: String? = nil
    @Persisted public var isEnabled = true
    
    @Persisted(originProperty: "repositories") public var repositoryCollection: LinkingObjects<RepositoryCollection>
    @Persisted(originProperty: "repository") public var codeExtensions: LinkingObjects<CodeExtension>
    
    // Git UI states
    @MainActor @Published public var gitTracks: [URL: Diff.Status] = [:]
    @MainActor @Published public var indexedResources: [URL: Diff.Status] = [:]
    @MainActor @Published public var workingResources: [URL: Diff.Status] = [:]
    @MainActor @Published public var branch: String = ""
    @MainActor @Published public var remote: String = ""
    @MainActor @Published public var commitMessage: String = ""
    @MainActor @Published public var isSyncing: Bool = false
    @MainActor @Published public var aheadBehind: (Int, Int)? = nil
    
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    public var needsSyncToServer: Bool { false }
    
    var cachedRootDirectory: URL? = nil
    
    @MainActor public lazy var workspaceStorage: WorkspaceStorage = {
        let workspaceStorage = WorkspaceStorage(url: directoryURL)
        Task { @MainActor in
            createAndUpdateDirectoryIfNeeded { error in
                Task { @MainActor [weak self] in
                    guard let self = self, error == nil else {
                        print(error?.localizedDescription ?? "")
                        return
                    }
                    let dir = directoryURL
                    await workspaceStorage.updateDirectory(url: dir) //.standardizedFileURL)
                    workspaceStorage.onDirectoryChange { url in
                        Task { [weak self] in try await self?.loadRepository() }
                    }
                    try await loadRepository()
                }
            }
        }
        return workspaceStorage
    }()
    
    public override init() {
        super.init()
    }
    
    public var url: URL? {
        return URL(string: repositoryURL)
    }
        
    public var name: String {
        return url?.deletingPathExtension().lastPathComponent ?? ""
    }
    
    public var directoryURL: URL {
        return getRootDirectory().appending(component: "Extensions").appending(component: name + "-" + id.uuidString.suffix(6), directoryHint: .isDirectory)
    }
    
    @MainActor var isWorkspaceInitialized: Bool {
        return workspaceStorage.currentDirectory.url == directoryURL.absoluteString && gitTracks.count > 0 || !branch.isEmpty
    }
    
    enum CodingKeys: CodingKey {
        case id
        case repositoryURL
        case isEnabled
        case modifiedAt
        case isDeleted
    }
    
    func getRootDirectory() -> URL {
        if let cachedRootDirectory = cachedRootDirectory {
            return cachedRootDirectory
        }
        // We want ./private prefix because all other files have it
        //    var dir = URL.documentsDirectory
        #if os(iOS)
        let documentsPathURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appending(component: "Documents", directoryHint: .isDirectory) ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        #else
        let documentsPathURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appending(component: "Documents", directoryHint: .isDirectory) ?? Optional(URL.homeDirectory)
        #endif
        if let documentsPathURL = documentsPathURL {
            if (!FileManager.default.fileExists(atPath: documentsPathURL.path)) {
                do {
                    try FileManager.default.createDirectory(at: documentsPathURL, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    print("Error in creating root directory for workspace storage")
                }
            }
            
#if targetEnvironment(simulator)
            cachedRootDirectory = documentsPathURL
            return documentsPathURL
#else
#if os(iOS)
            if let standardURL = URL(
                string: documentsPathURL.absoluteString.replacingOccurrences(
                    of: "file:///", with: "file:///private/"))
            {
                cachedRootDirectory = standardURL
                return standardURL
            } else {
                cachedRootDirectory = documentsPathURL
                return documentsPathURL
            }
#else
            cachedRootDirectory = documentsPathURL
            return documentsPathURL
#endif
#endif
        } else {
            fatalError("Could not locate iCloud Documents Directory")
        }
    }
}

public extension PackageRepository {
    enum PackageRepositoryError: Error {
        case repositoryLoadingFailed
        case missingGitServiceProvider
        case gitRepositoryInitializationError
    }
    
    @MainActor
    private func loadRepository() async throws {
        let extensionNames = try await extensionNamesFromFiles()
        
        guard let realm = realm else { return }
        try await realm.asyncWrite {
            let allExisting = realm.objects(CodeExtension.self).where { $0.repositoryURL == repositoryURL }
            for ext in allExisting {
                guard extensionNames.contains(ext.name) else {
                    ext.isDeleted = true
                    if let directoryURL = ext.directoryURL {
                        workspaceStorage.removeItem(at: directoryURL) { _ in }
                    }
                    return
                }
                
                if ext.repository != self {
                    ext.repository = self
                }
            }
            
            let existingNames = Set(allExisting.map { $0.name })
            for name in extensionNames {
                if existingNames.contains(name) {
                    continue
                }
                realm.create(CodeExtension.self, value: [
                    "repositoryURL": self.repositoryURL,
                    "name": name,
                    "repository": self,
                ] as [String: Any], update: .modified)
            }
        }
    }
    
    @MainActor
    func listExtensionFiles() async throws -> [URL] {
        try await gitStatus()
        guard isWorkspaceInitialized, let currentDirectory = URL(string: workspaceStorage.currentDirectory.url) else {
            throw PackageRepositoryError.repositoryLoadingFailed
        }
        var urls = [URL]()
        for prefix in [".", ""] {
            var extensionsDir = currentDirectory
            var comps = CodeExtension.extensionsPathComponents
            if !comps.isEmpty {
                let first = comps.removeFirst()
                comps = [(prefix + first)] + comps
            }
            for comp in CodeExtension.extensionsPathComponents {
                extensionsDir.append(component: comp, directoryHint: .isDirectory)
            }
            
            do {
                urls = try await workspaceStorage.contentsOfDirectory(at: extensionsDir)
            } catch {
                continue
            }
            if !urls.isEmpty {
                break
            }
        }
        return urls
    }
    
    @MainActor
    func extensionNamesFromFiles() async throws -> Set<String> {
        print("get urls \(await workspaceStorage.currentDirectory.url)")
        let urls = try await listExtensionFiles()
        print("got em...")
        print(Set<String>(urls.map { $0.deletingPathExtension().lastPathComponent }))
        return Set<String>(urls.map { $0.deletingPathExtension().lastPathComponent })
    }
    
    @MainActor
    private func createAndUpdateDirectoryIfNeeded(completionHandler: @escaping (Error?) -> Void) {
        guard !name.isEmpty else {
            completionHandler(PackageRepositoryError.gitRepositoryInitializationError)
            return
        }
        let dir = directoryURL
        Task { @MainActor in
            if try await !workspaceStorage.fileExists(at: dir) {
                workspaceStorage.createDirectory(at: dir, withIntermediateDirectories: true) { maybeError in
                    Task { @MainActor [weak self] in
                        await self?.workspaceStorage.updateDirectory(url: dir)
                        completionHandler(maybeError)
                    }
                }
            } else {
                await workspaceStorage.updateDirectory(url: dir)
                completionHandler(nil)
            }
        }
    }
    
    @MainActor
    func cloneOrPullIfNeeded(completionHandler: @escaping (Error?) -> Void) {
        guard let repositoryURL = URL(string: repositoryURL) else {
            completionHandler(PackageRepositoryError.repositoryLoadingFailed)
            return
        }
        print("### clone or pull if needed")
        createAndUpdateDirectoryIfNeeded { error in
            Task { @MainActor [weak self] in
                guard let self = self, error == nil else {
                    print(error?.localizedDescription ?? "")
                    completionHandler(error)
                    return
                }
        print("### clone or pull if needed \(url?.absoluteString): loadDirectory")
                workspaceStorage.gitServiceProvider?.loadDirectory(url: directoryURL.standardizedFileURL)
                
                do {
        print("### clone or pull if needed: git status")
                    try await gitStatus()
                    
        print("### clone or pull if needed: git status complete")
                    if isWorkspaceInitialized {
                        try await pull()
                        completionHandler(nil)
                    } else {
                        workspaceStorage.gitServiceProvider?.clone(
                            from: repositoryURL,
                            to: directoryURL,
                            progress: nil) { error in
                                print(error)
                                completionHandler(PackageRepositoryError.gitRepositoryInitializationError)
                            } completionHandler: {
                                Task { @MainActor [weak self] in
                                    try await self?.gitStatus()
                                    completionHandler(nil)
                                }
                            }
                    }
                } catch {
                    completionHandler(error)
                }
            }
        }
    }
    
    @MainActor
    func pull() async throws {
        return try await withCheckedThrowingContinuation { continuation in
           workspaceStorage.gitServiceProvider?.fetch(error: {
                print($0.localizedDescription)
                continuation.resume(throwing: $0)
            }) {
                Task { @MainActor [weak self] in
                    guard let self = self else {
                        continuation.resume(throwing: PackageRepositoryError.repositoryLoadingFailed)
                        return
                    }
                    try await gitStatus()
                    
                    workspaceStorage.gitServiceProvider?.checkout(
                        remoteBranchName: remote + "/" + branch,
                        detached: false,
                        error: {
                            print($0.localizedDescription)
                            continuation.resume(throwing: $0)
                        }) {
                            Task { @MainActor [weak self] in
                                try await self?.gitStatus()
                                continuation.resume()
                            }
                        }
                }
            }
        }
    }
    
    @MainActor
    func gitStatus() async throws {
        func clearState() {
            remote = ""
            branch = ""
            gitTracks = [:]
            indexedResources = [:]
            workingResources = [:]
        }

        if workspaceStorage.gitServiceProvider == nil {
            clearState()
        }

        return try await withCheckedThrowingContinuation { continuation in
            workspaceStorage.gitServiceProvider?.status(error: { error in
                clearState()
                continuation.resume(throwing: error)
            }) { indexed, worktree, branch in
                guard let hasRemote = self.workspaceStorage.gitServiceProvider?.hasRemote() else {
                    continuation.resume(with: .failure(PackageRepositoryError.missingGitServiceProvider))
                    return
                }
                
                Task { @MainActor in
                    let indexedDictionary = Dictionary(uniqueKeysWithValues: indexed)
                    let workingDictionary = Dictionary(uniqueKeysWithValues: worktree)
                    
                    if hasRemote {
                        self.remote = "origin"
                    } else {
                        self.remote = ""
                    }
                    self.branch = branch
                    self.indexedResources = indexedDictionary
                    self.workingResources = workingDictionary
                    
                    self.gitTracks = indexedDictionary.merging(
                        workingDictionary,
                        uniquingKeysWith: { current, _ in
                            current
                        })
                    
                    self.workspaceStorage.gitServiceProvider?.aheadBehind(error: { error in
                        print(error.localizedDescription)
                        Task { @MainActor in
                            self.aheadBehind = nil
                            continuation.resume(with: .failure(error))
                        }
                    }) { result in
                        Task { @MainActor in
                            self.aheadBehind = result
                            continuation.resume(with: .success(()))
                        }
                    }
                }
            }
        }
    }
}
