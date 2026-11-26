import Testing
import Foundation
@testable import BifrostLink

/// Set BIFROST_ROMS to a folder with ROMs to run these.
@Suite struct IconTests {
    static let folder = ProcessInfo.processInfo.environment["BIFROST_ROMS"]

    func rom(_ name: String) -> [UInt8]? {
        guard let folder = Self.folder, let d = FileManager.default.contents(atPath: folder + "/" + name) else { return nil }
        return [UInt8](d)
    }

    @Test func extract() throws {
        guard let folder = Self.folder else { return }
        if let fr = rom("Pokemon - FireRed Version (USA, Europe) (Rev 1).gba") {
            let icons = GBAIcons.extract(fr)
            print("FireRed icons:", icons.count)
            #expect(icons.count >= 386)
            for s in [25, 6, 1] { try icons[s]?.png?.write(to: URL(fileURLWithPath: "\(folder)/gba-\(s).png")) }
        }
        if let dp = rom("Pokemon - Diamond Version (USA) (Rev 5).nds") {
            let icons = NDSIcons.extract(dp)
            print("Diamond icons:", icons.count, "table found:", NDSIcons.lastFound != nil)
            #expect(icons.count == 493)
            NDSIcons.fallbackPalettes = NDSIcons.lastFound
            for s in [25, 448] { try icons[s]?.png?.write(to: URL(fileURLWithPath: "\(folder)/dp-\(s).png")) }
        }
        if let bw = rom("Pokemon - Black Version (USA, Europe) (NDSi Enhanced).nds") {
            let icons = NDSIcons.extract(bw)
            print("Black icons:", icons.count)
            #expect(icons.count == 493)
            for s in [25, 1, 495, 498, 501, 643, 644] { try icons[s]?.png?.write(to: URL(fileURLWithPath: "\(folder)/bw-\(s).png")) }
        }
    }
}
