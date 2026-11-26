import Testing
@testable import BifrostLink

@MainActor
@Suite struct OrganizeTests {
    func open(_ file: SaveFile) -> OpenSave {
        OpenSave(found: FoundSave(remote: "/test/\(file.game.rawValue)", companions: [], source: "Test"), file: file)
    }

    @Test func ultraMoonSwapMoveSortUndo() throws {
        guard let bytes = Fixtures.load("3ds-001b5100.main") else { return }
        let hub = PokemonHub()
        let save = open(try Save3DS(data: bytes, hint: nil))
        let total = save.file.allSlots.count
        let a = try #require(save.file.mon(at: .box(0, 0))), b = try #require(save.file.mon(at: .box(0, 1)))
        try hub.organize(save, from: .box(0, 0), to: .box(0, 1))                 // swap
        #expect(save.file.mon(at: .box(0, 0))?.pid == b.pid && save.file.mon(at: .box(0, 1))?.pid == a.pid)
        let free = try #require(save.file.firstFreeBoxSlot())
        try hub.organize(save, from: .box(0, 0), to: free)                       // move to empty
        #expect(save.file.mon(at: free)?.pid == b.pid && save.file.mon(at: .box(0, 0)) == nil)
        try hub.organize(save, from: .party(0), to: .box(free.box, free.index + 1)) // party → box
        #expect(save.file.party().count == 7 - 1 || save.file.party().count == 5)
        try hub.sortBoxes(save, by: .level, ascending: false)
        let levels = (0..<save.file.boxCount).flatMap { save.file.boxContents($0) }.compactMap { $0 }.map(\.level)
        #expect(levels == levels.sorted(by: >))
        try hub.sortBoxes(save, by: .level, ascending: true)
        let up = (0..<save.file.boxCount).flatMap { save.file.boxContents($0) }.compactMap { $0 }.map(\.level)
        #expect(up == up.sorted())
        #expect(save.file.boxContents(0).allSatisfy { $0 != nil })   // packed from the first box
        #expect(save.file.allSlots.count == total)
        #expect(hub.hasUnsavedChanges(save))
        let reread = try Save3DS(data: save.file.serialize(), hint: nil)
        #expect(reread.checksumsValid && reread.allSlots.count == total)
        hub.discardChanges(save)
        #expect(!hub.hasUnsavedChanges(save))
    }

    @Test func gameBoyPackedBoxes() throws {
        var blank = [UInt8](repeating: 0, count: 0x8000)
        blank[0x2F2C] = 0; blank[0x2F2D] = 0xFF; blank[0x30C0] = 0; blank[0x30C1] = 0xFF
        let file = try SaveGen1(data: blank, hint: .red)
        try file.set(sampleMon(species: 25), at: .party(0))
        for (i, s) in [1, 4, 7, 150].enumerated() { try file.set(sampleMon(species: s), at: .box(0, i)) }
        let hub = PokemonHub()
        let save = open(file)
        try hub.organize(save, from: .box(0, 0), to: .box(0, 3))   // swap Bulbasaur ↔ Mewtwo
        #expect(file.boxContents(0).compactMap { $0 }.map(\.species) == [150, 4, 7, 1])
        try hub.organize(save, from: .box(0, 1), to: .box(1, 0))   // move Charmander to box 2
        #expect(file.boxContents(0).compactMap { $0 }.map(\.species) == [150, 7, 1])
        #expect(file.mon(at: .box(1, 0))?.species == 4)
        try hub.sortBoxes(save, by: .dex)
        #expect(file.boxContents(0).compactMap { $0 }.map(\.species) == [1, 4, 7, 150])
        #expect(file.mon(at: .box(1, 0)) == nil)
        let again = try SaveGen1(data: file.serialize(), hint: .red)
        #expect(again.checksumValid && again.allSlots.count == 5)
    }
}

@MainActor
@Suite struct EditTests {
    @Test func renameReleaseEvolve() throws {
        guard let bytes = Fixtures.load("bdsp.bin") else { return }
        let hub = PokemonHub()
        let file = try SaveBDSP(data: bytes, hint: .brilliantDiamond)
        let save = OpenSave(found: FoundSave(remote: "/t/bdsp", companions: [], source: "Test"), file: file)
        let first = try #require(file.party().first)
        try hub.edit(save, slot: .party(0), to: PokemonHub.renamed(first, to: "Sparky the great", in: file.game))
        #expect(file.party().first?.nickname == "Sparky the g")             // 12 characters max
        try hub.edit(save, slot: .party(0), to: PokemonHub.renamed(file.party()[0], to: "", in: file.game))
        #expect(file.party().first?.isNicknamed == false)
        // Kadabra in the party evolves by trade
        let kadabraSlot = try #require(file.allSlots.first { $0.1.species == 64 })
        let option = try #require(TradeEvolution.options(for: kadabraSlot.1, in: file.game).first?.option)
        try hub.edit(save, slot: kadabraSlot.0, to: TradeEvolution.evolve(kadabraSlot.1, into: option, in: file.game).mon)
        #expect(file.mon(at: kadabraSlot.0)?.species == 65)
        // Release a boxed one
        let boxed = try #require(file.allSlots.first { $0.0.area == .box })
        let before = file.allSlots.count
        try hub.release(save, slot: boxed.0)
        #expect(file.allSlots.count == before - 1)
        let again = try SaveBDSP(data: file.serialize(), hint: .brilliantDiamond)
        #expect(again.integrityProblem == nil)
        #expect(again.allSlots.contains { $0.1.species == 65 })
    }
}

@MainActor
@Suite struct BatchReleaseTests {
    @Test func releaseSeveral() throws {
        var blank = [UInt8](repeating: 0, count: 0x8000)
        blank[0x2F2C] = 0; blank[0x2F2D] = 0xFF; blank[0x30C0] = 0; blank[0x30C1] = 0xFF
        let file = try SaveGen1(data: blank, hint: .red)
        try file.set(sampleMon(species: 25), at: .party(0))
        for (i, s) in [1, 4, 7, 10, 13].enumerated() { try file.set(sampleMon(species: s), at: .box(0, i)) }
        let hub = PokemonHub()
        let save = OpenSave(found: FoundSave(remote: "/t/red", companions: [], source: "Test"), file: file)
        try hub.releaseMany(save, slots: [.box(0, 1), .box(0, 3)])            // Charmander, Caterpie
        #expect(file.boxContents(0).compactMap { $0 }.map(\.species) == [1, 7, 13])
        #expect(throws: PKError.self) { try hub.releaseMany(save, slots: [.party(0)]) }   // last party member stays
        #expect(try SaveGen1(data: file.serialize(), hint: .red).integrityProblem == nil)
    }
}
