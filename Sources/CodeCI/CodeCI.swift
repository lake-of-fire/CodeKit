import SwiftUI
import CodeCore
import RealmSwift

public struct CodeCI: View {
    @ObservedObject public var controller: CodeCIController
    
    @StateObject private var codeCoreViewModel = CodeCoreViewModel()
    @ObservedResults(PackageRepository.self) private var packageRepos
    
    public var body: some View {
        CodeCoreView(codeCoreViewModel)
            .opacity(0)
            .frame(maxWidth: 0.00001, maxHeight: 0.00001)
            .allowsHitTesting(false)
    }
    
    public init(controller: CodeCIController) {
        self.controller = controller
    }
}
