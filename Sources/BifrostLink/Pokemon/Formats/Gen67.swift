import Foundation

/// PK6/PK7: 232-byte (box) / 260-byte (party) Pokémon for X/Y … Ultra Sun/Ultra Moon.
enum PK67 {
    static let storedSize = 0xE8
    static let partySize = 0x104

    static func decode(_ bytes: [UInt8], gen: Int) -> Mon? {
        guard bytes.count >= storedSize, !bytes.slice(0, storedSize).isAllZero else { return nil }
        let d = PKXCrypto.decrypt6(bytes, storedSize: storedSize)
        guard PKXCrypto.checksumValid6(d, storedSize: storedSize), d.u16(8) != 0 else { return nil }
        var m = Mon()
        m.sourceFamily = gen == 6 ? .gen6 : .gen7
        m.raw = d
        decodeCommon(d, into: &m, gen: gen)
        if bytes.count >= partySize {
            m.status = Int(d.u32(0xE8))
            m.level = d.u8(0xEC)
            m.currentHP = d.u16(0xF0)
            m.stats = (0..<6).map { d.u16(0xF2 + $0 * 2) }
        }
        return m
    }

    /// Fields shared by PK6, PK7 and PB7 (Let's Go uses the same skeleton).
    static func decodeCommon(_ d: [UInt8], into m: inout Mon, gen: Int) {
        m.encryptionConstant = d.u32(0)
        m.species = d.u16(8)
        m.heldItem = PokeData.shared.item(fromGame: d.u16(0x0A), generation: min(gen, 7))
        m.tid = d.u16(0x0C)
        m.sid = d.u16(0x0E)
        m.exp = Int(d.u32(0x10))
        m.ability = d.u8(0x14)
        let number = d.u8(0x15)
        m.abilitySlot = number == 4 ? 2 : (number == 2 ? 1 : 0)
        m.pid = d.u32(0x18)
        m.nature = d.u8(0x1C)
        let flags = d.u8(0x1D)
        m.fatefulEncounter = flags & 1 == 1
        m.gender = (flags >> 1) & 3
        m.form = flags >> 3
        m.evs = (0..<6).map { d.u8(0x1E + $0) }
        m.pokerus = d.u8(0x2B)
        m.nickname = TextCodec.decodeUTF16(d.slice(0x40, 0x1A))
        m.moves = (0..<4).map { d.u16(0x5A + $0 * 2) }
        m.pp = (0..<4).map { d.u8(0x62 + $0) }
        m.ppUps = (0..<4).map { d.u8(0x66 + $0) }
        m.relearnMoves = (0..<4).map { d.u16(0x6A + $0 * 2) }
        let iv = d.u32(0x74)
        m.ivs = (0..<6).map { Int((iv >> (UInt32($0) * 5)) & 31) }
        m.isEgg = (iv >> 30) & 1 == 1
        m.isNicknamed = (iv >> 31) & 1 == 1
        m.otName = TextCodec.decodeUTF16(d.slice(0xB0, 0x1A))
        m.friendship = d.u8(0xCA)
        if d.u8(0xD1) != 0 || d.u8(0xD2) != 0 { m.eggLocation = d.u16(0xD8) }
        m.metDate = DateComponents(year: 2000 + d.u8(0xD4), month: d.u8(0xD5), day: d.u8(0xD6))
        m.eggLocation = d.u16(0xD8)
        m.metLocation = d.u16(0xDA)
        m.ball = d.u8(0xDC)
        m.metLevel = d.u8(0xDD) & 0x7F
        m.otGender = d.u8(0xDD) >> 7
        m.originGame = PKGame.from(originVersion: d.u8(0xDF))
        m.language = d.u8(0xE3)
        m.level = PokeData.shared.level(forExp: m.exp, species: m.species)
    }

