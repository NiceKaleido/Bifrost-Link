import Foundation

/// Moves a Pokémon could know in a game, grouped the way the editor shows them.
struct MoveOption: Identifiable, Hashable {
    enum Source: Hashable {
        case levelUp(Int)
        case evolution
        case machine
        case tutor
        case egg
        case reminder

        var badge: String {
            switch self {
            case .levelUp(let l): return l <= 1 ? "Start" : "Lv \(l)"
            case .evolution: return "Evolve"
            case .machine: return "TM"
            case .tutor: return "Tutor"
            case .egg: return "Egg"
            case .reminder: return "Relearn"
            }
        }

        var order: Int {
            switch self {
            case .levelUp, .evolution: return 0
            case .reminder: return 1
            case .machine: return 2
            case .tutor: return 3
            case .egg: return 4
            }
        }
    }

    let move: Int
    let source: Source
    var id: String { "\(move)-\(source.badge)" }
    var name: String { PokeData.shared.moveName(move) }
}

enum MoveSuggester {
    /// The learnset for the game, falling back to the closest game of the same generation when
    /// PokeAPI has no data for that version group.
    static func learnset(species: Int, form: Int, game: PKGame) -> PokeData.Learnset {
        let data = PokeData.shared
        let own = data.learnset(species: species, form: form, versionGroup: game.versionGroup)
        if !own.levelUp.isEmpty { return own }
        let fallbacks: [PKGame: [Int]] = [.colosseum: [5, 6], .xd: [5, 6], .box: [5, 6], .green: [1], .legendsZA: [25]]
        for vg in fallbacks[game] ?? [] {
            let set = data.learnset(species: species, form: form, versionGroup: vg)
            if !set.levelUp.isEmpty { return set }
        }
        return own
    }

    /// Everything the Pokémon could know at its level in this game, level-up moves first.
    static func options(for mon: Mon, in game: PKGame, includeAll: Bool) -> [MoveOption] {
        let set = learnset(species: mon.species, form: mon.form, game: game)
        var seen = Set<Int>()
        var out: [MoveOption] = []
        func add(_ move: Int, _ source: MoveOption.Source) {
            guard move > 0, move <= game.maxMove, !seen.contains(move) else { return }
            seen.insert(move)
            out.append(MoveOption(move: move, source: source))
        }
        for entry in set.levelUp.sorted(by: { $0.level > $1.level }) where entry.level <= mon.level {
            add(entry.move, entry.level == 0 ? .evolution : .levelUp(entry.level))
        }
        if includeAll {
            set.reminder.forEach { add($0, .reminder) }
            set.machine.forEach { add($0, .machine) }
            set.tutor.forEach { add($0, .tutor) }
            set.egg.forEach { add($0, .egg) }
        }
        return out
    }

    /// The four most recent level-up moves, as the game would have taught them.
    static func latestLevelUp(for mon: Mon, in game: PKGame) -> [Int] {
        let set = learnset(species: mon.species, form: mon.form, game: game)
        var moves: [Int] = []
        for entry in set.levelUp.sorted(by: { ($0.level, $0.move) < ($1.level, $1.move) }) where entry.level <= mon.level && entry.move <= game.maxMove {
            if let i = moves.firstIndex(of: entry.move) { moves.remove(at: i) }
            moves.append(entry.move)
            if moves.count > 4 { moves.removeFirst() }
        }
        return moves + [Int](repeating: 0, count: 4 - moves.count)
    }

    /// Moves that exist in a game at all (Switch games dropped many).
    static func moveExists(_ move: Int, in game: PKGame) -> Bool {
        guard move > 0, move <= game.maxMove else { return false }
        switch game.family {
        case .lgpe, .swsh, .bdsp, .pla, .sv, .za:
            return movesInGame(game.versionGroup).contains(move)
        default:
            return true
        }
    }

    private static var cache: [Int: Set<Int>] = [:]
    private static let lock = NSLock()

    private static func movesInGame(_ vg: Int) -> Set<Int> {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[vg] { return cached }
        var all = Set<Int>()
        let data = PokeData.shared
        for (pid, mon) in data.mons where mon.species <= 1025 {
            let set = data.learnset(species: mon.species, form: data.forms[mon.species]?.firstIndex { $0.pokemon == pid } ?? 0, versionGroup: vg)
            set.levelUp.forEach { all.insert($0.move) }
            all.formUnion(set.machine); all.formUnion(set.tutor); all.formUnion(set.egg); all.formUnion(set.reminder)
        }
        cache[vg] = all
        return all
    }
}
