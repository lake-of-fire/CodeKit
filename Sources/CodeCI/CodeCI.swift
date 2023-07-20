import SwiftUI
import CodeCore
import RealmSwift

public struct CodeCI: View {
    @ObservedObject public var ciActor: CodeCIActor
    
    @StateObject private var codeCoreViewModel = CodeCoreViewModel()
//    @ObservedResults(PackageRepository.self, where: { !$0.isDeleted && $0.isEnabled }) private var packageRepos
    
    public var body: some View {
        CodeCoreView(codeCoreViewModel)
            .opacity(0)
            .frame(maxWidth: 0.00001, maxHeight: 0.00001)
            .allowsHitTesting(false)
    }
    
    public init(ciActor: CodeCIActor) {
        self.ciActor = ciActor
    }
}
