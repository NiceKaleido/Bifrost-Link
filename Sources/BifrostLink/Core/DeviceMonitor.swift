import Foundation

struct CPUCluster: Hashable, Identifiable {
    let name: String
    let cores: Int
    let currentMHz: Double
    let maxMHz: Double
    var id: String { name }
}

struct ThermalGroup: Hashable, Identifiable {
    enum Kind: Hashable { case chip, body, battery }
    let name: String
    let celsius: Double
    var kind: Kind = .chip
    /// What the part does, in a few words.
    var hint = ""
    var id: String { name }
}

/// The Thor's fan, from AYN's fan driver (`/sys/class/gpio5_pwm2`).
struct FanReading: Hashable {
    /// Measured by the fan's tachometer.
    let rpm: Int
    /// PWM duty cycle, 0…1: how hard the fan is being driven.
    let power: Double
    /// AYN's fan setting (Settings › Fan control), when known.
    var mode: String?
}

struct ProcessLoad: Hashable, Identifiable {
    let pid: Int
    let name: String
    let cpu: Double
    let memoryMB: Double
    var id: Int { pid }
}

struct DeviceSnapshot: Equatable {
    var fps: Double?
    var refreshRate: Double = 60
    var frameTimeMs: Double?
    var worstFrameMs: Double?
    var jank = 0
    /// Frames arrive at an even pace (a game capped at 30 or 60 fps), even if below the display's rate.
    var steady = false
    var measuring: String?
    var cpu: Double = 0
    var clusters: [CPUCluster] = []
    var gpu: Double = 0
    var gpuMHz: Double = 0
    var gpuMaxMHz: Double = 0
    var memTotalMB: Double = 0
    var memUsedMB: Double = 0
    var swapTotalMB: Double = 0
    var swapUsedMB: Double = 0
    var thermals: [ThermalGroup] = []
    var cpuTemp: Double?
    var gpuTemp: Double?
    var battery: Int?
    var batteryStatus = ""
    var batteryTemp: Double?
    var fan: FanReading?
    /// Battery draw; nil when the fuel gauge doesn't report current (the Thor reports 0).
    var watts: Double?
    /// Power coming in over USB right now.
    var usbWatts: Double?
    var processes: [ProcessLoad] = []

    var memPercent: Double { memTotalMB > 0 ? memUsedMB / memTotalMB * 100 : 0 }
    /// The hotter of CPU and GPU: what decides whether the chip slows itself down.
    var chipTemp: Double? { [cpuTemp, gpuTemp].compactMap { $0 }.max() }
}

struct DeviceSample: Identifiable, Hashable {
    let time: Date
    let fps: Double?
    let frameTimeMs: Double?
    let cpu: Double
    let gpu: Double
    let mem: Double
    let cpuTemp: Double?
    let gpuTemp: Double?
    let batteryTemp: Double?
    let fanRPM: Double?
    let watts: Double?
    var id: Date { time }
}

/// Live performance numbers from the device, polled over adb only while something is showing them.
@MainActor
final class DeviceMonitor: ObservableObject {
    @Published private(set) var snapshot: DeviceSnapshot?
    @Published private(set) var history: [DeviceSample] = []
    static let historyLength = 120

    var foreground: (() async -> String?)?
    var names: ((String) -> String?)?

    private var serial: String?
    private var watchers: Set<String> = []
    private var task: Task<Void, Never>?
    private var slowTask: Task<Void, Never>?
    /// Read once per link: sensor names per thermal zone, max clock per CPU, max GPU clock.
    private var zoneTypes: [String: String]?
    private var maxFreq: [Int: Double] = [:]
    private var gpuMaxMHz: Double = 0
    private var lastCPU: (total: Double, idle: Double)?
    private var lastPresent: Int64?
    private var layer: String?
    private var layerOwner: String?
    private var processes: [ProcessLoad] = []
    private var fanMode: String?
    private var refreshRate: Double = 60
    private var tick = 0

    func start(serial: String) {
        self.serial = serial
        resume()
    }

    func stop() {
        serial = nil
        task?.cancel()
        task = nil
        slowTask?.cancel()
        slowTask = nil
        zoneTypes = nil
        snapshot = nil
        history = []
        lastCPU = nil
        lastPresent = nil
        layer = nil
    }

