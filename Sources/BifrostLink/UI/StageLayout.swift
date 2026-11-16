import CoreGraphics

struct TilePlacement {
    var rect: CGRect
    var visible = true
    var floating = false
}

struct LayoutSpec: Equatable {
    var layout: ScreenLayout
    var swapped: Bool
    var overlayX: Double
    var overlayY: Double
    var overlayScale: Double
    var overlayOpacity: Double
    var top: CGSize?
    var bottom: CGSize?

    init(settings: LinkSettings, top: CGSize?, bottom: CGSize?) {
        layout = settings.layout
        swapped = settings.swapped
        overlayX = settings.overlayX
        overlayY = settings.overlayY
        overlayScale = settings.overlayScale
        overlayOpacity = settings.overlayOpacity
        self.top = top
        self.bottom = bottom
    }
}

enum StageLayout {
    static func contentSize(spec: LayoutSpec) -> CGSize? {
        guard let a = spec.top, a.width > 0 else { return nil }
        guard let b = spec.bottom, b.width > 0 else { return a }
        switch spec.layout {
        case .stacked: return CGSize(width: max(a.width, b.width), height: a.height + b.height)
        case .sideBySide: return CGSize(width: a.width + b.width, height: max(a.height, b.height))
        case .topOnly: return a
        case .bottomOnly: return b
        case .overlay: return spec.swapped ? b : a
        }
    }

    static func placements(in size: CGSize, gap: CGFloat, spec: LayoutSpec) -> [ScreenRole: TilePlacement] {
        guard let topRaw = spec.top else { return [:] }
        let bounds = CGRect(origin: .zero, size: size)
        let topSize = normalized(topRaw)
        guard let bottomRaw = spec.bottom else {
            return [.top: TilePlacement(rect: fit(topSize, in: bounds))]
        }
        let sizes: [ScreenRole: CGSize] = [.top: topSize, .bottom: normalized(bottomRaw)]
        let first: ScreenRole = spec.swapped ? .bottom : .top
        let second: ScreenRole = spec.swapped ? .top : .bottom
        let a = sizes[first]!, b = sizes[second]!
        var result: [ScreenRole: TilePlacement] = [:]

        switch spec.layout {
        case .stacked:
            let scale = min(size.width / max(a.width, b.width), (size.height - gap) / (a.height + b.height))
            let ah = a.height * scale, bh = b.height * scale
            let y0 = (size.height - ah - gap - bh) / 2
            result[first] = TilePlacement(rect: CGRect(x: (size.width - a.width * scale) / 2, y: y0, width: a.width * scale, height: ah))
            result[second] = TilePlacement(rect: CGRect(x: (size.width - b.width * scale) / 2, y: y0 + ah + gap, width: b.width * scale, height: bh))
        case .sideBySide:
            let scale = min((size.width - gap) / (a.width + b.width), size.height / max(a.height, b.height))
            let aw = a.width * scale, bw = b.width * scale
            let x0 = (size.width - aw - gap - bw) / 2
            result[first] = TilePlacement(rect: CGRect(x: x0, y: (size.height - a.height * scale) / 2, width: aw, height: a.height * scale))
            result[second] = TilePlacement(rect: CGRect(x: x0 + aw + gap, y: (size.height - b.height * scale) / 2, width: bw, height: b.height * scale))
        case .topOnly, .bottomOnly:
            let shown: ScreenRole = spec.layout == .topOnly ? .top : .bottom
            let hidden: ScreenRole = shown == .top ? .bottom : .top
            let rect = fit(sizes[shown]!, in: bounds)
            result[shown] = TilePlacement(rect: rect)
            let hs = sizes[hidden]!
            let hw = rect.width * 0.3
            let hh = hw * hs.height / hs.width
            result[hidden] = TilePlacement(rect: CGRect(x: rect.midX - hw / 2, y: shown == .top ? rect.maxY - hh : rect.minY, width: hw, height: hh), visible: false)
        case .overlay:
            let main = fit(a, in: bounds)
            result[first] = TilePlacement(rect: main)
            let ow = main.width * spec.overlayScale
            let oh = ow * b.height / b.width
            let cx = main.minX + main.width * spec.overlayX
            let cy = main.minY + main.height * spec.overlayY
            let x = min(max(cx - ow / 2, main.minX), main.maxX - ow)
            let y = min(max(cy - oh / 2, main.minY), main.maxY - oh)
            result[second] = TilePlacement(rect: CGRect(x: x, y: y, width: ow, height: oh), floating: true)
        }
        return result
    }

    private static func normalized(_ s: CGSize) -> CGSize {
        s.width > 0 && s.height > 0 ? s : CGSize(width: 16, height: 9)
    }

    private static func fit(_ s: CGSize, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / s.width, rect.height / s.height)
        let w = s.width * scale, h = s.height * scale
        return CGRect(x: rect.minX + (rect.width - w) / 2, y: rect.minY + (rect.height - h) / 2, width: w, height: h)
    }
}
