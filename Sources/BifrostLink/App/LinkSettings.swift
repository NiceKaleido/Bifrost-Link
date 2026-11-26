import Foundation
import Combine

enum ScreenLayout: String, CaseIterable, Identifiable {
    case stacked
    case sideBySide
    case overlay
    case topOnly
    case bottomOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stacked: return "Stacked"
        case .sideBySide: return "Side by Side"
        case .overlay: return "Overlay"
        case .topOnly: return "Top Only"
        case .bottomOnly: return "Bottom Only"
        }
    }

    var symbol: String {
        switch self {
        case .stacked: return "rectangle.split.1x2"
        case .sideBySide: return "rectangle.split.2x1"
        case .overlay: return "pip"
        case .topOnly: return "rectangle.tophalf.filled"
        case .bottomOnly: return "rectangle.bottomhalf.filled"
        }
    }

    var shortcut: Character {
        switch self {
        case .stacked: return "1"
        case .sideBySide: return "2"
        case .overlay: return "3"
        case .topOnly: return "4"
        case .bottomOnly: return "5"
        }
    }

    func shows(_ role: ScreenRole) -> Bool {
        switch self {
        case .topOnly: return role == .top
        case .bottomOnly: return role == .bottom
        default: return true
        }
    }
}


final class LinkSettings: ObservableObject {
    static let shared = LinkSettings()
    private let defaults = UserDefaults.standard

    @Published var codec: VideoCodecKind { didSet { defaults.set(codec.rawValue, forKey: "codec") } }
    @Published var bitrateMbps: Int { didSet { defaults.set(bitrateMbps, forKey: "bitrateMbps") } }
    @Published var maxFps: Int { didSet { defaults.set(maxFps, forKey: "maxFps") } }
    @Published var maxSize: Int { didSet { defaults.set(maxSize, forKey: "maxSize") } }

    @Published var layout: ScreenLayout { didSet { defaults.set(layout.rawValue, forKey: "layout") } }
    @Published var swapped: Bool { didSet { defaults.set(swapped, forKey: "swapped") } }
    @Published var overlayX: Double { didSet { defaults.set(overlayX, forKey: "overlayX") } }
    @Published var overlayY: Double { didSet { defaults.set(overlayY, forKey: "overlayY") } }
    @Published var overlayScale: Double { didSet { defaults.set(overlayScale, forKey: "overlayScale") } }
    @Published var overlayOpacity: Double { didSet { defaults.set(overlayOpacity, forKey: "overlayOpacity") } }
    @Published var cinemaMode: Bool { didSet { defaults.set(cinemaMode, forKey: "cinemaMode") } }
    @Published var upscaling: Bool { didSet { defaults.set(upscaling, forKey: "upscaling") } }
    @Published var smoothMotion: Bool { didSet { defaults.set(smoothMotion, forKey: "smoothMotion") } }
    @Published var statsOverlay: Bool { didSet { defaults.set(statsOverlay, forKey: "statsOverlay") } }
    @Published var replayEnabled: Bool { didSet { defaults.set(replayEnabled, forKey: "replayEnabled") } }
    @Published var replaySeconds: Int { didSet { defaults.set(replaySeconds, forKey: "replaySeconds") } }
    @Published var recordLayout: Bool { didSet { defaults.set(recordLayout, forKey: "recordLayout") } }

    @Published var masterVolume: Double { didSet { defaults.set(masterVolume, forKey: "masterVolume") } }
    @Published var topVolume: Double { didSet { defaults.set(topVolume, forKey: "topVolume") } }
    @Published var bottomVolume: Double { didSet { defaults.set(bottomVolume, forKey: "bottomVolume") } }
    @Published var muted: Bool { didSet { defaults.set(muted, forKey: "muted") } }
    @Published var audioEnabled: Bool { didSet { defaults.set(audioEnabled, forKey: "audioEnabled") } }
    @Published var perScreenAudio: Bool { didSet { defaults.set(perScreenAudio, forKey: "perScreenAudio") } }
    @Published var playOnDevice: Bool { didSet { defaults.set(playOnDevice, forKey: "playOnDevice") } }

