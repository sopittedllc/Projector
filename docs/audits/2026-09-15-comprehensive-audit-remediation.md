# Comprehensive Audit and Remediation — 2026-09-15

## Purpose

This is the durable handoff for the repository-wide audit requested on
2026-09-15. It records what was found, what was changed, how the changes were
verified, and the engineering lessons that should prevent the same classes of
failure from returning.

The changes described here are currently **uncommitted**. At the time of this
writing, the worktree contains 42 modified implementation, test, project, and
audit-script files, plus this report and two handoff updates. Preserve and review
that work before starting unrelated cleanup.

## Executive Summary

The audit found several real correctness and maintainability problems rather
than one single defect:

1. Security-scoped file access was acquired without a reliable owner or a
   balanced release path.
2. Several AVFoundation callbacks captured mutable local variables in ways that
   fail Swift's strict concurrency checks and make completion races possible.
3. Presentation-layer views performed media inspection directly, violating the
   project's layer boundary.
4. One unit test inherited the user's real `UserDefaults`, so its result
   depended on the machine running it.
5. The DocC audit could report impossible coverage above 100%.
6. The UI audit produced false positives and encouraged inconsistent one-off
   styling instead of semantic design tokens.
7. The initial UI-test invocation disabled signing, which caused macOS to report
   `ProjectorUITests-Runner` as damaged. The runner itself was not corrupt.

The initial sweep remediated the source-level issues it identified; peer review
then found and fixed one additional security-scope owner in
`ProjectMediaLibrary`. Debug compilation, unsigned
Release compilation, the complete unit suite, the signed UI suite, the DocC
audit, the UI audit, and whitespace validation passed. Manual product-level UI
verification remains intentionally outstanding.

## Verification Snapshot

| Check | Result | Important qualification |
|---|---|---|
| Debug build | Passed with no source warnings or errors | macOS destination |
| Release compile | Passed with `CODE_SIGNING_ALLOWED=NO` | Confirms source compilation, not distribution signing |
| Signed Release build | Blocked by the local signing environment | No matching Mac Development certificate/private key for team `G398H44H6X` |
| Complete `ProjectorTests` suite | Passed | One Xcode linker warning concerns XCTest's SDK/deployment-version mismatch, not project source |
| Signed `ProjectorUITests` suite | Passed | `testWaveformRendersAndSurvivesZoom`, 12.649 seconds |
| DocC audit | 100% for the 166 explicitly public declarations in its configured scope | Internal declarations are outside this metric |
| UI audit | Zero counted violations | Five files remain heuristic `REVIEW` items, described below |
| `git diff --check` | Passed | No whitespace errors |

## Detailed Findings and Fixes

### 1. Security-scoped resource lifetimes

#### Problem

Calling `startAccessingSecurityScopedResource()` is an acquisition, not a
one-time permission check. Every successful acquisition must remain alive for
the entire operation that needs the URL and must eventually be matched by
`stopAccessingSecurityScopedResource()`.

The project had two unsafe patterns:

- `ProjectDocument` could retain replacement project state without clearly
  releasing scopes from the previous state.
- QuickTime demo construction started access for helper media without an owner
  whose lifetime matched the returned composition. A short function-level
  `defer` would also have been wrong because AVFoundation can read lazily after
  the builder returns.

#### Remediation

- `ProjectDocument` now owns `activeSecurityScopedURLs`.
- It records only URLs for which scope acquisition actually succeeded.
- It releases all owned scopes before creating a new project, before replacing
  state during decode/load, and during deinitialization.
- Duplicate URLs are intentionally retained as duplicate acquisitions so every
  successful start receives a matching stop.
- Project JSON writes now use atomic replacement.
- `QuickTimeDemoSecurityScope` is a lifetime owner for a successful acquisition.
- `QuickTimeDemo` retains those owners for as long as its composition is alive.
- Replacing the audio mix creates a new demo value that preserves the retained
  scope owners.
- `ProjectMediaLibrary` owns one successful scope acquisition per media-item ID
  and releases it when the item is removed, the library is reloaded, or the
  library is destroyed. Peer review found this after the initial sweep.

#### Rule going forward

Treat security-scoped access like a file handle or lock:

1. Identify the object that truly owns the work.
2. Acquire the scope only when that owner can retain it.
3. Record only successful acquisitions.
4. Balance each acquisition exactly once.
5. Do not use a short `defer` when a framework may read the resource lazily.

### 2. Swift concurrency and callback state

#### Problem

The project was not consistently compiled with strict concurrency checking.
Once enabled, multiple callback pipelines exposed mutable local captures,
non-Sendable AVFoundation objects crossing closures, and potentially repeated
continuation/completion delivery.

Adding a lock around a captured local `var` is not a complete solution. The
compiler still sees independently captured mutable state, and future edits can
accidentally bypass the lock.

#### Remediation

`SWIFT_STRICT_CONCURRENCY = targeted` was added to all eight applicable build
configurations. Callback state was moved into small owner types:

