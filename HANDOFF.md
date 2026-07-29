# Settings UI Handoff

## Current State
Settings UI changes are live in the build. Git shows clean but changes exist in DerivedData.

## What Was Attempted
1. Transport bar padding - Removed duplicate horizontal padding from VitalControlsBar
2. Settings layout - Changed from fixed-width labels to inline HStack
3. Channel linking hover - Changed from view-swapping to state-based styling (added `isInLinkPreview`/`showLinkText` params to ChannelCellView)

## What's Broken
1. **Link hover UX** - 32x32 channel cells too small for meaningful feedback. Text "Link?" gets truncated. Icon approach still cramped.
2. **Overall settings layout** - No coherent plan. Changes were incremental patches, not designed.
3. **Root cause** - Kept tweaking symptoms instead of designing a proper layout system.

## Files Modified
- `SettingsAccordionView.swift` - Channel grid rewrite, ChannelCellView params, removed LinkPreviewView
- `VitalControlsBar.swift` - Removed internal horizontal padding
- `LayoutConstants.swift` - labelWidth changed to 100pt

## What Needs to Happen
The Settings UI needs a **designed layout spec** before more code:
- Define cell sizes that accommodate linking UX
- Define column widths and spacing
- Decide how link preview should look (spanning overlay vs individual cell styling)
- Consider whether 32px cells are viable or need to be larger

## User Feedback From Session
- "the link? hover is not working"
- "these dropdowns are so far from their labels for no reason"
- "I continue to feel like we have no plan for UI for this section"
- "you are not doing quality work"
