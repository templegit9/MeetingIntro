# MeetingIntro Privacy Policy

_Last updated 17 September 2026_

**I collect nothing.** MeetingIntro has no account, no sign up, no analytics, and no
telemetry. I do not receive your calendar, your recordings, your files, or any record that
you use the app at all. There is no server of mine for any of it to go to.

A formatted version of this page is at
<https://meetingintro-roadmap.vercel.app/privacy>.

## What the app reads, and where it stays

MeetingIntro runs entirely on your Mac. Everything below is stored on your own machine and
never sent anywhere unless a section further down says otherwise.

| Data | Where it lives |
| --- | --- |
| Calendar events | Read through macOS Calendar (EventKit) to know when your meetings are. Titles, times, attendees, notes and join links stay on the Mac. |
| Meeting recordings | Saved as .m4a files in ~/Movies/MeetingIntro, or a folder you pick. Never uploaded by the app. |
| Transcripts and notes | Written next to the recording as .transcript.md and .notes.md files. |
| Tasks and settings | macOS preferences for this app. |
| Diagnostic logs | ~/Library/Application Support/MeetingIntro/Diagnostics, kept for 7 days and then deleted automatically. You can read them in Settings. |
| Credentials | Any API key you enter, and the Microsoft 365 and Google sign in tokens, are stored in the macOS Keychain. Never in a plain file, never transmitted except to the service they belong to. |

## When data does leave your Mac

Five features can send data off the machine. **Every one of them is off until you turn it
on**, and each sends only to a service you chose and configured yourself.

- **Microsoft 365 calendar.** If you sign in, the app reads your calendar from Microsoft
  Graph and can create, move or cancel events there. That traffic goes to Microsoft under
  your own account, governed by Microsoft's privacy terms, not mine.
- **Google Calendar.** If you sign in, the app reads your calendar from Google and can
  reply to invitations and create events there. It requests three scopes and no more:
  `calendar.events` (read your events, and send your accept, tentative or decline),
  `calendar.calendarlist.readonly` (list your calendars so you can choose which to watch),
  and `calendar.freebusy` (when a time is free, for suggesting an alternative). That
  traffic goes to Google under your own account, governed by Google's privacy terms, not
  mine. **Your Google data is never sent anywhere except Google**, is not stored off your
  Mac, is not used to train any model, and is not shared with anyone.
- **Cloud transcription.** On device transcription with WhisperKit sends nothing anywhere.
  If you instead supply a Groq key, the meeting audio is uploaded to Groq to be transcribed.
- **AI parsing and notes.** Quick Add's smart parsing, meeting notes and the File Organizer
  can use an AI provider you configure with your own key: OpenRouter, Groq, Google Gemini,
  Cerebras, Anthropic, OpenAI, or a local Ollama. The text being processed goes to whichever
  you pick. With Ollama it never leaves the Mac.
- **Update checks.** The version installed with Homebrew asks GitHub's public releases API
  whether a newer version exists. It sends no information about you. The Mac App Store
  version does not do this at all, because the store handles updates.

## What the app deliberately does not do

- No analytics, crash reporting, or usage tracking of any kind.
- No advertising, and nothing sold or shared with anyone.
- No account, so there is nothing of yours for me to hold.
- Recordings are never uploaded automatically, and never without you enabling recording first.
- The camera is never opened. The camera cover reminder reads whether some other app is
  streaming, which is a property read, so no camera permission is requested and the green
  light never comes on.

## Permissions, and why each is asked for

| Permission | Why |
| --- | --- |
| Calendars | To see your meetings. This is the app. |
| Notifications | To deliver the reminders you configure. |
| Microphone | Only if you enable recording, for your side of the call. |
| Screen Recording | Only if you enable recording. It captures meeting audio through ScreenCaptureKit. **No video is ever recorded.** |
| Focus status | To stay quiet while you are in Do Not Disturb. |

## Recording other people

**Recording a conversation is your responsibility.** Laws differ by country and by state,
and many require everyone on the call to consent. MeetingIntro records only when you switch
it on, shows a notification when a recording starts, and marks the menu bar while it runs.
Please tell the people you are meeting.

## Children

MeetingIntro is a tool for work meetings and is not directed at children. It collects
nothing from anyone, of any age.

## Changes

If this policy changes I will update this page and change the date at the top.

## Contact

Questions about privacy, or anything else, go to
<https://github.com/templegit9/MeetingIntro/issues>.

MeetingIntro is made by Oluyinka Oginni.
