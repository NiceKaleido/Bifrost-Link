import Foundation

/// One Pokémon in a form every generation can be converted to and from.
/// Codecs fill in what their format has; `raw` keeps the original bytes so a Pokémon that is only
/// edited (not converted) is written back without losing fields this model doesn't cover.
struct Mon: Hashable, Identifiable {
    var id = UUID()

    var species = 0              // national dex number
    var form = 0
    var nickname = ""
    var isNicknamed = false
    var isEgg = false
    var language = 2             // 1 JP, 2 EN, 3 FR, 4 IT, 5 DE, 7 ES, 8 KO, 9 ZH-S, 10 ZH-T

    var otName = ""
    var otGender = 0
    var tid = 0                  // 16-bit trainer id (Gen 7+ also shown as a 6-digit id)
    var sid = 0

    var pid: UInt32 = 0
    var encryptionConstant: UInt32 = 0
    var nature = 0
    var statNature = -1          // Gen 8+ mint nature, -1 = same as nature
    var ability = 0              // ability id
    var abilitySlot = 0          // 0 first, 1 second, 2 hidden
    var gender = 0               // 0 male, 1 female, 2 genderless
    var shinyOverride: Bool?     // formats without PID shininess (Gen 1/2, Legends: Arceus flags)

    var level = 1
    var exp = 0
    var friendship = 70
    var heldItem = 0             // PokeAPI item id
    var ball = 4                 // Poké Ball (4) as in Gen 3+ numbering
    var ivs = [0, 0, 0, 0, 0, 0] // hp atk def spe spa spd
    var evs = [0, 0, 0, 0, 0, 0]
    var moves = [0, 0, 0, 0]
    var pp = [0, 0, 0, 0]
    var ppUps = [0, 0, 0, 0]
    var relearnMoves = [0, 0, 0, 0]
    var pokerus = 0
    var markings = 0

    var originGame: PKGame?
    var metLocation = 0
    var metLevel = 0
    var eggLocation = 0
    var metDate: DateComponents?
    var fatefulEncounter = false

    /// Gen 1/2 extras kept for a lossless round trip back into those games.
    var dvs: Int?                // 16-bit DV word
    var statExp: [Int]?          // hp atk def spe spc
    var caughtData = 0           // Crystal

    /// Party-only values; recalculated on write.
    var stats: [Int] = []        // hp atk def spe spa spd
    var currentHP = 0
    var status = 0

    /// The format and bytes this Pokémon was read from.
    var sourceFamily: SaveFamily?
    var raw: [UInt8] = []

    var isEmpty: Bool { species == 0 }

    var name: String {
        if isEgg { return "Egg" }
        return nickname.isEmpty ? PokeData.shared.speciesName(species) : nickname
    }

    var speciesName: String {
        let base = PokeData.shared.speciesName(species)
        let form = PokeData.shared.formName(species: species, form: self.form)
        return form.isEmpty || form == base ? base : "\(base) (\(form))"
    }

    // MARK: - Derived values

    var isShiny: Bool {
        if let shinyOverride { return shinyOverride }
        if let dvs, sourceFamily == .gen1 || sourceFamily == .gen2 { return Mon.isShiny(dvs: dvs) }
        return Mon.shinyValue(pid: pid, tid: tid, sid: sid) < 16
    }

    static func shinyValue(pid: UInt32, tid: Int, sid: Int) -> Int {
        Int((pid >> 16) ^ (pid & 0xFFFF)) ^ tid ^ sid
    }

    /// Gen 2 shininess: Defense, Speed and Special DVs are 10, Attack is 2, 3, 6, 7, 10, 11, 14 or 15.
    static func isShiny(dvs: Int) -> Bool {
        let atk = (dvs >> 12) & 0xF, def = (dvs >> 8) & 0xF, spe = (dvs >> 4) & 0xF, spc = dvs & 0xF
        return def == 10 && spe == 10 && spc == 10 && [2, 3, 6, 7, 10, 11, 14, 15].contains(atk)
    }

