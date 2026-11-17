import SwiftUI
import Charts

struct PlayTimeView: View {
    @ObservedObject var stats: PlayStats
    @ObservedObject var cocoon: CocoonBridge
    @State private var icons: [String: NSImage] = [:]

    private var top: [GameTotal] { Array(stats.totals.prefix(10)) }

    var body: some View {
        Group {
            if stats.totals.isEmpty {
                ContentUnavailableView {
                    Label("No play time yet", systemImage: "gamecontroller")
                } description: {
                    Text("Play something while docked and it shows up here. Play time Cocoon recorded on the Thor is added when the Thor links.")
                } actions: {
                    Button("Load From Cocoon") { Task { await stats.refreshCocoon() } }
                        .disabled(stats.serial == nil || stats.refreshing)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
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
    }

    private var header: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
            tile("Total", value: hours(stats.totalMinutes), symbol: "clock")
            tile("Games played", value: "\(stats.totals.count)", symbol: "square.stack.3d.up")
            tile("This week", value: "\(stats.playedThisWeek)", symbol: "calendar")
            tile("Longest session", value: stats.longestSession.map { hours($0.minutes) } ?? "–", symbol: "flame",
                 detail: stats.longestSession?.title)
        }
    }

    private func tile(_ title: String, value: String, symbol: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            if let detail { Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
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
                Text("Sessions are recorded from now on while the Thor is linked.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(stats.sessions.suffix(15).reversed()) { session in
                        HStack {
                            Text(session.title).font(.callout).lineLimit(1)
                            Text(systemName(session.system)).font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Text(session.start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Text(hours(session.minutes)).font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
                        }
                    }
                }
            }
        }
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
        for game in top where icons[game.key] == nil && !game.file.isEmpty {
            if let image = cocoon.cachedIcon(system: game.system, file: game.file) {
                icons[game.key] = image
            } else if let image = await cocoon.icon(system: game.system, file: game.file) {
                icons[game.key] = image
            }
        }
    }
}
