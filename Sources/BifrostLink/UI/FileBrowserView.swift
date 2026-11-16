import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @ObservedObject var files: FileService
    @ObservedObject var settings: LinkSettings
    @State private var selection: Set<String> = []
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var renaming: RemoteFile?
    @State private var renameText = ""
    @State private var confirmDelete = false
    @State private var dropTargeted = false
    @State private var showLargest = false

    private var selectedFiles: [RemoteFile] {
        files.entries.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            list
            if !files.transfers.isEmpty {
                Divider().opacity(0.5)
                transfers
            }
        }

        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { Task { await files.makeFolder(newFolderName) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
                .onAppear { if let file = renaming { renameText = file.name } }
            Button("Rename") {
                if let file = renaming { Task { await files.rename(file, to: renameText) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .sheet(isPresented: $showLargest) {
            LargestFilesView(files: files, settings: settings, isPresented: $showLargest)
        }
        .confirmationDialog("Delete \(selection.count == 1 ? "“\(selectedFiles.first?.name ?? "")”" : "\(selection.count) items") from the Thor?",
                            isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                let targets = selectedFiles
                selection.removeAll()
                Task { await files.delete(targets) }
            }
        } message: {
            Text("This can’t be undone.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(files.displayName(forPath: files.path) ?? (files.path as NSString).lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                if files.loading || files.measuring { ProgressView().controlSize(.mini) }
                Button { files.sizeMode.toggle() } label: {
                    Image(systemName: files.sizeMode ? "chart.bar.xaxis.ascending" : "chart.bar.xaxis")
                        .foregroundStyle(files.sizeMode ? Theme.accent : .secondary)
                }
                .buttonStyle(.borderless)
                .help(files.sizeMode ? "Hide folder sizes" : "Show folder sizes, biggest first")
                Button { showLargest = true } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Find the largest files on this storage")
                Menu {
                    Toggle("Show Hidden Files", isOn: $files.showHidden)
                    Divider()
                    Button("Open Download Folder on Mac") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: settings.downloadFolder))
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(files.space.isEmpty ? files.places : FileService.folderPlaces, id: \.self) { place in
                        Button {
                            selection.removeAll()
                            files.open(place.path)
                        } label: {
                            Label(place.name, systemImage: place.symbol)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(files.path == place.path ? AnyShapeStyle(Theme.accent.opacity(0.35)) : AnyShapeStyle(Theme.panel), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !files.space.isEmpty {
                HStack(spacing: 8) {
                    ForEach(files.space) { volume in
                        StorageCard(volume: volume, active: files.path.hasPrefix(volume.path)) {
                            selection.removeAll()
                            files.open(volume.path)
                        }
                    }
                }
            }

            HStack(spacing: 4) {
                Button { selection.removeAll(); files.goUp() } label: { Image(systemName: "chevron.left") }
                    .disabled(files.path == "/")
                    .help("Enclosing folder")
                breadcrumbs
                Spacer(minLength: 4)
                Button { Task { await files.loadVolumes(); await files.reload(); await files.loadSpace() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                Button { newFolderName = ""; showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }.help("New folder")
                Button(action: pickUpload) { Image(systemName: "square.and.arrow.up") }.help("Upload files to this folder")
                Button(action: downloadSelection) { Image(systemName: "square.and.arrow.down") }
                    .disabled(selection.isEmpty).help("Download to \(shortPath(settings.downloadFolder))")
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .disabled(selection.isEmpty).help("Delete")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
    }

    private var breadcrumbs: some View {
        let all = files.path.split(separator: "/").map(String.init)
        var start = 0
        for i in stride(from: all.count - 1, through: 0, by: -1) where files.displayName(forPath: "/" + all.prefix(i + 1).joined(separator: "/")) != nil {
            start = i
            break
        }
        let crumbs: [(String, String)] = all.indices.compactMap { i in
            guard i >= start else { return nil }
            let full = "/" + all.prefix(i + 1).joined(separator: "/")
            return (files.displayName(forPath: full) ?? all[i], full)
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 { Image(systemName: "chevron.compact.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button(crumb.0) {
                        selection.removeAll()
                        files.open(crumb.1)
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(index == crumbs.count - 1 ? .semibold : .regular))
                    .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                }
            }
        }
    }

    private var list: some View {
        ZStack {
            List(selection: $selection) {
                ForEach(files.entries) { file in
                    FileRow(file: file,
                            size: files.sizeMode ? files.size(of: file) : nil,
                            fraction: files.sizeMode && files.largestEntrySize > 0 ? Double(files.size(of: file) ?? 0) / Double(files.largestEntrySize) : nil,
                            measuring: files.sizeMode && files.measuring && file.isDirectory && files.size(of: file) == nil)
                        .tag(file.id)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: String.self) { ids in
                let targets = files.entries.filter { ids.contains($0.id) }
                if targets.count == 1, let file = targets.first, file.isDirectory {
                    Button("Open") { selection.removeAll(); files.open(file.path) }
                }
                if !targets.isEmpty {
                    Button("Download") { files.download(targets, to: URL(fileURLWithPath: settings.downloadFolder)) }
                    Button("Download To…") { downloadTo(targets) }
                }
                if targets.count == 1, let file = targets.first {
                    Button("Rename…") {
                        renaming = nil
                        renameText = file.name
                        DispatchQueue.main.async { renaming = file }
                    }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(file.path, forType: .string)
                    }
                }
                if !targets.isEmpty {
                    Divider()
                    Button("Delete…", role: .destructive) { selection = ids; confirmDelete = true }
                }
            } primaryAction: { ids in
                let targets = files.entries.filter { ids.contains($0.id) }
                if targets.count == 1, let file = targets.first, file.isDirectory {
                    selection.removeAll()
                    files.open(file.path)
                } else if !targets.isEmpty {
                    files.download(targets, to: URL(fileURLWithPath: settings.downloadFolder))
                }
            }

            if let error = files.error, files.entries.isEmpty {
                ContentUnavailableView("Can’t open folder", systemImage: "lock", description: Text(error))
            } else if files.entries.isEmpty && !files.loading {
                ContentUnavailableView("Empty folder", systemImage: "folder", description: Text("Drop files here to upload them."))
            }

            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.bifrost, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(Label("Upload to \(files.path)", systemImage: "arrow.up.doc").font(.callout.weight(.medium)))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                let urls = await DropLoader.fileURLs(providers)
                if !urls.isEmpty { files.upload(urls) }
            }
            return true
        }
    }

    private var transfers: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Transfers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { files.clearFinished() }.buttonStyle(.borderless).font(.caption)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(files.transfers) { t in
                        TransferRow(transfer: t) { files.cancel(t) }
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding(12)
    }

    private func shortPath(_ p: String) -> String {
        p.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func pickUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Upload"
        panel.message = "Choose files to send to \(files.path)"
        if panel.runModal() == .OK { files.upload(panel.urls) }
    }

    private func downloadSelection() {
        files.download(selectedFiles, to: URL(fileURLWithPath: settings.downloadFolder))
    }

    private func downloadTo(_ targets: [RemoteFile]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        if panel.runModal() == .OK, let url = panel.url { files.download(targets, to: url) }
    }
}

struct StorageCard: View {
    let volume: FileService.VolumeSpace
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: volume.symbol).foregroundStyle(Theme.accent)
                    Text(volume.name).font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule()
                            .fill(volume.usedFraction > 0.9 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Theme.bifrost))
                            .frame(width: max(4, geo.size.width * volume.usedFraction))
                    }
                }
                .frame(height: 5)
                Text("\(ByteCountFormatter.string(fromByteCount: volume.free, countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: volume.total, countStyle: .file))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(active ? Theme.accent.opacity(0.16) : Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(active ? Theme.accent.opacity(0.5) : Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}

struct FileRow: View {
    let file: RemoteFile
    var size: Int64? = nil
    var fraction: Double? = nil
    var measuring = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: file.symbol)
                .foregroundStyle(file.isDirectory ? AnyShapeStyle(Theme.bifrost) : AnyShapeStyle(.secondary))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                if let fraction {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.07))
                            Capsule().fill(Theme.bifrost).frame(width: max(3, geo.size.width * fraction))
                        }
                    }
                    .frame(height: 4)
                } else {
                    HStack(spacing: 6) {
                        if !file.isDirectory {
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        }
                        if let date = file.modified {
                            Text(date, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 6)
            if let size {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if measuring {
                ProgressView().controlSize(.mini)
            }
            if file.isDirectory {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct LargestFilesView: View {
    @ObservedObject var files: FileService
    @ObservedObject var settings: LinkSettings
    @Binding var isPresented: Bool
    @State private var selection: Set<String> = []
    @State private var confirmDelete = false

    private var root: String { files.currentVolumeRoot }
    private var rootName: String { files.displayName(forPath: root) ?? root }
    private var selected: [RemoteFile] { files.largest.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Largest Files").font(.headline)
                    Text("\(rootName) · files over 20 MB").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if files.scanningLargest { ProgressView().controlSize(.small) }
                Button { Task { await files.findLargestFiles() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(files.scanningLargest)
            }
            .padding(14)
            Divider().opacity(0.5)
            ZStack {
                List(selection: $selection) {
                    ForEach(files.largest) { file in
                        HStack(spacing: 10) {
                            Image(systemName: file.symbol).foregroundStyle(.secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.name).lineLimit(1).truncationMode(.middle)
                                Text(relative(file.path)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                .font(.callout.monospacedDigit())
                        }
                        .tag(file.id)
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    let targets = files.largest.filter { ids.contains($0.id) }
                    if targets.count == 1, let file = targets.first {
                        Button("Show in Folder") { files.reveal(file); isPresented = false }
                    }
                    if !targets.isEmpty {
                        Button("Download") { files.download(targets, to: URL(fileURLWithPath: settings.downloadFolder)) }
                        Divider()
                        Button("Delete…", role: .destructive) { selection = ids; confirmDelete = true }
                    }
                } primaryAction: { ids in
                    if let file = files.largest.first(where: { ids.contains($0.id) }) {
                        files.reveal(file)
                        isPresented = false
                    }
                }
                if files.largest.isEmpty {
                    if files.scanningLargest {
                        ProgressView("Scanning \(rootName)…")
                    } else {
                        ContentUnavailableView("No large files", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
            Divider().opacity(0.5)
            HStack {
                Text(selection.isEmpty ? "\(files.largest.count) files" : "\(selection.count) selected · \(ByteCountFormatter.string(fromByteCount: selected.reduce(0) { $0 + $1.size }, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Delete…", role: .destructive) { confirmDelete = true }.disabled(selection.isEmpty)
                Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 520)
        .task { if files.largest.isEmpty || !files.largest.allSatisfy({ $0.path.hasPrefix(root) }) { await files.findLargestFiles() } }
        .confirmationDialog("Delete \(selection.count) file\(selection.count == 1 ? "" : "s") from the Thor?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                let targets = selected
                selection.removeAll()
                Task { await files.delete(targets) }
            }
        } message: {
            Text("This can’t be undone.")
        }
    }

    private func relative(_ path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.hasPrefix(root) ? rootName + String(dir.dropFirst(root.count)) : dir
    }
}

struct TransferRow: View {
    let transfer: Transfer
    var onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: transfer.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name).font(.caption).lineLimit(1).truncationMode(.middle)
                switch transfer.status {
                case .running:
                    if transfer.totalBytes > 0 {
                        ProgressView(value: transfer.progress).controlSize(.mini).tint(Theme.accent)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.mini)
                    }
                case .done:
                    Text(transfer.direction == .upload ? "Sent" : "Saved").font(.caption2).foregroundStyle(.secondary)
                case .cancelled:
                    Text("Cancelled").font(.caption2).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            if transfer.status == .running, let onCancel {
                Button(action: onCancel) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Cancel this transfer")
                    .accessibilityLabel("Cancel transfer")
            }
            if transfer.status == .done && transfer.direction == .download {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: transfer.destination)])
                } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
        }
    }

    private var statusColor: Color {
        switch transfer.status {
        case .running: return Theme.accent
        case .done: return .green
        case .cancelled: return .secondary
        case .failed: return .red
        }
    }
}
