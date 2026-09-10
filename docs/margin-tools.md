# Margin · the tool registry

Every capability Margin could have, what already backs it, and what it would cost. The
registry is the *only* thing the model may do — anything not on this list it must decline,
which is why the list is worth being exhaustive about.

**Progress:** twelve tools built, registered and tested — eight for files — `find_files`,
`find_files_by_content`, `folder_summary`, `where_is`, `move_files`, `trash_files`,
`create_folder`, `rename_files` — plus `list_tasks`, `complete_task`, `day_briefing` and
`rsvp` over state the app already publishes. Verification: **39/39** routing fixtures
against the live registry, **6/6** deterministic guards with no model involved, and a
filesystem self-test covering collision renaming, exact undo, and restore-from-Trash.

## Three rails that apply to every tool below

1. **Reads answer; writes propose.** A read (find, list, summarise) returns a page. A write
   returns a page you confirm. Nothing the model produces reaches the disk or the calendar
   unreviewed, because a 4B-class model will eventually invent an argument.
2. **Nothing is deleted, ever.** Files go to the Trash, which is reversible by the user
   outside the app too. `rm` is not in the registry and will not be.
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
| `schedule_organize` | Every N hours, or daily at a time | **built** — `OrganizeJob.scheduleKind` |
| `list_jobs` / `pause_job` | What's running on its own, and stop it | wire |

## D · Calendar

| Tool | Does | Status |
|---|---|---|
| `create_event` | Meeting, hold, all-day, repeating, with invitees | **built** |
| `find_time` | Free slots, grouped and ranked, hold one | **built** |
| `whats_on_today` | Today at a glance | **built** |
| `day_briefing` | First, last, back-to-backs, longest gap, overlaps, unanswered, no-link, tasks due | **BUILT** |
| `week_report` | Hours in meetings this week | wire |
| `meeting_hygiene` | No join link, no agenda, unanswered invitations | wire |
| `rsvp` | Accept, decline, tentative | **BUILT** — a tear-out (it reaches the organiser); says plainly that macOS Calendar can't RSVP |
| `move_event` / `cancel_event` | Reschedule or cancel | **new** — issue #22. Both models correctly refuse today because it doesn't exist |
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
| `list_recordings` | What was recorded, and whether notes exist | wire |
| `generate_notes` | Transcribe and write up a recording | wire — `MeetingNotesPipeline` |
| `catch_me_up` | Answer from a past meeting's notes | wire |
| `search_transcripts` | Find where something was said | new (small) |

## G · Reference and self

| Tool | Does | Status |
|---|---|---|
| `define_word` | Meaning, synonyms, pronunciation | wire — Dictionary plugin |
| `list_capabilities` | What Margin can do, generated from this registry | **built** |
| `open_settings` | Jump to a settings tab | wire |
| `why_no_reminder` | Read the diagnostic trail for a meeting | wire |

## H · Deliberately excluded

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
4. `move_event` / `cancel_event` — the one piece of genuinely new provider work, and the
   thing most often asked for.

Every addition also goes into `MarginFixtures`, because routing on a local model is
measured, not assumed.
