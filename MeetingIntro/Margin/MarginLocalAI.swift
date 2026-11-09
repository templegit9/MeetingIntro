import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation

struct MarginAIManifest: Decodable {
    let runtimeVersion: String, runtimeURL: String, runtimeSHA256: String
    let runtimeBytes: Int64
    let model: String, modelSHA256: String
    let modelManifestURL: String?
    let modelGGUFURL: String?, modelGGUFSHA256: String?
    let modelBytes: Int64, minimumMemoryBytes: UInt64, minimumFreeBytes: Int64
    static func load() throws -> Self {
        guard let url = Bundle.main.url(forResource: "MarginLocalAI", withExtension: "json") else {
            throw ToolArgumentError(message: "Margin's setup files are missing. Please reinstall MeetingIntro.")
        }
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try manifest.validate()
        return manifest
    }
    var installedManifestPath: String {
        // Built-in managed packages use a local library name, never an arbitrary path.
        let parts = model.split(separator: ":", maxSplits: 1).map(String.init)
        return "models/manifests/registry.ollama.ai/library/" + parts[0] + "/" + (parts.count == 2 ? parts[1] : "latest")
    }
    func validate() throws {
        guard model.range(of: #"^[a-z0-9][a-z0-9._-]*:[a-zA-Z0-9._-]+$"#, options: .regularExpression) != nil,
              modelSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw ToolArgumentError(message: "Margin's model configuration is invalid.")
        }
        if let source = modelGGUFURL {
            guard URL(string: source)?.scheme == "https", modelBytes > 0,
                  modelGGUFSHA256?.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
                throw ToolArgumentError(message: "Margin's model download is not configured.")
            }
        } else if URL(string: modelManifestURL ?? "")?.scheme != "https" {
            throw ToolArgumentError(message: "Margin's model download is not configured.")
        }
    }
    var downloadDescription: String { "About \(Int(ceil(Double(modelBytes + runtimeBytes) / 1_000_000_000))) GB" }
}

