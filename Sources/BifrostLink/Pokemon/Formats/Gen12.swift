import Foundation

/// Gen 1 and Gen 2 Pokémon (PK1 33/44 bytes, PK2 32/48 bytes) and their list layout:
/// count, species list (+0xFF), structures, OT names, nicknames.
enum PKGB {
    static let nameLength = 11

    static func storedSize(gen: Int) -> Int { gen == 1 ? 33 : 32 }
    static func partySize(gen: Int) -> Int { gen == 1 ? 44 : 48 }
    static func listSize(gen: Int, capacity: Int, party: Bool) -> Int {
        let size = party ? partySize(gen: gen) : storedSize(gen: gen)
        return 2 + capacity * (size + 2 * nameLength) + capacity
    }

    // MARK: Species numbering

    static func national(fromGen1 index: Int) -> Int {
        guard let pid = PokeData.shared.gameIndex[1]?[index] else { return 0 }
        return PokeData.shared.mons[pid]?.species ?? 0
    }

    static func gen1Index(fromNational species: Int) -> Int {
        guard species > 0, species <= 151, let map = PokeData.shared.gameIndex[1] else { return 0 }
        return map.first { PokeData.shared.mons[$0.value]?.species == species }?.key ?? 0
    }

    /// Gen 1 type ids for the stored type bytes.
    static func gen1Type(_ pokeAPIType: Int) -> Int {
        // PokeAPI: 1 normal 2 fighting 3 flying 4 poison 5 ground 6 rock 7 bug 8 ghost 10 fire 11 water 12 grass 13 electric 14 psychic 15 ice 16 dragon
        [1: 0, 2: 1, 3: 2, 4: 3, 5: 4, 6: 5, 7: 7, 8: 8, 10: 20, 11: 21, 12: 22, 13: 23, 14: 24, 15: 25, 16: 26][pokeAPIType] ?? 0
    }

    // MARK: Decode

    static func decode(list: [UInt8], at offset: Int, slot: Int, capacity: Int, party: Bool, gen: Int, game: PKGame) -> Mon? {
        let count = Int(list[offset])
        guard slot < min(count, capacity) else { return nil }
        let speciesByte = Int(list[offset + 1 + slot])
        let size = party ? partySize(gen: gen) : storedSize(gen: gen)
        let structs = offset + 2 + capacity
        let ots = structs + capacity * size
        let nicks = ots + capacity * nameLength
        let d = list.slice(structs + slot * size, size)
        var m = Mon()
        m.sourceFamily = gen == 1 ? .gen1 : .gen2
        m.raw = d
        m.otName = TextCodec.decodeGB(list.slice(ots + slot * nameLength, nameLength))
        m.nickname = TextCodec.decodeGB(list.slice(nicks + slot * nameLength, nameLength))
        m.originGame = game
        m.language = 2
        if gen == 1 {
            m.species = national(fromGen1: d.u8(0))
            m.moves = (0..<4).map { d.u8(8 + $0) }
            m.tid = d.u16be(12)
            m.exp = d.u24be(14)
            m.statExp = (0..<5).map { d.u16be(17 + $0 * 2) }
            m.dvs = d.u16be(27)
            m.pp = (0..<4).map { d.u8(29 + $0) & 0x3F }
            m.ppUps = (0..<4).map { d.u8(29 + $0) >> 6 }
            m.heldItem = 0
            m.level = party ? d.u8(33) : d.u8(3)
            m.currentHP = d.u16be(1)
            m.status = d.u8(4)
            if party { m.stats = [d.u16be(34), d.u16be(36), d.u16be(38), d.u16be(40), d.u16be(42), d.u16be(42)] }
        } else {
            m.isEgg = speciesByte == 0xFD
            m.species = d.u8(0)
            m.heldItem = PokeData.shared.item(fromGame: d.u8(1), generation: 2)
            m.moves = (0..<4).map { d.u8(2 + $0) }
            m.tid = d.u16be(6)
            m.exp = d.u24be(8)
            m.statExp = (0..<5).map { d.u16be(11 + $0 * 2) }
            m.dvs = d.u16be(21)
            m.pp = (0..<4).map { d.u8(23 + $0) & 0x3F }
            m.ppUps = (0..<4).map { d.u8(23 + $0) >> 6 }
            m.friendship = d.u8(27)
            m.pokerus = d.u8(28)
            m.caughtData = d.u16be(29)
            m.metLevel = (m.caughtData >> 8) & 0x3F
            m.metLocation = m.caughtData & 0x7F
            m.otGender = (m.caughtData >> 7) & 1
            m.level = d.u8(31)
            if party {
                m.status = d.u8(32)
                m.currentHP = d.u16be(34)
                m.stats = (0..<6).map { d.u16be(36 + $0 * 2) }
            }
        }
        guard m.species > 0 else { return nil }
        let dv = m.dvs ?? 0
        m.ivs = Mon.ivs(fromDVs: dv)
        m.evs = [0, 0, 0, 0, 0, 0]
        m.gender = Mon.genderFromDVs(dv, species: m.species)
        if m.species == 201 {
            // Unown letter from the middle bits of each DV
            let a = (dv >> 12) & 0x6, b = (dv >> 8) & 0x6, c = (dv >> 4) & 0x6, e = dv & 0x6
            m.form = ((a << 5) | (b << 3) | (c << 1) | (e >> 1)) / 10
        }
        if let abilities = PokeData.shared.monData(species: m.species, form: m.form)?.abilities { m.ability = abilities[0] }
        m.nature = m.exp % 25          // what Pokémon Bank assigns
        m.isNicknamed = m.nickname.caseInsensitiveCompare(PokeData.shared.speciesName(m.species)) != .orderedSame
        m.ball = 4
        return m
    }