    /// Converts Gen 1/2 DVs to IVs the way Pokémon Bank does (DV × 2 + 1, HP from the low bits).
    static func ivs(fromDVs dvs: Int) -> [Int] {
        let atk = (dvs >> 12) & 0xF, def = (dvs >> 8) & 0xF, spe = (dvs >> 4) & 0xF, spc = dvs & 0xF
        let hp = ((atk & 1) << 3) | ((def & 1) << 2) | ((spe & 1) << 1) | (spc & 1)
        return [hp, atk, def, spe, spc, spc].map { $0 * 2 + 1 }
    }

    static func dvs(fromIVs ivs: [Int]) -> Int {
        func dv(_ iv: Int) -> Int { min(15, iv / 2) }
        return dv(ivs[1]) << 12 | dv(ivs[2]) << 8 | dv(ivs[3]) << 4 | dv(ivs[4])
    }

    static func gender(pid: UInt32, species: Int) -> Int {
        let rate = PokeData.shared.info(species).genderRate
        if rate < 0 { return 2 }
        if rate == 0 { return 0 }
        if rate == 8 { return 1 }
        // PokeAPI gives eighths; games compare the low PID byte with a threshold.
        let threshold = [0, 31, 63, 127, 191, 225, 254, 254, 255][rate]
        return Int(pid & 0xFF) < threshold ? 1 : 0
    }

    static func genderFromDVs(_ dvs: Int, species: Int) -> Int {
        let rate = PokeData.shared.info(species).genderRate
        if rate < 0 { return 2 }
        if rate == 0 { return 0 }
        if rate == 8 { return 1 }
        // Female when the Attack DV is at or below the threshold for the species' ratio.
        let threshold = [0, 1, 3, 5, 7, 9, 11, 13, 15][rate]
        return ((dvs >> 12) & 0xF) <= threshold ? 1 : 0
    }

    /// Recalculates stats from base stats, IVs, EVs, level and nature (Gen 3+ formula).
    mutating func recalculateStats() {
        guard let data = PokeData.shared.monData(species: species, form: form), data.stats.count == 6 else { return }
        // PokeAPI order: hp atk def spa spd spe → ours: hp atk def spe spa spd
        let base = [data.stats[0], data.stats[1], data.stats[2], data.stats[5], data.stats[3], data.stats[4]]
        let effective = statNature >= 0 ? statNature : nature
        let natureInfo = effective < PokeData.shared.natures.count ? PokeData.shared.natures[effective] : nil
        // PokeAPI stat ids: 2 atk, 3 def, 4 spa, 5 spd, 6 spe → our index
        let index = [2: 1, 3: 2, 4: 4, 5: 5, 6: 3]
        var result = [Int](repeating: 0, count: 6)
        for i in 0..<6 {
            let core = (2 * base[i] + ivs[i] + evs[i] / 4) * level / 100
            if i == 0 {
                result[0] = species == 292 ? 1 : core + level + 10
            } else {
                var value = core + 5
                if let n = natureInfo, n.up != n.down {
                    if index[n.up] == i { value = value * 110 / 100 }
                    if index[n.down] == i { value = value * 90 / 100 }
                }
                result[i] = value
            }
        }
        stats = result
        currentHP = result[0]
    }

    /// Gen 1/2 stat formula with DVs and stat experience.
    mutating func recalculateStatsGB() {
        guard let data = PokeData.shared.monData(species: species, form: form), data.stats.count == 6 else { return }
        let dv = dvs ?? Mon.dvs(fromIVs: ivs)
        let atk = (dv >> 12) & 0xF, def = (dv >> 8) & 0xF, spe = (dv >> 4) & 0xF, spc = dv & 0xF
        let hpDV = ((atk & 1) << 3) | ((def & 1) << 2) | ((spe & 1) << 1) | (spc & 1)
        let se = statExp ?? [0, 0, 0, 0, 0]
        func bonus(_ e: Int) -> Int { Int(min(255, (sqrt(Double(e)) + 1).rounded(.down))) / 4 }
        func stat(_ base: Int, _ dv: Int, _ e: Int) -> Int { ((base + dv) * 2 + bonus(e)) * level / 100 + 5 }
        let hp = ((data.stats[0] + hpDV) * 2 + bonus(se[0])) * level / 100 + level + 10
        stats = [hp, stat(data.stats[1], atk, se[1]), stat(data.stats[2], def, se[2]), stat(data.stats[5], spe, se[3]),
                 stat(data.stats[3], spc, se[4]), stat(data.stats[4], spc, se[4])]
        currentHP = hp
    }

