import Foundation

/// PK3: the 80-byte (box) / 100-byte (party) Gen 3 Pokémon, shared by RSE, FRLG and Box RS.
enum PK3 {
    static let storedSize = 80
    static let partySize = 100

    /// Decrypts the 48-byte data area and puts the substructures in G/A/E/M order.
    static func decrypt(_ stored: [UInt8]) -> [UInt8] {
        var d = stored
        let key = d.u32(0) ^ d.u32(4)
        var o = 32
        while o < 80 { d.set32(o, d.u32(o) ^ key); o += 4 }
        return PKXCrypto.unshuffle(d, start: 32, blockSize: 12, shuffle: Int(d.u32(0) % 24))
    }

    static func encrypt(_ plain: [UInt8]) -> [UInt8] {
        var d = plain
        d.set16(0x1C, PKXCrypto.sum16(d, range: 32..<80))
        d = PKXCrypto.shuffle(d, start: 32, blockSize: 12, shuffle: Int(d.u32(0) % 24))
        let key = d.u32(0) ^ d.u32(4)
        var o = 32
        while o < 80 { d.set32(o, d.u32(o) ^ key); o += 4 }
        return d
    }

    static func checksumValid(_ plain: [UInt8]) -> Bool {
        plain.u16(0x1C) == PKXCrypto.sum16(plain, range: 32..<80)
    }

    static func internalToNational(_ index: Int) -> Int {
        if index <= 251 { return index }
        let pid = PokeData.shared.gameIndex[7]?[index] ?? 0
        return PokeData.shared.mons[pid]?.species ?? 0
    }

    static func nationalToInternal(_ species: Int) -> Int {
        if species <= 251 { return species }
        guard let map = PokeData.shared.gameIndex[7] else { return 0 }
        return map.first { PokeData.shared.mons[$0.value]?.species == species }?.key ?? 0
    }

    static func unownForm(pid: UInt32) -> Int {
        let v = ((pid >> 24) & 3) << 6 | ((pid >> 16) & 3) << 4 | ((pid >> 8) & 3) << 2 | (pid & 3)
        return Int(v % 28)
    }

    // Growth at 32, Attacks at 44, EVs at 56, Misc at 68 (after unshuffling).
    static func decode(_ bytes: [UInt8], game: PKGame) -> Mon? {
        guard bytes.count >= storedSize, !bytes.slice(0, 80).isAllZero else { return nil }
        let d = decrypt(bytes)
        guard checksumValid(d) else { return nil }
        let speciesIndex = d.u16(32)
        guard speciesIndex != 0 else { return nil }
        var m = Mon()
        m.sourceFamily = game.family == .box ? .box : .gen3
        m.raw = d
        m.pid = d.u32(0)
        m.encryptionConstant = m.pid
        m.tid = d.u16(4)
        m.sid = d.u16(6)
        m.nickname = TextCodec.decodeGen3(d.slice(8, 10))
        m.language = d.u8(0x12)
        let flags = d.u8(0x13)
        m.otName = TextCodec.decodeGen3(d.slice(0x14, 7))
        m.markings = d.u8(0x1B)
        m.species = internalToNational(speciesIndex)
        m.heldItem = PokeData.shared.item(fromGame: d.u16(34), generation: 3)
        m.exp = Int(d.u32(36))
        let ppBonus = d.u8(40)
        m.ppUps = (0..<4).map { (ppBonus >> ($0 * 2)) & 3 }
        m.friendship = d.u8(41)
        m.moves = (0..<4).map { d.u16(44 + $0 * 2) }
        m.pp = (0..<4).map { d.u8(52 + $0) }
        m.evs = (0..<6).map { d.u8(56 + $0) }
        m.pokerus = d.u8(68)
        m.metLocation = d.u8(69)
        let origins = d.u16(70)
        m.metLevel = origins & 0x7F
        m.originGame = PKGame.from(originVersion: (origins >> 7) & 0xF)
        m.ball = (origins >> 11) & 0xF
        m.otGender = (origins >> 15) & 1
        let iv = d.u32(72)
        m.ivs = (0..<6).map { Int((iv >> (UInt32($0) * 5)) & 31) }
        m.isEgg = (iv >> 30) & 1 == 1 || flags & 4 != 0
        m.abilitySlot = Int(iv >> 31)
        m.fatefulEncounter = (d.u32(76) >> 31) & 1 == 1
        m.nature = Int(m.pid % 25)
        m.gender = Mon.gender(pid: m.pid, species: m.species)
        m.form = m.species == 201 ? unownForm(pid: m.pid) : 0
        if let abilities = PokeData.shared.monData(species: m.species, form: m.form)?.abilities {
            m.ability = abilities[min(m.abilitySlot, 1)]
        }
        m.level = PokeData.shared.level(forExp: m.exp, species: m.species)
        m.isNicknamed = !m.isEgg && m.nickname.caseInsensitiveCompare(PokeData.shared.speciesName(m.species)) != .orderedSame
        if bytes.count >= partySize {
            m.status = Int(bytes.u32(80))
            m.level = bytes.u8(84)
            m.currentHP = bytes.u16(86)
            m.stats = [bytes.u16(88), bytes.u16(90), bytes.u16(92), bytes.u16(94), bytes.u16(96), bytes.u16(98)]
        }
        return m
    }

