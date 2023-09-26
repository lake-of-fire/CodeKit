import SwiftUI
import Combine
import RealmSwift
import BigSyncKit
import RealmSwiftGaps
import SwiftGit2
import OPML

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

    public override required init() {
        super.init()
    }
    
    enum CodingKeys: CodingKey {
        case id
        case repositoryURL
        case isEnabled
        case modifiedAt
        case isDeleted
    }
    
    public var name: String {
        return URL(string: repositoryURL)?.deletingPathExtension().lastPathComponent ?? ""
    }
    
    public var directoryURL: URL {
        return getRootDirectory().appending(component: "CodeKit").appending(component: name + "-" + id.uuidString.suffix(6), directoryHint: .isDirectory)
    }
}

public extension CodePackage {
    func generateOPMLEntry() -> OPMLEntry {
        return OPMLEntry(text: name, attributes: [
            Attribute(name: "title", value: name),
            Attribute(name: "type", value: "CodeKit.CodePackage"),
            Attribute(name: "repositoryURL", value: repositoryURL),
            Attribute(name: "id", value: id.uuidString),
            Attribute(name: "isEnabled", value: isEnabled ? "true" : "false"),
        ])
    }
    
    func generateOPML() async throws -> OPML {
        let package = freeze()
        let task = Task.detached { [package] in
            try Task.checkCancellation()
            let entry = package.generateOPMLEntry()
            let opml = OPML(
                title: package.name,
                dateModified: Date(),
                entries: [entry])
            try Task.checkCancellation()
            return opml
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
    
    static func importOPML(entry: OPMLEntry) -> Self? {
        guard entry.attributeStringValue("type") == "CodeKit.CodePackage" else { return nil }
        guard let uuid = entry.attributeUUIDValue("id") else { return nil }
        var obj: Self?
        safeWrite { realm in
            if let match = realm.object(ofType: Self.self, forPrimaryKey: uuid) {
                obj = match
            } else {
                obj = Self()
                obj?.id = uuid
            }
            guard let obj = obj else { return }
            obj.repositoryURL = entry.attributeStringValue("repositoryURL") ?? obj.repositoryURL
            obj.isEnabled = entry.attributeBoolValue("isEnabled") ?? obj.isEnabled
            obj.modifiedAt = Date()
        }
        return obj
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
