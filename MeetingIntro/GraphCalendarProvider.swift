import AppKit
import Foundation

/// Calendar provider implementation using Microsoft Graph REST API.
/// Requires an Azure App Registration with `Calendars.Read` permission.
final class GraphCalendarProvider: CalendarProvider {

    let providerType: CalendarProviderType = .microsoftGraph

    /// MeetingIntro's own Azure app registration. **A client ID is not a secret** — a
    /// public client has none, which is why VS Code and the Azure CLI ship theirs in the
    /// open. Bundling it is the entire difference between "sign in with Microsoft" and
    /// "go create an app registration in the Azure Portal", which no user will do.
    static let defaultClientID = "meetingintro://auth"

    /// Diagnostic log, injected in `AppLifecycleManager.observe` (same as the EventKit
    /// provider). `DiagnosticLog` is main-actor isolated, so writes hop through
    /// `MainActor.run`.
    var diagnosticLog: DiagnosticLog?

    private func log(_ level: String, _ message: String) async {
        guard let diagnosticLog else { return }
        await MainActor.run {
            if level == "warn" { diagnosticLog.warn(.calendar, message) }
            else { diagnosticLog.info(.calendar, message) }
        }
    }

    /// The Application (client) ID. Falls back to the bundled registration, so the
    /// Settings field is an override for someone who wants their own, not a requirement.
    var clientId: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "graphClientId") ?? ""
            return stored.isEmpty ? Self.defaultClientID : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: "graphClientId") }
    }

    private static let accessTokenAccount = "graphAccessToken"
    private static let tokenExpirationAccount = "graphTokenExpiration"
    private static let refreshTokenAccount = "graphRefreshToken"
    private static let grantedScopeAccount = "graphGrantedScope"

    /// OAuth scope. `Calendars.ReadWrite` (v2.7.0, was `.Read`) so we can RSVP to
    /// invitations; `offline_access` yields a refresh token. Used by both the
    /// device-code request and the refresh request so they stay consistent.
    /// What we ask for at sign-in. **The registration's permission list doesn't grant
    /// anything — this string does.** A permission added in Azure but missing here is
    /// simply never consented to, which is a silent way to lose a capability.
    ///
    /// `Calendars.ReadWrite` covers reading (so `GraphVerifier` works) plus creating
    /// events with attendees, which is the one thing EventKit categorically cannot do —
    /// Apple blocks programmatic invitations. `Calendars.Read.Shared` extends reading to
    /// calendars shared with the user or accessed as a delegate.
    /// `User.Read` is here for a reason that cost a debugging round trip: without it the
    /// token is valid for calendars but **`/me` returns 401**, so the app could read your
    /// meetings while being unable to say whose they were. The registration listing a
    /// permission grants nothing — only this string does, which is the same trap that
    /// hid `Calendars.Read.Shared` earlier.
    private static let oauthScope = "https://graph.microsoft.com/Calendars.ReadWrite https://graph.microsoft.com/Calendars.Read.Shared https://graph.microsoft.com/User.Read offline_access"

    /// Whether the current token was granted `User.Read`. A token minted before that
    /// scope was requested keeps working for calendars, so the honest ask is "sign in
    /// again", not "something went wrong".
    var canReadProfile: Bool {
        grantedScope.lowercased().contains("user.read")
    }

    /// Cached OAuth2 access token. Backed by Keychain; on first read after upgrading
    /// from a UserDefaults-storing build, the legacy value is migrated and cleared.
    private var accessToken: String? {
        get {
            if let token = KeychainStore.get(Self.accessTokenAccount) { return token }
            if let legacy = UserDefaults.standard.string(forKey: Self.accessTokenAccount) {
                KeychainStore.set(legacy, for: Self.accessTokenAccount)
                UserDefaults.standard.removeObject(forKey: Self.accessTokenAccount)
                return legacy
            }
            return nil
        }
        set {
            if let value = newValue {
                KeychainStore.set(value, for: Self.accessTokenAccount)
            } else {
                KeychainStore.delete(Self.accessTokenAccount)
            }
        }
    }

    /// Token expiration date. Stored as `timeIntervalSince1970` string in Keychain.
    private var tokenExpiration: Date? {
        get {
            if let raw = KeychainStore.get(Self.tokenExpirationAccount),
               let interval = TimeInterval(raw) {
                return Date(timeIntervalSince1970: interval)
            }
            if let legacy = UserDefaults.standard.object(forKey: Self.tokenExpirationAccount) as? Date {
                KeychainStore.set(String(legacy.timeIntervalSince1970), for: Self.tokenExpirationAccount)
                UserDefaults.standard.removeObject(forKey: Self.tokenExpirationAccount)
                return legacy
            }
            return nil
        }
        set {
            if let date = newValue {
                KeychainStore.set(String(date.timeIntervalSince1970), for: Self.tokenExpirationAccount)
            } else {
                KeychainStore.delete(Self.tokenExpirationAccount)
            }
        }
    }

    /// Long-lived refresh token (from `offline_access`). Lets us mint new access
    /// tokens without making the user sign in again — previously discarded, which
    /// is why Graph silently died ~1h after login.
    private var refreshToken: String? {
        get { KeychainStore.get(Self.refreshTokenAccount) }
        set {
            if let value = newValue { KeychainStore.set(value, for: Self.refreshTokenAccount) }
            else { KeychainStore.delete(Self.refreshTokenAccount) }
        }
    }

    /// The scope string the current tokens were granted under. Lets us detect that a
    /// token predating the ReadWrite upgrade can't RSVP yet (→ prompt to re-authorize).
    private var grantedScope: String {
        get { KeychainStore.get(Self.grantedScopeAccount) ?? "" }
        set { KeychainStore.set(newValue, for: Self.grantedScopeAccount) }
    }

    /// Set of calendar IDs the user has chosen to monitor (empty = all).
    var selectedCalendarIDs: Set<String> = []

    /// Graph sign-in opens a browser; it is never started automatically. See the
    /// protocol extension for why.
    var requiresInteractiveSignIn: Bool { true }

    var isAuthorized: Bool {
        // A live access token, or a refresh token we can mint one from.
        if let token = accessToken, !token.isEmpty, let expiration = tokenExpiration, expiration > Date() {
            return true
        }
        return (refreshToken?.isEmpty == false)
    }

    /// Whether we can write RSVP responses — authorized AND the granted scope
    /// includes write access. Read-only legacy tokens report false until re-auth.
    var supportsResponding: Bool {
        isAuthorized && grantedScope.lowercased().contains("calendars.readwrite")
    }

    // MARK: - CalendarProvider

    func requestAccess() async throws -> Bool {
        guard !clientId.isEmpty else {
            throw CalendarProviderError.notAuthenticated
        }

        // Browser sign-in (authorization code + PKCE). The device code flow is kept
        // below as a fallback for the case where the custom-scheme callback can't be
        // presented; it asks the user to copy a code by hand, so it is never the default.
        let browser = await GraphBrowserAuth()
        let tokens = try await browser.signIn(clientID: clientId, scope: Self.oauthScope)
        self.accessToken = tokens.accessToken
        self.tokenExpiration = tokens.expiration
        if let rt = tokens.refreshToken { self.refreshToken = rt }
        self.grantedScope = tokens.scope ?? Self.oauthScope
        await refreshAccountLabel()
        return true
    }

    /// The original device code flow: shows a code the user types at
    /// microsoft.com/devicelogin. Retained for troubleshooting when the browser
    /// callback doesn't come back.
    func requestAccessWithDeviceCode() async throws -> Bool {
        guard !clientId.isEmpty else { throw CalendarProviderError.notAuthenticated }
        let token = try await performDeviceCodeAuth()
        self.accessToken = token.accessToken
        self.tokenExpiration = token.expiration
        if let rt = token.refreshToken { self.refreshToken = rt }
        self.grantedScope = token.scope ?? Self.oauthScope
        return true
    }

    /// Returns a usable access token, transparently refreshing via the refresh token
    /// when the cached one has expired. Throws `.notAuthenticated` only when there's
    /// no way to obtain a valid token (no refresh token, or refresh failed).
    private func validToken() async throws -> String {
        if let token = accessToken, !token.isEmpty, let exp = tokenExpiration, exp > Date().addingTimeInterval(60) {
            return token
        }
        guard let refresh = refreshToken, !refresh.isEmpty else {
            throw CalendarProviderError.notAuthenticated
        }
        return try await refreshAccessToken(using: refresh)
    }

    /// Exchange the refresh token for a new access token (and rotated refresh token).
    private func refreshAccessToken(using refresh: String) async throws -> String {
        let tokenUrl = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
        var request = URLRequest(url: tokenUrl)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=refresh_token&client_id=\(clientId)&refresh_token=\(refresh)&scope=\(Self.oauthScope)"
            .data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            // Refresh token rejected/expired — force a fresh sign-in.
            signOut()
            throw CalendarProviderError.notAuthenticated
        }
        self.accessToken = tokenResponse.accessToken
        self.tokenExpiration = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        if let rt = tokenResponse.refreshToken { self.refreshToken = rt }
        if let scope = tokenResponse.scope { self.grantedScope = scope }
        return tokenResponse.accessToken
    }

    func fetchUpcomingEvents(within interval: TimeInterval) async throws -> [MeetingEvent] {
        let token = try await validToken()

        let now = Date()
        let endDate = now.addingTimeInterval(interval)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let startStr = formatter.string(from: now)
        let endStr = formatter.string(from: endDate)

        let urlString = "https://graph.microsoft.com/v1.0/me/calendarview?startdatetime=\(startStr)&enddatetime=\(endStr)&$select=id,subject,start,end,location,isAllDay,organizer,body,attendees,onlineMeeting,isOnlineMeeting,isCancelled,responseStatus,type&$orderby=start/dateTime"

        guard let url = URL(string: urlString) else {
            throw CalendarProviderError.unknown(underlying: URLError(.badURL))
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CalendarProviderError.networkError(underlying: URLError(.badServerResponse))
        }

        if httpResponse.statusCode == 401 {
            self.accessToken = nil
            throw CalendarProviderError.notAuthenticated
        }

        guard httpResponse.statusCode == 200 else {
            throw CalendarProviderError.networkError(
                underlying: URLError(.init(rawValue: httpResponse.statusCode))
            )
        }

        let decoded = try JSONDecoder().decode(GraphCalendarResponse.self, from: data)

        return decoded.value
            .filter { !$0.isAllDay }
            .compactMap { event -> MeetingEvent? in
                guard let startDate = parseGraphDate(event.start),
                      let endDate = parseGraphDate(event.end) else { return nil }

                // Filter by selected calendars if any are set
                // Graph calendarview doesn't include calendar ID by default,
                // so we skip calendar filtering for now unless we add calendar-specific queries

                let attendeeNames = (event.attendees ?? []).compactMap { $0.emailAddress?.name }
                let notes = event.body.flatMap { Self.plainText(from: $0) }
                let onlineMeetingURL = event.onlineMeeting?.joinUrl.flatMap(URL.init(string:))
                let joinURL = ConferenceLinkExtractor.bestURL(
                    eventURL: nil,
                    notes: notes,
                    location: event.location?.displayName,
                    graphOnlineMeetingURL: onlineMeetingURL
                )
                let title = event.subject ?? "Untitled Meeting"
                let cancelled = (event.isCancelled ?? false) || CancellationTitlePrefix.matches(title)
                let myResponse = Self.mapResponse(event.responseStatus?.response)
                let counts = Self.responseCounts(from: event.attendees)
                return MeetingEvent(
                    id: event.id,
                    title: title,
                    startDate: startDate,
                    endDate: endDate,
                    calendarName: "Outlook",
                    location: event.location?.displayName,
                    isAllDay: event.isAllDay,
                    url: joinURL,
                    notes: notes,
                    attendeeNames: Array(attendeeNames.prefix(10)),
                    attendeeCount: attendeeNames.count,
                    organizerName: event.organizer?.emailAddress?.name,
                    isCancelled: cancelled,
                    isRecurring: event.type != nil && event.type != "singleInstance",
                    myResponse: myResponse,
                    responseCounts: counts
                )
            }
            .sorted { $0.startDate < $1.startDate }
    }

    func availableCalendars() async throws -> [CalendarInfo] {
        let token = try await validToken()

        let url = URL(string: "https://graph.microsoft.com/v1.0/me/calendars?$select=id,name,color")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(GraphCalendarsResponse.self, from: data)

        return decoded.value.map { cal in
            CalendarInfo(
                id: cal.id,
                name: cal.name,
                color: graphColorToHex(cal.color),
                source: "Microsoft 365"
            ,
                providerType: .microsoftGraph)
        }
    }

    // MARK: - Sign Out

    func signOut() {
        accessToken = nil
        tokenExpiration = nil
        refreshToken = nil
        grantedScope = ""
        accountLabel = nil
    }

    // MARK: - Which account is connected

    /// Cached "Name (email)" for the signed-in account. Persisted so Settings can say
    /// *who* is connected the moment it opens, with no network round trip — "Signed In"
    /// on its own doesn't tell you whether you're on your work or personal account,
    /// which is the only thing you actually want to know when two are in play.
    private(set) var accountLabel: String? {
        get { UserDefaults.standard.string(forKey: "graphAccountLabel") }
        set {
            if let value = newValue { UserDefaults.standard.set(value, forKey: "graphAccountLabel") }
            else { UserDefaults.standard.removeObject(forKey: "graphAccountLabel") }
        }
    }

    /// Ask Graph who we're signed in as. Uses `User.Read`, which sign-in already
    /// requests. Best-effort: a failure leaves the previous label rather than blanking
    /// a perfectly good sign-in over a transient network error.
    @discardableResult
    func refreshAccountLabel() async -> String? {
        guard isAuthorized else { return nil }
        do {
            let token = try await validToken()
            var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me?$select=displayName,mail,userPrincipalName")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                await log("warn", "Graph /me returned HTTP \(status) — can't show which account is signed in")
                return accountLabel
            }
            struct Me: Decodable {
                let displayName: String?
                let mail: String?
                let userPrincipalName: String?
            }
            let me = try JSONDecoder().decode(Me.self, from: data)
            let address = me.mail ?? me.userPrincipalName
            let label: String?
            switch (me.displayName, address) {
            case let (name?, addr?): label = "\(name) (\(addr))"
            case let (name?, nil):   label = name
            case let (nil, addr?):   label = addr
            default:                 label = nil
            }
            if let label { accountLabel = label }
            return accountLabel
        } catch {
            await log("warn", "Graph /me failed — \(error.localizedDescription)")
            return accountLabel
        }
    }

    // MARK: - RSVP write

    /// Respond to an invitation. Graph endpoints are POST /me/events/{id}/{accept|
    /// decline|tentativelyAccept}; they return 202 Accepted (not 200). `sendResponse`
    /// asks Graph to email the organizer, matching Calendar.app behavior.
    func respond(to eventID: String, status: ResponseStatus) async throws {
        let action: String
        switch status {
        case .accepted:  action = "accept"
        case .declined:  action = "decline"
        case .tentative: action = "tentativelyAccept"
        default: throw CalendarProviderError.notSupported   // organizer/unknown/noResponse aren't responses you can send
        }
        guard supportsResponding else { throw CalendarProviderError.notSupported }

        let token = try await validToken()
        let url = URL(string: "https://graph.microsoft.com/v1.0/me/events/\(eventID)/\(action)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["sendResponse": true])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CalendarProviderError.networkError(underlying: URLError(.badServerResponse))
        }
        switch http.statusCode {
        case 200, 202, 204:
            return
        case 401:
            self.accessToken = nil
            throw CalendarProviderError.notAuthenticated
        case 403:
            // Token lacks write scope — force re-auth for write.
            grantedScope = ""
            throw CalendarProviderError.notSupported
        default:
            throw CalendarProviderError.networkError(underlying: URLError(.init(rawValue: http.statusCode)))
        }
    }

    // MARK: - Device Code Flow

    private struct TokenResult {
        let accessToken: String
        let expiration: Date
        let refreshToken: String?
        let scope: String?
    }

    private func performDeviceCodeAuth() async throws -> TokenResult {
        let tenantId = "common" // Multi-tenant
        let url = URL(string: "https://login.microsoftonline.com/\(tenantId)/oauth2/v2.0/devicecode")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "client_id=\(clientId)&scope=\(Self.oauthScope)"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let deviceCode = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)

        // Open the verification URL in the browser for the user
        if let verificationUrl = URL(string: deviceCode.verificationUri) {
            await MainActor.run { _ =
                NSWorkspace.shared.open(verificationUrl)
            }
        }

        // Post a notification so the UI can show the user code
        await MainActor.run {
            NotificationCenter.default.post(
                name: .graphDeviceCodeReceived,
                object: nil,
                userInfo: ["userCode": deviceCode.userCode, "message": deviceCode.message]
            )
        }

        // Poll for token
        return try await pollForToken(deviceCode: deviceCode)
    }

    private func pollForToken(deviceCode: DeviceCodeResponse) async throws -> TokenResult {
        let tenantId = "common"
        let tokenUrl = URL(string: "https://login.microsoftonline.com/\(tenantId)/oauth2/v2.0/token")!

        let pollInterval = TimeInterval(deviceCode.interval)
        let expiresAt = Date().addingTimeInterval(TimeInterval(deviceCode.expiresIn))

        while Date() < expiresAt {
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))

            var request = URLRequest(url: tokenUrl)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let body = "grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id=\(clientId)&device_code=\(deviceCode.deviceCode)"
            request.httpBody = body.data(using: .utf8)

            let (data, _) = try await URLSession.shared.data(for: request)

            if let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data) {
                return TokenResult(
                    accessToken: tokenResponse.accessToken,
                    expiration: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
                    refreshToken: tokenResponse.refreshToken,
                    scope: tokenResponse.scope
                )
            }

            // If we get an error that's not "authorization_pending", throw
            if let errorResponse = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data) {
                if errorResponse.error != "authorization_pending" {
                    throw CalendarProviderError.notAuthenticated
                }
            }
        }

        throw CalendarProviderError.notAuthenticated
    }

    // MARK: - Date Parsing

    private func parseGraphDate(_ graphDate: GraphDateTime?) -> Date? {
        guard let dateStr = graphDate?.dateTime else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateStr) { return date }
        // Fallback without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateStr)
    }

    /// Converts a Graph `itemBody` payload into plain text. HTML bodies are stripped
    /// of tags via `NSAttributedString`; plaintext bodies pass through trimmed.
    fileprivate static func plainText(from body: GraphBody) -> String? {
        guard let content = body.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else { return nil }
        if body.contentType?.lowercased() == "html" {
            guard let data = content.data(using: .utf8) else { return content }
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]
            if let attr = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
                let stripped = attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
                return stripped.isEmpty ? nil : stripped
            }
            return content
        }
        return content
    }

    /// Map a Graph `responseStatus.response` string to our unified enum.
    fileprivate static func mapResponse(_ response: String?) -> ResponseStatus {
        switch response?.lowercased() {
        case "accepted":            return .accepted
        case "declined":            return .declined
        case "tentativelyaccepted": return .tentative
        case "notresponded":        return .noResponse
        case "organizer":           return .organizer
        default:                    return .unknown   // "none" or absent
        }
    }

    /// Tally attendee responses for the details-panel summary; nil when no attendees.
    fileprivate static func responseCounts(from attendees: [GraphAttendee]?) -> ResponseCounts? {
        guard let attendees, !attendees.isEmpty else { return nil }
        var c = ResponseCounts()
        for a in attendees {
            switch mapResponse(a.status?.response) {
            case .accepted:   c.accepted += 1
            case .declined:   c.declined += 1
            case .tentative:  c.tentative += 1
            case .noResponse: c.noResponse += 1
            default:          break
            }
        }
        return c
    }

    private func graphColorToHex(_ color: String?) -> String {
        let colorMap: [String: String] = [
            "auto": "#007AFF", "lightBlue": "#5AC8FA", "lightGreen": "#34C759",
            "lightOrange": "#FF9500", "lightGray": "#8E8E93", "lightYellow": "#FFCC00",
            "lightTeal": "#5AC8FA", "lightPink": "#FF2D55", "lightBrown": "#A2845E",
            "lightRed": "#FF3B30", "maxColor": "#AF52DE"
        ]
        return colorMap[color ?? "auto"] ?? "#007AFF"
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let graphDeviceCodeReceived = Notification.Name("graphDeviceCodeReceived")
}

