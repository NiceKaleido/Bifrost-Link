import Foundation

/// Converts a Pokémon for another game and explains every change in plain words.
struct TransferPlan {
    var mon: Mon
    var changes: [String] = []
    /// The real games could do this move (Poké Transfer, Bank, HOME…).
    var native: Bool
    /// When set, the Pokémon can't go to that game at all.
    var blocked: String?

    var isPossible: Bool { blocked == nil }
}

enum MonTransfer {
    /// Plans moving `mon` (currently in `source`) into `target`. Nothing is written here.
    static func plan(_ original: Mon, from source: PKGame, to target: PKGame) -> TransferPlan {
        var m = original
        var plan = TransferPlan(mon: m, native: target.isNativeTransfer(from: source))
        let data = PokeData.shared

        if original.isEgg {
            plan.blocked = "Eggs can't be moved between games. Hatch it first."
            return plan
        }
        if let problem = target.storeProblem(species: m.species, form: m.form) {
            plan.blocked = problem
            return plan
        }
        // Regional forms and other forms that are newer than the target game
        if m.form > 0, target.generation < 8, let form = data.forms[m.species]?[safe: m.form] {
            if TradeEvolution.generation(ofVersionGroup: form.since) > target.generation {
                plan.blocked = "\(m.speciesName) didn't exist yet in \(target.name)."
                return plan
            }
        }
        if target.generation <= 2 && m.form > 0 && m.species != 201 {
            plan.blocked = "\(target.name) only has the regular form of \(data.speciesName(m.species))."
            return plan
        }
        if !plan.native {
            plan.changes.append("This move isn't possible in the real games, so the Pokémon is rebuilt for \(target.name).")
        }

        // Level and experience stay; the growth curve caps it at level 100.
        m.exp = min(max(m.exp, data.exp(forLevel: m.level, species: m.species)), data.exp(forLevel: 100, species: m.species))

        // Ability by slot; hidden abilities don't exist before Gen 5, and Gen 3 only knows the first 76.
        if target.generation >= 3, let abilities = data.monData(species: m.species, form: m.form)?.abilities {
            var slot = m.abilitySlot
            if slot == 2 && target.generation < 5 {
                slot = 0
                plan.changes.append("Its hidden ability doesn't exist in \(target.name); it gets \(data.abilityName(abilities[0])) instead.")
            }
            var ability = abilities[min(slot, abilities.count - 1)]
            if target.generation == 3 && ability > 76 {
                ability = abilities[0] <= 76 ? abilities[0] : abilities[1]
                slot = ability == abilities[0] ? 0 : 1
            }
            if ability != m.ability && m.ability != 0 && slot == m.abilitySlot {
                plan.changes.append("Ability becomes \(data.abilityName(ability)) (how it works in \(target.name)).")
            }
            m.ability = ability
            m.abilitySlot = slot
        }

        // Gen 1/2 store DVs and stat experience instead of IVs/EVs.
        if target.generation <= 2 {
            if source.generation > 2 {
                var dvs = Mon.dvs(fromIVs: m.ivs)
                if m.isShiny { dvs = 0xAAAA }                            // the Gen 2 shiny pattern
                else if Mon.isShiny(dvs: dvs) { dvs ^= 0x0100 }          // don't turn it shiny by accident
                if m.species == 201 { dvs = unownDVs(form: m.form, base: dvs) }
                m.dvs = dvs
                m.statExp = m.evs.prefix(5).map { min(65535, $0 * 257) }
                plan.changes.append("IVs become Game Boy DVs (0–15 each); EVs become stat experience.")
            }
            m.heldItem = target.generation == 1 ? 0 : m.heldItem
            m.pid = 0
        } else if source.generation <= 2 {
            // Pokémon Bank's rules: IVs from DVs, shiny kept, nature from experience.
            let dv = m.dvs ?? 0
            m.ivs = Mon.ivs(fromDVs: dv)
            m.evs = [0, 0, 0, 0, 0, 0]
            m.nature = m.exp % 25
            m.gender = Mon.genderFromDVs(dv, species: m.species)
            m.pid = makePID(for: m, shiny: Mon.isShiny(dvs: dv), target: target)
            m.encryptionConstant = m.pid
            m.dvs = nil
            m.statExp = nil
            m.originGame = source
            plan.changes.append("Game Boy DVs become IVs and the Pokémon gets a personality value, like Pokémon Bank does.")
        } else if target.generation <= 5 {
            // Gen 3–5 derive nature, gender, ability and shininess from the personality value.
            if !pidFits(m, target: target) {
                m.pid = makePID(for: m, shiny: m.isShiny, target: target)
                plan.changes.append("It gets a new personality value so its nature, gender and shininess stay the same in \(target.name).")
            }
        } else if m.encryptionConstant == 0 {
            m.encryptionConstant = m.pid
        }

        // Moves
        var moves = m.moves
        var dropped: [String] = []
        for i in 0..<4 where moves[i] != 0 && !MoveSuggester.moveExists(moves[i], in: target) {
            dropped.append(data.moveName(moves[i]))
            moves[i] = 0
        }
        if !dropped.isEmpty {
            var probe = m
            probe.moves = moves
            let fill = MoveSuggester.latestLevelUp(for: probe, in: target).filter { $0 != 0 && !moves.contains($0) }
            var fillIterator = fill.makeIterator()
            for i in 0..<4 where moves[i] == 0 { moves[i] = fillIterator.next() ?? 0 }
            moves = moves.filter { $0 != 0 } + [Int](repeating: 0, count: 4)
            moves = Array(moves.prefix(4))
            plan.changes.append("\(dropped.joined(separator: ", ")) \(dropped.count == 1 ? "doesn't" : "don't") exist in \(target.name); replaced with moves it learns by level.")
        }
        if moves.allSatisfy({ $0 == 0 }) { moves = MoveSuggester.latestLevelUp(for: m, in: target) }
        if moves != m.moves {
            m.moves = moves
            m.ppUps = m.ppUps.enumerated().map { i, v in moves[i] == original.moves[safe: i] ? v : 0 }
        }
        m.relearnMoves = target.generation >= 6 ? m.relearnMoves.map { MoveSuggester.moveExists($0, in: target) ? $0 : 0 } : [0, 0, 0, 0]
        m.healPP()

        // Held item
        if m.heldItem > 0 && data.item(toGame: m.heldItem, generation: target.generation) == 0 {
            plan.changes.append("\(data.itemName(m.heldItem)) doesn't exist in \(target.name), so it's left behind.")
            m.heldItem = 0
        } else if m.heldItem > 0 && target.generation == 1 {
            plan.changes.append("Gen 1 Pokémon can't hold items; \(data.itemName(m.heldItem)) is left behind.")
            m.heldItem = 0
        }

        // Ball
        let maxBall = target.generation == 3 ? 12 : target.generation == 4 ? 24 : target.generation <= 6 ? 25 : target.generation == 7 ? 26 : 37
        if target.generation >= 3 && (m.ball > maxBall || m.ball == 0) {
            if m.ball != 0 { plan.changes.append("Its Poké Ball type doesn't exist in \(target.name); it's shown in a regular Poké Ball.") }
            m.ball = 4
        }

        // Effort values
        if target.family == .lgpe {
            if m.evs.contains(where: { $0 > 0 }) { plan.changes.append("Let's Go uses Awakening Values instead of EVs; EVs are reset.") }
            m.evs = [0, 0, 0, 0, 0, 0]
        } else if target.generation >= 6 && m.evs.contains(where: { $0 > 252 }) {
            m.evs = m.evs.map { min($0, 252) }
            plan.changes.append("EVs above 252 are capped at 252.")
        }
        let total = m.evs.reduce(0, +)
        if total > 510 {
            m.evs = m.evs.map { $0 * 510 / total }
            plan.changes.append("Total EVs are scaled down to 510.")
        }

        // Names: Gen 1–5 allow 10 characters, Gen 6+ 12.
        let maxName = target.generation <= 5 ? 10 : 12
        if m.isNicknamed && m.nickname.count > maxName {
            m.nickname = String(m.nickname.prefix(maxName))
            plan.changes.append("The nickname is shortened to \(maxName) characters.")
        }
        if target.generation <= 2 && m.otName.count > 7 { m.otName = String(m.otName.prefix(7)) }
        if target.generation == 3 && m.language > 7 { m.language = 2 }

        // Where it was met: keep it for native moves, otherwise mark it as received in a trade.
        if !plan.native || source.generation != target.generation {
            if let origin = m.originGame, origin.generation > target.generation || target.generation <= 2 { m.originGame = target }
            if m.originGame == nil { m.originGame = target }
            m.metLocation = tradeLocation(for: target)
            m.metLevel = target.generation <= 2 ? m.level : min(m.level, 100)
            if target.generation == 2 { m.caughtData = 0 }
            m.metDate = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        }

        // Stats are recalculated for the new game when written.
        if target.generation <= 2 { m.recalculateStatsGB() } else { m.recalculateStats() }
        m.sourceFamily = original.sourceFamily
        plan.mon = m
        return plan
    }

