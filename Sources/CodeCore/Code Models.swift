import SwiftUI
//import LakeKit
import RealmSwift
import BigSyncKit
import RealmSwiftGaps
import OPML

public actor CodeActor: ObservableObject {
    var configuration: Realm.Configuration
    
//    @MainActor @Published public var reposToBuild:
    
    private var realm: Realm {
        get async throws {
            try await Realm(configuration: configuration, actor: self)
        }
    }
    
    public init(realmConfiguration: Realm.Configuration) {
        configuration = realmConfiguration

    }
    
    public func generateRepositoryCollectionOPMLs() async throws -> [(String, URL)] {
        let realm = try await self.realm
        var opmls = [OPML]()
        var names = [String]()
        for collection in Array(realm.objects(RepositoryCollection.self).where({ !$0.isDeleted })) {
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

public class RepositoryCollection: Object, UnownedSyncableObject, ObjectKeyIdentifiable {
    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var name = ""
    @Persisted public var repositories = RealmSwift.MutableSet<PackageRepository>()
    
    @Persisted public var last = Date()
    
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    public var needsSyncToServer: Bool { false }
    
    public override init() {
        super.init()
    }
    
    func generateOPML() async throws -> OPML {
        let collection = freeze()
        let task = Task.detached { [collection] in
            try Task.checkCancellation()
            let entries = OPMLEntry(text: collection.name, attributes: [
                Attribute(name: "type", value: "CodeKit.RepositoryCollection"),
                Attribute(name: "id", value: collection.id.uuidString),
            ], children: collection.repositories.map({ repo in
                return OPMLEntry(text: repo.name, attributes: [
                    Attribute(name: "type", value: "CodeKit.PackageRepository"),
                    Attribute(name: "url", value: repo.repositoryURL ?? ""),
                    Attribute(name: "id", value: repo.id.uuidString),
                    Attribute(name: "isEnabled", value: repo.isEnabled ? "true" : "false"),
                ])
            }))
            let opml = OPML(
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
}
