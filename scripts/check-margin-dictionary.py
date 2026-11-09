from pathlib import Path
import tempfile, subprocess
root = Path(__file__).resolve().parents[1]
source = (root/'MeetingIntro/Margin/CapabilitiesTool.swift').read_text()
matcher = source[source.index('    static func requestedWord'):source.index('    static func lines')]
code = '\n'.join((root/p).read_text() for p in ['MeetingIntro/Dictionary/DictionaryModels.swift', 'MeetingIntro/Dictionary/DictionaryService.swift'])
code += '\nstruct Routing {\n' + matcher + '\n}\n'
code += '''
@main struct Checks {
 @MainActor static func main() async throws {
  precondition(Routing.requestedWord("Oneumatopia") == "Oneumatopia")
  precondition(Routing.requestedWord("define onomatopoeia") == "onomatopoeia")
  precondition(Routing.requestedWord("what does ephemeral mean?") == "ephemeral")
  precondition(Routing.requestedWord("meaning of serendipity") == "serendipity")
  for command in ["cancel", "undo", "help", "yes", "no", "stop", "index", "move my files", "create an event tomorrow"] {
   precondition(Routing.requestedWord(command) == nil, command)
  }
  let entries = try await DictionaryService.lookup("onomatopoeia", preferOffline: true)
  precondition(!entries.isEmpty && !entries[0].meanings.isEmpty)
  precondition(entries[0].sourceNote == "macOS dictionary (offline)")
  let corrections = DictionaryService.suggestions(for: "Oneumatopia")
  print("Screenshot spelling suggestions: \\(corrections)")
  print("PASS: explicit definitions, bare word, command exclusions, real offline definition")
 }
}
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'checks.swift'; p.write_text(code)
 subprocess.run(['swiftc','-parse-as-library',str(p),'-o',tmp+'/checks'],check=True)
 subprocess.run([tmp+'/checks'],check=True)
