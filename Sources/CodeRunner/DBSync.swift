import SwiftUI
import Realm
import RealmSwift
import Combine
import WebKit

public protocol SyncableObject: Object, RealmFetchable, Identifiable, Codable {
    var isDeleted: Bool { get set }
    var modifiedAt: Date { get set }
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
                "keyCompression": true,
                "primaryKey": primaryKeyProperty.name,
                "type": "object",
                "properties": objectSchema(realmSchema),
                "required": realmSchema.properties.compactMap { $0.isOptional ? nil : $0.name },
//                "encrypted": [],
            ]
            collections[realmSchema.className] = [
                "schema": schema,
            ]
        }
        _ = try await asyncJavaScriptCaller?(
            "window.createCollectionsFromCanonical(collections)", ["collections": collections], nil, .page)
    }
    
    private func objectSchema(_ realmSchema: ObjectSchema) -> [String: Any] {
        return Dictionary(uniqueKeysWithValues: realmSchema.properties.map { property in
            return (property.name, propertySchema(property, realmSchema: realmSchema))
        })
    }
    
    private func propertySchema(_ property: Property, realmSchema: ObjectSchema) -> [String: Any] {
        guard let realmConfiguration = realmConfiguration else {
            fatalError("No Realm configuration found for schema initialization.")
        }
        let realm = try! Realm(configuration: realmConfiguration)
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
        } else if property.type == .object {
            guard let objectClassName = property.objectClassName, let realmSchema = realm.schema[objectClassName] else { fatalError("Unexpected issue during Realm schema serialization") }
            schema = [
                "type": "object",
                "properties": objectSchema(realmSchema),
            ]
        } else if property.type == .objectId || property.type == .UUID {
            schema = plainPropertySchema(property)
            schema["maxLength"] = 36
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
        return [
            "type": Self.propertyType(property),
        ]
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
        
        for objectType in syncedTypes {
            let rawCheckpoint = try await asyncJavaScriptCaller?("window[`${collectionName}LastCheckpoint`]", ["collectionName": objectType.className()], nil, .page) as? [String: Any]
            var checkpoint: SyncCheckpoint?
            if let rawCheckpoint = rawCheckpoint, let modifiedAt = rawCheckpoint["updatedAt"] as? Double, let id = rawCheckpoint["id"] as? String, let uuid = UUID(uuidString: id) {
                checkpoint = SyncCheckpoint(modifiedAt: modifiedAt, id: uuid)
            }
            
            let realm = try await Realm(configuration: realmConfiguration)
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
        guard let collectionName = objects.first?.objectSchema.className else { return }
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
