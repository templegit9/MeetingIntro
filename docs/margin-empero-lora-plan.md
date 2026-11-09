# Margin Empero LoRA plan

Status: proposed implementation plan. No training, downloads, hardware reservation or deployment performed by this planning task. Prepared 2026-09-12 UTC.

## Objective and evidence

Adapt `empero-ai/Qwen3.8-4B-Distill` for Margin: improve unsupported-action handling, memory provenance, calendar arguments and temporal reasoning while preserving its responsiveness and small runtime footprint. Keep one inference model loaded at a time.

[Baseline report](evals/margin-models/20260912T000045Z-empero-qwen38-4b/report.html): 267/288 passed (92.7%), 21 failed, zero infrastructure errors; 89/96 model cases passed all three repetitions. The 21 failures represent seven distinct cases. Twelve critical failures represent four cases repeated three times. Median 4.76s, p95 11.01s; sampled process RSS peak 4.35 GiB on a 24 GiB Mac. These are model-output checks, not proof of provider execution or 16 GB compatibility.

The model is a community distillation using Qwen3.5 architecture. Start from the exact Empero Transformers/Safetensors checkpoint, not original Qwen3.5 weights and not the deployed GGUF. Pin its revision, tokenizer, configuration and chat template. Establish provenance between the training checkpoint and the evaluated publisher GGUF; if equivalence cannot be established, measure the training checkpoint's own unadapted export as an additional baseline. Publisher model description: [Empero model card](https://huggingface.co/empero-ai/Qwen3.8-4B-Distill).

## 1. Audit the seven failures before creating labels

| Priority / category | Observed failure | Training target and contrast examples |
|---|---|---|
| P0: unsupported actions | `empty the trash` calls `trash_files` | Explain permanent emptying is unsupported; no tool call. Contrast with explicitly filtered reversible trash requests. |
| P0: unsupported actions | Sending an email calls `create_event` | Decline sending; no calendar substitution. Contrast with a real meeting invitation containing attendees. Only offer drafts if actually supported. |
| P0: unsupported actions | Shell wipe calls `trash_files` | Decline shell execution/permanent deletion; do not silently reinterpret. Contrast with finding text about shell commands and authorized reversible file work. |
| P0: memory provenance | A quoted instruction becomes a soul preference | Return `[]` for quoted third-party preferences, task-only directions and document instructions. Contrast with direct, durable user preferences and explicit user adoption of a quoted preference. |
| P1: exact calendar arguments | Date-only move invents 15:00 | Supply `new_date`; omit `new_start`. Use the existing tool to preserve the actual meeting time. Contrast with explicit time changes and ambiguous selectors requiring clarification. |
| P1: calendar routing | `what’s on today?` selects `day_briefing` | Select `whats_on_today` for agenda contents and `day_briefing` for day analysis. Validate this distinction against product semantics before treating it as a training defect. |
| P1: timezone reasoning | 17:00 Los Angeles becomes 09:30 IST | On September 10, 2026, correct answer is September 11 at 05:30 IST. Generate labels with zoneinfo, covering summer/winter offsets, date rollover and ambiguous local times. |

Deliverable: reviewed failure taxonomy with source case IDs, expected behaviour and severity. Audit graders for valid alternative outputs, malformed argument handling and date parsing. Preserve historical scores; any grading correction creates a versioned suite and rescored baseline, never an undocumented score change.

## 2. Build balanced training data and protected evaluations

Initial proposed training budget: **3,000 reviewed examples**. This is an experiment size, not a claim that 3,000 guarantees success.

| Training category | Examples |
|---|---:|
| Unsupported-action boundaries, including valid near-neighbours | 900 |
| Memory/soul provenance, corrections and valid preferences | 600 |
| Calendar date/time arguments, ambiguity and preservation | 450 |
| Agenda versus briefing intent selection | 300 |
| Timezones and date rollover | 300 |
| Retention coverage: files, tasks, research, jobs, batch requests | 450 |
| Total | 3,000 |

Add **400 validation examples** for checkpoint selection and **600 sealed holdout examples** for final evaluation, independently authored with category coverage. Allocate at least 200 holdout examples to critical boundaries/provenance; include at least 100 positive permitted requests to detect over-refusal. Freeze this allocation before training.

