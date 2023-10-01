import SwiftUI
import Combine
import RealmSwift
import RealmSwiftGaps
import CodeCore

public class PersonaListViewModel: ObservableObject {
    var package: CodePackage? = nil
    
    @Published var personas: [Persona] = []
    
    private var cancellables = Set<AnyCancellable>()
        
    public init() {
        let realm = try! Realm()
        realm.objects(Persona.self)
            .where { !$0.isDeleted && $0.personaType != .user && $0.online }
            .changesetPublisher
            .receive(on: DispatchQueue.main)
            .sink { changeset in
                switch changeset {
                case .initial(let results):
                    Task { @MainActor [weak self] in
                        self?.personas = Array(results)
                    }
                case .update(let results, let deletions, let insertions, let modifications):
                    Task { @MainActor [weak self] in
                        self?.personas = Array(results)
                    }
                case .error(let error):
                    print("Error: \(error)")
                }
            }
            .store(in: &cancellables)
    }
}

public struct PersonaList: View {
    public var room: Room? = nil
    public var package: CodePackage? = nil
    public var onSelected: ((Persona?) -> Void)? = nil
    
    @StateObject private var viewModel = PersonaListViewModel()
    @State private var selection: Persona? = nil

    static func groupedURL(_ url: String?) -> String {
        guard let rawUrl = url, let url = URL(string: rawUrl) else { return "" }
        if url.host == "github.com", url.pathComponents.count >= 3 {
            let org = url.pathComponents[1]
            let repo = url.pathComponents[2]
            if repo.hasSuffix(".git"), org != repo {
                return org + "/" + repo.dropLast(".git".count)
            } else if org != repo {
                return org + "/" + repo
            }
        }
        var full = url.absoluteString
        if full.hasPrefix("https://") {
            full.removeFirst("https://".count)
        }
        return full
    }
    
    func groupBy(_ items: [Persona]) -> [(String, [Persona])] {
        let grouped = Dictionary(grouping: items, by: { Self.groupedURL($0.providedByExtension?.repositoryURL ?? "" ) })
        return grouped.sorted(by: { $0.key < $1.key })
    }
    
    func inner(pair: (String, [Persona])) -> some View {
        Section(header: Text(pair.0)) {
            ForEach(pair.1) { persona in
                // NavigationLink(value: persona) { // using tag instead now...
                HStack(spacing: 0) {
                    PersonaIcon(persona: persona)
                        .padding(.trailing)
                    Text(persona.name)
                    Spacer(minLength: 0)
                }
                .tag(persona)
            }
        }
    }
    
    public var body: some View {
//        if let onSelected = onSelected {
            List(groupBy(viewModel.personas.filter { !(room?.participants.contains($0) ?? false) }), id: \.0, selection: $selection) { pair in
                inner(pair: pair)
            }
            .listStyle(.inset)
            .onChange(of: selection) { selection in
                onSelected?(selection)
            }
//        } else {
//            List(groupBy(viewModel.personas.filter { !(room?.participants.contains($0) ?? false) }), id: \.0) { pair in
//                inner(pair: pair)
//            }
//        }
    }
    
    public init(room: Room? = nil, package: CodePackage? = nil, onSelected: ((Persona?) -> Void)? = nil) {
        self.room = room
        self.package = package
        self.onSelected = onSelected
    }
}

/// Includes invitation to room.
public struct PersonaListView: View {
    let room: Room
    let onSelected: (Persona?) -> Void
    
    @ScaledMetric(relativeTo: .body) private var idealWidth = 320
    @ScaledMetric(relativeTo: .body) private var idealHeight = 360
    
    public var body: some View {
        NavigationStack {
            PersonaList(room: room)
                .frame(idealWidth: idealWidth, idealHeight: idealHeight)
                .navigationDestination(for: Persona.self) { persona in
                    PersonaDetailsView(persona: persona)
                        .safeAreaInset(edge: .bottom) {
                            HStack {
                                Button {
                                    safeWrite(room) { realm, room in
                                        guard let matchPersona = realm?.object(ofType: Persona.self, forPrimaryKey: persona.id) else { return }
                                        room.participants.insert(matchPersona)
                                    }
                                    onSelected(persona)
                                } label: {
                                    HStack {
                                        Spacer()
                                        Text("Add to Room")
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .padding(10)
                            }
                            .background(.ultraThinMaterial)
                        }
                        .navigationTitle(persona.name)
                }
        }
    }
    
    public init(room: Room, onSelected: @escaping (Persona?) -> Void) {
        self.room = room
        self.onSelected = onSelected
    }
}