    static func encodeCommon(_ m: Mon, into d: inout [UInt8], gen: Int, game: PKGame) {
        let ec = m.encryptionConstant != 0 ? m.encryptionConstant : m.pid
        d.set32(0, ec)
        d.set16(8, m.species)
        d.set16(0x0A, PokeData.shared.item(toGame: m.heldItem, generation: min(gen, 7)))
        d.set16(0x0C, m.tid & 0xFFFF)
        d.set16(0x0E, m.sid & 0xFFFF)
        let exp = m.exp > 0 ? m.exp : PokeData.shared.exp(forLevel: m.level, species: m.species)
        d.set32(0x10, UInt32(exp))
        d.set8(0x14, m.ability)
        d.set8(0x15, m.abilitySlot == 2 ? 4 : (m.abilitySlot == 1 ? 2 : 1))
        d.set32(0x18, m.pid)
        d.set8(0x1C, m.nature)
        d.set8(0x1D, (m.fatefulEncounter ? 1 : 0) | (m.gender & 3) << 1 | (m.form & 0x1F) << 3)
        for i in 0..<6 { d.set8(0x1E + i, min(m.evs[i], 252)) }
        d.set8(0x2B, m.pokerus)
        let nick = m.isEgg ? "Egg" : (m.isNicknamed ? m.nickname : PokeData.shared.speciesName(m.species))
        // Keep the original bytes (including the game's leftover characters) when the name is unchanged.
        if TextCodec.decodeUTF16(d.slice(0x40, 0x1A)) != nick { d.put(0x40, TextCodec.encodeUTF16(nick, chars: 13)) }
        for i in 0..<4 {
            d.set16(0x5A + i * 2, m.moves[i])
            d.set8(0x62 + i, m.pp[i])
            d.set8(0x66 + i, min(m.ppUps[i], 3))
            d.set16(0x6A + i * 2, m.relearnMoves[i])
        }
        var iv: UInt32 = 0
        for i in 0..<6 { iv |= UInt32(min(m.ivs[i], 31)) << (UInt32(i) * 5) }
        if m.isEgg { iv |= 1 << 30 }
        if m.isNicknamed { iv |= 1 << 31 }
        d.set32(0x74, iv)
        if TextCodec.decodeUTF16(d.slice(0xB0, 0x1A)) != m.otName { d.put(0xB0, TextCodec.encodeUTF16(m.otName, chars: 13)) }
        d.set8(0xCA, min(m.friendship, 255))
        if let date = m.metDate, let y = date.year {
            d.set8(0xD4, max(0, y - 2000)); d.set8(0xD5, date.month ?? 1); d.set8(0xD6, date.day ?? 1)
        }
        d.set16(0xD8, m.eggLocation)
        d.set16(0xDA, m.metLocation)
        d.set8(0xDC, (1...26).contains(m.ball) ? m.ball : 4)
        d.set8(0xDD, (m.metLevel & 0x7F) | (m.otGender & 1) << 7)
        let origin = m.originGame.map { $0.generation <= gen ? $0.originVersion : game.originVersion } ?? game.originVersion
        d.set8(0xDF, origin)
        d.set8(0xE3, min(max(m.language, 1), 10))
    }

    static func encode(_ m: Mon, gen: Int, game: PKGame, party: Bool) throws -> [UInt8] {
        guard m.species > 0, m.species <= game.maxSpecies else {
            throw PKError.unsupported("\(m.speciesName) doesn't exist in \(game.name).")
        }
        let own: SaveFamily = gen == 6 ? .gen6 : .gen7
        var d = m.sourceFamily == own && m.raw.count >= storedSize ? Array(m.raw.prefix(storedSize)) : [UInt8](repeating: 0, count: storedSize)
        encodeCommon(m, into: &d, gen: gen, game: game)
        if party {
            var full = m
            full.level = PokeData.shared.level(forExp: Int(d.u32(0x10)), species: m.species)
            full.recalculateStats()
            d += [UInt8](repeating: 0, count: partySize - storedSize)
            d.set32(0xE8, UInt32(m.status))
            d.set8(0xEC, full.level)
            d.set16(0xF0, m.currentHP > 0 && m.currentHP <= full.stats[0] ? m.currentHP : full.stats[0])
            for i in 0..<6 { d.set16(0xF2 + i * 2, full.stats[i]) }
        }
        return PKXCrypto.encrypt6(d, storedSize: storedSize)
    }
}

/// The 3DS save container: blocks laid out back to back (each rounded up to 0x200), with a table of
/// (length, id, checksum) after the "BEEF" magic near the end of the file.
struct BlockTable3DS {
    struct Block { let id: Int; let offset: Int; let length: Int }
    let metadata: Int
    let blocks: [Block]
    let crc: ([UInt8], Range<Int>) -> Int

    init?(_ d: [UInt8], gen: Int) {
        guard d.count > 0x200 else { return nil }
        metadata = d.count - 0x200
        guard d.u32(metadata + 0x10) == 0x4245_4546 else { return nil }   // "BEEF"
        var list: [Block] = []
        var offset = 0
        var entry = metadata + 0x14
        while entry + 8 <= d.count {
            let length = Int(d.u32(entry))
            let id = d.u16(entry + 4)
            if length == 0 || id != list.count { break }
            list.append(Block(id: id, offset: offset, length: length))
            offset += (length + 0x1FF) & ~0x1FF
            entry += 8
        }
        guard !list.isEmpty else { return nil }
        blocks = list
        crc = gen == 6 ? { Checksums.crc16ccitt($0, $1) } : { Checksums.crc16gen7($0, $1) }
    }

