import Foundation
struct ToolArgumentError: LocalizedError { let message: String; var errorDescription: String? { message } }
@main struct ReaderCheck {
 static func main() async {
  let args=CommandLine.arguments
  var report:[String:Any] = ["started_at":ISO8601DateFormatter().string(from:Date()),"image":args[1],"scope":"Actual production reader only; no planner or calendar writes"]
  do {
   let result=try await MarginImageReader.calendar(image:Data(contentsOf:URL(fileURLWithPath:args[1])),question:"Extract every visible calendar event with exact dates, times and durations. Do not assume missing year or timezone.",base:"http://127.0.0.1:11434",planner:"margin-lora-pilot:final",readingDiagnostic:{report["raw_reader_output"]=$0})
   report["evidence"]=try JSONSerialization.jsonObject(with:Data(result.utf8))
   report["parsed"]=true
  } catch {report["error"]=error.localizedDescription;report["parsed"]=false}
  report["finished_at"]=ISO8601DateFormatter().string(from:Date())
  do {try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:args[2]));print("Reader diagnostic saved: \(args[2])")} catch {print(error);exit(2)}
 }
}
