import SwiftUI
import RealmSwift
import BigSyncKit
import SwiftUtilities
import RealmSwiftGaps
import MarkdownKit

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
    
    @RealmBackgroundActor
    public static func create() async throws -> Room {
        let room = Room()
        let realm = try await Realm(configuration: .defaultConfiguration, actor: RealmBackgroundActor.shared)
        try await realm.asyncWrite {
            realm.add(room)
        }
        return room
    }
    
    @discardableResult
    @RealmBackgroundActor
    public func submitUserMessage(text: String, directlyAddressing: Set<Persona> = Set()) async throws -> Event? {
//        guard let realm = realm?.thaw() else { return }
//        try! realm.write {
        var event: Event?
        let realm = try await Realm(configuration: .defaultConfiguration, actor: RealmBackgroundActor.shared)
        let sender = try await Persona.getOrCreateUser()
        try await realm.asyncWrite {
            event = realm.create(Event.self, value: [
                "room": self,
                "sender": sender,
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
    @Persisted public var lastSeenOnline: Date?
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
    
    @Persisted public var downloadsLastCheckedAt: Date?
    @Persisted public var isTyping = false
    
    // Bot params
    @Persisted public var modelOptions = RealmSwift.List<String>()
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
        case isTyping
        case lastSeenOnline
        case providedByExtension
        case modelOptions
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
        try container.encode(isTyping, forKey: .isTyping)
        try container.encodeIfPresent(lastSeenOnline, forKey: .lastSeenOnline)
        try container.encodeIfPresent(homepage, forKey: .homepage)
        try container.encodeIfPresent(providedByExtension?.id, forKey: .providedByExtension)
        try container.encode(modelOptions, forKey: .modelOptions)
        try container.encode(modelTemperature, forKey: .modelTemperature)
        try container.encode(customInstructionForContext, forKey: .customInstructionForContext)
        try container.encode(customInstructionForResponses, forKey: .customInstructionForResponses)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(isDeleted, forKey: .isDeleted)
    }
    
    @RealmBackgroundActor
    public static func getOrCreateUser() async throws -> Persona {
        let realm = try await Realm(configuration: .defaultConfiguration, actor: RealmBackgroundActor.shared)
        if let user = realm.objects(Persona.self).where({ $0.personaType == .user && !$0.isDeleted }).first {
            return user
        }
        let user = Persona()
        user.name = "User"
        user.personaType = .user
        try await realm.asyncWrite {
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
    
    @MainActor
    public func retry() async throws {
        guard !retryablePersonaFailures.isEmpty && retried == nil && sender?.personaType == .user else {
            return
        }
        if let retriedEvent = try await room?.submitUserMessage(text: content, directlyAddressing: Set(retryablePersonaFailures)) {
            try await Realm.asyncWrite(self) { _, event in
                event.retried = retriedEvent
                event.retryablePersonaFailures.removeAll()
            }
        }
    }
    
    public func makeAttributedString() -> NSAttributedString? {
        let generator = AttributedStringGenerator(
            fontSize: 12,
            fontFamily: "SF Pro, sans-serif",
            fontColor: Color.primary.toHex(),
            h1Color: Color.primary.toHex())
        let doc = MarkdownParser.standard.parse(content.trimmingCharacters(in: .whitespacesAndNewlines))
        return generator.generate(doc: doc)
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

fileprivate extension Color {
    func toHex() -> String {
#if os(macOS)
        guard let components = NSColor(self).cgColor.components else { return "" }
#else
        guard let components = UIColor(self).cgColor.components else { return "" }
#endif
        
        let r = UInt8(components[0] * 255.0)
        let g = UInt8(components[1] * 255.0)
        let b = UInt8(components[2] * 255.0)
        
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
