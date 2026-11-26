import Foundation
import CryptoKit

/// Colosseum, XD and Pokémon Box saves (Dolphin .gci files or bare save data).
enum GameCubeSaves {
    static let gciHeader = 0x40

    static func open(_ data: [UInt8], hint: PKGame?) throws -> SaveFile? {
        var body = data
        var header: [UInt8] = []
        var code = hint.flatMap { [.colosseum, .xd, .box].contains($0) ? $0.romCodes.first : nil }
        if data.count > gciHeader, let gameCode = String(bytes: data.prefix(3), encoding: .ascii), ["GC6", "GXX", "GPX"].contains(gameCode) {
            code = gameCode
            header = Array(data.prefix(gciHeader))
            body = Array(data.dropFirst(gciHeader))
        }
        if code == nil {
            if body.count == SaveColosseum.saveSize { code = "GC6" } else if body.count == SaveXD.saveSize { code = "GXX" } else { return nil }
        }
        switch code {
        case "GC6": return try SaveColosseum(body: body, header: header)
        case "GXX": return try SaveXD(body: body, header: header)
        case "GPX": throw PKError.unsupported("Pokémon Box saves are recognised, but editing them isn't available yet.")
        default: return nil
        }
    }

    // GameCube text is UTF-16 big-endian.
    static func decode(_ d: [UInt8], _ o: Int, _ n: Int) -> String {
        var units: [UInt16] = []
        var i = o
        while i + 1 < o + n { let v = UInt16(d.u16be(i)); if v == 0 { break }; units.append(v); i += 2 }
        return String(decoding: units, as: UTF16.self)
    }

    static func encode(_ s: String, into d: inout [UInt8], _ o: Int, chars: Int) {
        for i in 0..<chars * 2 { d[o + i] = 0 }
        for (i, unit) in s.utf16.prefix(chars - 1).enumerated() { d.set16be(o + i * 2, Int(unit)) }
    }

    /// GameCube language codes: 1 JP, 2 EN, 3 DE, 4 FR, 5 IT, 6 ES.
    static func language(fromGC v: Int) -> Int { [1: 1, 2: 2, 3: 5, 4: 3, 5: 4, 6: 7][v] ?? 2 }
    static func language(toGC v: Int) -> Int { [1: 1, 2: 2, 5: 3, 3: 4, 4: 5, 7: 6][v] ?? 2 }
    /// GameCube origin codes: 1 FR, 2 LG, 8 S, 9 R, 10 E, 11 Colosseum/XD.
    static func game(fromGC v: Int) -> PKGame? { [1: .fireRed, 2: .leafGreen, 8: .sapphire, 9: .ruby, 10: .emerald, 11: .colosseum][v] }
    static func gcVersion(_ game: PKGame?) -> Int {
        switch game { case .fireRed: return 1; case .leafGreen: return 2; case .sapphire: return 8; case .ruby: return 9; case .emerald: return 10; default: return 11 }
    }
}

/// Shared shape of CK3 (Colosseum) and XK3 (XD): big-endian, unencrypted, Gen 3 numbering.
private struct GCLayout {
    let size: Int
    let item: Int, hp: Int, friendship: Int, metLocation: Int, metLevel: Int, ball: Int, otGender: Int, level: Int
    let exp: Int, sid: Int, pid: Int, version: Int, language: Int, otName: Int, nickname: Int, nicknameDisplay: Int
    let moves: Int, stats: Int, evs: Int, ivs: Int, ivBytes: Bool

    static let ck3 = GCLayout(size: 0x138, item: 0x88, hp: 0x8A, friendship: 0xB0, metLocation: 0x0C, metLevel: 0x0E, ball: 0x0F, otGender: 0x10,
                              level: 0x60, exp: 0x5C, sid: 0x14, pid: 0x04, version: 0x08, language: 0x0B, otName: 0x18, nickname: 0x44,
                              nicknameDisplay: 0x2E, moves: 0x78, stats: 0x8C, evs: 0x98, ivs: 0xA4, ivBytes: false)
    static let xk3 = GCLayout(size: 0xC4, item: 0x02, hp: 0x04, friendship: 0x06, metLocation: 0x08, metLevel: 0x0E, ball: 0x0F, otGender: 0x10,
                              level: 0x11, exp: 0x20, sid: 0x24, pid: 0x28, version: 0x34, language: 0x37, otName: 0x38, nickname: 0x64,
                              nicknameDisplay: 0x4E, moves: 0x80, stats: 0x90, evs: 0x9C, ivs: 0xA8, ivBytes: true)
}

