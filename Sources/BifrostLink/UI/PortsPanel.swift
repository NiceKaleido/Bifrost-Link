import SwiftUI
import UniformTypeIdentifiers

enum PortsScope: String, CaseIterable, Identifiable {
    case all, installed, updates
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .installed: return "On Thor"
        case .updates: return "Updates"
        }
    }
}

struct PortsPanel: View {
    @ObservedObject var catalog: PortCatalog
    @ObservedObject var manager: DeviceManager
    @ObservedObject var settings: LinkSettings
    @AppStorage("portsScope") private var scope: PortsScope = .all
    @AppStorage("portsPlatform") private var platform = "all"
    @AppStorage("portsThorOnly") private var thorOnly = false
    @AppStorage("portsDualOnly") private var dualOnly = false
    @AppStorage("portsType") private var type = "all"
    @State private var search = ""
    @State private var selected: RecompaPort?

    private var filtered: [RecompaPort] {
        var list = catalog.ports
        switch scope {
        case .installed: list = list.filter(catalog.isInstalled)
        case .updates: list = list.filter { $0.forks.contains(where: catalog.hasUpdate) }
        case .all: break
        }
        if platform != "all" { list = list.filter { $0.originalPlatform == platform } }
        if thorOnly { list = list.filter { let r = catalog.rating($0); return r.total > 0 && r.great + r.playable >= r.broken } }
        if dualOnly { list = list.filter(\.dualScreen) }
        if type != "all" { list = list.filter { $0.type == type } }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { list = list.filter { $0.name.lowercased().contains(q) || ($0.game ?? "").lowercased().contains(q) || $0.forks.contains { $0.repo.lowercased().contains(q) } } }
        return list.sorted { a, b in
            if settings.thorRatedFirst {
                let ra = catalog.rating(a).score, rb = catalog.rating(b).score
                if ra != rb { return ra > rb }
            }
            return (a.downloads ?? 0) > (b.downloads ?? 0)
        }
    }

