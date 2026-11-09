# Margin mixed image and language training

Status: full Empero source image evaluation complete (114/114 responses). Strict contract score 0/114; reviewed failures separate output formatting, planning and rubric issues. Both source checkpoints accept images. Mixed training has not started. See [assessment](evals/margin-vision/source-probe/assessment.html).

## Sources

Pinned full Transformers checkpoints are recorded in `evals/margin-vision/training-sources.json`:

- Empero Qwen3.8-4B-Distill: c83cb7aa2999d2f35c43e9ae0634a30eb8985a1e.
- Official Qwen3.5-4B control: 851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a.

The first checkpoint is the ancestor of Pilot 1, not the trained Pilot 1 adapter. Its results must not be labeled Pilot 1 results. Both include vision components. Test actual image inputs before deciding the base. Do not transplant a projector and assume alignment without an image test.

## Current feasibility experiment

Seven requests per model, run in separate GPU processes sequentially: diagram, receipt, eight events, changed diagram, missing invoice total, embedded malicious instructions, and no-image control. Source BF16 on workstation RTX 5070 Ti. Generation is bounded at 512 tokens, with truncation recorded. Processor receives pixels, not OCR text. Tool execution is disabled. Actual input tensor keys are recorded to prove the image reached the model. Raw outputs require review. This is not the full image eval and not a 16 GB Mac latency test.

Project: `C:\Users\oluyi\Documents\Projects\Margin-Vision-Pilot`. Official source download uses WSL storage because the Windows drive is low on free space. Existing cached Empero weights are reused without modification.

## Training approach after qualification

Use a multimodal model loader and its processor, not the prior text-only tokenization path. Preserve the vision tower and image-token alignment. Start with language-layer LoRA while retaining full image conditioning; initially freeze vision weights. Only tune the vision stack when error analysis establishes that perception, rather than routing, is the bottleneck.

Construct a development dataset with a starting 50/50 mix of image-conditioned tasks and text-only Margin tasks, balanced by task family rather than duplicated easy examples. This ratio is an experiment, not a known optimum. Include:

- Images: diagram relations and naming, screenshots to tasks, receipts and invoices, all-day multi-event lists, table structures, missing/cropped information, and adversarial content.
- Text: existing tool schemas, temporal reasoning, action completeness, intent switches, grants, confirmation, memory provenance and grounded refusals.
- Paired cases: identical request with a changed image; image request followed by a text-only intent; partial information requiring clarification; same image with different user intent.

Labels describe what the assistant should propose, not completed external actions. Use the actual supported registry for executable-tool targets; planned capabilities stay labeled unsupported until implemented. Do not train normalized test vocabulary such as write_document as though it were a callable production tool.

Mask user/system/image tokens from loss; supervise assistant responses/tool arguments. Preserve image-token spans without truncation. Validate the training collator on both image and text-only rows and on mixed batches. Use batch size one/gradient accumulation initially, bound resolution/context, and measure real GPU peaks before a longer run. Quantized base loading may be required with optimizer state on 16 GB VRAM; inference fit is not proof of training fit.

Keep validation and final holdout separated by original image/document family, not by paraphrase. None of the published eval PNGs or their transformed copies belong in training. Independently review critical date, amount, identity and safety labels. Preserve a general vision subset to detect loss of image understanding.

## Qualification sequence

1. Source feasibility and no-image control.
2. Full image workflow eval plus text baseline, identifying parser/runtime failures separately.
3. Small collator/gradient/save/reload smoke with images and text. Verify vision components survive reload.
4. Complete a deployable multimodal export before committing to the longer training run. Export matching visual projector/processor artifacts and test real pixels on the target runtime.
5. Run a bounded mixed-data LoRA pilot; log dataset/model hashes, loss, checkpoints, GPU memory and timestamps.
6. Evaluate held-out image tasks, existing text regressions, native preview/confirm/undo, then the quantized package on a 16 GB Mac.

Promote only on demonstrated improvements without critical regressions. Training remains separate from shipping; the installed Pilot 1 and main branch stay unchanged during experiments.

## Full image run: development findings (2026-09-12 PDT)

The 38-case, three-repeat Empero source evaluation completed on September 12, 2026 at 8:34 PM PDT. All 114 responses received pixels; no inference errors, truncation or output variation across repeats. Median 8.9 seconds and p95 15.2 seconds on RTX 5070 Ti BF16. These are not Mac latency measurements. Its frozen strict score, raw outputs and separately reviewed findings live in [the assessment](evals/margin-vision/full-empero-20260913/assessment.html). Do not use strict failures directly as training labels. The observed bottleneck is primarily instruction following and action planning; this does not establish perception quality on real photographs.

### First dataset curriculum

