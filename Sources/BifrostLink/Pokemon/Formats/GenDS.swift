import Foundation

/// PK4/PK5: 136-byte (box) Pokémon used by Diamond … White 2. Party adds 100 (Gen 4) or 84 (Gen 5) bytes.
enum PK45 {
    static let storedSize = 136
    static func partySize(gen: Int) -> Int { gen == 4 ? 236 : 220 }

    static func decode(_ bytes: [UInt8], gen: Int) -> Mon? {
        guard bytes.count >= storedSize, !bytes.slice(0, storedSize).isAllZero else { return nil }
        let d = PKXCrypto.decrypt45(bytes)
        guard d.u16(6) == PKXCrypto.sum16(d, range: 8..<136), d.u16(8) != 0 else { return nil }
        var m = Mon()
        m.sourceFamily = gen == 4 ? .gen4 : .gen5
        m.raw = d
        m.pid = d.u32(0)
        m.encryptionConstant = m.pid
        m.species = d.u16(8)
        m.heldItem = PokeData.shared.item(fromGame: d.u16(0x0A), generation: gen)
        m.tid = d.u16(0x0C)
        m.sid = d.u16(0x0E)
        m.exp = Int(d.u32(0x10))
        m.friendship = d.u8(0x14)
        m.ability = d.u8(0x15)
        m.markings = d.u8(0x16)
        m.language = d.u8(0x17)
        m.evs = (0..<6).map { d.u8(0x18 + $0) }
        m.moves = (0..<4).map { d.u16(0x28 + $0 * 2) }
        m.pp = (0..<4).map { d.u8(0x30 + $0) }
        m.ppUps = (0..<4).map { d.u8(0x34 + $0) }
        let iv = d.u32(0x38)
        m.ivs = (0..<6).map { Int((iv >> (UInt32($0) * 5)) & 31) }
        m.isEgg = (iv >> 30) & 1 == 1
        m.isNicknamed = (iv >> 31) & 1 == 1
        let flags = d.u8(0x40)
        m.fatefulEncounter = flags & 1 == 1
        m.gender = (flags >> 1) & 3
        m.form = flags >> 3
        if gen == 5 {
            m.nature = d.u8(0x41)
            if d.u8(0x42) & 1 == 1 { m.abilitySlot = 2 }
            m.nickname = TextCodec.decodeUTF16(d.slice(0x48, 22), terminator: 0xFFFF)
            m.otName = TextCodec.decodeUTF16(d.slice(0x68, 16), terminator: 0xFFFF)
            m.ball = d.u8(0x83)
            m.metLocation = d.u16(0x80)
            m.eggLocation = d.u16(0x7E)
        } else {
            m.nature = Int(m.pid % 25)
            m.nickname = TextCodec.decodeGen4(d.slice(0x48, 22))
            m.otName = TextCodec.decodeGen4(d.slice(0x68, 16))
            let hgssBall = d.u8(0x86)
            m.ball = hgssBall != 0 ? hgssBall : d.u8(0x83)
            let extended = d.u16(0x46)
            m.metLocation = extended != 0 ? extended : d.u16(0x80)
            let extendedEgg = d.u16(0x44)
            m.eggLocation = extendedEgg != 0 ? extendedEgg : d.u16(0x7E)
        }
        m.originGame = PKGame.from(originVersion: d.u8(0x5F))
        m.metDate = DateComponents(year: 2000 + d.u8(0x7B), month: d.u8(0x7C), day: d.u8(0x7D))
        m.pokerus = d.u8(0x82)
        m.metLevel = d.u8(0x84) & 0x7F
        m.otGender = d.u8(0x84) >> 7
        if m.abilitySlot != 2, let abilities = PokeData.shared.monData(species: m.species, form: m.form)?.abilities {
            m.abilitySlot = m.ability == abilities[1] && abilities[0] != abilities[1] ? 1 : 0
        }
        m.level = PokeData.shared.level(forExp: m.exp, species: m.species)
        if bytes.count >= partySize(gen: gen) {
            m.status = Int(d.u32(0x88))
            m.level = d.u8(0x8C)
            m.currentHP = d.u16(0x8E)
            m.stats = (0..<6).map { d.u16(0x90 + $0 * 2) }
        }
        return m
    }

