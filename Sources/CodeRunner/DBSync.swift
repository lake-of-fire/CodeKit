import SwiftUI
import RealmSwift
import Combine
import WebKit

public protocol SyncableObject: RealmSwift.Object, RealmFetchable, Identifiable, Codable {
    var isDeleted: Bool { get set }
    var modifiedAt: Date { get set }
}

public class DBSync: ObservableObject {
    private var realmConfiguration: Realm.Configuration? = nil
    private var syncedTypes: [(any SyncableObject).Type] = []
    private var asyncJavaScriptCaller: ((String, [String: Any]?, WKFrameInfo?, WKContentWorld?) async throws -> Any?)? = nil
    
    private var subscriptions = Set<AnyCancellable>()
    
    @Published public var isSynchronizing = false
    
    public init() {
    }
    
    @MainActor
    public func initialize(realmConfiguration: Realm.Configuration, syncedTypes: [(any SyncableObject).Type], asyncJavaScriptCaller: @escaping ((String, [String: Any]?, WKFrameInfo?, WKContentWorld?) async throws -> Any?)) async {
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
            
            do {
                try await syncFrom()
            } catch (let error) {
                print("Sync from server error \(error)")
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
        guard let realmConfiguration = realmConfiguration else {
            fatalError("No Realm configuration found.")
        }
        let realm = try await Realm(configuration: realmConfiguration)
        for objectType in syncedTypes {
            realm.objects(objectType)
        }
        
        /*
        var remaining = appSyncClientPostChunkSizeLimit
        
        guard let userID = ManabiAuth.manabiSession.getUser()?.id else { return }
        
        var readerSources = [SyncedReaderSource]()
        for readerSource in realm.objects(SyncedReaderSource.self).where({ $0.owner.id == userID && $0.needsSyncToServer && ($0.sourceURL.starts(with: "https://") || $0.sourceURL.starts(with: "http://")) }) {
            guard remaining > 0 else { break }
            readerSources.append(readerSource)
            remaining -= 1
        }
        
        var decks = [Deck]()
        for deck in realm.objects(Deck.self).where({ $0.owner.id == userID && $0.needsSyncToServer == true }) {
            guard remaining > 0 else { break }
            decks.append(deck)
            remaining -= 1
        }

        var facts = [Fact]()
        for fact in realm.objects(Fact.self).where({ $0.owner.id == userID && $0.needsSyncToServer == true }) {
            guard remaining > 0 else { break }
            facts.append(fact)
            remaining -= 1
        }
        
        var cards = [Card]()
        for card in realm.objects(Card.self).where({ $0.owner.id == userID && $0.needsSyncToServer == true }) {
            guard remaining > 0 else { break }
            cards.append(card)
            remaining -= 1
        }
        
        if remaining == appSyncClientPostChunkSizeLimit {
            // No local objects to sync to server.
            return
        }
        
        let readerSourcesData = try JSONDecoder().decode([ManabiWebAPI.ReaderSourceRequest].self, from: JSONEncoder().encode(readerSources))
        let decksData = try JSONDecoder().decode([ManabiWebAPI.ChunkedDeckRequest].self, from: JSONEncoder().encode(decks))
        let factsData = try JSONDecoder().decode([ManabiWebAPI.FactRequest].self, from: JSONEncoder().encode(facts))
        let cardsData = try JSONDecoder().decode([ManabiWebAPI.CardRequest].self, from: JSONEncoder().encode(cards))
        
        _ = try await ManabiWebAPI.AppSyncAPI.postClientAppSyncChunk(
            appSyncChunkRequest: ManabiWebAPI.AppSyncChunkRequest(
                readerSources: readerSourcesData,
                decks: decksData,
                facts: factsData,
                cards: cardsData,
                cardHistories: []))
        if remaining > 0 {
            lastAppSyncToServerCompletedAt = Date()
        }
        print("Synced \(appSyncClientPostChunkSizeLimit - remaining) objects to server.")
        
        try realm.write {
            for readerSource in readerSources {
                readerSource.needsSyncToServer = false
            }
            for deck in decks {
                deck.needsSyncToServer = false
            }
            for fact in facts {
                fact.needsSyncToServer = false
            }
            for card in cards {
                card.needsSyncToServer = false
            }
        }
         */
    }
    
    @MainActor
    private func syncFrom() async throws {
        /*
        lastAppSyncFromServerThisSessionAt = Date()
        
//        print("syncFromServer(\(self.latestModifiedFromServerAppSync) \(appSyncServerCursors)")
        let resp = try await ManabiWebAPI.AppSyncAPI.getServerAppSyncChunk(appSyncRequestRequest: ManabiWebAPI.AppSyncRequestRequest(latestModifiedFromServer: latestModifiedFromServerAppSync, serverCursors: appSyncServerCursors.isEmpty ? nil : appSyncServerCursors))
//        print("syncFromServer resp \(resp)")
        appSyncClientPostChunkSizeLimit = resp.clientPostChunkSizeLimit
        
        let realm = try await Realm(configuration: SharedRealmConfigurer.configuration)
        
        try realm.write {
            for deck in realm.objects(Deck.self).where({ $0.serverID.in(resp.deletedDeckIds) || $0.uuid.in(resp.deletedDeckUuids) }) {
                deck.isDeleted = true
            }
            for fact in realm.objects(Deck.self).where({ $0.serverID.in(resp.deletedFactIds) || $0.uuid.in(resp.deletedFactUuids) }) {
                fact.isDeleted = true
            }
            
            var user: ManabiCommon.User?
            if let userResp = resp.user {
                user = try realm.create(ManabiCommon.User.self, value: JSONDecoder().decode(User.self, from: JSONEncoder().encode(userResp)), update: .modified)
            }
            #warning("TODO: deleted reader sources, etc. (backend too)")
            
            /*
            if !resp.readerFeedCategories.isEmpty {
                // Temporary hack to replace unchunked results for feed categories only until we move to Supabase.
                for feedCategory in realm.objects(FeedCategory.self) {
                    feedCategory.isDeleted = true
                }
                for feed in realm.objects(Feed.self) {
                    feed.isDeleted = true
                }
                
                for feedCategoryData in resp.readerFeedCategories {
                    let feedCategory = try realm.create(FeedCategory.self, value: JSONDecoder().decode(FeedCategory.self, from: JSONEncoder().encode(feedCategoryData)), update: .modified)
                    for feedData in feedCategoryData.feeds {
                        let feed = try realm.create(Feed.self, value: JSONDecoder().decode(Feed.self, from: JSONEncoder().encode(feedData)), update: .modified)
                        feed.category = feedCategory
                    }
                }
            }*/
            
            for readerSource in resp.readerSources {
                let sourceValue: SyncedReaderSource = try JSONDecoder().decode(SyncedReaderSource.self, from: JSONEncoder().encode(readerSource))
                if let existingSource = realm.objects(SyncedReaderSource.self).where({ $0.owner == user && $0.sourceURL == sourceValue.sourceURL }).first {
                    existingSource.title = sourceValue.title
                    existingSource.thumbnailURL = sourceValue.thumbnailURL
                } else {
                    sourceValue.owner = user
                    realm.create(SyncedReaderSource.self, value: sourceValue, update: .modified)
                }
            }

            var realmDecks = [Int: Deck]()
            for deck in resp.decks {
                let realmDeck = try realm.create(Deck.self, value: [
                    "uuid": deck.uuid,
                    "serverID": deck.id,
                    "owner": user,
                    "originalAuthor": deck.originalAuthor == nil ? nil : JSONDecoder().decode(User.self, from: JSONEncoder().encode(deck.originalAuthor)),
                    "sharedAt": deck.sharedAt,
                    "createdAt": deck.createdAt,
                    "modifiedAt": deck.modifiedAt,
                    "name": deck.name,
                    "image": deck.image,
                    "subscriberCount": deck.subscriberCount,
                    "shareURL": nil,
                    "synchronizedWith": deck.synchronizedWith == nil ? nil : JSONDecoder().decode(SharedDeck.self, from: JSONEncoder().encode(deck.synchronizedWith)),
                    "markdownDescription": deck.markdownDescription,
                    "shared": deck.shared,
                    "suspended": deck.suspended,
                    "isDeleted": deck.active,
                ], update: .modified)
                if let serverID = realmDeck.serverID {
                    realmDecks[serverID] = realmDeck
                }
                
                if let originalAuthor = deck.originalAuthor {
                    let realmOriginalAuthor = try realm.create(User.self, value: JSONDecoder().decode(User.self, from: JSONEncoder().encode(originalAuthor)), update: .modified)
                    realmDeck.originalAuthor = realmOriginalAuthor
                }
                
                if let synchronizedWith = deck.synchronizedWith {
                    let syncedWithDeck = try realm.create(SharedDeck.self, value: JSONDecoder().decode(SharedDeck.self, from: JSONEncoder().encode(synchronizedWith)), update: .modified)
                    realmDeck.synchronizedWith = syncedWithDeck
                }
            }
            
            var realmFacts = [Int: Fact]()
            for fact in resp.facts {
                let realmFact = realm.create(Fact.self, value: [
                    "uuid": fact.uuid as Any,
                    "serverID": fact.id as Any,
                    "deck": realmDecks[fact.deckId] as Any,
                    "createdAt": fact.createdAt as Any,
                    "modifiedAt": fact.modifiedAt as Any,
                    "exampleSentence": fact.exampleSentence as Any,
                    "expression": fact.reading as Any,
                    "meaning": fact.meaning as Any,
                    "readerSourceURL": fact.readerSourceUrl as Any,
                    "suspended": fact.suspended as Any,
                    "isDeleted": fact.active as Any,
                ] as [String: Any], update: .modified)
                realmFact.owner = user
                if let serverID = realmFact.serverID {
                    realmFacts[serverID] = realmFact
                }
            }
            
            for card in resp.cards {
                _ = realm.create(Card.self, value: [
                    "uuid": card.uuid as Any,
                    "owner": user as Any,
                    "serverID": card.id as Any,
                    "fact": realmFacts[card.factId] as Any,
                    "modifiedAt": card.createdOrModifiedAt as Any,
                    "easeFactor": card.easeFactor as Any,
                    "intervalSeconds": card.intervalSeconds as Any,
                    "dueAt": card.dueAt as Any,
                    "lastEaseFactor": card.lastEaseFactor as Any,
                    "lastIntervalSeconds": card.lastIntervalSeconds as Any,
                    "lastDueAt": card.lastDueAt as Any,
                    "lastReviewGrade": card.lastReviewGrade as Any,
                    "lastFailedAt": card.lastFailedAt as Any,
                    "reviewCount": card.reviewCount as Any,
                    "template": card.template.rawValue as Any,
                    "suspended": card.suspended as Any,
                    "isDeleted": card.active as Any,
                ] as [String: Any], update: .modified)
            }
        }
        
        latestModifiedFromServerAppSync = resp.latestModifiedFromServer
        appSyncServerCursors = resp.serverCursors
        
        if resp.isSyncFromServerFinished {
            lastAppSyncFromServerCompletedAt = Date()
        }
        */
    }
}
