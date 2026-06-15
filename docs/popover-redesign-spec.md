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
   - Title row: "MeetingIntro" or the selected date; right-aligned **status** ("synced 2m ago").
     ⚠️ **Correction:** `CalendarManager` has no public last-refresh timestamp (`lastPollDate` is
     `private`; `lastSync` belongs to the CalendarSync `Mirror` model, not here). **Prerequisite:**
     add `@Published private(set) var lastRefreshDate: Date?` to `CalendarManager`, set at the end
     of `refreshEvents()` (one-liner, zero risk). See §12.
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

## 11. Decisions (RESOLVED)

1. **Full `NSStatusItem` ownership — YES.** Drop `MenuBarExtra`; rebuild the native menu in AppKit.
2. **Default during rollout: native menu.** Popover is opt-in via the Menu Bar setting.
3. **Build the day-timeline** (the Canvas hero bar), not just the countdown line.
4. **Retire** the native-menu day-label/header-format settings once the popover is the default.

---

## 12. Design refinement (mac-app-designer review, grounded in the code)

A visual/UX pass against the actual source refined the tokens and caught several corrections.

### Locked decisions
- **Width: 340pt** (commit to one — variable 320–360 reads as buggy). Fits "12:59 PM" mono +
  ~160pt title + RSVP glyph + Join at 14pt padding without truncation.
- **Use `NSPopover`, not an `NSPanel`** — `.transient` behavior auto-dismisses on click-outside,
  and `show(relativeTo:of:preferredEdge:)` handles notch / multi-display placement automatically.
  (The existing `UpcomingPanelController` uses `NSPanel` because it's a *window*, not a dropdown.)
- **Don't force `.darkAqua`** (unlike the overlay panels) — the popover must work in light mode;
  let the system material show.
- **Segmented switcher:** tinted selection (`accent.opacity(0.15)` bg + accent text), NOT a solid
  accent capsule (too heavy in light mode). Build it as a custom `HStack` of buttons, not
  `Picker(.segmented)` (too tall in a popover).
- **Go straight to full `NSStatusItem` ownership** — coexistence with `MenuBarExtra` is proven
  impossible at runtime; don't build a workaround.

### Concrete tokens (highlights)
- Section headers: 10pt semibold, UPPERCASE, tracking 0.4, `.secondary`.
- Event row: time = 12pt medium **monospaced**, fixed **58pt** column (not 62); title `.body`
  (`.semibold` only for next meeting); 14pt h-pad / 6pt v-pad (≈32pt row).
- Hero "NEXT": a full-width **accent-tinted band** (`accent.opacity(0.07)`, no corner radius),
  "NEXT" 10pt + countdown 11pt mono accent + start time right-aligned; title `.subheadline` semibold.
- CalloutCard: icon (20pt frame) + title `.caption` semibold + trailing borderless action button;
  `iconColor.opacity(0.10)` fill + `0.25` stroke, radius 8, 12/8 padding, 3pt gap between cards.
  Colors: Recording = **red**, Auto-join armed / Update = **accent**, Cancelled = **orange**.
- Action rows: icon (18pt frame) `.secondary` + label `.callout` + right-aligned ⌘-shortcut hint
  (11pt mono `.tertiary`); hover highlight `Color.primary.opacity(0.05)`.
- Live updates: wrap **only** the hero + callout-card stack in one
  `TimelineView(.periodic(from: .now, by: 1))` — the event list shows static start times.

### Cheap wins (reuse existing code)
- `UpcomingDaysPanelView.eventRow` is ~90% the target EventRow — deltas: 62→58pt time column,
  add in-progress green dot, add `.onHover` highlight, swap the RSVP `contextMenu` for an **inline
  `Menu(.borderlessButton)`** (the single biggest UX win over NSMenu — promote RSVP to **Phase 3**).
- `relativeStart(_:)`, the day pager, `UpcomingDayFormat.longHeader`, and `Color(hex:)` already
  exist — reuse, don't duplicate.

### macOS-popover gotchas (must-handle)
1. **`NSApp.activate(ignoringOtherApps: true)` on show** — without it an `LSUIElement` popover
   renders but key events (⌘Q/⌘N, arrows, text fields) don't fire. (Existing panel already does this.)
2. **`.scrollBounceBehavior(.basedOnSize)`** on the events `ScrollView` — kills the wrong-feeling
   rubber-band for a menu-like surface.
3. **`SettingsLink` works** inside the hosted view but won't close the popover first — acceptable;
   don't try to intercept it (re: the v2.7.1 `showSettingsWindow:` selector that was unreliable).
4. **Icon swap** (`clock.badge.checkmark` ↔ `record.circle.fill`) becomes a manual Combine
   subscription on `recordingController.$isRecording` → `statusItem.button?.image`.
5. **`⌘Q`/shortcuts** must be bound on the SwiftUI buttons (`.keyboardShortcut`) — a custom popover
   doesn't inherit the NSMenu's free shortcuts; they fire only while the popover is focused.
6. **`Menu(.borderlessButton)` in an NSPopover** can briefly dismiss the popover on macOS 14.0–14.2
   — test on 14.0; fall back to `contextMenu` if it misbehaves.
7. **`errorMessage`** (rendered by the current NSMenu) must appear in the popover too — a small
   inline banner between hero and cards (not a card).

### Prerequisite before Phase 2
- **B1:** add `CalendarManager.lastRefreshDate` (above) — blocks the header status line.

### On the day-timeline (§4.2)
The "NEXT · in 12m" hero stands on its own; the Canvas timeline bar is **genuinely optional**, not
just deferred. A block-per-meeting bar for a 4-meeting day is less useful than the countdown
(CodexBar's bar works because it's continuous 24h utilization). Decide if it earns its cost.
