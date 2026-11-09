# Margin image tasks: delivery plan

> September 16 harness update: image requests now use the shared agent loop through `read_attached_image`, `prepare_document_draft` and `export_attachment`. The earlier regex-selected workflow has been removed. Persistent confirmation/resume and image export integration are verified in the development build. See [the current architecture audit](reviews/margin-agent-architecture-20260916.md) and [timestamped verification report](evals/margin-vision/harness-overhaul-20260916/index.html). Earlier entries below retain their historical qualification boundaries; they are not the current runtime design.

Historical starting point, 2026-09-13 (superseded by the harness update above): the image page began as an unconnected UI prototype. The entries below record its subsequent implementation and qualification.

## Architecture and interaction

Drop or paste an image onto Margin, keep its thumbnail pinned to the page, and type the request underneath. Support questions such as “What is this diagram?”, “Name this and save it in Projects”, “Extract these assigned tasks”, and “Add these events”. Use the imported-image UI from the supplied ZIP as the reference: no sample-page selector, preview-mode selector or fixture controls in the consumer flow. Keep one main action and a secondary cancel/edit action appropriate to the current state.

The vision model performs OCR and interpretation itself. Start with the unadapted reader candidate that did best in the image screening, then unload it before loading text Pilot 1. The reader returns structured facts, uncertainties and references to the source attachment; it cannot grant access or authorize actions. Pilot 1 receives that complete envelope and the actual user request. Evaluate memory peak and model-switch latency on the 16 GB Mac before making this the automatic installation path. Do not publish or silently download a vision package until its artifact, licensing, size and runtime have been verified.

Show specific progress: “Reading the diagram…”, “Checking the event dates…”, “Preparing a save preview…”. Allow cancellation. Do not claim that the image was saved or that events were created until the action succeeds.

## Delivery stages and acceptance

1. **Read-only image questions.** Connect one-image input to the reader and Pilot 1. Answer from the image and preserve uncertain or unreadable fields. Ask for a missing image. Test diagram identification, receipts, rotated/blurred images, empty input and embedded prompt injection on independent images. No calendar/file writes in this stage.
2. **Name and save the attached image.** Prepare a suggested name and granted destination, with an editable preview. Copy original bytes to the destination; do not re-render the original or rename its extension into another format. Never silently overwrite an existing file. Confirmation performs the copy, then offers Reveal and appropriate undo. Saving an image file and marking a notebook page with a ribbon remain separate actions.
3. **Tasks and calendar extraction.** Present extracted items with editable fields. Require missing years, ambiguous dates, owners and destinations to be resolved. Validate against structured evidence before showing a proposal. Preserve all-day flags per event, reject omitted/changed items and invented move times. Apply user corrections as explicit reviewed data, preserving the original reading for inspection. Confirm before writes; track partial completion and recovery accurately.
4. **Broader image work.** Add comparison of multiple images, whiteboard-to-note/table output and public web research from an image, each with its own fixtures. Do not send attachment contents to web search automatically; preview the external query and use only the necessary public terms.

Before enabling writes, the independent holdout must demonstrate both correct proposals and deterministic rejection of unsafe proposals. A blocked malformed proposal is a guard success, not a model success. Keep reader accuracy, planner accuracy, end-to-end task completion, latency and memory usage separate in the report.

## Calendar validation completed this turn

- Existing production text dispatch already calls `MarginRequestChecks.proposalProblem` before tool preparation; it blocks a dropped explicit all-day instruction and an invented time on a keep-time move.
- Added an optional complete image-evidence envelope to the same validation entry point. It rejects missing/malformed evidence, unresolved uncertainties, missing/duplicate/changed events, missing all-day settings and changed timed starts. It does not silently repair model arguments.
- Image dispatch must explicitly supply the envelope when wired. The optional parameter does not itself enable vision or connect the image UI.
- 20 Swift checks pass, including valid proposals and adversarial evidence changes.
- Four saved calendar failures from hybrid v2 are rejected by the Swift validation replay. This is no-inference verification and does not change model scores.

