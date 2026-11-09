# Margin roadmap — implementation tracker

User scope, 10 September 2026: fix batch calendar/progress, add Brave research, expose existing services, implement bounded persistent jobs. Design browser control, email sending, cloud workers and multiple agents first; do not enable those broader capabilities.

| Work | Implementation | Evidence / remaining boundary |
|---|---|---|
| Eight-event screenshot regression | `create_events`, deterministic explicit date-list parser, aggregation of multiple create calls, complete selectable preview including title/year/calendar | Invalid or omitted entries refuse; no live calendar creation in evals |
| Descriptive activity | Request excerpt / detected event count, actual search and synthesis stages, explicit slow-model message, Cancel | No fabricated percentage or claimed progress while waiting on model |
| Batch results and recovery | Local journal before/after each step; completed/uncertain steps excluded from resume; identical persisted steps held | Remote-write ambiguity remains uncertain, never assumed safe to retry |
| Bounded multi-step jobs | First workflow: calendar batch; list, pause, resume with fresh preview; per-step results | Not a general autonomous planner or arbitrary cross-tool execution loop |
| Brave web research | Keychain key setting, bounded source count, search excerpts, local cited brief, clickable source links | Live Brave query pending user key. Excerpts are not full-page verification; model synthesis can still misinterpret evidence |
| Standing folders | `watch_folder`, `schedule_organize`, `list_jobs`, `pause_job` wrap host jobs; review required | Runs only while local app/Mac is running; Margin grant checked at trigger; no unattended moves for Margin-created jobs |
| Recordings and notes | `list_recordings`, `search_transcripts`, `generate_notes` | Granted roots required; notes queue uses existing configured providers. Queued is not complete; live provider generation not exercised |
| Developer evals | Screenshot list, fault injection, source parsing/auth/quota guards; expanded routing suite and HTML report | See exact run artifacts; no paid Brave calls in tests |
| Browser/email/cloud/multi-agent | Design document complete | Not enabled or registered |

Registry now contains 29 tools. Source implementation and automated checks are distinct from live provider verification. Preserve old eval runs when new ones are generated.

## Acceptance checks

- The supplied eight-event request produces eight selectable event rows. No model wait is needed for that explicit date-list format.
- No calendar write occurs while preparing a preview. The button count equals selected rows.
- A failure at step two preserves step one, holds step two as uncertain and leaves step three pending.
- Resume revalidates the destination and never repeats known completed/uncertain steps.
- Search-key absence and Brave quota errors produce actionable errors, not empty research.
- Folder/recording access must remain inside granted roots and be checked again at execution.
- Broader capabilities remain design-only until a concrete implementation scope is chosen.

## Search implementation references

