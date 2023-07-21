import SwiftUI
import WebKit
import RealmSwift
import RealmSwiftGaps
import OPML
import CodeCore

public actor CodeCIActor: ObservableObject {
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
    
    @MainActor private var buildTask: Task<(), Error>?
    
    public init(realmConfiguration: Realm.Configuration) {
        configuration = realmConfiguration
        
//        Task {
//            try? await repos
//                .changesetPublisher
//                .sink { changeset in
//                    Task { [weak self] in
//                        try await self?.buildIfNeeded()
//                    }
//                }
//        }
    }
    
    @MainActor
    func buildIfNeeded(repo: PackageRepository, codeCoreViewModel: CodeCoreViewModel) async throws {
        buildTask?.cancel()
        let ref = ThreadSafeReference(to: repo)
        repo.cloneIfNeeded { [weak self] error in
            guard error == nil else {
                print(error?.localizedDescription ?? "")
                return
            }
            self?.buildTask = Task.detached { [weak self] in
                guard let self = self else { return }
                guard let repo = try await realm.resolve(ref) else { return }
                
                codeCoreViewModel
            }
        }
    }
}
