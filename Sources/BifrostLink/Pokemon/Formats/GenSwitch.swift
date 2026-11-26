import Foundation
import CryptoKit

/// Field layout of the Switch-era Pokémon. PK8 (Sword/Shield), PB8 (BD/SP), PK9 (Scarlet/Violet) and
/// PA9 (Z-A) share one layout with a few moved fields; PA8 (Legends: Arceus) is wider.
struct SwitchLayout {
    let family: SaveFamily
    let storedSize: Int
    let partySize: Int
    let nickname: Int, otName: Int, htName: Int, handler: Int
    let moves: Int, pp: Int, ppUps: Int, relearn: Int, iv: Int, hp: Int, status: Int
    let version: Int, language: Int, otFriendship: Int, metDate: Int, eggLocation: Int, metLocation: Int, ball: Int, metLevel: Int
    let genderShift: Int
    let speciesShift9: Bool
    let partyStats: Int

    static let pk8 = SwitchLayout(family: .swsh, storedSize: 0x148, partySize: 0x158, nickname: 0x58, otName: 0xF8, htName: 0xA8, handler: 0xC4,
                                  moves: 0x72, pp: 0x7A, ppUps: 0x7E, relearn: 0x82, iv: 0x8C, hp: 0x8A, status: 0x94,
                                  version: 0xDE, language: 0xE2, otFriendship: 0x112, metDate: 0x11C, eggLocation: 0x120, metLocation: 0x122,
                                  ball: 0x124, metLevel: 0x125, genderShift: 2, speciesShift9: false, partyStats: 0x148)
    static let pb8 = SwitchLayout(family: .bdsp, storedSize: 0x148, partySize: 0x158, nickname: 0x58, otName: 0xF8, htName: 0xA8, handler: 0xC4,
                                  moves: 0x72, pp: 0x7A, ppUps: 0x7E, relearn: 0x82, iv: 0x8C, hp: 0x8A, status: 0x94,
                                  version: 0xDE, language: 0xE2, otFriendship: 0x112, metDate: 0x11C, eggLocation: 0x120, metLocation: 0x122,
                                  ball: 0x124, metLevel: 0x125, genderShift: 2, speciesShift9: false, partyStats: 0x148)
    static let pk9 = SwitchLayout(family: .sv, storedSize: 0x148, partySize: 0x158, nickname: 0x58, otName: 0xF8, htName: 0xA8, handler: 0xC4,
                                  moves: 0x72, pp: 0x7A, ppUps: 0x7E, relearn: 0x82, iv: 0x8C, hp: 0x8A, status: 0x90,
                                  version: 0xCE, language: 0xD5, otFriendship: 0x112, metDate: 0x11C, eggLocation: 0x120, metLocation: 0x122,
                                  ball: 0x124, metLevel: 0x125, genderShift: 1, speciesShift9: true, partyStats: 0x148)
    static let pa9 = SwitchLayout(family: .za, storedSize: 0x148, partySize: 0x158, nickname: 0x58, otName: 0xF8, htName: 0xA8, handler: 0xC4,
                                  moves: 0x72, pp: 0x7A, ppUps: 0x7E, relearn: 0x82, iv: 0x8C, hp: 0x8A, status: 0x90,
                                  version: 0xCE, language: 0xD5, otFriendship: 0x112, metDate: 0x11C, eggLocation: 0x120, metLocation: 0x122,
                                  ball: 0x124, metLevel: 0x125, genderShift: 1, speciesShift9: true, partyStats: 0x148)
    static let pa8 = SwitchLayout(family: .pla, storedSize: 0x168, partySize: 0x178, nickname: 0x60, otName: 0x110, htName: 0xB8, handler: 0xD4,
                                  moves: 0x54, pp: 0x5C, ppUps: 0x86, relearn: 0x8A, iv: 0x94, hp: 0x92, status: 0x9C,
                                  version: 0xEE, language: 0xF2, otFriendship: 0x12A, metDate: 0x134, eggLocation: 0x138, metLocation: 0x13A,
                                  ball: 0x137, metLevel: 0x13D, genderShift: 2, speciesShift9: false, partyStats: 0x168)

