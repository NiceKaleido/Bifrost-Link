import Foundation

/// Game data generated from PokeAPI by `scripts/gen-pokedata.py` (names, stats, learnsets,
/// evolutions, dexes, index maps). Loaded once, lazily. No artwork lives here.
final class PokeData: @unchecked Sendable {
    static let shared = PokeData()

    struct SpeciesInfo {
        var generation = 0
        var genderRate = -1      // -1 genderless, 0 always male … 8 always female (in eighths)
        var growthRate = 1       // PokeAPI growth rate id (1…6)
        var evolvesFrom = 0
        var catchRate = 0
        var baseFriendship = 70
        var hatchCycles = 20
    }

    struct Form {
        let name: String
        let pokemon: Int         // PokeAPI pokemon id (holds stats and learnsets)
        let since: Int           // version group the form appeared in
    }

    struct MonData {
        let species: Int
        let stats: [Int]         // hp atk def spa spd spe (PokeAPI order)
        let types: [Int]
        let abilities: [Int]     // slot 1, slot 2, hidden
    }

    struct Move {
        let name: String
        let type: Int
        let pp: Int
        let power: Int
        let accuracy: Int
        let generation: Int
        let category: Int        // 1 status, 2 physical, 3 special
    }

    struct Learnset {
        var levelUp: [(level: Int, move: Int)] = []
        var machine: [Int] = []
        var tutor: [Int] = []
        var egg: [Int] = []
        var reminder: [Int] = []
    }

    struct Evolution {
        enum Trigger: Int { case levelUp = 1, trade = 2, useItem = 3, other = 0 }
        let from: Int
        let to: Int
        let trigger: Trigger
        let item: Int
        let minLevel: Int
        let heldItem: Int
        let tradeSpecies: Int
        let sinceVersionGroup: Int
        let evolvedForm: Int     // PokeAPI pokemon_form id, 0 = default
    }

    struct Nature {
        let name: String
        let up: Int              // PokeAPI stat id (2 atk … 6 spe), equal = neutral
        let down: Int
    }

    let source: String
    let speciesNames: [String]
    let speciesInfo: [SpeciesInfo]
    let forms: [Int: [Form]]
    let mons: [Int: MonData]
    let identifiers: [Int: String]            // PokeAPI pokemon id → identifier ("rattata-alola")
    let moves: [Move?]
    let items: [String]
    let itemIndex: [Int: [Int: Int]]          // generation → game index → item id
    let itemGameIndex: [Int: [Int: Int]]      // generation → item id → game index
    let abilities: [String]
    let types: [String]
    let natures: [Nature]
    let growth: [[Int]]
    let gameIndex: [Int: [Int: Int]]          // PokeAPI version id → internal index → pokemon id
    let evolutions: [Evolution]
    let dex: [Int: Set<Int>]                  // version group → species in its regional dexes
    let present: [Int: [Int: Set<Int>]]       // version group → species → forms the game can hold (Switch games)
    private let learnRaw: [String: Any]
    private var learnCache: [String: Learnset] = [:]
    private let lock = NSLock()

