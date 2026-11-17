import SwiftUI

struct WelcomeView: View {
    @ObservedObject var manager: DeviceManager
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 28) {
            AppLogo(size: 150)
                .scaleEffect(isBusy ? (pulse ? 1.0 : 0.96) : 1)
                .opacity(isBusy ? (pulse ? 1 : 0.8) : 1)
                .animation(isBusy ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default, value: pulse)
                .onAppear { pulse = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

            VStack(spacing: 8) {
                Text("Bifrost Link")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.bifrost)
                Text(headline)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .textSelection(.enabled)
            }

            actions
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isBusy: Bool {
        switch manager.state {
        case .searching, .linking: return true
        default: return false
        }
    }

    private var headline: String {
        switch manager.state {
        case .noADB: return "adb is missing"
        case .searching: return "Waiting for your \(DeviceInfo.name) to dock…"
        case .unauthorized: return "Allow USB debugging"
        case .linking(let name): return "Building the bridge to \(name)…"
        case .linked: return "Linked"
        case .failed: return "Couldn’t link"
        }
    }

    private var detail: String {
        switch manager.state {
        case .noADB: return "Install Android platform tools with Homebrew:\nbrew install android-platform-tools"
        case .searching: return manager.settings.autoConnect
            ? "Connect the \(DeviceInfo.name) over USB with USB debugging enabled. Bifrost links up automatically."
            : "Connect the \(DeviceInfo.name) over USB, then press Link."
        case .unauthorized: return "Unlock the \(DeviceInfo.name) and confirm the “Allow USB debugging?” prompt. Tick “Always allow from this computer” so it docks without asking next time."
        case .linking: return "Starting the mirror on both screens, audio routing and the lid guard."
        case .linked: return ""
        case .failed(let message): return message
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch manager.state {
        case .failed:
            Button { manager.retry() } label: { Label("Try Again", systemImage: "arrow.clockwise").padding(.horizontal, 8) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        case .searching where !manager.settings.autoConnect:
            Button { manager.connectNow() } label: { Label("Link", systemImage: "link").padding(.horizontal, 8) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        case .linking:
            ProgressView().controlSize(.small)
        default:
            EmptyView()
        }
    }
}
