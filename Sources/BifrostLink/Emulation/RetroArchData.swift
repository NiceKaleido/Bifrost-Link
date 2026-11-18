import Foundation

/// Per-game play time RetroArch records itself (content runtime logs), plus its recent-content history.
struct RetroPlay: Codable, Hashable {
    let stem: String
    let core: String
    let minutes: Double
    let lastPlayed: Date?
    /// Full ROM path from RetroArch's history, when the game is in it (gives the system folder).
    let path: String?

    var file: String? { path.map { ($0 as NSString).lastPathComponent } }
    var system: String? { path.map { (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent } }
}

@MainActor
enum RetroArchData {
    static let package = "com.retroarch"
    private static var playlistDirs: [String: String] = [:]

    /// RetroArch's playlist folder, read from its config (cached per device).
    static func playlistDir(serial: String) async -> String {
        if let cached = playlistDirs[serial] { return cached }
        let cfg = (try? await ADB.shared.shell("grep -h '^playlist_directory' /sdcard/Android/data/com.retroarch/files/retroarch.cfg /sdcard/RetroArch/retroarch.cfg 2>/dev/null | head -1", serial: serial, timeout: 5)) ?? ""
        let value = cfg.components(separatedBy: "=").dropFirst().joined(separator: "=").trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r"))
        let dir = value.isEmpty || value == "default" ? "/storage/emulated/0/Android/data/com.retroarch/files/RetroArch/playlists" : value
        playlistDirs[serial] = dir
        return dir
    }

    /// Paths in RetroArch's recent-content history, newest first.
    static func historyPaths(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { $0["path"] as? String }.filter { !$0.isEmpty }
    }

    /// The game RetroArch most recently loaded, if it was loaded at or after `since`.
    static func currentGame(serial: String, since: Date) async -> String? {
        let dir = await playlistDir(serial: serial)
        let history = dir + "/builtin/content_history.lpl"
        guard let out = try? await ADB.shared.shell("stat -c %Y \(ADB.quote(history)) 2>/dev/null; cat \(ADB.quote(history)) 2>/dev/null", serial: serial, timeout: 8) else { return nil }
        let lines = out.split(separator: "\n", maxSplits: 1).map(String.init)
        guard lines.count == 2, let stamp = Double(lines[0].trimmingCharacters(in: .whitespaces)),
              Date(timeIntervalSince1970: stamp) >= since.addingTimeInterval(-5) else { return nil }
        return historyPaths(lines[1]).first
    }

    /// Every runtime log RetroArch wrote, matched to history paths where possible.
    static func runtimes(serial: String) async -> [RetroPlay]? {
        let dir = await playlistDir(serial: serial)
        let script = "cd \(ADB.quote(dir + "/logs")) 2>/dev/null && for f in */*.lrtl; do [ -f \"$f\" ] && echo \"@@$f\" && cat \"$f\" && echo; done; echo '@@history'; cat \(ADB.quote(dir + "/builtin/content_history.lpl")) 2>/dev/null"
        guard let out = try? await ADB.shared.shell(script, serial: serial, timeout: 20), out.contains("@@history") else { return nil }
        let parts = out.components(separatedBy: "@@history")
        let byStem = Dictionary(historyPaths(parts.last ?? "").map { (((($0 as NSString).lastPathComponent) as NSString).deletingPathExtension, $0) }, uniquingKeysWith: { first, _ in first })
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var result: [RetroPlay] = []
        for block in (parts.first ?? "").components(separatedBy: "@@").dropFirst() {
            let lines = block.split(separator: "\n", maxSplits: 1).map(String.init)
            guard lines.count == 2, let data = lines[1].data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let runtime = json["runtime"] as? String else { continue }
            let name = lines[0].trimmingCharacters(in: .whitespaces)
            let core = (name as NSString).deletingLastPathComponent
            let stem = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
            let minutes = PlayStats.duration(runtime) / 60
            guard minutes > 0 else { continue }
            result.append(RetroPlay(stem: stem, core: core, minutes: minutes, lastPlayed: (json["last_played"] as? String).flatMap { f.date(from: $0) }, path: byStem[stem]))
        }
        return result
    }

    /// "Super Mario 64 (U) [!]" → "Super Mario 64"
    static func cleanTitle(_ stem: String) -> String {
        let cleaned = stem.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? stem : cleaned
    }
}
