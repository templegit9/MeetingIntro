# Feedback Form → GitHub Issues Bridge

The "Request Feature / Report Bug" button in the app points at a Google Form so
anyone can report without a GitHub account. A Google Apps Script trigger turns
every form submission into a GitHub Issue on `templegit9/MeetingIntro`, so
GitHub Issues stays the single source of truth.

```
About tab button → Google Form → Apps Script (onFormSubmit) → GitHub Issue
GitHub users     → repo Issues directly (templates in .github/ISSUE_TEMPLATE/)
```

## One-time setup (~10 minutes)

### 1. Create the Google Form

At <https://forms.new>, create a form named **MeetingIntro Feedback** with these
questions (titles must match exactly — the script keys off them):

| # | Question title | Type | Required | Options |
|---|---|---|---|---|
| 1 | `Type` | Multiple choice | Yes | `Bug report`, `Feature request` |
| 2 | `Title` | Short answer | Yes | — |
| 3 | `Description` | Paragraph | Yes | — |
| 4 | `App version` | Short answer | No | — |
| 5 | `Your name (optional — shipped ideas get credited in the app)` | Short answer | No | — |

Then: **Send** → link icon → copy the short URL (`https://forms.gle/XXXX`).
Give that URL to Claude to wire into the app's About tab.

### 2. Create a GitHub fine-grained PAT

<https://github.com/settings/personal-access-tokens/new>
- Resource owner: `templegit9`, Repository access: **Only `MeetingIntro`**
- Permissions → Repository permissions → **Issues: Read and write**
- Expiration: 1 year (set a calendar reminder to rotate)
- Copy the token (`github_pat_...`)

### 3. Attach the Apps Script to the form

In the form editor: **⋮ (kebab menu) → Script editor** (Apps Script opens bound
to the form). Replace the default code with the script below, then:

1. **Project Settings (gear) → Script Properties → Add**: key `GITHUB_TOKEN`,
   value = the PAT from step 2. (Keeps the token out of the code.)
2. Back in the editor: **Triggers (clock icon) → Add Trigger** →
   function `onFormSubmit`, event source **From form**, event type
   **On form submit**. Save and grant the authorization prompts.

```javascript
const REPO = "templegit9/MeetingIntro";

function onFormSubmit(e) {
  const answers = {};
  e.response.getItemResponses().forEach(function (ir) {
    answers[ir.getItem().getTitle()] = ir.getResponse();
  });

  const isBug = (answers["Type"] || "").indexOf("Bug") !== -1;
  const title = (isBug ? "[Bug] " : "[Feature] ") + (answers["Title"] || "Untitled report");

  const bodyParts = [answers["Description"] || "(no description)"];
  if (answers["App version"]) bodyParts.push("\n**App version:** " + answers["App version"]);
  const name = answers["Your name (optional — shipped ideas get credited in the app)"];
  if (name) bodyParts.push("**Submitted by:** " + name);
  bodyParts.push("\n---\n_Submitted via the in-app feedback form._");

  const payload = {
    title: title,
    body: bodyParts.join("\n"),
    labels: [isBug ? "bug" : "enhancement", "via-form"],
  };

  const token = PropertiesService.getScriptProperties().getProperty("GITHUB_TOKEN");
  UrlFetchApp.fetch("https://api.github.com/repos/" + REPO + "/issues", {
    method: "post",
    contentType: "application/json",
    headers: {
      Authorization: "Bearer " + token,
      Accept: "application/vnd.github+json",
    },
    payload: JSON.stringify(payload),
  });
}
```

### 4. Test

Submit the form once with Type = Bug report. Within a few seconds an issue
labeled `bug` + `via-form` should appear at
<https://github.com/templegit9/MeetingIntro/issues>. If not, check the
Apps Script **Executions** panel for the error (usually a token-permission
issue).

## Maintenance

- **Token expiry**: the PAT expires after a year; the script starts failing
  silently (check Executions). Rotate at the same settings URL, update the
  Script Property.
- **Spam**: if the form attracts junk, switch it to "respond once per Google
  account" (form Settings) — costs anonymity but keeps the no-GitHub-account
  property.
