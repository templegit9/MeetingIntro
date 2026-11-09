"""Exercise the actual game's persisted state in isolated preferences, without launching the app."""
from pathlib import Path
import subprocess,tempfile,hashlib
root=Path(__file__).resolve().parents[1];text=(root/'MeetingIntro/Margin/MarginPageView.swift').read_text();code=text[text.index('@MainActor final class MarginPocketGames:'):text.index('\nstruct MarginGamesPage:')]
checks=r'''
@main struct Checks {
 @MainActor static func main() {
  let name = "margin-game-checks-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: name)!
  defer { defaults.removePersistentDomain(forName: name) }
  var count = 0
  func check(_ value: Bool, _ label: String) { guard value else { fatalError(label) }; count += 1; print("PASS " + label) }
  let first = MarginPocketGames(defaults: defaults)
  let start = first.board
  let blank = first.board.firstIndex(of: 0)!
  let legal = first.board.indices.first { MarginPocketGames.adjacent($0, blank) }!
  first.play(legal)
  let moved = first.board
  let resumed = MarginPocketGames(defaults: defaults)
  check(resumed.board == moved && resumed.moves == 1 && resumed.level == 1, "Fifteen board, moves and level survive new instance")
  resumed.restart()
  check(resumed.board == start && resumed.moves == 0 && resumed.level == 1, "Start over preserves puzzle and level")
  resumed.select(.pairs)
  let pairStart = resumed.board
  let grouped = Dictionary(grouping: pairStart.indices, by: { pairStart[$0] })
  let pair = grouped.values.first!
  resumed.play(pair[0]); resumed.play(pair[1])
  let saved = MarginPocketGames(defaults: defaults)
  check(saved.game == .pairs && saved.board == pairStart && saved.matched.count == 2 && saved.moves == 1, "Matched pairs and selected game survive restart")
  for indices in grouped.values where !saved.matched.contains(indices[0]) { saved.play(indices[0]); saved.play(indices[1]) }
  check(saved.won && saved.moves == 6, "Finishing all pairs completes level")
  saved.nextLevel()
  check(saved.level == 2 && saved.board != pairStart && saved.moves == 0 && saved.matched.isEmpty, "Next level advances to a different board")
  let level2 = saved.board
  saved.select(.fifteen)
  check(saved.board == start && saved.level == 1, "Switching games preserves independent progress")
  saved.select(.pairs)
  check(saved.board == level2 && saved.level == 2, "Returning resumes current level")
  saved.nextLevel()
  check(saved.level == 2 && saved.board == level2, "Cannot advance unfinished puzzle")
  let clock = Date()
  check(saved.claimHint(now: clock) != nil && saved.claimHint(now: clock) == nil, "Hint cooldown persists")
  check(saved.claimHint(now: clock.addingTimeInterval(36*3600)) != nil, "Hint becomes eligible after 36 hours")
  saved.discover()
  check(saved.claimHint(now: clock.addingTimeInterval(72*3600)) == nil, "Discovery stops hints")
  let fresh = MarginPocketGames(defaults: defaults)
  check(fresh.level == 2 && fresh.board == level2, "Progress persists after discovery")
  print("\(count)/\(count) persistence checks passed")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='margin-game-check-') as tmp:
 p=Path(tmp);(p/'main.swift').write_text('import Foundation\nimport Combine\n'+code+checks)
 subprocess.run(['swiftc','-parse-as-library',str(p/'main.swift'),'-o',str(p/'checks')],check=True)
 subprocess.run([str(p/'checks')],check=True)
print('Game class SHA256:',hashlib.sha256(code.encode()).hexdigest())
