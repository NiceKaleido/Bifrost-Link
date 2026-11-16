import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case files, library, saves, cleanup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "Files"
        case .library: return "Library"
        case .saves: return "Saves"
        case .cleanup: return "Cleanup"
        }
    }

    var symbol: String {
        switch self {
        case .files: return "folder"
        case .library: return "square.stack.3d.up"
        case .saves: return "externaldrive.badge.checkmark"
        case .cleanup: return "sparkles"
        }
    }
}

struct InspectorView: View {
    @ObservedObject var manager: DeviceManager
    @ObservedObject var settings: LinkSettings
    @AppStorage("inspectorTab") private var tab: InspectorTab = .files

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(InspectorTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)

            switch tab {
            case .files: FileBrowserView(files: manager.files, settings: settings)
            case .library: LibraryView(hub: manager.emulation, files: manager.files, updater: manager.updater)
            case .saves: SavesView(backups: manager.backups, settings: settings)
            case .cleanup: CleanupView(cleanup: manager.cleanup)
            }
            ActivityPanel(files: manager.files, hub: manager.emulation)
        }
        .frame(minWidth: 320)
    }
}

struct SectionHeader: View {
    let title: String
    var symbol: String?
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).foregroundStyle(Theme.accent) }
            Text(title).font(.callout.weight(.semibold))
            Spacer()
            if let trailing {
                Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct SizeBar: View {
    let fraction: Double
    var tint: AnyShapeStyle = AnyShapeStyle(Theme.bifrost)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint).frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

extension Int64 {
    var bytesText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

struct LibraryView: View {
    @ObservedObject var hub: EmulationHub
    @ObservedObject var files: FileService
    @ObservedObject var updater: EmulatorUpdater
    @State private var repoTarget: SideloadedApp?
    @State private var repoText = ""
    @State private var dropTargeted = false
    @State private var showOrphans = false
    @State private var confirmOrphans = false

    var body: some View {
        GeometryReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                importZone
                if hub.scanning && hub.lastScan == nil {
                    Spacer(minLength: 20)
                    ProgressView("Looking through your library…").frame(maxWidth: .infinity, alignment: .center)
                    Spacer(minLength: 20)
                } else if hub.lastScan == nil {
                    Spacer(minLength: 10)
                    ContentUnavailableView {
                        Label("Library check", systemImage: "square.stack.3d.up")
                    } description: {
                        Text("See what takes up space, find stray ROMs, missing files and BIOS gaps.")
                    } actions: {
                        Button("Check Library") { Task { await hub.scan() } }.buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 10)
                } else {
                    updatesSection
                    unsortedSection
                    spaceSection
                    biosSection
                    healthSection
                    shrinkSection
                }
            }
            .padding(12)
            .frame(minHeight: proxy.size.height, alignment: .top)
        }
        }
        .confirmationDialog(hub.shrunk.count == 1 ? "Remove the original?" : "Remove \(hub.shrunk.count) originals?", isPresented: $hub.askRemoveOriginals) {
            Button(hub.shrunk.count == 1 ? "Remove Original" : "Remove All \(hub.shrunk.count)", role: .destructive) { Task { await hub.removeOriginals(hub.shrunk) } }
            Button("Keep Them for Now", role: .cancel) {}
        } message: {
            let original = hub.shrunk.reduce(0) { $0 + $1.candidate.size }
            let saved = hub.shrunk.reduce(0) { $0 + $1.saved }
            Text("The CHD versions are on your Thor and checked. Removing the originals frees \(original.bytesText) and saves \(saved.bytesText) overall. Playlists and Cocoon entries are pointed at the new files.")
        }
    }

    private var importZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down.on.square").font(.title2).foregroundStyle(Theme.bifrost)
            Text("Drop ROMs here").font(.callout.weight(.semibold))
            Text("They’re sorted into the right system folder automatically.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Choose Files…") { pick() }
                if hub.lastScan != nil {
                    Button { Task { await hub.scan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                        .disabled(hub.scanning)
                }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(dropTargeted ? Theme.accent.opacity(0.14) : Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(dropTargeted ? AnyShapeStyle(Theme.bifrost) : AnyShapeStyle(Theme.hairline), style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: dropTargeted ? [7, 4] : [])))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                let urls = await DropLoader.fileURLs(providers)
                await MainActor.run {
                    hub.prepareImport(urls)
                    if hub.importItems.isEmpty { hub.toast?("questionmark.folder", "Drop ROM files here, folders aren’t imported") }
                }
            }
            return true
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose ROMs to send to the Thor"
        if panel.runModal() == .OK { hub.prepareImport(panel.urls) }
    }

    @ViewBuilder
    private var updatesSection: some View {
        let available = updater.apps.filter(\.updateAvailable).count
        SectionHeader(title: "App updates", symbol: "arrow.down.app", trailing: updater.apps.isEmpty ? nil : (available == 0 ? "up to date" : "\(available) available"))
        Card {
            if updater.apps.isEmpty {
                HStack {
                    Text("Checks apps you installed outside the Play Store against their GitHub releases.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(updater.checking ? "Checking…" : "Check") { Task { await updater.check() } }
                        .controlSize(.small)
                        .disabled(updater.checking || updater.serial == nil)
                }
            } else {
                let tracked = updater.apps.filter { $0.repo != nil }
                let others = updater.apps.filter { $0.repo == nil }
                ForEach(tracked) { app in updateRow(app) }
                if !others.isEmpty {
                    DisclosureGroup {
                        ForEach(others) { app in updateRow(app) }
                    } label: {
                        Text("Other sideloaded apps (\(others.count)). Add a GitHub link to keep them updated").font(.caption)
                    }
                }
                HStack {
                    Text("Updates are verified before installing and keep your data.").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Button { Task { await updater.check() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .disabled(updater.checking)
                        .help("Check again")
                }
            }
        }
        .alert("GitHub source for \(repoTarget?.name ?? "")", isPresented: Binding(get: { repoTarget != nil }, set: { if !$0 { repoTarget = nil } })) {
            TextField("owner/repository or link", text: $repoText)
            Button("Save") {
                if let app = repoTarget { updater.setRepo(repoText, for: app.package) }
                repoTarget = nil
            }
            Button("Cancel", role: .cancel) { repoTarget = nil }
        } message: {
            Text("Bifrost looks at this repository’s latest release for an APK.")
        }
    }

    private func updateRow(_ app: SideloadedApp) -> some View {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).font(.callout)
                            Text(subtitle(app)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if updater.installing == app.package {
                            ProgressView().controlSize(.small)
                        } else if app.updateAvailable {
                            Button("Update") { Task { await updater.update(app) } }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                                .disabled(updater.installing != nil)
                        }
                        Menu {
                            Button(app.repo == nil ? "Set GitHub Source…" : "Change GitHub Source…") {
                                repoText = app.repo ?? ""
                                repoTarget = app
                            }
                            if let repo = app.repo, let url = URL(string: "https://github.com/\(repo)/releases") {
                                Button("Open Releases Page") { NSWorkspace.shared.open(url) }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                    .help(app.package)
    }

    private func subtitle(_ app: SideloadedApp) -> String {
        if let tag = app.latestTag, app.updateAvailable { return "\(app.installedVersion) → \(tag) · \(app.assetSize.bytesText)" }
        if let note = app.note { return "\(app.installedVersion) · \(note)" }
        if app.repo == nil { return "\(app.installedVersion) · no source set" }
        return "\(app.installedVersion) · up to date"
    }

    @ViewBuilder
    private var unsortedSection: some View {
        if !hub.unsorted.isEmpty {
            SectionHeader(title: "Stray ROMs", symbol: "tray.full", trailing: "\(hub.unsorted.count)")
            Card {
                Text("These sit outside your Roms folders, so frontends won’t find them.").font(.caption).foregroundStyle(.secondary)
                ForEach(hub.unsorted) { rom in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rom.name).font(.callout).lineLimit(1).truncationMode(.middle)
                            Text("\((rom.path as NSString).deletingLastPathComponent) · \(rom.size.bytesText)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Menu("Move") {
                            ForEach(rom.candidates, id: \.self) { system in
                                Button("to \(Systems.name(for: system))") { Task { await hub.moveUnsorted(rom, to: system) } }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var spaceSection: some View {
        let total = hub.space.reduce(0) { $0 + $1.bytes }
        SectionHeader(title: "Space by system", symbol: "chart.bar.xaxis", trailing: total.bytesText)
        Card {
            let maxBytes = hub.space.first?.bytes ?? 1
            ForEach(hub.space) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(Systems.name(for: entry.system)).font(.callout)
                        Spacer()
                        Text("\(entry.files) · \(entry.bytes.bytesText)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    SizeBar(fraction: Double(entry.bytes) / Double(max(1, maxBytes)))
                }
                .contentShape(Rectangle())
                .onTapGesture { files.open(entry.path) }
                .help("Open \(entry.path) in Files")
            }
        }
    }

    @ViewBuilder
    private var biosSection: some View {
        if !hub.bios.isEmpty {
            let missing = hub.bios.filter { $0.found == nil && $0.required }.count
            SectionHeader(title: "BIOS", symbol: "cpu", trailing: missing == 0 ? "all set" : "\(missing) missing")
            Card {
                ForEach(hub.bios) { status in
                    HStack(spacing: 8) {
                        Image(systemName: status.found != nil ? "checkmark.circle.fill" : (status.required ? "xmark.circle.fill" : "minus.circle"))
                            .foregroundStyle(status.found != nil ? .green : (status.required ? .orange : .secondary))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(Systems.name(for: status.system)) · \(status.label)").font(.callout)
                            Text(status.found ?? (status.required ? "Not found in the bios folder" : "Optional")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var healthSection: some View {
        let mediaBytes = hub.orphanMedia.reduce(0) { $0 + $1.size }
        SectionHeader(title: "Leftover artwork", symbol: "photo.stack", trailing: hub.orphanMedia.isEmpty && hub.orphanEntries.isEmpty ? "all tidy" : mediaBytes.bytesText)
        Card {
            if hub.orphanMedia.isEmpty && hub.orphanEntries.isEmpty {
                Label(hub.cocoonRoot == nil ? "Cocoon wasn’t found, so there’s no scraped data to check." : "Every scraped image and entry still belongs to a game on your Thor.", systemImage: "hand.thumbsup")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("\(hub.orphanMedia.count) images and \(hub.orphanEntries.count) Cocoon entries belong to games that are no longer on the Thor.")
                    .font(.callout)
                DisclosureGroup(isExpanded: $showOrphans) {
                    let names = Dictionary(grouping: hub.orphanEntries, by: \.system)
                    ForEach(names.keys.sorted(), id: \.self) { system in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Systems.name(for: system)).font(.caption.weight(.semibold))
                            ForEach(names[system] ?? []) { entry in
                                Text(entry.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } label: {
                    Text("Show games").font(.caption)
                }
                HStack {
                    Text("Your gamelists are backed up to the Mac first.").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Button(hub.cleaningOrphans ? "Cleaning…" : "Clean Up") { confirmOrphans = true }
                        .controlSize(.small)
                        .disabled(hub.cleaningOrphans)
                }
            }
        }
        .confirmationDialog("Remove leftover artwork?", isPresented: $confirmOrphans) {
            Button("Remove \(hub.orphanMedia.count) images and \(hub.orphanEntries.count) entries", role: .destructive) { Task { await hub.cleanOrphans() } }
        } message: {
            Text("Frees \(mediaBytes.bytesText). Rescan in Cocoon afterwards.")
        }
    }

    @ViewBuilder
    private var shrinkSection: some View {
        if !hub.shrinkCandidates.isEmpty || !hub.shrunk.isEmpty {
            let selected = hub.shrinkCandidates.filter { hub.shrinkSelection.contains($0.id) }
            let savings = (selected.isEmpty ? hub.shrinkCandidates : selected).reduce(0) { $0 + $1.estimatedSavings }
            SectionHeader(title: "Shrink games", symbol: "arrow.down.right.and.arrow.up.left", trailing: "≈ \(savings.bytesText)")
            Card {
                Text("Disc images become CHD, cartridge ROMs become ZIP. Each is converted on your Mac, checked, then sent back, and emulators play both directly. Multi-track games, playlists and Cocoon entries are handled for you.").font(.caption).foregroundStyle(.secondary)
                if !hub.shrunk.isEmpty {
                    HStack {
                        Label("\(hub.shrunk.count) original\(hub.shrunk.count == 1 ? "" : "s") still on the Thor", systemImage: "doc.on.doc").font(.caption)
                        Spacer()
                        Button("Remove…") { hub.askRemoveOriginals = true }.controlSize(.small)
                    }
                }
                if !hub.shrinkCandidates.isEmpty {
                    HStack {
                        Button(selected.count == hub.shrinkCandidates.count ? "Select None" : "Select All") {
                            hub.shrinkSelection = selected.count == hub.shrinkCandidates.count ? [] : Set(hub.shrinkCandidates.map(\.id))
                        }
                        .buttonStyle(.link).font(.caption)
                        Spacer()
                        Button(selected.isEmpty ? "Shrink" : "Shrink \(selected.count)") { hub.shrinkSelected() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(selected.isEmpty)
                    }
                    ForEach(hub.shrinkCandidates) { candidate in
                        Toggle(isOn: Binding(get: { hub.shrinkSelection.contains(candidate.id) }, set: { on in
                            if on { hub.shrinkSelection.insert(candidate.id) } else { hub.shrinkSelection.remove(candidate.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.name).font(.callout).lineLimit(1).truncationMode(.middle)
                                Text("\(Systems.name(for: candidate.system))\(candidate.trackCount > 1 ? " · \(candidate.trackCount) tracks" : "") · \(candidate.size.bytesText) → saves ≈ \(candidate.estimatedSavings.bytesText)")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    Toggle("Remove originals automatically once the CHD is checked", isOn: Binding(get: { hub.removeOriginalsAfterShrink }, set: { hub.removeOriginalsAfterShrink = $0 }))
                        .toggleStyle(.checkbox).font(.caption)
                }
            }
        }
    }
}

struct ImportSheet: View {
    @ObservedObject var hub: EmulationHub

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(hub.importItems.count == 1 ? "Import 1 ROM" : "Import \(hub.importItems.count) ROMs").font(.title3.weight(.semibold))
                Text("Pick the system for each game. It goes straight into that system’s folder on your Thor.").font(.callout).foregroundStyle(.secondary)
                if hub.importItems.count > 1 {
                    Picker("Set all to", selection: Binding(
                        get: {
                            let systems = Set(hub.importItems.map(\.system))
                            guard systems.count == 1, let only = systems.first, hub.installedSystems.contains(only) else { return "mixed" }
                            return only
                        },
                        set: { system in
                            guard system != "mixed" else { return }
                            for i in hub.importItems.indices { hub.importItems[i].system = system }
                        })) {
                        Text("Each its own").tag("mixed")
                        ForEach(hub.installedSystems, id: \.self) { Text(Systems.name(for: $0)).tag($0) }
                    }
                    .frame(maxWidth: 300)
                    .padding(.top, 6)
                }
            }
            .padding(18)
            Divider().opacity(0.5)
            List {
                ForEach($hub.importItems) { $item in
                    HStack(spacing: 10) {
                        Image(systemName: "gamecontroller").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text(item.system == "unsorted" ? item.size.bytesText : "\(item.size.bytesText) → \(hub.targetFolder(for: item.system))").font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Picker("System", selection: $item.system) {
                            ForEach(hub.installedSystems, id: \.self) { Text(Systems.name(for: $0)).tag($0) }
                            if item.system == "unsorted" { Text("Choose a system").tag("unsorted") }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)
            Divider().opacity(0.5)
            HStack {
                Text(hub.importItems.reduce(0) { $0 + $1.size }.bytesText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { hub.importItems = [] }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { Task { await hub.performImport() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(hub.importItems.contains { $0.system == "unsorted" })
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        .frame(width: 620, height: 440)
    }
}

struct ImportSheetPresenter: ViewModifier {
    @ObservedObject var hub: EmulationHub

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { !hub.importItems.isEmpty }, set: { if !$0 { hub.importItems = [] } })) {
            ImportSheet(hub: hub)
        }
    }
}
