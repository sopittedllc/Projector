# Rule: UI Composition First

## The Problem This Solves

On 2026-04-01, multiple UI redundancies shipped because changes were made piecemeal:
- Banner added for optimization suggestions
- Button already existed in header for same action
- Result: 3 ways to do the same thing, cluttered UI

## Before ANY UI Change

1. **Read the PARENT view first** - not just the component you're editing
2. **List all existing UI elements** that relate to the feature
3. **Ask: "What's already there?"** before adding anything new
4. **Check for redundancy** - does this duplicate existing functionality?

## The Composition Checklist

Before modifying any `Views/` file:

```
□ What view contains this component?
□ What sibling components exist?
□ Does similar functionality already exist elsewhere in this view?
□ If adding a banner/alert, is there already a button for this?
□ If adding a button, is there a contextual prompt that handles this?
```

## Example: The Optimization Failure

**What happened:**
- OptimizationSuggestionBanner added (smart, contextual)
- OptimizeMediaButton already in header (redundant)
- Banner also has "Optimize" button
- User sees: Header button + Banner + Banner button = 3 access points

**What should have happened:**
- Before adding the banner, check FileManagerView header
- See OptimizeMediaButton exists
- Decision: Banner REPLACES header button (not adds to it)

## The Macro Fix

**Every UI addition must answer:**
1. What already exists for this feature?
2. Am I adding or replacing?
3. What will the user actually see when this composes?

## Enforcement

Claude must read the parent view and list existing related UI elements before proposing any UI change.
