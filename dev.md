# MeetingIntro — Development & Deployment Guide

## Prerequisites
- macOS 14 (Sonoma) or later
- Xcode 15+ with Swift 5.9+
- Apple Developer account (for signing & calendar entitlement)

## Project Structure
```
MeetingIntro/
├── MeetingIntro/           # Xcode project source
│   ├── MeetingIntroApp.swift
│   ├── CalendarManager.swift
│   ├── AudioManager.swift
│   ├── SettingsView.swift
│   ├── CountdownOverlayView.swift
│   ├── Info.plist
│   └── MeetingIntro.entitlements
├── plan.md
├── AGENT_RULES.md
├── dev.md
├── dev_pattern.md
└── assumptions.md
```

## Build & Run
```bash
# Open in Xcode
open MeetingIntro.xcodeproj

# Or build from CLI (once xcodeproj exists)
xcodebuild -project MeetingIntro.xcodeproj -scheme MeetingIntro -configuration Debug build
```

## Key Configuration
- **Calendar access** requires the `com.apple.security.personal-information.calendars` entitlement.
- **LSUIElement** is set to `true` so the app appears only in the menu bar (no Dock icon).
- User preferences (countdown time, music file, monitored calendars) are stored in `UserDefaults`.

## Deployment
- Archive via Xcode → Distribute App → Developer ID for direct distribution, or App Store.

## 2026-09-10 · Margin calendar continuation

Resumed the unfinished `move_event` / `cancel_event` branch changes. Added time-reference lookup, ambiguity refusal, original-date disambiguation, exact recurring-occurrence lookup, Graph organiser and occurrence checks, and honest EventKit notification wording. Calendar changes remain preview-confirm operations; no automatic move undo is promised because recurring identities and sent updates cannot safely be rolled back using the old closure. Chat-history options are in `docs/margin-history-options.md`. Current verification is tracked in `docs/margin-tools.md`.

Margin settings now open from the plugin tile. Added Calm/Direct/Warm/Custom personality, editable soul instructions, opt-in explicit preference memory and local conversation receipts, an Index tab, and separate quiet/ribbon/nudge proactivity. Added a pre-SwiftUI CLI entry for developer evals and duplicate-instance prevention for normal launches. See `docs/margin-evals.md` for commands and evidence boundaries.

Developer eval results: full 49/50, focused 8/9, final focused 9/9 with 34/34 guards. The failures produced deterministic permanent-deletion refusal and exact-original-time calendar selection. HTML report: `docs/evals/margin/report.html`. Margin's plugin icon is now a green closed notebook rather than sparkles.


## 2026-09-10 — Back-of-book history and capability mapping

Inline back-of-book history replaces the modal, following the user’s updated 1C reference. Added per-request pages, outcome summaries, date groups, explicit execution markers and focused-notebook Cmd-K. Debug passed; 15 calendar and 16 behavior guards passed. Capability map: docs/margin-grok-bot-capability-map.html (20 mappings, primary-source links, local source evidence). HTML links and JavaScript syntax checked; local-browser policy blocks rendered HTML verification.

Release build passed and installed at /Applications/MeetingIntro.app with deep/strict codesign verification. Previous bundle retained at /private/tmp/MeetingIntro-before-inline-history-20260910.app. Native inspection verified the inline cream-paper empty index, red ribbon, search, saving-off message, footer and Cmd-K return. Saving remains off; populated rows are covered by source/guard checks, not a populated live archive screenshot. Native “what can you do” returned the current tool catalogue. Configuration controls and notebook icon were inspected on the preceding installed build; those sources are unchanged.


## 2026-09-10 — Batch calendar, research and standing work

Implemented eight-event batch preparation, complete selectable previews, real activity/cancellation, a durable per-step calendar job journal, Brave Search/Keychain/source links and local cited briefs, and wrappers for folder jobs and recordings/notes. Added runtime Margin-grant checks to organizer plan/apply/undo and notes stages. The broader browser/email/cloud/multi-agent scope is design-only. Validation and installation results will be appended after completion.


