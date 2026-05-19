import SwiftUI

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
                        ForEach(SettingsSection.allCases.filter { $0.group == group }, id: \.self) { section in
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
                case .countdown: countdownTab
                case .smart:     smartTab
                case .voice:     voiceTab
                case .sounds:    soundsTab
                case .audio:     audioTab
                case .handoff:   handoffTab
                case .guide:     guideTab
                case .about:     aboutTab
                }
            }
            .navigationTitle(selectedSection.title)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 600)
        .onAppear { loadSettings() }
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

            if let message = graphAuthMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
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
                        organizerName: "Alice Wong"
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

            Section("Live Signals") {
                signalRow(name: "In a call",
                          isOn: contextMonitor.snapshot.isInActiveCall,
                          detail: contextMonitor.snapshot.isConferenceAppActive
                            ? "video-conf app active"
                            : (contextMonitor.snapshot.isMicrophoneInUseElsewhere ? "mic in use" : "no signal"))
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

                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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

                Button("Request Feature / Report Bug") {
                    if let url = URL(string: "https://forms.gle/PLACEHOLDER_LINK") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            Spacer()

            Text("© \(Calendar.current.component(.year, from: Date())) TempleGit. All rights reserved.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}

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
    case countdown
    case smart
    case voice
    case sounds
    case audio
    case handoff
    case guide
    case about

    var title: String {
        switch self {
        case .calendar:  return "Calendar"
        case .countdown: return "Countdown"
        case .smart:     return "Smart"
        case .voice:     return "Voice"
        case .sounds:    return "Sounds"
        case .audio:     return "Audio"
        case .handoff:   return "Handoff"
        case .guide:     return "Guide"
        case .about:     return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .calendar:  return "calendar"
        case .countdown: return "timer"
        case .smart:     return "brain"
        case .voice:     return "waveform"
        case .sounds:    return "speaker.wave.2"
        case .audio:     return "music.note"
        case .handoff:   return "arrow.left.arrow.right.circle"
        case .guide:     return "book"
        case .about:     return "info.circle"
        }
    }

    var group: SettingsGroup {
        switch self {
        case .calendar:                                  return .sources
        case .countdown, .smart, .voice, .sounds:        return .reminders
        case .audio, .handoff:                           return .inMeeting
        case .guide, .about:                             return .help
        }
    }
}
