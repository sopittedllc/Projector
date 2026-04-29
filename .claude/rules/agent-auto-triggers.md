# Agent Auto-Trigger Rules

> These rules define when agents should be automatically invoked.

## Mandatory Triggers (MUST use)

### Before ANY Commit
```
TRIGGER: User says "commit", "push", or requests git operations
ACTION: Run gabriel (which dispatches clare + cecilia as needed)
BLOCK: Do not commit until QA passes
```

### Before Building New Features
```
TRIGGER: User describes a new feature to build
ACTION: Run thomas to research the problem space first
BLOCK: Do not start implementation until research is reviewed
```

### Before Implementing from Plan
```
TRIGGER: User approves a plan and says "build it" or "implement"
ACTION: Use joseph (not generic implementation)
REASON: joseph enforces no-scope-creep discipline
```

### When Code Review Requested
```
TRIGGER: User says "review", "check", or "audit" code
ACTION: Run clare for read-only review
HANDOFF: clare reports → User decides → joseph fixes (if needed)
```

## Recommended Triggers (SHOULD use)

### Weekly Maintenance
```
TRIGGER: Monday, or user says "cleanup", "maintenance"
ACTION: Run isidore for repo diagnostics
APPROVAL: Ask before deleting branches
```

### Before Any Release
```
TRIGGER: User mentions "release", "ship", "distribute", "deploy"
ACTION: Run gabriel with full QA (clare + cecilia)
BLOCK: Do not release until score >= 80
```

### After Major Refactor
```
TRIGGER: Large-scale code changes (>5 files, >200 lines)
ACTION: Run clare to verify no regressions
```

## Workflow Chain

```
1. User requests feature
   ↓
2. thomas researches (auto-trigger)
   ↓
3. joseph implements
   ↓
4. clare reviews (auto-trigger before commit)
   ↓
5. gabriel dispatches full QA if UI changes
   ↓
6. Commit (after user approval)
```

## Override Rules

User can override any trigger by explicitly saying:
- "Skip QA" - bypasses gabriel/clare
- "Quick commit" - bypasses pre-commit checks
- "No research needed" - bypasses thomas

Always document overrides:
```markdown
## Override Log
- Date: [date]
- Trigger bypassed: [which one]
- Reason: [user's stated reason]
- Risk: [what wasn't checked]
```