    /// Max PP for a move with the given PP Ups.
    static func maxPP(move: Int, ppUps: Int) -> Int {
        guard let base = PokeData.shared.move(move)?.pp, base > 0 else { return move == 0 ? 0 : 5 }
        return base + base * ppUps / 5
    }

    mutating func healPP() {
        for i in 0..<4 { pp[i] = Mon.maxPP(move: moves[i], ppUps: ppUps[i]) }
    }

    /// True when the nickname is just the species name in the Pokémon's language.
    var hasDefaultName: Bool {
        !isNicknamed || nickname.caseInsensitiveCompare(PokeData.shared.speciesName(species)) == .orderedSame
    }
}

/// A place a Pokémon can sit in a save.
struct SlotRef: Hashable, Codable {
    enum Area: String, Codable { case party, box }
    let area: Area
    let box: Int
    let index: Int

    static func party(_ i: Int) -> SlotRef { SlotRef(area: .party, box: 0, index: i) }
    static func box(_ b: Int, _ i: Int) -> SlotRef { SlotRef(area: .box, box: b, index: i) }

    var label: String { area == .party ? "Party \(index + 1)" : "Box \(box + 1), slot \(index + 1)" }
}

/// A loaded save. Each family implements reading and writing its own layout.
protocol SaveFile: AnyObject {
    var game: PKGame { get }
    var trainerName: String { get }
    var trainerID: Int { get }
    var secretID: Int { get }
    var trainerGender: Int { get }
    var boxCount: Int { get }
    var boxSize: Int { get }
    var partyCapacity: Int { get }
    var readOnlyReason: String? { get }

    func boxName(_ box: Int) -> String
    func party() -> [Mon]
    func mon(at slot: SlotRef) -> Mon?
    /// Writes a Pokémon (or clears the slot when nil). Party writes keep the party packed.
    func set(_ mon: Mon?, at slot: SlotRef) throws
    /// Marks a species as seen and caught in the Pokédex.
    func registerDex(_ mon: Mon)
    /// The full save, checksums recomputed. Multi-file saves return the main file.
    func serialize() throws -> [UInt8]
    /// Extra files written next to the main one (BDSP Backup.bin), keyed by file name.
    func companionFiles() throws -> [String: [UInt8]]
    /// Why the game would reject this save as it is now (wrong checksum, hash or signature), or nil.
    /// Every format must check everything its game checks: nothing is written unless both the
    /// original and the changed file pass.
    var integrityProblem: String? { get }
}

extension SaveFile {
    var readOnlyReason: String? { nil }
    var partyCapacity: Int { 6 }
    func companionFiles() throws -> [String: [UInt8]] { [:] }
    func registerDex(_ mon: Mon) {}

    func boxName(_ box: Int) -> String { "Box \(box + 1)" }

    func boxContents(_ box: Int) -> [Mon?] {
        (0..<boxSize).map { mon(at: .box(box, $0)) }
    }

    func firstFreeBoxSlot() -> SlotRef? {
        for b in 0..<boxCount {
            for i in 0..<boxSize where mon(at: .box(b, i)) == nil { return .box(b, i) }
        }
        return nil
    }

    var allSlots: [(SlotRef, Mon)] {
        var out: [(SlotRef, Mon)] = party().enumerated().map { (.party($0.offset), $0.element) }
        for b in 0..<boxCount {
            for i in 0..<boxSize { if let m = mon(at: .box(b, i)) { out.append((.box(b, i), m)) } }
        }
        return out
    }

    /// Writes the evolved/edited Pokémon back where it came from.
    func replace(_ mon: Mon, at slot: SlotRef) throws { try set(mon, at: slot) }
}
