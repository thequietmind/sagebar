import Foundation
import SageBarCore

struct ClaudeClient: Sendable {
    func fetch(cookie: String) async throws -> UsageSnapshot {
        let cookie = try UsageParser.normalizedCookie(cookie)
        let session = WebSession.make()
        defer { session.invalidateAndCancel() }
        let organization: String
        if let existing = UsageParser.organization(in: cookie) {
            organization = existing
        } else {
            let data = try await request(path: "/api/bootstrap", cookie: cookie, session: session)
            let bootstrap = try JSONDecoder().decode(Bootstrap.self, from: data)
            guard let uuid = UUID(uuidString: bootstrap.account.lastActiveOrgId) else { throw UsageError.invalidResponse }
            organization = uuid.uuidString.lowercased()
        }
        let data = try await request(path: "/api/organizations/\(organization)/usage", cookie: cookie, session: session)
        do { return try UsageParser.claude(data) } catch { throw UsageError.invalidResponse }
    }

    private func request(path: String, cookie: String, session: URLSession) async throws -> Data {
        guard let url = URL(string: "https://claude.ai" + path) else { throw UsageError.invalidResponse }
        return try await WebSession.get(url, cookie: cookie, referer: "https://claude.ai/settings/usage", session: session)
    }

    private struct Bootstrap: Decodable {
        struct Account: Decodable { let lastActiveOrgId: String }
        let account: Account
    }
}
