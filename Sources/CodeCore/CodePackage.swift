import SwiftUI
import Combine
import RealmSwift
import BigSyncKit
import RealmSwiftGaps
import SwiftGit2

public class CodePackageRepository: ObservableObject, GitRepositoryProtocol {
    public let package: CodePackage
    
    @Published public var gitTracks: [URL: Diff.Status] = [:]
    @Published public var indexedResources: [URL: Diff.Status] = [:]
    @Published public var workingResources: [URL: Diff.Status] = [:]
    @Published public var branch: String = ""
    @Published public var remote: String = ""
    @Published public var commitMessage: String = ""
    @Published public var isSyncing: Bool = false
    @Published public var aheadBehind: (Int, Int)? = nil
    
    @MainActor public lazy var workspaceStorage: WorkspaceStorage? = {
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
                        Task { [weak self] in
                            guard let self = self else { return }
                            try await loadRepository()
                            safeWrite(package) { _, package in
                                for ext in package.codeExtensions.where({ !$0.isDeleted }) {
                                    ext.buildRequested = true
                                }
                            }
                        }
                    }
                    try await loadRepository()
                }
            }
        }
        return workspaceStorage
    }()
    
    public var name: String {
        return package.name
    }
    
    public var repositoryURL: URL? {
        return URL(string: package.repositoryURL)
    }
    
    public var directoryURL: URL {
        return package.directoryURL
    }
    
    @MainActor var isWorkspaceInitialized: Bool {
        guard let workspaceStorage = workspaceStorage else { return false }
        return workspaceStorage.currentDirectory.url == directoryURL.absoluteString && gitTracks.count > 0 || !branch.isEmpty
    }

    public init(package: CodePackage) {
        self.package = package.isFrozen ? package : package.freeze()
        
        Task { @MainActor [weak self] in
            self?.workspaceStorage
        }
    }
}

public class CodePackage: Object, UnownedSyncableObject, ObjectKeyIdentifiable {
    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var repositoryURL = ""
//    @Persisted public var name = ""
//    @Persisted public var version = ""
//    @Persisted public var packageDescription = ""
//    @Persisted public var repositoryType: String? = nil
//    @Persisted var repositoryDirectory: String? = nil
    
//    @Persisted var packageJSONDirectory: String? = nil
    @Persisted public var isEnabled = true
    
    @Persisted(originProperty: "packages") public var packageCollection: LinkingObjects<PackageCollection>
    @Persisted(originProperty: "package") public var codeExtensions: LinkingObjects<CodeExtension>
    
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    public var needsSyncToServer: Bool { false }
       
    private var cachedRootDirectory: URL? = nil

    public override init() {
        super.init()
    }
    
    enum CodingKeys: CodingKey {
        case id
        case repositoryURL
        case isEnabled
        case modifiedAt
        case isDeleted
    }
    
    public func repository() -> CodePackageRepository {
        return CodePackageRepository(package: self)
    }
    
    public var name: String {
        return URL(string: repositoryURL)?.deletingPathExtension().lastPathComponent ?? ""
    }
    
    public var directoryURL: URL {
        return getRootDirectory().appending(component: "CodeKit").appending(component: name + "-" + id.uuidString.suffix(6), directoryHint: .isDirectory)
    }
}

