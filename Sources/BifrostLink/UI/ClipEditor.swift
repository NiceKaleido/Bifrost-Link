import SwiftUI
import AVKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum ClipEditorWindow {
    private static var windows: [URL: NSWindow] = [:]

    static func open(_ url: URL) {
        if let existing = windows[url] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Clip · \(url.lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ClipEditorView(url: url).preferredColorScheme(.dark).tint(Theme.accent))
        window.center()
        windows[url] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            Task { @MainActor in windows[url] = nil }
        }
        window.makeKeyAndOrderFront(nil)
    }

    static func chooseAndOpen(startingIn folder: URL) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.message = "Choose a recording or replay to make a clip from"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
}

enum ClipFormat: String, CaseIterable, Identifiable {
    case mp4, gif
    var id: String { rawValue }
    var title: String { self == .mp4 ? "MP4 video" : "GIF" }
}

enum ClipSize: String, CaseIterable, Identifiable {
    case original, p1080, p720, p480
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "Original"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        }
    }
    var preset: String {
        switch self {
        case .original: return AVAssetExportPresetHighestQuality
        case .p1080: return AVAssetExportPreset1920x1080
        case .p720: return AVAssetExportPreset1280x720
        case .p480: return AVAssetExportPreset640x480
        }
    }
    var gifWidth: CGFloat {
        switch self {
        case .original, .p1080: return 640
        case .p720: return 480
        case .p480: return 320
        }
    }
}

@MainActor
final class ClipModel: ObservableObject {
    let url: URL
    let asset: AVURLAsset
    let player: AVPlayer
    @Published var duration: Double = 0
    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published var format: ClipFormat = .mp4
    @Published var size: ClipSize = .original
    @Published var mute = false
    @Published var hasAudio = false
    @Published private(set) var exporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var result: URL?
    @Published private(set) var problem: String?
    private var session: AVAssetExportSession?
    private var gifTask: Task<Void, Never>?
    private var loopObserver: Any?

    init(url: URL) {
        self.url = url
        asset = AVURLAsset(url: url)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        Task { await load() }
    }

    private func load() async {
        guard let time = try? await asset.load(.duration) else {
            problem = "This file can’t be read as a video."
            return
        }
        duration = max(0, time.seconds)
        end = duration
        hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
        loopObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.end > self.start, time.seconds >= self.end else { return }
                self.player.seek(to: CMTime(seconds: self.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    var length: Double { max(0, end - start) }

    func setStart(_ value: Double) {
        start = min(max(0, value), max(0, end - 0.2))
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setEnd(_ value: Double) {
        end = max(min(duration, value), start + 0.2)
        player.seek(to: CMTime(seconds: max(start, end - 1), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    var playhead: Double { player.currentTime().seconds }

    private func outputURL(_ ext: String) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent + " clip"
        var candidate = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    func export() {
        guard !exporting, length > 0 else { return }
        problem = nil
        result = nil
        progress = 0
        exporting = true
        player.pause()
        if format == .gif { exportGIF() } else { Task { await exportMP4() } }
    }

    func cancel() {
        session?.cancelExport()
        gifTask?.cancel()
    }

    private func exportMP4() async {
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        let composition = AVMutableComposition()
        do {
            for track in try await asset.loadTracks(withMediaType: .video) {
                let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                try target?.insertTimeRange(range, of: track, at: .zero)
                target?.preferredTransform = try await track.load(.preferredTransform)
            }
            if !mute {
                for track in try await asset.loadTracks(withMediaType: .audio) {
                    let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    try target?.insertTimeRange(range, of: track, at: .zero)
                }
            }
        } catch {
            finish(nil, "The video couldn’t be prepared: \(error.localizedDescription)")
            return
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: size.preset) else {
            finish(nil, "This size isn’t available for this video.")
            return
        }
        let output = outputURL("mp4")
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        self.session = session
        let poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.progress = Double(session.progress)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        poll.cancel()
        self.session = nil
        switch session.status {
        case .completed: finish(output, nil)
        case .cancelled:
            try? FileManager.default.removeItem(at: output)
            finish(nil, nil)
        default:
            try? FileManager.default.removeItem(at: output)
            finish(nil, session.error?.localizedDescription ?? "Export failed")
        }
    }

    private func exportGIF() {
        let output = outputURL("gif")
        let fps = 15.0
        let start = start, end = end, width = size.gifWidth
        let asset = asset
        gifTask = Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: width, height: 0)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.03, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.03, preferredTimescale: 600)
            let count = max(1, Int((end - start) * fps))
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
                self?.finish(nil, "The GIF couldn’t be created.")
                return
            }
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
            for index in 0..<count {
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: output)
                    self?.finish(nil, nil)
                    return
                }
                let time = CMTime(seconds: start + Double(index) / fps, preferredTimescale: 600)
                if let image = try? await generator.image(at: time).image {
                    CGImageDestinationAddImage(destination, image, frameProperties)
                }
                self?.progress = Double(index + 1) / Double(count)
            }
            let ok = CGImageDestinationFinalize(destination)
            self?.finish(ok ? output : nil, ok ? nil : "The GIF couldn’t be written.")
        }
    }

    private func finish(_ output: URL?, _ message: String?) {
        exporting = false
        gifTask = nil
        result = output
        problem = message
        if let output { Log.write("clip exported: \(output.lastPathComponent)") }
    }

    func stop() {
        player.pause()
        if let loopObserver { player.removeTimeObserver(loopObserver) }
        loopObserver = nil
        cancel()
    }
}

struct ClipEditorView: View {
    @StateObject private var model: ClipModel

