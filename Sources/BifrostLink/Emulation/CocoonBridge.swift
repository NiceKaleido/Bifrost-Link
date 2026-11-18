import Foundation
import AppKit

struct NowPlaying: Equatable {
    let title: String
    let file: String
    let system: String
    let package: String
    let player: String
    var icon: NSImage?
    let started: Date

    static func == (a: NowPlaying, b: NowPlaying) -> Bool {
        a.file == b.file && a.package == b.package && (a.icon == nil) == (b.icon == nil)
    }

    var isApp: Bool { system.isEmpty }

    var safeName: String {
        title.replacingOccurrences(of: #"[/:\\?%*|"<>]"#, with: "-", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}

@MainActor
final class CocoonBridge: ObservableObject {
    static let package = "rip.moth.cocoonshell"
    static let homePackages: Set<String> = [package, "com.android.launcher3", "com.odin.odinlauncher", "com.android.settings", "com.android.systemui"]

    @Published private(set) var detected = false
    @Published private(set) var nowPlaying: NowPlaying? {
        didSet {
            guard !resolvingGame, let old = oldValue, old.file != nowPlaying?.file || old.package != nowPlaying?.package else { return }
            let ended = Date()
            Log.write("session ended: \(old.title) after \(Int(ended.timeIntervalSince(old.started) / 60)) min")
            onSessionEnded?(old, ended)
        }
    }
    var onSessionEnded: ((NowPlaying, Date) -> Void)?
    /// Set while an emulator session gets its game filled in, so that isn't treated as a new session.
    private var resolvingGame = false
    private var serial: String?
    private var root: String?
    private var task: Task<Void, Never>?
    private var lastTop: String?
    private let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/BifrostLink/media")

    func start(serial: String, cocoonRoot: String?) {
        stop()
        self.serial = serial
        root = cocoonRoot
        detected = cocoonRoot != nil
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                await self?.resolveRetroArch()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        nowPlaying = nil
        lastTop = nil
        detected = false
    }

    private var lastFeed = Date.distantPast

    func feed(_ listing: String) {
        lastFeed = Date()
        Task { await process(listing) }
    }

    private func poll() async {
        guard let serial, Date().timeIntervalSince(lastFeed) > 6 else { return }
        guard let listing = try? await ADB.shared.shell("cmd activity stack list", serial: serial, timeout: 5) else { return }
        await process(listing)
    }

    private func process(_ listing: String) async {
        guard let serial else { return }
        let visible = AudioRouter.visiblePackages(listing)
        let ordered = (visible[0] ?? []) + visible.keys.sorted().filter { $0 != 0 }.flatMap { visible[$0] ?? [] }
        guard let first = ordered.first else { return }
        let top = ordered.first { !Self.homePackages.contains($0) } ?? first
        guard top != lastTop else { return }
        lastTop = top

        if Self.homePackages.contains(top) {
            nowPlaying = nil
            return
        }

        guard let root,
              let tail = try? await ADB.shared.shell("tail -n 60 \(ADB.quote(root + "/launch_debug.log"))", serial: serial, timeout: 5),
              let launch = Self.lastLaunch(tail), launch.package == top || (launch.package.isEmpty && Self.matches(player: launch.player, package: top)) else {
            let name = EmulatorUpdater.knownNames[top] ?? EmulatorUpdater.prettyName(top)
            nowPlaying = NowPlaying(title: name, file: "", system: "", package: top, player: name, icon: nil, started: Date())
            Log.write("app in front: \(top)")
            return
        }
        var playing = NowPlaying(title: launch.title, file: launch.file, system: launch.system, package: top, player: launch.player, icon: nil, started: Date())
        nowPlaying = playing
        Log.write("session started: \(launch.title) (\(launch.system), \(launch.player))")
        if let icon = await loadIcon(system: launch.system, file: launch.file, serial: serial, root: root) {
            playing.icon = icon
            if nowPlaying?.file == playing.file { nowPlaying = playing }
        }
    }

    /// A game started inside RetroArch (not from Cocoon) shows up as just RetroArch; its history says which game it is.
    private func resolveRetroArch() async {
        guard let serial, let playing = nowPlaying, playing.package == RetroArchData.package, playing.file.isEmpty,
              let path = await RetroArchData.currentGame(serial: serial, since: playing.started),
              nowPlaying?.package == RetroArchData.package, nowPlaying?.file.isEmpty == true else { return }
        let file = (path as NSString).lastPathComponent
        let system = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        var game = NowPlaying(title: RetroArchData.cleanTitle((file as NSString).deletingPathExtension), file: file, system: system,
                              package: playing.package, player: playing.player, icon: nil, started: playing.started)
        resolvingGame = true
        nowPlaying = game
        resolvingGame = false
        Log.write("session started: \(game.title) (\(system), RetroArch, opened without Cocoon)")
        if let root, let icon = await loadIcon(system: system, file: file, serial: serial, root: root), nowPlaying?.file == file {
            game.icon = icon
            nowPlaying = game
        }
    }

    static func matches(player: String, package: String) -> Bool {
        let word = player.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init) ?? ""
        return word.count >= 3 && package.lowercased().contains(word)
    }

    struct Launch {
        let title: String
        let file: String
        let system: String
        let package: String
        let player: String
    }

    static func lastLaunch(_ log: String) -> Launch? {
        let lines = log.split(separator: "\n").map(String.init)
        guard let start = lines.lastIndex(where: { $0.contains("══ Launch: ") }) else { return nil }
        var title = "", file = "", path = "", package = "", player = ""
        if let r = lines[start].range(of: "Launch: ") {
            title = String(lines[start][r.upperBound...]).replacingOccurrences(of: "═", with: "").trimmingCharacters(in: .whitespaces)
        }
        for line in lines[start...] {
            if let r = line.range(of: "| File: ") { file = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
            if let r = line.range(of: "Player: ") {
                let value = String(line[r.upperBound...])
                if let m = value.range(of: #"\(([A-Za-z0-9_.]+)(/[^()]*)?\)\s*$"#, options: .regularExpression) {
                    let inner = String(value[m].dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: ") \t"))
                    package = inner.components(separatedBy: "/").first ?? ""
                    player = String(value[..<m.lowerBound]).trimmingCharacters(in: .whitespaces)
                } else {
                    player = value
                }
            }
            if package.isEmpty, let r = line.range(of: "component=ComponentInfo{") {
                package = String(line[r.upperBound...].prefix { $0 != "/" })
            }
            if let r = line.range(of: "Resolved file: ") {
                path = String(line[r.upperBound...]).components(separatedBy: " (exists").first ?? ""
            }
        }
        let system = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard !title.isEmpty else { return nil }
        return Launch(title: title, file: file.isEmpty ? (path as NSString).lastPathComponent : file, system: system, package: package, player: player)
    }

    func icon(system: String, file: String) async -> NSImage? {
        guard let serial, let root else { return nil }
        return await loadIcon(system: system, file: file, serial: serial, root: root)
    }

    func cachedIcon(system: String, file: String) -> NSImage? {
        NSImage(contentsOf: cache.appendingPathComponent(system).appendingPathComponent((file as NSString).deletingPathExtension + ".png"))
    }

    private func loadIcon(system: String, file: String, serial: String, root: String) async -> NSImage? {
        let base = (file as NSString).deletingPathExtension
        let local = cache.appendingPathComponent(system).appendingPathComponent(base + ".png")
        if let image = NSImage(contentsOf: local) { return image }
        for kind in ["icon", "logo"] {
            let dir = root + "/downloaded_media/" + system + "/" + kind
            let match = ((try? await ADB.shared.shell("ls -1 \(ADB.quote(dir)) 2>/dev/null | grep -F \(ADB.quote(base)) | head -1", serial: serial, timeout: 5)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !match.isEmpty else { continue }
            try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            let result = try? await ADB.shared.run(["pull", dir + "/" + match, local.path], serial: serial, timeout: 15)
            if result?.ok == true, let image = NSImage(contentsOf: local) { return image }
        }
        return nil
    }
}

struct LayoutProfile: Codable, Equatable {
    var layout: String
    var swapped: Bool
    var overlayX: Double
    var overlayY: Double
    var overlayScale: Double
    var cinema: Bool
    var perScreenAudio: Bool

    @MainActor
    init(settings: LinkSettings) {
        layout = settings.layout.rawValue
        swapped = settings.swapped
        overlayX = settings.overlayX
        overlayY = settings.overlayY
        overlayScale = settings.overlayScale
        cinema = settings.cinemaMode
        perScreenAudio = settings.perScreenAudio
    }

    @MainActor
    func apply(to settings: LinkSettings) {
        if let value = ScreenLayout(rawValue: layout), settings.layout != value { settings.layout = value }
        if settings.swapped != swapped { settings.swapped = swapped }
        settings.overlayX = overlayX
        settings.overlayY = overlayY
        settings.overlayScale = overlayScale
        if settings.cinemaMode != cinema { settings.cinemaMode = cinema }
        if settings.perScreenAudio != perScreenAudio { settings.perScreenAudio = perScreenAudio }
    }
}

enum LayoutProfiles {
    private static let key = "layoutProfiles"

    static func gameKey(_ playing: NowPlaying) -> String { playing.isApp ? "app:" + playing.package : "game:" + playing.file }
    static func systemKey(_ system: String) -> String { "system:" + system }

    static func all() -> [String: LayoutProfile] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: LayoutProfile].self, from: data)) ?? [:]
    }

    static func get(_ id: String) -> LayoutProfile? { all()[id] }

    static func set(_ profile: LayoutProfile?, for id: String) {
        var current = all()
        current[id] = profile
        UserDefaults.standard.set(try? JSONEncoder().encode(current), forKey: key)
    }

    static func suggestion(for system: String) -> ScreenLayout? {
        switch system {
        case "nds", "n3ds": return .stacked
        case "switch", "ps2", "gc", "wii", "xbox", "psp", "n64", "psx", "dreamcast": return .topOnly
        default: return nil
        }
    }
}
