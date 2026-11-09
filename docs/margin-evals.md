# Margin developer evals

These are operator/developer tools. There is no eval screen, score, or run button in the consumer notebook or settings.

## Run

Build the exact branch binary first:

```sh
xcodebuild -project MeetingIntro.xcodeproj -scheme MeetingIntro -configuration Debug \
  -derivedDataPath /private/tmp/margin-resume-build build
scripts/eval-margin.sh \
  /private/tmp/margin-resume-build/Build/Products/Debug/MeetingIntro.app/Contents/MacOS/MeetingIntro
```

The runner branches before SwiftUI app startup, so it opens no settings windows, starts no calendar polling, mirrors, reminder loops, or folder jobs, and does not replace the installed app. Fixture preferences and file grants are isolated. It uses the configured local model and endpoint, with the default Calm persona and no saved user memory.

The default report directory is `docs/evals/margin/run-<UTC timestamp>/`. It contains:

- `results.json`: each prompt and context, expected/actual tool, arguments, selected argument checks, dispatch mechanism, latency, completion state.
- `run.log`: deterministic guard results and routing progress.
- `base-commit.txt`, `working-tree.txt`, `binary-sha256.txt`: identifies the evaluated executable and its source base. The binary hash is authoritative for an uncommitted build; a diff stat is not a complete source snapshot.

`MARGIN_EVAL_CONTEXT_ONLY=1 scripts/eval-margin.sh <binary> <new-directory>` limits cases to the eight conversation regressions plus the explicit permanent-deletion regression. It still runs deterministic guards. `MARGIN_EVENT_SELFTEST=1 <binary>` runs only calendar and behavior guards, without a model.

## Coverage

- 42 standalone routing cases across the registry, including unsupported requests.
- 8 multi-turn cases: capability questions after dismissed PDF results (the reported screenshot), a capability paraphrase, switching from files to tasks, file refinement, and moving/cancelling after previous intents.
- File guards: filterless Trash, filtered proposals, granted roots, rename path handling, destination authorization.
- Calendar guards: time references, original-date disambiguation, duplicate recurring identities, cancellation exclusion, ambiguity, invalid dates.
- Behavior guards: opt-in memory, preference persistence and inclusion, history reload, inert historical proposals, the capabilities regression through `send()`, and exactly-once confirmation under concurrent clicks.

Clear capability queries use deterministic product dispatch; reports explicitly mark those cases. They are not evidence of model routing skill. Remaining cases call the local model. Move/cancel cases check a title or exact original time, plus a parseable new start for moves, but this is not complete semantic validation of all arguments.

Infrastructure failures stop the run, write `complete: false` and an error, and are not counted as model refusals. A completed report can still contain failed cases. The command exits nonzero on a routing or guard failure. Each row is written as it finishes; a valid prefix does not make an interrupted run complete.

## Boundaries

No live provider mutation or attendee delivery is tested. Routing accuracy alone does not establish filesystem execution, correct rendered UI, or calendar correctness. Native settings/history inspection and real-account recurring-event tests are separate checks. Latencies are observations on the current machine, including model cold start; they are not a controlled performance benchmark.

## 2026-09-10 findings

The first complete run scored **49/50**, with **28/28** deterministic guards. Its failure was an explicit permanent-deletion request being substituted with `trash_files`. A deterministic refusal now handles clear requests for permanent deletion, without misclassifying a search for text about deletion. The failed run is retained in `evals/margin/2026-09-10-resume/`.

The first focused rerun scored **8/9**, with **31/31** deterministic guards. `cancel my 2pm` returned the correct tool and exact `original_start`, but an empty title. The tool was safe (it refused), but could not use a valid precise selector. The implementation now accepts title or exact original start, refuses a missing selector, and retains ambiguity when multiple events start at that time. That run is retained in `evals/margin/2026-09-10-regression/`. The final focused rerun passed **9/9**, with **34/34** deterministic guards; see `evals/margin/2026-09-10-regression-v2/`. This is a focused rerun, not a new full 50-case result.

## HTML report

Open [the standalone report](evals/margin/report.html). It contains all retained runs, a run selector, failure/multi-turn/dispatch filters, search, and expandable contexts and arguments. Regenerate with `python3 scripts/render-margin-eval.py`; `scripts/eval-margin.sh` also regenerates it after either a passing or failing run. The report is self-contained and makes no external requests. Its data and JavaScript syntax were checked; automated browser opening of the local file was blocked by browser security policy, so rendered browser verification is not claimed.

Validation: `2026-09-10-learning-idle-v3` passed 80 deterministic checks and two live local-model learning checks (82/82 combined), with no routing cases requested. v1/v2 learning failures are retained. HTML run badges now include guard failures, and each run links its check log. JSON grammar constraints follow https://docs.ollama.com/capabilities/structured-outputs; evidence and category validation still run after decoding. Native idle/wake verification is recorded separately below.


### 2026-09-10 — Comprehensive categorized developer eval

