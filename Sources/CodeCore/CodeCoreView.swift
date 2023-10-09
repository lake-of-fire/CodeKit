import SwiftUI
import WebKit
import UniformTypeIdentifiers

#if canImport(AppKit)
    public typealias NativeView = NSViewRepresentable
#elseif canImport(UIKit)
    public typealias NativeView = UIViewRepresentable
#endif

@MainActor
public struct CodeCoreView: NativeView {
    @ObservedObject public var viewModel: CodeCoreViewModel
    let waitOnCodeCoreIsReadyMessage: Bool
    let urlSchemeHandlers: [(WKURLSchemeHandler, String)]
    let defaultURLSchemeHandlerExtensions: [WKURLSchemeHandler]

    public init(_ viewModel: CodeCoreViewModel, waitOnCodeCoreIsReadyMessage: Bool = false, urlSchemeHandlers: [(WKURLSchemeHandler, String)] = [], defaultURLSchemeHandlerExtensions: [WKURLSchemeHandler] = []) {
        self.viewModel = viewModel
        self.waitOnCodeCoreIsReadyMessage = waitOnCodeCoreIsReadyMessage
        self.urlSchemeHandlers = urlSchemeHandlers
        self.defaultURLSchemeHandlerExtensions = defaultURLSchemeHandlerExtensions
    }

    #if canImport(AppKit)
        public func makeNSView(context: Context) -> WKWebView {
            createWebView(context: context)
        }

        public func updateNSView(_ nsView: WKWebView, context: Context) {
            updateWebView(context: context)
        }
    #elseif canImport(UIKit)
        public func makeUIView(context: Context) -> WKWebView {
            createWebView(context: context)
        }

        public func updateUIView(_ nsView: WKWebView, context: Context) {
            updateWebView(context: context)
        }
    #endif

    private func createWebView(context: Context) -> WKWebView {
        let preferences = WKPreferences()
        let userController = WKUserContentController()
        userController.add(context.coordinator, name: ScriptMessageName.codeCoreIsReady)
        userController.add(context.coordinator, name: ScriptMessageName.surrogateDocumentChanges)
        userController.add(context.coordinator, name: ScriptMessageName.consoleMessage)

        let configuration = WKWebViewConfiguration()
        configuration.preferences = preferences
        configuration.userContentController = userController
        configuration.setURLSchemeHandler(context.coordinator.defaultURLSchemeHandler, forURLScheme: "code")
        for (urlSchemeHandler, urlScheme) in urlSchemeHandlers {
            configuration.setURLSchemeHandler(urlSchemeHandler, forURLScheme: urlScheme)
        }
        context.coordinator.defaultURLSchemeHandler.defaultURLSchemeHandlerExtensions = defaultURLSchemeHandlerExtensions

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        #if os(OSX)
            webView.setValue(false, forKey: "drawsBackground")  // prevent white flicks
            webView.allowsMagnification = false
        #elseif os(iOS)
            webView.isOpaque = false
        #endif
        
        if #available(macOS 13.3, iOS 16.4, *) {
            webView.isInspectable = true
        }
        
        context.coordinator.webView = webView
        
        context.coordinator.updateAllowHostsRule()
        
        return webView
    }
    
    private func updateWebView(context: Context) {
        context.coordinator.updateAllowHostsRule()
    }

    public func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(parent: self, viewModel: viewModel, waitOnCodeCoreIsReadyMessage: waitOnCodeCoreIsReadyMessage)
        
        viewModel.load = { (data, mimeType, characterEncodingName, baseURL) in
            coordinator.webView.load(
                data, mimeType: mimeType, characterEncodingName: characterEncodingName, baseURL: baseURL)
        }
        
        viewModel.asyncJavaScriptCaller = { (js, arguments, frame, world) -> Any? in
            try await withCheckedThrowingContinuation { continuation in
                let cb = { (result: Result<Any?, Error>) in
                    switch result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                coordinator.enqueueJavascript(JavascriptFunction(functionString: js, args: arguments ?? [:]), callback: cb)
            }
        }
        return coordinator
    }
}

@MainActor
public class Coordinator: NSObject {
    var parent: CodeCoreView
    var viewModel: CodeCoreViewModel
    var webView: WKWebView!
    let waitOnCodeCoreIsReadyMessage: Bool

    private var pageLoaded = false
    private var pendingFunctions = [(JavascriptFunction, JavascriptCallback?)]()

    var defaultURLSchemeHandler = GenericFileURLSchemeHandler()
    
    init(parent: CodeCoreView, viewModel: CodeCoreViewModel, waitOnCodeCoreIsReadyMessage: Bool) {
        self.parent = parent
        self.viewModel = viewModel
        self.waitOnCodeCoreIsReadyMessage = waitOnCodeCoreIsReadyMessage
    }

