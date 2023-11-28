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
            .collectionPublisher(keyPaths: ["id", "repositoryURL", "isEnabled"])
            .receive(on: DispatchQueue.main)
            .freeze()
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .threadSafeReference()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { results in
                    let ref = ThreadSafeReference(to: results)
//                    Task { @MainActor [weak self] in
//                    let results = results.freeze()
                Task { @MainActor [weak self] in
                    //                        guard let self = self, let results = try? await realm.resolve(ref) else { return }
                    guard let self = self, let realm = try? await Realm(), let results = realm.resolve(ref) else { return }
                    let packages = Array(results)
                    if refreshRepositories(packages: packages) {
                        requestBuildsIfNeeded(forceBuild: true)
                    }
                    //                        buildIfNeeded(packages: Set(insertions + modifications).map { results[$0] })
                }
            })
            .store(in: &cancellables)
    }
   
    @MainActor
    private func refreshRepositories(packages: [CodePackage]) -> Bool {
        // TODO: Only refresh/remove initial/added/modified/removed ones from wireRepos
        guard packages != repositories.map({ $0.package }) else {
            return false
        }
        var oldPackages = [UUID: CodePackage]()
        for package in repositories.map({ $0.package }) {
            oldPackages[package.id] = package
        }
        var anyChanged = false
        for newPackage in packages {
            if let oldPackage = oldPackages[newPackage.id] {
                if oldPackage.id != newPackage.id || oldPackage.isEnabled != newPackage.isEnabled || oldPackage.repositoryURL != newPackage.repositoryURL || oldPackage.allowAllHosts != newPackage.allowAllHosts || oldPackage.allowHosts != newPackage.allowHosts {
                    anyChanged = true
                    break
                }
            } else {
                anyChanged = true
                break
            }
        }
        guard anyChanged else { return false }
        repositories = packages.map { CodePackageRepository(package: $0, codeCoreViewModel: codeCoreViewModel) }
        return true
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