Split by scenario/template family before generating variants. Names, dates or wording substitutions of the same template must remain in one split. Deduplicate exact strings and semantic near-duplicates. Keep original 108 fixtures entirely out of training; they remain a known regression suite, not independent generalization evidence. Do not train on repeated copies of the seven failing eval prompts. Train on the underlying rules with new scenarios.

Use synthetic folders, calendars, emails and documents. Do not import private transcripts or personal memory automatically. Every record retains category, source, expected action, review status, generator version, scenario-family ID and split. Validate JSON/schema, compute date labels deterministically, and manually review boundary/provenance examples. Teacher-generated labels require review; no paid teacher calls are assumed.

Represent each task exactly as production invokes it: router prompt plus tool definitions; learning prompt plus JSON schema; research prompt plus evidence. Preserve tool-call serialization and chat-template control tokens. Mask user/system/tool-result tokens from training loss; verify masks on real rendered examples. Train concise correct responses and structured outputs. Preserve useful reasoning behaviour with reviewed examples rather than inventing long explanations or uniformly stripping reasoning. [TRL supports conversational and tool-calling SFT; assistant-only masking depends on the template](https://huggingface.co/docs/trl/v1.1.0/en/sft_trainer).

Deliverables: train/validation/holdout manifests and hashes, JSONL data, label validators, deduplication report and readable category examples.

## 3. Training and export preflight

Preferred approach: **BF16 base + LoRA**, with a separate quantized deployment export. Current [Unsloth Qwen3.5 guidance](https://unsloth.ai/docs/models/qwen3.5/fine-tune) supports 4B tuning, recommends BF16, and warns against 4-bit QLoRA for this family. That guidance does not prove Empero compatibility or our exact memory needs.

Use an isolated CUDA training environment on an available workstation; verify GPU model, free VRAM, disk and running workloads first. Prefer 24 GB VRAM headroom; a 16 GB GPU is only a candidate pending measured preflight. The consumer 16 GB unified-RAM target is a separate inference requirement. Do not assume the Mac's Ollama installation is a training environment. No cloud spend until a concrete budget is authorized.

Pin PyTorch, CUDA, Transformers, PEFT, TRL and Unsloth versions that pass the checkpoint preflight. Inspect actual language-module names, including hybrid attention projections; do not blindly reuse a different Qwen model's module list. Keep vision components, embeddings and output head frozen initially. Inspect trainable-parameter counts and ensure gradients reach intended adapters. [PEFT LoRA configuration reference](https://huggingface.co/docs/peft/main/package_reference/lora).

Run a 32-example, 20-step engineering smoke test: finite loss, valid gradients, correct loss masking, measured peak VRAM, checkpoint reload and tool-call decoding. Tokenize the full production prompts and schemas before choosing sequence length. Start at 4K only if complete examples fit; support up to 8K where required. Never silently truncate tool definitions, user requests or target responses.

Before the full pilot, prove the round trip: load Empero → adapter train/save/reload → merge into a clean compatible base → GGUF Q4_K_M export → Ollama import → structured-call and JSON smoke tests. Check tokenizer, EOS/stop tokens and thinking tags. Verify an untrained/unmodified conversion as a control to separate conversion errors from training errors. Budget disk for source, checkpoints and merged/exported copies, not just the final 2.8 GB package.

## 4. Bounded pilot

Proposed starting configuration, subject to preflight: rank 16, alpha 32, dropout 0.05; learning rate 5e-5; microbatch 1, gradient accumulation 16, gradient checkpointing; one epoch first, maximum two. Record seed, token count, actual trainable modules and all hyperparameters. These are starting choices, not measured optima.

Train one rank-16 pilot. Select a checkpoint using category validation accuracy, critical failures, over-refusal and retention; training loss alone cannot select a winner. Permit one diagnosis-driven follow-up (for example lower learning rate, changed mixture or rank 8). Stop after two pilots to review evidence rather than running an open-ended sweep. Estimate duration and storage from measured smoke-test throughput before the full training run.

Controls: (A) unchanged Empero, (B) prompt-only candidate, (C) LoRA with baseline prompts. If combining prompt changes and LoRA later, evaluate that as a separately named arm. Use validation to select the candidate; run the sealed holdout only after selection. Once inspected, that holdout becomes regression evidence and must not be reused as an untouched final test for later rounds.

## 5. Acceptance gates — proposed, not achieved

Evaluate the **actual Q4_K_M Ollama package** at the same 8K context, temperature 0, 2,048-token output cap and 120-second request timeout as the baseline. Keep publisher-recommended sampling as a separately labelled diagnostic arm if needed. Measure three serial repetitions, recording every outcome and timestamp.

- All seven original failure cases pass all three repetitions; the 89 previously stable cases remain stable. Audit any legitimate alternate behaviour before grading, not after choosing a preferred model.
- Zero critical boundary/provenance failures on the sealed holdout across three repetitions. This is finite test coverage, not a guarantee.
- At least 97% scored accuracy overall on the holdout and at least 95% in each targeted category; permitted-request success at least 98%.
- All planned requests complete without infrastructure exclusions for acceptance. Preserve partial runs but do not select a winner from them.
- On matched host/profile: median no more than 5.5s and p95 no more than 13s, with no material increase in output length or sampled memory. These are proposed budgets based on baseline 4.76s/11.01s; rerun the unadapted control under the same background conditions.
- Verify inference on an actual 16 GB Mac: cold load, all categories, an hour of mixed usage and repeated load/unload. Provisional model-process RSS ceiling 6 GiB, memory pressure normal, and no sustained swap growth attributable to the model. Record other applications and total system state. Tests on our 24 GiB Mac cannot satisfy this gate.

Report raw model behaviour separately from application guards. Ensure the app still enforces granted roots, reversible file operations, preview/confirmation and memory authority boundaries even when a model emits bad output. Add fake-provider integration tests proving these rules and date-only time preservation. LoRA must not become the sole authorization mechanism.

## 6. Delivery and rollout

Produce adapter weights, training manifest, model/data hashes, pinned environment, exact merge/export commands, package checksum, category-level timestamped HTML comparison, failure examples and before/after latency/memory plots. Include label counts, contamination audit and untested boundaries.

Install only as a developer-selectable candidate first. Keep the original Empero package available for rollback. No consumer default change until inference-package, integration and 16 GB gates pass. This is a versioned product adapter, not continual per-user weight training; editable/evolving user memory remains application state.

## Execution checklist

- [ ] Review labels and graders; freeze failure taxonomy.
- [ ] Author, review and split data; seal holdout.
- [ ] Verify training hardware and checkpoint/export compatibility.
- [ ] Run smoke test and quantify compute/disk budget.
- [ ] Run first LoRA pilot and select with validation.
- [ ] Export and run full regression plus sealed holdout.
- [ ] Validate guarded integration and real 16 GB experience.
- [ ] Publish developer report and decide promotion or rollback.

Initial planning status superseded by the execution record below.


## Execution record — 2026-09-12 UTC

Workstation project created at `C:\Users\oluyi\Documents\Projects\Margin-Empero-LoRA`
on Temple-Workstation (RTX 5070 Ti, 16,303 MiB). Isolated WSL environment;
existing ComfyUI left running. Live developer dashboard:
[Training monitor](http://127.0.0.1:18766), reachable on the Mac while its SSH tunnel is connected.
Access/restart instructions: `scripts/margin-lora/README.md`.

Generated 3,000 training, 400 validation and 600 heldout synthetic development
examples; all pass structural validation. These shared-generator heldouts do
**not** satisfy the independent adversarial release gate above. Training coverage
is 27/29 tools. All 3,400 training/validation examples pass text-offset loss masking;
maximum lengths are 5,480 and 5,488 tokens, with no prompt truncation.

The engineering smoke reached 20/20 optimizer steps after resuming a saved
step-10 checkpoint. First attempts exposed adapter-name matching, processor vs
text-tokenizer and thinking-template-prefix issues. A later attempt exhausted
GPU memory after evaluation; loss-only validation, disabled KV caching and
CUDA cache cleanup were added. Historical attempt logs remain in the project.
Final validation/save completed at 2026-09-12 01:31:21 UTC; adapter tensors are finite and changed. Full pilot, GGUF round trip, original
output-based eval and 16 GB Mac verification remain pending. No app model changed.


### Continuation — 2026-09-12 02:45 UTC

Export/reload gate passed: base and repaired smoke Q4_K_M imports each passed JSON and native tool-call checks. Canonicalization restores exact source keys and 15 untouched MTP tensors omitted by merge serialization. Full 3,000-example pilot launched through Windows task Margin-Empero-LoRA-Pilot-20260912, with its own monitor and checkpoints every 10 steps. Live optimizer progress is being verified. Evidence: [preflight report](evals/margin-lora/20260912T021645Z-preflight/report.html).

Verified full-pilot advancement at 2026-09-12 02:48:46 UTC: 2/188 optimizer steps, loss 0.3853803, finite gradient norm 1.5025; NVML total GPU usage 13,331 MiB. Windows task reports Running, start 2026-09-11 19:45:08 PDT. Pilot and monitoring sidecar continue independently of the Mac SSH connection. Checkpoints every 10 steps; full eval and deployment remain pending.


### 2026-09-12 — Completed pilot evaluation

Pilot and serial comparison completed: 279/288 (96.875%) versus control 267/288, all seven original cases repaired, three new regressions. Do not promote. Next candidate should address missing move destination, all-day flags and research citations with rehearsal and fresh frozen holdouts. [Completed comparison](evals/margin-lora/20260912T045552Z-final-comparison/comparison.html).


### 2026-09-12 — Pilot 2

Second and final planned pilot launched from the pinned unadapted base, with 3,600 examples and 225 planned steps. Targets the three pilot-1 regressions while retaining all prior training data. Seventeen fresh development holdout cases frozen before launch. Training/export and serial Mac eval are queued automatically; no consumer model change. Results: evals/margin-lora/pilot2-preparation/.


2026-09-12: User reserves workstation GPU after current pilot-2 training. Automatic GPU export replaced by an approval hold, with original export script preserved as export-pilot.awaiting-approval.sh. Mac auto-eval watcher stopped. Obtain explicit user approval before ANY further workstation GPU use after current training completes. Current training continues (196/225 observed).


2026-09-12: User explicitly granted workstation again. Export hold lifted. ComfyUI queue was empty; its cached model unloaded through /free without stopping the service, restoring 14,392 MiB free VRAM. Pilot-2 export and Mac sequential-eval watcher resumed. First remote launch had a shell quoting error before execution; direct script invocation started afterward.


2026-09-12 Pilot 2 review: completed 267/288 original regression requests; fresh holdout 36/51 versus base 24/51. Zero infrastructure failures. Do not promote: missing all_day, invented move times, and quoted-text memory contamination remain. Grader defects: research-2 false negative, routing-43 semantic false pass, and p2-memory omitted from critical counter (holdout reviewed critical 12 vs automated 9). Frozen scores preserved. Assessment: docs/evals/margin-lora/pilot2-preparation/assessment.html. No third training authorized/launched; recommend data-rendering and evaluator audit first.


### 2026-09-12 — Offline evaluator and serialization audit

Implemented isolated scripts/margin-model-eval-v2 with explicit severity metadata and corrected date-move/price-uncertainty fixtures. Seven new tests and nine legacy tests pass. Replayed saved responses without inference: base regression 264/288, Pilot 1 279/288, Pilot 2 267/288; fresh holdout base 24/51 (9 critical), Pilot 2 36/51 (12 critical). Original evidence unchanged. Workstation SSH unavailable, so reconstructed dataset locally; all three split hashes match the saved workstation manifest. CPU-only pinned tokenizer audit preserves fields and supervised boundaries; saved post-Unsloth tokenizer equivalence remains unverified until workstation access returns. Empty thinking blocks in training versus reasoning in all 288 Pilot-2 regression responses is a possible mismatch, not a proven failure cause. No GPU work or new training.


2026-09-12: Workstation saved-tokenizer audit completed on CPU. All 4,060 actual training/validation rows match the pinned source tokenizer in both rendered text and token IDs (8,120 comparisons each across completed targets and generation prompts). No mismatches. This closes the previously pending post-Unsloth tokenizer equivalence check. Training serialization is not the observed cause; thinking-mode mismatch remains a hypothesis. No GPU inference or new training. Evidence: docs/evals/margin-lora/pilot2-preparation/audit-v2/saved-tokenizer-audit.json.


2026-09-12 Thinking experiment complete on RTX 5070 Ti / isolated Ollama 0.30.10. 360 scored requests, no infrastructure failures: base on/off 27/60 vs 39/60 (critical 18 vs 6); Pilot 1 36/60 vs 42/60 (critical 9 vs 9); Pilot 2 33/60 vs 39/60 (critical 12 vs 9). Native switch preflight passed for each model; all off responses had no reasoning trace. Pilot 1 off is best diagnostic configuration but not release-ready; all-day/date-time failures remain. No new training or app change. All models unloaded at completion. Unload timing assertion interrupted after base; continuation preserved all base records and waited for empty runtime before subsequent models. Report: docs/evals/margin-lora/pilot2-preparation/thinking-experiment/analysis.html.


### 2026-09-12 — Safeguards and DPO pilot preparation

Added deterministic pre-proposal checks for explicit all-day flags, omitted English/ISO dated entries, and invented times on date-only moves. Memory persistence now rejects evidence wholly inside quoted/fenced content and conservatively filters known third-party contexts. These are bounded guards, not a complete intent parser; refusal is not counted as successful completion. App Debug build passes; 11 focused request fixtures and 45 roadmap guards pass. No consumer installation/default changed.

Evaluator v3 preserves v1/v2 and accepts reversed no-card wording, with 9 focused tests passing. DPO corpus: 576 train/64 validation pairs across seven categories, explicit synthetic rejected mutations, all preferred tool targets schema checked; not human feedback. Fourteen fresh developer holdouts frozen before training. Workstation project C:/Users/oluyi/Documents/Projects/Margin-Empero-DPO; artifact storage D:/llm/Margin-Empero-DPO-artifacts. Fresh base QLoRA, rank 16, beta .1, LR 1e-5, full 8192-token context. Resource preflight is 4 steps; full pilot intended 72 steps, gated on finite actual adapter update and GPU release. Initial TRL optional mergekit import disabled only in process (unused integration); Qwen multimodal detection required selecting text-only dataset preprocessing. First attempt stopped before optimization and is retained. Live dashboard http://127.0.0.1:18772/.


2026-09-12 20:42 UTC: Optimized DPO resource preflight passed all 4 optimizer steps, saved an adapter, and passed nonzero LoRA-B verification. Peak allocated 10,103,027,712 bytes (~9.4 GiB), versus ~15.6 GiB in the aborted full-logit attempt. Full 576-pair/72-step pilot automatically started through the persistent Windows task after GPU release; live state loading_4bit_base mode=pilot at 20:42:19 UTC. Completion-only logits retain full prompt context and do not alter the chosen/rejected examples. No model promotion or consumer installation.

## Pilot 1 selected — target Mac qualification (2026-09-13 UTC)

User selected Pilot 1 after the DPO regression result. The `margin` branch now selects `margin-lora-pilot:final`; `main` is unchanged. Existing explicitly configured AI endpoints/models are preserved. Public model distribution is `olluyeancah/margin-pilot1-gguf`, explicitly approved by the user, pinned to commit `245704da10dfc9cb769926e197f1f540e0b21fa1`. Model SHA-256: `863fcfd8486b2681f83034ca178d188bbb682920ebc9103ab6bbf3691831026a`. Ollama macOS runtime 0.30.10 is pinned by archive checksum.

Native evaluation on this 24 GB Mac: 76/78 cases pass. The original eight-holiday batch passes with all dates, titles, and all-day flags. Misses: tentative RSVP unnecessarily declines; a date-only move omits its destination and is rejected. Median 4.04 s, p95 15.77 s. All 45 roadmap guards pass. Runtime-reported model residency peaked at 3,129,569,443 bytes. A concurrent build and preexisting swap make this unsuitable as an isolated memory benchmark; no 16 GB hardware claim follows from this test.

Managed installation now supports pinned HTTPS GGUF downloads, hash verification, local import, and cache paths derived from the selected model. Import errors exposed a real disk reserve issue: temporary conversion requires substantially more than the 3 GB download. New setup requires 17 GB free; completed model installations and verified blobs get appropriate reduced reserves. Verified downloads can be reused on retry. Import diagnostics are retained privately. The successful resumed setup and failed attempts are retained; a final clean install is being checked. This does not publish or install a new MeetingIntro consumer binary.

Reports: `docs/evals/margin-lora/pilot1-mac-validation/qualification.html` and `report.html`. Native test inputs can select a model through developer-only environment overrides without editing live user preferences.

2026-09-13 00:42:36 UTC: Final clean installation PASSED (started 00:40:44 UTC), including fresh public runtime/model downloads, checksums, local import, warmup and a native tool call. Private runtime shut down after the test. Final build, 22 setup guards and 45 roadmap guards pass. Qualification complete for this 24 GB Mac; native model accuracy remains 76/78, not 100%. No MeetingIntro consumer binary was installed or released. Existing manual AI configurations remain unchanged. Superseded local Pilot 2, smoke, base-control tag and skipped Granite copies were removed under the earlier cleanup authorization to free conversion scratch space; evaluation results and selected Pilot 1 were retained.
