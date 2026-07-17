import Combine
import Foundation

// MARK: - On-device parser

/// `NSDataDetector`-based parser. Finds the first date (and optional duration) in the
/// text; the title is whatever remains after removing the matched date phrase.
/// Free, offline, instant — the floor the LLM parser falls back to.
enum DetectorParser {

    static func parse(_ text: String, defaultDurationMinutes: Int) -> EventDraft? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = detector.firstMatch(in: trimmed, options: [], range: range),
              let start = match.date else { return nil }

        // NSDataDetector reports an explicit duration for ranges like "2-3:30pm".
        let end: Date
        if match.duration > 0 {
            end = start.addingTimeInterval(match.duration)
        } else {
            end = start.addingTimeInterval(TimeInterval(defaultDurationMinutes * 60))
        }

        // Detect a date-only phrase ("friday June 5th" with no clock time) — the
        // detector fills in a default time silently; we surface that as an
        // assumption so the preview can warn instead of quietly guessing.
        var assumptions: [String] = []
        if let matchRange = Range(match.range, in: trimmed) {
            let matchedText = String(trimmed[matchRange])
            let hasExplicitTime = matchedText.range(
                of: #"\d{1,2}:\d{2}|\d{1,2}\s*(am|pm|AM|PM)|noon|midnight"#,
                options: .regularExpression
            ) != nil
            if !hasExplicitTime {
                let tf = DateFormatter()
                tf.timeStyle = .short
                assumptions.append("No start time given — assumed \(tf.string(from: start))")
            }
        }

        // Title = text minus the date phrase, tidied up.
        var title = trimmed
        if let swiftRange = Range(match.range, in: trimmed) {
            title.removeSubrange(swiftRange)
        }
        title = title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.-—@"))
        if title.isEmpty { title = "New Event" }

        return EventDraft(
            title: title,
            startDate: start,
            endDate: end,
            location: nil,
            notes: nil,
            parserUsed: .detector,
            assumptions: assumptions
        )
    }
}

// MARK: - OpenRouter LLM parser

/// Parses via any OpenAI-compatible chat model on OpenRouter. Strict-JSON prompt;
/// current local time + timezone injected so relative dates resolve correctly.
/// Throws on any failure — the service falls back to `DetectorParser`.
enum OpenRouterParser {

    struct ParseFailure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static func parse(_ text: String, key: String, model: String, baseURL: String = QuickAddConfig.defaultBaseURL) async throws -> EventDraft {
        let now = ISO8601DateFormatter().string(from: Date())
        let tz = TimeZone.current.identifier

        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let endpoint = URL(string: trimmedBase + "/chat/completions"), endpoint.scheme != nil else {
            throw ParseFailure(reason: "Invalid API base URL: \(baseURL)")
        }