    static func of(_ family: SaveFamily) -> SwitchLayout {
        switch family {
        case .bdsp: return pb8
        case .pla: return pa8
        case .sv: return pk9
        case .za: return pa9
        default: return pk8
        }
    }
}

/// Gen 9 stores species from 917 on in its own order.
enum Species9 {
    private static let toInternal: [Int] = [1, 1, 1, 1, 33, 33, 33, 21, 21, 44, 44, 7, 7, 7, 29, 31, 31, 31, 68, 68, 68, 2, 2, 17, 17, 30, 30, 24, 24, 28, 28, 58, 58, 12, -13, -13, -31, -31, -29, -29, 43, 43, 43, -31, -31, -3, -30, -30, -23, -23, -14, -24, -3, -3, -47, -47, -12, -27, -27, -44, -46, -26, 31, 29, -53, -65, 25, -6, -3, -7, -4, -4, -8, -4, 1, -3, -3, -6, -4, -47, -47, -47, -23, -23, -5, -7, -9, -7, -20, -13, -9, -9, -29, -23, 1, 12, 12, 0, 0, 0, -6, 5, -6, -3, -3, -2, -4, -3, -3]
    private static let toNational: [Int] = [65, -1, -1, -1, -1, 31, 31, 47, 47, 29, 29, 53, 31, 31, 46, 44, 30, 30, -7, -7, -7, 13, 13, -2, -2, 23, 23, 24, -21, -21, 27, 27, 47, 47, 47, 26, 14, -33, -33, -33, -17, -17, 3, -29, 12, -12, -31, -31, -31, 3, 3, -24, -24, -44, -44, -30, -30, -28, -28, 23, 23, 6, 7, 29, 8, 3, 4, 4, 20, 4, 23, 6, 3, 3, 4, -1, 13, 9, 7, 5, 7, 9, 9, -43, -43, -43, -68, -68, -68, -58, -58, -25, -29, -31, 6, -1, 6, 0, 0, 0, 3, 3, 4, 2, 3, 3, -5, -12, -12]

    static func national(_ raw: Int) -> Int {
        let shift = raw - 917
        return shift >= 0 && shift < toNational.count ? raw + toNational[shift] : raw
    }

    static func internalID(_ species: Int) -> Int {
        let shift = species - 917
        return shift >= 0 && shift < toInternal.count ? species + toInternal[shift] : species
    }
}

enum PKSwitch {
    static func decode(_ bytes: [UInt8], layout L: SwitchLayout) -> Mon? {
        guard bytes.count >= L.storedSize, !bytes.slice(0, L.storedSize).isAllZero else { return nil }
        let d = PKXCrypto.decrypt6(Array(bytes.prefix(max(L.storedSize, min(bytes.count, L.partySize)))), storedSize: L.storedSize)
        guard PKXCrypto.checksumValid6(d, storedSize: L.storedSize) else { return nil }
        let raw = d.u16(8)
        guard raw != 0 else { return nil }
        var m = Mon()
        m.sourceFamily = L.family
        m.raw = d
        m.encryptionConstant = d.u32(0)
        m.species = L.speciesShift9 ? Species9.national(raw) : raw
        m.heldItem = PokeData.shared.item(fromGame: d.u16(0x0A), generation: L.family == .sv || L.family == .za ? 9 : 8)
        m.tid = d.u16(0x0C)
        m.sid = d.u16(0x0E)
        m.exp = Int(d.u32(0x10))
        m.ability = d.u16(0x14)
        let number = d.u8(0x16) & 7
        m.abilitySlot = number == 4 ? 2 : (number == 2 ? 1 : 0)
        m.pid = d.u32(0x1C)
        m.nature = d.u8(0x20)
        m.statNature = d.u8(0x21) == m.nature ? -1 : d.u8(0x21)
        m.fatefulEncounter = d.u8(0x22) & 1 == 1
        m.gender = (d.u8(0x22) >> L.genderShift) & 3
        m.form = d.u16(0x24)
        m.evs = (0..<6).map { d.u8(0x26 + $0) }
        m.pokerus = d.u8(0x32)
        m.nickname = TextCodec.decodeUTF16(d.slice(L.nickname, 0x1A))
        m.moves = (0..<4).map { d.u16(L.moves + $0 * 2) }
        m.pp = (0..<4).map { d.u8(L.pp + $0) }
        m.ppUps = (0..<4).map { d.u8(L.ppUps + $0) }
        m.relearnMoves = (0..<4).map { d.u16(L.relearn + $0 * 2) }
        m.currentHP = d.u16(L.hp)
        let iv = d.u32(L.iv)
        m.ivs = (0..<6).map { Int((iv >> (UInt32($0) * 5)) & 31) }
        m.isEgg = (iv >> 30) & 1 == 1
        m.isNicknamed = (iv >> 31) & 1 == 1
        m.otName = TextCodec.decodeUTF16(d.slice(L.otName, 0x1A))
        m.friendship = d.u8(L.otFriendship)
        m.metDate = DateComponents(year: 2000 + d.u8(L.metDate), month: d.u8(L.metDate + 1), day: d.u8(L.metDate + 2))
        m.eggLocation = d.u16(L.eggLocation)
        m.metLocation = d.u16(L.metLocation)
        m.ball = d.u8(L.ball)
        m.metLevel = d.u8(L.metLevel) & 0x7F
        m.otGender = d.u8(L.metLevel) >> 7
        m.originGame = PKGame.from(originVersion: d.u8(L.version))
        m.language = d.u8(L.language)
        m.level = PokeData.shared.level(forExp: m.exp, species: m.species)
        if d.count >= L.partySize {
            m.level = d.u8(L.partyStats)
            m.stats = (0..<6).map { d.u16(L.partyStats + 2 + $0 * 2) }
        }
        return m
    }