public extension CodePackage {
    func getRootDirectory() -> URL {
        if let cachedRootDirectory = cachedRootDirectory {
            return cachedRootDirectory
        }
        // We want ./private prefix because all other files have it
        //    var dir = URL.documentsDirectory
#if os(iOS)
        let documentsPathURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appending(component: "Documents", directoryHint: .isDirectory) ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
#else
        let documentsPathURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appending(component: "Documents", directoryHint: .isDirectory) ?? Optional(URL.documentsDirectory)
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
    
public extension CodePackageRepository {
    enum CodePackageError: Error {
        case repositoryLoadingFailed
        case gitRepositoryInitializationError
    }
    
    @MainActor
    private func loadRepository() async throws {
        let extensionNames = try await extensionNamesFromFiles()
        
        guard let package = package.isFrozen ? package.thaw() : package, let realm = package.realm, let repositoryURL = repositoryURL?.absoluteString else { return }
        let allExisting = realm.objects(CodeExtension.self).where { $0.repositoryURL == repositoryURL && !$0.isDeleted }
        for ext in allExisting {
            guard extensionNames.contains(ext.name) else {
                try! realm.write {
                    ext.isDeleted = true
                }
                try await ext.removeAllExtensionBuildsFromStorage()
                return
            }
            
            if ext.package != package {
                safeWrite(ext) { _, ext in
                    ext.package = package
                }
            }
        }
        
        let existingNames = Set(allExisting.map { $0.name })
        let newNames = extensionNames.subtracting(existingNames)
        if !newNames.isEmpty {
            try! realm.write {
                for name in newNames {
                    realm.create(CodeExtension.self, value: [
                        "repositoryURL": repositoryURL,
                        "name": name,
                        "repository": self,
                    ] as [String: Any], update: .modified)
                }
            }
        }
    }
    
    @MainActor
    func listExtensionFiles() async throws -> [URL] {
        try await gitStatus()
        
        guard let workspaceStorage = workspaceStorage, isWorkspaceInitialized, let currentDirectory = URL(string: workspaceStorage.currentDirectory.url) else {
            throw CodePackageError.repositoryLoadingFailed
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
                    .filter { CodeExtension.isValidExtension(fileURL: $0) }
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
        let urls = try await listExtensionFiles()
        return Set<String>(urls.map { $0.deletingPathExtension().lastPathComponent })
    }
    
    @MainActor
    private func createAndUpdateDirectoryIfNeeded(completionHandler: @escaping (Error?) -> Void) {
        guard !name.isEmpty else {
            completionHandler(nil)
            return
        }
        let dir = directoryURL
        Task { @MainActor in
            guard let workspaceStorage = workspaceStorage else { return }
            if try await !workspaceStorage.fileExists(at: dir) {
                workspaceStorage.createDirectory(at: dir, withIntermediateDirectories: true) { maybeError in
                    Task { @MainActor [weak self] in
                        await self?.workspaceStorage?.updateDirectory(url: dir)
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
        createAndUpdateDirectoryIfNeeded { error in
            Task { @MainActor [weak self] in
                guard let self = self, error == nil, let workspaceStorage = workspaceStorage, let repositoryURL = repositoryURL else {
                    print(error?.localizedDescription ?? "")
                    completionHandler(error)
                    return
                }
                
                workspaceStorage.gitServiceProvider?.loadDirectory(url: directoryURL.standardizedFileURL)
                try? await gitStatus()
                    
                do {
                    if isWorkspaceInitialized {
                        try await pull()
                        completionHandler(nil)
                    } else {
                        workspaceStorage.gitServiceProvider?.clone(
                            from: repositoryURL,
                            to: directoryURL,
                            progress: nil) { error in
                                print(error)
                                completionHandler(CodePackageError.gitRepositoryInitializationError)
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
           workspaceStorage?.gitServiceProvider?.fetch(error: {
                print($0.localizedDescription)
                continuation.resume(throwing: $0)
            }) {
                Task { @MainActor [weak self] in
                    guard let self = self else {
                        continuation.resume(throwing: CodePackageError.repositoryLoadingFailed)
                        return
                    }
                    try await gitStatus()
                    
                    workspaceStorage?.gitServiceProvider?.checkout(
                        remoteBranchName: remote + "/" + branch,
//                        localBranchName: branch,
                        detached: false,
                        error: {
                            print($0.localizedDescription)
                            continuation.resume(throwing: $0)
                        }) {
                            Task { @MainActor [weak self] in
                                try await self?.gitStatus()
                                continuation.resume(returning: ())
                            }
                        }
                }
            }
        }
    }
}