    internal func enqueueJavascript(
        _ function: JavascriptFunction,
        callback: JavascriptCallback? = nil
    ) {
        if pageLoaded {
            evaluateJavascript(function: function, callback: callback)
        } else {
            pendingFunctions.append((function, callback))
        }
    }
    
    internal func updateAllowHostsRule() {
        let rules = """
            [{
                "trigger": {
                    "url-filter": ".*",
                    "url-filter-is-case-sensitive": false,
                    "unless-domain": [\(viewModel.allowHosts.map({ "\"\($0)\"" }).joined(separator: ","))]
                },
                "action": {
                    "type": "block"
                }
            }]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "codeCoreViewAllowHosts", encodedContentRuleList: rules) { [weak self] list, error in
            guard let list = list, let self = self else {
                print(error ?? "No list found.")
                return
            }
            webView.configuration.userContentController.add(list)
        }
    }

    private func callPendingFunctions() {
        for (function, callback) in pendingFunctions {
            evaluateJavascript(function: function, callback: callback)
        }
        pendingFunctions.removeAll()
    }

    private func evaluateJavascript(
        function: JavascriptFunction,
        callback: JavascriptCallback? = nil
    ) {
        /*
        // not sure why but callAsyncJavaScript always callback with result of nil
        if let callback = callback {
            webView.evaluateJavaScript(function.functionString) { (response, error) in
                if let error = error {
                    callback(.failure(error))
                }
                else {
                    callback(.success(response))
                }
            }
        }
        else {*/
            webView.callAsyncJavaScript(
                function.functionString,
                arguments: function.args,
                in: nil,
                in: .page
            ) { (result) in
                switch result {
                case .failure(let error):
                    callback?(.failure(error))
                case .success(let data):
                    callback?(.success(data))
                }
            }
//        }
    }
}

extension Coordinator: WKScriptMessageHandler {
    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case ScriptMessageName.codeCoreIsReady:
            if pageLoaded {
                callPendingFunctions()
                Task { @MainActor in await parent.viewModel.onLoadSuccess?() }
            } else {
                pageLoaded = true
            }
        case ScriptMessageName.surrogateDocumentChanges:
            guard let surrogateDocumentChanges = viewModel.surrogateDocumentChanges else {
                print("ERROR: no surrogateDocumentChanges set on view model")
                return
            }
            guard let result = message.body as? [String: Any], let collectionName = result["collectionName"] as? String, let changedDocs = result["changedDocs"] as? [[String: Any]] else {
                print("ERROR: failed to decode surrogateDocumentChanges message")
                return
            }
            surrogateDocumentChanges(collectionName, changedDocs)
        case ScriptMessageName.consoleMessage:
            print("CONSOLE: \(message.body)")
        default:
            print("received unhandled \(message.name) \(message.body)")
        }
    }
}

extension Coordinator: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        pageLoaded = false
    }
    
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !waitOnCodeCoreIsReadyMessage || pageLoaded {
            pageLoaded = true
            callPendingFunctions()
            Task { @MainActor in await parent.viewModel.onLoadSuccess?() }
        }
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        pageLoaded = false
        parent.viewModel.onLoadFailed?(error)
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        pageLoaded = false
        parent.viewModel.onLoadFailed?(error)
    }
}

final class GenericFileURLSchemeHandler: NSObject, WKURLSchemeHandler {
    var defaultURLSchemeHandlerExtensions: [WKURLSchemeHandler] = []
    
    enum CustomSchemeHandlerError: Error {
        case notFound
    }
    
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let baseURL = Bundle.module.url(forResource: "src", withExtension: nil)
        var fileURL: URL?
        if url.path == "/" {
            fileURL = baseURL?.appending(path: "/codekit/index.html")
        } else if url.absoluteString.hasPrefix("code://code/codekit/") {
            if let path = url.pathComponents.dropFirst(2).joined(separator: "/").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let baseURL = Bundle.module.url(forResource: "src", withExtension: nil) {
                fileURL = baseURL.appending(path: "/" + path)
                if fileURL?.isDirectory ?? false {
                    fileURL = fileURL?.appending(component: "index.html")
                }
            }
        }
        if let fileURL = fileURL {
            let mimeType = mimeType(ofFileAtUrl: fileURL)
            if let data = try? Data(contentsOf: fileURL) {
                let response = HTTPURLResponse(
                    url: url,
                    mimeType: mimeType,
                    expectedContentLength: data.count, textEncodingName: nil)
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
                return
            }
            
            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.notFound)
            return
        }
        
        for handler in defaultURLSchemeHandlerExtensions {
            handler.webView(webView, start: urlSchemeTask)
        }
    }
    
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        for handler in defaultURLSchemeHandlerExtensions {
            handler.webView(webView, stop: urlSchemeTask)
        }
    }
    
    private func mimeType(ofFileAtUrl url: URL) -> String {
        return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}
