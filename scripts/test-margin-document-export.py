import pathlib,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
s=(root/'MeetingIntro/Margin/FileWriteTools.swift').read_text();export=s[s.index('@MainActor\nenum MarginDocumentExport'):]
check=r'''
@main struct Check {
 @MainActor static func main() throws {
  var n=0
  func test(_ v:Bool) {precondition(v);n+=1}
  func refuses(_ f:() throws -> Void) {do {try f();fatalError("Expected refusal")}catch{n+=1}}
  let original="Receipt\nTotal: 19.44 & <tag>\nCafé"
  for f in [MarginDocumentExport.Format.txt,.md] {test(String(data:try MarginDocumentExport.data(text:original,format:f),encoding:.utf8)==original)}
  let doc=try MarginDocumentExport.data(text:original,format:.docx)
  let restored=try NSAttributedString(data:doc,options:[.documentType:NSAttributedString.DocumentType.officeOpenXML],documentAttributes:nil)
  test(restored.string.trimmingCharacters(in:.whitespacesAndNewlines)==original)
  test(try MarginImageReader.transcription(#"{"visible_text":"Exact text","uncertainties":[]}"#)=="Exact text")
  test(try MarginImageReader.transcription(#"{"visible_text":[{"text":"First"},{"text":"Second"}]}"#)=="First\nSecond")
  test(try MarginImageReader.transcription(#"{"visible_text":"A","uncertainties":["Date unclear"]}"#).contains("Date unclear"))
  refuses {_ = try MarginImageReader.transcription(#"{"visible_text":[]}"#)}
  refuses {_ = try MarginImageReader.transcription(#"{"visible_text":[{"text":2}]}"#)}
  refuses {_ = try MarginImageReader.transcription(#"{"visible_text":"A","uncertainties":"none"}"#)}
  refuses {_ = try MarginDocumentExport.data(text:"  ",format:.txt)}
  print("Document export checks passed: \(n)")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='margin-document-checks-') as tmp:
 p=pathlib.Path(tmp)/'test.swift';p.write_text('import AppKit\nstruct ToolArgumentError:LocalizedError{let message:String;var errorDescription:String?{message}}\n'+export+check)
 exe=pathlib.Path(tmp)/'test';subprocess.run(['swiftc','-parse-as-library',str(root/'MeetingIntro/Margin/OllamaToolClient.swift'),str(p),'-o',str(exe)],check=True);subprocess.run([str(exe)],check=True)
