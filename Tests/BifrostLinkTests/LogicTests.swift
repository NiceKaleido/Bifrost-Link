import Testing
@testable import BifrostLink

@Suite struct LogicTests {
    @Test func transfersFromUltraMoon() throws {
        guard let bytes = Fixtures.load("3ds-001b5100.main") else { return }
        let um = try Save3DS(data: bytes, hint: nil)
        let party = um.party()
        let gyarados = try #require(party.first { $0.species == 130 })
        let incineroar = try #require(party.first { $0.species == 727 })
        let pikachu = try #require(party.first { $0.species == 25 })

        let blocked = MonTransfer.plan(incineroar, from: .ultraMoon, to: .emerald)
        #expect(!blocked.isPossible)
        print("Incineroar → Emerald:", blocked.blocked ?? "")

        let cap = MonTransfer.plan(pikachu, from: .ultraMoon, to: .fireRed)
        #expect(!cap.isPossible)
        print("Cap Pikachu → FireRed:", cap.blocked ?? "")

        let plan = MonTransfer.plan(gyarados, from: .ultraMoon, to: .fireRed)
        #expect(plan.isPossible)
        #expect(!plan.native)
        print("Gyarados → FireRed:"); plan.changes.forEach { print("  -", $0) }
        let g = plan.mon
        #expect(g.moves.allSatisfy { $0 <= 354 })
        #expect(g.heldItem == 0)
        #expect(Int(g.pid % 25) == gyarados.nature)
        #expect(g.isShiny == gyarados.isShiny)

        // Write into a Gen 3 save and read back
        let fr = try SaveGen3(data: Gen3Tests.blankSave(frlg: true))
        try fr.set(g, at: .box(0, 0))
        let back = try #require(try SaveGen3(data: fr.serialize()).mon(at: .box(0, 0)))
        #expect(back.species == 130 && back.level == gyarados.level && back.nature == gyarados.nature && back.ivs == gyarados.ivs)

        // And forward again into Scarlet (HOME-style, native)
        let toSV = MonTransfer.plan(back, from: .fireRed, to: .scarlet)
        print("FireRed Gyarados → Scarlet:", toSV.native, toSV.changes)
        #expect(toSV.isPossible)

        // Down to Gen 1 keeps the level, drops what Gen 1 lacks
        let toRed = MonTransfer.plan(gyarados, from: .ultraMoon, to: .red)
        #expect(toRed.isPossible)
        #expect(toRed.mon.moves.allSatisfy { $0 <= 165 })
        print("Gyarados → Red:", toRed.changes)
    }

    @Test func tradeEvolutions() {
        var kadabra = sampleMon(species: 64, level: 30)
        kadabra.isNicknamed = false
        let options = TradeEvolution.options(for: kadabra, in: .fireRed)
        #expect(options.map(\.option.to) == [65])
        let result = TradeEvolution.evolve(kadabra, into: options[0].option, in: .fireRed)
        #expect(result.mon.species == 65)
        #expect(result.mon.nickname == "Alakazam")

        var onix = sampleMon(species: 95, level: 25)
        onix.heldItem = 0
        let onixOptions = TradeEvolution.options(for: onix, in: .gold)
        #expect(onixOptions.first?.option.to == 208)
        #expect(onixOptions.first?.needsItem == true)
        #expect(TradeEvolution.options(for: onix, in: .red).isEmpty)   // Steelix isn't in Gen 1
        onix.heldItem = onixOptions[0].option.heldItem
        let steelix = TradeEvolution.evolve(onix, into: onixOptions[0].option, in: .gold)
        #expect(steelix.mon.heldItem == 0)

        let karrablast = sampleMon(species: 588, level: 20)
        #expect(TradeEvolution.options(for: karrablast, in: .black).first?.option.to == 589)
        #expect(TradeEvolution.options(for: sampleMon(species: 64), in: .legendsZA).isEmpty == !PKGame.legendsZA.canStore(species: 65))
    }

    @Test func moveOptions() {
        let charmander = sampleMon(species: 4, level: 20)
        let options = MoveSuggester.options(for: charmander, in: .fireRed, includeAll: false)
        #expect(options.contains { $0.move == 52 })        // Ember
        #expect(!options.contains { $0.move == 53 })       // Flamethrower is learned later
        let all = MoveSuggester.options(for: charmander, in: .fireRed, includeAll: true)
        #expect(all.count > options.count)
        let latest = MoveSuggester.latestLevelUp(for: charmander, in: .fireRed)
        print("Charmander Lv20 FRLG:", latest.map(PokeData.shared.moveName))
        #expect(latest.contains(52))
        #expect(!MoveSuggester.moveExists(237, in: .scarlet))   // Hidden Power was removed
        #expect(MoveSuggester.moveExists(85, in: .scarlet))     // Thunderbolt
    }
}
