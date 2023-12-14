import SwiftUI
import RealmSwift
import RealmSwiftGaps
import DebouncedOnChange
import CodeCore

public struct PersonaDetailsView: View {
    @ObservedObject public var personaViewModel: PersonaViewModel

    @State private var name: String = ""
    @State private var modelTemperature = 0.5
    @State private var customInstructionForContext = ""
    @State private var customInstructionForResponses = ""
    @State private var rooms: [Room] = []
    
    @StateObject private var modelsControlsViewModel = ModelsControlsViewModel()
    
    var persona: Persona {
        return personaViewModel.persona
    }
    
    public var body: some View {
        Form {
            TextField("Name", text: $name)
                .task { Task { @MainActor in
                    name = persona.name
                }}
                .onChange(of: name, debounceTime: .seconds(0.2)) { name in
                    Task { @MainActor in
                        guard name != persona.name else { return }
                        try await Realm.asyncWrite(ThreadSafeReference(to: persona)) { _, persona in
                            persona.name = name
                            persona.modifiedAt = Date()
                        }
                    }
                }

            if let codeExtension = persona.providedByExtension {
                LabeledContent("Extension", value: codeExtension.nameWithOwner)
            }

            Section("Configuration") {
                ModelPickerView(personaViewModel: personaViewModel)
                    .environmentObject(modelsControlsViewModel)
                LabeledContent {
                    Slider(value: $modelTemperature, in: 0.0...2.0)  {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("0")
                    } maximumValueLabel: {
                        Text("2")
                    }
                } label: {
                    Text("Temperature / Creativity")
                }
                .task {
                    Task { @MainActor in
                    }
                }
                .onChange(of: modelTemperature, debounceTime: .seconds((0.2))) { modelTemperature in
                    Task { @MainActor in
                        guard modelTemperature != persona.modelTemperature else { return }
                        try await Realm.asyncWrite(ThreadSafeReference(to: persona)) { _, persona in
                            persona.modelTemperature = modelTemperature
                            persona.modifiedAt = Date()
                        }
                        let personaID = persona.id
                        
                        try await Task.detached { @RealmBackgroundActor in
                            let realm = try await Realm(configuration: .defaultConfiguration, actor: RealmBackgroundActor.shared)
                            for llm in realm.objects(LLMConfiguration.self).where({ !$0.isDeleted && $0.usedByPersona.id == personaID }) {
                                try await realm.asyncWrite {
                                    llm.temperature = Float(modelTemperature)
                                    llm.modifiedAt = Date()
                                }
                            }
                        }.value
//                            if let llm = realm.objects(LLMConfiguration.self) {
//                                safeWrite(ext) { _, ext in ext.modelTemperature = modelTemperature }
//                            }
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
                            try await Realm.asyncWrite(ThreadSafeReference(to: persona)) { _, persona in
                                persona.customInstructionForContext = customInstructionForContext
                                persona.modifiedAt = Date()
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
                            try await Realm.asyncWrite(ThreadSafeReference(to: persona)) { _, persona in
                                persona.customInstructionForResponses = customInstructionForResponses
                                persona.modifiedAt = Date()
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

    public init(personaViewModel: PersonaViewModel) {
        self.personaViewModel = personaViewModel
    }
}
