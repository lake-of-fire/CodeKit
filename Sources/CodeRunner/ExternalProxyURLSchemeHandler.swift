// Some code borrowed from https://github.com/wikimedia/wikipedia-ios/blob/main/Wikipedia/Code/SchemeHandler/SchemeHandler.swift
import SwiftUI
import WebKit
import RealmSwift
import RealmSwiftGaps

final class ExternalProxyURLSchemeHandler: NSObject, ObservableObject {
    var proxyConfiguration: CodeRunnerProxyConfiguration?
    
    init(proxyConfiguration: CodeRunnerProxyConfiguration? = nil) {
        self.proxyConfiguration = proxyConfiguration
        super.init()
    }
    
    private let session: Session = Session()
    private var activeSessionTasks: [URLRequest: URLSessionTask] = [:]
    private var activeSchemeTasks = NSMutableSet(array: [])
}

extension ExternalProxyURLSchemeHandler: WKURLSchemeHandler {
    enum CustomSchemeHandlerError: Error {
        case rejected
    }
    
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard var request = urlRequestWithoutCustomScheme(from: urlSchemeTask.request), let proxiedHost = request.url?.host else {
            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.rejected)
            return
        }
        guard proxyConfiguration?.allowHosts?.contains(proxiedHost) ?? true else {
            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.rejected)
            return
        }
        
        if let requestModifier = proxyConfiguration?.requestModifiers?[proxiedHost] {
            request = requestModifier(request)
        }
        
        addSchemeTask(urlSchemeTask: urlSchemeTask)
        
        kickOffDataTask(request: request, urlSchemeTask: urlSchemeTask)
    }
    
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        removeSchemeTask(urlSchemeTask: urlSchemeTask)
        
        if let task = activeSessionTasks[urlSchemeTask.request] {
            removeSessionTask(request: urlSchemeTask.request)
            
            switch task.state {
            case .canceling:
                fallthrough
            case .completed:
                break
            default:
                task.cancel()
            }
        }
    }
}

private extension ExternalProxyURLSchemeHandler {
    func urlRequestWithoutCustomScheme(from originalRequest: URLRequest) -> URLRequest? {
        guard let url = originalRequest.url, url.pathComponents.starts(with: ["/", "load"]), let host = url.pathComponents.dropFirst(2).first?.lowercased() else {
            return nil
        }
        let path = "/" + url.pathComponents.dropFirst(3).joined(separator: "/")
        var oldComponents = URLComponents(url: url, resolvingAgainstBaseURL: true)
        oldComponents?.scheme = "https"
        oldComponents?.path = path
        oldComponents?.host = proxyConfiguration?.rewriteHosts?[host] ?? host
        var mutableRequest = originalRequest
        mutableRequest.url = oldComponents?.url
        return mutableRequest
    }
    
