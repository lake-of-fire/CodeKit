import SwiftUI
import CodeCore
import Realm
import RealmSwift
import RealmSwiftGaps
import Combine
import WebKit

public protocol DBSyncableObject: Object, Identifiable, Codable {
    associatedtype IDType
    var id: IDType { get set }
    var isDeleted: Bool { get set }
    var modifiedAt: Date { get set }
}

fileprivate extension DBSyncableObject {
    static func dbCollectionName() -> String {
        return Self.className().camelCaseToSnakeCase()
    }
}

public extension DBSyncableObject {
    var idString: String {
        if let uuid = id as? UUID {
            return uuid.uuidString
        } else if let id = id as? String {
            return id
        }
        fatalError("Invalid ID format.")
    }
}

struct DBPendingRelationship: Hashable {
    let relationshipName: String
    let targetID: String
    let entityType: String
    let entityID: String
}

fileprivate extension ObjectSchema {
    func dbCollectionName() -> String {
        return className.camelCaseToSnakeCase()
    }
}
//
//fileprivate extension [any DBSyncableObject] {
//    func encode(to jsonEncoder: JSONEncoder) throws -> Data {
//        try jsonEncoder.encode(self)
//    }
//}

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

struct SyncCheckpoint {
    let modifiedAt: Date
    let id: String
}

public class DBSync: ObservableObject {
    private var realmConfiguration: Realm.Configuration? = nil
//    private var syncedTypes: [Object.Type] = []
    private var syncedTypes: [any DBSyncableObject.Type] = []
    private var syncFromSurrogateMap: [((any DBSyncableObject.Type), ([String: Any], (any DBSyncableObject)?, CodeExtension) -> [String: Any]?)]?
    private var syncToSurrogateMap: [((any DBSyncableObject.Type), (any DBSyncableObject, CodeExtension) -> ((any DBSyncableObject)?, [String: Any]?))]?
    private var asyncJavaScriptCaller: ((String, [String: Any]?, WKFrameInfo?, WKContentWorld?) async throws -> Any?)? = nil
    private var codeExtension: CodeExtension? = nil
    
    private var subscriptions = Set<AnyCancellable>()
    private var pendingRelationships = [DBPendingRelationship]()
    
    @Published public var isSynchronizing = false
    
    lazy var dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return dateFormatter
    }()
    
    public init() { }
    
    @MainActor
    public func initialize(realmConfiguration: Realm.Configuration, syncedTypes: [any DBSyncableObject.Type], syncFromSurrogateMap: [((any DBSyncableObject.Type), ([String: Any], (any DBSyncableObject)?, CodeExtension) -> [String: Any]?)]? = nil, syncToSurrogateMap: [((any DBSyncableObject.Type), (any DBSyncableObject, CodeExtension) -> ((any DBSyncableObject)?, [String: Any]?))]? = nil, asyncJavaScriptCaller: @escaping ((String, [String: Any]?, WKFrameInfo?, WKContentWorld?) async throws -> Any?), codeExtension: CodeExtension, beforeFinalizing: (() async -> Void)? = nil) async {
        self.realmConfiguration = realmConfiguration
        self.syncedTypes = syncedTypes
        self.syncFromSurrogateMap = syncFromSurrogateMap
        self.syncToSurrogateMap = syncToSurrogateMap
        self.asyncJavaScriptCaller = asyncJavaScriptCaller
        self.codeExtension = codeExtension
        
        let realm = try! await Realm(configuration: realmConfiguration)
        
        #warning("TODO: setupChildrenRelationshipsLookup")
        #warning("TODO: conflict res, merge policy == .custom")
        
        try? await initializeRemoteSchema()
        
        for subscription in subscriptions {
            subscription.cancel()
        }
        for objectType in syncedTypes {
            realm.objects(objectType)
                .changesetPublisher
//                .print()
                .delay(for: .milliseconds(20), scheduler: DispatchQueue.main)
                .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
                .receive(on: DispatchQueue.main)
                .sink { changes in
                    switch changes {
                    case .initial(_):
                        break
                    case .update(_, deletions: _, insertions: _, modifications: _):
                        Task { [weak self] in await self?.syncIfNeeded() }
                    case .error(let error):
                        print(error.localizedDescription)
                    }
                }
                .store(in: &subscriptions)
        }
        
        await syncIfNeeded()
        await beforeFinalizing?()
        do {
            _ = try await asyncJavaScriptCaller("await window.chat.parentBridge.finishedSyncingDocsFromCanonical()", nil, nil, nil)
        } catch {
            print("ERROR Finishing sync: \(error)")
        }
    }
    
    @MainActor
    public func syncIfNeeded() async {
        guard !isSynchronizing else { return }
        isSynchronizing = true
        
        do {
            try await syncTo()
        } catch (let error) {
            print("Sync to surrogate DB error: \(error)")
        }
        
        isSynchronizing = false
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
            collections[objectType.dbCollectionName()] = [
                "schema": schema,
            ]
        }
        
