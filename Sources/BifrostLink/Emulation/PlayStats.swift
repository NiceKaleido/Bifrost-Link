import Foundation
import AppKit

struct PlaySession: Codable, Identifiable, Hashable {
    var id = UUID()
    let title: String
    let system: String
    let package: String
    let file: String
    let start: Date
    let end: Date
    var minutes: Double { end.timeIntervalSince(start) / 60 }
}

struct CocoonPlay: Codable, Identifiable, Hashable {
    let system: String
    let name: String
    let file: String
    let minutes: Int
    let playcount: Int
    let lastPlayed: Date?
    var id: String { system + "/" + file }
}

struct AppPlay: Codable, Hashable {
    let package: String
    let name: String
    let minutes: Double
    let lastPlayed: Date?
}

struct GameTotal: Identifiable, Hashable {
    let key: String
    let title: String
    let system: String
    let file: String
    let minutes: Double
    let lastPlayed: Date?
    var id: String { key }
}

@MainActor
final class PlayStats: ObservableObject {
    @Published private(set) var sessions: [PlaySession] = []
    @Published private(set) var cocoon: [CocoonPlay] = []
    /// Android games Cocoon knows about, with foreground time from Android's usage stats, keyed by yearly stats period.
    @Published private(set) var appPeriods: [String: [String: AppPlay]] = [:]
    /// Per-game time from RetroArch's own runtime logs (covers games started in RetroArch without Cocoon).
    @Published private(set) var retro: [RetroPlay] = []
    @Published private(set) var refreshing = false
    /// Names the user gave games in Play Time, keyed by GameTotal.key (Cocoon's own renames live in its private database).
    @Published private(set) var customNames: [String: String] = UserDefaults.standard.dictionary(forKey: "playTitleOverrides") as? [String: String] ?? [:]
    @Published private(set) var cocoonUpdated: Date?
    weak var bridge: CocoonBridge?
    var serial: String?
    var cocoonRoot: String?
    /// Apps that run other games: their time is counted per game (Cocoon's Windows/Steam entries), never as the app itself.
    static let gameLaunchers: Set<String> = ["app.gamenative"]
    var names: ((String) -> String?)?
    var isGame: ((String) -> Bool)?

