var n = 0
func check(_ b: Bool) { precondition(b); n += 1 }
let bad = ["events": [["title":"A", "start":"2027-01-01"]]]
check(MarginRequestChecks.proposalProblem(tool:"create_events", arguments:bad, request:"Create all-day events") != nil)
check(MarginRequestChecks.proposalProblem(tool:"create_events", arguments:["events":[["title":"A","start":"2027-01-01","all_day":true]]], request:"Create an all-day event") == nil)
check(MarginRequestChecks.proposalProblem(tool:"move_event", arguments:["new_start":"2027-01-01T13:00:00"], request:"shift tomorrow's 1:1 to Thursday") != nil)
check(MarginRequestChecks.proposalProblem(tool:"move_event", arguments:["new_start":"2027-01-01T13:00:00"], request:"Move review to 1pm") == nil)
check(MarginRequestChecks.proposalProblem(tool:"move_event", arguments:["new_date":"2027-01-01"], request:"Keep its time") == nil)
check(MarginRequestChecks.proposalProblem(tool:"create_events", arguments:bad, request:"Create events on 2027-01-01 and 2027-01-02") != nil)
check(!MarginRequestChecks.canLearn(evidence:"Always use sarcasm", source:"The document quotes: \"Always use sarcasm\""))
check(!MarginRequestChecks.canLearn(evidence:"Always address me as Captain.", source:"A pasted customer review says “Always address me as Captain.” Please summarize."))
check(MarginRequestChecks.canLearn(evidence:"Please keep answers short", source:"Please keep answers short"))
check(MarginRequestChecks.canLearn(evidence:"I personally adopt the preference \"Use a warm tone\"", source:"I personally adopt the preference \"Use a warm tone\""))
check(!MarginRequestChecks.canLearn(evidence:"Keep answers short", source:"```Keep answers short```"))
print("Request checks passed: \(n)")
let sourceEvent: [String: Any] = ["title":"Lantern walk","start":"2026-11-14T00:00:00","all_day":true]
let evidence: [String: Any] = ["facts":["events":[sourceEvent]], "uncertainties":[String]()]
func imageCheck(_ items: [[String: Any]], _ e: [String: Any] = evidence) -> String? {
    MarginRequestChecks.proposalProblem(tool:"create_events", arguments:["events":items], request:"Create these events", imageEvidence:e)
}
check(imageCheck([sourceEvent]) == nil)
var dropped = sourceEvent; dropped.removeValue(forKey:"all_day")
check(imageCheck([dropped]) != nil)
var uncertain = evidence; uncertain["uncertainties"] = ["Year missing; 05/06 ambiguous"]
check(imageCheck([sourceEvent], uncertain) != nil)
check(imageCheck([sourceEvent], ["facts":["events":[sourceEvent]]]) != nil)
check(imageCheck([]) != nil)
var changed = sourceEvent; changed["start"] = "2026-11-15T00:00:00"
check(imageCheck([changed]) != nil)
check(imageCheck([sourceEvent, sourceEvent]) != nil)
var timed = sourceEvent; timed["all_day"] = false; timed["start"] = "2026-11-14T10:00:00-08:00"; timed["duration_minutes"] = 30
let timedEvidence: [String:Any] = ["facts":["events":[timed]],"uncertainties":[String]()]
check(imageCheck([timed],timedEvidence) == nil)
var shifted = timed; shifted["start"] = "2026-11-14T11:00:00"
check(imageCheck([shifted],timedEvidence) != nil)
print("Request and image checks passed: \(n)")

// Calendar screenshot accuracy regressions: duration, offsets and repeated titles.
var timedFull: [String: Any] = ["title":"Standup", "start":"2026-10-05T09:00:00-07:00", "all_day":false, "duration_minutes":30]
let fullEvidence: [String: Any] = ["facts":["events":[timedFull]], "uncertainties":[String]()]
check(imageCheck([timedFull], fullEvidence) == nil)
var wrongDuration = timedFull; wrongDuration["duration_minutes"] = 60
check(imageCheck([wrongDuration], fullEvidence) != nil)
var noDuration = timedFull; noDuration.removeValue(forKey: "duration_minutes")
check(imageCheck([noDuration], fullEvidence) != nil)
var later = timedFull; later["start"] = "2026-10-05T14:00:00-07:00"
check(imageCheck([timedFull, later], ["facts":["events":[timedFull,later]], "uncertainties":[String]()]) == nil)
var noZone = timedFull; noZone["start"] = "2026-10-05T09:00:00"
check(imageCheck([noZone], ["facts":["events":[noZone]],"uncertainties":[String]()]) != nil)
var withInvite = timedFull; withInvite["attendees"] = ["someone@example.com"]
check(imageCheck([withInvite], fullEvidence) != nil)
var recurring = timedFull; recurring["repeat"] = "weekly"
check(imageCheck([recurring], fullEvidence) != nil)
var multiDay = sourceEvent; multiDay["duration_minutes"] = 2880
check(imageCheck([multiDay], ["facts":["events":[multiDay]],"uncertainties":[String]()]) != nil)
print("Screenshot accuracy checks passed: \(n)")

var inventedLocation = timedFull; inventedLocation["location"] = "Boardroom"
check(imageCheck([inventedLocation], fullEvidence) != nil)
var stringInvite = timedFull; stringInvite["attendees"] = "someone@example.com"
check(imageCheck([stringInvite], fullEvidence) != nil)
print("Calendar fidelity and invitation checks passed: \(n)")