private enum GCMon {
    // GC stat order is HP Atk Def SpA SpD Spe; ours is HP Atk Def Spe SpA SpD.
    static let order = [0, 1, 2, 4, 5, 3]        // GC index → our index
    static let fromGC = [0, 1, 2, 5, 3, 4]       // our index → GC index

    static func decode(_ d: [UInt8], layout L: GCLayout, xd: Bool) -> Mon? {
        let species = d.u16be(0)
        guard species != 0, d.count >= L.size else { return nil }
        var m = Mon()
        m.sourceFamily = xd ? .xd : .colosseum
        m.raw = d
        m.species = PK3.internalToNational(species)
        guard m.species > 0 else { return nil }
        m.heldItem = PokeData.shared.item(fromGame: d.u16be(L.item), generation: 3)
        m.currentHP = d.u16be(L.hp)
        m.friendship = min(255, d.u16be(L.friendship))
        m.metLocation = d.u16be(L.metLocation)
        m.metLevel = d.u8(L.metLevel)
        m.ball = d.u8(L.ball)
        m.otGender = d.u8(L.otGender)
        m.level = d.u8(L.level)
        m.exp = Int(d.u32be(L.exp))
        m.sid = d.u16be(L.sid)
        m.tid = d.u16be(L.sid + 2)
        m.pid = d.u32be(L.pid)
        m.encryptionConstant = m.pid
        m.originGame = GameCubeSaves.game(fromGC: d.u8(L.version))
        m.language = GameCubeSaves.language(fromGC: d.u8(L.language))
        m.otName = GameCubeSaves.decode(d, L.otName, 22)
        m.nickname = GameCubeSaves.decode(d, L.nickname, 22)
        m.moves = (0..<4).map { d.u16be(L.moves + $0 * 4) }
        m.pp = (0..<4).map { d.u8(L.moves + $0 * 4 + 2) }
        m.ppUps = (0..<4).map { d.u8(L.moves + $0 * 4 + 3) }
        let gcStats = (0..<6).map { d.u16be(L.stats + $0 * 2) }
        let gcEVs = (0..<6).map { min(255, d.u16be(L.evs + $0 * 2)) }
        let gcIVs = (0..<6).map { L.ivBytes ? d.u8(L.ivs + $0) & 31 : min(31, d.u16be(L.ivs + $0 * 2)) }
        m.stats = fromGC.map { gcStats[$0] }
        m.evs = fromGC.map { gcEVs[$0] }
        m.ivs = fromGC.map { gcIVs[$0] }
        if xd {
            let flags = d.u8(0x1D)
            m.abilitySlot = (flags >> 6) & 1
            m.isEgg = (flags >> 7) & 1 == 1
        } else {
            m.abilitySlot = d.u8(0xCC) & 1
            m.isEgg = d.u8(0xCB) == 1
        }
        m.nature = Int(m.pid % 25)
        m.gender = Mon.gender(pid: m.pid, species: m.species)
        m.form = m.species == 201 ? PK3.unownForm(pid: m.pid) : 0
        if let abilities = PokeData.shared.monData(species: m.species, form: m.form)?.abilities { m.ability = abilities[min(m.abilitySlot, 1)] }
        m.isNicknamed = m.nickname.caseInsensitiveCompare(PokeData.shared.speciesName(m.species)) != .orderedSame
        return m
    }

