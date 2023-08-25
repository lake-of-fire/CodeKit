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
    
    public init(realmConfiguration: Realm.Configuration, autoBuild: Bool = true) {
        configuration = realmConfiguration
        
        Task {
            let (liveCodesData, liveCodesURL) = loadLiveCodes()
            await codeCoreViewModel.load(
                htmlData: liveCodesData,
                baseURL: liveCodesURL)
            if autoBuild {
                await wireRepos()
            }
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
                        requestBuildsIfNeeded(forceBuild: true)
                    }
                case .update(let results, let deletions, let insertions, let modifications):
                    let ref = ThreadSafeReference(to: results)
                    Task { @MainActor [weak self] in
                        guard let self = self, let results = try? await realm.resolve(ref) else { return }
                        let packages = Array(results)
                        refreshRepositories(packages: packages)
                        requestBuildsIfNeeded(forceBuild: true)
//                        buildIfNeeded(packages: Set(insertions + modifications).map { results[$0] })
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
        repositories = packages.map { CodePackageRepository(package: $0, codeCoreViewModel: codeCoreViewModel) }
    }
    
    @MainActor
    func requestBuildsIfNeeded(forceBuild: Bool = false) {
        buildTask?.cancel()
        buildTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            for repo in repositories {
                try? await repo.requestBuildIfNeeded(forceBuild: forceBuild)
            }
        }
    }
    
    
}
