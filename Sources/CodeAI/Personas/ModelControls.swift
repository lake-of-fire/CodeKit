import SwiftUI
import RealmSwift
import RealmSwiftGaps
import BigSyncKit
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
    @PublishedAppStorage("downloadLLMModels") var downloadModels: [String] = []
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
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
//            .print("##")
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] results in
                Task { @MainActor [weak self] in
                    self?.refreshModelItems()
                    await self?.refreshDownloads()
//                    self?.refreshDownloadMessage()
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
        
        $downloadModels
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] downloadModels in
                Task { @MainActor [weak self] in
                    await self?.refreshDownloads(downloadModels: downloadModels)
//                    self?.refreshDownloadMessage()
                }
            }
            .store(in: &cancellables)
        
        $selectedDownloadable
            .compactMap { $0 }
            .removeDuplicates()
            .flatMap { $0.$isFinishedDownloading }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isFinishedDownloading in
                self?.refreshDownloadMessage()
            }
            .store(in: &cancellables)
        
        $selectedModel
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] selectedModel in
                guard let persona = self?.persona else { return }
                
                Task { @MainActor [weak self] in
                    // Reset until it's loaded back in.
                    self?.selectedDownloadable = nil
                }
                
                let personaRef = ThreadSafeReference(to: persona)
                Task { @RealmBackgroundActor [weak self] in
                    guard let selectedModel = selectedModel else { return }
                    let realm = try! await Realm(actor: RealmBackgroundActor.shared)
                    guard let persona = realm.resolve(personaRef) else { return }
                    let toRemove = Array(realm.objects(LLMConfiguration.self).where { !$0.isDeleted && $0.usedByPersona.id == persona.id }.filter { $0.id != selectedModel })
                    for llm in toRemove {
                        try? await realm.asyncWrite {
                            //                        safeWrite(llm) { _, llm in
                            llm.usedByPersona = nil
                        }
                    }
                    if let llm = realm.object(ofType: LLMConfiguration.self, forPrimaryKey: selectedModel) {
                        let modelDownloadURL = llm.modelDownloadURL
                        Task { @MainActor [weak self] in
                            if self?.selectedDownloadable?.url.absoluteString != modelDownloadURL {
                                self?.selectedDownloadable = nil
                            }
                        }
                        try? await realm.asyncWrite {
//                        safeWrite(llm) { _, llm in
                            llm.usedByPersona = (persona.isFrozen ? persona.thaw() : persona)
                        }
                    }
                }
            }
            .store(in: &cancellables)
        
        $persona
            .removeDuplicates(by: {
                return $0?.id == $1?.id
            })
            .receive(on: DispatchQueue.main)
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
                    await refreshDownloads(persona: persona)
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
        var safelyAvailableMemory = UInt64(0.95 * Double(MTLCopyAllDevices().sorted {
            $0.recommendedMaxWorkingSetSize > $1.recommendedMaxWorkingSetSize
        } .first?.recommendedMaxWorkingSetSize ?? 0))
#elseif DEBUG
        var safelyAvailableMemory: UInt64 = 8_000_000_000
#else
        let metalDevice = MTLCreateSystemDefaultDevice()
        var safelyAvailableMemory = UInt64(0.8 * Double(metalDevice?.recommendedMaxWorkingSetSize ?? 0))
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
            let llms = Array(realm.objects(LLMConfiguration.self)
                .where({ !$0.isDeleted && $0.usedByPersona == nil })
                .sorted(by: \.defaultPriority, ascending: false))
            if let llm = llms.filter({ $0.memoryRequirement == nil || (Int64($0.memoryRequirement ?? 0)) <= Int64(safelyAvailableMemory) }).first {
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
    private func updateDownloadsLastCheckedAt(persona: Persona) {
        if let codeExtension = persona.providedByExtension, persona.downloadsLastCheckedAt == nil || (codeExtension.lastRunStartedAt ?? .distantPast > persona.downloadsLastCheckedAt ?? .distantPast) {
            safeWrite(persona) { _, persona in
                persona.downloadsLastCheckedAt = Date()
            }
        }
    }
    
    @MainActor
    private func refreshDownloads(downloadModels: [String]? = nil, persona: Persona? = nil) async {
        let persona = persona ?? self.persona
        let inputDownloadModels = downloadModels
        var downloadModels = [String]()
        // To avoid parallel access to read/write PublishingAppStorage
        downloadModels.append(contentsOf: inputDownloadModels ?? self.downloadModels)
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
        
        let ensureTask = Task { @MainActor in
            await DownloadController.shared.ensureDownloaded(Set(downloads), deletingOrphansIn: [LLMConfiguration.downloadDirectory])
        }
        
        if let selectedDownload = DownloadController.shared.assuredDownloads.first(where: { $0.url == selectedLLM?.downloadable?.url }) {
            if selectedDownloadable?.id != selectedDownload.id {
                selectedDownloadable = selectedDownload
            }
        } else if let download = selectedLLM?.downloadable, selectedDownloadable?.url != download.url {
            selectedDownloadable = download
        }
        
        if let persona = persona ?? self.persona {
            if let selectedDownloadable = selectedDownloadable, selectedDownloadable.fileSize == nil {
                Task { @MainActor in
                    do {
                        try await selectedDownloadable.fetchRemoteFileSize()
                        updateDownloadsLastCheckedAt(persona: persona)
                    } catch {
                        updateDownloadsLastCheckedAt(persona: persona)
                    }
                }
            } else {
                updateDownloadsLastCheckedAt(persona: persona)
            }
        }
        
        refreshDownloadMessage()
        await ensureTask.value
        refreshDownloadMessage()
    }
    
    private func refreshDownloadMessage() {
        let realm = try! Realm()
        if let persona = persona, let llm = realm.objects(LLMConfiguration.self).where({ !$0.isDeleted && $0.usedByPersona.id == persona.id }).first {
            if llm.isModelInstalled && blockableMessagingViewModel?.messageSubmissionBlockMessage == "Download" {
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
        VStack(alignment: .leading, spacing: 0) {
            Text(viewModel.selectedDownloadable?.url.absoluteString ?? "_none_")
            ModelSwitcher(persona: persona)
                .task {
                    Task { @MainActor in
                        viewModel.persona = persona.freeze()
                    }
                }
                .onChange(of: persona) { persona in
                    Task { @MainActor in
                        if viewModel.persona != persona {
                            viewModel.persona = persona.freeze()
                        }
//                        viewModel.refreshModelItems()
                    }
                }
            
            if let downloadable = viewModel.selectedDownloadable {
                HStack(alignment: .center) {
                    Text("\(persona.name.truncate(20)) AI Model")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ModelControls(viewModel: viewModel, persona: persona, downloadable: downloadable)
                }
#if os(macOS)
                .padding(.leading, 3)
                .padding(.top, 2)
#else
                .padding(.leading, 12)
                .padding(.bottom, 2)
#endif
            }
        }
        .environmentObject(viewModel)
    }
}
