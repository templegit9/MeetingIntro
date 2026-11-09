# Margin broader testing — 1 October 2026

**Screenshot import is not qualified for accurate whole-week creation.** Tests ran against a synthetic week grid, not the user's Outlook screenshot. No real calendar was changed. Code changes are on the margin branch; no installed-app replacement or public release was performed.

## Results

| Boundary | Result | Evidence |
| --- | --- | --- |
| Full existing first-decision suite | 73/78 under the legacy single-tool rubric | `routing.json`, `routing.log`, `routing-review.json` |
| Real agent file journey | Pass: create Installers, move exactly two DMGs, preserve keep.txt, two confirmations, final grounded answer | `real-files.log` |
| Orchestration / durable journal | 25/25 pass | `loop-final.log` |
| Compiled image/document and confirmation integration | 16/16 pass | `integration-final.log` |
| Request / calendar fidelity guards | 30/30 pass | `calendar-final-guards.log` |
| Scripted screenshot integration | 8/8 pass: correct batch plus omitted event, wrong duration, duplicate, unread source, replaced source, cleared source and uncertain evidence | `final-*.json` |
| Actual vision reader, original prompt | Fail: wrong format, missing durations/end times, all-day event treated as timed | `reader-diagnostic.json` |
| Actual vision reader, revised prompt | Fail: 7/8 event facts exact; all-day offsite became 09:00 for 30 minutes. Response also contained a Markdown fence rather than the requested JSON object | `reader-v2.json`, `reader-v2-accuracy.json` |
| Reader with missing year/timezone | Fail: invented 2024 and UTC, with empty uncertainties | `reader-ambiguous.json`, `reader-ambiguous-review.json` |
| Real Outlook screenshot / native paste / real provider writes | Not exercised | User image is still needed; provider writes remain isolated |

The reader's fenced response was stripped only in the offline accuracy audit, never to permit calendar execution. All eight titles were present in the revised read, but finding every title is not sufficient: one event's all-day status, start and duration were wrong. The original live agent run ended without a complete preview and created nothing (`calendar-live.json`). Scripted image integration supplies known reader/model responses, so its passing result does not demonstrate OCR accuracy.

The negative uncertainty integration case supplies a known uncertainty envelope and verifies blocking; the actual vision model failed to produce that envelope. This distinction is why the release gate remains held.

## Routing review

The legacy test labels all missing single calls as `(declined)`, which is misleading for an agent:

- `move the dmgs into an Installers folder` returned `create_folder` and `move_files` together. A subsequent real-file journey successfully executed the goal after separate approvals; the original score is retained.
- Two calendar requests asked for clarification instead of immediately selecting RSVP/cancel.
- Two capability prompts produced textual answers without querying the registry.

These five mismatches are not five harmful actions or refusals. Nor does 73/78 establish multi-step completion reliability. The 78-case report finished completely after a temporary report-write failure due to disk exhaustion. An additional diagnostic build failed for the same reason; only that newly created failed build directory was removed. A final incremental Debug build passed using the existing cache.

## Production changes prompted by testing

The agent previously did not pass its attached-image evidence to the existing calendar completeness validator. The validator also omitted duration checks. Added a dedicated `read_calendar_image` tool and structured evidence handoff. Calendar proposals now require the matching attached image's evidence and preserve counts, exact titles, dates, timezone offsets, all-day flags, durations and locations. Imports reject uncertain readings, duplicate events, invented invitations/recurring series and unsupported multi-day all-day entries instead of silently shortening them.

The pending approval stores the source attachment ID. It is revalidated at confirmation and recovery, including when an image is replaced or cleared. Restart preserves the binding; missing restored evidence requires a new reading/review rather than silently trusting old arguments. Scripted tests verify unchanged drafts can execute, while invalid or changed sources cannot.

These checks enforce consistency with the reader's evidence; they cannot prove that the reader interpreted the pixels correctly. The observed all-day and missing-context failures therefore remain blockers even though the guards pass. The stricter reader also returns a useful error for malformed output rather than a generic Foundation parsing error.

## Reproduction

Build incrementally with the existing dependency cache:

```sh
xcodebuild -project MeetingIntro.xcodeproj -scheme MeetingIntro -configuration Debug \
  -derivedDataPath build/agentic-check -clonedSourcePackagesDirPath build/release/SourcePackages \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
/usr/bin/python3 scripts/test-margin-agent-loop.py
/usr/bin/python3 scripts/test-margin-request-checks.py
```

Set `MARGIN_FIXTURES=1`, `MARGIN_EVAL_MODEL=margin-lora-pilot:final` and `MARGIN_EVAL_REPORT` to a **new** report path when running the built executable for the full first-decision suite. It also runs file/calendar/behavior/roadmap guards before routing. The saved log records 6/6, 15/15, 16/16 and 45/45 respectively; some behavior checks use live model responses, so do not label the whole entry point deterministic.

Set `MARGIN_FILE_JOURNEY=1` for the real temporary-file journey. For screenshot integration, set `MARGIN_CALENDAR_IMAGE_TEST` to the image path, `MARGIN_CALENDAR_EXPECTED` to the independent JSON manifest and `MARGIN_CALENDAR_REPORT` to a new output path. `MARGIN_CALENDAR_SCRIPTED=1` injects known reading/planning responses; omit it for live inference. `MARGIN_CALENDAR_READER_ONLY=1` isolates the reader comparison. All calendar effects use test output, not EventKit or Graph.

The standalone reader diagnostic is compiled from the production reader:

```sh
swiftc -parse-as-library MeetingIntro/Margin/OllamaToolClient.swift \
  scripts/margin-calendar-reader-check.swift -o /tmp/margin-calendar-reader-check
/tmp/margin-calendar-reader-check /absolute/image.png /absolute/new-report.json
```

Generate the development image and independent event manifest with `swift scripts/margin-week-fixture.swift /output/folder`; add `--ambiguous` to omit the year/timezone labels. The image was visually inspected against the generated event list. It is explicitly a synthetic week view, not an Outlook screenshot or an independent generalization dataset. Prompt revisions and diagnostic runs are preserved separately rather than combined into a best-of score.

## Where to resume

Obtain the actual Outlook screenshot plus its timezone/year if not visible. Establish the exact expected events independently. Improve or qualify the reader's all-day/grid and uncertainty handling, then verify the real paste → complete editable preview → confirmed event creation flow against a test calendar. Do not publish a whole-week accuracy claim from these results. The earlier intermittent two-write final-response issue is not explained by this run.
