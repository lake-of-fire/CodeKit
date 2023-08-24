import SwiftUI
import WebKit

@MainActor
public class CodeCoreViewModel: ObservableObject {
    var onLoadSuccess: (() -> Void)?
    var onLoadFailed: ((Error) -> Void)?
//    public var onContentChange: (() -> Void)?

//    internal var executeJS: ((JavascriptFunction, JavascriptCallback?) -> Void)!
//    internal var asyncJavaScriptCaller: ((String, [String: Any]?, WKFrameInfo?, WKContentWorld?, ((Result<Any, any Error>) -> Void)?) async -> Void)? = nil
    internal var load: ((Data, String, String, URL) -> Void)? = nil
    public var asyncJavaScriptCaller: ((String, [String: Any]?, WKFrameInfo?, WKContentWorld?) async throws -> Any?)? = nil
    public var surrogateDocumentChanges: ((String, [[String: Any]]) -> Void)? = nil

//    @Published public var  = false
//    @Published public var darkMode = false
//    @Published public var lineWrapping = false

    public init(
        onLoadSuccess: (() -> Void)? = nil,
        onLoadFailed: ((Error) -> Void)? = nil
//        onContentChange: (() -> Void)? = nil
    ) {
        self.onLoadSuccess = onLoadSuccess
        self.onLoadFailed = onLoadFailed
//        self.onContentChange = onContentChange
    }
    
    public func load(htmlData: Data, mimeType: String = "text/html", characterEncodingName: String = "utf-8", baseURL: URL) {
        guard let loader = load else { return }
        loader(
            htmlData, mimeType, characterEncodingName, baseURL)
    }
    
    public func callAsyncJavaScript(_ js: String, arguments: [String: Any]? = nil) async throws -> Any? {
        // TODO: Should instead error if nil
        guard let asyncJavaScriptCaller = asyncJavaScriptCaller else { return nil }
//        return try await asyncJavaScriptCaller(js, arguments, nil, .defaultClient)
        return try await asyncJavaScriptCaller(js, arguments, nil, .page)
    }
}