    private let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bifrost Link")
    private var sessionsFile: URL { folder.appendingPathComponent("sessions.json") }
    private var cocoonFile: URL { folder.appendingPathComponent("cocoon-playtime.json") }
    private var appsFile: URL { folder.appendingPathComponent("app-playtime.json") }
    private var retroFile: URL { folder.appendingPathComponent("retroarch-playtime.json") }
    private var labelsFile: URL { folder.appendingPathComponent("app-labels.json") }
    private lazy var labels: [String: String] = (try? Data(contentsOf: labelsFile)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        sessions = (try? Data(contentsOf: sessionsFile)).flatMap { try? decoder.decode([PlaySession].self, from: $0) } ?? []
        cocoon = (try? Data(contentsOf: cocoonFile)).flatMap { try? decoder.decode([CocoonPlay].self, from: $0) } ?? []
        appPeriods = (try? Data(contentsOf: appsFile)).flatMap { try? decoder.decode([String: [String: AppPlay]].self, from: $0) } ?? [:]
        retro = (try? Data(contentsOf: retroFile)).flatMap { try? decoder.decode([RetroPlay].self, from: $0) } ?? []
        cocoonUpdated = (try? cocoonFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? encoder.encode(value) { try? data.write(to: url, options: .atomic) }
    }

    func record(_ playing: NowPlaying, ended: Date) {
        guard ended.timeIntervalSince(playing.started) >= 60 else { return }
        sessions.append(PlaySession(title: playing.title, system: playing.system, package: playing.package, file: playing.file, start: playing.started, end: ended))
        save(sessions, to: sessionsFile)
    }

    func refreshCocoon() async {
        guard let serial, let root = cocoonRoot, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let list = (try? await ADB.shared.shell("ls -1 \(ADB.quote(root + "/gamelists")) 2>/dev/null", serial: serial, timeout: 10)) ?? ""
        var result: [CocoonPlay] = []
        for system in list.split(separator: "\n").map({ String($0).trimmingCharacters(in: .whitespaces) }) where !system.isEmpty {
            let path = root + "/gamelists/" + system + "/gamelist.xml"
            guard let xml = try? await ADB.shared.shell("cat \(ADB.quote(path)) 2>/dev/null", serial: serial, timeout: 30), xml.contains("<gameList") else { continue }
            for entry in GamelistParser.parse(xml) where entry.playtime > 0 || entry.playcount > 0 {
                result.append(CocoonPlay(system: system, name: entry.name.isEmpty ? (entry.path as NSString).lastPathComponent : entry.name,
                                         file: (entry.path as NSString).lastPathComponent, minutes: entry.playtime,
                                         playcount: entry.playcount, lastPlayed: Self.date(entry.lastPlayed)))
            }
        }
        await refreshApps(serial: serial, root: root)
        await refreshRetroArch(serial: serial)
        guard !result.isEmpty || cocoon.isEmpty else { return }
        cocoon = result
        cocoonUpdated = Date()
        save(result, to: cocoonFile)
        Log.write("play stats: \(result.count) games with play time from Cocoon")
    }

    private func refreshRetroArch(serial: String) async {
        guard let result = await RetroArchData.runtimes(serial: serial) else { return }
        retro = result
        save(result, to: retroFile)
        relabelRetroArchSessions()
        Log.write("play stats: \(result.count) games with play time from RetroArch")
    }

    /// Docked sessions recorded as just "RetroArch" (game started inside RetroArch) get the game whose
    /// RetroArch runtime log was last written during that session.
    private func relabelRetroArchSessions() {
        var changed = false
        sessions = sessions.map { session in
            guard session.package == RetroArchData.package, session.file.isEmpty,
                  let match = retro.filter({ play in
                      guard let last = play.lastPlayed else { return false }
                      return last >= session.start.addingTimeInterval(-120) && last <= session.end.addingTimeInterval(120)
                  }).min(by: { abs($0.lastPlayed!.timeIntervalSince(session.end)) < abs($1.lastPlayed!.timeIntervalSince(session.end)) }) else { return session }
            changed = true
            let file = gameFile(for: match)
            return PlaySession(id: session.id, title: title(for: match), system: file.system, package: session.package, file: file.file, start: session.start, end: session.end)
        }
        if changed { save(sessions, to: sessionsFile) }
    }

    /// The Cocoon entry a RetroArch log belongs to (same ROM name), else what RetroArch's history says.
    private func gameFile(for play: RetroPlay) -> (file: String, system: String) {
        if let entry = cocoon.first(where: { ($0.file as NSString).deletingPathExtension == play.stem }) { return (entry.file, entry.system) }
        return (play.file ?? play.stem, play.system ?? "retroarch")
    }

    private func title(for play: RetroPlay) -> String {
        cocoon.first(where: { ($0.file as NSString).deletingPathExtension == play.stem })?.name ?? RetroArchData.cleanTitle(play.stem)
    }

    /// Cocoon keeps Android-game play time in its private database, so use Android's own
    /// usage stats for the apps Cocoon lists as games (the ones with artwork under android_app).
    private func refreshApps(serial: String, root: String) async {
        let media = (try? await ADB.shared.shell("ls -1 \(ADB.quote(root + "/downloaded_media/android_app"))/* 2>/dev/null", serial: serial, timeout: 10)) ?? ""
        let installed = (try? await ADB.shared.shell("pm list packages", serial: serial, timeout: 15)) ?? ""
        var byStem: [String: String] = [:]
        for line in installed.split(separator: "\n") where line.hasPrefix("package:") {
            let package = line.dropFirst("package:".count).trimmingCharacters(in: .whitespaces)
            byStem[package.replacingOccurrences(of: ".", with: "_")] = package
        }
        var games = Set<String>()
        for line in media.split(separator: "\n") {
            var stem = (String(line).trimmingCharacters(in: .whitespaces) as NSString).deletingPathExtension
            if let r = stem.range(of: "__cocoon_edit") { stem = String(stem[..<r.lowerBound]) }
            if let package = byStem[stem], !Self.gameLaunchers.contains(package), isGame?(package) ?? true { games.insert(package) }
        }
        guard !games.isEmpty, let dump = try? await ADB.shared.shell("dumpsys usagestats", serial: serial, timeout: 30),
              let (period, usage) = Self.parseYearlyUsage(dump) else { return }
        var entries: [String: AppPlay] = [:]
        for (package, value) in usage where games.contains(package) && value.minutes >= 1 {
            if labels[package] == nil, let label = await Self.label(of: package, serial: serial) {
                labels[package] = label
                save(labels, to: labelsFile)
            }
            entries[package] = AppPlay(package: package, name: labels[package] ?? names?(package) ?? EmulatorUpdater.knownNames[package] ?? EmulatorUpdater.prettyName(package),
                                       minutes: value.minutes, lastPlayed: value.last)
        }
        appPeriods[period] = entries
        save(appPeriods, to: appsFile)
        Log.write("play stats: \(entries.count) Android games with play time from usage stats")
    }

    /// Reads the app's display name by pulling just its manifest and resource table (APKs can be gigabytes) and asking aapt2.
    private static func label(of package: String, serial: String) async -> String? {
        guard let aapt = EmulatorUpdater.aapt else { return nil }
        let remote = "/data/local/tmp/bifrost-label"
        let extract = "rm -rf \(remote) && mkdir -p \(remote) && unzip -o -q \"$(pm path \(ADB.quote(package)) | head -1 | cut -d: -f2)\" AndroidManifest.xml resources.arsc -d \(remote)"
        _ = try? await ADB.shared.shell(extract, serial: serial, timeout: 30)
        defer { Task { _ = try? await ADB.shared.shell("rm -rf \(remote)", serial: serial, timeout: 10) } }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("bifrost-label-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: local) }
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        for name in ["AndroidManifest.xml", "resources.arsc"] {
            _ = try? await ADB.shared.run(["pull", remote + "/" + name, local.appendingPathComponent(name).path], serial: serial, timeout: 30)
        }
        let apk = local.appendingPathComponent("label.apk")
        _ = await EmulatorUpdater.run("/usr/bin/zip", ["-q", "-0", "-j", apk.path, local.appendingPathComponent("AndroidManifest.xml").path, local.appendingPathComponent("resources.arsc").path])
        let badging = await EmulatorUpdater.run(aapt, ["dump", "badging", apk.path])
        guard let line = badging.split(separator: "\n").first(where: { $0.hasPrefix("application-label:") }) else { return nil }
        let label = line.dropFirst("application-label:".count).trimmingCharacters(in: CharacterSet(charactersIn: "' "))
        return label.isEmpty ? nil : label
    }

    static func parseYearlyUsage(_ dump: String) -> (period: String, usage: [String: (minutes: Double, last: Date?)])? {
        let lines = dump.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains("In-memory yearly stats") }) else { return nil }
        var period = ""
        var usage: [String: (minutes: Double, last: Date?)] = [:]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for line in lines[(start + 1)...] {
            if line.contains("In-memory ") || line.contains("stats files:") { break }
            if period.isEmpty, let value = attribute("timeRange", in: line) {
                period = value.components(separatedBy: " – ").first?.trimmingCharacters(in: .whitespaces) ?? value
            }
            guard let package = line.range(of: "package=").map({ String(line[$0.upperBound...].prefix { $0 != " " }) }),
                  let used = attribute("totalTimeUsed", in: line) else { continue }
            usage[package] = (duration(used) / 60, attribute("lastTimeUsed", in: line).flatMap { f.date(from: $0) })
        }
        return period.isEmpty ? nil : (period, usage)
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let r = line.range(of: name + "=\"") else { return nil }
        return String(line[r.upperBound...].prefix { $0 != "\"" })
    }

