# Margin harness overhaul — September 16, 2026

## Assessment

The previous implementation was a single-dispatch assistant. Its prompt explicitly assigned routing, prohibited preparatory searches and model clarification, and rejected multiple tool calls. Reads did not return to the model within a request. Images used a separate regex-selected reader/export pipeline. Approval closures and history pages were not a durable agent task.

## Implemented

- One goal-directed loop for ordinary requests and image requests. The model chooses tools, receives structured observations/errors, can clarify, and adapts subsequent steps.
- Structured observations include evidence, choice IDs, provenance, warnings, uncertainties supplied by readers and source links. UI actions do not execute as a consequence of reading their result.
- Image tools: read_attached_image, prepare_document_draft, export_attachment. The reader performs OCR; the planner chooses when to use it. Attachment IDs bind proposals to their source. Full transcription is preserved by default; TXT is editable, and Word/Markdown follow-ups reuse existing text.
- Folder tools: list_granted_folders and inspect_folder, enabling destination discovery within granted roots. Duplicate folder names fail closed instead of selecting the first match.
- Persistent goals, transcripts, exact pending arguments, approval signatures, execution receipts and task states. Saved tasks remain discoverable after another request starts. Recovery rebuilds a fresh proposal and requires fresh confirmation.
- Confirmation re-prepares the tool and compares the selected proposal before execution. Changed targets, content or permissions invalidate approval. Source/draft hashes bind exports to reviewed content. Execution is serialized, and completed calls cannot repeat within a task.
- A write is journaled before execution. Interrupted or failed writes are uncertain, not automatically retried. Explicit user reconciliation is distinguished from a tool execution receipt. Batch calendar partial failures stop continuation while preserving per-event results.
- Execution receipts return to the model so it can continue toward the original goal. A model's final answer is recorded as answered, not as verified goal completion.
- Cancellation, an eight-round/16-tool-step/ten-minute continuation budget, a persistent 24-request task budget, a 64 KB observation limit and a 512 KB transcript limit. Stop during an in-flight write finishes that operation and prevents later steps. Corrupt/unwritable journals fail closed.
- No production single-tool dispatch shortcuts or regex-selected image workflows. Historical baseline classifiers remain isolated for legacy guard comparisons; new eval exports no longer exempt those cases as deterministic dispatch.
- Notebook image pages retain the image and show the same conversation/action views. Editable document text uses the paper, formats are inline text choices, and save proposals remain explicit. Saved tasks and uncertain-write reconciliation are accessible from the notebook.

## Verification

The timestamped report is `docs/evals/margin-vision/harness-overhaul-20260916/index.html`.

- 21/21 production-loop/journal checks: evidence chaining, correction, limits, cancellation, exact proposal signatures, persistence failure, crash recovery, reconciliation, duplicate prevention and archived-task recovery.
- 17/17 compiled-agent integration checks: actual agent and confirmation handler, changed target, single execution, actual temporary file contents, restart, image-to-TXT, Word follow-up without OCR repeat, DOCX contents, Undo, revoked grants and concurrent confirmation/stop behavior. Model and image-reader responses are scripted in these tests.
- One live Pilot 1 trajectory passed both checkpoints: inspect -> evidence -> preview -> confirm -> actual file -> resumed answer. 22.4 seconds. Only fixture tools were registered; no live calendar access or user-folder write.
- 20/20 request/image guards; 12/12 filesystem export checks; 10/10 document export checks; image-draft persistence regressions passed.
- 15/15 synthetic calendar guards, 16/16 behavior guards, 45/45 roadmap guards. Two legacy classifier checks in that last group are baseline compatibility checks, not proof of production shortcut dispatch.
- Debug build passed. Native SwiftUI image-draft rendering inspected; this is an isolated component render, not a complete physical-input UI test.

## Qualification boundaries

This is a working harness overhaul, not a claim of 99% model reliability. Broad multi-step model evaluation, live calendar/provider effects and full native physical-input qualification remain release gates. No installed app replacement, master merge, release, model promotion, browser control, email sending or cloud-worker authority was performed.

The completed Ornith comparison remains frozen on the earlier routing/planning architecture: 106/117 versus Pilot 1's 110/117, with 9.2s versus 4.0s median latency. It does not qualify the new harness or Ornith vision. Keep Pilot 1 pending broader trajectory evaluation.

## Installation — September 16, 2026

At the user’s request, installed the Developer ID signed Release build `202609162240` at `/Applications/MeetingIntro.app`. The exact signed Release passed 16/16 integration checks (the optional native-render check is excluded). One installed instance is running; Pilot 1 is explicitly selected; the notebook opened successfully. The previous 2.20.7 app is retained as a verified rollback ZIP. See the report’s `installation.json`. This supersedes the earlier no-installation boundary; master and public releases remain unchanged.


## Agentic continuation — September 18, 2026

Fixed a loop guard that prevented refreshing successful read evidence after a later tool error. An expired note ID now permits a fresh inventory read; repeated failed calls, repeated reads without a new error, write confirmation and duplicate-write guards remain enforced. A regression failed before this change and the expanded orchestration suite passes 24/24. Compiled image/confirmation integration passes 16/16; Debug build passes.

Added live Pilot 1 journeys for evidence-to-save, stale-ID recovery, ambiguous-folder clarification and two separately approved writes, using actual temporary folder grants and production folder discovery. Each scenario has a successful execution. Earlier fixture defects and one unexplained failure after both writes completed remain recorded; two diagnostic repetitions of that final continuation passed, which is not proof of consistent reliability. No installed app replacement or public release in this turn.

Evidence and exact per-run boundaries: `docs/evals/margin-agentic/20260918-journeys/README.md` and `results.json`. Next qualification should target completion consistency and the full tool registry rather than report these four scenarios as a broad reliability score.

## Broader qualification — October 1, 2026

The full existing first-decision suite finished at 73/78 under its legacy single-tool rubric. Raw review distinguishes a valid two-tool file plan, two clarification questions and two textual capability answers from refusals. The two-tool file goal passed a subsequent live-model journey using actual temporary files and two explicit confirmations.

Added and verified screenshot-to-calendar evidence checks, duration/location fidelity, and durable source-attachment approval binding. Final results: 25/25 loop/journal checks, 16/16 compiled integration checks, 30/30 request/calendar checks and 8/8 scripted screenshot cases. Debug build passed; no installation or public release.

The real vision reader is **not qualified** for whole-week imports: a synthetic week grid yielded only 7/8 exact events after revised instructions, with the all-day event treated as timed. Removing the year/timezone labels caused invented values and no uncertainty warning. Reader format violations were rejected; no real calendar was modified. The user's actual Outlook screenshot and native paste/live-provider verification remain outstanding. Preserve these failures; do not combine successful scripted checks into a vision-accuracy claim.

Detailed results and reproduction: `docs/evals/margin-agentic/20261001-broad/README.md` and `summary.json`.
