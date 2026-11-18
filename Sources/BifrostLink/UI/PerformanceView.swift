import SwiftUI
import Charts

/// Validated (dataviz validator, dark surface) categorical slots and status colours.
enum PerfPalette {
    static let blue = Color(hex: 0x3987E5)
    static let orange = Color(hex: 0xD95926)
    static let aqua = Color(hex: 0x199E70)
    static let good = Color(hex: 0x0CA30C)
    static let warning = Color(hex: 0xFAB219)
    static let critical = Color(hex: 0xD03B3B)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// A reading's state, always shown as a word next to its colour (never colour alone).
struct PerfStatus {
    let label: String
    let color: Color

    static func load(_ percent: Double) -> PerfStatus {
        percent >= 90 ? PerfStatus(label: "Maxed", color: PerfPalette.critical)
            : percent >= 70 ? PerfStatus(label: "Busy", color: PerfPalette.warning)
            : PerfStatus(label: "Easy", color: PerfPalette.good)
    }

    static func temperature(_ celsius: Double) -> PerfStatus {
        celsius >= 85 ? PerfStatus(label: "Hot", color: PerfPalette.critical)
            : celsius >= 65 ? PerfStatus(label: "Warm", color: PerfPalette.warning)
            : PerfStatus(label: "Cool", color: PerfPalette.good)
    }

    static func frames(_ fps: Double?, target: Double) -> PerfStatus {
        guard let fps else { return PerfStatus(label: "Idle", color: .secondary) }
        let ratio = fps / max(1, target)
        return ratio >= 0.9 ? PerfStatus(label: "Smooth", color: PerfPalette.good)
            : ratio >= 0.45 ? PerfStatus(label: "Dipping", color: PerfPalette.warning)
            : PerfStatus(label: "Struggling", color: PerfPalette.critical)
    }
}

struct PerformanceView: View {
    @ObservedObject var monitor: DeviceMonitor
    @ObservedObject var manager: DeviceManager

    var body: some View {
        Group {
            if manager.serial == nil {
                ContentUnavailableView("Link your \(DeviceInfo.name)", systemImage: "cable.connector", description: Text("Live performance shows up here once it’s connected."))
            } else if let snap = monitor.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        measuring(snap)
                        gauges(snap)
                        charts
                        clocks(snap)
                        thermals(snap)
                        power(snap)
                        processes(snap)
                        ForEach(manager.screens, id: \.role) { StreamStatsCard(controller: $0) }
                    }
                    .padding(12)
                }
            } else {
                ProgressView("Reading performance…").frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { monitor.watch("tab", true) }
        .onDisappear { monitor.watch("tab", false) }
    }

