import Foundation
import AppKit

/// RetroAchievements: your profile, games, achievements and recent unlocks, from the official web API
/// (https://retroachievements.org, documented at api-docs.retroachievements.org). Read-only.
@MainActor
final class AchievementsHub: ObservableObject {
    struct Profile: Equatable {
        var user = ""
        var picture = ""
        var points = 0
        var softcorePoints = 0
        var truePoints = 0
        var richPresence = ""
        var memberSince = ""
    }

    struct GameProgress: Identifiable, Equatable {
        let id: Int
        let title: String
        let console: String
        let consoleID: Int
        let icon: String
        let total: Int
        let earned: Int
        let earnedHardcore: Int
        let lastUnlock: Date?
        let award: String?          // "mastered", "completed", "beaten-hardcore", "beaten-softcore"
        var fraction: Double { total == 0 ? 0 : Double(max(earned, earnedHardcore)) / Double(total) }
        var awardLabel: String? {
            switch award {
            case "mastered": return "Mastered"
            case "completed": return "Completed"
            case "beaten-hardcore": return "Beaten (hardcore)"
            case "beaten-softcore": return "Beaten"
            default: return nil
            }
        }
    }

    struct Achievement: Identifiable, Equatable {
        let id: Int
        let title: String
        let description: String
        let points: Int
        let badge: String
        let order: Int
        let earned: Date?
        let earnedHardcore: Date?
        var isEarned: Bool { earned != nil || earnedHardcore != nil }
    }

    struct GameDetail: Equatable {
        let id: Int
        let title: String
        let console: String
        let icon: String
        let achievements: [Achievement]
    }

    struct Unlock: Identifiable, Equatable {
        var id: String { "\(achievement)-\(date.timeIntervalSince1970)" }
        let achievement: Int
        let title: String
        let description: String
        let badge: String
        let points: Int
        let hardcore: Bool
        let date: Date
        let gameID: Int
        let gameTitle: String
    }

    @Published private(set) var username: String?
    @Published private(set) var profile: Profile?
    @Published private(set) var games: [GameProgress] = []
    @Published private(set) var recent: [Unlock] = []
    @Published private(set) var details: [Int: GameDetail] = [:]
    @Published private(set) var loading = false
    @Published private(set) var problem: String?
    @Published private(set) var updated: Date?
    @Published private(set) var imageRevision = 0
    /// RA game ids of games that have a ROM on the device (matched by title).
    @Published private(set) var onDevice: Set<Int> = []

    var serial: String?
    private var images: [String: NSImage] = [:]
    private var loadingImages = Set<String>()
    private var lastRequest = Date.distantPast

    static let site = URL(string: "https://retroachievements.org")!
    static let media = "https://media.retroachievements.org"