    static func encodePlain(_ m: Mon, gen: Int, game: PKGame) throws -> [UInt8] {
        guard m.species > 0, m.species <= (gen == 4 ? 493 : 649) else {
            throw PKError.unsupported("\(m.speciesName) doesn't exist in \(game.name).")
        }
        let own: SaveFamily = gen == 4 ? .gen4 : .gen5
        var d = m.sourceFamily == own && m.raw.count >= storedSize ? Array(m.raw.prefix(storedSize)) : [UInt8](repeating: 0, count: storedSize)
        d.set32(0, m.pid)
        d.set16(8, m.species)
        d.set16(0x0A, PokeData.shared.item(toGame: m.heldItem, generation: gen))
        d.set16(0x0C, m.tid & 0xFFFF)
        d.set16(0x0E, m.sid & 0xFFFF)
        let exp = m.exp > 0 ? m.exp : PokeData.shared.exp(forLevel: m.level, species: m.species)
        d.set32(0x10, UInt32(exp))
        d.set8(0x14, min(m.friendship, 255))
        d.set8(0x15, m.ability)
        d.set8(0x16, m.markings & 0x3F)
        d.set8(0x17, min(max(m.language, 1), 8))
        for i in 0..<6 { d.set8(0x18 + i, min(m.evs[i], 255)) }
        for i in 0..<4 {
            d.set16(0x28 + i * 2, m.moves[i])
            d.set8(0x30 + i, m.pp[i])
            d.set8(0x34 + i, min(m.ppUps[i], 3))
        }
        var iv: UInt32 = 0
        for i in 0..<6 { iv |= UInt32(min(m.ivs[i], 31)) << (UInt32(i) * 5) }
        if m.isEgg { iv |= 1 << 30 }
        if m.isNicknamed { iv |= 1 << 31 }
        d.set32(0x38, iv)
        d.set8(0x40, (m.fatefulEncounter ? 1 : 0) | (m.gender & 3) << 1 | (m.form & 0x1F) << 3)
        let nick = m.isEgg ? "Egg" : (m.isNicknamed ? m.nickname : PokeData.shared.speciesName(m.species).uppercased())
        let origin = m.originGame.map { $0.generation <= gen ? $0.originVersion : game.originVersion } ?? game.originVersion
        if gen == 5 {
            d.set8(0x41, m.nature)
            d.set8(0x42, (d.u8(0x42) & ~1) | (m.abilitySlot == 2 ? 1 : 0))
            if TextCodec.decodeUTF16(d.slice(0x48, 22), terminator: 0xFFFF) != nick { d.put(0x48, TextCodec.encodeUTF16(nick, chars: 11, terminator: 0xFFFF, gen5: true)) }
            if TextCodec.decodeUTF16(d.slice(0x68, 16), terminator: 0xFFFF) != m.otName { d.put(0x68, TextCodec.encodeUTF16(m.otName, chars: 8, terminator: 0xFFFF, gen5: true)) }
            d.set16(0x7E, m.eggLocation)
            d.set16(0x80, m.metLocation)
            d.set8(0x83, (1...25).contains(m.ball) ? m.ball : 4)
        } else {
            if TextCodec.decodeGen4(d.slice(0x48, 22)) != nick { d.put(0x48, TextCodec.encodeGen4(nick, chars: 11)) }
            if TextCodec.decodeGen4(d.slice(0x68, 16)) != m.otName { d.put(0x68, TextCodec.encodeGen4(m.otName, chars: 8)) }
            let location = m.metLocation
            d.set16(0x80, location)
            d.set16(0x46, game == .platinum || game == .heartGold || game == .soulSilver ? location : 0)
            d.set16(0x7E, m.eggLocation)
            let ball = (1...24).contains(m.ball) ? m.ball : 4
            d.set8(0x83, ball <= 16 ? ball : 4)
            d.set8(0x86, ball > 16 || game == .heartGold || game == .soulSilver ? ball : 0)
        }
        d.set8(0x5F, origin)
        if let date = m.metDate, let y = date.year {
            d.set8(0x7B, max(0, y - 2000)); d.set8(0x7C, date.month ?? 1); d.set8(0x7D, date.day ?? 1)
        }
        d.set8(0x82, m.pokerus)
        d.set8(0x84, (m.metLevel & 0x7F) | (m.otGender & 1) << 7)
        return d
    }

    static func encode(_ m: Mon, gen: Int, game: PKGame, party: Bool) throws -> [UInt8] {
        var plain = try encodePlain(m, gen: gen, game: game)
        if party {
            var full = m
            full.level = PokeData.shared.level(forExp: Int(plain.u32(0x10)), species: m.species)
            full.recalculateStats()
            plain += [UInt8](repeating: 0, count: partySize(gen: gen) - storedSize)
            plain.set32(0x88, UInt32(m.status))
            plain.set8(0x8C, full.level)
            plain.set16(0x8E, m.currentHP > 0 && m.currentHP <= full.stats[0] ? m.currentHP : full.stats[0])
            for i in 0..<6 { plain.set16(0x90 + i * 2, full.stats[i]) }
        }
        return PKXCrypto.encrypt45(plain)
    }
}

