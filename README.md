# MeetingIntro

> Never be late to a meeting again — countdown overlays, voice reminders, and auto-join, right from your Mac's menu bar.

**MeetingIntro** is a macOS menu-bar app (macOS 14+) that makes sure you never miss the start of a meeting. It watches your calendar and, at the thresholds you choose before each event, fires the right nudge: a floating, always-on-top countdown overlay with a one-click **Join** button and meeting context, a system notification, and/or a spoken voice reminder. Crucially, it's context-aware — it quiets itself when you're already on a call, in Focus, screen-sharing, or in a fullscreen app, and it respects your RSVP so meetings you've declined don't interrupt you. With **"Start at Time,"** you can arm a meeting to open its conference link automatically the moment it begins, tracked by a live countdown right in the menu bar. The dropdown itself is a polished popover with a Today/Upcoming switcher, a day timeline, and "next meeting in 12m" at a glance.

Beyond reminders, MeetingIntro quietly handles the rest of your meeting workflow. It can **auto-record** meetings that have a detected conference link, capturing both system audio and your mic to dual-track `.m4a` files, then run them through on-device or cloud transcription to produce AI **meeting notes**. It adds events from plain text (**Quick Add** — "lunch with Sam tomorrow 1pm"), **mirrors** one or more calendars into another for shareable availability, and can hand off your audio output and Focus state when a meeting starts and restore them when it ends. It works with local macOS calendars (iCloud, Google, Exchange via EventKit) and connects directly to **Microsoft 365** through the Graph API, including RSVP. It's distributed as a notarized Homebrew cask with a built-in self-updater, so it stays current without any fuss.

## Features

- ⏰ **Countdown reminders** — floating overlay, system notification, and/or voice, per-threshold.
- 🎬 **One-click Join** + **Start at Time** auto-join with a live menu-bar countdown.
- 🧠 **Context-aware** — suppresses reminders when you're in a call, in Focus, screen-sharing, or fullscreen.
- 🗓️ **Today / Upcoming** popover with a day timeline and the next meeting at a glance.
- 🔴 **Auto-recording** of meetings with a detected link → transcript + AI **meeting notes**.
- ✍️ **Quick Add** — natural-language text to calendar event.
- 🔁 **Calendar mirror** — one-way sync from one or more calendars into another (shareable availability).
- 🔊 **System handoff** — switch audio output + Focus on meeting start, restore on end.
- 🔗 **Backends** — local calendars via EventKit (iCloud, Google, Exchange) and **Microsoft 365** via Graph (incl. RSVP).
- 🙅 **RSVP-aware** — declined / unanswered invitations don't interrupt you.

## Install

With [Homebrew](https://brew.sh):

```sh
brew install --cask templegit9/tap/meetingintro
```

The app runs in the menu bar (no Dock icon) and updates itself from within Settings → About. It's notarized and stapled by Apple.

## Requirements

- macOS 14 (Sonoma) or later
- Calendar access (and, for recording, Microphone + Screen Recording permissions)

## Feedback

Found a bug or have a feature request? Use the in-app **Settings → About → Feedback** link, or open an issue.

## License

MIT — see [LICENSE](./LICENSE). Free to use, fork, and modify; keep the copyright notice.

© 2026 TempleGit