    // MARK: Encode

    static func encode(_ m: Mon, gen: Int, party: Bool) throws -> [UInt8] {
        let size = party ? partySize(gen: gen) : storedSize(gen: gen)
        var d = (m.sourceFamily == (gen == 1 ? .gen1 : .gen2)) && m.raw.count >= storedSize(gen: gen)
            ? Array(m.raw.prefix(storedSize(gen: gen))) + [UInt8](repeating: 0, count: size - storedSize(gen: gen))
            : [UInt8](repeating: 0, count: size)
        if d.count > size { d = Array(d.prefix(size)) }
        let dv = m.dvs ?? Mon.dvs(fromIVs: m.ivs)
        let statExp = m.statExp ?? m.evs.prefix(5).map { min(65535, $0 * 257) }
        var full = m
        full.dvs = dv
        full.statExp = statExp
        let exp = m.exp > 0 ? min(m.exp, PokeData.shared.exp(forLevel: 100, species: m.species)) : PokeData.shared.exp(forLevel: m.level, species: m.species)
        full.level = PokeData.shared.level(forExp: exp, species: m.species)
        full.recalculateStatsGB()
        func ppByte(_ i: Int) -> Int { (min(m.ppUps[i], 3) << 6) | min(m.pp[i], 63) }
        if gen == 1 {
            let index = gen1Index(fromNational: m.species)
            guard index > 0 else { throw PKError.unsupported("\(m.speciesName) doesn't exist in Gen 1.") }
            d.set8(0, index)
            d.set16be(1, full.stats[0])
            d.set8(3, full.level)
            d.set8(4, 0)
            let types = PokeData.shared.monData(species: m.species, form: 0)?.types ?? [1, 1]
            let past = PKGB.gen1Types[m.species]
            d.set8(5, past?.0 ?? gen1Type(types[0]))
            d.set8(6, past?.1 ?? gen1Type(types[1]))
            if m.sourceFamily != .gen1 { d.set8(7, PokeData.shared.info(m.species).catchRate) }
            for i in 0..<4 { d.set8(8 + i, m.moves[i]) }
            d.set16be(12, m.tid & 0xFFFF)
            d.set24be(14, exp)
            for i in 0..<5 { d.set16be(17 + i * 2, statExp[i]) }
            d.set16be(27, dv)
            for i in 0..<4 { d.set8(29 + i, ppByte(i)) }
            if party {
                d.set8(33, full.level)
                d.set16be(34, full.stats[0]); d.set16be(36, full.stats[1]); d.set16be(38, full.stats[2])
                d.set16be(40, full.stats[3]); d.set16be(42, full.stats[4])
            }
        } else {
            guard m.species <= 251 else { throw PKError.unsupported("\(m.speciesName) doesn't exist in Gen 2.") }
            d.set8(0, m.species)
            d.set8(1, PokeData.shared.item(toGame: m.heldItem, generation: 2))
            for i in 0..<4 { d.set8(2 + i, m.moves[i]) }
            d.set16be(6, m.tid & 0xFFFF)
            d.set24be(8, exp)
            for i in 0..<5 { d.set16be(11 + i * 2, statExp[i]) }
            d.set16be(21, dv)
            for i in 0..<4 { d.set8(23 + i, ppByte(i)) }
            d.set8(27, min(m.friendship, 255))
            d.set8(28, m.pokerus)
            d.set16be(29, m.caughtData)
            d.set8(31, full.level)
            if party {
                d.set8(32, 0)
                d.set16be(34, full.stats[0])
                for i in 0..<6 { d.set16be(36 + i * 2, full.stats[i]) }
            }
        }
        return d
    }

