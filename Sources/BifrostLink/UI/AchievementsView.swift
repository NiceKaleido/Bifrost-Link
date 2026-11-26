import SwiftUI

/// The Achievements tab: your RetroAchievements profile, games, unlocks, and switching achievements
/// on in the emulators on the device.
struct AchievementsView: View {
    @ObservedObject var hub: AchievementsHub
    @State private var filter: Filter = .all
    @State private var openGame: Int?
    @State private var error: String?

    enum Filter: String, CaseIterable { case all = "All", inProgress = "In progress", mastered = "Mastered", onDevice = "On my Thor" }

    var body: some View {
        Group {
            if !hub.isSignedIn {
                ScrollView { SignInCard(hub: hub).padding(12) }
            } else {
                // Profile and recent unlocks stay put; the games list takes the rest of the window.
                VStack(alignment: .leading, spacing: 12) {
                    profileCard
                    if !hub.recent.isEmpty { recentCard }
                    gamesCard.frame(maxHeight: .infinity, alignment: .top)
                }
                .padding(12)
            }
        }
        .task(id: hub.username) {
            guard hub.isSignedIn else { return }
            await hub.refresh()
            await hub.matchDevice()
        }
        .sheet(item: Binding(get: { openGame.map { GameID(id: $0) } }, set: { openGame = $0?.id })) { game in
            GameAchievementsSheet(hub: hub, gameID: game.id) { openGame = nil }
        }
        .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private struct GameID: Identifiable { let id: Int }

    // MARK: Profile

    private var profileCard: some View {
        Card {
            HStack(spacing: 12) {
                RemoteImage(hub: hub, path: hub.profile?.picture ?? "", size: 52, corner: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hub.profile?.user ?? hub.username ?? "").font(.title3.weight(.semibold))
                    if let p = hub.profile {
                        Text("\(p.points) points · \(p.softcorePoints) softcore · \(p.truePoints) RetroPoints").font(.caption).foregroundStyle(.secondary)
                        if !p.richPresence.isEmpty { Text(p.richPresence).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    }
                }
                Spacer()
            }
            HStack(spacing: 6) {
                if hub.loading { ProgressView().controlSize(.mini); Text("Updating…").font(.caption).foregroundStyle(.secondary) }
                else if let problem = hub.problem { Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                else if let updated = hub.updated {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    Text("Updated \(updated.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Games

    private var filteredGames: [AchievementsHub.GameProgress] {
        switch filter {
        case .all: return hub.games
        case .inProgress: return hub.games.filter { $0.fraction > 0 && $0.fraction < 1 }
        case .mastered: return hub.games.filter { $0.award == "mastered" || $0.award == "completed" }
        case .onDevice: return hub.games.filter { hub.onDevice.contains($0.id) }
        }
    }

    private var gamesCard: some View {
        Card {
            HStack {
                Text("Your games").font(.headline)
                Spacer()
                Text("\(hub.games.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            let list = filteredGames
            if list.isEmpty {
                Text(filter == .onDevice ? "None of your RetroAchievements games were found in the Roms folders." : "Nothing here yet.")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(list) { game in
                            Button { openGame = game.id } label: { GameProgressRow(hub: hub, game: game, onDevice: hub.onDevice.contains(game.id)) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: Recent

    private var recentCard: some View {
        Card {
            Text("Recent unlocks").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(hub.recent.prefix(10)) { unlock in
                        Button { openGame = unlock.gameID } label: {
                            VStack(spacing: 3) {
                                RemoteImage(hub: hub, path: AchievementsHub.badgePath(unlock.badge, locked: false), size: 44, corner: 6)
                                    .overlay(alignment: .topTrailing) {
                                        if unlock.hardcore { Image(systemName: "flame.fill").font(.system(size: 9)).foregroundStyle(.orange).offset(x: 3, y: -3) }
                                    }
                                Text(unlock.title).font(.system(size: 9, weight: .medium)).lineLimit(1).frame(width: 64)
                                Text(unlock.date.formatted(.relative(presentation: .named))).font(.system(size: 8)).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("\(unlock.title) · \(unlock.gameTitle) · \(unlock.points) points\n\(unlock.description)")
                    }
                }
            }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task { do { try await work() } catch { self.error = error.localizedDescription } }
    }
}

/// Sign in with username and web API key.
private struct SignInCard: View {
    @ObservedObject var hub: AchievementsHub
    @State private var user = ""
    @State private var key = ""
    @State private var busy = false

    var body: some View {
        Card {
            Label("Sign in to RetroAchievements", systemImage: "trophy.fill").font(.headline)
            Text("You'll need your username and your web API key. The key is on retroachievements.org under Settings ▸ Keys. ")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Username", text: $user).textFieldStyle(.roundedBorder)
            SecureField("Web API key", text: $key).textFieldStyle(.roundedBorder)
            if let problem = hub.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            HStack {
                Link("Open RetroAchievements settings", destination: URL(string: "https://retroachievements.org/settings")!).font(.caption)
                Spacer()
                Button(busy ? "Checking…" : "Connect") {
                    busy = true
                    Task { _ = await hub.signIn(user: user, apiKey: key); busy = false }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || user.isEmpty || key.isEmpty)
            }
        }
    }
}

/// One game in the list: icon, progress bar, counts and award.
private struct GameProgressRow: View {
    @ObservedObject var hub: AchievementsHub
    let game: AchievementsHub.GameProgress
    let onDevice: Bool

    var body: some View {
        HStack(spacing: 10) {
            RemoteImage(hub: hub, path: game.icon, size: 44, corner: 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(game.title).font(.callout.weight(.semibold)).lineLimit(1)
                    if let award = game.awardLabel {
                        Text(award).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(award == "Mastered" ? Color.yellow.opacity(0.8) : Theme.accent))
                    }
                    if onDevice {
                        Text("on Thor").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.green.opacity(0.7)))
                    }
                }
                Text(game.console).font(.caption2).foregroundStyle(.secondary)
                ProgressView(value: game.fraction).controlSize(.mini).tint(game.fraction >= 1 ? .yellow : Theme.accent)
            }
            Text("\(max(game.earned, game.earnedHardcore)) / \(game.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
        .contentShape(Rectangle())
    }
}

/// All achievements of one game.
private struct GameAchievementsSheet: View {
    @ObservedObject var hub: AchievementsHub
    let gameID: Int
    let dismiss: () -> Void
    @State private var hardcoreDates = false

    var body: some View {
        let detail = hub.details[gameID]
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                RemoteImage(hub: hub, path: detail?.icon ?? "", size: 48, corner: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail?.title ?? "Loading…").font(.title3.weight(.semibold))
                    if let detail {
                        let earned = detail.achievements.filter(\.isEarned).count
                        Text("\(detail.console) · \(earned) of \(detail.achievements.count) unlocked · \(detail.achievements.filter(\.isEarned).map(\.points).reduce(0, +)) points")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("Hardcore dates", isOn: $hardcoreDates).toggleStyle(.switch).controlSize(.mini).font(.caption)
            }
            .padding(16)
            Divider()
            ScrollView {
                if let detail {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(detail.achievements) { a in
                            HStack(alignment: .top, spacing: 10) {
                                RemoteImage(hub: hub, path: AchievementsHub.badgePath(a.badge, locked: !a.isEarned), size: 40, corner: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(a.title).font(.callout.weight(.semibold))
                                        Text("\(a.points)").font(.caption2.monospacedDigit().weight(.bold))
                                            .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.white.opacity(0.1)))
                                    }
                                    Text(a.description).font(.caption).foregroundStyle(.secondary)
                                    if let date = hardcoreDates ? a.earnedHardcore : (a.earned ?? a.earnedHardcore) {
                                        Text("Unlocked \(date.formatted(date: .abbreviated, time: .shortened))\(a.earnedHardcore != nil ? " · hardcore" : "")")
                                            .font(.caption2).foregroundStyle(.green)
                                    }
                                }
                                Spacer()
                            }
                            .opacity(a.isEarned ? 1 : 0.6)
                        }
                    }
                    .padding(16)
                } else {
                    ProgressView().padding(40).frame(maxWidth: .infinity)
                }
            }
            Divider()
            HStack {
                Link("Open on RetroAchievements", destination: URL(string: "https://retroachievements.org/game/\(gameID)")!).font(.caption)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 600)
        .task { await hub.loadDetail(gameID) }
    }
}

/// A badge, icon or avatar from RetroAchievements, cached on this Mac.
private struct RemoteImage: View {
    @ObservedObject var hub: AchievementsHub
    let path: String
    let size: CGFloat
    var corner: CGFloat = 6

    var body: some View {
        let _ = hub.imageRevision
        Group {
            if let image = hub.image(path) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: corner).fill(Color.white.opacity(0.06))
                    .overlay(Image(systemName: "trophy").foregroundStyle(.tertiary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct AchievementsHeaderActions: View {
    @ObservedObject var hub: AchievementsHub

    var body: some View {
        HStack {
            if hub.isSignedIn {
                Menu {
                    Button("Sign Out of RetroAchievements") { hub.signOut() }
                } label: { Image(systemName: "person.crop.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Button {
                Task {
                    await hub.refresh(force: true)
                    await hub.matchDevice()
                }
            } label: {
                if hub.loading { ProgressView().controlSize(.mini) } else { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            .disabled(hub.loading || !hub.isSignedIn)
        }
    }
}