// MARK: - Graph API Response Models

struct GraphCalendarResponse: Codable {
    let value: [GraphEvent]
}

struct GraphEvent: Codable {
    let id: String
    let subject: String?
    let start: GraphDateTime?
    let end: GraphDateTime?
    let location: GraphLocation?
    let isAllDay: Bool
    let body: GraphBody?
    let attendees: [GraphAttendee]?
    let onlineMeeting: GraphOnlineMeeting?
    let isOnlineMeeting: Bool?
    let organizer: GraphRecipient?
    let isCancelled: Bool?
    let responseStatus: GraphResponseStatus?
    /// `singleInstance` | `occurrence` | `exception` | `seriesMaster` — used to flag
    /// recurring events so time-change detection can skip them.
    let type: String?
}

struct GraphBody: Codable {
    let contentType: String?
    let content: String?
}

struct GraphAttendee: Codable {
    let emailAddress: GraphEmailAddress?
    let type: String?
    let status: GraphResponseStatus?
}

/// Graph `responseStatus` — `response` is one of: none, organizer, tentativelyAccepted,
/// accepted, declined, notResponded. Used both for the event (my response) and per
/// attendee (their response).
struct GraphResponseStatus: Codable {
    let response: String?
    let time: String?
}

struct GraphRecipient: Codable {
    let emailAddress: GraphEmailAddress?
}

struct GraphEmailAddress: Codable {
    let name: String?
    let address: String?
}

struct GraphOnlineMeeting: Codable {
    let joinUrl: String?
}

struct GraphDateTime: Codable {
    let dateTime: String
    let timeZone: String?
}

struct GraphLocation: Codable {
    let displayName: String?
}

struct GraphCalendarsResponse: Codable {
    let value: [GraphCalendarItem]
}

struct GraphCalendarItem: Codable {
    let id: String
    let name: String
    let color: String?
}

struct DeviceCodeResponse: Codable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let expiresIn: Int
    let interval: Int
    let message: String

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case expiresIn = "expires_in"
        case interval
        case message
    }
}

struct TokenResponse: Codable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

struct OAuthErrorResponse: Codable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}
