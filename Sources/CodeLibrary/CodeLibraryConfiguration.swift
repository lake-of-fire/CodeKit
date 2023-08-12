import Foundation
import OPML
import RealmSwift
import BigSyncKit
import Combine
import SwiftUIWebView
//import Collections
import SwiftUIDownloads
import RealmSwiftGaps
import CodeCore

public struct CodeLibraryConfiguration {
    public static var securityApplicationGroupIdentifier = ""
    public static var downloadstDirectoryName = "code-library-configuration"
    public static var opmlURLs = [URL]()

    public var downloadables: Set<Downloadable> {
//        guard !Self.securityApplicationGroupIdentifier.isEmpty else { fatalError("securityApplicationGroupIdentifier unset") }
        return Set(Self.opmlURLs.compactMap { url in
            Downloadable(
                name: "App Data (\(url.lastPathComponent))",
                groupIdentifier: Self.securityApplicationGroupIdentifier,
                parentDirectoryName: Self.downloadstDirectoryName,
                downloadMirrors: [url])
        })
    }
    
    public static let shared = CodeLibraryConfiguration()
    
    public init() {
    }
    
    public func importOPML(fileURLs: [URL]) {
        for fileURL in fileURLs {
            do {
                try importOPML(fileURL: fileURL)
            } catch {
                print("Failed to import OPML from local file \(fileURL.absoluteString). Error: \(error.localizedDescription)")
            }
        }
    }
    
    public func importOPML(fileURL: URL, fromDownload download: Downloadable? = nil) throws {
        let text = try String(contentsOf: fileURL)
        let opml = try OPML(Data(text.utf8))
//        var allImportedFeeds = OrderedSet<Feed>()
//        for entry in opml.entries {
//            let (importedCategories, importedFeeds, importedScripts) = importOPMLEntry(entry, opml: opml, download: download)
//            allImportedCategories.formUnion(importedCategories)
//            allImportedFeeds.formUnion(importedFeeds)
//            allImportedScripts.formUnion(importedScripts)
//        }
//
//        let allImportedCategoryIDs = allImportedCategories.map { $0.id }
//        let allImportedFeedIDs = allImportedFeeds.map { $0.id }
//        let allImportedScriptIDs = allImportedScripts.map { $0.id }
//        let realm = try! Realm(configuration: LibraryDataManager.realmConfiguration)
//
//        // Delete orphan scripts
//        if let downloadURL = download?.url {
//            let filteredScripts = realm.objects(UserScript.self).filter({ $0.isDeleted == false && $0.opmlURL == downloadURL })
//            for script in filteredScripts {
//                if !allImportedScriptIDs.contains(script.id) {
//                    safeWrite(script) { _, script in
//                        script.isDeleted = true
//                    }
//                }
//            }
//        }
//
//        // Add new scripts
//        for script in allImportedScripts {
//            if !configuration.userScripts.contains(script) {
//                var lastNeighborIdx = configuration.userScripts.count - 1
//                if let downloadURL = download?.url {
//                    lastNeighborIdx = configuration.userScripts.lastIndex(where: { $0.opmlURL == downloadURL }) ?? lastNeighborIdx
//                }
//                safeWrite(configuration) { _, configuration in
//                    configuration.userScripts.insert(script, at: lastNeighborIdx + 1)
//                }
//            }
//        }
    }
    
    public func importOPML(download: Downloadable) throws {
//        try importOPML(fileURL: download.localDestination, fromDownload: download)
    }
    
