import SwiftUI
import Combine
import RealmSwift
import BigSyncKit
import RealmSwiftGaps
import SwiftGit2

public class CodeExtension: Object, UnownedSyncableObject, ObjectKeyIdentifiable {
    /// Do not prepend dot. Checks both dot-prepended and as-is automatically and in that order.
    public static var extensionsPathComponents = [String]()
    
    @Persisted(primaryKey: true) public var id = ""
    public var compoundKey: String {
        return Self.makeCompoundKey(repositoryURL: repositoryURL, name: name)
    }
    
    @Persisted(indexed: true) public var repositoryURL = ""
    
    @Persisted public var name = ""
    @Persisted public var package: CodePackage?
    
    @Persisted public var buildRequested = false
    @Persisted public var lastBuildRequestedAt: Date?
    @Persisted public var isBuilding = false
    @Persisted public var lastBuiltAt: Date?
    @Persisted public var desiredBuildHash: String? = nil
    @Persisted public var latestBuildHashAvailable: String? = nil
    
//    @Persisted public var isRunning = false
    @Persisted public var lastRunStartedAt: Date?
    
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    public var needsSyncToServer: Bool { false }
    
    public static func makeCompoundKey(repositoryURL: String, name: String) -> String {
        return "[" + repositoryURL + "][" + name + "]"
    }
    
    @Persisted(originProperty: "providedByExtension") public var personas: LinkingObjects<Persona>
    
//    // Git UI states
//    @MainActor @Published public var gitTracks: [URL: Diff.Status] = [:]
//    @MainActor @Published public var indexedResources: [URL: Diff.Status] = [:]
//    @MainActor @Published public var workingResources: [URL: Diff.Status] = [:]
//    @MainActor @Published public var branch: String = ""
//    @MainActor @Published public var remote: String = ""
//    @MainActor @Published public var commitMessage: String = ""
//    @MainActor @Published public var isSyncing: Bool = false
//    @MainActor @Published public var aheadBehind: (Int, Int)? = nil
//    @MainActor private var cachedWorkspaceStorage: WorkspaceStorage? = nil
    
//    @MainActor public var workspaceStorage: WorkspaceStorage? {
//        get {
//            guard !name.isEmpty && !repositoryURL.isEmpty else { return nil }
//            if let cachedWorkspaceStorage = cachedWorkspaceStorage {
//                return cachedWorkspaceStorage
//            }
////            guard let repo = repository, repo.isWorkspaceInitialized, let directoryURL = directoryURL else {
//            guard let directoryURL = directoryURL else {
//                return nil
//            }
//            let workspaceStorage = WorkspaceStorage(url: directoryURL)
//            workspaceStorage.onDirectoryChange { url in
////                Task { [weak self] in try await self?.loadFromWorkspace() }
//            }
////            Task { [weak self] in try await self?.loadFromWorkspace() }
//            cachedWorkspaceStorage = workspaceStorage
//            return workspaceStorage
//        }
//    }
    
    private var cancellables = Set<AnyCancellable>()
    
    public var nameWithOwner: String {
        guard let url = URL(string: repositoryURL) else { return "" }
        if url.host == "github.com", url.pathComponents.count >= 3 {
            let org = url.pathComponents[1]
            let repo = url.pathComponents[2]
            if repo.hasSuffix(".git"), org != repo {
                return org + "/" + repo.dropLast(".git".count)
            } else if org != repo {
                return org + "/" + repo
            }
        }
        var full = url.absoluteString
        if full.hasPrefix("https://") {
            full.removeFirst("https://".count)
        }
        return full
    }
    
    public var directoryURL: URL? {
        guard let package = package else { return nil }
        var baseURL = package.directoryURL
        for component in Self.extensionsPathComponents {
            baseURL.append(component: component, directoryHint: .isDirectory)
        }
        return baseURL
    }
    
    public var buildResultPageURL: URL? {
        guard let package = package, !name.isEmpty else { return nil }
        return URL(string: "code://code/codekit/extensions/")?.appending(component: "\(name)-\(package.id.uuidString.prefix(6))")
    }
    
    public var buildDirectoryURL: URL? {
        return directoryURL?.appending(component: ".build", directoryHint: .isDirectory)
    }
    
    public var desiredBuildResultStorageURL: URL? {
        guard let desiredBuildHash = desiredBuildHash else { return nil }
        return buildResultStorageURL(forBuildHash: desiredBuildHash)
    }
    
    public var latestBuildResultStorageURL: URL? {
        guard let latestBuildHashAvailable = latestBuildHashAvailable else { return nil }
        return buildResultStorageURL(forBuildHash: latestBuildHashAvailable)
    }
    
    public func buildResultStorageURL(forBuildHash buildHash: String) -> URL? {
        return buildDirectoryURL?.appending(component: "\(name)-\(buildHash).html")
    }
    
    public var humanizedLastBuiltAt: String? {
        guard let lastBuiltAt = lastBuiltAt else { return nil }
        let df = DateFormatter()
        df.dateFormat = "y-MM-dd H:mm:ss.SS"
        return df.string(from: lastBuiltAt)
    }
    
    public var humanizedLastRunStartedAt: String? {
        guard let lastRunStartedAt = lastRunStartedAt else { return nil }
        let df = DateFormatter()
        df.dateFormat = "y-MM-dd H:mm:ss.SS"
        return df.string(from: lastRunStartedAt)
    }
    
    public override init() {
        super.init()
        
//        name.publisher
//            .sink { _ in
//                Task { @MainActor [weak self] in
////                    self?.cachedWorkspaceStorage = nil
//                    try? await self?.refreshBuildHash()
////                    buildHash =
//                }
//            }
//            .store(in: &cancellables)
    }
    
//    @MainActor
//    var isWorkspaceInitialized: Bool {
//        guard let repo = repository else { return false }
//        return (repo.gitTracks.count > 0 || !repo.branch.isEmpty) && !name.isEmpty && cachedWorkspaceStorage != nil
//    }
    
    enum CodingKeys: CodingKey {
        case id
        case repositoryURL
        case name
        case package
        case modifiedAt
        case isDeleted
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(repositoryURL, forKey: .repositoryURL)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(package?.id, forKey: .package)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(isDeleted, forKey: .isDeleted)
    }
}

extension Bundle {
    var appVersionLong: String    { getInfo("CFBundleShortVersionString") }
    var appBuild: String          { getInfo("CFBundleVersion") }
    //var appVersionShort: String { getInfo("CFBundleShortVersion") }
    
    private func getInfo(_ str: String) -> String {
        infoDictionary?[str] as? String ?? "UNKNOWN-VERSION"
    }
}

