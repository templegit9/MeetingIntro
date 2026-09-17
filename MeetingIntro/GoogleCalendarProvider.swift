import Foundation

/// Google Calendar via the REST API v3.
///
/// **Why this exists at all, given EventKit already reads Google:** it doesn't add
/// coverage, it adds *capability*. A Google invitation read through macOS Calendar can
/// never be answered — Apple exposes no participant-status API — so every Gmail
/// invitation was awareness-only. Google's API can PATCH your own `responseStatus`, and
/// can answer free/busy for **other people**, which is the one thing that would let a
/// proposed time stop being a guess about everyone but you.
///
/// Sits alongside EventKit rather than replacing it: a user who has their Google account
/// in macOS Calendar keeps every per-event state keyed to the EventKit id (armed
/// auto-joins, dismissed reminders), and the merge in `CalendarManager` hands the
/// surviving copy this provider's id for replies — the same trick the Graph twin uses.
@MainActor
final class GoogleCalendarProvider: ObservableObject, CalendarProvider {

    /// **The app ships its own OAuth client, exactly as it does for Microsoft 365.**
    ///
    /// A client ID is not a secret: a native app has no client secret, PKCE is what stops
    /// an intercepted code being redeemed elsewhere, and every desktop tool that does this
    /// ships one (the gcloud CLI and VS Code both do). Bundling it is the whole difference
    /// between "Sign in with Google" and "go create a Google Cloud project", which nobody
    /// does — the same reasoning that put `GraphCalendarProvider.defaultClientID` in the
    /// app, and the user's standing rule that the app should never hand someone homework
    /// it could do itself.
    ///
    /// **What bundling does NOT change** — worth knowing before raising the limits:
    /// every sign-in runs against *this* Google Cloud project, so its quota and its
    /// unverified-app user cap are shared by everyone, and while the project sits in
    /// *Testing* publishing status Google expires refresh tokens after 7 days, which
    /// reaches users as a weekly silent sign-out. Those are properties of the project,
    /// not of the app, and are fixed in the Google console rather than here.
    static let defaultClientID = "501318872780-5amv9qgi8o61svla5lqb36bthrs4mrcf.apps.googleusercontent.com"

    /// Where someone would create their own client, if they'd rather not use ours.
    static let setupURL = "https://console.cloud.google.com/apis/credentials/oauthclient"

    private static let base = "https://www.googleapis.com/calendar/v3"

    @Published var lastError: String?
    /// Non-fatal trouble worth a log line — wired to `DiagnosticLog` by `CalendarManager`.
    var onDiagnostic: ((String) -> Void)?

    private let auth = GoogleCalendarAuth()

    /// Which calendar each event was read from.
    ///
    /// Google's event endpoints are **per calendar** — `events/{id}` on the wrong
    /// calendar is a 404, not a redirect — and `MeetingEvent` carries a calendar *name*,
    /// not an id. Without this, replying to anything outside the primary calendar
    /// (every shared team calendar) would fail with an error about the event not
    /// existing, which is both wrong and unactionable.
    private var calendarIDByEvent: [String: String] = [:]

    // MARK: - Stored credentials

    /// Client ID is configuration, not a credential, so UserDefaults. Tokens are in the
    /// Keychain, same split as Graph.
    /// The bundled client unless the user has set a valid override.
    ///
    /// An implausible override **falls back to the bundled one** rather than failing the
    /// sign-in, mirroring `GraphCalendarProvider`: v2.20.1 shipped a non-GUID in that
    /// constant and every sign-in died with an error naming a tenant that didn't exist.
    /// A typo in a field should not be able to break the feature silently.
    var clientID: String {
        let override = UserDefaults.standard.string(forKey: "googleClientID") ?? ""
        return GoogleCalendarAuth.isPlausibleClientID(override) ? override : Self.defaultClientID
    }

