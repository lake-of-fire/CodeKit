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
    
//    enum CodeCIError: Error {
//        case repositoryLoadingFailed
//        case missingGitServiceProvider
//        case gitRepositoryInitializationError
//    }
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
                        guard let results = try? await self?.realm.resolve(ref) else { return }
                        print("Gonna build for \(results)")
                        try? await self?.buildIfNeeded(repos: Array(results))
                    }
                case .update(let results, let deletions, let insertions, let modifications):
                    let ref = ThreadSafeReference(to: results)
                    Task { @MainActor [weak self] in
                        guard let results = try? await self?.realm.resolve(ref) else { return }
                        try? await self?.buildIfNeeded(repos: Set(insertions + modifications).map { results[$0] })
                    }
                case .error(let error):
                    print(error)
                }
            }
            .store(in: &cancellables)
    }
    
    @MainActor
    func buildIfNeeded(repo: PackageRepository) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                try Task.checkCancellation()
                let ref = ThreadSafeReference(to: repo)
                repo.cloneOrPullIfNeeded { [weak self] error in
                    if let error = error {
                        print(error)
                        continuation.resume(throwing: error)
                        return
                    }
                    Task { [weak self] in
                        try Task.checkCancellation()
                        guard let self = self else { return }
                        guard let repo = try await realm.resolve(ref) else { return }
                        
                        //                codeCoreViewModel
                    }
                }
            }
        }
    }

    @MainActor
    func buildIfNeeded(repos: [PackageRepository]) async throws {
        buildTask?.cancel()
        buildTask = Task { @MainActor [weak self] in
            for repo in repos {
                try? await self?.buildIfNeeded(repo: repo)
            }
        }
    }
}
