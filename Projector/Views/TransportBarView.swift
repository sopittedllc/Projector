//
//  TransportBarView.swift
//  Projector
//
//  REMOVED 2026-07-25 - intentionally left as an empty translation unit.
//
//  Held two views, both with zero call sites:
//
//  - `TransportBarView` (plus its `TransportBarViewForEngine` alias). Its only
//    reference anywhere was its own `#Preview`, so it compiled and rendered in
//    Xcode but never appeared in the running app.
//  - `TimecodeDisplayView`, an overlay timecode readout, referenced nowhere.
//
//  The first was actively misleading rather than merely unused: it held the
//  app's only numeric playhead readout - `Text(playbackEngine.currentTimecode
//  .stringValue())` - which made the transport look like it already had
//  position feedback. It did not. The bar that actually renders,
//  VitalControlsBar, showed only Start TC, Duration and FPS: three static
//  project settings, nothing live. With no media loaded the player window is
//  empty too, and the timeline playhead advances ~0.08pt per second of timecode
//  at fit-to-4-hours zoom, so every source of motion feedback was absent at
//  once and a transport correctly chasing MTC looked identical to a dead one.
//
//  The readout now lives in VitalControlsBar as `positionReadout`. If transport
//  *controls* (play/pause/step/stop) are wanted, add them there - today the only
//  control is the zero-size spacebar Button inside `playIndicator`. Note the
//  buttons here were all gated on `playbackEngine.hasContent`, which would have
//  disabled them on an empty timeline; don't carry that condition over.
//
//  Nothing else was lost: AudioMeterView, GlassTransportButtonStyle,
//  GlassIconButtonStyle and TransportLayout.controlBoxHeight are all defined
//  elsewhere and still used.
//
//  The file remains because only the ProjectorQuickLook group is
//  filesystem-synchronized in the pbxproj; deleting it from disk alone would
//  break the build. Safe to remove properly from within Xcode.
//
