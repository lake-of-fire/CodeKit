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
import CodeAI

struct CodePackageWithRepositoryView: View {
    let package: CodePackage
    
    @State private var repository: CodePackageRepository?
    
    var body: some View {
        // Workaround for a known issue where `NavigationSplitView` and
        // `NavigationStack` fail to update when their contents are conditional.
        // For more information, see the iOS 16 Release Notes and
        // macOS 13 Release Notes. (91311311)"
        ZStack {
            if let repository = repository {
                CodePackageView(package: package, repository: repository)
                    .navigationTitle(package.name)
            } else {
                ProgressView()
            }
        }
        .onChange(of: package) { [oldPackage = package] package in
            Task { @MainActor in
                guard package != oldPackage || repository == nil else { return }
                repository = CodePackageRepository(package: package, codeCoreViewModel: nil)
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

public struct CodeLibraryDataButtons: View {
    @ObservedResults(PackageCollection.self, where: { !$0.isDeleted }) private var packageCollections
    @ObservedResults(CodePackage.self, where: { !$0.isDeleted && $0.packageCollection.count == 0 }) private var orphanPackages
    
    @State private var isOPMLImportPresented = false
    @State private var isOPMLExportPresented = false
    @State private var opmlFile: OPMLFile?
    
    public var body: some View {
        Menu {
            Menu("Export Extensions…") {
                ForEach(packageCollections) { packageCollection in
                    Menu(packageCollection.name) {
                        Button("Export Collection") {
                            generateOPMLCollection(packageCollection: packageCollection)
                        }
                        Divider()
                        ForEach(packageCollection.packages) { package in
                            Button(package.name) {
                                generateOPML(package: package)
                            }
                        }
                    }
                }
                ForEach(orphanPackages) { package in
                    Button(package.name) {
                        generateOPML(package: package)
                    }
                }
            }
            Button("Import Extensions…") {
                isOPMLImportPresented.toggle()
            }
        } label: {
            Label("More Options", systemImage: "ellipsis.circle")
                .foregroundStyle(.gray, .gray)
                .imageScale(.large)
        }
        .menuIndicator(.hidden)
        .fileExporter(isPresented: $isOPMLExportPresented, document: opmlFile, contentType: OPMLFile.readableContentTypes.first!, defaultFilename: opmlFile?.title) { _ in }
        .fileImporter(isPresented: $isOPMLImportPresented, allowedContentTypes: OPMLFile.readableContentTypes, allowsMultipleSelection: false) { results in
            switch results {
            case .success(let fileurls):
                CodeLibraryConfiguration.shared.importOPML(fileURLs: fileurls)
            case .failure(let error):
                print(error)
            }
        }
    }
    
    public init() {
    }
    
    func generateOPMLCollection(packageCollection: PackageCollection) {
        Task { @MainActor in
            opmlFile = try? await OPMLFile(opml: packageCollection.generateOPML())
//            print(opmlFile?.title)
            isOPMLExportPresented = true
        }
    }
    
    func generateOPML(package: CodePackage) {
        Task { @MainActor in
            opmlFile = try? await OPMLFile(opml: package.generateOPML())
//            print(opmlFile?.title)
            isOPMLExportPresented = true
        }
    }
}

struct CodeLibraryNavigationItemMenuButtons: View {
    @ObservedRealmObject var package: CodePackage
    let allowMenus: Bool
    
    @ObservedResults(PackageCollection.self, where: { !$0.isDeleted }) private var packageCollections
    
    @State private var isMovingPresented = false
    @State private var isUserEditable = false
    
    var body: some View {
        Group {
            if isUserEditable {
                if allowMenus {
                    Menu {
                        collectionMoveButtons
                    } label: { Label("Move", systemImage: "folder") }
                } else {
                    Button {
                        isMovingPresented.toggle()
                    } label: { Label("Move", systemImage: "folder") }
                        .alert("Move to Collection", isPresented: $isMovingPresented) {
                            collectionMoveButtons
                            Button("Cancel", role: .cancel) {
                                isMovingPresented = false
                            }
                        }
                }
                Divider()
                Button(role: .destructive) {
                    safeWrite(package) { _, package in
                        package.isDeleted = true
                    }
                } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .task {
            refreshEditable()
        }
        .onChange(of: package.packageCollection.count) { _ in
            refreshEditable()
        }
        .id("CodeLibraryNavigationItemMenuButtons-\(package.id.uuidString)")
    }
    
    var collectionMoveButtons: some View {
        ForEach(packageCollections) { packageCollection in
            if !package.packageCollection.isEmpty {
                Button("No Collection") {
                    safeWrite(package) { _, package in
                        for existing in package.packageCollection {
                            existing.packages.remove(package)
                        }
                    }
                }
            }
            if !package.packageCollection.contains(where: { $0.id == packageCollection.id }) {
                Button(packageCollection.name) {
                    safeWrite(package) { _, package in
                        for existing in package.packageCollection {
                            existing.packages.remove(package)
                        }
                        packageCollection.thaw()?.packages.insert(package)
                    }
                }
            }
        }
    }

    func refreshEditable() {
        Task { @MainActor in
            isUserEditable = package.packageCollection.allSatisfy({ $0.isUserEditable })
            print("package \(package.name) is editable \(isUserEditable.description)")
        }
    }
    
}

struct CodeLibraryPackageCell: View {
    @ObservedRealmObject var package: CodePackage
//    let personas: [Persona]
    
    var packageLabel: some View {
        Text(package.name)
    }
    
    public var body: some View {
//        if (personas.isEmpty) {
            packageLabel
//        } else {
//            OutlineGroup {
//                PersonaListItems(personas: personas) { persona in
//                    Task { @MainActor in
//                        navigationModel.selectedPersona = persona
//                    }
//                }
//            } label: {
//                packageLabel
//            }
//            .swipeActions(edge: .trailing) {
//                CodeLibraryNavigationItemMenuButtons(package: package, allowMenus: false)
//            }
//            .contextMenu {
//                CodeLibraryNavigationItemMenuButtons(package: package, allowMenus: true)
//            }
            .tag(package)
//        }
    }
}

public struct CodeLibraryView: View {
    @ObservedResults(PackageCollection.self, where: { !$0.isDeleted }) private var packageCollections
    @ObservedResults(CodePackage.self, where: { !$0.isDeleted && $0.packageCollection.count > 0 }) private var collectionRepos
    @ObservedResults(CodePackage.self, where: { !$0.isDeleted && $0.packageCollection.count == 0 }) private var orphanPackages
    
    @State private var isCollectionNameAlertPresented = false
    @State private var newExtensionCollectionName = ""
    
    @State private var isExtensionURLAlertPresented = false
    @State private var addExtensionURL = ""
    
    @StateObject private var navigationModel = CodeLibraryNavigationModel()
    @SceneStorage("navigation") private var navigationData: Data?
    
    func packageCell(package: CodePackage) -> some View {
//        CodeLibraryPackageCell(package: package, personas: Array(allOnlinePersonas.where({ $0.providedByExtension.package == package })), navigationModel: navigationModel)
        CodeLibraryPackageCell(package: package)
    }
    
    public var body: some View {
        NavigationSplitView(columnVisibility: $navigationModel.columnVisibility, sidebar: {
            List(selection: $navigationModel.selectedPackage) {
                ForEach(packageCollections) { collection in
                    Section {
                        ForEach(collection.packages.where { !$0.isDeleted }) { package in
                            packageCell(package: package)
                        }
                    } header: {
                        Label(collection.name, systemImage: "folder")
                            .contextMenu {
                                if collection.isUserEditable {
                                    Button(role: .destructive) {
                                        safeWrite(collection) { _, collection in
                                            collection.isDeleted = true
                                        }
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                    }
                    .headerProminence(.increased)
                }
                Section {
                    ForEach(orphanPackages) { package in
                        packageCell(package: package)
                    }
                }
            }
            .navigationTitle("Extensions")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Menu {
                        Button("New Collection…") {
                            isCollectionNameAlertPresented.toggle()
                        }
                        Button("Add Repository URL…") {
                            isExtensionURLAlertPresented.toggle()
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
//                            .foregroundStyle(.secondary, .secondary)
                            .foregroundStyle(.gray, .gray)
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
                        .alert("Enter extension repository URL", isPresented: $isExtensionURLAlertPresented) {
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
                    CodeLibraryDataButtons()
                    Spacer()
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .padding()
            }
        }, detail: {
            NavigationStack(path: $navigationModel.navigationPath) {
                ZStack {
                    Text("Choose or add a repository containing Chat extensions.")
                        .navigationTitle("")
                }
                .navigationDestination(for: CodePackage.self) { package in
                    CodePackageWithRepositoryView(package: package)
                }
                .navigationDestination(for: Persona.self) { persona in
                    PersonaDetailsView(persona: persona)
                }
            }
        })
        .environmentObject(navigationModel)
//        .navigationSplitViewStyle(.balanced)
//        .environmentObject(viewModel)
        .task {
            if let jsonData = navigationData {
                navigationModel.jsonData = jsonData
            }
            for await _ in navigationModel.objectWillChangeSequence {
                navigationData = navigationModel.jsonData
            }
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
