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
            .collectionPublisher
            .freeze()
            .removeDuplicates()
            .threadSafeReference()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] results in
                let ref = ThreadSafeReference(to: results)
                Task { @MainActor [weak self] in
                    if let realm = try? await Realm(), let personas = realm.resolve(ref) {
                        self?.personas = Array(personas)
                    }
                }
            })
            .store(in: &cancellables)
    }
}

public struct PersonaListItem: View {
    @ObservedRealmObject var persona: Persona
    
    public var body: some View {
        HStack(spacing: 0) {
            PersonaIcon(persona: persona)
                .padding(.trailing)
            Text(persona.name)
            Spacer(minLength: 0)
        }
    }
    
    public init(persona: Persona) {
        self.persona = persona
    }
}

public struct WrappedPersona: Identifiable, Hashable {
    public let persona: Persona
    let rank: Int
    let rankedName: String
    
    public var id: Persona.ID {
        persona.id
    }
    
    public func hash(into hasher: inout Hasher) {
        persona.hash(into: &hasher)
    }
    
    public init(persona: Persona, rank: Int, rankedName: String) {
        self.persona = persona
        self.rank = rank
        self.rankedName = rankedName
    }
}

public struct PersonaListItems: View {
    public let personas: [WrappedPersona]
    public let maxRanks: [String: Int]
    
    public var body: some View {
//        Text(Array(personas).map { $0.persona.name }.joined(separator: ";"))
        ForEach(personas, id: \.persona) { persona in
            if maxRanks[persona.rankedName] == persona.rank {
                Label(personas.contains(where: { $0.rankedName == persona.rankedName && $0.rank != persona.rank }) ? "Add New \(persona.rankedName)" : persona.rankedName, systemImage: "plus")
                    .foregroundStyle(Color.accentColor)
                    .tag(persona.persona)
            } else {
                PersonaListItem(persona: persona.persona)
                    .tag(persona.persona)
            }
        }
    }
    
    public init(personas: [WrappedPersona], maxRanks: [String: Int]) {
        self.personas = personas
        self.maxRanks = maxRanks
    }
}

public struct PersonaList: View {
    public var room: Room? = nil
    public var onSelected: ((Persona?) -> Void)? = nil
    
    @StateObject private var viewModel = PersonaListViewModel()
    @State private var selection: Persona? = nil

    @State private var rankedPersonas = [(String, [WrappedPersona])]()
    @State private var maxRanks = [String: [String: Int]]()
    
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
        let grouped = Dictionary(grouping: items.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }), by: { Self.groupedURL($0.providedByExtension?.repositoryURL ?? "" ) })
        return grouped.sorted(by: { $0.key < $1.key })
    }
    
    func inner(pair: (String, [WrappedPersona])) -> some View {
        Section(header: Text(pair.0)) {
            if let maxRanks = maxRanks[pair.0] {
                PersonaListItems(personas: pair.1, maxRanks: maxRanks)
            }
        }
    }
    
    func personaPairs(personas: [Persona]? = nil) -> [(String, [Persona])] {
        let pairs = groupBy((personas ?? viewModel.personas).filter { !(room?.participants.contains($0) ?? false) })
        return pairs
//                if let last = comps.last, !last.isEmpty, let iLast = Int(last), String(iLast) == last {
    }
    
    public var body: some View {
//        if let onSelected = onSelected {
        List(rankedPersonas, id: \.0, selection: $selection) { pair in
            inner(pair: pair)
        }
        .listStyle(.inset)
        .onChange(of: selection) { selection in
            onSelected?(selection)
        }
        .task {
            Task { @MainActor in refreshPersonas() }
        }
        .onChange(of: viewModel.personas) { personas in
            Task { @MainActor in refreshPersonas(personas) }
        }
        //        } else {
        //            List(groupBy(viewModel.personas.filter { !(room?.participants.contains($0) ?? false) }), id: \.0) { pair in
        //                inner(pair: pair)
        //            }
        //        }
    }
    
    public init(room: Room? = nil, onSelected: ((Persona?) -> Void)? = nil) {
        self.room = room
        self.onSelected = onSelected
    }
    
    private func refreshPersonas(_ personas: [Persona]? = nil) {
        var ranked = [(String, [WrappedPersona])]()
        var maxRanks = [String: [String: Int]]()
        for (repoURL, personas) in (personaPairs(personas: personas)) {
            var wrapped = [WrappedPersona]()
            maxRanks[repoURL] = [:]
            for persona in personas {
                var rank = 0
                var rankedName = persona.name
                if let last: String = persona.name.components(separatedBy: CharacterSet.whitespacesAndNewlines).last, !last.isEmpty, let iLast = Int(last), String(iLast) == last {
                    rank = iLast
                    rankedName = persona.name.prefix(persona.name.count - last.count).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let existingRank = maxRanks[repoURL]?[rankedName] {
                    maxRanks[repoURL]?[rankedName] = max(rank, existingRank)
                } else {
                    maxRanks[repoURL]?[rankedName] = rank
                }
                wrapped.append(WrappedPersona(persona: persona, rank: rank, rankedName: rankedName))
            }
            ranked.append((repoURL, wrapped))
        }
        self.rankedPersonas = ranked
        self.maxRanks = maxRanks
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
                                    Task { @MainActor in
                                        try await Realm.asyncWrite(room) { realm, room in
                                            guard let matchPersona = realm.object(ofType: Persona.self, forPrimaryKey: persona.id) else { return }
                                            room.participants.insert(matchPersona)
                                        }
                                        onSelected(persona)
                                    }
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
