import SwiftUI
import WebKit

@MainActor
public class CodeCoreViewModel: ObservableObject {
    public var onLoadSuccess: (() -> Void)?
    public var onLoadFailed: ((Error) -> Void)?
//    public var onContentChange: (() -> Void)?

//    internal var executeJS: ((JavascriptFunction, JavascriptCallback?) -> Void)!
//    internal var asyncJavaScriptCaller: ((String, [String: Any]?, WKFrameInfo?, WKContentWorld?, ((Result<Any, any Error>) -> Void)?) async -> Void)? = nil
    internal var asyncJavaScriptCaller: ((String, [String: Any]?, WKFrameInfo?, WKContentWorld?) async throws -> Any?)? = nil

//    @Published public var  = false
//    @Published public var darkMode = false
//    @Published public var lineWrapping = false

    public init(
        onLoadSuccess: (() -> Void)? = nil,
        onLoadFailed: ((Error) -> Void)? = nil,
        onContentChange: (() -> Void)? = nil
    ) {
        self.onLoadSuccess = onLoadSuccess
        self.onLoadFailed = onLoadFailed
//        self.onContentChange = onContentChange
    }
}
