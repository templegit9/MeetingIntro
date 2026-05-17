import AppKit
import Foundation

/// Calendar provider implementation using Microsoft Graph REST API.
/// Requires an Azure App Registration with `Calendars.Read` permission.
final class GraphCalendarProvider: CalendarProvider {

    let providerType: CalendarProviderType = .microsoftGraph

    /// The Azure AD Application (client) ID, set by the user in Settings.
    var clientId: String {
        get { UserDefaults.standard.string(forKey: "graphClientId") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "graphClientId") }
    }

    /// Cached OAuth2 access token.
    private var accessToken: String? {
        get { UserDefaults.standard.string(forKey: "graphAccessToken") }
        set { UserDefaults.standard.set(newValue, forKey: "graphAccessToken") }
    }

    /// Token expiration date.
    private var tokenExpiration: Date? {
        get { UserDefaults.standard.object(forKey: "graphTokenExpiration") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "graphTokenExpiration") }
    }

    /// Set of calendar IDs the user has chosen to monitor (empty = all).
    var selectedCalendarIDs: Set<String> = []

    var isAuthorized: Bool {
        guard let token = accessToken, !token.isEmpty,
              let expiration = tokenExpiration else { return false }
        return expiration > Date()
    }

    // MARK: - CalendarProvider

    func requestAccess() async throws -> Bool {
        guard !clientId.isEmpty else {
            throw CalendarProviderError.notAuthenticated
        }

        // Use Device Code Flow for macOS CLI / menu bar apps
        // This avoids the need for a web view redirect URI
        let token = try await performDeviceCodeAuth()
        self.accessToken = token.accessToken
        self.tokenExpiration = token.expiration
        return true
    }

    func fetchUpcomingEvents(within interval: TimeInterval) async throws -> [MeetingEvent] {
        guard isAuthorized else {
            throw CalendarProviderError.notAuthenticated
        }

        let now = Date()
        let endDate = now.addingTimeInterval(interval)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let startStr = formatter.string(from: now)
        let endStr = formatter.string(from: endDate)

        let urlString = "https://graph.microsoft.com/v1.0/me/calendarview?startdatetime=\(startStr)&enddatetime=\(endStr)&$select=id,subject,start,end,location,isAllDay,organizer&$orderby=start/dateTime"

        guard let url = URL(string: urlString) else {
            throw CalendarProviderError.unknown(underlying: URLError(.badURL))
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken ?? "")", forHTTPHeaderField: "Authorization")
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

                return MeetingEvent(
                    id: event.id,
                    title: event.subject ?? "Untitled Meeting",
                    startDate: startDate,
                    endDate: endDate,
                    calendarName: "Outlook",
                    location: event.location?.displayName,
                    isAllDay: event.isAllDay
                )
            }
            .sorted { $0.startDate < $1.startDate }
    }

    func availableCalendars() async throws -> [CalendarInfo] {
        guard isAuthorized else {
            throw CalendarProviderError.notAuthenticated
        }

        let url = URL(string: "https://graph.microsoft.com/v1.0/me/calendars?$select=id,name,color")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken ?? "")", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(GraphCalendarsResponse.self, from: data)

        return decoded.value.map { cal in
            CalendarInfo(
                id: cal.id,
                name: cal.name,
                color: graphColorToHex(cal.color),
                source: "Microsoft 365"
            )
        }
    }

    // MARK: - Sign Out

    func signOut() {
        accessToken = nil
        tokenExpiration = nil
    }

    // MARK: - Device Code Flow

    private struct TokenResult {
        let accessToken: String
        let expiration: Date
    }

    private func performDeviceCodeAuth() async throws -> TokenResult {
        let tenantId = "common" // Multi-tenant
        let url = URL(string: "https://login.microsoftonline.com/\(tenantId)/oauth2/v2.0/devicecode")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "client_id=\(clientId)&scope=https://graph.microsoft.com/Calendars.Read offline_access"
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
                    expiration: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
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

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
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
