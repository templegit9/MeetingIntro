# Assumptions

## Calendar Source
- **Assumption:** We support **both** Apple EventKit and Microsoft Graph API as calendar sources. A `CalendarProvider` protocol abstracts the two, and the user selects their preferred source in Settings.
- **Rationale:** EventKit is simpler and works offline for users with accounts in macOS Internet Accounts. Graph API enables access for users who haven't configured their Microsoft account locally or need direct Outlook integration.
- **Status:** ✅ Confirmed by user

## Audio Playback
- **Assumption:** The user selects a local audio file (mp3, m4a, wav) via an `NSOpenPanel` / file picker. We use `AVAudioPlayer` for playback.
- **Status:** ✅ Accepted

## Countdown Overlay
- **Assumption:** The overlay is a borderless, always-on-top SwiftUI window that shows a countdown timer and meeting title.
- **Status:** ✅ Accepted

## Target macOS Version
- **Assumption:** macOS 14 (Sonoma) minimum. This lets us use modern SwiftUI APIs like `MenuBarExtra`.
- **Status:** ✅ Accepted

## App Distribution
- **Assumption:** Initially for personal use — no App Store submission needed. Developer ID signing is sufficient.
- **Status:** ✅ Accepted

## Margin calendar changes and history (2026-09-10)

A time-only reference such as “3pm” means today; a supplied original date distinguishes another day. Repeated names require disambiguation. Only individual occurrences are supported, not whole-series operations. Microsoft Graph changes require organiser authority; attendees are directed to RSVP. EventKit removal may notify other people according to its calendar service. Calendar changes have no automatic undo in this implementation. History design remains a proposal; the existing in-memory conversation is not a persisted archive. Live provider writes and notification delivery need separate verification with an explicitly chosen test event.

Personality preferences shape the prompt without granting new authority. Explicit saved preferences and conversation history default off independently. History retains up to 100 conversations / 100 entries per conversation for the selected 7/30/90 days. Proactivity preserves existing gentle nudges by default; quiet and ribbon modes reduce interruptions and never authorize autonomous writes. Evals remain developer-only.


## 2026-09-10 — Back-of-book history and capability mapping

History preference is the updated 1C back-of-book index, not a modal. Cmd-K currently applies while the notebook is focused. Cloud execution, browser control and multi-agent orchestration are capability-map gaps, not authorized implementation scope.


## 2026-09-10 — Batch calendar, research and standing work

User chose Brave Search API with a key entered later, and chose design-first for browser control, email sending, cloud workers and multiple agents. The initial bounded multi-step workflow is calendar batch creation; arbitrary cross-tool planning is not claimed. Date-only explicit lists prepare all-day events; titles, year, destination and count remain reviewable. Brave live validation is pending the user key.


### 2026-09-10 — Resting notebook and evolving preferences

Open Margin now fades to the selected resting opacity after 60 seconds without notebook input (30/60/120/300 seconds or Never in settings). Pointer hover does not wake it. The first click is consumed; click or Option-Space wakes the existing page and draft. Preparing or executing actions keeps the notebook visible. AppKit event observation is limited to this panel; SwiftUI renders the fade.

Memory and soul learn independently from new user messages after the foreground answer, using the configured local model without tools. No file, transcript or web result is passed to reflection. The small category allowlist bounds what can be retained; model filtering of sensitive/one-off content remains probabilistic. Entries carry a verbatim evidence quote, update date and previous value. Explicit notes take priority; editing pins an entry and forgetting persists a category tombstone. New configurations enable learning, while existing explicit memory-off settings remain off; history saving remains independent and opt-in. New requests cancel background reflection. No learned state grants permissions or changes proactivity settings.

Reflection is an initial bounded implementation, not a claim of longitudinal personality accuracy: it sees one new user message at a time, supports twelve preference categories, and keeps only the previous value rather than a full revision log.


### 2026-09-10 — Inactivity returns to the cover (user correction)

Supersedes faded-open-page behavior: idle now closes to the small notebook cover at the saved resting opacity. Hover and pending suggestions do not brighten or expand the idle cover; clicking or Option-Space reopens it. Active work still postpones rest. Draft storage moved from page-local State to a controller-owned binding so removing the page view cannot discard unsent input; conversation and Index selection remain in their existing owners.


### 2026-09-10 — Comprehensive categorized developer eval

Expanded to 78 routing cases spanning all 29 registered tools, plus existing deterministic guards and six live learning scenarios (style, one-time request, correction, working hours, credentials and permission escalation). A seventh learning-related pause check is deterministic. Reports show one selected run, category totals, separate check types, failed checks first, untested boundaries and historical runs. Every new run has immutable artifacts, runner start/end timestamps, per-routing-case timestamps, a planned-case manifest and binary hash. Infrastructure failures produce non-scored records and continue until three consecutive failures. Old runs keep their original recorded timestamps without invented start/end times.

The comprehensive baseline exposed a learned refusal stored as a soul preference; the raw failure is retained. A downstream pause assertion used a stale baseline. Its explicit run-review.json marks that evidence invalid (not passed), and the fixture now captures state immediately before pausing. Seven report-accounting tests cover timestamps, missing cases, failed guards, infrastructure separation, invalid-test review and registry coverage.


### 2026-09-10 — Provisioned web research

