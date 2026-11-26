import Testing
@testable import BifrostLink

@MainActor
@Suite struct IntegrityTests {
    func open(_ name: String) throws -> SaveFile? {
        guard let bytes = Fixtures.load(name) else { return nil }
        var hint = SaveDetector.Hint(fileName: name)
        if name.hasPrefix("bdsp") { hint.titleID = "0100000011D90000" }
        if name.hasPrefix("za") { hint.titleID = "0100F43008C44000" }
        return try SaveDetector.open(bytes, hint: hint)
    }

    /// Every real save as the game wrote it must pass; otherwise the checks would block good saves.
    @Test(arguments: ["3ds-00055e00.main", "3ds-0011c500.main", "3ds-001b5100.main", "black.sav", "bdsp.bin", "za.main"])
    func originalsPass(name: String) throws {
        guard let save = try open(name) else { return }
        #expect(save.integrityProblem == nil, "\(name): \(save.integrityProblem ?? "")")
    }

    /// The file that broke Ultra Moon is caught.
    @Test func brokenUltraMoonIsCaught() throws {
        guard let save = try open("um-after.main") else { return }
        #expect(save.integrityProblem != nil)
    }

    /// Changed files from every real save pass every check the game does.
    @Test(arguments: ["3ds-00055e00.main", "3ds-0011c500.main", "3ds-001b5100.main", "bdsp.bin"])
    func changedFilesPass(name: String) throws {
        guard let save = try open(name), let first = save.allSlots.first(where: { $0.0.area == .box }), let free = save.firstFreeBoxSlot() else { return }
        let hub = PokemonHub()
        let open = OpenSave(found: FoundSave(remote: "/t/\(name)", companions: [], source: "Test"), file: save)
        try hub.organize(open, from: first.0, to: free)
        try hub.sortBoxes(open, by: .level)
        let out = try save.serialize()
        var hint = SaveDetector.Hint(fileName: name)
        if name.hasPrefix("bdsp") { hint.titleID = "0100000011D90000" }
        let again = try SaveDetector.open(out, hint: hint)
        #expect(again.integrityProblem == nil, "\(name): \(again.integrityProblem ?? "")")
        #expect(again.allSlots.count == save.allSlots.count)
        if name == "3ds-001b5100.main" { #expect(MemeCrypto.verify(out)) }
    }

    @Test func syntheticFormatsPass() throws {
        let gen3 = try SaveGen3(data: Gen3Tests.blankSave(frlg: true))
        try gen3.set(sampleMon(species: 25), at: .box(0, 0))
        #expect(try SaveGen3(data: gen3.serialize()).integrityProblem == nil)
        var g2 = [UInt8](repeating: 0, count: 0x8000 + 48)
        g2[0x288A] = 0; g2[0x288B] = 0xFF; g2[0x2D6C] = 0; g2[0x2D6D] = 0xFF
        let gen2 = try SaveGen2(data: g2, hint: .gold)
        try gen2.set(sampleMon(species: 152), at: .party(0))
        #expect(try SaveGen2(data: gen2.serialize(), hint: .gold).integrityProblem == nil)
    }
}
