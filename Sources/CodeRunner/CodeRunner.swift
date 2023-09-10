import SwiftUI
import CodeCore
import RealmSwift
import RealmSwiftGaps
import WebKit

public struct CodeRunner: View {
    @ObservedRealmObject var codeExtension: CodeExtension
    let syncedTypes: [any DBSyncableObject.Type]?
    let syncFromSurrogateMap: [((any DBSyncableObject.Type), ([String: Any], (any DBSyncableObject)?, CodeExtension) -> [String: Any]?)]?
    let syncToSurrogateMap: [((any DBSyncableObject.Type), (any DBSyncableObject, CodeExtension) -> (any DBSyncableObject)?)]?
    let urlSchemeHandlers: [(WKURLSchemeHandler, String)]
    let defaultURLSchemeHandlerExtensions: [WKURLSchemeHandler]
    
    @StateObject private var codeCoreViewModel = CodeCoreViewModel()
    @StateObject private var dbSync = DBSync()
    
    @State private var workspaceStorage: WorkspaceStorage?
    
    public var body: some View {
        CodeCoreView(
            codeCoreViewModel,
            urlSchemeHandlers: urlSchemeHandlers,
            defaultURLSchemeHandlerExtensions: defaultURLSchemeHandlerExtensions)
            .opacity(0)
            .frame(maxWidth: 0.0000001, maxHeight: 0.0000001)
            .allowsHitTesting(false)
            .task {
                Task { @MainActor in
                    guard let packageDir = codeExtension.package?.directoryURL, let directoryURL = codeExtension.directoryURL else { return }
                    workspaceStorage = WorkspaceStorage(url: packageDir, isDirectoryMonitored: false)
                    await workspaceStorage?.updateDirectory(url: directoryURL)
                }
                
                codeCoreViewModel.surrogateDocumentChanges = dbSync.surrogateDocumentChanges(collectionName:changedDocs:)
                try? await run()
            }
            .onChange(of: codeExtension.lastBuiltAt) { latestBuildHashAvailable in
                guard latestBuildHashAvailable != nil else {
                    return
                }
                Task { @MainActor in try? await run() }
            }
    }
    
    public init(codeExtension: CodeExtension, syncedTypes: [any DBSyncableObject.Type]? = nil, syncFromSurrogateMap: [((any DBSyncableObject.Type), ([String: Any], (any DBSyncableObject)?, CodeExtension) -> [String: Any]?)]? = nil, syncToSurrogateMap: [((any DBSyncableObject.Type), (any DBSyncableObject, CodeExtension) -> (any DBSyncableObject)?)]? = nil, urlSchemeHandlers: [(WKURLSchemeHandler, String)] = [], defaultURLSchemeHandlerExtensions: [WKURLSchemeHandler] = []) {
        self.codeExtension = codeExtension
        self.syncedTypes = syncedTypes
        self.syncFromSurrogateMap = syncFromSurrogateMap
        self.syncToSurrogateMap = syncToSurrogateMap
        self.urlSchemeHandlers = urlSchemeHandlers
        self.defaultURLSchemeHandlerExtensions = defaultURLSchemeHandlerExtensions
    }
    
    @MainActor
    func run() async throws {
        let (data, url) = try await loadLatestAvailableBuildResult()
        codeCoreViewModel.onLoadSuccess = {
            safeWrite(codeExtension) { _, codeExtension in
                codeExtension.lastRunStartedAt = Date()
            }
            
    //        if try await codeCoreViewModel.callAsyncJavaScript("window.livecodes") == nil {
    //            print("Error initializing JS")
    //        }
            
            if let syncedTypes = syncedTypes, let asyncJavaScriptCaller = codeCoreViewModel.asyncJavaScriptCaller {
                guard let realm = codeExtension.realm else {
                    print("No Realm found for CodeExtension in CodeRunner")
                    return
                }
                await dbSync.initialize(
                    realmConfiguration: realm.configuration,
                    syncedTypes: syncedTypes,
                    syncFromSurrogateMap: syncFromSurrogateMap,
                    syncToSurrogateMap: syncToSurrogateMap,
                    asyncJavaScriptCaller: asyncJavaScriptCaller,
                    codeExtension: codeExtension)
            }

            if syncedTypes != nil && codeCoreViewModel.asyncJavaScriptCaller != nil {
                await dbSync.beginSyncIfNeeded()
            }
        }
        codeCoreViewModel.load(
            htmlData: data,
            baseURL: url)
    }
    
    @MainActor
    func loadLatestAvailableBuildResult() async throws -> (Data, URL) {
        guard let workspaceStorage = workspaceStorage, let buildResultStorageURL = codeExtension.latestBuildResultStorageURL, let buildResultPageURL = codeExtension.buildResultPageURL else {
            throw CodeError.unknownError
        }
        let resultData = try await workspaceStorage.contents(at: buildResultStorageURL)
        return (resultData, buildResultPageURL)
    }
}
