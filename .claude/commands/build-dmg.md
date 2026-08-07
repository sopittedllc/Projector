---
allowed-tools: Bash, Read
description: Build, sign, notarize and create distributable DMG
---

# Build Release DMG

Execute the release build script to create a signed, notarized DMG for distribution.

## Steps

1. Run the build-release.sh script (uses current date as version automatically):

```bash
cd /Users/keegandewitt/Developer/Projector && ./scripts/build-release.sh
```

2. After the build completes, run the verification script to confirm all checks pass:

```bash
./scripts/verify-distribution.sh release-build/Projector-*.dmg
```

3. Report the results to the user, including:
   - Location of the DMG file
   - Whether all 6 verification checks passed
   - File size of the DMG
   - Reminder to upload to distribution location (Dropbox)

If any verification checks fail, explain what failed and how to fix it.
