import Foundation

enum ShortcutAction: String, CaseIterable, Identifiable {
    case quickSave, quickLoad, saveReplay, screenshot, closeApp, record

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickSave: return "Quick save"
        case .quickLoad: return "Quick load"
        case .saveReplay: return "Save replay"
        case .screenshot: return "Screenshot"
        case .closeApp: return "Close the game"
        case .record: return "Start / stop recording"
        }
    }

    var defaultButton: PadInput? {
        switch self {
        case .quickSave: return .r1
        case .quickLoad: return .l1
        case .saveReplay: return .r2
        case .screenshot: return .l2
        case .closeApp: return .start
        case .record: return .select
        }
    }
}

enum ShortcutStore {
    private static let modifierKey = "shortcutModifier"
    private static let bindingsKey = "shortcutBindings"

    static var modifier: PadInput? {
        get {
            let raw = UserDefaults.standard.string(forKey: modifierKey) ?? PadInput.home.rawValue
            return raw == "off" ? nil : PadInput(rawValue: raw)
        }
        set { UserDefaults.standard.set(newValue?.rawValue ?? "off", forKey: modifierKey) }
    }

    private static var bindings: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: bindingsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: bindingsKey) }
    }

    static func button(for action: ShortcutAction) -> PadInput? {
        guard let raw = bindings[action.rawValue] else { return action.defaultButton }
        return raw == "off" ? nil : PadInput(rawValue: raw)
    }

    static func set(_ button: PadInput?, for action: ShortcutAction) {
        var map = bindings
        map[action.rawValue] = button?.rawValue ?? "off"
        bindings = map
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: bindingsKey)
        UserDefaults.standard.removeObject(forKey: modifierKey)
    }

    static func action(for button: PadInput) -> ShortcutAction? {
        ShortcutAction.allCases.first { self.button(for: $0) == button }
    }
}

final class ShortcutTracker {
    private var held = false
    private var used = false
    private var suppressed: Set<PadInput> = []
    private var previous: Set<PadInput> = []

    struct Result {
        var state: PadState
        var fired: [ShortcutAction] = []
        var tapModifier: PadInput?
    }

    func filter(_ input: PadState) -> Result {
        var result = Result(state: input)
        guard let modifier = ShortcutStore.modifier else {
            previous = input.pressed
            return result
        }
        let pressed = input.pressed
        if pressed.contains(modifier) {
            if !held {
                held = true
                used = false
            }
            for button in pressed.subtracting([modifier]).subtracting(previous).subtracting(suppressed) {
                guard let action = ShortcutStore.action(for: button) else { continue }
                result.fired.append(action)
                used = true
                suppressed.insert(button)
            }
        } else if held {
            held = false
            if !used { result.tapModifier = modifier }
        }
        suppressed.formIntersection(pressed)
        result.state.pressed.subtract(suppressed)
        result.state.pressed.remove(modifier)
        if suppressed.contains(.l2) { result.state.l2 = 0 }
        if suppressed.contains(.r2) { result.state.r2 = 0 }
        previous = pressed
        return result
    }
}