    /// Writes a whole list (party or box) from Pokémon.
    static func writeList(_ mons: [Mon], into data: inout [UInt8], at offset: Int, capacity: Int, party: Bool, gen: Int) throws {
        let size = party ? partySize(gen: gen) : storedSize(gen: gen)
        let structs = offset + 2 + capacity
        let ots = structs + capacity * size
        let nicks = ots + capacity * nameLength
        data.set8(offset, mons.count)
        for i in 0...capacity { data.set8(offset + 1 + i, 0xFF) }
        for (i, m) in mons.enumerated() {
            let bytes = try encode(m, gen: gen, party: party)
            data.set8(offset + 1 + i, gen == 2 && m.isEgg ? 0xFD : Int(bytes[0]))
            data.put(structs + i * size, bytes)
            data.put(ots + i * nameLength, TextCodec.encodeGB(m.otName, length: nameLength))
            let nick = m.isEgg ? "EGG" : (m.isNicknamed ? m.nickname : PokeData.shared.speciesName(m.species).uppercased())
            data.put(nicks + i * nameLength, TextCodec.encodeGB(nick, length: nameLength))
        }
        for i in mons.count..<capacity {
            data.put(structs + i * size, [UInt8](repeating: 0, count: size))
            data.put(ots + i * nameLength, [UInt8](repeating: 0, count: nameLength))
            data.put(nicks + i * nameLength, [UInt8](repeating: 0, count: nameLength))
        }
    }

    /// Gen 1 typings that changed later (Fairy, Steel), as Gen 1 type ids.
    static let gen1Types: [Int: (Int, Int)] = [
        35: (0, 0), 36: (0, 0), 39: (0, 0), 40: (0, 0),        // Clefairy line, Jigglypuff line: Normal
        81: (23, 23), 82: (23, 23),                           // Magnemite, Magneton: Electric
        122: (24, 24),                                        // Mr. Mime: Psychic
    ]
}

/// Red, Blue, Yellow (international) 32 KB saves.
final class SaveGen1: SaveFile {
    private var data: [UInt8]
    private(set) var game: PKGame
    private let boxCapacity = 20
    private var boxes: [[Mon]] = []
    private var partyMons: [Mon] = []

    static func looksValid(_ d: [UInt8]) -> Bool {
        guard d.count >= 0x8000 else { return false }
        func list(_ o: Int, _ max: Int) -> Bool { let c = Int(d[o]); return c <= max && d[o + 1 + c] == 0xFF }
        return list(0x2F2C, 20) && list(0x30C0, 20)
    }

    static func looksJapanese(_ d: [UInt8]) -> Bool {
        guard d.count >= 0x8000 else { return false }
        func list(_ o: Int, _ max: Int) -> Bool { let c = Int(d[o]); return c <= max && d[o + 1 + c] == 0xFF }
        return list(0x2ED5, 30) && list(0x302D, 30)
    }

