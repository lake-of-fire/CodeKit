import SwiftUI
import Combine
import RealmSwift
import CodeCore
import CodeAI
import BigSyncKit

class CodeLibraryNavigationModel: ObservableObject, Codable {
    @Published var columnVisibility: NavigationSplitViewVisibility
    @Published var selectedPackage: CodePackage?
    @Published var selectedPersona: Persona?
    @Published var navigationPath = [RealmSwift.Object]()
    
    private lazy var decoder = JSONDecoder()
    private lazy var encoder = JSONEncoder()
    
    private var cancellables = Set<AnyCancellable>()
    
    enum CodingKeys: String, CodingKey {
        case columnVisibility
        case selectedPackage
        case selectedPersona
    }
 
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(columnVisibility, forKey: .columnVisibility)
        try container.encodeIfPresent(selectedPackage?.id, forKey: .selectedPackage)
        try container.encodeIfPresent(selectedPersona?.id, forKey: .selectedPersona)
    }
    
    init(columnVisibility: NavigationSplitViewVisibility = .automatic,
         selectedPackage: CodePackage? = nil,
         selectedPersona: Persona? = nil
    ) {
        self.columnVisibility = columnVisibility
        self.selectedPackage = selectedPackage
        self.selectedPersona = selectedPersona
        
        objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self = self else { return }
            navigationPath = [selectedPersona?.providedByExtension?.package ?? selectedPackage, selectedPersona].compactMap { $0 }
        }.store(in: &cancellables)
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
 
        self.columnVisibility = try container.decode(
            NavigationSplitViewVisibility.self, forKey: .columnVisibility)
        
        let realm = try! Realm()
        
        let selectedPackageID = try container.decodeIfPresent(String.self, forKey: .selectedPackage)
        if let selectedPackageID = selectedPackageID, let selectedPackageUUID = UUID(uuidString: selectedPackageID) {
            self.selectedPackage = realm.object(ofType: CodePackage.self, forPrimaryKey: selectedPackageUUID)
        }
        
        let selectedPersonaID = try container.decodeIfPresent(String.self, forKey: .selectedPersona)
        if let selectedPersonaID = selectedPersonaID, let selectedPersonaUUID = UUID(uuidString: selectedPersonaID) {
            self.selectedPersona = realm.object(ofType: Persona.self, forPrimaryKey: selectedPersonaUUID)
        }
    }
    
    // helper to serialize the model to/from JSON Data
    var jsonData: Data? {
        get { try? encoder.encode(self) }
        set {
            guard let data = newValue,
                  let model = try? decoder.decode(Self.self, from: data)
            else { return }
            columnVisibility = model.columnVisibility
            selectedPackage = model.selectedPackage
            selectedPersona = model.selectedPersona
        }
    }
    
    // async sequence of updates (from the sample code project)
    var objectWillChangeSequence: AsyncPublisher<Publishers.Buffer<ObservableObjectPublisher>> {
        objectWillChange
            .buffer(size: 1, prefetch: .byRequest, whenFull: .dropOldest)
            .values
    }
}
