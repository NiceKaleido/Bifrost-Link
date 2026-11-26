import Foundation

/// How a game's save file is laid out. One `SaveFile` implementation per family.
enum SaveFamily: String, Codable {
    case gen1, gen2, gen3, colosseum, xd, box, gen4, gen5, gen6, gen7, lgpe, swsh, bdsp, pla, sv, za

    /// Entity format generation used for cross-game rules.
    var generation: Int {
        switch self {
        case .gen1: return 1
        case .gen2: return 2
        case .gen3, .colosseum, .xd, .box: return 3
        case .gen4: return 4
        case .gen5: return 5
        case .gen6: return 6
        case .gen7, .lgpe: return 7
        case .swsh, .bdsp, .pla: return 8
        case .sv, .za: return 9
        }
    }
}

/// Every mainline game from Red/Green to Legends: Z-A, with the identifiers needed to recognise
/// its ROM, its save and where it lives. The table covers games that aren't installed too.
enum PKGame: String, CaseIterable, Codable, Identifiable {
    case red, green, blue, yellow
    case gold, silver, crystal
    case ruby, sapphire, emerald, fireRed, leafGreen
    case colosseum, xd, box
    case diamond, pearl, platinum, heartGold, soulSilver
    case black, white, black2, white2
    case x, y, omegaRuby, alphaSapphire
    case sun, moon, ultraSun, ultraMoon
    case letsGoPikachu, letsGoEevee
    case sword, shield
    case brilliantDiamond, shiningPearl
    case legendsArceus
    case scarlet, violet
    case legendsZA

    var id: String { rawValue }

    var name: String {
        switch self {
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        case .gold: return "Gold"
        case .silver: return "Silver"
        case .crystal: return "Crystal"
        case .ruby: return "Ruby"
        case .sapphire: return "Sapphire"
        case .emerald: return "Emerald"
        case .fireRed: return "FireRed"
        case .leafGreen: return "LeafGreen"
        case .colosseum: return "Colosseum"
        case .xd: return "XD: Gale of Darkness"
        case .box: return "Box: Ruby & Sapphire"
        case .diamond: return "Diamond"
        case .pearl: return "Pearl"
        case .platinum: return "Platinum"
        case .heartGold: return "HeartGold"
        case .soulSilver: return "SoulSilver"
        case .black: return "Black"
        case .white: return "White"
        case .black2: return "Black 2"
        case .white2: return "White 2"
        case .x: return "X"
        case .y: return "Y"
        case .omegaRuby: return "Omega Ruby"
        case .alphaSapphire: return "Alpha Sapphire"
        case .sun: return "Sun"
        case .moon: return "Moon"
        case .ultraSun: return "Ultra Sun"
        case .ultraMoon: return "Ultra Moon"
        case .letsGoPikachu: return "Let's Go, Pikachu!"
        case .letsGoEevee: return "Let's Go, Eevee!"
        case .sword: return "Sword"
        case .shield: return "Shield"
        case .brilliantDiamond: return "Brilliant Diamond"
        case .shiningPearl: return "Shining Pearl"
        case .legendsArceus: return "Legends: Arceus"
        case .scarlet: return "Scarlet"
        case .violet: return "Violet"
        case .legendsZA: return "Legends: Z-A"
        }
    }

    var title: String { "Pokémon \(name)" }

    var family: SaveFamily {
        switch self {
        case .red, .green, .blue, .yellow: return .gen1
        case .gold, .silver, .crystal: return .gen2
        case .ruby, .sapphire, .emerald, .fireRed, .leafGreen: return .gen3
        case .colosseum: return .colosseum
        case .xd: return .xd
        case .box: return .box
        case .diamond, .pearl, .platinum, .heartGold, .soulSilver: return .gen4
        case .black, .white, .black2, .white2: return .gen5
        case .x, .y, .omegaRuby, .alphaSapphire: return .gen6
        case .sun, .moon, .ultraSun, .ultraMoon: return .gen7
        case .letsGoPikachu, .letsGoEevee: return .lgpe
        case .sword, .shield: return .swsh
        case .brilliantDiamond, .shiningPearl: return .bdsp
        case .legendsArceus: return .pla
        case .scarlet, .violet: return .sv
        case .legendsZA: return .za
        }
    }

    var generation: Int {
        switch self {
        case .letsGoPikachu, .letsGoEevee: return 7
        case .brilliantDiamond, .shiningPearl, .legendsArceus, .sword, .shield: return 8
        default: return family.generation
        }
    }

