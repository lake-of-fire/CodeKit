import SwiftUI
import Combine
import RealmSwift
import BigSyncKit
import RealmSwiftGaps
import SwiftGit2

public class CodeExtension: Object, UnownedSyncableObject, ObjectKeyIdentifiable  {
    /// Do not prepend dot. Checks both dot-prepended and as-is automatically and in that order.
    public static var extensionsPathComponents = [String]()
    
    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted(indexed: true) public var repositoryURL = ""
    
    @Persisted public var name = ""
    @Persisted public var repository: PackageRepository?
    
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    public var needsSyncToServer: Bool { false }
    
    @MainActor private var cachedWorkspaceStorage: WorkspaceStorage? = nil
    @MainActor public var workspaceStorage: WorkspaceStorage? {
        get {
            if let cachedWorkspaceStorage = cachedWorkspaceStorage {
                return cachedWorkspaceStorage
            }
            guard let repo = repository, repo.isWorkspaceInitialized, let directoryURL = directoryURL else { return nil }
            let workspaceStorage = WorkspaceStorage(url: directoryURL)
            workspaceStorage.onDirectoryChange { url in
//                Task { [weak self] in try await self?.loadFromWorkspace() }
            }
//            Task { [weak self] in try await self?.loadFromWorkspace() }
            cachedWorkspaceStorage = workspaceStorage
            return workspaceStorage
        }
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    public var directoryURL: URL? {
        guard let repo = repository else { return nil }
        var baseURL = repo.directoryURL
        for component in Self.extensionsPathComponents {
            baseURL.append(component: component, directoryHint: .isDirectory)
        }
        return baseURL.appending(component: name)
    }
    
    enum CodeExtensionError: Error {
        case unknownError
    }
    public struct ExtensionPackage {
        public struct Source {
            public var language: String
            public let content: String
            
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
                if let language = scriptFileExtensions[scriptFileURL.pathExtension] {
                    self.language = language
                    do {
                        content = try String(contentsOfFile: scriptFileURL.path())
                        return
                    } catch { return nil }
                }
                return nil
            }
            
            init?(styleFileURL: URL) {
                if let language = styleFileExtensions[styleFileURL.pathExtension] {
                    self.language = language
                    do {
                        content = try String(contentsOfFile: styleFileURL.path())
                        return
                    } catch { return nil }
                }
                return nil
            }
            
            init?(markupFileURL: URL) {
                if let language = markupFileExtensions[markupFileURL.pathExtension] {
                    self.language = language
                    do {
                        content = try String(contentsOfFile: markupFileURL.path())
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
        
        name.publisher
            .sink { _ in
                Task { @MainActor [weak self] in
                    self?.cachedWorkspaceStorage = nil
                }
            }
            .store(in: &cancellables)
    }
    
    @MainActor
    var isWorkspaceInitialized: Bool {
        guard let repo = repository else { return false }
        return (repo.gitTracks.count > 0 || !repo.branch.isEmpty) && !name.isEmpty && cachedWorkspaceStorage != nil
    }
    
    @MainActor
    public func createBuildDirectoryIfNeeded() async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            guard let directoryURL = directoryURL else {
                continuation.resume(throwing: CodeExtensionError.unknownError)
                return
            }
            let buildURL = directoryURL.appending(component: "build")
            workspaceStorage?.createDirectory(at: buildURL, withIntermediateDirectories: false) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: buildURL)
                }
            }
        }
    }
    
    @MainActor
    public func readSources() async throws -> CodeExtension.ExtensionPackage {
//        let targetURLs = urls.filter { $0.deletingPathExtension().lastPathComponent == name }
        guard let directoryURL = directoryURL, let workspaceStorage = workspaceStorage else {
            throw CodeExtensionError.unknownError
        }
        
        let targetURLs = try await workspaceStorage.contentsOfDirectory(at: directoryURL)
            .filter {
                $0.deletingPathExtension().lastPathComponent == name
            }
        
        guard let script = targetURLs.compactMap({ CodeExtension.ExtensionPackage.Source(scriptFileURL: $0) }).first else {
            throw CodeExtensionError.unknownError
        }
        let style = targetURLs.compactMap { CodeExtension.ExtensionPackage.Source(styleFileURL: $0) }.first
        let markup = targetURLs.compactMap { CodeExtension.ExtensionPackage.Source(markupFileURL: $0) }.first
        
        return CodeExtension.ExtensionPackage(
            name: name,
            markup: markup,
            style: style,
            script: script)
    }

    enum CodingKeys: CodingKey {
        case id
        case repositoryURL
        case name
        case repository
        case modifiedAt
        case isDeleted
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
