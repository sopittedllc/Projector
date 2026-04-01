# Resume Prompt

Copy this into a new Claude Code session to resume work:

---

```
Resume session from crash/disconnect. Read these files to get context:

1. `.claude/SESSION_STATE.md` - Current task, todos, modified files
2. `PROJECT_ROADMAP.md` - Overall progress (currently 100%)
3. `CLAUDE.md` - Project standards and agent workflow

After reading, summarize:
- What was I working on?
- What files were modified?
- What's the next action?

Then continue from where we left off.
```

---

## Alternative: Quick Status Check

```
Read `.claude/SESSION_STATE.md` and give me a 3-line summary of current status.
```

---

## Alternative: Full Context Load

```
I'm resuming work on Projector. Read these files in order:
1. `.claude/SESSION_STATE.md`
2. `PROJECT_ROADMAP.md`
3. `FEATURES.md`
4. `CLAUDE.md`

Then tell me the project status and await my next instruction.
```
