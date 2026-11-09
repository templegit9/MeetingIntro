#if !MAS
import Foundation

/// Headless setup checks use isolated preferences and never approve a download.
@MainActor enum MarginLocalAIGuards {
    /// Developer-only, explicitly invoked end-to-end candidate installation. Uses isolated defaults.
    static func managedCandidate(manifestPath: String, rootPath: String, reportPath: String) async -> Bool {
        let started = ISO8601DateFormatter().string(from: Date())
        let suite = "margin-managed-candidate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var report: [String: Any] = ["started": started, "passed": false]
        do {
            let manifest = try JSONDecoder().decode(MarginAIManifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
            try manifest.validate()
            let config = MarginConfig(defaults: defaults)
            config.baseURL = "http://127.0.0.1:1"; config.model = manifest.model; config.aiSetupApproved = true
            let setup = MarginLocalAI(config: config, root: URL(fileURLWithPath: rootPath), manifest: manifest)
            defer { setup.stop() }
            let ready = await setup.ensureReady()
            report["ready"] = ready; report["detail"] = setup.detail
            guard ready else { throw ToolArgumentError(message: setup.detail) }
            report["endpoint"] = config.baseURL; report["model"] = config.model
            let tool: [String: Any] = ["type": "function", "function": ["name": "list_capabilities", "description": "List supported capabilities", "parameters": ["type": "object", "properties": [:], "required": []]]]
            let response = try await OllamaToolClient.chat(baseURL: config.baseURL, model: config.model, messages: [["role": "system", "content": "Call list_capabilities when asked what you can do."], ["role": "user", "content": "What can you do?"]], tools: [tool])
            report["tool_reply"] = String(describing: response)
            report["passed"] = response.toolCalls.count == 1 && response.toolCalls.first?.name == "list_capabilities"
        } catch { report["error"] = error.localizedDescription }
        report["finished"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        }
        print(report)
        return report["passed"] as? Bool == true
    }

    static func run() async -> Bool {
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ value: Bool) { checks.append((name, value)); print("\(value ? "PASS" : "FAIL") · \(name)") }
        do {
            let manifest = try MarginAIManifest.load()
            check("Pinned manifest is bundled", manifest.runtimeSHA256.count == 64 && manifest.modelSHA256.count == 64 && manifest.modelBytes > 0)
            let source = Bundle.main.url(forResource: "MarginLocalAI", withExtension: "json")!
            var candidate = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as! [String: Any]
            candidate["model"] = "margin-lora-pilot:final"
            candidate["modelGGUFURL"] = "https://huggingface.co/olluyeancah/margin-pilot1-gguf/resolve/test/model.gguf"
            candidate["modelGGUFSHA256"] = String(repeating: "a", count: 64)
            let pinned = try JSONDecoder().decode(MarginAIManifest.self, from: JSONSerialization.data(withJSONObject: candidate))
            try pinned.validate()
            check("GGUF model cache path follows the selected model", pinned.installedManifestPath == "models/manifests/registry.ollama.ai/library/margin-lora-pilot/final")
            for (key, value) in [("model", "../../outside:latest"), ("modelGGUFURL", "http://example.com/model.gguf"), ("modelGGUFSHA256", "bad") ] {
                var invalid = candidate; invalid[key] = value
                let decoded = try JSONDecoder().decode(MarginAIManifest.self, from: JSONSerialization.data(withJSONObject: invalid))
                do { try decoded.validate(); check("Invalid GGUF \(key) rejected", false) }
                catch { check("Invalid GGUF \(key) rejected", true) }
            }
            check("Intel compatibility explained", MarginLocalAI.compatibility(memory: 32 << 30, appleSilicon: false, available: 100_000_000_000, manifest: manifest)?.contains("Apple silicon") == true)
            check("Insufficient memory explained", MarginLocalAI.compatibility(memory: 8 << 30, appleSilicon: true, available: 100_000_000_000, manifest: manifest)?.contains("16 GB") == true)
            check("Insufficient disk explained", MarginLocalAI.compatibility(memory: 32 << 30, appleSilicon: true, available: 1, manifest: manifest)?.contains("\(Int(ceil(Double(manifest.minimumFreeBytes) / 1_000_000_000))) GB") == true)
            check("Supported Mac accepted", MarginLocalAI.compatibility(memory: 16 << 30, appleSilicon: true, available: manifest.minimumFreeBytes, manifest: manifest) == nil)
            check("Checksum detects changed bytes", MarginLocalAI.digest(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" && MarginLocalAI.digest(Data("abd".utf8)) != MarginLocalAI.digest(Data("abc".utf8)))
            var progress = MarginModelPullProgress(total: 100)
            try progress.consume(#"{"digest":"a","completed":25}"#)
            try progress.consume(#"{"digest":"a","completed":40}"#)
            try progress.consume(#"{"digest":"b","completed":10}"#)
            check("Repeated layer updates are not double-counted", progress.count == 50 && progress.fraction == 0.5)
            try progress.consume(#"{"digest":"a","completed":-50}"#)
            check("Negative progress is bounded", progress.count == 10)
            try progress.consume(#"{"digest":"a","completed":9223372036854775807}"#)
            check("Oversized progress is bounded", progress.count == 100 && progress.fraction == 1)
            do { try progress.finish(); check("Closed stream requires success", false) } catch { check("Closed stream requires success", true) }
            do { try progress.consume(#"{"error":"network failure"}"#); check("Provider error fails setup", false) } catch { check("Provider error fails setup", true) }
            do { try progress.consume("broken"); check("Malformed update fails setup", false) } catch { check("Malformed update fails setup", true) }
            try progress.consume(#"{"status":"success"}"#); try progress.finish()
            check("Terminal success accepted", true)
            let suite = "margin-setup-test-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let config = MarginConfig(defaults: defaults)
            check("First enable requires introduction and download approval", !config.isEnabled && !config.introductionSeen && !config.aiSetupApproved)
            defaults.set(true, forKey: MarginConfig.enabledKey)
            let legacy = MarginConfig(defaults: defaults)
            check("Legacy enabled users skip introduction without granting downloads", legacy.introductionSeen && !legacy.aiSetupApproved)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            config.baseURL = "http://127.0.0.1:1"
            let setup = MarginLocalAI(config: config, root: root)
            _ = await setup.ensureReady()
            check("Unavailable AI cannot download without approval", setup.state == .needsApproval && !FileManager.default.fileExists(atPath: root.path))
            setup.start(); setup.cancel()
            _ = await setup.ensureReady()
            check("Cancelled setup does not write files", !setup.isReady && !FileManager.default.fileExists(atPath: root.path))
            config.aiSetupApproved = true; config.introductionSeen = true
            let reloaded = MarginConfig(defaults: defaults)
            check("Approval survives app updates", reloaded.aiSetupApproved && reloaded.introductionSeen)
        } catch { check("Setup guard execution: \(error.localizedDescription)", false) }
        print("SETUP GUARDS: \(checks.filter(\.1).count)/\(checks.count)")
        return checks.allSatisfy(\.1)
    }
}
#endif
