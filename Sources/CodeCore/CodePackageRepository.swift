import SwiftUI
import Combine
import RealmSwift
import BigSyncKit
import RealmSwiftGaps
import SwiftGit2
import CryptoKit

public enum CodeError: Error {
    case unknownError
}

public class CodePackageRepository: ObservableObject, GitRepositoryProtocol {
    public let package: CodePackage
    /// Set if using this `CodePackageRepository` instance for triggering builds.
    public let codeCoreViewModel: CodeCoreViewModel?
    
    @Published public var gitServiceIsBusy = false
    @Published public var availableCheckoutDestination: [CheckoutDestination] = []
    @Published public var gitTracks: [URL: Diff.Status] = [:]
    @Published public var remotes: [Remote] = []
    @Published public var remoteBranches: [Branch] = []
    @Published public var localBranches: [Branch] = []
    @Published public var tags: [TagReference] = []
    @Published public var indexedResources: [URL: Diff.Status] = [:]
    @Published public var workingResources: [URL: Diff.Status] = [:]
    @Published public var statusDescription: String = ""
    @Published public var branch: String = ""
//    @Published public var remote: String = ""
    @Published public var commitMessage: String = ""
    @Published public var isSyncing: Bool = false
    @Published public var aheadBehind: (Int, Int)? = nil
    
    @MainActor public lazy var workspaceStorage: WorkspaceStorage? = {
        let workspaceStorage = WorkspaceStorage(url: directoryURL, isDirectoryMonitored: true)
        if codeCoreViewModel != nil {
            Task { @MainActor in
                createAndUpdateDirectoryIfNeeded { error in
                    Task { @MainActor [weak self] in
                        guard let self = self, error == nil else {
                            print(error?.localizedDescription ?? "")
                            return
                        }
                        let dir = directoryURL
                        await workspaceStorage.updateDirectory(url: dir) //.standardizedFileURL)
                        workspaceStorage.onDirectoryChange { url in
                            Task { [weak self] in
                                guard let self = self else { return }
                                try await loadRepository()
                                safeWrite(package, configuration: package.realm?.configuration) { _, package in
                                    for ext in package.codeExtensions.where({ !$0.isDeleted }) {
                                        ext.buildRequested = true
                                    }
                                }
                            }
                        }
                        try await loadRepository()
                    }
                }
            }
        }
        return workspaceStorage
    }()
    
    private var cancellables = Set<AnyCancellable>()
    
    public var name: String {
        return package.name
    }
    
    public var repositoryURL: URL? {
        return URL(string: package.repositoryURL)
    }
    
    public var directoryURL: URL {
        return package.directoryURL
    }
    
    @MainActor
    public var isWorkspaceInitialized: Bool {
        guard let workspaceStorage = workspaceStorage else { return false }
        return workspaceStorage.currentDirectory.url == directoryURL.absoluteString && (gitTracks.count > 0 || !branch.isEmpty)
    }

    public init(package: CodePackage, codeCoreViewModel: CodeCoreViewModel?) {
        self.package = package.isFrozen ? package : package.freeze()
        self.codeCoreViewModel = codeCoreViewModel
        
        Task { @MainActor [weak self] in
            if codeCoreViewModel != nil {
                _ = self?.workspaceStorage
                self?.wireBuilds()
            }
        }
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
    
}

public extension CodePackageRepository {
    // MARK: File and git management
    
    enum CodePackageError: Error {
        case repositoryLoadingFailed
        case gitRepositoryInitializationError
    }
    
    @MainActor
    private func loadRepository() async throws {
        let extensionNames = try await extensionNamesFromFiles()
        let realm = try! await Realm()
        guard let package = realm.object(ofType: CodePackage.self, forPrimaryKey: package.id), let realm = package.realm, let repositoryURL = repositoryURL?.absoluteString else { return }
        let allExisting = realm.objects(CodeExtension.self).where { $0.repositoryURL == repositoryURL && !$0.isDeleted }
        for ext in allExisting {
            guard extensionNames.contains(ext.name) else {
                try! realm.write {
                    ext.isDeleted = true
                }
                try await removeAllExtensionBuildsFromStorage(codeExtension: ext)
                return
            }
            
            if ext.package != package {
                safeWrite(ext, configuration: package.realm?.configuration) { _, ext in
                    ext.package = package
                }
            }
        }
        
        let existingNames = Set(allExisting.map { $0.name })
        let newNames = extensionNames.subtracting(existingNames)
        if !newNames.isEmpty {
            try! realm.write {
                for name in newNames {
                    realm.create(CodeExtension.self, value: [
                        "id": CodeExtension.makeCompoundKey(repositoryURL: repositoryURL, name: name),
                        "repositoryURL": repositoryURL,
                        "name": name,
                        "package": package,
                    ] as [String: Any], update: .modified)
                }
            }
        }
    }
    
