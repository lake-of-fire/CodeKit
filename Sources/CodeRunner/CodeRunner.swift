import SwiftUI
import CodeCore
import RealmSwift
import RealmSwiftGaps
import WebKit

public class CodeRunnerProxyConfiguration {
    public var allowHosts: [String]?
    public var hostsToProxy: [String]?
    public var rewriteHosts: [String: String]?
    public var requestModifiers: [String: ((URLRequest) throws -> URLRequest?)]?
    public var responseModifiers: [String: ((WKURLSchemeTask, URLResponse?) async throws -> (URLResponse?, Data?))]?
    public var responseDataModifiers: [String: ((URLSessionDataTask?, Data?) throws -> Data?)]?

    public init(
        allowHosts: [String]? = [],
        hostsToProxy: [String]? = [],
        rewriteHosts: [String: String]? = nil
    ) {
        self.allowHosts = allowHosts
        self.hostsToProxy = hostsToProxy
        self.rewriteHosts = rewriteHosts
    }
}

public struct CodeRunner: View {
    @ObservedRealmObject var codeExtension: CodeExtension
    let beforeRun: (() async -> Void)?
    let syncedTypes: [any DBSyncableObject.Type]?
    let syncFromSurrogateMap: [((any DBSyncableObject.Type), ([String: Any], (any DBSyncableObject)?, CodeExtension) -> [String: Any]?)]?
    let syncToSurrogateMap: [((any DBSyncableObject.Type), (any DBSyncableObject, CodeExtension) -> ((any DBSyncableObject)?, [String: Any]?))]?
    let urlSchemeHandlers: [(WKURLSchemeHandler, String)]
    let defaultURLSchemeHandlerExtensions: [WKURLSchemeHandler]
    let proxyConfiguration: CodeRunnerProxyConfiguration

    @StateObject private var codeCoreViewModel = CodeCoreViewModel()
    @StateObject private var dbSync = DBSync()
    @StateObject private var proxySchemeHandler = ExternalProxyURLSchemeHandler()

    @State private var workspaceStorage: WorkspaceStorage?
    
    public var body: some View {
        CodeCoreView(
            codeCoreViewModel,
            urlSchemeHandlers: urlSchemeHandlers,
            defaultURLSchemeHandlerExtensions: [proxySchemeHandler] + defaultURLSchemeHandlerExtensions)
            .opacity(0)
            .frame(maxWidth: 0.0000001, maxHeight: 0.0000001)
            .allowsHitTesting(false)
            .task {
                Task { @MainActor in
                    proxySchemeHandler.proxyConfiguration = proxyConfiguration
                    codeCoreViewModel.disallowHosts = proxyConfiguration.hostsToProxy
                    
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

    public init(codeExtension: CodeExtension, beforeRun: (() async -> Void)? = nil, syncedTypes: [any DBSyncableObject.Type]? = nil, syncFromSurrogateMap: [((any DBSyncableObject.Type), ([String: Any], (any DBSyncableObject)?, CodeExtension) -> [String: Any]?)]? = nil, syncToSurrogateMap: [((any DBSyncableObject.Type), (any DBSyncableObject, CodeExtension) -> ((any DBSyncableObject)?, [String: Any]?))]? = nil, urlSchemeHandlers: [(WKURLSchemeHandler, String)] = [], defaultURLSchemeHandlerExtensions: [WKURLSchemeHandler] = [], proxyConfiguration: CodeRunnerProxyConfiguration = CodeRunnerProxyConfiguration()) {
        self.codeExtension = codeExtension
        self.beforeRun = beforeRun
        self.syncedTypes = syncedTypes
        self.syncFromSurrogateMap = syncFromSurrogateMap
        self.syncToSurrogateMap = syncToSurrogateMap
        self.urlSchemeHandlers = urlSchemeHandlers
        self.defaultURLSchemeHandlerExtensions = defaultURLSchemeHandlerExtensions
        self.proxyConfiguration = proxyConfiguration
    }

    @MainActor
    func run() async throws {
        let (data, url) = try await loadLatestAvailableBuildResult()
        
        if let package = codeExtension.package {
            codeCoreViewModel.additionalAllowHosts = Array(package.allowHosts)
        } else {
            codeCoreViewModel.additionalAllowHosts = []
        }
        
        codeCoreViewModel.onLoadFailed = { error in
            print(error)
        }
        codeCoreViewModel.onLoadSuccess = {
            safeWrite(codeExtension) { _, codeExtension in
                codeExtension.lastRunStartedAt = Date()
            }

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
                    codeExtension: codeExtension) {
                        await beforeRun?()
                    }
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