/// All installation files are private app support data. This never changes a user's existing engine.
@MainActor final class MarginLocalAI: ObservableObject {
    enum State: Equatable { case idle, checking, downloadingEngine, installing, starting, downloadingModel, warming, ready, cancelled, needsApproval, failed(String) }
    @Published private(set) var state: State = .idle
    @Published private(set) var fraction: Double?
    @Published private(set) var detail = ""
    private let config: MarginConfig
    private let root: URL
    private let manifestOverride: MarginAIManifest?
    private var task: Task<Void, Never>?
    private var process: Process?
    private var managedURL: String?
    private var terminationObserver: AnyCancellable?
    private var download: MarginEngineDownload?
    var isReady: Bool { state == .ready }
    var isPreparing: Bool { [.checking, .downloadingEngine, .installing, .starting, .downloadingModel, .warming].contains(state) }
    var title: String {
        switch state {
        case .idle: return "Prepare Margin"
        case .checking: return "Checking your Mac…"
        case .downloadingEngine: return "Downloading Margin’s engine…"
        case .installing: return "Preparing the engine…"
        case .starting: return "Starting local AI…"
        case .downloadingModel: return "Downloading local AI…"
        case .warming: return "Getting Margin ready…"
        case .ready: return "Ready on this Mac"
        case .cancelled: return "Setup paused"
        case .needsApproval: return "A little setup first"
        case .failed: return "Setup needs attention"
        }
    }
    init(config: MarginConfig, root: URL? = nil, manifest: MarginAIManifest? = nil) {
        self.manifestOverride = manifest
        self.config = config
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingIntro/Margin/LocalAI", isDirectory: true)
        terminationObserver = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.stop() }
    }
    func start() {
        guard task == nil, !isReady else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do { try await prepare() }
            catch is CancellationError { state = .cancelled; detail = "You can retry when you're ready. Completed model layers are kept." }
            catch {
                if Task.isCancelled { state = .cancelled; detail = "Setup paused. Retry when you’re ready." }
                else { state = .failed(error.localizedDescription); detail = error.localizedDescription }
                process?.terminate(); process = nil; managedURL = nil
            }
            fraction = nil; task = nil
        }
    }
    func ensureReady() async -> Bool {
        if isReady, case .success = await OllamaToolClient.status(baseURL: config.baseURL, model: config.model) { return !Task.isCancelled }
        if isReady { state = .idle }
        start(); await task?.value
        return isReady && !Task.isCancelled
    }
    func cancel() { task?.cancel(); download?.cancel(); process?.terminate(); process = nil; managedURL = nil }
    func stop() { cancel(); if task == nil { state = .idle } }
    func retry() { guard task == nil else { return }; state = .idle; start() }
    static func compatibility(memory: UInt64, appleSilicon: Bool, available: Int64, manifest: MarginAIManifest) -> String? {
        if !appleSilicon { return "Automatic local AI currently requires a Mac with Apple silicon." }
        if memory < manifest.minimumMemoryBytes { return "This version of Margin needs a Mac with at least 16 GB of memory for local AI." }
        if available < manifest.minimumFreeBytes { return "Free at least \(Int(ceil(Double(manifest.minimumFreeBytes) / 1_000_000_000))) GB of storage, then retry setup." }
        return nil
    }
    private func prepare() async throws {
        state = .checking; detail = "Looking for AI already available on this Mac."; fraction = nil
        // Existing user-configured services keep their endpoint, model, files and lifecycle.
        if case .success = await OllamaToolClient.status(baseURL: config.baseURL, model: config.model) {
            try Task.checkCancellation(); state = .ready; detail = "Using your existing local AI. No download needed."; return
        }
        try Task.checkCancellation()
        guard config.aiSetupApproved else { state = .needsApproval; detail = "Prepare local AI once to use Margin. No extra app or account is needed."; return }
        let manifest = try manifestOverride ?? MarginAIManifest.load()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let available = (try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])).volumeAvailableCapacityForImportantUsage ?? 0
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        // Existing managed models do not need another full model's worth of free space.
        let cachedManifest = try? Data(contentsOf: root.appendingPathComponent(manifest.installedManifestPath))
        let hasModel = cachedManifest.map { Self.digest($0) == manifest.modelSHA256 } ?? false
        let verifiedBlob: Bool
        if let expected = manifest.modelGGUFSHA256 {
            let blob = root.appendingPathComponent("models/blobs/sha256-" + expected)
            verifiedBlob = await Task.detached { (try? Self.fileDigest(blob)) == expected }.value
        } else { verifiedBlob = false }
        let remainingReserve = hasModel ? Int64(1_000_000_000) : verifiedBlob ? max(1_000_000_000, manifest.minimumFreeBytes - 2 * manifest.modelBytes) : manifest.minimumFreeBytes
        let requiredFree = available >= remainingReserve ? max(available, manifest.minimumFreeBytes) : available
        if let problem = Self.compatibility(memory: ProcessInfo.processInfo.physicalMemory, appleSilicon: appleSilicon, available: requiredFree, manifest: manifest) {
            throw ToolArgumentError(message: problem)
        }
        let engine = try await installEngine(manifest)
        try Task.checkCancellation()
        let endpoint = try await startEngine(engine)
        if !(try await modelInstalled(endpoint, manifest: manifest)) {
            if manifest.modelGGUFURL != nil {
                try await importGGUF(endpoint, engine: engine, manifest: manifest)
            } else {
            // Fail closed if the upstream tag changed; a release must qualify and pin its replacement.
            var check = URLRequest(url: URL(string: manifest.modelManifestURL ?? "")!)
            check.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: check)
            guard (response as? HTTPURLResponse)?.statusCode == 200, Self.digest(data) == manifest.modelSHA256 else {
                throw ToolArgumentError(message: "The local AI download has changed. Update MeetingIntro before continuing setup.")
            }
            try await pullModel(endpoint, manifest: manifest)
            }
        }
        try Task.checkCancellation()
        guard try await modelInstalled(endpoint, manifest: manifest) else {
            throw ToolArgumentError(message: "The AI download could not be verified. Retry setup.")
        }
        state = .warming; detail = "The download is complete. Loading AI for the first time…"; fraction = nil
        var warm = URLRequest(url: URL(string: endpoint + "/api/generate")!)
        warm.httpMethod = "POST"; warm.timeoutInterval = 180
        warm.setValue("application/json", forHTTPHeaderField: "Content-Type")
        warm.httpBody = try JSONSerialization.data(withJSONObject: ["model": manifest.model, "prompt": "", "stream": false, "keep_alive": "5m"])
        let (data, response) = try await URLSession.shared.data(for: warm)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any], body["done"] as? Bool == true, body["error"] == nil else {
            throw ToolArgumentError(message: "Local AI could not start. Close memory-heavy apps and retry. Your download is kept.")
        }
        try Task.checkCancellation()
        config.baseURL = endpoint; config.model = manifest.model
        state = .ready; detail = "AI is ready on this Mac. Your model will be kept across app updates."
    }
    nonisolated static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    nonisolated static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func installEngine(_ manifest: MarginAIManifest) async throws -> URL {
        let destination = root.appendingPathComponent("engine-" + manifest.runtimeVersion, isDirectory: true)
        let executable = destination.appendingPathComponent("ollama")
        let receipt = destination.appendingPathComponent("margin-runtime-receipt")
        if FileManager.default.isExecutableFile(atPath: executable.path),
           (try? String(contentsOf: receipt, encoding: .utf8)) == manifest.runtimeSHA256 { return executable }
        state = .downloadingEngine; detail = "One-time setup · engine download"; fraction = 0
        let archive = root.appendingPathComponent("engine-download-\(UUID().uuidString).tgz")
        let staging = root.appendingPathComponent("engine-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archive); try? FileManager.default.removeItem(at: staging) }
        let transfer = MarginEngineDownload(); download = transfer
        try await transfer.fetch(URL(string: manifest.runtimeURL)!, to: archive, expectedBytes: manifest.runtimeBytes) { [weak self] completed, total in
            Task { @MainActor in
                guard let self, self.state == .downloadingEngine else { return }
                self.fraction = total > 0 ? min(Double(completed) / Double(total), 1) : nil
                self.detail = ByteCountFormatter.string(fromByteCount: completed, countStyle: .file) + " downloaded"
            }
        }
        download = nil
        try Task.checkCancellation()
        state = .installing; fraction = nil; detail = "Verifying the engine download…"
        let hash = try await Task.detached { try Self.fileDigest(archive) }.value
        guard hash == manifest.runtimeSHA256 else { throw ToolArgumentError(message: "The engine download failed verification. Retry to download a fresh copy.") }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try await Self.command("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path])
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: staging.appendingPathComponent("ollama").path) else {
            throw ToolArgumentError(message: "The engine download was incomplete. Retry setup.")
        }
        // Archive bytes are pinned; extracted links must still remain inside this app-owned directory.
        if let entries = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: nil) {
            for case let url as URL in entries {
                let resolved = url.resolvingSymlinksInPath().path
                guard resolved.hasPrefix(staging.resolvingSymlinksInPath().path + "/") else {
                    throw ToolArgumentError(message: "The engine contains an invalid file link. Setup stopped.")
                }
            }
        }
        try manifest.runtimeSHA256.write(to: staging.appendingPathComponent("margin-runtime-receipt"), atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: destination.path) {
            // Preserve a broken installation for diagnosis rather than merging old and new binaries.
            try FileManager.default.moveItem(at: destination, to: root.appendingPathComponent("old-engine-\(UUID().uuidString)"))
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        return executable
    }
    private func startEngine(_ executable: URL) async throws -> String {
        if let process, process.isRunning, let managedURL { return managedURL }
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "MarginRuntimeSupervisor") else {
            throw ToolArgumentError(message: "Margin's startup helper is missing. Please reinstall MeetingIntro.")
        }
        state = .starting; detail = "Starting the engine privately on this Mac…"
        let port = try Self.availablePort()
        let endpoint = "http://127.0.0.1:\(port)"
        let child = Process(); child.executableURL = helper; child.arguments = [executable.path]
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = "127.0.0.1:\(port)"
        environment["OLLAMA_MODELS"] = root.appendingPathComponent("models").path
        environment["OLLAMA_NO_CLOUD"] = "1"; environment["OLLAMA_NUM_PARALLEL"] = "1"
        environment["OLLAMA_MAX_LOADED_MODELS"] = "1"; environment["OLLAMA_KEEP_ALIVE"] = "5m"
        child.environment = environment; child.currentDirectoryURL = executable.deletingLastPathComponent()
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] child in
            Task { @MainActor in
                guard let self, self.process === child else { return }
                self.process = nil; self.managedURL = nil
                if self.state == .ready {
                    self.state = .failed("Local AI stopped. Retry to restart it.")
                    self.detail = "Local AI stopped. Retry to restart it. Your download is kept."
                }
            }
        }
        try child.run(); process = child; managedURL = endpoint
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 500_000_000); try Task.checkCancellation()
            guard child.isRunning else { throw ToolArgumentError(message: "The local engine stopped. Retry setup.") }
            var request = URLRequest(url: URL(string: endpoint + "/api/version")!); request.timeoutInterval = 1
            if let (_, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200, child.isRunning { return endpoint }
        }
        child.terminate(); throw ToolArgumentError(message: "Local AI took too long to start. Retry setup.")
    }
    nonisolated static func availablePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw URLError(.cannotConnectToHost) }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw URLError(.cannotConnectToHost) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard result == 0 else { throw URLError(.cannotConnectToHost) }
        return UInt16(bigEndian: address.sin_port)
    }
    private func modelInstalled(_ endpoint: String, manifest: MarginAIManifest) async throws -> Bool {
        var request = URLRequest(url: URL(string: endpoint + "/api/tags")!); request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (body?["models"] as? [[String: Any]] ?? []).contains { ($0["name"] as? String) == manifest.model && ($0["digest"] as? String)?.replacingOccurrences(of: "sha256:", with: "") == manifest.modelSHA256 }
    }
    private func importGGUF(_ endpoint: String, engine: URL, manifest: MarginAIManifest) async throws {
        try manifest.validate()
        guard let source = manifest.modelGGUFURL, let expected = manifest.modelGGUFSHA256 else {
            throw ToolArgumentError(message: "Margin's model download is not configured.")
        }
        state = .downloadingModel; detail = "One-time download · \(manifest.downloadDescription)"; fraction = 0
        let blob = root.appendingPathComponent("models/blobs/sha256-" + expected)
        let cachedBlob = (try? Self.fileDigest(blob)) == expected
        let file = cachedBlob ? blob : root.appendingPathComponent("model-" + expected + ".gguf")
        var imported = false
        let recipe = root.appendingPathComponent("Modelfile-\(UUID().uuidString)")
        defer { if imported && !cachedBlob { try? FileManager.default.removeItem(at: file) }; try? FileManager.default.removeItem(at: recipe) }
        let transfer = MarginEngineDownload(); download = transfer
        defer { download = nil }
        if (try? Self.fileDigest(file)) != expected {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try await transfer.fetch(URL(string: source)!, to: file, expectedBytes: manifest.modelBytes) { [weak self] count, total in
            Task { @MainActor in
                guard let self, self.state == .downloadingModel else { return }
                self.fraction = total > 0 ? min(Double(count) / Double(total), 1) : nil
                self.detail = ByteCountFormatter.string(fromByteCount: count, countStyle: .file) + " downloaded"
            }
        }
        try Task.checkCancellation()
        }
        state = .installing; fraction = nil; detail = "Verifying Margin’s model…"
        let digest = try await Task.detached { try Self.fileDigest(file) }.value
        guard digest == expected else { throw ToolArgumentError(message: "The AI download failed verification. Retry setup.") }
        try Task.checkCancellation()
        // Process arguments and a generated recipe avoid shell evaluation of paths.
        try ("FROM \"" + file.path + "\"\nPARAMETER num_ctx 8192\nPARAMETER temperature 0\n").write(to: recipe, atomically: true, encoding: .utf8)
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = endpoint
        environment["OLLAMA_MODELS"] = root.appendingPathComponent("models").path
        environment["OLLAMA_NO_CLOUD"] = "1"
        try await Self.command(engine.path, ["create", manifest.model, "-f", recipe.path], environment: environment, logURL: root.appendingPathComponent("model-import.log"))
        imported = true
        try Task.checkCancellation()
    }

    private func pullModel(_ endpoint: String, manifest: MarginAIManifest) async throws {
        state = .downloadingModel; fraction = 0; detail = "One-time download · \(manifest.downloadDescription)"
        var request = URLRequest(url: URL(string: endpoint + "/api/pull")!)
        request.httpMethod = "POST"; request.timeoutInterval = 3600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": manifest.model, "stream": true])
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ToolArgumentError(message: "The AI download could not start. Check your connection and retry.") }
        var progress = MarginModelPullProgress(total: manifest.modelBytes)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            try progress.consume(line)
            fraction = progress.fraction
            detail = "\(ByteCountFormatter.string(fromByteCount: progress.count, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: manifest.modelBytes, countStyle: .file)) · You can cancel and retry later."
        }
        try progress.finish()
    }

    nonisolated static func command(_ path: String, _ arguments: [String], environment: [String: String]? = nil, logURL: URL? = nil) async throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath: path); child.arguments = arguments
        if let environment { child.environment = environment }
        var log: FileHandle?
        if let logURL {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            log = try FileHandle(forWritingTo: logURL)
        }
        defer { try? log?.close() }
        child.standardOutput = log ?? FileHandle.nullDevice; child.standardError = log ?? FileHandle.nullDevice
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                child.terminationHandler = { process in
                    if process.terminationStatus == 0 { continuation.resume() }
                    else { continuation.resume(throwing: ToolArgumentError(message: "Could not prepare the local engine. Retry setup.")) }
                }
                do { try Task.checkCancellation(); try child.run() } catch { child.terminationHandler = nil; continuation.resume(throwing: error) }
            }
        }, onCancel: { if child.isRunning { child.terminate() } })
    }
}

