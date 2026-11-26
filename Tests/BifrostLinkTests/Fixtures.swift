import Foundation

/// Real saves live in tmp/pokemon-fixtures (gitignored, never committed). Tests skip when absent.
enum Fixtures {
    static let folder: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("tmp/pokemon-fixtures")
    }()

    static func load(_ name: String) -> [UInt8]? {
        let url = folder.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return [UInt8](data)
    }
}