/// Diamond, Pearl, Platinum, HeartGold, SoulSilver: two 256 KB partitions, each with a General and
/// a Storage block; the newer copy of each block (by its save counter) is the live one.
final class SaveGen4: SaveFile {
    private enum Kind { case dp, pt, hgss }
    private var data: [UInt8]
    private let kind: Kind
    private(set) var game: PKGame
    private let generalSize: Int
    private let storageSize: Int
    private let storageStart: Int
    private let footer: Int
    private let general: Int      // absolute offset of the live General block
    private let storage: Int      // absolute offset of the live Storage block

    static func detect(_ d: [UInt8]) -> PKGame? {
        guard d.count >= 0x80000 else { return nil }
        func valid(_ size: Int) -> Bool {
            let o = 0x40000 + size
            return d.u32(o - 0xC) == UInt32(size) && (d.u32(o - 8) == 0x2006_0623 || d.u32(o - 8) == 0x2007_0903)
        }
        if valid(0xC100) { return .diamond }
        if valid(0xCF2C) { return .platinum }
        if valid(0xF628) { return .heartGold }
        // Saves where only the first partition was ever written
        func valid0(_ size: Int) -> Bool { d.u32(size - 0xC) == UInt32(size) && d.u32(size - 8) == 0x2006_0623 }
        if valid0(0xC100) { return .diamond }
        if valid0(0xCF2C) { return .platinum }
        if valid0(0xF628) { return .heartGold }
        return nil
    }

    init(data: [UInt8], hint: PKGame?) throws {
        guard let detected = Self.detect(data) else { throw PKError.unsupported("Not a Gen 4 save.") }
        self.data = Array(data.prefix(0x80000))
        switch detected {
        case .diamond:
            kind = .dp; generalSize = 0xC100; storageSize = 0x121E0; storageStart = 0xC100; footer = 0x14
            game = hint == .pearl ? .pearl : .diamond
        case .platinum:
            kind = .pt; generalSize = 0xCF2C; storageSize = 0x121E4; storageStart = 0xCF2C; footer = 0x14
            game = .platinum
        default:
            kind = .hgss; generalSize = 0xF628; storageSize = 0x12310; storageStart = 0xF628 + 0xD8; footer = 0x10
            game = hint == .soulSilver ? .soulSilver : .heartGold
        }
        general = Self.active(self.data, begin: 0, length: generalSize)
        storage = Self.active(self.data, begin: storageStart, length: storageSize) + storageStart
    }

    private static func active(_ d: [UInt8], begin: Int, length: Int) -> Int {
        let o1 = begin + length - 0x14, o2 = o1 + 0x40000
        func cmp(_ a: UInt32, _ b: UInt32) -> Int? {
            if a == .max && b != .max - 1 { return 1 }
            if b == .max && a != .max - 1 { return 0 }
            if a > b { return 0 }
            if a < b { return 1 }
            return nil
        }
        let pick = cmp(d.u32(o1), d.u32(o2)) ?? cmp(d.u32(o1 + 4), d.u32(o2 + 4)) ?? 0
        return pick == 0 ? 0 : 0x40000
    }

    private var partyOffset: Int { general + (kind == .pt ? 0xA0 : 0x98) }
    private var trainerOffset: Int { general + (kind == .pt ? 0x68 : 0x64) }
    private var dexOffset: Int { general + (kind == .dp ? 0x12DC : kind == .pt ? 0x1328 : 0x12B8) }

    private func boxOffset(_ box: Int, _ slot: Int) -> Int {
        kind == .hgss ? storage + box * 0x1000 + slot * 136 : storage + 4 + box * 0xFF0 + slot * 136
    }

    var trainerName: String { TextCodec.decodeGen4(data.slice(trainerOffset, 16)) }
    var trainerID: Int { data.u16(trainerOffset + 0x10) }
    var secretID: Int { data.u16(trainerOffset + 0x12) }
    var trainerGender: Int { data.u8(trainerOffset + 0x18) }
    var boxCount: Int { 18 }
    var boxSize: Int { 30 }

    func boxName(_ box: Int) -> String {
        let o = kind == .hgss ? storage + 0x12008 : storage + 4 + 18 * 0xFF0
        let name = TextCodec.decodeGen4(data.slice(o + box * 40, 40))
        return name.isEmpty ? "Box \(box + 1)" : name
    }

