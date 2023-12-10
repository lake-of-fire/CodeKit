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