    /// PokeAPI version group (learnsets, dexes). DLC groups are merged into the base game by the generator.
    var versionGroup: Int {
        switch self {
        case .red, .green, .blue: return 1
        case .yellow: return 2
        case .gold, .silver: return 3
        case .crystal: return 4
        case .ruby, .sapphire, .box: return 5
        case .emerald: return 6
        case .fireRed, .leafGreen: return 7
        case .diamond, .pearl: return 8
        case .platinum: return 9
        case .heartGold, .soulSilver: return 10
        case .black, .white: return 11
        case .colosseum: return 12
        case .xd: return 13
        case .black2, .white2: return 14
        case .x, .y: return 15
        case .omegaRuby, .alphaSapphire: return 16
        case .sun, .moon: return 17
        case .ultraSun, .ultraMoon: return 18
        case .letsGoPikachu, .letsGoEevee: return 19
        case .sword, .shield: return 20
        case .brilliantDiamond, .shiningPearl: return 23
        case .legendsArceus: return 24
        case .scarlet, .violet: return 25
        case .legendsZA: return 30
        }
    }

    /// PokeAPI version id (internal species index tables for Gen 1–3).
    var pokeAPIVersion: Int {
        switch self {
        case .red: return 1
        case .green: return 45
        case .blue: return 2
        case .yellow: return 3
        case .gold: return 4
        case .silver: return 5
        case .crystal: return 6
        case .ruby, .box: return 7
        case .sapphire: return 8
        case .emerald: return 9
        case .fireRed: return 10
        case .leafGreen: return 11
        case .colosseum: return 19
        case .xd: return 20
        default: return 0
        }
    }

    /// The game's own "origin version" number, stored on every Pokémon from Gen 3 on.
    var originVersion: Int {
        switch self {
        case .sapphire: return 1
        case .ruby: return 2
        case .emerald: return 3
        case .fireRed: return 4
        case .leafGreen: return 5
        case .colosseum, .xd, .box: return 15
        case .heartGold: return 7
        case .soulSilver: return 8
        case .diamond: return 10
        case .pearl: return 11
        case .platinum: return 12
        case .white: return 20
        case .black: return 21
        case .white2: return 22
        case .black2: return 23
        case .x: return 24
        case .y: return 25
        case .alphaSapphire: return 26
        case .omegaRuby: return 27
        case .sun: return 30
        case .moon: return 31
        case .ultraSun: return 32
        case .ultraMoon: return 33
        case .red: return 35
        case .green: return 36
        case .blue: return 37
        case .yellow: return 38
        case .gold: return 39
        case .silver: return 40
        case .crystal: return 41
        case .letsGoPikachu: return 42
        case .letsGoEevee: return 43
        case .sword: return 44
        case .shield: return 45
        case .legendsArceus: return 47
        case .brilliantDiamond: return 48
        case .shiningPearl: return 49
        case .scarlet: return 50
        case .violet: return 51
        case .legendsZA: return 52
        }
    }

    static func from(originVersion: Int) -> PKGame? {
        allCases.first { $0.originVersion == originVersion && $0 != .xd && $0 != .box }
    }

    /// Cartridge game codes (GBA/NDS header) or title strings (GB header at 0x134), any region.
    var romCodes: [String] {
        switch self {
        case .red: return ["POKEMON RED"]
        case .green: return ["POKEMON GREEN"]
        case .blue: return ["POKEMON BLUE"]
        case .yellow: return ["POKEMON YELLOW"]
        case .gold: return ["POKEMON_GLD"]
        case .silver: return ["POKEMON_SLV"]
        case .crystal: return ["PM_CRYSTAL"]
        case .ruby: return ["AXV"]
        case .sapphire: return ["AXP"]
        case .emerald: return ["BPE"]
        case .fireRed: return ["BPR"]
        case .leafGreen: return ["BPG"]
        case .colosseum: return ["GC6"]
        case .xd: return ["GXX"]
        case .box: return ["GPX"]
        case .diamond: return ["ADA"]
        case .pearl: return ["APA"]
        case .platinum: return ["CPU"]
        case .heartGold: return ["IPK"]
        case .soulSilver: return ["IPG"]
        case .black: return ["IRB"]
        case .white: return ["IRA"]
        case .black2: return ["IRE"]
        case .white2: return ["IRD"]
        default: return []
        }
    }

    /// 3DS title id (low 32 bits, as Azahar names the save folder).
    var threeDSTitle: String? {
        switch self {
        case .x: return "00055d00"
        case .y: return "00055e00"
        case .omegaRuby: return "0011c400"
        case .alphaSapphire: return "0011c500"
        case .sun: return "00164800"
        case .moon: return "00175e00"
        case .ultraSun: return "001b5000"
        case .ultraMoon: return "001b5100"
        default: return nil
        }
    }

    /// Switch title id (Peanuts Native names the save folder after it).
    var switchTitle: String? {
        switch self {
        case .letsGoPikachu: return "010003F003A34000"
        case .letsGoEevee: return "0100187003A36000"
        case .sword: return "0100ABF008968000"
        case .shield: return "01008DB008C2C000"
        case .brilliantDiamond: return "0100000011D90000"
        case .shiningPearl: return "010018E011D92000"
        case .legendsArceus: return "01001F5010DFA000"
        case .scarlet: return "0100A3D008C5C000"
        case .violet: return "01008F6008C5E000"
        case .legendsZA: return "0100F43008C44000"
        default: return nil
        }
    }

