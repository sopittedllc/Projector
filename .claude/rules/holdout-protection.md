# Holdout Protection Rule

> **Path Pattern**: `.qa-criteria/*`

## Rule

**DEVELOPMENT AGENTS MUST NOT READ HOLDOUT FILES.**

The files in `.qa-criteria/` contain test scenarios that are deliberately hidden from development agents. This "blindness" is what makes blind testing valuable.

## Why This Matters

If the same AI that writes code also knows the test criteria, it will optimize for passing the test rather than building a genuinely good product. The holdout scenarios are only for Cecilia (blind tester).

## Allowed Access

| Agent | Can Read .qa-criteria? |
|-------|------------------------|
| Cecilia | YES - this is her job |
| User | YES - you write the scenarios |
| Clare | NO |
| Thomas | NO |
| Joseph | NO |
| Gabriel | NO (dispatches Cecilia who can) |
| Any dev agent | NO |

## If You're a Development Agent

If you find yourself about to read `.qa-criteria/holdout-scenarios.md`:

1. **STOP**
2. Ask yourself: "Am I Cecilia?"
3. If no, **DO NOT READ IT**
4. If you need to know what to test, ask the user or spawn Cecilia

## Violation Response

If a development agent reads the holdout file:
```markdown
## WARNING: Holdout Protection Violated

Agent [name] read `.qa-criteria/holdout-scenarios.md`.
This compromises blind testing.

Recommended actions:
1. Regenerate holdout scenarios
2. Have user write new test criteria
3. Document incident in docs/incidents/
```

## Exception

The only valid exception is if the user explicitly asks you to show them the holdout file contents. In that case, document:
```markdown
## Holdout Access Log
- Date: [date]
- Requested by: User
- Reason: [stated reason]
```
