import Foundation

enum XrayStorage {
    private static let legacyDefaultsMigrationKey = "storage_migrated_sandbox_defaults_v1"

    nonisolated static func applicationSupportDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        let legacyDirectory = legacySandboxApplicationSupportDirectory(fileManager: fileManager)
        let legacyDatabase = legacyDirectory.appendingPathComponent("xray.sqlite3")
        let legacyModels = legacyDirectory.appendingPathComponent("Models", isDirectory: true)

        if fileManager.fileExists(atPath: legacyDatabase.path)
            || fileManager.fileExists(atPath: legacyModels.path)
        {
            return legacyDirectory
        }

        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent("Xray", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    static func migrateLegacySandboxDefaultsIfNeeded(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        guard !defaults.bool(forKey: legacyDefaultsMigrationKey) else { return }
        defer { defaults.set(true, forKey: legacyDefaultsMigrationKey) }

        let preferencesURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.alexeyalbert.Xray/Data/Library/Preferences")
            .appendingPathComponent("com.alexeyalbert.Xray.plist")

        guard let data = try? Data(contentsOf: preferencesURL),
              let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let legacyDefaults = propertyList as? [String: Any]
        else { return }

        for (key, value) in legacyDefaults where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    nonisolated private static func legacySandboxApplicationSupportDirectory(
        fileManager: FileManager
    ) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.alexeyalbert.Xray/Data/Library/Application Support")
            .appendingPathComponent("Xray", isDirectory: true)
    }
}
