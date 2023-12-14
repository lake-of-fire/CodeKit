import SwiftUI
import RealmSwift
import RealmSwiftGaps
import DebouncedOnChange
import CodeCore
import Metal
import Combine
@_spi(Advanced) import SwiftUIIntrospect

struct ModelSwitcher: View {
    @ObservedObject var personaViewModel: PersonaViewModel
    
    var body: some View {
        Group {
            if personaViewModel.persona.modelOptions.count > 4 || personaViewModel.persona.modelOptions.isEmpty {
                ModelPickerView(personaViewModel: personaViewModel)
                    .pickerStyle(.menu)
#if os(macOS)
                    .introspect(.picker(style: .menu), on: .macOS(.v12...)) { picker in
                        picker.isBordered = false
                    }
#endif
                    .fixedSize()
            } else {
                ModelPickerView(personaViewModel: personaViewModel)
                    .pickerStyle(.segmented)
                    .labelsHidden()
            }
        }
    }
}

public struct ModelPickerView: View {
    @ObservedObject var personaViewModel: PersonaViewModel
    @EnvironmentObject private var viewModel: ModelsControlsViewModel
    
    @State private var personaLastModifiedAt: Date?
    
    public init(personaViewModel: PersonaViewModel) {
        self.personaViewModel = personaViewModel
    }
    
    var persona: Persona {
        return personaViewModel.persona
    }
    
    public var body: some View {
        Group {
            if let modelID = viewModel.selectedModel, viewModel.modelItems.contains(where: { $0.0 == modelID }) {
                Picker("Model", selection: $viewModel.selectedModel) {
                    ForEach(viewModel.selectedModel == nil ? [] : viewModel.modelItems, id: \.0) { modelItem in
                        let (id, modelDisplayName) = modelItem
                        Text(modelDisplayName)
                            .bold()
                            .tag(id as UUID?)
                    }
                }
            }
        }
        .onChange(of: persona.modifiedAt) { _ in
            if personaLastModifiedAt != persona.modifiedAt {
                Task { @MainActor in
                    viewModel.persona = persona
                    do {
                        try await viewModel.refreshModelItems(modelOptions: Array(persona.modelOptions))
                    } catch {
                        print("ERROR \(error)")
                    }
                    personaLastModifiedAt = persona.modifiedAt
                }
            }
        }
        .task {
            Task { @MainActor in
                viewModel.persona = persona
                do {
                    try await viewModel.refreshModelItems()
                } catch {
                    print("ERROR \(error)")
                }
                personaLastModifiedAt = persona.modifiedAt
            }
        }
    }
}
