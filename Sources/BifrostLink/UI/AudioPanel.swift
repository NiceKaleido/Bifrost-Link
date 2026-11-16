import SwiftUI

struct VolumeRow: View {
    let title: String
    let symbol: String
    @Binding var value: Double
    var subtitle: String?
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text("\(Int(value * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...1)
                .tint(tint)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

struct AudioPanel: View {
    @ObservedObject var manager: DeviceManager
    @ObservedObject var settings: LinkSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Audio").font(.headline)
                Spacer()
                Toggle("Mute", isOn: $settings.muted).toggleStyle(.switch).controlSize(.small)
            }

            HStack(alignment: .top, spacing: 10) {
                Button {
                    settings.muted.toggle()
                } label: {
                    Image(systemName: settings.muted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                        .frame(width: 28, height: 28)
                        .foregroundStyle(settings.muted ? .red : .primary)
                }
                .buttonStyle(.borderless)
                .help(settings.muted ? "Unmute" : "Mute")
                VolumeRow(title: "Both Screens", symbol: "hifispeaker.2.fill", value: $settings.masterVolume,
                          subtitle: "Master, also covers background apps", tint: Theme.bifrostColors[2])
            }

            if settings.perScreenAudio && manager.screens.count > 1 {
                Divider().opacity(0.4)
                VolumeRow(title: "Top Screen", symbol: "rectangle.tophalf.filled", value: $settings.topVolume,
                          subtitle: appNames(.top), tint: Theme.bifrostColors[0])
                VolumeRow(title: "Bottom Screen", symbol: "rectangle.bottomhalf.filled", value: $settings.bottomVolume,
                          subtitle: appNames(.bottom), tint: Theme.bifrostColors[4])
            }

            Divider().opacity(0.4)
            Toggle("Separate audio per screen", isOn: $settings.perScreenAudio)
                .help("Captures each screen’s apps separately so they get their own volume. An app shown on both screens counts as top.")
            if !settings.perScreenAudio {
                Text("Capturing the Thor’s whole audio output. Works with every app.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Toggle("Also play on the Thor’s speakers", isOn: $settings.playOnDevice)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(18)
        .frame(width: 320)
    }

    private func appNames(_ channel: AudioChannel) -> String {
        let apps = manager.screenApps[channel] ?? []
        if apps.isEmpty { return channel == .bottom ? "No separate app on this screen" : "–" }
        return apps.map { $0.split(separator: ".").last.map(String.init) ?? $0 }.joined(separator: ", ")
    }
}
