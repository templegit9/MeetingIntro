# Spec — Menu-bar popover redesign (`.window`-style dropdown)

> Status: **proposal / not implemented.** Target: a future minor (suggested **v2.9.0**).
> Inspiration: CodexBar's `.window` popover. This spec is design + architecture only — no code.
> Authored after the v2.8.x menu-bar work (upcoming-days browsing, day-label/header formats).

## 1. Goal

Replace the flat native NSMenu dropdown with a **custom popover** that supports real layout —
hierarchy, columns, cards, a day timeline, and disclosure rows — while keeping the existing
native menu available as a fallback. The popover is the "north star" surface CodexBar
demonstrates; our current `.menu` style fundamentally can't render it (text-only menu items).

Non-goals (this phase): changing reminder/overlay logic, calendar backends, or any data model.
This is a **presentation-layer** project.

## 2. Why this needs an architecture change

`MenuBarExtra` **cannot switch between `.menu` and `.window` styles at runtime** — SwiftUI's
SceneBuilder has no `buildEither`, and the two styles are incompatible content models (proven
during v2.8.0). Therefore, to offer **both** a native menu and a rich popover as a user choice,
we must **stop using `MenuBarExtra` and own the `NSStatusItem` directly** in AppKit:

- One app-managed `NSStatusItem` (the icon + recording/countdown state).
- On click, present **either** an `NSMenu` (menu mode) **or** an `NSPopover` hosting a SwiftUI
  view (popover mode), based on the `upcomingViewStyle` / a new `menuBarPresentation` setting.