    /// Builds the plain 80-byte structure, starting from the original bytes when they are PK3.
    static func encodePlain(_ m: Mon, game: PKGame) throws -> [UInt8] {
        let index = nationalToInternal(m.species)
        guard index > 0 else { throw PKError.unsupported("\(m.speciesName) doesn't exist in \(game.name).") }
        var d = (m.sourceFamily == .gen3 || m.sourceFamily == .box) && m.raw.count >= 80 ? Array(m.raw.prefix(80)) : [UInt8](repeating: 0, count: 80)
        d.set32(0, m.pid)
        d.set16(4, m.tid & 0xFFFF)
        d.set16(6, m.sid & 0xFFFF)
        let nick = m.isEgg ? "EGG" : (m.isNicknamed ? m.nickname : PokeData.shared.speciesName(m.species).uppercased())
        if TextCodec.decodeGen3(d.slice(8, 10)) != nick { d.put(8, TextCodec.encodeGen3(nick, length: 10)) }
        d.set8(0x12, m.isEgg ? 1 : min(max(m.language, 1), 7))
        d.set8(0x13, (m.isEgg ? 4 : 0) | 2)
        if TextCodec.decodeGen3(d.slice(0x14, 7)) != m.otName { d.put(0x14, TextCodec.encodeGen3(m.otName, length: 7)) }
        d.set8(0x1B, m.markings & 0xF)
        d.set16(32, index)
        d.set16(34, PokeData.shared.item(toGame: m.heldItem, generation: 3))
        let exp = m.exp > 0 ? m.exp : PokeData.shared.exp(forLevel: m.level, species: m.species)
        d.set32(36, UInt32(exp))
        d.set8(40, (0..<4).reduce(0) { $0 | (min(m.ppUps[$1], 3) << ($1 * 2)) })
        d.set8(41, m.isEgg ? min(m.friendship, 255) : min(m.friendship, 255))
        for i in 0..<4 {
            d.set16(44 + i * 2, m.moves[i])
            d.set8(52 + i, m.pp[i])
        }
        for i in 0..<6 { d.set8(56 + i, min(m.evs[i], 255)) }
        d.set8(68, m.pokerus)
        d.set8(69, m.metLocation & 0xFF)
        let origin = m.originGame.map { [.colosseum, .xd].contains($0) ? 15 : ($0.generation == 3 ? $0.originVersion : game.originVersion) } ?? game.originVersion
        let ball = (1...12).contains(m.ball) ? m.ball : 4
        d.set16(70, (m.metLevel & 0x7F) | (origin & 0xF) << 7 | ball << 11 | (m.otGender & 1) << 15)
        var iv: UInt32 = 0
        for i in 0..<6 { iv |= UInt32(min(m.ivs[i], 31)) << (UInt32(i) * 5) }
        if m.isEgg { iv |= 1 << 30 }
        if m.abilitySlot == 1 { iv |= 1 << 31 }
        d.set32(72, iv)
        var ribbons = d.u32(76) & 0x7FFF_FFFF
        if m.fatefulEncounter { ribbons |= 1 << 31 }
        d.set32(76, ribbons)
        return d
    }

