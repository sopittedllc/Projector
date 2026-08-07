---
allowed-tools: Bash, Read
description: Verify a DMG passes all Gatekeeper checks before distribution
argument-hint: [path-to-dmg]
---

# Verify Distribution DMG

Run comprehensive verification on a DMG to ensure it will pass Gatekeeper for users.

## Steps

1. Run the verification script on the specified DMG (or the most recent one in release-build/):

```bash
cd /Users/keegandewitt/Developer/Projector && ./scripts/verify-distribution.sh $ARGUMENTS
```

If no path is provided, find the most recent DMG:

```bash
cd /Users/keegandewitt/Developer/Projector && ./scripts/verify-distribution.sh "$(ls -t release-build/*.dmg 2>/dev/null | head -1)"
```

2. Report the results clearly:
   - PASS or FAIL for each of the 6 checks
   - If any checks failed, explain what's wrong and how to fix it
   - If all pass, confirm the DMG is ready for distribution
