import Foundation

/// Decides whether a window is one ScreenMate should refuse to photograph.
///
/// Deliberately conservative and deliberately not a security boundary: it stops
/// the obvious accidents (the user asks "what am I looking at?" while their
/// password manager is open) and tells them why, rather than silently capturing.
public struct SensitiveAppPolicy: Sendable {
    /// Bundle identifiers that are blocked outright.
    public static let blockedBundleIdentifiers: Set<String> = [
        "com.1password.1password",
        "com.1password.1password7",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.Dashlane",
        "in.sinew.Enpass-Desktop",
        "com.apple.keychainaccess",
        "org.keepassxc.keepassxc",
        "com.apple.Passwords",
        "com.stripe.dashboard",
    ]

    /// Substrings matched case-insensitively against the window title.
    public static let blockedTitleFragments: [String] = [
        "password",
        "passphrase",
        "private key",
        "secret key",
        "seed phrase",
        "recovery phrase",
        "authenticator",
        "one-time code",
        "credit card",
        "card number",
        "cvv",
        "social security",
        "bank login",
        "sign in to",
        "two-factor",
    ]

    public struct Decision: Sendable, Equatable {
        public let isBlocked: Bool
        /// Shown verbatim to the user when blocked.
        public let reason: String?

        public init(isBlocked: Bool, reason: String?) {
            self.isBlocked = isBlocked
            self.reason = reason
        }

        public static let allowed = Decision(isBlocked: false, reason: nil)
    }

    public init() {}

    public func evaluate(
        bundleIdentifier: String?,
        windowTitle: String?,
        appName: String?,
        isEnabled: Bool = true
    ) -> Decision {
        guard isEnabled else { return .allowed }

        if let bundleIdentifier,
           Self.blockedBundleIdentifiers.contains(bundleIdentifier.lowercased()) {
            let name = appName ?? bundleIdentifier
            return Decision(
                isBlocked: true,
                reason: "ScreenMate does not capture \(name), because it usually shows credentials. You can turn this guard off in Settings › Privacy."
            )
        }

        if let windowTitle {
            let lowered = windowTitle.lowercased()
            if let fragment = Self.blockedTitleFragments.first(where: { lowered.contains($0) }) {
                return Decision(
                    isBlocked: true,
                    reason: "This window's title mentions \"\(fragment)\", so ScreenMate did not capture it. Capture a different region, or turn this guard off in Settings › Privacy."
                )
            }
        }

        return .allowed
    }
}
