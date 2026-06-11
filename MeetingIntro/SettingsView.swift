import AppKit
import SwiftUI

/// Brings the Settings window to the front and activates the app. `SettingsLink`
/// reliably *opens* the Settings scene, but on an `LSUIElement` (menu-bar) app it
/// opens behind whatever you were using because the app isn't activated. This
/// background accessor fixes that — on first appear, and again whenever the window
/// becomes visible (the re-open-while-buried case) via the occlusion notification,
/// without re-fronting on every SwiftUI state update.
private struct SettingsWindowActivator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.observe(window)
            Self.bringToFront(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func bringToFront(_ window: NSWindow) {
        guard !window.isKeyWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    final class Coordinator {
        private var observer: NSObjectProtocol?
        func observe(_ window: NSWindow) {
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak window] _ in
                guard let window, window.occlusionState.contains(.visible) else { return }
                SettingsWindowActivator.bringToFront(window)
            }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

/// Settings window for configuring calendar source, countdown, and audio.
struct SettingsView: View {
    @ObservedObject var calendarManager: CalendarManager
    @ObservedObject var audioManager: AudioManager
    @ObservedObject var voiceReminder: VoiceReminderManager
    @ObservedObject var notificationManager: NotificationManager
    @ObservedObject var countdownConfig: CountdownConfigManager
    @ObservedObject var mixkitSounds: MixkitSoundManager
    @ObservedObject var contextMonitor: MeetingContextMonitor
    @ObservedObject var smartConfig: SmartConfigManager
    @ObservedObject var audioRouter: AudioRouter
    @ObservedObject var handoffConfig: HandoffConfigManager
    @ObservedObject var handoffCoordinator: MeetingHandoffCoordinator
    @ObservedObject var recordingConfig: RecordingConfig
    @ObservedObject var recordingController: RecordingController
    @ObservedObject var recordingCoordinator: MeetingRecordingCoordinator
    @ObservedObject var overlayController: OverlayWindowController
    @ObservedObject var quickAddConfig: QuickAddConfig
    @ObservedObject var quickAddPanel: QuickAddPanelController
    @ObservedObject var notesConfig: MeetingNotesConfig
    @ObservedObject var diagnosticLog: DiagnosticLog
    @ObservedObject var mirrorConfig: MirrorConfigManager
    @ObservedObject var mirrorEngine: CalendarMirrorEngine

    @State private var editingMirror: Mirror?
    @State private var showMirrorSheet = false

    @AppStorage("nextMeetingHighlightHex") private var nextMeetingHighlightHex: String = defaultNextMeetingHighlightHex

    @State private var diagCategoryFilter: DiagnosticLog.Category?
    @State private var diagSearch: String = ""

    /// Diagnostics is a hidden tab (Android developer-options style): tap the
    /// version line in About 3× to reveal it. The log captures the whole time
    /// regardless — only the tab's visibility is gated. Persisted once unlocked.
    @AppStorage("diagnosticsUnlocked") private var diagnosticsUnlocked: Bool = false
    @State private var versionTapCount: Int = 0
    @State private var unlockHint: String?

    @Environment(\.openWindow) private var openWindow
    @State private var groqKeyDraft: String = ""

    @State private var quickAddKeyDraft: String = ""
    @State private var quickAddCalendars: [CalendarInfo] = []
    @State private var quickAddTesting = false
    @State private var quickAddTestResult: (passed: Bool, message: String)?
    @State private var newLinkName: String = ""
    @State private var newLinkURL: String = ""
    @State private var editingTemplate: QuickAddTemplate?

    @AppStorage("cancellationShowInTodayView") private var cancellationShowInTodayView: Bool = true
    @AppStorage("cancellationShowOverlay") private var cancellationShowOverlay: Bool = false
    @AppStorage("cancellationOverlayPosition") private var cancellationOverlayPosition: String = OverlayWindowController.CancellationOverlayPosition.topRight.rawValue

    @StateObject private var releaseNotes = ReleaseNotesManager()
    @StateObject private var updater = AppUpdater()

    @State private var showRecordingDisclaimer = false
    @State private var recordingStats: (count: Int, sizeBytes: Int64) = (0, 0)
    /// Bumped when the app reactivates so the recording permission rows re-read TCC
    /// state after the user grants access in System Settings.
    @State private var permissionTick = 0

    @State private var selectedProvider: CalendarProviderType = .eventKit
    @State private var selectedSection: SettingsSection = .calendar

    @AppStorage("contextPanelShowNotes") private var contextPanelShowNotes: Bool = true
    @AppStorage("contextPanelShowAttendees") private var contextPanelShowAttendees: Bool = true
    @AppStorage("contextPanelShowJoinURL") private var contextPanelShowJoinURL: Bool = true
    @AppStorage("contextPanelMinThreshold") private var contextPanelMinThreshold: Int = 0

    @State private var graphClientId: String = ""
    @State private var graphAuthMessage: String?
    @State private var isSigningIn: Bool = false
    @State private var availableCalendars: [CalendarInfo] = []
    @State private var selectedCalendarIDs: Set<String> = []
    @State private var volume: Float = 0.7

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                ForEach(SettingsGroup.allCases, id: \.self) { group in
                    Section(group.title) {
                        ForEach(SettingsSection.allCases.filter { $0.group == group && ($0 != .diagnostics || diagnosticsUnlocked) }, id: \.self) { section in
                            Label(section.title, systemImage: section.systemImage)
                                .tag(section)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                switch selectedSection {
                case .calendar:  calendarTab
                case .quickAdd:  quickAddTab
                case .calendarSync: calendarSyncTab
                case .countdown: countdownTab
                case .smart:     smartTab
                case .voice:     voiceTab
                case .sounds:    soundsTab
                case .audio:     audioTab
                case .handoff:   handoffTab
                case .recording: recordingTab
                case .whatsNew:  whatsNewTab
                case .diagnostics: diagnosticsTab
                case .guide:     guideTab
                case .about:     aboutTab
                }
            }
            .navigationTitle(selectedSection.title)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 600)
        .onAppear { loadSettings() }
        .background(SettingsWindowActivator())
    }

    // MARK: - Calendar Tab

    private var calendarTab: some View {
        Form {
            Section("Calendar Source") {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(CalendarProviderType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedProvider) { _, newValue in
                    calendarManager.activeProviderType = newValue
                }

                Text(selectedProvider.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if selectedProvider == .microsoftGraph {
                graphSettingsSection
            }

            Section("Calendars to Monitor") {
                if availableCalendars.isEmpty {
                    Button("Load Calendars") {
                        Task { await loadCalendars() }
                    }
                } else {
                    ForEach(availableCalendars) { calendar in
                        Toggle(isOn: Binding(
                            get: { selectedCalendarIDs.contains(calendar.id) },
                            set: { isSelected in
                                if isSelected {
                                    selectedCalendarIDs.insert(calendar.id)
                                } else {
                                    selectedCalendarIDs.remove(calendar.id)
                                }
                                calendarManager.selectedCalendarIDs = selectedCalendarIDs
                            }
                        )) {
                            HStack {
                                Circle()
                                    .fill(Color(hex: calendar.color))
                                    .frame(width: 10, height: 10)
                                Text(calendar.name)
                                Spacer()
                                Text(calendar.source)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if selectedCalendarIDs.isEmpty {
                    Text("All calendars are monitored when none are selected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Graph Settings Section

    private var graphSettingsSection: some View {
        Section("Microsoft Graph API") {
            TextField("Client ID (from Azure Portal)", text: $graphClientId)
                .textFieldStyle(.roundedBorder)
                .onChange(of: graphClientId) { _, newValue in
                    calendarManager.graphCalendarProvider.clientId = newValue
                }

            HStack {
                if calendarManager.graphCalendarProvider.isAuthorized {
                    Label("Signed In", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)

                    Spacer()

                    Button("Sign Out") {
                        calendarManager.graphCalendarProvider.signOut()
                        calendarManager.isAuthorized = false
                    }
                    .tint(.red)
                } else {
                    Button(isSigningIn ? "Waiting for browser…" : "Sign In") {
                        Task { await signInGraph() }
                    }
                    .disabled(graphClientId.isEmpty || isSigningIn)

                    if isSigningIn {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                }
            }

            // Write access (RSVP) needs the Calendars.ReadWrite scope. A token from
            // before v2.7.0 is read-only until the user re-authorizes once.
            if calendarManager.graphCalendarProvider.isAuthorized
                && !calendarManager.graphCalendarProvider.supportsResponding {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Re-authorize to accept/decline invites from MeetingIntro", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Button(isSigningIn ? "Waiting for browser…" : "Re-authorize (write access)") {
                        Task { await signInGraph() }
                    }
                    .disabled(isSigningIn)
                }
            }

            if let message = graphAuthMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Quick Add Tab

    private var quickAddTab: some View {
        Form {
            Section("Text to Calendar") {
                Text("Create events by typing plain English — \"Coffee with Sam tomorrow 3pm\". Open from the menu bar: New Event… (⌘N while the menu is open).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Try it now") { quickAddPanel.show() }
            }

            Section("Parsing") {
                Text(quickAddConfig.llmEnabled
                     ? (quickAddConfig.provider == .ollama
                        ? "Smart parsing is ON via a local model — nothing you type leaves this Mac."
                        : "Smart parsing is ON — text is sent to \(quickAddConfig.provider.displayName) for parsing.")
                     : "On-device parsing only — nothing you type leaves this Mac. Pick a provider and add a key for smarter parsing.")
                    .font(.caption)
                    .foregroundStyle(quickAddConfig.llmEnabled ? .primary : .secondary)

                Picker("Provider", selection: Binding(
                    get: { quickAddConfig.provider },
                    set: { quickAddConfig.setProvider($0) }
                )) {
                    ForEach(QuickAddProvider.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }

                if quickAddConfig.provider == .custom {
                    TextField("API base URL (OpenAI-compatible)", text: $quickAddConfig.apiBaseURL)
                }

                if quickAddConfig.provider == .ollama {
                    Text("Runs entirely on this Mac via Ollama — install from ollama.com, then `ollama pull \(quickAddConfig.modelID)`. No key, no network.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    SecureField(quickAddConfig.provider.keyPlaceholder, text: $quickAddKeyDraft)
                    HStack {
                        Button(quickAddConfig.hasLLMKey ? "Update key" : "Save key") {
                            quickAddConfig.openRouterKey = quickAddKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        .disabled(quickAddKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        if quickAddConfig.hasLLMKey {
                            Button("Remove key") {
                                quickAddConfig.openRouterKey = ""
                                quickAddKeyDraft = ""
                            }
                            .tint(.red)
                        }
                        if let console = quickAddConfig.provider.keyConsoleURL {
                            Spacer()
                            Button("Get a key ↗") {
                                if let url = URL(string: console) { NSWorkspace.shared.open(url) }
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                    Text("Key is stored in the macOS Keychain, never in plain preferences.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    TextField("Model", text: $quickAddConfig.modelID)
                        .disabled(!quickAddConfig.llmEnabled)
                    Button {
                        testQuickAddModel()
                    } label: {
                        if quickAddTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Test", systemImage: "bolt.badge.checkmark")
                        }
                    }
                    .disabled(!quickAddConfig.llmEnabled || quickAddTesting)
                    .help("Send a sample phrase through this endpoint + model and show exactly what happens")
                }
                if let result = quickAddTestResult {
                    Label(result.message, systemImage: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(result.passed ? .green : .orange)
                        .textSelection(.enabled)
                }
                Text("Suggested for \(quickAddConfig.provider.displayName): \(quickAddConfig.provider.suggestedModel.isEmpty ? "any OpenAI-compatible model ID" : quickAddConfig.provider.suggestedModel). Avoid reasoning models — too slow for the 6-second live-parse window, and they often wrap output in thinking text instead of JSON.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Event Defaults") {
                Picker("Create in calendar", selection: Binding(
                    get: { quickAddConfig.defaultCalendarID ?? "" },
                    set: { quickAddConfig.defaultCalendarID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("System default").tag("")
                    ForEach(quickAddCalendars) { cal in
                        Text("\(cal.name) (\(cal.source))").tag(cal.id)
                    }
                }
                Stepper(value: $quickAddConfig.defaultDurationMinutes, in: 5...240, step: 5) {
                    Text("Default duration: \(quickAddConfig.defaultDurationMinutes) min")
                }
                Text("Events are created in your Mac calendars (EventKit). Note: macOS doesn't let apps add attendees or send invites — events are created without invitees.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Meeting Links") {
                Text("Save your join links (personal Zoom room, Teams meeting, phone bridge). When you create a meeting-like event — \"sync with Sam\", \"1:1\" — MeetingIntro attaches your default link automatically (you can switch or remove it in the preview). That makes the overlay Join button, audio handoff, and auto-record work for events you create yourself.")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(quickAddConfig.meetingLinks) { link in
                    HStack(spacing: 8) {
                        Button {
                            quickAddConfig.setDefaultLink(link.id)
                        } label: {
                            Image(systemName: link.isDefault ? "star.fill" : "star")
                                .foregroundStyle(link.isDefault ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(link.isDefault ? "Default link for smart-attach" : "Make default")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(link.name).font(.callout)
                            Text(link.url).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            quickAddConfig.removeLink(link.id)
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                }

                HStack(spacing: 8) {
                    TextField("Name (e.g. Personal Zoom)", text: $newLinkName)
                    TextField("https://…", text: $newLinkURL)
                    Button("Add") {
                        let name = newLinkName.trimmingCharacters(in: .whitespaces)
                        let url = newLinkURL.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, !url.isEmpty else { return }
                        quickAddConfig.addLink(name: name, url: url)
                        newLinkName = ""; newLinkURL = ""
                    }
                    .disabled(newLinkName.trimmingCharacters(in: .whitespaces).isEmpty
                              || newLinkURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if quickAddConfig.meetingLinks.isEmpty {
                    Text("No links yet — add one above to enable smart-attach.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            Section("Event Templates") {
                Text("Type a shorthand like /standup into Quick Add and it expands to a full event — title, duration, and a meeting link — then you just add the date/time (/standup tomorrow 9am).")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(quickAddConfig.templates) { t in
                    Button {
                        editingTemplate = t
                    } label: {
                        HStack(spacing: 8) {
                            Text("/\(t.trigger)")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.title).font(.callout).foregroundStyle(.primary)
                                Text("\(t.durationMinutes) min" + (quickAddConfig.link(id: t.linkID).map { " · \($0.name)" } ?? ""))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    editingTemplate = QuickAddTemplate(trigger: "", title: "", durationMinutes: quickAddConfig.defaultDurationMinutes)
                } label: {
                    Label("New template", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            quickAddCalendars = await calendarManager.eventKitCalendars()
        }
        .sheet(item: $editingTemplate) { template in
            TemplateEditSheet(
                template: template,
                links: quickAddConfig.meetingLinks,
                existingTriggers: quickAddConfig.templates.filter { $0.id != template.id }.map { $0.trigger },
                onSave: { saved in
                    if quickAddConfig.templates.contains(where: { $0.id == saved.id }) {
                        quickAddConfig.updateTemplate(saved)
                    } else {
                        quickAddConfig.addTemplate(saved)
                    }
                    editingTemplate = nil
                },
                onDelete: quickAddConfig.templates.contains(where: { $0.id == template.id }) ? {
                    quickAddConfig.removeTemplate(template.id)
                    editingTemplate = nil
                } : nil,
                onCancel: { editingTemplate = nil }
            )
        }
    }

    // MARK: - Calendar Sync Tab

    private var calendarSyncTab: some View {
        Form {
            Section("Calendar Sync") {
                Text("Mirror events from one or more calendars into another — one-way and continuous. A colleague checking the destination sees your true availability without you copying anything. The destination is a read-only reflection; edit in the source.")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    editingMirror = nil
                    showMirrorSheet = true
                } label: { Label("Add Mirror", systemImage: "plus") }
            }

            if mirrorConfig.mirrors.isEmpty {
                Section {
                    Text("No mirrors yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Your Mirrors") {
                    ForEach(mirrorConfig.mirrors) { mirror in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(mirror.name).fontWeight(.medium)
                                Text(mirror.detailMode.displayName)
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { mirror.enabled },
                                    set: { on in toggleMirror(mirror, enabled: on) }
                                )).labelsHidden()
                            }
                            Text("\(mirror.sourceCalendarIDs.count) source\(mirror.sourceCalendarIDs.count == 1 ? "" : "s") → \(mirrorEngine.destinationName(for: mirror) ?? "destination")")
                                .font(.caption).foregroundStyle(.secondary)
                            if mirror.paused, let err = mirror.lastError {
                                Label(err, systemImage: "pause.circle.fill")
                                    .font(.caption2).foregroundStyle(.orange)
                                Button("Re-enable") { reEnableMirror(mirror) }
                                    .controlSize(.small)
                            } else if let err = mirror.lastError {
                                Label(err, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2).foregroundStyle(.orange)
                            } else if let last = mirror.lastSync {
                                Text("Last synced \(last, format: .relative(presentation: .named))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            HStack(spacing: 12) {
                                Button("Sync now") { mirrorEngine.reconcileAll() }
                                    .controlSize(.small)
                                Button("Edit") { editingMirror = mirror; showMirrorSheet = true }
                                    .controlSize(.small)
                                Button("Delete") { deleteMirror(mirror) }
                                    .controlSize(.small).tint(.red)
                            }
                            .padding(.top, 2)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showMirrorSheet) {
            MirrorEditSheet(
                existing: editingMirror,
                calendars: quickAddCalendars,
                isWritable: { mirrorEngine.isWritable($0) },
                creatableSources: mirrorEngine.creatableSources(),
                defaultSourceID: mirrorEngine.defaultCreatableSourceID(),
                createCalendar: { name, sourceID in mirrorEngine.createDedicatedCalendar(named: name, sourceID: sourceID) },
                onSave: { mirror in saveMirror(mirror); showMirrorSheet = false },
                onCancel: { showMirrorSheet = false }
            )
        }
        .task { quickAddCalendars = await calendarManager.eventKitCalendars() }
    }

    private func toggleMirror(_ mirror: Mirror, enabled: Bool) {
        mirrorConfig.update(mirror.id) {
            $0.enabled = enabled
            if enabled { $0.paused = false; $0.lastError = nil }
        }
        if !enabled, mirror.deleteCopiesOnDisable {
            mirrorEngine.tearDown(mirror)
        } else if enabled {
            mirrorEngine.reconcileAll()
        }
    }

    private func reEnableMirror(_ mirror: Mirror) {
        mirrorConfig.update(mirror.id) { $0.paused = false; $0.lastError = nil }
        mirrorEngine.reconcileAll()
    }

    private func deleteMirror(_ mirror: Mirror) {
        if mirror.deleteCopiesOnDisable { mirrorEngine.tearDown(mirror) }
        mirrorConfig.remove(mirror.id)
    }

    private func saveMirror(_ mirror: Mirror) {
        mirrorConfig.upsert(mirror)
        mirrorEngine.reconcileAll()
    }

    // MARK: - Countdown Tab

    private var countdownTab: some View {
        Form {
            Section("Countdown Triggers") {
                Text("Choose when to be reminded and how. Each trigger can overlay, notify, or speak.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(CountdownConfigManager.availableMinutes, id: \.self) { minutes in
                    let isEnabled = countdownConfig.triggers.contains { $0.minutes == minutes }
                    DisclosureGroup {
                        if let trigger = countdownConfig.trigger(for: minutes) {
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle("🖥️ Show Overlay", isOn: Binding(
                                    get: { trigger.showOverlay },
                                    set: { val in
                                        var t = trigger; t.showOverlay = val
                                        countdownConfig.update(t)
                                    }
                                ))

                                Toggle("🔔 System Notification", isOn: Binding(
                                    get: { trigger.sendNotification },
                                    set: { val in
                                        var t = trigger; t.sendNotification = val
                                        countdownConfig.update(t)
                                    }
                                ))

                                Toggle("🗣️ Voice Reminder", isOn: Binding(
                                    get: { trigger.playVoice },
                                    set: { val in
                                        var t = trigger; t.playVoice = val
                                        countdownConfig.update(t)
                                    }
                                ))
                            }
                            .padding(.leading, 4)
                        }
                    } label: {
                        Toggle(isOn: Binding(
                            get: { isEnabled },
                            set: { on in
                                if on {
                                    countdownConfig.addTrigger(minutes: minutes)
                                } else {
                                    countdownConfig.removeTrigger(minutes: minutes)
                                }
                            }
                        )) {
                            Text(minutes == 1 ? "1 minute before" : "\(minutes) minutes before")
                                .fontWeight(isEnabled ? .medium : .regular)
                        }
                    }
                }

                if countdownConfig.triggers.isEmpty {
                    Text("⚠️ Select at least one countdown time.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Join Meeting Button") {
                Toggle("Show \"Join Meeting\" button when a link is detected", isOn: $countdownConfig.joinButtonEnabled)
                Text("MeetingIntro scans the event's URL field, description, and location for Zoom, Teams, Google Meet, Webex, and GoToMeeting links.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Today's Meetings (menu bar)") {
                ColorPicker("Next-meeting highlight color", selection: Binding(
                    get: { Color(hex: nextMeetingHighlightHex) },
                    set: { nextMeetingHighlightHex = $0.hexString }
                ), supportsOpacity: false)
                Button("Reset to default") { nextMeetingHighlightHex = defaultNextMeetingHighlightHex }
                    .controlSize(.small)
                Text("In the menu bar dropdown, the next upcoming meeting is marked with ▸, bolded, shown in this color with a countdown; already-ended meetings are dimmed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Meeting Details Panel") {
                Toggle("Show notes in overlay", isOn: $contextPanelShowNotes)
                Toggle("Show attendees in overlay", isOn: $contextPanelShowAttendees)
                Toggle("Show secondary join link in overlay", isOn: $contextPanelShowJoinURL)
                Stepper(value: $contextPanelMinThreshold, in: 0...60) {
                    Text("Hide panel when meeting is closer than \(contextPanelMinThreshold) min")
                }
                Text("The details panel adds notes, attendees, and a copy/open join link below the countdown ring. Use the stepper to suppress it on last-minute reminders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cancelled Meetings") {
                Toggle("Notify me immediately when a meeting is cancelled",
                       isOn: $notificationManager.cancellationNotifyEnabled)
                Toggle("Play sound with cancellation notifications",
                       isOn: $notificationManager.cancellationPlaySound)
                    .disabled(!notificationManager.cancellationNotifyEnabled)
                Toggle("Show cancelled meetings in Today's Meetings",
                       isOn: $cancellationShowInTodayView)
                Toggle("Show overlay notice when a meeting is cancelled",
                       isOn: $cancellationShowOverlay)
                Picker("Overlay position", selection: $cancellationOverlayPosition) {
                    ForEach(OverlayWindowController.CancellationOverlayPosition.allCases, id: \.rawValue) { position in
                        Text(position.displayName).tag(position.rawValue)
                    }
                }
                .disabled(!cancellationShowOverlay)
                Text("Reminders, voice prompts, and auto-recording are always suppressed for cancelled meetings — these settings only control how you're told about the cancellation. The overlay notice stays on screen until you dismiss it (even across restarts and sleep), and politely hides while you're in a call or sharing your screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Test Cancellation Notice") {
                    let testMeeting = MeetingEvent(
                        id: "cancel-test",
                        title: "Sprint Demo (Test)",
                        startDate: Date().addingTimeInterval(1800),
                        endDate: Date().addingTimeInterval(5400),
                        calendarName: "Preview",
                        location: nil,
                        isAllDay: false,
                        url: nil,
                        notes: nil,
                        attendeeNames: [],
                        attendeeCount: 0,
                        organizerName: "Jon Lind",
                        isCancelled: true,
                        myResponse: .organizer
                    )
                    overlayController.showCancellation(for: testMeeting)
                }
            }

            Section("Preview") {
                Button("Test Countdown Overlay") {
                    let previewMinutes = countdownConfig.enabledMinutes.first ?? 2
                    let testMeeting = MeetingEvent(
                        id: "test",
                        title: "Test Meeting Preview",
                        startDate: Date().addingTimeInterval(TimeInterval(previewMinutes * 60)),
                        endDate: Date().addingTimeInterval(TimeInterval(previewMinutes * 60 + 3600)),
                        calendarName: "Preview",
                        location: "Conference Room A",
                        isAllDay: false,
                        url: URL(string: "https://zoom.us/j/0000000000"),
                        notes: "Sprint review for Q2 planning. Bring updates on the data-pipeline migration and the customer-segmentation analysis. We'll spend the first 15 minutes on the roadmap doc, then open the floor for blockers.",
                        attendeeNames: ["Alice Wong", "Ben Patel", "Chiamaka Eze", "Diego Ortiz", "Emma Schultz", "Fatima Bello", "Grace Liu", "Henry Park"],
                        attendeeCount: 8,
                        organizerName: "Alice Wong",
                        isCancelled: false,
                        myResponse: .accepted,
                        responseCounts: ResponseCounts(accepted: 5, declined: 1, tentative: 0, noResponse: 2)
                    )
                    showCountdownOverlay(for: testMeeting)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Smart Tab

    private var smartTab: some View {
        Form {
            Section("Context-Aware Reminders") {
                Toggle("Suppress when I'm already in a call",
                       isOn: $smartConfig.suppressWhenInCall)
                Toggle("Visual-only when Focus is on",
                       isOn: $smartConfig.visualOnlyWhenFocus)
                Toggle("No voice when I'm screen sharing",
                       isOn: $smartConfig.noVoiceWhenScreenSharing)
                Toggle("Escalate when a fullscreen app is active",
                       isOn: $smartConfig.escalateWhenFullscreen)

                Text("MeetingIntro reads four live signals to decide which channels should fire. Rules are evaluated top-to-bottom — the first matching rule wins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Meeting Responses (RSVP)") {
                Toggle("Skip meetings I've declined",
                       isOn: $smartConfig.skipDeclinedMeetings)
                Toggle("…and ones I haven't responded to",
                       isOn: $smartConfig.skipNoResponseMeetings)
                    .disabled(!smartConfig.skipDeclinedMeetings)
                Text("Quietens reminders **and** auto-recording for invitations you've declined (and optionally not answered). Tentative invites still remind. Personal events, meetings you organize, and anything without RSVP data are never affected — this only applies to real invitations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Live Signals") {
                signalRow(name: "In a call",
                          isOn: contextMonitor.snapshot.isInActiveCall,
                          detail: contextMonitor.snapshot.isMicrophoneInUseElsewhere
                            ? "mic in use"
                            : (contextMonitor.snapshot.isConferenceAppActive ? "conf app open (mic idle)" : "no signal"))
                signalRow(name: "Focus on",
                          isOn: contextMonitor.snapshot.isFocusActive,
                          detail: focusAuthDetail)
                signalRow(name: "Screen sharing",
                          isOn: contextMonitor.snapshot.isScreenCaptured)
                signalRow(name: "Fullscreen app",
                          isOn: contextMonitor.snapshot.isFullscreenAppActive,
                          detail: contextMonitor.snapshot.frontmostBundleID ?? "—")
            }

            if contextMonitor.focus.authorizationStatus != .authorized {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading) {
                            Text("Focus integration needs permission")
                                .font(.subheadline).fontWeight(.semibold)
                            Text("Without Focus permission, MeetingIntro treats Focus as always off.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Grant…") {
                            Task { await contextMonitor.requestFocusAuthorization() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var focusAuthDetail: String {
        switch contextMonitor.focus.authorizationStatus {
        case .authorized: return "authorized"
        case .denied: return "permission denied"
        case .restricted: return "restricted"
        case .notDetermined: return "permission not asked"
        }
    }

    private func signalRow(name: String, isOn: Bool, detail: String? = nil) -> some View {
        HStack {
            Circle()
                .fill(isOn ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 10, height: 10)
            Text(name)
            Spacer()
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Handoff Tab

    private var handoffTab: some View {
        Form {
            Section("Audio Output") {
                Toggle("Switch output device when a meeting starts", isOn: $handoffConfig.audioHandoffEnabled)
                Picker("Preferred", selection: handoffDeviceBinding(\.preferredOutputUID)) {
                    Text("(none)").tag(String?.none)
                    ForEach(audioRouter.devices, id: \.uid) { device in
                        deviceLabel(device).tag(String?.some(device.uid))
                    }
                }
                .disabled(!handoffConfig.audioHandoffEnabled)
                Picker("Fallback", selection: handoffDeviceBinding(\.fallbackOutputUID)) {
                    Text("Built-in (default)").tag(String?.none)
                    ForEach(audioRouter.devices, id: \.uid) { device in
                        deviceLabel(device).tag(String?.some(device.uid))
                    }
                }
                .disabled(!handoffConfig.audioHandoffEnabled)
            }

            Section("Focus Mode") {
                Toggle("Enable Focus during meetings", isOn: $handoffConfig.focusHandoffEnabled)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Setup (one time)")
                        .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                    Text("macOS doesn't let apps toggle Focus directly — we go through Shortcuts. Create two Shortcuts in the Shortcuts app, named exactly:")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Image(systemName: "1.circle.fill").foregroundStyle(Color.accentColor)
                        Text("MeetingIntro – Start Focus")
                            .font(.system(.caption, design: .monospaced))
                    }
                    Text("Single action: \"Set Focus\" → Do Not Disturb → On")
                        .font(.caption).foregroundStyle(.secondary).padding(.leading, 22)

                    HStack(spacing: 8) {
                        Image(systemName: "2.circle.fill").foregroundStyle(Color.accentColor)
                        Text("MeetingIntro – End Focus")
                            .font(.system(.caption, design: .monospaced))
                    }
                    Text("Single action: \"Set Focus\" → Do Not Disturb → Off")
                        .font(.caption).foregroundStyle(.secondary).padding(.leading, 22)

                    HStack(spacing: 12) {
                        Button {
                            NSWorkspace.shared.open(URL(string: "shortcuts://")!)
                        } label: {
                            Label("Open Shortcuts App", systemImage: "arrow.up.right.square")
                        }
                        Button("Test Start Focus") {
                            Task { await handoffCoordinator.testFocusEnable() }
                        }
                        .disabled(!handoffConfig.focusHandoffEnabled)
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 2)

                if let outcome = handoffCoordinator.lastFocusOutcome {
                    focusOutcomeView(outcome)
                }
            }

            Section("Restore") {
                Toggle("Restore prior audio + Focus state when meeting ends", isOn: $handoffConfig.restoreOnEnd)
                Text("A snapshot of the prior state is taken when the meeting starts. If MeetingIntro crashes mid-meeting, the state is restored on next launch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func deviceLabel(_ device: AudioRouter.OutputDevice) -> some View {
        let icon: String
        if device.isBluetooth { icon = "airpods" }
        else if device.isBuiltIn { icon = "speaker.wave.2" }
        else { icon = "hifispeaker" }
        return Label(device.name, systemImage: icon)
    }

    private func handoffDeviceBinding(_ keyPath: ReferenceWritableKeyPath<HandoffConfigManager, String?>) -> Binding<String?> {
        Binding(
            get: { handoffConfig[keyPath: keyPath] },
            set: { handoffConfig[keyPath: keyPath] = $0 }
        )
    }

    @ViewBuilder
    private func focusOutcomeView(_ outcome: FocusModeController.Outcome) -> some View {
        switch outcome {
        case .verified:
            Label("Focus shortcut ran successfully", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        case .unverified:
            Label("Focus state didn't change — did you install the Shortcuts?", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.caption)
        case .noFocusPermission:
            Label("Focus permission needed to verify (grant in the Smart tab)", systemImage: "lock.fill")
                .foregroundStyle(.orange).font(.caption)
        }
    }

    // MARK: - Recording Tab

    private var recordingTab: some View {
        Form {
            Section("Auto-Record Meetings") {
                Toggle("Record meetings with conference links automatically",
                       isOn: Binding(
                        get: { recordingConfig.isEnabled },
                        set: { newValue in
                            if newValue && !recordingConfig.hasAcceptedDisclaimer {
                                showRecordingDisclaimer = true
                            } else {
                                recordingConfig.isEnabled = newValue
                            }
                        }))
                Text("MeetingIntro starts a mic + system-audio recording at the meeting's start time and stops at its end time. Meetings without a detected Zoom/Teams/Meet/Webex link are skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if recordingController.isRecording, let title = recordingController.currentMeetingTitle {
                    HStack {
                        Circle().fill(Color.red).frame(width: 10, height: 10)
                        Text("Recording: \(title)").font(.caption).fontWeight(.medium)
                        Spacer()
                        Button("Stop") { Task { await recordingCoordinator.stopManually() } }
                            .tint(.red)
                    }
                }
            }

            if recordingConfig.isEnabled {
                Section("Permissions") {
                    permissionRow(
                        title: "Screen Recording",
                        granted: RecordingController.hasScreenRecordingPermission,
                        detail: "Required to capture the meeting audio you hear (the other participants).",
                        grant: {
                            // First call surfaces the system prompt; if already decided,
                            // macOS ignores it, so also deep-link to the settings pane.
                            RecordingController.requestScreenRecordingPermission()
                            openScreenRecordingSettings()
                        })
                    permissionRow(
                        title: "Microphone",
                        granted: RecordingController.hasMicrophonePermission,
                        detail: "Required to capture your own voice. Prompted automatically on first recording.",
                        grant: { openMicrophoneSettings() })
                }
                .id(permissionTick)
            }

            Section("Save Location") {
                HStack {
                    Image(systemName: "folder")
                    Text(recordingConfig.resolveSaveDirectory().path)
                        .font(.system(.caption, design: .monospaced))
                        .truncationMode(.middle)
                        .lineLimit(1)
                    Spacer()
                }
                HStack(spacing: 12) {
                    Button("Show in Finder") {
                        let url = recordingConfig.resolveSaveDirectory()
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    Button("Change…") { pickSaveLocation() }
                    if recordingConfig.saveDirectoryBookmark != nil {
                        Button("Reset to default") { recordingConfig.saveDirectoryBookmark = nil }
                    }
                }
                Text("\(recordingStats.count) recording\(recordingStats.count == 1 ? "" : "s"), \(formatBytes(recordingStats.sizeBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcription & Notes") {
                Toggle("Generate transcript + meeting notes after each recording",
                       isOn: $notesConfig.autoGenerate)

                Picker("Transcription engine", selection: $notesConfig.engine) {
                    ForEach(MeetingNotesConfig.Engine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                Text(notesConfig.engine == .whisperKit
                     ? "Audio never leaves this Mac. The model downloads once on first use and runs on the Neural Engine — roughly 3–5 minutes per hour of audio."
                     : "Audio is uploaded to Groq for transcription — roughly 30 seconds per hour of audio. Free tier available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if notesConfig.engine == .whisperKit {
                    Picker("Model", selection: $notesConfig.whisperModel) {
                        ForEach(MeetingNotesConfig.whisperModelOptions, id: \.self) { Text($0).tag($0) }
                    }
                    Text("base (~150 MB) is fast and decent; large-v3_turbo (~1.6 GB) is noticeably better on accents and crosstalk.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    SecureField("Groq API key (gsk_…)", text: $groqKeyDraft)
                    HStack {
                        Button(notesConfig.groqKey.isEmpty ? "Save key" : "Update key") {
                            notesConfig.groqKey = groqKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        .disabled(groqKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        if quickAddConfig.provider == .groq && quickAddConfig.hasLLMKey && notesConfig.groqKey != quickAddConfig.openRouterKey {
                            Button("Use Quick Add key") {
                                notesConfig.groqKey = quickAddConfig.openRouterKey
                            }
                        }
                        if !notesConfig.groqKey.isEmpty {
                            Button("Remove key") {
                                notesConfig.groqKey = ""
                                groqKeyDraft = ""
                            }
                            .tint(.red)
                        }
                        Spacer()
                        Button("Get a key ↗") {
                            if let url = URL(string: "https://console.groq.com/keys") { NSWorkspace.shared.open(url) }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                    if !notesConfig.groqKey.isEmpty {
                        Label("Key saved in Keychain", systemImage: "checkmark.circle.fill")
                            .font(.caption2).foregroundStyle(.green)
                    }
                }

                Text("Notes are written by your Quick Add AI provider — currently \(quickAddConfig.provider.displayName) · \(quickAddConfig.modelID). Change it under Quick Add.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Open Meeting Notes") {
                    openWindow(id: "meetingNotes")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            if let error = recordingCoordinator.lastError {
                Section("Last error") {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { refreshRecordingStats() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // User may have just granted permission in System Settings — re-read TCC.
            permissionTick += 1
        }
        .alert("Before you enable recording", isPresented: $showRecordingDisclaimer) {
            Button("Cancel", role: .cancel) {}
            Button("I understand, enable recording") {
                recordingConfig.hasAcceptedDisclaimer = true
                recordingConfig.isEnabled = true
            }
        } message: {
            Text("MeetingIntro will record your microphone and the meeting audio you hear when each meeting with a conference link starts, and stop when it ends. Recordings save to your chosen folder.\n\nRecording laws vary by jurisdiction. In California, Massachusetts, Illinois, and most of the EU, you generally need participants to know they're being recorded. You're responsible for telling them.")
        }
    }

    /// One permission status row: green check + "Granted", or an orange warning with a
    /// Grant button that prompts / deep-links to the right System Settings pane.
    @ViewBuilder
    private func permissionRow(title: String, granted: Bool, detail: String, grant: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                Text(title).fontWeight(.medium)
                Spacer()
                if granted {
                    Text("Granted").font(.caption).foregroundStyle(.green)
                } else {
                    Button("Grant…", action: grant)
                }
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Sends a fixed sample phrase through the configured key + model and reports
    /// the outcome (with timing) — the one-click diagnostic for "why did my parse
    /// fall back to on-device?".
    private func testQuickAddModel() {
        quickAddTesting = true
        quickAddTestResult = nil
        let start = Date()
        Task { @MainActor in
            defer { quickAddTesting = false }
            do {
                let draft = try await OpenRouterParser.parse(
                    "Lunch with Sam tomorrow 1pm",
                    key: quickAddConfig.openRouterKey,
                    model: quickAddConfig.modelID,
                    baseURL: quickAddConfig.apiBaseURL
                )
                let secs = String(format: "%.1f", Date().timeIntervalSince(start))
                quickAddTestResult = (true, "Works — parsed \"\(draft.title)\" in \(secs)s")
            } catch {
                quickAddTestResult = (false, error.localizedDescription)
            }
        }
    }

    private func pickSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            recordingConfig.saveDirectoryBookmark = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            refreshRecordingStats()
        }
    }

    private func refreshRecordingStats() {
        let dir = recordingConfig.resolveSaveDirectory()
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            recordingStats = (0, 0)
            return
        }
        let m4as = items.filter { $0.pathExtension.lowercased() == "m4a" }
        let totalSize = m4as.reduce(Int64(0)) { acc, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return acc + Int64(size)
        }
        recordingStats = (m4as.count, totalSize)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Audio Tab

    private var audioTab: some View {
        Form {
            Section("Music File") {
                HStack {
                    if let fileName = audioManager.currentFileName {
                        Label(fileName, systemImage: "music.note")
                    } else {
                        Text("No file selected")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Choose File…") {
                        selectMusicFile()
                    }
                }
            }

            Section("Volume") {
                HStack {
                    Image(systemName: "speaker.fill")
                    Slider(value: $volume, in: 0...1, step: 0.05) { _ in
                        audioManager.setVolume(volume)
                    }
                    Image(systemName: "speaker.wave.3.fill")
                }

                HStack {
                    Button("Test Play") {
                        audioManager.play()
                    }
                    .disabled(audioManager.musicFileURL == nil)

                    Button("Stop") {
                        audioManager.stop()
                    }
                    .disabled(!audioManager.isPlaying)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Sounds Tab

    private var soundsTab: some View {
        Form {
            Section("Notification Sound") {
                Text("Download free notification sounds from Mixkit. The selected sound plays with each countdown notification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if mixkitSounds.selectedSoundID == nil {
                    Text("Using default system sound")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Sound Library") {
                ForEach(mixkitSounds.sounds) { sound in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sound.name)
                                .font(.subheadline)
                                .fontWeight(mixkitSounds.selectedSoundID == sound.id ? .semibold : .regular)
                            Text(sound.category)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()

                        if mixkitSounds.selectedSoundID == sound.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }

                        if mixkitSounds.downloadedSoundIDs.contains(sound.id) {
                            Button { mixkitSounds.preview(sound) } label: {
                                Image(systemName: "play.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Preview")

                            Button {
                                if mixkitSounds.selectedSoundID == sound.id {
                                    mixkitSounds.selectedSoundID = nil
                                } else {
                                    mixkitSounds.selectedSoundID = sound.id
                                }
                            } label: {
                                Image(systemName: mixkitSounds.selectedSoundID == sound.id ? "speaker.slash" : "speaker.wave.2")
                            }
                            .buttonStyle(.borderless)
                            .help(mixkitSounds.selectedSoundID == sound.id ? "Deselect" : "Use this sound")

                            Button { mixkitSounds.delete(sound) } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Delete")
                        } else if mixkitSounds.downloadingIDs.contains(sound.id) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button { mixkitSounds.download(sound) } label: {
                                Image(systemName: "arrow.down.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Download")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - What's New Tab

    private var whatsNewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("What's New")
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                    if releaseNotes.isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        Task { await releaseNotes.refreshIfNeeded(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh release notes")
                }

                if let error = releaseNotes.errorMessage {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(releaseNotes.releases) { release in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(release.tagName)
                                .font(.headline)
                            if release.tagName == "v\(currentAppVersion)" {
                                Text("CURRENT")
                                    .font(.caption2).fontWeight(.semibold)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.2), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }
                            Spacer()
                            Text(release.publishedAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        changelogBody(release.changelog)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }

                if releaseNotes.releases.isEmpty && !releaseNotes.isLoading && releaseNotes.errorMessage == nil {
                    Text("No release notes yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .task { await releaseNotes.refreshIfNeeded() }
    }

    /// Android-style hidden-feature unlock: 3 taps on the version reveals
    /// Diagnostics, with countdown feedback. No-op once already unlocked.
    private func handleVersionTap() {
        guard !diagnosticsUnlocked else { return }
        versionTapCount += 1
        let remaining = 3 - versionTapCount
        withAnimation {
            if remaining <= 0 {
                diagnosticsUnlocked = true
                unlockHint = "Diagnostics unlocked — see the Help section"
                diagnosticLog.info(.lifecycle, "Diagnostics tab revealed by user")
            } else if remaining == 1 {
                unlockHint = "1 more tap to reveal Diagnostics…"
            } else {
                unlockHint = "\(remaining) more taps to reveal Diagnostics…"
            }
        }
    }

    private var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Icon button beside the version: check for / install updates via Homebrew.
    @ViewBuilder
    private var updateControl: some View {
        switch updater.state {
        case .checking, .updating:
            ProgressView().controlSize(.small)
        case .available:
            Button { Task { await updater.update() } } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Update to the latest version")
        case .upToDate:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("You're on the latest version")
        case .failed:
            Button { Task { await updater.check() } } label: {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("Update check failed — click to retry")
        case .updated:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .idle:
            Button { Task { await updater.check() } } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain)
            .help("Check for updates")
        }
    }

    /// One-line status under the version for the states worth spelling out.
    @ViewBuilder
    private var updateStatusLine: some View {
        switch updater.state {
        case .available(let v):
            Button("Update available — install v\(v)") { Task { await updater.update() } }
                .font(.caption)
                .buttonStyle(.link)
        case .updating:
            Text("Updating via Homebrew…").font(.caption2).foregroundStyle(.secondary)
        case .updated:
            Text("Updated — relaunching…").font(.caption2).foregroundStyle(.green)
        case .failed(let msg):
            Text(msg).font(.caption2).foregroundStyle(.orange)
                .multilineTextAlignment(.center).textSelection(.enabled)
        default:
            EmptyView()
        }
    }

    /// Lightweight renderer for the auto-generated changelog markdown:
    /// "## Header" lines → small bold subheaders, "- item" lines → bullet rows,
    /// everything else → plain body text.
    private func changelogBody(_ changelog: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(changelog.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    EmptyView()
                } else if trimmed.hasPrefix("## ") {
                    Text(trimmed.dropFirst(3))
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                } else if trimmed.hasPrefix("- ") {
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(trimmed.dropFirst(2)).font(.caption)
                    }
                } else {
                    Text(trimmed).font(.caption)
                }
            }
        }
    }

    // MARK: - Diagnostics Tab

    private var filteredDiagnostics: [DiagnosticLog.Entry] {
        diagnosticLog.entries.reversed().filter { entry in
            (diagCategoryFilter == nil || entry.category == diagCategoryFilter) &&
            (diagSearch.isEmpty || entry.message.localizedCaseInsensitiveContains(diagSearch))
        }
    }

    private var diagnosticsTab: some View {
        VStack(spacing: 0) {
            // Notification authorization banner — the #1 silent-failure cause.
            if !notificationManager.notificationsAuthorized {
                HStack(spacing: 8) {
                    Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
                    Text("Notifications are turned off (\(NotificationManager.describe(notificationManager.authorizationStatus))) — reminders and cancellation notices won't appear.")
                        .font(.caption)
                    Spacer()
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
            }

            HStack(spacing: 8) {
                TextField("Search log…", text: $diagSearch)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $diagCategoryFilter) {
                    Text("All").tag(DiagnosticLog.Category?.none)
                    ForEach(DiagnosticLog.Category.allCases, id: \.self) { cat in
                        Text(cat.rawValue.capitalized).tag(DiagnosticLog.Category?.some(cat))
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnosticLog.exportText(), forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .help("Copy full log")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.logDirectory])
                } label: { Image(systemName: "folder") }
                .help("Reveal log files in Finder")
                Button {
                    diagnosticLog.clear()
                } label: { Image(systemName: "trash") }
                .help("Clear the log")
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            HStack {
                Text("Logs are kept for 7 days, then deleted automatically.")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Hide Diagnostics") {
                    versionTapCount = 0
                    unlockHint = nil
                    diagnosticsUnlocked = false
                }
                .controlSize(.small)
                .help("Re-hide this tab — tap the version in About 3× to bring it back")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            Divider()

            if filteredDiagnostics.isEmpty {
                ContentUnavailableView("No log entries", systemImage: "stethoscope",
                                       description: Text("Events will appear here as the app runs."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(filteredDiagnostics) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(levelColor(entry.level)).frame(width: 7, height: 7).padding(.top, 4)
                                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(entry.category.rawValue)
                                    .font(.caption2).fontWeight(.medium)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 84, alignment: .leading)
                                Text(entry.message)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func levelColor(_ level: DiagnosticLog.Level) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    // MARK: - Guide Tab

    private var guideTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("How to Use MeetingIntro")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("MeetingIntro runs silently in your macOS menu bar (check the clock-checkmark icon at the top right of your screen) and ensures you never miss a meeting.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                Divider()

                Group {
                    guideSection(
                        icon: "calendar", title: "1. Connect Your Calendar",
                        body: "Go to the Calendar tab and choose either Apple EventKit (local Mac calendars) or Microsoft Graph (Office 365). Select which specific calendars to monitor for upcoming meetings."
                    )
                    guideSection(
                        icon: "timer", title: "2. Set Up Countdowns",
                        body: "In the Countdown tab, enable times (like 5 minutes before) and choose how you want to be alerted for each: via a floating Overlay window, a standard macOS System Notification, or a spoken Voice Announcement."
                    )
                    guideSection(
                        icon: "speaker.wave.2", title: "3. Choose Alert Sounds",
                        body: "In the Sounds tab, download and select a free Mixkit sound effect. This sound will play whenever a System Notification is triggered."
                    )
                    guideSection(
                        icon: "music.note", title: "4. Pre-Meeting Lobby Music",
                        body: "In the Audio tab, pick a track to play automatically in the background while the countdown overlay is visible. This sets the tone before your meeting starts."
                    )
                    guideSection(
                        icon: "waveform", title: "5. Customize Voice Prompts",
                        body: "In the Voice tab, you can customize the exact phrase your Mac speaks when a Voice Announcement is triggered. Use placeholders like {{meeting}} and {{time}}."
                    )
                }

                Spacer(minLength: 20)
            }
            .padding()
        }
    }

    private func guideSection(icon: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.headline)
            Text(body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 20) {
            Spacer()

            // App Icon / Logo area
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 56))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.4, green: 0.8, blue: 1.0),
                            Color(red: 0.6, green: 0.4, blue: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 6) {
                Text("MeetingIntro")
                    .font(.system(size: 24, weight: .bold, design: .rounded))

                // Tap the version 3× to reveal the hidden Diagnostics tab
                // (Android developer-options mechanic). The log captures the whole
                // time regardless — this only unhides the viewer.
                HStack(spacing: 8) {
                    Text("Version \(currentAppVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .onTapGesture { handleVersionTap() }
                    updateControl
                }

                if let hint = unlockHint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }

                updateStatusLine
            }

            Text("Never be late to a meeting again.\nGet countdown overlays and voice reminders\nbefore your meetings start.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()
                .padding(.horizontal, 60)

            VStack(spacing: 8) {
                Text("Developed by")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("TempleGit")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .fontDesign(.rounded)

                // Feedback front door: the Google Form (no GitHub account needed;
                // submissions auto-bridge to GitHub Issues via Apps Script — see
                // docs/feedback-form-bridge.md). GitHub-savvy users can also file
                // directly via the templates in .github/ISSUE_TEMPLATE/.
                Button("Request Feature / Report Bug") {
                    if let url = URL(string: "https://forms.gle/9ueTH3vZq71TpDD86") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            Divider()
                .padding(.horizontal, 60)

            VStack(spacing: 4) {
                Text("Special thanks")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Text("Jon Lind, for suggesting smarter cancellation handling (v2.2.0)")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Spacer()

            Text("© \(Calendar.current.component(.year, from: Date())) TempleGit. All rights reserved.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Check once when About opens (don't re-check if we already know).
            if case .idle = updater.state { await updater.check() }
        }
    }

    // MARK: - Voice Reminder Tab

    private var voiceTab: some View {
        Form {
            Section("Voice Reminder") {
                Toggle("Enable voice reminders", isOn: $voiceReminder.isEnabled)

                Text("A voice will announce your upcoming meeting at the configured time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if voiceReminder.isEnabled {
                Section("Your Name") {
                    TextField("What should the voice call you?", text: $voiceReminder.userName)
                        .textFieldStyle(.roundedBorder)

                    Text("Used in phrases like \"Hi \(voiceReminder.userName), it's 5 minutes before your meeting…\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Reminder Timing") {
                    Picker("Announce", selection: $voiceReminder.reminderMinutesBefore) {
                        Text("1 minute before").tag(1)
                        Text("2 minutes before").tag(2)
                        Text("3 minutes before").tag(3)
                        Text("5 minutes before").tag(5)
                        Text("10 minutes before").tag(10)
                        Text("15 minutes before").tag(15)
                    }

                    Text("The voice reminder fires separately from the countdown overlay.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Voice") {
                    Picker("System Voice", selection: $voiceReminder.selectedVoiceId) {
                        Text("Default").tag("")
                        ForEach(voiceReminder.availableVoices, id: \.id) { voice in
                            Text("\(voice.name) (\(voice.language))")
                                .tag(voice.id)
                        }
                    }
                }

                Section("Test") {
                    HStack {
                        Button("Test Voice") {
                            voiceReminder.speakTest()
                        }
                        .disabled(voiceReminder.isSpeaking)

                        Button("Stop") {
                            voiceReminder.stopSpeaking()
                        }
                        .disabled(!voiceReminder.isSpeaking)

                        if voiceReminder.isSpeaking {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Actions

    private func loadSettings() {
        selectedProvider = calendarManager.activeProviderType

        graphClientId = calendarManager.graphCalendarProvider.clientId
        volume = audioManager.volume
        selectedCalendarIDs = calendarManager.selectedCalendarIDs
    }

    private func loadCalendars() async {
        do {
            availableCalendars = try await calendarManager.activeProvider.availableCalendars()
        } catch {
            availableCalendars = []
        }
    }

    private func signInGraph() async {
        isSigningIn = true
        graphAuthMessage = nil

        // Listen for device code notification
        let observer = NotificationCenter.default.addObserver(
            forName: .graphDeviceCodeReceived,
            object: nil,
            queue: .main
        ) { notification in
            if let message = notification.userInfo?["message"] as? String {
                graphAuthMessage = message
            }
        }

        do {
            let success = try await calendarManager.graphCalendarProvider.requestAccess()
            calendarManager.isAuthorized = success
            graphAuthMessage = success ? "✅ Successfully signed in!" : "Sign-in failed."
        } catch {
            graphAuthMessage = "Error: \(error.localizedDescription)"
        }

        NotificationCenter.default.removeObserver(observer)
        isSigningIn = false
    }

    private func selectMusicFile() {
        let panel = NSOpenPanel()
        panel.title = "Select Music File"
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            audioManager.saveMusicFile(url: url)
        }
    }

    private func showCountdownOverlay(for meeting: MeetingEvent) {
        calendarManager.countdownMeeting = meeting
        calendarManager.shouldShowCountdown = true
    }
}

// MARK: - Color Extension for Hex

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            r = 0; g = 0.48; b = 1.0
        }
        self.init(red: r, green: g, blue: b)
    }

    /// "#RRGGBB" for persistence. Falls back to the default highlight blue if the
    /// color can't be resolved to RGB (e.g. a dynamic system color).
    var hexString: String {
        guard let components = NSColor(self).usingColorSpace(.sRGB) else { return "#4F8CF7" }
        let r = Int((components.redComponent * 255).rounded())
        let g = Int((components.greenComponent * 255).rounded())
        let b = Int((components.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// Default highlight color for the next upcoming meeting in the dropdown.
let defaultNextMeetingHighlightHex = "#4F8CF7"

// MARK: - Sidebar sections

/// Groups for the Settings sidebar. The order here is the display order
/// in the sidebar; sections are filtered into their group by `SettingsSection.group`.
enum SettingsGroup: String, CaseIterable, Hashable {
    case sources
    case reminders
    case inMeeting
    case help

    var title: String {
        switch self {
        case .sources:   return "Sources"
        case .reminders: return "Reminders"
        case .inMeeting: return "In-Meeting"
        case .help:      return "Help"
        }
    }
}

/// One row in the Settings sidebar. Order within `allCases` is the display order
/// within each group.
enum SettingsSection: String, CaseIterable, Hashable {
    case calendar
    case quickAdd
    case calendarSync
    case countdown
    case smart
    case voice
    case sounds
    case audio
    case handoff
    case recording
    case whatsNew
    case diagnostics
    case guide
    case about

    var title: String {
        switch self {
        case .calendar:  return "Calendar"
        case .quickAdd:  return "Quick Add"
        case .calendarSync: return "Calendar Sync"
        case .countdown: return "Countdown"
        case .smart:     return "Smart"
        case .voice:     return "Voice"
        case .sounds:    return "Sounds"
        case .audio:     return "Audio"
        case .handoff:   return "Handoff"
        case .recording: return "Recording"
        case .whatsNew:  return "What's New"
        case .diagnostics: return "Diagnostics"
        case .guide:     return "Guide"
        case .about:     return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .calendar:  return "calendar"
        case .quickAdd:  return "square.and.pencil"
        case .calendarSync: return "arrow.triangle.2.circlepath"
        case .countdown: return "timer"
        case .smart:     return "brain"
        case .voice:     return "waveform"
        case .sounds:    return "speaker.wave.2"
        case .audio:     return "music.note"
        case .handoff:   return "arrow.left.arrow.right.circle"
        case .recording: return "record.circle"
        case .whatsNew:  return "sparkles"
        case .diagnostics: return "stethoscope"
        case .guide:     return "book"
        case .about:     return "info.circle"
        }
    }

    var group: SettingsGroup {
        switch self {
        case .calendar, .quickAdd, .calendarSync:        return .sources
        case .countdown, .smart, .voice, .sounds:        return .reminders
        case .audio, .handoff, .recording:               return .inMeeting
        case .whatsNew, .diagnostics, .guide, .about:    return .help
        }
    }
}