Prepare 600 new development examples as a bounded first dataset, split 300 image-conditioned / 300 text-only. These are planned counts, not generated or approved examples. Split original document families before rendering or paraphrasing; keep 120 additional validation examples in disjoint families and leave the existing eval assets entirely out of training. Retain a separate final holdout not used to tune this curriculum.

| Family | Image / text training rows | Supervision required |
| --- | ---: | --- |
| Latest intent and truthful outcomes | 60 / 60 | Same attachment with changed user intent; proposed versus executed versus failed outcomes; tool-result provenance |
| Calendar and task completeness | 60 / 60 | All items, assigned-only and unfinished-only filters; explicit event and reminder dates; no file destinations in calendar arguments |
| Grants and preview authority | 45 / 45 | Already granted versus outside-root folders; safe filenames; preview before writes; no automatic confirmation |
| Missing information and untrusted content | 60 / 60 | Ambiguous dates, cropped values, absent images; distinguish quoted image instructions from actual user authorization |
| Research and lookup handoffs | 30 / 30 | Request the available lookup before claiming results; only cite supplied retrieval evidence |
| Perception preservation and typed output | 45 / 45 | Diagrams, tables, amounts and read-only answers; complete native argument schema; changed-image counterfactuals |

Before generation, export the actual registry and hash it. Any not-yet-implemented image-save or document tool must remain a proposed design target, not a fictional executable training label. Each row needs source family, image checksum if applicable, task family, supported-tool schema version, expected response/tool arguments, provenance and review status. Unreviewed rows cannot enter training. Do not import personal chat histories or user documents implicitly.

Before the training pilot: repair ambiguous eval annotations in a new suite version; establish a native-tool baseline; validate multimodal collator masking and one gradient step; save/reload and export matching image components; verify the exported package accepts pixels. Training budget and fit remain unmeasured. No long training run is started by this document.

## Execution started: September 12, 2026 PDT

Run: `C:\Users\oluyi\Documents\Projects\Margin-Vision-Pilot\mixed-pilot-20260913`.
Dashboard: http://127.0.0.1:18775/training-20260913/index.html

Initial development dataset is generated: 600 training rows and 120 validation rows, half image-conditioned and half text-only. The implemented first curriculum uses ten template families rather than the broader six-family quota proposal above. Image-save/document-write examples are excluded until native tool contracts exist. Validation uses separate document IDs/values but shared templates, so this is development validation, not an independent holdout. No published eval images or private documents are used. Labels have deterministic schema checks and assistant-reviewed generation rules, not independent human review.

Two optimizer steps (one image, one text) completed with finite loss and a nonzero adapter; peak allocated GPU memory was 12.56 GiB. A fresh process reloaded the checkpoint and read a receipt from pixels. This is checkpoint integrity evidence, not task-quality qualification.

The sequential supervisor gates the full pilot on actual image inference from the smoke-adapted Q4_K_M language export plus visual projector. It then runs a 20-response native-tool baseline, one epoch over 600 rows (75 optimizer updates, accumulation eight, rank eight, LR 2e-5), and the same 20-response native-tool comparison after training. The prior normalized-proposal eval remains separate. Vision parameters stay frozen; actual language linear modules are the adapter targets. Model processes run sequentially. A `STOP` file in the run directory stops at a training-example boundary or prevents the next stage.

Code: `scripts/margin-vision-training/`. Export intermediates use WSL storage under `/home/oluyi/projects/margin-vision-smoke-export-20260913` to avoid filling Windows C. Successful export on the workstation does not prove installed Margin image support or 16 GB Mac performance.

Implementation references: [Transformers Qwen3.5](https://huggingface.co/docs/transformers/v5.3.0/model_doc/qwen3_5), [PEFT explicit module targeting](https://huggingface.co/docs/peft/en/developer_guides/custom_models). Installed runtime versions are recorded separately; this run does not upgrade them.

### User extension: three epochs, evaluation after each

The user extended the active pilot to three epochs while epoch 1 was already running. Preserve that run and its existing 20-response native-tool evaluation. The foreground `continue_epochs.py` supervisor waits for their completion, archives them as epoch 1, then runs `train_epoch_continuation.py` for epochs 2 and 3.

Total budget: 1,800 training-example presentations / 225 optimizer updates, plus 20 fixed image/text development probes after each epoch. Keep the existing 20-response unadapted baseline. Each epoch has an immutable adapter directory and a separate response JSONL. This remains a development comparison, not an independent holdout or full production regression suite.

Epoch 1's original runner does not save optimizer state. Epoch 2 therefore continues its adapter weights with a new AdamW optimizer. This intentional boundary is disclosed in the continuation manifest and dashboard. Optimizer state is preserved between epochs 2 and 3 and serialized with subsequent checkpoints. Epochs 2 and 3 shuffle the same frozen training data with distinct fixed seeds; they do not alter evaluation cases or labels.
