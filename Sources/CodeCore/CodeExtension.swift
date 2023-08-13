import SwiftUI
import Combine
import RealmSwift
import BigSyncKit
import RealmSwiftGaps
import SwiftGit2
import CryptoKit

public class CodeExtension: Object, UnownedSyncableObject, ObjectKeyIdentifiable {
    /// Do not prepend dot. Checks both dot-prepended and as-is automatically and in that order.
    public static var extensionsPathComponents = [String]()
    
    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted(indexed: true) public var repositoryURL = ""
    
    @Persisted public var name = ""
    @Persisted public var package: CodePackage?
    
    @Persisted public var buildRequested = false
    @Persisted public var isBuilding = false
    @Persisted public var desiredBuildHash: String? = nil
    @Persisted public var latestBuildHashAvailable: String? = nil
    
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    public var needsSyncToServer: Bool { false }
    
//    // Git UI states
//    @MainActor @Published public var gitTracks: [URL: Diff.Status] = [:]
//    @MainActor @Published public var indexedResources: [URL: Diff.Status] = [:]
//    @MainActor @Published public var workingResources: [URL: Diff.Status] = [:]
//    @MainActor @Published public var branch: String = ""
//    @MainActor @Published public var remote: String = ""
//    @MainActor @Published public var commitMessage: String = ""
//    @MainActor @Published public var isSyncing: Bool = false
//    @MainActor @Published public var aheadBehind: (Int, Int)? = nil
//    @MainActor private var cachedWorkspaceStorage: WorkspaceStorage? = nil
    
//    @MainActor public var workspaceStorage: WorkspaceStorage? {
//        get {
//            guard !name.isEmpty && !repositoryURL.isEmpty else { return nil }
//            if let cachedWorkspaceStorage = cachedWorkspaceStorage {
//                return cachedWorkspaceStorage
//            }
////            guard let repo = repository, repo.isWorkspaceInitialized, let directoryURL = directoryURL else {
//            guard let directoryURL = directoryURL else {
//                return nil
//            }
//            let workspaceStorage = WorkspaceStorage(url: directoryURL)
//            workspaceStorage.onDirectoryChange { url in
////                Task { [weak self] in try await self?.loadFromWorkspace() }
//            }
////            Task { [weak self] in try await self?.loadFromWorkspace() }
//            cachedWorkspaceStorage = workspaceStorage
//            return workspaceStorage
//        }
//    }
    
    private var cancellables = Set<AnyCancellable>()
    
    public var directoryURL: URL? {
        guard let package = package else { return nil }
        var baseURL = package.directoryURL
        for component in Self.extensionsPathComponents {
            baseURL.append(component: component, directoryHint: .isDirectory)
        }
        return baseURL
    }
    
    var buildResultPageURL: URL? {
        guard let package = package, !name.isEmpty else { return nil }
        return URL(string: "codekit://codekit/extensions/")?.appending(component: "\(name)-\(package.id.uuidString.prefix(6))")
    }
    
    public var buildDirectoryURL: URL? {
        return directoryURL?.appending(component: ".build", directoryHint: .isDirectory)
    }
    
    public var desiredBuildResultStorageURL: URL? {
        guard let desiredBuildHash = desiredBuildHash else { return nil }
        return buildResultStorageURL(forBuildHash: desiredBuildHash)
    }
    
    public var latestBuildResultStorageURL: URL? {
        guard let latestBuildHashAvailable = latestBuildHashAvailable else { return nil }
        return buildResultStorageURL(forBuildHash: latestBuildHashAvailable)
    }
    
    public func buildResultStorageURL(forBuildHash buildHash: String) -> URL? {
        return buildDirectoryURL?.appending(component: "\(name)-\(buildHash).html")
    }
    
    enum CodeExtensionError: Error {
        case unknownError
    }
    public struct SourcePackage {
        public struct Source {
            public var language: String
            public let content: String
            
            init(language: String, content: String) {
                self.language = language
                self.content = content
            }
                
