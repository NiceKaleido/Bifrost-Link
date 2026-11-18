import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case files, apps, library, ports, playtime, performance, saves, cleanup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "Files"
        case .apps: return "Apps"
        case .library: return "Library"
        case .ports: return "Ports"
        case .playtime: return "Play Time"
        case .performance: return "Performance"
        case .saves: return "Saves"
        case .cleanup: return "Cleanup"
        }
    }

    var headline: String {
        switch self {
        case .files: return "Files on your \(DeviceInfo.name)"
        case .apps: return "Installed Apps"
        case .library: return "Game Library"
        case .ports: return "Native Ports"
        case .playtime: return "Play Time"
        case .performance: return "Performance"
        case .saves: return "Save Backups"
        case .cleanup: return "Cleanup"
        }
    }

    var subtitle: String {
        switch self {
        case .files: return "Browse internal storage and the SD card, copy files both ways."
        case .apps: return "Everything you installed, biggest first. Open, clean up, back up or remove apps."
        case .library: return "Import games, check your collection and make room."
        case .ports: return "Android versions of classic games, rated by \(DeviceInfo.name) owners."
        case .playtime: return "How long you play, on the \(DeviceInfo.name) and while docked."
        case .performance: return "Live frame rate, load, memory and temperatures from your \(DeviceInfo.name)."
        case .saves: return "Copies of your emulator saves and settings on this Mac."
        case .cleanup: return "Free up space that emulators leave behind."
        }
    }

    var symbol: String {
        switch self {
        case .files: return "folder.fill"
        case .apps: return "square.grid.2x2.fill"
        case .library: return "books.vertical.fill"
        case .ports: return "shippingbox.fill"
        case .playtime: return "timer"
        case .performance: return "gauge.with.dots.needle.67percent"
        case .saves: return "clock.arrow.circlepath"
        case .cleanup: return "sparkles"
        }
    }

    static let groups: [[InspectorTab]] = [[.files, .apps], [.library, .ports, .playtime, .performance], [.saves, .cleanup]]
}

struct InspectorView: View {
    @ObservedObject var manager: DeviceManager
    @ObservedObject var settings: LinkSettings
    @AppStorage("inspectorTab") private var tab: InspectorTab = .files

