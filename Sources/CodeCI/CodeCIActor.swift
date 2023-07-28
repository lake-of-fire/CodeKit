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
    
    private var repos: Results<PackageRepository> {
        get async throws {
            try await realm.objects(PackageRepository.self).where({ !$0.isDeleted && $0.isEnabled })
        }
    }
//    @MainActor @Published private var activeRepos:
    
    
    private var cancellables = Set<AnyCancellable>()
    @MainActor private var buildTask: Task<(), Error>?
    
    enum CodeCIError: Error {
        case unknownError
    }
    
    public init(realmConfiguration: Realm.Configuration) {
        configuration = realmConfiguration
        Task { await wireRepos() }
    }
    
    public func wireRepos() async {
        try? await realm.objects(PackageRepository.self).where({ !$0.isDeleted && $0.isEnabled })
//        try? await repos
            .changesetPublisher
            .receive(on: DispatchQueue.main)
            .sink { changeset in
                switch changeset {
                case .initial(let results):
                    let ref = ThreadSafeReference(to: results)
                    Task { @MainActor [weak self] in
                        guard let self = self, let results = try? await realm.resolve(ref) else { return }
                        buildIfNeeded(repos: Array(results))
                    }
                case .update(let results, let deletions, let insertions, let modifications):
                    let ref = ThreadSafeReference(to: results)
                    Task { @MainActor [weak self] in
                        guard let self = self, let results = try? await realm.resolve(ref) else { return }
                        buildIfNeeded(repos: Set(insertions + modifications).map { results[$0] })
                    }
                case .error(let error):
                    print(error)
                }
            }
            .store(in: &cancellables)
    }
   
    @MainActor
    func buildIfNeeded(repos: [PackageRepository]) {
        buildTask?.cancel()
        buildTask = Task { @MainActor [weak self] in
            for repo in repos {
                try? await self?.buildIfNeeded(repo: repo)
            }
        }
    }
    
    @MainActor
    func buildIfNeeded(repo: PackageRepository) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let ref = ThreadSafeReference(to: repo)
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
                        guard let self = self, let repo = try await realm.resolve(ref) else {
                            continuation.resume(throwing: CodeCIError.unknownError)
                            return
                        }

                        let names = try await repo.extensionNamesFromFiles()
                        for extensionName in names {
                            guard let codeExtension = repo.codeExtensions.where({ $0.name == extensionName && !$0.isDeleted }).first else {
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
        let buildDirectoryURL = try await codeExtension.createBuildDirectoryIfNeeded()
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
        print(resultPageHTML)
        print()
    }
}
