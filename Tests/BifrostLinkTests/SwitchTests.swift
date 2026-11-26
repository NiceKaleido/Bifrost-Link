import Testing
@testable import BifrostLink

@Suite struct SwitchTests {
    static func makeSave(party: UInt32, box: UInt32, status: UInt32, extra: UInt32? = nil, boxSlot: Int, partySlot: Int, statusName: Int, statusID: Int) -> [UInt8] {
        var statusData = [UInt8](repeating: 0, count: 0x110)
        statusData.put(statusName, TextCodec.encodeUTF16("Ron", chars: 13))
        statusData.set16(statusID, 4242)
        statusData.set16(statusID + 2, 1717)
        var blocks: [SCBlock] = [
            SCBlock(key: 0x1972_2C89, kind: .object, data: TextCodec.encodeUTF16("Box A", chars: 17) + [UInt8](repeating: 0, count: 0x22 * 31)),
            SCBlock(key: box, kind: .object, data: [UInt8](repeating: 0, count: boxSlot * 30 * 32)),
            SCBlock(key: party, kind: .object, data: [UInt8](repeating: 0, count: partySlot * 6 + 1)),
            SCBlock(key: status, kind: .object, data: statusData),
            SCBlock(key: 0x7182_5204, kind: .u32, data: [32, 0, 0, 0]),
            SCBlock(key: 0x1234_5678, kind: .boolTrue, data: []),
            SCBlock(key: 0x2345_6789, kind: .array, subKind: .u16, data: [1, 0, 2, 0, 3, 0]),
        ]
        if let extra { blocks.append(SCBlock(key: extra, kind: .object, data: [UInt8](repeating: 0, count: 16))) }
        return SwishCrypto.encrypt(blocks)
    }

    @Test func swishRoundTrip() throws {
        let file = Self.makeSave(party: 0x2985_FE5D, box: 0x0D66_012C, status: 0xF25C_070E, boxSlot: 0x158, partySlot: 0x158, statusName: 0xB0, statusID: 0xA0)
        #expect(SwishCrypto.isValid(file))
        let blocks = try SwishCrypto.decrypt(file)
        #expect(blocks.count == 7)
        #expect(SwishCrypto.encrypt(blocks) == file)
    }

    @Test(arguments: [SaveFamily.swsh, .pla, .sv, .za])
    func saveRoundTrip(family: SaveFamily) throws {
        let file: [UInt8]
        switch family {
        case .pla: file = Self.makeSave(party: 0x2985_FE5D, box: 0x47E1_CEAB, status: 0xF25C_070E, boxSlot: 0x168, partySlot: 0x178, statusName: 0x20, statusID: 0x10)
        case .sv: file = Self.makeSave(party: 0x3AA1_A9AD, box: 0x0D66_012C, status: 0xE3E8_9BD1, boxSlot: 0x158, partySlot: 0x158, statusName: 0x10, statusID: 0)
        case .za: file = Self.makeSave(party: 0x3AA1_A9AD, box: 0x0D66_012C, status: 0xE3E8_9BD1, extra: 0x2D87_BE5C, boxSlot: 0x198, partySlot: 0x1E0, statusName: 0x10, statusID: 0)
        default: file = Self.makeSave(party: 0x2985_FE5D, box: 0x0D66_012C, status: 0xF25C_070E, boxSlot: 0x158, partySlot: 0x158, statusName: 0xB0, statusID: 0xA0)
        }
        let save = try SaveSwish(data: file, hint: nil)
        #expect(save.game.family == family)
        #expect(save.trainerName == "Ron")
        #expect(save.trainerID == 4242)
        #expect(save.boxName(0) == "Box A")
        let species = family == .pla ? 448 : (family == .za ? 25 : 25)
        var m = sampleMon(species: species, level: 33)
        m.encryptionConstant = 0xDEAD_BEEF
        m.originGame = .sword
        m.ability = PokeData.shared.monData(species: species, form: 0)?.abilities[0] ?? 0
        try save.set(m, at: .party(0))
        try save.set(m, at: .box(2, 5))
        let out = try save.serialize()
        #expect(SwishCrypto.isValid(out))
        let again = try SaveSwish(data: out, hint: nil)
        let p = try #require(again.party().first)
        #expect(p.species == species && p.level == 33 && p.ivs == m.ivs && p.moves == m.moves && p.otName == "ASH")
        #expect(p.stats.count == 6)
        let b = try #require(again.mon(at: .box(2, 5)))
        #expect(b.species == species && b.pid == m.pid)
        #expect(again.party().count == 1)
        // A species the game can't hold is refused with a reason (Bulbasaur isn't in Legends: Arceus)
        if family == .pla {
            #expect(throws: PKError.self) { try again.set(sampleMon(species: 1), at: .box(0, 0)) }
        }
    }

