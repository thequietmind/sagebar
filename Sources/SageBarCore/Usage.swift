import Foundation

public enum Provider: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude, codex, grok
    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }
}

/// How close a limit is to running out, used to color meters green, yellow, or red.
public enum UsageSeverity: Sendable {
    case normal, warning, critical
}

public struct UsageLimit: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(id: String, title: String, usedPercent: Double, resetsAt: Date?) {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent.isFinite ? min(9999, max(0, usedPercent)) : 0
        self.resetsAt = resetsAt
    }

    public var fraction: Double { min(1, usedPercent / 100) }
    public var roundedPercent: Int { Int(usedPercent.rounded()) }
    public var remainingPercent: Int { max(0, 100 - roundedPercent) }
    /// Based on the displayed used percentage, whether the menu bar shows used or remaining.
    public var severity: UsageSeverity { roundedPercent >= 90 ? .critical : roundedPercent >= 70 ? .warning : .normal }
    /// Claude's model-scoped weekly limit for Fable, which is hidden unless enabled in Settings.
    public var isFable: Bool { id.lowercased().hasPrefix("weekly_scoped.fable") }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let limits: [UsageLimit]
    public let fetchedAt: Date
    public let note: String?
    public let isBlocked: Bool
    public let accountLabel: String?

    public init(limits: [UsageLimit], fetchedAt: Date = Date(), note: String? = nil, isBlocked: Bool = false, accountLabel: String? = nil) {
        self.limits = limits
        self.fetchedAt = fetchedAt
        self.note = note
        self.isBlocked = isBlocked
        self.accountLabel = accountLabel
    }
}

public enum UsageError: Error, LocalizedError, Sendable {
    case notConnected, invalidCookie, invalidGrokCookie, invalidResponse, signInExpired, rateLimited, network
    case server(Int), codexMissing, codexUnavailable, codexTimedOut, keychain(Int32)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Add a session in Settings to see your usage."
        case .invalidCookie: "Paste a session key or a single Cookie header from claude.ai."
        case .invalidGrokCookie: "Paste the whole Cookie header from a grok.com request, with its name=value pairs."
        case .invalidResponse: "The provider returned an unfamiliar usage response."
        case .signInExpired: "Your sign-in has expired. Reconnect this provider."
        case .rateLimited: "The provider asked us to wait. Try again in a few minutes."
        case .network: "Couldn't reach the provider. Check your connection."
        case .server(let status): "The provider is unavailable (HTTP \(status))."
        case .codexMissing: "Install Codex CLI or Codex Desktop, then sign in."
        case .codexUnavailable: "Codex couldn't read your limits. Open Codex and check your sign-in."
        case .codexTimedOut: "Codex took too long to respond. Try refreshing."
        case .keychain: "Couldn't access the saved session in Keychain."
        }
    }
}

public enum UsageParser {
    public static func claude(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        let document = try JSONDecoder().decode(ClaudeDocument.self, from: data)
        var limits: [UsageLimit] = []
        for entry in document.limits ?? [] {
            guard let percent = entry.percent else { continue }
            let title: String
            switch entry.kind {
            case "session": title = "5-hour session"
            case "weekly_all": title = "Weekly"
            case "weekly_scoped": title = "Weekly · \(entry.scope?.model?.display_name ?? "model")"
            default: continue
            }
            let id = entry.kind + (entry.scope?.model?.display_name.map { "." + $0 } ?? "")
            guard !limits.contains(where: { $0.id == id }) else { continue }
            limits.append(UsageLimit(id: id, title: title, usedPercent: percent, resetsAt: isoDate(entry.resets_at)))
        }
        let legacy: [(String, String, ClaudeDocument.Legacy?)] = [
            ("session", "5-hour session", document.five_hour),
            ("weekly_all", "Weekly", document.seven_day),
            ("weekly_sonnet", "Weekly · Sonnet", document.seven_day_sonnet),
            ("weekly_opus", "Weekly · Opus", document.seven_day_opus)
        ]
        for (id, title, value) in legacy {
            guard !limits.contains(where: { $0.id == id }), let value, let percent = value.utilization else { continue }
            limits.append(UsageLimit(id: id, title: title, usedPercent: percent, resetsAt: isoDate(value.resets_at)))
        }
        guard !limits.isEmpty else { throw UsageError.invalidResponse }
        limits.sort { priority($0.id) < priority($1.id) }
        return UsageSnapshot(limits: limits, fetchedAt: now)
    }

