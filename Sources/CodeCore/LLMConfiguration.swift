import SwiftUI
import RealmSwift
import BigSyncKit
import SwiftUtilities
import RealmSwiftGaps
import SwiftUIDownloads

public class LLMConfiguration: Object, UnownedSyncableObject {
    public static var securityApplicationGroupIdentifier = ""
    
    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var name = ""
    @Persisted public var organization = ""
    @Persisted public var displayName = ""
    @Persisted public var markdownDescription = ""
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    
    @Persisted public var defaultPriority = -1
    @Persisted public var providedByExtension: CodeExtension?
    @Persisted public var usedByPersona: Persona?
    @Persisted public var apiURL = ""
    
    // Local LLM
    @Persisted public var modelDownloadURL = ""
    @Persisted public var memoryRequirement: Int?
    @Persisted public var modelInference = ""
    @Persisted public var context: Int?
    @Persisted public var nBatch: Int?
    @Persisted public var topK: Int?
    @Persisted public var systemFormat = ""
    @Persisted public var systemPromptTemplate = ""
    @Persisted public var promptFormat = ""
    @Persisted public var stopWords = RealmSwift.List<String>()
//    @Persisted public var supportsCPUInference = true
    @Persisted public var temperature: Float = 0.75
    @Persisted public var topP: Float?
    @Persisted public var repeatLastN: Int?
    @Persisted public var repeatPenalty: Float?
    
    public var needsSyncToServer: Bool { false }
    
    public static var downloadDirectory: DownloadDirectory {
        DownloadDirectory.local(parentDirectoryName: "Downloads/llm-models", groupIdentifier:  Self.securityApplicationGroupIdentifier)
    }
    public var downloadable: Downloadable? {
        guard let url = URL(string: modelDownloadURL) else { return nil }
        return Downloadable(
            name: name,
            destination: Self.downloadDirectory,
            filename: url.lastPathComponent,
            downloadMirrors: [url])
    }
    
    public func supports(safelyAvailableMemory: UInt64) -> Bool {
        if !supportsCPU && !canUseMetal {
            return false
        }
        return memoryRequirement == nil || (Int64(memoryRequirement ?? 0) <= Int64(safelyAvailableMemory))
    }
    
    public var supportsCPU: Bool {
        return modelDownloadURL.isEmpty || Double(memoryRequirement ?? 0) <= 2.1
    }
    
    public var canUseMetal: Bool {
#if os(iOS)
        return MTLCreateSystemDefaultDevice()?.supportsFamily(.apple7) ?? false
#else
        guard MTLCreateSystemDefaultDevice()?.supportsFamily(.mac2) ?? false else { return false }
        var systeminfo = utsname()
        uname(&systeminfo)
        let machine = withUnsafeBytes(of: &systeminfo.machine) {bufPtr->String in
            let data = Data(bufPtr)
            if let lastIndex = data.lastIndex(where: {$0 != 0}) {
                return String(data: data[0...lastIndex], encoding: .isoLatin1)!
            } else {
                return String(data: data, encoding: .isoLatin1)!
            }
        }
        return machine == "arm64"
#endif
    }
    
    public var isModelInstalled: Bool {
        guard !isDeleted, let downloadable = downloadable else { return false }
        return FileManager.default.fileExists(atPath: downloadable.localDestination.path)
    }
    
    public static func isModelInstalled(_ modelName: String) -> Bool {
        let realm = try! Realm()
        if let path = realm.objects(LLMConfiguration.self).where({
            !$0.isDeleted && $0.name == modelName }).first?.downloadable?.localDestination.path {
                return FileManager.default.fileExists(atPath: path)
            }
        return false
    }
    
    public enum CodingKeys: String, CodingKey {
        case id
        case name
        case organization
        case displayName
        case markdownDescription
        case providedByExtension
        case usedByPersona
        case modelDownloadURL
        case defaultPriority
        case apiURL
        case memoryRequirement
        case createdAt
        case modifiedAt
        case isDeleted
        case stopWords
        case modelInference
        case context
        case nBatch
        case topK
        case systemFormat
        case systemPromptTemplate
        case promptFormat
        case temperature
        case topP
        case repeatLastN
        case repeatPenalty
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(organization, forKey: .organization)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(markdownDescription, forKey: .markdownDescription)
        try container.encodeIfPresent(providedByExtension?.id, forKey: .providedByExtension)
        try container.encodeIfPresent(usedByPersona?.id, forKey: .usedByPersona)
        try container.encode(modelDownloadURL, forKey: .modelDownloadURL)
        try container.encode(apiURL, forKey: .apiURL)
        try container.encode(stopWords, forKey: .stopWords)
        try container.encode(memoryRequirement, forKey: .memoryRequirement)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(isDeleted, forKey: .isDeleted)
        try container.encode(defaultPriority, forKey: .defaultPriority)
        try container.encode(modelInference, forKey: .modelInference)
        try container.encode(context, forKey: .context)
        try container.encode(nBatch, forKey: .nBatch)
        try container.encode(topK, forKey: .topK)
        try container.encode(systemPromptTemplate, forKey: .systemPromptTemplate)
        try container.encode(systemFormat, forKey: .systemFormat)
        try container.encode(promptFormat, forKey: .promptFormat)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(topP, forKey: .topP)
        try container.encode(repeatLastN, forKey: .repeatLastN)
        try container.encode(repeatPenalty, forKey: .repeatPenalty)
    }
}