### 2026-09-10 — Resting notebook and evolving preferences

Open Margin now fades to the selected resting opacity after 60 seconds without notebook input (30/60/120/300 seconds or Never in settings). Pointer hover does not wake it. The first click is consumed; click or Option-Space wakes the existing page and draft. Preparing or executing actions keeps the notebook visible. AppKit event observation is limited to this panel; SwiftUI renders the fade.

Memory and soul learn independently from new user messages after the foreground answer, using the configured local model without tools. No file, transcript or web result is passed to reflection. The small category allowlist bounds what can be retained; model filtering of sensitive/one-off content remains probabilistic. Entries carry a verbatim evidence quote, update date and previous value. Explicit notes take priority; editing pins an entry and forgetting persists a category tombstone. New configurations enable learning, while existing explicit memory-off settings remain off; history saving remains independent and opt-in. New requests cancel background reflection. No learned state grants permissions or changes proactivity settings.

Reflection is an initial bounded implementation, not a claim of longitudinal personality accuracy: it sees one new user message at a time, supports twelve preference categories, and keeps only the previous value rather than a full revision log.

Validation: `2026-09-10-learning-idle-v3` passed 80 deterministic checks and two live local-model learning checks (82/82 combined), with no routing cases requested. v1/v2 learning failures are retained. HTML run badges now include guard failures, and each run links its check log. JSON grammar constraints follow https://docs.ollama.com/capabilities/structured-outputs; evidence and category validation still run after decoding. Native idle/wake verification is recorded separately below.

Release build passed; installed bundle signature verified. Installed executable SHA-256: `72fcbb3625d04548043ae4c350541dcae1171ee60d3da070b798407696b2b9a6`. Prior bundle retained at `/private/tmp/MeetingIntro-before-idle-20260910.app`. Calendar live-write and Brave-key boundaries remain unchanged.

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

### 2026-09-10 — Margin managed AI / Option A

First-use introduction is now wired ahead of plugin activation. Download consent and introduction state are separate persisted flags, so legacy enabled users can reuse existing AI without authorizing an unseen download. MarginLocalAI installs a pinned official runtime in private app support, streams a pinned model pull, verifies digests and warms the model. Setup has cancel/retry and readable status in notebook/settings. The signed C supervisor shuts down the app-owned runtime on normal exit or app crash; it does not stop an existing user service. project.yml packages the supervisor through a reproducible build script. The first-use options HTML marks A selected. Dedicated guards and real-runtime lifecycle checks are separate from historical routing scores; fresh-Mac full model download remains an explicit validation boundary.

### 2026-09-10 — Frozen Margin model comparison

Added developer-only MARGIN_SUITE_EXPORT entry before normal UI startup. It exports live production prompts, schemas and fixtures; no provider tools execute. Extracted existing research/learning prompts into shared constants without changing their content. The Python comparison runner records three serial repetitions, frozen clock/settings/source hashes and raw output. Nine grader checks cover wrong times, omitted arguments, blank refusals, invalid citations, unsupported facts, learning escalation and incomplete responses. Reports separate deterministic paths, raw model capability probes, infrastructure events and unrun cases. Runtime model identities are checked directly on the mini rather than through fallback-capable HomeLLM slots.

### 2026-09-11 — 16 GB candidate screening

Added Granite 4.2-8B and Qwen3.5-4B to the model catalogue and opt-in, disk-budgeted downloads to the serial controller. New timestamped run 20260911T101545Z-16gb-candidates includes Qwen3.5-9B. Removed three tested local packages at user request, preserving reports. Nine grading tests pass; no Swift app changes or installation.

### 2026-09-11 — Empero evaluation

Added serial predecessor waiting and opt-in publisher GGUF download verification for the Empero Qwen3.8-4B distillation eval. Pinned checksum before alias creation; nine grading unit tests passed. Existing active frozen runner unchanged.

