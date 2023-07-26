import SwiftUI
import CodeCore
import RealmSwift

public struct CodeCI: View {
    @ObservedObject public var ciActor: CodeCIActor
    
    @ObservedResults(PackageRepository.self, where: { !$0.isDeleted && $0.isEnabled }) private var repos
    
    public var body: some View {
        CodeCoreView(ciActor.codeCoreViewModel)
            .opacity(0)
            .frame(maxWidth: 0.00001, maxHeight: 0.00001)
            .allowsHitTesting(false)
        
        ForEach(repos) { repo in
            CodeCIRepository(repo: repo, workspaceStorage: repo.workspaceStorage) {
                try? await ciActor.buildIfNeeded(repos: [repo])
            }
        }
//        .environmentObject(codeCoreViewModel)
    }
    
    public init(ciActor: CodeCIActor) {
        self.ciActor = ciActor
    }
}

struct CodeCIRepository: View {
    @ObservedRealmObject var repo: PackageRepository
    @ObservedObject var workspaceStorage: WorkspaceStorage
    let buildIfNeeded: () async throws -> Void
    
    @EnvironmentObject private var codeCoreViewModel: CodeCoreViewModel
    
    var body: some View {
        // Must be the only view for task etc. to be called properly
        // (undocumented/unverified, may only apply to onAppear)
        EmptyView()
            .task {
                try? await buildIfNeeded()
            }
            .onChange(of: repo.gitTracks) { _ in
                Task { try? await buildIfNeeded() }
            }
            .onChange(of: repo.isEnabled) { _ in
                Task { try? await buildIfNeeded() }
            }
    }
}