/// A bounded, cancellable runtime download, with delegate progress rather than buffering 160 MB in RAM.
final class MarginEngineDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var destination: URL?
    private var expectedBytes: Int64 = 0
    private var progress: (@Sendable (Int64, Int64) -> Void)?
    private var cancelled = false
    func fetch(_ url: URL, to destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock(); defer { lock.unlock() }
                if cancelled { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation; self.destination = destination; self.expectedBytes = expectedBytes; self.progress = progress
                let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 1800
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session; let task = session.downloadTask(with: url); self.task = task; task.resume()
            }
        }, onCancel: { self.cancel() })
    }
    func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    private func finish(_ result: Result<Void, Error>) {
        lock.lock(); let continuation = continuation; self.continuation = nil; let session = session; self.session = nil; lock.unlock()
        continuation?.resume(with: result); session?.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expectedBytes { downloadTask.cancel(); finish(.failure(ToolArgumentError(message: "The engine download size did not match. Setup stopped."))); return }
        progress?(totalBytesWritten, expectedBytes)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let destination, (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { finish(.failure(URLError(.badServerResponse))); return }
        do {
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard Int64(size) == expectedBytes else { throw URLError(.cannotDecodeContentData) }
            try FileManager.default.moveItem(at: location, to: destination); finish(.success(()))
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error)) }
    }
}

/// Pull streams may repeat layer updates. Count the latest bounded value for each layer,
/// and require the terminal success record before treating a closed connection as done.
struct MarginModelPullProgress {
    let total: Int64
    private var completed: [String: Int64] = [:]
    private var success = false
    init(total: Int64) { self.total = total }
    var count: Int64 { completed.values.reduce(0) { min($0 + $1, max(1, total)) } }
    var fraction: Double { Double(count) / Double(max(1, total)) }
    mutating func consume(_ line: String) throws {
        guard line.utf8.count < 65_536, let data = line.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolArgumentError(message: "The AI download returned an unreadable update. Retry setup.")
        }
        if value["error"] != nil { throw ToolArgumentError(message: "The AI download stopped. Check your connection and free storage, then retry. Completed layers are kept.") }
        if let digest = value["digest"] as? String, let amount = value["completed"] as? Int64 {
            guard completed[digest] != nil || completed.count < 256 else { throw URLError(.badServerResponse) }
            completed[digest] = max(0, min(amount, max(1, total)))
        }
        if value["status"] as? String == "success" { success = true }
    }
    func finish() throws {
        guard success else { throw ToolArgumentError(message: "The AI download was interrupted. Retry to continue setup.") }
    }
}