    func kickOffDataTask(request: URLRequest, urlSchemeTask: WKURLSchemeTask) {
//        print("PROXIED REQUEST:")
//        print(request.debugDescription)
//        print(request.httpMethod)
//        print(request.allHTTPHeaderFields)
//        if let data = request.httpBody {
//            print(String(data: data, encoding: .utf8))
//        } else {
//            print("(No HTTP body set on proxied request.)")
//        }
        
        guard schemeTaskIsActive(urlSchemeTask: urlSchemeTask) else {
            return
        }
        
        // IMPORTANT: Ensure the urlSchemeTask is not strongly captured by the callback blocks.
        // Otherwise it will sometimes be deallocated on a non-main thread, causing a crash https://phabricator.wikimedia.org/T224113
        
        var errorStatus: Int? = nil
        let callback = Session.Callback(response: { [weak urlSchemeTask] response in
            DispatchQueue.main.async {
                guard let urlSchemeTask = urlSchemeTask else {
                    return
                }
                guard self.schemeTaskIsActive(urlSchemeTask: urlSchemeTask) else {
                    return
                }
                if let httpResponse = response as? HTTPURLResponse, !HTTPStatusCode.isSuccessful(httpResponse.statusCode) {
                    errorStatus = httpResponse.statusCode
                    print("PROXIED RESPONSE ERROR:")
                    print(response)
//                    self.removeSessionTask(request: urlSchemeTask.request)
//                    urlSchemeTask.didFailWithError(error)
//                    self.removeSchemeTask(urlSchemeTask: urlSchemeTask)
                } else {
                    // May fix potential crashes if we have already called urlSchemeTask.didFinish() or webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) has already been called.
                    // https://developer.apple.com/documentation/webkit/wkurlschemetask/2890839-didreceive
                    guard self.schemeTaskIsActive(urlSchemeTask: urlSchemeTask) else {
                        return
                    }
                    
                    urlSchemeTask.didReceive(response)
                }
            }
        }, data: { [weak urlSchemeTask] dataTask, data in
            DispatchQueue.main.async {
                guard let urlSchemeTask = urlSchemeTask else {
                    return
                }
                guard self.schemeTaskIsActive(urlSchemeTask: urlSchemeTask) else {
                    return
                }
                
                if let errorStatus = errorStatus {
                    print("PROXIED RESPONSE ERROR:")
                    let body = String(data: data, encoding: .utf8)
                    print(body)
                    let response = dataTask.response ?? HTTPURLResponse()
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
//                    urlSchemeTask.didFailWithError(error)
                    self.removeSchemeTask(urlSchemeTask: urlSchemeTask)
                    return
                }
                
                urlSchemeTask.didReceive(data)
            }
        }, success: { [weak urlSchemeTask] usedPermanentCache in
            DispatchQueue.main.async {
                guard let urlSchemeTask = urlSchemeTask else {
                    return
                }
                guard self.schemeTaskIsActive(urlSchemeTask: urlSchemeTask) else {
                    return
                }
                urlSchemeTask.didFinish()
                self.removeSessionTask(request: urlSchemeTask.request)
                self.removeSchemeTask(urlSchemeTask: urlSchemeTask)
            }
            
        }, failure: { [weak urlSchemeTask] error in
            DispatchQueue.main.async {
                guard let urlSchemeTask = urlSchemeTask else {
                    return
                }
                guard self.schemeTaskIsActive(urlSchemeTask: urlSchemeTask) else {
                    return
                }
                self.removeSessionTask(request: urlSchemeTask.request)
                urlSchemeTask.didFailWithError(error)
                self.removeSchemeTask(urlSchemeTask: urlSchemeTask)
            }
            
        })
        
        if let dataTask = session.dataTask(with: request, callback: callback) {
            addSessionTask(request: request, dataTask: dataTask)
            dataTask.resume()
        }
    }
    
    func schemeTaskIsActive(urlSchemeTask: WKURLSchemeTask) -> Bool {
        assert(Thread.isMainThread)
        return activeSchemeTasks.contains(urlSchemeTask)
    }
    
    func removeSchemeTask(urlSchemeTask: WKURLSchemeTask) {
        assert(Thread.isMainThread)
        activeSchemeTasks.remove(urlSchemeTask)
    }
    
    func removeSessionTask(request: URLRequest) {
        assert(Thread.isMainThread)
        activeSessionTasks.removeValue(forKey: request)
    }
    
    func addSchemeTask(urlSchemeTask: WKURLSchemeTask) {
        assert(Thread.isMainThread)
        activeSchemeTasks.add(urlSchemeTask)
    }
    
    func addSessionTask(request: URLRequest, dataTask: URLSessionTask) {
        assert(Thread.isMainThread)
        activeSessionTasks[request] = dataTask
    }
}

fileprivate  struct HTTPStatusCode {
    public static func isSuccessful(_ statusCode: Int) -> Bool {
        return statusCode >= 200 && statusCode <= 299
    }
}

enum RequestError: LocalizedError {
    case unknown
    case invalidParameters
    case unexpectedResponse
    case notModified
    case noNewData
    case unauthenticated
    case http(Int, String?)
    case api(String)
    
    public var errorDescription: String? {
        switch self {
        case .unexpectedResponse:
            return "The app received an unexpected response from the server. Please try again later."
        default:
            return "Proxy request error"
        }
    }
    
    public static func from(code: Int, body: String?) -> RequestError {
        return .http(code, body)
    }
    
//    public static func from(_ apiError: [String: Any]?) -> RequestError? {
//        guard
//            let error = apiError?["error"] as? [String: Any],
//            let code = error["code"] as? String
//        else {
//            return nil
//        }
//        return .api(code)
//    }
}

