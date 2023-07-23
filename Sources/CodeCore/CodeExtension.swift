import SwiftUI
import Combine
import RealmSwift
import BigSyncKit
import RealmSwiftGaps
import SwiftGit2

public class CodeExtension: Object, UnownedSyncableObject, ObjectKeyIdentifiable  {
    /// Do not prepend dot. Checks both dot-prepended and as-is automatically and in that order.
    public static var extensionsPathComponents = [String]()
    
    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted(indexed: true) public var repositoryURL = ""
    
    @Persisted public var name = ""
    @Persisted public var repository: PackageRepository?
    
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    public var needsSyncToServer: Bool { false }
    
    @MainActor private var cachedWorkspaceStorage: WorkspaceStorage? = nil
    @MainActor public var workspaceStorage: WorkspaceStorage? {
        get {
            if let cachedWorkspaceStorage = cachedWorkspaceStorage {
                return cachedWorkspaceStorage
            }
            guard let repo = repository, repo.isWorkspaceInitialized, let directoryURL = directoryURL else { return nil }
            let workspaceStorage = WorkspaceStorage(url: directoryURL)
            workspaceStorage.onDirectoryChange { url in
                Task { [weak self] in try await self?.loadFromWorkspace() }
            }
            Task { [weak self] in try await self?.loadFromWorkspace() }
            cachedWorkspaceStorage = workspaceStorage
            return workspaceStorage
        }
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    public var directoryURL: URL? {
        guard let repo = repository else { return nil }
        var baseURL = repo.directoryURL
        for component in Self.extensionsPathComponents {
            baseURL.append(component: component, directoryHint: .isDirectory)
        }
        return baseURL.appending(component: name)
    }
    
    public override init() {
        super.init()
        
        name.publisher
            .sink { _ in
                Task { @MainActor [weak self] in
                    self?.cachedWorkspaceStorage = nil
                }
            }
            .store(in: &cancellables)
    }
    
    @MainActor
    var isWorkspaceInitialized: Bool {
        guard let repo = repository else { return false }
        return (repo.gitTracks.count > 0 || !repo.branch.isEmpty) && !name.isEmpty && cachedWorkspaceStorage != nil
    }
    
    @MainActor
    func loadFromWorkspace() async throws {
    }
    
    enum CodingKeys: CodingKey {
        case id
        case repositoryURL
        case name
        case repository
        case modifiedAt
        case isDeleted
    }
}

//fileprivate func walkDirectory(at url: URL, options: FileManager.DirectoryEnumerationOptions ) -> AsyncStream<URL> {
//    AsyncStream { continuation in
//        Task {
//            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: options)
//
//            while let fileURL = enumerator?.nextObject() as? URL {
//                if fileURL.hasDirectoryPath {
//                    for await item in walkDirectory(at: fileURL, options: options) {
//                        continuation.yield(item)
//                    }
//                } else {
//                    continuation.yield( fileURL )
//                }
//            }
//            continuation.finish()
//        }
//    }
//}
