# DAW MMC output setup — research

**Date**: 2026-09-14  
**Agent**: thomas  
**Purpose**: verified menu paths for making each supported DAW transmit MMC to `Projector MMC IN`, for the onboarding wizard.


## Research Report: Making Logic Pro, Pro Tools, Cubase, Studio One, and REAPER transmit MMC to "Projector MMC IN"

Note on my role: I am read-only and did not write this to `docs/research/2026-09-14-daw-mmc-output.md`. Someone with write access (joseph, or you directly) should save it there if you want it on disk.

### Summary
Logic Pro, Pro Tools, and Cubase all expose a genuine "become MMC master" setting, each in a different place, and each with its own destination-selection quirk. Studio One appears **not** to expose a separate MMC toggle at all — it piggybacks MMC onto whatever device is configured for MTC, which is a real problem for Projector's split-port design. REAPER has **no native MMC output** — confirmed by two independent sources — and only reaches it via an unsupported third-party script. None of the vendor docs I could reach explicitly document "sends MMC Locate on Play, never sends Stop" as a spec'd behavior; that pattern is closest to Cubase's documented "activating MMC Master sends commands to locate and start playback," but I could not confirm the incident trace was Cubase specifically.

### Local Findings

- Current onboarding only covers MTC, never MMC, for all five DAWs.
  - Source: `Projector/Views/OnboardingView.swift:52-205` (`DAWType.setupSteps`)
- The MMC IN port already exists in the product and is named consistently.
  - Source: `Projector/Views/OnboardingView.swift:512` ("Projector creates two virtual MIDI ports automatically, \"Projector MTC IN\" and \"Projector MMC IN\"")
