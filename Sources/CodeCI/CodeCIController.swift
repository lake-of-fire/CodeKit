import SwiftUI
import WebKit
import RealmSwift
import RealmSwiftGaps
import OPML
import CodeCore

public actor CodeCIActor: ObservableObject {
    var configuration: Realm.Configuration
    
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
    
    public init(realmConfiguration: Realm.Configuration) {
        configuration = realmConfiguration
        
        Task {
            try? await repos
                .changesetPublisher
                .sink { changeset in
                    Task { [weak self] in
                        try await self?.buildIfNeeded()
                    }
                }
        }
    }
    
    func buildIfNeeded() async throws {
        for repo in try await repos {
            
        }
    }
}
