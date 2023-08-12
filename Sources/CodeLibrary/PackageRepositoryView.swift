import SwiftUI
import CodeCore
import RealmSwift
import RealmSwiftGaps

struct PackageRepositoryView: View {
    @ObservedRealmObject var repo: PackageRepository
    
    var body: some View {
        Form {
            LabeledContent("Name", value: repo.name)
            RealmTextField("Repository URL", object: repo, objectValue: $repo.repositoryURL)
            Toggle("Extensions Enabled", isOn: $repo.isEnabled)
            
            Section("Extensions") {
                ForEach(repo.codeExtensions.where { !$0.isDeleted }) { ext in
                    LabeledContent("Name", value: ext.name)
                    DisclosureGroup {
                    LabeledContent("Name", value: ext.name)
                    } label : {
                        Label(ext.name, systemImage: "puzzlepiece.extension")
                    }
                    
                }
            }
        }
        .onChange(of: repo.repositoryURL) { newURL in
            if URL(string: newURL) == nil {
                #warning("fixme implement this")
//                $repo.isEnabled.wrappedValue = false
            }
        }
        .formStyle(.grouped)
#if os(iOS)
        .toolbarTitleMenu {
            PackageRepositoryCommands(repo: repo)
        }
#else
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                PackageRepositoryCommands(repo: repo)
            } label: { Label("Package", systemImage: "shippingbox") }
        }
#endif
    }
}

struct PackageRepositoryCommands: View {
    @ObservedRealmObject var repo: PackageRepository
    var body: some View {
#if os(macOS)
        Button {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repo.directoryURL.path)
        } label: { Label("Open in Finder", systemImage: "folder") }
#endif
        Button {
            safeWrite(repo) { _, repo in
                repo.buildRequested = true
            }
        } label: { Label("Build", systemImage: "arrow.clockwise") }
            .keyboardShortcut("b")
    }
}
