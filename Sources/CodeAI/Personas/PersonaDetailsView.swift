import SwiftUI
import RealmSwift
import RealmSwiftGaps
import DebouncedOnChange
import CodeCore

public struct PersonaDetailsView: View {
    @ObservedRealmObject public var persona: Persona

    @State private var name: String = ""
    @State private var modelTemperature = 0.5
    @State private var customInstructionForContext = ""
    @State private var customInstructionForResponses = ""
    @State private var rooms: [Room] = []
    
    @StateObject private var modelsControlsViewModel = ModelsControlsViewModel()
    
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
                        safeWrite(persona) { _, persona in persona.modelTemperature = modelTemperature }
                        safeWrite { realm in
                            for llm in realm.objects(LLMConfiguration.self).where({ !$0.isDeleted && $0.usedByPersona.id == persona.id }) {
                                llm.temperature = Float(modelTemperature)
                            }
//                            if let llm = realm.objects(LLMConfiguration.self) {
//                                safeWrite(ext) { _, ext in ext.modelTemperature = modelTemperature }
//                            }
                        }
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
