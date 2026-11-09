import Foundation
import SageBarCore
import Security

/// Pasted website sessions in Keychain, one item per provider (`com.quietmindcreative.SageBar.<provider>`).
enum SessionVault {
    private static func query(_ provider: Provider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(AppInfo.identifier).\(provider.rawValue)",
         kSecAttrAccount as String: "session"]
    }

    static func load(_ provider: Provider) throws -> String? {
        var request = query(provider)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw UsageError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    /// Validates the pasted session for its provider, then saves the normalized form.
    static func save(_ cookie: String, for provider: Provider) throws {
        let normalized = try provider == .grok ? UsageParser.normalizedGrokCookie(cookie) : UsageParser.normalizedCookie(cookie)
        let attributes = [kSecValueData as String: Data(normalized.utf8)]
        let status = SecItemUpdate(query(provider) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw UsageError.keychain(status) }
        var entry = query(provider).merging(attributes) { _, new in new }
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(entry as CFDictionary, nil)
        guard added == errSecSuccess else { throw UsageError.keychain(added) }
    }

    static func delete(_ provider: Provider) throws {
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw UsageError.keychain(status) }
    }
}

/// Cookie-authenticated JSON reads from a provider's website: no cookie storage, no redirects to other hosts.
enum WebSession {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    static func make() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: SameHostRedirects(), delegateQueue: nil)
    }

    static func get(_ url: URL, cookie: String, referer: String, session: URLSession) async throws -> Data {
        guard let scheme = url.scheme, let host = url.host() else { throw UsageError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw UsageError.network }
        guard let response = response as? HTTPURLResponse else { throw UsageError.network }
        switch response.statusCode {
        case 200: return data
        case 401, 403: throw UsageError.signInExpired
        case 429: throw UsageError.rateLimited
        default: throw UsageError.server(response.statusCode)
        }
    }
}

private final class SameHostRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let allowed = request.url?.scheme == "https" && request.url?.host == task.originalRequest?.url?.host
        completionHandler(allowed ? request : nil)
    }
}