    static let folder: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bifrost Link/achievements", isDirectory: true)
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("img"), withIntermediateDirectories: true)
        return url
    }()

    init() {
        username = Keychain.get("username")
        loadCache()
    }

    var isSignedIn: Bool { username != nil && Keychain.get("apiKey") != nil }

    func reset(serial: String?) {
        self.serial = serial
        if serial == nil { onDevice = [] }
    }

    // MARK: - Signing in

    /// Checks the key with a profile request and keeps both in the Keychain.
    func signIn(user: String, apiKey: String) async -> Bool {
        let user = user.trimmingCharacters(in: .whitespaces), key = apiKey.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, !key.isEmpty else { problem = "Enter your username and web API key."; return false }
        do {
            let json = try await request("API_GetUserProfile", ["u": user], key: key)
            guard let dict = json as? [String: Any], dict["User"] != nil else {
                problem = "RetroAchievements didn't accept that username and key."
                return false
            }
            Keychain.set(user, for: "username")
            Keychain.set(key, for: "apiKey")
            username = user
            problem = nil
            profile = Self.profile(from: dict)
            await refresh(force: true)
            return true
        } catch {
            problem = "RetroAchievements didn't accept that username and key."
            return false
        }
    }

    func signOut() {
        for account in ["username", "apiKey", "token"] { Keychain.delete(account) }
        username = nil
        profile = nil
        games = []
        recent = []
        details = [:]
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("cache.json"))
    }

    // MARK: - Loading

    func refresh(force: Bool = false) async {
        guard let user = username, !loading else { return }
        if !force, let updated, Date().timeIntervalSince(updated) < 15 * 60 { return }
        loading = true
        defer { loading = false }
        do {
            if let dict = try await request("API_GetUserProfile", ["u": user]) as? [String: Any] { profile = Self.profile(from: dict) }
            // The avatar keeps the same address when it changes, so it's fetched again on every refresh.
            if force, let picture = profile?.picture, !picture.isEmpty { forgetImage(picture) }
            var all: [GameProgress] = []
            var offset = 0
            while true {
                guard let page = try await request("API_GetUserCompletionProgress", ["u": user, "c": "500", "o": String(offset)]) as? [String: Any],
                      let results = page["Results"] as? [[String: Any]] else { break }
                all += results.compactMap(Self.progress(from:))
                let total = Self.int(page["Total"])
                offset += results.count
                if results.isEmpty || offset >= total { break }
            }
            games = all.sorted { ($0.lastUnlock ?? .distantPast) > ($1.lastUnlock ?? .distantPast) }
            if let list = try await request("API_GetUserRecentAchievements", ["u": user, "m": "43200"]) as? [[String: Any]] {
                recent = list.compactMap(Self.unlock(from:)).sorted { $0.date > $1.date }
            }
            updated = Date()
            problem = nil
            saveCache()
            Log.write("achievements: \(games.count) game(s), \(recent.count) recent unlock(s)")
        } catch {
            problem = "Couldn't reach RetroAchievements: \(error.localizedDescription)"
        }
    }

    func loadDetail(_ gameID: Int, force: Bool = false) async {
        guard let user = username else { return }
        if !force, details[gameID] != nil { return }
        do {
            guard let dict = try await request("API_GetGameInfoAndUserProgress", ["u": user, "g": String(gameID)]) as? [String: Any] else { return }
            let list = (dict["Achievements"] as? [String: [String: Any]])?.values.compactMap(Self.achievement(from:)) ?? []
            details[gameID] = GameDetail(id: gameID, title: dict["Title"] as? String ?? "", console: dict["ConsoleName"] as? String ?? "",
                                         icon: dict["ImageIcon"] as? String ?? "",
                                         achievements: list.sorted { ($0.isEarned ? 0 : 1, $0.order, $0.id) < ($1.isEarned ? 0 : 1, $1.order, $1.id) })
        } catch {
            problem = "Couldn't load that game's achievements: \(error.localizedDescription)"
        }
    }

    // MARK: - Matching games on the device

    /// RetroAchievements console ids for the Roms folder names.
    static let consoles: [String: Int] = [
        "megadrive": 1, "genesis": 1, "md": 1, "n64": 2, "snes": 3, "sfc": 3, "gb": 4, "gba": 5, "gbc": 6, "nes": 7, "fc": 7, "famicom": 7,
        "pcengine": 8, "tg16": 8, "segacd": 9, "megacd": 9, "sega32x": 10, "32x": 10, "mastersystem": 11, "sms": 11, "psx": 12, "ps1": 12,
        "lynx": 13, "ngp": 14, "ngpc": 14, "gamegear": 15, "gg": 15, "gc": 16, "gamecube": 16, "nds": 18, "ps2": 21, "pokemini": 24,
        "atari2600": 25, "arcade": 27, "virtualboy": 28, "msx": 29, "atari7800": 51, "wonderswan": 53, "wsc": 53, "saturn": 39,
        "dreamcast": 40, "dc": 40, "psp": 41, "3do": 43, "colecovision": 44, "intellivision": 45, "vectrex": 46, "atari5200": 50,
    ]

    /// Matches the ROMs on the device to RetroAchievements games by title (per console, cached for a week).
    func matchDevice() async {
        guard let serial, isSignedIn else { return }
        let library = await LeftoverScanner.Library.load(serial: serial)
        var titlesBySystem: [Int: Set<String>] = [:]
        for entry in library.files {
            guard let console = Self.consoles[entry.system] else { continue }
            titlesBySystem[console, default: []].insert(PortCatalog.normalizedTitle((entry.path as NSString).lastPathComponent))
        }
        var matched = Set<Int>()
        for (console, titles) in titlesBySystem {
            guard let list = await gameList(console) else { continue }
            for (id, title) in list where titles.contains(title) { matched.insert(id) }
        }
        onDevice = matched
    }

    private func gameList(_ console: Int) async -> [(Int, String)]? {
        let file = Self.folder.appendingPathComponent("games-\(console).json")
        let fresh = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) < 7 * 86400 } ?? false
        var list: [[String: Any]]?
        if fresh, let data = try? Data(contentsOf: file) { list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] }
        if list == nil, let fetched = try? await request("API_GetGameList", ["i": String(console), "f": "1"]) as? [[String: Any]] {
            list = fetched
            if let data = try? JSONSerialization.data(withJSONObject: fetched) { try? data.write(to: file) }
        }
        return list?.map { (Self.int($0["ID"]), PortCatalog.normalizedTitle($0["Title"] as? String ?? "")) }
    }

    // MARK: - Images

    /// A badge or icon, downloaded once and kept on this Mac.
    func image(_ path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let cached = images[path] { return cached }
        let file = Self.folder.appendingPathComponent("img").appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
        if let image = NSImage(contentsOf: file) { images[path] = image; return image }
        guard !loadingImages.contains(path), let url = URL(string: path.hasPrefix("http") ? path : Self.media + path) else { return nil }
        loadingImages.insert(path)
        Task {
            defer { loadingImages.remove(path) }
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data) else { return }
            try? data.write(to: file)
            images[path] = image
            imageRevision += 1
        }
        return nil
    }

    /// Drops a cached image so the next look-up downloads it again.
    func forgetImage(_ path: String) {
        images[path] = nil
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("img").appendingPathComponent(path.replacingOccurrences(of: "/", with: "_")))
        imageRevision += 1
    }

    nonisolated static func badgePath(_ badge: String, locked: Bool) -> String { "/Badge/\(badge)\(locked ? "_lock" : "").png" }

    // MARK: - Web API

    enum APIError: LocalizedError {
        case notSignedIn, http(Int)
        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Not signed in to RetroAchievements."
            case .http(let code): return code == 401 || code == 403 ? "RetroAchievements rejected the key." : "RetroAchievements answered with error \(code)."
            }
        }
    }

    /// One request at a time, at most a few per second (the API asks clients to be gentle).
    private func request(_ name: String, _ parameters: [String: String], key: String? = nil) async throws -> Any {
        guard let key = key ?? Keychain.get("apiKey") else { throw APIError.notSignedIn }
        let wait = 0.35 - Date().timeIntervalSince(lastRequest)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        lastRequest = Date()
        var components = URLComponents(url: Self.site.appendingPathComponent("API/\(name).php"), resolvingAgainstBaseURL: false)!
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "y", value: key)]
        var request = URLRequest(url: components.url!)
        request.setValue("BifrostLink", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw APIError.http(status) }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Parsing (the API mixes numbers and strings, so values are read loosely)

    nonisolated static func int(_ any: Any?) -> Int {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) ?? Int(Double(s) ?? 0) }
        return 0
    }

    nonisolated static func date(_ any: Any?) -> Date? {
        guard let s = any as? String, !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    nonisolated static func profile(from d: [String: Any]) -> Profile {
        Profile(user: d["User"] as? String ?? "", picture: d["UserPic"] as? String ?? "", points: int(d["TotalPoints"]),
                softcorePoints: int(d["TotalSoftcorePoints"]), truePoints: int(d["TotalTruePoints"]),
                richPresence: d["RichPresenceMsg"] as? String ?? "", memberSince: d["MemberSince"] as? String ?? "")
    }

    nonisolated static func progress(from d: [String: Any]) -> GameProgress? {
        let id = int(d["GameID"])
        guard id > 0 else { return nil }
        return GameProgress(id: id, title: d["Title"] as? String ?? "", console: d["ConsoleName"] as? String ?? "", consoleID: int(d["ConsoleID"]),
                            icon: d["ImageIcon"] as? String ?? "", total: int(d["MaxPossible"]), earned: int(d["NumAwarded"]),
                            earnedHardcore: int(d["NumAwardedHardcore"]), lastUnlock: date(d["MostRecentAwardedDate"]),
                            award: d["HighestAwardKind"] as? String)
    }

    nonisolated static func achievement(from d: [String: Any]) -> Achievement? {
        let id = int(d["ID"])
        guard id > 0 else { return nil }
        return Achievement(id: id, title: d["Title"] as? String ?? "", description: d["Description"] as? String ?? "", points: int(d["Points"]),
                           badge: d["BadgeName"] as? String ?? "", order: int(d["DisplayOrder"]),
                           earned: date(d["DateEarned"]), earnedHardcore: date(d["DateEarnedHardcore"]))
    }

    nonisolated static func unlock(from d: [String: Any]) -> Unlock? {
        guard let date = date(d["Date"]) else { return nil }
        return Unlock(achievement: int(d["AchievementID"]), title: d["Title"] as? String ?? "", description: d["Description"] as? String ?? "",
                      badge: d["BadgeName"] as? String ?? "", points: int(d["Points"]), hardcore: int(d["HardcoreMode"]) == 1,
                      date: date, gameID: int(d["GameID"]), gameTitle: d["GameTitle"] as? String ?? "")
    }

    // MARK: - Cache (so the tab shows something right away)

    private func saveCache() {
        let payload: [String: Any] = [
            "updated": updated?.timeIntervalSince1970 ?? 0,
            "profile": ["User": profile?.user ?? "", "UserPic": profile?.picture ?? "", "TotalPoints": profile?.points ?? 0,
                        "TotalSoftcorePoints": profile?.softcorePoints ?? 0, "TotalTruePoints": profile?.truePoints ?? 0,
                        "RichPresenceMsg": profile?.richPresence ?? "", "MemberSince": profile?.memberSince ?? ""],
            "games": games.map { ["GameID": $0.id, "Title": $0.title, "ConsoleName": $0.console, "ConsoleID": $0.consoleID, "ImageIcon": $0.icon,
                                  "MaxPossible": $0.total, "NumAwarded": $0.earned, "NumAwardedHardcore": $0.earnedHardcore,
                                  "MostRecentAwardedDate": $0.lastUnlock.map(Self.cacheDate) ?? "", "HighestAwardKind": $0.award ?? ""] },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) { try? data.write(to: Self.folder.appendingPathComponent("cache.json")) }
    }

    private static func cacheDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    private func loadCache() {
        guard username != nil, let data = try? Data(contentsOf: Self.folder.appendingPathComponent("cache.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let p = json["profile"] as? [String: Any] { profile = Self.profile(from: p) }
        games = ((json["games"] as? [[String: Any]]) ?? []).compactMap(Self.progress(from:))
        let stamp = (json["updated"] as? NSNumber)?.doubleValue ?? 0
        updated = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }
}
