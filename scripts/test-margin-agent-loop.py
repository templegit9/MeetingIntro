"""Replay the production orchestration with scripted model replies; no inference or provider writes."""
import pathlib,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
loop=(root/'MeetingIntro/Margin/AgentTool.swift').read_text().split('@MainActor\nenum MarginToolLoop')[1]
action=(root/'MeetingIntro/Margin/ProposedAction.swift').read_text()
stubs='''import Foundation
struct ToolArgumentError: LocalizedError { let message: String; var errorDescription: String? { message } }
struct PageSource { let id: String; let title: String; let url: URL }
enum OllamaToolClient {
 struct ToolCall { let name: String; let arguments: [String: Any] }
 struct Reply { var text: String; var toolCalls: [ToolCall] }
}
'''
checks='''
@main struct Checks {
 @MainActor static func main() async throws {
  var count = 0
  func check(_ condition: Bool, _ label: String) { precondition(condition, label); count += 1; print("PASS \\(label)") }
  func reply(_ name: String, _ args: [String: Any] = [:]) -> OllamaToolClient.Reply { .init(text: "", toolCalls: [.init(name: name, arguments: args)]) }
  var calls = 0; var prepared: [String] = []; var ran = false; var messages: [[String: Any]] = []
  try await MarginToolLoop.run(messages: [], request: { transcript in
   messages = transcript; calls += 1
   return reply(calls == 1 ? "find" : calls == 2 ? "read" : "move")
  }, prepare: { call in
   prepared.append(call.name)
   if call.name == "move" { return ProposedAction(kind: .change, title: "Move preview", run: { _ in ran = true; return "Moved" }) }
   return .answer("Evidence", ["/granted/project/diagram.png"])
  }, present: { _ in }, answer: { _ in })
  check(prepared == ["find", "read", "move"], "read -> inspect -> read -> write preview")
  check(!ran, "write never executes without confirmation")
  check(messages.filter { $0["role"] as? String == "tool" }.count == 2, "both read observations reach next model call")
  calls = 0; var recovered = false
  try await MarginToolLoop.run(messages: [], request: { transcript in
   calls += 1
   if calls == 2 { recovered = (transcript.last?["content"] as? String)?.contains("missing folder") == true }
   return calls < 3 ? reply("find", ["folder": calls == 1 ? "bad" : "good"]) : .init(text: "Found it", toolCalls: [])
  }, prepare: { call in
   if call.arguments["folder"] as? String == "bad" { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing folder"]) }
   return .answer("Found", ["diagram"])
  }, present: { _ in }, answer: { _ in })
  check(recovered && calls == 3, "tool error -> corrected arguments -> grounded answer")
  calls = 0
  try await MarginToolLoop.run(messages: [], request: { _ in calls += 1; return reply("find") }, prepare: { _ in .answer("Empty", []) }, present: { _ in }, answer: { _ in })
  check(calls == 2, "identical call loop stops")
  calls = 0
  try await MarginToolLoop.run(messages: [], maxRounds: 3, request: { _ in calls += 1; return reply("find", ["n": calls]) }, prepare: { _ in .answer("Empty", []) }, present: { _ in }, answer: { _ in })
  check(calls == 3, "step budget stops changing-call loop")
  calls = 0; var refreshed = false; var recoveredID = false
  let refreshEnd = try await MarginToolLoop.run(messages: [], request: { _ in
   calls += 1
   switch calls {
   case 1, 3: return reply("inventory")
   case 2: return reply("read", ["id": "expired"])
   case 4: return reply("read", ["id": "current"])
   default: return .init(text: "Recovered", toolCalls: [])
   }
  }, prepare: { call in
   if call.name == "inventory" { refreshed = calls == 3; return .answer("Inventory", [refreshed ? "current" : "expired"]) }
   if call.arguments["id"] as? String == "expired" { throw ToolArgumentError(message: "ID expired; refresh inventory") }
   recoveredID = true; return .answer("Read", ["verified note"])
  }, present: { _ in }, answer: { _ in })
  check(refreshed && recoveredID && refreshEnd == .answered, "stale ID permits inventory refresh and recovery")
  calls = 0; var failedPreparations = 0
  try await MarginToolLoop.run(messages: [], request: { _ in
   calls += 1; return reply("read", ["id": "expired"])
  }, prepare: { _ in failedPreparations += 1; throw ToolArgumentError(message: "Expired") }, present: { _ in }, answer: { _ in })
  check(calls == 2 && failedPreparations == 1, "identical failed call still stops without retry")
  calls = 0; var inventoryReads = 0
  try await MarginToolLoop.run(messages: [], request: { _ in
   calls += 1; return reply(calls == 2 ? "bad" : "inventory")
  }, prepare: { call in
   if call.name == "bad" { throw ToolArgumentError(message: "Refresh needed") }
   inventoryReads += 1; return .answer("Inventory", ["unchanged"])
  }, present: { _ in }, answer: { _ in })
  check(calls == 4 && inventoryReads == 2, "one error permits only one refresh of the same read")
  calls = 0; prepared = []
  try await MarginToolLoop.run(messages: [], request: { _ in .init(text: "", toolCalls: [.init(name: "grant", arguments: [:]), .init(name: "later", arguments: [:])]) }, prepare: { call in
   prepared.append(call.name); return ProposedAction(kind: .answer, title: "Grant access", run: { _ in ran = true; return "Granted" })
  }, present: { _ in }, answer: { _ in })
  check(prepared == ["grant"] && !ran, "authorization pause blocks later calls and run closure")
  let task = Task { @MainActor in
   try await MarginToolLoop.run(messages: [], request: { _ in throw CancellationError() }, prepare: { _ in fatalError("must not prepare") }, present: { _ in }, answer: { _ in })
  }
  do { try await task.value; fatalError("cancel swallowed") } catch is CancellationError { check(true, "cancellation propagates") }
  print("\\(count)/\\(count) orchestration checks passed")
 }
}
'''
checks = checks.replace('  print(', (root/'scripts/margin-agent-journal-checks.swift').read_text() + '\n  print(', 1)
with tempfile.TemporaryDirectory(prefix='margin-loop-') as tmp:
 p=pathlib.Path(tmp)/'checks.swift';p.write_text(stubs+action+'\n@MainActor\nenum MarginToolLoop'+loop+checks)
 subprocess.run(['swiftc','-parse-as-library',str(p),'-o',str(pathlib.Path(tmp)/'checks')],check=True)
 subprocess.run([str(pathlib.Path(tmp)/'checks')],check=True)
