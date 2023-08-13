import SwiftUI
import CodeCore
import RealmSwift
import RealmSwiftGaps

struct CodePackageView: View {
    @ObservedRealmObject var package: CodePackage
    @ObservedObject var repository: CodePackageRepository
    
    var body: some View {
        let _ = Self._printChanges()
        Form {
            LabeledContent("Name", value: package.name)
            RealmTextField("Repository URL", object: package, objectValue: $package.repositoryURL)
            if let aheadBehind = repository.aheadBehind {
                if aheadBehind != (0, 0) {
                    Text("\(aheadBehind.1)↓ \(aheadBehind.0)↑")
                } else {
                    Text("This branch is up to date with \(repository.remote):\(repository.branch)")
                }
            }
            LabeledContent("Build Status") {
                if package.buildRequested {
                    ProgressView() {
                        Text("Building…")
                    }
                }
            }
            Toggle("Installed", isOn: $package.isEnabled)
            
            
            ForEach(package.codeExtensions.where { !$0.isDeleted }) { ext in
                Section {
                    LabeledContent("Extension", value: ext.name)
                }
            }
        }
//        .onChange(of: repo.repositoryURL) { newURL in
//            if URL(string: newURL) == nil {
//                #warning("fixme implement this")
////                $repo.isEnabled.wrappedValue = false
//            } else {
//                try? await repo.gitStatus()
//            }
//        }
        .formStyle(.grouped)
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
            safeWrite(package) { _, repo in
                package.buildRequested = true
            }
        } label: { Label("Build", systemImage: "arrow.clockwise") }
            .keyboardShortcut("b")
    }
}