- `ThumbnailCompletionCounter` coordinates thumbnail completion.
- `URLContinuationBox` provides locked, one-shot continuation resumption.
- `TranscodeCallbackState` coordinates video, audio, timecode, progress, and
  once-only completion for optimization.
- `AudioExtractionPipeline` confines reader/writer/input state to its dedicated
  queue.
- `AudioClipPlayback` is explicitly main-actor isolated; its mutable routing and
  scheduling fields are not declared generally Sendable.
- `SeekCompletionBox` transfers AVFoundation seek completion to the main actor.
- `UpdateInstallHandlerBox` transfers Sparkle's callback to the main actor.
- AVFoundation imports use `@preconcurrency` only at legacy framework
  boundaries where required.
- Immutable waveform constants were marked `nonisolated` where appropriate.

The two immutable callback boxes above are transfer adapters, not locks. Their
unchecked conformance is narrow: neither stored closure is read or invoked on
the framework callback executor; each is transferred immediately and accessed
only after entering `MainActor`. Their source comments record that invariant.

#### Rule going forward

For delegate and callback APIs, prefer an owned synchronization boundary:

- Put related mutable state in one reference type.
- Protect all access through that type or confine it to one executor/queue.
- Make terminal completion idempotent.
- Resume checked continuations exactly once.
- Keep `@unchecked Sendable` narrow and document the confinement invariant that
  makes it sound.
- Do not use `@preconcurrency` to hide application-owned races; reserve it for
  framework annotations that lag the concurrency model.

### 3. Presentation/logic layer boundary

#### Problem

Timeline views imported AVFoundation and performed asset inspection directly.
That coupled UI rendering to media I/O and violated the architecture documented
in `CLAUDE.md`.

#### Remediation

`MediaInspection` was added to the logic layer in `VideoCodecSupport.swift`. It
returns neutral, Sendable values for:

- asset duration;
- video properties;
- nominal video frame rate;
- audio-track descriptions; and
- video display size.

`ContentView+Timeline`, `VideoTrackView`, `AudioLaneView`, and
`MultiTrackTimelineView` now consume that boundary instead of importing
AVFoundation. The unused import in `ContentView` was removed.

The remaining view-layer AVFoundation uses are deliberate exceptions:

- `QuickTimeDemoSheet` bridges AVPlayer/AVPlayerView for presentation.
- `ContentView+Setup` contains DEBUG-only UI-test media generation.

#### Rule going forward

Views should ask for application concepts, not inspect framework objects. When a
view needs media metadata, add a logic-layer operation that returns small,
Sendable domain data. Keep the AVPlayer display bridge as the narrow exception,
not a precedent for arbitrary media work in views.

### 4. Unit-test isolation

#### Problem

`AudioOutputManagerTests` ran in an app-hosted environment and inherited the
actual user's selected output device and mappings. The test expecting the system
default failed when the machine had a saved Lynx output UID.

#### Remediation

The test fixture now:

1. Saves the real selected-output and mapping preferences.
2. Clears the selected output before constructing the manager under test.
3. Restores the original values during teardown.

#### Rule going forward

Any test touching `UserDefaults`, global audio state, notifications, singleton
caches, or filesystem locations must establish and restore its own environment.
A test passing on a clean CI machine is not enough; it must also pass on a
developer machine with real persisted settings.

### 5. DocC audit correctness

#### Problem

The old script counted lines beginning with `///` and divided by the number of
public declarations. A single multi-line DocC comment counted several times, so
coverage could exceed 100%—sometimes by thousands of percent. That metric could
not be trusted.

#### Remediation

`scripts/docc-audit.sh` now associates a preceding DocC block with the public
declaration it documents, allowing attributes and blank lines between the two.
It reports documented declarations over total public declarations, matching the
project standard. Missing public documentation was filled in across the export,
diagnostic, MIDI sync, panning, and protocol surfaces.

This is **not** documentation coverage for the whole internal implementation.
At verification time it covered 166 explicitly public declarations. Internal
types such as `MediaInspection` and roughly 900 internal Manager declarations
are outside the configured scope and must not be described as 100% documented
by this result.

#### Rule going forward

Static audits must count the unit named by the policy. If the policy says
"public declarations," count declarations—not comment lines. Sanity-check every
percentage-producing script with these invariants:

- the numerator can never exceed the denominator;
- an empty file has a defined result;
- attributes and multiline declarations do not change the classification; and
- the script's scope matches the written standard.

### 6. UI audit and design tokens

#### Problem

The UI audit flagged valid zero-spacing stacks and 1–4 point separators as
magic-number violations. Its file-level accessibility heuristic also treated
any button in a file as an error if the same file lacked an accessibility label,
even when the button had a visible text label. These false positives reduce
trust in the audit.

The audit also found legitimate hardcoded typography, spacing, colors, and
control heights spread across views.

#### Remediation