public class Session: NSObject {
    public struct Request {
        public enum Method {
            case get
            case post
            case put
            case delete
            case head

            var stringValue: String {
                switch self {
                case .post:
                    return "POST"
                case .put:
                    return "PUT"
                case .delete:
                    return "DELETE"
                case .head:
                    return "HEAD"
                case .get:
                    fallthrough
                default:
                    return "GET"
                }
            }
        }

        public enum Encoding {
            case json
            case form
            case html
        }
    }
    
    public struct Callback {
        public typealias UsedPermanentCache = Bool
        let response: ((URLResponse) -> Void)?
        let data: ((URLSessionDataTask, Data) -> Void)?
        let success: ((UsedPermanentCache) -> Void)
        let failure: ((Error) -> Void)
        
        public init(response: ((URLResponse) -> Void)?, data: ((URLSessionDataTask, Data) -> Void)?, success: @escaping (UsedPermanentCache) -> Void, failure: @escaping (Error) -> Void) {
            self.response = response
            self.data = data
            self.success = success
            self.failure = failure
        }
    }
    
    private static func getURLSession(delegate: SessionDelegate) -> URLSession {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: delegate, delegateQueue: delegate.delegateQueue)
    }
    
    public var defaultURLSession: URLSession
    private let sessionDelegate: SessionDelegate
    
    @objc public override init() {
        self.sessionDelegate = SessionDelegate()
        self.defaultURLSession = Session.getURLSession(delegate: sessionDelegate)
        super.init()
    }
    
    deinit {
        teardown()
    }
    
    @objc public func teardown() {
        guard defaultURLSession !== URLSession.shared else { // [NSURLSession sharedSession] may not be invalidated
            return
        }
        defaultURLSession.invalidateAndCancel()
        defaultURLSession = URLSession.shared
    }
    
    public let wifiOnlyURLSession: URLSession = {
        let config = URLSessionConfiguration.default
//        config.allowsCellularAccess = false
        return URLSession(configuration: config)
    }()
    
    @objc(requestToGetURL:)
    public func request(toGET requestURL: URL?) -> URLRequest? {
        guard let requestURL = requestURL else {
            return nil
        }
        return request(with: requestURL, method: .get)
    }

    /// If `bodyData` is set, it will be used. Otherwise, `bodyParameters` will be encoded into the provided `bodyEncoding`
    public func request(with requestURL: URL, method: Session.Request.Method = .get, bodyParameters: Any? = nil, bodyData: Data? = nil, bodyEncoding: Session.Request.Encoding = .json, headers: [String: String] = [:], cachePolicy: URLRequest.CachePolicy? = nil) -> URLRequest {
        var request = URLRequest(url: requestURL)
        request.httpMethod = method.stringValue
        if let cachePolicy = cachePolicy {
            request.cachePolicy = cachePolicy
        }
        let defaultHeaders = [
            "Accept": "application/json; charset=utf-8",
            "Accept-Encoding": "gzip",
//            "User-Agent": WikipediaAppUtils.versionedUserAgent(),
//            "Accept-Language": requestURL.wmf_languageVariantCode ?? Locale.acceptLanguageHeaderForPreferredLanguages
        ]
        for (key, value) in defaultHeaders {
            guard headers[key] == nil else {
                continue
            }
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        guard bodyParameters != nil || bodyData != nil else {
            return request
        }
        switch bodyEncoding {
        case .json:
            if let data = bodyData {
                request.httpBody = data
            } else if let bodyParameters = bodyParameters {
                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: bodyParameters, options: [])
                } catch let error {
                    print("error serializing JSON: \(error)")
                }
            }
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        case .form:
            if let data = bodyData {
                request.httpBody = data
            } else if let bodyParametersDictionary = bodyParameters as? [String: Any] {
                let queryString = URLComponents.percentEncodedQueryStringFrom(bodyParametersDictionary)
                request.httpBody = queryString.data(using: String.Encoding.utf8)
            }
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        case .html:
            if let data = bodyData {
                request.httpBody = data
            } else if let  body = bodyParameters as? String {
                request.httpBody = body.data(using: .utf8)
            }
            request.setValue("text/html; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
    
    /*
    @discardableResult public func jsonDictionaryTask(with url: URL?, method: Session.Request.Method = .get, bodyParameters: Any? = nil, bodyEncoding: Session.Request.Encoding = .json, completionHandler: @escaping ([String: Any]?, HTTPURLResponse?, Error?) -> Swift.Void) -> URLSessionDataTask? {
        guard let url = url else {
            return nil
        }
        let dictionaryRequest = request(with: url, method: method, bodyParameters: bodyParameters, bodyEncoding: bodyEncoding)
        return jsonDictionaryTask(with: dictionaryRequest, completionHandler: completionHandler)
    }
     */
    
    public func dataTask(with request: URLRequest, callback: Callback) -> URLSessionTask? {
        let task = defaultURLSession.dataTask(with: request)
        sessionDelegate.addCallback(callback: callback, for: task)
        return task
    }
    
    /*
    public func dataTask(with request: URLRequest, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Swift.Void) -> URLSessionDataTask? {
        let cachedCompletion = { [weak self] (data: Data?, response: URLResponse?, error: Error?) -> Swift.Void in
            
            if let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 304 {
                
                if let cachedResponse = self?.permanentCache?.urlCache.cachedResponse(for: request) {
                    completionHandler(cachedResponse.data, cachedResponse.response, nil)
                    return
                }
            }
            
            if error != nil {
                
                if let cachedResponse = self?.permanentCache?.urlCache.cachedResponse(for: request) {
                    completionHandler(cachedResponse.data, cachedResponse.response, nil)
                    return
                }
            }
            
            completionHandler(data, response, error)
            
        }
        
        let task = defaultURLSession.dataTask(with: request, completionHandler: cachedCompletion)
        return task
    }
    
    // tonitodo: utlilize Callback & addCallback/session delegate stuff instead of completionHandler
    public func downloadTask(with url: URL, completionHandler: @escaping (URL?, URLResponse?, Error?) -> Void) -> URLSessionDownloadTask {
        return defaultURLSession.downloadTask(with: url, completionHandler: completionHandler)
    }

    public func downloadTask(with urlRequest: URLRequest, completionHandler: @escaping (URL?, URLResponse?, Error?) -> Void) -> URLSessionDownloadTask? {

        return defaultURLSession.downloadTask(with: urlRequest, completionHandler: completionHandler)
    }
    
    public func dataTask(with url: URL?, method: Session.Request.Method = .get, bodyParameters: Any? = nil, bodyEncoding: Session.Request.Encoding = .json, headers: [String: String] = [:], cachePolicy: URLRequest.CachePolicy? = nil, priority: Float = URLSessionTask.defaultPriority, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Swift.Void) -> URLSessionDataTask? {
        guard let url = url else {
            return nil
        }
        let dataRequest = request(with: url, method: method, bodyParameters: bodyParameters, bodyEncoding: bodyEncoding, headers: headers, cachePolicy: cachePolicy)
        let task = defaultURLSession.dataTask(with: dataRequest, completionHandler: completionHandler)
        task.priority = priority
        return task
    }
     */
    
    /**
     Shared response handling for common status codes. Currently logs the user out and removes local credentials if a 401 is received
     and an attempt to re-login with stored credentials fails.
    */
    private func handleResponse(_ response: URLResponse?, reattemptLoginOn401Response: Bool = true) {
        guard let response = response, let httpResponse = response as? HTTPURLResponse else {
            return
        }
        switch httpResponse.statusCode {
        default:
            break
        }
    }
}

// MARK: Modern Swift Concurrency APIs

extension Session {
    public func data(for url: URL) async throws -> (Data, URLResponse) {
        let request = request(with: url)
        return try await defaultURLSession.data(for: request)
    }
}

// MARK: PermanentlyPersistableURLCache Passthroughs

enum SessionPermanentCacheError: Error {
    case unexpectedURLCacheType
}

public class SessionDelegate: NSObject, URLSessionDelegate, URLSessionDataDelegate {
    let delegateDispatchQueue = DispatchQueue(label: "SessionDelegateDispatchQueue", qos: .default, attributes: [], autoreleaseFrequency: .workItem, target: nil) // needs to be serial according the docs for NSURLSession
    let delegateQueue: OperationQueue
    var callbacks: [Int: Session.Callback] = [:]
    
    override init() {
        delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = delegateDispatchQueue
    }
    
    func addCallback(callback: Session.Callback, for task: URLSessionTask) {
        delegateDispatchQueue.async {
            self.callbacks[task.taskIdentifier] = callback
        }
    }
    
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
//        print("DID RECEIVE response")
        
        defer {
            completionHandler(.allow)
        }
        
        guard let callback = callbacks[dataTask.taskIdentifier]?.response else {
            return
        }
        callback(response)
    }
    
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let callback = callbacks[dataTask.taskIdentifier]?.data else {
            return
        }
        callback(dataTask, data)
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let callback = callbacks[task.taskIdentifier] else {
            return
        }
        
        defer {
            callbacks.removeValue(forKey: task.taskIdentifier)
        }
        
        if let error = error as NSError? {
            if error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled {
                callback.failure(error)
            }
            return
        }
        
        callback.success(false)
    }
}

