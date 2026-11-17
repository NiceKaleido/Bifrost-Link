import SwiftUI

enum SavesConfirm: Identifiable {
    case restoreAll(SaveSnapshot)
    case restore(SaveSnapshot, String)
    case delete(SaveSnapshot)

    var id: String {
        switch self {
        case .restoreAll(let s): return "all-\(s.url.path)"
        case .restore(let s, let e): return "one-\(s.url.path)-\(e)"
        case .delete(let s): return "delete-\(s.url.path)"
        }
    }
}

struct SavesView: View {
    @ObservedObject var backups: SaveBackupService
    @ObservedObject var settings: LinkSettings
    @State private var expanded: Set<URL> = []
    @State private var details: [URL: [SnapshotGroup]] = [:]
    @State private var addingFolder = false
    @State private var confirm: SavesConfirm?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                sourcesSection
                snapshotsSection
            }
            .padding(12)
        }
        .task(id: backups.serial) {
            if backups.serial != nil && backups.sources.isEmpty { await backups.scanSources() }
        }
        .onChange(of: settings.customSaveFolders) { _, _ in Task { await backups.scanSources() } }
        .onChange(of: backups.snapshots) { _, list in
            let urls = Set(list.map(\.url))
            details = details.filter { urls.contains($0.key) }
            expanded = expanded.intersection(urls)
        }
        .sheet(isPresented: $addingFolder) { AddSaveFolderSheet(backups: backups, settings: settings) }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { item in
            switch item {
            case .restoreAll(let snapshot):
                Button("Restore Everything", role: .destructive) { Task { await backups.restore(snapshot) } }
            case .restore(let snapshot, let emulator):
                Button("Restore \(emulator)", role: .destructive) { Task { await backups.restore(snapshot, emulators: [emulator]) } }
            case .delete(let snapshot):
                Button("Delete Backup", role: .destructive) { backups.delete(snapshot) }
            }
        } message: { item in
            switch item {
            case .restoreAll(let snapshot):
                Text("\(snapshot.emulators.joined(separator: ", ")) will be closed on the Thor and their saves replaced with the ones from this backup. Your current saves are backed up first as “Before restore”.")
            case .restore(_, let emulator):
                Text("\(emulator) will be closed on the Thor and its saves replaced with the ones from this backup. Your current saves are backed up first as “Before restore”.")
            case .delete(let snapshot):
                Text("The backup from \(snapshot.date.formatted(date: .abbreviated, time: .shortened)) (\(snapshot.bytes.bytesText)) is removed from this Mac. Nothing changes on the Thor.")
            }
        }
    }

    private var confirmTitle: String {
        switch confirm {
        case .restoreAll: return "Restore everything from this backup?"
        case .restore(_, let emulator): return "Restore \(emulator) saves?"
        case .delete: return "Delete this backup?"
        case nil: return ""
        }
    }

    private var header: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "externaldrive.badge.checkmark").font(.title2).foregroundStyle(Theme.bifrost)
                VStack(alignment: .leading, spacing: 3) {
                    Text(lastBackupText).font(.callout.weight(.semibold))
                    Text(backups.snapshots.isEmpty ? "Saves, states and emulator settings are copied to this Mac." : "\(backups.snapshots.count) \(backups.snapshots.count == 1 ? "backup" : "backups") · \(backups.totalBytes.bytesText) on this Mac")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Show Backups in Finder") {
                try? FileManager.default.createDirectory(at: backups.root, withIntermediateDirectories: true)
                NSWorkspace.shared.open(backups.root)
            }
            .controlSize(.small)
            if let progress = backups.progress {
                VStack(alignment: .leading, spacing: 3) {
                    if let fraction = backups.fraction {
                        ProgressView(value: fraction).controlSize(.mini).tint(Theme.accent)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.mini)
                    }
                    Text(progress).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if !backups.locked.isEmpty {
                Label("\(backups.locked.joined(separator: ", ")) stores its saves privately, so they can’t be copied over USB. Use the emulator’s own export for those.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider().opacity(0.5)
            Toggle("Back up automatically once a day when the Thor links", isOn: $settings.autoSaveBackup)
                .toggleStyle(.switch).controlSize(.small).font(.caption)
            HStack {
                Text("Keep").font(.caption)
                Picker("Keep", selection: $settings.saveBackupKeep) {
                    ForEach([3, 5, 10, 20, 50], id: \.self) { Text("the last \($0) backups").tag($0) }
                    Text("every backup").tag(0)
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Spacer()
            }
            Text(settings.saveBackupKeep == 0 ? "Nothing is replaced. Delete old backups yourself when they pile up." : "Once there are more, the oldest are replaced by new ones. Pinned backups are never replaced.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            let found = backups.sources.filter(\.found)
            let custom = backups.sources.filter { $0.custom && !$0.found }
            let missing = backups.sources.filter { !$0.custom && !$0.found }
            let included = found.filter { settings.isSaveSourceIncluded($0.key) }
            SectionHeader(title: "What gets backed up", symbol: "checklist",
                          trailing: found.isEmpty ? nil : "\(included.reduce(Int64(0)) { $0 + $1.bytes }.bytesText) on the Thor")
            Card {
                if backups.sources.isEmpty {
                    HStack(spacing: 8) {
                        if backups.scanningSources { ProgressView().controlSize(.small) }
                        Text(backups.scanningSources ? "Looking for saves on the Thor…" : backups.serial == nil ? "Link the Thor to see what’s there." : "Nothing found yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(found + custom) { source in sourceRow(source) }
                    if !missing.isEmpty {
                        Text("Not found on this Thor: \(missing.map(\.name).joined(separator: ", "))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Divider().opacity(0.5)
                HStack {
                    Button { addingFolder = true } label: { Label("Add Folder…", systemImage: "folder.badge.plus") }
                    Spacer()
                    Button { Task { await backups.scanSources() } } label: {
                        if backups.scanningSources { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .buttonStyle(.borderless)
                    .help("Look again")
                    .disabled(backups.serial == nil || backups.scanningSources)
                }
                .controlSize(.small)
                Text("Missing a game? Add the folder where its emulator keeps saves, or right-click a folder in Files and choose Back Up With Saves.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func sourceRow(_ source: SaveSource) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { settings.isSaveSourceIncluded(source.key) }, set: { settings.setSaveSource(source.key, included: $0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(source.name).font(.caption.weight(.medium))
                        if source.custom {
                            Text("Your folder").font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.panel, in: Capsule())
                        }
                    }
                    Text(source.found ? "\(source.bytes.bytesText) · \(source.paths.count == 1 ? shortPath(source.paths[0]) : "\(source.paths.count) locations")" : "Folder not found on the Thor")
                        .font(.caption2).foregroundStyle(source.found ? .secondary : Color.orange).lineLimit(1).truncationMode(.middle)
                }
            }
            .toggleStyle(.checkbox)
            .help(source.paths.isEmpty ? source.key : source.paths.joined(separator: "\n"))
            Spacer(minLength: 4)
            if source.custom {
                Button { settings.removeCustomSaveFolder(source.key) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Stop backing up this folder")
                    .accessibilityLabel("Remove \(source.name)")
            }
        }
    }

    private func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: "/sdcard/Android/data/", with: "…/").replacingOccurrences(of: "/sdcard/", with: "Internal/")
    }

    private var snapshotsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Backups", symbol: "clock.arrow.circlepath", trailing: backups.snapshots.isEmpty ? nil : "\(backups.snapshots.count)")
            if backups.snapshots.isEmpty {
                ContentUnavailableView("No backups yet", systemImage: "tray", description: Text("Your first backup is one click away."))
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(backups.snapshots) { snapshot in snapshotCard(snapshot) }
            }
        }
    }

    private func snapshotCard(_ snapshot: SaveSnapshot) -> some View {
        let open = expanded.contains(snapshot.url)
        return Card {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if open { expanded.remove(snapshot.url) } else { expanded.insert(snapshot.url) }
                    }
                    if !open && details[snapshot.url] == nil {
                        Task { details[snapshot.url] = await SaveBackupService.details(for: snapshot) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(snapshot.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                                    .font(.callout.weight(.medium))
                                if snapshot.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Theme.accent) }
                            }
                            HStack(spacing: 5) {
                                badge(snapshot.label)
                                Text("\(snapshot.bytes.bytesText) · \(snapshot.emulators.count == 1 ? snapshot.emulators[0] : "\(snapshot.emulators.count) sources")")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                Menu {
                    Button("Restore Everything…") { confirm = .restoreAll(snapshot) }
                    Menu("Restore Only") {
                        ForEach(snapshot.emulators, id: \.self) { emulator in
                            Button(emulator) { confirm = .restore(snapshot, emulator) }
                        }
                    }
                    Divider()
                    Button(snapshot.pinned ? "Unpin" : "Pin, Never Replace") { backups.setPinned(snapshot, !snapshot.pinned) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([snapshot.url]) }
                    Divider()
                    Button("Delete…", role: .destructive) { confirm = .delete(snapshot) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(backups.running)
            }
            if open {
                if let groups = details[snapshot.url] {
                    ForEach(groups) { group in
                        SnapshotGroupView(group: group, busy: backups.running || backups.serial == nil) {
                            confirm = .restore(snapshot, group.emulator)
                        }
                    }
                    Button { confirm = .restoreAll(snapshot) } label: {
                        Label("Restore Everything", systemImage: "arrow.uturn.backward")
                    }
                    .controlSize(.small)
                    .disabled(backups.running || backups.serial == nil)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(text == "Manual" ? Theme.accent : .secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Theme.panel, in: Capsule())
    }

    private var lastBackupText: String {
        guard let last = backups.snapshots.first else { return "No backups yet" }
        return "Last backup " + last.date.formatted(.relative(presentation: .named))
    }
}

struct SnapshotGroupView: View {
    let group: SnapshotGroup
    let busy: Bool
    let restore: () -> Void
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(group.emulator).font(.caption.weight(.semibold))
                Text("\(group.items.count) \(group.items.count == 1 ? "item" : "items") · \(group.bytes.bytesText)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Restore…", action: restore)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(busy)
            }
            .help(group.locations.joined(separator: "\n"))
            let visible = showAll ? group.items : Array(group.items.prefix(6))
            ForEach(visible) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.isFolder ? "folder" : "doc")
                        .font(.caption2).foregroundStyle(.tertiary).frame(width: 12)
                    Text(item.name).font(.caption2).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let modified = item.modified {
                        Text(modified.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(item.bytes.bytesText).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(minWidth: 52, alignment: .trailing)
                }
            }
            if group.items.count > 6 {
                Button(showAll ? "Show less" : "Show all \(group.items.count)") { showAll.toggle() }
                    .buttonStyle(.borderless).font(.caption2)
            }
        }
        .padding(8)
        .background(Theme.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct AddSaveFolderSheet: View {
    @ObservedObject var backups: SaveBackupService
    @ObservedObject var settings: LinkSettings
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var path = "/sdcard/"
    @State private var checking = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a save folder").font(.headline)
            Text("Everything inside this folder on the Thor is copied with every backup and can be restored like the rest.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Citra saves"))
                TextField("Folder on the Thor", text: $path, prompt: Text("/sdcard/…"))
                    .font(.body.monospaced())
            }
            .formStyle(.columns)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { await add() }
                } label: {
                    if checking { ProgressView().controlSize(.small) } else { Text("Add Folder") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.trimmingCharacters(in: .whitespaces).count < 2 || checking)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func add() async {
        let clean = path.trimmingCharacters(in: .whitespaces)
        if settings.customSaveFolders.contains(where: { $0.path == clean }) {
            problem = "That folder is already on the list."
            return
        }
        checking = true
        let exists = await backups.checkFolder(clean)
        checking = false
        guard exists || backups.serial == nil else {
            problem = "There’s no folder at that path on the Thor. Check the spelling, paths are case sensitive."
            return
        }
        settings.addCustomSaveFolder(clean, name: name)
        dismiss()
    }
}

struct CleanupView: View {
    @ObservedObject var cleanup: CleanupService
    @State private var expanded: Set<String> = []
    @State private var confirm = false

    private var selectedItems: [CleanupItem] {
        cleanup.usage.flatMap(\.items).filter { cleanup.selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if cleanup.usage.isEmpty {
                        Spacer(minLength: 10)
                        if cleanup.scanning {
                            ProgressView("Measuring emulator data…").frame(maxWidth: .infinity)
                        } else {
                            ContentUnavailableView {
                                Label("Emulator cleanup", systemImage: "sparkles")
                            } description: {
                                Text("Find shader caches, logs, dumps and old saves that pile up over time.")
                            } actions: {
                                Button("Measure") { Task { await cleanup.scan() } }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(cleanup.serial == nil)
                            }
                            .frame(maxWidth: .infinity)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 10)
                    } else {
                        ForEach(cleanup.usage) { usage in emulatorCard(usage) }
                    }
                }
                .padding(12)
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
            }
            if !cleanup.usage.isEmpty {
                Divider().opacity(0.5)
                HStack {
                    if let working = cleanup.working {
                        ProgressView().controlSize(.mini)
                        Text(working).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(selectedItems.isEmpty ? "Nothing selected" : "\(selectedItems.count) selected · \(selectedItems.reduce(0) { $0 + $1.bytes }.bytesText)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clean Selected") { confirm = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedItems.isEmpty || cleanup.working != nil)
                }
                .padding(12)
            }
        }
        .confirmationDialog("Clean \(selectedItems.count) item(s)?", isPresented: $confirm) {
            Button("Clean \(selectedItems.reduce(0) { $0 + $1.bytes }.bytesText)", role: .destructive) {
                let items = selectedItems
                Task { _ = await cleanup.clean(items) }
            }
        } message: {
            let saves = selectedItems.filter { $0.category.perGame }.count
            Text(saves > 0 ? "\(saves) save/state item(s) are backed up to your Mac first. The emulators are closed on the Thor while cleaning." : "Caches rebuild themselves; the emulators are closed on the Thor while cleaning.")
        }
    }

    private func emulatorCard(_ usage: EmulatorUsage) -> some View {
        Card {
            HStack {
                Text(usage.profile.name).font(.headline)
                Spacer()
                Text(usage.byCategory.values.reduce(0, +).bytesText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(EmulatorProfile.Category.allCases) { category in
                if let bytes = usage.byCategory[category], bytes > 0 {
                    categoryRow(usage, category, bytes)
                }
            }
        }
    }

    @ViewBuilder
    private func categoryRow(_ usage: EmulatorUsage, _ category: EmulatorProfile.Category, _ bytes: Int64) -> some View {
        let items = usage.items.filter { $0.category == category }
        let key = usage.id + category.rawValue
        let selectable = category != .mods && !items.isEmpty
        let allSelected = selectable && items.allSatisfy { cleanup.selection.contains($0.id) }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if selectable && !category.perGame {
                    Toggle("", isOn: Binding(get: { allSelected }, set: { on in
                        if on { cleanup.selection.formUnion(items.map(\.id)) } else { cleanup.selection.subtract(items.map(\.id)) }
                    }))
                    .labelsHidden().toggleStyle(.checkbox)
                } else {
                    Image(systemName: category.symbol).foregroundStyle(.secondary).frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(category.title).font(.callout)
                    Text(category.note).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Text(bytes.bytesText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if category.perGame {
                    Button {
                        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
                    } label: {
                        Image(systemName: expanded.contains(key) ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .help("Choose games")
                }
            }
            if category.perGame && expanded.contains(key) {
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        if item.locked {
                            Image(systemName: "lock").font(.caption2).foregroundStyle(.tertiary).frame(width: 14)
                                .help("Stored privately by the emulator, can’t be changed over USB")
                        } else {
                            Toggle("", isOn: Binding(get: { cleanup.selection.contains(item.id) }, set: { on in
                                if on { cleanup.selection.insert(item.id) } else { cleanup.selection.remove(item.id) }
                            }))
                            .labelsHidden().toggleStyle(.checkbox)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.caption).lineLimit(1).truncationMode(.middle)
                            if let date = item.modified {
                                Text("last used " + date.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Text(item.bytes.bytesText).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 24)
                }
            }
        }
    }
}
