import SwiftUI
import CodeCore

public struct CodeCI: View {
    @ObservedObject public var viewModel: CodeCIViewModel
    
    @StateObject private var codeCoreViewModel = CodeCoreViewModel()
    
    public var body: some View {
        CodeCoreView(codeCoreViewModel)
    }
    
    public init(_ viewModel: CodeCIViewModel) {
        self.viewModel = viewModel
    }
}
