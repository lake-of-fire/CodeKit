import SwiftUI
//import LakeKit
import RealmSwift
import BigSyncKit
import RealmSwiftGaps
import OPML
import Clibgit2

public actor CodeActor: ObservableObject {
//    @MainActor @Published public var reposToBuild:
    
    private var configuration: Realm.Configuration
    private var realm: Realm {
        get async throws {
            try await Realm(configuration: configuration, actor: self)
        }
    }
    
    public init(realmConfiguration: Realm.Configuration = Realm.Configuration.defaultConfiguration) {
        configuration = realmConfiguration
        git_libgit2_init()
    }
    
    deinit {
        git_libgit2_shutdown()
    }
    
    public func generatePackageCollectionOPMLs() async throws -> [(String, URL)] {
        let realm = try await self.realm
        var opmls = [OPML]()
        var names = [String]()
        for collection in Array(realm.objects(PackageCollection.self).where({ !$0.isDeleted })) {
            try Task.checkCancellation()
            let opml = try await collection.generateOPML()
            opmls.append(opml)
            names.append(collection.name)
        }
        
        let task = Task { @MainActor [opmls] () -> [URL] in
            var urls = [URL]()
            for opml in opmls {
                try Task.checkCancellation()
                let resultURL = FileManager.default.temporaryDirectory
                    .appending(component: "codekit-opml", directoryHint: .notDirectory)
                    .appendingPathExtension("opml")
                do {
                    if FileManager.default.fileExists(atPath: resultURL.path(percentEncoded: false)) {
                        try FileManager.default.removeItem(at: resultURL)
                    }
                    let data = opml.xml.data(using: .utf8) ?? Data()
                    try data.write(to: resultURL, options: [.atomic])
                    urls.append(resultURL)
                }
            }
            return urls
        }
        let urls = try await withTaskCancellationHandler {
            return try await task.value
        } onCancel: {
            task.cancel()
        }
        return Array(zip(names, urls))
    }
}

public class PackageCollection: Object, UnownedSyncableObject, ObjectKeyIdentifiable {
    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var name = ""
    @Persisted public var packages = RealmSwift.MutableSet<CodePackage>()
    
//    @Persisted public var last = Date()
    
    @Persisted public var modifiedAt = Date()
    @Persisted public var isUserEditable = true
    @Persisted public var isDeleted = false
    public var needsSyncToServer: Bool { false }
    
    public override init() {
        super.init()
    }
    
    public func generateOPML() async throws -> OPML {
        let collection = freeze()
        let task = Task.detached { [collection] in
            try Task.checkCancellation()
            let entries = OPMLEntry(text: collection.name, attributes: [
                Attribute(name: "type", value: "CodeKit.PackageCollection"),
                Attribute(name: "id", value: collection.id.uuidString),
                Attribute(name: "title", value: collection.name),
            ], children: collection.packages.where({ !$0.isDeleted }).map({ package in
                return package.generateOPMLEntry()
            }))
            let opml = OPML(
                title: collection.name,
                dateModified: Date(),
                entries: [entries])
            try Task.checkCancellation()
            return opml
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
    
    public static func importOPML(entry: OPMLEntry) -> PackageCollection? {
        guard entry.attributeStringValue("type") == "CodeKit.PackageCollection" else { return nil }
        var obj: PackageCollection?
        safeWrite { realm in
            if let uuid = entry.attributeUUIDValue("id"), let match = realm.object(ofType: Self.self, forPrimaryKey: uuid) {
                obj = match
            } else {
                obj = PackageCollection()
            }
            guard let obj = obj else { return }
            obj.id = entry.attributeUUIDValue("id") ?? obj.id
            obj.name = entry.title ?? entry.text
            obj.modifiedAt = Date()
            for entry in entry.children ?? [] {
                if let package = CodePackage.importOPML(entry: entry) {
                    obj.packages.insert(package)
                }
            }
            for removeObj in obj.packages.where({ !$0.isDeleted && !$0.id.in((entry.children ?? []).compactMap({ $0.attributeUUIDValue("id") })) }) {
                removeObj.isDeleted = true
            }
        }
        return obj
    }
}
