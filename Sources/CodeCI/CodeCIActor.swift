import SwiftUI
import WebKit
import RealmSwift
import RealmSwiftGaps
import OPML
import CodeCore
import Combine

public actor CodeCIActor: ObservableObject {
    @MainActor public var codeCoreViewModel = CodeCoreViewModel()
    
    private var configuration: Realm.Configuration
    private var realm: Realm {
        get async throws {
            try await Realm(configuration: configuration, actor: self)
        }
    }
    
    private var packages: Results<CodePackage> {
        get async throws {
            try await realm.objects(CodePackage.self).where({ !$0.isDeleted && $0.isEnabled })
        }
    }
    
    private var codeExtensions: Results<CodeExtension> {
        get async throws {
            try await realm.objects(CodeExtension.self).where({ !$0.isDeleted })
        }
    }
    
//    @MainActor @Published private var activeRepos:
    
    @MainActor @Published var repositories = [CodePackageRepository]()
    
    private var cancellables = Set<AnyCancellable>()
    @MainActor private var buildTask: Task<(), Error>?
    
    enum CodeCIError: Error {
        case unknownError
    }
    
    public init(realmConfiguration: Realm.Configuration) {
        configuration = realmConfiguration
        
        Task {
            let (liveCodesData, liveCodesURL) = loadLiveCodes()
            await codeCoreViewModel.load(
                htmlData: liveCodesData,
                baseURL: liveCodesURL)
            await wireRepos()
        }
    }
    
    private func wireRepos() async {
        try? await packages
            .changesetPublisher
            .receive(on: DispatchQueue.main)
            .sink { changeset in
                switch changeset {
                case .initial(let results):
                    let ref = ThreadSafeReference(to: results)
                    Task { @MainActor [weak self] in
                        guard let self = self, let results = try? await realm.resolve(ref) else { return }
                        let packages = Array(results)
                        refreshRepositories(packages: packages)
                        requestBuildIfNeeded(packages: packages, forceBuild: true)
                    }
                case .update(let results, let deletions, let insertions, let modifications):
                    let ref = ThreadSafeReference(to: results)
                    Task { @MainActor [weak self] in
                        guard let self = self, let results = try? await realm.resolve(ref) else { return }
                        let packages = Array(results)
                        refreshRepositories(packages: packages)
                        requestBuildIfNeeded(packages: packages, forceBuild: true)
//                        buildIfNeeded(packages: Set(insertions + modifications).map { results[$0] })
                    }
                case .error(let error):
                    print("Error: \(error)")
                }
            }
            .store(in: &cancellables)
        
        try? await codeExtensions
            .where { !$0.buildRequested }
            .changesetPublisher(keyPaths: ["name", "package", "isDeleted"])
            .receive(on: DispatchQueue.main)
            .sink { changeset in
                switch changeset {
                case .initial(let results):
                    Task { @MainActor [weak self] in
                        try await self?.requestBuildsIfNeeded()
                    }
                case .update(let results, let deletions, let insertions, let modifications):
                    Task { @MainActor [weak self] in
                        try await self?.requestBuildsIfNeeded()
                    }
                case .error(let error):
                    print("Error: \(error)")
                }
            }
            .store(in: &cancellables)
        
        try? await codeExtensions
            .where { $0.buildRequested }
            .changesetPublisher(keyPaths: ["buildRequested"])
            .receive(on: DispatchQueue.main)
            .sink { changeset in
                switch changeset {
                case .initial(let results):
                    let ref = ThreadSafeReference(to: results)
                    Task { @MainActor [weak self] in
                        guard let self = self, let results = try? await realm.resolve(ref) else { return }
                        for codeExtension in Array(results) {
                            if codeExtension.buildRequested {
                                try await build(codeExtension: codeExtension)
                            }
                        }
                    }
                case .update(let results, let deletions, let insertions, let modifications):
                    let ref = ThreadSafeReference(to: results)
                    Task { @MainActor [weak self] in
                        guard let self = self, let results = try? await realm.resolve(ref) else { return }
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
    private func refreshRepositories(packages: [CodePackage]) {
        // TODO: Only refresh/remove initial/added/modified/removed ones from wireRepos
        repositories = packages.map { $0.repository() }
    }
    
    @MainActor
    func requestBuildIfNeeded(packages: [CodePackage], forceBuild: Bool = false) {
        buildTask?.cancel()
        buildTask = Task { @MainActor [weak self] in
            for package in packages {
                try? await self?.requestBuildIfNeeded(package: package, forceBuild: forceBuild)
            }
        }
    }
    
    @MainActor
    func requestBuildsIfNeeded() async throws {
        let codeExtensions = try await codeExtensions
        for codeExtension in Array(codeExtensions) {
            try await requestBuildIfNeeded(codeExtension: codeExtension)
        }
    }
    
    @MainActor
    func requestBuildIfNeeded(package: CodePackage, forceBuild: Bool = false) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let ref = ThreadSafeReference(to: package)
            let repo = package.repository()
            
            repo.cloneOrPullIfNeeded { [weak self] error in
                if let error = error {
                    print("Error: \(error)")
                    continuation.resume(throwing: error)
                    return
                }
                
                Task { [weak self] in
                    do { try Task.checkCancellation() } catch {
                        continuation.resume(throwing: CodeCIError.unknownError)
                        return
                    }
                    
                    do {
                        guard let self = self, let package = try await realm.resolve(ref) else {
                            continuation.resume(throwing: CodeCIError.unknownError)
                            return
                        }
                        
                        let names = try await repo.extensionNamesFromFiles()
                        for extensionName in names {
                            guard let codeExtension = package.codeExtensions.where({ $0.name == extensionName && !$0.isDeleted }).first else {
                                print("Warning: Couldn't find CodeExtension matching \(repo.name) \(extensionName)")
                                continue
                            }
                            
                            if forceBuild {
                                safeWrite(codeExtension) { _, codeExtension in
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
    func requestBuildIfNeeded(codeExtension: CodeExtension) async throws {
        try await codeExtension.refreshBuildStatus()
        if codeExtension.desiredBuildHash != codeExtension.latestBuildHashAvailable && !codeExtension.buildRequested && (codeExtension.package?.isEnabled ?? false) && !(codeExtension.package?.isDeleted ?? true) {
            safeWrite(codeExtension) { _, codeExtension in
                codeExtension.buildRequested = true
            }
        }
    }
    
    @MainActor
    func build(codeExtension: CodeExtension) async throws {
        let sourcePackage = try await codeExtension.readSources()
        
        safeWrite(codeExtension) { _, codeExtension in
            codeExtension.isBuilding = true
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
                throw CodeCIError.unknownError
            }
            _ = try await codeExtension.store(buildResultHTML: resultPageHTML, forSources: sourcePackage)
            safeWrite(codeExtension) { _, codeExtension in
                codeExtension.buildRequested = false
                codeExtension.isBuilding = false
            }
        } catch {
            safeWrite(codeExtension) { _, codeExtension in
                codeExtension.isBuilding = false
            }
            throw error
        }
        try await codeExtension.refreshBuildStatus()
    }
}
