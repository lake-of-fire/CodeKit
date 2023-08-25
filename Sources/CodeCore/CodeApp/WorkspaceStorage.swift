import Foundation
import SwiftUI
import FilesProvider

@MainActor
public class WorkspaceStorage: ObservableObject {
    @Published public var currentDirectory: FileItemRepresentable
    @Published public var explorerIsBusy = false
    @Published public var editorIsBusy = false

    private var directoryMonitor = DirectoryMonitor()
    var onDirectoryChangeAction: ((String) -> Void)? = nil
    private var directoryStorage: [String: [(FileItemRepresentable)]] = [:]
    private var fss: [String: FileSystemProvider] = [:]
    private var isConnecting = false

    enum FSError: String, LocalizedError {
        case NotImplemented = "errors.fs.not_implemented"
        case SchemeNotRegistered = "errors.fs.scheme_not_registered"
        case InvalidHost = "errors.fs.invalid_host"
        case UnsupportedEncoding = "errors.fs.unsupported_encoding"
        case Unknown = "errors.fs.unknown"
        case ConnectionFailure = "errors.fs.connection_failure"
        case AuthFailure = "errors.fs.authentication_failure"
        case AttemptingToCopyParentToChild = "errors.fs.attempting_to_copy_parent_to_child"
        case AttemptingToCopyOneself = "errors.fs.attempting_to_copy_oneself"
        case AlreadyConnectingToAHost = "errors.fs.already_connecting_to_a_host"
        case UnsupportedAuthenticationMethod = "errors.fs.unsupported_auth"
        case UnableToFindASuitableName = "errors.fs.unable_to_find_suitable_name"
        case TargetIsiCloudFile = "errors.fs.icloud.file"

        var errorDescription: String? {
            NSLocalizedString(self.rawValue, comment: "")
        }
    }
    
    var currentScheme: String? {
        URL(string: currentDirectory.url)?.scheme
    }
    private var fs: FileSystemProvider? {
        currentScheme != nil ? fss[currentScheme!] : nil
    }

    public init(url: URL) {
        let localFS = LocalFileSystemProvider()
        localFS.gitServiceProvider = LocalGitServiceProvider(root: url)

        self.fss["file"] = localFS
        self.currentDirectory = FileItemRepresentable(
            name: url.lastPathComponent, url: url.absoluteString, isDirectory: true)
        self.requestDirectoryUpdateAt(id: url.absoluteString)
    }

    private func fileURLWithSuffix(url: URL, suffix: String) -> URL {
        let pathExtension = url.pathExtension
        let newName = "\(url.deletingPathExtension().lastPathComponent) (\(suffix))"
        return url.deletingLastPathComponent().appendingPathComponent(newName)
            .appendingPathExtension(pathExtension)
    }

    func urlWithSuffixIfExistingFileExist(url: URL) async throws -> URL {
        if !(try await self.fileExists(at: url)) {
            return url
        }
        var num = 2
        while try await self.fileExists(at: fileURLWithSuffix(url: url, suffix: String(num))) {
            num += 1
            if num > 100 {
                throw FSError.UnableToFindASuitableName
            }
        }
        return fileURLWithSuffix(url: url, suffix: String(num))
    }

    /// Reload the whole directory and invalidate all existing cache
    @MainActor
    func updateDirectory(url: URL) async {
        return await withCheckedContinuation { continuation in
            let urlStr = url.absoluteString
            if urlStr != currentDirectory.url {
                // Directory is updated
                directoryMonitor.removeAll()
                directoryStorage.removeAll()
                currentDirectory = FileItemRepresentable(name: url.lastPathComponent, url: urlStr, isDirectory: true)
                requestDirectoryUpdateAt(id: urlStr) {
                    continuation.resume(with: .success(()))
                }
            } else {
                // Directory is not updated
                for key in directoryStorage.keys {
                    // TODO: Wait on these to complete too
                    loadURL(
                        url: key,
                        completionHandler: { items, error in
                            self.directoryStorage[key] = items
                        })
                }
                
                DispatchQueue.main.async {
                    withAnimation(.easeInOut) {
                        self.currentDirectory = self.buildTree(at: urlStr)
                        continuation.resume(with: .success(()))
                    }
                }
            }
        }
    }

