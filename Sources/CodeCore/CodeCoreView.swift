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

    public init(_ viewModel: CodeCoreViewModel) {
        self.viewModel = viewModel
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

        let configuration = WKWebViewConfiguration()
        configuration.preferences = preferences
        configuration.userContentController = userController
        configuration.setURLSchemeHandler(GenericFileURLSchemeHandler(), forURLScheme: "code")
        for (urlSchemeHandler, urlScheme) in context.coordinator.viewModel.urlSchemeHandlers {
            configuration.setURLSchemeHandler(urlSchemeHandler, forURLScheme: urlScheme)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        #if os(OSX)
            webView.setValue(false, forKey: "drawsBackground")  // prevent white flicks
            webView.allowsMagnification = false
        #elseif os(iOS)
            webView.isOpaque = false
        #endif
        
        context.coordinator.webView = webView
        return webView
    }

    private func updateWebView(context: Context) {
        for (urlSchemeHandler, urlScheme) in context.coordinator.viewModel.urlSchemeHandlers {
            if context.coordinator.webView.configuration.urlSchemeHandler(forURLScheme: urlScheme) == nil {
                context.coordinator.webView.configuration.setURLSchemeHandler(urlSchemeHandler, forURLScheme: urlScheme)
            }
        }
    }

    public func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(parent: self, viewModel: viewModel)
        
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

    private var pageLoaded = false
    private var pendingFunctions = [(JavascriptFunction, JavascriptCallback?)]()

    init(parent: CodeCoreView, viewModel: CodeCoreViewModel) {
        self.parent = parent
        self.viewModel = viewModel
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
            pageLoaded = true
            callPendingFunctions()
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
        default:
            print("received unhandled \(message.name) \(message.body)")
        }
    }
}

extension Coordinator: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        parent.viewModel.onLoadSuccess?()
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        parent.viewModel.onLoadFailed?(error)
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        parent.viewModel.onLoadFailed?(error)
    }
}

final class GenericFileURLSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let scheme = "code"
        if url.absoluteString.hasPrefix("\(scheme)://"),
           let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let baseURL = Bundle.module.url(forResource: "src", withExtension: nil) {
            var fileUrl = baseURL.appending(path: path)
            if fileUrl.isDirectory {
                fileUrl = fileUrl.appending(component: "index.html")
            }
            let mimeType = mimeType(ofFileAtUrl: fileUrl)
            if let data = try? Data(contentsOf: fileUrl) {
                let response = HTTPURLResponse(
                    url: url,
                    mimeType: mimeType,
                    expectedContentLength: data.count, textEncodingName: nil)
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            }
        }
    }
    
    private func mimeType(ofFileAtUrl url: URL) -> String {
        return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}