    @MainActor
    func listExtensionFiles() async throws -> [URL] {
        await updateGitRepositoryStatus()
        
        guard let workspaceStorage = workspaceStorage, isWorkspaceInitialized, let currentDirectory = URL(string: workspaceStorage.currentDirectory.url) else {
            throw CodePackageError.repositoryLoadingFailed
        }
        
        var urls = [URL]()
        for prefix in [".", ""] {
            var extensionsDir = currentDirectory
            var comps = CodeExtension.extensionsPathComponents
            if !comps.isEmpty {
                let first = comps.removeFirst()
                comps = [(prefix + first)] + comps
            }
            for comp in CodeExtension.extensionsPathComponents {
                extensionsDir.append(component: comp, directoryHint: .isDirectory)
            }
            
            do {
                urls = try await workspaceStorage.contentsOfDirectory(at: extensionsDir)
                    .filter { Self.isValidExtension(fileURL: $0) }
            } catch {
                continue
            }
            if !urls.isEmpty {
                break
            }
        }
        return urls
    }
    
    @MainActor
    func extensionNamesFromFiles() async throws -> Set<String> {
        let urls = try await listExtensionFiles()
        return Set<String>(urls.map { $0.deletingPathExtension().lastPathComponent })
    }
    
    @MainActor
    private func createAndUpdateDirectoryIfNeeded(completionHandler: @escaping (Error?) -> Void) {
        guard !name.isEmpty else {
            completionHandler(nil)
            return
        }
        let dir = directoryURL
        Task { @MainActor in
            guard let workspaceStorage = workspaceStorage else { return }
            if try await !workspaceStorage.fileExists(at: dir) {
                workspaceStorage.createDirectory(at: dir, withIntermediateDirectories: true) { maybeError in
                    Task { @MainActor [weak self] in
                        await self?.workspaceStorage?.updateDirectory(url: dir)
                        completionHandler(maybeError)
                    }
                }
            } else {
                await workspaceStorage.updateDirectory(url: dir)
                completionHandler(nil)
            }
        }
    }
    
    @MainActor
    func cloneOrPullIfNeeded(completionHandler: @escaping (Error?) -> Void) {
        createAndUpdateDirectoryIfNeeded { error in
            Task { @MainActor [weak self] in
                guard let self = self, error == nil, let workspaceStorage = workspaceStorage, let repositoryURL = repositoryURL else {
                    print(error?.localizedDescription ?? "")
                    completionHandler(error)
                    return
                }
                
                workspaceStorage.gitServiceProvider?.loadDirectory(url: directoryURL.standardizedFileURL)
                
                await updateGitRepositoryStatus()
                    
                do {
                    if isWorkspaceInitialized {
                        try await pull()
                        completionHandler(nil)
                    } else {
                        try await workspaceStorage.gitServiceProvider?.clone(
                            from: repositoryURL,
                            to: directoryURL,
                            progress: nil)
                        workspaceStorage.gitServiceProvider?.loadDirectory(url: directoryURL.standardizedFileURL)
                        try await loadRepository()
                        await updateGitRepositoryStatus()
                        completionHandler(nil)
                    }
                } catch {
                    print(error)
                    completionHandler(error)
                }
            }
        }
    }
    
    @MainActor
    func pull() async throws {
        guard let serviceProvider = workspaceStorage?.gitServiceProvider else { throw CodeError.unknownError }
        let head = try await serviceProvider.head()
        guard let localBranch = head as? Branch else {
            throw NSError(descriptionKey: "Repository is in detached mode")
        }
        let remotes = try await serviceProvider.remotes()
        guard let origin = remotes.first(where: { $0.name == "origin" }) else {
            throw NSError(descriptionKey: "Repository remote 'origin' not found")
        }
        guard let remoteBranch = try await serviceProvider.remoteBranches().first(where: {
            $0.name == origin.name + "/" + localBranch.name })
        else {
            throw NSError(descriptionKey: "Repository is in detached mode")
        }
        
        try await serviceProvider.pull(branch: remoteBranch, remote: origin)
        
        await updateGitRepositoryStatus()
//        return try await withCheckedThrowingContinuation { continuation in
//           workspaceStorage?.gitServiceProvider?.fetch(error: {
//                print($0.localizedDescription)
//                continuation.resume(throwing: $0)
//            }) {
//                Task { @MainActor [weak self] in
//                    guard let self = self else {
//                        continuation.resume(throwing: CodePackageError.repositoryLoadingFailed)
//                        return
//                    }
//                    try await gitStatus()
//
//                    workspaceStorage?.gitServiceProvider?.checkout(
//                        remoteBranchName: remote + "/" + branch,
////                        localBranchName: branch,
//                        detached: false,
//                        error: {
//                            print($0.localizedDescription)
//                            continuation.resume(throwing: $0)
//                        }) {
//                            Task { @MainActor [weak self] in
//                                try await self?.gitStatus()
//                                continuation.resume(returning: ())
//                            }
//                        }
//                }
//            }
//        }
    }
    
