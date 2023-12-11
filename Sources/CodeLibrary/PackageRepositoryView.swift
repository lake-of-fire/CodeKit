import SwiftUI
import CodeCore
import CodeAI
import RealmSwift
import RealmSwiftGaps

struct CodePackageView: View {
    @ObservedRealmObject var package: CodePackage
    @ObservedObject var repository: CodePackageRepository
    let personas: [Persona]
    
    @EnvironmentObject private var navigationModel: CodeLibraryNavigationModel
    
    var isUserEditable: Bool {
        package.packageCollection.allSatisfy({ $0.isUserEditable })
    }
    
    var body: some View {
        Form {
            LabeledContent("Name", value: package.name)
            HStack {
                RealmTextField("Repository URL", object: package, objectValue: $package.repositoryURL)
                    .disabled(!isUserEditable)
                if let url = URL(string: package.repositoryURL) {
                    Group {
                        Link(destination: url) {
                            Label("Open Link", systemImage: "link")
                        }
                        ShareLink(item: url)
                            .buttonStyle(.borderless)
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.accentColor)
                }
            }
            if !repository.statusDescription.isEmpty {
                LabeledContent("Git Status", value: repository.statusDescription)
            }
//            Toggle("Allow Access to All Hosts", isOn: $package.allowAllHosts)
//                .disabled(!isUserEditable)
            RealmCSVTextField("Allows Hosts", object: package, objectValue: $package.allowHosts)
                .disabled(!isUserEditable || package.allowAllHosts)
            Toggle("Installed", isOn: $package.isEnabled)
                .disabled(!isUserEditable)
            
            ForEach(package.codeExtensions.where { !$0.isDeleted }) { ext in
                Section {
                    CodeExtensionStatus(ext: ext)
//                        .disabled(!isUserEditable)
                    
                    let extensionPersonas = personas.filter { $0.providedByExtension?.id == ext.id }
                    if !extensionPersonas.isEmpty {
                        ForEach(extensionPersonas) { persona in
                            NavigationLink(value: persona) {
                                PersonaListItem(persona: persona)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
#if os(macOS)
        .textFieldStyle(.roundedBorder)
#endif
#if os(iOS)
        .toolbarTitleMenu {
            CodePackageCommands(package: package, repository: repository)
        }
#else
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                CodePackageCommands(package: package, repository: repository)
            } label: { Label("Package", systemImage: "shippingbox") }
        }
#endif
        .onChange(of: package) { _ in
            Task { @MainActor in
                await repository.updateGitRepositoryStatus()
            }
        }
        .task {
            Task { @MainActor in
                await repository.updateGitRepositoryStatus()
            }
        }
        .id("CodePackageView-\(package.id.uuidString)")
    }
}

fileprivate struct CodeExtensionStatus: View {
    @ObservedRealmObject var ext: CodeExtension
    
    var body: some View {
        LabeledContent("Extension", value: ext.name)
        if ext.buildRequested {
            if ext.isBuilding {
                LabeledContent("Build Status") {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Building…")
                    }
                }
            } else {
                LabeledContent("Build Status", value: "Waiting to build…")
            }
//            LabeledContent("Latest Build Available", value: ext.latestBuildHashAvailable ?? "None")
        } else {
            if ext.desiredBuildHash == ext.latestBuildHashAvailable {
                LabeledContent("Build Status") {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
        }
        if let lastBuiltAt = ext.humanizedLastBuiltAt {
            LabeledContent("Build Timestamp", value: lastBuiltAt)
        }
        if let lastRunStartedAt = ext.humanizedLastRunStartedAt {
            LabeledContent("Last Run Timestamp", value: lastRunStartedAt)
        }
    }
}

struct CodePackageCommands: View {
    @ObservedRealmObject var package: CodePackage
    @ObservedObject var repository: CodePackageRepository
    
    var body: some View {
#if os(macOS)
        Button {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repository.directoryURL.path)
        } label: { Label("Open in Finder", systemImage: "folder") }
#endif
        Button {
            Task { @MainActor in
                if repository.isWorkspaceInitialized {
                    try? await repository.pull()
                }
                
                try await Realm.asyncWrite(ThreadSafeReference(to: package)) { _, package in
                    for codeExtension in package.codeExtensions.where({ !$0.isDeleted }) {
                        codeExtension.buildRequested = true
                        codeExtension.lastBuildRequestedAt = Date()
                    }
                }
            }
        } label: {
            Label("Build", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("b")
    }
}