    /// `owner` is the save's trainer: a Pokémon from someone else gets them as its current handler.
    static func encode(_ m: Mon, layout L: SwitchLayout, game: PKGame, owner: (name: String, gender: Int, tid: Int, sid: Int), party: Bool) throws -> [UInt8] {
        guard game.canStore(species: m.species, form: m.form) else {
            throw PKError.unsupported("\(m.speciesName) can't live in \(game.name).")
        }
        var d = m.sourceFamily == L.family && m.raw.count >= L.storedSize ? Array(m.raw.prefix(L.storedSize)) : [UInt8](repeating: 0, count: L.storedSize)
        let gen = game.generation
        d.set32(0, m.encryptionConstant != 0 ? m.encryptionConstant : m.pid)
        d.set16(8, L.speciesShift9 ? Species9.internalID(m.species) : m.species)
        d.set16(0x0A, PokeData.shared.item(toGame: m.heldItem, generation: gen))
        d.set16(0x0C, m.tid & 0xFFFF)
        d.set16(0x0E, m.sid & 0xFFFF)
        let exp = m.exp > 0 ? m.exp : PokeData.shared.exp(forLevel: m.level, species: m.species)
        d.set32(0x10, UInt32(exp))
        d.set16(0x14, m.ability)
        d.set8(0x16, (d.u8(0x16) & ~7) | (m.abilitySlot == 2 ? 4 : (m.abilitySlot == 1 ? 2 : 1)))
        d.set32(0x1C, m.pid)
        d.set8(0x20, m.nature)
        d.set8(0x21, m.statNature >= 0 ? m.statNature : m.nature)
        let genderMask = 3 << L.genderShift
        d.set8(0x22, (d.u8(0x22) & ~(genderMask | 1)) | (m.gender & 3) << L.genderShift | (m.fatefulEncounter ? 1 : 0))
        d.set16(0x24, m.form)
        for i in 0..<6 { d.set8(0x26 + i, min(m.evs[i], 252)) }
        d.set8(0x32, m.pokerus)
        let nick = m.isEgg ? "Egg" : (m.isNicknamed ? m.nickname : PokeData.shared.speciesName(m.species))
        if TextCodec.decodeUTF16(d.slice(L.nickname, 0x1A)) != nick { d.put(L.nickname, TextCodec.encodeUTF16(nick, chars: 13)) }
        for i in 0..<4 {
            d.set16(L.moves + i * 2, m.moves[i])
            d.set8(L.pp + i, m.pp[i])
            d.set8(L.ppUps + i, min(m.ppUps[i], 3))
            d.set16(L.relearn + i * 2, m.relearnMoves[i])
        }
        var iv: UInt32 = 0
        for i in 0..<6 { iv |= UInt32(min(m.ivs[i], 31)) << (UInt32(i) * 5) }
        if m.isEgg { iv |= 1 << 30 }
        if m.isNicknamed { iv |= 1 << 31 }
        d.set32(L.iv, iv)
        if TextCodec.decodeUTF16(d.slice(L.otName, 0x1A)) != m.otName { d.put(L.otName, TextCodec.encodeUTF16(m.otName, chars: 13)) }
        d.set8(L.otFriendship, min(m.friendship, 255))
        if let date = m.metDate, let y = date.year {
            d.set8(L.metDate, max(0, y - 2000)); d.set8(L.metDate + 1, date.month ?? 1); d.set8(L.metDate + 2, date.day ?? 1)
        }
        d.set16(L.eggLocation, m.eggLocation)
        d.set16(L.metLocation, m.metLocation)
        d.set8(L.ball, (1...37).contains(m.ball) ? m.ball : 4)
        d.set8(L.metLevel, (m.metLevel & 0x7F) | (m.otGender & 1) << 7)
        let origin = m.originGame?.originVersion ?? game.originVersion
        d.set8(L.version, origin)
        d.set8(L.language, min(max(m.language, 1), 10))
        if L.family == .sv && m.sourceFamily != .sv {
            // Tera Type defaults to the species' first type.
            let type = PokeData.shared.monData(species: m.species, form: m.form)?.types.first ?? 1
            d.set8(0x94, max(0, type - 1))
            d.set8(0x95, 0x13)
        }
        if L.family == .sv || L.family == .za { d.set8(0x11F, max(m.metLevel, 1)) }   // obedience level
        // Handling trainer: the save's owner looks after Pokémon from other trainers.
        let isOwner = m.otName == owner.name && m.tid == owner.tid && m.sid == owner.sid
        if !isOwner {
            if TextCodec.decodeUTF16(d.slice(L.htName, 0x1A)) != owner.name { d.put(L.htName, TextCodec.encodeUTF16(owner.name, chars: 13)) }
            d.set8(L.htName + 0x1A, owner.gender)
            d.set8(L.handler, 1)
            if d.u8(L.handler + 4) == 0 { d.set8(L.handler + 4, PokeData.shared.info(m.species).baseFriendship) }
        } else {
            d.set8(L.handler, 0)
        }
        var full = m
        full.level = PokeData.shared.level(forExp: exp, species: m.species)
        full.recalculateStats()
        d.set16(L.hp, m.currentHP > 0 && m.currentHP <= full.stats[0] ? m.currentHP : full.stats[0])
        if party {
            d += [UInt8](repeating: 0, count: L.partySize - L.storedSize)
            d.set8(L.partyStats, full.level)
            for i in 0..<6 { d.set16(L.partyStats + 2 + i * 2, full.stats[i]) }
        }
        return PKXCrypto.encrypt6(d, storedSize: L.storedSize)
    }
}