    /// Polling runs while at least one watcher (the Performance tab, the stream overlay) is registered.
    func watch(_ id: String, _ on: Bool) {
        if on { watchers.insert(id) } else { watchers.remove(id) }
        resume()
    }

    private func resume() {
        guard serial != nil, !watchers.isEmpty else {
            task?.cancel()
            task = nil
            slowTask?.cancel()
            slowTask = nil
            lastCPU = nil
            lastPresent = nil
            return
        }
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let started = Date()
                await self?.poll()
                let spent = Date().timeIntervalSince(started)
                try? await Task.sleep(nanoseconds: UInt64(max(0.2, 1 - spent) * 1_000_000_000))
            }
        }
        // Processes and the measured surface change slowly; their own loop keeps the 1 s tick fast.
        slowTask = Task { [weak self] in
            while !Task.isCancelled {
                if let serial = self?.serial { await self?.slowPoll(serial: serial) }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func loadStatic(serial: String) async {
        let script = """
        echo @@types; grep -s . /sys/class/thermal/thermal_zone*/type
        echo @@max; grep -s . /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq
        echo @@gpumax; cat /sys/class/kgsl/kgsl-3d0/max_gpuclk 2>/dev/null
        echo @@display; dumpsys display | grep -m1 mActiveSfDisplayMode
        """
        guard let out = try? await ADB.shared.shell(script, serial: serial, timeout: 10) else { return }
        let s = Self.sections(out)
        var types: [String: String] = [:]
        for (path, value) in Self.pathValues(s["types"] ?? "") { types[Self.zone(path)] = value }
        zoneTypes = types
        maxFreq = [:]
        for (path, value) in Self.pathValues(s["max"] ?? "") {
            if let cpu = Self.cpuIndex(path), let khz = Double(value) { maxFreq[cpu] = khz }
        }
        gpuMaxMHz = (Double((s["gpumax"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) / 1_000_000
        if let rate = Self.firstMatch(#"refreshRate=([0-9.]+)"#, in: s["display"] ?? "").flatMap(Double.init) { refreshRate = rate.rounded() }
    }

    private func poll() async {
        guard let serial else { return }
        if zoneTypes == nil { await loadStatic(serial: serial) }
        let latency = layer.map { "dumpsys SurfaceFlinger --latency \(ADB.quote($0))" } ?? "true"
        // Only values that change; one grep per group keeps this well under the 1 s tick.
        let script = """
        echo @@cpu; head -1 /proc/stat
        echo @@freq; grep -s . /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq
        echo @@gpu; cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage /sys/class/kgsl/kgsl-3d0/gpuclk 2>/dev/null
        echo @@mem; grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo
        echo @@therm; grep -s . /sys/class/thermal/thermal_zone*/temp
        echo @@fan; grep -s . /sys/class/gpio5_pwm2/speed /sys/class/gpio5_pwm2/duty /sys/class/gpio5_pwm2/period /sys/class/gpio5_pwm2/state
        echo @@batt; grep -s . /sys/class/power_supply/battery/capacity /sys/class/power_supply/battery/status /sys/class/power_supply/battery/current_now /sys/class/power_supply/battery/voltage_now /sys/class/power_supply/battery/temp /sys/class/power_supply/usb/current_now /sys/class/power_supply/usb/voltage_now
        echo @@fps; \(latency)
        """
        guard let out = try? await ADB.shared.shell(script, serial: serial, timeout: 5), self.serial == serial, task != nil else { return }
        apply(Self.sections(out))
    }

    /// Every few seconds: the busiest processes and which surface to measure frames on.
    private func slowPoll(serial: String) async {
        let out = (try? await ADB.shared.shell("echo @@top; top -b -n 1 -m 6 -s 2 -o PID,%CPU,RES,NAME; echo @@fanmode; settings get system fan_mode 2>/dev/null",
                                               serial: serial, timeout: 5)) ?? ""
        let s = Self.sections(out)
        let top = s["top"] ?? ""
        fanMode = Int((s["fanmode"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).map(Self.fanModeName)
        let cores = Double(max(1, snapshot?.clusters.reduce(0) { $0 + $1.cores } ?? 8))
        processes = Self.parseTop(top).map { ProcessLoad(pid: $0.pid, name: names?($0.name) ?? $0.name, cpu: $0.cpu / cores, memoryMB: $0.memoryMB) }
            .filter { $0.name != "top" }
        guard let package = await foreground?() else { layer = nil; layerOwner = nil; return }
        tick += 1
        if package == layerOwner, layer != nil, tick % 5 != 0 { return }
        let list = (try? await ADB.shared.shell("dumpsys SurfaceFlinger --list", serial: serial, timeout: 5)) ?? ""
        let candidates = Self.layers(for: package, in: list)
        var best: (name: String, newest: Int64)?
        for candidate in candidates.prefix(4) {
            let text = (try? await ADB.shared.shell("dumpsys SurfaceFlinger --latency \(ADB.quote(candidate))", serial: serial, timeout: 5)) ?? ""
            let newest = Self.presents(text).last ?? 0
            if newest > (best?.newest ?? 0) { best = (candidate, newest) }
        }
        if best?.name != layer { lastPresent = nil }
        layer = best?.name
        layerOwner = package
    }

    private func apply(_ s: [String: String]) {
        var snap = snapshot ?? DeviceSnapshot()
        snap.refreshRate = refreshRate
        snap.processes = processes
        snap.measuring = layerOwner.map { names?($0) ?? EmulatorUpdater.knownNames[$0] ?? EmulatorUpdater.prettyName($0) }

        if let fields = s["cpu"]?.split(separator: " ").dropFirst().compactMap({ Double($0) }), fields.count >= 5 {
            let total = fields.reduce(0, +), idle = fields[3] + fields[4]
            if let last = lastCPU, total > last.total { snap.cpu = max(0, min(100, (1 - (idle - last.idle) / (total - last.total)) * 100)) }
            lastCPU = (total, idle)
        }
        var current: [Int: Double] = [:]
        for (path, value) in Self.pathValues(s["freq"] ?? "") {
            if let cpu = Self.cpuIndex(path), let khz = Double(value) { current[cpu] = khz }
        }
        snap.clusters = Self.clusters(current: current, max: maxFreq)

        let gpu = (s["gpu"] ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " %")) }
        if gpu.count >= 2 {
            snap.gpu = Double(gpu[0]) ?? 0
            snap.gpuMHz = (Double(gpu[1]) ?? 0) / 1_000_000
            snap.gpuMaxMHz = gpuMaxMHz
        }

        var mem: [String: Double] = [:]
        for line in (s["mem"] ?? "").split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == ":" || $0 == " " })
            if parts.count >= 2, let kb = Double(parts[1]) { mem[String(parts[0])] = kb / 1024 }
        }
        snap.memTotalMB = mem["MemTotal"] ?? 0
        snap.memUsedMB = max(0, (mem["MemTotal"] ?? 0) - (mem["MemAvailable"] ?? 0))
        snap.swapTotalMB = mem["SwapTotal"] ?? 0
        snap.swapUsedMB = max(0, (mem["SwapTotal"] ?? 0) - (mem["SwapFree"] ?? 0))

        let types = zoneTypes ?? [:]
        snap.thermals = Self.thermals(Self.pathValues(s["therm"] ?? "").compactMap { path, value in
            types[Self.zone(path)].map { "\($0) \(value)" }
        }.joined(separator: "\n"))
        snap.cpuTemp = snap.thermals.first { $0.name == "CPU" }?.celsius
        snap.gpuTemp = snap.thermals.first { $0.name == "GPU" }?.celsius

        var batt: [String: String] = [:]
        var usb: [String: String] = [:]
        for (path, value) in Self.pathValues(s["batt"] ?? "") {
            let supply = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if supply == "usb" { usb[(path as NSString).lastPathComponent] = value } else { batt[(path as NSString).lastPathComponent] = value }
        }
        if let current = usb["current_now"].flatMap(Double.init), let voltage = usb["voltage_now"].flatMap(Double.init) {
            let watts = abs(current) / 1_000_000 * voltage / 1_000_000
            snap.usbWatts = watts > 0.2 ? watts : nil
        } else {
            snap.usbWatts = nil
        }
        snap.battery = batt["capacity"].flatMap { Int($0) }
        snap.batteryStatus = batt["status"] ?? ""
        snap.batteryTemp = batt["temp"].flatMap { Double($0) }.map { $0 / 10 }
        if let current = batt["current_now"].flatMap(Double.init), let voltage = batt["voltage_now"].flatMap(Double.init), voltage > 0 {
            let watts = abs(current) / 1_000_000 * voltage / 1_000_000
            snap.watts = watts > 0.05 ? watts : nil
        }
        if let temp = snap.batteryTemp { snap.thermals.append(ThermalGroup(name: "Battery", celsius: temp, kind: .battery, hint: "Keeps best above 15° and below 45°")) }

        var fan: [String: String] = [:]
        for (path, value) in Self.pathValues(s["fan"] ?? "") { fan[(path as NSString).lastPathComponent] = value }
        if let rpm = fan["speed"].flatMap(Int.init) {
            let on = fan["state"] != "0"
            let duty = fan["duty"].flatMap(Double.init) ?? 0, period = fan["period"].flatMap(Double.init) ?? 0
            snap.fan = FanReading(rpm: on ? rpm : 0, power: on && period > 0 ? min(1, duty / period) : 0, mode: fanMode)
        } else {
            snap.fan = nil
        }

        updateFrames(&snap, latency: s["fps"] ?? "")
        snapshot = snap
        history.append(DeviceSample(time: Date(), fps: snap.fps, frameTimeMs: snap.frameTimeMs, cpu: snap.cpu, gpu: snap.gpu, mem: snap.memPercent,
                                    cpuTemp: snap.cpuTemp, gpuTemp: snap.gpuTemp, batteryTemp: snap.batteryTemp,
                                    fanRPM: snap.fan.map { Double($0.rpm) }, watts: snap.watts))
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    /// Frame rate from SurfaceFlinger's present timestamps, over the newest second of frames.
    /// (It keeps only ~128 frames, so counting "frames since the last poll" undercounts whenever a poll is slow.)
    private func updateFrames(_ snap: inout DeviceSnapshot, latency: String) {
        let presents = Self.presents(latency)
        guard layer != nil, let newest = presents.last else {
            snap.fps = nil; snap.frameTimeMs = nil; snap.worstFrameMs = nil; snap.jank = 0; snap.steady = false
            return
        }
        let stalled = lastPresent.map { newest <= $0 } ?? false
        lastPresent = newest
        let window = presents.filter { $0 >= newest - 1_000_000_000 }
        guard !stalled, window.count >= 2 else {
            snap.fps = 0; snap.frameTimeMs = nil; snap.worstFrameMs = nil; snap.jank = 0; snap.steady = false
            return
        }
        let deltas = zip(window.dropFirst(), window).map { Double($0 - $1) / 1_000_000 }
        let span = deltas.reduce(0, +)
        snap.fps = span > 0 ? Double(deltas.count) / (span / 1000) : nil
        snap.frameTimeMs = span / Double(deltas.count)
        snap.worstFrameMs = deltas.max()
        let budget = 1000 / max(1, refreshRate)
        snap.jank = deltas.filter { $0 > budget * 1.5 && $0 > (snap.frameTimeMs ?? 0) * 1.5 }.count
        snap.steady = snap.jank == 0 && (snap.worstFrameMs ?? 0) <= (snap.frameTimeMs ?? 0) * 1.5
    }

    // MARK: - Parsing

    static func sections(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var current: String?
        var lines: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                if let current { result[current] = lines.joined(separator: "\n") }
                current = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                lines = []
            } else {
                lines.append(line)
            }
        }
        if let current { result[current] = lines.joined(separator: "\n") }
        return result
    }

    /// Present times (ns) from `dumpsys SurfaceFlinger --latency`, skipping pending (INT64_MAX) and empty rows.
    static func presents(_ text: String) -> [Int64] {
        text.split(separator: "\n").dropFirst().compactMap { line in
            let cols = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard cols.count >= 3, let value = Int64(cols[1]), value > 0, value != Int64.max else { return nil }
            return value
        }.sorted()
    }

    static func layers(for package: String, in list: String) -> [String] {
        let lines = list.split(separator: "\n").map(String.init)
        let surfaces = lines.filter { $0.hasPrefix("SurfaceView[") && $0.contains(package) && !$0.contains("Background") }
        let windows = lines.filter { $0.hasPrefix(package + "/") }
        return (surfaces.reversed() + windows.reversed())
    }

    static func clusters(current: [Int: Double], max: [Int: Double]) -> [CPUCluster] {
        var groups: [Double: (count: Int, current: Double)] = [:]
        for (cpu, top) in max {
            let entry = groups[top] ?? (0, 0)
            groups[top] = (entry.count + 1, Swift.max(entry.current, current[cpu] ?? 0))
        }
        let ordered = groups.sorted { $0.key < $1.key }
        let names = ordered.count == 3 ? ["Efficiency", "Performance", "Prime"] : ordered.count == 2 ? ["Efficiency", "Performance"] : ordered.indices.map { "Cluster \($0 + 1)" }
        return ordered.enumerated().map { index, item in
            CPUCluster(name: names[index], cores: item.value.count, currentMHz: item.value.current / 1000, maxMHz: item.key / 1000)
        }
    }

    /// "path:value" lines as printed by `grep -s . file…`.
    static func pathValues(_ text: String) -> [(String, String)] {
        text.split(separator: "\n").compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
    }

    /// "/sys/class/thermal/thermal_zone10/temp" → "thermal_zone10"
    static func zone(_ path: String) -> String { ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent }

    /// "/sys/devices/system/cpu/cpu3/cpufreq/scaling_cur_freq" → 3
    static func cpuIndex(_ path: String) -> Int? {
        path.split(separator: "/").first { $0.hasPrefix("cpu") && $0.count > 3 && Int($0.dropFirst(3)) != nil }.flatMap { Int($0.dropFirst(3)) }
    }

    /// AYN's names for `settings get system fan_mode`.
    static func fanModeName(_ mode: Int) -> String {
        let names = ["Off", "Quiet", "Sport", "High speed", "Smart"]
        return names.indices.contains(mode) ? names[mode] : "Custom"
    }

    /// Sensors grouped into parts that matter on a handheld; each shows its hottest sensor.
    /// The chip also has camera, modem and AI-engine sensors, but the Thor doesn't use those blocks,
    /// so they only echo the chip's own temperature.
    static func thermals(_ text: String) -> [ThermalGroup] {
        let groups: [(name: String, prefixes: [String], kind: ThermalGroup.Kind, hint: String)] = [
            ("CPU", ["cpu-", "cpuss-"], .chip, "Runs the game and emulator"),
            ("GPU", ["gpuss-"], .chip, "Draws the graphics"),
            ("Memory", ["ddr"], .chip, "RAM, stacked on the chip"),
            ("Video encoder", ["video"], .chip, "Streams the screen to this Mac"),
            ("Mainboard", ["xo-therm"], .body, "Inside the case, near the chip"),
            ("USB-C port", ["usb-therm"], .body, "Warms up while charging"),
            ("Charging chip", ["pm8550b_tz"], .body, "Manages battery charging"),
        ]
        var hottest: [String: Double] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let milli = Double(parts[1]) else { continue }
            let type = String(parts[0])
            let celsius = milli / 1000
            guard celsius > -20, celsius < 150 else { continue }
            // Short names ("pa") must match exactly; longer ones also match numbered sensors ("mmw3", "cpu-1-4").
            if let group = groups.first(where: { g in g.prefixes.contains { type == $0 || ($0.count > 2 && type.hasPrefix($0)) } }) {
                hottest[group.name] = max(hottest[group.name] ?? -100, celsius)
            }
        }
        return groups.compactMap { g in hottest[g.name].map { ThermalGroup(name: g.name, celsius: $0, kind: g.kind, hint: g.hint) } }
    }

    static func parseTop(_ text: String) -> [ProcessLoad] {
        var rows: [ProcessLoad] = []
        var started = false
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            if cols.first?.hasPrefix("PID") == true { started = true; continue }
            guard started, cols.count >= 4, let pid = Int(cols[0]), let cpu = Double(cols[1]) else { continue }
            rows.append(ProcessLoad(pid: pid, name: cols[3...].joined(separator: " "), cpu: cpu, memoryMB: memory(String(cols[2]))))
        }
        return rows
    }

    private static func memory(_ text: String) -> Double {
        let value = Double(text.dropLast()) ?? Double(text) ?? 0
        switch text.last {
        case "G": return value * 1024
        case "M": return value
        case "K": return value / 1024
        default: return value / 1024 / 1024
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
