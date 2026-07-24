# Standalone Player Window — Implementation Plan

**Date**: 2026-07-24
**For**: Implementation session (Opus). Follow CLAUDE.md workflow: implement → build → USER runtime-verifies → commit. Do not commit before the user has run the checklist at the bottom.
**Branch**: continue on `codex/repair-sync-core` (4 verified commits already landed 2026-07-24).

## Goal

The video player becomes a **permanent, separate window** — never embedded in the
main window. The main window keeps Settings / Timeline / Media only. The pop-out
("Float") and pop-back ("Return") machinery is removed. The player window gains a
**"Lock to Foreground" pin**: when on, it floats above every other app.

## Decisions (already made with the user — do not re-litigate)

1. **Closing the player window hides it; playback continues.** Reopen via a
   button in the main window AND menu-bar items. (User-chosen.)
2. **Pin scope: above everything, including fullscreen apps on any Space**
   (`.floating` level + `.canJoinAllSpaces` + `.fullScreenAuxiliary`). Default
   default-off, persisted. (Recommended default the user did not override —
   flag in your summary so they can flip it.)
3. **Video drops import from both the timeline video track and the player
   window.** (Recommended default the user did not override — flag likewise.)

## Verified starting facts (2026-07-24)

- `ProjectorApp.swift:17` — single `WindowGroup`; **menus are built in AppKit
  by the AppDelegate** (`setupMenus`, called delayed — see startup log lines
  `>>> AppDelegate: delayed setupMenus call`). Menu items go THERE, not in
  SwiftUI `.commands` (which would target the wrong menu system).
- `FloatingVideoPanel.swift` (202 lines) — `FloatingVideoPanelController`
  singleton (`.shared`, line 29) already hosts the player in a panel. **This is
  the foundation: repurpose it in place.** Do NOT create a new file (pbxproj
  trap below).
- `ContentView.swift`: `isVideoFloating` @State (line ~131); embedded-vs-floating
  branch (~414); Float button (~458); `floatVideoWindow()` (~574) /
  return+`closePanel()` (~586); playback-area `.onDrop` (~423) routing internal
  drags to `handlePlaybackAreaDrop` and external to
  `mediaImportCoordinator.handleDrop(providers:)`.
- `VideoContentViewForEngine` renders the player w/ timecode overlay settings —
  reuse unchanged inside the window.
- `FullScreenVideoView.swift` (70 lines) — custom fullscreen. Likely
  replaceable by native fullscreen once the player is a titled window.
- `AppSettings` (Models/AppSettings.swift) is the existing persisted-settings
  pattern — put the pin preference there, not in ad-hoc @AppStorage.

## Codebase traps (each one cost us real time this week)

1. **Check call sites before trusting/removing ANY function.** This codebase
   ships dead code that looks live (`resizeToFitLanes`, `handleMultiFileDropNative`,
   `AudioLaneView.handleDrop(providers:)` were all dead). `grep -rn <symbol>`
   and count call sites before every edit, and again after removals (expect 0).
2. **New .swift files are NOT picked up** — only ProjectorQuickLook is
   filesystem-synchronized in the pbxproj. Repurpose existing files (rename the
   type, keep the filename) or add files through Xcode.
3. **`.help()` never fires on `glassEffect` surfaces (macOS 26).** Overlay
   buttons on the dark video controls (`AppColors.overlayDarker` style) are
   fine — the existing Float button's `.help` pattern works there. For any
   glass-styled button use `GlassActionButtonStyle(tint:help:)`.
4. **Runtime log capture**: launch the binary directly
   (`…/Projector.app/Contents/MacOS/Projector > log 2>&1`); `log stream`
   redacts NSLog as `<private>`.
5. **UI changes need user runtime verification before commit** (project rule).

## Phases

### Phase 0 — Inventory (read before editing)
Read `FloatingVideoPanel.swift` fully (panel class, style mask, how the SwiftUI
content is hosted, `showPanel`/`closePanel` signatures). Grep and list call
sites for: `FloatingVideoPanelController`, `isVideoFloating`,
`floatVideoWindow`, `FullScreenVideoView`, `enterFullScreen`,
`handlePlaybackAreaDrop`, `VideoContentViewForEngine`. Record counts in
`.claude/SESSION_STATE.md`.

### Phase 1 — Permanent PlayerWindowController (repurpose FloatingVideoPanel.swift in place)
- Rename `FloatingVideoPanelController` → `PlayerWindowController` (same file).
- Window: titled, closable, miniaturizable, resizable;
  `isReleasedWhenClosed = false`; `hidesOnDeactivate = false`;
  `frameAutosaveName = "PlayerWindow"` (frame + screen persist).
- **Hide-on-close**: `NSWindowDelegate.windowShouldClose` → `orderOut(nil)`,
  return `false`. Playback engine untouched — transport keeps running.
