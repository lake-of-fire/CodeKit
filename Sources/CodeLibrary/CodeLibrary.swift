import SwiftUI
import RealmSwift
import FilePicker
import UniformTypeIdentifiers
import OPML
import SwiftUIWebView
//import FaviconFinder
//import DebouncedOnChange
//import OpenGraph
import RealmSwiftGaps
import SwiftUtilities
import CodeCore


struct MaybePackageRepositoryView: View {
    var repo: PackageRepository?

    var body: some View {
        // Workaround for a known issue where `NavigationSplitView` and
        // `NavigationStack` fail to update when their contents are conditional.
        // For more information, see the iOS 16 Release Notes and
        // macOS 13 Release Notes. (91311311)"
        ZStack {
            if let repo = repo {
                PackageRepositoryView(repo: repo)
                    .navigationTitle(repo.name)
            } else {
                Text("Choose or add a repository")
                    .navigationTitle("")
            }
        }
    }

    var columns: [GridItem] {
        [ GridItem(.adaptive(minimum: 240)) ]
    }
}

struct CodeLibraryExportButton: View {
    @ObservedResults(RepositoryCollection.self, where: { !$0.isDeleted }) private var repoCollections
    
    @EnvironmentObject private var codeActor: CodeActor
    
    @State private var repositoryCollectionOPMLs = [(String, URL)]()
    @State private var isMenuPresented = false

    @ScaledMetric(relativeTo: .body) private var width = 290
    
    var body: some View {
        Button {
            isMenuPresented.toggle()
        } label: { Label("Export", systemImage: "square.and.arrow.up") }
            .popover(isPresented: $isMenuPresented) {
                VStack {
                    ForEach(repositoryCollectionOPMLs, id: \.1) { pack in
                        let (name, url) = pack
                        ShareLink("Share \(name)", item: url, message: Text(""), preview: SharePreview("OPML File", image: Image(systemName: "doc"))) // {
//                            Text("Share \(name)")
//                                .fixedSize(horizontal: false, vertical: true)
//                        }
                    }
//                    Button("Done") {
//                        isMenuPresented = false
//                    }
//                    .buttonStyle(.borderedProminent)
                }
                .frame(idealWidth: width)
                .padding()
                .task  {
                    let opmls = try? await codeActor.generateRepositoryCollectionOPMLs()
                    Task { @MainActor in
                        repositoryCollectionOPMLs = opmls ?? []
                    }
                }
        }
    }
}

public struct CodeLibraryView: View {
    @ObservedResults(RepositoryCollection.self, where: { !$0.isDeleted }) private var repoCollections
    @ObservedResults(PackageRepository.self, where: { !$0.isDeleted && $0.repositoryCollection.count > 0 }) private var collectionRepos
    @ObservedResults(PackageRepository.self, where: { !$0.isDeleted && $0.repositoryCollection.count == 0 }) private var orphanRepos
    
    @State private var selectedRepo: PackageRepository?
    @State private var columnVisibility = NavigationSplitViewVisibility.doubleColumn
    
    @State private var isCollectionNameAlertPresented = false
    @State private var newExtensionCollectionName = ""
    
    @State private var isExtensionURLAlertPresented = false
    @State private var addExtensionURL = ""
    
    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, sidebar: {
            List(selection: $selectedRepo) {
                ForEach(repoCollections) { collection in
                    Section(collection.name) {
                        ForEach(collection.repositories) { repo in
                            NavigationLink(repo.name, value: repo)
                        }
                    }
                    .headerProminence(.increased)
                }
                Section {
                    ForEach(orphanRepos) { repo in
                        NavigationLink(repo.name, value: repo)
                    }
                }
            }
            .navigationTitle("Extensions")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button("New Extension Collection…") {
                            isCollectionNameAlertPresented.toggle()
                        }
                        Button("Add Extension Repository…") {
                            isExtensionURLAlertPresented.toggle()
                        }
                    } label: { Label("Add", systemImage: "plus") }
                        .alert("Enter new extension collection name", isPresented: $isCollectionNameAlertPresented) {
                            TextField("Enter extension collection name", text: $newExtensionCollectionName)
                            Button("Add Collection") {
                                let collection = RepositoryCollection()
                                collection.name = newExtensionCollectionName
                                $repoCollections.append(collection)
                            }
                        }
                        .alert("Enter extension repository URL", isPresented: $isExtensionURLAlertPresented) {
                            TextField("Enter extension repository URL", text: $addExtensionURL)
                            Button("Add repository") {
                                let repo = PackageRepository()
                                repo.repositoryURL = addExtensionURL
                                $orphanRepos.append(repo)
                            }
                        }
                }
                ToolbarItem(placement: .automatic) {
                    HStack {
                        Button {
                            
                        } label: { Label("Import", systemImage: "square.and.arrow.down") }
                        CodeLibraryExportButton()
                    }
                }
            }
        }, detail: {
            MaybePackageRepositoryView(repo: selectedRepo)
        })
//        .navigationSplitViewStyle(.balanced)
//        .environmentObject(viewModel)
    }
    
    public init() {
    }
}

public extension View {
    func codeLibrarySheet(isPresented: Binding<Bool>) -> some View {
        self.modifier(CodeLibrarySheetModifier(isPresented: isPresented))
    }
}

struct CodeLibrarySheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                CodeLibraryView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            HStack(spacing: 12) {
                                Button {
                                    isPresented = false
                                } label: {
                                    Text("Done")
                                        .bold()
                                }
                            }
                        }
                    }
            }
    }
}
