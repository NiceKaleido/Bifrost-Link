import Foundation

/// What one emulator needs to boot games, where it looks, and what's there.
struct BiosReport: Identifiable, Hashable {
    struct Line: Identifiable, Hashable {
        enum State: Hashable { case ok, missing, optional }
        let label: String
        let detail: String
        let state: State
        /// A copy from the shared bios folder that would fix this line.
        var copy: Copy?
        var id: String { label }
    }

    struct Copy: Hashable {
        let from: String
        let to: String
    }

    let emulator: String
    let system: String
    /// Where the emulator reads its BIOS files.
    let folder: String?
    let lines: [Line]
    var note: String?
    var id: String { emulator }
    var missingRequired: Int { lines.filter { $0.state == .missing }.count }
}

/// Checks the BIOS and keys each installed emulator reads from its own folder. Files are told apart by MD5,
/// so renamed copies are still recognised, and missing ones are looked up in the shared bios folder.
enum BiosCheck {
    private static let data = Emulators.data

    /// PlayStation BIOS images by MD5 (the same ones DuckStation and PCSX-ReARMed recognise).
    static let ps1: [String: (name: String, region: String)] = [
        "8dd7d5296a650fac7319bce665a6a53c": ("SCPH-5500", "Japan"),
        "490f666e1afb15b7362b406ed1cea246": ("SCPH-5501", "USA"),
        "32736f17079d0b2b7024407c39bd3050": ("SCPH-5502", "Europe"),
        "924e392ed05558ffdb115408c263dccf": ("SCPH-1001", "USA"),
    ]
    /// The file names PCSX-ReARMed looks for, per region.
    private static let ps1Names = ["Japan": "scph5500.bin", "USA": "scph5501.bin", "Europe": "scph5502.bin"]

    private struct FileInfo { let path: String; let md5: String? }

    static func scan(serial: String) async -> [BiosReport] {
        let packages = ((try? await ADB.shared.shell("pm list packages", serial: serial, timeout: 15)) ?? "")
        let installed = Set(packages.split(separator: "\n").map { $0.replacingOccurrences(of: "package:", with: "").trimmingCharacters(in: .whitespaces) })
        let shared = await files(in: ["/storage/*/bios", "/sdcard/bios"], depth: 2, hash: true, serial: serial)
        var reports: [BiosReport] = []

        if installed.contains("com.github.stenzek.duckstation") {
            let folder = "\(data)/com.github.stenzek.duckstation/files/bios"
            let present = await files(in: [folder], depth: 1, hash: true, serial: serial)
            let writable = await isWritable(folder, serial: serial)
            reports.append(playStation(emulator: "DuckStation", folder: folder, present: present, shared: shared, writable: writable, required: true,
                                       target: { _ in folder + "/" }))
        }
        if installed.contains("com.retroarch") {
            reports.append(await retroArch(shared: shared, serial: serial))
        }
        if installed.contains("com.armsx2") {
            let folder = "\(data)/com.armsx2/files/bios"
            let present = await files(in: [folder], depth: 1, hash: false, serial: serial)
                .filter { $0.path.lowercased().hasSuffix(".bin") }
            let regions = Set(present.compactMap { ps2Region((($0.path as NSString).lastPathComponent)) })
            let line: BiosReport.Line = present.isEmpty
                ? .init(label: "PlayStation 2 BIOS", detail: "None found. ARMSX2 can’t start games without one", state: .missing)
                : .init(label: "PlayStation 2 BIOS", detail: "\(present.count) file\(present.count == 1 ? "" : "s")" + (regions.isEmpty ? "" : " · " + regions.sorted().joined(separator: ", ")), state: .ok)
            reports.append(BiosReport(emulator: "ARMSX2", system: "PlayStation 2", folder: folder, lines: [line],
                                      note: "Pick which one it uses in ARMSX2’s settings."))
        }
        for profile in Emulators.all where profile.id.hasPrefix("eden") && installed.contains(profile.package) {
            reports.append(await eden(profile, shared: shared, serial: serial))
        }
        let needNothing = [("org.ppsspp.ppsspp", "PPSSPP"), ("org.dolphinemu.dolphinemu", "Dolphin"), ("me.magnum.melondualds", "WatermelonDS"),
                           ("io.github.lime3ds.android", "Azahar"), ("com.rfandango.haku_x", "hakuX")]
            .filter { installed.contains($0.0) }.map(\.1)
        if !needNothing.isEmpty {
            reports.append(BiosReport(emulator: needNothing.joined(separator: ", "), system: "", folder: nil, lines: [],
                                      note: "Play without a BIOS. Dolphin can use a GameCube IPL just for the boot animation, and Azahar only needs keys for encrypted 3DS games."))
        }
        return reports
    }

