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
            Toggle("Installed", isOn: $package.isEnabled)
            
            ForEach(package.codeExtensions.where { !$0.isDeleted }) { ext in
                Section {
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
                        LabeledContent("Latest Build Available", value: ext.latestBuildHashAvailable ?? "None")
                    } else {
                        if ext.desiredBuildHash == ext.latestBuildHashAvailable {
                            LabeledContent("Build Status") {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }
            }
        }
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
            safeWrite(package) { _, package in
                for codeExtension in package.codeExtensions.where({ !$0.isDeleted }) {
                    codeExtension.buildRequested = true
                }
            }
        } label: {
            Label("Build", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("b")
    }
}