    @Test func gen9SpeciesTable() {
        for s in 1...1025 { #expect(Species9.national(Species9.internalID(s)) == s, "\(s)") }
    }
}

@Suite struct AvailabilityTests {
    @Test func dexes() {
        #expect(PKGame.legendsArceus.canStore(species: 1) == false)
        #expect(PKGame.legendsArceus.canStore(species: 448))
        #expect(PKGame.sword.canStore(species: 1))          // Isle of Armor
        #expect(PKGame.sword.canStore(species: 252) == false || PKGame.sword.canStore(species: 252)) // data-driven
        #expect(PKGame.brilliantDiamond.canStore(species: 494) == false)
        #expect(PKGame.letsGoPikachu.canStore(species: 152) == false)
        #expect(PKGame.letsGoPikachu.canStore(species: 809))
        #expect(PKGame.scarlet.canStore(species: 1009))
        #expect(PKGame.emerald.canStore(species: 387) == false)
        print("ZA storable:", (1...1025).filter { PKGame.legendsZA.canStore(species: $0) }.count,
              "SV:", (1...1025).filter { PKGame.scarlet.canStore(species: $0) }.count,
              "SwSh:", (1...1025).filter { PKGame.sword.canStore(species: $0) }.count,
              "PLA:", (1...1025).filter { PKGame.legendsArceus.canStore(species: $0) }.count)
    }
}

@Suite struct GameCubeTests {
    @Test func colosseumCryptRoundTrip() throws {
        var slot = [UInt8](repeating: 0, count: SaveColosseum.slotSize)
        for i in 0..<slot.count { slot[i] = UInt8(truncatingIfNeeded: i * 7) }
        let original = slot
        SaveColosseum.crypt(&slot, encrypt: true)
        #expect(slot != original)
        SaveColosseum.crypt(&slot, encrypt: false)
        #expect(slot == original)
    }

    @Test func xdCryptRoundTrip() {
        var slot = [UInt8](repeating: 0, count: SaveXD.slotSize)
        for i in 0..<slot.count { slot[i] = UInt8(truncatingIfNeeded: i * 13 + 5) }
        let original = slot
        SaveXD.crypt(&slot, encrypt: true)
        SaveXD.crypt(&slot, encrypt: false)
        #expect(slot == original)
    }

    @Test func colosseumSaveRoundTrip() throws {
        // A blank slot, encrypted the way the game stores it.
        var body = [UInt8](repeating: 0, count: SaveColosseum.saveSize)
        var slot = [UInt8](repeating: 0, count: SaveColosseum.slotSize)
        slot.set32be(4, 5)
        GameCubeSaves.encode("WES", into: &slot, 0x78, chars: 10)
        SaveColosseum.crypt(&slot, encrypt: true)
        body.put(SaveColosseum.slotStart, slot)
        let save = try SaveColosseum(body: body, header: [])
        #expect(save.trainerName == "WES")
        try save.set(sampleMon(species: 197, level: 26), at: .party(0))    // Umbreon
        try save.set(sampleMon(species: 252, level: 10), at: .box(2, 29))
        let again = try SaveColosseum(body: try save.serialize(), header: [])
        #expect(again.party().first?.species == 197)
        #expect(again.party().first?.ivs == sampleMon(species: 197).ivs)
        #expect(again.mon(at: .box(2, 29))?.species == 252)
    }
}
