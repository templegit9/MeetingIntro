# App Store listing copy

Draft for approval. Character limits are Apple's and are counted below each field.

---

## App name (30 max)

```
MeetingIntro
```
12 characters. Must be unique across the whole store; App Store Connect says so immediately
when you create the record.

## Subtitle (30 max)

```
A countdown before every call
```
29 characters.

Alternatives if that reads flat:
- `Never walk into a meeting late` (30)
- `Your meetings, announced` (24)
- `The reminder Outlook forgot` (27)

## Promotional text (170 max, editable without a new build)

```
Reminders you cannot miss: a full screen countdown, a spoken heads up, and a Join button that opens the right link. Works with Google, iCloud, Exchange and Microsoft 365.
```
168 characters.

## Description (4000 max)

```
I missed a meeting with a member of my company's leadership earlier this year. She was
gracious about it and we found another slot, but I decided it should never happen again,
to me or to anyone else. Calendar notifications are a small grey banner that slides past
while you are reading something else. That is the problem MeetingIntro fixes.

At the times you choose before each meeting, MeetingIntro announces it. A countdown
overlay appears over whatever you are doing, with background music, the meeting title,
who is attending, and one button that opens the correct Zoom, Teams or Meet link. It can
speak the reminder aloud. It can post a system notification with its own sound. You decide
which of those fires at 15 minutes, at 5 minutes, at 1 minute, or at any threshold you add.

WHAT IT DOES

Countdown overlay. A floating panel that appears over full screen apps, counts down, and
keeps counting after the start time so a meeting you are late for stays visible until you
join or dismiss it.

Start at Time. Arm a meeting and the link opens by itself when it begins. A countdown
appears in the menu bar so you always know what is coming, and one click cancels it.

Every calendar at once. Google, iCloud, Exchange and anything else in macOS Calendar,
plus a work calendar read directly from Microsoft 365. A meeting that appears in both is
shown once.

It knows when to stay quiet. If you are already on a call, in Do Not Disturb, or sharing
your screen, the overlay holds back. Reminders that interrupt the thing they are reminding
you about get switched off, and then they protect you never.

Quick Add. Type "lunch with Sam tomorrow 1pm" and it becomes an event, with every
assumption it had to make written on screen before you create it.

Recording and notes. Optionally record a meeting to a file on your Mac, transcribe it on
device, and write up notes. Nothing is uploaded unless you configure a cloud provider with
your own key.

Plugins, all off by default. A file organiser, a dictionary, a news style ticker across
the menu bar, and a reminder to close your camera cover after calls.

WHAT IT DOES NOT DO

No account. No sign up. No analytics, no telemetry, no tracking. I never receive your
calendar, your recordings, or any record that you use the app. There is no server of mine
for any of it to reach. The full privacy policy is at
github.com/templegit9/MeetingIntro/blob/main/PRIVACY.md

MeetingIntro is a menu bar app. It has no Dock icon and no window until you ask for one.
It needs access to your calendars, and to your microphone only if you switch recording on.
```

Roughly 2,350 characters, well inside the limit.

## Keywords (100 max, comma separated, no spaces after commas)

```
meeting,reminder,countdown,calendar,menubar,outlook,zoom,teams,notes,focus,agenda,standup
```
89 characters. Deliberately excludes "MeetingIntro" — the app name is already indexed, so
repeating it wastes the budget.

## Category

Primary: **Productivity**. Secondary: **Business**.

## Support URL

```
https://github.com/templegit9/MeetingIntro/issues
```

## Privacy Policy URL

```
https://github.com/templegit9/MeetingIntro/blob/main/PRIVACY.md
```
Accepted by App Store Connect. The vercel.app address is rejected by its URL validator.

## Privacy nutrition labels

Answer **Data Not Collected**. Nothing is gathered by the developer. The calendar data,
recordings and any text sent to an AI provider are all either local or sent directly to a
service the user chose and authenticated themselves, which Apple does not count as
collection by the developer.

## Review notes (for the App Review team)

```
MeetingIntro is a menu bar app that reminds you about calendar meetings.

No account or login is required to review the app. Grant calendar access when prompted and
add an event a few minutes in the future, or use Settings > Countdown > "Test Countdown
Overlay", which triggers every reminder surface with a synthetic meeting and needs no
calendar data at all.

Recording is off by default and never starts on its own. When enabled it captures meeting
audio via ScreenCaptureKit and the microphone, writes a local .m4a file, posts a
notification when it starts, and marks the menu bar while it runs. No video is captured.

The AI features are optional and require the user's own API key. Without a key the app
falls back to on device parsing and works fully.

Microsoft 365 support is optional and signs in with the user's own Microsoft account.
```
