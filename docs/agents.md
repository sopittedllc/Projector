# Projector Agent System

This project uses specialized AI agents for role separation. Each agent has specific capabilities and constraints that create adversarial checks.

## Agent Overview

### Development Agents (Write Access)

| Agent | Role | When to Use |
|-------|------|-------------|
| **joseph** | Implementer | Writing code from approved plans |
| **backend-logic** | MIDI/Audio specialist | CoreMIDI, CoreAudio, AVFoundation code |
| **ui-specialist** | SwiftUI/AppKit specialist | Views, layouts, animations |

### Review Agents (Read-Only)

| Agent | Role | When to Use |
|-------|------|-------------|
| **clare** | Code reviewer | Before merging any code |
| **thomas** | Researcher | Before building anything new |
| **qa-auditor** | Deep code audit | Detailed standards compliance |

### Utility Agents

| Agent | Role | When to Use |
|-------|------|-------------|
| **isidore** | Repo janitor | Git cleanup, branch management |
| **gabriel** | QA dispatcher | Pre-merge QA gate |
| **cecilia** | Blind product tester | Testing running app |
| **scope-guard** | Scope control | Preventing feature creep |

### Post-Mortem Agents

| Agent | Role | When to Use |
|-------|------|-------------|
| **coroner** | Forensic analysis | When something breaks unexpectedly |
| **surgeon** | Fix implementation | Implementing coroner-approved fixes |

### Project Management

| Agent | Role | When to Use |
|-------|------|-------------|
| **the-lead** | Roadmap maintainer | After features complete |
| **arch-architect** | System design | Before starting implementation |
| **the-librarian** | Knowledge capture | After learning something new |

## How to Use Agents

### Natural Language
```
"Have Clare review the code I just wrote"
"Use Thomas to research MTC synchronization"
"Run Isidore to clean up branches"
```

### Explicit Spawn
```
"Spawn Clare to review src/"
"Spawn Thomas to research rate limiting"
```

### In Workflow
```
"I want a full QA pass before merge - use Gabriel"
```

## Agent Frontmatter

Agents are defined in `.claude/agents/*.md` with YAML frontmatter:

```yaml
---
name: agent-name
aliases: ["alias1", "alias2"]
description: "When to use this agent"
tools:
  - Read      # Can read files
  - Write     # Can write files
  - Edit      # Can edit files
  - Grep      # Can search
  - Bash      # Can run commands
model: sonnet  # or opus, haiku
memory: project
---
```

## Directory Structure

```
.claude/
  agents/           # Agent definitions
  rules/            # Path-based rules (auto-load)
  commands/         # Slash commands
  hooks/            # Event hooks

.work/
  active/           # Work-in-progress plans

.qa-criteria/
  holdout-scenarios.md  # Cecilia's test criteria (blind)

docs/
  learnings/        # Lessons learned
  incidents/        # Post-mortems
  agents.md         # This file
```

## Constraints Are Features

The agents are valuable because of their constraints:
- **Clare can't fix code** - provides unbiased review
- **Thomas can't write files** - prevents premature implementation
- **Cecilia can't read source** - provides blind user testing
- **Joseph can't expand scope** - prevents feature creep

These constraints create adversarial checks that catch what a single "do everything" AI would miss.

## Adding New Agents

1. Create `.claude/agents/your-agent.md`
2. Add YAML frontmatter with tools list
3. Document role, constraints, and output format
4. Add to this reference file

## Related Files

- `CLAUDE.md` - Project standards (agents inherit these)
- `KNOWLEDGE_BASE.md` - Golden patterns
- `PROJECT_ROADMAP.md` - Progress tracking
- `FEATURES.md` - Feature registry