        let systemPrompt = """
        You convert natural-language text into a calendar event. Reply with ONLY a JSON object, no prose, no code fences:
        {"title": string, "start_iso8601": string, "end_iso8601": string, "location": string or null, "notes": string or null, "assumptions": [string]}
        Rules: Current local time is \(now) in timezone \(tz) — resolve relative dates ("tomorrow", "next Tue") against it and output offsets in that timezone. If no end time or duration is given, set end_iso8601 to start + 30 minutes. Keep the title short; put extra instructions in notes. If the text contains no date or time at all, reply with exactly {"error": "no_date"}.
        IMPORTANT — assumptions: whenever a relevant detail is MISSING from the text and you have to guess it, add a short human-readable note to the assumptions array. Examples: a date but no clock time → "No start time given — assumed 9:00 AM"; a time but no date → "No date given — assumed today"; ambiguous duration → "Duration unclear — assumed 30 minutes". If nothing was assumed, return an empty array. Never silently invent details without listing them.
        """

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        if !key.isEmpty {
            // Local providers (Ollama) need no auth — only send the header when set.
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
            "temperature": 0,
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            let isTimeout = (error as? URLError)?.code == .timedOut
            throw ParseFailure(reason: isTimeout
                ? "Timed out after 6s — the model is too slow for live parsing (reasoning and free-tier models often are). Try a fast instruct model."
                : "Network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // OpenRouter puts a useful message in the error body — surface it.
            var detail = ""
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = root["error"] as? [String: Any],
               let msg = err["message"] as? String {
                detail = " — \(msg)"
            }
            let hint = code == 401 ? " (bad API key?)" : code == 429 ? " (rate-limited — free models throttle hard)" : code == 404 ? " (unknown model ID?)" : ""
            throw ParseFailure(reason: "HTTP \(code)\(hint)\(detail)")
        }

        // OpenAI-compatible shape: choices[0].message.content
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              var content = message["content"] as? String, !content.isEmpty else {
            throw ParseFailure(reason: "Model returned an empty or malformed response — reasoning models often put output outside message.content. Use an instruct model.")
        }

        // Defensive: strip code fences some models add despite instructions.
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasPrefix("```") {
            content = content
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let jsonData = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw ParseFailure(reason: "Model didn't return valid JSON — it replied with prose or reasoning text instead. Use an instruct model.")
        }
        if obj["error"] != nil { throw ParseFailure(reason: "Model found no date or time in the text.") }

        let iso = ISO8601DateFormatter()
        guard let title = obj["title"] as? String,
              let startStr = obj["start_iso8601"] as? String,
              let endStr = obj["end_iso8601"] as? String,
              let start = iso.date(from: startStr),
              let end = iso.date(from: endStr),
              end > start else {
            throw ParseFailure(reason: "Model returned JSON but with missing or invalid date fields.")
        }

        return EventDraft(
            title: title,
            startDate: start,
            endDate: end,
            location: obj["location"] as? String,
            notes: obj["notes"] as? String,
            parserUsed: .llm(model: model),
            assumptions: (obj["assumptions"] as? [String]) ?? []
        )
    }
}

// MARK: - Service

/// Debounced parse-as-you-type orchestrator for the Quick Add panel.
/// LLM path when a key is configured (with detector fallback on any failure);
/// detector-only otherwise. In-flight LLM calls are cancelled when the text changes.
@MainActor
final class QuickAddService: ObservableObject {

    @Published var inputText: String = "" {
        didSet { scheduleParse() }
    }
    @Published private(set) var draft: EventDraft?
    @Published private(set) var isParsing: Bool = false
    /// Titles of existing meetings that overlap the current draft's time (Issue #10).
    /// Informational — surfaced in the preview as a warning; never blocks creation.
    @Published private(set) var conflicts: [String] = []

    /// Injected: returns the titles of existing events overlapping a `[start, end)`
    /// window. Wired to `CalendarManager.conflicts` where a manager is available.
    var conflictProvider: ((Date, Date) -> [String])?

    /// User's link choice from the preview controls. Changing it re-applies to the
    /// current draft without re-parsing (no network round-trip just to toggle a link).
    @Published var linkChoice: LinkChoice = .auto {
        didSet { if oldValue != linkChoice { reapplyLink() } }
    }

    /// User override for event-vs-task (Issue #19). nil = auto-detect from the text.
    /// Reset per new input so a per-entry override doesn't bleed.
    @Published var kindOverride: DraftKind? = nil {
        didSet { if oldValue != kindOverride { reapplyLink() } }
    }

    private let config: QuickAddConfig
    private var parseTask: Task<Void, Never>?
    /// The template matched on the current input, if any — its chosen link is the
    /// "auto" default for this draft (overriding the heuristic + global default).
    private var activeTemplate: QuickAddTemplate?
    /// The draft as produced by the parser, before link application — so toggling
    /// the link choice can re-derive from a clean base.
    private var baseDraft: EventDraft?

    init(config: QuickAddConfig) {
        self.config = config
    }

    /// Clear state when the panel opens/closes.
    func reset() {
        parseTask?.cancel()
        inputText = ""
        draft = nil
        baseDraft = nil
        activeTemplate = nil
        linkChoice = .auto
        isParsing = false
    }

