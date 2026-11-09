"""Exercise actual Swift export against real granted temp folders; no inference."""
import pathlib,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
s=(root/'MeetingIntro/Margin/FileWriteTools.swift').read_text();export=s[s.index('@MainActor\nenum MarginImageExport'):]
checks='''
@main struct Check {
 @MainActor static func main() throws {
  let fm=FileManager.default, folder=fm.temporaryDirectory.appendingPathComponent("margin-image-export-"+UUID().uuidString)
  try fm.createDirectory(at:folder,withIntermediateDirectories:true)
  defer { try? fm.removeItem(at:folder) }
  let suite="margin-export-check-"+UUID().uuidString
  let defaults=UserDefaults(suiteName:suite)!
  let roots=MarginRoots(defaults:defaults)
  guard let grant=roots.add(folder) else { fatalError("Grant failed") }
  defer { roots.remove(grant); defaults.removePersistentDomain(forName:suite) }
  let data=Data([1,2,3,4]);var total=0
  func check(_ value:Bool) { precondition(value);total += 1 }
  func refuses(_ f:() throws -> Void) { do { try f();fatalError("Expected refusal") } catch { total += 1 } }
  let saved=try MarginImageExport.save(data:data,folder:folder,filename:"receipt.png",fileExtension:"png",roots:roots)
  check(try Data(contentsOf:saved.url)==data)
  refuses { _ = try MarginImageExport.save(data:Data([9]),folder:folder,filename:"receipt.png",fileExtension:"png",roots:roots) }
  check(try Data(contentsOf:saved.url)==data)
  refuses { _ = try MarginImageExport.destination(folder:folder,filename:"../escape.png",fileExtension:"png") }
  refuses { _ = try MarginImageExport.destination(folder:folder,filename:"receipt.jpg",fileExtension:"png") }
  refuses { _ = try MarginImageExport.destination(folder:folder,filename:".hidden.png",fileExtension:"png") }
  try Data([9]).write(to:saved.url)
  refuses { try MarginImageExport.undo(saved,roots:roots) }
  check(fm.fileExists(atPath:saved.url.path))
  let safe=try MarginImageExport.save(data:data,folder:folder,filename:"undo.png",fileExtension:"png",roots:roots)
  try MarginImageExport.undo(safe,roots:roots);check(!fm.fileExists(atPath:safe.url.path))
  let left = folder.appendingPathComponent("left/shared")
  let right = folder.appendingPathComponent("right/shared")
  try fm.createDirectory(at:left,withIntermediateDirectories:true)
  try fm.createDirectory(at:right,withIntermediateDirectories:true)
  let leftGrant = roots.add(left)!, rightGrant = roots.add(right)!
  check(roots.resolve("shared") == nil)
  check(roots.resolve(left.path)?.standardizedFileURL == left.standardizedFileURL)
  roots.remove(leftGrant); roots.remove(rightGrant)
  roots.remove(grant)
  refuses { _ = try MarginImageExport.save(data:data,folder:folder,filename:"revoked.png",fileExtension:"png",roots:roots) }
  print("Image export checks passed: \\(total)")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='margin-export-') as tmp:
 p=pathlib.Path(tmp)/'check.swift';p.write_text('import AppKit\nimport Foundation\nstruct ToolArgumentError:LocalizedError {let message:String;var errorDescription:String?{message}}\n'+(root/'MeetingIntro/Margin/MarginRoots.swift').read_text()+export+checks)
 exe=pathlib.Path(tmp)/'check';subprocess.run(['swiftc','-parse-as-library',str(p),'-o',str(exe)],check=True);subprocess.run([str(exe)],check=True)