    init(data: [UInt8], hint: PKGame?) throws {
        guard Self.looksValid(data) else { throw PKError.unsupported("Not an international Gen 1 save.") }
        self.data = data
        let yellow = data[0x29C3] == 0x54 || data[0x271C] != 0   // Pikachu starter / friendship
        game = yellow ? .yellow : (hint.map { [.red, .blue, .green].contains($0) ? $0 : .red } ?? .red)
        let current = Int(data[0x284C] & 0x7F)
        let size = PKGB.listSize(gen: 1, capacity: boxCapacity, party: false)
        for b in 0..<12 {
            let offset = b == current ? 0x30C0 : (b < 6 ? 0x4000 + b * size : 0x6000 + (b - 6) * size)
            let initialized = b == current || data[0x284C] & 0x80 != 0
            var mons: [Mon] = []
            if initialized && Int(data[offset]) <= boxCapacity {
                for i in 0..<Int(data[offset]) {
                    if let m = PKGB.decode(list: data, at: offset, slot: i, capacity: boxCapacity, party: false, gen: 1, game: game) { mons.append(m) }
                }
            }
            boxes.append(mons)
        }
        for i in 0..<min(Int(data[0x2F2C]), 6) {
            if let m = PKGB.decode(list: data, at: 0x2F2C, slot: i, capacity: 6, party: true, gen: 1, game: game) { partyMons.append(m) }
        }
    }

    var trainerName: String { TextCodec.decodeGB(data.slice(0x2598, 11)) }
    var trainerID: Int { data.u16be(0x2605) }
    var secretID: Int { 0 }
    var trainerGender: Int { 0 }
    var boxCount: Int { 12 }
    var boxSize: Int { boxCapacity }

    func party() -> [Mon] { partyMons }

    func mon(at slot: SlotRef) -> Mon? {
        switch slot.area {
        case .party: return slot.index < partyMons.count ? partyMons[slot.index] : nil
        case .box: return slot.index < boxes[slot.box].count ? boxes[slot.box][slot.index] : nil
        }
    }

    /// Gen 1/2 boxes are packed lists, so a new Pokémon goes to the end of the box.
    func set(_ mon: Mon?, at slot: SlotRef) throws {
        switch slot.area {
        case .party:
            if let mon {
                if slot.index < partyMons.count { partyMons[slot.index] = mon } else if partyMons.count < 6 { partyMons.append(mon) }
            } else if slot.index < partyMons.count {
                guard partyMons.count > 1 else { throw PKError.unsupported("The party can't be left empty.") }
                partyMons.remove(at: slot.index)
            }
        case .box:
            if let mon {
                if slot.index < boxes[slot.box].count { boxes[slot.box][slot.index] = mon }
                else if boxes[slot.box].count < boxCapacity { boxes[slot.box].append(mon) }
                else { throw PKError.unsupported("That box is full.") }
            } else if slot.index < boxes[slot.box].count {
                boxes[slot.box].remove(at: slot.index)
            }
        }
        // Validate right away so errors surface on the change, not on save.
        _ = try mon.map { try PKGB.encode($0, gen: 1, party: slot.area == .party) }
    }

    func registerDex(_ mon: Mon) {
        guard mon.species > 0, mon.species <= 151 else { return }
        data.setBit(0x25A3, mon.species - 1, true)
        data.setBit(0x25B6, mon.species - 1, true)
    }