    // MARK: - PlayStation

    private static func playStation(emulator: String, folder: String, present: [FileInfo], shared: [FileInfo], writable: Bool, required: Bool,
                                    target: (String) -> String) -> BiosReport {
        let found = present.compactMap { $0.md5.flatMap { ps1[$0] } }
        var lines: [BiosReport.Line] = []
        for region in ["USA", "Europe", "Japan"] {
            if let bios = found.first(where: { $0.region == region }) {
                lines.append(.init(label: "\(region) BIOS", detail: bios.name, state: .ok))
                continue
            }
            let source = shared.first { $0.md5.flatMap { ps1[$0]?.region } == region }
            let state: BiosReport.Line.State = required && found.isEmpty ? .missing : .optional
            let detail = (state == .missing ? "Missing" : "Not there, needed for \(region) games") + (source.map { " · in your bios folder as \(($0.path as NSString).lastPathComponent)" } ?? "")
            lines.append(.init(label: "\(region) BIOS", detail: detail, state: state,
                               copy: writable ? source.map { .init(from: $0.path, to: target(region)) } : nil))
        }
        return BiosReport(emulator: emulator, system: "PlayStation", folder: folder, lines: lines)
    }

    // MARK: - RetroArch

    private static func retroArch(shared: [FileInfo], serial: String) async -> BiosReport {
        let base = "\(data)/com.retroarch/files"
        let config = (try? await ADB.shared.shell("grep -E '^system_directory' \(ADB.quote(base + "/retroarch.cfg")) 2>/dev/null", serial: serial, timeout: 5)) ?? ""
        var folder = config.components(separatedBy: "\"").dropFirst().first ?? ""
        if folder.isEmpty || folder.contains(":") { folder = "\(base)/RetroArch/system" }
        folder = folder.replacingOccurrences(of: "/storage/emulated/0/", with: "/sdcard/")
        // The cores you use leave a saves folder behind; only check BIOS for those.
        let cores = Set(((try? await ADB.shared.shell("ls -1 \(ADB.quote(base + "/RetroArch/saves")) /sdcard/RetroArch/saves 2>/dev/null", serial: serial, timeout: 5)) ?? "")
            .split(separator: "\n").map { $0.lowercased() })
        let present = await files(in: [folder], depth: 2, hash: true, serial: serial)
        let writable = await isWritable(folder, serial: serial)
        func has(_ relative: String) -> Bool { present.contains { $0.path.lowercased() == (folder + "/" + relative).lowercased() } }
        func source(named name: String) -> FileInfo? { shared.first { ($0.path as NSString).lastPathComponent.lowercased() == name } }

        var lines: [BiosReport.Line] = []
        if cores.contains("pcsx-rearmed") || cores.contains("swanstation") || cores.contains("beetle psx") || cores.contains("beetle psx hw") {
            let found = present.compactMap { info -> String? in
                guard ((info.path as NSString).deletingLastPathComponent) == folder, let bios = info.md5.flatMap({ ps1[$0] }) else { return nil }
                return "\(bios.name) (\(bios.region))"
            }
            if found.isEmpty {
                let src = shared.first { $0.md5.flatMap { ps1[$0] } != nil }
                lines.append(.init(label: "PlayStation BIOS", detail: "Not there. PCSX-ReARMed falls back to a built-in BIOS that some games don’t like" + (src.map { " · in your bios folder as \(($0.path as NSString).lastPathComponent)" } ?? ""),
                                   state: .optional,
                                   copy: writable ? src.map { s in .init(from: s.path, to: folder + "/" + (ps1Names[ps1[s.md5 ?? ""]?.region ?? "USA"] ?? "scph5501.bin")) } : nil))
            } else {
                lines.append(.init(label: "PlayStation BIOS", detail: found.joined(separator: ", "), state: .ok))
            }
        }
        if cores.contains("flycast") {
            for (name, label) in [("dc_boot.bin", "Dreamcast BIOS"), ("dc_flash.bin", "Dreamcast flash")] {
                if has("dc/" + name) {
                    lines.append(.init(label: label, detail: "dc/\(name)", state: .ok))
                } else {
                    let src = source(named: name)
                    lines.append(.init(label: label, detail: "Not in dc/. Flycast uses its own fallback, some games need the real one" + (src.map { " · in your bios folder as \(($0.path as NSString).lastPathComponent)" } ?? ""),
                                       state: .optional, copy: writable ? src.map { .init(from: $0.path, to: folder + "/dc/" + name) } : nil))
                }
            }
        }
        if cores.contains("mgba") || cores.contains("vba-m") || cores.contains("gpsp") {
            let src = source(named: "gba_bios.bin")
            lines.append(has("gba_bios.bin")
                ? .init(label: "Game Boy Advance BIOS", detail: "gba_bios.bin", state: .ok)
                : .init(label: "Game Boy Advance BIOS", detail: "Not needed, only adds the boot logo", state: .optional, copy: writable ? src.map { .init(from: $0.path, to: folder + "/gba_bios.bin") } : nil))
        }
        var note: String?
        if !writable, lines.contains(where: { $0.state != .ok }) {
            note = "RetroArch made this folder read-only for other apps, so files can’t be copied in from the Mac. You can point RetroArch at your bios folder instead, in Settings › Directory › System/BIOS. Dreamcast files then go in a dc folder inside it."
        }
        if lines.isEmpty { note = "None of the cores you use need a BIOS." }
        return BiosReport(emulator: "RetroArch", system: "Several systems", folder: folder, lines: lines, note: note)
    }

