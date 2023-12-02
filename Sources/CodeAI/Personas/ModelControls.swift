import SwiftUI
import RealmSwift
import RealmSwiftGaps
import CodeCore
import SwiftUIDownloads
@_spi(Advanced) import SwiftUIIntrospect
import LakeKit
import Metal
import Combine

//public struct ModelPickerView: View {
//    @ObservedRealmObject var persona: Persona
//    @State private var selectedModel: String
//
//    @State private var modelItems: [(String, String)] = []
//
//    public init(persona: Persona) {
//        self._persona = ObservedRealmObject(wrappedValue: persona)
//        self._selectedModel = State(initialValue: persona.selectedModel)
//    }
//
//    var modelOptions: [String] {
//        persona.modelOptions.filter { !$0.isEmpty }
//    }
//
//    public var body: some View {
//        Text(persona.selectedModel)
//        Text(selectedModel)
//        Picker("Model", selection: $selectedModel) {
//            Text("").tag("")
//            ForEach(modelItems, id: \.0) { modelItem in
//                let (modelName, modelDisplayName) = modelItem
//                Text(modelDisplayName).tag(modelName)
//            }
//        }
//        .onChange(of: selectedModel) { selectedModel in
//            Task {
//                guard selectedModel != persona.selectedModel else { return }
//                safeWrite(persona) { _, persona in persona.selectedModel = selectedModel }
//            }
//        }
//        .onChange(of: persona.modelOptions) { modelOptions in
//            Task { @MainActor in refreshModel(modelOptions: Array(modelOptions)) }
//        }
//        .task {
//            Task { @MainActor in
//                refreshModel()
//                selectedModel = persona.selectedModel
//            }
//        }
//    }
//
//    private func refreshModel(modelOptions: [String]? = nil) {
//        let modelOptions = modelOptions ?? self.modelOptions
//        let realm = try! Realm()
//        let modelDisplayNames = Array(realm.objects(LLMConfiguration.self).where { $0.name.in(modelOptions) && !$0.isDeleted }.map { $0.displayName })
//        let modelDisplayNames2 = Array(realm.objects(LLMConfiguration.self).where { !$0.isDeleted }.map { $0.displayName })
//        modelItems = Array(zip(modelOptions, modelDisplayNames))
//    }
//}

struct ModelSwitcher: View {
    @ObservedRealmObject var persona: Persona
    
    var body: some View {
        Group {
            if persona.modelOptions.count > 4 {
                ModelPickerView(persona: persona)
                    .pickerStyle(.menu)
#if os(macOS)
                    .introspect(.picker(style: .menu), on: .macOS(.v12...)) { picker in
                        picker.isBordered = false
                    }
#endif
                    .fixedSize()
            } else {
                ModelPickerView(persona: persona)
                    .pickerStyle(.segmented)
                    .labelsHidden()
            }
        }
    }
}

open class BlockableMessagingViewModel: ObservableObject {
    @Published public var messageSubmissionBlockMessage: String?
    @Published public var messageSubmissionBlockedAction: (() -> Void)?
    
    public init() { }
}

struct ModelControls: View {
    @ObservedObject var viewModel: ModelsControlsViewModel
    @ObservedRealmObject var persona: Persona
    @ObservedObject var downloadable: Downloadable
    
    @ObservedObject private var downloadController = DownloadController.shared
    @ScaledMetric(relativeTo: .callout) private var downloadProgressSize: CGFloat = 18
    
    @EnvironmentObject private var blockableMessagingViewModel: BlockableMessagingViewModel
    
    var body: some View {
        DownloadControls(downloadable: downloadable, downloadURLs: $viewModel.downloadModels)
            .task {
                Task { @MainActor in
                    viewModel.blockableMessagingViewModel = blockableMessagingViewModel
                }
            }
    }
}

class ModelsControlsViewModel: ObservableObject {
    @Published var selectedDownloadable: Downloadable?
    @PublishingAppStorage("downloadLLMModels") var downloadModels: [String] = []
//    @Published var downloadModels: [String] = []
    @Published var persona: Persona? = nil
    @Published var modelItems: [(UUID, String)] = []
    @Published var selectedModel: LLMConfiguration.ID?
    
    @Published var blockableMessagingViewModel: BlockableMessagingViewModel? = nil
    
    private var cancellables = Set<AnyCancellable>()
    
    private var modelOptions: [String] {
        persona?.modelOptions.filter { !$0.isEmpty } ?? []
    }