            init?(scriptFileURL: URL) {
//                if scriptFileURL.pathExtension == "js" {
//                    do {
//                        for try await line in scriptFileURL.lines {
//                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
//                            if trimmed == "/* @flow */" || trimmed == "// @flow" {
//                                language = "flow"
//                                content = try String(contentsOfFile: scriptFileURL.path())
//                                return
//                            }
//                            if !(trimmed.isEmpty || trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasSuffix( "*/")) {
//                                break
//                            }
//                        }
//                    } catch { }
//                }
                if scriptFileURL.isFileURL, let language = scriptFileExtensions[scriptFileURL.pathExtension] {
                    do {
                        let content = try String(contentsOfFile: scriptFileURL.standardizedFileURL.path(percentEncoded: false), encoding: .utf8)
                        self = Source(language: language, content: content)
                        return
                    } catch { return nil }
                }
                return nil
            }
            
            init?(styleFileURL: URL) {
                if styleFileURL.isFileURL, let language = styleFileExtensions[styleFileURL.pathExtension] {
                    do {
                        let content = try String(contentsOfFile: styleFileURL.standardizedFileURL.path(percentEncoded: false), encoding: .utf8)
                        self = Source(language: language, content: content)
                        return
                    } catch { return nil }
                }
                return nil
            }
            
            init?(markupFileURL: URL) {
                if markupFileURL.isFileURL, let language = markupFileExtensions[markupFileURL.pathExtension] {
                    do {
                        let content = try String(contentsOfFile: markupFileURL.standardizedFileURL.path(percentEncoded: false), encoding: .utf8)
                        self = Source(language: language, content: content)
                        return
                    } catch { return nil }
                }
                return nil
            }
        }
        
        public let name: String
        public let markup: Source?
        public let style: Source?
        public let script: Source
    }
    
    public override init() {
        super.init()
        
//        name.publisher
//            .sink { _ in
//                Task { @MainActor [weak self] in
////                    self?.cachedWorkspaceStorage = nil
//                    try? await self?.refreshBuildHash()
////                    buildHash =
//                }
//            }
//            .store(in: &cancellables)
    }
    
//    @MainActor
//    var isWorkspaceInitialized: Bool {
//        guard let repo = repository else { return false }
//        return (repo.gitTracks.count > 0 || !repo.branch.isEmpty) && !name.isEmpty && cachedWorkspaceStorage != nil
//    }
    
    @MainActor
    func removeAllExtensionBuildsFromStorage(excludingBuildHash: String? = nil) async throws {
        guard !name.isEmpty, let buildDirectoryURL = buildDirectoryURL, let workspaceStorage = package?.repository().workspaceStorage else {
            throw CodeExtensionError.unknownError
        }
        let contents = try await workspaceStorage.contentsOfDirectory(at: buildDirectoryURL)
        for path in contents {
            let fileName = path.deletingPathExtension().lastPathComponent
            if path.isFileURL, path.lastPathComponent.hasSuffix(".html"), let lastIndex = fileName.lastIndex(of: "-"), String(fileName[..<lastIndex]) == name {
                let existingBuildHash = String(fileName[lastIndex...])
                if existingBuildHash != excludingBuildHash {
                    try await workspaceStorage.removeItem(at: path)
                }
            }
        }
    }
    
    @MainActor
    func createBuildDirectoryIfNeeded() async throws -> URL {
        guard let buildDirectoryURL = buildDirectoryURL, let workspaceStorage = package?.repository().workspaceStorage else {
            throw CodeExtensionError.unknownError
        }
        if try await !workspaceStorage.fileExists(at: buildDirectoryURL) {
            try await workspaceStorage.createDirectory(at: buildDirectoryURL, withIntermediateDirectories: true)
        }
        return buildDirectoryURL
    }
    
