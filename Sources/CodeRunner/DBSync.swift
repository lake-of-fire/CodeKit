import SwiftUI
import Realm
import RealmSwift
import Combine
import WebKit

public protocol DBSyncableObject: Object, RealmFetchable, Identifiable, Codable {
    var isDeleted: Bool { get set }
    var modifiedAt: Date { get set }
}

fileprivate extension String {
    func camelCaseToSnakeCase() -> String {
        let acronymPattern = "([A-Z]+)([A-Z][a-z]|[0-9])"
        let fullWordsPattern = "([a-z])([A-Z]|[0-9])"
        let digitsFirstPattern = "([0-9])([A-Z])"
        return self.processCamelCaseRegex(pattern: acronymPattern)?
            .processCamelCaseRegex(pattern: fullWordsPattern)?
            .processCamelCaseRegex(pattern:digitsFirstPattern)?.lowercased() ?? self.lowercased()
    }
    
    private func processCamelCaseRegex(pattern: String) -> String? {
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(location: 0, length: count)
        return regex?.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: "$1_$2")
    }
}

fileprivate func dbCollectionName(realmSchema: ObjectSchema) -> String {
    return realmSchema.className.camelCaseToSnakeCase()
}

struct SyncCheckpoint {
    let modifiedAt: Double
    let id: UUID
}

public class DBSync: ObservableObject {
    private var realmConfiguration: Realm.Configuration? = nil
    private var syncedTypes: [Object.Type] = []
    private var asyncJavaScriptCaller: ((String, [String: Any]?, WKFrameInfo?, WKContentWorld?) async throws -> Any?)? = nil
    
    private var subscriptions = Set<AnyCancellable>()
    
    @Published public var isSynchronizing = false
    
    public init() {
    }
    
    @MainActor
    public func initialize(realmConfiguration: Realm.Configuration, syncedTypes: [Object.Type], asyncJavaScriptCaller: @escaping ((String, [String: Any]?, WKFrameInfo?, WKContentWorld?) async throws -> Any?)) async {
        self.realmConfiguration = realmConfiguration
        self.syncedTypes = syncedTypes
        self.asyncJavaScriptCaller = asyncJavaScriptCaller
        
        try? await initializeRemoteSchema()
        
        let realm = try! await Realm(configuration: realmConfiguration)
        for objectType in syncedTypes {
            realm.objects(objectType)
                .changesetPublisher
                .delay(for: .milliseconds(50), scheduler: DispatchQueue.main)
                .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
                .receive(on: DispatchQueue.main)
                .sink { changes in
                    switch changes {
                    case .initial(_):
                        Task.detached { [weak self] in await self?.beginSyncIfNeeded() }
                    case .update(_, deletions: _, insertions: _, modifications: _):
                        Task.detached { [weak self] in await self?.beginSyncIfNeeded() }
                    case .error(let error):
                        print(error.localizedDescription)
                    }
                }
                .store(in: &subscriptions)
        }
    }
    
    public func beginSyncIfNeeded() async {
        Task { @MainActor in
            guard !isSynchronizing else { return }
            isSynchronizing = true
            
            do {
                try await syncTo()
            } catch (let error) {
                print("Sync to server error \(error)")
            }
            
            isSynchronizing = false
        }
    }
    
    @MainActor
    private func initializeRemoteSchema() async throws {
        guard let realmConfiguration = realmConfiguration else {
            fatalError("No Realm configuration found for schema initialization.")
        }
        let realm = try await Realm(configuration: realmConfiguration)
        var collections = [String: Any]()
        for objectType in syncedTypes {
            guard let realmSchema = realm.schema[objectType.className()] else { fatalError("No Realm schema for \(objectType.className())") }
            guard let primaryKeyProperty = realmSchema.primaryKeyProperty else { fatalError("No primary key for \(realmSchema.className)") }
            let schema: [String: Any] = [
                "title": "\(realmSchema.className) schema",
                "version": 0,
                "description": "",
                "keyCompression": false,
                "primaryKey": primaryKeyProperty.name,
                "type": "object",
                "properties": objectSchema(realmSchema),
                "required": realmSchema.properties.compactMap { $0.isOptional ? nil : $0.name },
//                "encrypted": [],
            ]
            collections[dbCollectionName(realmSchema: realmSchema)] = [
                "schema": schema,
            ]
        }
        
        let d = JSON(collections)
        print(String(data: d.data(options: .prettyPrinted), encoding: .utf8) ?? "")
        print(Date())
        try await Task.sleep(nanoseconds: 8_000_000_000)
        print(Date())
        print("### GONNA SHOW...")
        let ret = try await asyncJavaScriptCaller?(
            "window.createCollectionsFromCanonical(collections)", ["collections": collections], nil, .page)
        print("### RESPONSE FROM WEBVIEW:")
        print(ret)
    }
    
