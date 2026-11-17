import SwiftUI
import UniformTypeIdentifiers

enum AppConfirm: Identifiable {
    case clearData(ThorApp)
    case uninstall(ThorApp)

    var id: String {
        switch self {
        case .clearData(let app): return "data-" + app.package
        case .uninstall(let app): return "remove-" + app.package
        }
    }
}

struct AppsPanel: View {
    @ObservedObject var apps: AppManager
    @State private var search = ""
    @State private var confirm: AppConfirm?
    @State private var dropTargeted = false
    @State private var expanded: String?

    private var filtered: [ThorApp] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return apps.apps }
        return apps.apps.filter { $0.name.lowercased().contains(q) || $0.package.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if apps.serial == nil {
                ContentUnavailableView("Link your \(DeviceInfo.name)", systemImage: "cable.connector", description: Text("Installed apps show up here once it’s connected."))
                    .frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 6) {
                    TextField("Search \(apps.apps.count) apps", text: $search).textFieldStyle(.roundedBorder)
                }
                .controlSize(.small)
                .padding(12)
                Divider().opacity(0.5)
                if apps.apps.isEmpty && apps.loading {
                    ProgressView("Reading installed apps…").frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filtered) { app in row(app) }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
                dropZone
            }
        }
        .task(id: apps.serial) {
            if apps.serial != nil && apps.apps.isEmpty { await apps.refresh() }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { item in
            switch item {
            case .clearData(let app):
                Button("Reset \(app.name)", role: .destructive) { Task { await apps.clearData(app) } }
            case .uninstall(let app):
                Button("Remove \(app.name)", role: .destructive) { Task { await apps.uninstall(app, keepData: false) } }
                Button("Remove, Keep Its Data") { Task { await apps.uninstall(app, keepData: true) } }
            }
        } message: { item in
            switch item {
            case .clearData(let app):
                Text("Everything \(app.name) stored privately (\(app.dataSize.bytesText)) is deleted: settings, logins and saves kept inside the app. Files in its Android/data folder can be backed up in Saves first.")
            case .uninstall(let app):
                Text("\(app.name) is removed from your \(DeviceInfo.name). Back up its APK first if you might want this exact version again.")
            }
        }
    }

    private var confirmTitle: String {
        switch confirm {
        case .clearData(let app): return "Reset \(app.name)?"
        case .uninstall(let app): return "Remove \(app.name)?"
        case nil: return ""
        }
    }

    private func row(_ app: ThorApp) -> some View {
        let open = expanded == app.package
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon(for: app)).font(.title3).foregroundStyle(Theme.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(app.name).font(.callout.weight(.medium)).lineLimit(1)
                        if let kind = app.kind {
                            Text(kind).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.panel, in: Capsule())
                        }
                    }
                    Text([app.version.isEmpty ? nil : "v\(app.version)", app.package].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(app.total.bytesText).font(.caption.monospacedDigit())
                    if app.cacheSize > 1_048_576 {
                        Text("\(app.cacheSize.bytesText) cache").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).rotationEffect(.degrees(open ? 90 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded = open ? nil : app.package } }
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        sizeLabel("App", app.appSize)
                        sizeLabel("Data", app.dataSize)
                        sizeLabel("Cache", app.cacheSize)
                    }
                    HStack(spacing: 6) {
                        Button("Open") { Task { await apps.open(app) } }
                        Button("Close") { Task { await apps.close(app) } }
                        Button("Clear Cache") { Task { await apps.clearCache(app) } }.disabled(app.cacheSize == 0)
                        Menu("More") {
                            Button("Back Up APK to Mac") { Task { await apps.backupAPK(app) } }
                            let saved = apps.backups(for: app.package)
                            if !saved.isEmpty {
                                Section("Install a backed-up version") {
                                    ForEach(saved) { backup in
                                        Button(backup.version) { Task { await apps.restore(backup) } }
                                    }
                                }
                            }
                            Divider()
                            Button("Reset App…", role: .destructive) { confirm = .clearData(app) }
                            Button("Remove App…", role: .destructive) { confirm = .uninstall(app) }
                        }
                        .fixedSize()
                    }
                    .controlSize(.small)
                    .disabled(apps.working != nil)
                }
                .padding(.leading, 36)
            }
        }
        .padding(.vertical, 3)
    }

    private func sizeLabel(_ title: String, _ value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value.bytesText).font(.caption.monospacedDigit())
        }
    }

    private func icon(for app: ThorApp) -> String {
        switch app.kind {
        case "Emulator": return "gamecontroller.fill"
        case "Port": return "shippingbox.fill"
        case "Launcher": return "house.fill"
        default: return "app.fill"
        }
    }

    private var dropZone: some View {
        HStack(spacing: 8) {
            if let working = apps.working {
                ProgressView().controlSize(.small)
                Text(working).font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "arrow.down.app").foregroundStyle(Theme.accent)
                Text("Drop .apk or .apks files here to install them").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show APK Backups") {
                try? FileManager.default.createDirectory(at: apps.backupRoot, withIntermediateDirectories: true)
                NSWorkspace.shared.open(apps.backupRoot)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(dropTargeted ? Theme.accent.opacity(0.14) : Color.clear)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                let urls = await DropLoader.fileURLs(providers)
                await apps.installDropped(urls)
            }
            return true
        }
    }
}