/// Sword/Shield, Legends: Arceus, Scarlet/Violet and Legends: Z-A saves (SwishCrypto + blocks).
final class SaveSwish: SaveFile {
    private var blocks: [SCBlock]
    private(set) var game: PKGame
    private let layout: SwitchLayout
    private let boxKey: UInt32, partyKey: UInt32, statusKey: UInt32
    private let layoutKey: UInt32 = 0x1972_2C89
    /// Bytes per box slot / party slot inside the blocks (Z-A pads both).
    private let boxSlot: Int, partySlot: Int

    init(data: [UInt8], hint: PKGame?) throws {
        let decrypted = try SwishCrypto.decrypt(data)
        blocks = decrypted
        let keys = Set(decrypted.map(\.key))
        func has(_ key: UInt32) -> Bool { keys.contains(key) }
        if has(0x47E1_CEAB) {                              // Legends: Arceus box
            game = .legendsArceus; layout = .pa8
            boxKey = 0x47E1_CEAB; partyKey = 0x2985_FE5D; statusKey = 0xF25C_070E
            boxSlot = 0x168; partySlot = 0x178
        } else if has(0x2D87_BE5C) {                       // Z-A Pokédex
            game = .legendsZA; layout = .pa9
            boxKey = 0x0D66_012C; partyKey = 0x3AA1_A9AD; statusKey = 0xE3E8_9BD1
            boxSlot = 0x158 + 0x40; partySlot = 0x158 + 0x48 + 0x40
        } else if has(0x3AA1_A9AD) {                       // Scarlet/Violet party
            layout = .pk9
            boxKey = 0x0D66_012C; partyKey = 0x3AA1_A9AD; statusKey = 0xE3E8_9BD1
            boxSlot = 0x158; partySlot = 0x158
            game = .scarlet
        } else if has(0x2985_FE5D) {                       // Sword/Shield party
            layout = .pk8
            boxKey = 0x0D66_012C; partyKey = 0x2985_FE5D; statusKey = 0xF25C_070E
            boxSlot = 0x158; partySlot = 0x158
            game = .sword
        } else {
            throw PKError.unsupported("This Switch save isn't one of the supported Pokémon games.")
        }
        let statusGame = statusData.u8(statusGameOffset)
        if let stored = PKGame.from(originVersion: statusGame), stored.family == game.family { game = stored }
        else if let hint, hint.family == game.family { game = hint }
    }