    /// True when a user-supplied client ID is present but unusable — Settings says so
    /// rather than letting it look as though the override took effect.
    var hasUnusableClientIDOverride: Bool {
        let override = UserDefaults.standard.string(forKey: "googleClientID") ?? ""
        return !override.isEmpty && !GoogleCalendarAuth.isPlausibleClientID(override)
    }
    private var accessToken: String? {
        get { KeychainStore.get("googleAccessToken") }
        set { newValue.map { _ = KeychainStore.set($0, for: "googleAccessToken") } ?? { _ = KeychainStore.delete("googleAccessToken") }() }
    }
    private var refreshToken: String? {
        get { KeychainStore.get("googleRefreshToken") }
        set { newValue.map { _ = KeychainStore.set($0, for: "googleRefreshToken") } ?? { _ = KeychainStore.delete("googleRefreshToken") }() }
    }
    private var expiresAt: Date {
        get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "googleTokenExpiry")) }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "googleTokenExpiry") }
    }
    /// Calendars the user ticked. Empty = the primary calendar only.
    var selectedCalendarIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "googleSelectedCalendarIDs") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "googleSelectedCalendarIDs") }
    }
    private(set) var accountEmail: String? {
        get { UserDefaults.standard.string(forKey: "googleAccountEmail") }
        set { UserDefaults.standard.set(newValue, forKey: "googleAccountEmail") }
    }

    // MARK: - CalendarProvider

    var providerType: CalendarProviderType { .googleCalendar }
    var isAuthorized: Bool { refreshToken != nil || (accessToken != nil && expiresAt > Date()) }
    /// Opens a browser, so a poll must never trigger it — see the v2.20.3 sign-in ambush.
    var requiresInteractiveSignIn: Bool { true }
    var canCreateEvents: Bool { true }
    var supportsResponding: Bool { isAuthorized }

    func requestAccess() async throws -> Bool {
        let tokens = try await auth.signIn(clientID: clientID)
        accessToken = tokens.accessToken
        if let refresh = tokens.refreshToken { refreshToken = refresh }
        expiresAt = tokens.expiresAt
        lastError = nil
        await refreshAccountEmail()
        return true
    }

    func signOut() {
        accessToken = nil
        refreshToken = nil
        accountEmail = nil
        selectedCalendarIDs = []
        expiresAt = .distantPast
    }

    /// A valid access token, refreshed transparently. Every call goes through this — a
    /// provider that only checks at sign-in dies an hour later.
    private func validToken() async throws -> String {
        if let token = accessToken, expiresAt > Date() { return token }
        guard let refresh = refreshToken else { throw CalendarProviderError.notAuthenticated }
        let tokens = try await auth.refresh(refreshToken: refresh, clientID: clientID)
        accessToken = tokens.accessToken
        expiresAt = tokens.expiresAt
        return tokens.accessToken
    }

    func availableCalendars() async throws -> [CalendarInfo] {
        let items: [GoogleCalendarListEntry] = try await get("/users/me/calendarList", as: GoogleCalendarList.self).items ?? []
        return items.map {
            CalendarInfo(id: $0.id, name: $0.summary ?? $0.id,
                         color: $0.backgroundColor ?? "#4285F4",
                         source: "Google", providerType: .googleCalendar)
        }
    }

    /// Reads every ticked calendar, falling back to `primary`.
    ///
    /// **One unreadable calendar never takes the account down** — the same rule Graph
    /// learned the hard way: a per-calendar failure is collected and the rest still load,
    /// because a shared calendar that was revoked must not empty your whole day.
    func fetchUpcomingEvents(within interval: TimeInterval) async throws -> [MeetingEvent] {
        let ids = selectedCalendarIDs.isEmpty ? ["primary"] : Array(selectedCalendarIDs)
        let formatter = ISO8601DateFormatter()
        let timeMin = formatter.string(from: Date())
        let timeMax = formatter.string(from: Date().addingTimeInterval(interval))

        var all: [MeetingEvent] = []
        var seen = Set<String>()
        var failures: [String] = []

        for id in ids {
            let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
            let path = "/calendars/\(escaped)/events"
                + "?timeMin=\(timeMin)&timeMax=\(timeMax)"
                + "&singleEvents=true&orderBy=startTime&maxResults=250"
            do {
                let page = try await get(path, as: GoogleEventList.self)
                for raw in page.items ?? [] {
                    guard let event = Self.map(raw, accountEmail: accountEmail) else { continue }
                    if seen.insert(event.id).inserted {
                        all.append(event)
                        calendarIDByEvent[event.id] = id
                    }
                }
            } catch {
                failures.append("\(id): \(error.localizedDescription)")
                onDiagnostic?("Google calendar \(id) failed — \(error.localizedDescription); other calendars still read")
            }
        }

        // Every selected calendar failing is a real failure; some failing is not.
        if all.isEmpty, failures.count == ids.count, !failures.isEmpty {
            throw CalendarProviderError.unknown(underlying: NSError(
                domain: "MeetingIntro.Google", code: 1,
                userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]))
        }
        return all.sorted { $0.startDate < $1.startDate }
    }

    // MARK: - RSVP

    /// Google has no dedicated accept/decline endpoint: you PATCH the event with the
    /// attendee list, changing your own entry.
    ///
    /// **The whole list must be sent.** A PATCH carrying only your attendee would drop
    /// everyone else from the meeting — so we read the event first and modify one entry.
    /// That read is not optional and must not be "optimised" away.
    func respond(to eventID: String, status: ResponseStatus) async throws {
        let googleStatus: String
        switch status {
        case .accepted:  googleStatus = "accepted"
        case .declined:  googleStatus = "declined"
        case .tentative: googleStatus = "tentative"
        default: throw CalendarProviderError.notSupported
        }

        // The calendar this event actually lives in, remembered at fetch time.
        let calendarID = calendarIDByEvent[eventID] ?? "primary"
        let escapedCalendar = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
        let escapedEvent = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventID
        let event = try await get("/calendars/\(escapedCalendar)/events/\(escapedEvent)", as: GoogleEvent.self)

        guard var attendees = event.attendees, !attendees.isEmpty else {
            throw CalendarProviderError.notSupported
        }
        guard let mine = attendees.firstIndex(where: { $0.this_is_me }) else {
            // No attendee is flagged as us — patching a guessed entry could answer on
            // someone else's behalf, which is not a risk worth taking to save a click.
            throw CalendarProviderError.notSupported
        }
        attendees[mine].responseStatus = googleStatus

        let body: [String: Any] = ["attendees": attendees.map { $0.asDictionary }]
        try await patch("/calendars/\(escapedCalendar)/events/\(escapedEvent)?sendUpdates=all", body: body)
    }

    /// Google Calendar has **no counter-proposal concept** — there is no API, and no UI
    /// in Google Calendar itself. Declining with a suggested time is a message, not a
    /// calendar operation. Saying so plainly beats sending a decline that quietly drops
    /// the time the user chose.
    func propose(_ status: ResponseStatus, to eventID: String, start: Date, end: Date) async throws {
        throw CalendarProviderError.notSupported
    }

    // MARK: - Writing

    func createEvent(from draft: EventDraft, calendarID: String?) async throws {
        let formatter = ISO8601DateFormatter()
        var body: [String: Any] = ["summary": draft.title]
        if draft.isAllDay {
            let cal = Calendar.current
            let startDay = cal.startOfDay(for: draft.startDate)
            // Google treats an all-day `end` as exclusive, same as Graph.
            let endDay = max(cal.startOfDay(for: draft.endDate), cal.date(byAdding: .day, value: 1, to: startDay)!)
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "yyyy-MM-dd"
            dayFormatter.locale = Locale(identifier: "en_US_POSIX")
            body["start"] = ["date": dayFormatter.string(from: startDay)]
            body["end"] = ["date": dayFormatter.string(from: endDay)]
        } else {
            body["start"] = ["dateTime": formatter.string(from: draft.startDate)]
            body["end"] = ["dateTime": formatter.string(from: draft.endDate)]
        }
        if let location = draft.location, !location.isEmpty { body["location"] = location }
        var notes = draft.notes ?? ""
        if let url = draft.url, !url.isEmpty { notes = notes.isEmpty ? url : "\(notes)\n\n\(url)" }
        if !notes.isEmpty { body["description"] = notes }
        if !draft.attendees.isEmpty { body["attendees"] = draft.attendees.map { ["email": $0] } }

        let id = calendarID ?? "primary"
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        try await post("/calendars/\(escaped)/events?sendUpdates=all", body: body)
    }

    // MARK: - Free/busy

    /// When other people are busy — the thing no other source here can answer.
    ///
    /// Returns the intervals Google will admit to; an address it can't see (outside the
    /// organization, or with calendar sharing off) simply contributes nothing. **Absence
    /// of busy time is therefore not evidence of free time**, and any caller presenting
    /// this to a user has to say whose calendars were actually readable.
    func busyIntervals(for emails: [String], from start: Date, to end: Date) async throws -> [String: [DateInterval]] {
        guard !emails.isEmpty else { return [:] }
        let formatter = ISO8601DateFormatter()
        let body: [String: Any] = [
            "timeMin": formatter.string(from: start),
            "timeMax": formatter.string(from: end),
            "items": emails.map { ["id": $0] }
        ]
        let response = try await post("/freeBusy", body: body, as: GoogleFreeBusyResponse.self)
        var result: [String: [DateInterval]] = [:]
        for (email, entry) in response.calendars ?? [:] {
            // An entry with errors is "we couldn't look", not "they're free".
            guard entry.errors == nil else { continue }
            let intervals: [DateInterval] = (entry.busy ?? []).compactMap {
                guard let s = formatter.date(from: $0.start), let e = formatter.date(from: $0.end) else { return nil }
                return DateInterval(start: s, end: e)
            }
            result[email] = intervals
        }
        return result
    }

    // MARK: - Account

    private func refreshAccountEmail() async {
        struct Profile: Decodable { let email: String? }
        guard let token = try? await validToken(),
              let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let (data, _) = try? await URLSession.shared.data(for: request),
           let profile = try? JSONDecoder().decode(Profile.self, from: data) {
            accountEmail = profile.email
        }
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let token = try await validToken()
        var request = URLRequest(url: URL(string: Self.base + path)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await send(request, as: type)
    }

    @discardableResult
    private func post<T: Decodable>(_ path: String, body: [String: Any], as type: T.Type) async throws -> T {
        var request = URLRequest(url: URL(string: Self.base + path)!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await authorized(request, as: type)
    }

    private func post(_ path: String, body: [String: Any]) async throws {
        _ = try await post(path, body: body, as: GoogleEmptyResponse.self)
    }

    private func patch(_ path: String, body: [String: Any]) async throws {
        var request = URLRequest(url: URL(string: Self.base + path)!)
        request.httpMethod = "PATCH"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await authorized(request, as: GoogleEmptyResponse.self)
    }

    private func authorized<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        var request = request
        let token = try await validToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, as: type)
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            onDiagnostic?("Google API \(code) on \(request.url?.path ?? "?"): \(body.prefix(300))")
            if code == 401 {
                accessToken = nil
                throw CalendarProviderError.notAuthenticated
            }
            throw CalendarProviderError.networkError(underlying: URLError(.badServerResponse))
        }
        if T.self == GoogleEmptyResponse.self { return GoogleEmptyResponse() as! T }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Mapping

    /// Google → `MeetingEvent`. Returns nil for anything without a usable start, so a
    /// malformed row is dropped rather than landing at 1970.
    static func map(_ raw: GoogleEvent, accountEmail: String?) -> MeetingEvent? {
        guard let id = raw.id else { return nil }
        let isAllDay = raw.start?.date != nil
        guard let start = parse(raw.start), let end = parse(raw.end) ?? parse(raw.start) else { return nil }

        let attendees = raw.attendees ?? []
        let mine = attendees.first { $0.this_is_me }
        let myResponse: ResponseStatus
        if raw.organizer?.this_is_me == true {
            myResponse = .organizer
        } else if let mine {
            switch mine.responseStatus {
            case "accepted":    myResponse = .accepted
            case "declined":    myResponse = .declined
            case "tentative":   myResponse = .tentative
            case "needsAction": myResponse = .noResponse
            default:            myResponse = .unknown
            }
        } else {
            // Attendees exist but none is flagged as us (multi-account aliases), or
            // there are no attendees at all. Either way we can't claim a response —
            // `.unknown` keeps the response gate from silencing the meeting.
            myResponse = .unknown
        }

        var counts = ResponseCounts()
        for a in attendees {
            switch a.responseStatus {
            case "accepted":    counts.accepted += 1
            case "declined":    counts.declined += 1
            case "tentative":   counts.tentative += 1
            case "needsAction": counts.noResponse += 1
            default: break
            }
        }

        let notes = raw.description
        // hangoutLink is the structured Meet link; anything else is found the same way
        // every other provider's link is found, so an odd conferencing tool still works.
        let joinURL = raw.hangoutLink.flatMap(URL.init(string:))
            ?? ConferenceLinkExtractor.bestURL(eventURL: nil, notes: notes, location: raw.location, graphOnlineMeetingURL: nil)

        let title = raw.summary ?? "Untitled Meeting"
        return MeetingEvent(
            id: id,
            title: title,
            startDate: start,
            endDate: end,
            calendarName: "Google",
            location: raw.location,
            isAllDay: isAllDay,
            url: joinURL,
            notes: notes,
            attendeeNames: attendees.prefix(10).compactMap { $0.displayName ?? $0.email },
            attendeeCount: attendees.count,
            organizerName: raw.organizer?.displayName ?? raw.organizer?.email,
            isCancelled: raw.status == "cancelled" || CancellationTitlePrefix.matches(title),
            isRecurring: raw.recurringEventId != nil,
            sourceProvider: .googleCalendar,
            myResponse: myResponse,
            responseCounts: attendees.isEmpty ? nil : counts,
            // Google has no counter-proposal concept at all — see `propose`.
            allowsNewTimeProposals: false
        )
    }

    /// Timed events carry RFC3339 with an offset; all-day events carry `date` only.
    private static func parse(_ value: GoogleEventDate?) -> Date? {
        guard let value else { return nil }
        if let dateTime = value.dateTime {
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = withFraction.date(from: dateTime) { return parsed }
            return ISO8601DateFormatter().date(from: dateTime)
        }
        if let day = value.date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            return formatter.date(from: day)
        }
        return nil
    }
}