    static func encode(_ m: Mon, game: PKGame, party: Bool) throws -> [UInt8] {
        let plain = try encodePlain(m, game: game)
        var out = encrypt(plain)
        if party {
            var full = m
            full.level = PokeData.shared.level(forExp: Int(plain.u32(36)), species: m.species)
            full.recalculateStats()
            out += [UInt8](repeating: 0, count: 20)
            out.set32(80, UInt32(m.status))
            out.set8(84, full.level)
            out.set8(85, 0xFF)
            out.set16(86, m.currentHP > 0 && m.currentHP <= full.stats[0] ? m.currentHP : full.stats[0])
            for i in 0..<6 { out.set16(88 + i * 2, full.stats[i]) }
        }
        return out
    }
}

/// Ruby, Sapphire, Emerald, FireRed and LeafGreen 128 KB flash saves.
final class SaveGen3: SaveFile {
    private static let sector = 0x1000
    private static let used = 0xF80
    private static let mainSize = 14 * sector

    private(set) var game: PKGame
    private var data: [UInt8]
    private let activeSlot: Int
    private var small: [UInt8]
    private var large: [UInt8]
    private var storage: [UInt8]
    let readOnlyReason: String?

    init(data: [UInt8], hint: PKGame? = nil) throws {
        guard data.count >= 0x20000 else { throw PKError.unsupported("Not a Gen 3 save (wrong size).") }
        self.data = Array(data.prefix(0x20000))
        let v0 = Self.allSectorsPresent(self.data, slot: 0)
        let v1 = Self.allSectorsPresent(self.data, slot: 1)
        guard v0 != nil || v1 != nil else { throw PKError.corrupt("The save's sectors are incomplete.") }
        if let s0 = v0, let s1 = v1 {
            let c0 = self.data.u32(s0 + 0xFFC), c1 = self.data.u32(s1 + 0xFFC)
            activeSlot = (c0 == .max && c1 != .max - 1) ? 1 : (c1 == .max && c0 != .max - 1) ? 0 : (c1 > c0 ? 1 : 0)
        } else {
            activeSlot = v0 != nil ? 0 : 1
        }
        small = [UInt8](repeating: 0, count: Self.used)
        large = [UInt8](repeating: 0, count: Self.used * 4)
        storage = [UInt8](repeating: 0, count: Self.used * 9)
        for i in 0..<14 {
            let ofs = activeSlot * Self.mainSize + i * Self.sector
            let id = self.data.u16(ofs + 0xFF4)
            let chunk = self.data.slice(ofs, Self.used)
            switch id {
            case 0: small = chunk
            case 1...4: large.put((id - 1) * Self.used, chunk)
            default: storage.put((id - 5) * Self.used, chunk)
            }
        }
        let japanese = small.u16(6) == 0
        // Version: FRLG has a fixed 1 at 0xAC, RS has nothing past 0x890, Emerald does.
        let marker = small.u32(0xAC)
        let family: [PKGame]
        if marker == 1 { family = [.fireRed, .leafGreen] }
        else if marker == 0 || small.slice(0x890, 0xF2C - 0x890).isAllZero { family = [.ruby, .sapphire] }
        else { family = [.emerald] }
        game = hint.flatMap { family.contains($0) ? $0 : nil } ?? family[0]
        readOnlyReason = japanese ? "Japanese Gen 3 saves can be viewed but not changed yet." : nil
    }

    private static func allSectorsPresent(_ data: [UInt8], slot: Int) -> Int? {
        var bits = 0, zero: Int?
        for i in 0..<14 {
            let ofs = slot * mainSize + i * sector
            let id = data.u16(ofs + 0xFF4)
            guard id < 14 else { return nil }
            bits |= 1 << id
            if id == 0 { zero = ofs }
        }
        return bits == 0x3FFF ? zero : nil
    }

    static func looksValid(_ data: [UInt8]) -> Bool {
        data.count == 0x20000 && (allSectorsPresent(data, slot: 0) != nil || allSectorsPresent(data, slot: 1) != nil)
    }

