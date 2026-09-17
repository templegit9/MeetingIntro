import AppKit
import Foundation

/// Self-update for the Homebrew-cask distribution. Checks the latest GitHub release
/// against the running version and, when newer, runs `brew upgrade --cask` in-process
/// (the app isn't sandboxed, so it can spawn brew) and relaunches. Falls back to a
/// clear manual command if Homebrew isn't found or the upgrade fails.
@MainActor
final class AppUpdater: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)   // latest version string, e.g. "2.8.0"
        case updating
        case updated
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// We query the releases LIST (not /releases/latest) and pick the highest semver —
    /// /releases/latest lags behind on GitHub's CDN and depends on a "latest" pointer
    /// that can be wrong. per_page=30 comfortably covers our release cadence.
    private static let listURL = URL(string: "https://api.github.com/repos/templegit9/MeetingIntro/releases?per_page=30")!
    private static let caskRef = "templegit9/tap/meetingintro"
    static let releasesPage = "https://github.com/templegit9/MeetingIntro/releases/latest"

    /// Ephemeral session = no persistent URL cache. GitHub sends `max-age=60`, so a
    /// shared/cached session can serve a stale "latest" and falsely report up-to-date
    /// right after a release. We always want a fresh read for update checks.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    private let currentVersion: String
    private var pollTimer: Timer?
    private var autoChecksStarted = false
    private var wakeObserver: NSObjectProtocol?
    static let autoCheckKey = "autoUpdateChecksEnabled"

    init() {
        self.currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// User preference: run background update checks (default on). Off → only manual checks.
    var autoCheckEnabled: Bool { UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true }

    private struct Release: Decodable { let tag_name: String; let draft: Bool; let prerelease: Bool }

    /// Start proactive checks: once now, then every 6 hours, plus on wake. Silent —
    /// background failures don't surface an error icon. Idempotent. No-op if the user
    /// disabled auto-checks.
    /// True when this build updates itself. **False for the App Store build**: an App
    /// Store app may not install software, and the sandbox couldn't spawn `brew` anyway.
    /// Updates arrive through the store, so every surface that offers one is hidden
    /// rather than left to fail at the moment someone presses it.
    static var selfUpdateAvailable: Bool {
        #if MAS
        false
        #else
        true
        #endif
    }

    func startAutoChecks() {
        guard Self.selfUpdateAvailable else { return }
        guard autoCheckEnabled, !autoChecksStarted else { return }
        autoChecksStarted = true
        Task { await checkSilently() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkSilently() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkSilently() }
        }
    }

    /// Stop background checks (timer + wake observer). Manual checks still work.
    func stopAutoChecks() {
        pollTimer?.invalidate(); pollTimer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        autoChecksStarted = false
    }

    /// Re-evaluate after the user toggles the preference: start or stop accordingly.
    func refreshAutoChecks() {
        guard Self.selfUpdateAvailable else { return }
        if autoCheckEnabled { startAutoChecks() } else { stopAutoChecks() }
    }

    /// User-initiated check — shows the spinner and surfaces failures.
    func check() async {
        guard Self.selfUpdateAvailable else { state = .idle; return }
        state = .checking
        await performCheck(silent: false)
    }

    /// Background check — never shows the spinner; on failure it leaves the prior state
    /// (so a flaky network doesn't flip a known result to an error). Won't interrupt an
    /// in-progress update.
    func checkSilently() async {
        guard Self.selfUpdateAvailable else { return }
        if case .updating = state { return }
        await performCheck(silent: true)
    }

    private func performCheck(silent: Bool) async {
        do {
            var req = URLRequest(url: Self.listURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, resp) = try await Self.session.data(for: req)
            guard let code = (resp as? HTTPURLResponse)?.statusCode, code == 200 else {
                if !silent { state = .failed("Couldn't reach GitHub to check for updates.") }
                return
            }
            let releases = try JSONDecoder().decode([Release].self, from: data)
            let newest = releases
                .filter { !$0.draft && !$0.prerelease }
                .map { $0.tag_name.hasPrefix("v") ? String($0.tag_name.dropFirst()) : $0.tag_name }
                .max { Self.isNewer($1, than: $0) } // highest semver
            if let newest, Self.isNewer(newest, than: currentVersion) {
                state = .available(newest)
            } else {
                state = .upToDate
            }
        } catch {
            if !silent { state = .failed("Couldn't check for updates: \(error.localizedDescription)") }
        }
    }

    /// Run the Homebrew upgrade, then relaunch. Only valid from `.available`.
    func update() async {
        guard Self.selfUpdateAvailable else { return }
        guard case .available(let version) = state else { return }
        state = .updating
        guard let brew = Self.brewPath() else {
            // No Homebrew at all — the download is the only route, so lead with it.
            state = .failed("Homebrew isn't installed, so this copy can't update itself.\n\nDownload \(version) from:\n\(Self.releasesPage)")
            return
        }
        // `brew upgrade` auto-refreshes the tap first, so it sees the new cask version.
        let result = await Self.runShell("\(brew) upgrade --cask \(Self.caskRef)")
        if result.ok {
            state = .updated
            Self.relaunch()
            return
        }

        let output = result.output
        let tail = String(output.suffix(280)).trimmingCharacters(in: .whitespacesAndNewlines)

        // "not installed" means Homebrew has no record of this app, which is what you
        // get when it was installed by unzipping a GitHub release rather than through
        // the cask. **No brew command can fix that** — the old copy told the user to run
        // `brew upgrade` anyway, which fails with the same error forever. Reported from a
        // 2.20.6 install trying to reach 2.20.7.
        let notAHomebrewInstall = output.localizedCaseInsensitiveContains("is not installed")
            || output.localizedCaseInsensitiveContains("No available cask")
            || output.localizedCaseInsensitiveContains("No installed keg")
        if notAHomebrewInstall {
            state = .failed("""
                This copy wasn't installed with Homebrew, so it can't update itself.

                Download \(version) directly:
                \(Self.releasesPage)

                Or switch to Homebrew so future updates are one click:
                brew install --cask \(Self.caskRef)
                """)
            return
        }

        // Homebrew had to escalate to `sudo`, which happens when the copy in
        // /Applications isn't writable by this user. We run brew through `zsh -lc` with
        // **no TTY**, so sudo has nothing to prompt on, fails with "a terminal is
        // required to read the password", and brew rolls back — the user sees
        // "Purging files for version X" and a message about askpass helpers.
        // **No in-app retry can fix this**: the password has to be typed somewhere that
        // has a terminal. Reported 2026-09-17 from a genuine cask install of 2.20.7 that
        // could not reach 2.21.0 — note this is a *different* failure from the
        // not-a-Homebrew-install case above and matches none of its markers, which is
        // why the generic message sent the user chasing the wrong problem.
        let needsPassword = output.localizedCaseInsensitiveContains("terminal is required to read the password")
            || output.localizedCaseInsensitiveContains("askpass")
            || output.localizedCaseInsensitiveContains("sudo:")
        if needsPassword {
            state = .failed("""
                This update needs your Mac password, and it can't be typed inside the app.

                Run this once in Terminal:
                brew upgrade --cask \(Self.caskRef)

                It only asks because this copy of MeetingIntro isn't owned by your user                 account. The upgrade replaces it with one that is, so updates after this                 won't ask again.
                """)
            return
        }

        // Any other failure is a real brew problem. Name the FULL cask reference — the
        // old message said `brew upgrade --cask meetingintro`, which fails for anyone
        // who hasn't tapped templegit9/tap.
        state = .failed("Update failed. Run this in Terminal:\nbrew upgrade --cask \(Self.caskRef)\n\n\(tail)")
    }

    // MARK: - Helpers

    /// Numeric semver compare ("2.10.0" > "2.9.1").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Run a shell command via a login shell (so brew's environment resolves).
    /// Reads stdout to EOF before waiting on exit to avoid a full-pipe deadlock.
    static func runShell(_ command: String) async -> (ok: Bool, output: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                proc.arguments = ["-lc", command]
                var env = ProcessInfo.processInfo.environment
                env["HOMEBREW_NO_ANALYTICS"] = "1"
                env["HOMEBREW_NO_ENV_HINTS"] = "1"
                proc.environment = env
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                do {
                    try proc.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    cont.resume(returning: (proc.terminationStatus == 0, String(data: data, encoding: .utf8) ?? ""))
                } catch {
                    cont.resume(returning: (false, error.localizedDescription))
                }
            }
        }
    }

    /// Relaunch the (now-upgraded) bundle and quit this instance.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }
}
