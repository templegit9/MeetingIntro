import AuthenticationServices
import CryptoKit
import Foundation

/// Browser sign-in for Microsoft 365: OAuth authorization code + PKCE, presented with
/// `ASWebAuthenticationSession`.
///
/// **Why this replaced the device code flow.** Device code makes the user read a code out
/// of the app, open a browser themselves, navigate to microsoft.com/devicelogin and type
/// it in. That was chosen on the assumption a menu-bar app has no reliable redirect URI —
/// but MeetingIntro is **not** App-Sandboxed (that's how the in-app `brew upgrade` works),
/// so it can receive a custom-scheme callback like any native app. One click, browser
/// opens, approve, done.
///
/// **Custom scheme, not loopback.** `ASWebAuthenticationSession` can only intercept a
/// custom scheme; catching `http://localhost` would mean running a local web server for
/// no benefit. The registration therefore needs `meetingintro://auth` as a public-client
/// redirect URI.
///
/// **PKCE is required, not optional.** A public client has no secret, so the code verifier
/// is what stops an intercepted authorization code from being redeemed by anything else.
@MainActor
final class GraphBrowserAuth: NSObject {

    struct Tokens {
        let accessToken: String
        let expiration: Date
        let refreshToken: String?
        let scope: String?
    }

    /// A sign-in that failed because the tenant demands an administrator's approval —
    /// carried as its own case so the UI can offer the consent link instead of showing a
    /// raw OAuth error. Microsoft's policy now requires admin consent for calendar
    /// permissions in default tenants, so for enterprise users this is the *expected*
    /// outcome, not an edge case.
    enum AuthError: LocalizedError {
        case adminConsentRequired(clientID: String)
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .adminConsentRequired:
                return "Your organisation requires an administrator to approve MeetingIntro's calendar access."
            case .cancelled:
                return "Sign-in was cancelled."
            case .failed(let message):
                return message
            }
        }

        /// The URL an IT administrator opens to approve the app for the whole tenant.
        var adminConsentURL: URL? {
            guard case .adminConsentRequired(let clientID) = self else { return nil }
            return URL(string: "https://login.microsoftonline.com/common/adminconsent?client_id=\(clientID)")
        }
    }

    static let redirectURI = "meetingintro://auth"
    static let callbackScheme = "meetingintro"

    private var session: ASWebAuthenticationSession?

    func signIn(clientID: String, scope: String) async throws -> Tokens {
        let verifier = Self.codeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = UUID().uuidString

        var components = URLComponents(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "response_mode", value: "query"),
            .init(name: "scope", value: scope),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            // Let the user pick which account, rather than silently reusing whichever
            // one the browser happens to be signed into.
            .init(name: "prompt", value: "select_account")
        ]

        let callback = try await present(components.url!)

        guard let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw AuthError.failed("Sign-in returned no result.")
        }
        if let returnedState = items.first(where: { $0.name == "state" })?.value, returnedState != state {
            throw AuthError.failed("Sign-in state mismatch — the response didn't match the request.")
        }
        if let error = items.first(where: { $0.name == "error" })?.value {
            let description = items.first(where: { $0.name == "error_description" })?.value ?? error
            throw Self.classify(error: error, description: description, clientID: clientID)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw AuthError.failed("Sign-in returned no authorization code.")
        }

        return try await redeem(code: code, verifier: verifier, clientID: clientID)
    }

    // MARK: - Steps

    private func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                } else {
                    continuation.resume(throwing: AuthError.failed(error?.localizedDescription ?? "Sign-in failed."))
                }
            }
            session.presentationContextProvider = self
            // Keep the existing browser session so corporate SSO carries over — an
            // ephemeral session would make every sign-in a full re-authentication.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }

    private func redeem(code: String, verifier: String, clientID: String) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id=\(clientID)",
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(Self.redirectURI.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? Self.redirectURI)",
            "code_verifier=\(verifier)"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.failed("No response from Microsoft.")
        }
        struct TokenResponse: Decodable {
            let access_token: String?
            let expires_in: Int?
            let refresh_token: String?
            let scope: String?
            let error: String?
            let error_description: String?
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        if let error = decoded.error {
            throw Self.classify(error: error, description: decoded.error_description ?? error, clientID: clientID)
        }
        guard http.statusCode == 200, let token = decoded.access_token else {
            throw AuthError.failed("Token request failed (HTTP \(http.statusCode)).")
        }
        return Tokens(
            accessToken: token,
            expiration: Date().addingTimeInterval(TimeInterval(decoded.expires_in ?? 3600)),
            refreshToken: decoded.refresh_token,
            scope: decoded.scope
        )
    }

    /// Entra reports "an administrator must approve this" through several AADSTS codes;
    /// they all mean the same thing to a user, and none of them is a bug to debug.
    private static func classify(error: String, description: String, clientID: String) -> AuthError {
        let haystack = "\(error) \(description)".lowercased()
        let consentCodes = ["aadsts65001", "aadsts90094", "aadsts900941", "consent_required", "admin_consent"]
        if consentCodes.contains(where: haystack.contains) || haystack.contains("administrator") {
            return .adminConsentRequired(clientID: clientID)
        }
        return .failed(description)
    }

    // MARK: - PKCE

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

extension GraphBrowserAuth: ASWebAuthenticationPresentationContextProviding {
    /// `LSUIElement` apps often have no window at all, so fall back to a throwaway one —
    /// returning nothing crashes the session.
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApplication.shared.keyWindow
                ?? NSApplication.shared.windows.first { $0.isVisible }
                ?? NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        }
    }
}