Evidence: `docs/evals/margin-vision/hybrid-pilot1-v2-20260913/calendar-guard-replay/results.json`.
Run tests: `/usr/bin/python3 scripts/test-margin-request-checks.py`.
Reproduce saved replay: `swift docs/evals/margin-vision/hybrid-pilot1-v2-20260913/calendar-guard-replay/replay.swift docs/evals/margin-vision/hybrid-pilot1-v2-20260913/calendar-guard-replay/cases.json`.

## Next implementation

Connect the read-only reader/attachment boundary and test real drag/drop on the Mac. Keep the writes preview behind the image evidence validator. The remaining all-day generation and citation/explanation failures still need repair; do not represent them as fixed by rejection alone.


## Read-only implementation update

The image page now has a writing line and routes image questions through `MarginImageReader`, without an action registry or memory extraction. It shows reading/answering status, supports cancellation, and discards answers for a replaced or differently selected attachment. Saved image pages retain the answer and selected source together; selection/reset clears stale answers. Original image bytes remain untouched; the model sees a PNG made from the orientation-corrected preview (maximum 2400px).

For local runtime validation only, the reader is the installed `qwen3.5:4b`, because the installed Empero GGUF is text-only. This is not a promotion of Qwen over the workstation Empero reader and does not add an automatic model download. Missing readers produce an explicit unavailable message. Other loaded models block the request; Margin's planner is unloaded before the reader, and the reader is released before Pilot 1.

Verification: Debug app build succeeds. The production Swift pipeline answered the receipt fixture with `USD 19.44`; the service reported no loaded models afterward. Draft source/answer persistence and stale-state tests pass, as do the 20 calendar request checks. This does not yet establish native drag/drop usability, installed-app rendering, broad image accuracy, peak memory or acceptable model-switch latency. The existing installed application has not been replaced by this build.

Evidence: `docs/evals/margin-vision/image-read-integration-20260913/results.json`. Draft tests: `/usr/bin/python3 scripts/test-margin-image-draft.py`.


## Native verification completed

On the Debug validation build, a real Finder drag imported the receipt. Native typing produced USD 19.44; Command-V imported a second image and cleared the old answer. Native Cancel stopped a second request and left no models loaded. Saving with a ribbon and reopening through Index restored the original source, question and answer. These five workflow checks pass; broad independent image quality, release installation and peak-memory qualification remain outstanding. The installed bundle was not replaced. Evidence: `docs/evals/margin-vision/image-read-integration-20260913/native/index.html`.


## Image-save stage update

Name/save requests now prepare an editable filename; the image context menu also opens Save image as. Destination selection uses the folder-grant picker, and Save revalidates grants and preserves the imported bytes and their actual format. Exclusive creation refuses collisions. Undo verifies the saved file identity and content before moving it to Trash. Ten real filesystem checks pass, and draft persistence tests pass. The native preview was inspected; native confirmation and model-generated naming are not yet separately verified. The updated Debug validation app is running alone; the installed bundle is unchanged.

The user's “Convert tjis into a doc” request previously exhausted the model output budget. It created no document. Document conversion is now explicitly declined immediately; a native retry verified that no model loaded. The image page was preserved across restart. Next: editable document extraction/export, with Word (.docx) recommended; output preference requested separately. Report: `docs/evals/margin-vision/image-save-20260913/index.html`.


## Document format preference implemented

TXT is the default editable draft. After transcription, Margin asks “Keep this as text, or use Word or Markdown?” A picker and typed follow-ups (for example “Word please”) switch format and filename without new inference. Explicit Word/Markdown requests select that format directly. All formats save only on confirmation through the granted-folder/exclusive-create path, with guarded Undo to Trash. DOCX contains editable text, not a reconstructed screenshot layout or native tables.

Native verification on the user's saved screenshot produced the default TXT draft and table rows; a typed Word preference switched to .docx without loading a model. Text was then restored as the default. Ten export checks and ten filesystem checks pass; saved document draft/format tests pass. The Word fixture opened and its single page was rendered and inspected using LibreOffice plus pdftoppm because the skill renderer's pdf2image dependency was unavailable. The updated Debug validation build is running alone; installed bundle unchanged. Evidence: `docs/evals/margin-vision/document-export-20260913/index.html`.
