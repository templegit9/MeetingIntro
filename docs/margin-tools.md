# Margin · the tool registry

**Current runtime:** shared agent loop, persistent approvals/recovery, and image/document tools. See the [September 16 architecture audit](reviews/margin-agent-architecture-20260916.md) and [verification report](evals/margin-vision/harness-overhaul-20260916/index.html).

Every capability Margin could have, what already backs it, and what it would cost. The
registry is the *only* thing the model may do — anything not on this list it must decline,
which is why the list is worth being exhaustive about.

**Earlier registry snapshot:** 29 tools are registered in Margin, including eight file tools and the implemented `move_event` / `cancel_event` paths. Earlier full routing run: **49/50**; final focused regression: **9/9** with **34/34** guards. Subsequent history-only changes passed **15 calendar + 16 behavior guards**. These are distinct runs, not a claim of a fresh full 50/50. Live EventKit/Graph mutations remain unverified. See [developer eval report](evals/margin/report.html) and [capability map](margin-grok-bot-capability-map.html).

## Three rails that apply to every tool below

1. **Reads answer; writes propose.** A read (find, list, summarise) returns a page. A write
   returns a page you confirm. Nothing the model produces reaches the disk or the calendar
   unreviewed, because a 4B-class model will eventually invent an argument.
2. **Files are never permanently deleted.** Files go to the Trash, which is reversible by the user
   outside the app too. `rm` is not in the registry and will not be. Calendar cancellation
   is a separate, explicitly confirmed operation and cannot be undone from Margin.
3. **Margin acts only inside granted roots.** A folder becomes available when you grant it
   once (a picker, or the macOS prompt for Desktop/Documents/Downloads). Granted roots are
   listed on the inside cover and revocable there. Asked to touch anything outside one,
   Margin says so and offers to ask for access rather than failing quietly.

Status key — **built**: exists in the app today · **wire**: the machinery exists, needs a
tool wrapper · **new**: real new work.

---

## A · Finding things (reads — instant, safe)

| Tool | Does | Arguments | Status |
|---|---|---|---|
| `find_files` | Files by name, extension, size, age, folder | `query, ext[], folder?, newer_than_days?, older_than_days?, larger_than_mb?, recursive?, limit` | **BUILT** |
| `find_files_by_content` | Files whose *text* matches, including scans and screenshots | `text, folder?, ext[], limit` | **BUILT** — reads at most 120 files and says how many it opened |
| `find_duplicates` | Byte-identical copies, keeps the shortest path | `folder` | **built** — `FileOrganizer.findDuplicates`, size→SHA-256 |
| `folder_summary` | What's in here: counts by kind, total size, oldest, biggest | `folder, recursive?` | **BUILT** |
| `disk_hogs` | Largest files or folders under a root | `folder, limit` | wire |
| `recent_files` | Recently added or changed, e.g. "what did I download yesterday" | `folder?, since` | wire |
| `read_file` | Text, PDF first page, or OCR of one file, to answer about it | `path` | **built** — `FilePreviewExtractor.extract` |
| `compare_folders` | In A but not in B, and vice versa | `folder_a, folder_b` | new (small) |
| `where_is` | Locate a named file anywhere granted | `name` | **BUILT** — searches every granted root, subfolders included |

## B · Moving and tidying (writes — previewed, undoable)

| Tool | Does | Arguments | Status |
|---|---|---|---|
| `move_files` | Move a matched set to a destination | `selector…, destination` | **BUILT** — collision-safe, exact undo |
| `copy_files` | Same, copying instead of moving | `selector, destination` | new |
| `rename_files` | Pattern rename: date prefix, lowercase, kebab-case, find/replace | `selector…, style, find?, replace_with?` | **BUILT** — extension never touched, undo restores names |
| `organize_folder` | AI foldering of a folder, with a preview | `folder, rename?` | **built** — `FileOrganizer.plan` / `apply` |
| `reorganize_folder` | Pull everything out of nested folders into a fresh structure | `folder` | **built** — `OrganizeMode.reorganize`, prunes emptied folders |
| `create_folder` | Make a folder | `parent, name` | **BUILT** — undo removes it only if still empty |
| `trash_files` | Move to Trash. Never a permanent delete | `selector…` | **BUILT** — refuses without a filter; undo restores from the Trash |
| `archive_files` | Zip a set into one archive, optionally trashing the originals | `selector, archive_name` | new |
| `flatten_folder` | Unnest one level, resolving name collisions | `folder` | wire |
| `sort_by_date` | Into `YYYY/MM` folders | `folder, granularity` | wire |
| `tag_files` | Finder tags — the non-destructive alternative to moving | `selector, tags[]` | new (small) |
| `reveal_in_finder` | Show it rather than touch it | `path` | wire |
| `save_rule` | Turn a correction into a standing rule | `match, action` | **built** — `OrganizeRule` |

