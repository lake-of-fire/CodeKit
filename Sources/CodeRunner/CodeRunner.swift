import SwiftUI
import CodeCore
import RealmSwift

public struct CodeRunner: View {
    @ObservedRealmObject var codeExtension: CodeExtension
    
    @StateObject private var codeCoreViewModel = CodeCoreViewModel()
    
    public var body: some View {
        CodeCoreView(codeCoreViewModel)
            .opacity(0)
            .frame(maxWidth: 0.0000001, maxHeight: 0.0000001)
            .allowsHitTesting(false)
            .task {
                try? await run()
            }
            .onChange(of: codeExtension.buildHash) { buildHash in
                guard buildHash != nil else {
                    return
                }
                Task { @MainActor in try? await run() }
            }
    }
    
    public init(codeExtension: CodeExtension) {
        self.codeExtension = codeExtension
    }
    
    @MainActor
    func run() async throws {
        let (data, url) = try await codeExtension.loadBuildResult()
        codeCoreViewModel.load(
            htmlData: data,
            baseURL: url)
    }
}
