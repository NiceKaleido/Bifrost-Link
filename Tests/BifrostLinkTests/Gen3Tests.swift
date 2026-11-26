import Testing
@testable import BifrostLink

@Suite struct Gen3Tests {
    /// A blank 128 KB save with valid sector ids in slot 0, FireRed-style (fixed 1 at 0xAC).
    static func blankSave(frlg: Bool) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 0x20000)
        for i in 0..<14 {
            let ofs = i * 0x1000
            d.set16(ofs + 0xFF4, i)
            d.set32(ofs + 0xFF8, 0x0801_2025)
            d.set32(ofs + 0xFFC, 1)
        }
        if frlg { d.set32(0xAC, 1) }
        d.put(0, TextCodec.encodeGen3("RED", length: 7))
        d.set8(7, 0xFF)
        return d
    }

    @Test(arguments: [true, false])
    func syntheticRoundTrip(frlg: Bool) throws {
        let save = try SaveGen3(data: Self.blankSave(frlg: frlg))
        #expect(save.trainerName == "RED")
        var treecko = sampleMon(species: 252, level: 20)  // internal index differs from national from here on
        treecko.heldItem = 1
        treecko.ball = 4
        treecko.originGame = .emerald
        try save.set(treecko, at: .party(0))
        try save.set(sampleMon(species: 386, level: 50), at: .box(13, 29))
        try save.set(sampleMon(species: 201), at: .box(0, 0))
        let out = try save.serialize()
        let again = try SaveGen3(data: out)
        #expect(again.checksumsValid)
        let p = try #require(again.party().first)
        #expect(p.species == 252)
        #expect(p.level == 20)
        #expect(p.heldItem == 1)
        #expect(p.ivs == treecko.ivs)
        #expect(p.evs == treecko.evs)
        #expect(p.moves == treecko.moves)
        #expect(p.otName == "ASH")
        #expect(p.tid == 12345 && p.sid == 54321)
        #expect(p.stats.count == 6 && p.stats[0] > 0)
        #expect(again.mon(at: .box(13, 29))?.species == 386)
        #expect(again.mon(at: .box(0, 0))?.form == PK3.unownForm(pid: 0x1234_5678))
        #expect(try again.serialize() == out)
        // Removing works and leaves an empty slot
        try again.set(nil, at: .box(13, 29))
        #expect(again.mon(at: .box(13, 29)) == nil)
    }
}