    func party() -> [Mon] {
        let count = min(data.u8(partyOffset - 4), 6)
        return (0..<count).compactMap { PK45.decode(data.slice(partyOffset + $0 * 236, 236), gen: 4) }
    }

    func mon(at slot: SlotRef) -> Mon? {
        switch slot.area {
        case .party:
            guard slot.index < min(data.u8(partyOffset - 4), 6) else { return nil }
            return PK45.decode(data.slice(partyOffset + slot.index * 236, 236), gen: 4)
        case .box:
            return PK45.decode(data.slice(boxOffset(slot.box, slot.index), 136), gen: 4)
        }
    }

    func set(_ mon: Mon?, at slot: SlotRef) throws {
        switch slot.area {
        case .box:
            let bytes = try mon.map { try PK45.encode($0, gen: 4, game: game, party: false) } ?? [UInt8](repeating: 0, count: 136)
            data.put(boxOffset(slot.box, slot.index), bytes)
            if kind == .hgss {
                // Tell the game which boxes changed so it re-reads them.
                let flags = storage + 0x12008 + 18 * 40 + 18
                data.set32(flags, data.u32(flags) | (1 << UInt32(slot.box)))
            }
        case .party:
            var members = party()
            if let mon {
                if slot.index < members.count { members[slot.index] = mon } else { members.append(mon) }
            } else if slot.index < members.count {
                guard members.count > 1 else { throw PKError.unsupported("The party can't be left empty.") }
                members.remove(at: slot.index)
            }
            for i in 0..<6 {
                let bytes = i < members.count ? try PK45.encode(members[i], gen: 4, game: game, party: true) : [UInt8](repeating: 0, count: 236)
                data.put(partyOffset + i * 236, bytes)
            }
            data.set8(partyOffset - 4, members.count)
        }
    }

    func registerDex(_ mon: Mon) {
        guard mon.species > 0, mon.species <= 493 else { return }
        let bit = mon.species - 1
        let seenBefore = data.bit(dexOffset + 0x44, bit)
        data.setBit(dexOffset + 4, bit, true)
        data.setBit(dexOffset + 0x44, bit, true)
        if !seenBefore {
            data.setBit(dexOffset + 0x84, bit, mon.gender == 1)
            data.setBit(dexOffset + 0xC4, bit, mon.gender == 1)
        }
    }

    func serialize() throws -> [UInt8] {
        var out = data
        for (start, size) in [(general, generalSize), (storage, storageSize)] {
            out.set16(start + size - 2, Checksums.crc16ccitt(out, start..<(start + size - footer)))
        }
        return out
    }

    var integrityProblem: String? { checksumsValid ? nil : "a save block has a wrong checksum" }

    var checksumsValid: Bool {
        [(general, generalSize), (storage, storageSize)].allSatisfy { start, size in
            data.u16(start + size - 2) == Checksums.crc16ccitt(data, start..<(start + size - footer))
        }
    }
}

/// Black, White, Black 2, White 2 (512 KB). Every block has a CRC and a mirror in the checksum block.
final class SaveGen5: SaveFile {
    private var data: [UInt8]
    private let b2w2: Bool
    private(set) var game: PKGame
    private var checksumBlock: Int { b2w2 ? 0x25F00 : 0x23F00 }
    private var checksumLength: Int { b2w2 ? 0x94 : 0x8C }
    private var dexOffset: Int { b2w2 ? 0x21400 : 0x21600 }
    private let partyBlock = 0x18E00
    private let trainer = 0x19400

    static func detect(_ d: [UInt8]) -> Bool? {
        guard d.count >= 0x80000 else { return nil }
        func valid(_ main: Int, _ info: Int) -> Bool {
            let f = main - 0x100
            return d.u16(f + info + 0x10 - 2) == Checksums.crc16ccitt(d, f..<(f + info))
        }
        if valid(0x24000, 0x8C) { return false }
        if valid(0x26000, 0x94) { return true }
        return nil
    }

    init(data: [UInt8], hint: PKGame?) throws {
        guard let b2w2 = Self.detect(data) else { throw PKError.unsupported("Not a Gen 5 save.") }
        self.data = Array(data.prefix(0x80000))
        self.b2w2 = b2w2
        let version = PKGame.from(originVersion: self.data.u8(0x19400 + 0x1F))
        if b2w2 { game = version == .white2 ? .white2 : (hint == .white2 ? .white2 : .black2) }
        else { game = version == .white ? .white : (hint == .white ? .white : .black) }
    }