    private init() {
        var root: [String: Any] = [:]
        if let url = Bundle.main.url(forResource: "pokedata.json", withExtension: "deflate") ?? PokeData.devURL(),
           let packed = try? Data(contentsOf: url),
           let raw = try? (packed as NSData).decompressed(using: .zlib) as Data,
           let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            root = json
        } else {
            Log.write("pokedata: missing or unreadable")
        }
        func ints(_ any: Any?) -> [Int] { (any as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? [] }

        source = root["source"] as? String ?? ""
        speciesNames = root["species"] as? [String] ?? []
        speciesInfo = ((root["speciesInfo"] as? [Any]) ?? []).map { entry in
            let v = ints(entry)
            guard v.count >= 7 else { return SpeciesInfo() }
            return SpeciesInfo(generation: v[0], genderRate: v[1], growthRate: v[2], evolvesFrom: v[3],
                               catchRate: v[4], baseFriendship: v[5], hatchCycles: v[6])
        }
        var forms: [Int: [Form]] = [:]
        for (key, value) in (root["forms"] as? [String: Any]) ?? [:] {
            forms[Int(key) ?? 0] = ((value as? [[Any]]) ?? []).map {
                Form(name: $0[0] as? String ?? "", pokemon: ($0[1] as? NSNumber)?.intValue ?? 0, since: ($0[2] as? NSNumber)?.intValue ?? 0)
            }
        }
        self.forms = forms
        var mons: [Int: MonData] = [:]
        for (key, value) in (root["mons"] as? [String: Any]) ?? [:] {
            guard let v = value as? [Any], v.count == 4 else { continue }
            mons[Int(key) ?? 0] = MonData(species: (v[0] as? NSNumber)?.intValue ?? 0, stats: ints(v[1]), types: ints(v[2]), abilities: ints(v[3]))
        }
        self.mons = mons
        var identifiers: [Int: String] = [:]
        for (key, value) in (root["ids"] as? [String: String]) ?? [:] { identifiers[Int(key) ?? 0] = value }
        self.identifiers = identifiers
        moves = ((root["moves"] as? [Any]) ?? []).map { entry in
            guard let v = entry as? [Any], v.count == 7 else { return nil }
            let n = v.dropFirst().map { ($0 as? NSNumber)?.intValue ?? 0 }
            return Move(name: v[0] as? String ?? "", type: n[0], pp: n[1], power: n[2], accuracy: n[3], generation: n[4], category: n[5])
        }
        items = root["items"] as? [String] ?? []
        var itemIndex: [Int: [Int: Int]] = [:], itemGameIndex: [Int: [Int: Int]] = [:]
        for (gen, map) in (root["itemIndex"] as? [String: [String: NSNumber]]) ?? [:] {
            let g = Int(gen) ?? 0
            for (index, item) in map {
                itemIndex[g, default: [:]][Int(index) ?? 0] = item.intValue
                itemGameIndex[g, default: [:]][item.intValue] = Int(index) ?? 0
            }
        }
        self.itemIndex = itemIndex
        self.itemGameIndex = itemGameIndex
        abilities = root["abilities"] as? [String] ?? []
        types = root["types"] as? [String] ?? []
        natures = ((root["natures"] as? [[Any]]) ?? []).map {
            Nature(name: $0[0] as? String ?? "", up: ($0[1] as? NSNumber)?.intValue ?? 0, down: ($0[2] as? NSNumber)?.intValue ?? 0)
        }
        growth = ((root["growth"] as? [Any]) ?? []).map(ints)
        var gameIndex: [Int: [Int: Int]] = [:]
        for (version, map) in (root["gameIndex"] as? [String: [String: NSNumber]]) ?? [:] {
            gameIndex[Int(version) ?? 0] = Dictionary(uniqueKeysWithValues: map.map { (Int($0.key) ?? 0, $0.value.intValue) })
        }
        self.gameIndex = gameIndex
        evolutions = ((root["evolutions"] as? [[Any]]) ?? []).map { row in
            let v = row.map { ($0 as? NSNumber)?.intValue ?? 0 }
            return Evolution(from: v[0], to: v[1], trigger: Evolution.Trigger(rawValue: v[2]) ?? .other, item: v[3], minLevel: v[4],
                             heldItem: v[5], tradeSpecies: v[6], sinceVersionGroup: v[7], evolvedForm: v[8])
        }
        var dex: [Int: Set<Int>] = [:]
        for (vg, list) in (root["dex"] as? [String: Any]) ?? [:] { dex[Int(vg) ?? 0] = Set(ints(list)) }
        self.dex = dex
        var present: [Int: [Int: Set<Int>]] = [:]
        for (vg, table) in (root["present"] as? [String: [String: Any]]) ?? [:] {
            var map: [Int: Set<Int>] = [:]
            for (species, forms) in table { map[Int(species) ?? 0] = Set(ints(forms)) }
            present[Int(vg) ?? 0] = map
        }
        self.present = present
        learnRaw = root["learn"] as? [String: Any] ?? [:]
    }

