import Testing
@testable import BifrostLink

@Suite struct RealSwitchTests {
    @Test(arguments: ["bdsp.bin", "bdsp-backup.bin", "za.main"])
    func open(name: String) throws {
        guard let bytes = Fixtures.load(name) else { return }
        var hint = SaveDetector.Hint(fileName: name)
        if name.hasPrefix("bdsp") { hint.titleID = "0100000011D90000" }
        if name == "za.main" { hint.titleID = "0100F43008C44000" }
        let save = try SaveDetector.open(bytes, hint: hint)
        print(name, save.game, save.trainerName, save.trainerID, "boxes", save.boxCount, "slots", save.allSlots.count)
        if let bdsp = save as? SaveBDSP {
            #expect(bdsp.checksumValid)
            #expect(try bdsp.serialize() == bytes)
            // Edit a move on a party member and read it back
            var m = try #require(bdsp.party().first)
            m.moves[3] = 86
            try bdsp.set(m, at: .party(0))
            let again = try SaveBDSP(data: try bdsp.serialize(), hint: .brilliantDiamond)
            #expect(again.checksumValid)
            #expect(again.party().first?.moves[3] == 86)
            #expect(again.party().count == 6)
            #expect(again.allSlots.count == save.allSlots.count)
            // Untouched Pokémon keep their exact bytes
            for (slot, mon) in again.allSlots.dropFirst() { #expect(mon.raw == save.mon(at: slot)?.raw, "\(slot.label)") }
        }
        for m in save.party() { print("  party:", m.speciesName, "Lv", m.level, m.moves.map(PokeData.shared.moveName), m.stats) }
        print("  first boxed:", save.allSlots.filter { $0.0.area == .box }.prefix(8).map { "\($0.1.speciesName) Lv\($0.1.level)" })
    }
}

@Suite struct BatchMoveTests {
    @Test func ultraMoonToBrilliantDiamond() throws {
        guard let um = Fixtures.load("3ds-001b5100.main"), let bd = Fixtures.load("bdsp.bin") else { return }
        let source = try Save3DS(data: um, hint: nil)
        let target = try SaveBDSP(data: bd, hint: .brilliantDiamond)
        let boxed = source.allSlots.filter { $0.0.area == .box }.prefix(6)
        let plans = boxed.map { (slot: $0.0, plan: MonTransfer.plan($0.1, from: source.game, to: target.game)) }
        let movable = plans.filter { $0.plan.isPossible }
        print("moving:", plans.map { "\($0.plan.mon.name)\($0.plan.isPossible ? "" : " (blocked)")" })
        let beforeSource = source.allSlots.count, beforeTarget = target.allSlots.count
        let placed = try PokemonHub.applyMoves(movable, from: source, to: target)
        #expect(placed.count == movable.count)
        #expect(source.allSlots.count == beforeSource - movable.count)
        let bd2 = try SaveBDSP(data: target.serialize(), hint: .brilliantDiamond)
        #expect(bd2.checksumValid)
        #expect(bd2.allSlots.count == beforeTarget + movable.count)
        for (slot, item) in zip(placed, movable) {
            let m = try #require(bd2.mon(at: slot))
            #expect(m.species == item.plan.mon.species && m.level == item.plan.mon.level && m.ivs == item.plan.mon.ivs)
        }
        let um2 = try Save3DS(data: source.serialize(), hint: nil)
        #expect(um2.checksumsValid)
    }
}