    /*
    func importOPMLEntry(_ opmlEntry: OPMLEntry, opml: OPML, download: Downloadable?, category: FeedCategory? = nil, importedCategories: OrderedSet<FeedCategory> = OrderedSet(), importedFeeds: OrderedSet<Feed> = OrderedSet(), importedScripts: OrderedSet<UserScript> = OrderedSet()) -> (OrderedSet<FeedCategory>, OrderedSet<Feed>, OrderedSet<UserScript>) {
        var category = category
        var importedCategories = importedCategories
        var importedFeeds = importedFeeds
        var importedScripts = importedScripts
        var uuid: UUID?
        if let rawUUID = opmlEntry.attributeStringValue("uuid") {
            uuid = UUID(uuidString: rawUUID)
        }
        
        if opmlEntry.feedURL != nil {
            safeWrite(configuration: LibraryDataManager.realmConfiguration) { realm in
                if let uuid = uuid, let feed = realm.object(ofType: Feed.self, forPrimaryKey: uuid) {
                    if feed.category?.opmlURL == download?.url || feed.isDeleted {
                        Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, download: download, feed: feed, category: category)
                        importedFeeds.append(feed)
                    }
                } else if opmlEntry.feedURL != nil {
                    let feed = Feed()
                    if let uuid = uuid, feed.realm == nil {
                        feed.id = uuid
                        Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, download: download, feed: feed, category: category)
                        realm.add(feed, update: .modified)
                        importedFeeds.append(feed)
                    }
                }
            }
        } else if !(opmlEntry.attributeStringValue("script")?.isEmpty ?? true) {
            safeWrite(configuration: LibraryDataManager.realmConfiguration) { realm in
                if let uuid = uuid, let script = realm.objects(UserScript.self).filter({ $0.id == uuid }).first {
                    if script.opmlURL == download?.url || script.isDeleted {
                        Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, download: download, script: script)
                        importedScripts.append(script)
                    }
                } else {
                    let script = UserScript()
                    if let uuid = uuid, script.realm == nil {
                        script.id = uuid
                        if let downloadURL = download?.url {
                            script.opmlURL = downloadURL
                        }
                        Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, download: download, script: script)
                        realm.add(script, update: .modified)
                        importedScripts.append(script)
                    }
                }
            }
        } else if !(opmlEntry.children?.isEmpty ?? true) {
            let opmlTitle = opmlEntry.title ?? opmlEntry.text
            if category == nil {
                safeWrite(configuration: LibraryDataManager.realmConfiguration) { realm in
                    if let uuid = uuid, let existingCategory = realm.object(ofType: FeedCategory.self, forPrimaryKey: uuid) {
                        category = existingCategory
                        if existingCategory.opmlURL == download?.url || existingCategory.isDeleted {
                            Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, download: download, category: existingCategory)
                            importedCategories.append(existingCategory)
                        }
                    } else if let uuid = uuid {
                        category = FeedCategory()
                        if let category = category {
                            category.id = uuid
                            if let downloadURL = download?.url {
                                category.opmlURL = downloadURL
                            }
                            Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, download: download, category: category)
                            realm.add(category, update: .modified)
                            importedCategories.append(category)
                        }
                    }
                }
            }// else if let category = category {
                // Ignore/flatten nested categories from OPML.
            //}
        }
       
        for childEntry in (opmlEntry.children ?? []) {
            let (newCategories, newFeeds, newScripts) = importOPMLEntry(childEntry, opml: opml, download: download, category: category, importedCategories: importedCategories, importedFeeds: importedFeeds, importedScripts: importedScripts)
            importedCategories.append(contentsOf: newCategories)
            importedFeeds.append(contentsOf: newFeeds)
            importedScripts.append(contentsOf: newScripts)
        }
        return (importedCategories, importedFeeds, importedScripts)
    }
    
    static func applyAttributes(opml: OPML, opmlEntry: OPMLEntry, download: Downloadable?, repo: PackageRepository) {
        repo.name = opmlEntry.text
        
        repo.isDeleted = false
        repo.isArchived = false
        repo.modifiedAt = Date()
    }
    
    public func exportUserOPML() throws -> OPML {
        let configuration = LibraryConfiguration.shared
        let userCategories = configuration.categories.filter { $0.opmlOwnerName == nil && $0.opmlURL == nil && $0.isDeleted == false }
        
        let scriptEntries = OPMLEntry(text: "User Scripts", attributes: [
            Attribute(name: "isUserScriptList", value: "true"),
        ], children: LibraryConfiguration.shared.userScripts.where({ $0.opmlURL == nil }).map({ script in
            return OPMLEntry(text: script.title, attributes: [
                Attribute(name: "uuid", value: script.id.uuidString),
                Attribute(name: "script", value: script.script.addingPercentEncoding(withAllowedCharacters: Self.attributeCharacterSet) ?? script.script),
                Attribute(name: "injectAtStart", value: script.injectAtStart ? "true" : "false"),
                Attribute(name: "mainFrameOnly", value: script.mainFrameOnly ? "true" : "false"),
                Attribute(name: "sandboxed", value: script.sandboxed ? "true" : "false"),
                Attribute(name: "isArchived", value: script.isArchived ? "true" : "false"),
                Attribute(name: "previewURL", value: script.previewURL?.absoluteString ?? "about:blank"),
            ])
        }))
        
        let opml = OPML(
            dateModified: Date(),
            ownerName: (Self.currentUsername?.isEmpty ?? true) ? nil : Self.currentUsername,
            entries: try [scriptEntries] + userCategories.map { category in
                try Task.checkCancellation()
                
                return OPMLEntry(
                    text: category.title,
                    attributes: [
                        Attribute(name: "uuid", value: category.id.uuidString),
                        Attribute(name: "backgroundImageUrl", value: category.backgroundImageUrl.absoluteString),
                        Attribute(name: "isFeedCategory", value: "true"),
                    ],
                    children: try category.feeds.where({ $0.isDeleted == false && $0.isArchived == false }).sorted(by: \.title).map { feed in
                        try Task.checkCancellation()
                        
                        var attributes = [
                            Attribute(name: "uuid", value: feed.id.uuidString),
                            Attribute(name: "extractImageFromContent", value: feed.extractImageFromContent ? "true" : "false"),
                            Attribute(name: "isReaderModeByDefault", value: feed.isReaderModeByDefault ? "true" : "false"),
                            Attribute(name: "iconUrl", value: feed.iconUrl.absoluteString),
                        ]
                        if !feed.markdownDescription.isEmpty {
                            attributes.append(Attribute(name: "markdownDescription", value: feed.markdownDescription))
                        }
                        attributes.append(Attribute(name: "rssContainsFullContent", value: feed.rssContainsFullContent ? "true" : "false"))
                        attributes.append(Attribute(name: "injectEntryImageIntoHeader", value: feed.injectEntryImageIntoHeader ? "true" : "false"))
                        attributes.append(Attribute(name: "displayPublicationDate", value: feed.displayPublicationDate ? "true" : "false"))
                        attributes.append(Attribute(name: "meaningfulContentMinLength", value: String(feed.meaningfulContentMinLength)))
                        return OPMLEntry(
                            rss: feed.rssUrl,
                            siteURL: nil,
                            title: feed.title,
                            attributes: attributes)
                    })
            })
        return opml
    }
     */
}

extension OPMLEntry {
    func attributeBoolValue(_ name: String) -> Bool? {
        guard let value = attributes?.first(where: { $0.name == name })?.value else { return nil }
        return value == "true"
    }
    
    func attributeStringValue(_ name: String) -> String? {
        return attributes?.first(where: { $0.name == name })?.value
    }
}
