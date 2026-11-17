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
    @Published private(set) var refreshing = false
    @Published private(set) var cocoonUpdated: Date?
    weak var bridge: CocoonBridge?
    var serial: String?
    var cocoonRoot: String?

    private let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bifrost Link")
    private var sessionsFile: URL { folder.appendingPathComponent("sessions.json") }
    private var cocoonFile: URL { folder.appendingPathComponent("cocoon-playtime.json") }

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        sessions = (try? Data(contentsOf: sessionsFile)).flatMap { try? decoder.decode([PlaySession].self, from: $0) } ?? []
        cocoon = (try? Data(contentsOf: cocoonFile)).flatMap { try? decoder.decode([CocoonPlay].self, from: $0) } ?? []
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
        guard !result.isEmpty || cocoon.isEmpty else { return }
        cocoon = result
        cocoonUpdated = Date()
        save(result, to: cocoonFile)
        Log.write("play stats: \(result.count) games with play time from Cocoon")
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
        let cocoonFiles = Set(cocoon.map(\.file))
        for session in sessions {
            let key = session.file.isEmpty ? "app:" + session.package : "game:" + session.file
            if !session.file.isEmpty && cocoonFiles.contains(session.file) {
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
        return map.values.filter { $0.minutes >= 1 }.sorted { $0.minutes > $1.minutes }
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
        for session in sessions {
            let day = calendar.startOfDay(for: session.start)
            if buckets[day] != nil { buckets[day, default: 0] += session.minutes }
        }
        return buckets.map { (day: $0.key, minutes: $0.value) }.sorted { $0.day < $1.day }
    }

    var playedThisWeek: Int {
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        return Set(totals.filter { ($0.lastPlayed ?? .distantPast) > weekAgo }.map(\.key)).count
    }

    var longestSession: PlaySession? { sessions.max { $0.minutes < $1.minutes } }
}