    /// "Link trade" style locations the games accept for received Pokémon.
    static func tradeLocation(for game: PKGame) -> Int {
        switch game.generation {
        case 1, 2: return 0
        case 3: return 254            // in-game trade
        case 4: return 2002           // link trade
        case 5: return 30003          // link trade
        default: return 30002         // link trade (Gen 6 onward)
        }
    }

    /// Does the current PID already give the same nature, gender, ability slot and shininess in Gen 3–5?
    static func pidFits(_ m: Mon, target: PKGame) -> Bool {
        guard m.pid != 0 else { return false }
        if Int(m.pid % 25) != m.nature { return false }
        let rate = PokeData.shared.info(m.species).genderRate
        if rate > 0 && rate < 8 && Mon.gender(pid: m.pid, species: m.species) != m.gender { return false }
        if (Mon.shinyValue(pid: m.pid, tid: m.tid, sid: m.sid) < 8) != m.isShiny { return false }
        if target.generation == 4 && m.abilitySlot < 2 && Int(m.pid & 1) != m.abilitySlot { return false }
        if m.species == 201 && PK3.unownForm(pid: m.pid) != m.form { return false }
        return true
    }

    /// Finds a personality value matching nature, gender, ability slot, shininess and Unown letter.
    static func makePID(for m: Mon, shiny: Bool, target: PKGame) -> UInt32 {
        var rng = SystemRandomNumberGenerator()
        let rate = PokeData.shared.info(m.species).genderRate
        for _ in 0..<5_000_000 {
            var pid = UInt32.random(in: .min ... .max, using: &rng)
            if shiny {
                // Make the high half so that the shiny value is below 8.
                let low = pid & 0xFFFF
                let high = (low ^ UInt32(m.tid) ^ UInt32(m.sid)) & 0xFFF8 | UInt32.random(in: 0..<8, using: &rng)
                pid = high << 16 | low
            }
            if Int(pid % 25) != m.nature { continue }
            if rate > 0 && rate < 8 && Mon.gender(pid: pid, species: m.species) != m.gender { continue }
            if !shiny && Mon.shinyValue(pid: pid, tid: m.tid, sid: m.sid) < 16 { continue }
            if target.generation == 4 && m.abilitySlot < 2 && Int(pid & 1) != m.abilitySlot { continue }
            if target.generation == 5 && m.abilitySlot < 2 && Int((pid >> 16) & 1) != m.abilitySlot { continue }
            if m.species == 201 && PK3.unownForm(pid: pid) != m.form { continue }
            return pid
        }
        return m.pid
    }

    /// Gen 2 Unown letters come from the DVs; nudge the DVs to keep the letter.
    static func unownDVs(form: Int, base: Int) -> Int {
        for dv in 0..<0x10000 {
            let candidate = (base & 0x9999) | (dv & 0x6666)
            let a = (candidate >> 12) & 0x6, b = (candidate >> 8) & 0x6, c = (candidate >> 4) & 0x6, e = candidate & 0x6
            if ((a << 5) | (b << 3) | (c << 1) | (e >> 1)) / 10 == form { return candidate }
        }
        return base
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { index >= 0 && index < count ? self[index] : nil }
}