    private func measuring(_ snap: DeviceSnapshot) -> some View {
        HStack(spacing: 6) {
            Circle().fill(PerfPalette.good).frame(width: 7, height: 7)
                .shadow(color: PerfPalette.good.opacity(0.8), radius: 3)
            Text("Live").font(.caption.weight(.semibold))
            Text("·").foregroundStyle(.tertiary)
            Text(snap.measuring.map { "Frames from \($0)" } ?? "Nothing on screen to measure").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text("\(Int(snap.refreshRate)) Hz display").font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: Gauges

    private func gauges(_ snap: DeviceSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            RingGauge(title: "Frame rate", value: snap.fps.map { String(format: "%.1f", $0) } ?? "—", unit: "fps",
                      fraction: (snap.fps ?? 0) / max(1, snap.refreshRate), status: PerfStatus.frames(snap.fps, target: snap.refreshRate),
                      detail: snap.frameTimeMs.map { String(format: "%.1f ms per frame · ", $0) + (snap.jank == 0 ? "no drops" : "\(snap.jank) late") } ?? "no new frames")
            RingGauge(title: "CPU", value: "\(Int(snap.cpu.rounded()))", unit: "%", fraction: snap.cpu / 100, status: .load(snap.cpu),
                      detail: snap.cpuTemp.map { "\(Int($0.rounded()))°C" } ?? " ")
            RingGauge(title: "GPU", value: "\(Int(snap.gpu.rounded()))", unit: "%", fraction: snap.gpu / 100, status: .load(snap.gpu),
                      detail: snap.gpuMHz > 0 ? "\(Int(snap.gpuMHz)) MHz" + (snap.gpuTemp.map { " · \(Int($0.rounded()))°C" } ?? "") : " ")
            RingGauge(title: "Memory", value: String(format: "%.1f", snap.memUsedMB / 1024), unit: "GB", fraction: snap.memPercent / 100, status: .load(snap.memPercent),
                      detail: String(format: "of %.0f GB", snap.memTotalMB / 1024) + (snap.swapUsedMB > 1 ? String(format: " · %.1f GB swap", snap.swapUsedMB / 1024) : ""))
        }
    }

    // MARK: Charts

    private var charts: some View {
        let samples = monitor.history
        return VStack(spacing: 12) {
            card("Frame rate") {
                LiveChart(samples: samples, unit: "fps", domain: 0...max(30, (monitor.snapshot?.refreshRate ?? 60) + 5),
                          series: [.init(name: "FPS", color: PerfPalette.blue) { $0.fps }], filled: true)
            }
            card("Load") {
                LiveChart(samples: samples, unit: "%", domain: 0...100,
                          series: [.init(name: "CPU", color: PerfPalette.blue) { $0.cpu },
                                   .init(name: "GPU", color: PerfPalette.orange) { $0.gpu },
                                   .init(name: "Memory", color: PerfPalette.aqua) { $0.mem }])
            }
            card("Temperature") {
                let peak = samples.flatMap { [$0.cpuTemp, $0.gpuTemp, $0.batteryTemp].compactMap { $0 } }.max() ?? 60
                LiveChart(samples: samples, unit: "°C", domain: 20...max(70, (peak / 10).rounded(.up) * 10),
                          series: [.init(name: "CPU", color: PerfPalette.blue) { $0.cpuTemp },
                                   .init(name: "GPU", color: PerfPalette.orange) { $0.gpuTemp },
                                   .init(name: "Battery", color: PerfPalette.aqua) { $0.batteryTemp }])
            }
        }
    }

    // MARK: Details

    private func clocks(_ snap: DeviceSnapshot) -> some View {
        card("Clock speeds") {
            VStack(spacing: 10) {
                ForEach(snap.clusters) { cluster in
                    MeterRow(title: "\(cluster.name) cores", subtitle: "\(cluster.cores) × up to \(ghz(cluster.maxMHz))",
                             value: ghz(cluster.currentMHz), fraction: cluster.currentMHz / max(1, cluster.maxMHz))
                }
                if snap.gpuMaxMHz > 0 {
                    MeterRow(title: "GPU", subtitle: "up to \(Int(snap.gpuMaxMHz)) MHz", value: "\(Int(snap.gpuMHz)) MHz", fraction: snap.gpuMHz / snap.gpuMaxMHz)
                }
            }
        }
    }

    private func thermals(_ snap: DeviceSnapshot) -> some View {
        card("Temperatures") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(snap.thermals) { sensor in
                    let status = PerfStatus.temperature(sensor.celsius)
                    HStack(spacing: 8) {
                        Text(sensor.name).font(.callout)
                        Spacer()
                        Text("\(Int(sensor.celsius.rounded()))°").font(.callout.weight(.semibold).monospacedDigit())
                        StatusChip(status: status)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private func power(_ snap: DeviceSnapshot) -> some View {
        card("Battery & power") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                Stat(title: "Battery", value: snap.battery.map { "\($0)%" } ?? "—", detail: batteryDetail(snap))
                Stat(title: "USB input", value: snap.usbWatts.map { String(format: "%.1f W", $0) } ?? "—",
                     detail: snap.usbWatts == nil ? "not plugged in" : "coming in from the charger")
                if let watts = snap.watts {
                    Stat(title: "Battery draw", value: String(format: "%.1f W", watts), detail: "from the battery sensor")
                }
            }
        }
    }

    private func batteryDetail(_ snap: DeviceSnapshot) -> String {
        switch (snap.batteryStatus, snap.usbWatts != nil) {
        case ("Discharging", true): return "plugged in, still draining"
        case ("Charging", _): return "charging"
        case ("Full", _): return "full"
        case ("Discharging", false): return "on battery"
        default: return snap.batteryStatus.isEmpty ? " " : snap.batteryStatus.lowercased()
        }
    }

    private func processes(_ snap: DeviceSnapshot) -> some View {
        card("Busiest processes") {
            if snap.processes.isEmpty {
                Text("Reading…").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    let peak = max(1, snap.processes.map(\.cpu).max() ?? 1)
                    ForEach(snap.processes.prefix(5)) { process in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(process.name).font(.callout).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(process.memoryMB >= 1024 ? String(format: "%.1f GB", process.memoryMB / 1024) : "\(Int(process.memoryMB)) MB")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(String(format: "%.0f%%", process.cpu)).font(.callout.weight(.medium).monospacedDigit()).frame(width: 44, alignment: .trailing)
                            }
                            Capsule().fill(PerfPalette.blue.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: 4)
                                .scaleEffect(x: max(0.02, process.cpu / peak), anchor: .leading)
                                .animation(.linear(duration: 1), value: process.cpu)
                        }
                    }
                    Text("Share of all CPU cores.").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func ghz(_ mhz: Double) -> String { String(format: "%.2f GHz", mhz / 1000) }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }
}

// MARK: - Pieces

struct RingGauge: View {
    let title: String
    let value: String
    let unit: String
    let fraction: Double
    let status: PerfStatus
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, fraction)))
                    .stroke(Theme.bifrost, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: fraction)
                VStack(spacing: -2) {
                    Text(value).font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                        .animation(.default, value: value)
                    Text(unit).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 66, height: 66)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                StatusChip(status: status)
                Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct StatusChip: View {
    let status: PerfStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(status.color).frame(width: 6, height: 6)
            Text(status.label).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
        }
    }
}

struct MeterRow: View {
    let title: String
    let subtitle: String
    let value: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.callout)
                Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text(value).font(.callout.weight(.medium).monospacedDigit())
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule().fill(Theme.bifrost)
                        .frame(width: max(4, proxy.size.width * min(1, fraction)))
                        .animation(.linear(duration: 1), value: fraction)
                }
            }
            .frame(height: 5)
        }
    }
}

