import AuthenticationServices
import CryptoKit
import Foundation

/// Browser sign-in for Google Calendar: authorization code + PKCE via
/// `ASWebAuthenticationSession`, the same shape as `GraphBrowserAuth`.
///
/// **Three things differ from Microsoft and all three are load-bearing:**
///
/// 1. **The redirect URI is derived from the client ID**, not a constant. Google's
///    native (iOS/macOS) client type only accepts the *reversed* client ID as a scheme —
///    `com.googleusercontent.apps.123-abc:/oauth2redirect`. Our `meetingintro://auth`
///    is rejected outright, so `redirectURI(for:)` builds it per client.
/// 2. **A refresh token is only issued with `access_type=offline` AND `prompt=consent`.**
///    Without the second, a user who has approved before gets an access token and *no*
///    refresh token, and the account silently dies an hour later — the exact bug Graph
///    shipped with before v2.7.0. Don't remove `prompt=consent` to smooth the flow.
/// 3. **There is no bundled client ID.** Google will not let an app ship one usable by
///    other people without OAuth verification, so the user supplies their own. See
///    `GoogleCalendarProvider.setupURL`.
@MainActor
final class GoogleCalendarAuth: NSObject {

    struct Tokens {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
        var grantedScope: String
    }

    enum AuthError: LocalizedError {
        case cancelled
        case missingClientID
        case malformedClientID
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Sign-in was cancelled."
            case .missingClientID:
                return "Add a Google OAuth client ID in Settings → Calendar before signing in."
            case .malformedClientID:
                return "That doesn't look like a Google client ID. It should end in .apps.googleusercontent.com"
            case .failed(let message):
                return message
            }
        }
    }

    /// Google client IDs look like `1234567890-abcdef.apps.googleusercontent.com`.
    /// Checked before we open a browser, so a typo fails immediately with a clear
    /// message instead of a Google error page the user has to interpret.
    static func isPlausibleClientID(_ id: String) -> Bool {
        id.hasSuffix(".apps.googleusercontent.com") && id.count > ".apps.googleusercontent.com".count
    }

    /// `1234-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.1234-abc`
    static func callbackScheme(for clientID: String) -> String {
        let head = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(head)"
    }

    static func redirectURI(for clientID: String) -> String {
        "\(callbackScheme(for: clientID)):/oauth2redirect"
    }

    /// Least privilege, deliberately: events read+write (RSVP needs write), the calendar
    /// list, and free/busy. **Not** the blanket `/auth/calendar` scope — a narrower set
    /// is both safer and materially easier to get through Google's verification review.
    static let scope = [
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.freebusy"
    ].joined(separator: " ")

    private var session: ASWebAuthenticationSession?

    func signIn(clientID: String) async throws -> Tokens {
        guard !clientID.isEmpty else { throw AuthError.missingClientID }
        guard Self.isPlausibleClientID(clientID) else { throw AuthError.malformedClientID }

        let verifier = Self.codeVerifier()
        let state = UUID().uuidString
        let redirect = Self.redirectURI(for: clientID)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "scope", value: Self.scope),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            // Both are required for a refresh token. See the note at the top.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent")
        ]

        let callback = try await present(components.url!, scheme: Self.callbackScheme(for: clientID))
        guard let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw AuthError.failed("Sign-in returned no result.")
        }
        if let returned = items.first(where: { $0.name == "state" })?.value, returned != state {
            throw AuthError.failed("Sign-in state mismatch — the response didn't match the request.")
        }
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw AuthError.failed(Self.explain(error))
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw AuthError.failed("Sign-in returned no authorization code.")
        }
        return try await redeem(code: code, verifier: verifier, clientID: clientID, redirect: redirect)
    }

    /// Exchange a refresh token for a fresh access token. Google does **not** return a
    /// new refresh token here, so the caller must keep the one it already has.
    func refresh(refreshToken: String, clientID: String) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = [
            "client_id=\(clientID)",
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken)"
        ].joined(separator: "&").data(using: .utf8)
        var tokens = try await Self.decodeTokens(from: request)
        tokens.refreshToken = refreshToken
        return tokens
    }

    // MARK: - Steps

    private func present(_ url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                } else {
                    continuation.resume(throwing: AuthError.failed(error?.localizedDescription ?? "Sign-in failed."))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }

    private func redeem(code: String, verifier: String, clientID: String, redirect: String) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encodedRedirect = redirect.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? redirect
        request.httpBody = [
            "client_id=\(clientID)",
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(encodedRedirect)",
            "code_verifier=\(verifier)"
        ].joined(separator: "&").data(using: .utf8)
        return try await Self.decodeTokens(from: request)
    }

    private static func decodeTokens(from request: URLRequest) async throws -> Tokens {
        struct Response: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expires_in: Int?
            let scope: String?
            let error: String?
            let error_description: String?
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        if let error = decoded.error {
            throw AuthError.failed(decoded.error_description ?? explain(error))
        }
        guard let token = decoded.access_token else {
            throw AuthError.failed("Google returned no access token.")
        }
        return Tokens(
            accessToken: token,
            refreshToken: decoded.refresh_token,
            // 60s of slack so a request never starts against a token about to expire.
            expiresAt: Date().addingTimeInterval(TimeInterval((decoded.expires_in ?? 3600) - 60)),
            grantedScope: decoded.scope ?? ""
        )
    }

    /// Google's raw error codes are opaque to a user; the two that actually happen get
    /// an answer rather than a code.
    private static func explain(_ error: String) -> String {
        switch error {
        case "access_denied":
            return "Google sign-in was declined. If your account is managed by an organization, an administrator may need to allow this app."
        case "redirect_uri_mismatch":
            return "Google rejected the redirect URI. The OAuth client must be created as an iOS/macOS app type — a Web application client won't work here."
        case "admin_policy_enforced":
            return "Your organization's Google Workspace policy blocks this app. An administrator has to allow it before you can sign in."
        default:
            return "Google sign-in failed: \(error)"
        }
    }

    private static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension GoogleCalendarAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApplication.shared.windows.first ?? ASPresentationAnchor() }
    }
}