    private func objectSchema(_ realmSchema: ObjectSchema) -> [String: Any] {
        return Dictionary(uniqueKeysWithValues: realmSchema.properties.map { property in
            return (property.name, propertySchema(property, realmSchema: realmSchema))
        })
    }
    
    private func propertySchema(_ property: Property, realmSchema: ObjectSchema) -> [String: Any] {
        var schema = [String: Any]()
        if property.isArray {
            schema = [
                "type": "array",
                "items": plainPropertySchema(property),
            ]
        } else if property.isSet {
            schema = [
                "type": "array",
                "uniqueItems": true,
                "items": plainPropertySchema(property),
            ]
        } else if property.isMap {
            schema = [
                "type": "object",
                "properties": [
                    "key": [
                        "type": "string",
                    ],
                    "value": [
                        "type": Self.propertyType(property),
                    ],
                ],
            ]
        } else {
            schema = plainPropertySchema(property)
        }
        if property.name == realmSchema.primaryKeyProperty?.name {
            schema["final"] = true
            if property.type == .string {
                schema["maxLength"] = 1024 * 4
            }
        }
        return schema
    }
    
    private func plainPropertySchema(_ property: Property) -> [String: Any] {
        guard let realmConfiguration = realmConfiguration else {
            fatalError("No Realm configuration found for schema initialization.")
        }
        let realm = try! Realm(configuration: realmConfiguration)
        
        if property.type == .object {
            guard let objectClassName = property.objectClassName, let realmSchema = realm.schema[objectClassName] else { fatalError("Unexpected issue during Realm schema serialization") }
            return [
                "type": "object",
                "properties": objectSchema(realmSchema),
            ]
        }
        
        var schema: [String: Any] = [
            "type": Self.propertyType(property),
        ]
        if property.type == .objectId || property.type == .UUID {
            schema["maxLength"] = 36
        }
        return schema
    }
    
    private static func propertyType(_ property: Property) -> String {
        switch property.type {
        case .UUID: return "string"
        case .bool: return "boolean"
        case .data: return "string"
        case .date: return "string"
//        case .decimal128: return "string"
        case .double: return "number"
        case .float: return "number"
        case .int: return "integer"
        case .objectId: return "string"
        case .string: return "string"
        default:
            fatalError("Unsupported synced property type '\(property.type)'")
        }
    }
    
    @MainActor
    private func syncTo() async throws {
        guard let realmConfiguration = realmConfiguration, asyncJavaScriptCaller != nil else {
            fatalError("No Realm configuration found.")
        }
        let realm = try await Realm(configuration: realmConfiguration)
        
        for objectType in syncedTypes {
            guard let realmSchema = realm.schema[objectType.className()] else {
                fatalError("No schema found for object type")
            }
            let rawCheckpoint = try await asyncJavaScriptCaller?("window[`${collectionName}LastCheckpoint`]", ["collectionName": dbCollectionName(realmSchema: realmSchema)], nil, .page) as? [String: Any]
            var checkpoint: SyncCheckpoint?
            if let rawCheckpoint = rawCheckpoint, let modifiedAt = rawCheckpoint["updatedAt"] as? Double, let id = rawCheckpoint["id"] as? String, let uuid = UUID(uuidString: id) {
                checkpoint = SyncCheckpoint(modifiedAt: modifiedAt, id: uuid)
            }
            
            var objects = realm.objects(objectType)
                .sorted(by: [
                    SortDescriptor(keyPath: "modifiedAt", ascending: true),
                    SortDescriptor(keyPath: "id", ascending: true),
                ])
            if let checkpoint = checkpoint {
                objects = objects.filter(
                    "modifiedAt >= %@ && (modifiedAt > %@ || id > %@)",
                    checkpoint.modifiedAt, checkpoint.modifiedAt, checkpoint.id)
            }
            
            let batchSize = 20
            var remaining = batchSize
            var toSend: [Object] = []
            for obj in objects {
                toSend.append(obj)
                remaining -= 1
                if remaining == 0 {
                    try await syncTo(objects: toSend)
                    remaining = batchSize
                }
            }
        }
    }
    
    @MainActor
    private func syncTo(objects: [Object]) async throws {
        guard let realmSchema = objects.first?.objectSchema else { return }
        let collectionName = dbCollectionName(realmSchema: realmSchema)
        _ = try await asyncJavaScriptCaller?("window.syncDocsFromCanonical(collectionName, changedDocs)", [
            "collectionName": collectionName,
            "changedDocs": objects,
        ], nil, .page)
    }
    
    public func syncFrom(collectionName: String, changedDocs: [String: Any]) {
        print("syncfrom ")
        print(collectionName)
    }
}
