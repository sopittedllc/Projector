# Rule: UI Verification Required

## Trigger
Any change to files in `Views/` directory.

## Requirement
After UI changes, Claude MUST:

1. **Remind the user** that runtime testing is required
2. **Provide a specific checklist** of what to verify for that change
3. **NOT declare the feature complete** until user confirms it works

## Example Response After UI Change

```
Build succeeded. Before we commit, please verify:

- [ ] Click the settings gear icon - does SettingsView appear (not an empty dialog)?
- [ ] Drag a file onto the timeline - does SpotMediaSheet appear?
- [ ] Check the timeline footer - is the hint text vertically centered?

Let me know if anything looks wrong.
```

## Why This Rule Exists

On 2026-04-01, multiple UI bugs shipped because:
- Code audits checked syntax, types, layer violations
- Nobody actually ran the app and clicked the buttons
- Issues were only found when the user tested manually

See: `docs/incidents/2026-04-01-ui-issues-batch.md`

## Enforcement

Claude cannot mark UI tasks as complete until user explicitly confirms verification.