    private func index(_ key: UInt32) -> Int? { blocks.firstIndex { $0.key == key } }
    private var statusData: [UInt8] { index(statusKey).map { blocks[$0].data } ?? [] }
    private var statusGameOffset: Int { layout.family == .swsh ? 0xA4 : (layout.family == .pla ? 0x14 : 0x04) }
    private var statusNameOffset: Int { layout.family == .swsh ? 0xB0 : (layout.family == .pla ? 0x20 : 0x10) }
    private var statusIDOffset: Int { layout.family == .swsh ? 0xA0 : (layout.family == .pla ? 0x10 : 0x00) }

    var trainerName: String { statusData.count > statusNameOffset + 0x1A ? TextCodec.decodeUTF16(statusData.slice(statusNameOffset, 0x1A)) : "" }
    var trainerID: Int { statusData.count > statusIDOffset + 4 ? statusData.u16(statusIDOffset) : 0 }
    var secretID: Int { statusData.count > statusIDOffset + 4 ? statusData.u16(statusIDOffset + 2) : 0 }
    var trainerGender: Int { statusData.count > statusGameOffset + 1 ? statusData.u8(statusGameOffset + 1) : 0 }
    var boxCount: Int {
        guard let i = index(boxKey) else { return 0 }
        return min(32, blocks[i].data.count / (boxSlot * 30))
    }
    var boxSize: Int { 30 }

    func boxName(_ box: Int) -> String {
        guard let i = index(layoutKey), blocks[i].data.count >= (box + 1) * 0x22 else { return "Box \(box + 1)" }
        let name = TextCodec.decodeUTF16(blocks[i].data.slice(box * 0x22, 0x22))
        return name.isEmpty ? "Box \(box + 1)" : name
    }

    private var partyCount: Int {
        guard let i = index(partyKey) else { return 0 }
        let d = blocks[i].data
        if layout.family == .za {
            return (0..<6).first { PKSwitch.decode(d.slice($0 * partySlot, layout.partySize), layout: layout) == nil } ?? 6
        }
        return min(d.u8(6 * partySlot), 6)
    }

    func party() -> [Mon] { (0..<partyCount).compactMap { mon(at: .party($0)) } }

    func mon(at slot: SlotRef) -> Mon? {
        switch slot.area {
        case .party:
            guard slot.index < partyCount, let i = index(partyKey) else { return nil }
            return PKSwitch.decode(blocks[i].data.slice(slot.index * partySlot, layout.partySize), layout: layout)
        case .box:
            guard let i = index(boxKey) else { return nil }
            let o = (slot.box * 30 + slot.index) * boxSlot
            let size = layout.family == .pla ? layout.storedSize : layout.partySize
            guard o + size <= blocks[i].data.count else { return nil }
            return PKSwitch.decode(blocks[i].data.slice(o, size), layout: layout)
        }
    }