extension CharacterSet {
//    // RFC 3986 reserved + unreserved characters + percent (%)
//    public static var rfc3986Allowed: CharacterSet {
//        return CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
//    }
    
    static let urlQueryComponentAllowed: CharacterSet = {
        var characterSet = CharacterSet.urlQueryAllowed
        characterSet.remove(charactersIn: "+&=")
        return characterSet
    }()
}

extension URLComponents {
     static func with(host: String, scheme: String = "https", path: String = "/", queryParameters: [String: Any]? = nil) -> URLComponents {
        var components = URLComponents()
        components.host = host
        components.scheme = scheme
        components.path = path
        components.replacePercentEncodedQueryWithQueryParameters(queryParameters)
        return components
    }
    
    public static func percentEncodedQueryStringFrom(_ queryParameters: [String: Any]) -> String {
        var query = ""
        
        // sort query parameters by key, this allows for consistency when itemKeys are generated for the persistent cache.
        struct KeyValue {
            let key: String
            let value: Any
        }
        
        var unorderedKeyValues: [KeyValue] = []
        
        for (name, value) in queryParameters {
            
            unorderedKeyValues.append(KeyValue(key: name, value: value))
        }
        
        let orderedKeyValues = unorderedKeyValues.sorted { (lhs, rhs) -> Bool in
            return lhs.key < rhs.key
        }
        
        for keyValue in orderedKeyValues {
            guard
                let encodedName = keyValue.key.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryComponentAllowed),
                let encodedValue = String(describing: keyValue.value).addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryComponentAllowed) else {
                    continue
            }
            if query != "" {
                query.append("&")
            }
            
