import Testing
@testable import BifrostLink

@Suite struct Gen67Tests {
    @Test(arguments: ["3ds-00055e00.main", "3ds-0011c500.main", "3ds-001b5100.main"])
    func realSaves(name: String) throws {
        guard let bytes = Fixtures.load(name) else { return }
        let save = try Save3DS(data: bytes, hint: nil)
        #expect(save.checksumsValid)
        print(name, save.game, save.trainerName, save.trainerID, save.secretID, save.boxName(0))
        for m in save.party() {
            print("  party:", m.speciesName, "Lv", m.level, m.nickname, m.moves.map(PokeData.shared.moveName), PokeData.shared.itemName(m.heldItem),
                  PokeData.shared.natureName(m.nature), PokeData.shared.abilityName(m.ability), m.stats, m.isShiny)
            var copy = m
            copy.recalculateStats()
            #expect(copy.stats == m.stats, "\(m.speciesName) stats")
        }
        let boxed = save.allSlots.filter { $0.0.area == .box }
        print("  boxed:", boxed.count, boxed.prefix(8).map { $0.1.speciesName })
        #expect(try save.serialize() == bytes)
        for (slot, m) in save.allSlots {
            var d = Array(m.raw.prefix(PK67.storedSize))
            PK67.encodeCommon(m, into: &d, gen: save.game.generation, game: save.game)
            #expect(d == Array(m.raw.prefix(PK67.storedSize)), "\(slot.label) \(m.speciesName)")
        }
        if let first = save.party().first, let free = save.firstFreeBoxSlot() {
            try save.set(first, at: free)
            save.registerDex(first)
            let out = try save.serialize()
            let again = try Save3DS(data: out, hint: nil)
            #expect(again.checksumsValid)
            #expect(again.mon(at: free)?.pid == first.pid)
        }
    }
}
