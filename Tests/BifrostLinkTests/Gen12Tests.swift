import Testing
@testable import BifrostLink

func sampleMon(species: Int, level: Int = 30) -> Mon {
    var m = Mon()
    m.species = species
    m.level = level
    m.exp = PokeData.shared.exp(forLevel: level, species: species)
    m.otName = "ASH"
    m.tid = 12345
    m.sid = 54321
    m.pid = 0x1234_5678
    m.ivs = [31, 30, 29, 28, 27, 26]
    m.evs = [4, 8, 12, 16, 20, 24]
    m.moves = [33, 45, 0, 0]
    m.healPP()
    m.friendship = 120
    m.nature = Int(m.pid % 25)
    return m
}

@Suite struct Gen12Tests {
    @Test func gen1SyntheticRoundTrip() throws {
        var blank = [UInt8](repeating: 0, count: 0x8000)
        blank[0x2F2C] = 0; blank[0x2F2D] = 0xFF
        blank[0x30C0] = 0; blank[0x30C1] = 0xFF
        let save = try SaveGen1(data: blank, hint: .red)
        try save.set(sampleMon(species: 25), at: .party(0))
        try save.set(sampleMon(species: 150, level: 70), at: .box(0, 0))
        try save.set(sampleMon(species: 1, level: 5), at: .box(3, 0))
        let out = try save.serialize()
        let again = try SaveGen1(data: out, hint: .red)
        #expect(again.checksumValid)
        #expect(again.party().first?.species == 25)
        #expect(again.party().first?.level == 30)
        #expect(again.party().first?.otName == "ASH")
        #expect(again.mon(at: .box(0, 0))?.species == 150)
        #expect(again.mon(at: .box(3, 0))?.species == 1)
        #expect(again.party().first?.moves == [33, 45, 0, 0])
        #expect(try again.serialize() == out)
    }

    @Test func gen2SyntheticRoundTrip() throws {
        var blank = [UInt8](repeating: 0, count: 0x8000 + 48)
        blank[0x288A] = 0; blank[0x288B] = 0xFF
        blank[0x2D6C] = 0; blank[0x2D6D] = 0xFF
        let save = try SaveGen2(data: blank, hint: .gold)
        var togepi = sampleMon(species: 175, level: 12)
        togepi.heldItem = 1     // Master Ball, exists in Gen 2
        try save.set(togepi, at: .party(0))
        try save.set(sampleMon(species: 249, level: 45), at: .box(8, 0))
        let out = try save.serialize()
        #expect(out.count == blank.count)
        let again = try SaveGen2(data: out, hint: .gold)
        #expect(again.checksumValid)
        #expect(again.party().first?.species == 175)
        #expect(again.party().first?.heldItem == 1)
        #expect(again.mon(at: .box(8, 0))?.species == 249)
        #expect(try again.serialize() == out)
    }
}