    /// Same layout, different checksum (Let's Go uses a non-inverted CRC).
    init(rebinding other: BlockTable3DS, crc: @escaping ([UInt8], Range<Int>) -> Int) {
        metadata = other.metadata
        blocks = other.blocks
        self.crc = crc
    }

    func checksumOffset(_ id: Int) -> Int { metadata + 0x14 + id * 8 + 6 }

    func isValid(_ d: [UInt8], _ id: Int) -> Bool {
        let b = blocks[id]
        return d.u16(checksumOffset(id)) == crc(d, b.offset..<(b.offset + b.length))
    }

    func fix(_ d: inout [UInt8], _ id: Int) {
        let b = blocks[id]
        d.set16(checksumOffset(id), crc(d, b.offset..<(b.offset + b.length)))
    }
}

/// X, Y, Omega Ruby, Alpha Sapphire, Sun, Moon, Ultra Sun, Ultra Moon.
final class Save3DS: SaveFile {
    private var data: [UInt8]
    private let table: BlockTable3DS
    private let gen: Int
    private(set) var game: PKGame
    private let statusBlock: Int, partyBlock: Int, boxBlock: Int, layoutBlock: Int, dexBlock: Int
    private var touched: Set<Int> = []

    static func detect(_ d: [UInt8]) -> [PKGame]? {
        guard d.count > 0x200, d.u32(d.count - 0x1F0) == 0x4245_4546 else { return nil }
        switch d.count {
        case 0x65600: return [.x, .y]
        case 0x76000: return [.omegaRuby, .alphaSapphire]
        case 0x6BE00: return [.sun, .moon]
        case 0x6CC00: return [.ultraSun, .ultraMoon]
        default: return nil
        }
    }

    init(data: [UInt8], hint: PKGame?) throws {
        guard let family = Self.detect(data) else { throw PKError.unsupported("Not a 3DS Pokémon save.") }
        gen = family[0].generation
        guard let table = BlockTable3DS(data, gen: gen) else { throw PKError.corrupt("The save's block table is unreadable.") }
        self.data = data
        self.table = table
        if gen == 6 {
            statusBlock = 17; partyBlock = 18; layoutBlock = 12; dexBlock = 20
            boxBlock = family[0] == .x ? 53 : 56
        } else {
            statusBlock = 3; partyBlock = 4; layoutBlock = 13; dexBlock = 6; boxBlock = 14
        }
        let status = table.blocks[statusBlock].offset
        let stored = PKGame.from(originVersion: data.u8(status + 4))
        game = stored.flatMap { family.contains($0) ? $0 : nil } ?? hint.flatMap { family.contains($0) ? $0 : nil } ?? family[0]
    }

    private var status: Int { table.blocks[statusBlock].offset }
    private var partyOffset: Int { table.blocks[partyBlock].offset }
    private var boxOffset: Int { table.blocks[boxBlock].offset }

    var trainerName: String { TextCodec.decodeUTF16(data.slice(status + (gen == 6 ? 0x48 : 0x38), 0x1A)) }
    var trainerID: Int { data.u16(status) }
    var secretID: Int { data.u16(status + 2) }
    var trainerGender: Int { data.u8(status + 5) }
    var boxCount: Int { gen == 6 ? 31 : 32 }
    /// Sun/Moon and Ultra Sun/Ultra Moon sign their checksum table; a save written without a new
    /// signature is rejected by the game, so these stay read-only until signing is in place.
    var readOnlyReason: String? { gen == 7 && !Save3DS.canSignGen7 ? "Sun/Moon saves can be looked at but not changed yet." : nil }
    static let canSignGen7 = true
    var boxSize: Int { 30 }

    func boxName(_ box: Int) -> String {
        let name = TextCodec.decodeUTF16(data.slice(table.blocks[layoutBlock].offset + box * 0x22, 0x22))
        return name.isEmpty ? "Box \(box + 1)" : name
    }

    private func slotOffset(_ slot: SlotRef) -> Int {
        slot.area == .party ? partyOffset + slot.index * PK67.partySize : boxOffset + (slot.box * 30 + slot.index) * PK67.storedSize
    }

    private var partyCount: Int { min(data.u8(partyOffset + 6 * PK67.partySize), 6) }

