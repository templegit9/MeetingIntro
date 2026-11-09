from pathlib import Path
import subprocess,tempfile,ast
root=Path(__file__).resolve().parents[1]
s=(root/'MeetingIntro/Margin/MarginPageView.swift').read_text()
a=s.index('@MainActor\nfinal class MarginImageDraft');b=s.index('struct MarginImagePreviewPage',a)
code='import SwiftUI\nimport ImageIO\nimport UniformTypeIdentifiers\n'+s[a:b]
bookmark_tree=ast.parse((root/'scripts/check-margin-bookmarks.py').read_text())
stub=next(ast.literal_eval(n.value) for n in bookmark_tree.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='stub' for t in n.targets))
code+=(root/'MeetingIntro/Margin/MarginHistory.swift').read_text()+stub
code+=''' 
@main struct Checks {
 @MainActor static func main() async throws {
  let d=MarginImageDraft()
  let path=CommandLine.arguments[1]
  let data=try Data(contentsOf: URL(fileURLWithPath:path))
  d.importURLs([URL(fileURLWithPath:path)])
  precondition(d.attachments.count == 1 && d.active)
  precondition(d.current!.image.size.width > 0)
  d.accept(Data("invalid".utf8),name:"broken.png")
  precondition(d.attachments.count == 1 && d.problem != nil)
  d.importURLs(Array(repeating: URL(fileURLWithPath:path),count:5))
  precondition(d.attachments.count == 1)
  for _ in 0..<4 { d.accept(data,name:"diagram.png") }
  precondition(d.attachments.count == 5)
  d.accept(data,name:"sixth.png")
  precondition(d.attachments.count == 5)
  d.reset()
  precondition(!d.active && d.attachments.isEmpty && d.fields.isEmpty && d.problem == nil)
  let provider=NSItemProvider(item:URL(fileURLWithPath:path) as NSURL,typeIdentifier:"public.file-url")
  precondition(d.receive([provider]))
  for _ in 0..<30 { if !d.attachments.isEmpty { break }; try await Task.sleep(nanoseconds:50_000_000) }
  precondition(d.attachments.count == 1)
  d.reset()
  _ = d.receive([provider]); d.reset()
  try await Task.sleep(nanoseconds:150_000_000)
  precondition(d.attachments.isEmpty && !d.active)
  d.importURLs([URL(fileURLWithPath:path)])
  let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at:folder) }
  let archive=folder.appendingPathComponent("history.json")
  let history=MarginHistory(url:archive)
  try history.saveImagePage(id:d.pageID,title:"Diagram test",payload:d.encoded(request:"Name the diagram"),color:.cyan)
  let reloaded=MarginHistory(url:archive)
  precondition(reloaded.bookmarks.count == 1 && reloaded.bookmarks[0].bookmark!.color == .cyan)
  let restored=MarginImageDraft()
  try restored.restore(reloaded.imagePayload(for:reloaded.bookmarks[0])!)
  precondition(restored.attachments.count == 1 && restored.savedRequest == "Name the diagram" && restored.saved)
  let originalID=restored.pageID
  do { try restored.restore(Data("bad".utf8)); preconditionFailure() } catch {}
  precondition(restored.pageID == originalID && restored.attachments.count == 1)
  try reloaded.saveImagePage(id:d.pageID,title:"Diagram test",payload:d.encoded(request:"Updated request"),color:.purple)
  let images=folder.appendingPathComponent("image-pages")
  let savedFiles=try FileManager.default.contentsOfDirectory(atPath:images.path); precondition(savedFiles.count == 1)
  reloaded.forgetImagePage(d.pageID)
  precondition(reloaded.entries.isEmpty)
  reloaded.clear()
  let clearedFiles=try FileManager.default.contentsOfDirectory(atPath:images.path); precondition(clearedFiles.isEmpty)
  let originalData=try Data(contentsOf:URL(fileURLWithPath:path)); precondition(originalData == data)
  try reloaded.saveImagePage(id:d.pageID,title:"Retained image",payload:d.encoded(request:""),color:.gold)
  reloaded.unmark(d.pageID)
  var json=try JSONSerialization.jsonObject(with:Data(contentsOf:archive)) as! [[String:Any]]
  json[0]["updated"] = -1000000000
  try JSONSerialization.data(withJSONObject:json).write(to:archive)
  let expired=MarginHistory(url:archive); expired.prune(days:1)
  precondition(expired.entries.isEmpty)
  let expiredFiles=try FileManager.default.contentsOfDirectory(atPath:images.path); precondition(expiredFiles.isEmpty)
  print("PASS: real image import, display decode, corrupt input preserves source, batch cap, total cap, reset, async file provider, cancelled import, saved image reload, colour, corrupt restore, replaced-payload cleanup, clear, original preserved, expired image cleanup, forget one saved image")
 }
}
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'checks.swift';p.write_text(code)
 subprocess.run(['swiftc','-parse-as-library',str(p),'-o',tmp+'/checks'],check=True)
 subprocess.run([tmp+'/checks',str(root/'docs/evals/margin-vision/assets/diagram.png')],check=True)
