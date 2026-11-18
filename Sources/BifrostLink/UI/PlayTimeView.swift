import SwiftUI
import Charts

struct PlayTimeView: View {
    @ObservedObject var stats: PlayStats
    @ObservedObject var cocoon: CocoonBridge
    @State private var icons: [String: NSImage] = [:]
    @State private var renaming: (key: String, title: String)?
    @State private var draftName = ""

    private var top: [GameTotal] { Array(stats.totals.prefix(10)) }

    var body: some View {
        Group {
            if stats.totals.isEmpty {
                ContentUnavailableView {
                    Label("No play time yet", systemImage: "gamecontroller")
                } description: {
                    Text(stats.cocoonRoot == nil && stats.serial != nil ? "Play something while docked and it shows up here. With Cocoon installed, the play time it records on the device is added too." : "Play something while docked and it shows up here. Play time Cocoon recorded on the \(DeviceInfo.name) is added when the \(DeviceInfo.name) links.")
                } actions: {
                    Button("Load From Cocoon") { Task { await stats.refreshCocoon() } }
                        .disabled(stats.serial == nil || stats.refreshing)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if stats.cocoonRoot == nil && stats.serial != nil {
                            Label("Play time per game on the device itself comes from Cocoon, which isn’t installed. Bifrost still counts the time you play while docked, by game for Cocoon launches and by app otherwise.", systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(10)
                                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        header
                        mostPlayed
                        perSystem
                        lastDays
                        recent
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: top.map(\.key)) { await loadIcons() }
        .alert("Rename \(renaming?.title ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draftName)
            Button("Rename") { if let item = renaming { stats.rename(item.key, to: draftName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shown in Play Time instead of the name read from the \(DeviceInfo.name).")
        }
    }

    private var header: some View {
        let systems = stats.bySystem.count
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            tile("Total", value: hours(stats.totalMinutes), symbol: "clock", detail: systems == 1 ? "on 1 system" : "across \(systems) systems")
            tile("Games played", value: "\(stats.totals.count)", symbol: "square.stack.3d.up", detail: "with a minute or more")
            tile("This week", value: "\(stats.playedThisWeek)", symbol: "calendar", detail: "games in the last 7 days")
            tile("Longest session", value: stats.longestSession.map { hours($0.minutes) } ?? "–", symbol: "flame",
                 detail: stats.longestSession.map { stats.customNames[PlayStats.key(for: $0)] ?? $0.title } ?? "while docked")
        }
    }

    private func tile(_ title: String, value: String, symbol: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var mostPlayed: some View {
        section("Most played") {
            VStack(spacing: 8) {
                let maximum = top.first?.minutes ?? 1
                ForEach(top) { game in
                    HStack(spacing: 10) {
                        Group {
                            if let icon = icons[game.key] {
                                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                            } else {
                                Image(systemName: game.system.isEmpty ? "app" : "gamecontroller").foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(game.title).font(.callout.weight(.medium)).lineLimit(1)
                                Text(systemName(game.system)).font(.caption2).foregroundStyle(.tertiary)
                                Spacer()
                                Text(hours(game.minutes)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            GeometryReader { proxy in
                                Capsule().fill(Theme.bifrost)
                                    .frame(width: max(4, proxy.size.width * game.minutes / maximum), height: 5)
                            }
                            .frame(height: 5)
                        }
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        gameMenu(key: game.key, title: game.title)
                    }
                }
                if !stats.ignored.isEmpty {
                    HStack {
                        Spacer()
                        Menu("\(stats.ignored.count) not counted") {
                            ForEach(stats.ignored.sorted { $0.value < $1.value }, id: \.key) { item in
                                Button("Count \(item.value) Again") { stats.restore(item.key) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var perSystem: some View {
        section("Per system") {
            Chart(stats.bySystem.prefix(8), id: \.system) { item in
                BarMark(x: .value("Hours", item.minutes / 60), y: .value("System", systemName(item.system)))
                    .foregroundStyle(Theme.accent.gradient)
            }
            .chartXAxisLabel("hours")
            .frame(height: 180)
        }
    }

    private var lastDays: some View {
        section("Last 30 days while docked") {
            Chart(stats.daily(), id: \.day) { item in
                BarMark(x: .value("Day", item.day, unit: .day), y: .value("Minutes", item.minutes))
                    .foregroundStyle(Theme.violet.gradient)
            }
            .chartYAxisLabel("minutes")
            .frame(height: 180)
        }
    }

    private var recent: some View {
        section("Recent sessions while docked") {
            if stats.sessions.isEmpty {
                Text("Sessions are recorded from now on while the \(DeviceInfo.name) is linked.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(stats.sessions.filter { stats.ignored[PlayStats.key(for: $0)] == nil }.suffix(15).reversed()) { session in
                        let key = PlayStats.key(for: session)
                        let title = stats.customNames[key] ?? session.title
                        HStack {
                            Text(title).font(.callout).lineLimit(1)
                            Text(systemName(session.system)).font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Text(session.start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Text(hours(session.minutes)).font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                        .contextMenu { gameMenu(key: key, title: title) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func gameMenu(key: String, title: String) -> some View {
        Button("Rename…") { draftName = title; renaming = (key, title) }
        if stats.customNames[key] != nil {
            Button("Use Original Name") { stats.rename(key, to: nil) }
        }
        Divider()
        Button("Don’t Count \(title)") { stats.setIgnored(key: key, title: title, true) }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func systemName(_ system: String) -> String { system.isEmpty ? "Android" : Systems.name(for: system) }

    private func hours(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total < 60 { return "\(total) min" }
        return total % 60 == 0 ? "\(total / 60) h" : "\(total / 60) h \(total % 60) min"
    }

    private func loadIcons() async {
        for game in top where icons[game.key] == nil {
            // Android games use Cocoon's artwork under android_app, named after the package with dots as underscores.
            let source = game.key.hasPrefix("app:")
                ? (system: "android_app", file: game.key.dropFirst(4).replacingOccurrences(of: ".", with: "_"))
                : (system: game.system, file: game.file)
            guard !source.file.isEmpty else { continue }
            if let image = cocoon.cachedIcon(system: source.system, file: source.file) {
                icons[game.key] = image
            } else if let image = await cocoon.icon(system: source.system, file: source.file) {
                icons[game.key] = image
            }
        }
    }
}