    func serialize() throws -> [UInt8] {
        var out = data
        let size = PKGB.listSize(gen: 1, capacity: boxCapacity, party: false)
        let current = Int(out[0x284C] & 0x7F)
        let anyBoxes = boxes.enumerated().contains { $0.offset != current && !$0.element.isEmpty }
        if anyBoxes { out[0x284C] |= 0x80 }
        for b in 0..<12 {
            let offset = b < 6 ? 0x4000 + b * size : 0x6000 + (b - 6) * size
            if out[0x284C] & 0x80 != 0 || b == current {
                try PKGB.writeList(boxes[b], into: &out, at: offset, capacity: boxCapacity, party: false, gen: 1)
            }
            if b == current { out.put(0x30C0, out.slice(offset, size)) }
        }
        try PKGB.writeList(partyMons, into: &out, at: 0x2F2C, capacity: 6, party: true, gen: 1)
        out[0x3523] = Self.checksum(out, 0x2598..<0x3523)
        // Box bank checksums: whole bank, then one per box.
        for (bank, base) in [(0, 0x4000), (1, 0x6000)] {
            out[base + 0x1A4C] = Self.checksum(out, base..<(base + 0x1A4C))
            for i in 0..<6 { out[base + 0x1A4D + i] = Self.checksum(out, (base + i * size)..<(base + (i + 1) * size)) }
            _ = bank
        }
        return out
    }

    private static func checksum(_ d: [UInt8], _ range: Range<Int>) -> UInt8 {
        var sum: UInt8 = 0
        for i in range { sum &+= d[i] }
        return ~sum
    }

    var checksumValid: Bool { data[0x3523] == Self.checksum(data, 0x2598..<0x3523) }
    var integrityProblem: String? { checksumValid ? nil : "the main checksum is wrong" }
}

/// Gold, Silver, Crystal (international) saves; the RTC footer after 32 KB is kept untouched.
final class SaveGen2: SaveFile {
    private var data: [UInt8]
    private(set) var game: PKGame
    private let crystal: Bool
    private let boxCapacity = 20
    private var boxes: [[Mon]] = []
    private var partyMons: [Mon] = []

    private var currentBoxIndex: Int { crystal ? 0x2700 : 0x2724 }
    private var boxNames: Int { crystal ? 0x2703 : 0x2727 }
    private var partyOffset: Int { crystal ? 0x2865 : 0x288A }
    private var dexCaught: Int { crystal ? 0x2A27 : 0x2A4C }
    private var dexSeen: Int { crystal ? 0x2A47 : 0x2A6C }
    private var currentBox: Int { crystal ? 0x2D10 : 0x2D6C }
    private var checksumEnd: Int { crystal ? 0x2B82 : 0x2D68 }
    private var checksum1: Int { crystal ? 0x2D0D : 0x2D69 }
    private var checksum2: Int { crystal ? 0x1F0D : 0x7E6D }

    static func detect(_ d: [UInt8]) -> Bool? {
        guard d.count >= 0x8000 else { return nil }
        func list(_ o: Int, _ max: Int) -> Bool { let c = Int(d[o]); return c <= max && d[o + 1 + c] == 0xFF }
        if list(0x288A, 20) && list(0x2D6C, 20) { return false }
        if list(0x2865, 20) && list(0x2D10, 20) { return true }
        return nil
    }

    init(data: [UInt8], hint: PKGame?) throws {
        guard let crystal = Self.detect(data) else { throw PKError.unsupported("Not an international Gen 2 save.") }
        self.data = data
        self.crystal = crystal
        game = crystal ? .crystal : (hint == .silver ? .silver : .gold)
        let size = PKGB.listSize(gen: 2, capacity: boxCapacity, party: false)
        let current = Int(data[currentBoxIndex] & 0x7F)
        for b in 0..<14 {
            let offset = b == current ? currentBox : (b < 7 ? 0x4000 + b * (size + 2) : 0x6000 + (b - 7) * (size + 2))
            var mons: [Mon] = []
            if Int(data[offset]) <= boxCapacity {
                for i in 0..<Int(data[offset]) {
                    if let m = PKGB.decode(list: data, at: offset, slot: i, capacity: boxCapacity, party: false, gen: 2, game: game) { mons.append(m) }
                }
            }
            boxes.append(mons)
        }
        for i in 0..<min(Int(data[partyOffset]), 6) {
            if let m = PKGB.decode(list: data, at: partyOffset, slot: i, capacity: 6, party: true, gen: 2, game: game) { partyMons.append(m) }
        }
    }

