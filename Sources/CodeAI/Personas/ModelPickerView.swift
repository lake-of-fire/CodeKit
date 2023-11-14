import SwiftUI
import RealmSwift
import RealmSwiftGaps
import DebouncedOnChange
import CodeCore
import Metal
import Combine

public struct ModelPickerView: View {
    @ObservedRealmObject var persona: Persona
    @EnvironmentObject private var viewModel: ModelsControlsViewModel
    
    @State private var personaLastModifiedAt: Date?
    
    public init(persona: Persona) {
        self._persona = ObservedRealmObject(wrappedValue: persona)
    }
    
    public var body: some View {
        Group {
            if viewModel.selectedModel != nil {
                Picker("Model", selection: $viewModel.selectedModel) {
                    ForEach(viewModel.modelItems, id: \.0) { modelItem in
                        let (id, modelDisplayName) = modelItem
                        Text(modelDisplayName).tag(id as UUID?)
                    }
                }
            }
        }
        .onChange(of: persona.modifiedAt) { _ in
            if personaLastModifiedAt != persona.modifiedAt {
                Task { @MainActor in
                    viewModel.persona = persona
                    viewModel.refreshModelItems(modelOptions: Array(persona.modelOptions))
                    personaLastModifiedAt = persona.modifiedAt
                }
            }
        }
        .task {
            Task { @MainActor in
                viewModel.persona = persona
                viewModel.refreshModelItems()
                personaLastModifiedAt = persona.modifiedAt
            }
        }
            
    }
   
}