### 2026-09-12 — Empero LoRA planning

Created docs/margin-empero-lora-plan.md at user request. Plan targets seven repeated failure cases with balanced data, scenario-family-separated holdouts, BF16 LoRA preflight, quantized-export verification and 16 GB deployment gates. Planning only; no training or deployment initiated.

### 2026-09-12 — Workstation LoRA pilot and dashboard

Created an isolated Empero BF16 LoRA project on Temple-Workstation under Documents/Projects/Margin-Empero-LoRA, with validated synthetic development data, pinned base revision, training scripts and a read-only live dashboard via SSH at http://127.0.0.1:18766. Initial smoke failed before optimization on adapter module matching; corrected to leaf names and restarted. Training completion and quality gains remain unverified.

Smoke setup follow-up: adapter matching and text-processor handling corrected. Assistant-only labels use offset mappings across the thinking-template boundary. CPU validation checked every train/validation example (3,400 total), maximum lengths 5,480/5,488 tokens. Smoke reached the training loop with 32,464,896 trainable parameters; completion is not yet established.

Workstation smoke reached step 10/20, saved artifacts/smoke/checkpoint-10 and reported eval loss 0.3959 before the next training forward failed on insufficient fused-loss GPU memory. Validation now requests loss-only output, disables KV caching and clears unused CUDA allocations after evaluation; resumed checkpoint run is in progress. Historical failure logs are retained. Full pilot is not yet launched.

Smoke completed at 2026-09-12 01:31:21 UTC (2026-09-11 18:31:21 PDT): 20/20 optimizer steps, final validation and adapter save passed; tensor checks confirm finite nonzero adapter updates. Dashboard API reflects smoke_complete. Full pilot remains gated on export/reload preflight.

### 2026-09-12 — LoRA continuation

Resumed the authorized pipeline after stopping prematurely at smoke completion. Adapter reload produced the expected JSON; safe merge completed. Building and testing both base-control and adapted Q4_K_M exports before the full pilot. Export transport checks are separate from the original failed-category eval, which has not yet been rerun.

Export gate caught a real load failure: plain Transformers save repeated language_model prefixes and omitted 15 mtp.* tensors while preserving the declared auxiliary layer. Base-control JSON/tool checks passed; adapted Ollama load failed on missing blk.32.attn_norm.weight. Added strict canonical mapping to original tensor keys, preserving only untouched source MTP tensors. Re-export is pending; full pilot remains blocked by this engineering check, not user authorization.

Full pilot launched at approximately 2026-09-12 02:45 UTC through the persistent limited-permission Windows task after all four quantized transport checks passed. Live dashboard confirms mode=pilot and loading_bf16. Source base is fresh, not the smoke adapter; no app deployment.

Verified full-pilot advancement at 2026-09-12 02:48:46 UTC: 2/188 optimizer steps, loss 0.3853803, finite gradient norm 1.5025; NVML total GPU usage 13,331 MiB. Windows task reports Running, start 2026-09-11 19:45:08 PDT. Pilot and monitoring sidecar continue independently of the Mac SSH connection. Checkpoints every 10 steps; full eval and deployment remain pending.

Full pilot completed 188/188 steps on 3,000 examples at 2026-09-12 04:49:40 UTC. Final adapter and checkpoint-188 saved; mean train loss 0.01236, monitoring validation loss 0.01070 on 32 examples. Runtime 7,339 seconds. Original output-based eval and independent holdout checks remain unrun; no app model changed.


### 2026-09-12 — Completed pilot evaluation

Final serial LoRA comparison completed 2026-09-12 05:55:50 UTC (Sept 11 22:55:50 PDT): control 267/288, pilot 279/288, zero infrastructure errors. All seven original failures fixed 3/3; three new regressions (routing-43 missing destination, args-4 missing all_day flags, research-1 missing citation), each 3/3. Critical count 12→3; median 4.94→3.94s, p95 11.46→7.67s. No promotion. Timestamped comparison.html includes assessment and raw-evidence links.


