import SwiftUI
import CodeCore
import RealmSwift

public struct CodeRunner: View {
    @ObservedRealmObject var codeExtension: CodeExtension
    @StateObject var codeCoreViewModel = CodeCoreViewModel()
    
    public var body: some View {
let _ = Self._printChanges()
        CodeCoreView(ciActor.codeCoreViewModel)
            .opacity(0)
            .frame(maxWidth: 0.00001, maxHeight: 0.00001)
            .allowsHitTesting(false)
        
        ForEach(repos) { repo in
            if let workspaceStorage = repo.workspaceStorage {
                CodeCIRepository(repo: repo, workspaceStorage: workspaceStorage) {
                    try? await ciActor.buildIfNeeded(repos: [repo])
                }
            }
        }
//        .environmentObject(codeCoreViewModel)
    }
    
    public init(codeExtension: CodeExtension) {
        self.codeExtension = codeExtension
    }
}