    func onDirectoryChange(_ action: @escaping ((String) -> Void)) {
        onDirectoryChangeAction = action
    }

    /// Reload a specific subdirectory
    func requestDirectoryUpdateAt(id: String, forceUpdate: Bool = false, completion: (() -> Void)? = nil) {
        guard forceUpdate || !directoryStorage.keys.contains(id) else {
            if let completion = completion { completion() }
            return
        }
        if !directoryMonitor.keys.contains(id) && id.hasPrefix("file://") {
            directoryMonitor.monitorURL(url: id) { _ in
                print("Directory monitor triggered for \(id) \(self.onDirectoryChangeAction)")
                self.onDirectoryChangeAction?(id)
                self.requestDirectoryUpdateAt(id: id, forceUpdate: true)
            }
        }

        loadURL(
            url: id,
            completionHandler: { items, error in
                guard let items = items else {
                    if let completion = completion { completion() }
                    return
                }
                self.directoryStorage[id] = items
                DispatchQueue.main.async {
                    withAnimation(.easeInOut) {
                        self.currentDirectory = self.buildTree(at: self.currentDirectory.url)
                        if let completion = completion { completion() }
                    }
                }
            })
    }

    private func removeFromTree(url: URL) {
        let isDirectory = url.isDirectory

        if isDirectory {
            directoryStorage.removeValue(forKey: url.absoluteString)
        } else {
            let urlToRemove = url.deletingLastPathComponent()
            directoryStorage[urlToRemove.absoluteString]?.removeAll(where: {
                $0.url == url.absoluteString
            })
        }
        DispatchQueue.main.async {
            withAnimation(.easeInOut) {
                self.currentDirectory = self.buildTree(at: self.currentDirectory.url)
            }
        }
    }

    private func insertToTree(file: FileItemRepresentable) {
        guard var urlToInsert = URL(string: file.url) else {
            return
        }
        urlToInsert.deleteLastPathComponent()
        if directoryStorage[urlToInsert.absoluteString] != nil {
            // Remove duplicated file
            var storage = directoryStorage[urlToInsert.absoluteString]!.filter {
                $0.url != file.url
            }
            storage.append(file)
            directoryStorage[urlToInsert.absoluteString] = storage
        } else {
            directoryStorage[urlToInsert.absoluteString] = [file]
        }
        DispatchQueue.main.async {
            withAnimation(.easeInOut) {
                self.currentDirectory = self.buildTree(at: self.currentDirectory.url)
            }
        }
    }

    private func buildTree(at base: String) -> FileItemRepresentable {
        let items = directoryStorage[base]
        guard items != nil else {
            return FileItemRepresentable(url: base, isDirectory: true)
        }
        let subItems =
            items!.filter { $0.subFolderItems != nil }.map { buildTree(at: $0.url) }
            + items!.filter { $0.subFolderItems == nil }
        var item = FileItemRepresentable(url: base, isDirectory: true)
        item.subFolderItems = subItems
        return item
    }

    private func loadURL(
        url: String, completionHandler: @escaping ([FileItemRepresentable]?, Error?) -> Void
    ) {
        guard let url = URL(string: url) else {
            completionHandler(nil, nil)
            return
        }

        self.contentsOfDirectory(at: url) { fileURLs, error in
            guard let fileURLs = fileURLs else {
                completionHandler(nil, error)
                return
            }
            var folders: [FileItemRepresentable] = []
            var files: [FileItemRepresentable] = []

            for i in fileURLs {
                var name = i.lastPathComponent.removingPercentEncoding ?? ""
                if name.isEmpty {
                    name = i.host ?? ""
                }
                if i.hasDirectoryPath {
                    folders.append(
                        FileItemRepresentable(name: name, url: i.absoluteString, isDirectory: true))
                } else {
                    files.append(
                        FileItemRepresentable(name: name, url: i.absoluteString, isDirectory: false)
                    )
                }
            }

            files.sort {
                return $0.url.lowercased() < $1.url.lowercased()
            }
            folders.sort {
                return $0.url.lowercased() < $1.url.lowercased()
            }

            completionHandler(folders + files, nil)
        }
    }
}

