# Margin vision architecture review

Reviewed September 12, 2026. Recommendation: evaluate the full Empero 4B vision checkpoint before training or choosing a two-model architecture. Keep Pilot 1 as the text baseline during comparison.

## Qwen 3.8 naming and actual vision support

The 4B and 9B packages reviewed here are Empero distillations built on Qwen3.5, not official Qwen-team small 3.8 releases. The official Qwen release material reviewed identifies larger 3.8 checkpoints; I did not find official Qwen3.8-4B or Qwen3.8-9B releases. [Qwen release repository](https://github.com/QwenLM/Qwen3.8)

Both Empero model cards describe text-only distillation with untested inherited vision behavior. This makes them candidates, not validated multimodal products. [4B model card](https://huggingface.co/empero-ai/Qwen3.8-4B-Distill), [9B model card](https://huggingface.co/empero-ai/Qwen3.8-9B-Distill)

I inspected the actual configs and only the safetensors headers, without downloading weights. Both declare Qwen3_5ForConditionalGeneration and contain vision tensors: 297 tensors / 333,514,240 visual parameters in 4B; 333 tensors / 456,010,480 visual parameters in 9B. These are structural checks, not inference results. Exact commits and metadata are retained in [package audit](evals/margin-vision/model-package-audit.json).

Neither publisher GGUF file listing contains a separate mmproj artifact at the inspected revision. Absence of that artifact is a packaging gap for the normal separate-projector path, not proof the original checkpoint lacks vision. Margin's installed Pilot 1 previously reported completion/tools/thinking, without vision. Its current installation cannot be assumed to accept images merely because its ancestor can.

## 4B versus 9B

| Candidate | Why test it | Main concern | Position |
|---|---|---|---|
| Empero Qwen3.8-4B-Distill, full multimodal export | Same base family as Pilot 1; actual vision tower present; smaller deployment | Vision quality after text distillation unmeasured; image export must be validated | First experimental candidate |
| Empero Qwen3.8-9B-Distill, full multimodal export | More language capacity could help interpreting complicated images and plans | More RAM, loading and inference cost; no published vision validation; improvement is a hypothesis | Quality challenger |
| Official Qwen3.5-4B | Established multimodal checkpoint and Ollama image support | Existing text-only performance does not establish image performance or production routing reliability | Required control |
| Official Qwen3.5-9B | Larger multimodal control separates size effects from Empero distillation | Larger resource footprint on 16 GB systems | Control for 9B challenger |

For package scale, Ollama lists official Qwen3.5-4B at 3.4 GB and 9B at 6.6 GB. These are downloads, not peak RAM. The 9B Empero Q4_K_M language GGUF is listed at 5.780 GB; vision components, runtime buffers and context add to that. I would start at 4-bit, bounded image resolution, and modest context; actual 16 GB viability remains unmeasured. [Ollama packages](https://ollama.com/library/qwen3.5), [Empero 9B GGUF](https://huggingface.co/empero-ai/Qwen3.8-9B-Distill-GGUF)

The publisher's reported math/general-knowledge results do not evaluate OCR, diagram edges, filenames or Margin tool arguments. They cannot select the winner for this use case.

## Architecture trade-offs

| Approach | Benefits | Costs and failure modes | Verdict |
|---|---|---|---|
| Vision model → Pilot 1 | Reuses measured text planner; perception errors can be isolated; swap models sequentially | Lost evidence in handoff; two generation stages plus unload/reload; larger download footprint | Strong fallback if its workflow accuracy beats direct multimodal planning |
| One existing multimodal model | Direct access to pixels while planning; one runtime/model lifecycle; simpler deployment | Must pass both image workflows and all existing text regressions | Preferred product shape if measured results support it |
| Package Pilot-derived language weights with compatible vision components | Potentially retain task tuning and add image input without another training run | Tensor presence is not alignment; exact base, processor, token layout and projector compatibility need checking | Cheap feasibility experiment, never assumed compatible |
| Multimodal SFT/LoRA on a working vision-language base | Targets recurring Margin errors using actual images and tool outcomes | Data labeling, visual alignment and text regression risk; conversion and calibration work | Only after baseline failure analysis |
| Train a vision-language model from scratch | Full architectural control | Far beyond the data/compute needed for this product | Not justified |

A text-only LoRA does not create a vision encoder. Prefer a checkpoint that already has one. For adaptation, initially preserve the vision stack while training the language/task path with a mixed image-and-text dataset; selectively adapt vision only if evidence shows a perception bottleneck. This is a proposed experiment, not a guaranteed recipe. [TRL multimodal SFT support](https://huggingface.co/docs/trl/sft_trainer)

## Test order

1. Confirm full Empero 4B can answer pixel-dependent questions with the correct runtime and image processor. Use no-image and changed-image controls.
2. Compare against official Qwen3.5-4B on the frozen image suite.
3. Feed identical vision observations into Pilot 1 and compare full workflow accuracy and total latency with direct multimodal proposals.
4. Evaluate the two 9B variants only if the smaller candidates leave useful quality headroom.
5. Train the best suitable base only for stable, repeated failure categories; then rerun untouched holdout, existing text evals and actual native writes/undo.

No model download, training, or new inference was run as part of this review. The attached evaluation pack is prepared, not scored.
