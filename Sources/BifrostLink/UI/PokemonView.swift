import SwiftUI

/// The Pokémon tab: every Pokémon save on the device, their boxes, and tools to edit moves,
/// evolve trade evolutions and move Pokémon between games.
struct PokemonView: View {
    @ObservedObject var hub: PokemonHub
    @ObservedObject var icons: IconCache
    @ObservedObject private var settings = LinkSettings.shared
    @State private var box = 0
    @State private var picked: PickedMon?
    @State private var error: String?
    @State private var closePrompt: ClosePrompt?
    @State private var selected: Set<SlotRef> = []
    @State private var moving: MoveRequest?
    @State private var dropTargeted = false
    @State private var renaming: PickedMon?
    @State private var releasing: ReleaseRequest?

    struct ReleaseRequest: Identifiable {
        let id = UUID()
        let save: String
        let slots: [SlotRef]
    }

    struct MoveRequest: Identifiable {
        let id = UUID()
        let source: String
        let slots: [SlotRef]
        let target: String
    }

    struct PickedMon: Identifiable {
        let save: String
        let slot: SlotRef
        var id: String { save + slot.label }
    }

    struct ClosePrompt: Identifiable {
        let id = UUID()
        let apps: [String]
        let run: () async throws -> Void
    }

    init(hub: PokemonHub) {
        self.hub = hub
        self.icons = hub.icons
    }

    private var current: OpenSave? { hub.open(hub.selection) }

