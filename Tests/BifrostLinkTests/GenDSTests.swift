import Testing
@testable import BifrostLink

@Suite struct GenDSTests {
    @Test func blackRealSave() throws {
        guard let bytes = Fixtures.load("black.sav") else { return }
        let save = try SaveGen5(data: bytes, hint: .black)
        #expect(save.checksumsValid)
        print("black", save.game, save.trainerName, save.trainerID, save.secretID)
        for m in save.party() { print("  party:", m.speciesName, "Lv", m.level, m.nickname, m.moves.map(PokeData.shared.moveName), PokeData.shared.itemName(m.heldItem), PokeData.shared.natureName(m.nature), PokeData.shared.abilityName(m.ability), m.stats) }
        let boxed = save.allSlots.filter { $0.0.area == .box }
        print("  boxed:", boxed.count, boxed.prefix(6).map { $0.1.speciesName }, "box1:", save.boxName(0))
        #expect(try save.serialize() == bytes)
        for (slot, m) in save.allSlots {
            #expect(try PK45.encodePlain(m, gen: 5, game: save.game) == Array(m.raw.prefix(136)), "\(slot.label) \(m.speciesName)")
        }
        // Party stats recompute to what the game stored
        for m in save.party() {
            var copy = m
            copy.recalculateStats()
            #expect(copy.stats == m.stats, "\(m.speciesName) stats")
        }
        // Write a party member into a box and read it back
        if let first = save.party().first, let free = save.firstFreeBoxSlot() {
            try save.set(first, at: free)
            let out = try save.serialize()
            let again = try SaveGen5(data: out, hint: .black)
            #expect(again.checksumsValid)
            #expect(again.mon(at: free)?.species == first.species)
            #expect(again.mon(at: free)?.nickname == first.nickname)
        }
    }

    @Test func gen4Synthetic() throws {
        // Blank Platinum layout: valid footers in partition 0.
        var d = [UInt8](repeating: 0, count: 0x80000)
        for (start, size) in [(0, 0xCF2C), (0xCF2C, 0x121E4)] {
            d.set32(start + size - 0x14, 1)
            d.set32(start + size - 0xC, UInt32(size))
            d.set32(start + size - 8, 0x2006_0623)
        }
        for (start, size) in [(0x40000, 0xCF2C), (0x40000 + 0xCF2C, 0x121E4)] {
            d.set32(start + size - 0xC, UInt32(size))
            d.set32(start + size - 8, 0x2006_0623)
        }
        let save = try SaveGen4(data: d, hint: nil)
        #expect(save.game == .platinum)
        var m = sampleMon(species: 448, level: 40)
        m.nickname = "Lucario"; m.isNicknamed = false
        m.ability = 80
        m.gender = 0
        try save.set(m, at: .party(0))
        try save.set(sampleMon(species: 493, level: 80), at: .box(17, 29))
        let out = try save.serialize()
        let again = try SaveGen4(data: out, hint: nil)
        #expect(again.checksumsValid)
        let p = try #require(again.party().first)
        #expect(p.species == 448 && p.level == 40 && p.otName == "ASH" && p.ivs == m.ivs && p.moves == m.moves)
        #expect(again.mon(at: .box(17, 29))?.species == 493)
        #expect(try again.serialize() == out)
    }
}