    /// Parses Android's elapsed-time strings such as "17:18:43", "05:12" or "1d 2:03:04" into seconds.
    static func duration(_ text: String) -> Double {
        var seconds = 0.0
        var clock = text
        if let d = text.range(of: "d ") {
            seconds += (Double(text[..<d.lowerBound].trimmingCharacters(in: .whitespaces)) ?? 0) * 86400
            clock = String(text[d.upperBound...])
        }
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        return seconds + parts.reduce(0) { $0 * 60 + $1 }
    }

    /// Each Android game's time summed over every yearly period seen, so totals survive the yearly rollover.
    var appTotals: [String: AppPlay] {
        var result: [String: AppPlay] = [:]
        for entries in appPeriods.values {
            for (package, play) in entries {
                let previous = result[package]
                result[package] = AppPlay(package: package, name: play.name, minutes: (previous?.minutes ?? 0) + play.minutes,
                                          lastPlayed: max(previous?.lastPlayed ?? .distantPast, play.lastPlayed ?? .distantPast))
            }
        }
        return result
    }

    private static func date(_ value: String) -> Date? {
        guard value.count >= 15 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.date(from: String(value.prefix(15)))
    }

    var totals: [GameTotal] {
        var map: [String: GameTotal] = [:]
        for game in cocoon {
            map["game:" + game.file] = GameTotal(key: "game:" + game.file, title: game.name, system: game.system, file: game.file, minutes: Double(game.minutes), lastPlayed: game.lastPlayed)
        }
        // RetroArch counts every session (also ones started without Cocoon); Cocoon only its own launches.
        // Both include Cocoon-launched RetroArch time, so take the larger, never the sum.
        var covered = Set(cocoon.map(\.file))
        for play in retro {
            let target = gameFile(for: play)
            let key = "game:" + target.file
            covered.insert(target.file)
            if let existing = map[key] {
                guard play.minutes > existing.minutes else { continue }
                map[key] = GameTotal(key: key, title: existing.title, system: existing.system, file: existing.file, minutes: play.minutes,
                                     lastPlayed: max(existing.lastPlayed ?? .distantPast, play.lastPlayed ?? .distantPast))
            } else {
                map[key] = GameTotal(key: key, title: title(for: play), system: target.system, file: target.file, minutes: play.minutes, lastPlayed: play.lastPlayed)
            }
        }
        let apps = appTotals
        for app in apps.values {
            map["app:" + app.package] = GameTotal(key: "app:" + app.package, title: app.name, system: "", file: "", minutes: app.minutes, lastPlayed: app.lastPlayed)
        }
        for session in sessions {
            let key = Self.key(for: session)
            // An emulator in front without a known game isn't a game of its own.
            if session.file.isEmpty && !(isGame?(session.package) ?? true) { continue }
            if session.file.isEmpty ? apps[session.package] != nil : covered.contains(session.file) {
                if let existing = map[key], (existing.lastPlayed ?? .distantPast) < session.end {
                    map[key] = GameTotal(key: key, title: existing.title, system: existing.system, file: existing.file, minutes: existing.minutes, lastPlayed: session.end)
                }
                continue
            }
            let previous = map[key]
            map[key] = GameTotal(key: key, title: previous?.title ?? session.title, system: session.system, file: session.file,
                                 minutes: (previous?.minutes ?? 0) + session.minutes,
                                 lastPlayed: max(previous?.lastPlayed ?? .distantPast, session.end))
        }
        return map.values.filter { $0.minutes >= 1 && ignored[$0.key] == nil }.map { total in
            guard let name = customNames[total.key] else { return total }
            return GameTotal(key: total.key, title: name, system: total.system, file: total.file, minutes: total.minutes, lastPlayed: total.lastPlayed)
        }.sorted { $0.minutes > $1.minutes }
    }