    // MARK: - Eden

    private static func eden(_ profile: EmulatorProfile, shared: [FileInfo], serial: String) async -> BiosReport {
        let root = "\(data)/\(profile.package)/files"
        let out = (try? await ADB.shared.shell("[ -s \(ADB.quote(root + "/keys/prod.keys")) ] && echo keys; ls \(ADB.quote(root + "/nand/system/Contents/registered")) 2>/dev/null | wc -l; ls /storage/*/bios/switch /sdcard/bios/switch 2>/dev/null | grep -i firmware",
                                               serial: serial, timeout: 10)) ?? ""
        let rows = out.split(separator: "\n").map(String.init)
        let keys = rows.contains("keys")
        let firmwareCount = rows.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.first ?? 0
        let zips = rows.filter { $0.lowercased().contains("firmware") }.sorted()
        var lines: [BiosReport.Line] = [
            .init(label: "Keys (prod.keys)", detail: keys ? "Installed" : "Missing. Eden can’t start games without them", state: keys ? .ok : .missing),
        ]
        lines.append(firmwareCount > 0
            ? .init(label: "Firmware", detail: "Installed", state: .ok)
            : .init(label: "Firmware", detail: "Not installed. Some games need it" + (zips.last.map { " · \($0) is in your bios/switch folder" } ?? ""), state: .optional))
        return BiosReport(emulator: profile.name, system: "Nintendo Switch", folder: root + "/keys", lines: lines,
                          note: firmwareCount == 0 && !zips.isEmpty ? "Firmware is installed from inside Eden, from the zip." : nil)
    }

    // MARK: - Helpers

    private static func ps2Region(_ name: String) -> String? {
        let n = name.lowercased()
        if n.contains("(e)") || n.contains("_e_") || n.contains("europ") { return "Europe" }
        if n.contains("(u)") || n.contains("_u_") || n.contains("usa") { return "USA" }
        if n.contains("(j)") || n.contains("_j_") || n.contains("japan") { return "Japan" }
        return nil
    }

    /// Files in these folders (globs allowed), with MD5 for files up to 16 MB when `hash` is set.
    private static func files(in dirs: [String], depth: Int, hash: Bool, serial: String) async -> [FileInfo] {
        let list = dirs.joined(separator: " ")
        let action = hash ? "-size -16M -exec md5sum {} +" : "-print"
        let command = "for d in \(list); do [ -d \"$d\" ] && find \"$d\" -maxdepth \(depth) -type f \(action) 2>/dev/null; done; true"
        let out = (try? await ADB.shared.shell(command, serial: serial, timeout: 60)) ?? ""
        return out.split(separator: "\n").compactMap { line in
            let text = String(line)
            if hash {
                guard text.count > 34, text.prefix(32).allSatisfy(\.isHexDigit) else { return nil }
                return FileInfo(path: String(text.dropFirst(34)).replacingOccurrences(of: "/storage/emulated/0/", with: "/sdcard/"), md5: String(text.prefix(32)))
            }
            return FileInfo(path: text, md5: nil)
        }
    }

    private static func isWritable(_ folder: String, serial: String) async -> Bool {
        ((try? await ADB.shared.shell("[ -w \(ADB.quote(folder)) ] && echo yes", serial: serial, timeout: 5)) ?? "").contains("yes")
    }
}
