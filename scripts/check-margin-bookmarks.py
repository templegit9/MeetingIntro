from pathlib import Path
import tempfile,subprocess
root=Path(__file__).resolve().parents[1]
code='import Combine\n'+(root/'MeetingIntro/Margin/MarginHistory.swift').read_text()
stub='''
enum Role { case user, assistant }
enum Kind { case change, read }
struct Action { var kind: Kind }
struct AssistantTurn { var role: Role; var text: String; var performed = false; var outcome: String? = nil; var action: Action? = nil; var contextText: String { text } }
'''
checks='''
@main struct Checks {
 @MainActor static func main() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: folder) }
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let url = folder.appendingPathComponent("history.json")
  let old = MarginHistory.Entry(id: UUID(), title: "Older receipt", updated: Date(timeIntervalSince1970: 0), turns: [.init(user: false, text: "Answer")])
  try JSONEncoder().encode([old]).write(to: url)
  let h = MarginHistory(url: url)
  precondition(h.entries.count == 1 && h.bookmarks.isEmpty)
  h.mark(old.id, color: .purple, title: "Reference")
  h.prune(days: 1)
  precondition(h.entries.count == 1)
  precondition(MarginHistory.RibbonColor.allCases.count == 12)
  for color in MarginHistory.RibbonColor.allCases {
   let id = UUID()
   h.save(id: id, turns: [.init(role: .user, text: color.rawValue), .init(role: .assistant, text: "Read only")], days: 1)
   h.mark(id, color: color)
  }
  let reopened = MarginHistory(url: url)
  precondition(reopened.bookmarks.count == 13)
  precondition(reopened.bookmarks[0].displayTitle == "Reference")
  precondition(reopened.bookmarks.dropFirst().map { $0.bookmark!.color } == MarginHistory.RibbonColor.allCases)
  let last = reopened.bookmarks.last!.id
  reopened.moveBookmark(last, before: old.id)
  precondition(MarginHistory(url: url).bookmarks.first!.id == last)
  reopened.save(id: old.id, turns: [.init(role: .user, text: "Updated request")], days: 1)
  precondition(reopened.entries.first { $0.id == old.id }!.bookmark!.color == .purple)
  precondition(reopened.entries.first { $0.id == old.id }!.displayTitle == "Reference")
  reopened.unmark(last)
  precondition(MarginHistory(url: url).bookmarks.count == 12)
  precondition(reopened.entries.contains { $0.id == last })
  print("PASS: legacy archive, retention, 12 colours, edited title, reload, ordering, update preservation, non-destructive unmark")
 }
}
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'checks.swift';p.write_text(code+stub+checks)
 subprocess.run(['swiftc','-parse-as-library',str(p),'-o',tmp+'/checks'],check=True)
 subprocess.run([tmp+'/checks'],check=True)