    private var owner: (name: String, gender: Int, tid: Int, sid: Int) { (trainerName, trainerGender, trainerID, secretID) }

    private func emptySlot(_ size: Int) -> [UInt8] {
        PKXCrypto.encrypt6([UInt8](repeating: 0, count: size), storedSize: layout.storedSize)
    }

    func set(_ mon: Mon?, at slot: SlotRef) throws {
        switch slot.area {
        case .box:
            guard let i = index(boxKey) else { throw PKError.corrupt("The boxes are missing from this save.") }
            let party = layout.family != .pla
            let bytes = try mon.map { try PKSwitch.encode($0, layout: layout, game: game, owner: owner, party: party) }
                ?? emptySlot(party ? layout.partySize : layout.storedSize)
            blocks[i].data.put((slot.box * 30 + slot.index) * boxSlot, bytes)
        case .party:
            guard let i = index(partyKey) else { throw PKError.corrupt("The party is missing from this save.") }
            var members = party()
            if let mon {
                if slot.index < members.count { members[slot.index] = mon } else { members.append(mon) }
            } else if slot.index < members.count {
                guard members.count > 1 else { throw PKError.unsupported("The party can't be left empty.") }
                members.remove(at: slot.index)
            }
            // Keep each slot's trailing bytes (Z-A footers) from an occupied slot.
            let footer = layout.family == .za ? blocks[i].data.slice(layout.partySize, partySlot - layout.partySize) : []
            for s in 0..<6 {
                let bytes = s < members.count ? try PKSwitch.encode(members[s], layout: layout, game: game, owner: owner, party: true) : emptySlot(layout.partySize)
                blocks[i].data.put(s * partySlot, bytes)
                if layout.family == .za {
                    var tail = footer
                    if s >= members.count { tail = [UInt8](repeating: 0, count: footer.count); tail[0x48] = 1 }
                    blocks[i].data.put(s * partySlot + layout.partySize, tail)
                }
            }
            if layout.family != .za { blocks[i].data.set8(6 * partySlot, members.count) }
        }
    }

    func serialize() throws -> [UInt8] { SwishCrypto.encrypt(blocks) }
    /// The hash is checked when the file is opened (opening fails otherwise) and redone on save.
    var integrityProblem: String? { nil }
}

/// Brilliant Diamond / Shining Pearl: a plain file with an MD5 over everything.
final class SaveBDSP: SaveFile {
    private var data: [UInt8]
    private(set) var game: PKGame
    private let box = 0x14EF4, partyOffset = 0x14098, layoutOffset = 0x148AA, status = 0x79BB4
    private let hashOffset = 0xE9828 - 16
    private let slot = 0x158
    let companions: [String]

    static func looksValid(_ d: [UInt8]) -> Bool {
        guard [0xE9828, 0xEDC20, 0xEED8C, 0xEF0A4].contains(d.count) else { return false }
        return [0x25, 0x2C, 0x32, 0x34].contains(d.u32(0) & 0xFF) || d.u32(0) > 0
    }

    init(data: [UInt8], hint: PKGame?, companions: [String] = ["Backup.bin"]) throws {
        guard Self.looksValid(data) else { throw PKError.unsupported("Not a Brilliant Diamond / Shining Pearl save.") }
        self.data = data
        self.companions = companions
        game = hint == .shiningPearl ? .shiningPearl : .brilliantDiamond
    }

    var trainerName: String { TextCodec.decodeUTF16(data.slice(status, 0x1A)) }
    var trainerID: Int { data.u16(status + 0x1C) }
    var secretID: Int { data.u16(status + 0x1E) }
    var trainerGender: Int { 0 }
    var boxCount: Int { 40 }
    var boxSize: Int { 30 }

    func boxName(_ b: Int) -> String {
        let name = TextCodec.decodeUTF16(data.slice(layoutOffset + b * 0x22, 0x22))
        return name.isEmpty ? "Box \(b + 1)" : name
    }

    private var partyCount: Int { min(data.u8(partyOffset + 6 * slot), 6) }