    @MainActor
    public func readSources() async throws -> CodeExtension.SourcePackage {
        guard let directoryURL = directoryURL, let workspaceStorage = package?.repository().workspaceStorage else {
            throw CodeExtensionError.unknownError
        }
        let candidateURLs = try await workspaceStorage.contentsOfDirectory(at: directoryURL)
        let targetURLs = candidateURLs
            .filter {
                return $0.deletingPathExtension().lastPathComponent == name
            }
        guard let script = targetURLs.compactMap({
            CodeExtension.SourcePackage.Source(scriptFileURL: $0)
        }).first else {
            throw CodeExtensionError.unknownError
        }
        let style = targetURLs.compactMap { CodeExtension.SourcePackage.Source(styleFileURL: $0) }.first
        let markup = targetURLs.compactMap { CodeExtension.SourcePackage.Source(markupFileURL: $0) }.first
        
        return CodeExtension.SourcePackage(
            name: name,
            markup: markup,
            style: style,
            script: script)
    }

    @MainActor
    public func store(buildResultHTML: String, forSources sourcePackage: CodeExtension.SourcePackage) async throws -> URL {
        let buildDirectoryURL = try await createBuildDirectoryIfNeeded()
        let buildHash = try await Self.buildHash(sourcePackage: sourcePackage)
        guard !name.isEmpty, let workspaceStorage = package?.repository().workspaceStorage, let resultData = buildResultHTML.data(using: .utf8), let storageURL = buildResultStorageURL(forBuildHash: buildHash) else {
            throw CodeExtensionError.unknownError
        }
        try await workspaceStorage.write(at: storageURL, content: resultData, atomically: true, overwrite: true)
        try await refreshBuildStatus()
        try await removeAllExtensionBuildsFromStorage(excludingBuildHash: buildHash)
        return buildDirectoryURL
    }
    
    @MainActor
    public func refreshBuildStatus() async throws {
        guard let workspaceStorage = package?.repository().workspaceStorage else {
            safeWrite(self) { _, codeExtension in
                codeExtension.desiredBuildHash = nil
                codeExtension.latestBuildHashAvailable = nil
            }
            return
        }
 
        let sources = try await readSources()
        let buildHash = try await Self.buildHash(sourcePackage: sources)
        safeWrite(self) { _, codeExtension in
            codeExtension.desiredBuildHash = buildHash
        }
        
        if let storageURL = buildResultStorageURL(forBuildHash: buildHash) {
            let buildExists = try await workspaceStorage.fileExists(at: storageURL)
            if buildExists {
                safeWrite(self) { _, codeExtension in
                    codeExtension.latestBuildHashAvailable = buildHash
                }
            } else if let latestBuildHashAvailable = latestBuildHashAvailable, let oldStorageURL = buildResultStorageURL(forBuildHash: latestBuildHashAvailable) {
                let oldBuildExists = try await workspaceStorage.fileExists(at: oldStorageURL)
                if !oldBuildExists {
                    safeWrite(self) { _, codeExtension in
                        codeExtension.latestBuildHashAvailable = nil
                    }
                }
            } else {
                safeWrite(self) { _, codeExtension in
                    codeExtension.latestBuildHashAvailable = nil
                }
            }
        }
    }
    
    @MainActor
    public func loadLatestAvailableBuildResult() async throws -> (Data, URL) {
        guard let workspaceStorage = package?.repository().workspaceStorage, let buildResultStorageURL = latestBuildResultStorageURL, let buildResultPageURL = buildResultPageURL else {
            throw CodeExtensionError.unknownError
        }
        let resultData = try await workspaceStorage.contents(at: buildResultStorageURL)
        return (resultData, buildResultPageURL)
    }
    
