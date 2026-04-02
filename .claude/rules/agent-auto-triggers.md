# Agent Auto-Trigger Rules

> These rules define when agents should be automatically invoked.

## Mandatory Triggers (MUST use)

### Before ANY Commit
```
TRIGGER: User says "commit", "push", or requests git operations
ACTION: Run Gabriel (which dispatches Clare + Cecilia as needed)
BLOCK: Do not commit until QA passes
```

### Before Building New Features
```
TRIGGER: User describes a new feature to build
ACTION: Run Thomas to research the problem space first
BLOCK: Do not start implementation until research is reviewed
```

### Before Implementing from Plan
```
TRIGGER: User approves a plan and says "build it" or "implement"
ACTION: Use Joseph (not generic implementation)
REASON: Joseph enforces no-scope-creep discipline
```

### When Code Review Requested
```
TRIGGER: User says "review", "check", or "audit" code
ACTION: Run Clare for read-only review
HANDOFF: Clare reports → User decides → Joseph fixes (if needed)
```

## Recommended Triggers (SHOULD use)

### Weekly Maintenance
```
TRIGGER: Monday, or user says "cleanup", "maintenance"
ACTION: Run Isidore for repo diagnostics
APPROVAL: Ask before deleting branches
```

### Before Any Release
```
TRIGGER: User mentions "release", "ship", "distribute", "deploy"
ACTION: Run Gabriel with full QA (Clare + Cecilia)
BLOCK: Do not release until score >= 80
```

### After Major Refactor
```
TRIGGER: Large-scale code changes (>5 files, >200 lines)
ACTION: Run Clare to verify no regressions
```

### When Something Breaks Unexpectedly
```
TRIGGER: User reports bug that "was working before"
ACTION: Run Coroner for forensic analysis
HANDOFF: Coroner → Surgeon (with user approval)
```

## Integration with Existing Agents

| Skip's Agent | Replaces/Augments | Notes |
|--------------|-------------------|-------|
| Clare | Augments qa-auditor | Clare for quick review, qa-auditor for deep audit |
| Thomas | Augments arch-architect | Thomas for research, architect for design |
| Joseph | Augments backend-logic/ui-specialist | Joseph for scope control, specialists for domain expertise |
| Gabriel | New | Pre-merge QA gate |
| Cecilia | New | Blind product testing |
| Isidore | New | Git maintenance |

## Workflow Chain

```
1. User requests feature
   ↓
2. Thomas researches (auto-trigger)
   ↓
3. arch-architect designs (existing workflow)
   ↓
4. scope-guard checks (existing workflow)
   ↓
5. Joseph implements (or backend-logic/ui-specialist)
   ↓
6. Clare reviews (auto-trigger before commit)
   ↓
7. Gabriel dispatches full QA if UI changes
   ↓
8. the-lead updates roadmap
   ↓
9. the-librarian captures learnings
```

## Override Rules

User can override any trigger by explicitly saying:
- "Skip QA" - bypasses Gabriel/Clare
- "Quick commit" - bypasses pre-commit checks
- "No research needed" - bypasses Thomas

Always document overrides:
```markdown
## Override Log
- Date: [date]
- Trigger bypassed: [which one]
- Reason: [user's stated reason]
- Risk: [what wasn't checked]
```
