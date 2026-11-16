import SwiftUI

enum Theme {
    static let cyan = Color(red: 0.36, green: 0.82, blue: 1.0)
    static let blue = Color(red: 0.26, green: 0.45, blue: 1.0)
    static let indigo = Color(red: 0.20, green: 0.25, blue: 0.62)
    static let violet = Color(red: 0.43, green: 0.20, blue: 0.75)

    static let bifrost = LinearGradient(colors: [cyan, blue, violet], startPoint: .leading, endPoint: .trailing)
    static let bifrostColors: [Color] = [cyan, blue, indigo, violet, blue]

    static let accent = Color(red: 0.33, green: 0.58, blue: 1.0)
    static let stage = Color(red: 0.035, green: 0.035, blue: 0.07)
    static let panel = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.09)
}

struct AuroraBackground: View {
    var intensity: Double = 1
    var animated = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.stage))
                for (i, color) in Theme.bifrostColors.enumerated() {
                    let phase = t * 0.07 + Double(i) * 1.3
                    let x = size.width * (0.5 + 0.42 * sin(phase))
                    let y = size.height * (0.5 + 0.38 * cos(phase * 0.8 + Double(i)))
                    let r = max(size.width, size.height) * 0.42
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect), with: .radialGradient(
                        Gradient(colors: [color.opacity(0.22 * intensity), color.opacity(0)]),
                        center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
    }
}

extension View {
    func glassCapsule() -> some View { modifier(GlassCapsule()) }
}

struct AppLogo: View {
    var size: CGFloat = 150

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .shadow(color: Theme.violet.opacity(0.45), radius: 30, y: 10)
    }
}
