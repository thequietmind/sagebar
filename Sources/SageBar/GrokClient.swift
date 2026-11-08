import Foundation
import SageBarCore

/// Reads the shared weekly credit pool that grok.com's Settings → Usage tab shows (undocumented endpoint).
struct GrokClient: Sendable {
    private static let creditsURL = URL(string: "https://grok.com/rest/grok/credits")!

    func fetch(cookie: String) async throws -> UsageSnapshot {
        let cookie = try UsageParser.normalizedGrokCookie(cookie)
        let session = WebSession.make()
        defer { session.invalidateAndCancel() }
        let data = try await WebSession.get(Self.creditsURL, cookie: cookie, referer: "https://grok.com/", session: session)
        do { return try UsageParser.grok(data) } catch { throw UsageError.invalidResponse }
    }
}