            query.append("\(encodedName)=\(encodedValue)")
        }
        
        return query
    }
    
    mutating func appendQueryParametersToPercentEncodedQuery(_ queryParameters: [String: Any]?) {
        guard let queryParameters = queryParameters else {
            return
        }
        var newPEQ = ""
        if let existing = percentEncodedQuery {
            newPEQ = existing + "&"
        }
        newPEQ = newPEQ + URLComponents.percentEncodedQueryStringFrom(queryParameters)
        percentEncodedQuery = newPEQ
    }
    
    mutating func replacePercentEncodedQueryWithQueryParameters(_ queryParameters: [String: Any]?) {
        guard let queryParameters = queryParameters else {
            percentEncodedQuery = nil
            return
        }
        percentEncodedQuery = URLComponents.percentEncodedQueryStringFrom(queryParameters)
    }
    
    mutating func replacePercentEncodedPathWithPathComponents(_ pathComponents: [String]?) {
        guard let pathComponents = pathComponents else {
            percentEncodedPath = "/"
            return
        }
        let fullComponents = [""] + pathComponents
        #if DEBUG
        for component in fullComponents {
            assert(!component.contains("/"))
        }
        #endif
        percentEncodedPath = fullComponents.joined(separator: "/") // NSString.path(with: components) removes the trailing slash that the reading list API needs
    }
}
