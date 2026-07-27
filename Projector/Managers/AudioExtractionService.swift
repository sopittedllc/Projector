//
//  AudioExtractionService.swift
//  Projector
//
//  REMOVED 2026-07-25 - intentionally left as an empty translation unit.
//
//  `AudioExtractionService` had zero call sites. It was a near-copy of the
//  audio-extraction path that actually runs, which lives in
//  ContentView+Timeline.swift (`prepareAudioLaneIfNeeded`,
//  `extractAudioInBackground`, `extractAudioTrackToTemp`).
//
//  Worse than merely unused: its copy emitted the *same* debugPrint strings as
//  the live one ("prepareAudioLaneIfNeeded: Created new lane ..."), so a log
//  line could not be attributed to a function with certainty. It had also
//  drifted - the live copy skips lanes reserved by an in-flight batch drop and
//  names lanes after their media, while this copy still adopted any free lane
//  and named everything "Audio N".
//
//  If audio extraction is ever lifted out of the view layer (it does belong in
//  a manager), start from the live implementation, not from this file's
//  history.
//
//  The file remains because only the ProjectorQuickLook group is
//  filesystem-synchronized in the pbxproj; deleting it from disk alone would
//  break the build. Safe to remove properly from within Xcode.
//