//        let d = JSON(collections)
//        print(String(data: d.data(options: .prettyPrinted), encoding: .utf8) ?? "")
        do {
            _ = try await asyncJavaScriptCaller?(
                "return await window.chat.parentBridge.createCollectionsFromCanonical(collections)", ["collections": collections], nil, .page)
        } catch {
            print(error)
            throw error
        }
    }
    
    private func objectSchema(_ realmSchema: ObjectSchema) -> [String: Any] {
        return Dictionary(uniqueKeysWithValues: realmSchema.properties.map { property in
            return (property.name, propertySchema(property, realmSchema: realmSchema))
        })
    }
    
    private func propertySchema(_ property: Property, realmSchema: ObjectSchema) -> [String: Any] {
        var schema = [String: Any]()
        if property.isArray {
            schema = ["type": "array"]
            if property.type == .object, let objectClassName = property.objectClassName {
                schema["items"] = ["type": "string"]
                schema["ref"] = objectClassName
            } else {
                schema["items"] = plainPropertySchema(property)
            }
        } else if property.isSet {
            schema = [
                "type": "array",
                "uniqueItems": true,
            ]
            if property.type == .object, let objectClassName = property.objectClassName {
                schema["items"] = ["type": "string"]
                schema["ref"] = objectClassName
            } else {
                schema["items"] = plainPropertySchema(property)
            }
        } else if property.isMap {
            var properties: [String: Any] = [
                "key": [
                    "type": "string",
                    "maxLength": 36,
                ] as [String: Any],
            ]
            if property.type == .object, let objectClassName = property.objectClassName {
                properties["value"] = [
                    "ref": objectClassName,
                    "type": "string",
                ]
            } else {
                properties["value"] = plainPropertySchema(property)
            }
            schema = [
                "type": "object",
                "properties": properties,
            ]
//        } else if property.type == .object, let objectClassName = property.objectClassName {
//            schema["type"] = "string"
//            schema["ref"] = objectClassName
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
                "ref": realmSchema.dbCollectionName(),
                "type": "string",
//                "properties": objectSchema(realmSchema),
            ]
        }
        
        var schema: [String: Any] = [
            "type": Self.propertyType(property),
        ]
        if property.type == .UUID {
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
        guard let realmConfiguration = realmConfiguration, asyncJavaScriptCaller != nil, let codeExtension = codeExtension else {
            fatalError("Incomplete configuration.")
        }
        let realm = try await Realm(configuration: realmConfiguration)
        
        for objectType in syncedTypes {
//            guard let realmSchema = realm.schema[objectType.className()] else {
//                fatalError("No schema found for object type")
//            }
            
            let rawCheckpoint = try await asyncJavaScriptCaller?("window[`${collectionName}LastCheckpoint`]", ["collectionName": objectType.dbCollectionName()], nil, .page) as? [String: Any]
            var checkpoint: SyncCheckpoint?
            if let rawCheckpoint = rawCheckpoint, let rawModifiedAt = rawCheckpoint["modifiedAt"] as? Int64, let id = rawCheckpoint["id"] as? String {
                let modifiedAt = Date(timeIntervalSince1970: Double(rawModifiedAt) / 1000.0)
                checkpoint = SyncCheckpoint(modifiedAt: modifiedAt, id: id)
            }
            
            @ThreadSafe var objects = realm.objects(objectType)
                .sorted(by: [
                    SortDescriptor(keyPath: "modifiedAt", ascending: true),
                    SortDescriptor(keyPath: "id", ascending: true),
                ])
            if let checkpoint = checkpoint {
                objects = objects?.filter(
                    "modifiedAt >= %@ && (modifiedAt > %@ || id > %@)",
                    checkpoint.modifiedAt, checkpoint.modifiedAt, checkpoint.id)
            }
            
            if let objects = objects {
                for chunk in Array(objects).chunked(into: 400) {
                    guard var objects = chunk as? [any DBSyncableObject] else {
                        print("ERROR Couldn't cast chunk to DBSyncableObject")
                        continue
                    }
                    let surrogateMaps = syncToSurrogateMap?.filter { $0.0 == objectType }.map { $0.1 } ?? []
                    var overrides = [String: [String: Any]]()
                    for surrogateMap in surrogateMaps {
                        objects = objects.compactMap { object in
                            let (newObject, newOverrides) = surrogateMap(object, codeExtension)
                            
                            if let newOverrides = newOverrides, !newOverrides.isEmpty {
                                var toSet = overrides[object.className] ?? [String: Any]()
                                for entry in newOverrides {
                                    toSet[entry.key] = entry.value
                                }
                                overrides[object.className] = toSet
                            }
                            
                            return newObject
                        }
                    }
                    if !objects.isEmpty {
                        try await syncTo(objects: objects, overrides: overrides)
                    }
                }
            }
        }
    }
    
    @MainActor
    private func jsonDictionaryFor(object: some DBSyncableObject, overrides: [String: Any]?) async throws -> String? {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int64(1000 * date.timeIntervalSince1970))
        }
        var jsonDoc = try jsonEncoder.encode(object)
        
        if let overrides = overrides, !overrides.isEmpty, var decoded = try JSONSerialization.jsonObject(with: jsonDoc, options: []) as? [String: Any] {
            for override in overrides {
                decoded[override.key] = override.value
            }
            jsonDoc = try JSONSerialization.data(withJSONObject: decoded)
        }
        guard let jsonStr = String(data: jsonDoc, encoding: .utf8) else {
            print("ERROR encoding \(object)")
            return nil
        }
        return jsonStr
    }
    
    @MainActor
    private func syncTo(objects: [any DBSyncableObject], overrides: [String: [String: Any]]) async throws {
        var jsonStr = "["
        for object in objects {
            guard let objJson = try await jsonDictionaryFor(object: object, overrides: overrides[object.className]) else {
                print("ERROR serializing \(object)")
                continue
            }
            jsonStr += objJson + ","
        }
        jsonStr = String(jsonStr.dropLast(1))
        jsonStr += "]"
        
        if let firstObject = objects.first {
            let collectionName = type(of: firstObject).dbCollectionName()
//            print("window.chat.parentBridge.syncDocsFromCanonical('\(collectionName)', \(jsonStr))")
            _ = try await asyncJavaScriptCaller?("window.chat.parentBridge.syncDocsFromCanonical(collectionName, \(jsonStr))", [
                "collectionName": collectionName,
            ], nil, .page)
        }
    }
    
    public func surrogateDocumentChanges(collectionName: String, changedDocs: [[String: Any]]) {
        var changedDocs = changedDocs
        guard let objectType: any DBSyncableObject.Type = syncedTypes.first(where: { $0.dbCollectionName() == collectionName }) else {
            print("ERROR syncFrom received invalid collection name")
            return
        }
        guard let codeExtension = codeExtension else {
            fatalError("Incomplete configuration.")
        }
        
        let surrogateMaps = syncFromSurrogateMap?.filter { $0.0 == objectType }.map { $0.1 } ?? []
        
        safeWrite { realm in
            for doc in changedDocs {
                guard let rawUUID = doc["id"] as? String, let uuid = UUID(uuidString: rawUUID), let rawModifiedAt = doc["modifiedAt"] as? Int64 else {
                    print("ERROR: Missing or malformed uuid and/or modifiedAt in changedDocs object")
                    continue
                }
                let modifiedAt = Date().advanced(by: TimeInterval(integerLiteral: Int64(rawModifiedAt / 1000)))
                
                let matchingObj = realm.object(ofType: objectType, forPrimaryKey: uuid) as? any DBSyncableObject
                
                var surrogateDoc = Optional(doc)
                for surrogateMap in surrogateMaps {
                    surrogateDoc = surrogateMap(doc, matchingObj, codeExtension)
                    if surrogateDoc == nil {
                        break
                    }
                }
                guard let surrogateDoc = surrogateDoc else { continue }
                
                if let matchingObj = matchingObj {
                    if matchingObj.modifiedAt <= modifiedAt {
                        applyChanges(in: surrogateDoc, to: matchingObj)
                    }
                } else {
                    let newObject = objectType.init()
                    applyChanges(in: surrogateDoc, to: newObject)
                    realm.add(newObject)
                }
            }
        }
        applyPendingRelationships()
    }
    
    private func applyChanges(in doc: [String: Any], to targetObj: any DBSyncableObject) {
        for property in targetObj.objectSchema.properties {
            let key = property.name
            let value = doc[key]
            
            if property.isArray {
                switch property.type {
                case .int:
                    guard let value = value as? [Int] else { continue }
                    let new = RealmSwift.List<Int>()
                    new.append(objectsIn: value)
                    targetObj.setValue(new, forKey: key)
                case .string:
                    guard let value = value as? [String] else { continue }
                    let new = RealmSwift.List<String>()
                    new.append(objectsIn: value)
                    targetObj.setValue(new, forKey: key)
                case .bool:
                    guard let value = value as? [Bool] else { continue }
                    let new = RealmSwift.List<Bool>()
                    new.append(objectsIn: value)
                    targetObj.setValue(new, forKey: key)
                case .float:
                    guard let value = value as? [Float] else { continue }
                    let new = RealmSwift.List<Float>()
                    new.append(objectsIn: value)
                    targetObj.setValue(new, forKey: key)
                case .double:
                    guard let value = value as? [Double] else { continue }
                    let new = RealmSwift.List<Double>()
                    new.append(objectsIn: value)
                    targetObj.setValue(new, forKey: key)
                case .date:
                    guard let value = value as? [String] else { continue }
                    let dates = value.compactMap { dateFormatter.date(from: $0) }
                    let new = RealmSwift.List<Date>()
                    new.append(objectsIn: dates)
                    targetObj.setValue(new, forKey: key)
                case .object:
                    // Save relationship to be applied after all records have been downloaded and persisted
                    // to ensure target of the relationship has already been created
                    if let refs = value as? [String] {
                        for ref in refs {
                            savePendingRelationship(relationshipName: key, targetID: ref, entity: targetObj)
                        }
                    }
                default:
                    print("Unsupported property \(property)")
                }
            } else if property.isSet {
                switch property.type {
                case .int:
                    guard let value = value as? [Int] else { continue }
                    let new = RealmSwift.MutableSet<Int>()
                    new.insert(objectsIn: value)
                    targetObj.setValue(new, forKey: key)
                case .string:
                    guard let value = value as? [String] else { continue }
                    let new = RealmSwift.MutableSet<String>()
                    new.insert(objectsIn: value)
                    targetObj.setValue(new, forKey: key)
                case .bool:
                    guard let value = value as? [Bool] else { continue }
                    let new = RealmSwift.MutableSet<Bool>()
                    new.insert(objectsIn: value)
                    targetObj.setValue(new, forKey: key)
                case .float:
                    guard let value = value as? [Float] else { continue }
                    let new = RealmSwift.MutableSet<Float>()
                    new.insert(objectsIn: value)
                    targetObj.setValue(new, forKey: key)
                case .double:
                    guard let value = value as? [Double] else { continue }
                    let new = RealmSwift.MutableSet<Double>()
                    new.insert(objectsIn: value)
                    targetObj.setValue(new, forKey: key)
                case .date:
                    guard let value = value as? [String] else { continue }
                    let dates = value.compactMap { dateFormatter.date(from: $0) }
                    let new = RealmSwift.MutableSet<Date>()
                    new.insert(objectsIn: dates)
                    targetObj.setValue(new, forKey: key)
                case .object:
                    // Save relationship to be applied after all records have been downloaded and persisted
                    // to ensure target of the relationship has already been created
                    if let refs = value as? [String] {
                        for ref in refs {
                            savePendingRelationship(relationshipName: key, targetID: ref, entity: targetObj)
                        }
                    }
                default:
                    print("Unsupported property \(property)")
                }
            } else if property.isMap {
                fatalError("Map types unsupported by DBSync")
            } else if property.type == .object, let ref = value as? String {
                savePendingRelationship(relationshipName: key, targetID: ref, entity: targetObj)
            } else if property.type == .UUID, let rawUUID = value as? String, let uuid = UUID(uuidString: rawUUID) {
                if targetObj.objectSchema.primaryKeyProperty?.name == key, targetObj.realm != nil {
                    // Don't re-apply primary keys
                    continue
                }
                targetObj.setValue(uuid, forKey: key)
            } else if property.type == .date, let rawDate = value as? Int64 {
                let date = Date(timeIntervalSince1970: Double(rawDate) / 1000.0)
                targetObj.setValue(date, forKey: key)
            } else if value != nil || property.isOptional {
                targetObj.setValue(value, forKey: key)
            }
        }
    }
    
    func savePendingRelationship(relationshipName: String, targetID: String, entity: any DBSyncableObject) {
        pendingRelationships.append(DBPendingRelationship(relationshipName: relationshipName, targetID: targetID, entityType: entity.objectSchema.className, entityID: entity.idString))
    }
    
    func applyPendingRelationships() {
        if pendingRelationships.isEmpty { return }
        
        safeWrite { realm in
            var connectedRelationships = Set<DBPendingRelationship>()
            for relationship in pendingRelationships {
                guard let objectType = syncedTypes.first(where: { $0.className() == relationship.entityType }) else {
                    print("Unsupported relationship entity type \(relationship.entityType)")
                    continue
                }
                
                var entity: (any DBSyncableObject)?
                if let entityUUID = UUID(uuidString: relationship.entityID) {
                    guard let matchedEntity = realm.object(ofType: objectType, forPrimaryKey: entityUUID) as? any DBSyncableObject else {
                        print("Entity \(relationship.entityType) with ID \(relationship.entityID) not found for sync")
                        continue
                    }
                    entity = matchedEntity
                } else {
                    guard let matchedEntity = realm.object(ofType: objectType, forPrimaryKey: relationship.entityID) as? any DBSyncableObject else {
                        print("Entity \(relationship.entityType) with ID \(relationship.entityID) not found for sync")
                        continue
                    }
                    entity = matchedEntity
                }
                guard let entity = entity else { continue }
                
                if entity.isDeleted { continue }
                
                var targetClassName: String?
                for property in entity.objectSchema.properties {
                    if property.name == relationship.relationshipName {
                        targetClassName = property.objectClassName
                        break
                    }
                }
                guard let targetClassName = targetClassName, let targetObjectType = syncedTypes.first(where: { $0.className() == targetClassName }) else {
                    print("Unsupported relationship target type \(relationship.entityType). syncedTypes configured: \(syncedTypes)")
                    continue
                }
                if let targetUUID = UUID(uuidString: relationship.targetID) {
                    guard let target = realm.object(ofType: targetObjectType, forPrimaryKey: targetUUID) as? any DBSyncableObject else {
                        print("Target \(targetObjectType) with ID \(relationship.entityID) not found for sync")
                        continue
                    }
                    applyPendingRelationshipUUID(entity: entity, target: target, relationshipName: relationship.relationshipName)
                } else {
                    guard let target = realm.object(ofType: targetObjectType, forPrimaryKey: relationship.targetID) as? any DBSyncableObject else {
                        print("Target \(targetObjectType) with ID \(relationship.entityID) not found for sync")
                        continue
                    }
                    // FIXME: Maybe breaks for non-UUID PK'd objects in List or MutableSet, see above.
                    entity.setValue(target, forKey: relationship.relationshipName)
                }
                
                connectedRelationships.insert(relationship)
            }
            pendingRelationships.removeAll(where: { connectedRelationships.contains($0) })
        }
    }
    
    func applyPendingRelationshipUUID<T>(entity: any DBSyncableObject, target: T, relationshipName: String) where T: DBSyncableObject {
        if let set = entity.value(forKey: relationshipName) as? MutableSet<T> {
            set.insert(target)
        } else if let lst = entity.value(forKey: relationshipName) as? RealmSwift.List<T> {
            lst.append(target)
        } else {
            entity.setValue(target, forKey: relationshipName)
        }
    }
}

fileprivate extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
