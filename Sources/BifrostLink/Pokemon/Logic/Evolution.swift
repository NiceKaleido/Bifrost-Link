import Foundation

/// Evolutions that normally need a trade, done in place.
enum TradeEvolution {
    struct Option: Identifiable, Hashable {
        let to: Int
        let heldItem: Int            // item the Pokémon must hold (consumed), 0 = none
        let partner: Int             // Karrablast ↔ Shelmet, 0 = none
        var id: Int { to }
        var name: String { PokeData.shared.speciesName(to) }

        var requirement: String {
            if heldItem > 0 { return "while holding \(PokeData.shared.itemName(heldItem))" }
            if partner > 0 { return "traded for \(PokeData.shared.speciesName(partner))" }
            return "by trading"
        }
    }

    /// Version group → generation, to know whether an evolution exists yet in a game.
    static func generation(ofVersionGroup vg: Int) -> Int {
        switch vg {
        case 1, 2, 28, 29: return 1
        case 3, 4: return 2
        case 5, 6, 7, 12, 13: return 3
        case 8, 9, 10: return 4
        case 11, 14: return 5
        case 15, 16: return 6
        case 17, 18, 19: return 7
        case 20, 21, 22, 23, 24: return 8
        default: return 9
        }
    }

    /// Trade evolutions available for this Pokémon in this game. Ones whose required item isn't held
    /// are still listed (so the editor can offer to give the item), flagged by `needsItem`.
    static func options(for mon: Mon, in game: PKGame) -> [(option: Option, needsItem: Bool)] {
        guard !mon.isEgg else { return [] }
        var seen = Set<Int>()
        var out: [(Option, Bool)] = []
        for evo in PokeData.shared.evolutions where evo.from == mon.species && evo.trigger == .trade {
            guard generation(ofVersionGroup: evo.sinceVersionGroup) <= game.generation,
                  game.canStore(species: evo.to, form: 0), !seen.contains(evo.to) else { continue }
            if evo.heldItem > 0 && PokeData.shared.item(toGame: evo.heldItem, generation: game.generation) == 0 && game.generation >= 2 { continue }
            if evo.heldItem > 0 && game.generation == 1 { continue }
            seen.insert(evo.to)
            let option = Option(to: evo.to, heldItem: evo.heldItem, partner: evo.tradeSpecies)
            out.append((option, evo.heldItem > 0 && mon.heldItem != evo.heldItem))
        }
        return out
    }

    struct Result {
        var mon: Mon
        var newMoves: [Int]          // moves the evolved form learns on evolving (offer them)
        var notes: [String]
    }

    static func evolve(_ mon: Mon, into option: Option, in game: PKGame) -> Result {
        var m = mon
        var notes: [String] = []
        let oldName = mon.name
        m.species = option.to
        if PokeData.shared.formCount(option.to) <= m.form { m.form = 0 }
        if option.heldItem > 0 {
            m.heldItem = 0
            notes.append("Used up the \(PokeData.shared.itemName(option.heldItem)).")
        }
        if !m.isNicknamed { m.nickname = PokeData.shared.speciesName(option.to) }
        if let abilities = PokeData.shared.monData(species: m.species, form: m.form)?.abilities {
            let slot = game.generation < 5 && m.abilitySlot == 2 ? 0 : m.abilitySlot
            m.ability = abilities[min(slot, abilities.count - 1)]
        }
        if game.generation <= 2 { m.recalculateStatsGB() } else { m.recalculateStats() }
        let learnset = MoveSuggester.learnset(species: m.species, form: m.form, game: game)
        let onEvolve = learnset.levelUp.filter { $0.level == 0 || $0.level == m.level }.map(\.move).filter { !m.moves.contains($0) }
        notes.insert("\(oldName) evolved into \(PokeData.shared.speciesName(option.to))!", at: 0)
        return Result(mon: m, newMoves: Array(Set(onEvolve)).sorted(), notes: notes)
    }
}