### 2026-09-12 — Pilot 2

Pilot 2 launched as persistent Windows task Margin-Empero-LoRA-Pilot2-20260912 in a separate Projects folder. All 3,000 original rows retained unchanged plus 600 new rows (200 each date destinations, all-day batches, cited research). Schemas passed for 4,660 train/validation/generated-heldout rows. Seventeen separately authored development holdouts frozen before training; original 108-fixture suite unchanged. Artifacts use D: (717 GiB free); pinned base, fresh rank-16 adapter and original training settings retained. Durable task trains then exports; Mac controller scripts/margin-lora/finish_pilot2.py waits for success then verifies/imports and runs serial regression + holdout comparisons. Dashboard http://127.0.0.1:18768. Live loading_bf16 observed; optimizer progress pending.


2026-09-12: User reserves workstation GPU after current pilot-2 training. Automatic GPU export replaced by an approval hold, with original export script preserved as export-pilot.awaiting-approval.sh. Mac auto-eval watcher stopped. Obtain explicit user approval before ANY further workstation GPU use after current training completes. Current training continues (196/225 observed).


2026-09-12: User explicitly granted workstation again. Export hold lifted. ComfyUI queue was empty; its cached model unloaded through /free without stopping the service, restoring 14,392 MiB free VRAM. Pilot-2 export and Mac sequential-eval watcher resumed. First remote launch had a shell quoting error before execution; direct script invocation started afterward.


2026-09-12 Pilot 2 review: completed 267/288 original regression requests; fresh holdout 36/51 versus base 24/51. Zero infrastructure failures. Do not promote: missing all_day, invented move times, and quoted-text memory contamination remain. Grader defects: research-2 false negative, routing-43 semantic false pass, and p2-memory omitted from critical counter (holdout reviewed critical 12 vs automated 9). Frozen scores preserved. Assessment: docs/evals/margin-lora/pilot2-preparation/assessment.html. No third training authorized/launched; recommend data-rendering and evaluator audit first.


### 2026-09-12 — Offline evaluator and serialization audit

Implemented isolated scripts/margin-model-eval-v2 with explicit severity metadata and corrected date-move/price-uncertainty fixtures. Seven new tests and nine legacy tests pass. Replayed saved responses without inference: base regression 264/288, Pilot 1 279/288, Pilot 2 267/288; fresh holdout base 24/51 (9 critical), Pilot 2 36/51 (12 critical). Original evidence unchanged. Workstation SSH unavailable, so reconstructed dataset locally; all three split hashes match the saved workstation manifest. CPU-only pinned tokenizer audit preserves fields and supervised boundaries; saved post-Unsloth tokenizer equivalence remains unverified until workstation access returns. Empty thinking blocks in training versus reasoning in all 288 Pilot-2 regression responses is a possible mismatch, not a proven failure cause. No GPU work or new training.


2026-09-12: Workstation saved-tokenizer audit completed on CPU. All 4,060 actual training/validation rows match the pinned source tokenizer in both rendered text and token IDs (8,120 comparisons each across completed targets and generation prompts). No mismatches. This closes the previously pending post-Unsloth tokenizer equivalence check. Training serialization is not the observed cause; thinking-mode mismatch remains a hypothesis. No GPU inference or new training. Evidence: docs/evals/margin-lora/pilot2-preparation/audit-v2/saved-tokenizer-audit.json.


### 2026-09-12 — Workstation thinking-mode experiment