    private var activeFilters: Int {
        (platform != "all" ? 1 : 0) + (thorOnly ? 1 : 0) + (dualOnly ? 1 : 0) + (type != "all" ? 1 : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider().opacity(0.5)
            if catalog.ports.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                ContentUnavailableView(scope == .updates ? "Everything is up to date" : "Nothing here",
                                       systemImage: scope == .updates ? "checkmark.circle" : "magnifyingglass",
                                       description: Text(scope == .updates ? "Installed ports match their latest release." : "Try another filter or search."))
                    .frame(maxHeight: .infinity)
            } else {
                List(filtered) { port in
                    PortRow(port: port, catalog: catalog)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = port }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            footer
        }
        .task {
            await catalog.refresh()
            if catalog.installed.isEmpty { await catalog.detectInstalled() }
        }
        .sheet(item: $selected) { port in
            PortDetailView(port: port, catalog: catalog, manager: manager)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Show", selection: $scope) {
                ForEach(PortsScope.allCases) { scope in
                    Text(scope == .updates && !catalog.updates.isEmpty ? "Updates (\(catalog.updates.count))" : scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 6) {
                TextField("Search ports", text: $search).textFieldStyle(.roundedBorder)
                Menu {
                    Toggle("Works on the Thor", isOn: $thorOnly)
                    Toggle("Dual screen", isOn: $dualOnly)
                    Picker("Type", selection: $type) {
                        Text("All types").tag("all")
                        Text("Recompilations").tag("recomp")
                        Text("Decompilations").tag("decomp")
                        Text("Source ports").tag("source-port")
                        Text("Emulators").tag("emulator")
                    }
                    Picker("Platform", selection: $platform) {
                        Text("All platforms").tag("all")
                        ForEach(platformsWithPorts, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    if activeFilters > 0 {
                        Divider()
                        Button("Clear Filters") {
                            platform = "all"; thorOnly = false; dualOnly = false; type = "all"
                        }
                    }
                } label: {
                    Label(activeFilters > 0 ? "Filters (\(activeFilters))" : "Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
                .fixedSize()
            }
            if scope == .updates && !catalog.updates.isEmpty {
                Button { catalog.updateAll() } label: { Label("Update All (\(catalog.updates.count))", systemImage: "arrow.down.circle") }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(manager.state != .linked)
            }
            if let problem = catalog.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .controlSize(.small)
        .padding(12)
    }

    private var platformsWithPorts: [RecompaPlatform] {
        let used = Set(catalog.ports.map(\.originalPlatform))
        return catalog.platforms.filter { used.contains($0.id) }
    }

    private var emptyState: some View {
        Group {
            if catalog.loading {
                ProgressView("Loading the Recompa catalog…")
            } else {
                ContentUnavailableView {
                    Label("No catalog yet", systemImage: "shippingbox")
                } description: {
                    Text(catalog.problem ?? "Native ports of games for Android, from recompa.app.")
                } actions: {
                    Button("Load Catalog") { Task { await catalog.refresh(force: true) } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text("Catalog by").font(.caption2).foregroundStyle(.secondary)
            Link("Recompa", destination: URL(string: "https://recompa.app")!).font(.caption2)
            Spacer()
            Text("\(filtered.count) of \(catalog.ports.count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct PortRow: View {
    let port: RecompaPort
    @ObservedObject var catalog: PortCatalog

    var body: some View {
        HStack(spacing: 10) {
            PortCover(port: port, compact: true)
                .frame(width: 42, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(port.name).font(.callout.weight(.medium)).lineLimit(1)
                    if port.dualScreen {
                        Image(systemName: "rectangle.split.1x2").font(.caption2).foregroundStyle(.secondary).help("Supports both Thor screens")
                    }
                }
                Text(catalog.platformName(port.originalPlatform)).font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    RatingChip(rating: catalog.rating(port))
                    if port.forks.contains(where: catalog.hasUpdate) {
                        tag("Update", Theme.accent)
                    } else if catalog.isInstalled(port) {
                        tag("On Thor", .green)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color, in: Capsule())
    }
}

struct RatingChip: View {
    let rating: ThorRating

    var body: some View {
        Text(rating.total == 0 ? "Not rated" : "\(rating.verdict.replacingOccurrences(of: " on Thor", with: "")) · \(rating.total)")
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .help(rating.total == 0 ? "No reports from Thor owners yet" : "Thor owners: \(rating.great) great, \(rating.playable) playable, \(rating.broken) broken")
    }

    private var color: Color {
        guard rating.total > 0 else { return .secondary }
        switch rating.verdict {
        case "Great on Thor": return .green
        case "Broken on Thor": return .red
        default: return .yellow
        }
    }
}

struct PortCover: View {
    let port: RecompaPort
    var compact = false

    var body: some View {
        AsyncImage(url: port.art?.cover.flatMap(URL.init(string:))) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Theme.indigo, Theme.violet.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    VStack(spacing: 6) {
                        Image(systemName: "gamecontroller").font(compact ? .callout : .title)
                        if !compact {
                            Text(port.name).font(.caption.weight(.semibold)).multilineTextAlignment(.center).padding(.horizontal, 8)
                        }
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
    }
}

struct PortJobsStrip: View {
    @ObservedObject var catalog: PortCatalog

    var body: some View {
        if !catalog.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Installing").font(.caption.weight(.semibold))
                    Spacer()
                    if catalog.jobs.contains(where: { !$0.isActive }) {
                        Button("Clear") { catalog.clearFinished() }.buttonStyle(.borderless).font(.caption)
                    }
                }
                ForEach(catalog.jobs) { job in PortJobRow(job: job, catalog: catalog) }
            }
            .padding(12)
            .background(.bar)
            .overlay(alignment: .top) { Divider().opacity(0.5) }
        }
    }
}

struct PortJobRow: View {
    let job: PortJob
    @ObservedObject var catalog: PortCatalog

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill").foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(job.portName) \(job.release.tag)").font(.caption).lineLimit(1)
                switch job.status {
                case .queued:
                    Text("Waiting · \((job.release.asset?.size ?? 0).bytesText)").font(.caption2).foregroundStyle(.secondary)
                case .downloading:
                    ProgressView(value: job.fraction ?? 0).controlSize(.mini).tint(Theme.accent)
                    Text("Downloading · \(Int((job.fraction ?? 0) * 100))% of \((job.release.asset?.size ?? 0).bytesText)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                case .verifying:
                    Text("Checking the download…").font(.caption2).foregroundStyle(.secondary)
                case .installing:
                    ProgressView().progressViewStyle(.linear).controlSize(.mini)
                    Text("Installing on the Thor…").font(.caption2).foregroundStyle(.secondary)
                case .done:
                    Text("Installed").font(.caption2).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.caption2).foregroundStyle(.red).lineLimit(2)
                case .cancelled:
                    Text("Cancelled").font(.caption2).foregroundStyle(.secondary)
                case .needsUninstall:
                    Text("Android won’t put this version over the installed one, because it comes from a different author or is older. That needs an uninstall first; the port’s files in Android/data are backed up before, but data the app keeps privately is lost.")
                        .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Button("Back Up, Uninstall & Install") { Task { await catalog.uninstallAndInstall(job.id) } }
                        .controlSize(.small)
                }
            }
            Spacer()
            if job.isActive {
                Button { catalog.cancel(job.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Cancel")
            }
        }
    }

    private var tint: Color {
        switch job.status {
        case .done: return .green
        case .failed: return .red
        case .needsUninstall: return .orange
        case .cancelled, .queued: return .secondary
        default: return Theme.accent
        }
    }
}

struct PortDetailView: View {
    let port: RecompaPort
    @ObservedObject var catalog: PortCatalog
    @ObservedObject var manager: DeviceManager
    @Environment(\.dismiss) private var dismiss
    @State private var localProblem: [String: String] = [:]

    private var linked: Bool { manager.state == .linked }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Port details", systemImage: "shippingbox.fill").font(.headline).foregroundStyle(.secondary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let warning = catalog.compatibility(port) {
                        Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                    }
                    if let forks = catalog.ambiguous(port) {
                        ambiguity(forks)
                    }
                    versions
                    if let assets = port.assets, !assets.isEmpty {
                        gameFiles(assets)
                    }
                    screenshots
                }
                .padding(20)
            }
            PortJobsStrip(catalog: catalog)
            HStack {
                if let first = port.forks.first {
                    Link("Open on GitHub", destination: URL(string: "https://github.com/\(first.repo)")!)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 620, idealWidth: 760, minHeight: 480, idealHeight: 680)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            PortCover(port: port)
                .frame(width: 140, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(port.name).font(.title2.weight(.semibold))
                Text([catalog.platformName(port.originalPlatform), port.typeTitle, (port.genres ?? []).prefix(2).joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    RatingChip(rating: catalog.rating(port))
                    if port.dualScreen {
                        Label("Dual screen", systemImage: "rectangle.split.1x2").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.panel, in: Capsule())
                    }
                    if let downloads = port.downloads {
                        Text("\(downloads.formatted()) downloads").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if let description = port.description {
                    Text(description).font(.callout).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                }
            }
        }
    }

    private func ambiguity(_ forks: [RecompaFork]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Which version is on your Thor?", systemImage: "questionmark.circle").font(.callout.weight(.semibold))
            Text("Several versions share the same app id and the installed build isn’t in the catalog, so Bifrost can’t tell them apart. Pick the one you installed to get its updates.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                ForEach(forks) { fork in
                    Button(fork.name ?? fork.repo) {
                        if let package = fork.package { catalog.chooseFork(fork.repo, for: package) }
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var versions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(port.forks.count == 1 ? "Version" : "Versions").font(.headline)
            ForEach(port.forks) { fork in forkRow(fork) }
        }
    }

    private func forkRow(_ fork: RecompaFork) -> some View {
        let installed = catalog.isInstalled(fork)
        let entry = catalog.installedEntry(for: fork)
        let update = catalog.hasUpdate(fork)
        let busy = catalog.jobs.contains { $0.repo == fork.repo && $0.isActive }
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(fork.name ?? fork.repo).font(.callout.weight(.medium))
                    if let channel = fork.channel { Text(channel).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 5).background(Theme.panel, in: Capsule()) }
                    if fork.dualScreen == true { Image(systemName: "rectangle.split.1x2").font(.caption2).help("Supports both Thor screens") }
                    RatingChip(rating: catalog.rating(fork))
                }
                Link(fork.repo, destination: URL(string: "https://github.com/\(fork.repo)")!).font(.caption2)
                if let release = fork.release {
                    Text("Latest \(release.tag)\(release.date.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "") · \((release.asset?.size ?? 0).bytesText)")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("No release yet").font(.caption2).foregroundStyle(.secondary)
                }
                if installed, let entry {
                    Text(entry.tag.map { "On your Thor: \($0)\(entry.exact ? "" : " (as installed by Bifrost)")" } ?? "On your Thor: version \(entry.versionName), build not in the catalog")
                        .font(.caption2).foregroundStyle(update ? Theme.accent : .green)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if busy {
                    ProgressView().controlSize(.small)
                } else if update {
                    Button("Update") { catalog.install(port, fork: fork) }.buttonStyle(.borderedProminent)
                } else if installed {
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                } else {
                    Button("Install") { catalog.install(port, fork: fork) }.buttonStyle(.borderedProminent)
                        .disabled(fork.release == nil || catalog.compatibility(port) != nil)
                }
                if fork.allReleases.count > 1 || installed {
                    Menu("More") {
                        if installed { Button("Reinstall Latest") { catalog.install(port, fork: fork) } }
                        if let history = fork.history, !history.isEmpty {
                            Section("Install an older version") {
                                ForEach(history, id: \.tag) { release in
                                    Button("\(release.tag)\(release.date.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "")") { catalog.install(port, fork: fork, release: release) }
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.caption)
                }
            }
            .disabled(!linked)
            .controlSize(.small)
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func gameFiles(_ assets: [RecompaAsset]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your game files").font(.headline)
            Text("Ports need files from your own copy of the game. Bifrost can find matching files in your Roms folders or check one you choose, then put it where the port expects it.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(assets) { asset in assetRow(asset) }
        }
    }

    private func assetRow(_ asset: RecompaAsset) -> some View {
        let key = port.id + "/" + asset.id
        let matches = catalog.gameFiles[key]
        let searching = catalog.searchingFiles.contains(key)
        let checksums = asset.accepted?.contains { $0.sha1 != nil } == true
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(asset.label).font(.callout.weight(.medium))
                Spacer()
                if checksums {
                    Button(searching ? "Looking…" : "Find on Thor") { Task { await catalog.findGameFiles(port, asset: asset) } }
                        .disabled(!linked || searching)
                    Button("Choose on Mac…") { chooseLocal(asset) }
                        .disabled(!linked)
                }
            }
            .controlSize(.small)
            if let accepted = asset.accepted, !accepted.isEmpty {
                Text("Accepted: " + accepted.compactMap { $0.label }.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if let matches {
                if matches.isEmpty {
                    Text("No matching file in your Roms folders. The dump has to match exactly, check region and revision.")
                        .font(.caption2).foregroundStyle(.orange)
                }
                ForEach(matches) { match in
                    HStack {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text((match.path as NSString).lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                        Text(match.label).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy for the Port") { Task { await catalog.deliver(match, port: port, asset: asset) } }
                            .controlSize(.small)
                    }
                }
            }
            if let problem = localProblem[key] {
                Text(problem).font(.caption2).foregroundStyle(.orange)
            }
            if let markdown = asset.instructionsMd, let text = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if asset.delivery?.mode != "intent" {
                Text("Bifrost copies it to \(catalog.deliveryFolder(port, asset: asset).replacingOccurrences(of: "/sdcard/", with: "Internal/")).")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func chooseLocal(_ asset: RecompaAsset) {
        let key = port.id + "/" + asset.id
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose your \(asset.label)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        localProblem[key] = "Checking \(url.lastPathComponent)…"
        Task {
            if let match = await catalog.checkLocal(url, port: port, asset: asset) {
                localProblem[key] = nil
                await catalog.deliver(match, port: port, asset: asset)
            } else {
                localProblem[key] = "\(url.lastPathComponent) isn’t one of the accepted versions. The dump has to match exactly."
            }
        }
    }

    @ViewBuilder
    private var screenshots: some View {
        if let shots = port.art?.screenshots, !shots.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Screenshots").font(.headline)
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(shots.prefix(6), id: \.self) { shot in
                            AsyncImage(url: URL(string: shot)) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Theme.panel
                            }
                            .frame(width: 240, height: 135)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }
        }
    }
}
