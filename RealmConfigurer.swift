import Foundation
import RealmSwift
import CodeCore
import CodeAI
import LakeOfFire

public enum RealmConfigurer {
    static let schemaVersion: UInt64 = 90
    
    public static var configuration: Realm.Configuration {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.chatonmac.shared")?.appendingPathComponent("chat-shared.realm") ?? Self.applicationDocumentsDirectory()?.appendingPathComponent("chat.realm") else {
            fatalError("No container found for App Group while configuring Realm.")
        }
        // Disable file protection for this directory (why?)
//        try! FileManager.default.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: url.path)
        return Realm.Configuration(
            fileURL: url,
            schemaVersion: schemaVersion,
            migrationBlock: migrationBlock,
            shouldCompactOnLaunch: { totalBytes, usedBytes in
                let targetBytes = 50 * 1024 * 1024
                return (totalBytes > targetBytes) && (Double(usedBytes) / Double(totalBytes)) < 0.65
            },
            objectTypes: [
                TokenBuyer.self,
                PurchasedTokens.self,
                
                // CodeCore
                CodePackage.self,
                PackageCollection.self,
                CodeExtension.self,
                
                // CodeAI
                Room.self,
                Event.self,
                Persona.self,
                Link.self,
            ]
            + (LakeOfFire.DefaultRealmConfiguration.configuration.objectTypes ?? [])
        )
    }

    fileprivate static func applicationDocumentsDirectory() -> URL? {
#if TARGET_OS_IPHONE
        if let path = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true).last {
            return URL(string: path)
        }
#else
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        //        return urls.last?.appendingPathComponent("com.lake-of-fire.BigSyncKit").path
        if let path = urls.last?.path {
            return URL(string: path)
        }
#endif
        return nil
    }
    
    static private func migrationBlock(migration: Migration, oldSchemaVersion: UInt64) {
//        if oldSchemaVersion < 17 + 48 + 14 {
//            migration.deleteData(forType: CodeExtension.className())
//            migration.deleteData(forType: Room.className())
//            migration.deleteData(forType: Event.className())
//            migration.deleteData(forType: Persona.className())
//        }
    }
}
