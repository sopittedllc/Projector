//
//  FullScreenVideoView.swift
//  Projector
//
//  REMOVED 2026-07-24 - intentionally left as an empty translation unit.
//
//  `FullScreenVideoView` existed because the video was embedded in the main
//  window: fullscreening the main window swapped its entire content for a bare
//  video view. The player is now its own window (see `PlayerWindowController`
//  in FloatingVideoPanel.swift) and uses native fullscreen - the green traffic
//  light, or the toggle in its hover overlay.
//
//  Keeping the custom path would have been an active bug rather than merely
//  dead code: ContentView observed `NSWindow.didEnterFullScreenNotification`
//  without filtering by window, so the *player* entering fullscreen flipped the
//  *main* window into video mode.
//
//  The file remains because only the ProjectorQuickLook group is
//  filesystem-synchronized in the pbxproj; deleting it from disk alone would
//  break the build. Safe to remove properly from within Xcode.
//