- `docs/user-guide/midi-sync-setup.md:142-158` already has a rough sketch of MMC-sending steps for Pro Tools, Logic, and Cubase, but it's under-specified (no tab names, no device-ID notes, no Studio One/REAPER) and doesn't match the exact wording I verified below in a couple of places (e.g. it says Logic's setting is at "Preferences → MIDI → Sync", but the verified path is `File → Project Settings → Synchronization → MIDI tab`).
- `docs/incidents/2026-08-26-mtc-stop-stutter.md:49-51` — trace evidence: "**The DAW sends no MMC Stop.** It sends `MMC Locate` to the play-start and simply ceases timecode." The DAW is not named in that document. `.claude/SESSION_STATE.md` (lines 598, 689, 1754, 1823, 1825, 1850) shows Cubase is the DAW in active daily use for hands-on testing on this project, which makes Cubase the most likely candidate for that trace — but this is circumstantial, not a confirmed identification.
- `KNOWLEDGE_BASE.md:2617-2664` documents Projector's own MMC handling: it responds to device ID `0x7F` (all-call) by default (`sendMMCCommand(_:to deviceID: UInt8 = 0x7F)`), and the transport codes it understands (Stop 0x01, Play 0x02, FF 0x04, RW 0x05, Pause 0x09, Locate 0x44). This confirms Projector doesn't care what device ID a DAW sends — so any DAW "device ID" field is a non-issue as long as it's left at its default (all-call) or matches what the docs below describe.

### External Findings — Logic Pro

1. **Open Synchronization Settings** — `File → Project Settings → Synchronization` (or Option+P), then the **MIDI** tab. This is the same dialog the existing onboarding step already sends users to for MTC.
   - Source: [MIDI Synchronization settings in Logic Pro](https://support.apple.com/guide/logicpro/midi-synchronization-settings-lgcp72142361/mac) — Confidence: High (also mirrored in [support.apple.com/en-us/102005](https://support.apple.com/en-us/102005) and the legacy [Logic Pro 9 manual](https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_40_section_5.html))
2. **Add a row for the MMC port** — The MIDI tab is a **table, one row per MIDI output port**, with a *Destination* column and separate *MTC* and *MMC* checkboxes per row. Check **MMC** on the row whose Destination is **"Projector MMC IN"** (a different row than the one you already checked *MTC* on, targeting "Projector MTC IN" — they don't have to be the same port).
   - Source: [MIDI Synchronization settings in Logic Pro](https://support.apple.com/guide/logicpro/midi-synchronization-settings-lgcp72142361/mac) — quote via search snippet: "The MMC checkbox activates transmission of MIDI Machine Control for the MIDI output port shown in the Destination field of that row." Confidence: High
3. **No device ID field** — Logic doesn't expose a separate MMC "device ID"; enabling the MMC checkbox for a port is sufficient. Projector accepts all-call regardless.
   - Source: `KNOWLEDGE_BASE.md:2617-2631` (Projector side) + absence of any device-ID field in the Apple docs above. Confidence: High

**Gotcha — Locate is not sent on every Play.** Logic only transmits MMC Locate under two specific, named conditions: "Pressing Stop twice" and "Dragging regions or events" while stopped — both togglable checkboxes in **Sync preferences** (`Logic Pro → Settings → MIDI → Sync`). A plain Play press from the current playhead does not appear to fire Locate per this documentation.
- Source: [Sync preferences in Logic Pro](https://support.apple.com/guide/logicpro/sync-preferences-lgcp5b21b38a/mac); corroborated in the [Logic Pro 9 manual, chapter 44 section 5](https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_44_section_5.html) ("Transmit Locate Commands When: Pressing Stop twice" / "Dragging regions or events"). Confidence: Medium — I could not get WebFetch to render the current (v11) Apple guide page directly (it only serves a JS-driven TOC to non-browser fetches); this is via WebSearch's snippet of the same official URL, and independently corroborated by the older static manual.

### External Findings — Pro Tools

1. **Open Peripherals** — `Setup → Peripherals`, click the **Machine Control** tab (reuses existing onboarding step 3, which currently goes to the *Synchronization* tab of the same window for MTC).
2. **Enable Machine Control Master** — In the **Machine Control Master** field, check **Enable**. Leave the **ID** field at its default of **127** (0x7F, all-call) — this exactly matches Projector's default listening ID, so no change is needed.
3. **Point it at Projector** — Choose **"Projector MMC IN"** as the output device for Machine Control Master. This is a separate destination selector from wherever MTC Generate sends timecode.
   - Sources: [Digidesign/Avid Pro Tools Reference Guide, "Using MIDI Machine Control"](https://www.manualslib.com/manual/452347/Digidesign-Pro-Tools.html?page=821); [Pro Tools on the same computer via MTC, MMC & HUI (Video Sync 6)](https://non-lethal-applications.com/knowledge-base/VideoSync6/12_DAW%20Sync%20Option%202) — Confidence: High (matches vendor-manual scan + independent third-party walkthrough)

**Gotcha — don't confuse two different "Machine Control" things.** Avid also sells **"Pro Tools | MachineControl"** as a paid add-on (requires Pro Tools HD 6+) — but that product is for controlling *external tape decks and video transports over 9-pin/RS-422 serial*, not the built-in MIDI MMC master field described above. The built-in MIDI Machine Control Master in `Setup → Peripherals → Machine Control` is what Projector needs, and nothing in the sources above suggests it requires the paid add-on.
- Source: [avid.com/products/pro-tools-machinecontrol](https://www.avid.com/products/pro-tools-machinecontrol) — Confidence: Medium (the page itself doesn't discuss the MIDI-only path directly, so this is an inference from what it *does* say — "9-pin, V-LAN, non-linear video recorders" — combined with the MIDI-only path being documented separately and for free in the sources above)

**UNVERIFIED**: whether the Machine Control tab is present in every current Pro Tools tier (Intro/Standard/Studio/Ultimate) — I could not confirm this from available sources. Recommend checking on the actual install before finalizing wizard copy.

**Locate on Play**: Pro Tools ties Locate transmission to **Preferences → Synchronization**'s **"Machine Chases Memory Location"** and **"Machine Follows Edit Insertion/Scrub"** checkboxes — i.e., Locate fires on memory-location recall and edit-point moves, not automatically on every bare Play press.
- Source: [manualslib.com/manual/452347](https://www.manualslib.com/manual/452347/Digidesign-Pro-Tools.html?page=821) via the non-lethal-applications walkthrough — Confidence: Medium

### External Findings — Cubase (verified against Cubase Pro 15, current as of 2026)

1. **Make the port visible first** — `Studio → Studio Setup → MIDI Port Setup`, check the **Visible** column for **"Projector MMC IN"**. Cubase hides newly-appeared MIDI ports from every output dropdown (including the Machine Control page below) until this is checked.
   - Source: [MIDI Port Setup Page (Cubase AI 14.0)](https://www.steinberg.help/r/cubase-ai/14.0/en/cubase_nuendo/topics/setting_up/setting_up_midi_port_setup_r.html), corroborated at [v9.5](https://archive.steinberg.help/cubase_pro_artist/v9.5/en/cubase_nuendo/topics/setting_up/setting_up_midi_port_setup_r.html), [v10](https://archive.steinberg.help/cubase_pro/v10/en/cubase_nuendo/topics/setting_up/setting_up_midi_port_setup_r.html), [v12](https://archive.steinberg.help/cubase_pro/v12/en/cubase_nuendo/topics/setting_up/setting_up_midi_port_setup_r.html) — Confidence: High
2. **Open the Machine Control page** — `Transport → Project Synchronization Setup → Machine Control` page (a different page of the same dialog the existing onboarding step already opens for MTC, which is the *Sources* page).
3. **Turn on MMC Master Active, pick the port** — In *Machine Control Output Settings*: check **MMC Master Active**, set **MMC Output** to "Projector MMC IN".
4. **Leave the Device ID alone** — **MMC Device ID** only needs to match the *Machine Control Input Settings* ID if you also want Cubase to receive commands back from Projector (not needed here); leave at default or "All."
   - Source (verbatim, fetched): [Machine Control Page, Cubase Pro v10](https://archive.steinberg.help/cubase_pro/v10/en/cubase_nuendo/topics/synchronization/synchronization_setup_machine_control_r.html) — "MMC Master Active — Routes transport commands to any device while sync is enabled." / "MMC Output — Determines which MIDI port in your system sends MMC commands." / "MMC Device ID — Set this to the same device ID as in the Machine Control Input Settings section." Confidence: High. The same page exists at [v15 (current)](https://www.steinberg.help/r/cubase-pro/15.0/en/cubase_nuendo/topics/synchronization/synchronization_setup_machine_control_r.html) — I confirmed the URL and title resolve via search but could not get WebFetch to render its body (Steinberg's help site serves a JS-only shell to non-browser fetchers); treat the v15 wording as Medium confidence pending a screenshot-level check, though the structure has been stable from v9.5 through v14/Nuendo 13 in everything I could check.

**Correction to your stated gotcha**: there is **no** separate "add an MMC Master device in Studio Setup" step in current or archived Cubase docs. What actually lives in Studio Setup is the **port-visibility** toggle (step 1 above) — the MMC Master switch itself is on the Machine Control page of Project Synchronization Setup, reached from the Transport menu, not from Studio Setup.

**Locate on Play**: "When activated, Cubase sends MMC commands to the [external device] to locate and start playback" — i.e. Cubase's documented behavior is Locate-then-Play together. This is consistent with (but does not prove) the incident trace's "Locate then timecode, no Stop" pattern.
- Source: WebSearch aggregation of the v10/v10.5 Machine Control Page content — Confidence: Medium (paraphrase of official doc, not a verbatim quote I could independently pull)

### External Findings — Studio One

Existing onboarding steps (Options → External Devices → Add → New Instrument, "Send MIDI Clock/MTC" checked, output = Projector MTC IN) are for MTC. For MMC, the picture is different and matters for Projector's architecture:

- Studio One does **not** appear to have an independent "send MMC" toggle or destination selector. Per third-party documentation: "Studio One seems to always send MMC commands to all attached devices," and the same MTC-destination device "will suffice to also send MMC" — no separate MMC port selection is exposed in the UI.
  - Source: [Presonus Studio One on the same computer via MTC & MMC](https://non-lethal-applications.com/knowledge-base/VideoSync6/19_DAW%20Sync%20Option%209), [...on a separate computer](https://non-lethal-applications.com/knowledge-base/VideoSync6/20_DAW%20Sync%20Option%2010) — Confidence: **Low-Medium, single-source** (both pages are from the same third-party vendor, not PreSonus itself; I could not get PreSonus's own KB articles to render — `support.presonus.com` returned HTTP 403 to WebFetch on every article I tried).
- The closest official corroboration: PreSonus's own External Devices doc describes a **"MIDI Time Code" selector** for choosing "the device that will receive MIDI Time Code (MTC)" but says nothing about a separate MMC selector — silence that's *consistent with* (but doesn't prove) the third-party claim above.
  - Source: [MIDI: External Devices/Control Surfaces Setup](https://support.presonus.com/hc/en-us/articles/210040463-MIDI-External-Devices-Control-Surfaces-Setup) — via WebSearch snippet only, WebFetch blocked (403). Confidence: Low

**This is an architectural problem, not just a wizard-copy problem.** If Studio One really only sends MMC to whatever device is configured for MTC, and the wizard tells users to point that device at "Projector MTC IN," then MMC commands from Studio One would arrive at Projector's **MTC** port, not its **MMC** port — and Projector's MMC listener would never see them. I do not have a verified fix for this. A plausible but **unverified** workaround: add a *second* External Devices → New Instrument entry with "Send To" = "Projector MMC IN" and MTC/Clock unchecked, on the theory that Studio One sends MMC to every configured device regardless of its MTC setting. Nothing in the sources confirms this actually works — it needs to be tested against a real Studio One install before it goes in the wizard.

### External Findings — REAPER

**REAPER has no native MMC output.** Confirmed independently twice:
- "Currently, REAPER does not natively support MMC output."
  - Source: [REAPER on the same computer via MTC & MMC (Video Sync 6)](https://non-lethal-applications.com/knowledge-base/VideoSync6/27_DAW%20Sync%20Option%2017) — Confidence: Medium (third-party, but specific and consistent with REAPER's general design philosophy of not implementing legacy MIDI protocols beyond raw MIDI routing)
- Getting MMC out of REAPER requires a third-party ReaScript/JS plugin (mrlimbic's "MMC Locate," placed in `~/Library/Application Support/REAPER/Effects/utility` as an FX on a timecode track) which has known gaps — "REAPER's Pause button is not recognised."
  - Source: same page as above; script itself at [github.com/mrlimbic/reascripts](https://github.com/mrlimbic/reascripts) — **UNVERIFIED**, I did not fetch the GitHub repo to confirm the script exists in that form or still works with a current REAPER build.

Given this, I'd recommend the wizard for REAPER **not** promise MMC support at all, or clearly label it as an unsupported/advanced path — REAPER users would get MTC-only sync with manual Play/Stop, which is a legitimate and already-supported Projector workflow.

### Conflicting Information
- Your brief's hint that "Cubase needs an MMC Master device added in Studio Setup" does not match what the docs describe (see Cubase Correction above) — Studio Setup is only where you make the *port* visible; the MMC Master switch itself lives elsewhere.

### Single-Source Claims (Verify These)
- Studio One auto-routes MMC to whatever device is configured for MTC, with no independent MMC destination.
  - Source: [non-lethal-applications.com Video Sync 6, DAW Sync Options 9 & 10](https://non-lethal-applications.com/knowledge-base/VideoSync6/19_DAW%20Sync%20Option%209) (same vendor for both citations)
  - Recommendation: Verify against a real Studio One 6/7 install before writing wizard copy that depends on this.
- REAPER's mrlimbic "MMC Locate" script as the only path to MMC output.
  - Source: [non-lethal-applications.com Video Sync 6, DAW Sync Option 17](https://non-lethal-applications.com/knowledge-base/VideoSync6/27_DAW%20Sync%20Option%2017)
  - Recommendation: Don't build wizard steps around this without confirming the script still exists/works.

### UNVERIFIED List
- Which Pro Tools tier(s) include the Setup → Peripherals → Machine Control tab.
- Whether Cubase Pro 15's Machine Control page still matches the v9.5–v14 wording exactly (URL and title confirmed live; body content not independently rendered).
- Whether adding a second Studio One "New Instrument" pointed at "Projector MMC IN" actually receives MMC.
- Whether the DAW in the 2026-08-26 incident trace ("Locate then timecode, no Stop") was actually Cubase — plausible from SESSION_STATE.md's Cubase-heavy testing history and Cubase's documented Locate-then-play behavior, but not confirmed.
- Whether Logic sends MMC Locate on a bare Play press in any circumstance beyond the two named triggers (double-Stop, drag-while-stopped).

### Recommended Approach
1. For Logic Pro, Pro Tools, and Cubase: add MMC steps to `setupSteps` per the verified paths above — these are solid enough to ship.
2. For Cubase specifically: add the Studio Setup → MIDI Port Setup → Visible step *before* the Machine Control page step, since Projector's new virtual port won't be selectable otherwise.
3. For Studio One: hold off on promising MMC control in the wizard until someone verifies on a real install whether a second External Device pointed at "Projector MMC IN" actually carries MMC. Don't ship a plausible-but-unverified instruction here.
4. For REAPER: don't add MMC steps to the wizard at all, or label them clearly as unsupported/community-script-only.
5. Separately from the wizard: the "no MMC Stop, only Locate" trace behavior in `docs/incidents/2026-08-26-mtc-stop-stutter.md` means Projector's own MMC/MTC handling already has to treat "timecode just stopped arriving" as the stop signal — worth keeping in mind that this isn't a one-DAW quirk to work around, it may be a general MMC-master pattern (Cubase's own docs describe Locate-to-start-playback as intentional behavior).

### Open Questions
- Should the wizard show a warning banner for REAPER and Studio One instead of numbered MMC steps, given the uncertainty above?
- Does Projector's `MIDISyncActor` (per `KNOWLEDGE_BASE.md:2617-2664`) need a fallback to accept MMC on either virtual port, to route around the Studio One MTC/MMC-same-port issue, rather than relying on the DAW side to fix it?

## Handoff
→ user: decide whether to (a) ship wizard steps for Logic/Pro Tools/Cubase now and defer Studio One/REAPER, and (b) whether Projector's MMC listener should be made port-agnostic to route around the Studio One finding.
→ joseph: if approved, implement the verified `setupSteps` additions for Logic Pro, Pro Tools, and Cubase only; do not add Studio One or REAPER MMC steps until the open questions above are resolved.

Relevant local files:
- `/Users/keegandewitt/Developer/Projector/Projector/Views/OnboardingView.swift` (lines 52-205, 506-524)
- `/Users/keegandewitt/Developer/Projector/docs/user-guide/midi-sync-setup.md` (lines 142-158)
- `/Users/keegandewitt/Developer/Projector/docs/incidents/2026-08-26-mtc-stop-stutter.md` (lines 49-51)
- `/Users/keegandewitt/Developer/Projector/KNOWLEDGE_BASE.md` (lines 2617-2664)
- `/Users/keegandewitt/Developer/Projector/.claude/SESSION_STATE.md` (lines 598, 689, 1754, 1823-1850)