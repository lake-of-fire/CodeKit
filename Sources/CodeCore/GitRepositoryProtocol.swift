import Foundation
import SwiftGit2

public protocol GitRepositoryProtocol: AnyObject {
    var workspaceStorage: WorkspaceStorage? { get }
    var gitTracks: [URL: Diff.Status] { get set }
    var indexedResources: [URL: Diff.Status] { get set }
    var workingResources: [URL: Diff.Status] { get set }
    var branch: String { get set }
    var remote: String { get set }
    var commitMessage: String { get set }
    var isSyncing: Bool { get set }
    var aheadBehind: (Int, Int)? { get set }
}

enum GitRepositoryError: Error {
    case missingGitServiceProvider
}

public extension GitRepositoryProtocol {
    private func clearState() {
        remote = ""
        branch = ""
        gitTracks = [:]
        indexedResources = [:]
        workingResources = [:]
    }
    
    @MainActor
    func gitStatus() async throws {
        guard let workspaceStorage = workspaceStorage else { return }
        
        if workspaceStorage.gitServiceProvider == nil {
            clearState()
        }

        return try await withCheckedThrowingContinuation { continuation in
            workspaceStorage.gitServiceProvider?.status(error: { [weak self] error in
                self?.clearState()
                continuation.resume(throwing: error)
            }) { indexed, worktree, branch in
                guard let hasRemote = self.workspaceStorage?.gitServiceProvider?.hasRemote() else {
                    continuation.resume(with: .failure(GitRepositoryError.missingGitServiceProvider))
                    return
                }
                
                Task { @MainActor in
                    let indexedDictionary = Dictionary(uniqueKeysWithValues: indexed)
                    let workingDictionary = Dictionary(uniqueKeysWithValues: worktree)
                    
                    if hasRemote {
                        self.remote = "origin"
                    } else {
                        self.remote = ""
                    }
                    self.branch = branch
                    self.indexedResources = indexedDictionary
                    self.workingResources = workingDictionary
                    
                    self.gitTracks = indexedDictionary.merging(
                        workingDictionary,
                        uniquingKeysWith: { current, _ in
                            current
                        })
                    
                    self.workspaceStorage?.gitServiceProvider?.aheadBehind(error: { error in
                        print(error.localizedDescription)
                        Task { @MainActor in
                            self.aheadBehind = nil
                            continuation.resume(with: .failure(error))
                        }
                    }) { result in
                        Task { @MainActor in
                            self.aheadBehind = result
                            continuation.resume(with: .success(()))
                        }
                    }
                }
            }
        }
    }
}
