import Foundation

/// Small private store for the RetroAchievements username and web API key.
///
/// Not the macOS Keychain on purpose: the app is ad-hoc/self-signed and every update changes its
/// signature, so the Keychain asked for the Mac password after each update. The values live in a
/// file only your user account can read (permissions 600) in the app's data folder.
enum Keychain {
    private static let file: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bifrost Link", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("retroachievements.json")
    }()

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return values
    }

    private static func save(_ values: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: values) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func get(_ account: String) -> String? { load()[account] }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        var values = load()
        values[account] = value
        save(values)
        return true
    }

    static func delete(_ account: String) {
        var values = load()
        values[account] = nil
        if values.isEmpty { try? FileManager.default.removeItem(at: file) } else { save(values) }
    }
}