public extension WorkspaceStorage {
    struct FileItemRepresentable: Identifiable {
        public var id: String {
            self.url
        }
        var name: String
        public var url: String
        var subFolderItems: [FileItemRepresentable]?
        var isDownloading = false
        var isFolder: Bool {
            subFolderItems != nil
        }
        var _url: URL? {
            URL(string: url)
        }

        init(name: String? = nil, url: String, isDirectory: Bool) {
            if name != nil {
                self.name = name!
            } else if let url = URL(string: url) {
                let displayName = url.lastPathComponent.removingPercentEncoding ?? ""
                if displayName.isEmpty {
                    self.name = url.host ?? ""
                } else {
                    self.name = displayName
                }
            } else {
                self.name = ""
            }
            self.url = url
            if isDirectory {
                subFolderItems = []
            } else {
                subFolderItems = nil
            }
        }
    }
}

extension WorkspaceStorage: FileSystemProvider {
    static var registeredScheme: String {
        "nil"
    }

    var gitServiceProvider: GitServiceProvider? {
        fs?.gitServiceProvider
    }

    func write(
        at: URL, content: Data, atomically: Bool, overwrite: Bool,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let scheme = at.scheme, let fs = fss[scheme] else {
            completionHandler(FSError.SchemeNotRegistered)
            return
        }
        if scheme != "file" {
            let fileToInsert = FileItemRepresentable(url: at.absoluteString, isDirectory: false)
            insertToTree(file: fileToInsert)
        }
        return fs.write(
            at: at, content: content, atomically: atomically, overwrite: overwrite
        ) { error in
            DispatchQueue.main.async {
                completionHandler(error)
            }
        }
    }

    func contentsOfDirectory(at url: URL, completionHandler: @escaping ([URL]?, Error?) -> Void) {
        guard let scheme = url.scheme, let fs = fss[scheme] else {
            completionHandler(nil, FSError.SchemeNotRegistered)
            return
        }
        DispatchQueue.main.async {
            self.explorerIsBusy = true
        }
        return fs.contentsOfDirectory(at: url) { urls, error in
            DispatchQueue.main.async {
                self.explorerIsBusy = false
            }
            DispatchQueue.main.async {
                completionHandler(urls, error)
            }
        }
    }

    func fileExists(at url: URL, completionHandler: @escaping (Bool) -> Void) {
        guard let scheme = url.scheme, let fs = fss[scheme] else {
            completionHandler(false)
            return
        }
        return fs.fileExists(at: url) { error in
            DispatchQueue.main.async {
                completionHandler(error)
            }
        }
    }

    func createDirectory(
        at: URL, withIntermediateDirectories: Bool, completionHandler: @escaping (Error?) -> Void
    ) {
        guard let scheme = at.scheme, let fs = fss[scheme] else {
            completionHandler(FSError.SchemeNotRegistered)
            return
        }
        if scheme != "file" {
            let fileToInsert = FileItemRepresentable(url: at.absoluteString, isDirectory: true)
            insertToTree(file: fileToInsert)
        }
        return fs.createDirectory(
            at: at, withIntermediateDirectories: withIntermediateDirectories
        ) { error in
            Task { @MainActor in
                completionHandler(error)
            }
        }
    }