    private var isFRLG: Bool { game == .fireRed || game == .leafGreen }
    private var partyCountOffset: Int { isFRLG ? 0x34 : 0x234 }
    private var seen2: Int { isFRLG ? 0x5F8 : (game == .emerald ? 0x988 : 0x938) }
    private var seen3: Int { isFRLG ? 0x3A18 : (game == .emerald ? 0x3B24 : 0x3A8C) }

    var trainerName: String { TextCodec.decodeGen3(small.slice(0, 7)) }
    var trainerGender: Int { small.u8(8) }
    var trainerID: Int { small.u16(0xA) }
    var secretID: Int { small.u16(0xC) }
    var boxCount: Int { 14 }
    var boxSize: Int { 30 }

    func boxName(_ box: Int) -> String {
        let name = TextCodec.decodeGen3(storage.slice(4 + 80 * 420 + box * 9, 9))
        return name.isEmpty ? "Box \(box + 1)" : name
    }

    func party() -> [Mon] {
        let count = min(large.u8(partyCountOffset), 6)
        return (0..<count).compactMap { PK3.decode(large.slice(partyCountOffset + 4 + $0 * 100, 100), game: game) }
    }

    func mon(at slot: SlotRef) -> Mon? {
        switch slot.area {
        case .party:
            guard slot.index < min(large.u8(partyCountOffset), 6) else { return nil }
            return PK3.decode(large.slice(partyCountOffset + 4 + slot.index * 100, 100), game: game)
        case .box:
            return PK3.decode(storage.slice(boxOffset(slot), 80), game: game)
        }
    }

    private func boxOffset(_ slot: SlotRef) -> Int { 4 + 80 * (slot.box * 30 + slot.index) }

    func set(_ mon: Mon?, at slot: SlotRef) throws {
        if let reason = readOnlyReason { throw PKError.readOnly(reason) }
        switch slot.area {
        case .box:
            let bytes = try mon.map { try PK3.encode($0, game: game, party: false) } ?? [UInt8](repeating: 0, count: 80)
            storage.put(boxOffset(slot), bytes)
        case .party:
            var members = party()
            if let mon {
                if slot.index < members.count { members[slot.index] = mon } else { members.append(mon) }
            } else if slot.index < members.count {
                guard members.count > 1 else { throw PKError.unsupported("The party can't be left empty.") }
                members.remove(at: slot.index)
            }
            let base = partyCountOffset + 4
            for i in 0..<6 {
                let bytes = i < members.count ? try PK3.encode(members[i], game: game, party: true) : [UInt8](repeating: 0, count: 100)
                large.put(base + i * 100, bytes)
            }
            large.set8(partyCountOffset, members.count)
        }
    }

    func registerDex(_ mon: Mon) {
        guard mon.species > 0, mon.species <= 386 else { return }
        let bit = mon.species - 1
        small.setBit(0x18 + 0x10, bit, true)   // caught
        small.setBit(0x18 + 0x44, bit, true)   // seen
        large.setBit(seen2, bit, true)
        large.setBit(seen3, bit, true)
    }

    func serialize() throws -> [UInt8] {
        var out = data
        for i in 0..<14 {
            let ofs = activeSlot * Self.mainSize + i * Self.sector
            let id = out.u16(ofs + 0xFF4)
            let chunk: [UInt8]
            switch id {
            case 0: chunk = small
            case 1...4: chunk = large.slice((id - 1) * Self.used, Self.used)
            default: chunk = storage.slice((id - 5) * Self.used, Self.used)
            }
            out.put(ofs, chunk)
            out.set16(ofs + 0xFF6, Checksums.sum32fold(out, ofs..<(ofs + Self.used)))
        }
        return out
    }

    var integrityProblem: String? { checksumsValid ? nil : "a save sector has a wrong checksum" }

    /// Every sector of the active slot passes its checksum.
    var checksumsValid: Bool {
        (0..<14).allSatisfy { i in
            let ofs = activeSlot * Self.mainSize + i * Self.sector
            return data.u16(ofs + 0xFF6) == Checksums.sum32fold(data, ofs..<(ofs + Self.used))
        }
    }
}
