import SwiftUI
import RealmSwift
import RealmSwiftGaps
import DebouncedOnChange
import CodeCore
import Metal

public struct ModelPickerView: View {
    @ObservedRealmObject var persona: Persona
    @State private var selectedModel: String
    
    @State private var modelItems: [(String, String)] = []

    public init(persona: Persona) {
        self._persona = ObservedRealmObject(wrappedValue: persona)
        self._selectedModel = State(initialValue: persona.selectedModel)
    }

    var modelOptions: [String] {
        persona.modelOptions.filter { !$0.isEmpty }
    }
    
    public var body: some View {
        Picker("Model", selection: $selectedModel) {
            Text("").tag("")
            ForEach(modelItems, id: \.0) { modelItem in
                let (modelName, modelDisplayName) = modelItem
                Text(modelDisplayName).tag(modelName)
            }
        }
        .onChange(of: selectedModel) { selectedModel in
            Task {
                guard selectedModel != persona.selectedModel else { return }
                safeWrite(persona) { _, persona in persona.selectedModel = selectedModel }
            }
        }
        .onChange(of: persona.modelOptions) { modelOptions in
            Task { @MainActor in refreshModel(modelOptions: Array(modelOptions)) }
        }
        .task {
            Task { @MainActor in
                refreshModel()
                selectedModel = persona.selectedModel
            }
        }
    }
    
    private func refreshModel(modelOptions: [String]? = nil) {
        let modelOptions = modelOptions ?? self.modelOptions
        let realm = try! Realm()
        let memory = MTLCopyAllDevices().sorted {
            $0.recommendedMaxWorkingSetSize > $1.recommendedMaxWorkingSetSize
        } .first?.recommendedMaxWorkingSetSize
        modelItems = realm.objects(LLMConfiguration.self)
            .where { $0.name.in(modelOptions) && !$0.isDeleted }
            .filter {
                if LLMModel.shared.state == .none || LLMModel.shared.modelURL == $0.downloadable?.localDestination.path, let memoryRequirement = $0.memoryRequirement {
                    return (memory ?? 0) >= memoryRequirement
                }
                return true
            }
            .sorted { $0.name < $1.name }
            .map { ($0.name, $0.displayName) }
    }
}

public struct PersonaDetailsView: View {
    @ObservedRealmObject public var persona: Persona

    @State private var name: String = ""
    @State private var modelTemperature = 0.5
    @State private var customInstructionForContext = ""
    @State private var customInstructionForResponses = ""
    @State private var rooms: [Room] = []

    public var body: some View {
        Form {
            TextField("Name", text: $name)
                .task { Task { @MainActor in
                    name = persona.name
                }}
                .onChange(of: name, debounceTime: .seconds(0.2)) { name in
                    Task { @MainActor in
                        guard name != persona.name else { return }
                        safeWrite(persona) { _, persona in
                            persona.name = name
                        }
                    }
                }

            if let codeExtension = persona.providedByExtension {
                LabeledContent("Extension", value: codeExtension.nameWithOwner)
            }

            Section("Configuration") {
                ModelPickerView(persona: persona)

                LabeledContent {
                    Slider(value: $modelTemperature, in: 0.0...2.0)
                } label: {
                    Text("Temperature")
                }
                .onChange(of: modelTemperature, debounceTime: .seconds((0.2))) { modelTemperature in
                    Task { @MainActor in
                        guard modelTemperature != persona.modelTemperature else { return }
                        safeWrite(persona) { _, persona in persona.modelTemperature = modelTemperature }
                    }
                }

                TextField("What should the bot know about you?", text: $customInstructionForContext, axis: .vertical)
                    .lineLimit(25)
                    .task { Task { @MainActor in
                        customInstructionForContext = persona.customInstructionForContext
                    }}
                    .onChange(of: customInstructionForContext, debounceTime: .seconds(0.2)) { customInstructionForContext in
                        Task { @MainActor in
                            guard name != persona.customInstructionForContext else { return }
                            safeWrite(persona) { _, persona in
                                persona.customInstructionForContext = customInstructionForContext
                            }
                        }
                    }

                TextField("How should the bot respond?", text: $customInstructionForResponses, axis: .vertical)
                    .lineLimit(25)
                    .task { Task { @MainActor in
                        customInstructionForResponses = persona.customInstructionForResponses
                    }}
                    .onChange(of: customInstructionForResponses, debounceTime: .seconds(0.2)) { customInstructionForResponses in
                        Task { @MainActor in
                            guard name != persona.customInstructionForResponses else { return }
                            safeWrite(persona) { _, persona in
                                persona.customInstructionForResponses = customInstructionForResponses
                            }
                        }
                    }
            }

            Section("Rooms") {
                if rooms.isEmpty {
                    Text("Not in any rooms.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(rooms) { room in
                        Text(room.displayName)
                    }
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .formStyle(.grouped)
        .task {
            Task { @MainActor in
                let realm = try! Realm()
                guard let matchPersona = realm.object(ofType: Persona.self, forPrimaryKey: persona.id) else { return }
                rooms = Array(realm.objects(Room.self).where { $0.participants.contains(matchPersona) })
                modelTemperature = persona.modelTemperature
            }
        }
    }

    public init(persona: Persona) {
        self.persona = persona
    }
}