    init() {
        let realm = try! Realm()
        realm.objects(LLMConfiguration.self)
            .where { !$0.isDeleted }
            .collectionPublisher
            .freeze()
            .removeDuplicates()
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] results in
                Task { @MainActor [weak self] in
                    self?.refreshModelItems()
                    await self?.refreshDownloads()
                }
            })
            .store(in: &cancellables)
        
        $blockableMessagingViewModel
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshDownloadMessage()
                }
            }
            .store(in: &cancellables)
        
        $downloadModels.publisher
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] downloadModels in
                Task { @MainActor [weak self] in
                    await self?.refreshDownloads(downloadModels: downloadModels)
                }
            }
            .store(in: &cancellables)
        
        $selectedModel
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] selectedModel in
                Task { @MainActor [weak self] in
                    guard let self = self, let selectedModel = selectedModel, let persona = persona else { return }
                    let realm = try! Realm()
                    let toRemove = realm.objects(LLMConfiguration.self).where { !$0.isDeleted && $0.usedByPersona.id == persona.id }.filter { $0.id != selectedModel }
                    for llm in toRemove {
                        safeWrite(llm) { _, llm in llm.usedByPersona = nil }
                    }
                    if let llm = realm.object(ofType: LLMConfiguration.self, forPrimaryKey: selectedModel) {
                        safeWrite(llm) { _, llm in llm.usedByPersona = (persona.isFrozen ? persona.thaw() : persona) }
                    }
                }
            }
            .store(in: &cancellables)
        
        $persona
            .receive(on: DispatchQueue.main)
            .removeDuplicates(by: {
                return $0?.id == $1?.id
            })
            .sink { [weak self] persona in
                guard let personaID = persona?.id else {
                    self?.selectedModel = nil
                    self?.modelItems = []
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let realm = try! await Realm()
                    refreshModelItems()
                    selectedModel = realm.objects(LLMConfiguration.self)
                        .where { !$0.isDeleted && $0.usedByPersona.id == personaID }
                        .first?.id
                }
            }
            .store(in: &cancellables)
    }
    
    @MainActor
    func refreshModelItems(modelOptions: [String]? = nil) {
        guard let persona = (persona?.isFrozen ?? false ? persona?.thaw() : persona) else {
            modelItems = []
            selectedModel = nil
            return
        }
        
        let modelOptions = modelOptions ?? self.modelOptions
        let realm = try! Realm()
        
#if os(macOS)
        var safelyAvailableMemory = UInt64(1 * Double(MTLCopyAllDevices().sorted {
            $0.recommendedMaxWorkingSetSize > $1.recommendedMaxWorkingSetSize
        } .first?.recommendedMaxWorkingSetSize ?? 0))
#else
        let metalDevice = MTLCreateSystemDefaultDevice()
        var safelyAvailableMemory = UInt64(1 * Double(metalDevice?.recommendedMaxWorkingSetSize ?? 0))
#endif
        
        if LLMModel.shared.state != .none {
            let active = realm.objects(LLMConfiguration.self).where({
                !$0.isDeleted && $0.usedByPersona != nil
            }).filter({ $0.downloadable?.localDestination.path == LLMModel.shared.modelURL })
            let activeMemory = UInt64(active.compactMap { $0.memoryRequirement }.reduce(0, +))
            safelyAvailableMemory += activeMemory
        }
        
        // Default model
        if let llm = realm.objects(LLMConfiguration.self).where({ !$0.isDeleted && $0.usedByPersona.id == persona.id }).first {
            selectedModel = llm.id
        } else {
            if let llm = realm.objects(LLMConfiguration.self).where({
                !$0.isDeleted && $0.usedByPersona == nil && ($0.memoryRequirement == nil || $0.memoryRequirement <= Int(safelyAvailableMemory))
            }).sorted(by: \.defaultPriority, ascending: false).first {
                safeWrite(llm) { _, llm in
                    llm.usedByPersona = persona
                }
                selectedModel = llm.id
            }
        }
        
        let modelItems: [(UUID, String)] = realm.objects(LLMConfiguration.self)
            .where {
                $0.name.in(modelOptions) && !$0.isDeleted && ($0.usedByPersona.id == persona.id || $0.usedByPersona == nil)
            }
            .sorted {
                if $0.name == $1.name {
                    if $0.usedByPersona?.id == persona.id {
                        return $1.usedByPersona?.id == persona.id ? $0.id.uuidString < $1.id.uuidString : true
                    } else if $1.usedByPersona?.id == persona.id {
                        return false
                    } else if $0.usedByPersona != nil, $1.usedByPersona == nil {
                        return false
                    } else if $0.usedByPersona == nil, $1.usedByPersona != nil {
                        return true
                    } else if $0.usedByPersona == nil, $1.usedByPersona == nil {
                        return $0.createdAt < $1.createdAt
                    }
                }
                return $0.name < $1.name
            }
            .reduce(into: [String: LLMConfiguration]()) { result, llmConfig in
                // Keep the first occurrence of each name
                result[llmConfig.name] = result[llmConfig.name] ?? llmConfig
            }
            .values
            .filter { (llm: LLMConfiguration) -> Bool in
                if llm.usedByPersona?.id == persona.id {
                    return true
                }
                if LLMModel.shared.state == .none || LLMModel.shared.modelURL == llm.downloadable?.localDestination.path,
                   let memoryRequirement = llm.memoryRequirement {
                    return safelyAvailableMemory >= memoryRequirement
                } else if LLMModel.shared.state != .none, (llm.memoryRequirement ?? 0) > 0 {
                    return safelyAvailableMemory >= llm.memoryRequirement ?? 0
                }
                return true
            }
            .sorted { $0.displayName < $1.displayName }
            .map { (llm: LLMConfiguration) -> (UUID, String) in (llm.id, llm.displayName) }
        self.modelItems = Array(modelItems)
    }
    
    @MainActor
    private func refreshDownloads(downloadModels: [String]? = nil) async {
        var downloadModels = downloadModels ?? Array(self.downloadModels)
        let realm = try! await Realm()
        
        let selectedLLM = realm.objects(LLMConfiguration.self).where {
            !$0.isDeleted && $0.usedByPersona.id == (persona?.id ?? UUID())
        }.first
        
        // Queue downloads
        var downloads = [Downloadable]()
        self.downloadModels = downloadModels
        var toRemove = [String]()
        for modelURL in downloadModels {
            var download = realm.objects(LLMConfiguration.self).where {
                !$0.isDeleted && !$0.providedByExtension.isDeleted
                && $0.providedByExtension.package.isEnabled }
                .filter { $0.downloadable?.url.absoluteString == modelURL }
                .first?.downloadable
            if let existingSelectedDL = selectedDownloadable, existingSelectedDL.url == download?.url {
                download = existingSelectedDL
            }
            if let existingDL = DownloadController.shared.assuredDownloads.first(where: { $0.url == download?.url }) {
                download = existingDL
            }
            if let download = download, selectedDownloadable == nil || selectedDownloadable?.url != download.url, selectedLLM == nil || download.url == selectedLLM?.downloadable?.url {
                selectedDownloadable = download
            }
            if let download = download, !downloads.contains(where: { $0.url.absoluteString == modelURL }) {
                downloads.append(download)
            } else {
                toRemove.append(modelURL)
            }
        }
        for modelURL in toRemove {
            downloadModels.removeAll(where: { $0 == modelURL })
        }
        await DownloadController.shared.ensureDownloaded(Set(downloads))
        
        if let selectedDownload = DownloadController.shared.assuredDownloads.first(where: { $0.url == selectedLLM?.downloadable?.url }) {
            if selectedDownloadable?.id != selectedDownload.id {
                selectedDownloadable = selectedDownload
                if selectedDownload.fileSize == nil {
                    await selectedDownload.fetchRemoteFileSize()
                }
            }
        } else if let download = selectedLLM?.downloadable, selectedDownloadable?.url != download.url {
            selectedDownloadable = download
        }
        
        refreshDownloadMessage()
    }
    
    private func refreshDownloadMessage() {
        let realm = try! Realm()
        if let persona = persona, let llm = realm.objects(LLMConfiguration.self).where({ !$0.isDeleted && $0.usedByPersona.id == persona.id }).first {
            if llm.isModelInstalled {
                blockableMessagingViewModel?.messageSubmissionBlockMessage = nil
                blockableMessagingViewModel?.messageSubmissionBlockedAction = nil
            } else if let downloadable = llm.downloadable {
                if !downloadModels.contains(downloadable.url.absoluteString) {
                    blockableMessagingViewModel?.messageSubmissionBlockMessage = "Download"
                    blockableMessagingViewModel?.messageSubmissionBlockedAction = {
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            downloadModels = Array(Set(downloadModels).union(Set([downloadable.url.absoluteString])))
                        }
                    }
                } else {
                    blockableMessagingViewModel?.messageSubmissionBlockMessage = "Download"
                    blockableMessagingViewModel?.messageSubmissionBlockedAction = nil
                }
            }
        }
    }
}

