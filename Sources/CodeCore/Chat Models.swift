import SwiftUI
import RealmSwift
import BigSyncKit
import SwiftUtilities
import RealmSwiftGaps

public class Room: Object, UnownedSyncableObject {
    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var displayName = "New Chat"
    @Persisted public var displayIcon = "💬"
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    
    @Persisted public var isPinned = false
    @Persisted public var participants = MutableSet<Persona>()
    @Persisted(originProperty: "room") public var events: LinkingObjects<Event>
    
    public var needsSyncToServer: Bool { false }
    
//    public override convenience init () {
//        self.init()
//        self.displayName = preset.displayName
//        self.displayIcon = preset.displayIcon
//    }
    
    public var lastActivityAt: Date {
        return events.last?.createdAt ?? createdAt
    }
    
    public enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case displayIcon
        case participants
        case createdAt
        case modifiedAt
        case isDeleted
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(displayIcon, forKey: .displayIcon)
        try container.encode(participants.map { $0.id.uuidString }, forKey: .participants)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(isDeleted, forKey: .isDeleted)
    }
    
    public static func create() -> Room {
        let room = Room()
        safeWrite { realm in
            realm.add(room)
        }
        return room
    }
    
    @discardableResult
    public func submitUserMessage(text: String, directlyAddressing: Set<Persona> = Set()) -> Event? {
//        guard let realm = realm?.thaw() else { return }
//        try! realm.write {
        var event: Event?
        safeWrite { realm in
            event = realm.create(Event.self, value: [
                "room": self,
                "sender": Persona.getOrCreateUser(),
                "type": "message",
                "directlyAddresses": directlyAddressing,
                "content": text,
            ] as [String : Any?], update: .modified)
        }
        return event
//        }
    }
    
    public func delete() {
        for event in events {
            for link in event.links {
                link.isDeleted = true
            }
            event.isDeleted = true
        }
        isDeleted = true
    }
}

public class Persona: Object, UnownedSyncableObject {
    @Persisted(primaryKey: true) public var id = UUID()
    
    @Persisted public var personaType = PersonaType.bot
    public enum PersonaType: String, Codable, PersistableEnum {
        case user = "user"
        case bot = "bot"
        //case chatOnMac = "chatOnMac"
        //case chatOnMacTeam = "chatOnMacTeam"
    }
    
    @Persisted public var online = false
    @Persisted public var name = ""
    @Persisted public var iconSymbol: String?
    @Persisted public var tint: PersonaTint = .gray
    public enum PersonaTint: String, Codable, PersistableEnum, CaseIterable {
            case red = "red"
            case orange = "orange"
            case yellow = "yellow"
            case green = "green"
            case mint = "mint"
            case teal = "teal"
            case cyan = "cyan"
            case blue = "blue"
            case indigo = "indigo"
            case purple = "purple"
            case pink = "pink"
            case brown = "brown"
            case gray = "gray"
    }
    
    @Persisted public var homepage: URL?
    @Persisted public var providedByExtension: CodeExtension?
    
    // Bot params
    @Persisted public var modelOptions = RealmSwift.List<String>()
    @objc @Persisted public dynamic var selectedModel = ""
    @Persisted public var modelTemperature = 0.5
    @Persisted public var customInstructionForContext = ""
    @Persisted public var customInstructionForResponses = ""
    
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    public var needsSyncToServer: Bool { false }
    
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case personaType
        case name
        case iconSymbol
        case tint
        case online
        case homepage
        case providedByExtension
        case modelOptions
        case selectedModel
        case modelTemperature
        case customInstructionForContext
        case customInstructionForResponses
        case modifiedAt
        case isDeleted
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(online, forKey: .online)
        try container.encode(personaType, forKey: .personaType)
        try container.encode(name, forKey: .name)
        try container.encode(iconSymbol, forKey: .iconSymbol)
        try container.encode(tint, forKey: .tint)
        try container.encodeIfPresent(homepage, forKey: .homepage)
        try container.encodeIfPresent(providedByExtension?.id, forKey: .providedByExtension)
        try container.encode(modelOptions, forKey: .modelOptions)
        try container.encode(selectedModel, forKey: .selectedModel)
        try container.encode(modelTemperature, forKey: .modelTemperature)
        try container.encode(customInstructionForContext, forKey: .customInstructionForContext)
        try container.encode(customInstructionForResponses, forKey: .customInstructionForResponses)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(isDeleted, forKey: .isDeleted)
    }
    
    public static func getOrCreateUser() -> Persona {
        let realm = try! Realm()
        if let user = realm.objects(Persona.self).where({ $0.personaType == .user && !$0.isDeleted }).first {
            return user
        }
        let user = Persona()
        user.name = "User"
        user.personaType = .user
        safeWrite { realm in
            realm.add(user)
        }
        return user
    }
}

public class Event: Object, UnownedSyncableObject {
    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var room: Room?
    @Persisted public var sender: Persona?
    @Persisted public var type = ""
    @Persisted public var content = ""
    @Persisted public var links = RealmSwift.List<Link>()
    
    @Persisted public var directlyAddresses = RealmSwift.MutableSet<Persona>()
    @Persisted public var retryablePersonaFailures = RealmSwift.MutableSet<Persona>()
    @Persisted public var failureMessages = RealmSwift.MutableSet<String>()
    @Persisted public var retried: Event?
    
//    @Persisted var commands: RealmSwift.List<CommandEnum>
//    @Persisted var commandContextJSON: String
    
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    public var needsSyncToServer: Bool { false }
    
