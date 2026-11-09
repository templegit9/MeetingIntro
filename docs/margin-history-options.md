# Margin history — selected design

The user selected **1C: Back of the book** on 10 September 2026. This supersedes the modal Index and earlier alternatives.

History is a page in the notebook, on cream paper with the green spine and a red ribbon at the upper right. The index has search, date groups, request titles, outcome summaries and times. Green dots mark successful executed actions; grey dots mark answers, pending proposals and dismissals. Legacy receipts without execution metadata remain neutral.

Each new user request is saved as a page when opt-in saving is enabled. Unchanged pages retain their dates. Selecting a page opens inert text receipts, never old action closures. The current conversation is parked while browsing; follow-up requests get fresh pages without duplicating the historical prefix. New page begins a fresh conversation.

⌘K toggles the Index while the notebook is focused. It is not an OS-wide shortcut. Saving, retention and clearing remain in Margin settings. Search covers request and receipt text. The illustration in the capability report is sample content, not actual history.

Verification: Debug build passed; 15 calendar and 16 behavior guards passed, including action markers, stable dates, reload and inert receipts. Native presentation and Release installation are verified separately in dev.md.

Release installed and signed. Native empty-state layout and Cmd-K navigation verified. Existing saving preference remains off; no sample entries were inserted into the user's archive.

## Saved-page ribbons — September 13, 2026

The right edge now carries up to five persistent saved-page ribbons, beneath the Index control. Palette: red (#C2382B approximately), gold (#BA8F1F), green (#295E45), purple (#594AA8), orange (#E66E1F), teal (#148278), blue (#2966C7), pink (#D15791), lime (#85A329), cyan (#33ADCC), brown (#7A4F36), and slate (#5C6978). Colours are user-chosen bookmark labels, not action-status indicators; green/grey outcome dots retain their existing meaning.

Click + to save the current request/receipt, including when automatic history saving is off. Right-click + to choose a colour. Drag + onto the paper to save with red. Click a ribbon to reopen an inert receipt; no old tool action is executed. Right-click a ribbon to edit its title/colour, move it first, or remove the ribbon. Drag a ribbon onto another to reorder. Full title and outcome appear in its tooltip. Overflow opens the Saved filter in the Index, where every saved page remains available.

Bookmark metadata is stored alongside receipts using optional fields, compatible with old history archives. Retention pruning preserves marked pages. Removing a ribbon does not delete its receipt; clearing all saved history still clears the archive. Training on the workstation is independent of this UI change.