Expanded to 78 routing cases spanning all 29 registered tools, plus existing deterministic guards and six live learning scenarios (style, one-time request, correction, working hours, credentials and permission escalation). A seventh learning-related pause check is deterministic. Reports show one selected run, category totals, separate check types, failed checks first, untested boundaries and historical runs. Every new run has immutable artifacts, runner start/end timestamps, per-routing-case timestamps, a planned-case manifest and binary hash. Infrastructure failures produce non-scored records and continue until three consecutive failures. Old runs keep their original recorded timestamps without invented start/end times.

The comprehensive baseline exposed a learned refusal stored as a soul preference; the raw failure is retained. A downstream pause assertion used a stale baseline. Its explicit run-review.json marks that evidence invalid (not passed), and the fixture now captures state immediately before pausing. Seven report-accounting tests cover timestamps, missing cases, failed guards, infrastructure separation, invalid-test review and registry coverage.

Comprehensive run `20260911T034323Z-comprehensive`: started 2026-09-10 20:44:22 PDT, finished 20:55:56 PDT. All 78 routing cases ran, covering 29/29 tools: 75 passed and 3 failed (daily Documents organization routed to create_event; two move_event cases omitted the new time). Deterministic checks: 80 valid passes; live learning: 5/6 pass, with permission-escalation refusal incorrectly retained as a soul entry. One stale-baseline pause assertion is explicitly invalid and excluded, not counted as a pass. Aggregate: 160 pass, 4 fail, 1 invalid test, no infrastructure errors or unrun cases.

Provisioned-search Release build installed and signature verified: `ffe92eaaa5b7d98a97ffb91e4427c7f3afcf943cbbd8516f1a34baf5e89ebcf9`. Native settings inspection confirms the web setup section is gone. This is newer than the comprehensive test binary only in settings removal, related error copy and the corrected pause fixture; the historical comprehensive result remains tied to its saved binary hash.

Post-update native verification: the web setup section is absent. One public Brave request successfully retrieved five excerpts using the saved Keychain credential; the local model did not produce a reliably cited brief and the app showed its honest source-excerpt fallback. Recorded as separate retrieval pass and brief-generation failure in native-checks.json, not merged into the automated score.

## Cross-model comparison (2026-09-10)

### September 11, 2026, 01:07 PDT — Gemma cancelled, Qwen3-8B next

User requested stopping Gemma due to latency and moving to the next model. Terminated the local controller and Gemma runner, unloaded Gemma, retained completed case records and marked its run cancelled rather than completed. GPT-OSS had completed beforehand. Started installed `qwen3:8b` in a [new timestamped report](evals/margin-models/20260911T080711Z-qwen3-local/report.html), with the same 108 fixtures, three repetitions and inference settings. This older installed model is distinct from the mini's Qwen3.5/Qwen3.8 candidates. No download or mini workload changes. The frozen previous runs are retained; only Gemma's cancellation metadata and derived report were updated.

### Local two-model comparison — September 11, 2026, 00:02 PDT

Superseded by [fresh local run at 00:03:55 PDT](evals/margin-models/20260911T070355Z-local/report.html). The 00:02 run stopped after one passing model response because the swap-growth guard included initial model loading. The new run retains initial and post-load swap separately and applies the same 2 GiB growth threshold from the post-load baseline. This changes resource-stop accounting, not prompts or scoring; it does not establish that host memory pressure is absent. The earlier raw result is retained.

At the user's direction, moved the comparison to this Mac using only installed `gpt-oss:20b` and `gemma4:12b`. [Live timestamped HTML report](evals/margin-models/20260911T070224Z-local/report.html). This is a new run, separate from the interrupted mini results. Each candidate has the same 108 fixtures and three repetitions (288 model requests plus 36 deterministic dispatch records). No downloads. The controller runs GPT-OSS first, verifies unload, then starts Gemma; an incomplete run or a loaded competing model stops the queue. Reports regenerate every ten seconds. A private copy of the frozen harness lives with the run so subsequent source edits cannot change the running evaluation. Initial preflight: no loaded model, about 6 GiB disk free. Completion must be read from the report or queue-status.json, not inferred from launch.

### Mini run interrupted — September 10, 2026, 23:26 PDT

[Timestamped comparison report](evals/margin-models/20260911T061120Z/report.html): Qwen3.5-9B produced 35 valid model responses, all passing, before the memory-pressure guard stopped the run. These are a partial prefix, not a completed comparison or evidence of repeatability. The other candidates have not run. Reported latency is affected by this host state and should not be used to select a model.

The mini has 24 GiB RAM. Swap used rose from 53,589,835,776 to 57,105,711,104 bytes during the run, exceeding the 2 GiB growth limit. The runner recorded no model loaded after cleanup. A later queue check found Qwen loaded again with a 4,096-token context instead of the evaluation's 8,192, indicating shared-service activity after cleanup. The queue stopped without loading another model. Other clients must be paused and memory pressure resolved before a fresh timestamped comparison. No background user processes were terminated.

The controller now also refuses to advance after any incomplete candidate, even if cleanup leaves Ollama idle. Frozen scoring files and historical results are unchanged. Grading unit tests: 9 passed. HTML generation and data were checked; rendered browser verification is not claimed.

