import Foundation
import RealmSwift

public enum DefaultRealmConfiguration {
    public static let schemaVersion: UInt64 = 14
    
    public static var configuration: Realm.Configuration {
        var config = Realm.Configuration.defaultConfiguration
        config.schemaVersion = schemaVersion
        config.migrationBlock = migrationBlock
        config.shouldCompactOnLaunch = { totalBytes, usedBytes in
            let targetBytes = 40 * 1024 * 1024
            return (totalBytes > targetBytes) && (Double(usedBytes) / Double(totalBytes)) < 0.6
        }
        config.objectTypes = [
            CodePackage.self,
            PackageCollection.self,
            CodeExtension.self,
        ]
        return config
    }

    public static func migrationBlock(migration: Migration, oldSchemaVersion: UInt64) {
    }
}
