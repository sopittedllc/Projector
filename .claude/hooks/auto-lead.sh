#!/bin/bash
# auto-lead.sh: Automates Roadmap updates and Git sync

set -e

# 1. Parse JSON input from Claude (Session ID and Directory)
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

# 2. Check if we are in a Git repository
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  echo '{"systemMessage": "⚠️ Not a git repository. Skipping automation.", "suppressOutput": true}'
  exit 0
fi

# 3. Check for any changes (staged or unstaged)
if git diff --quiet && git diff --cached --quiet; then
  echo '{"systemMessage": "No changes detected. Roadmap & Git sync skipped.", "suppressOutput": true}'
  exit 0
fi

# 4. Git Execution
git add .

COMMIT_MSG="chore(lead): automated checkpoint for session $SESSION_ID"

if git commit -m "$COMMIT_MSG"; then
    if git push > /dev/null 2>&1; then
        echo "{\"systemMessage\": \"✅ Lead: Changes committed and pushed. Session: $SESSION_ID\", \"suppressOutput\": false}"
    else
        echo "{\"systemMessage\": \"✅ Lead: Changes committed locally (push failed - check remote).\", \"suppressOutput\": false}"
    fi
else
    echo "{\"systemMessage\": \"❌ Lead: Git commit failed.\", \"suppressOutput\": false}"
fi