    func party() -> [Mon] { (0..<partyCount).compactMap { mon(at: .party($0)) } }

    func mon(at s: SlotRef) -> Mon? {
        switch s.area {
        case .party:
            guard s.index < partyCount else { return nil }
            return PKSwitch.decode(data.slice(partyOffset + s.index * slot, slot), layout: .pb8)
        case .box:
            return PKSwitch.decode(data.slice(box + (s.box * 30 + s.index) * slot, slot), layout: .pb8)
        }
    }

    private var owner: (name: String, gender: Int, tid: Int, sid: Int) { (trainerName, trainerGender, trainerID, secretID) }

    func set(_ mon: Mon?, at s: SlotRef) throws {
        let empty = PKXCrypto.encrypt6([UInt8](repeating: 0, count: slot), storedSize: 0x148)
        switch s.area {
        case .box:
            let bytes = try mon.map { try PKSwitch.encode($0, layout: .pb8, game: game, owner: owner, party: true) } ?? empty
            data.put(box + (s.box * 30 + s.index) * slot, bytes)
        case .party:
            var members = party()
            if let mon {
                if s.index < members.count { members[s.index] = mon } else { members.append(mon) }
            } else if s.index < members.count {
                guard members.count > 1 else { throw PKError.unsupported("The party can't be left empty.") }
                members.remove(at: s.index)
            }
            for i in 0..<6 {
                let bytes = i < members.count ? try PKSwitch.encode(members[i], layout: .pb8, game: game, owner: owner, party: true) : empty
                data.put(partyOffset + i * slot, bytes)
            }
            data.set8(partyOffset + 6 * slot, members.count)
        }
    }

    private static func md5(_ d: [UInt8]) -> [UInt8] {
        Array(Insecure.MD5.hash(data: d))
    }

    func serialize() throws -> [UInt8] {
        var out = data
        out.put(hashOffset, [UInt8](repeating: 0, count: 16))
        out.put(hashOffset, Self.md5(out))
        return out
    }


    var integrityProblem: String? { checksumValid ? nil : "the MD5 hash is wrong" }

    var checksumValid: Bool {
        var copy = data
        copy.put(hashOffset, [UInt8](repeating: 0, count: 16))
        return Self.md5(copy) == data.slice(hashOffset, 16)
    }
}

/// Let's Go, Pikachu! / Eevee!: 1000 storage slots (shown as 40 boxes of 25) plus a party index list.
final class SaveLGPE: SaveFile {
    private var data: [UInt8]
    private(set) var game: PKGame
    private let table: BlockTable3DS
    private let storage = 0x05C00, header = 0x05A00, status = 0x01000
    private var touched: Set<Int> = []

    static func looksValid(_ d: [UInt8]) -> Bool {
        d.count == 0x100000 && d.u32(0xB8800 - 0x1F0) == 0x4245_4546 && d.u16(0xB8800 - 0x200 + 0xB0) == 0x13
    }

    init(data: [UInt8], hint: PKGame?) throws {
        guard Self.looksValid(data), let table = BlockTable3DS(Array(data.prefix(0xB8800)), gen: 7) else {
            throw PKError.unsupported("Not a Let's Go save.")
        }
        self.data = data
        self.table = BlockTable3DS(rebinding: table) { Checksums.crc16noInvert($0, $1) }
        let stored = PKGame.from(originVersion: data.u8(status + 4))
        game = stored == .letsGoEevee ? .letsGoEevee : (stored == .letsGoPikachu ? .letsGoPikachu : (hint == .letsGoEevee ? .letsGoEevee : .letsGoPikachu))
    }

    var trainerName: String { TextCodec.decodeUTF16(data.slice(status + 0x38, 0x1A)) }
    var trainerID: Int { data.u16(status) }
    var secretID: Int { data.u16(status + 2) }
    var trainerGender: Int { data.u8(status + 5) }
    var boxCount: Int { 40 }
    var boxSize: Int { 25 }

    private func partyIndex(_ i: Int) -> Int { data.u16(header + i * 2) }

    private var partyIndexes: [Int] { (0..<6).map(partyIndex).filter { $0 < 1000 } }