    var body: some View {
        VStack(spacing: 0) {
            if !hub.unsavedSaves.isEmpty {
                unsavedBar.padding([.horizontal, .top], 12)
            }
            content
        }
        .animation(.easeOut(duration: 0.2), value: hub.unsavedSaves.count)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if hub.serial == nil && hub.saves.isEmpty {
                    Card { Label("Link your \(DeviceInfo.name) to see its Pokémon saves.", systemImage: "cable.connector").font(.callout) }
                } else if hub.scanning && hub.saves.isEmpty {
                    Card { HStack { ProgressView().controlSize(.small); Text("Looking for Pokémon saves…").font(.callout) } }
                } else if hub.saves.isEmpty {
                    emptyCard
                } else {
                    gamePicker
                    if let save = current, save.file.allSlots.isEmpty {
                        Card {
                            Label("There are no Pokémon in this save yet.", systemImage: "tray").font(.callout)
                            Text("Play on until you have your first Pokémon and save in the game, then press Rescan.").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let save = current {
                        SaveContents(save: save, hub: hub, box: $box, picked: $picked, selected: $selected, onError: { error = $0 },
                                     onRename: { renaming = .init(save: save.id, slot: $0) },
                                     onRelease: { releasing = ReleaseRequest(save: save.id, slots: $0) }) { slots, target in
                            moving = MoveRequest(source: save.id, slots: slots, target: target)
                        }
                        selectionBar(save)
                        evolveBox(save)
                    }
                    else if let found = hub.saves.first(where: { $0.id == hub.selection }), let message = found.error {
                        Card { Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary) }
                    }
                }
            }
            .padding(12)
        }
        .task(id: hub.serial) {
            if hub.serial != nil && hub.lastScan == nil {
                await hub.scan()
                await hub.icons.build(roms: hub.roms)
                await hub.fetchArt()
            }
        }
        .sheet(item: $picked) { item in
            if let save = hub.open(item.save), let mon = save.file.mon(at: item.slot) {
                MonDetailSheet(hub: hub, save: save, slot: item.slot, mon: mon, run: run) { picked = nil }
            }
        }
        .sheet(item: $renaming) { item in
            if let save = hub.open(item.save), let mon = save.file.mon(at: item.slot) {
                RenameSheet(mon: mon, game: save.file.game) { name in
                    renaming = nil
                    guard let name else { return }
                    do { try hub.edit(save, slot: item.slot, to: PokemonHub.renamed(mon, to: name, in: save.file.game)) }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
        .confirmationDialog(releaseTitle, isPresented: Binding(get: { releasing != nil }, set: { if !$0 { releasing = nil } }), presenting: releasing) { item in
            Button(item.slots.count == 1 ? "Release" : "Release \(item.slots.count)", role: .destructive) {
                if let save = hub.open(item.save) {
                    do { try hub.releaseMany(save, slots: item.slots) } catch { self.error = error.localizedDescription }
                    selected.subtract(item.slots)
                }
                releasing = nil
            }
        } message: { _ in
            Text("It's removed from the save once you press Save to \(DeviceInfo.name). Until then you can still undo it.")
        }
        .sheet(item: $moving) { request in
            if let source = hub.open(request.source), let target = hub.open(request.target) {
                MoveSheet(hub: hub, source: source, slots: request.slots, target: target, run: run) { moved in
                    moving = nil
                    if moved { selected = [] }
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog("Close the game first?", isPresented: Binding(get: { closePrompt != nil }, set: { if !$0 { closePrompt = nil } }), presenting: closePrompt) { prompt in
            Button("Close and Save") {
                Task {
                    await hub.closeApps(prompt.apps)
                    do { try await prompt.run() } catch { self.error = error.localizedDescription }
                }
            }
        } message: { prompt in
            Text("\(prompt.apps.map(PokemonView.appName).joined(separator: " and ")) is open on the \(DeviceInfo.name). It's closed before saving so it can't overwrite the change. Anything unsaved in the game is lost.")
        }
        .onChange(of: hub.selection) { _, _ in box = 0; selected = [] }
    }

    /// One bar for all unsaved changes, in every game.
    private var unsavedBar: some View {
        let dirty = hub.unsavedSaves
        return HStack(spacing: 10) {
            Image(systemName: "square.and.pencil").font(.title3).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(dirty.count == 1 ? "Unsaved changes" : "Unsaved changes in \(dirty.count) games").font(.callout.weight(.semibold))
                Text(dirty.map { $0.found.game?.name ?? $0.found.title }.joined(separator: ", ") + " · nothing is written to the \(DeviceInfo.name) until you save")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Undo All") { withAnimation { hub.discardAll() } }
            Button(hub.busy ?? "Save All") {
                run(dirty) {
                    try await hub.write(dirty, label: "Before Pokémon changes")
                    hub.toast?("checkmark.circle", dirty.count == 1 ? "Changes saved in \(dirty[0].found.title)" : "Changes saved in \(dirty.count) games")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(hub.busy != nil)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.opacity(0.6)))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func selectionBar(_ save: OpenSave) -> some View {
        let order: (SlotRef, SlotRef) -> Bool = { ($0.area == .party ? 0 : 1, $0.box, $0.index) < ($1.area == .party ? 0 : 1, $1.box, $1.index) }
        let picked = selected.sorted(by: order).compactMap { slot in save.file.mon(at: slot).map { (slot, $0) } }
        let targets = hub.saves.filter { $0.id != save.id && $0.error == nil }
        return Group {
            if picked.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down").font(.title3).foregroundStyle(dropTargeted ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Batch send").font(.callout.weight(.semibold))
                        Text("Drag Pokémon here, or right-click one → Add to Batch Send.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(dropTargeted ? Theme.accent.opacity(0.15) : Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(dropTargeted ? Theme.accent : Theme.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            } else { trayCard(save, picked: picked, targets: targets) }
        }
        .dropDestination(for: String.self) { items, _ in
            let others = hub.saves.filter { $0.id != save.id && $0.error == nil && $0.readOnly == nil && $0.game != nil }
            let slots = items.compactMap(SlotRef.parse(dragID:)).filter { $0.save == save.id }.map(\.slot).filter { slot in
                guard let mon = save.file.mon(at: slot) else { return false }
                return others.contains { MonTransfer.plan(mon, from: save.file.game, to: $0.game!).isPossible }
            }
            selected.formUnion(slots)
            return !slots.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }

    private func trayCard(_ save: OpenSave, picked: [(SlotRef, Mon)], targets: [FoundSave]) -> some View {
        Card {
            HStack {
                Label("\(picked.count) selected", systemImage: "tray.full.fill").font(.callout.weight(.semibold))
                Spacer()
                Button("Release…", role: .destructive) { releasing = ReleaseRequest(save: save.id, slots: picked.map(\.0)) }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.red)
                    .disabled(save.found.readOnly != nil)
                Button("Clear") { selected = [] }.buttonStyle(.borderless).font(.caption)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(picked, id: \.0) { slot, mon in
                        Button { selected.remove(slot) } label: {
                            VStack(spacing: 1) {
                                MonIcon(mon: mon, generation: save.file.game.generation, icons: icons, size: 30)
                                Text(mon.name).font(.system(size: 8)).lineLimit(1).frame(width: 44)
                            }
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.18)))
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.secondary).offset(x: 3, y: -3)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Take \(mon.name) out of the selection")
                    }
                }
                .padding(.vertical, 3)
            }
            Divider().opacity(0.5)
            Text("Send them to").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(targets) { found in
                let fits = picked.filter { MonTransfer.plan($0.1, from: save.file.game, to: found.game ?? save.file.game).isPossible }.count
                Button {
                    moving = MoveRequest(source: save.id, slots: picked.map(\.0), target: found.id)
                } label: {
                    HStack {
                        Text(found.game?.name ?? found.title).font(.callout)
                        Text(found.source).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(fits == picked.count ? "all \(fits) can go" : "\(fits) of \(picked.count) can go")
                            .font(.caption).foregroundStyle(fits == picked.count ? Color.secondary : (fits == 0 ? Color.red : Color.orange))
                        Image(systemName: "arrow.right.circle.fill").foregroundStyle(fits > 0 ? Theme.accent : Color.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(fits == 0 || found.readOnly != nil || save.found.readOnly != nil)
                .opacity(fits == 0 || found.readOnly != nil ? 0.5 : 1)
            }
            Text("A preview of every change comes before anything is written. Drag or ⌘-click Pokémon to add more.").font(.caption2).foregroundStyle(.tertiary)
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(dropTargeted ? Theme.accent : Color.clear, lineWidth: 1.5))
    }

    private var releaseTitle: String {
        guard let item = releasing, let save = hub.open(item.save) else { return "Release these Pokémon?" }
        if item.slots.count == 1, let mon = save.file.mon(at: item.slots[0]) { return "Release \(mon.name)?" }
        let names = item.slots.compactMap { save.file.mon(at: $0)?.name }
        return "Release \(names.count) Pokémon (\(names.prefix(4).joined(separator: ", "))\(names.count > 4 ? " …" : ""))?"
    }

    /// Pokémon in this game that can evolve right away (trade evolutions).
    @ViewBuilder
    private func evolveBox(_ save: OpenSave) -> some View {
        let candidates = save.file.allSlots.compactMap { slot, mon -> (SlotRef, Mon, TradeEvolution.Option, Bool)? in
            guard let first = TradeEvolution.options(for: mon, in: save.file.game).first else { return nil }
            return (slot, mon, first.option, first.needsItem)
        }
        if !candidates.isEmpty && save.found.readOnly == nil {
            Card {
                HStack {
                    Label("Ready to evolve", systemImage: "sparkles").font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(candidates.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                ForEach(candidates, id: \.0) { slot, mon, option, needsItem in
                    HStack(spacing: 10) {
                        MonIcon(mon: mon, generation: save.file.game.generation, icons: icons, size: 30)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                        MonIcon(mon: { var m = mon; m.species = option.to; m.form = 0; return m }(), generation: save.file.game.generation, icons: icons, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(mon.name) → \(option.name)").font(.callout)
                            Text("\(slot.label) · Lv \(mon.level) · normally \(option.requirement)\(needsItem ? " (the item is given and used up)" : "")")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button("Evolve") {
                            var start = mon
                            if option.heldItem > 0 { start.heldItem = option.heldItem }
                            let result = TradeEvolution.evolve(start, into: option, in: save.file.game)
                            do { try hub.edit(save, slot: slot, to: result.mon) } catch let failure { error = failure.localizedDescription }
                        }
                        .controlSize(.small)
                    }
                }
                Text("Evolving is saved together with your other changes.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    static func status(_ save: FoundSave) -> String {
        if save.error != nil { return "can't be read" }
        if save.count == 0 { return "no Pokémon yet" }
        return "\(save.count) Pokémon"
    }

    static func appName(_ package: String) -> String {
        Emulators.all.first { $0.package == package }?.name ?? package
    }

    /// Runs a write, asking to close the game first when it's open.
    func run(_ saves: [OpenSave], _ action: @escaping () async throws -> Void) {
        Task {
            let open = await hub.runningApps(for: saves)
            if !open.isEmpty {
                closePrompt = ClosePrompt(apps: open, run: action)
                return
            }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }

    private var emptyCard: some View {
        Card {
            Label("No Pokémon saves found", systemImage: "magnifyingglass").font(.callout.weight(.semibold))
            Text("Saves from PokeDaisy, RetroArch, melonDS, Azahar, Dolphin and Peanuts Native show up here once a game has been saved at least once.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var gamePicker: some View {
        Card {
            HStack {
                Text("Your games").font(.headline)
                Spacer()
                Text("\(hub.saves.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(hub.saves) { save in
                        GameRow(save: save, party: hub.open(save.id)?.file.party() ?? [], art: save.game.flatMap { hub.art[$0] },
                                icons: icons, selected: save.id == hub.selection, edited: hub.open(save.id).map(hub.hasUnsavedChanges) ?? false) {
                            withAnimation(.easeOut(duration: 0.15)) { hub.selection = save.id }
                        }
                        .contextMenu {
                            Button("Hide from List") { withAnimation { hub.hide(save) } }
                        }
                    }
                }
            }
            .frame(height: hub.saves.count > 5 ? 5 * 66 + 4 * 6 : nil)
            if let reason = current?.file.readOnlyReason ?? hub.saves.first(where: { $0.id == hub.selection })?.readOnly {
                Label(reason, systemImage: "lock").font(.caption).foregroundStyle(.secondary)
            }
            if !LinkSettings.shared.hiddenPokemonSaves.isEmpty {
                Text("\(LinkSettings.shared.hiddenPokemonSaves.count) hidden · bring them back in Settings ▸ Emulation").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("Right-click a game to hide it.").font(.caption2).foregroundStyle(.tertiary)
            }
            Divider().opacity(0.4)
            statusLine
        }
    }

    /// Always says what's going on: scanning, reading icons, getting artwork, or that everything is ready.
    @ViewBuilder
    private var statusLine: some View {
        if let text = hub.busy ?? hub.phase ?? icons.working {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
                if let progress = hub.progress { ProgressView(value: progress).controlSize(.mini).tint(Theme.accent) }
                else { ProgressView().progressViewStyle(.linear).controlSize(.mini) }
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(readyText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Species in the opened saves that still show a badge instead of an icon.
    private var missingIcons: Int {
        Set(hub.opened.values.flatMap { $0.file.allSlots.map(\.1) }.filter { !$0.isEgg && icons.image(species: $0.species, form: $0.form) == nil }.map(\.species)).count
    }

    private var readyText: String {
        var parts = ["Done"]
        if icons.iconCount > 0 { parts.append("icons for \(icons.iconCount) species") } else { parts.append("no icons yet (they're downloaded once, or read from a GBA/DS Pokémon ROM)") }
        let missing = missingIcons
        if missing > 0 { parts.append("\(missing) species in your games have no icon source yet") }
        if let last = hub.lastScan { parts.append("checked \(last.formatted(date: .omitted, time: .shortened))") }
        return parts.joined(separator: " · ")
    }
}

/// One game in the list: platform tile with the lead Pokémon, title, where it runs, the party and a count.
private struct GameRow: View {
    let save: FoundSave
    let party: [Mon]
    let art: NSImage?
    @ObservedObject var icons: IconCache
    let selected: Bool
    var edited = false
    let action: () -> Void
    @State private var hovering = false

    private var platform: (name: String, colors: [Color]) {
        switch save.game?.family {
        case .gen1, .gen2: return ("Game Boy", [Color(red: 0.45, green: 0.62, blue: 0.28), Color(red: 0.22, green: 0.38, blue: 0.16)])
        case .gen3: return ("GBA", [Color(red: 0.42, green: 0.32, blue: 0.85), Color(red: 0.25, green: 0.18, blue: 0.55)])
        case .colosseum, .xd, .box: return ("GameCube", [Color(red: 0.42, green: 0.28, blue: 0.72), Color(red: 0.20, green: 0.14, blue: 0.40)])
        case .gen4, .gen5: return ("DS", [Color(red: 0.55, green: 0.60, blue: 0.68), Color(red: 0.30, green: 0.33, blue: 0.40)])
        case .gen6, .gen7: return ("3DS", [Color(red: 0.85, green: 0.25, blue: 0.30), Color(red: 0.50, green: 0.10, blue: 0.16)])
        case nil: return ("", [Theme.indigo, Theme.violet])
        default: return ("Switch", [Color(red: 0.95, green: 0.30, blue: 0.28), Color(red: 0.20, green: 0.55, blue: 0.95)])
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: platform.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    if let art {
                        Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                            .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else if let lead = party.first {
                        MonIcon(mon: lead, generation: save.game?.generation ?? 9, icons: icons, size: 34).offset(y: -6)
                    } else {
                        Image(systemName: "gamecontroller.fill").font(.title3).foregroundStyle(.white.opacity(0.8)).offset(y: -8)
                    }
                    Text(platform.name)
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(.black.opacity(art == nil ? 0 : 0.55)))
                        .padding(.bottom, 3)
                }
                .frame(width: 48, height: 48)
                .shadow(color: platform.colors[0].opacity(0.35), radius: 4, y: 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(save.game?.name ?? save.title).font(.callout.weight(.semibold)).lineLimit(1)
                        if save.readOnly != nil { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.tertiary) }
                        if edited {
                            Text("edited").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.accent))
                        }
                    }
                    Text([save.source, save.trainer.isEmpty ? nil : save.trainer,
                          save.modified.map { "saved \($0.formatted(.relative(presentation: .named)))" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if !party.isEmpty {
                        HStack(spacing: 0) {
                            ForEach(Array(party.prefix(6).enumerated()), id: \.offset) { _, mon in
                                MonIcon(mon: mon, generation: save.game?.generation ?? 9, icons: icons, size: 24)
                                    .frame(width: 24, height: 20)
                            }
                        }
                        .opacity(0.9)
                    }
                }
                Spacer(minLength: 4)
                Text(save.count > 0 ? "\(save.count)" : "–")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(selected ? Theme.accent.opacity(0.35) : Color.white.opacity(0.08)))
                    .help(PokemonView.status(save))
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? AnyShapeStyle(LinearGradient(colors: [Theme.accent.opacity(0.22), Theme.violet.opacity(0.12)], startPoint: .leading, endPoint: .trailing))
                                   : AnyShapeStyle(Color.white.opacity(hovering ? 0.07 : 0.035)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(Theme.bifrost) : AnyShapeStyle(Theme.hairline), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

private struct DragIfFilled: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id { content.draggable(id) } else { content }
    }
}

extension SlotRef {
    /// "pk|<save path>|party:2" or "pk|<save path>|box:3:14"
    func dragID(save: String) -> String { "pk|\(save)|" + (area == .party ? "party:\(index)" : "box:\(box):\(index)") }

    /// Parses a drag id; returns the slot and the save it came from.
    static func parse(dragID: String) -> (save: String, slot: SlotRef)? {
        let outer = dragID.components(separatedBy: "|")
        guard outer.count == 3, outer[0] == "pk" else { return nil }
        let parts = outer[2].split(separator: ":").map(String.init)
        if parts.count == 2, parts[0] == "party", let i = Int(parts[1]) { return (outer[1], .party(i)) }
        if parts.count == 3, parts[0] == "box", let b = Int(parts[1]), let i = Int(parts[2]) { return (outer[1], .box(b, i)) }
        return nil
    }
}

/// Party and boxes of one save.
private struct SaveContents: View {
    @ObservedObject var save: OpenSave
    @ObservedObject var hub: PokemonHub
    @Binding var box: Int
    @Binding var picked: PokemonView.PickedMon?
    @Binding var selected: Set<SlotRef>
    let onError: (String) -> Void
    let onRename: (SlotRef) -> Void
    let onRelease: ([SlotRef]) -> Void
    let requestMove: ([SlotRef], String) -> Void

    private func tile(_ slot: SlotRef, generation: Int) -> some View {
        let mon = slot.area == .box && slot.box >= save.file.boxCount ? nil : save.file.mon(at: slot)
        return SlotView(mon: mon, generation: generation, icons: hub.icons, selected: selected.contains(slot), action: {
            guard mon != nil else { return }
            if NSEvent.modifierFlags.contains(.command) { toggle(slot) }
            else { picked = .init(save: save.id, slot: slot) }
        })
        .contextMenu { if let mon { menu(for: slot, mon: mon) } }
        .modifier(DragIfFilled(id: mon == nil ? nil : slot.dragID(save: save.id)))
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.compactMap(SlotRef.parse(dragID:)).first, item.save == save.id, item.slot != slot else { return false }
            do { try hub.organize(save, from: item.slot, to: slot) } catch { onError(error.localizedDescription) }
            selected.remove(item.slot)
            return true
        }
    }

    private func sort(_ order: PokemonHub.BoxOrder, ascending: Bool) {
        do { try hub.sortBoxes(save, by: order, ascending: ascending); box = 0 } catch { onError(error.localizedDescription) }
    }

    /// Dropping on a box arrow moves the Pokémon to the first free slot of that box.
    private func dropOnArrow(_ items: [String], to target: Int) -> Bool {
        guard let item = items.compactMap(SlotRef.parse(dragID:)).first, item.save == save.id,
              let free = (0..<save.file.boxSize).first(where: { save.file.mon(at: .box(target, $0)) == nil }) else { return false }
        do { try hub.organize(save, from: item.slot, to: .box(target, free)) } catch { onError(error.localizedDescription); return false }
        box = target
        return true
    }

    private func toggle(_ slot: SlotRef) {
        if selected.contains(slot) { selected.remove(slot) }
        else if let mon = save.file.mon(at: slot), canSendAnywhere(mon) { selected.insert(slot) }
    }

    /// True when at least one other listed game can take this Pokémon.
    private func canSendAnywhere(_ mon: Mon) -> Bool {
        guard save.found.readOnly == nil else { return false }
        return hub.saves.contains { found in
            found.id != save.id && found.error == nil && found.readOnly == nil && found.game != nil &&
                MonTransfer.plan(mon, from: save.file.game, to: found.game!).isPossible
        }
    }

    @ViewBuilder
    private func menu(for slot: SlotRef, mon: Mon) -> some View {
        Button("Details…") { picked = .init(save: save.id, slot: slot) }
        if selected.contains(slot) {
            Button("Remove from Batch Send") { toggle(slot) }
        } else if canSendAnywhere(mon) {
            Button("Add to Batch Send") { toggle(slot) }
        }
        Divider()
        let group = selected.contains(slot) && selected.count > 1 ? Array(selected) : [slot]
        let mons = group.compactMap { save.file.mon(at: $0) }
        // Only games at least one of them can go to.
        let targets = save.found.readOnly != nil ? [] : hub.saves.filter { found in
            found.id != save.id && found.error == nil && found.readOnly == nil && found.game != nil &&
                mons.contains { MonTransfer.plan($0, from: save.file.game, to: found.game!).isPossible }
        }
        if !targets.isEmpty {
            Menu(group.count > 1 ? "Move \(group.count) Pokémon to" : "Move to") {
                ForEach(targets) { found in
                    Button("\(found.game?.name ?? found.title) · \(found.source)") { requestMove(group, found.id) }
                }
            }
        }
        let evolutions = TradeEvolution.options(for: mon, in: save.file.game)
        if !evolutions.isEmpty && save.found.readOnly == nil {
            ForEach(evolutions, id: \.option.id) { entry in
                Button("Evolve into \(entry.option.name)") {
                    var start = mon
                    if entry.option.heldItem > 0 { start.heldItem = entry.option.heldItem }
                    let result = TradeEvolution.evolve(start, into: entry.option, in: save.file.game)
                    do { try hub.edit(save, slot: slot, to: result.mon) } catch { onError(error.localizedDescription) }
                }
            }
        }
        if save.found.readOnly == nil && !mon.isEgg {
            Divider()
            Button("Rename…") { onRename(slot) }
            if group.count > 1 {
                Button("Release \(group.count) Pokémon…", role: .destructive) { onRelease(group) }
            } else {
                Button("Release…", role: .destructive) { onRelease([slot]) }
            }
        }
    }

    var body: some View {
        let file = save.file
        let generation = file.game.generation
        VStack(alignment: .leading, spacing: 12) {
            Card {
                Text("Party").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(0..<6, id: \.self) { i in tile(.party(i), generation: generation) }
                }
            }
            Card {
                HStack {
                    Button { box = (box - 1 + file.boxCount) % max(file.boxCount, 1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless)
                        .dropDestination(for: String.self) { items, _ in dropOnArrow(items, to: (box - 1 + file.boxCount) % max(file.boxCount, 1)) }
                    Spacer()
                    Text(file.boxName(box)).font(.callout.weight(.semibold))
                    Text("\(box + 1)/\(file.boxCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Menu {
                        Section("Sort all boxes by") {
                            ForEach(PokemonHub.BoxOrder.allCases, id: \.self) { order in
                                Button(order.label(ascending: true)) { sort(order, ascending: true) }
                                Button(order.label(ascending: false)) { sort(order, ascending: false) }
                            }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Sort the Pokémon in all boxes")
                    .disabled(save.found.readOnly != nil)
                    Spacer()
                    Button { box = (box + 1) % max(file.boxCount, 1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.borderless)
                        .dropDestination(for: String.self) { items, _ in dropOnArrow(items, to: (box + 1) % max(file.boxCount, 1)) }
                }
                let columns = file.boxSize == 25 ? 5 : 6
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
                    ForEach(0..<file.boxSize, id: \.self) { i in tile(.box(box, i), generation: generation) }
                }
            }
            .id(save.revision)
        }
    }
}

/// One square with the Pokémon's icon (or a badge when no ROM icon is available) and its name.
private struct SlotView: View {
    let mon: Mon?
    let generation: Int
    @ObservedObject var icons: IconCache
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                ZStack {
                    if let mon {
                        MonIcon(mon: mon, generation: generation, icons: icons, size: 50)
                        if mon.isShiny {
                            Image(systemName: "sparkle").font(.system(size: 8, weight: .bold)).foregroundStyle(.yellow)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(2)
                        }
                        if !mon.isEgg {
                            Text("Lv\(mon.level)")
                                .font(.system(size: 8, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(Capsule().fill(.black.opacity(0.45)))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                Text(mon?.name ?? " ")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.accent.opacity(0.25) : (mon == nil ? Color.white.opacity(0.03) : Theme.panel)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mon.map { "\($0.name) · \($0.speciesName) · Lv \($0.level)" } ?? "")
    }
}

/// The usual type colours.
enum TypeColor {
    static func color(_ type: Int) -> Color {
        let hex: [Int: UInt32] = [1: 0x9FA19F, 2: 0xFF8000, 3: 0x81B9EF, 4: 0x9141CB, 5: 0x915121, 6: 0xAFA981, 7: 0x91A119, 8: 0x704170, 9: 0x60A1B8,
                                  10: 0xE62829, 11: 0x2980EF, 12: 0x3FA129, 13: 0xFAC000, 14: 0xEF4179, 15: 0x3DCEF3, 16: 0x5060E1, 17: 0x624D4E, 18: 0xEF70EF]
        let v = hex[type] ?? 0x888888
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

struct MonIcon: View {
    let mon: Mon
    let generation: Int
    @ObservedObject var icons: IconCache
    var size: CGFloat = 36

    var body: some View {
        if mon.isEgg {
            Image(systemName: "oval.portrait.fill").font(.system(size: size * 0.45)).foregroundStyle(.white.opacity(0.7))
        } else if let image = icons.image(species: mon.species, form: mon.form, preferredGeneration: generation) {
            Image(nsImage: image).interpolation(.none).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: size * 1.2, maxHeight: size)
        } else {
            Text(String(PokeData.shared.speciesName(mon.species).prefix(2)))
                .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size * 0.8, height: size * 0.8)
                .background(Circle().fill(Self.color(for: mon)))
        }
    }

    static func color(for mon: Mon) -> Color {
        let type = PokeData.shared.monData(species: mon.species, form: mon.form)?.types.first ?? 1
        let colors: [Int: Color] = [1: .gray, 2: .brown, 3: .cyan, 4: .purple, 5: .orange, 6: .brown, 7: .green, 8: .indigo, 9: .gray,
                                    10: .red, 11: .blue, 12: .green, 13: .yellow, 14: .pink, 15: .teal, 16: .indigo, 17: .black, 18: .pink]
        return (colors[type] ?? .gray).opacity(0.75)
    }
}

/// Everything about one Pokémon: details, moves, trade evolution and moving it to another game.
private struct MonDetailSheet: View {
    @ObservedObject var hub: PokemonHub
    @ObservedObject var save: OpenSave
    let slot: SlotRef
    @State var mon: Mon
    let run: ([OpenSave], @escaping () async throws -> Void) -> Void
    let dismiss: () -> Void

    @State private var showAllMoves = false
    @State private var transferTarget: OpenSave?
    @State private var message: String?
    private var working: Bool { hub.busy != nil }

    init(hub: PokemonHub, save: OpenSave, slot: SlotRef, mon: Mon, run: @escaping ([OpenSave], @escaping () async throws -> Void) -> Void, dismiss: @escaping () -> Void) {
        self.hub = hub
        self.save = save
        self.slot = slot
        self._mon = State(initialValue: mon)
        self.run = run
        self.dismiss = dismiss
    }

    private var game: PKGame { save.file.game }
    private var original: Mon? { save.file.mon(at: slot) }
    private var changed: Bool {
        original.map { $0.moves != mon.moves || $0.species != mon.species || $0.heldItem != mon.heldItem
            || $0.nickname != mon.nickname || $0.isNicknamed != mon.isNicknamed } ?? false
    }
    private var readOnly: String? { save.file.readOnlyReason ?? save.found.readOnly }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let message { Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                    summary
                    moves
                    evolution
                    sendTo
                }
                .padding(16)
            }
            Divider()
            footer.padding(12)
        }
        .frame(width: 440, height: 600)
        .sheet(isPresented: Binding(get: { transferTarget != nil }, set: { if !$0 { transferTarget = nil } })) {
            if let target = transferTarget {
                MoveSheet(hub: hub, source: save, slots: [slot], target: target, run: run) { moved in
                    transferTarget = nil
                    if moved { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            MonIcon(mon: mon, generation: game.generation, icons: hub.icons, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if readOnly == nil && !mon.isEgg {
                        TextField(PokeData.shared.speciesName(mon.species), text: Binding(
                            get: { mon.isNicknamed ? mon.nickname : "" },
                            set: { mon = PokemonHub.renamed(mon, to: $0, in: game) }))
                            .textFieldStyle(.plain)
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: 200)
                            .help("Nickname (up to \(PokemonHub.maxNameLength(game)) characters; empty = normal name)")
                        Image(systemName: "pencil").font(.caption).foregroundStyle(.tertiary)
                    } else {
                        Text(mon.name).font(.title3.weight(.semibold))
                    }
                    if mon.isShiny { Image(systemName: "sparkles").foregroundStyle(.yellow) }
                }
                Text("\(mon.speciesName) · Lv \(mon.level) · \(game.title)").font(.caption).foregroundStyle(.secondary)
                Text("\(slot.label) · OT \(mon.otName) (\(String(format: "%05d", mon.tid)))").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    /// Games only store stats for party Pokémon; boxed ones are calculated the way the game does.
    private var shownStats: [Int] {
        if mon.stats.count == 6 && mon.stats.contains(where: { $0 > 0 }) { return mon.stats }
        var copy = mon
        if game.generation <= 2 { copy.recalculateStatsGB() } else { copy.recalculateStats() }
        return copy.stats.count == 6 ? copy.stats : [0, 0, 0, 0, 0, 0]
    }

    private var summary: some View {
        let data = PokeData.shared
        let stats = ["HP", "Atk", "Def", "Spe", "SpA", "SpD"]
        let values = shownStats
        let types = Array(Set(data.monData(species: mon.species, form: mon.form)?.types ?? [])).sorted()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(types, id: \.self) { type in
                    Text(data.typeName(type))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(TypeColor.color(type)))
                }
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if game.generation >= 3 {
                    GridRow { Text("Nature").foregroundStyle(.secondary); Text(data.natureName(mon.nature)) }
                    GridRow { Text("Ability").foregroundStyle(.secondary); Text(data.abilityName(mon.ability) + (mon.abilitySlot == 2 ? " (hidden)" : "")) }
                }
                if game.generation >= 2 {
                    GridRow { Text("Held item").foregroundStyle(.secondary); Text(data.itemName(mon.heldItem)) }
                }
            }
            .font(.callout)
            HStack(spacing: 4) {
                ForEach(0..<6, id: \.self) { i in
                    VStack(spacing: 1) {
                        Text(stats[i]).font(.caption2).foregroundStyle(.secondary)
                        Text("\(values[safe: i] ?? 0)").font(.caption.monospacedDigit().weight(.semibold))
                        Text(game.generation <= 2 ? "DV \((mon.ivs[i] - 1) / 2)" : "IV \(mon.ivs[i])").font(.system(size: 9).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var moves: some View {
        let options = MoveSuggester.options(for: mon, in: game, includeAll: showAllMoves)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Moves").font(.headline)
                Spacer()
                Toggle("Show TMs, tutors and egg moves", isOn: $showAllMoves).toggleStyle(.switch).controlSize(.mini).font(.caption)
            }
            ForEach(0..<4, id: \.self) { i in
                HStack {
                    Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 14)
                    Picker("Move \(i + 1)", selection: Binding(get: { mon.moves[i] }, set: { setMove(i, $0) })) {
                        Text("—").tag(0)
                        if mon.moves[i] != 0 && !options.contains(where: { $0.move == mon.moves[i] }) {
                            Text("\(PokeData.shared.moveName(mon.moves[i])) (current)").tag(mon.moves[i])
                        }
                        ForEach(options.filter { $0.move == mon.moves[i] || !mon.moves.contains($0.move) }) { option in
                            Text("\(option.name)  ·  \(option.source.badge)").tag(option.move)
                        }
                    }
                    .labelsHidden()
                    if let move = PokeData.shared.move(mon.moves[i]) {
                        Text("\(PokeData.shared.typeName(move.type)) · \(move.pp) PP").font(.caption2).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                    }
                }
            }
            Button("Use the moves it would know at level \(mon.level)") {
                mon.moves = MoveSuggester.latestLevelUp(for: mon, in: game)
                mon.ppUps = [0, 0, 0, 0]
                mon.healPP()
            }
            .controlSize(.small)
            Text("The list shows moves \(mon.speciesName) learns by level up to \(mon.level) in \(game.name)\(showAllMoves ? ", plus TM, tutor, egg and relearnable moves" : "").")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func setMove(_ index: Int, _ move: Int) {
        mon.moves[index] = move
        mon.ppUps[index] = 0
        mon.pp[index] = Mon.maxPP(move: move, ppUps: 0)
        // Keep moves packed at the top like the games do.
        let packed = mon.moves.enumerated().filter { $0.element != 0 }
        if packed.count < 4 {
            let order = packed.map(\.offset) + (0..<4).filter { mon.moves[$0] == 0 }
            mon.moves = order.map { mon.moves[$0] }
            mon.pp = order.map { mon.pp[$0] }
            mon.ppUps = order.map { mon.ppUps[$0] }
        }
    }

    @ViewBuilder
    private var evolution: some View {
        let options = TradeEvolution.options(for: mon, in: game)
        if !options.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Trade evolution").font(.headline)
                ForEach(options, id: \.option.id) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Evolve into \(entry.option.name)").font(.callout)
                            Text("Normally \(entry.option.requirement).").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(entry.needsItem ? "Give item & Evolve" : "Evolve") { evolve(entry.option) }
                            .disabled(readOnly != nil)
                    }
                }
            }
        }
    }

    private func evolve(_ option: TradeEvolution.Option) {
        var start = mon
        if option.heldItem > 0 { start.heldItem = option.heldItem }
        let result = TradeEvolution.evolve(start, into: option, in: game)
        mon = result.mon
        var text = result.notes.joined(separator: " ")
        if !result.newMoves.isEmpty {
            text += " It can learn \(result.newMoves.map(PokeData.shared.moveName).joined(separator: ", ")) now — pick it in the moves list."
        }
        message = text + " Save to keep it."
    }

    @ViewBuilder
    private var sendTo: some View {
        let others = hub.saves.filter { $0.id != save.id && $0.error == nil }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Move to another game").font(.headline)
                ForEach(others) { found in
                    let plan = MonTransfer.plan(mon, from: game, to: found.game ?? game)
                    let target = hub.open(found.id)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(found.title) · \(found.source)").font(.callout)
                            if let blocked = plan.blocked {
                                Text(blocked).font(.caption).foregroundStyle(.orange)
                            } else if let reason = target?.file.readOnlyReason ?? found.readOnly {
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(plan.native ? "Possible in the real games" : "Not possible in the real games — it gets rebuilt")
                                    .font(.caption).foregroundStyle(plan.native ? Color.secondary : Color.orange)
                            }
                        }
                        Spacer()
                        Button("Move…") { transferTarget = target }
                            .disabled(!plan.isPossible || target == nil || readOnly != nil || changed || (target?.file.readOnlyReason ?? found.readOnly) != nil)
                    }
                    .opacity(plan.isPossible ? 1 : 0.6)
                }
                if changed { Text("Save your changes first, then move it.").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let readOnly { Label(readOnly, systemImage: "lock").font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(working ? "Saving…" : "Save to \(DeviceInfo.name)") { saveChanges() }
                .buttonStyle(.borderedProminent)
                .disabled(!changed || readOnly != nil || working)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func saveChanges() {
        do {
            try hub.update(save, slot: slot, with: mon)
        } catch {
            message = error.localizedDescription
            return
        }
        run([save]) {
            try await hub.write([save])
            hub.toast?("checkmark.circle", "Saved \(mon.name) in \(save.found.title)")
            dismiss()
        }
    }
}

/// Asks for a new nickname (empty = the normal species name).
private struct RenameSheet: View {
    let mon: Mon
    let game: PKGame
    let done: (String?) -> Void
    @State private var name: String

    init(mon: Mon, game: PKGame, done: @escaping (String?) -> Void) {
        self.mon = mon
        self.game = game
        self.done = done
        _name = State(initialValue: mon.isNicknamed ? mon.nickname : "")
    }

    var body: some View {
        let limit = PokemonHub.maxNameLength(game)
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(mon.name)").font(.headline)
            TextField(PokeData.shared.speciesName(mon.species), text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) { _, new in if new.count > limit { name = String(new.prefix(limit)) } }
                .onSubmit { done(name) }
            Text("Up to \(limit) characters in \(game.name). Leave it empty to use the normal name.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Rename") { done(name) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// The preview shown before moving one or more Pokémon to another game.
private struct MoveSheet: View {
    @ObservedObject var hub: PokemonHub
    let source: OpenSave
    let slots: [SlotRef]
    let target: OpenSave
    let run: ([OpenSave], @escaping () async throws -> Void) -> Void
    let done: (Bool) -> Void

    private struct Item: Identifiable {
        let slot: SlotRef
        let mon: Mon
        let plan: TransferPlan
        var id: SlotRef { slot }
        var changes: [String] { plan.changes.filter { !$0.hasPrefix("This move isn't possible") } }
    }

    private var items: [Item] {
        slots.sorted { ($0.area == .party ? 0 : 1, $0.box, $0.index) < ($1.area == .party ? 0 : 1, $1.box, $1.index) }.compactMap { slot in
            source.file.mon(at: slot).map { Item(slot: slot, mon: $0, plan: MonTransfer.plan($0, from: source.file.game, to: target.file.game)) }
        }
    }

    var body: some View {
        let items = self.items
        let movable = items.filter { $0.plan.isPossible }
        let rebuilt = movable.contains { !$0.plan.native }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(items.count == 1 ? "Move \(items[0].mon.name) to \(target.found.title)?" : "Move \(movable.count) Pokémon to \(target.found.title)?")
                    .font(.headline)
                Text("They leave \(source.found.title) and go into the first free box slots.").font(.caption).foregroundStyle(.secondary)
            }
            if rebuilt {
                Label("The real games can't do this. They're rebuilt so \(target.file.game.name) accepts them.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 10) {
                            MonIcon(mon: item.mon, generation: source.file.game.generation, icons: hub.icons, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(item.mon.name) · Lv \(item.mon.level)").font(.callout.weight(.medium))
                                if let blocked = item.plan.blocked {
                                    Label("Stays here: \(blocked)", systemImage: "nosign").font(.caption).foregroundStyle(.orange)
                                } else if item.changes.isEmpty {
                                    Text("Nothing about it changes.").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    ForEach(item.changes, id: \.self) { change in
                                        Label(change, systemImage: "arrow.turn.down.right").font(.caption)
                                    }
                                    Text("Moves after: \(item.plan.mon.moves.filter { $0 != 0 }.map(PokeData.shared.moveName).joined(separator: ", "))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .opacity(item.plan.isPossible ? 1 : 0.6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            Text("Both saves are backed up to this Mac first (Saves tab).").font(.caption2).foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Cancel") { done(false) }.keyboardShortcut(.cancelAction)
                Button(movable.count == 1 ? "Move" : "Move \(movable.count)") {
                    let work = movable.map { (slot: $0.slot, plan: $0.plan) }
                    run([source, target]) {
                        try await hub.moveMany(work, from: source, to: target)
                        done(true)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(movable.isEmpty || hub.busy != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct PokemonHeaderActions: View {
    @ObservedObject var hub: PokemonHub

    var body: some View {
        Button {
            Task {
                await hub.scan()
                await hub.icons.build(roms: hub.roms)
                await hub.fetchArt()
            }
        } label: {
            if hub.scanning { ProgressView().controlSize(.mini) } else { Label("Rescan", systemImage: "arrow.clockwise") }
        }
        .disabled(hub.scanning || hub.serial == nil)
        .help("Look for Pokémon saves again")
    }
}