    @MainActor
    private static func buildHash(sourcePackage: SourcePackage) async throws -> String {
        var hasher = SHA256()
        for str in [
            sourcePackage.name,
            sourcePackage.script.language,
            sourcePackage.script.content,
            sourcePackage.markup?.language,
            sourcePackage.markup?.content,
            sourcePackage.style?.language,
            sourcePackage.style?.content,
            sourcePackage.style?.content,
            Bundle.main.appVersionLong,
            Bundle.main.appBuild,
        ].compactMap({ $0 }) {
            if let data = str.data(using: .utf8, allowLossyConversion: true) {
                hasher.update(data: data)
            }
        }
        return String(hasher.finalize().hexString().prefix(12))
//
//        let buildDirectoryURL = try await createBuildDirectoryIfNeeded()
//        let storageURL = buildDirectoryURL.appending(component: name + ".html")
//        guard let workspaceStorage = package?.repository().workspaceStorage, try await workspaceStorage.fileExists(at: storageURL) else {
//            buildHash = nil
//            return
//        }
//        buildHash = try getSHA256(forFile: storageURL)
    }
    
    @MainActor
    public static func isValidExtension(fileURL: URL) -> Bool {
        guard fileURL.isFileURL else { return false }
        let pathExtension = fileURL.pathExtension
        return scriptFileExtensions.contains(where: { $0.key == pathExtension }) || styleFileExtensions.contains(where: { $0.key == pathExtension }) || markupFileExtensions.contains(where: { $0.key == pathExtension })
    }
    
    enum CodingKeys: CodingKey {
        case id
        case repositoryURL
        case name
//        case package
        case modifiedAt
        case isDeleted
    }
}

extension Bundle {
    var appVersionLong: String    { getInfo("CFBundleShortVersionString") }
    var appBuild: String          { getInfo("CFBundleVersion") }
    //var appVersionShort: String { getInfo("CFBundleShortVersion") }
    
    private func getInfo(_ str: String) -> String {
        infoDictionary?[str] as? String ?? "UNKNOWN-VERSION"
    }
}

fileprivate let scriptFileExtensions = [
    "js": "javascript",
    "ts": "typescript",
//    "": "babel",
//    "": "sucrase",
    "jsx": "jsx",
    "tsx": "tsx",
    //react-native
    //react-native-tsx
    "vue": "vue",
    "vue3": "vue",
    "vue2": "vue2",
    "svelte": "svelte",
//    "": "stencil",
//    "": "solid",
//    "": "solid-tsx",
//    "": "riot",
//    "": "malina",
//    "": "coffeescript",
    "ls": "livescript",
    "civet": "civet",
    "clio": "clio",
    "imba": "imba",
    "res": "rescript",
    "re": "reason",
    "ml": "ocaml",
//    "py": "python",
    "py": "pyodide",
    "r": "r",
    "rb": "ruby",
    "go": "go",
    "php": "php",
    "cpp": "cpp",
    "c": "clang",
    "pl": "perl",
    "lua": "lua",
    "tl": "teal",
    "fnl": "fennel",
    "jl": "julia",
    "scm": "scheme",
    "lisp": "commonlisp",
    "cljs": "clojurescript",
    "tcl": "tcl",
//    "": "assemblyscript",
    "wat": "wat",
//    "sql": "sql",
//    "": "prolog",
    "block": "blockly",
]

fileprivate let markupFileExtensions = [
    "htm": "html",
    "html": "html",
    "md": "markdown",
    "mdx": "mdx",
    "astro": "astro",
    "pug": "pug",
    "adoc": "asciidoc",
    "haml": "haml",
    "mustache": "mustache",
    "handlebars": "handlebars",
    "ejs": "ejs",
    "eta": "eta",
    "njk": "nunjucks",
    "liquid": "liquid",
    "dot": "dot",
    "twig": "twig",
//    "": "art-template",
//    "": "mjml",
    "diagrams": "diagrams",
    "diagram": "diagrams",
    "rte": "richtext",
    "rte.html": "richtext",
]

fileprivate let styleFileExtensions = [
    "css": "css",
    "scss": "scss",
    "sass": "sass",
    "less": "less",
    "styl": "stylus",
    "stylis": "stylis",
//    "": "tailwindcss",
//    "": "windicss",
//    "": "unocss",
//    "": "tokencss",
//    "": "lightningcss",
//    "": "cssmodules",
]