struct Stat: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).lineLimit(1)
            Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A 2-minute rolling line chart with one y-axis, a legend for several series and a hover readout.
struct LiveChart: View {
    struct Series {
        let name: String
        let color: Color
        let value: (DeviceSample) -> Double?
    }

    let samples: [DeviceSample]
    let unit: String
    let domain: ClosedRange<Double>
    let series: [Series]
    var filled = false
    @State private var hover: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if series.count > 1 { legend }
            // Redraw at 30 fps and slide the window with the clock, so the line scrolls steadily
            // instead of jumping once per sample. The window trails "now" by a little more than one
            // poll, so the newest point is already there when it reaches the right edge.
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                chart(end: context.date.addingTimeInterval(-1.3))
            }
            .frame(height: 130)
        }
    }

    private func chart(end: Date) -> some View {
            Chart {
                ForEach(series, id: \.name) { s in
                    ForEach(samples) { sample in
                        if let v = s.value(sample) {
                            if filled {
                                AreaMark(x: .value("Time", sample.time), y: .value(unit, v))
                                    .foregroundStyle(LinearGradient(colors: [s.color.opacity(0.35), s.color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                    .interpolationMethod(.monotone)
                            }
                            LineMark(x: .value("Time", sample.time), y: .value(unit, v), series: .value("Series", s.name))
                                .foregroundStyle(s.color)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                .interpolationMethod(.monotone)
                        }
                    }
                }
                if let hover, let sample = nearest(hover) {
                    RuleMark(x: .value("Time", sample.time))
                        .foregroundStyle(Color.white.opacity(0.25))
                        .annotation(position: .top, alignment: .center, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            readout(sample)
                        }
                    ForEach(series, id: \.name) { s in
                        if let v = s.value(sample) {
                            PointMark(x: .value("Time", sample.time), y: .value(unit, v))
                                .symbolSize(60)
                                .foregroundStyle(s.color)
                        }
                    }
                }
            }
            .chartYScale(domain: domain)
            .chartXScale(domain: end.addingTimeInterval(-120)...end)
            .chartXAxis {
                // Ticks fixed relative to the right edge: the labels stay put and only the data scrolls.
                AxisMarks(values: [120, 90, 60, 30, 0].map { end.addingTimeInterval(-Double($0)) }) { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.05))
                    AxisValueLabel(anchor: value.index == 4 ? .topTrailing : value.index == 0 ? .topLeading : .top) {
                        Text(["-2m", "-90s", "-1m", "-30s", "now"][value.index]).font(.caption2)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text("\(Int(v))\(unit == "%" ? "%" : unit == "°C" ? "°" : "")").font(.caption2) }
                    }
                }
            }
            .chartXSelection(value: $hover)
            .chartPlotStyle { $0.padding(.top, 4).clipped() }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(series, id: \.name) { s in
                HStack(spacing: 5) {
                    Capsule().fill(s.color).frame(width: 12, height: 3)
                    Text(s.name).font(.caption2).foregroundStyle(.secondary)
                    if let v = samples.last.flatMap(s.value) {
                        Text(format(v)).font(.caption2.weight(.semibold).monospacedDigit())
                    }
                }
            }
        }
    }

    private func readout(_ sample: DeviceSample) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ago(sample.time, now: samples.last?.time ?? Date())).font(.caption2).foregroundStyle(.secondary)
            ForEach(series, id: \.name) { s in
                if let v = s.value(sample) {
                    HStack(spacing: 4) {
                        Circle().fill(s.color).frame(width: 6, height: 6)
                        Text(series.count > 1 ? "\(s.name) \(format(v))" : format(v)).font(.caption2.weight(.medium).monospacedDigit())
                    }
                }
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func nearest(_ date: Date) -> DeviceSample? {
        samples.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
    }

    private func format(_ v: Double) -> String {
        switch unit {
        case "%": return "\(Int(v.rounded()))%"
        case "°C": return "\(Int(v.rounded()))°C"
        case "fps": return String(format: "%.1f fps", v)
        default: return "\(Int(v.rounded())) \(unit)"
        }
    }

    private func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date).rounded())
        return seconds <= 0 ? "now" : seconds < 60 ? "-\(seconds)s" : "-\(seconds / 60)m\(seconds % 60 == 0 ? "" : " \(seconds % 60)s")"
    }
}

struct StreamStatsCard: View {
    @ObservedObject var controller: ScreenController

    var body: some View {
        if let stats = controller.statsSnapshot {
            VStack(alignment: .leading, spacing: 10) {
                Text("Stream · \(controller.role.title)").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    Stat(title: "On this Mac", value: "\(Int(stats.fps.rounded())) fps", detail: "\(stats.codec) \(stats.resolution)")
                    Stat(title: "Bitrate", value: String(format: "%.1f Mbit/s", stats.mbps), detail: stats.dropped > 0 ? "\(stats.dropped) frames dropped" : "no dropped frames")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        }
    }
}
