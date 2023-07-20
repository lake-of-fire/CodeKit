import Foundation
import Combine
import RealmSwift
import BigSyncKit
import RealmSwiftGaps

public class PackageRepository: Object, UnownedSyncableObject, ObjectKeyIdentifiable {
    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var repositoryURL: String? = nil
//    @Persisted public var name = ""
//    @Persisted public var version = ""
//    @Persisted public var packageDescription = ""
//    @Persisted public var repositoryType: String? = nil
//    @Persisted var repositoryDirectory: String? = nil
    
//    @Persisted var packageJSONDirectory: String? = nil
    @Persisted public var isEnabled = true
    
    @Persisted(originProperty: "repositories") public var repositoryCollection: LinkingObjects<RepositoryCollection>
    
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    
    public var needsSyncToServer: Bool { false }
    
    public override init() {
        super.init()
    }
    
    public var url: URL? {
        guard let repositoryURL = repositoryURL, let url = URL(string: repositoryURL) else { return nil }
        return url
    }
        
    public var name: String {
        return url?.deletingPathExtension().lastPathComponent ?? ""
    }
    
    enum CodingKeys: CodingKey {
        case id
        case repositoryURL
        case isEnabled
        case modifiedAt
        case isDeleted
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