    func updateGitBranches() async throws {
        guard let gitServiceProvider = await workspaceStorage?.gitServiceProvider else { return }
        let remotes = try await gitServiceProvider.remotes()
        let remoteBranches = try await gitServiceProvider.remoteBranches()
        let localBranches = try await gitServiceProvider.localBranches()
        let tags = try await gitServiceProvider.tags()
        await MainActor.run {
            self.remotes = remotes
            self.remoteBranches = remoteBranches
            self.localBranches = localBranches
            self.tags = tags
        }
    }
}

public extension CodePackageRepository {
    // MARK: Builds
    
    private func wireBuilds() {
        guard let package = package.thaw() else { return }
        package.codeExtensions
            .where { !$0.buildRequested }
            .changesetPublisher(keyPaths: ["name", "package", "isDeleted"])
            .receive(on: DispatchQueue.main)
            .sink { changeset in
                switch changeset {
                case .initial(let results):
                    Task { @MainActor [weak self] in
                        try await self?.requestBuildsIfNeeded()
                        self?.refreshCodeExtensionDirectoryMonitors()
                    }
                case .update(let results, let deletions, let insertions, let modifications):
                    Task { @MainActor [weak self] in
                        try await self?.requestBuildsIfNeeded()
                        self?.refreshCodeExtensionDirectoryMonitors()
                    }
                case .error(let error):
                    print("Error: \(error)")
                }
            }
            .store(in: &cancellables)
        
        package.codeExtensions
            .where { $0.buildRequested }
            .changesetPublisher(keyPaths: ["buildRequested"])
            .receive(on: DispatchQueue.main)
            .print("###")
            .sink { changeset in
                switch changeset {
                case .initial(let results):
                    let ref = ThreadSafeReference(to: results)
                    Task { @MainActor [weak self] in
                        guard let self = self, let results = package.realm?.resolve(ref) else { return }
                        for codeExtension in Array(results) {
                            if codeExtension.buildRequested {
                                try await build(codeExtension: codeExtension)
                            }
                        }
                    }
                case .update(let results, let deletions, let insertions, let modifications):
                    let ref = ThreadSafeReference(to: results)
                    Task { @MainActor [weak self] in
                        guard let self = self, let results = package.realm?.resolve(ref) else { return }
                        for codeExtension in Array(results) {
                            if codeExtension.buildRequested {
                                try await build(codeExtension: codeExtension)
                            }
                        }
                    }
                case .error(let error):
                    print("Error: \(error)")
                }
            }
            .store(in: &cancellables)
    }
    
