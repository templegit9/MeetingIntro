# Development Pattern

## Working Pattern with AI Agent
1. **Plan first** — always review/update `plan.md` before starting implementation.
2. **Iterative development** — build one component at a time, verify, then move on.
3. **Document as you go** — update `dev.md`, `assumptions.md`, and `AGENT_RULES.md` with each change.
4. **Test immediately** — after creating/editing code, build and run to validate.
5. **No hardcoding** — use configuration / UserDefaults for all tunable values.

## Commit Pattern
- Meaningful commit messages following conventional commits.
- Commit after each working milestone (e.g., "feat: add CalendarManager with EventKit polling").

## File Organization
- Swift source files live in the `MeetingIntro/` Xcode target folder.
- Documentation and config stay at the project root.