    var trainerName: String { TextCodec.decodeGB(data.slice(0x200B, 11)) }
    var trainerID: Int { data.u16be(0x2009) }
    var secretID: Int { 0 }
    var trainerGender: Int { crystal ? Int(data[0x3E3D]) : 0 }
    var boxCount: Int { 14 }
    var boxSize: Int { boxCapacity }

    func boxName(_ box: Int) -> String {
        let name = TextCodec.decodeGB(data.slice(boxNames + box * 9, 9))
        return name.isEmpty ? "Box \(box + 1)" : name
    }

    func party() -> [Mon] { partyMons }

    func mon(at slot: SlotRef) -> Mon? {
        switch slot.area {
        case .party: return slot.index < partyMons.count ? partyMons[slot.index] : nil
        case .box: return slot.index < boxes[slot.box].count ? boxes[slot.box][slot.index] : nil
        }
    }

    func set(_ mon: Mon?, at slot: SlotRef) throws {
        switch slot.area {
        case .party:
            if let mon {
                if slot.index < partyMons.count { partyMons[slot.index] = mon } else if partyMons.count < 6 { partyMons.append(mon) }
            } else if slot.index < partyMons.count {
                guard partyMons.count > 1 else { throw PKError.unsupported("The party can't be left empty.") }
                partyMons.remove(at: slot.index)
            }
        case .box:
            if let mon {
                if slot.index < boxes[slot.box].count { boxes[slot.box][slot.index] = mon }
                else if boxes[slot.box].count < boxCapacity { boxes[slot.box].append(mon) }
                else { throw PKError.unsupported("That box is full.") }
            } else if slot.index < boxes[slot.box].count {
                boxes[slot.box].remove(at: slot.index)
            }
        }
        _ = try mon.map { try PKGB.encode($0, gen: 2, party: slot.area == .party) }
    }

    func registerDex(_ mon: Mon) {
        guard mon.species > 0, mon.species <= 251 else { return }
        data.setBit(dexCaught, mon.species - 1, true)
        data.setBit(dexSeen, mon.species - 1, true)
    }

    func serialize() throws -> [UInt8] {
        var out = data
        let size = PKGB.listSize(gen: 2, capacity: boxCapacity, party: false)
        let current = Int(out[currentBoxIndex] & 0x7F)
        for b in 0..<14 {
            let offset = b < 7 ? 0x4000 + b * (size + 2) : 0x6000 + (b - 7) * (size + 2)
            try PKGB.writeList(boxes[b], into: &out, at: offset, capacity: boxCapacity, party: false, gen: 2)
            if b == current { out.put(currentBox, out.slice(offset, size)) }
        }
        try PKGB.writeList(partyMons, into: &out, at: partyOffset, capacity: 6, party: true, gen: 2)
        var sum = 0
        for i in 0x2009...checksumEnd { sum &+= Int(out[i]) }
        out.set16(checksum1, sum & 0xFFFF)
        out.set16(checksum2, sum & 0xFFFF)
        // Mirror into the backup copy the game falls back to.
        if crystal {
            out.put(0x1209, out.slice(0x2009, 0xB7A))
        } else {
            out.put(0x15C7, Array(out[0x2009..<0x222F]))
            out.put(0x3D69, Array(out[0x222F..<0x23D9]))
            out.put(0x0C6B, Array(out[0x23D9..<0x2856]))
            out.put(0x7E39, Array(out[0x2856..<0x288A]))
            out.put(0x10E8, Array(out[0x288A..<0x2D69]))
        }
        return out
    }

    var checksumValid: Bool {
        var sum = 0
        for i in 0x2009...checksumEnd { sum &+= Int(data[i]) }
        return data.u16(checksum1) == sum & 0xFFFF
    }
    var integrityProblem: String? {
        var sum = 0
        for i in 0x2009...checksumEnd { sum &+= Int(data[i]) }
        if data.u16(checksum1) != sum & 0xFFFF { return "the main checksum is wrong" }
        if data.u16(checksum2) != sum & 0xFFFF { return "the backup checksum is wrong" }
        return nil
    }
}