    var body: some View {
        HStack(spacing: 0) {
            SectionRail(selection: $tab, ports: manager.ports)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            VStack(spacing: 0) {
                PanelHeader(tab: tab) { headerActions }
                Divider().opacity(0.6)
                Group {
                    switch tab {
                    case .files: FileBrowserView(files: manager.files, settings: settings)
                    case .apps: AppsPanel(apps: manager.apps)
                    case .library: LibraryView(hub: manager.emulation, files: manager.files, updater: manager.updater, ports: manager.ports)
                    case .ports: PortsPanel(catalog: manager.ports, manager: manager, settings: settings)
                    case .playtime: PlayTimeView(stats: manager.stats, cocoon: manager.cocoon)
                    case .performance: PerformanceView(monitor: manager.monitor, manager: manager)
                    case .saves: SavesView(backups: manager.backups, settings: settings)
                    case .cleanup: CleanupView(cleanup: manager.cleanup)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                ActivityPanel(files: manager.files, hub: manager.emulation, ports: manager.ports)
            }
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        switch tab {
        case .files: FilesHeaderActions(files: manager.files)
        case .apps: AppsHeaderActions(apps: manager.apps)
        case .library: LibraryHeaderActions(hub: manager.emulation)
        case .ports: PortsHeaderActions(catalog: manager.ports)
        case .playtime: PlayTimeHeaderActions(stats: manager.stats)
        case .performance: PerformanceHeaderActions(settings: settings)
        case .saves: SavesHeaderActions(backups: manager.backups)
        case .cleanup: CleanupHeaderActions(cleanup: manager.cleanup)
        }
    }
}

struct SectionRail: View {
    @Binding var selection: InspectorTab
    @ObservedObject var ports: PortCatalog

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(InspectorTab.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Rectangle().fill(Theme.hairline).frame(width: 36, height: 1).padding(.vertical, 6)
                }
                ForEach(group) { tab in
                    RailButton(tab: tab, selected: selection == tab, badge: tab == .ports ? ports.updates.count : 0) {
                        withAnimation(.easeOut(duration: 0.15)) { selection = tab }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .padding(.horizontal, 6)
        .frame(width: 76)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.12))
    }
}

struct RailButton: View {
    let tab: InspectorTab
    let selected: Bool
    var badge = 0
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .frame(height: 20)
                Text(tab.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            .frame(width: 64, height: 52)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.16) : (hovering ? Theme.panel : .clear))
            }
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Theme.accent, in: Capsule())
                        .offset(x: -6, y: 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tab.subtitle)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct PanelHeader<Actions: View>: View {
    let tab: InspectorTab
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.headline).font(.title3.weight(.semibold))
                Text(tab.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actions.controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

struct FilesHeaderActions: View {
    @ObservedObject var files: FileService

    var body: some View {
        Button { Task { await files.loadVolumes(); await files.reload(); await files.loadSpace() } } label: {
            if files.loading { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
        }
        .help("Refresh")
    }
}

struct AppsHeaderActions: View {
    @ObservedObject var apps: AppManager

    var body: some View {
        Button { Task { await apps.refresh() } } label: {
            if apps.loading { ProgressView().controlSize(.mini) } else { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .disabled(apps.loading || apps.serial == nil)
    }
}

struct LibraryHeaderActions: View {
    @ObservedObject var hub: EmulationHub

    var body: some View {
        if hub.lastScan != nil || hub.scanning {
            Button { Task { await hub.scan() } } label: {
                if hub.scanning { ProgressView().controlSize(.mini) } else { Label("Rescan", systemImage: "arrow.clockwise") }
            }
            .disabled(hub.scanning)
            .help(hub.lastScan.map { "Last checked \($0.formatted(.relative(presentation: .named)))" } ?? "Checking…")
        }
    }
}

struct PortsHeaderActions: View {
    @ObservedObject var catalog: PortCatalog

    var body: some View {
        Button {
            Task {
                await catalog.refresh(force: true)
                await catalog.detectInstalled()
                if catalog.libraryMatchedAt != nil { await catalog.scanLibraryMatches() }
            }
        } label: {
            if catalog.loading || catalog.detecting || catalog.matchingLibrary { ProgressView().controlSize(.mini) } else { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .disabled(catalog.loading || catalog.detecting)
        .help("Load the latest catalog and check the \(DeviceInfo.name) again")
    }
}

struct PerformanceHeaderActions: View {
    @ObservedObject var settings: LinkSettings

    var body: some View {
        Toggle(isOn: $settings.statsOverlay) {
            Label("Overlay", systemImage: settings.statsOverlay ? "rectangle.inset.topleft.filled" : "rectangle.dashed")
        }
        .toggleStyle(.button)
        .help(settings.statsOverlay ? "Hide the stats overlay on the stream" : "Show live stats over the stream")
    }
}

struct PlayTimeHeaderActions: View {
    @ObservedObject var stats: PlayStats

    var body: some View {
        Button { Task { await stats.refreshCocoon() } } label: {
            if stats.refreshing { ProgressView().controlSize(.mini) } else { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .disabled(stats.serial == nil || stats.refreshing)
        .help(stats.cocoonUpdated.map { "Cocoon’s play time was read \($0.formatted(.relative(presentation: .named)))" } ?? "Read play time from Cocoon")
    }
}

struct SavesHeaderActions: View {
    @ObservedObject var backups: SaveBackupService

    var body: some View {
        Button { Task { await backups.backup() } } label: {
            Label(backups.running ? "Working…" : "Back Up Now", systemImage: "arrow.down.to.line")
        }
        .buttonStyle(.borderedProminent)
        .disabled(backups.running || backups.serial == nil)
    }
}

struct CleanupHeaderActions: View {
    @ObservedObject var cleanup: CleanupService

    var body: some View {
        if !cleanup.usage.isEmpty {
            Button { Task { await cleanup.scan() } } label: {
                if cleanup.scanning { ProgressView().controlSize(.mini) } else { Label("Measure", systemImage: "arrow.clockwise") }
            }
            .disabled(cleanup.scanning || cleanup.working != nil)
            .help("Measure again")
        }
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
    @ObservedObject var ports: PortCatalog
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
            Text("The CHD versions are on your \(DeviceInfo.name) and checked. Removing the originals frees \(original.bytesText) and saves \(saved.bytesText) overall. Playlists and Cocoon entries are pointed at the new files.")
        }
    }

    private var importZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down.on.square").font(.title2).foregroundStyle(Theme.bifrost)
            Text("Drop ROMs here").font(.callout.weight(.semibold))
            Text("They’re sorted into the right system folder automatically.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Choose Files…") { pick() }
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
                await MainActor.run { hub.prepareImport(urls) }
            }
            return true
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose ROMs to send to the \(DeviceInfo.name)"
        if panel.runModal() == .OK { hub.prepareImport(panel.urls) }
    }

    private func checkAll() {
        Task {
            await ports.refresh()
            updater.excludedPackages = ports.packages
            await updater.check()
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        let available = updater.apps.filter(\.updateAvailable).count
        let anything = !updater.apps.isEmpty
        SectionHeader(title: "App updates", symbol: "arrow.down.app", trailing: anything ? (available == 0 ? "up to date" : "\(available) available") : nil)
        Card {
            if !anything {
                HStack {
                    Text("Checks emulators and apps you installed outside the Play Store against their GitHub releases. Native ports are updated in the Ports section.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(updater.checking ? "Checking…" : "Check") { checkAll() }
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
                    Button { checkAll() } label: {
                        if updater.checking { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                    }
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
                Label(hub.cocoonRoot == nil ? "This check tidies up Cocoon’s game artwork. Cocoon isn’t installed, so there’s nothing to check." : "Every scraped image and entry still belongs to a game on your \(DeviceInfo.name).", systemImage: hub.cocoonRoot == nil ? "info.circle" : "hand.thumbsup")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("\(hub.orphanMedia.count) images and \(hub.orphanEntries.count) Cocoon entries belong to games that are no longer on the \(DeviceInfo.name).")
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
                        Label("\(hub.shrunk.count) original\(hub.shrunk.count == 1 ? "" : "s") still on the \(DeviceInfo.name)", systemImage: "doc.on.doc").font(.caption)
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
    @State private var thorPickerFor: URL?

    private var visibleItems: [Binding<ImportItem>] {
        $hub.importItems.filter { hub.importOriginals || !hub.isOriginalOnlyForPatch($0.wrappedValue) }
    }

    private var sending: [ImportItem] {
        hub.importItems.filter { hub.importOriginals || !hub.isOriginalOnlyForPatch($0) }
    }

    private var hasOriginals: Bool { hub.importItems.contains(where: hub.isOriginalOnlyForPatch) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text(hub.importItems.contains { $0.patch != nil } || !hub.unpairedPatches.isEmpty
                     ? "Patches are applied on this Mac, then the patched game goes straight into its system’s folder on your \(DeviceInfo.name)."
                     : "Pick the system for each game. It goes straight into that system’s folder on your \(DeviceInfo.name).")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    if sending.count > 1 {
                        Picker("Set all to", selection: Binding(
                            get: {
                                let systems = Set(sending.map(\.system))
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
                    }
                    if hasOriginals {
                        Toggle("Also send the unpatched originals", isOn: $hub.importOriginals)
                            .toggleStyle(.checkbox)
                    }
                }
                .padding(.top, 6)
            }
            .padding(18)
            Divider().opacity(0.5)
            List {
                if !hub.unpairedPatches.isEmpty {
                    Section("Patches waiting for their game") {
                        ForEach(hub.unpairedPatches, id: \.self) { patch in
                            HStack(spacing: 10) {
                                Image(systemName: "bandage").foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(patch.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Text("Choose the game this patch is for").font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Button("On This Mac…") { chooseLocal(for: patch) }
                                Button("On the \(DeviceInfo.name)…") { thorPickerFor = patch }
                                    .disabled(hub.serial == nil)
                            }
                            .controlSize(.small)
                            .padding(.vertical, 2)
                        }
                    }
                }
                ForEach(visibleItems) { $item in
                    HStack(spacing: 10) {
                        Image(systemName: item.patch != nil ? "bandage.fill" : "gamecontroller")
                            .foregroundStyle(item.patch != nil ? AnyShapeStyle(Theme.bifrost) : AnyShapeStyle(Theme.accent))
                        VStack(alignment: .leading, spacing: 1) {
                            if item.patch != nil {
                                TextField("Name", text: $item.outputName).textFieldStyle(.plain)
                                Text("\(item.patch?.lastPathComponent ?? "") + \(item.remoteSource.map { "Thor: " + ($0 as NSString).lastPathComponent } ?? item.url.lastPathComponent)")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            } else {
                                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            }
                            Text(item.system == "unsorted" ? item.size.bytesText : "\(item.patch != nil ? "≈ " : "")\(item.size.bytesText) → \(item.remoteSource.map { ($0 as NSString).deletingLastPathComponent } ?? hub.targetFolder(for: item.system))").font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Picker("System", selection: $item.system) {
                            ForEach(hub.installedSystems, id: \.self) { Text(Systems.name(for: $0)).tag($0) }
                            if item.system == "unsorted" { Text("Choose a system").tag("unsorted") }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                        .disabled(item.remoteSource != nil)
                        .help(item.remoteSource != nil ? "Goes next to the original on the \(DeviceInfo.name)" : "")
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)
            Divider().opacity(0.5)
            HStack {
                if let pairing = hub.pairing {
                    ProgressView().controlSize(.small)
                    Text(pairing).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(sending.reduce(0) { $0 + $1.size }.bytesText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    hub.importItems = []
                    hub.unpairedPatches = []
                }
                .keyboardShortcut(.cancelAction)
                Button(sending.contains { $0.patch != nil } ? "Patch & Import" : "Import") { Task { await hub.performImport() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending.isEmpty || hub.pairing != nil || sending.contains { $0.system == "unsorted" } || sending.contains { $0.patch != nil && $0.outputName.trimmingCharacters(in: .whitespaces).isEmpty })
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        .frame(width: 640, height: 460)
        .sheet(item: Binding(get: { thorPickerFor.map(PatchTarget.init) }, set: { thorPickerFor = $0?.patch })) { target in
            ThorRomPicker(hub: hub, patch: target.patch) { thorPickerFor = nil }
        }
    }

    private var title: String {
        let patched = hub.importItems.filter { $0.patch != nil }.count + hub.unpairedPatches.count
        let plain = sending.filter { $0.patch == nil }.count
        if patched == 0 { return plain == 1 ? "Import 1 ROM" : "Import \(plain) ROMs" }
        if plain == 0 { return patched == 1 ? "Patch 1 Game" : "Patch \(patched) Games" }
        return "Patch \(patched) & Import \(plain)"
    }

    private func chooseLocal(for patch: URL) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the game “\(patch.lastPathComponent)” is for"
        panel.directoryURL = patch.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { hub.pair(patch, withLocal: url) }
    }
}

struct PatchTarget: Identifiable {
    let patch: URL
    var id: URL { patch }
}

struct ThorRomPicker: View {
    @ObservedObject var hub: EmulationHub
    let patch: URL
    let done: () -> Void
    @State private var roms: [String] = []
    @State private var loading = true
    @State private var query = ""
    @State private var selection: String?

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? roms : roms.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which game is “\(patch.lastPathComponent)” for?").font(.headline)
            TextField("Search your games", text: $query).textFieldStyle(.roundedBorder)
            if loading {
                ProgressView("Listing games on the \(DeviceInfo.name)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered, id: \.self, selection: $selection) { path in
                    VStack(alignment: .leading, spacing: 1) {
                        Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text((path as NSString).deletingLastPathComponent).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    }
                    .tag(path)
                }
                .listStyle(.inset)
            }
            HStack {
                Text("The game is copied to this Mac, patched, and the patched copy goes next to the original.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Use This Game") {
                    guard let selection else { return }
                    done()
                    Task { await hub.pair(patch, withRemote: selection) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(18)
        .frame(width: 560, height: 480)
        .task {
            roms = await hub.thorRoms()
            loading = false
        }
    }
}

struct ImportSheetPresenter: ViewModifier {
    @ObservedObject var hub: EmulationHub

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { !hub.importItems.isEmpty || !hub.unpairedPatches.isEmpty }, set: { if !$0 { hub.importItems = []; hub.unpairedPatches = [] } })) {
            ImportSheet(hub: hub)
        }
    }
}