    private func scheduleParse() {
        parseTask?.cancel()
        let text = inputText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            draft = nil
            baseDraft = nil
            activeTemplate = nil
            isParsing = false
            return
        }
        // A fresh input resets the link + kind overrides so a per-entry choice doesn't
        // bleed across different things typed into the same panel.
        linkChoice = .auto
        kindOverride = nil
        parseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Debounce: wait for a typing pause before parsing (and before any network call).
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }

            // Expand a /trigger template (if any) into the text we actually parse.
            let (parseText, template) = TemplateExpander.expand(text, templates: self.config.templates)
            self.activeTemplate = template
            let duration = template?.durationMinutes ?? self.config.defaultDurationMinutes

            // Instant on-device result first so the preview feels alive...
            if let detectorDraft = DetectorParser.parse(parseText, defaultDurationMinutes: duration) {
                self.publish(self.applyTemplate(template, to: detectorDraft))
            } else {
                self.publish(nil)
            }

            // ...then upgrade via the LLM when configured (key set, or a custom
            // base URL like a local Ollama that needs no key).
            guard self.config.llmEnabled else { return }
            self.isParsing = true
            defer { self.isParsing = false }
            do {
                let llmDraft = try await OpenRouterParser.parse(
                    parseText,
                    key: self.config.openRouterKey,
                    model: self.config.modelID,
                    baseURL: self.config.apiBaseURL
                )
                if !Task.isCancelled && self.inputText == text {
                    self.publish(self.applyTemplate(template, to: llmDraft))
                }
            } catch {
                // Keep the detector draft (or nil) — the LLM is an upgrade, never a gate.
            }
        }
    }

    /// Overlay a template's fixed fields (title, duration, location) onto a parsed
    /// draft. The typed text supplied date/time; the template supplies the rest.
    private func applyTemplate(_ template: QuickAddTemplate?, to draft: EventDraft) -> EventDraft {
        guard let template else { return draft }
        var d = draft
        d.title = template.title
        d.endDate = d.startDate.addingTimeInterval(TimeInterval(template.durationMinutes * 60))
        if let loc = template.location, !loc.isEmpty { d.location = loc }
        return d
    }

    /// Store the parser/template output as the base draft and apply the link choice.
    private func publish(_ draft: EventDraft?) {
        baseDraft = draft
        self.draft = draft.map(applyingLink)
        // Overlap check keys off the draft's time window (unaffected by link choice).
        if let draft {
            conflicts = conflictProvider?(draft.startDate, draft.endDate) ?? []
        } else {
            conflicts = []
        }
    }

    /// Re-derive the link on the current base draft (called when the user flips the
    /// link toggle/picker — no re-parse needed).
    private func reapplyLink() {
        guard let base = baseDraft else { return }
        draft = applyingLink(base)
    }

    /// Resolve and attach the effective link per the current `linkChoice`:
    /// - `.none` → strip any attached library link.
    /// - `.specific(id)` → that saved link.
    /// - `.auto` → the active template's link if it has one; else the default link
    ///   when the phrase reads like a meeting (heuristic). A link the *parser* found
    ///   in the text is preserved and never overwritten.
    private func applyingLink(_ draft: EventDraft) -> EventDraft {
        var d = draft
        // Event vs task: user override, else auto-detect from the raw text (Issue #19).
        d.kind = kindOverride ?? (TaskIntentHeuristic.isTask(inputText) ? .task : .event)
        // Don't clobber a join URL the parser pulled out of the text itself.
        let parserFoundURL = d.url != nil && d.attachedLinkName == nil
        if parserFoundURL { return d }

        let chosen: SavedMeetingLink?
        switch linkChoice {
        case .none:
            chosen = nil
        case .specific(let id):
            chosen = config.link(id: id)
        case .auto:
            if let template = activeTemplate, let id = template.linkID {
                chosen = config.link(id: id)
            } else if MeetingLinkHeuristic.isLikelyMeeting(inputText), let def = config.defaultLink {
                chosen = def
            } else {
                chosen = nil
            }
        }
        d.url = chosen?.url
        d.attachedLinkName = chosen?.name
        return d
    }
}