User authorized workstation GPU for on/off test. Existing Ollama 0.17.1 failed compatibility (not scored). Installed official portable Ollama 0.30.10 separately at D:/llm/margin-ollama-0.30.10, loopback port 11436, isolated model store, maximum one resident model and one request. Existing runtime unchanged. Native think=true/false works on matching runtime; raw-template fallback was prepared but not executed. Frozen 20-case, 3-repetition, 3-model, 2-mode experiment = 360 scored requests plus preflight. Original system prompts/tool schemas/learning JSON format retained; only think changes. GPU residency verified through /api/ps and nvidia-smi (~5 GiB total usage). Source GGUF base/Pilot1/Pilot2 imported into diagnostic aliases. Results at docs/evals/margin-lora/pilot2-preparation/thinking-experiment/. No new training or app default change.


2026-09-12 Thinking experiment complete on RTX 5070 Ti / isolated Ollama 0.30.10. 360 scored requests, no infrastructure failures: base on/off 27/60 vs 39/60 (critical 18 vs 6); Pilot 1 36/60 vs 42/60 (critical 9 vs 9); Pilot 2 33/60 vs 39/60 (critical 12 vs 9). Native switch preflight passed for each model; all off responses had no reasoning trace. Pilot 1 off is best diagnostic configuration but not release-ready; all-day/date-time failures remain. No new training or app change. All models unloaded at completion. Unload timing assertion interrupted after base; continuation preserved all base records and waited for empty runtime before subsequent models. Report: docs/evals/margin-lora/pilot2-preparation/thinking-experiment/analysis.html.

Thinking-run review caveat: base/off research-1 answers “A credit card is not required [1]”; existing no/without/not-before-card regex rejects this valid wording 3/3. Original scores preserved. Recognizing the wording would tie base/off with Pilot 1/off at 42/60, so no definitive model winner is established.


### 2026-09-12 — Safeguards and DPO pilot preparation

Added deterministic pre-proposal checks for explicit all-day flags, omitted English/ISO dated entries, and invented times on date-only moves. Memory persistence now rejects evidence wholly inside quoted/fenced content and conservatively filters known third-party contexts. These are bounded guards, not a complete intent parser; refusal is not counted as successful completion. App Debug build passes; 11 focused request fixtures and 45 roadmap guards pass. No consumer installation/default changed.

Evaluator v3 preserves v1/v2 and accepts reversed no-card wording, with 9 focused tests passing. DPO corpus: 576 train/64 validation pairs across seven categories, explicit synthetic rejected mutations, all preferred tool targets schema checked; not human feedback. Fourteen fresh developer holdouts frozen before training. Workstation project C:/Users/oluyi/Documents/Projects/Margin-Empero-DPO; artifact storage D:/llm/Margin-Empero-DPO-artifacts. Fresh base QLoRA, rank 16, beta .1, LR 1e-5, full 8192-token context. Resource preflight is 4 steps; full pilot intended 72 steps, gated on finite actual adapter update and GPU release. Initial TRL optional mergekit import disabled only in process (unused integration); Qwen multimodal detection required selecting text-only dataset preprocessing. First attempt stopped before optimization and is retained. Live dashboard http://127.0.0.1:18772/.


2026-09-12 20:42 UTC: Optimized DPO resource preflight passed all 4 optimizer steps, saved an adapter, and passed nonzero LoRA-B verification. Peak allocated 10,103,027,712 bytes (~9.4 GiB), versus ~15.6 GiB in the aborted full-logit attempt. Full 576-pair/72-step pilot automatically started through the persistent Windows task after GPU release; live state loading_4bit_base mode=pilot at 20:42:19 UTC. Completion-only logits retain full prompt context and do not alter the chosen/rejected examples. No model promotion or consumer installation.

### 2026-09-13 — Pilot 1 Mac selection and managed distribution

Selected Pilot 1 on margin only; added checksum-pinned HF GGUF import and safe model-specific cache paths. Published explicitly approved weights to olluyeancah/margin-pilot1-gguf. Developer-only native model overrides and isolated managed-install tests preserve live app settings. Native 76/78, known safe misses retained; eight-holiday batch passes. Runtime 0.30.10 pinned; 17 GB initial disk reserve accounts for importer conversion scratch. See pilot1-mac-validation reports for exact evidence and pending clean-install status.
