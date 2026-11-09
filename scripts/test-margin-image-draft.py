"""Compile and exercise the actual image draft's persistence and invalidation code."""
import pathlib,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
s=(root/'MeetingIntro/Margin/MarginPageView.swift').read_text()
draft=s[s.index('@MainActor\nfinal class MarginImageDraft'):s.index('struct MarginImagePreviewPage')]
checks='''
@main struct Check {
 @MainActor static func main() throws {
  let data = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
  let d = MarginImageDraft(); d.accept(data,name:"first.png"); d.accept(data,name:"second.png")
  d.answer="USD 19.44"; d.savedRequest="What is the total?"
  let saved=try d.encoded(request:d.savedRequest)
  let restored=MarginImageDraft(); try restored.restore(saved)
  precondition(restored.selected==1 && restored.current?.name=="second.png")
  precondition(restored.answer=="USD 19.44" && restored.savedRequest=="What is the total?")
  restored.selected=0; precondition(restored.answer.isEmpty && restored.savedRequest.isEmpty)
  restored.answer="old"; restored.reset(); precondition(restored.answer.isEmpty && restored.attachments.isEmpty)
  let oldPage=restored.pageID
  do { try restored.restore(Data("{}".utf8)); fatalError("Accepted invalid snapshot") } catch { precondition(restored.pageID==oldPage) }
  restored.accept(data,name:"receipt.png")
  restored.beginDocument(text:"Heading\\nExact text & amounts 19.44")
  precondition(restored.documentFormat == .txt && restored.exportFilename.hasSuffix(".txt"))
  restored.documentFormat = .docx
  precondition(restored.exportFilename.hasSuffix(".docx"))
  let docSaved=try restored.encoded(request:"Convert to a doc")
  let docRestored=MarginImageDraft();try docRestored.restore(docSaved)
  precondition(docRestored.documentMode && docRestored.documentFormat == .docx && docRestored.documentText == restored.documentText)
  precondition(docRestored.exportFolder == nil)
  docRestored.clearExport();precondition(docRestored.documentFormat == .txt && docRestored.documentText.isEmpty)
  print("Image draft: selected source/answer round-trip, selection/reset invalidation and corrupt snapshot preservation passed")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='margin-image-draft-') as tmp:
 p=pathlib.Path(tmp)/'test.swift';export=(root/'MeetingIntro/Margin/FileWriteTools.swift').read_text();export=export[export.index('@MainActor\nenum MarginImageExport'):]
 p.write_text('import SwiftUI\nimport AppKit\nimport ImageIO\nimport UniformTypeIdentifiers\n'+(root/'MeetingIntro/Margin/MarginRoots.swift').read_text()+'\nstruct ToolArgumentError:LocalizedError {let message:String;var errorDescription:String?{message}}\n'+export+draft+checks)
 exe=pathlib.Path(tmp)/'test';subprocess.run(['swiftc','-parse-as-library',str(p),'-o',str(exe)],check=True)
 subprocess.run([str(exe),str(root/'docs/evals/margin-vision/separated-20260913b/assets/NEW-03.png')],check=True)
