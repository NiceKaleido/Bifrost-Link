import Testing
import Foundation
import AppKit
@testable import BifrostLink

/// Set BIFROST_ONLINE=1 to download the sheet and check the crops.
@Suite struct OnlineIconTests {
    @Test func cutSheet() async throws {
        guard ProcessInfo.processInfo.environment["BIFROST_ONLINE"] != nil else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bifrost-online-test")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sheet = try Data(contentsOf: IconCache.sheetURL)
        let source = try String(contentsOf: IconCache.indexURL, encoding: .utf8)
        let index = IconCache.parseIndex(source)
        print("index entries:", index.count, "rattataalola:", index["rattataalola"] ?? -1)
        try sheet.write(to: dir.appendingPathComponent("sheet.png"))
        try JSONSerialization.data(withJSONObject: index).write(to: dir.appendingPathComponent("index.json"))
        let images = IconCache.cutSheet(sheetFile: dir.appendingPathComponent("sheet.png"), indexFile: dir.appendingPathComponent("index.json"))
        let species = images.keys.filter { $0 < 10_000 }.count
        let forms = images.keys.filter { $0 >= 100_000 }.count
        print("species:", species, "forms:", forms)
        #expect(species == 1025)
        #expect(forms > 100)
        let rattataAlola = PokeData.shared.forms[19]?.firstIndex { $0.name.contains("Alola") } ?? 1
        #expect(images[IconCache.formKey(19, rattataAlola)] != nil)
        for (name, key) in [("pikachu", 25), ("pecharunt", 1025), ("rattata-alola", IconCache.formKey(19, rattataAlola))] {
            if let tiff = images[key]?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
        print("written to", dir.path)
    }
}