// MARK: - Wire types

struct GoogleEmptyResponse: Decodable {}

struct GoogleCalendarList: Decodable { let items: [GoogleCalendarListEntry]? }
struct GoogleCalendarListEntry: Decodable {
    let id: String
    let summary: String?
    let backgroundColor: String?
}

struct GoogleEventList: Decodable { let items: [GoogleEvent]? }

struct GoogleEvent: Decodable {
    let id: String?
    let summary: String?
    let description: String?
    let location: String?
    let status: String?
    let hangoutLink: String?
    let recurringEventId: String?
    let start: GoogleEventDate?
    let end: GoogleEventDate?
    let organizer: GoogleAttendee?
    let attendees: [GoogleAttendee]?
}

struct GoogleEventDate: Decodable {
    let dateTime: String?
    let date: String?
}

/// `self` is a Swift keyword, so the JSON key is mapped to `this_is_me`.
struct GoogleAttendee: Decodable {
    var email: String?
    var displayName: String?
    var responseStatus: String?
    var optional: Bool?
    var organizer: Bool?
    var this_is_me: Bool = false

    enum CodingKeys: String, CodingKey {
        case email, displayName, responseStatus, optional, organizer
        case this_is_me = "self"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        responseStatus = try c.decodeIfPresent(String.self, forKey: .responseStatus)
        optional = try c.decodeIfPresent(Bool.self, forKey: .optional)
        organizer = try c.decodeIfPresent(Bool.self, forKey: .organizer)
        this_is_me = (try? c.decodeIfPresent(Bool.self, forKey: .this_is_me)) as? Bool ?? false
    }

    /// Only the fields Google accepts back on a PATCH. Sending unknown or read-only keys
    /// makes the whole write fail.
    var asDictionary: [String: Any] {
        var dict: [String: Any] = [:]
        if let email { dict["email"] = email }
        if let responseStatus { dict["responseStatus"] = responseStatus }
        if let optional { dict["optional"] = optional }
        if let organizer { dict["organizer"] = organizer }
        if this_is_me { dict["self"] = true }
        return dict
    }
}

struct GoogleFreeBusyResponse: Decodable {
    let calendars: [String: GoogleFreeBusyCalendar]?
}
struct GoogleFreeBusyCalendar: Decodable {
    let busy: [GoogleFreeBusyInterval]?
    let errors: [GoogleFreeBusyError]?
}
struct GoogleFreeBusyInterval: Decodable { let start: String; let end: String }
struct GoogleFreeBusyError: Decodable { let domain: String?; let reason: String? }