- Zero stack spacing and thin separators are no longer counted as violations.
- The accessibility heuristic now emits `REVIEW` rather than a proven failure.
- Hardcoded values were replaced with semantic `Typography`, `Spacing`,
  `AppColors`, `PanelLayout`, and `TransportLayout` tokens.
- New typography tokens cover accessibility proxy text, empty-state display,
  medium display, monospaced variants, action text, larger body text, and micro
  icons.
- Named layout tokens cover action-footer and frame-rate-pill heights.
- Peer review found that several approximate token substitutions changed actual
  rendering. Exact semantic tokens now preserve the original reel weight and
  reel-count typography, FPS
  size, pure-green drop affordance, blue onboarding tint, and 3/5-point compact
  control insets. Textual reel-count/filter/status labels no longer use
  icon-named tokens.

The five remaining accessibility review files are:

- `ProVideoFormatsInstallSheet`
- `CleanupOriginalFilesDialog`
- `DAWRoutingSetupSheet`
- `SaveProjectSheet`
- `OnboardingView`

These are prompts for human inspection, not confirmed violations.

#### Rule going forward

An audit should distinguish mechanically provable failures from heuristics.
Fail the build only for the former; label the latter as review work. When a
visual value has semantic meaning or repeats, give it a named token. Do not add
a token merely to disguise an unexplained number—its name should communicate
why the value exists.

### 7. Why macOS said the UI-test runner was damaged

#### Problem

The first broad test command used `CODE_SIGNING_ALLOWED=NO`, including for the
macOS UI-test target. macOS launches UI tests as a separate runner application.
Disabling signing made that bundle unacceptable to the platform, which surfaced
as:

> “ProjectorUITests-Runner” is damaged and can’t be opened.

This was a test-invocation error, not evidence of damaged project files or a
corrupt runner in the repository.

#### Remediation

The UI suite was rerun with normal signing and passed. Disabling signing remains
useful for checking Release compilation on a machine without the distribution
identity, but it must not be applied indiscriminately to UI tests.

#### Rule going forward

- Use normal code signing for macOS UI tests.
- Use `CODE_SIGNING_ALLOWED=NO` only for compile validation when signing is not
  itself under test.
- Keep compilation, unit tests, UI tests, and release/distribution signing as
  separate checks with separate conclusions.
- A signed Release failure caused by a missing local certificate is an
  environment failure, not automatically a source failure.

## Files and Change Groups

The work spans these groups:

- Build configuration: `Projector.xcodeproj/project.pbxproj`
- Security scopes and persistence: `ProjectDocument.swift`,
  `ProjectMediaLibrary.swift`, `QuickTimeDemoBuilder.swift`,
  `QuickTimeDemoSheet.swift`
- Concurrency bridges: `AudioTrackExtractor.swift`,
  `MediaImportCoordinator.swift`, `MediaOptimizationService.swift`,
  `PlaybackEngine.swift`, `SparkleUpdateService.swift`, `ThumbnailCache.swift`,
  `WaveformCache.swift`
- Architecture: `VideoCodecSupport.swift` and timeline/content views
- Documentation: manager and contract DocC comments
- Design system cleanup: `LayoutConstants.swift` and affected views
- Test isolation: `AudioOutputManagerTests.swift`
- Audit tooling: `scripts/docc-audit.sh`, `scripts/ui-audit.sh`

Use `git diff --stat` and `git diff -- <group>` during review. Do not flatten
these changes into an unexplained bulk cleanup; the groupings above express the
reason each change exists.

## Remaining Work Before Commit or Ship

1. Review the uncommitted diff by the change groups above.
2. Run the app and manually verify the workflows that static analysis cannot:
   import, optimize, place, playback, timeline drag/drop, QuickTime demo
   preview/export, audio routing, and the visually changed screens.
3. Inspect the five accessibility `REVIEW` files at runtime or with the
   Accessibility Inspector; do not assume either pass or failure from the
   heuristic.
4. If distribution signing matters for this change, rerun the signed Release
   build on a machine/keychain containing the correct certificate and private
   key.
5. Commit only after the required user runtime approval described in
   `CLAUDE.md`.

## Suggested Regression Checklist

For future broad refactors, run checks in this order so each result has a clear
meaning:

1. `git diff --check`
2. `./scripts/docc-audit.sh`
3. `./scripts/ui-audit.sh`
4. Debug build with normal signing
5. Complete unit suite
6. UI suite with normal signing
7. Release compile without signing, if credentials are unavailable
8. Signed Release build when release credentials are available
9. Manual runtime workflow and visual verification

Record environmental warnings separately from code failures. Never weaken a
test command globally just to get past one environmental constraint; scope the
workaround to the check for which it is valid.

## Closing Lesson

The common thread was lifetime and boundary clarity: who owns a permission, who
owns callback state, which layer owns media inspection, which environment owns
test preferences, and what an audit actually measures. Most of these bugs become
hard to create when ownership and boundaries are explicit in types rather than
implicit in local variables, comments, or developer convention.
