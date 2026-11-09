# Margin agentic journeys — 18 September 2026

Scope: the existing `margin` branch and production agent loop. No public release or installed app replacement.

## Production fix

A stale note ID exposed a recovery bug: the loop rejected a second inventory read even after another tool explicitly reported stale evidence. A successful read may now refresh after a subsequent tool error. Identical failed calls still stop, and one error allows only one refresh of a given read. Approval, write deduplication and step budgets remain enforced.

The new regression failed against the previous implementation (`refresh-before.log`). After the fix, 24/24 orchestration/journal checks passed (`loop-after.log`). The compiled agent passed 16/16 checks including actual TXT/Word output, approval revalidation, recovery, cancellation and revoked access (`image-integration-unrestricted.log`). Those model/reader responses are scripted. The first sandboxed image run could not grant a temporary folder; its failure is retained separately.

## Live-model cases

The model is `margin-lora-pilot:final`. Each case uses a fresh temporary filesystem, defaults suite and task journal. The final version registers three fixture note/save tools and uses the production `list_granted_folders` and `inspect_folder` tools, restricted to real security-scoped grants for temporary folders. No real calendar, search provider or user-folder action is available. The model chooses steps and arguments. The driver confirms a proposal only after checking its destination, content, filename and absence of earlier writes. Exact resulting file bytes and execution receipt counts are asserted.

- Evidence: discover a generated note ID, read its text, discover a destination, propose and save the exact contents.
- Recovery: encounter an expired ID, refresh inventory, read the new ID and complete the original task.
- Clarification: ask which of two Reports folders the user means; continue after the supplied answer.
- Two writes: save the first copy, consume its receipt, prepare a second copy and wait for a separate confirmation.

The first run passed evidence; the remaining three cases did not start inference because the preflight rejected the selected model briefly remaining resident after the prior case. Those are infrastructure blocks, despite the old runner's `FAIL` label. The corrected preflight accepts its own selected model, as the production loop does, and the next run selects only those unstarted cases. No failed case is silently retried. The original fixture had a further mismatch: it provided a synthetic destination tool while the automatically added production folder tools had no grants. The two-write case chose real folder discovery, found no grants and correctly asked for access instead of reaching a preview. Its failure remains in `live-remaining.log`. The final, separately versioned fixture replaces synthetic destinations with actual temporary grants and canonical path checks; all four cases run under that revised setup (`manifest-real-folders.json`, `live-real-folders.log`).

## Reproduction

```sh
/usr/bin/python3 scripts/test-margin-agent-loop.py
xcodebuild -project MeetingIntro.xcodeproj -scheme MeetingIntro -configuration Debug \
  -derivedDataPath build/agentic-check \
  -clonedSourcePackagesDirPath build/release/SourcePackages \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
MARGIN_HARNESS_SELFTEST=1 \
  MARGIN_HARNESS_IMAGE="$PWD/docs/evals/margin-vision/assets/receipt.png" \
  build/agentic-check/Build/Products/Debug/MeetingIntro.app/Contents/MacOS/MeetingIntro
MARGIN_HARNESS_JOURNEYS=1 NSUnbufferedIO=YES \
  build/agentic-check/Build/Products/Debug/MeetingIntro.app/Contents/MacOS/MeetingIntro
```

Live tests require the existing local model service and selected model. The image test requires macOS security-scoped bookmark access for its temporary fixture root. `MARGIN_JOURNEY_CASES=recovery,clarification,two-writes` selects cases without rerunning evidence. Hashes and run boundaries are in the manifests and logs. The corrected manifest also hashes the Debug dylib containing the implementation.

These checks do not establish broad model reliability, the full production tool registry, OCR accuracy, live provider effects, or physical-input UI behavior.

## Fixture feedback correction

The first run using real grants passed evidence and clarification, but recovery and two-writes stopped without writing. The save fixture used the same “Work or Personal?” error for both genuinely ambiguous destinations and a missing exact path, even when only Work existed. That feedback was incorrect. The fixture now distinguishes those cases and directs invalid-path calls to actual folder discovery; canonical path components handle `/var` and `/private/var` consistently. Only the two affected cases are selected in `manifest-feedback-fix.json` / `live-feedback-fix.log`. The production change remains the read-refresh fix; folder error changes are confined to the test fixture.

## Outcome

- Production recovery fix: verified by failing-before/passing-after regression, with 24/24 loop/journal checks and 16/16 compiled image integration checks passing.
- Evidence and clarification: passed with real folder discovery (`live-real-folders.log`).
- Stale-ID recovery: passed with corrected fixture feedback (`live-feedback-fix.log`).
- Two writes: both files were created correctly after separate confirmations, but one run failed the final continuation check. The original diagnostic did not capture the exact agent error. After adding state/error diagnostics, two repetitions completed successfully (`live-diagnostic.log`, `live-diagnostic-repeat.log`). This does not explain or erase the first failure.
- Debug build passes; whitespace check passes. No installed app replacement, signing/publishing, model promotion or live provider writes.

All four scenarios now have successful executions, but this is not a clean 4/4 reliability qualification. Final-continuation consistency, full-registry journeys, live OCR and native UI remain open. `results.json` preserves per-run outcomes rather than combining the best results into a success percentage.