This is the load-bearing decision. Everything else depends on it. (Alternative considered and
rejected: a second status item or a panel launched from the menu — that's the v2.8.0 interim we
already shipped; it isn't the real dropdown-popover.)

## 3. Design language (tokens)

Grounded in the app's existing dark overlay aesthetic and the user accent.

- **Surface:** popover with system material; dark-leaning. Corner radius ~12. Width **320–360**,
  height content-driven with a max (~560) then internal scroll for the events list.
- **Accent:** the existing user highlight color (`nextMeetingHighlightHex`, default `#4F8CF7`).
  Use it for the "next meeting," the day-timeline marker, and primary actions. One accent only.
- **Secondary emphasis:** reserve a second hue **only** for the live "Recording" card (red) —
  mirrors CodexBar reserving blue for its single highlighted card.
- **Type scale:**
  - Section titles: `.headline` / `.subheadline` semibold.
  - Primary values (meeting title, "in 12m"): `.body` / `.callout`, medium–semibold.
  - Meta (dates, counts, "synced 2m ago"): `.caption`/`.caption2` secondary.
  - Numbers/times: monospaced digits for alignment.
- **Spacing:** 14pt horizontal padding, ~6–8pt row vertical, dividers between logical groups,
  generous group spacing (CodexBar's vertical rhythm is a big part of why it reads well).
- **SF Symbols:** keep `clock.badge.checkmark` identity; `video.fill` (join), `record.circle.fill`
  (recording), `clock.badge.checkmark` (armed), `chevron.right` (disclosure), `chevron.left/right`
  (day paging).

## 4. Information architecture (top → bottom)

1. **Header**
   - Title row: "MeetingIntro" or the selected date; right-aligned **status** ("synced 2m ago",
     from `CalendarManager.lastSync`-equivalent / last poll).
   - **Segmented switcher:** `Today | Upcoming` (and, if multiple providers configured,
     a source toggle). Accent-filled selected segment.
2. **Day timeline (hero)** — a horizontal bar representing the workday with meeting blocks; a
   "NEXT · {title} — in {countdown}" line beneath, accent-colored. This is our analogue of
   CodexBar's hero usage bar. (Today view only.)
3. **Live callout cards** (only when active, accent/red boxed):
   - 🔴 Recording — {title} · **Stop**
   - ⏱ Auto-join armed — {title} {time} · **Cancel**
   - ⬇︎ Update available — install v{X} · **Update**
   - ✕ Cancelled today — {title} · **Dismiss** (or a compact stack)
4. **Events list** (columned rows, scrollable):
   - `time` (mono, right-padded) · `title` (truncating) · trailing **RSVP glyph** + **Join** button.
   - Next meeting gets the accent treatment (bold + accent time + "in 12m").
   - Cancelled = strikethrough + red glyph. In-progress = green dot.
   - **Today view:** today's meetings. **Upcoming view:** day pager (`‹ Wed, Jun 18 ›`) with that
     day's events — reuses the `events(on:)` data already built for the panel.
5. **Disclosure / action rows** (icon + label, ⌘-shortcut right-aligned):
   - Meeting Notes … ›  (⌘M)
   - New Event …      (⌘N)
   - Refresh          (⌘R)
   - Settings …       (⌘,)
   - Quit             (⌘Q)

ASCII north-star (from the prior discussion):
```
┌─────────────────────────────────────┐
│  ◐ Today  |  Upcoming        ⚙︎      │  segmented switcher + status
│  Wed, Jun 18 · synced 2m ago        │
├─────────────────────────────────────┤
│  ▌▌  ▌   ▌▌▌     ▌   ▌              │  day timeline
│  NEXT · Standup            in 12m   │  hero next-meeting
├─────────────────────────────────────┤
│  ┃🔴 Recording — Sprint review  Stop┃│  callout cards
│  ┃⏱ Auto-join · 2:30        cancel ┃│
├─────────────────────────────────────┤
│  9:00  Standup                  ▶   │  columned event rows
│  2:00  1:1 with Sam        tentative│
│  …  (scroll)                         │
├─────────────────────────────────────┤
│  Meeting Notes …                  › │  disclosure/action rows
│  New Event …                    ⌘N  │
│  Settings …                     ⌘,  │
└─────────────────────────────────────┘
```

## 5. Component inventory (to build, presentation only)

- `MenuBarController` (AppKit) — owns the `NSStatusItem`; toggles `NSMenu` vs `NSPopover`.
- `PopoverRootView` (SwiftUI) — the layout above; observes the existing managers.
- `SegmentedSwitcher` — Today/Upcoming (+ source) control.
- `DayTimelineBar` — the hero viz (a `Canvas`/`GeometryReader` bar of the day's blocks).
- `CalloutCard` — reusable accent/red boxed row (recording / armed / update / cancelled).
- `EventRow` — columned row with Join + RSVP (largely exists in `UpcomingDaysPanelView`/popover view).
- `DisclosureActionRow` — icon + label + trailing shortcut/chevron.
- Reuse existing data: `todaysMeetings`, `upcomingWeek`, `events(on:)`, `armedAutoJoinMeetings`,
  `pendingCancellations`, `nextMeeting`, `AppUpdater.state`, `recordingController`.

## 6. Behavior

- **Open/close:** click status item → popover (transient: closes on click-outside / Esc). Needs
  key focus for the segmented control + Join buttons (NSPopover behavior `.transient`,
  activates app).
- **Live updates:** popover observes the same `@ObservableObject`s; updates while open (the day
  timeline + "in 12m" tick via a 1s timeline, like the overlay/menu-bar countdown).
- **Keyboard:** preserve ⌘N/⌘M/⌘R/⌘,/⌘Q. Arrow keys page the Upcoming day view. Esc closes.
- **Empty states:** "No meetings today" / "Nothing on {day}".
- **Accessibility:** every row VoiceOver-labelled; respects Reduce Motion (no timeline animation),
  Increase Contrast, Dynamic Type within reason.

## 7. Settings impact

- Replace/extend the current `upcomingViewStyle` so **"Day-by-day popover"** means *this* full
  popover (not the interim panel). Likely a clearer `menuBarPresentation` setting:
  `Native menu` (default during rollout) vs `Popover`.
- The day-label/header-format settings (v2.8.2–v2.8.4) apply to the **native menu** path; the
  popover uses its own richer layout (formats become less relevant there).
- Keep everything under the **Menu Bar** settings category already created.

## 8. Risks / failure modes / mitigations

| # | Risk | Why it matters | Mitigation |
|---|------|----------------|-----------|
| 1 | **Dropping `MenuBarExtra`** means re-implementing the status item, icon, recording/countdown swap, and the *entire* native menu in AppKit `NSMenu`. | Huge regression surface — this menu is the app's main surface and is battle-tested. | Keep native menu as default; build popover behind the setting. Re-create the native `NSMenu` from the existing SwiftUI menu content faithfully, item-by-item, and diff against current behavior before flipping the default. Consider keeping `MenuBarExtra` for the menu path and only adding the popover path if a clean coexistence is found — but assume full ownership. |
| 2 | **Wiring point.** `observe()` runs from the MenuBarExtra label's `onAppear`. Removing MenuBarExtra removes that trigger. | App wouldn't start polling/overlays. | Move `observe()` to `AppDelegate.applicationDidFinishLaunching` (deterministic, always runs) — cleaner than the current view-driven trigger anyway. Keep the `hasObserved` guard. |
| 3 | **NSPopover focus/dismiss quirks** for an `LSUIElement` app (activation, click-outside, multi-display). | Popover that won't take clicks or won't dismiss is worse than the menu. | Prototype the popover shell first (open/close/focus/Join click) before building content. Use `.transient` behavior + `NSApp.activate`. Reuse lessons from `KeyablePanel`/QuickAdd. |
| 4 | **Live-updating SwiftUI in a popover** (1s timeline) waking the app. | Battery. | Only run the 1s ticker **while the popover is open** (start on show, stop on close). |
| 5 | **Scope creep / long-lived branch.** This is multi-session. | Risk of a stalled half-migration. | Phase it (below); each phase ships behind the setting and is independently revertable. Default stays native menu until the popover is verified. |
| 6 | **Visual verification is manual** (and we don't screen-capture the user's machine). | Can't headlessly confirm layout. | Ship behind the setting; user opts in and pastes screenshots; iterate. Optionally use the `mac-app-designer` agent on the real `PopoverRootView` for grounded refinement. |
| 7 | **Notarization** of any new AppKit surface. | Release gate. | No new entitlements needed (pure UI). Standard release pipeline. |
| 8 | **Two code paths to maintain** (menu + popover) indefinitely. | Maintenance cost. | Acceptable during rollout; once popover is proven, consider deprecating the native menu in a later major. |

## 9. Phasing

1. **Shell** — `MenuBarController` owns the `NSStatusItem`; reproduce the *current native menu*
   exactly (no visual change), prove parity, move `observe()` to `AppDelegate`. Ship behind a
   hidden flag. (Highest-risk plumbing, zero UX change — de-risks #1/#2.)
2. **Popover skeleton** — NSPopover hosting a minimal `PopoverRootView` (header + today list +
   action rows). Validate open/close/focus/Join (#3). Selectable via the Menu Bar setting.
3. **Hierarchy + cards** — callout cards (recording/armed/update/cancelled), columned EventRow,
   disclosure rows, status line.
4. **Hero + switcher** — segmented Today/Upcoming, day pager, day-timeline viz, 1s live ticker.
5. **Polish** — tokens, spacing, accessibility, Reduce Motion; `mac-app-designer` pass; docs +
   CLAUDE.md update; consider making popover the default.

## 10. Effort

Multi-session. Phase 1 is the riskiest (status-item ownership + menu parity). Phases 2–4 are
additive SwiftUI behind the setting. Each phase is shippable and revertable.

## 11. Open decisions (resolve before Phase 1)

1. **Full `NSStatusItem` ownership** (drop `MenuBarExtra`) — confirm appetite, since it's the
   crux. (Recommended; no clean alternative for runtime menu↔popover switching.)
2. Default presentation during rollout: **native menu** (recommended) vs popover.
3. Does the **Today timeline** earn its complexity, or start with just the "NEXT · in 12m" hero line?
4. Keep the native-menu day-label/header-format settings, or retire them once popover is default?