    /// Games and apps the user chose not to count, keyed by GameTotal.key, with the title they had when ignored.
    @Published private(set) var ignored: [String: String] = UserDefaults.standard.dictionary(forKey: "playIgnored") as? [String: String] ?? [:]

    func setIgnored(key: String, title: String, _ value: Bool) {
        ignored[key] = value ? title : nil
        UserDefaults.standard.set(ignored, forKey: "playIgnored")
    }

    func restore(_ key: String) {
        ignored[key] = nil
        UserDefaults.standard.set(ignored, forKey: "playIgnored")
    }

    static func key(for session: PlaySession) -> String { session.file.isEmpty ? "app:" + session.package : "game:" + session.file }

    /// How Play Time names an Android app: the user's rename, else the app's real label.
    /// The app's own name, read from its APK once and remembered.
    func label(for package: String) async -> String? {
        if let name = displayName(package: package) { return name }
        guard let serial, let label = await Self.label(of: package, serial: serial) else { return nil }
        labels[package] = label
        save(labels, to: labelsFile)
        return label
    }

    func displayName(package: String) -> String? {
        customNames["app:" + package] ?? labels[package]
    }

    func rename(_ key: String, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        customNames[key] = trimmed.isEmpty ? nil : trimmed
        UserDefaults.standard.set(customNames, forKey: "playTitleOverrides")
    }

    var totalMinutes: Double { totals.reduce(0) { $0 + $1.minutes } }

    var bySystem: [(system: String, minutes: Double)] {
        Dictionary(grouping: totals, by: \.system).map { (system: $0.key, minutes: $0.value.reduce(0) { $0 + $1.minutes }) }.sorted { $0.minutes > $1.minutes }
    }

    func daily(days: Int = 30) -> [(day: Date, minutes: Double)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var buckets: [Date: Double] = [:]
        for offset in 0..<days {
            if let day = calendar.date(byAdding: .day, value: -offset, to: today) { buckets[day] = 0 }
        }
        for session in sessions where ignored[Self.key(for: session)] == nil {
            let day = calendar.startOfDay(for: session.start)
            if buckets[day] != nil { buckets[day, default: 0] += session.minutes }
        }
        return buckets.map { (day: $0.key, minutes: $0.value) }.sorted { $0.day < $1.day }
    }

    var playedThisWeek: Int {
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        return Set(totals.filter { ($0.lastPlayed ?? .distantPast) > weekAgo }.map(\.key)).count
    }

    var longestSession: PlaySession? { sessions.filter { ignored[Self.key(for: $0)] == nil }.max { $0.minutes < $1.minutes } }
}
