// Much of this file is forked from https://github.com/thebaselab/codeapp/blob/main/CodeApp/Managers/MainApp.swift#L605
import Foundation
import SwiftGit2

public protocol GitRepositoryProtocol: AnyObject {
    var workspaceStorage: WorkspaceStorage? { get }
    var gitServiceIsBusy: Bool { get set }
    var availableCheckoutDestination: [CheckoutDestination] { get set }
    var gitTracks: [URL: Diff.Status] { get set }
    var indexedResources: [URL: Diff.Status] { get set }
    var workingResources: [URL: Diff.Status] { get set }
    var statusDescription: String { get set }
    var branch: String { get set }
    var commitMessage: String { get set }
    var isSyncing: Bool { get set }
    var aheadBehind: (Int, Int)? { get set }
}

enum GitRepositoryError: Error {
    case missingGitServiceProvider
}

public struct CheckoutDestination: Identifiable {
    public var id = UUID()
    public var reference: ReferenceType

    public var shortOID: String {
        String(self.reference.oid.description.dropLast(32))
    }
    public var name: String {
        self.reference.shortName ?? self.reference.longName
    }
}

public extension GitRepositoryProtocol {
    private func clearState() {
        aheadBehind = nil
        branch = ""
        gitTracks = [:]
        indexedResources = [:]
        workingResources = [:]
    }
    
    @MainActor
    func updateGitRepositoryStatus() async {
        self.gitServiceIsBusy = true
        
        @Sendable func onFinish() {
            self.gitServiceIsBusy = false
        }
        
        @Sendable func clearUIState() {
                self.aheadBehind = nil
                self.statusDescription = ""
                self.branch = ""
                self.gitTracks = [:]
                self.indexedResources = [:]
                self.workingResources = [:]
        }
        
        guard let gitServiceProvider = workspaceStorage?.gitServiceProvider else {
            clearUIState()
            onFinish()
            return
        }
        
        await Task {
            defer {
                onFinish()
            }
            do {
                let entries = try await gitServiceProvider.status()
                guard let (indexed, worktree) = groupStatusEntries(entries: entries) else { return }
                
                let indexedDictionary = Dictionary(uniqueKeysWithValues: indexed)
                let workingDictionary = Dictionary(uniqueKeysWithValues: worktree)
                
                await MainActor.run {
                    self.indexedResources = indexedDictionary
                    self.workingResources = workingDictionary
                    self.gitTracks = indexedDictionary.merging(
                        workingDictionary,
                        uniquingKeysWith: { current, _ in
                            current
                        })
                }
                
                let aheadBehind = try? await gitServiceProvider.aheadBehind(remote: nil)
                let currentHead = try await gitServiceProvider.head()
                
                await MainActor.run {
                    self.aheadBehind = aheadBehind
                    
                    var branchLabel: String
                    if let currentBranch = currentHead as? Branch {
                        branchLabel = currentBranch.name
                    } else {
                        branchLabel = String(currentHead.oid.description.prefix(7))
                    }
                    
                    if entries.first(where: { $0.status.contains(.workTreeModified) }) != nil {
//                        branchLabel += "*"
                        self.statusDescription = "Changes not staged for commit"
                    }
                    if entries.first(where: { $0.status.contains(.indexModified) }) != nil {
//                        branchLabel += "+"
                        self.statusDescription = "Changes staged for commit"
                    }
                    if entries.first(where: { $0.status.contains(.conflicted) }) != nil {
//                        branchLabel += "!"
                        self.statusDescription = "Conflicts require merging"
                    }
                    if self.statusDescription.isEmpty, let aheadBehind = aheadBehind {
                        if aheadBehind == (0, 0) {
                            self.statusDescription = "Up to date"
                        } else {
                            self.statusDescription = "\(aheadBehind.1)↓ \(aheadBehind.0)↑"
                        }
                    }
                    
                    self.branch = branchLabel
                }
            } catch {
                clearUIState()
            }
        }.value
        
        try? await Task {
            let references: [ReferenceType] =
            (try await gitServiceProvider.tags())
            + (try await gitServiceProvider.remoteBranches())
            + (try await gitServiceProvider.localBranches())
            await MainActor.run {
                availableCheckoutDestination = references.map {
                    CheckoutDestination(reference: $0)
                }
            }
        }.value
    }
    
    @MainActor
    private func groupStatusEntries(entries: [StatusEntry]) -> (
        [(URL, Diff.Status)], [(URL, Diff.Status)]
    )? {
        var indexedGroup = [(URL, Diff.Status)]()
        var workingGroup = [(URL, Diff.Status)]()
        
        guard let workingURL = workspaceStorage?.currentDirectory._url else { return nil }
        
        for i in entries {
            let status = i.status
            
            let headToIndexURL: URL? = {
                guard let path = i.headToIndex?.newFile?.path else {
                    return nil
                }
                return workingURL.appendingPathComponent(path)
            }()
            let indexToWorkURL: URL? = {
                guard let path = i.indexToWorkDir?.newFile?.path else {
                    return nil
                }
                return workingURL.appendingPathComponent(path)
            }()
            
            status.allIncludedCases.forEach { includedCase in
                if [
                    .indexDeleted, .indexRenamed, .indexModified, .indexDeleted,
                    .indexTypeChange, .indexNew,
                ].contains(includedCase) {
                    indexedGroup.append((headToIndexURL!, includedCase))
                } else if [
                    .workTreeNew, .workTreeDeleted, .workTreeRenamed, .workTreeModified,
                    .workTreeUnreadable, .workTreeTypeChange, .conflicted,
                ].contains(includedCase) {
                    workingGroup.append((indexToWorkURL!, includedCase))
                }
            }
        }
        return (indexedGroup, workingGroup)
    }

//    @MainActor
//    func gitStatus() async throws {
//        guard let workspaceStorage = workspaceStorage else { return }
//
//        if workspaceStorage.gitServiceProvider == nil {
//            clearState()
//        }
//
//        return try await withCheckedThrowingContinuation { continuation in
//            workspaceStorage.gitServiceProvider?.status(error: { [weak self] error in
//                self?.clearState()
//                continuation.resume(throwing: error)
//            }) { indexed, worktree, branch in
//                guard let hasRemote = self.workspaceStorage?.gitServiceProvider?.hasRemote() else {
//                    continuation.resume(with: .failure(GitRepositoryError.missingGitServiceProvider))
//                    return
//                }
//
//                Task { @MainActor in
//                    let indexedDictionary = Dictionary(uniqueKeysWithValues: indexed)
//                    let workingDictionary = Dictionary(uniqueKeysWithValues: worktree)
//
//                    if hasRemote {
//                        self.remote = "origin"
//                    } else {
//                        self.remote = ""
//                    }
//                    self.branch = branch
//                    self.indexedResources = indexedDictionary
//                    self.workingResources = workingDictionary
//
//                    self.gitTracks = indexedDictionary.merging(
//                        workingDictionary,
//                        uniquingKeysWith: { current, _ in
//                            current
//                        })
//
//                    self.workspaceStorage?.gitServiceProvider?.aheadBehind(error: { error in
//                        print(error.localizedDescription)
//                        Task { @MainActor in
//                            self.aheadBehind = nil
//                            continuation.resume(with: .failure(error))
//                        }
//                    }) { result in
//                        Task { @MainActor in
//                            self.aheadBehind = result
//                            continuation.resume(with: .success(()))
//                        }
//                    }
//                }
//            }
//        }
//    }
}
