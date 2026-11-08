import AppKit
import Combine
import Foundation
import SageBarCore
import ServiceManagement

struct ProviderState {
    var snapshot: UsageSnapshot?
    var error: String?
    var refreshing = false
    var connected = false
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case percentage, bar
    var id: String { rawValue }
    var title: String { self == .percentage ? "Percentages" : "Bars" }
}

@MainActor
final class UsageStore: ObservableObject {
    /// Grok is opt-in; Claude and Codex start enabled.
    static let defaultProviders: Set<Provider> = [.claude, .codex]
    @Published var states = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, ProviderState()) })
    @Published var notice: String?
    @Published private(set) var enabledProviders: Set<Provider>
    @Published var showResetCountdown: Bool {
        didSet { defaults.set(showResetCountdown, forKey: "showResetCountdown") }
    }
    @Published var refreshMinutes: Int {
        didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes"); scheduleRefresh() }
    }
    @Published var showRemaining: Bool {
        didSet { defaults.set(showRemaining, forKey: "showRemaining") }
    }
    @Published var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
    }
    @Published var showFable: Bool {
        didSet { defaults.set(showFable, forKey: "showFable") }
    }
    @Published var colorBars: Bool {
        didSet { defaults.set(colorBars, forKey: "colorBars") }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    let isDemo: Bool
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var generations: [Provider: Int] = [:]

    init(demo: Bool = false) {
        isDemo = demo
        let savedProviders = UserDefaults.standard.stringArray(forKey: "enabledProviders")
        let providers = savedProviders.map { Set($0.compactMap(Provider.init(rawValue:))) } ?? Self.defaultProviders
        enabledProviders = providers.isEmpty ? Self.defaultProviders : providers
        showResetCountdown = UserDefaults.standard.bool(forKey: "showResetCountdown")
        let savedMinutes = UserDefaults.standard.integer(forKey: "refreshMinutes")
        refreshMinutes = [1, 2, 5, 10, 15].contains(savedMinutes) ? savedMinutes : 5
        showRemaining = UserDefaults.standard.bool(forKey: "showRemaining")
        menuBarStyle = UserDefaults.standard.string(forKey: "menuBarStyle").flatMap(MenuBarStyle.init(rawValue:)) ?? .percentage
        showFable = UserDefaults.standard.bool(forKey: "showFable")
        colorBars = UserDefaults.standard.bool(forKey: "colorBars")
        if demo {
            let now = Date()
            states[.claude] = ProviderState(snapshot: UsageSnapshot(limits: [
                UsageLimit(id: "session", title: "5-hour session", usedPercent: 32, resetsAt: now.addingTimeInterval(8000)),
                UsageLimit(id: "weekly_all", title: "Weekly", usedPercent: 54, resetsAt: now.addingTimeInterval(230000)),
                UsageLimit(id: "weekly_scoped.Fable", title: "Weekly · Fable", usedPercent: 41, resetsAt: now.addingTimeInterval(230000))
            ]), connected: true)
            states[.codex] = ProviderState(snapshot: UsageSnapshot(limits: [
                UsageLimit(id: "primary", title: "Weekly", usedPercent: 76, resetsAt: now.addingTimeInterval(270000))
            ]), connected: true)
            states[.grok] = ProviderState(snapshot: UsageSnapshot(limits: [
                UsageLimit(id: "credits", title: "Weekly", usedPercent: 93, resetsAt: now.addingTimeInterval(190000))
            ]), connected: true)
        }
    }

    func start() {
        guard !isDemo else { return }
        refreshAll()
        scheduleRefresh()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    func state(_ provider: Provider) -> ProviderState { states[provider] ?? ProviderState() }

    /// The provider's limits after display preferences, such as hiding Fable.
    func limits(for provider: Provider) -> [UsageLimit] {
        let limits = state(provider).snapshot?.limits ?? []
        return showFable ? limits : limits.filter { !$0.isFable }
    }

    var visibleProviders: [Provider] { Provider.allCases.filter { enabledProviders.contains($0) } }

    func setEnabled(_ enabled: Bool, for provider: Provider) {
        guard enabled != enabledProviders.contains(provider) else { return }
        if enabled {
            enabledProviders.insert(provider)
            refresh(provider)
        } else {
            guard enabledProviders.count > 1 else { return }
            enabledProviders.remove(provider)
            generations[provider, default: 0] += 1
            states[provider]?.refreshing = false
        }
        defaults.set(visibleProviders.map(\.rawValue), forKey: "enabledProviders")
    }

    func refreshAll() { for provider in visibleProviders { refresh(provider) } }

    func refresh(_ provider: Provider) {
        guard !isDemo, enabledProviders.contains(provider), !state(provider).refreshing else { return }
        states[provider]?.refreshing = true
        let generation = (generations[provider] ?? 0) + 1
        generations[provider] = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await Self.fetch(provider)
                guard generations[provider] == generation else { return }
                states[provider] = ProviderState(snapshot: snapshot, connected: true)
            } catch {
                guard generations[provider] == generation else { return }
                states[provider]?.refreshing = false
                states[provider]?.error = (error as? UsageError)?.localizedDescription ?? UsageError.invalidResponse.localizedDescription
            }
        }
    }

    private static func fetch(_ provider: Provider) async throws -> UsageSnapshot {
        switch provider {
        case .codex:
            return try await Task.detached(priority: .utility) { try CodexClient.fetch() }.value
        case .claude:
            return try await ClaudeClient().fetch(cookie: savedSession(.claude))
        case .grok:
            return try await GrokClient().fetch(cookie: savedSession(.grok))
        }
    }

    private static func savedSession(_ provider: Provider) throws -> String {
        guard let cookie = try SessionVault.load(provider) else { throw UsageError.notConnected }
        return cookie
    }

    /// Saves a pasted session and turns the provider on, since saving one signals intent to see it.
    func connect(_ provider: Provider, cookie: String) {
        guard !isDemo else { return }
        do {
            try SessionVault.save(cookie, for: provider)
            generations[provider, default: 0] += 1
            states[provider] = ProviderState(connected: true)
            notice = nil
            if enabledProviders.contains(provider) { refresh(provider) } else { setEnabled(true, for: provider) }
        } catch { notice = error.localizedDescription }
    }

    func disconnect(_ provider: Provider) {
        do {
            try SessionVault.delete(provider)
            generations[provider, default: 0] += 1
            states[provider] = ProviderState()
            notice = nil
        } catch { notice = error.localizedDescription }
    }

    func toggleLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && !launchAtLogin { notice = "Allow SageBar in System Settings → General → Login Items." }
        } catch { notice = "Couldn't change Launch at Login. Run SageBar from Applications and try again." }
    }

    func menuBarReadings() -> [MenuBarReading] { menuBarReadings(countdown: showResetCountdown) }

    func menuBarReadings(countdown: Bool) -> [MenuBarReading] {
        visibleProviders.map { provider in
            guard let limit = currentLimit(for: provider) else {
                return MenuBarReading(provider: provider, value: "—", fraction: nil, severity: nil, reset: nil)
            }
            let value = showRemaining ? limit.remainingPercent : limit.roundedPercent
            let fraction = showRemaining ? 1 - limit.fraction : limit.fraction
            let reset = countdown ? UsageParser.compactResetDescription(limit.resetsAt) : nil
            return MenuBarReading(provider: provider, value: "\(value)%", fraction: fraction,
                                  severity: limit.severity, reset: reset)
        }
    }

    private func currentLimit(for provider: Provider) -> UsageLimit? {
        let state = state(provider)
        guard state.error == nil, let snapshot = state.snapshot,
              Date().timeIntervalSince(snapshot.fetchedAt) < Double(refreshMinutes * 60 + 60) else { return nil }
        return limits(for: provider).first
    }

    private func scheduleRefresh() {
        timer?.invalidate()
        guard !isDemo else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Double(refreshMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        timer?.tolerance = 10
    }
}
