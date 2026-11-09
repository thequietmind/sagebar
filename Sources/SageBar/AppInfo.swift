import Foundation

/// Identity shared by the app bundle, its Keychain items, and the Codex handshake.
enum AppInfo {
    /// Matches `CFBundleIdentifier` in Scripts/build-app.sh.
    static let identifier = "com.quietmindcreative.SageBar"
    /// The bundle's marketing version, from the VERSION file; "dev" outside the app bundle, as with `swift run`.
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}
