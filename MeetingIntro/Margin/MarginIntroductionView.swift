import SwiftUI

/// Option A: consent precedes setup; dismissing this view never enables the plugin.
struct MarginIntroductionView: View {
    let notNow: () -> Void
    let prepare: () -> Void
    @State private var expanded = false
    private var size: String { (try? MarginAIManifest.load().downloadDescription) ?? "A one-time download" }

    private var requirements: String {
        guard let manifest = try? MarginAIManifest.load() else { return "Margin checks memory and storage before downloading." }
        let memory = Int(ceil(Double(manifest.minimumMemoryBytes) / 1_073_741_824))
        let storage = Int(ceil(Double(manifest.minimumFreeBytes) / 1_000_000_000))
        return "Automatic setup requires Apple silicon, at least \(memory) GB of memory and \(storage) GB of free storage. An existing working installation can be reused."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "book.closed.fill").font(.system(size: 34)).foregroundStyle(MarginTheme.cloth)
            Text("Meet Margin").font(.system(size: 27, weight: .semibold, design: .serif))
            Text("A notebook that helps with your files, tasks and calendar.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                Text(size).font(.title3.bold())
                Text("One-time download to prepare AI on this Mac.").foregroundStyle(.secondary)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(MarginTheme.cloth.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 10) {
                Label("No extra app or AI account to set up", systemImage: "checkmark")
                Label("AI conversations run on your Mac", systemImage: "desktopcomputer")
                Label("Review changes before they happen", systemImage: "checkmark.circle")
            }.font(.callout)
            DisclosureGroup("What else should I know?", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Setup time depends on your connection. Margin checks memory and storage first. You can cancel and retry later. Installed models are kept.")
                    Text(requirements)
                    Text("Web research sends search queries online. Connected calendar actions use your calendar service. You choose which folders and calendars Margin can access.")
                    Text("Memory and voice learn from your messages. You can inspect, edit or pause learning in Margin’s settings.")
                }.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            HStack {
                Spacer()
                Button("Not now", action: notNow).keyboardShortcut(.cancelAction)
                Button("Prepare Margin", action: prepare).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(MarginTheme.cloth)
            }.padding(.top, 4)
        }.padding(28).frame(width: 440).interactiveDismissDisabled()
    }
}

struct MarginAISetupStatus: View {
    @ObservedObject var config: MarginConfig
    @ObservedObject var setup: MarginLocalAI
    @State private var showIntroduction = false
    private var requirements: String {
        guard let manifest = try? MarginAIManifest.load() else { return "Margin checks memory and storage before downloading." }
        let memory = Int(ceil(Double(manifest.minimumMemoryBytes) / 1_073_741_824))
        let storage = Int(ceil(Double(manifest.minimumFreeBytes) / 1_000_000_000))
        return "Automatic setup requires Apple silicon, at least \(memory) GB of memory and \(storage) GB of free storage. An existing working installation can be reused."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(setup.title).font(.headline)
            if !setup.detail.isEmpty { Text(setup.detail).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if setup.isPreparing {
                if let fraction = setup.fraction { ProgressView(value: fraction) }
                else { ProgressView().controlSize(.small) }
                Button("Cancel setup") { setup.cancel() }
            } else if !setup.isReady {
                Button(config.aiSetupApproved ? "Retry setup" : "Prepare Margin…") {
                    if config.aiSetupApproved { config.isEnabled = true; setup.retry() }
                    else { showIntroduction = true }
                }
            }
        }.sheet(isPresented: $showIntroduction) {
            MarginIntroductionView(notNow: { showIntroduction = false }, prepare: {
                config.aiSetupApproved = true; config.introductionSeen = true
                config.isEnabled = true; showIntroduction = false; setup.start()
            })
        }
    }
}
