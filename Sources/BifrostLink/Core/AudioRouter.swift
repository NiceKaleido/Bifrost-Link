import Foundation

@MainActor
final class AudioRouter {
    private let serial: String
    private let output: AudioOutput
    private let topDisplay: Int
    private let bottomDisplay: Int?
    private var perScreen: Bool
    private var playOnDevice: Bool
    private var running: [AudioChannel: (session: ServerSession, stream: AudioStream?, key: String)] = [:]
    private var pending: [AudioChannel: (session: ServerSession, key: String)] = [:]
    private var uidCache: [String: Int] = [:]
    private var pollTask: Task<Void, Never>?
    private var physicalOutputs: Set<Int> = []
    private var lastTopUids: Set<Int> = []
    private var lastBottomUids: Set<Int> = []
    private var physicalCheckedAt = Date.distantPast
    private var lastReroute: [AudioChannel: Date] = [:]
    private(set) var apps: [AudioChannel: [String]] = [:]
    var onAppsChanged: (([AudioChannel: [String]]) -> Void)?
    var onListing: ((String) -> Void)?

    init(serial: String, output: AudioOutput, topDisplay: Int, bottomDisplay: Int?, perScreen: Bool, playOnDevice: Bool) {
        self.serial = serial
        self.output = output
        self.topDisplay = topDisplay
        self.bottomDisplay = bottomDisplay
        self.perScreen = perScreen
        self.playOnDevice = playOnDevice
    }

    func start() {
        output.start()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        for (channel, entry) in running {
            retire(entry)
            output.flush(channel)
        }
        running.removeAll()
        pending.values.forEach { $0.session.stop() }
        pending.removeAll()
        output.stop()
    }

    func reconfigure(perScreen: Bool, playOnDevice: Bool) {
        guard perScreen != self.perScreen || playOnDevice != self.playOnDevice else { return }
        self.perScreen = perScreen
        self.playOnDevice = playOnDevice
        for (channel, entry) in running {
            retire(entry)
            output.flush(channel)
        }
        running.removeAll()
        pending.values.forEach { $0.session.stop() }
        pending.removeAll()
        Task { await refresh() }
    }

    private func refresh() async {
        guard perScreen else {
            apply([.background: ([], false)])
            await enforceRouting()
            return
        }
        let marker = "__BIFROST_PLAYERS__"
        let command = playOnDevice ? "cmd activity stack list" : "cmd activity stack list; echo \(marker); dumpsys audio | grep 'AudioPlaybackConfiguration.*state:started'"
        guard let output = try? await ADB.shared.shell(command, serial: serial, timeout: 5) else { return }
        let sections = output.components(separatedBy: marker)
        let listing = sections[0]
        let players = sections.count > 1 ? sections[1] : nil
        onListing?(listing)
        let visible = Self.visiblePackages(listing)
        let topPackages = visible[topDisplay] ?? []
        let bottomPackages = bottomDisplay.map { visible[$0] ?? [] } ?? []
        let needed = Set(topPackages + bottomPackages)
        if !needed.isSubset(of: uidCache.keys) {
            await loadUids()
        }
        let topUids = Set(topPackages.compactMap { uidCache[$0] }).filter { $0 >= 10000 }
        let bottomUids = Set(bottomPackages.compactMap { uidCache[$0] }).filter { $0 >= 10000 }.subtracting(topUids)
        let union = topUids.union(bottomUids)
        lastTopUids = topUids
        lastBottomUids = bottomUids

        let newApps: [AudioChannel: [String]] = [.top: topPackages, .bottom: bottomPackages.filter { uidCache[$0].map(bottomUids.contains) ?? false }]
        if newApps != apps {
            apps = newApps
            onAppsChanged?(newApps)
        }

        var plan: [AudioChannel: ([Int], Bool)] = [:]
        if !topUids.isEmpty { plan[.top] = (topUids.sorted(), false) }
        if !bottomUids.isEmpty { plan[.bottom] = (bottomUids.sorted(), false) }
        plan[.background] = (union.sorted(), true)
        apply(plan)
        await enforceRouting(players: players, top: topUids, bottom: bottomUids)
    }