At the user’s request, their clipboard credential was pasted directly into Margin’s secure field and saved through the app to macOS Keychain; the UI confirmed success. The key was not read into the assistant context or copied into source/artifacts. Removed the entire Web research setup section (key field, source count and signup link). Runtime continues to use the existing Keychain account across app updates, on this Mac. Updated missing/rejected-key errors so they do not direct users to a removed settings control. This is per-Mac provisioning, not a credential distributed inside the binary.

### Margin automatic AI setup — 2026-09-10

- Automatic setup targets Apple silicon Macs with at least 16 GB memory and 19 GB free storage, using the bundled approximately 14 GB model/runtime manifest. Existing working local services can be reused independently of this download compatibility gate.
- The intro appears before first enable; Not now leaves it off. Existing enabled users do not see repeated onboarding on update, but missing AI still requires explicit download approval.
- Model files survive app updates in Application Support. Disabling Margin stops its owned runtime, not an existing service. Cancellation keeps completed model layers; retries verify completion before enabling input.
- Runtime download hashes and model digest are pinned; an upstream tag change requires a qualified app update. Fresh-Mac full-model transfer, broader hardware performance and notarized release installation are not established by isolated lifecycle checks.

### Margin comparison boundaries — 2026-09-10

The comparison runs sequentially on a 24 GB Mac mini using its direct loopback Ollama endpoint. The HomeLLM slot API is intentionally not used because automatic substitution would invalidate model identity. Existing model files are retained; one-at-a-time means loaded for inference. The current profile constrains context/output for a practical desktop workload. A frozen syntax/regex assertion suite is not a universal semantic judge. Synthetic source grounding and simulated recovery do not establish live web research or provider-write reliability. Larger models may be hardware-blocked; a result on this mini cannot claim performance across all supported Macs.

### 2026-09-11 — local candidate queue supersedes mini

Current queue runs Granite 4.2-8B then Qwen3.5-9B then Qwen3.5-4B on the 24 GiB laptop. User permits removal of tested model packages; only local GPT-OSS-20B, Gemma4-12B and Qwen3-8B were removed. Reports remain. Downloads are authorized for these three new candidates. A 16 GB target is a screening objective, not an emulated or verified host.

### 2026-09-11 — Empero evaluation

Empero Qwen3.8-4B-Distill is a community full-parameter distillation on Qwen3.5-4B architecture. First eval uses common Margin settings, not publisher-recommended sampling/long output; recommendations are not evidence of performance. Scheduled after current Qwen3.5-4B run; not yet scored.

### 2026-09-12 — Empero LoRA planning

Created docs/margin-empero-lora-plan.md at user request. Plan targets seven repeated failure cases with balanced data, scenario-family-separated holdouts, BF16 LoRA preflight, quantized-export verification and 16 GB deployment gates. Planning only; no training or deployment initiated.

### 2026-09-12 — Workstation LoRA pilot and dashboard

The 4,000-example generated corpus is a synthetic development set, not an independently authored adversarial holdout. Structural validation covers all rows; 27/29 tools have training examples. The dashboard is HTTP/API and syntax verified; native browser rendering was unavailable. A live dashboard or falling loss does not establish repaired critical checks, export compatibility or 16 GB Mac performance.

Workstation smoke reached step 10/20, saved artifacts/smoke/checkpoint-10 and reported eval loss 0.3959 before the next training forward failed on insufficient fused-loss GPU memory. Validation now requests loss-only output, disables KV caching and clears unused CUDA allocations after evaluation; resumed checkpoint run is in progress. Historical failure logs are retained. Full pilot is not yet launched.

### 2026-09-12 — LoRA continuation

Resumed the authorized pipeline after stopping prematurely at smoke completion. Adapter reload produced the expected JSON; safe merge completed. Building and testing both base-control and adapted Q4_K_M exports before the full pilot. Export transport checks are separate from the original failed-category eval, which has not yet been rerun.

Full pilot launch now uses a limited-permission Windows scheduled task with no automatic trigger, and a local monitoring sidecar. This avoids dependence on the Mac SSH process. A differential APFS-clone transfer stalled in host file I/O; a fresh non-cloned SCP destination progresses. This is infrastructure evidence, not a model eval failure.


### 2026-09-12 — Completed pilot evaluation

The completed pilot regression eval is not independent holdout validation or 16 GB hardware verification. Current checkpoint is not qualified for promotion: one critical batch case fails all three repetitions and overall accuracy is 96.875%, below the 97% gate.


### 2026-09-12 — Pilot 2

Pilot 2 fresh holdout is 17 manually authored development cases, not independently authored external review. Three repeated tests per case assess regression stability, not statistical independence. 600 original generated heldout rows remain excluded from training. No promotion without review of both suites and remaining hardware/holdout gates.


2026-09-12: User reserves workstation GPU after current pilot-2 training. Automatic GPU export replaced by an approval hold, with original export script preserved as export-pilot.awaiting-approval.sh. Mac auto-eval watcher stopped. Obtain explicit user approval before ANY further workstation GPU use after current training completes. Current training continues (196/225 observed).


2026-09-12: User explicitly granted workstation again. Export hold lifted. ComfyUI queue was empty; its cached model unloaded through /free without stopping the service, restoring 14,392 MiB free VRAM. Pilot-2 export and Mac sequential-eval watcher resumed. First remote launch had a shell quoting error before execution; direct script invocation started afterward.


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