    func party() -> [Mon] { partyIndexes.compactMap { decode(at: $0) } }

    private func decode(at index: Int) -> Mon? {
        guard let bytes = Optional(data.slice(storage + index * 0x104, 0x104)), !bytes.isAllZero else { return nil }
        let d = PKXCrypto.decrypt6(bytes, storedSize: 0xE8)
        guard PKXCrypto.checksumValid6(d, storedSize: 0xE8), d.u16(8) != 0 else { return nil }
        var m = Mon()
        m.sourceFamily = .lgpe
        m.raw = d
        PK67.decodeCommon(d, into: &m, gen: 7)
        m.level = d.u8(0xEC) > 0 ? d.u8(0xEC) : m.level
        m.currentHP = d.u16(0xF0)
        m.stats = (0..<6).map { d.u16(0xF2 + $0 * 2) }
        return m
    }

    func mon(at slot: SlotRef) -> Mon? {
        switch slot.area {
        case .party:
            let list = partyIndexes
            return slot.index < list.count ? decode(at: list[slot.index]) : nil
        case .box:
            // Party members live in storage too and show up in their box slot, like in the game.
            return decode(at: slot.box * 25 + slot.index)
        }
    }

    private func encode(_ m: Mon) throws -> [UInt8] {
        guard game.canStore(species: m.species, form: m.form) else { throw PKError.unsupported("\(m.speciesName) can't live in \(game.name).") }
        var d = m.sourceFamily == .lgpe && m.raw.count >= 0xE8 ? Array(m.raw.prefix(0xE8)) : [UInt8](repeating: 0, count: 0xE8)
        PK67.encodeCommon(m, into: &d, gen: 7, game: game)
        var full = m
        full.level = PokeData.shared.level(forExp: Int(d.u32(0x10)), species: m.species)
        full.recalculateStats()
        d += m.sourceFamily == .lgpe && m.raw.count >= 0x104 ? Array(m.raw[0xE8..<0x104]) : [UInt8](repeating: 0, count: 0x104 - 0xE8)
        d.set8(0xEC, full.level)
        d.set16(0xF0, full.stats[0])
        for i in 0..<6 { d.set16(0xF2 + i * 2, full.stats[i]) }
        return PKXCrypto.encrypt6(d, storedSize: 0xE8)
    }

    private var firstFreeStorage: Int? {
        let used = Set(partyIndexes)
        return (0..<1000).first { !used.contains($0) && decode(at: $0) == nil }
    }

    func set(_ mon: Mon?, at slot: SlotRef) throws {
        let empty = PKXCrypto.encrypt6([UInt8](repeating: 0, count: 0x104), storedSize: 0xE8)
        switch slot.area {
        case .box:
            let index = slot.box * 25 + slot.index
            if mon == nil, partyIndexes.contains(index) { throw PKError.unsupported("That Pokémon is in your party; take it out of the party first.") }
            data.put(storage + index * 0x104, try mon.map(encode) ?? empty)
        case .party:
            var list = partyIndexes
            if let mon {
                if slot.index < list.count {
                    data.put(storage + list[slot.index] * 0x104, try encode(mon))
                } else {
                    guard let free = firstFreeStorage else { throw PKError.unsupported("Storage is full.") }
                    data.put(storage + free * 0x104, try encode(mon))
                    list.append(free)
                }
            } else if slot.index < list.count {
                guard list.count > 1 else { throw PKError.unsupported("The party can't be left empty.") }
                data.put(storage + list[slot.index] * 0x104, empty)
                list.remove(at: slot.index)
            }
            for i in 0..<6 { data.set16(header + i * 2, i < list.count ? list[i] : 1001) }
            touched.insert(8)
        }
        touched.insert(9)
    }

    func serialize() throws -> [UInt8] {
        var out = data
        for id in touched { table.fix(&out, id) }
        return out
    }

    var integrityProblem: String? {
        let main = Array(data.prefix(0xB8800))
        if let bad = table.blocks.first(where: { !table.isValid(main, $0.id) }) { return "block \(bad.id) has a wrong checksum" }
        return nil
    }
}