    private func enforceRouting(players known: String? = nil, top: Set<Int> = [], bottom: Set<Int> = []) async {
        guard !playOnDevice else { return }
        var fetched = known
        if fetched == nil { fetched = try? await ADB.shared.shell("dumpsys audio | grep 'AudioPlaybackConfiguration.*state:started'", serial: serial, timeout: 5) }
        guard let players = fetched else { return }
        var stray: [(uid: Int, device: Int)] = []
        for line in players.split(separator: "\n") {
            guard line.contains("USAGE_MEDIA") || line.contains("USAGE_GAME") || line.contains("USAGE_UNKNOWN"),
                  let d = line.range(of: #"deviceId:(\d+)"#, options: .regularExpression),
                  let u = line.range(of: #"u/pid:(\d+)/"#, options: .regularExpression),
                  let device = Int(line[d].dropFirst("deviceId:".count)),
                  let uid = Int(line[u].dropFirst("u/pid:".count).dropLast()), uid >= 10000, device > 0 else { continue }
            stray.append((uid, device))
        }
        guard !stray.isEmpty else { return }
        if Date().timeIntervalSince(physicalCheckedAt) > 30 {
            await loadPhysicalOutputs()
        }
        let misrouted = stray.filter { physicalOutputs.contains($0.device) }
        guard !misrouted.isEmpty else { return }
        var channels = Set<AudioChannel>()
        for player in misrouted {
            if !perScreen { channels.insert(.background) }
            else if top.contains(player.uid) { channels.insert(.top) }
            else if bottom.contains(player.uid) { channels.insert(.bottom) }
            else { channels.insert(.background) }
        }
        for channel in channels {
            guard Date().timeIntervalSince(lastReroute[channel] ?? .distantPast) > 4,
                  pending[channel] == nil, let entry = running[channel] else { continue }
            lastReroute[channel] = Date()
            Log.write("audio: \(misrouted.map { "uid \($0.uid)" }.joined(separator: ", ")) was playing on the Thor, pulling it back to the Mac")
            let parts = entry.key.split(separator: "|", omittingEmptySubsequences: false)
            let uids = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Int($0) } : []
            let exclude = parts.count > 2 && parts[2] == "true"
            retire(entry)
            running[channel] = nil
            output.flush(channel)
            try? await Task.sleep(nanoseconds: 150_000_000)
            launch(channel: channel, uids: uids, exclude: exclude, key: entry.key)
        }
    }

    private func loadPhysicalOutputs() async {
        physicalCheckedAt = Date()
        guard let out = try? await ADB.shared.shell("dumpsys media.audio_policy 2>/dev/null | grep -E 'Port ID: [0-9]+; .*AUDIO_DEVICE_OUT_' | grep -v -E 'REMOTE_SUBMIX|TELEPHONY'", serial: serial, timeout: 8) else { return }
        var ids = Set<Int>()
        for line in out.split(separator: "\n") {
            if let r = line.range(of: #"Port ID: (\d+)"#, options: .regularExpression), let id = Int(line[r].dropFirst("Port ID: ".count)) {
                ids.insert(id)
            }
        }
        if !ids.isEmpty { physicalOutputs = ids }
    }

    private func apply(_ plan: [AudioChannel: ([Int], Bool)]) {
        for (channel, entry) in running where plan[channel] == nil {
            retire(entry)
            output.flush(channel)
            running[channel] = nil
        }
        for (channel, entry) in pending where plan[channel] == nil {
            entry.session.stop()
            pending[channel] = nil
        }
        for (channel, spec) in plan {
            let key = "\(perScreen)|\(spec.0.map(String.init).joined(separator: ","))|\(spec.1)|\(playOnDevice)"
            if let existing = pending[channel] {
                if existing.key == key { continue }
                existing.session.stop()
                pending[channel] = nil
            }
            if let existing = running[channel], existing.key == key { continue }
            launch(channel: channel, uids: spec.0, exclude: spec.1, key: key)
        }
    }

    private func retire(_ entry: (session: ServerSession, stream: AudioStream?, key: String)) {
        entry.stream?.onEnd = nil
        entry.stream?.stop()
        entry.session.stop()
    }

    private func launch(channel: AudioChannel, uids: [Int], exclude: Bool, key: String) {
        var options: [String: String] = [
            "audio_codec": "raw",
            "cleanup": "false",
        ]
        if perScreen {
            options["audio_source"] = "playback"
            options["audio_dup"] = playOnDevice ? "true" : "false"
            options["audio_kick"] = "true"
            if !uids.isEmpty {
                options["audio_uids"] = uids.map(String.init).joined(separator: ",")
                options["audio_exclude_uids"] = exclude ? "true" : "false"
            }
        } else {
            options["audio_source"] = playOnDevice ? "playback" : "output"
            if playOnDevice { options["audio_dup"] = "true" }
        }
        let session = ServerSession(serial: serial, label: "audio-\(channel.rawValue)", video: false, audio: true, control: false, options: options)
        pending[channel] = (session, key)
        Task { [weak self] in
            guard let self else { return }
            do {
                let sockets = try await session.start()
                guard let socket = sockets.audio, let current = self.pending[channel], current.session === session else {
                    session.stop()
                    return
                }
                self.pending[channel] = nil
                let stream = AudioStream(socket: socket, channel: channel, output: self.output)
                stream.onEnd = { [weak self] in
                    Task { @MainActor in
                        guard let self, let active = self.running[channel], active.session === session else { return }
                        session.stop()
                        self.running[channel] = nil
                    }
                }
                stream.start()
                let previous = self.running[channel]
                self.running[channel] = (session, stream, key)
                if let previous {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    self.retire(previous)
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    await self.enforceRouting(top: self.lastTopUids, bottom: self.lastBottomUids)
                }
            } catch {
                NSLog("Audio %@ failed: %@", channel.rawValue, error.localizedDescription)
                if let current = self.pending[channel], current.session === session {
                    self.pending[channel] = nil
                }
            }
        }
    }

    private func loadUids() async {
        guard let out = try? await ADB.shared.shell("pm list packages -U", serial: serial, timeout: 10) else { return }
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0].hasPrefix("package:"), parts[1].hasPrefix("uid:") else { continue }
            let pkg = String(parts[0].dropFirst("package:".count))
            let uidString = parts[1].dropFirst("uid:".count).split(separator: ",").first ?? ""
            if let uid = Int(uidString) { uidCache[pkg] = uid }
        }
    }

    static func visiblePackages(_ listing: String) -> [Int: [String]] {
        var result: [Int: [String]] = [:]
        var currentDisplay: Int?
        for raw in listing.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("RootTask") {
                currentDisplay = line.range(of: #"displayId=(\d+)"#, options: .regularExpression).flatMap {
                    Int(line[$0].dropFirst("displayId=".count))
                }
            } else if line.hasPrefix("taskId="), let display = currentDisplay, line.contains("visible=true") {
                if let r = line.range(of: #"topActivity=ComponentInfo\{([^/]+)/"#, options: .regularExpression) {
                    let pkg = line[r].dropFirst("topActivity=ComponentInfo{".count).dropLast()
                    var list = result[display] ?? []
                    if !list.contains(String(pkg)) { list.append(String(pkg)) }
                    result[display] = list
                }
            }
        }
        return result
    }
}