- [Brave authentication](https://api-dashboard.search.brave.com/documentation/guides/authentication): API key in the `X-Subscription-Token` header.
- [Brave Web Search documentation](https://api-dashboard.search.brave.com/app/documentation/web-search): search endpoint, result descriptions and freshness filters. Margin deliberately caps results below the API maximum.

The local model brief is generated from returned excerpts with numbered references. Citation-number validation is structural; it does not prove that every model claim is supported. Full source pages are not fetched by this implementation.

## Recovery and date handling

Uncertain calendar steps can be reconciled under Margin settings → Interrupted jobs after checking the destination. “Not created” returns the step to pending; it does not execute it. Resume still prepares a fresh preview. “Already created” prevents replay.

`move_event` now accepts a new date while preserving the existing clock time, and an original day without inventing midnight. Calendar previews exclude read-only destinations using EventKit write permission and Graph `canEdit`; see [Microsoft’s calendar resource documentation](https://learn.microsoft.com/en-us/graph/api/resources/calendar?view=graph-rest-1.0).

Empty model completions are invalid outputs, not legitimate refusals. The eval distinguishes them from transport/quota failures. The API fields used are documented in [Ollama’s chat API](https://docs.ollama.com/api/chat). The clock is supplied after the stable tool/system prefix to permit cache reuse; no latency improvement is claimed without comparing the saved measurements.

Web queries are bound to the current user request rather than a model-generated query copied from previous file/transcript results. Context-dependent “look this up” requests need the public topic stated explicitly; prior private tool output is not attached to Brave requests.


### 2026-09-10 — Resting notebook and evolving preferences

Open Margin now fades to the selected resting opacity after 60 seconds without notebook input (30/60/120/300 seconds or Never in settings). Pointer hover does not wake it. The first click is consumed; click or Option-Space wakes the existing page and draft. Preparing or executing actions keeps the notebook visible. AppKit event observation is limited to this panel; SwiftUI renders the fade.

Memory and soul learn independently from new user messages after the foreground answer, using the configured local model without tools. No file, transcript or web result is passed to reflection. The small category allowlist bounds what can be retained; model filtering of sensitive/one-off content remains probabilistic. Entries carry a verbatim evidence quote, update date and previous value. Explicit notes take priority; editing pins an entry and forgetting persists a category tombstone. New configurations enable learning, while existing explicit memory-off settings remain off; history saving remains independent and opt-in. New requests cancel background reflection. No learned state grants permissions or changes proactivity settings.

Reflection is an initial bounded implementation, not a claim of longitudinal personality accuracy: it sees one new user message at a time, supports twelve preference categories, and keeps only the previous value rather than a full revision log.

Validation: `2026-09-10-learning-idle-v3` passed 80 deterministic checks and two live local-model learning checks (82/82 combined), with no routing cases requested. v1/v2 learning failures are retained. HTML run badges now include guard failures, and each run links its check log. JSON grammar constraints follow https://docs.ollama.com/capabilities/structured-outputs; evidence and category validation still run after decoding. Native idle/wake verification is recorded separately below.

Release build passed; installed bundle signature verified. Installed executable SHA-256: `72fcbb3625d04548043ae4c350541dcae1171ee60d3da070b798407696b2b9a6`. Prior bundle retained at `/private/tmp/MeetingIntro-before-idle-20260910.app`. Calendar live-write and Brave-key boundaries remain unchanged.

Native verification: observed the open page fade at the saved 0.2787 opacity after 60 seconds, with an unsent draft intact. A position click restored full opacity. The first accessibility-action test bypassed event interception, so resting content is now disabled and a dedicated accessible Wake Margin button is overlaid. The temporary draft was cleared without sending.

Final accessibility build installed and signature verified: `e89469ca42712d76ac3b400724cc9a07a02a95fbe903be3d604b920482c8dc01`. This supersedes the earlier idle build hash. The final change disables underlying resting controls and adds an accessible wake button; learning code is unchanged from the 82-check run.

Final native check passed: faded notebook exposed a Wake Margin button and disabled Index, suggestion buttons and text field. Activating Wake Margin restored full opacity and enabled the same page without opening Index or sending a request.


### 2026-09-10 — Inactivity returns to the cover (user correction)

Supersedes faded-open-page behavior: idle now closes to the small notebook cover at the saved resting opacity. Hover and pending suggestions do not brighten or expand the idle cover; clicking or Option-Space reopens it. Active work still postpones rest. Draft storage moved from page-local State to a controller-owned binding so removing the page view cannot discard unsent input; conversation and Index selection remain in their existing owners.

Closed-cover correction: Release build and installed bundle signature verification passed. Installed executable SHA-256 `1e27558b749e4c21e8f85029c1f5264fe6d8b9ff8c6dd2d0668814158d0a838f`. Native close/reopen verification could not finish: Computer Use repeatedly timed out selecting the installed app, including after session reset. Process sampling showed the main thread servicing the AppKit event loop, not a captured deadlock. Do not treat the previous faded-page native check as validation of the new closed-cover transition.


### 2026-09-10 — Comprehensive categorized developer eval

Expanded to 78 routing cases spanning all 29 registered tools, plus existing deterministic guards and six live learning scenarios (style, one-time request, correction, working hours, credentials and permission escalation). A seventh learning-related pause check is deterministic. Reports show one selected run, category totals, separate check types, failed checks first, untested boundaries and historical runs. Every new run has immutable artifacts, runner start/end timestamps, per-routing-case timestamps, a planned-case manifest and binary hash. Infrastructure failures produce non-scored records and continue until three consecutive failures. Old runs keep their original recorded timestamps without invented start/end times.

The comprehensive baseline exposed a learned refusal stored as a soul preference; the raw failure is retained. A downstream pause assertion used a stale baseline. Its explicit run-review.json marks that evidence invalid (not passed), and the fixture now captures state immediately before pausing. Seven report-accounting tests cover timestamps, missing cases, failed guards, infrastructure separation, invalid-test review and registry coverage.


### 2026-09-10 — Provisioned web research

At the user’s request, their clipboard credential was pasted directly into Margin’s secure field and saved through the app to macOS Keychain; the UI confirmed success. The key was not read into the assistant context or copied into source/artifacts. Removed the entire Web research setup section (key field, source count and signup link). Runtime continues to use the existing Keychain account across app updates, on this Mac. Updated missing/rejected-key errors so they do not direct users to a removed settings control. This is per-Mac provisioning, not a credential distributed inside the binary.

Native idle-to-cover verification now passed on installed hash 1e27558b: small transparent cover after one minute, then exact same page and unsent draft after clicking. Cleared temporary draft without sending. Timestamped observations are in docs/evals/margin/native-checks.json, separate from automated eval scores.

Comprehensive run `20260911T034323Z-comprehensive`: started 2026-09-10 20:44:22 PDT, finished 20:55:56 PDT. All 78 routing cases ran, covering 29/29 tools: 75 passed and 3 failed (daily Documents organization routed to create_event; two move_event cases omitted the new time). Deterministic checks: 80 valid passes; live learning: 5/6 pass, with permission-escalation refusal incorrectly retained as a soul entry. One stale-baseline pause assertion is explicitly invalid and excluded, not counted as a pass. Aggregate: 160 pass, 4 fail, 1 invalid test, no infrastructure errors or unrun cases.

Provisioned-search Release build installed and signature verified: `ffe92eaaa5b7d98a97ffb91e4427c7f3afcf943cbbd8516f1a34baf5e89ebcf9`. Native settings inspection confirms the web setup section is gone. This is newer than the comprehensive test binary only in settings removal, related error copy and the corrected pause fixture; the historical comprehensive result remains tied to its saved binary hash.

Post-update native verification: the web setup section is absent. One public Brave request successfully retrieved five excerpts using the saved Keychain credential; the local model did not produce a reliably cited brief and the app showed its honest source-excerpt fallback. Recorded as separate retrieval pass and brief-generation failure in native-checks.json, not merged into the automated score.

### Managed local AI and first-use introduction — Option A

Selected: compact “Meet Margin” introduction, approximately 14 GB download card, expandable expectations, Not now / Prepare Margin. First activation asks before downloading; Not now leaves the plugin off. Approval persists across updates. Previously enabled installations skip the introduction but do not silently authorize a download if their existing AI becomes unavailable.

Implementation: bundled pinned runtime/model metadata, Apple silicon/16 GB RAM/19 GB free-space checks, private Application Support installation, streaming download progress, engine archive SHA-256 verification, model digest verification, warm-up, cancellation and retry. Existing configured AI is reused. A signed supervisor owns only Margin’s local engine process group and exits when the app exits or crashes. Settings and notebook show preparation state; setup keeps the notebook from idling and blocks submission while preserving the draft. Consumer instructions no longer ask users to run Terminal commands.

Validation is recorded separately from routing evals: isolated real-runtime startup/shutdown/crash checks, deterministic preparation guards, Release build and installed native state. A clean-Mac full 14 GB model pull is not yet verified. This work is on the margin branch, not a published updater release.

Final setup build installed and deep signature verified: `8f67c7df5eb31ff668a645d384300b68d2f44fbfa62395043bfdcb99ec013095`. Release succeeded; 18/18 deterministic setup guards and 8/8 isolated real-engine lifecycle checks passed. Report recorded 2026-09-10 22:18:58 PDT: [setup verification](evals/margin/20260911-managed-setup/report.html). Native restart shows ready notebook input without onboarding or download, reusing existing AI. Fresh-user native popup interaction and a complete clean-Mac model pull remain unverified.
