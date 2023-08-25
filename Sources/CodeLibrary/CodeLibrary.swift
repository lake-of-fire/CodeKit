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
import CodeCI

struct MaybeCodePackageView: View {
    let package: CodePackage?
    let codeCoreViewModel: CodeCoreViewModel
    
    @State private var repository: CodePackageRepository?

    var body: some View {
        // Workaround for a known issue where `NavigationSplitView` and
        // `NavigationStack` fail to update when their contents are conditional.
        // For more information, see the iOS 16 Release Notes and
        // macOS 13 Release Notes. (91311311)"
        ZStack {
            if let package = package, let repository = repository {
                CodePackageView(package: package, repository: repository)
                    .navigationTitle(package.name)
            } else {
                Text("Choose or add a repository")
                    .navigationTitle("")
            }
        }
        .onChange(of: package) { package in
            Task { @MainActor in
                guard let package = package else { return }
                repository = CodePackageRepository(package: package, codeCoreViewModel: codeCoreViewModel)
            }
        }
    }

    var columns: [GridItem] {
        [ GridItem(.adaptive(minimum: 240)) ]
    }
}

struct CodeLibraryExportButton: View {
    @ObservedResults(PackageCollection.self, where: { !$0.isDeleted }) private var repoCollections
    
    @EnvironmentObject private var codeActor: CodeActor
    
    @State private var packageCollectionOPMLs = [(String, URL)]()
    @State private var isMenuPresented = false

    @ScaledMetric(relativeTo: .body) private var width = 290
    
    var body: some View {
        Button {
            isMenuPresented.toggle()
        } label: { Label("Export", systemImage: "square.and.arrow.up") }
            .popover(isPresented: $isMenuPresented) {
                VStack {
                    ForEach(packageCollectionOPMLs, id: \.1) { pack in
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
                    let opmls = try? await codeActor.generatePackageCollectionOPMLs()
                    Task { @MainActor in
                        packageCollectionOPMLs = opmls ?? []
                    }
                }
        }
    }
}

public struct CodeLibraryView: View {
    @StateObject private var ciActor = CodeCIActor(realmConfiguration: .defaultConfiguration, autoBuild: false)
    
    @ObservedResults(PackageCollection.self, where: { !$0.isDeleted }) private var packageCollections
    @ObservedResults(CodePackage.self, where: { !$0.isDeleted && $0.packageCollection.count > 0 }) private var collectionRepos
    @ObservedResults(CodePackage.self, where: { !$0.isDeleted && $0.packageCollection.count == 0 }) private var orphanPackages
    
    @State private var selectedPackage: CodePackage?
    @State private var columnVisibility = NavigationSplitViewVisibility.doubleColumn
    
    @State private var isCollectionNameAlertPresented = false
    @State private var newExtensionCollectionName = ""
    
    @State private var isExtensionURLAlertPresented = false
    @State private var addExtensionURL = ""
    
    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, sidebar: {
            List(selection: $selectedPackage) {
                ForEach(packageCollections) { collection in
                    Section(collection.name) {
                        ForEach(collection.packages) { package in
                            NavigationLink(package.name, value: package)
                        }
                    }
                    .headerProminence(.increased)
                }
                Section {
                    ForEach(orphanPackages) { package in
                        NavigationLink(package.name, value: package)
                    }
                }
            }
            .navigationTitle("Extensions")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Menu {
                        Button("New Extension Collection…") {
                            isCollectionNameAlertPresented.toggle()
                        }
                        Button("Add Extension Repository…") {
                            isExtensionURLAlertPresented.toggle()
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                            .foregroundStyle(.secondary, .secondary)
                            .imageScale(.large)
                    }
                        .menuIndicator(.hidden)
                        .alert("Enter new extension collection name", isPresented: $isCollectionNameAlertPresented) {
                            TextField("Enter extension collection name", text: $newExtensionCollectionName)
                            Button("Add Collection") {
                                let collection = PackageCollection()
                                collection.name = newExtensionCollectionName
                                $packageCollections.append(collection)
                            }
                            Button("Cancel", role: .cancel) {
                                isCollectionNameAlertPresented = false
                            }
                        }
                        .alert("Enter Extension Repository URL", isPresented: $isExtensionURLAlertPresented) {
                            TextField("Enter extension repository URL", text: $addExtensionURL)
                            Button("Add Repository") {
                                let package = CodePackage()
                                package.repositoryURL = addExtensionURL
                                $orphanPackages.append(package)
                            }
                            Button("Cancel", role: .cancel) {
                                isExtensionURLAlertPresented = false
                            }
                        }
//                    Button {
//
//                    } label: { Label("Import", systemImage: "square.and.arrow.down") }
//                    CodeLibraryExportButton()
                    Spacer()
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .padding()
            }
        }, detail: {
            MaybeCodePackageView(package: selectedPackage, codeCoreViewModel: ciActor.codeCoreViewModel)
        })
//        .navigationSplitViewStyle(.balanced)
//        .environmentObject(viewModel)
        .background {
            CodeCI(ciActor: ciActor)
        }
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
