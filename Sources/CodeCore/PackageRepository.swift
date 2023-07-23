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
    
    @MainActor public lazy var workspaceStorage: WorkspaceStorage = {
        let workspaceStorage = WorkspaceStorage(url: getRootDirectory())
        Task { @MainActor in
            createDirectoryIfNeeded { error in
                Task { @MainActor [weak self] in
                    guard let self = self, error == nil else {
                        print(error?.localizedDescription ?? "")
                        return
                    }
                    let dir = directoryURL
                    workspaceStorage.updateDirectory(url: dir) //.standardizedFileURL)
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
        return getRootDirectory().appending(component: name + "-" + id.uuidString.suffix(6), directoryHint: .isDirectory)
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
}

public extension PackageRepository {
    enum PackageRepositoryError: Error {
        case repositoryLoadingFailed
        case missingGitServiceProvider
        case gitRepositoryInitializationError
    }
    
    @MainActor
    private func loadRepository() async throws {
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
            
            urls = try await workspaceStorage.contentsOfDirectory(at: extensionsDir)
            if !urls.isEmpty {
                break
            }
        }
        let names = urls.map { $0.lastPathComponent }
        guard let realm = realm else { return }
        try await realm.asyncWrite {
            let allExisting = realm.objects(CodeExtension.self).where { $0.repositoryURL == repositoryURL }
            for ext in allExisting {
                guard names.contains(ext.name) else {
                    ext.isDeleted = true
                    return
                }
                
                if ext.repository != self {
                    ext.repository = self
                }
            }
            
            let existingNames = Set(allExisting.map { $0.name })
            for name in names {
                if existingNames.contains(name) {
                    continue
                }
                realm.create(CodeExtension.self, value: [
                    "repositoryURL": self.repositoryURL,
                    "name": name,
                    "repository": self,
                ], update: .modified)
            }
        }
    }
    
    @MainActor
    private func createDirectoryIfNeeded(completionHandler: @escaping (Error?) -> Void) {
        guard !name.isEmpty else {
            completionHandler(PackageRepositoryError.gitRepositoryInitializationError)
            return
        }
        let dir = directoryURL
        Task { @MainActor in
            print(dir)
            if try await !workspaceStorage.fileExists(at: dir) {
                workspaceStorage.createDirectory(at: dir, withIntermediateDirectories: true, completionHandler: completionHandler)
            } else {
                completionHandler(nil)
            }
        }
    }
    
    @MainActor
    func cloneIfNeeded(completionHandler: @escaping (Error?) -> Void) {
        createDirectoryIfNeeded { error in
            Task { @MainActor [weak self] in
                guard let self = self, error == nil else {
                    print(error?.localizedDescription ?? "")
                    completionHandler(error)
                    return
                }
                if isWorkspaceInitialized {
                    workspaceStorage.gitServiceProvider?.loadDirectory(url: directoryURL.standardizedFileURL)
                    try await gitStatus()
                    completionHandler(nil)
                } else {
                    workspaceStorage.gitServiceProvider?.initialize(error: { error in
                        print(error)
                        completionHandler(PackageRepositoryError.gitRepositoryInitializationError)
                    }) {
                        Task { @MainActor [weak self] in
                            try await self?.gitStatus()
                            completionHandler(nil)
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
            workspaceStorage.gitServiceProvider?.status(error: { _ in
                clearState()
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