## C · Standing folder work

| Tool | Does | Status |
|---|---|---|
| `watch_folder` | Organize when new files land (debounced) | **built** — `DirectoryWatcher` |
| `schedule_organize` | Daily organization previews at a local time | **BUILT in Margin** — review required; interval scheduling remains available in the host UI |
| `list_jobs` | Durable batch and standing-folder jobs with per-step state | **BUILT** |
| `pause_job` | Pause future work; an in-flight step may finish | **BUILT** |
| `resume_job` | Fresh preview of pending calendar-batch steps | **BUILT** — no automatic replay of completed/uncertain writes |

## D · Calendar

| Tool | Does | Status |
|---|---|---|
| `create_event` | Meeting, hold, all-day, repeating, with invitees | **BUILT** — title/year/writable destination; unknown date asks |
| `create_events` | Complete selectable batch of one-off calendar events | **BUILT** — durable per-event results, pause and recovery; no batch invitees |
| `find_time` | Free slots, grouped and ranked, hold one | **built** |
| `whats_on_today` | Today at a glance | **built** |
| `day_briefing` | First, last, back-to-backs, longest gap, overlaps, unanswered, no-link, tasks due | **BUILT** |
| `week_report` | Hours in meetings this week | wire |
| `meeting_hygiene` | No join link, no agenda, unanswered invitations | wire |
| `rsvp` | Accept, decline, tentative | **BUILT** — a tear-out (it reaches the organiser); says plainly that macOS Calendar can't RSVP |
| `move_event` | Reschedule one existing occurrence | **IMPLEMENTED — automated checks passed; live provider verification pending**: EventKit save / Graph PATCH; exact-match lookup, conflict warning, preview and confirmation |
| `cancel_event` | Cancel or remove one existing occurrence | **IMPLEMENTED — automated checks passed; live provider verification pending**: Graph organiser cancellation / EventKit removal; notification warning and confirmation; no automatic undo |
| `add_link_to_event` | Attach a join link to an existing meeting | new — needs the same modify path |

## E · Tasks

| Tool | Does | Status |
|---|---|---|
| `create_task` | To-do with deadline, reminder and channels | **built** |
| `list_tasks` | What's outstanding, scoped all/overdue/today/week — pick a line and tick it | **BUILT** |
| `complete_task` | Tick one off by name; more than one match asks rather than guesses | **BUILT** |
| `snooze_task` | Push a deadline | wire |
| `extract_tasks` | Action items out of a transcript or notes into tasks | new — the most executive-assistant thing on this page |

## F · Meetings, recordings, notes

| Tool | Does | Status |
|---|---|---|
| `start_recording` / `stop_recording` | Record the meeting in progress | wire |
| `list_recordings` | What was recorded, and whether notes exist | **BUILT** — granted recording folder required |
| `generate_notes` | Queue transcript and notes generation | **BUILT** — existing pipeline; queued is not complete; live generation unverified |
| `catch_me_up` | Answer from a past meeting's notes | wire |
| `search_transcripts` | Literal attributed excerpts from saved transcripts | **BUILT** — bounded local reads inside granted roots |

## G · Reference and self

| Tool | Does | Status |
|---|---|---|
| `define_word` | Definitions, examples, synonyms and phonetic spelling when available; offline first | built — Margin notebook, direct lookup and spelling suggestions |
| `list_capabilities` | What Margin can do, generated from this registry | **built** |
| `open_settings` | Jump to a settings tab | wire |
| `why_no_reminder` | Read the diagnostic trail for a meeting | wire |

## H · Web research

| Tool | Does | Status |
|---|---|---|
| `web_research` | Brave search, local cited brief and linked excerpts | **BUILT** — key required; live Brave verification pending; not full-page research |

## I · Deliberately excluded

- **Permanent deletion.** Trash only.
- **Running shell commands.** An assistant that can run anything can do anything, and no
  preview page can meaningfully describe an arbitrary command.
- **Sending email.** It may open a pre-filled draft; it may not send.
- **Touching anything outside a granted root**, including system folders.
- **Changing system or security settings.**

---

## Order

1. ~~`find_files`, `find_files_by_content`, `folder_summary`, `where_is`~~ — **done**.
2. ~~`move_files`, `trash_files`, `create_folder`, `rename_files`~~ — **done**.
3. ~~`list_tasks`, `complete_task`, `day_briefing`, `rsvp`~~ — **done**.
4. `move_event` / `cancel_event` — implemented on the branch; see verification below.

