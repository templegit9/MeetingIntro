---
name: project_popover_redesign
description: Visual design spec for the v2.9.0 .window-style menu-bar popover; tokens, component tree, ASCII mockup, spec gaps, and macOS gotchas — produced 2026-06-14.
metadata:
  type: project
---

Full design proposal delivered 2026-06-14. Key decisions:

- Width 340pt fixed, max-height 560pt, internal ScrollView on events list only.
- CalloutCard uses `.background(color.opacity(0.12))` + `RoundedRectangle(cornerRadius: 8)` stroke at `color.opacity(0.3)`, NOT a filled card — avoids clashing with popover material on light mode.
- EventRow time column is exactly 58pt wide (fits "12:59 PM" in SF Mono caption-medium without truncation).
- Day timeline bar (`DayTimelineBar`) deferred — hero "NEXT · title — in Xm" single line is the Phase 4 minimum; Canvas timeline is Phase 4 polish.
- No `lastSyncDate` published on CalendarManager — the "synced Xm ago" status line in the header must be driven by a local `@State` Date stamped when the popover observes a `todaysMeetings` change, OR we add `@Published private(set) var lastRefreshDate: Date?` to CalendarManager. Spec was wrong to reference it as existing.
- `lastPollDate` on CalendarManager is `private` — not directly accessible from the popover view. Same fix: expose `@Published private(set) var lastRefreshDate: Date?`.
- RSVP action in popover: inline button row (Accept / Tentative / Decline) shown only when `supportsRSVPWrite`, replacing the NSMenu submenu approach. Full row-level RSVP UI is the popover's killer feature over the native menu.

**Why:** so future sessions don't re-derive these non-obvious decisions.
**How to apply:** reference when implementing `PopoverRootView` and its sub-components.
