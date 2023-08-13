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
//        try? await repos
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
                        buildIfNeeded(packages: packages, forceBuild: true)
                    }
                case .update(let results, let deletions, let insertions, let modifications):
                    let ref = ThreadSafeReference(to: results)
                    Task { @MainActor [weak self] in
                        guard let self = self, let results = try? await realm.resolve(ref) else { return }
                        let packages = Array(results)
                        refreshRepositories(packages: packages)
                        buildIfNeeded(packages: Set(insertions + modifications).map { results[$0] })
                    }
                case .error(let error):
                    print(error)
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
    func buildIfNeeded(packages: [CodePackage], forceBuild: Bool = false) {
        buildTask?.cancel()
        buildTask = Task { @MainActor [weak self] in
            for package in packages {
                try? await self?.buildIfNeeded(package: package, forceBuild: forceBuild)
            }
        }
    }
    
    @MainActor
    func buildIfNeeded(package: CodePackage, forceBuild: Bool = false) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let ref = ThreadSafeReference(to: package)
            let repo = package.repository()
            repo.cloneOrPullIfNeeded { [weak self] error in
                if let error = error {
                    print(error)
                    continuation.resume(throwing: error)
                    return
                }
                Task { [weak self] in
                    do {
                        try Task.checkCancellation()
                    } catch {
                        continuation.resume(throwing: CodeCIError.unknownError)
                        return
                    }
                    
                    do {
                        guard let self = self, let package = try await realm.resolve(ref) else {
                            continuation.resume(throwing: CodeCIError.unknownError)
                            return
                        }

                        if package.buildRequested {
                            safeWrite(package) { _, package in
                                package.buildRequested = false
                            }
                        } else if !forceBuild {
                            continuation.resume(returning: ())
                            return
                        }
                        
                        let names = try await repo.extensionNamesFromFiles()
                        for extensionName in names {
                            guard let codeExtension = package.codeExtensions.where({ $0.name == extensionName && !$0.isDeleted }).first else {
                                print("Warning: Couldn't find CodeExtension matching \(repo.name) \(extensionName)")
                                continue
                            }
                            
                            try await build(codeExtension: codeExtension)
                        }
                        continuation.resume(returning: ())
                    } catch {
                        print(error)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    @MainActor
    func build(codeExtension: CodeExtension) async throws {
                    //                codeCoreViewModel
        let sourcePackage = try await codeExtension.readSources()
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
        let storedURL = try await codeExtension.store(buildResultHTML: resultPageHTML)
    }
}