The developer comparison lives in `scripts/margin-model-eval/`. A headless app export supplies the exact production system prompt, 29-tool schema, original 78 routing fixtures, research instructions and learning instructions/schema. Additional fixtures raise the frozen suite to 108 cases. Assertions now check selected explicit arguments, batch completeness, supplied citations/facts, bounded learning extraction, timezone arithmetic and recovery after synthetic feedback. Capability probes and simulated recovery are labeled; they are not proof of live multi-step provider execution.

Three repetitions per candidate; profile: temperature 0, 8,192-token context and 2,048 generated tokens, native default thinking, 120-second request timeout. Frozen reference time is 2026-09-10 noon America/Los_Angeles. Model scores exclude deterministic dispatch. Exact model digest, runtime, clock, source and suite hashes, per-case timestamps, cold start, latency, sampled process RSS, runtime GPU allocation and swap are retained. Incomplete and missing models cannot win. A single model is loaded at a time; each switch unloads the previous model. Concurrent model observations invalidate the affected result and stop that run.

Mac mini is reachable over SSH at the user's configured host. Its Ollama API is loopback-only and is used from the mini, avoiding HomeLLM slot substitution. Both available Macs have 24 GB RAM. The mini already holds Qwen3.5-9B and Qwen3.8-27B; GPT-OSS-20B and Gemma 4 12B are on the laptop. Storage and memory limits are recorded, not treated as model quality failures. The first cold preflight returned READY but failed the single-model identity check; no cases were scored. That incident remains separate from the subsequent frozen run with richer identity diagnostics.

### September 11, 2026 — candidates for a 16 GB system

User authorized removal of previously tested packages. Removed local gpt-oss:20b, gemma4:12b and qwen3:8b through Ollama; historical raw evaluations remain. Free disk rose from about 7 to 32 GiB before downloads. Started [Granite 4.2-8B, Qwen3.5-9B and Qwen3.5-4B](evals/margin-models/20260911T101545Z-16gb-candidates/report.html), sequentially, three repetitions of the same 108 fixtures. Controller downloads only these budgeted packages when missing and keeps a 3 GiB disk reserve. Host is the 24 GiB laptop running Ollama 0.30.10. This screens correctness, latency and memory allocation; it does not certify a 16 GB machine. No app default model was changed. The previous default GPT-OSS package is no longer installed. Grader unit tests: 9 passed.

### September 11, 2026, 04:07 PDT — Granite skipped for latency

At user request, terminated Granite and its controller, unloaded the model and marked its partial run cancelled. Retained 70 passes, 4 scored failures and 5 infrastructure errors; 209 model requests were not run. Median valid-response latency was 20.8s, p95 111.8s. This supports deprioritizing it for responsiveness, not a full accuracy comparison. The new [Qwen3.5-9B then 4B queue](evals/margin-models/20260911T110720Z-qwen35-local/report.html) uses unchanged fixtures/settings, serial inference and an explicit 24 GiB host versus 16 GB target limitation.

### Qwen restart — 2026-09-11T21:16:28.810064+00:00

User requested a restart after the 9B run stopped on consecutive request timeouts. New [timestamped report](evals/margin-models/20260911T211628Z-qwen35-restart/report.html). Copied the previous frozen runner and retained identical prompts, scoring, 120-second timeout and inference settings. Order remains Qwen3.5-9B then 4B. Previous incomplete results remain intact. Preflight: Ollama responding, no loaded models or active prior eval processes, approximately 21 GiB disk available.

### Qwen3.5-4B — 2026-09-11T23:00:54.598198+00:00

User approved moving to 4B after the second incomplete 9B run. New [timestamped report](evals/margin-models/20260911T230054Z-qwen35-4b/report.html), using the same frozen runner, prompts, grading, 8K context and three repetitions. Previous results retained. Preflight: no model loaded, approximately 19 GiB disk available. Still a 24 GiB host screening for a 16 GB target, not target-device certification.

### Empero community distillation queued — 2026-09-11T23:59:47.260680+00:00

User requested https://huggingface.co/empero-ai/Qwen3.8-4B-Distill. Queued publisher Q4_K_M GGUF in a [separate timestamped report](evals/margin-models/20260911T235947Z-empero-qwen38-4b/report.html), after the existing Qwen3.5-4B run completes and unloads. If that run stops abnormally, the new controller holds. Download uses publisher GGUF repository, verifies SHA256 dec96e8cf2e11b613bb46513dec485377f9ca5a351e71712ee0e244f287c6790 from revision 391fc7d103e3942a408def3e4f51c2f85d464417, then creates local alias empero-qwen38-distill:4b-q4_k_m. No second inference model loads while predecessor runs. Publisher recommends sampling and long reasoning; this first compatibility screen retains the common Margin settings and labels that difference. No claim of official Qwen provenance or 16 GB validation.

Empero follow-up: predecessor stopped on swap guard; waiting queue held before download. Live check found no loaded models, swap down to 4.3 GiB and 16 GiB free disk. Started [fresh Empero run](evals/margin-models/20260912T000045Z-empero-qwen38-4b/report.html) after cleanup with unchanged guards. Earlier waiting manifest retained.