    @MainActor
    func requestBuildIfNeeded(forceBuild: Bool = false) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let ref = ThreadSafeReference(to: package)
            cloneOrPullIfNeeded { [weak self] error in
                if let error = error {
                    print("Error: \(error)")
                    continuation.resume(throwing: error)
                    return
                }
                
                Task { @MainActor [weak self] in
                    do { try Task.checkCancellation() } catch {
                        continuation.resume(throwing: CodeError.unknownError)
                        return
                    }
                    
                    do {
                        let realm = try await Realm()
                        guard let self = self, let package = realm.resolve(ref) else {
                            continuation.resume(throwing: CodeError.unknownError)
                            return
                        }
                        
                        let names = try await extensionNamesFromFiles()
                        for extensionName in names {
                            guard let codeExtension = package.codeExtensions.where({ $0.name == extensionName && !$0.isDeleted }).first else {
                                print("Warning: Couldn't find CodeExtension matching \(name) \(extensionName)")
                                continue
                            }
                            
                            if forceBuild {
                                safeWrite(codeExtension, configuration: package.realm?.configuration) { _, codeExtension in
                                    codeExtension.buildRequested = true
                                }
                            } else {
                                try await requestBuildIfNeeded(codeExtension: codeExtension)
                            }
                        }
                        continuation.resume(returning: ())
                    } catch {
                        print("Error: \(error)")
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    @MainActor
    func refreshCodeExtensionDirectoryMonitors() {
        guard let workspaceStorage = workspaceStorage else { return }
        for codeExtension in Array(package.codeExtensions) {
            guard let directoryURL = codeExtension.directoryURL else { continue }
            workspaceStorage.requestDirectoryUpdateAt(id: directoryURL.standardizedFileURL.absoluteString)
        }
    }
    
    @MainActor
    func requestBuildsIfNeeded() async throws {
        for codeExtension in Array(package.codeExtensions) {
            try await requestBuildIfNeeded(codeExtension: codeExtension)
        }
    }
    
    @MainActor
    func requestBuildIfNeeded(codeExtension: CodeExtension) async throws {
        try await refreshBuildStatus(codeExtension: codeExtension)
        if codeExtension.desiredBuildHash != codeExtension.latestBuildHashAvailable && !codeExtension.buildRequested && (codeExtension.package?.isEnabled ?? false) && !(codeExtension.package?.isDeleted ?? true) {
            safeWrite(codeExtension, configuration: package.realm?.configuration) { _, codeExtension in
                codeExtension.buildRequested = true
            }
        }
    }
    
    @MainActor
    func build(codeExtension: CodeExtension) async throws {
        print("### BUILD \(codeExtension.nameWithOwner)")
        guard let codeCoreViewModel = codeCoreViewModel else {
            print("No codeCoreViewModel on CodePackageRepository")
            return
        }
        let sourcePackage = try await readSources(codeExtension: codeExtension)
        
        safeWrite(codeExtension, configuration: package.realm?.configuration) { _, codeExtension in
            codeExtension.isBuilding = true
        }
        
        if let package = codeExtension.package {
            codeCoreViewModel.additionalAllowHosts = Array(package.allowHosts)
        } else {
            codeCoreViewModel.additionalAllowHosts.removeAll()
        }
        
        do {
            let resultPageHTML = try await codeCoreViewModel.callAsyncJavaScript(
            """
            return new Promise(resolve => {
                (async () => {
                    let result = await window.buildCode(
                        markupLanguage, markupContent,
                        styleLanguage, styleContent,
                        scriptLanguage, scriptContent);
                    resolve(result);
                })();
            });
            """,
            arguments: [
                "markupLanguage": sourcePackage.markup?.language ?? "html",
                "markupContent": sourcePackage.markup?.content ?? "",
                "styleLanguage": sourcePackage.style?.language ?? "css",
                "styleContent": sourcePackage.style?.content ?? "",
                "scriptLanguage": sourcePackage.script.language,
                "scriptContent": sourcePackage.script.content,
            ])
            guard let resultPageHTML = resultPageHTML as? String else {
                throw CodeError.unknownError
            }
            let fileChanged = try await store(codeExtension: codeExtension, buildResultHTML: resultPageHTML, forSources: sourcePackage)
            safeWrite(codeExtension, configuration: package.realm?.configuration) { _, codeExtension in
                codeExtension.buildRequested = false
                codeExtension.isBuilding = false
                if fileChanged {
                    codeExtension.lastBuiltAt = Date()
                }
            }
        } catch {
            safeWrite(codeExtension, configuration: package.realm?.configuration) { _, codeExtension in
                codeExtension.isBuilding = false
            }
            throw error
        }
        try await refreshBuildStatus(codeExtension: codeExtension)
    }
    
    @MainActor
    func removeAllExtensionBuildsFromStorage(codeExtension: CodeExtension, excludingBuildHash: String? = nil) async throws {
        guard !codeExtension.name.isEmpty, let buildDirectoryURL = codeExtension.buildDirectoryURL, let workspaceStorage = workspaceStorage else {
            throw CodeExtensionError.unknownError
        }
        let contents = try await workspaceStorage.contentsOfDirectory(at: buildDirectoryURL)
        for path in contents {
            let fileName = path.deletingPathExtension().lastPathComponent
            if path.isFileURL, path.lastPathComponent.hasSuffix(".html"), let lastIndex = fileName.lastIndex(of: "-"), String(fileName[..<lastIndex]) == codeExtension.name {
                let existingBuildHash = String(fileName[fileName.index(after: lastIndex)...])
                if existingBuildHash != excludingBuildHash {
                    try await workspaceStorage.removeItem(at: path)
                }
            }
        }
    }
    
    @MainActor
    func createBuildDirectoryIfNeeded(codeExtension: CodeExtension) async throws -> URL {
        guard let buildDirectoryURL = codeExtension.buildDirectoryURL, let workspaceStorage = workspaceStorage else {
            throw CodeExtensionError.unknownError
        }
        if try await !workspaceStorage.fileExists(at: buildDirectoryURL) {
            try await workspaceStorage.createDirectory(at: buildDirectoryURL, withIntermediateDirectories: true)
        }
        return buildDirectoryURL
    }
    
    @MainActor
    func readSources(codeExtension: CodeExtension) async throws -> SourcePackage {
        guard let directoryURL = codeExtension.directoryURL, let workspaceStorage = workspaceStorage else {
            throw CodeExtensionError.unknownError
        }
        let candidateURLs = try await workspaceStorage.contentsOfDirectory(at: directoryURL)
        let targetURLs = candidateURLs
            .filter {
                return $0.deletingPathExtension().lastPathComponent == codeExtension.name
            }
        guard let script = targetURLs.compactMap({
            SourcePackage.Source(scriptFileURL: $0)
        }).first else {
            throw CodeExtensionError.unknownError
        }
        let style = targetURLs.compactMap { SourcePackage.Source(styleFileURL: $0) }.first
        let markup = targetURLs.compactMap { SourcePackage.Source(markupFileURL: $0) }.first
        
        return SourcePackage(
            name: codeExtension.name,
            markup: markup,
            style: style,
            script: script)
    }

    /// Returns whether the file changed.
    @MainActor
    func store(codeExtension: CodeExtension, buildResultHTML: String, forSources sourcePackage: SourcePackage) async throws -> Bool {
        let buildDirectoryURL = try await createBuildDirectoryIfNeeded(codeExtension: codeExtension)
        let buildHash = try await Self.buildHash(sourcePackage: sourcePackage)
        guard !codeExtension.name.isEmpty, let workspaceStorage = workspaceStorage, let resultData = buildResultHTML.data(using: .utf8), let storageURL = codeExtension.buildResultStorageURL(forBuildHash: buildHash) else {
            throw CodeExtensionError.unknownError
        }
        if try await workspaceStorage.fileExists(at: storageURL) {
            let existingContent = try await workspaceStorage.contents(at: storageURL)
            if existingContent == resultData {
                return false
            }
        }
        try await workspaceStorage.write(at: storageURL, content: resultData, atomically: true, overwrite: true)
        try await refreshBuildStatus(codeExtension: codeExtension)
        try await removeAllExtensionBuildsFromStorage(codeExtension: codeExtension, excludingBuildHash: buildHash)
        return true
    }
    
    @MainActor
    func refreshBuildStatus(codeExtension: CodeExtension) async throws {
        guard let workspaceStorage = workspaceStorage else {
            safeWrite(codeExtension, configuration: package.realm?.configuration) { _, codeExtension in
                codeExtension.desiredBuildHash = nil
                codeExtension.latestBuildHashAvailable = nil
            }
            return
        }
 
        let sources = try await readSources(codeExtension: codeExtension)
        let buildHash = try await Self.buildHash(sourcePackage: sources)
        safeWrite(codeExtension, configuration: package.realm?.configuration) { _, codeExtension in
            codeExtension.desiredBuildHash = buildHash
        }
        
        if let storageURL = codeExtension.buildResultStorageURL(forBuildHash: buildHash) {
            let buildExists = try await workspaceStorage.fileExists(at: storageURL)
            if buildExists {
                safeWrite(codeExtension, configuration: package.realm?.configuration) { _, codeExtension in
                    codeExtension.latestBuildHashAvailable = buildHash
                }
            } else if let latestBuildHashAvailable = codeExtension.latestBuildHashAvailable, let oldStorageURL = codeExtension.buildResultStorageURL(forBuildHash: latestBuildHashAvailable) {
                let oldBuildExists = try await workspaceStorage.fileExists(at: oldStorageURL)
                if !oldBuildExists {
                    safeWrite(codeExtension, configuration: package.realm?.configuration) { _, codeExtension in
                        codeExtension.latestBuildHashAvailable = nil
                    }
                }
            } else {
                safeWrite(codeExtension, configuration: package.realm?.configuration) { _, codeExtension in
                    codeExtension.latestBuildHashAvailable = nil
                }
            }
        }
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
    static func isValidExtension(fileURL: URL) -> Bool {
        guard fileURL.isFileURL else { return false }
        let pathExtension = fileURL.pathExtension
        return scriptFileExtensions.contains(where: { $0.key == pathExtension }) || styleFileExtensions.contains(where: { $0.key == pathExtension }) || markupFileExtensions.contains(where: { $0.key == pathExtension })
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