    func party() -> [Mon] {
        (0..<partyCount).compactMap { PK67.decode(data.slice(slotOffset(.party($0)), PK67.partySize), gen: gen) }
    }

    func mon(at slot: SlotRef) -> Mon? {
        if slot.area == .party && slot.index >= partyCount { return nil }
        let size = slot.area == .party ? PK67.partySize : PK67.storedSize
        return PK67.decode(data.slice(slotOffset(slot), size), gen: gen)
    }

    func set(_ mon: Mon?, at slot: SlotRef) throws {
        if let readOnlyReason { throw PKError.readOnly(readOnlyReason) }
        switch slot.area {
        case .box:
            let bytes = try mon.map { try PK67.encode($0, gen: gen, game: game, party: false) }
                ?? PKXCrypto.encrypt6([UInt8](repeating: 0, count: PK67.storedSize), storedSize: PK67.storedSize)
            data.put(slotOffset(slot), bytes)
            touched.insert(boxBlock)
        case .party:
            var members = party()
            if let mon {
                if slot.index < members.count { members[slot.index] = mon } else { members.append(mon) }
            } else if slot.index < members.count {
                guard members.count > 1 else { throw PKError.unsupported("The party can't be left empty.") }
                members.remove(at: slot.index)
            }
            for i in 0..<6 {
                let bytes = i < members.count ? try PK67.encode(members[i], gen: gen, game: game, party: true)
                    : PKXCrypto.encrypt6([UInt8](repeating: 0, count: PK67.partySize), storedSize: PK67.storedSize)
                data.put(partyOffset + i * PK67.partySize, bytes)
            }
            data.set8(partyOffset + 6 * PK67.partySize, members.count)
            touched.insert(partyBlock)
        }
    }

    func registerDex(_ mon: Mon) {
        guard mon.species > 0, mon.species <= game.maxSpecies else { return }
        let dex = table.blocks[dexBlock].offset
        let bit = mon.species - 1
        let (caught, seen, size) = gen == 6 ? (8, 0x68, 0x60) : (0x88, 0xF0, 0x8C)
        let region = (mon.gender == 1 ? 1 : 0) + (mon.isShiny ? 2 : 0)
        data.setBit(dex + caught, bit, true)
        data.setBit(dex + seen + region * size, bit, true)
        let displayed = (0..<4).contains { data.bit(dex + seen + (4 + $0) * size, bit) }
        if !displayed { data.setBit(dex + seen + (4 + region) * size, bit, true) }
        touched.insert(dexBlock)
    }

    func serialize() throws -> [UInt8] {
        if gen == 7 && !touched.isEmpty && !Save3DS.canSignGen7 { throw PKError.readOnly(readOnlyReason ?? "") }
        var out = data
        guard !touched.isEmpty else { return out }
        if gen == 7, let meme = MemeCrypto.layout(saveSize: out.count) {
            // Sun/Moon: checksums are taken with the signature area blank, then the table is signed.
            out.replaceSubrange(meme.region..<(meme.region + MemeCrypto.regionLength), with: [UInt8](repeating: 0, count: MemeCrypto.regionLength))
            for id in touched { table.fix(&out, id) }
            if let block = memeBlock { table.fix(&out, block) }
            MemeCrypto.sign(&out)
        } else {
            for id in touched { table.fix(&out, id) }
        }
        return out
    }

    /// The block that holds the Sun/Moon signature area.
    private var memeBlock: Int? {
        guard let meme = MemeCrypto.layout(saveSize: data.count) else { return nil }
        return table.blocks.first { meme.region >= $0.offset && meme.region < $0.offset + $0.length }?.id
    }

    var checksumsValid: Bool {
        [statusBlock, partyBlock, boxBlock, layoutBlock, dexBlock].allSatisfy { table.isValid(data, $0) }
    }

    /// Every block checksum (and for Sun/Moon the signature) the game checks.
    var integrityProblem: String? { Self.integrityProblem(data, table: table, gen: gen) }

    static func integrityProblem(_ bytes: [UInt8], table: BlockTable3DS, gen: Int) -> String? {
        var check = bytes
        if gen == 7, let meme = MemeCrypto.layout(saveSize: bytes.count) {
            guard MemeCrypto.verify(bytes) else { return "the Sun/Moon signature doesn't match" }
            check.replaceSubrange(meme.region..<(meme.region + MemeCrypto.regionLength), with: [UInt8](repeating: 0, count: MemeCrypto.regionLength))
        }
        if let bad = table.blocks.first(where: { !table.isValid(check, $0.id) }) { return "block \(bad.id) has a wrong checksum" }
        return nil
    }
}