    static func encode(_ m: Mon, layout L: GCLayout, xd: Bool) throws -> [UInt8] {
        let index = PK3.nationalToInternal(m.species)
        guard index > 0, m.species <= 386 else { throw PKError.unsupported("\(m.speciesName) doesn't exist in \(xd ? "XD" : "Colosseum").") }
        var d = (m.sourceFamily == (xd ? .xd : .colosseum)) && m.raw.count >= L.size ? Array(m.raw.prefix(L.size)) : [UInt8](repeating: 0, count: L.size)
        var full = m
        let exp = m.exp > 0 ? m.exp : PokeData.shared.exp(forLevel: m.level, species: m.species)
        full.level = PokeData.shared.level(forExp: exp, species: m.species)
        full.recalculateStats()
        d.set16be(0, index)
        d.set16be(L.item, PokeData.shared.item(toGame: m.heldItem, generation: 3))
        d.set16be(L.hp, full.stats[0])
        d.set16be(L.friendship, min(m.friendship, 255))
        d.set16be(L.metLocation, m.metLocation)
        d.set8(L.metLevel, m.metLevel)
        d.set8(L.ball, (1...12).contains(m.ball) ? m.ball : 4)
        d.set8(L.otGender, m.otGender & 1)
        d.set8(L.level, full.level)
        d.set32be(L.exp, UInt32(exp))
        d.set16be(L.sid, m.sid & 0xFFFF)
        d.set16be(L.sid + 2, m.tid & 0xFFFF)
        d.set32be(L.pid, m.pid)
        d.set8(L.version, GameCubeSaves.gcVersion(m.originGame))
        d.set8(L.language, GameCubeSaves.language(toGC: m.language))
        if GameCubeSaves.decode(d, L.otName, 22) != m.otName { GameCubeSaves.encode(m.otName, into: &d, L.otName, chars: 11) }
        let nick = m.isNicknamed ? m.nickname : PokeData.shared.speciesName(m.species).uppercased()
        if GameCubeSaves.decode(d, L.nickname, 22) != nick {
            GameCubeSaves.encode(nick, into: &d, L.nickname, chars: 11)
            GameCubeSaves.encode(nick, into: &d, L.nicknameDisplay, chars: 11)
        }
        for i in 0..<4 {
            d.set16be(L.moves + i * 4, m.moves[i])
            d.set8(L.moves + i * 4 + 2, m.pp[i])
            d.set8(L.moves + i * 4 + 3, min(m.ppUps[i], 3))
        }
        for (gc, ours) in order.enumerated() {
            d.set16be(L.stats + gc * 2, full.stats[ours])
            d.set16be(L.evs + gc * 2, min(m.evs[ours], 255))
            if L.ivBytes { d.set8(L.ivs + gc, min(m.ivs[ours], 31)) } else { d.set16be(L.ivs + gc * 2, min(m.ivs[ours], 31)) }
        }
        if xd {
            d.set8(0x1D, (d.u8(0x1D) & 0x3F) | (m.abilitySlot & 1) << 6 | (m.isEgg ? 0x80 : 0))
        } else {
            d.set8(0xCC, m.abilitySlot & 1)
            d.set8(0xCB, m.isEgg ? 1 : 0)
            d.set8(0xCD, 1)   // valid
        }
        return d
    }
}

/// Pokémon Colosseum: three save slots, each SHA-1 chain-encrypted.
final class SaveColosseum: SaveFile {
    static let slotSize = 0x1E000, slotStart = 0x6000, slotCount = 3
    static let saveSize = slotStart + slotSize * slotCount
    private var body: [UInt8]
    private let header: [UInt8]
    private let slotIndex: Int
    private var slot: [UInt8]
    let game: PKGame = .colosseum

    init(body: [UInt8], header: [UInt8]) throws {
        guard body.count == Self.saveSize else { throw PKError.unsupported("This Colosseum save has an unexpected size.") }
        self.body = body
        self.header = header
        var best = -1, index = 0
        for i in 0..<Self.slotCount {
            let counter = Int(Int32(bitPattern: body.u32be(Self.slotStart + i * Self.slotSize + 4)))
            if counter > best { best = counter; index = i }
        }
        slotIndex = index
        slot = Array(body[(Self.slotStart + index * Self.slotSize)..<(Self.slotStart + (index + 1) * Self.slotSize)])
        Self.crypt(&slot, encrypt: false)
    }

    private static func sha1(_ bytes: ArraySlice<UInt8>) -> [UInt8] { Array(Insecure.SHA1.hash(data: Array(bytes))) }

    /// Each 20-byte chunk is XORed with the hash of the previous (encrypted) chunk.
    static func crypt(_ d: inout [UInt8], encrypt: Bool) {
        var digest = d.suffix(20).map { ~$0 }
        var o = 0x18
        let end = d.count - 20
        while o + 20 <= end {
            if encrypt {
                for j in 0..<20 { d[o + j] ^= digest[j] }
                digest = sha1(d[o..<(o + 20)])
            } else {
                let next = sha1(d[o..<(o + 20)])
                for j in 0..<20 { d[o + j] ^= digest[j] }
                digest = next
            }
            o += 20
        }
    }

    private static func setChecksums(_ d: inout [UInt8]) {
        d.set32be(0x0C, 0)
        let hash = sha1(d[0..<(d.count - 40)])
        d.put(d.count - 20, hash)
        var result: Int32 = 0
        for i in stride(from: 0, to: 0x18, by: 4) { result &-= Int32(bitPattern: d.u32be(i)) }
        let h0 = Int32(bitPattern: hash.u32be(0)), h1 = Int32(bitPattern: hash.u32be(4))
        result &-= Int32(bitPattern: d.u32be(0x18)) ^ ~h0
        result &-= Int32(bitPattern: d.u32be(0x1C)) ^ ~h1
        d.set32be(0x0C, UInt32(bitPattern: result))
    }

