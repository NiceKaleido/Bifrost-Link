import Foundation
import AppKit

/// Pokémon icons read from the ROMs on the device, cached as PNGs on this Mac.
/// Nothing is bundled with the app: no ROM, no icons.
///
/// At most one ROM per generation is read, once. Each species shows the icon from the newest
/// generation that has it.
@MainActor
final class IconCache: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var working: String?
    private var step_: (Int, Int) = (0, 0)
    /// Species that have an icon.
    var iconCount: Int { best.keys.filter { $0 < 10_000 }.count }
    /// True when every species already has an icon from the online sheet (no ROM reading needed).
    var hasOnlineIcons: Bool { cachedGenerations.contains(Self.onlineGeneration) }
    var serial: String?

    /// species (or Unown letter key) → icon from the newest generation available
    private var best: [Int: (generation: Int, image: NSImage)] = [:]
    private var cachedGenerations = Set<Int>()
    private var loaded = false

    nonisolated static let root: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bifrost Link/Pokemon/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() {
        Task { await loadCached() }
    }

    func image(species: Int, form: Int = 0, preferredGeneration: Int? = nil) -> NSImage? {
        if form > 0, let formIcon = best[Self.formKey(species, form)] { return formIcon.image }
        if species == 201 && form > 0, let unown = best[10_000 + 201 * 32 + form] { return unown.image }
        return best[species]?.image
    }

    nonisolated static func formKey(_ species: Int, _ form: Int) -> Int { 100_000 + species * 128 + form }

    // MARK: - Online icons (Pokémon Showdown's icon sheet)

    /// One sheet with every species and form (40×30 cells, 12 per row) plus an index of the forms.
    /// Downloaded once, then cut up locally. Icons © Nintendo / Game Freak; sheet by Pokémon Showdown.
    static let sheetURL = URL(string: "https://play.pokemonshowdown.com/sprites/pokemonicons-sheet.png")!
    static let indexURL = URL(string: "https://raw.githubusercontent.com/smogon/pokemon-showdown-client/24c266052dbe037322c8b84a2d99b0085839e3bd/play.pokemonshowdown.com/src/battle-dex-data.ts")!
    nonisolated static var onlineFolder: URL { root.appendingPathComponent("online", isDirectory: true) }
    static let onlineGeneration = 10   // newer than any ROM, so these win

    /// Loads the cached sheet, or downloads it the first time.
    func loadOnline() async {
        let folder = Self.onlineFolder
        let sheetFile = folder.appendingPathComponent("sheet.png"), indexFile = folder.appendingPathComponent("index.json")
        if !FileManager.default.fileExists(atPath: sheetFile.path) || !FileManager.default.fileExists(atPath: indexFile.path) {
            working = "Downloading Pokémon icons (only once)…"
            defer { working = nil }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let (sheet, sheetResponse) = try await URLSession.shared.data(from: Self.sheetURL)
                let (source, indexResponse) = try await URLSession.shared.data(from: Self.indexURL)
                guard (sheetResponse as? HTTPURLResponse)?.statusCode == 200, (indexResponse as? HTTPURLResponse)?.statusCode == 200 else { return }
                let index = Self.parseIndex(String(decoding: source, as: UTF8.self))
                guard !index.isEmpty, NSImage(data: sheet) != nil else { return }
                try sheet.write(to: sheetFile)
                try JSONSerialization.data(withJSONObject: index).write(to: indexFile)
            } catch {
                Log.write("pokemon icons: online download failed: \(error.localizedDescription)")
                return
            }
        }
        let images = await Task.detached(priority: .userInitiated) { Self.cutSheet(sheetFile: sheetFile, indexFile: indexFile) }.value
        guard !images.isEmpty else { return }
        merge(images, generation: Self.onlineGeneration)
        Log.write("pokemon icons: \(images.count) from the online sheet")
        revision += 1
    }

    /// `name: 1032 + 119,` → ["name": 1151]
    nonisolated static func parseIndex(_ source: String) -> [String: Int] {
        guard let start = source.range(of: "BattlePokemonIconIndexes:"), let end = source.range(of: "};", range: start.upperBound..<source.endIndex) else { return [:] }
        var index: [String: Int] = [:]
        let regex = try! NSRegularExpression(pattern: #"^\s*'?([a-z0-9]+)'?\s*:\s*(\d+)(?:\s*\+\s*(\d+))?"#, options: .anchorsMatchLines)
        let body = String(source[start.upperBound..<end.lowerBound])
        for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let name = Range(match.range(at: 1), in: body), let a = Range(match.range(at: 2), in: body) else { continue }
            var value = Int(body[a]) ?? 0
            if let b = Range(match.range(at: 3), in: body) { value += Int(body[b]) ?? 0 }
            index[String(body[name])] = value
        }
        return index
    }

    /// The Showdown id for a species form, e.g. (19, Alolan) → "rattataalola", Unown B → "unownb".
    nonisolated static func showdownID(species: Int, form: Int) -> String? {
        let data = PokeData.shared
        if species == 201 {
            let letter = data.formName(species: 201, form: form).lowercased()
            return letter == "!" ? "unownexclamation" : letter == "?" ? "unownquestion" : "unown" + letter
        }
        let pid = data.pokemonID(species: species, form: form)
        guard pid != species, let identifier = data.identifiers[pid] else { return nil }
        return identifier.filter { $0.isLetter || $0.isNumber }.lowercased()
    }

    nonisolated static func cutSheet(sheetFile: URL, indexFile: URL) -> [Int: NSImage] {
        guard let source = NSImage(contentsOf: sheetFile), let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let raw = try? Data(contentsOf: indexFile), let index = try? JSONSerialization.jsonObject(with: raw) as? [String: Int] else { return [:] }
        let scale = CGFloat(cg.width) / 480   // the sheet is 12 cells of 40 px wide
        func cell(_ slot: Int) -> NSImage? {
            let rect = CGRect(x: CGFloat(slot % 12) * 40 * scale, y: CGFloat(slot / 12) * 30 * scale, width: 40 * scale, height: 30 * scale)
            guard rect.maxY <= CGFloat(cg.height), let piece = cg.cropping(to: rect) else { return nil }
            return NSImage(cgImage: piece, size: NSSize(width: 40, height: 30))
        }
        var images: [Int: NSImage] = [:]
        let data = PokeData.shared
        for species in 1...min(1025, data.maxSpecies) {
            if let image = cell(species) { images[species] = image }
            for form in 1..<max(1, data.formCount(species)) {
                if let id = showdownID(species: species, form: form), let slot = index[id], let image = cell(slot) {
                    images[formKey(species, form)] = image
                }
            }
        }
        return images
    }

    var hasAnyIcons: Bool { !best.isEmpty }

    private func merge(_ images: [Int: NSImage], generation: Int) {
        for (key, image) in images where (best[key]?.generation ?? 0) <= generation {
            best[key] = (generation, image)
        }
        cachedGenerations.insert(generation)
    }

    /// Loads the PNGs cached by earlier runs, off the main thread.
    private func loadCached() async {
        let sets = await Task.detached(priority: .userInitiated) { () -> [(Int, [Int: NSImage])] in
            let fm = FileManager.default
            var out: [(Int, [Int: NSImage])] = []
            for dir in (try? fm.contentsOfDirectory(at: IconCache.root, includingPropertiesForKeys: nil)) ?? [] {
                guard dir.lastPathComponent != "online", let data = try? Data(contentsOf: dir.appendingPathComponent("set.json")),
                      let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
                      let generation = meta["generation"], (meta["count"] ?? 0) > 0 else { continue }
                var images: [Int: NSImage] = [:]
                for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "png" {
                    if let key = Int(file.deletingPathExtension().lastPathComponent), let image = NSImage(contentsOf: file) { images[key] = image }
                }
                out.append((generation, images))
            }
            return out
        }.value
        for (generation, images) in sets.sorted(by: { $0.0 < $1.0 }) { merge(images, generation: generation) }
        loaded = true
        revision += 1
        await loadOnline()
    }

    /// Newest game first within each generation (it has the most forms and the latest art).
    private static func preference(_ game: PKGame) -> Int {
        switch game {
        case .emerald: return 0
        case .fireRed, .leafGreen: return 1
        case .heartGold, .soulSilver: return 0
        case .platinum: return 1
        case .black2, .white2: return 0
        default: return 5
        }
    }

    /// Reads icons from one Pokémon ROM per generation that isn't cached yet. Gen 4 goes before
    /// Gen 5 so Black/White can borrow its palette table.
    func build(roms: [String]) async {
        guard let serial else { return }
        while !loaded { try? await Task.sleep(nanoseconds: 50_000_000) }
        if !hasOnlineIcons { await loadOnline() }
        // With the online sheet every species has an icon already; ROMs are only the offline fallback.
        guard !hasOnlineIcons else { return }
        var pick: [Int: (String, PKGame)] = [:]
        for rom in roms {
            guard !PokemonHub.isSpinOff((rom as NSString).lastPathComponent),
                  let game = SaveDetector.game(fromName: (rom as NSString).lastPathComponent),
                  [.gen3, .gen4, .gen5].contains(game.family), !cachedGenerations.contains(game.generation) else { continue }
            if let current = pick[game.generation], Self.preference(current.1) <= Self.preference(game) { continue }
            pick[game.generation] = (rom, game)
        }
        let order = pick.keys.sorted()
        for (step, generation) in order.enumerated() {
            guard let (rom, game) = pick[generation] else { continue }
            step_ = (step, order.count)
            if generation == 5 && NDSIcons.fallbackPalettes == nil { NDSIcons.fallbackPalettes = Self.storedPalettes() }
            working = "Reading Pokémon icons from \(game.title) (\(step + 1) of \(order.count), only once)…"
            let icons = await Self.extract(rom: rom, generation: generation, serial: serial)
            if generation == 4, let table = NDSIcons.lastFound { Self.storePalettes(table) }
            let images = await Task.detached(priority: .utility) { () -> [Int: NSImage] in
                let dir = IconCache.root.appendingPathComponent("gen\(generation)", isDirectory: true)
                try? FileManager.default.removeItem(at: dir)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var images: [Int: NSImage] = [:]
                for (key, icon) in icons {
                    if let png = icon.png { try? png.write(to: dir.appendingPathComponent("\(key).png")) }
                    images[key] = icon.image
                }
                let meta = try? JSONSerialization.data(withJSONObject: ["generation": generation, "count": icons.count])
                try? meta?.write(to: dir.appendingPathComponent("set.json"))
                return images
            }.value
            merge(images, generation: generation)
            Log.write("pokemon icons: \(icons.count) from \((rom as NSString).lastPathComponent)")
            revision += 1
        }
        working = nil
    }

    /// Pulls the ROM to a temporary folder, unzips it if needed, and reads the icons.
    private static func extract(rom: String, generation: Int, serial: String) async -> [Int: IconImage] {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("bifrost-rom-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let local = temp.appendingPathComponent((rom as NSString).lastPathComponent)
        guard (try? await ADB.shared.run(["pull", rom, local.path], serial: serial, timeout: 600))?.ok == true else { return [:] }
        return await Task.detached(priority: .utility) { () -> [Int: IconImage] in
            var romURL = local
            if local.pathExtension.lowercased() == "zip" {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-o", "-q", local.path, "-d", temp.appendingPathComponent("x").path]
                try? process.run()
                process.waitUntilExit()
                let extracted = (try? FileManager.default.contentsOfDirectory(at: temp.appendingPathComponent("x"), includingPropertiesForKeys: nil)) ?? []
                guard let found = extracted.first(where: { ["gba", "nds"].contains($0.pathExtension.lowercased()) }) else { return [:] }
                romURL = found
            }
            guard let data = try? Data(contentsOf: romURL) else { return [:] }
            let bytes = [UInt8](data)
            return generation == 3 ? GBAIcons.extract(bytes) : NDSIcons.extract(bytes)
        }.value
    }

    private static var paletteFile: URL { root.appendingPathComponent("palettes-gen4.json") }
    static func storePalettes(_ table: [Int]) {
        NDSIcons.fallbackPalettes = table
        try? JSONSerialization.data(withJSONObject: table).write(to: paletteFile)
    }
    static func storedPalettes() -> [Int]? {
        (try? Data(contentsOf: paletteFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Int] }
    }

    /// Deletes cached icons (they're rebuilt from the ROMs on the next scan).
    func clear() {
        try? FileManager.default.removeItem(at: Self.root)
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        best = [:]; cachedGenerations = []
        revision += 1
    }
}