Every addition also goes into `MarginFixtures`, because routing on a local model is
measured, not assumed.

## Calendar continuation · 2026-09-10

- Both tools are registered and included in the developer routing eval (42 standalone + 8 contextual cases).
- `3pm` matches today's start time. `original_start` can identify an exact original time without inventing a title. Multiple matches return a question instead of selecting the earliest.
- EventKit recurring lookup fails when the exact occurrence cannot be found; no fallback to the series' first event. Writes use `.thisEvent`.
- Graph verifies organiser authority and event type before preview and execution. Lookup failures throw. Series masters are refused; attendee requests direct the user to RSVP instead of silently becoming DELETE.
- Graph move uses UTC date/time pairs. Only start/end are patched, preserving other event fields.
- EventKit previews no longer claim that nobody is notified. Apple documents removal as the cancellation operation in the SDK's `EKEvent.h`; the calendar service controls notifications. Graph's [cancel operation](https://learn.microsoft.com/en-us/graph/api/event-cancel?view=graph-rest-1.0) is organiser-only.
- Moves have no automatic undo: a detached EventKit occurrence may have a changed identity, and a second update cannot unsend the first notification. A user can request another move.
- Concurrent confirmation clicks are guarded while the write runs.

Verification: Debug and Release builds passed. The full routing eval scored **49/50**; its defect was fixed. A focused rerun exposed an exact-time-selector issue (**8/9**), also fixed. The final focused rerun passed **9/9**, plus **34/34** deterministic guards. The [HTML report](evals/margin/report.html) preserves all three runs. No live calendar was changed during testing; provider mutation, recurring-event behavior on real accounts, attendee delivery, and native rendering of the new confirmation pages are not yet verified. This is source implementation, not a claim of an installed release.

Chat history is a separate design choice: [three options and recommendation](margin-history-options.md).

## Margin behavior and history

| Item | Implementation status |
|---|---|
| Plugin tile → settings | Implemented; dedicated configuration sheet with Open notebook |
| Personality / soul | Implemented; Calm, Direct, Warm, Custom plus user-authored instructions |
| Explicit memory | Implemented; opt-in preferences, stored locally and excluded from the prompt while disabled |
| Conversation history | Implemented; opt-in text receipts, searchable Index, no executable actions after reload |
| Proactivity | Implemented; only-when-asked, quiet ribbon, gentle nudges, plus pause and daily budget |
| Developer eval | Implemented; CLI only, isolated preferences/grants, JSON and log artifacts; see `margin-evals.md` |
| Duplicate app prevention | Implemented; normal launches activate the existing app, evals branch before UI startup |

The full eval found two defects across successive runs; both reports are retained. Do not turn partial regression success into a claim that a new full 50-case run passed.

## Roadmap implementation — 10 September evening

Added `create_events`, `web_research`, `list_jobs`, `pause_job`, `resume_job`, `watch_folder`, `schedule_organize`, `list_recordings`, `search_transcripts` and `generate_notes`. These are registered implementations; old catalogue rows above describe the earlier snapshot. See [current progress](margin-roadmap-progress.md) for exact scope and verification boundaries, and [broader-capability designs](margin-broader-capabilities-design.md) for the design-only work.

Brave requires a key entered in Margin settings. Search evidence is excerpt-based, with a local cited brief and linked sources, not an assertion of full-page research. Permanent deletion, arbitrary shell execution and external sending remain outside the registry.


## Agent harness update — September 16, 2026

Production uses a bounded observation/tool loop, not the historical single-route classifier. Write proposals pause; exact confirmation revalidates state and returns an execution receipt to the model. Goals, pending calls and receipts persist; saved tasks can be resumed after restart, while uncertain writes require explicit reconciliation.

| Tool | Status | Contract |
|---|---|---|
| list_granted_folders | Built, development branch | Exact granted paths; cannot grant access |
| inspect_folder | Built, development branch | Up to 100 file/folder entries inside a granted root |
| read_attached_image | Built, development branch | Model-produced image observations or transcription; untrusted evidence |
| prepare_document_draft | Built, development branch | Editable TXT by default; Word/Markdown follow-ups reuse text; no save |
| export_attachment | Built, development branch | Source-bound image/document proposal; explicit confirmation, no overwrite, Undo |

The last three tools are exposed only while an image is attached. Image content is excluded from preference learning. See [architecture and evidence](reviews/margin-agent-architecture-20260916.md). Model accuracy, native physical-input qualification and live-provider release testing remain separate from harness verification.