    /// Header checksum and SHA-1 body hash of the (decrypted) slot.
    var integrityProblem: String? {
        var copy = slot
        let storedHeader = copy.u32be(0x0C), storedHash = copy.suffix(20)
        Self.setChecksums(&copy)
        if Array(copy.suffix(20)) != Array(storedHash) { return "the SHA-1 hash is wrong" }
        if copy.u32be(0x0C) != storedHeader { return "the header checksum is wrong" }
        return nil
    }

    private let partyOffset = 0xA8, box = 0xB90
    var trainerName: String { GameCubeSaves.decode(slot, 0x78, 20) }
    var trainerID: Int { slot.u16be(0xA6) }
    var secretID: Int { slot.u16be(0xA4) }
    var trainerGender: Int { slot.u8(0xAF8) }
    var boxCount: Int { 3 }
    var boxSize: Int { 30 }
    var readOnlyReason: String? { body[0] == 0x83 || header.first.map { _ in header.count > 3 && header[3] == 0x4A } == true ? "Japanese Colosseum saves can be looked at but not changed." : nil }

    func boxName(_ b: Int) -> String {
        let name = GameCubeSaves.decode(slot, box + 0x24A4 * b, 16)
        return name.isEmpty ? "Box \(b + 1)" : name
    }

    private func offset(_ s: SlotRef) -> Int {
        s.area == .party ? partyOffset + s.index * 0x138 : box + (30 * 0x138 + 0x14) * s.box + 0x14 + s.index * 0x138
    }

    func party() -> [Mon] { (0..<6).compactMap { GCMon.decode(slot.slice(offset(.party($0)), 0x138), layout: .ck3, xd: false) } }

    func mon(at s: SlotRef) -> Mon? {
        if s.area == .party && s.index >= party().count { return nil }
        return GCMon.decode(slot.slice(offset(s), 0x138), layout: .ck3, xd: false)
    }

    func set(_ mon: Mon?, at s: SlotRef) throws {
        if let readOnlyReason { throw PKError.readOnly(readOnlyReason) }
        if s.area == .party {
            var members = party()
            if let mon { if s.index < members.count { members[s.index] = mon } else { members.append(mon) } }
            else if s.index < members.count { guard members.count > 1 else { throw PKError.unsupported("The party can't be left empty.") }; members.remove(at: s.index) }
            for i in 0..<6 { slot.put(offset(.party(i)), i < members.count ? try GCMon.encode(members[i], layout: .ck3, xd: false) : [UInt8](repeating: 0, count: 0x138)) }
        } else {
            slot.put(offset(s), try mon.map { try GCMon.encode($0, layout: .ck3, xd: false) } ?? [UInt8](repeating: 0, count: 0x138))
        }
    }

    func serialize() throws -> [UInt8] {
        var out = slot
        Self.setChecksums(&out)
        Self.crypt(&out, encrypt: true)
        var whole = body
        whole.put(Self.slotStart + slotIndex * Self.slotSize, out)
        return header + whole
    }
}

/// Pokémon XD: two save slots, encrypted with four rolling 16-bit keys.
final class SaveXD: SaveFile {
    static let slotSize = 0x28000, slotStart = 0x6000, slotCount = 2
    static let saveSize = slotStart + slotSize * slotCount
    private var body: [UInt8]
    private let header: [UInt8]
    private let slotIndex: Int
    private var slot: [UInt8]
    private var sub: [Int] = []
    let game: PKGame = .xd

    init(body: [UInt8], header: [UInt8]) throws {
        guard body.count == Self.saveSize else { throw PKError.unsupported("This XD save has an unexpected size.") }
        self.body = body
        self.header = header
        var best = -1, index = 0
        for i in 0..<Self.slotCount {
            let counter = Int(Int32(bitPattern: body.u32be(Self.slotStart + i * Self.slotSize + 4)))
            if counter > best { best = counter; index = i }
        }
        slotIndex = index
        slot = Array(body[(Self.slotStart + index * Self.slotSize)..<(Self.slotStart + (index + 1) * Self.slotSize)])
        Self.crypt(&slot, encrypt: false)
        sub = (0..<16).map { slot.u16be(0x40 + $0 * 4) | slot.u16be(0x40 + $0 * 4 + 2) << 16 }
    }

