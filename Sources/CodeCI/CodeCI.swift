import SwiftUI
import CodeCore
import RealmSwift

public struct CodeCI: View {
    @ObservedObject public var ciActor: CodeCIActor
    
    @ObservedResults(CodePackage.self, where: { !$0.isDeleted && $0.isEnabled }) private var packages
    
    public var body: some View {
        CodeCoreView(ciActor.codeCoreViewModel)
            .opacity(0)
            .frame(maxWidth: 0.00001, maxHeight: 0.00001)
            .allowsHitTesting(false)
        
//        ForEach(packages) { package in
////            if let workspaceStorage = repo.workspaceStorage {
//            CodeCIRepository(package: package) { //}, workspaceStorage: workspaceStorage) {
//                try? await ciActor.buildIfNeeded(package: package)
//            }
////            }
//        }
//        .environmentObject(codeCoreViewModel)
    }
    
    public init(ciActor: CodeCIActor) {
        self.ciActor = ciActor
    }
}
//
//struct CodeCIRepository: View {
//    @ObservedRealmObject var package: CodePackage
////    @ObservedObject var workspaceStorage: WorkspaceStorage
//    let buildIfNeeded: () async throws -> Void
//
//    @EnvironmentObject private var codeCoreViewModel: CodeCoreViewModel
//
//    var body: some View {
//        // Must be the only view for task etc. to be called properly
//        // (undocumented/unverified, may only apply to onAppear)
//        EmptyView()
//            .task {
//                try? await buildIfNeeded()
//            }
//            .onChange(of: package.buildRequested) { buildRequested in
//                if buildRequested {
//                    Task { try? await buildIfNeeded() }
//                }
//            }
//            .onChange(of: package.isEnabled) { _ in
//                Task { try? await buildIfNeeded() }
//            }
//    }
//}
