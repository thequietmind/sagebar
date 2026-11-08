import AppKit
import SageBarCore
import SwiftUI

private let sage = Color(red: 0.40, green: 0.56, blue: 0.44)

extension Provider {
    /// Grok's Usage view is a tab inside grok.com's Settings dialog with no address of its own.
    var usageURL: URL {
        switch self {
        case .claude: URL(string: "https://claude.ai/settings/usage")!
        case .codex: URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .grok: URL(string: "https://grok.com/")!
        }
    }

    /// Providers connected by pasting a website session into Settings, rather than through an installed CLI.
    var usesPastedSession: Bool { self != .codex }

    var introduction: String {
        switch self {
        case .claude: "A little clarity for your Claude limits."
        case .codex: "Your Codex limits, without another login."
        case .grok: "Your weekly Grok pool, at a glance."
        }
    }
}

struct DashboardView: View {
    @ObservedObject var store: UsageStore
    let openSettings: () -> Void
    /// Opens the dashboard in its own window; nil when this view already is that window.
    var popOut: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "leaf")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(sage)
                Text("SageBar").font(.system(size: 14, weight: .semibold))
                if store.isDemo {
                    Text("Preview").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: store.refreshAll) { Image(systemName: "arrow.clockwise") }
                    .disabled(store.states.values.contains { $0.refreshing } || store.isDemo)
                    .help("Refresh enabled providers").accessibilityLabel("Refresh usage")
                if let popOut {
                    Button(action: popOut) { Image(systemName: "macwindow.on.rectangle") }
                        .help("Open in a window").accessibilityLabel("Open SageBar in a window")
                }
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .help("Settings").accessibilityLabel("Open settings")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 3)

            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 12) {
                    ForEach(store.visibleProviders) { provider in
                        ProviderCard(provider: provider, state: store.state(provider), limits: store.limits(for: provider),
                                     remaining: store.showRemaining, now: context.date,
                                     refreshMinutes: store.refreshMinutes, connect: openSettings)
                    }
                }
            }

            HStack {
                Image(systemName: "clock").font(.system(size: 10))
                Text("Every \(store.refreshMinutes) min").font(.system(size: 11))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 11))
                    .keyboardShortcut("q")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
        .padding(18)
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ProviderCard: View {
    let provider: Provider
    let state: ProviderState
    let limits: [UsageLimit]
    let remaining: Bool
    let now: Date
    let refreshMinutes: Int
    let connect: () -> Void

    private var stale: Bool {
        state.error != nil || state.snapshot.map { now.timeIntervalSince($0.fetchedAt) > Double(refreshMinutes * 60 + 60) } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                ProviderMark(provider: provider)
                Text(provider.name).font(.system(size: 14, weight: .semibold))
                Spacer()
                if state.refreshing {
                    ProgressView().controlSize(.mini).accessibilityLabel("Refreshing \(provider.name)")
                } else if state.snapshot != nil {
                    Circle().fill(stale ? Color.orange : sage).frame(width: 5, height: 5)
                    Text(stale ? "Last known" : "Live").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                Button { NSWorkspace.shared.open(provider.usageURL) } label: {
                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Open \(provider.name) usage").accessibilityLabel("Open \(provider.name) usage page")
            }

            if state.snapshot != nil, let first = limits.first {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(remaining ? first.remainingPercent : first.roundedPercent)%")
                            .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        Text(remaining ? "left" : "used")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer()
                        Text(first.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Meter(limit: first, remaining: remaining)
                    resetText(first)
                }
                .opacity(stale ? 0.65 : 1)

                ForEach(limits.dropFirst()) { limit in
                    Divider().opacity(0.5)
                    VStack(spacing: 7) {
                        HStack {
                            Text(limit.title).font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("\(remaining ? limit.remainingPercent : limit.roundedPercent)% \(remaining ? "left" : "used")")
                                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        }
                        Meter(limit: limit, remaining: remaining)
                        HStack { resetText(limit); Spacer() }
                    }
                    .opacity(stale ? 0.65 : 1)
                }
            } else if state.refreshing {
                Text("Reading your usage…").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            } else if state.snapshot == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text(provider.introduction)
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if provider.usesPastedSession {
                        Button("Connect \(provider.name)", action: connect).controlSize(.small)
                    } else {
                        Button("Open Codex") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Codex.app")) }
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 3)
            }

            if let note = state.snapshot?.note {
                Label(note, systemImage: state.snapshot?.isBlocked == true ? "exclamationmark.circle" : "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = state.error, !(provider.usesPastedSession && error == UsageError.notConnected.localizedDescription) {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let fetchedAt = state.snapshot?.fetchedAt {
                Text("Read \(fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.06)))
    }

    private func resetText(_ limit: UsageLimit) -> some View {
        Label(UsageParser.resetDescription(limit.resetsAt, now: now), systemImage: "arrow.counterclockwise")
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .help(limit.resetsAt?.formatted(date: .complete, time: .shortened) ?? "Reset time unavailable")
    }
}

/// A provider's logo in the popup, colored the way each provider presents it.
private struct ProviderMark: View {
    let provider: Provider

    var body: some View {
        ZStack {
            if provider == .codex {
                // The bundled cloud has its >_ prompt cut out; a white plate behind it keeps the
                // prompt white in dark mode, as in the Codex app icon.
                RoundedRectangle(cornerRadius: 1.5).fill(.white)
                    .frame(width: 9.6, height: 6.6)
                    .offset(x: -0.2, y: -0.4)
            }
            Image(nsImage: ProviderIcons.image(for: provider))
                .resizable().renderingMode(.template).scaledToFit()
                .foregroundStyle(style)
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    private var style: AnyShapeStyle {
        switch provider {
        case .claude:
            AnyShapeStyle(Color(red: 0.75, green: 0.47, blue: 0.34))
        case .codex:
            // Lavender to deep blue, sampled from the Codex desktop app icon.
            AnyShapeStyle(LinearGradient(colors: [Color(red: 203 / 255, green: 191 / 255, blue: 250 / 255),
                                                  Color(red: 135 / 255, green: 160 / 255, blue: 249 / 255),
                                                  Color(red: 63 / 255, green: 71 / 255, blue: 247 / 255)],
                                         startPoint: .top, endPoint: .bottom))
        case .grok:
            AnyShapeStyle(.primary)
        }
    }
}

private struct Meter: View {
    let limit: UsageLimit
    let remaining: Bool
    private var color: Color {
        switch limit.severity {
        case .normal: sage
        case .warning: .orange
        case .critical: .red
        }
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.07))
                Capsule().fill(color)
                    .frame(width: max(0, geometry.size.width * (remaining ? 1 - limit.fraction : limit.fraction)))
            }
        }
        .frame(height: 6)
        .accessibilityLabel("\(limit.title): \(limit.roundedPercent) percent used")
    }
}

/// Development sheet comparing each menu bar style in light and dark, from demo readings.
struct MenuBarPreview: View {
    private struct Variant {
        let title: String
        let style: MenuBarStyle
        let countdown: Bool
        let colored: Bool
    }

    let store: UsageStore
    private let variants = [
        Variant(title: "Percentages", style: .percentage, countdown: false, colored: false),
        Variant(title: "Percentages + countdowns", style: .percentage, countdown: true, colored: false),
        Variant(title: "Bars", style: .bar, countdown: false, colored: false),
        Variant(title: "Bars + countdowns", style: .bar, countdown: true, colored: false),
        Variant(title: "Colored bars", style: .bar, countdown: false, colored: true),
        Variant(title: "Colored bars + countdowns", style: .bar, countdown: true, colored: true)
    ]

    var body: some View {
        HStack(spacing: 0) {
            column(dark: false)
            column(dark: true)
        }
    }

    private func column(dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(variants, id: \.title) { variant in
                VStack(alignment: .leading, spacing: 5) {
                    Text(variant.title).font(.system(size: 10)).foregroundStyle(.secondary)
                    label(variant, dark: dark)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Color(white: dark ? 0.2 : 0.92), in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
        .padding(16)
        .frame(minWidth: 260, alignment: .leading)
        .background(Color(white: dark ? 0.1 : 1))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    @ViewBuilder
    private func label(_ variant: Variant, dark: Bool) -> some View {
        let image = MenuBarLabel.image(readings: store.menuBarReadings(countdown: variant.countdown),
                                       style: variant.style, colored: variant.colored)
        if image.isTemplate {
            Image(nsImage: image).renderingMode(.template).foregroundStyle(.primary)
        } else {
            Image(nsImage: Self.rasterized(image, dark: dark))
        }
    }

    /// Draws a self-colored label as the menu bar would, resolving its dynamic colors for the given appearance.
    private static func rasterized(_ image: NSImage, dark: Bool) -> NSImage {
        guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(image.size.width * 2)),
                                            pixelsHigh: Int(ceil(image.size.height * 2)), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        appearance.performAsCurrentDrawingAppearance { image.draw(in: NSRect(origin: .zero, size: image.size)) }
        NSGraphicsContext.restoreGraphicsState()
        let output = NSImage(size: image.size)
        output.addRepresentation(bitmap)
        return output
    }
}

/// Paste, save, and disconnect rows for a provider connected by website session.
private struct SessionFields: View {
    let provider: Provider
    @ObservedObject var store: UsageStore
    let instructions: String
    let placeholder: String
    @State private var cookie = ""

    var body: some View {
        Text(instructions).font(.callout).foregroundStyle(.secondary)
        SecureField(placeholder, text: $cookie)
            .textFieldStyle(.roundedBorder)
            .onSubmit(save)
        HStack {
            Button("Save session", action: save).disabled(cookie.isEmpty)
            Spacer()
            Button("Disconnect", role: .destructive) { store.disconnect(provider) }
        }
        if store.state(provider).connected {
            Label("Session saved", systemImage: "checkmark.circle.fill").foregroundStyle(sage)
        }
    }

    private func save() {
        store.connect(provider, cookie: cookie)
        if store.notice == nil { cookie = "" }
    }
}

struct PreferencesView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Form {
            Section("Providers") {
                ForEach(Provider.allCases) { provider in
                    Toggle(isOn: Binding(
                        get: { store.enabledProviders.contains(provider) },
                        set: { store.setEnabled($0, for: provider) }
                    )) {
                        HStack(spacing: 7) {
                            Image(nsImage: ProviderIcons.image(for: provider))
                                .resizable().renderingMode(.template).scaledToFit()
                                .frame(width: 16, height: 16).accessibilityHidden(true)
                            Text(provider.name)
                        }
                    }
                    .disabled(store.enabledProviders.count == 1 && store.enabledProviders.contains(provider))
                }
                Text("Choose which providers appear and refresh. Keep at least one enabled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Picker("Menu bar shows", selection: $store.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
                if store.menuBarStyle == .bar {
                    Toggle(isOn: $store.colorBars) {
                        Text("Color bars by usage")
                        Text("Green below 70% used, yellow from 70%, red from 90%.")
                    }
                }
                Toggle("Show remaining capacity", isOn: $store.showRemaining)
                Toggle("Show reset countdowns", isOn: $store.showResetCountdown)
                Text(store.menuBarStyle == .bar
                     ? "Add a compact reset time, such as 3d4h, beneath each bar."
                     : "Add a reset icon and time, such as 3d4h, beside each percentage.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Refresh") {
                Picker("Refresh every", selection: $store.refreshMinutes) {
                    ForEach([1, 2, 5, 10, 15], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: store.toggleLogin))
            }
            Section("Claude") {
                SessionFields(provider: .claude, store: store,
                              instructions: "Paste a session key from claude.ai. SageBar saves it in your Mac’s Keychain.",
                              placeholder: "Session key or Cookie header")
                Toggle("Show Fable weekly limit", isOn: $store.showFable)
            }
            Section("Codex") {
                Text("Uses the current Codex CLI sign-in to read your plan’s limits. This can differ from the account selected in Codex Desktop.")
                    .font(.callout).foregroundStyle(.secondary)
                if let label = store.state(.codex).snapshot?.accountLabel, !label.isEmpty {
                    Text(label).font(.callout).textSelection(.enabled)
                }
                Button("Refresh Codex") { store.refresh(.codex) }
                    .disabled(!store.enabledProviders.contains(.codex) || store.state(.codex).refreshing)
            }
            Section("Grok") {
                SessionFields(provider: .grok, store: store,
                              instructions: "In your browser’s developer tools, open any grok.com request and copy its whole cookie request header, every name=value pair, not a single cookie. SageBar saves it in your Mac’s Keychain.",
                              placeholder: "Cookie header")
            }
            if let notice = store.notice {
                Section { Label(notice, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            }
            Section {
                Text("SageBar 0.1.0 · Built on your Mac\nConnections go directly to the providers. No analytics or SageBar account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 470, height: 640)
        .disabled(store.isDemo)
    }
}