- `show()` = create-if-needed + `makeKeyAndOrderFront`. Called at app start
  once media/content exists (mirror wherever `floatVideoWindow()` got its
  parameters from) and by the reopen affordances below.
- If the current class is an `NSPanel` with non-activating style, convert to a
  regular `NSWindow` — the player must accept focus for native fullscreen.

### Phase 2 — Remove the embedded player + pop machinery
- `ContentView`: delete the embedded/floating branch (~414), the Float button
  (~458), `floatVideoWindow()`, the return path + `closePanel()` call,
  `isVideoFloating`. Timeline/Media reflow to fill the freed space; check
  `MainWindowLayout` values still make sense for a player-less main window.
- Inside the (former) panel view: delete the "Return" button.
- `FullScreenVideoView` + `enterFullScreen`: after Phase 1 the green traffic
  light gives native fullscreen. If no remaining call sites need the custom
  path, delete both (FEATURES.md removal checklist applies). If something
  still uses it, keep and re-point at the player window.
- Re-grep every removed symbol: zero call sites, then build.

### Phase 3 — Reopen affordances
- **Main window button**: "Show Player" in the timeline toolbar next to the
  settings gear (`MultiTrackTimelineView` toolbar, ~line 590) — plain style,
  `.help("Show the video player window")`, accessibility label. Always enabled;
  action = `PlayerWindowController.shared.show()` (idempotent bring-to-front).
- **Menu bar** (in AppDelegate `setupMenus`): under Window —
  "Show Video Player" (⇧⌘P) → `show()`; "Lock Player to Foreground"
  (checkmark item reflecting the pin state) → toggles pin. Use
  target/action to the controller; keep menu item state synced via
  `NSMenuItemValidation` or by setting `.state` when toggled.

### Phase 4 — Lock to Foreground (pin)
- `AppSettings`: add persisted `playerWindowPinnedToFront: Bool = false`.
- Pin ON: `window.level = .floating`;
  `window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])`.
  Pin OFF: `.normal` level, remove those behaviors.
- Apply persisted state when the window is created.
- Pin button in the player window's control overlay (where Float used to be):
  `pin.fill`/`pin.slash` SF Symbol, same dark-circle style as the existing
  overlay buttons, `.help("Keep this window above all apps")`, a11y label.
  Keep the menu checkmark in sync (single source of truth = AppSettings).

### Phase 5 — Drops on the player window
- Attach the same `.onDrop` contract as the old playback area (~ContentView:423)
  to the player window's content: internal drags → `dragContext` items routed
  like `handlePlaybackAreaDrop`; external → `mediaImportCoordinator.handleDrop`.
  The handlers live in ContentView — pass closures into
  `PlayerWindowController.show(...)` at setup exactly the way the old
  `showPanel(...)` received its dependencies. Do not duplicate the import logic.
- Timeline video-track drops unchanged.

### Phase 6 — Registry, docs, cleanup
- `FEATURES.md`: move "Floating video panel / Return" to Removed (use its entry
  as the removal checklist); add "Standalone Player Window" entry listing files,
  state added to AppSettings, menu integration points.
- Update `docs/UX_USER_READY_GAMEPLAN.md` status note if touched areas overlap.
- Full build; run `bash scripts/ui-audit.sh` (should not regress).

## Acceptance criteria

- App launch (with a project containing media): player appears in its own
  window at its last position; main window has no player region and no hole.
- Close the player mid-playback → audio continues; toolbar button and ⇧⌘P both
  bring it back exactly where it was.
- Pin on → window stays visible over another app's fullscreen window on the
  same monitor; pin off → normal stacking. State survives relaunch.
- Menu checkmark, pin button, and AppSettings always agree.
- Drop a video on the player window → imports exactly like the old playback
  area (batch sheet behavior included). Drop on timeline unchanged.
- `grep -rn "isVideoFloating\|floatVideoWindow\|FloatingVideoPanelController"` → 0 hits.
- Native fullscreen works on the player window.

## Runtime verification checklist (user runs before any commit)

- [ ] Launch → player in own window, main window reflowed cleanly
- [ ] Play, close player → audio continues; reopen via toolbar button; via ⇧⌘P
- [ ] Pin, switch to fullscreen Logic/another app → player stays on top
- [ ] Unpin → normal; quit + relaunch → pin state and window frame restored
- [ ] Drop 1 video + 3 audio stems onto the player window → same import flow
- [ ] Green traffic light → fullscreen in/out clean

## Resume instructions

If interrupted: `.claude/SESSION_STATE.md` holds phase + modified files. Phases
are ordered so the build compiles at every phase boundary; find the last
completed phase by grepping for the Phase-2 symbols (still present = Phase 1;
absent = Phase ≥ 2, check menu items for Phase 3, AppSettings key for Phase 4).
