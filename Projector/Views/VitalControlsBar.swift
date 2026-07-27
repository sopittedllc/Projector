//
//  VitalControlsBar.swift
//  Projector
//
//  REMOVED 2026-07-26 - intentionally left as an empty translation unit.
//
//  The transport bar that used to run across the top of the main window. Its
//  contents were dispersed rather than deleted:
//
//  - Start TC and Duration  -> TimelineTimecodeControls (TimelineAccordionView)
//  - Incoming MIDI, POS, FPS -> TimelineHeaderReadouts (TimelineAccordionView)
//  - Play/stop and pop-out   -> the hover overlay on InlineVideoArea
//    (FloatingVideoPanel.swift), sitting on the picture itself
//  - The Projector wordmark  -> dropped; the window title already reads
//    "PROJECTOR: <project name>", so the bar spent ~90pt repeating it
//
//  What remained afterwards was a full-width bar holding two buttons, which is
//  why the video moved into that space instead.
//
//  The spacebar binding lived here, in a zero-size Button inside the play
//  indicator. It now lives in InlineVideoArea, still always-mounted and
//  invisible - it has to keep working while the video is popped out, so it
//  cannot depend on the hover overlay being on screen.
//
//  The `transportBox()` modifier introduced for this bar went with it; the
//  header readouts use `headerFieldBox()` in TimelineAccordionView, which
//  matches the editable timecode fields they sit beside.
//
//  The file remains because only the ProjectorQuickLook group is
//  filesystem-synchronized in the pbxproj; deleting it from disk alone would
//  break the build. Safe to remove properly from within Xcode.
//
