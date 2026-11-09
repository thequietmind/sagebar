import AppKit
import SageBarCore
import SwiftUI

/// Renders README and website images from demo readings at 2× (menu bar labels at 3×), in light and dark:
/// `SageBar --render-screenshots <directory>`. Nothing is read from or written to your real settings or sessions.
@MainActor
enum Screenshots {
    private struct MenuBarVariant {
        let name: String
        let style: MenuBarStyle
        let countdown: Bool
        let colored: Bool
    }

    private static let variants = [
        MenuBarVariant(name: "percentages", style: .percentage, countdown: false, colored: false),
        MenuBarVariant(name: "percentages-countdown", style: .percentage, countdown: true, colored: false),
        MenuBarVariant(name: "bars", style: .bar, countdown: false, colored: false),
        MenuBarVariant(name: "bars-countdown", style: .bar, countdown: true, colored: false),
        MenuBarVariant(name: "colored-bars", style: .bar, countdown: false, colored: true),
        MenuBarVariant(name: "colored-bars-countdown", style: .bar, countdown: true, colored: true)
    ]

    static func render(to directory: URL) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let store = showcaseStore()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for dark in [false, true] {
                let appearance = dark ? "dark" : "light"
                application.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                try write(popup(store, dark: dark), to: directory.appending(path: "popup-\(appearance).png"))
                try write(settings(store, dark: dark), to: directory.appending(path: "settings-\(appearance).png"))
                for variant in variants {
                    let label = MenuBarLabel.image(readings: store.menuBarReadings(countdown: variant.countdown),
                                                   style: variant.style, colored: variant.colored)
                    try write(menuBarLabel(label, dark: dark),
                              to: directory.appending(path: "menu-bar-\(variant.name)-\(appearance).png"))
                }
            }
        } catch {
            fputs("Couldn't save screenshots: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        print("Rendered screenshots in \(directory.path)")
    }

    /// Demo readings with every provider shown and default display settings, whatever the saved preferences are.
    private static func showcaseStore() -> UsageStore {
        let store = UsageStore(demo: true)
        for provider in Provider.allCases { store.setEnabled(true, for: provider) }
        store.menuBarStyle = .bar
        store.colorBars = true
        store.showRemaining = false
        store.showResetCountdown = false
        store.showFable = false
        store.refreshMinutes = 5
        return store
    }

    /// The dropdown as it sits under the menu bar, clipped to the popover's rounded corners.
    private static func popup(_ store: UsageStore, dark: Bool) -> NSBitmapImageRep? {
        let content = DashboardView(store: store, openSettings: {}, popOut: {})
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return renderer.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
    }

    /// The Settings window, title bar included, drawn from its own views so it's sharp on any display. It stays
    /// transparent on screen. Window buttons and switches take their active colors only if macOS lets SageBar
    /// become the active app, which it may refuse when another app has focus.
    private static func settings(_ store: UsageStore, dark: Bool) -> NSBitmapImageRep? {
        let window = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView(store: store)))
        window.title = "SageBar Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let deadline = Date().addingTimeInterval(2)
        while !window.isKeyWindow, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        if !window.isKeyWindow { print("macOS kept SageBar in the background, so Settings drew as an inactive window.") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        defer { window.close() }
        guard let frame = window.contentView?.superview, let capture = bitmap(frame.bounds.size, scale: 2) else { return nil }
        frame.cacheDisplay(in: frame.bounds, to: capture)
        return rounded(capture, radius: 12)
    }

    /// Clips a window capture to the window's rounded corners, which drawing the frame view leaves square.
    private static func rounded(_ capture: NSBitmapImageRep, radius: CGFloat) -> NSBitmapImageRep? {
        guard let output = bitmap(capture.size, scale: CGFloat(capture.pixelsWide) / capture.size.width) else { return nil }
        let bounds = NSRect(origin: .zero, size: capture.size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).addClip()
        capture.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
        return output
    }

    /// A menu bar label on a transparent background, inked as the light or dark menu bar would draw it.
    private static func menuBarLabel(_ image: NSImage, dark: Bool) -> NSBitmapImageRep? {
        guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua),
              let bitmap = bitmap(image.size, scale: 3) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        appearance.performAsCurrentDrawingAppearance {
            let bounds = NSRect(origin: .zero, size: image.size)
            image.draw(in: bounds)
            guard image.isTemplate else { return }
            (dark ? NSColor.white : NSColor.black).set()
            bounds.fill(using: .sourceAtop)
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private static func bitmap(_ size: NSSize, scale: CGFloat) -> NSBitmapImageRep? {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)),
                                      pixelsHigh: Int(ceil(size.height * scale)), bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        bitmap?.size = size
        return bitmap
    }

    private static func write(_ bitmap: NSBitmapImageRep?, to url: URL) throws {
        guard let png = bitmap?.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        try png.write(to: url)
    }
}