    /// While developing (`swift run`), read the file straight from the repo.
    private static func devURL() -> URL? {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let candidate = url.appendingPathComponent("Resources/pokedata.json.deflate")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    var isLoaded: Bool { speciesNames.count > 1 }
    var maxSpecies: Int { speciesNames.count - 1 }

    // MARK: - Lookups

    func speciesName(_ species: Int) -> String {
        species > 0 && species < speciesNames.count ? speciesNames[species] : "#\(species)"
    }

    func info(_ species: Int) -> SpeciesInfo {
        species > 0 && species < speciesInfo.count ? speciesInfo[species] : SpeciesInfo()
    }

    func moveName(_ move: Int) -> String {
        move > 0 && move < moves.count ? moves[move]?.name ?? "Move \(move)" : "—"
    }

    func move(_ id: Int) -> Move? { id > 0 && id < moves.count ? moves[id] : nil }

    func itemName(_ item: Int) -> String {
        item > 0 && item < items.count ? items[item] : (item == 0 ? "None" : "Item \(item)")
    }

    func abilityName(_ ability: Int) -> String {
        ability > 0 && ability < abilities.count ? abilities[ability] : "—"
    }

    func typeName(_ type: Int) -> String { type > 0 && type < types.count ? types[type] : "" }

    func natureName(_ nature: Int) -> String { nature >= 0 && nature < natures.count ? natures[nature].name : "—" }

    /// The PokeAPI "pokemon" entry (stats, abilities, learnset) for a species form.
    func pokemonID(species: Int, form: Int) -> Int {
        guard let list = forms[species], !list.isEmpty else { return species }
        return list[min(max(form, 0), list.count - 1)].pokemon
    }

    func monData(species: Int, form: Int) -> MonData? {
        mons[pokemonID(species: species, form: form)] ?? mons[species]
    }

    func formName(species: Int, form: Int) -> String {
        guard let list = forms[species], form > 0, form < list.count else { return "" }
        return list[form].name
    }

    func formCount(_ species: Int) -> Int { forms[species]?.count ?? 1 }

    // MARK: - Experience

    func exp(forLevel level: Int, species: Int) -> Int {
        let rate = info(species).growthRate
        guard rate >= 1, rate <= growth.count else { return 0 }
        let table = growth[rate - 1]
        return table[min(max(level, 1), 100)]
    }

    func level(forExp exp: Int, species: Int) -> Int {
        let rate = info(species).growthRate
        guard rate >= 1, rate <= growth.count else { return 1 }
        let table = growth[rate - 1]
        var level = 1
        while level < 100 && table[level + 1] <= exp { level += 1 }
        return level
    }

    // MARK: - Items across generations

    /// Converts a game's own item index to the PokeAPI item id.
    func item(fromGame index: Int, generation: Int) -> Int {
        guard index > 0 else { return 0 }
        return itemIndex[generation]?[index] ?? 0
    }

    /// Converts a PokeAPI item id to the game's own index (0 when the item doesn't exist there).
    func item(toGame item: Int, generation: Int) -> Int {
        guard item > 0 else { return 0 }
        return itemGameIndex[generation]?[item] ?? 0
    }

    // MARK: - Learnsets

    func learnset(species: Int, form: Int, versionGroup: Int) -> Learnset {
        let pid = pokemonID(species: species, form: form)
        let key = "\(versionGroup)/\(pid)"
        lock.lock(); defer { lock.unlock() }
        if let cached = learnCache[key] { return cached }
        var set = Learnset()
        let group = learnRaw[String(versionGroup)] as? [String: Any]
        let entry = (group?[String(pid)] ?? group?[String(species)]) as? [String: Any]
        if let entry {
            set.levelUp = ((entry["l"] as? [[NSNumber]]) ?? []).map { (level: $0[0].intValue, move: $0[1].intValue) }
            func list(_ k: String) -> [Int] { ((entry[k] as? [NSNumber]) ?? []).map(\.intValue) }
            set.machine = list("m"); set.tutor = list("t"); set.egg = list("e"); set.reminder = list("r")
        }
        learnCache[key] = set
        return set
    }

    /// Version groups that have any learnset data (used to fall back for games PokeAPI lacks).
    var learnsetGroups: [Int] { learnRaw.keys.compactMap(Int.init).sorted() }
}