    static func from(romCode code: String) -> PKGame? {
        let upper = code.uppercased()
        return allCases.first { game in game.romCodes.contains { upper.hasPrefix($0) } }
    }

    static func from(threeDSTitle id: String) -> PKGame? {
        let lower = id.lowercased()
        return allCases.first { $0.threeDSTitle.map { lower.hasSuffix($0) } ?? false }
    }

    static func from(switchTitle id: String) -> PKGame? {
        allCases.first { $0.switchTitle?.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// Highest national dex number the game's data knows about.
    var maxSpecies: Int {
        switch generation {
        case 1: return 151
        case 2: return 251
        case 3: return 386
        case 4: return 493
        case 5: return 649
        case 6: return 721
        case 7: return family == .lgpe ? 809 : 807
        case 8: return family == .bdsp ? 493 : (family == .pla ? 905 : 898)
        default: return family == .za ? 1025 : 1025
        }
    }

    /// Highest move id in the game.
    var maxMove: Int {
        switch self.family {
        case .gen1: return 165
        case .gen2: return 251
        case .gen3, .colosseum, .xd, .box: return 354
        case .gen4: return 467
        case .gen5: return 559
        case .gen6: return family == .gen6 && (self == .omegaRuby || self == .alphaSapphire) ? 621 : 617
        case .gen7: return (self == .ultraSun || self == .ultraMoon) ? 728 : 719
        case .lgpe: return 742
        case .swsh: return 826
        case .bdsp: return 826
        case .pla: return 850
        case .sv: return 919
        case .za: return 919
        }
    }

    /// Species (and form) that can live in this game's boxes. Switch games use their own
    /// "present in game" flags; older games hold every species up to their generation.
    func canStore(species: Int, form: Int = 0) -> Bool {
        guard species > 0, species <= maxSpecies else { return false }
        switch family {
        case .gen1, .gen2, .gen3, .gen4, .gen5, .gen6, .gen7, .box, .colosseum, .xd:
            return true
        default:
            let data = PokeData.shared
            if let table = data.present[versionGroup] {
                guard let forms = table[species] else { return false }
                return forms.contains(form) || (form == 0 && !forms.isEmpty)
            }
            if family == .lgpe { return species <= 151 || species == 808 || species == 809 }
            if family == .bdsp { return species <= 493 }
            return data.dex[versionGroup]?.contains(species) == true
        }
    }

    /// Why a species can't go into this game, in plain words (nil when it can).
    func storeProblem(species: Int, form: Int = 0) -> String? {
        let name = PokeData.shared.speciesName(species)
        if species > maxSpecies { return "\(name) didn't exist yet in \(self.name)." }
        guard !canStore(species: species, form: form) else { return nil }
        if PokeData.shared.present[versionGroup]?[species] != nil {
            let formName = PokeData.shared.formName(species: species, form: form)
            return "\(self.name) doesn't have \(formName.isEmpty ? "this form of \(name)" : formName)."
        }
        return "\(name) isn't in \(self.name)."
    }

    /// Package names of the Android apps that run this game, used for "close the game first" checks.
    var playerPackages: [String] {
        switch family {
        case .gen1, .gen2, .gen3: return ["com.pokedaisy.app", "com.retroarch"]
        case .gen4, .gen5: return ["com.pokedaisy.app", "me.magnum.melondualds", "com.retroarch"]
        case .colosseum, .xd, .box: return ["org.dolphinemu.dolphinemu"]
        case .gen6, .gen7: return ["io.github.lime3ds.android"]
        default: return [Emulators.peanuts]
        }
    }

    /// True when a Pokémon from `source` could reach this game the way the real games allow
    /// (Poké Transfer, Pokémon Bank, Pokémon HOME). Everything else is a "rebuilt" transfer.
    func isNativeTransfer(from source: PKGame) -> Bool {
        if source == self { return true }
        let s = source.generation, t = generation
        // Gen 1 ↔ Gen 2 time capsule
        if s <= 2 && t <= 2 { return true }
        // VC Gen 1/2 → Bank → Gen 7, then HOME onwards
        if s <= 2 { return t >= 7 && family != .lgpe }
        // Gen 3 → Pal Park → Gen 4 → Poké Transfer → Gen 5 → Bank → Gen 6/7 → HOME → Switch
        if [.colosseum, .xd, .box].contains(source.family) && family == .gen3 { return true }
        if family == .gen3 && [.colosseum, .xd, .box].contains(source.family) { return true }
        if source.family == .gen3 && [.colosseum, .xd, .box].contains(family) { return true }
        if s == 6 && t == 6 { return true }
        if s == 7 && t == 7 { return source.family == family }
        if source.family == .lgpe { return t >= 8 }
        if family == .lgpe { return false }
        if s >= 8 && t >= 8 { return true }       // HOME moves between every Switch game
        return t > s
    }
}