    var trainerName: String { TextCodec.decodeUTF16(data.slice(trainer + 4, 16), terminator: 0xFFFF) }
    var trainerID: Int { data.u16(trainer + 0x14) }
    var secretID: Int { data.u16(trainer + 0x16) }
    var trainerGender: Int { data.u8(trainer + 0x21) }
    var boxCount: Int { 24 }
    var boxSize: Int { 30 }

    func boxName(_ box: Int) -> String {
        let name = TextCodec.decodeUTF16(data.slice(4 + box * 0x28, 0x28), terminator: 0xFFFF)
        return name.isEmpty ? "Box \(box + 1)" : name
    }

    private func boxOffset(_ box: Int, _ slot: Int) -> Int { 0x400 + box * 0x1000 + slot * 136 }

    func party() -> [Mon] {
        let count = min(data.u8(partyBlock + 4), 6)
        return (0..<count).compactMap { PK45.decode(data.slice(partyBlock + 8 + $0 * 220, 220), gen: 5) }
    }

    func mon(at slot: SlotRef) -> Mon? {
        switch slot.area {
        case .party:
            guard slot.index < min(data.u8(partyBlock + 4), 6) else { return nil }
            return PK45.decode(data.slice(partyBlock + 8 + slot.index * 220, 220), gen: 5)
        case .box:
            return PK45.decode(data.slice(boxOffset(slot.box, slot.index), 136), gen: 5)
        }
    }

    func set(_ mon: Mon?, at slot: SlotRef) throws {
        switch slot.area {
        case .box:
            let bytes = try mon.map { try PK45.encode($0, gen: 5, game: game, party: false) } ?? [UInt8](repeating: 0, count: 136)
            data.put(boxOffset(slot.box, slot.index), bytes)
        case .party:
            var members = party()
            if let mon {
                if slot.index < members.count { members[slot.index] = mon } else { members.append(mon) }
            } else if slot.index < members.count {
                guard members.count > 1 else { throw PKError.unsupported("The party can't be left empty.") }
                members.remove(at: slot.index)
            }
            for i in 0..<6 {
                let bytes = i < members.count ? try PK45.encode(members[i], gen: 5, game: game, party: true) : [UInt8](repeating: 0, count: 220)
                data.put(partyBlock + 8 + i * 220, bytes)
            }
            data.set8(partyBlock + 4, members.count)
        }
    }

    func registerDex(_ mon: Mon) {
        guard mon.species > 0, mon.species <= 649 else { return }
        let bit = mon.species - 1
        let region = (mon.gender == 1 ? 1 : 0) + (mon.isShiny ? 2 : 0)
        data.setBit(dexOffset + 8, bit, true)
        data.setBit(dexOffset + 0x5C + region * 0x54, bit, true)
        let displayed = (0..<4).contains { data.bit(dexOffset + 0x1AC + $0 * 0x54, bit) }
        if !displayed { data.setBit(dexOffset + 0x1AC + region * 0x54, bit, true) }
    }

    /// Block (offset, length, checksum offset, mirror offset) for every block we touch.
    private var blocks: [(Int, Int, Int, Int)] {
        var list: [(Int, Int, Int, Int)] = [(0, 0x3E0, 0x3E2, checksumBlock)]
        for i in 0..<24 {
            let o = 0x400 + i * 0x1000
            list.append((o, 0xFF0, o + 0xFF2, checksumBlock + 2 + i * 2))
        }
        list.append((partyBlock, 0x534, partyBlock + 0x536, checksumBlock + 0x34))
        list.append((dexOffset, b2w2 ? 0x4DC : 0x4D4, dexOffset + (b2w2 ? 0x4DE : 0x4D6), checksumBlock + (b2w2 ? 0x6C : 0x6E)))
        return list
    }

    func serialize() throws -> [UInt8] {
        var out = data
        for (offset, length, checksum, mirror) in blocks {
            let crc = Checksums.crc16ccitt(out, offset..<(offset + length))
            out.set16(checksum, crc)
            out.set16(mirror, crc)
        }
        let crc = Checksums.crc16ccitt(out, checksumBlock..<(checksumBlock + checksumLength))
        out.set16(checksumBlock + checksumLength + 0xE, crc)
        return out
    }

    var integrityProblem: String? { checksumsValid ? nil : "a save block has a wrong checksum" }

    var checksumsValid: Bool {
        blocks.allSatisfy { offset, length, checksum, mirror in
            let crc = Checksums.crc16ccitt(data, offset..<(offset + length))
            return data.u16(checksum) == crc && data.u16(mirror) == crc
        } && data.u16(checksumBlock + checksumLength + 0xE) == Checksums.crc16ccitt(data, checksumBlock..<(checksumBlock + checksumLength))
    }
}
