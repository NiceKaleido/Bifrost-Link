import SwiftUI

struct ActivityPanel: View {
    @ObservedObject var files: FileService
    @ObservedObject var hub: EmulationHub
    @ObservedObject var ports: PortCatalog
    @AppStorage("activityExpanded") private var expanded = true

    private var ordered: [Transfer] {
        let rank: (Transfer) -> Int = {
            switch $0.status {
            case .running: return 0
            case .queued: return 1
            default: return 2
            }
        }
        return files.transfers.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    private var orderedJobs: [ShrinkJob] {
        let rank: (ShrinkJob) -> Int = {
            switch $0.status {
            case .running: return 0
            case .queued: return 1
            default: return 2
            }
        }
        return hub.shrinkJobs.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    private var summary: String {
        var parts: [String] = []
        let active = files.transfers.filter(\.isActive)
        if !active.isEmpty {
            let total = files.transfers.filter { $0.isActive || $0.status == .done }
            let done = total.count - active.count
            let bytes = total.reduce(Int64(0)) { $0 + $1.totalBytes }
            let moved = total.reduce(Int64(0)) { $0 + ($1.status == .done ? $1.totalBytes : $1.transferred) }
            parts.append("\(done + 1) of \(total.count) · \(moved.bytesText) of \(bytes.bytesText)")
        }
        let installing = ports.jobs.filter(\.isActive)
        if !installing.isEmpty {
            parts.append(installing.count == 1 ? "Installing \(installing[0].portName)" : "Installing \(installing.count) ports")
        }
        let shrinking = hub.shrinkJobs.filter(\.isActive)
        if !shrinking.isEmpty {
            let total = hub.shrinkJobs.filter { $0.isActive || { if case .done = $0.status { return true }; return false }($0) }.count
            parts.append("Shrinking \(total - shrinking.count + 1) of \(total)")
        }
        if parts.isEmpty {
            let finished = files.transfers.filter { $0.status == .done }.count + hub.shrinkJobs.filter { if case .done = $0.status { return true }; return false }.count
            return finished == 1 ? "1 task finished" : "\(finished) tasks finished"
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if !files.transfers.isEmpty || !hub.shrinkJobs.isEmpty || !ports.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                header
                if expanded {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(ports.jobs) { job in
                                PortJobRow(job: job, catalog: ports)
                            }
                            ForEach(orderedJobs) { job in
                                ShrinkJobRow(job: job) { hub.cancelShrink(job.id) }
                            }
                            ForEach(ordered) { t in
                                TransferRow(transfer: t) { files.cancel(t) }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
            .padding(12)
            .background(.bar)
            .overlay(alignment: .top) { Divider().opacity(0.5) }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Activity").font(.caption.weight(.semibold))
                    Text(summary).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 4)
            if files.activeCount + hub.shrinkJobs.filter(\.isActive).count + ports.jobs.filter(\.isActive).count > 1 {
                Button("Cancel All") {
                    files.cancelAll()
                    hub.cancelAllShrinks()
                    ports.jobs.filter(\.isActive).forEach { ports.cancel($0.id) }
                }.buttonStyle(.borderless).font(.caption)
            }
            if files.transfers.contains(where: { !$0.isActive }) || hub.shrinkJobs.contains(where: { !$0.isActive }) || ports.jobs.contains(where: { !$0.isActive }) {
                Button("Clear") { files.clearFinished(); hub.clearFinishedShrinks(); ports.clearFinished() }.buttonStyle(.borderless).font(.caption)
            }
        }
    }
}

struct ShrinkJobRow: View {
    let job: ShrinkJob
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.right.and.arrow.up.left.circle.fill").foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.candidate.name).font(.caption).lineLimit(1).truncationMode(.middle)
                switch job.status {
                case .queued:
                    Text("Waiting to shrink · \(job.candidate.size.bytesText)").font(.caption2).foregroundStyle(.secondary)
                case .running:
                    if let fraction = job.fraction {
                        ProgressView(value: fraction).controlSize(.mini).tint(Theme.violet)
                            .animation(.linear(duration: 0.4), value: fraction)
                        Text("\(job.step) · \(Int(fraction * 100))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.mini)
                        Text(job.step).font(.caption2).foregroundStyle(.secondary)
                    }
                case .done(let saved):
                    Text("Shrunk to \(job.candidate.outName.split(separator: ".").last.map { $0.uppercased() } ?? "") · saved \(saved.bytesText)").font(.caption2).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.caption2).foregroundStyle(.red).lineLimit(2)
                case .cancelled:
                    Text("Cancelled, nothing changed").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if job.isActive {
                Button(action: cancel) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(job.status == .queued ? "Remove from the queue" : "Stop shrinking this game")
                    .accessibilityLabel("Cancel shrinking")
            }
        }
    }

    private var tint: Color {
        switch job.status {
        case .queued, .cancelled: return .secondary
        case .running: return Theme.violet
        case .done: return .green
        case .failed: return .red
        }
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
                case .queued:
                    Text("Waiting · \(transfer.totalBytes.bytesText)").font(.caption2).foregroundStyle(.secondary)
                case .running:
                    if transfer.totalBytes > 0 {
                        ProgressView(value: transfer.progress).controlSize(.mini).tint(Theme.accent)
                            .animation(.linear(duration: 0.9), value: transfer.progress)
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
            if transfer.isActive, let onCancel {
                Button(action: onCancel) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(transfer.status == .queued ? "Remove from the queue" : "Cancel this transfer")
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
        case .queued: return .secondary
        case .running: return Theme.accent
        case .done: return .green
        case .cancelled: return .secondary
        case .failed: return .red
        }
    }
}
