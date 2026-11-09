import AppKit
import Combine
import SageBarCore
import SwiftUI

@main
struct SageBarApplication {
    @MainActor static func main() {
        if let path = argument(after: "--render-screenshots") {
            Screenshots.render(to: URL(fileURLWithPath: path, isDirectory: true))
            return
        }
        if CommandLine.arguments.contains("--check-codex") {
            do {
                let snapshot = try CodexClient.fetch()
                for limit in snapshot.limits { print("\(limit.title): \(limit.roundedPercent)% used; \(UsageParser.resetDescription(limit.resetsAt))") }
                if let note = snapshot.note { print(note) }
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }

    private static func argument(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.count > index + 1 else { return nil }
        return CommandLine.arguments[index + 1]
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = UsageStore(demo: CommandLine.arguments.contains("--demo"))
    private let popover = NSPopover()
    private var item: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var dashboardWindow: NSWindow?
    /// After a pop-out, menu bar clicks show and hide the standalone window instead of the popup,
    /// until the window's close button ends standalone mode.
    private var standalone = false
    private var subscription: AnyCancellable?
    private var statusTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item?.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.imagePosition = .imageOnly
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Colored labels aren't templates, so redraw them when the menu bar flips between light and dark.
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.updateStatus() }
            }
        }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: DashboardView(
            store: store,
            openSettings: { [weak self] in self?.showSettings() },
            popOut: { [weak self] in self?.showDashboardWindow() }
        ))
        subscription = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatus() }
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatus() }
        }
        updateStatus()
        store.start()
        if CommandLine.arguments.contains("--preview") { showDashboardWindow() }
    }

    private func updateStatus() {
        guard let button = item?.button else { return }
        let readings = store.menuBarReadings()
        let metric = store.showRemaining ? "remaining" : "used"
        button.title = ""
        button.image = MenuBarLabel.image(readings: readings, style: store.menuBarStyle, colored: store.colorBars)
        button.toolTip = readings.map { reading in
            let usage = reading.value == "—" ? "unavailable" : "\(reading.value) \(metric)"
            let reset = reading.reset.map { " · reset \($0)" } ?? ""
            return "\(reading.provider.name): \(usage)\(reset)"
        }.joined(separator: "\n")
        button.setAccessibilityLabel("SageBar usage")
        button.setAccessibilityValue(button.toolTip)
    }

    @objc private func statusItemClicked() {
        guard let button = item?.button else { return }
        if standalone, let window = dashboardWindow {
            toggleStandalone(window)
            return
        }
        if popover.isShown { popover.performClose(nil); return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: PreferencesView(store: store))
            let window = NSWindow(contentViewController: controller)
            window.title = "SageBar Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hides the standalone window when any part of it is on screen; otherwise brings it back to the front.
    private func toggleStandalone(_ window: NSWindow) {
        let onScreen = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        if onScreen {
            window.orderOut(nil)
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens the popup's dashboard as a regular window and enters standalone mode; reused if already open.
    private func showDashboardWindow() {
        popover.performClose(nil)
        if dashboardWindow == nil {
            let controller = NSHostingController(rootView: DashboardView(store: store, openSettings: { [weak self] in self?.showSettings() }))
            let window = NSWindow(contentViewController: controller)
            window.title = store.isDemo ? "SageBar Preview" : "SageBar"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("SageBarDashboard")
            dashboardWindow = window
        }
        standalone = true
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Only the close button closes the standalone window (menu bar clicks hide it), so closing ends standalone mode.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === dashboardWindow else { return }
        standalone = false
    }
}
