import SwiftUI
import RealmSwift
import BigSyncKit
import SwiftUtilities
import RealmSwiftGaps
import SwiftUIDownloads
import CodeCore
import CodeRunner

public class LLMConfiguration: Object, UnownedSyncableObject, DBSyncableObject {
    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var name = ""
    @Persisted public var organization = ""
    @Persisted public var displayName = ""
    @Persisted public var markdownDescription = ""
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    
    @Persisted public var providedByExtension: CodeExtension?
    @Persisted public var apiURL = ""
    
    // Local LLM
    @Persisted public var modelDownloadURL = ""
    @Persisted public var memoryRequirement: Int?
    @Persisted public var modelInference = ""
    @Persisted public var context: Int?
    @Persisted public var nBatch: Int?
    @Persisted public var topK: Int?
    @Persisted public var reversePrompt = ""
    @Persisted public var systemFormat = ""
    @Persisted public var systemPromptTemplate = ""
    @Persisted public var promptFormat = ""
    @Persisted public var temperature: Float = 0.89999997615814209
    @Persisted public var topP: Float?
    @Persisted public var repeatLastN: Int?
    @Persisted public var repeatPenalty: Float?
    
    public var needsSyncToServer: Bool { false }
    
    public var downloadable: Downloadable? {
        guard let url = URL(string: modelDownloadURL) else { return nil }
        return Downloadable(
            name: name,
            parentDirectoryName: "Downloads/llm-models",
            filename: url.lastPathComponent,
            downloadMirrors: [url])
    }
    
    public var canUseMetal: Bool {
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
    }
    
        
    public enum CodingKeys: String, CodingKey {
        case id
        case name
        case organization
        case displayName
        case markdownDescription
        case providedByExtension
        case modelDownloadURL
        case apiURL
        case memoryRequirement
        case createdAt
        case modifiedAt
        case isDeleted
        case modelInference
        case context
        case nBatch
        case topK
        case reversePrompt
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
        try container.encode(modelDownloadURL, forKey: .modelDownloadURL)
        try container.encode(apiURL, forKey: .apiURL)
        try container.encode(memoryRequirement, forKey: .memoryRequirement)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(isDeleted, forKey: .isDeleted)
        try container.encode(modelInference, forKey: .modelInference)
        try container.encode(context, forKey: .context)
        try container.encode(nBatch, forKey: .nBatch)
        try container.encode(topK, forKey: .topK)
        try container.encode(reversePrompt, forKey: .reversePrompt)
        try container.encode(systemPromptTemplate, forKey: .systemPromptTemplate)
        try container.encode(systemFormat, forKey: .systemFormat)
        try container.encode(promptFormat, forKey: .promptFormat)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(topP, forKey: .topP)
        try container.encode(repeatLastN, forKey: .repeatLastN)
        try container.encode(repeatPenalty, forKey: .repeatPenalty)
    }
}
