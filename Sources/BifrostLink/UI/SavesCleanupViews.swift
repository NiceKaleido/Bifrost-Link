import SwiftUI

struct SavesView: View {
    @ObservedObject var backups: SaveBackupService
    @ObservedObject var settings: LinkSettings
    @State private var restoreTarget: (SaveSnapshot, String)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Card {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "externaldrive.badge.checkmark").font(.title2).foregroundStyle(Theme.bifrost)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(lastBackupText).font(.callout.weight(.semibold))
                            Text("Saves and states from RetroArch, PPSSPP, Dolphin, DuckStation, Eden, Azahar, melonDS and ARMSX2.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button {
                            Task { await backups.backup() }
                        } label: {
                            Label(backups.running ? "Backing up…" : "Back Up Now", systemImage: "arrow.down.to.line")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(backups.running || backups.serial == nil)
                        Button("Show in Finder") {
                            try? FileManager.default.createDirectory(at: backups.root, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(backups.root)
                        }
                    }
                    .controlSize(.small)
                    if let progress = backups.progress {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(progress).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !backups.locked.isEmpty {
                        Label("\(backups.locked.joined(separator: ", ")) stores its saves privately, so they can’t be copied over USB. Use the emulator’s own export for those.", systemImage: "lock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Back up automatically once a day when the Thor links", isOn: $settings.autoSaveBackup)
                        .toggleStyle(.switch).controlSize(.small).font(.caption)
                }

                SectionHeader(title: "Snapshots", symbol: "clock.arrow.circlepath", trailing: backups.snapshots.isEmpty ? nil : "\(backups.snapshots.count)")
                if backups.snapshots.isEmpty {
                    ContentUnavailableView("No backups yet", systemImage: "tray", description: Text("Your first backup is one click away."))
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(backups.snapshots) { snapshot in
                        Card {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(snapshot.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                                    Text("\(snapshot.bytes.bytesText) · \(snapshot.emulators.joined(separator: ", "))").font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                                }
                                Spacer()
                                Menu {
                                    ForEach(snapshot.emulators, id: \.self) { emulator in
                                        Button("Restore \(emulator)…") { restoreTarget = (snapshot, emulator) }
                                    }
                                    Divider()
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([snapshot.url]) }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .disabled(backups.running)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .confirmationDialog(restoreTarget.map { "Restore \($0.1) saves?" } ?? "", isPresented: Binding(get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } })) {
            if let target = restoreTarget {
                Button("Restore", role: .destructive) { Task { await backups.restore(target.0, emulator: target.1) } }
            }
        } message: {
            Text("\(restoreTarget?.1 ?? "The emulator") will be closed on the Thor and its saves replaced with the ones from this snapshot.")
        }
    }

    private var lastBackupText: String {
        guard let last = backups.snapshots.first else { return "No backups yet" }
        return "Last backup " + last.date.formatted(.relative(presentation: .named))
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
                    Button { Task { await cleanup.scan() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .disabled(cleanup.scanning || cleanup.working != nil)
                        .help("Measure again")
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