    @Published var keepAwake: Bool { didSet { defaults.set(keepAwake, forKey: "keepAwake") } }
    @Published var panelsOffWhenClosed: Bool { didSet { defaults.set(panelsOffWhenClosed, forKey: "panelsOffWhenClosed") } }
    @Published var panelsOffOnLink: Bool { didSet { defaults.set(panelsOffOnLink, forKey: "panelsOffOnLink") } }
    @Published var pauseSleepManager: Bool { didSet { defaults.set(pauseSleepManager, forKey: "pauseSleepManager") } }
    @Published var chargingSeparation: Bool { didSet { defaults.set(chargingSeparation, forKey: "chargingSeparation") } }
    @Published var sleepOnUnlinkIfClosed: Bool { didSet { defaults.set(sleepOnUnlinkIfClosed, forKey: "sleepOnUnlinkIfClosed") } }

    @Published var autoConnect: Bool { didSet { defaults.set(autoConnect, forKey: "autoConnect") } }
    @Published var gamepadEnabled: Bool { didSet { defaults.set(gamepadEnabled, forKey: "gamepadEnabled") } }
    @Published var rumbleEnabled: Bool { didSet { defaults.set(rumbleEnabled, forKey: "rumbleEnabled") } }
    @Published var controllerIdentity: String { didSet { defaults.set(controllerIdentity, forKey: "controllerIdentity") } }
    @Published var hoverEnabled: Bool { didSet { defaults.set(hoverEnabled, forKey: "hoverEnabled") } }
    @Published var screenshotFolder: String { didSet { defaults.set(screenshotFolder, forKey: "screenshotFolder") } }
    @Published var recordingFolder: String { didSet { defaults.set(recordingFolder, forKey: "recordingFolder") } }
    @Published var saveBackupFolder: String { didSet { defaults.set(saveBackupFolder, forKey: "saveBackupFolder") } }
    @Published var autoSaveBackup: Bool { didSet { defaults.set(autoSaveBackup, forKey: "autoSaveBackup") } }
    @Published var saveBackupKeep: Int { didSet { defaults.set(saveBackupKeep, forKey: "saveBackupKeep") } }
    @Published var customSaveFolders: [CustomSaveFolder] { didSet { defaults.set(try? JSONEncoder().encode(customSaveFolders), forKey: "customSaveFolders") } }
    @Published var excludedSaveSources: [String] { didSet { defaults.set(excludedSaveSources, forKey: "excludedSaveSources") } }
    /// Pokémon saves hidden from the Pokémon tab: device path → name shown in Settings.
    @Published var hiddenPokemonSaves: [String: String] { didSet { defaults.set(hiddenPokemonSaves, forKey: "hiddenPokemonSaves") } }

    func addCustomSaveFolder(_ path: String, name: String? = nil) {
        let clean = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !clean.isEmpty, !customSaveFolders.contains(where: { $0.path == clean }) else { return }
        let fallback = (clean as NSString).lastPathComponent
        let label = name?.trimmingCharacters(in: .whitespaces).isEmpty == false ? name! : fallback
        customSaveFolders.append(CustomSaveFolder(name: label, path: clean))
    }

    func removeCustomSaveFolder(_ path: String) {
        customSaveFolders.removeAll { $0.path == path }
        excludedSaveSources.removeAll { $0 == path }
    }

    func isSaveSourceIncluded(_ key: String) -> Bool { !excludedSaveSources.contains(key) }

    func setSaveSource(_ key: String, included: Bool) {
        excludedSaveSources.removeAll { $0 == key }
        if !included { excludedSaveSources.append(key) }
    }
    @Published var fullscreenControls: Bool { didSet { defaults.set(fullscreenControls, forKey: "fullscreenControls") } }
    @Published var detachedScreen: String { didSet { defaults.set(detachedScreen, forKey: "detachedScreen") } }
    var detachedRole: ScreenRole? { ScreenRole(rawValue: detachedScreen) }
    @Published var autoUpdateCheck: Bool { didSet { defaults.set(autoUpdateCheck, forKey: "autoUpdateCheck") } }
    @Published var showMenuBar: Bool { didSet { defaults.set(showMenuBar, forKey: "showMenuBar") } }
    @Published var fullscreenOnLink: Bool { didSet { defaults.set(fullscreenOnLink, forKey: "fullscreenOnLink") } }
    @Published var thorRatedFirst: Bool { didSet { defaults.set(thorRatedFirst, forKey: "thorRatedFirst") } }
    @Published var checkPortUpdates: Bool { didSet { defaults.set(checkPortUpdates, forKey: "checkPortUpdates") } }
    @Published var macKeyboardTyping: Bool { didSet { defaults.set(macKeyboardTyping, forKey: "macKeyboardTyping") } }
    @Published var quietFullscreen: Bool { didSet { defaults.set(quietFullscreen, forKey: "quietFullscreen") } }
    @Published var downloadFolder: String { didSet { defaults.set(downloadFolder, forKey: "downloadFolder") } }