    func copyItem(at: URL, to: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let scheme = at.scheme, let fs = fss[scheme] else {
            completionHandler(FSError.SchemeNotRegistered)
            return
        }

        if at.sameFileLocation(path: to.path) {
            completionHandler(FSError.AttemptingToCopyOneself)
            return
        }

        if at.hasChild(url: to) {
            completionHandler(FSError.AttemptingToCopyParentToChild)
            return
        }

        if scheme != "file" {
            let fileToInsert = FileItemRepresentable(
                url: to.absoluteString, isDirectory: to.isDirectory)
            insertToTree(file: fileToInsert)
        }
        DispatchQueue.main.async {
            self.explorerIsBusy = true
        }
        return fs.copyItem(at: at, to: to) { error in
            DispatchQueue.main.async {
                completionHandler(error)
            }
            DispatchQueue.main.async {
                self.explorerIsBusy = false
            }
        }
    }

    func moveItem(at: URL, to: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let scheme = at.scheme, let fs = fss[scheme] else {
            completionHandler(FSError.SchemeNotRegistered)
            return
        }
        if scheme != "file" {
            let fileToInsert = FileItemRepresentable(
                url: to.absoluteString, isDirectory: to.isDirectory)
            insertToTree(file: fileToInsert)
            removeFromTree(url: at)
        }
        DispatchQueue.main.async {
            self.explorerIsBusy = true
        }
        return fs.moveItem(at: at, to: to) { error in
            DispatchQueue.main.async {
                completionHandler(error)
            }
            DispatchQueue.main.async {
                self.explorerIsBusy = false
            }
        }
    }

    func removeItem(at: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let scheme = at.scheme, let fs = fss[scheme] else {
            completionHandler(FSError.SchemeNotRegistered)
            return
        }
        return fs.removeItem(at: at) { error in
            if scheme != "file" && error == nil {
                self.removeFromTree(url: at)
            }
            DispatchQueue.main.async {
                completionHandler(error)
            }
        }
    }

    func contents(at: URL, completionHandler: @escaping (Data?, Error?) -> Void) {
        guard let scheme = at.scheme, let fs = fss[scheme] else {
            completionHandler(nil, FSError.SchemeNotRegistered)
            return
        }
        DispatchQueue.main.async {
            self.editorIsBusy = true
        }
        return fs.contents(at: at) { data, error in
            DispatchQueue.main.async {
                self.editorIsBusy = false
                completionHandler(data, error)
            }
        }
    }

    func attributesOfItem(
        at: URL, completionHandler: @escaping ([FileAttributeKey: Any?]?, Error?) -> Void
    ) {
        guard let scheme = at.scheme, let fs = fss[scheme] else {
            completionHandler(nil, FSError.SchemeNotRegistered)
            return
        }
        return fs.attributesOfItem(at: at) { attributes, error in
            DispatchQueue.main.async {
                completionHandler(attributes, error)
            }
        }
    }
}

extension WorkspaceStorage {
    func write(at: URL, content: Data, atomically: Bool, overwrite: Bool) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            write(
                at: at, content: content, atomically: atomically, overwrite: overwrite
            ) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func contentsOfDirectory(at url: URL) async throws -> [URL] {
        return try await withCheckedThrowingContinuation { continuation in
            contentsOfDirectory(at: url) { urls, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: urls ?? [])
                }
            }
        }
    }

    func fileExists(at url: URL) async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            fileExists(at: url) { exists in
                continuation.resume(returning: exists)
            }
        }
    }

    func createDirectory(at: URL, withIntermediateDirectories: Bool) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            createDirectory(
                at: at, withIntermediateDirectories: withIntermediateDirectories
            ) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func copyItem(at: URL, to: URL) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            copyItem(at: at, to: to) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func moveItem(at: URL, to: URL) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            moveItem(at: at, to: to) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func removeItem(at: URL) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            removeItem(at: at) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func contents(at: URL) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            contents(at: at) { data, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    func attributesOfItem(at: URL) async throws -> [FileAttributeKey: Any?] {
        return try await withCheckedThrowingContinuation { continuation in
            attributesOfItem(at: at) { attributes, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: attributes ?? [:])
                }
            }
        }
    }
}