    static func crypt(_ d: inout [UInt8], encrypt: Bool) {
        var keys = (0..<4).map { UInt16(d.u16be(0x08 + $0 * 2)) }
        var o = 0x10
        while o < 0x27FD8 {
            for k in 0..<4 where o < 0x27FD8 {
                let v = UInt16(d.u16be(o))
                d.set16be(o, Int(encrypt ? v &+ keys[k] : v &- keys[k]))
                o += 2
            }
            let k3 = Int(keys[3]) + 0x13, k2 = Int(keys[2]) + 0x17, k1 = Int(keys[1]) + 0x29, k0 = Int(keys[0]) + 0x43
            keys[3] = UInt16(truncatingIfNeeded: ((k0 >> 12) & 0xF) | ((k1 >> 8) & 0xF0) | ((k2 >> 4) & 0xF00) | (k3 & 0xF000))
            keys[2] = UInt16(truncatingIfNeeded: ((k0 >> 8) & 0xF) | ((k1 >> 4) & 0xF0) | (k2 & 0xF00) | ((k3 << 4) & 0xF000))
            keys[1] = UInt16(truncatingIfNeeded: ((k0 >> 4) & 0xF) | (k1 & 0xF0) | ((k2 << 4) & 0xF00) | ((k3 << 8) & 0xF000))
            keys[0] = UInt16(truncatingIfNeeded: (k0 & 0xF) | ((k1 << 4) & 0xF0) | ((k2 << 8) & 0xF00) | ((k3 << 12) & 0xF000))
        }
    }

    private func setChecksums(_ d: inout [UInt8]) {
        var headerSum = 0
        for i in 0..<8 { headerSum += Int(d[i]) }
        d.set32be(0xA8 + sub[0] + 0x38, UInt32(truncatingIfNeeded: headerSum))
        for i in 0x10..<0x20 { d[i] = 0 }
        var sums: [UInt32] = []
        var start = 8
        for _ in 0..<4 {
            var v: UInt32 = 0
            let end = start + 0x9FF4
            var j = start
            while j < end { v &+= UInt32(d.u16be(j)); j += 2 }
            sums.append(v)
            start = end
        }
        var words: [Int] = []
        for v in sums { words.append(Int(v >> 16)); words.append(Int(v & 0xFFFF)) }
        for i in 0..<8 { d.set16be(0x10 + i * 2, words[7 - i]) }
    }

    var integrityProblem: String? {
        var copy = slot
        setChecksums(&copy)
        return copy == slot ? nil : "a checksum is wrong"
    }

    private var trainer: Int { sub[1] + 0xA8 }
    private var partyOffset: Int { trainer + 0x30 }
    private var boxBase: Int { sub[2] + 0xA8 }

    var trainerName: String { GameCubeSaves.decode(slot, trainer, 20) }
    var trainerID: Int { slot.u16be(trainer + 0x2E) }
    var secretID: Int { slot.u16be(trainer + 0x2C) }
    var trainerGender: Int { 0 }
    var boxCount: Int { 8 }
    var boxSize: Int { 30 }

    func boxName(_ b: Int) -> String {
        let name = GameCubeSaves.decode(slot, boxBase + (30 * 0xC4 + 0x14) * b, 16)
        return name.isEmpty ? "Box \(b + 1)" : name
    }

    private func offset(_ s: SlotRef) -> Int {
        s.area == .party ? partyOffset + s.index * 0xC4 : boxBase + (30 * 0xC4 + 0x14) * s.box + 20 + s.index * 0xC4
    }

    func party() -> [Mon] { (0..<6).compactMap { GCMon.decode(slot.slice(offset(.party($0)), 0xC4), layout: .xk3, xd: true) } }

    func mon(at s: SlotRef) -> Mon? {
        if s.area == .party && s.index >= party().count { return nil }
        return GCMon.decode(slot.slice(offset(s), 0xC4), layout: .xk3, xd: true)
    }

    func set(_ mon: Mon?, at s: SlotRef) throws {
        if s.area == .party {
            var members = party()
            if let mon { if s.index < members.count { members[s.index] = mon } else { members.append(mon) } }
            else if s.index < members.count { guard members.count > 1 else { throw PKError.unsupported("The party can't be left empty.") }; members.remove(at: s.index) }
            for i in 0..<6 { slot.put(offset(.party(i)), i < members.count ? try GCMon.encode(members[i], layout: .xk3, xd: true) : [UInt8](repeating: 0, count: 0xC4)) }
        } else {
            slot.put(offset(s), try mon.map { try GCMon.encode($0, layout: .xk3, xd: true) } ?? [UInt8](repeating: 0, count: 0xC4))
        }
    }

    func serialize() throws -> [UInt8] {
        var out = slot
        setChecksums(&out)
        Self.crypt(&out, encrypt: true)
        var whole = body
        whole.put(Self.slotStart + slotIndex * Self.slotSize, out)
        return header + whole
    }
}
