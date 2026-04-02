# Projector - Holdout Test Scenarios

> **WARNING**: This file is for Cecilia (blind tester) ONLY.
> Development agents (Joseph, Clare, etc.) must NEVER read this file.
> The blindness is what makes the testing valuable.

## Test Personas

### Persona 1: Film Editor (Alex)
- **Background**: Professional editor, uses Final Cut Pro daily
- **Expectations**: Fast, responsive, keyboard shortcuts work
- **Pain points**: Lag, unclear timeline, missing standard shortcuts

### Persona 2: Music Video Director (Jordan)
- **Background**: Works with multiple audio tracks synchronized to video
- **Expectations**: Precise audio sync, easy waveform navigation
- **Pain points**: Audio drift, no waveform visibility, poor sync

### Persona 3: Content Creator (Sam)
- **Background**: YouTuber, needs quick edits and previews
- **Expectations**: Simple interface, quick export
- **Pain points**: Complexity, slow preview, confusing menus

---

## Test Categories

### First Impressions (25 points)

| Scenario | Points | Pass Criteria |
|----------|--------|---------------|
| App launches cleanly | 5 | No errors, no spinning beach ball, < 3 seconds |
| Main purpose is obvious | 5 | Can tell it's a video player/editor within 5 seconds |
| File opening works | 5 | Can open a .projector file or create new project |
| UI is responsive | 5 | No lag when clicking buttons or menus |
| Help/onboarding exists | 5 | Can find how to get started |

### Core Workflow (40 points)

| Scenario | Points | Pass Criteria |
|----------|--------|---------------|
| Play/pause video | 10 | Spacebar works, buttons work, instant response |
| Seek in timeline | 10 | Can click timeline to seek, playhead moves |
| Add media to timeline | 10 | Can import video/audio files to project |
| Audio waveforms visible | 5 | Can see waveforms in audio clips |
| Basic editing works | 5 | Can trim, move, or delete clips |

### Edge Cases (20 points)

| Scenario | Points | Pass Criteria |
|----------|--------|---------------|
| Empty project | 5 | No crashes, helpful empty state shown |
| Missing media files | 5 | Handled gracefully with option to locate |
| Large files | 5 | Performance acceptable with 1GB+ files |
| Rapid interactions | 5 | No crash/hang when clicking rapidly |

### Polish (15 points)

| Scenario | Points | Pass Criteria |
|----------|--------|---------------|
| Consistent design | 5 | Icons, colors, spacing feel unified |
| Keyboard shortcuts | 5 | Standard shortcuts work (Cmd+S, Space, etc.) |
| Window management | 5 | Resize, minimize, full-screen all work |

---

## Test Commands

```bash
# Launch app with project
open -a "Projector" ~/path/to/test.projector

# Launch app fresh
open -a "Projector"

# Check if app is running
pgrep -x "Projector"
```

---

## Scoring

- **80-100**: PASS - Ready to ship
- **60-79**: CONDITIONAL PASS - Minor issues, can ship with known issues
- **< 60**: FAIL - Must fix before shipping

---

## Notes for Tester

1. Test as if you've never seen the app before
2. Don't make allowances for "it's supposed to work this way"
3. Report exactly what you see, not what you expect
4. Time how long things take - users notice lag
5. Try to break it with unusual inputs