    init(url: URL) {
        _model = StateObject(wrappedValue: ClipModel(url: url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VideoPlayer(player: model.player)
                .frame(minHeight: 280)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            trimControls
            Divider().opacity(0.5)
            HStack(spacing: 16) {
                Picker("Format", selection: $model.format) {
                    ForEach(ClipFormat.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Picker("Size", selection: $model.size) {
                    ForEach(ClipSize.allCases) { size in
                        Text(model.format == .gif ? "\(Int(size.gifWidth)) px wide" : size.title).tag(size)
                    }
                }
                .frame(width: 200)
                if model.format == .mp4 && model.hasAudio {
                    Toggle("No sound", isOn: $model.mute).toggleStyle(.checkbox)
                }
                Spacer()
            }
            .disabled(model.exporting)
            footer
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 540)
        .onDisappear { model.stop() }
    }

    private var trimControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Clip").font(.headline)
                Text("\(time(model.start)) – \(time(model.end)) · \(time(model.length))")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Start Here") { model.setStart(model.playhead) }
                Button("End Here") { model.setEnd(model.playhead) }
                Button("Whole Video") {
                    model.setStart(0)
                    model.setEnd(model.duration)
                }
            }
            .controlSize(.small)
            row("Start", value: Binding(get: { model.start }, set: { model.setStart($0) }))
            row("End", value: Binding(get: { model.end }, set: { model.setEnd($0) }))
            if model.format == .gif && model.length > 30 {
                Label("GIFs longer than 30 seconds get very big. A short moment works best.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .disabled(model.exporting || model.duration == 0)
    }

    private func row(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 34, alignment: .leading)
            Slider(value: value, in: 0...max(model.duration, 0.1))
            Text(time(value.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if model.exporting {
                ProgressView(value: model.progress).frame(maxWidth: 260)
                Text("\(Int(model.progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancel() }
            } else {
                if let result = model.result {
                    Label("Saved \(result.lastPathComponent)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).lineLimit(1).truncationMode(.middle)
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([result]) }
                        .buttonStyle(.borderless)
                } else if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(2)
                } else {
                    Text("Saved next to the original.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.format == .gif ? "Make GIF" : "Export Clip") { model.export() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.length <= 0 || model.duration == 0)
            }
        }
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let tenths = Int((seconds - Double(total)) * 10)
        return String(format: "%d:%02d.%d", total / 60, total % 60, tenths)
    }
}