    public static func codex(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        let document = try JSONDecoder().decode(CodexDocument.self, from: data)
        let bucket = document.rateLimitsByLimitId?["codex"] ?? document.rateLimits
        var limits: [UsageLimit] = []
        for (id, value) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
            guard let value else { continue }
            limits.append(UsageLimit(
                id: id, title: windowTitle(value.windowDurationMins), usedPercent: value.usedPercent,
                resetsAt: value.resetsAt.map { Date(timeIntervalSince1970: $0) }
            ))
        }
        if let monthly = bucket.individualLimit {
            limits.append(UsageLimit(id: "monthly", title: "Monthly credits", usedPercent: 100 - monthly.remainingPercent,
                                     resetsAt: Date(timeIntervalSince1970: monthly.resetsAt)))
        }
        let blocked = document.ordinaryUsageAllowed == false || bucket.spendControlReached == true || bucket.rateLimitReachedType != nil
        let note: String?
        if blocked {
            note = "Codex reports a usage limit or credit restriction."
        } else if limits.isEmpty {
            note = "Your plan isn't reporting a percentage limit."
        } else {
            note = nil
        }
        return UsageSnapshot(limits: limits, fetchedAt: now, note: note, isBlocked: blocked)
    }

    /// Grok's shared credit pool from grok.com's `/rest/grok/credits`; `productUsage` is a breakdown of spend, not separate limits.
    public static func grok(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        let document = try JSONDecoder().decode(GrokDocument.self, from: data)
        guard let config = document.config else { throw UsageError.invalidResponse }
        guard config.isUnifiedBillingUser != false, let period = config.currentPeriod else {
            return UsageSnapshot(limits: [], fetchedAt: now, note: "Your plan isn't reporting a percentage limit.")
        }
        let title = switch period.type {
        case "USAGE_PERIOD_TYPE_WEEKLY": "Weekly"
        case "USAGE_PERIOD_TYPE_MONTHLY": "Monthly"
        default: "Usage window"
        }
        // Protobuf JSON omits zero values, so a reported period without a percentage means none used yet.
        let limit = UsageLimit(id: "credits", title: title, usedPercent: config.creditUsagePercent ?? 0,
                               resetsAt: isoDate(period.end ?? config.billingPeriodEnd))
        return UsageSnapshot(limits: [limit], fetchedAt: now)
    }

    public static func resetDescription(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Reset time unavailable" }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Reset due · refresh to confirm" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 { return "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
        return "Resets in \(minutes)m"
    }

    public static func compactResetDescription(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "due" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 { return "\(minutes / 1440)d\((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h\(minutes % 60)m" }
        return "\(minutes)m"
    }

    public static func normalizedCookie(_ input: String) throws -> String {
        guard var cookie = cleanedCookie(input) else { throw UsageError.invalidCookie }
        if cookie.hasPrefix("sk-ant-") && !cookie.contains("=") { cookie = "sessionKey=" + cookie }
        guard cookiePairs(cookie).contains(where: { $0.name == "sessionKey" }) else { throw UsageError.invalidCookie }
        return cookie
    }

    /// Accepts a grok.com Cookie header; grok.com decides which of its cookies authenticate the request.
    public static func normalizedGrokCookie(_ input: String) throws -> String {
        guard let cookie = cleanedCookie(input), !cookiePairs(cookie).isEmpty else { throw UsageError.invalidGrokCookie }
        return cookie
    }

    /// Trims whitespace and a leading `Cookie:` label, rejecting empty input and anything that could inject headers.
    private static func cleanedCookie(_ input: String) -> String? {
        var cookie = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if cookie.lowercased().hasPrefix("cookie:") { cookie = String(cookie.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        guard !cookie.isEmpty, cookie.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return cookie
    }

    private static func cookiePairs(_ cookie: String) -> [(name: Substring, value: Substring)] {
        cookie.split(separator: ";").compactMap { part in
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { return nil }
            return (pair[0], pair[1])
        }
    }

    public static func organization(in cookie: String) -> String? {
        for part in cookie.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0] == "lastActiveOrg", let uuid = UUID(uuidString: String(pair[1])) else { continue }
            return uuid.uuidString.lowercased()
        }
        return nil
    }

    private static func priority(_ id: String) -> Int { id == "session" ? 0 : id == "weekly_all" ? 1 : 2 }
    private static func isoDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
    private static func windowTitle(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "Usage window" }
        if minutes == 10080 { return "Weekly" }
        if minutes == 1440 { return "Daily" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)-day window" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour session" }
        return "\(minutes)-minute window"
    }
}

private struct ClaudeDocument: Decodable {
    struct Entry: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable { let display_name: String? }
            let model: Model?
        }
        let kind: String
        let percent: Double?
        let resets_at: String?
        let scope: Scope?
    }
    struct Legacy: Decodable { let utilization: Double?; let resets_at: String? }
    let limits: [Entry]?
    let five_hour: Legacy?
    let seven_day: Legacy?
    let seven_day_sonnet: Legacy?
    let seven_day_opus: Legacy?
}

private struct GrokDocument: Decodable {
    struct Period: Decodable { let type: String?; let end: String? }
    struct Config: Decodable {
        let currentPeriod: Period?
        let creditUsagePercent: Double?
        let isUnifiedBillingUser: Bool?
        let billingPeriodEnd: String?
    }
    let config: Config?
}

private struct CodexDocument: Decodable {
    struct Window: Decodable { let usedPercent: Double; let windowDurationMins: Int?; let resetsAt: Double? }
    struct Monthly: Decodable { let remainingPercent: Double; let resetsAt: Double }
    struct Bucket: Decodable {
        let primary: Window?
        let secondary: Window?
        let individualLimit: Monthly?
        let spendControlReached: Bool?
        let rateLimitReachedType: String?
    }
    let rateLimits: Bucket
    let rateLimitsByLimitId: [String: Bucket]?
    let ordinaryUsageAllowed: Bool?
}
