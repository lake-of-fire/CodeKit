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
                    workspaceStorage.updateDirectory(url: dir.standardizedFileURL)
                    workspaceStorage.onDirectoryChange { url in
                        Task { [weak self] in try await self?.gitStatus() }
                    }
                    try await gitStatus()
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
        return getRootDirectory().appending(path: name + "-" + id.uuidString.suffix(6), directoryHint: .isDirectory)
    }
    
    @MainActor
    var isRepositoryInitialized: Bool {
        return gitTracks.count > 0 || !branch.isEmpty
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
        case missingGitServiceProvider
        case gitRepositoryInitializationError
    }
    
    @MainActor
    private func createDirectoryIfNeeded(completionHandler: @escaping (Error?) -> Void) {
        let dir = directoryURL
        Task { @MainActor in
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
                if isRepositoryInitialized {
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

fileprivate func walkDirectory(at url: URL, options: FileManager.DirectoryEnumerationOptions ) -> AsyncStream<URL> {
    AsyncStream { continuation in
        Task {
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: options)
            
            while let fileURL = enumerator?.nextObject() as? URL {
                if fileURL.hasDirectoryPath {
                    for await item in walkDirectory(at: fileURL, options: options) {
                        continuation.yield(item)
                    }
                } else {
                    continuation.yield( fileURL )
                }
            }
            continuation.finish()
        }
    }
}