    enum CodingKeys: String, CodingKey {
        case id
        case room
        case sender
        case type
        case content
        case links
        case directlyAddresses
        case retryablePersonaFailures
        case failureMessages
        case createdAt
        case modifiedAt
        case isDeleted
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.uuidString, forKey: .id)
        try container.encodeIfPresent(room?.id, forKey: .room)
        try container.encodeIfPresent(sender?.id, forKey: .sender)
        try container.encode(type, forKey: .type)
        try container.encode(content, forKey: .content)
        try container.encode(type, forKey: .type)
        try container.encode(links.map { $0.id }, forKey: .links)
        try container.encode(directlyAddresses.map { $0.id }, forKey: .directlyAddresses)
        try container.encode(retryablePersonaFailures.map { $0.id }, forKey: .retryablePersonaFailures)
        try container.encode(failureMessages, forKey: .failureMessages)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(isDeleted, forKey: .isDeleted)
    }
//    func command(_ command: CommandEnum) -> [String: Any]? {
//        return nil
//    }
    
    public func filterPersonaFailures(byCodeExtension codeExtension: CodeExtension) -> [Persona] {
        return Array(retryablePersonaFailures.where {
            $0.providedByExtension.id == codeExtension.id
        })
    }
    
    public func retry() {
        guard !retryablePersonaFailures.isEmpty && retried == nil && sender?.personaType == .user else {
            return
        }
        if let retriedEvent = room?.submitUserMessage(text: content, directlyAddressing: Set(retryablePersonaFailures)) {
            safeWrite(self) { _, event in
                event.retried = retriedEvent
                event.retryablePersonaFailures.removeAll()
            }
        }
    }
}

public class Link: Object, UnownedSyncableObject {
    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted var href: URL = URL(string: "about:blank")!
    @Persisted var type = "text/plain"
    @Persisted var title = ""
    @Persisted var byteLength = 0
    @Persisted var rel = "enclosure"
    
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    public var needsSyncToServer: Bool { false }
    
    public enum CodingKeys: String, CodingKey {
        case id
        case href
        case type
        case title
        case byteLength
        case rel
        case modifiedAt
        case isDeleted
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(href, forKey: .href)
        try container.encode(type, forKey: .type)
        try container.encode(title, forKey: .title)
        try container.encode(byteLength, forKey: .byteLength)
        try container.encode(rel, forKey: .rel)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(isDeleted, forKey: .isDeleted)
    }
}

//public class MessageTemplate: Object, UnownedSyncableObject {
//    @Persisted(primaryKey: true) public var id = UUID().uuidString
//    @Persisted public var modifiedAt = Date()
//    @Persisted public var isDeleted = false
//
//    @Persisted var author = AuthorEnum.user
//    @Persisted var title = ""
//    @Persisted var text = ""
//    @Persisted var systemText = ""
//
//    public var needsSyncToServer: Bool { false }
//
//    var displayName: String {
//        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? systemText : text) : title
//        if name.count > 45 {
//            return name.prefix(45) + "..."
//        }
//        return name
//    }
//}

//public class Tool: Object, UnownedSyncableObject {
//    @Persisted(primaryKey: true) public var id = UUID()
//    @Persisted public var displayName = ""
//    @Persisted var displaySubtitle = ""
//    @Persisted var displayIcon = "💬"
//    @Persisted var promptTemplates: RealmSwift.List<MessageTemplate>
//    @Persisted var replyTemplates: RealmSwift.List<MessageTemplate>
//    @Persisted var isFavorite = false
//    @Persisted public var createdAt = Date()
//    @Persisted public var modifiedAt = Date()
//    @Persisted public var isDeleted = false
//
//    public var needsSyncToServer: Bool { false }
//
//    convenience init(displayName: String, displaySubtitle: String, displayIcon: String, promptTemplates: [MessageTemplate], replyTemplates: [MessageTemplate]) {
//        self.init()
//        self.displayName = displayName
//        self.displaySubtitle = displaySubtitle
//        self.displayIcon = displayIcon
//        self.promptTemplates.append(objectsIn: promptTemplates)
//        self.replyTemplates.append(objectsIn: replyTemplates)
//    }
////
////    func makeMessage(inConversation conversation: Conversation, author: AuthorEnum = .user, text: String) -> ConversationMessage {
////        let message = ConversationMessage()
////        message.conversation = conversation
////        message.author = author
////        message.text = text
////        message.preset = self
////        return message
////    }
//
//    func makeMessages(inConversation conversation: Conversation, fromTemplate template: MessageTemplate) -> [ConversationMessage] {
//        var messages = [ConversationMessage]()
//        if !template.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
//            let message = ConversationMessage()
//            message.conversation = conversation
//            message.author = template.author
//            message.text = template.text
//            message.preset = self
//            messages.append(message)
//        }
//        if !template.systemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
//            let message = ConversationMessage()
//            message.conversation = conversation
//            message.author = .chatOnMac
//            message.text = template.systemText
//            message.preset = self
//            messages.append(message)
//        }
//        return messages
//    }
//}

//public class ConversationManager: ObservableObject {
//    static func
//}