public struct ModelsControlsContainer: View {
    @ObservedRealmObject var persona: Persona
   
    @ObservedObject private var downloadController = DownloadController.shared
    @StateObject private var viewModel = ModelsControlsViewModel()
    
//    @ObservedResults(LLMConfiguration.self, where: {
//        !$0.isDeleted }, keyPaths: ["id", "usedByPersona"]) private var llmConfigurations
    
    public init(persona: Persona) {
        self.persona = persona
    }
    
    public var body: some View {
        VStack(alignment: .center, spacing: 0) {
            ModelSwitcher(persona: persona)
                .task {
                    Task { @MainActor in
                        viewModel.persona = persona.freeze()
                    }
                }
                .onChange(of: persona) { persona in
                    Task { @MainActor in
                        if viewModel.persona?.id != persona.id {
                            viewModel.persona = persona.freeze()
                        }
//                        viewModel.refreshModelItems()
                    }
                }
            if let downloadable = viewModel.selectedDownloadable {
                HStack(alignment: .center) {
                    Text("AI Model")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ModelControls(viewModel: viewModel, persona: persona, downloadable: downloadable)
                }
//                Text(downloadable.debugUUID.uuidString.prefix(3))
//                Text(downloadable.isActive.description)
            }
        }
        .environmentObject(viewModel)
    }
}
