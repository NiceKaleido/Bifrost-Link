import Foundation

/// Works out which game a save belongs to and opens it with the right format.
enum SaveDetector {
    struct Hint {
        var fileName = ""
        var romCode: String?          // GB title / GBA, NDS, GC game code from the matching ROM header
        var titleID: String?          // 3DS or Switch title id from the save's folder
        var companions: [String] = [] // other files that must be written alongside (BDSP Backup.bin)
    }

    /// Guesses the version from the file name ("Pokemon - Sapphire Version (USA).sav").
    static func game(fromName name: String) -> PKGame? {
        let n = name.lowercased()
        let pairs: [(String, PKGame)] = [
            ("firered", .fireRed), ("fire red", .fireRed), ("leafgreen", .leafGreen), ("leaf green", .leafGreen),
            ("heartgold", .heartGold), ("heart gold", .heartGold), ("soulsilver", .soulSilver), ("soul silver", .soulSilver),
            ("black 2", .black2), ("black2", .black2), ("white 2", .white2), ("white2", .white2),
            ("omega ruby", .omegaRuby), ("alpha sapphire", .alphaSapphire), ("ultra sun", .ultraSun), ("ultra moon", .ultraMoon),
            ("brilliant diamond", .brilliantDiamond), ("shining pearl", .shiningPearl),
            ("crystal", .crystal), ("emerald", .emerald), ("platinum", .platinum), ("yellow", .yellow),
            ("ruby", .ruby), ("sapphire", .sapphire), ("diamond", .diamond), ("pearl", .pearl),
            ("gold", .gold), ("silver", .silver), ("black", .black), ("white", .white),
            ("red", .red), ("blue", .blue), ("green", .green), ("colosseum", .colosseum), ("gale of darkness", .xd),
            ("pokemon x", .x), ("pokémon x", .x), ("pokemon y", .y), ("pokémon y", .y), ("let's go, pikachu", .letsGoPikachu),
            ("let's go, eevee", .letsGoEevee), ("sword", .sword), ("shield", .shield), ("legends arceus", .legendsArceus),
            ("legends: arceus", .legendsArceus), ("scarlet", .scarlet), ("violet", .violet), ("legends z-a", .legendsZA), ("legends: z-a", .legendsZA),
        ]
        return pairs.first { n.contains($0.0) }?.1
    }

    /// Opens a save. Throws with a readable reason when the file isn't a supported Pokémon save.
    static func open(_ data: [UInt8], hint: Hint) throws -> SaveFile {
        let named = hint.romCode.flatMap(PKGame.from(romCode:)) ?? hint.titleID.flatMap { PKGame.from(switchTitle: $0) ?? PKGame.from(threeDSTitle: $0) }
            ?? game(fromName: hint.fileName)
        let size = data.count

        // Switch
        if let named, named.switchTitle != nil || hint.titleID != nil {
            switch named.family {
            case .bdsp: return try SaveBDSP(data: data, hint: named, companions: hint.companions)
            case .lgpe: return try SaveLGPE(data: data, hint: named)
            case .swsh, .pla, .sv, .za: return try SaveSwish(data: data, hint: named)
            default: break
            }
        }
        if SaveLGPE.looksValid(data) { return try SaveLGPE(data: data, hint: named) }
        if size > 0x100000 || (size > 0x40000 && SwishCrypto.isValid(data)) {
            if SwishCrypto.isValid(data) { return try SaveSwish(data: data, hint: named) }
        }
        if SaveBDSP.looksValid(data) && (named?.family == .bdsp || named == nil) {
            return try SaveBDSP(data: data, hint: named, companions: hint.companions)
        }
        // 3DS
        if Save3DS.detect(data) != nil { return try Save3DS(data: data, hint: named) }
        // GameCube
        if let gc = try GameCubeSaves.open(data, hint: named) { return gc }
        // DS (512 KB, some emulators add a footer)
        if size >= 0x80000 && size <= 0x80000 + 0x7A {
            let trimmed = Array(data.prefix(0x80000))
            if SaveGen5.detect(trimmed) != nil { return try SaveGen5(data: trimmed, hint: named) }
            if SaveGen4.detect(trimmed) != nil { return try SaveGen4(data: trimmed, hint: named) }
        }
        // GBA (128 KB, PokeDaisy adds a 16-byte RTC footer; romhacks are bigger structures)
        if size >= 0x20000 && size <= 0x20000 + 0x10 {
            guard SaveGen3.looksValid(Array(data.prefix(0x20000))) else {
                throw PKError.unsupported("This GBA save isn't a Pokémon game this app understands (or it's a romhack).")
            }
            return try SaveGen3Container(data: data, hint: named)
        }
        // GB/GBC (32 KB, plus RTC footers)
        if size >= 0x8000 && size <= 0x8000 + 0x30 {
            if SaveGen2.detect(data) != nil { return try SaveGen2(data: data, hint: named) }
            if SaveGen1.looksValid(data) { return try SaveGen1(data: data, hint: named) }
            if SaveGen1.looksJapanese(data) { throw PKError.unsupported("Japanese Gen 1 saves aren't supported yet.") }
            if Array(data.prefix(0x8000)).isAllFF || Array(data.prefix(0x8000)).isAllZero {
                throw PKError.unsupported("This save is empty; play the game and save once first.")
            }
        }
        if data.isAllFF || data.isAllZero { throw PKError.unsupported("This save is empty; play the game and save once first.") }
        throw PKError.unsupported("Not a Pokémon save this app understands.")
    }
}

/// Wraps a Gen 3 save that carries extra bytes after the 128 KB (PokeDaisy's RTC footer, romhacks).
final class SaveGen3Container: SaveFile {
    private let inner: SaveGen3
    private let tail: [UInt8]
    private let hackReason: String?

    init(data: [UInt8], hint: PKGame?) throws {
        inner = try SaveGen3(data: Array(data.prefix(0x20000)), hint: hint)
        tail = Array(data.dropFirst(0x20000))
        // Vanilla saves are exactly 128 KB. Romhacks (Unbound, CFRU …) come out bigger in PokeDaisy
        // and lay their Pokémon out differently, so they're shown but never written.
        hackReason = tail.isEmpty ? nil : "Romhack saves (like Unbound) can be looked at but not changed — their Pokémon are stored differently."
    }

    var game: PKGame { inner.game }
    var trainerName: String { inner.trainerName }
    var trainerID: Int { inner.trainerID }
    var secretID: Int { inner.secretID }
    var trainerGender: Int { inner.trainerGender }
    var boxCount: Int { inner.boxCount }
    var boxSize: Int { inner.boxSize }
    var readOnlyReason: String? { hackReason ?? inner.readOnlyReason }
    var isRomhack: Bool { hackReason != nil }
    func boxName(_ box: Int) -> String { inner.boxName(box) }
    func party() -> [Mon] { inner.party() }
    func mon(at slot: SlotRef) -> Mon? { inner.mon(at: slot) }
    func set(_ mon: Mon?, at slot: SlotRef) throws {
        if let hackReason { throw PKError.readOnly(hackReason) }
        try inner.set(mon, at: slot)
    }
    func registerDex(_ mon: Mon) { inner.registerDex(mon) }
    func serialize() throws -> [UInt8] { try inner.serialize() + tail }
    var checksumsValid: Bool { inner.checksumsValid }
    var integrityProblem: String? { inner.integrityProblem }
}
