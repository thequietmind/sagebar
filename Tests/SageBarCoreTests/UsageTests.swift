import Foundation
import XCTest
@testable import SageBarCore

final class UsageTests: XCTestCase {
    func testClaudeLegacyWindowsAndFractionalReset() throws {
        let snapshot = try UsageParser.claude(Data(#"{"five_hour":{"utilization":32.4,"resets_at":"2026-11-08T22:30:00.123456Z"},"seven_day":{"utilization":61},"seven_day_sonnet":null}"#.utf8))
        XCTAssertEqual(snapshot.limits.map(\.title), ["5-hour session", "Weekly"])
        XCTAssertEqual(snapshot.limits[0].roundedPercent, 32)
        XCTAssertNotNil(snapshot.limits[0].resetsAt)
        XCTAssertNil(snapshot.limits[1].resetsAt)
    }

    func testClaudeModernWindowsUseScopeNamesAndFallback() throws {
        let snapshot = try UsageParser.claude(Data(#"{"limits":[{"kind":"weekly_scoped","percent":83,"scope":{"model":{"display_name":"Fable"}}},{"kind":"session","percent":11},{"kind":"unrecognized","percent":5}],"seven_day":{"utilization":44}}"#.utf8))
        XCTAssertEqual(snapshot.limits.map(\.title), ["5-hour session", "Weekly", "Weekly · Fable"])
        XCTAssertEqual(snapshot.limits.map(\.roundedPercent), [11, 44, 83])
    }

    func testFableLimitIsIdentifiedByModelScope() throws {
        let snapshot = try UsageParser.claude(Data(#"{"limits":[{"kind":"session","percent":11},{"kind":"weekly_scoped","percent":83,"scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_scoped","percent":20,"scope":{"model":{"display_name":"Opus"}}}]}"#.utf8))
        XCTAssertEqual(snapshot.limits.filter(\.isFable).map(\.title), ["Weekly · Fable"])
        XCTAssertEqual(snapshot.limits.filter { !$0.isFable }.map(\.title), ["5-hour session", "Weekly · Opus"])
    }

    func testNoInventedClaudeQuotaForUnknownResponse() {
        XCTAssertThrowsError(try UsageParser.claude(Data(#"{"limits":[],"five_hour":null}"#.utf8)))
        XCTAssertThrowsError(try UsageParser.claude(Data(#"{"five_hour":{"utilization":true}}"#.utf8)))
        XCTAssertThrowsError(try UsageParser.claude(Data("not json".utf8)))
    }

    func testCodexLabelsWeeklyPrimaryAccurately() throws {
        let snapshot = try UsageParser.codex(Data(#"{"rateLimits":{"primary":{"usedPercent":65,"windowDurationMins":10080,"resetsAt":1794444215},"secondary":null}}"#.utf8))
        XCTAssertEqual(snapshot.limits.count, 1)
        XCTAssertEqual(snapshot.limits[0].title, "Weekly")
        XCTAssertEqual(snapshot.limits[0].remainingPercent, 35)
        XCTAssertEqual(snapshot.limits[0].resetsAt, Date(timeIntervalSince1970: 1794444215))
    }

    func testCodexSelectsCodexBucketAndMonthlyLimit() throws {
        let snapshot = try UsageParser.codex(Data(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":20,"windowDurationMins":300},"secondary":{"usedPercent":35,"windowDurationMins":10080},"individualLimit":{"remainingPercent":13,"resetsAt":1794444215}}}}"#.utf8))
        XCTAssertEqual(snapshot.limits.map(\.title), ["5-hour session", "Weekly", "Monthly credits"])
        XCTAssertEqual(snapshot.limits.map(\.roundedPercent), [20, 35, 87])
    }

    func testCodexNoPercentageIsUnavailableNotZero() throws {
        let snapshot = try UsageParser.codex(Data(#"{"rateLimits":{"primary":null,"secondary":null}}"#.utf8))
        XCTAssertTrue(snapshot.limits.isEmpty)
        XCTAssertNotNil(snapshot.note)
        XCTAssertFalse(snapshot.isBlocked)
    }

    func testCodexRestrictionSurvivesLowPercentage() throws {
        let snapshot = try UsageParser.codex(Data(#"{"ordinaryUsageAllowed":false,"rateLimits":{"primary":{"usedPercent":0}}}"#.utf8))
        XCTAssertTrue(snapshot.isBlocked)
        XCTAssertNotNil(snapshot.note)
    }

    func testNoExtraCreditsDoesNotMeanSubscriptionIsExhausted() throws {
        let snapshot = try UsageParser.codex(Data(#"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":65,"windowDurationMins":10080},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"spendControlReached":false,"rateLimitReachedType":null}}"#.utf8))
        XCTAssertFalse(snapshot.isBlocked)
        XCTAssertNil(snapshot.note)
        XCTAssertEqual(snapshot.limits[0].remainingPercent, 35)
    }

    func testGrokWeeklyPoolUsesCurrentPeriodNotProductShares() throws {
        let snapshot = try UsageParser.grok(Data(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-11-05T03:47:45.598Z","end":"2026-11-12T03:47:45.598Z"},"creditUsagePercent":64,"onDemandCap":null,"productUsage":[{"product":"PRODUCT_GROK_BOT","usagePercent":71},{"product":"PRODUCT_CURSOR","usagePercent":29}],"isUnifiedBillingUser":true,"prepaidBalance":{"val":"0"},"billingPeriodEnd":"2026-11-12T03:47:45.598Z"}}"#.utf8))
        XCTAssertEqual(snapshot.limits.map(\.title), ["Weekly"])
        XCTAssertEqual(snapshot.limits[0].roundedPercent, 64)
        XCTAssertEqual(snapshot.limits[0].resetsAt, Date(timeIntervalSince1970: 1_794_455_265.598))
        XCTAssertNil(snapshot.note)
    }

    func testGrokOmittedPercentMeansNoneUsedWithinReportedPeriod() throws {
        let snapshot = try UsageParser.grok(Data(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY"},"billingPeriodEnd":"2026-12-01T00:00:00Z"}}"#.utf8))
        XCTAssertEqual(snapshot.limits.map(\.title), ["Monthly"])
        XCTAssertEqual(snapshot.limits[0].roundedPercent, 0)
        XCTAssertEqual(snapshot.limits[0].resetsAt, Date(timeIntervalSince1970: 1_796_083_200))
    }

    func testGrokLegacyBillingIsUnavailableNotZero() throws {
        let legacy = try UsageParser.grok(Data(#"{"config":{"isUnifiedBillingUser":false,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY"}}}"#.utf8))
        XCTAssertTrue(legacy.limits.isEmpty)
        XCTAssertNotNil(legacy.note)
        XCTAssertTrue(try UsageParser.grok(Data(#"{"config":{"creditUsagePercent":40}}"#.utf8)).limits.isEmpty)
        XCTAssertThrowsError(try UsageParser.grok(Data("{}".utf8)))
        XCTAssertThrowsError(try UsageParser.grok(Data("not json".utf8)))
    }

    func testGrokCookieAcceptsHeaderAndRejectsInjection() throws {
        XCTAssertEqual(try UsageParser.normalizedGrokCookie(" Cookie: sso=abc; sso-rw=def "), "sso=abc; sso-rw=def")
        XCTAssertThrowsError(try UsageParser.normalizedGrokCookie("sso=abc\r\nAuthorization: bad"))
        XCTAssertThrowsError(try UsageParser.normalizedGrokCookie(""))
        XCTAssertThrowsError(try UsageParser.normalizedGrokCookie("just-a-token"))
        XCTAssertThrowsError(try UsageParser.normalizedGrokCookie("sso="))
    }

    func testSeverityFollowsDisplayedUsedPercent() {
        let severity = { (percent: Double) in UsageLimit(id: "test", title: "Test", usedPercent: percent, resetsAt: nil).severity }
        XCTAssertEqual(severity(0), .normal)
        XCTAssertEqual(severity(69.4), .normal)
        XCTAssertEqual(severity(69.5), .warning)
        XCTAssertEqual(severity(89), .warning)
        XCTAssertEqual(severity(90), .critical)
        XCTAssertEqual(severity(125), .critical)
    }

    func testClampedMeterKeepsOverageAndNeverGoesNegative() {
        let over = UsageLimit(id: "test", title: "Test", usedPercent: 125, resetsAt: nil)
        XCTAssertEqual(over.fraction, 1)
        XCTAssertEqual(over.roundedPercent, 125)
        XCTAssertEqual(over.remainingPercent, 0)
        XCTAssertEqual(UsageLimit(id: "test", title: "Test", usedPercent: -9, resetsAt: nil).fraction, 0)
    }

    func testResetCountdownDoesNotAssumeQuotaRecovered() {
        let now = Date(timeIntervalSince1970: 10000)
        XCTAssertEqual(UsageParser.resetDescription(now.addingTimeInterval(-1), now: now), "Reset due · refresh to confirm")
        XCTAssertEqual(UsageParser.resetDescription(now.addingTimeInterval(1), now: now), "Resets in 1m")
        XCTAssertEqual(UsageParser.resetDescription(now.addingTimeInterval(3660), now: now), "Resets in 1h 1m")
        XCTAssertEqual(UsageParser.resetDescription(nil, now: now), "Reset time unavailable")
    }

    func testCompactResetCountdownBoundaries() {
        let now = Date(timeIntervalSince1970: 10000)
        XCTAssertNil(UsageParser.compactResetDescription(nil, now: now))
        XCTAssertEqual(UsageParser.compactResetDescription(now, now: now), "due")
        XCTAssertEqual(UsageParser.compactResetDescription(now.addingTimeInterval(-1), now: now), "due")
        XCTAssertEqual(UsageParser.compactResetDescription(now.addingTimeInterval(1), now: now), "1m")
        XCTAssertEqual(UsageParser.compactResetDescription(now.addingTimeInterval(3600), now: now), "1h0m")
        XCTAssertEqual(UsageParser.compactResetDescription(now.addingTimeInterval(3660), now: now), "1h1m")
        XCTAssertEqual(UsageParser.compactResetDescription(now.addingTimeInterval(86400), now: now), "1d0h")
        XCTAssertEqual(UsageParser.compactResetDescription(now.addingTimeInterval(273600), now: now), "3d4h")
    }

    func testCookieNormalizationAndHeaderInjectionRejection() throws {
        XCTAssertEqual(try UsageParser.normalizedCookie(" sk-ant-test "), "sessionKey=sk-ant-test")
        XCTAssertEqual(try UsageParser.normalizedCookie("Cookie: sessionKey=example; other=value"), "sessionKey=example; other=value")
        XCTAssertThrowsError(try UsageParser.normalizedCookie("sessionKey=test\r\nAuthorization: bad"))
        XCTAssertThrowsError(try UsageParser.normalizedCookie(""))
        XCTAssertThrowsError(try UsageParser.normalizedCookie("not-a-session"))
        XCTAssertThrowsError(try UsageParser.normalizedCookie("sessionKey="))
    }

    func testOrganizationMustBeUUID() {
        XCTAssertEqual(UsageParser.organization(in: "sessionKey=test; lastActiveOrg=12345678-1234-1234-1234-123456789abc"), "12345678-1234-1234-1234-123456789abc")
        XCTAssertNil(UsageParser.organization(in: "lastActiveOrg=../../example"))
        XCTAssertNil(UsageParser.organization(in: "sessionKey=test"))
    }
}
