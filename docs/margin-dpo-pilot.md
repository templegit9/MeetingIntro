# Margin DPO pilot — 2026-09-12

This is a bounded experiment, not a 99% reliability claim or consumer model release.

## Completed before training

- Versioned evaluator v3 fixes reversed no-card wording without rewriting historical scores. Nine focused tests pass.
- Native proposal guards reject missing explicit all-day flags, omitted dated items, and invented clock times on date-only moves.
- Memory persistence rejects evidence wholly inside quoted/fenced text and conservatively filters recognized third-party contexts.
- Debug build passes, with 11 focused request checks and 45 roadmap checks. These guards block failures; a blocked request is not successful completion.
- 640 synthetic preference pairs: 576 train, 64 development validation. Preferred tool targets pass schema validation; mutation rules and representative pairs reviewed. These are not independent human preference labels.
- 14 fresh developer evaluation cases frozen before optimizer training. Original evaluations remain excluded from preference training.

## Training scope

Pinned Empero base, fresh rank-16 QLoRA adapter, beta 0.1, learning rate 1e-5, 8192 context, assistant preference pairs rendered with thinking disabled. Reference probabilities are computed against the unadapted base. The pilot does not continue Pilot 1 or Pilot 2 weights.

Four-step preflight must complete with finite, nonzero adapter changes and release GPU memory. Only then may the durable task start the 576-pair, one-epoch pilot (72 optimizer steps with accumulation 8).

Initial setup failures are infrastructure evidence, not model scores: optional mergekit import detection; vision preprocessing selected for a text-only corpus; excessive prompt-position logits consuming GPU memory. The text path and completion-only logits option address the latter two without truncating the prompt. Failed logs are retained.

## Evidence and monitoring

- Workstation project: `C:/Users/oluyi/Documents/Projects/Margin-Empero-DPO`
- Artifacts: `D:/llm/Margin-Empero-DPO-artifacts`
- [Live dashboard](http://127.0.0.1:18772/)
- [Pair manifest](evals/margin-lora/dpo-pilot/data-manifest.json)
- [Review samples](evals/margin-lora/dpo-pilot/review-samples.json)
- [Fresh holdout](evals/margin-lora/dpo-pilot/holdout-manifest.json)

After successful training, verify export/reload before output-based evaluation. Keep model correctness, guarded task completion, safe refusal, and latency separate. No automatic consumer promotion. Broader untouched evaluation and actual target-Mac testing remain necessary for a credible 99% target.


2026-09-12 20:42 UTC: Optimized DPO resource preflight passed all 4 optimizer steps, saved an adapter, and passed nonzero LoRA-B verification. Peak allocated 10,103,027,712 bytes (~9.4 GiB), versus ~15.6 GiB in the aborted full-logit attempt. Full 576-pair/72-step pilot automatically started through the persistent Windows task after GPU release; live state loading_4bit_base mode=pilot at 20:42:19 UTC. Completion-only logits retain full prompt context and do not alter the chosen/rejected examples. No model promotion or consumer installation.

2026-09-12 23:23 UTC: Continued the authorized post-training pipeline. Training completed 72 steps at 22:22 UTC. Adapter reload returned the exact readiness JSON. Canonical merge verification passed: three trained tensor samples changed, all 15 auxiliary MTP tensors remained exact. BF16 export completed and Q4_K_M quantization started. The local controller `scripts/margin-dpo/evaluate.py` waits for successful export, imports only into isolated workstation Ollama 0.30.10 at port 11436, and evaluates 381 requests (96 original + 17 prior holdout + 14 fresh holdout, each repeated three times). Original deterministic dispatch fixtures are excluded from model scoring. Evaluator v3 tests pass 9/9. Existing thinking-disabled workstation baseline outputs will be reused for the matched comparison, not rerun. HTML report: http://127.0.0.1:18773/evaluation/report.html; final assessment will be at evaluation/analysis.html. No consumer model change. Browser automation was unavailable; HTTP delivery verified, visual QA not yet established.

2026-09-12 23:34 UTC: Export, reload and all 381 evaluation attempts complete. Model unloaded, isolated runtime reports no resident models. Q4_K_M export SHA-256: `9ea75f9a918722ea425821c5fa39f911f076fc0294f0d03d89b3811f292db9eb`. 300 passes, 48 check failures, 33 runtime native-format parsing errors; 15 critical-labelled check failures. Original 249/288 attempted, prior holdout 24/51, fresh holdout 27/42. Same 20-case thinking-disabled workstation comparison, regraded v3: DPO 36/60 attempted, base 42/60, SFT1 42/60, SFT2 39/60. Do not promote. Parser errors are ungradable infrastructure events and unsuccessful service attempts, not silently excluded successes. One extra routing-9 diagnostic reproduced the parser error outside scoring. Import timeout and continuation provenance retained; eight completed results were preserved, no retry-to-pass. Final report: http://127.0.0.1:18773/evaluation/analysis.html. Next: diagnose raw tool-call output compatibility before further training; address held-out date preservation and inappropriate memory retention. Native safeguard behavior and Mac latency were not measured by this workstation output evaluation.
