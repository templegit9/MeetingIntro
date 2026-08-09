import SwiftUI

/// The Ticker's configuration, in a sheet off the Plugins card rather than inline.
///
/// The Plugins tab is a list of *what's available*, not a place to configure one add-on
/// at length — three inline sections of ticker options buried the other plugins below the
/// fold. Everything tunable lives here; the card keeps just the toggle, live status, and
/// the two buttons.
struct TickerSettingsSheet: View {

    @ObservedObject var config: TickerConfig
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Meetings — today's remaining meetings and their countdown", isOn: $config.showMeetings)
                    Toggle("Tasks — overdue and due soon", isOn: $config.showTasks)
                    Stepper(value: $config.taskLookaheadHours, in: 1...168) {
                        Text("Include tasks due within \(config.taskLookaheadHours)h")
                    }
                    .disabled(!config.showTasks)
                    Toggle("Cancellations — meetings cancelled but not yet acknowledged", isOn: $config.showCancellations)
                    Toggle("Status — recording in progress, auto-join armed", isOn: $config.showStatus)

                    if config.hasNoSources {
                        Label("Pick at least one source, or the ticker has nothing to show.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    SettingsSectionHeader("What rides in the ticker", info: "Only what you tick here ever appears. When nothing qualifies, the strip disappears completely — so its presence on screen is itself a signal that something needs you.")
                }

                Section {
                    HStack {
                        Text("Speed")
                        Slider(value: $config.scrollSpeed, in: TickerConfig.speedRange)
                        Text("\(Int(config.scrollSpeed)) pt/s")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    HStack {
                        Text("Width")
                        Slider(value: $config.width, in: TickerConfig.widthRange)
                        Text("\(Int(config.width)) pt")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                } header: {
                    SettingsSectionHeader("Appearance", info: "Speed is how fast the text crawls; 40 pt/s is about the pace of a TV news ticker. Width keeps the strip inside the empty middle of the menu bar — widen it and it starts to reach your app menus on the left and status icons on the right.")
                }

                Section {
                    Toggle("Hide while screen sharing", isOn: $config.hideWhileScreenSharing)
                    Toggle("Hide while I'm on a call", isOn: $config.hideWhileInCall)
                    Toggle("Hide while Focus is on", isOn: $config.hideWhileFocus)
                } header: {
                    SettingsSectionHeader("Auto-hide", info: "Screen sharing is on by default for a reason: a crawl of your task titles across a shared screen is a real leak. These use the same live signals as the reminder policy, and the strip comes back on its own once the condition clears.")
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 540)
    }
}
