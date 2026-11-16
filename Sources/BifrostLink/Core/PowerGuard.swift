import Foundation

@MainActor
final class PowerGuard {
    private let serial: String
    private var eventProcess: Process?
    private var pollTask: Task<Void, Never>?
    private var pendingCheck: Task<Void, Never>?
    private(set) var lidClosed = false
    var panelsOn = true
    var settings: LinkSettings { LinkSettings.shared }
    var setPanels: ((Bool) -> Void)?
    var onLidChange: ((Bool) -> Void)?

    init(serial: String) {
        self.serial = serial
    }

    func start() async {
        let info = (try? await ADB.shared.shell("getevent -pl", serial: serial, timeout: 10)) ?? ""
        var devices: [String] = []
        var currentPath: String?
        for raw in info.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("add device") {
                currentPath = line.split(separator: " ").last.map(String.init)
            } else if line.hasPrefix("name:"), let path = currentPath {
                if line.contains("hall") || line.contains("pwrkey") || line.contains("gpio-keys") || line.contains("lid") {
                    devices.append(path)
                }
            } else if line.contains("SW_LID*") {
                lidClosed = true
            }
        }
        onLidChange?(lidClosed)

        if !devices.isEmpty {
            eventProcess = try? ADB.shared.startStreaming(["shell", "getevent -l " + devices.joined(separator: " ")], serial: serial, onLine: { [weak self] line in
                Task { @MainActor in self?.handle(line) }
            }, onExit: { _ in })
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.ensureAwake()
            }
        }

        if lidClosed {
            await ensureAwake()
            if settings.panelsOffWhenClosed { applyPanels(false) }
        } else if settings.panelsOffOnLink {
            applyPanels(false)
        }
    }

    func stop() {
        eventProcess?.terminate()
        eventProcess = nil
        pollTask?.cancel()
        pollTask = nil
        pendingCheck?.cancel()
    }

    private func handle(_ line: String) {
        if line.contains("SW_LID") {
            let closed = line.hasSuffix("00000001")
            guard closed != lidClosed else { return }
            lidClosed = closed
            onLidChange?(closed)
            if closed {
                schedule { guard self.settings.keepAwake else { return }
                    await self.ensureAwake(force: true)
                    if self.settings.panelsOffWhenClosed { self.applyPanels(false) }
                }
            } else {
                schedule { self.applyPanels(true) }
            }
        } else if line.contains("KEY_POWER") && line.contains("UP") {
            let wanted = !panelsOn
            schedule {
                guard self.settings.keepAwake else { return }
                await self.ensureAwake(force: true)
                self.applyPanels(self.lidClosed ? false : wanted)
            }
        }
    }

    private func schedule(_ work: @escaping @MainActor () async -> Void) {
        pendingCheck?.cancel()
        pendingCheck = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await work()
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await work()
        }
    }

    func applyPanels(_ on: Bool) {
        panelsOn = on
        setPanels?(on)
    }

    @discardableResult
    func ensureAwake(force: Bool = false) async -> Bool {
        guard settings.keepAwake || force else { return false }
        let script = #"w=$(dumpsys power | grep -m1 mWakefulness=); case "$w" in *Awake*) echo awake;; *) input keyevent 224; wm dismiss-keyguard; echo woke;; esac"#
        guard let out = try? await ADB.shared.shell(script, serial: serial, timeout: 5) else { return false }
        let woke = out.contains("woke")
        if woke && !panelsOn {
            try? await Task.sleep(nanoseconds: 250_000_000)
            setPanels?(false)
        }
        return woke
    }

    func releaseDevice() async {
        stop()
        if lidClosed && settings.sleepOnUnlinkIfClosed {
            _ = try? await ADB.shared.shell("input keyevent 223", serial: serial, timeout: 5)
        } else if !panelsOn {
            panelsOn = true
            setPanels?(true)
        }
    }
}
