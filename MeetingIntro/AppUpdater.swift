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

    private static let latestURL = URL(string: "https://api.github.com/repos/templegit9/MeetingIntro/releases/latest")!
    private static let caskRef = "templegit9/tap/meetingintro"

    private let currentVersion: String

    init() {
        self.currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private struct LatestRelease: Decodable { let tag_name: String }

    /// Fetch the latest release tag and compare against the running version.
    func check() async {
        state = .checking
        do {
            var req = URLRequest(url: Self.latestURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let code = (resp as? HTTPURLResponse)?.statusCode, code == 200 else {
                state = .failed("Couldn't reach GitHub to check for updates.")
                return
            }
            let latest = try JSONDecoder().decode(LatestRelease.self, from: data)
            let version = latest.tag_name.hasPrefix("v") ? String(latest.tag_name.dropFirst()) : latest.tag_name
            state = Self.isNewer(version, than: currentVersion) ? .available(version) : .upToDate
        } catch {
            state = .failed("Couldn't check for updates: \(error.localizedDescription)")
        }
    }

    /// Run the Homebrew upgrade, then relaunch. Only valid from `.available`.
    func update() async {
        guard case .available = state else { return }
        state = .updating
        guard let brew = Self.brewPath() else {
            state = .failed("Homebrew wasn't found. Update manually in Terminal:\nbrew upgrade --cask meetingintro")
            return
        }
        // `brew upgrade` auto-refreshes the tap first, so it sees the new cask version.
        let result = await Self.runShell("\(brew) upgrade --cask \(Self.caskRef)")
        if result.ok {
            state = .updated
            Self.relaunch()
        } else {
            let tail = String(result.output.suffix(280)).trimmingCharacters(in: .whitespacesAndNewlines)
            state = .failed("Update failed. Run this in Terminal:\nbrew upgrade --cask meetingintro\n\n\(tail)")
        }
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
