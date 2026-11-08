import AppKit
import SageBarCore

@MainActor
enum ProviderIcons {
    static let claude = load("Claude", inset: 3)
    static let codex = load("Codex")
    static let grok = load("Grok")

    static func image(for provider: Provider) -> NSImage {
        switch provider {
        case .claude: claude
        case .codex: codex
        case .grok: grok
        }
    }

    private static func load(_ name: String, inset: CGFloat = 0) -> NSImage {
        let bundle = Bundle.main.url(forResource: "SageBar_SageBar", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? Bundle.module
        guard let image = bundle.image(forResource: NSImage.Name(name)) else {
            preconditionFailure("Missing provider icon: \(name)")
        }
        let bounds = NSRect(origin: .zero, size: image.size).insetBy(dx: inset, dy: inset)
        let icon = NSImage(size: bounds.size, flipped: false) { rect in
            image.draw(in: rect, from: bounds, operation: .sourceOver, fraction: 1)
            return true
        }
        icon.isTemplate = true
        return icon
    }
}

struct MenuBarReading {
    let provider: Provider
    let value: String
    /// Displayed share of the bar (used or remaining); nil when the reading is unavailable.
    let fraction: Double?
    /// How close the limit is to running out, for colored bars; nil when the reading is unavailable.
    let severity: UsageSeverity?
    let reset: String?
}

/// One provider's content after its icon: a fixed width and a drawing routine given the left edge.
private struct MenuBarSegment {
    let width: CGFloat
    let draw: (CGFloat) -> Void
}

/// Monochrome labels are template images the menu bar tints. Colored labels draw their own ink:
/// the dynamic label color resolves at draw time against the menu bar's appearance.
private struct MenuBarInk {
    let colored: Bool
    var text: NSColor { colored ? .labelColor : .black }
    var track: NSColor { text.withAlphaComponent(0.3) }

    func fill(for severity: UsageSeverity?) -> NSColor {
        guard colored, let severity else { return text }
        switch severity {
        case .normal: return .systemGreen
        case .warning: return .systemYellow
        case .critical: return .systemRed
        }
    }
}

@MainActor
enum MenuBarLabel {
    private static let height: CGFloat = 18
    private static let iconSize: CGFloat = 16
    private static let iconGap: CGFloat = 4
    private static let providerGap: CGFloat = 12
    private static let barWidth: CGFloat = 26
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let compactFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    /// `colored` applies only to bars; percentages always stay monochrome.
    static func image(readings: [MenuBarReading], style: MenuBarStyle, colored: Bool = false) -> NSImage {
        let ink = MenuBarInk(colored: colored && style == .bar)
        let icons = readings.map { reading in
            let icon = ProviderIcons.image(for: reading.provider)
            return ink.colored ? tinted(icon, with: ink.text) : icon
        }
        let segments = readings.map { style == .bar ? barSegment($0, ink: ink) : percentageSegment($0, ink: ink) }
        let contentWidth = segments.reduce(CGFloat(0)) { $0 + iconSize + iconGap + $1.width }
        let width = contentWidth + CGFloat(max(0, segments.count - 1)) * providerGap
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (icon, segment) in zip(icons, segments) {
                icon.draw(in: NSRect(x: x, y: 1, width: iconSize, height: iconSize),
                          from: .zero, operation: .sourceOver, fraction: 1)
                x += iconSize + iconGap
                segment.draw(x)
                x += segment.width + providerGap
            }
            return true
        }
        image.isTemplate = !ink.colored
        return image
    }

    private static func percentageSegment(_ reading: MenuBarReading, ink: MenuBarInk) -> MenuBarSegment {
        let label = text(reading.value, font: font, ink: ink)
        let labelWidth = ceil(label.size().width)
        guard let reset = reading.reset.map({ text($0, font: font, ink: ink) }) else {
            return MenuBarSegment(width: labelWidth) { x in drawCentered(label, x: x) }
        }
        let resetGap: CGFloat = 5
        let refreshSize: CGFloat = 10
        let refreshGap: CGFloat = 3
        let refreshIcon = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        let width = labelWidth + resetGap + refreshSize + refreshGap + ceil(reset.size().width)
        return MenuBarSegment(width: width) { x in
            drawCentered(label, x: x)
            let iconX = x + labelWidth + resetGap
            refreshIcon?.draw(in: NSRect(x: iconX, y: 4, width: refreshSize, height: refreshSize),
                              from: .zero, operation: .sourceOver, fraction: 1)
            drawCentered(reset, x: iconX + refreshSize + refreshGap)
        }
    }

    /// A single fill bar; with a countdown, the bar sits above a compact reset time instead of beside it.
    private static func barSegment(_ reading: MenuBarReading, ink: MenuBarInk) -> MenuBarSegment {
        guard let fraction = reading.fraction else {
            let dash = text(reading.value, font: font, ink: ink)
            let inset = (barWidth - ceil(dash.size().width)) / 2
            return MenuBarSegment(width: barWidth) { x in drawCentered(dash, x: x + inset) }
        }
        let fill = ink.fill(for: reading.severity)
        guard let reset = reading.reset.map({ text($0, font: compactFont, ink: ink) }) else {
            return MenuBarSegment(width: barWidth) { x in
                drawBar(NSRect(x: x, y: 6, width: barWidth, height: 6), fraction: fraction, track: ink.track, fill: fill)
            }
        }
        let resetWidth = ceil(reset.size().width)
        let width = max(barWidth, resetWidth)
        return MenuBarSegment(width: width) { x in
            drawBar(NSRect(x: x + (width - barWidth) / 2, y: 12, width: barWidth, height: 4),
                    fraction: fraction, track: ink.track, fill: fill)
            reset.draw(at: NSPoint(x: x + (width - resetWidth) / 2, y: 0))
        }
    }

    private static func text(_ string: String, font: NSFont, ink: MenuBarInk) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: ink.text])
    }

    private static func tinted(_ icon: NSImage, with color: NSColor) -> NSImage {
        NSImage(size: icon.size, flipped: false) { rect in
            icon.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private static func drawCentered(_ label: NSAttributedString, x: CGFloat) {
        label.draw(at: NSPoint(x: x, y: floor((height - label.size().height) / 2)))
    }

    /// Draws a faint capsule track with the filled share clipped to the same shape, so small values stay proportional.
    private static func drawBar(_ rect: NSRect, fraction: Double, track: NSColor, fill: NSColor) {
        let capsule = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        track.setFill()
        capsule.fill()
        NSGraphicsContext.saveGraphicsState()
        capsule.addClip()
        fill.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width * min(1, max(0, fraction)), height: rect.height)
            .fill(using: .sourceOver)
        NSGraphicsContext.restoreGraphicsState()
    }
}