    static func defaultFolder(for title: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if title.hasPrefix("Screenshot") { return home.appendingPathComponent("Pictures/Bifrost Link").path }
        if title.hasPrefix("Recording") { return home.appendingPathComponent("Movies/Bifrost Link").path }
        if title.hasPrefix("Save") { return home.appendingPathComponent("Library/Application Support/Bifrost Link/Saves").path }
        return home.appendingPathComponent("Downloads").path
    }

    private init() {
        let d = UserDefaults.standard
        func value<T>(_ key: String, _ fallback: T) -> T { d.object(forKey: key) as? T ?? fallback }
        codec = VideoCodecKind(rawValue: value("codec", "h265")) ?? .h265
        bitrateMbps = value("bitrateMbps", 16)
        maxFps = value("maxFps", 60)
        maxSize = value("maxSize", 0)
        layout = ScreenLayout(rawValue: value("layout", "stacked")) ?? .stacked
        swapped = value("swapped", false)
        overlayX = value("overlayX", 0.8)
        overlayY = value("overlayY", 0.76)
        overlayScale = value("overlayScale", 0.32)
        overlayOpacity = value("overlayOpacity", 1.0)
        cinemaMode = value("cinemaMode", false)
        upscaling = value("upscaling", true)
        smoothMotion = value("smoothMotion", true)
        statsOverlay = value("statsOverlay", false)
        replayEnabled = value("replayEnabled", false)
        replaySeconds = value("replaySeconds", 30)
        recordLayout = value("recordLayout", false)
        masterVolume = value("masterVolume", 0.9)
        topVolume = value("topVolume", 1.0)
        bottomVolume = value("bottomVolume", 1.0)
        let legacyAudioOff = !value("audioEnabled", true)
        muted = value("muted", false) || legacyAudioOff
        audioEnabled = true
        if legacyAudioOff {
            UserDefaults.standard.set(true, forKey: "audioEnabled")
            UserDefaults.standard.set(true, forKey: "muted")
        }
        perScreenAudio = value("perScreenAudio", true)
        playOnDevice = value("playOnDevice", false)
        keepAwake = value("keepAwake", true)
        panelsOffWhenClosed = value("panelsOffWhenClosed", true)
        panelsOffOnLink = value("panelsOffOnLink", false)
        pauseSleepManager = value("pauseSleepManager", false)
        sleepOnUnlinkIfClosed = value("sleepOnUnlinkIfClosed", true)
        chargingSeparation = value("chargingSeparation", false)
        autoConnect = value("autoConnect", true)
        gamepadEnabled = value("gamepadEnabled", true)
        rumbleEnabled = value("rumbleEnabled", true)
        controllerIdentity = value("controllerIdentity", "odin")
        hoverEnabled = value("hoverEnabled", false)
        let home = FileManager.default.homeDirectoryForCurrentUser
        screenshotFolder = value("screenshotFolder", home.appendingPathComponent("Pictures/Bifrost Link").path)
        recordingFolder = value("recordingFolder", home.appendingPathComponent("Movies/Bifrost Link").path)
        saveBackupFolder = value("saveBackupFolder", home.appendingPathComponent("Library/Application Support/Bifrost Link/Saves").path)
        autoSaveBackup = value("autoSaveBackup", true)
        saveBackupKeep = value("saveBackupKeep", 10)
        customSaveFolders = d.data(forKey: "customSaveFolders").flatMap { try? JSONDecoder().decode([CustomSaveFolder].self, from: $0) } ?? []
        excludedSaveSources = value("excludedSaveSources", [String]())
        hiddenPokemonSaves = value("hiddenPokemonSaves", [String: String]())
        fullscreenControls = value("fullscreenControls", true)
        quietFullscreen = value("quietFullscreen", true)
        macKeyboardTyping = value("macKeyboardTyping", true)
        checkPortUpdates = value("checkPortUpdates", true)
        thorRatedFirst = value("thorRatedFirst", true)
        autoUpdateCheck = value("autoUpdateCheck", true)
        showMenuBar = value("showMenuBar", true)
        fullscreenOnLink = value("fullscreenOnLink", false)
        detachedScreen = value("detachedScreen", "")
        downloadFolder = value("downloadFolder", home.appendingPathComponent("Downloads").path)
    }
}

struct CustomSaveFolder: Codable, Identifiable, Hashable {
    var name: String
    var path: String
    var id: String { path }
}
