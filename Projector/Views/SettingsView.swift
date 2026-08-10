import SwiftUI
import AppKit

/// Natural height of the settings content, reported up so the window can be
/// sized to it instead of scrolling.
private struct SettingsContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    /// The tallest report wins. There is only one reporter today, but a `max`
    /// keeps a future second one from shrinking the window to whichever
    /// happened to be measured last.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Settings window for audio and display configuration.
///
/// Provides accordion-style sections for:
/// - Audio: Output device selection and channel mapping
/// - Display: Timecode overlay configuration
///
/// Updating is reached from the application menu's Check for Updates, not from
/// here: a panel of controls for a mechanism that runs itself was three rows
/// explaining that there was nothing to do.
///
/// Sizes itself to its content rather than scrolling - see ``settingsHeight``.
struct SettingsView: View {
    @ObservedObject var audioManager: AudioOutputManager
    @ObservedObject var settings = AppSettings.shared

    @Binding var isPresented: Bool

    // Accordion section states - default to expanded
    @State private var audioExpanded = true
    @State private var displayExpanded = true

    @State private var pendingOutputRole: OutputRole?

    /// Whether the DAW routing setup sheet is on screen.
    @State private var showDAWRoutingSetup = false

    /// Whether the DAW routing explanation popover is on screen.
    @State private var showDAWRoutingHelp = false

    /// Whether the routing device is being torn down right now.
    @State private var isRemovingDAWRouting = false

    /// Whether the confirmation for removing the routing device is on screen.
    @State private var showRemoveDAWRoutingConfirmation = false

    /// How to name the selected device's channels, when it is Projector's aggregate.
    ///
    /// Held rather than computed on demand because deriving it reads the aggregate's
    /// sub-device list from CoreAudio, which a view body must not do on every pass.
    /// Refreshed from the two things that can invalidate it: which device is selected,
    /// and what the machine currently has.
    @State private var channelOrigin: AggregateChannelOrigin?
    @State private var selectedProfileId: UUID?
    @State private var isNamingProfile = false
    @State private var newProfileName = ""
    @State private var pendingProfile: AudioOutputProfile?
    @State private var showProfileDeviceWarning = false

    /// Natural height of the scrolling content, once it has been measured.
    ///
    /// Zero until the first layout, which is why ``settingsHeight`` falls back
    /// to the fixed height rather than collapsing the window to its chrome.
    @State private var contentHeight: CGFloat = 0

    /// Height the window should be: tall enough not to scroll, within the space
    /// the screen actually has.
    ///
    /// The panel used to be a fixed 650pt with Audio and Display both expanded
    /// by default, which overflowed it, and Display's own rows were cut off.
    /// Sizing to the content fixes that for whatever the
    /// sections happen to contain, rather than for their length on the day a
    /// number was picked.
    ///
    /// The `ScrollView` stays underneath: on a short screen the cap wins and
    /// scrolling is the only honest answer.
    private var settingsHeight: CGFloat {
        guard contentHeight > 0 else { return SettingsLayout.height }

        let screenCap = NSScreen.main.map {
            $0.visibleFrame.height * SettingsLayout.maxScreenFraction
        } ?? SettingsLayout.maxHeight

        let wanted = contentHeight + SettingsLayout.chromeHeight
        return min(max(SettingsLayout.height, wanted), screenCap)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: Spacing.sm) {
                Image(systemName: "gearshape")
                    .font(Typography.iconMedium)
                    .foregroundColor(.secondary)
                Text("Settings")
                    .font(Typography.title)
                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.sm)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    // MIDI Info Blurb
                    midiInfoSection

                    accordionSection(
                        title: "Audio",
                        icon: "speaker.wave.2",
                        isExpanded: $audioExpanded
                    ) {
                        audioSectionContent
                    }

                    accordionSection(
                        title: "Display",
                        icon: "tv",
                        isExpanded: $displayExpanded
                    ) {
                        displaySectionContent
                    }

                }
                .padding()
                // Measured at a fixed width with the height unconstrained, so
                // this reports what the content *wants* - a number the window's
                // own height cannot influence, which is what makes feeding it
                // back into the frame safe.
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SettingsContentHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                )
            }
            .onPreferenceChange(SettingsContentHeightKey.self) { height in
                contentHeight = height
            }

            Divider()

            // Footer
            HStack {
                Button("Reset to Defaults") {
                    settings.resetToDefaults()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: SettingsLayout.width, height: settingsHeight)
    }

    // MARK: - Accordion Helper

    @ViewBuilder
    private func accordionSection<Content: View>(
        title: String,
        icon: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            // Header - entire area is clickable
            Button(action: { isExpanded.wrappedValue.toggle() }) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(Typography.iconSmall)
                        .foregroundColor(.secondary)
                        .frame(width: Spacing.md)

                    Label(title, systemImage: icon)
                        .font(SettingsDesign.sectionTitle)
                        .foregroundColor(.primary)

                    Spacer()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) section, \(isExpanded.wrappedValue ? "expanded" : "collapsed")")
            .accessibilityHint("Double-tap to \(isExpanded.wrappedValue ? "collapse" : "expand")")

            // Content
            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: SettingsDesign.rowSpacing) {
                    content()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.md)
            }
        }
        .glassPanel()
    }

    // MARK: - MIDI Info Section

    private var midiInfoSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label("MIDI", systemImage: "pianokeys")
                .font(Typography.heading)

            Text("On launch, Projector creates a \"Projector MIDI IN\" port. Within your DAW, send MTC and MMC to that port and you're good to go!")
                .font(Typography.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    // MARK: - Audio Section

    private var audioSectionContent: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Profiles first: loading one replaces everything below, so it reads
            // as a header for the section rather than another row inside it.
            profileBox

            deviceRow

            dawRoutingRow

            if audioManager.selectedDeviceChannelCount == 0 {
                Text("No output channels detected for this device.")
                    .font(SettingsDesign.caption)
                    .foregroundColor(.secondary)
            } else {
                outputChoosers
                dawRoutingSummary
            }
        }
        .onAppear { refreshChannelOrigin() }
        .onChangeCompat(of: audioManager.selectedDeviceUID) { _ in refreshChannelOrigin() }
        .onChangeCompat(of: audioManager.availableDevices.count) { _ in refreshChannelOrigin() }
        .sheet(item: $pendingOutputRole) { role in
            ChooseOutputSheet(
                role: role,
                audioManager: audioManager,
                channelOrigin: channelOrigin,
                onCancel: { pendingOutputRole = nil },
                onChoose: { name, firstChannel, isStereo in
                    audioManager.addOrReplaceOutput(
                        name: name,
                        firstChannelNumber: firstChannel,
                        isStereo: isStereo,
                        roleId: role.fixedName == nil ? nil : role.id
                    )
                    pendingOutputRole = nil
                }
            )
        }
        .sheet(isPresented: $showDAWRoutingSetup) {
            DAWRoutingSetupSheet(
                audioManager: audioManager,
                onDismiss: { showDAWRoutingSetup = false }
            )
        }
        .alert("Remove \(AggregateDeviceManager.aggregateName)?",
               isPresented: $showRemoveDAWRoutingConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) { removeDAWRouting() }
        } message: {
            Text("Any DAW currently set to this device will lose its inputs. "
                 + "Projector will go back to your previous output.")
        }
        .alert("Profile built for another device", isPresented: $showProfileDeviceWarning) {
            Button("Apply Anyway") { applyPendingProfile() }
            Button("Cancel", role: .cancel) { pendingProfile = nil }
        } message: {
            Text(profileWarningMessage)
        }
    }

    private var deviceRow: some View {
        SettingsRow(label: "Device") {
            SettingsMenu(selection: selectedDeviceName) {
                Button("System Default") { audioManager.selectedDeviceUID = nil }
                ForEach(audioManager.availableDevices) { device in
                    Button(device.isSystemDefault ? "\(device.name) (Default)" : device.name) {
                        audioManager.selectedDeviceUID = device.uid
                    }
                }
            }
            .accessibilityLabel("Audio output device")

            // Tearing the routing down belongs to the device it built, so once that
            // device is the one selected there is nothing left for a separate DAW
            // Routing row to say - the menu above already names it.
            if isUsingDAWRouting {
                SettingsClearButton(label: "Remove the DAW routing device") {
                    // Confirmed, unlike every other clear button in this window. The
                    // others drop a mapping the user can re-pick in a second; this one
                    // destroys a system audio device, and any DAW currently set to it
                    // loses its inputs mid-session with no undo.
                    showRemoveDAWRoutingConfirmation = true
                }
                SettingsHelpButton(isPresented: $showDAWRoutingHelp) {
                    dawRoutingExplanation
                }
            }

            RefreshIconButton(helpText: "Refresh Devices") {
                audioManager.refreshDevices()
            }
        }
    }

    /// Whether Projector is currently playing through the device it built.
    private var isUsingDAWRouting: Bool {
        audioManager.selectedDeviceUID == AggregateDeviceManager.aggregateUID
    }

    // MARK: - Output Choosers

    /// The three named roles plus a free-form fourth.
    ///
    /// Stereo Out, DX/SFX and MX get dedicated rows because they are what a
    /// scoring session almost always needs; choosing one twice re-points it
    /// rather than adding a duplicate.
    ///
    /// Stereo Out leads because it is the one an unconfigured device already
    /// has, and the only one needed to simply hear playback.
    /// One row for DAW routing, directly under the device it extends.
    ///
    /// Deliberately a single row with a single action rather than another device
    /// picker: the aggregate *is* a device and already appears in `deviceRow`'s menu,
    /// so a second way to select it would be the third route to the same thing (rule
    /// in `.claude/rules/ui-composition-first.md`). What this row offers is the one
    /// thing that menu cannot - building the device in the first place, and taking it
    /// away again.
    @ViewBuilder
    private var dawRoutingRow: some View {
        // Only while there is an offer to make. Once the device exists and is selected,
        // the row's whole content was a value restating the Device row above it and a
        // clear button that now lives there - three lines saying one thing.
        if !isUsingDAWRouting {
            SettingsRow(label: "DAW Routing") {
                Button {
                    // Already built, just not in use: select it rather than reopening
                    // setup, which would tear the device down and rebuild it under a
                    // DAW that is very likely already listening to it.
                    if dawRoutingDeviceExists {
                        audioManager.selectedDeviceUID = AggregateDeviceManager.aggregateUID
                    } else {
                        showDAWRoutingSetup = true
                    }
                } label: {
                    Text(dawRoutingDeviceExists
                         ? "Switch To Them"
                         : "Set Up Virtual Stem Tracks")
                }
                .settingsChooserButton()

                SettingsHelpButton(isPresented: $showDAWRoutingHelp) {
                    dawRoutingExplanation
                }
            }
        }
    }

    /// What DAW routing is, for the reader who has never needed an aggregate device.
    ///
    /// Answers the question the row cannot: not how to switch it on, but why an extra
    /// device has to exist at all. Kept in a popover rather than under the row because
    /// it is read once and never again, and the Audio section is already the densest
    /// part of this window.
    private var dawRoutingExplanation: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Sending stems to a DAW")
                .font(SettingsDesign.sectionTitle)

            Text("Projector will create a custom Audio Device that stacks virtual "
                 + "inputs for your stem audio lanes on top of your interface's own "
                 + "channels. This will allow you to set up your Projector Audio "
                 + "lanes inside your DAW.")

            Text("Projector will put your virtual inputs first, then your interface.")
                .font(SettingsDesign.caption)
                .foregroundColor(.secondary)
        }
        .font(SettingsDesign.value)
        .fixedSize(horizontal: false, vertical: true)
        .padding(Spacing.md)
        .frame(width: SettingsDesign.popoverWidth, alignment: .leading)
    }

    /// Whether Projector's aggregate device is present on the system.
    ///
    /// False the moment removal starts, rather than when the device list catches up.
    /// Destroying the device and re-enumerating happen in a task, so for a frame or two
    /// afterwards the list still holds it - long enough for the row to offer to switch
    /// to a device the user has just deleted, then change its own mind.
    private var dawRoutingDeviceExists: Bool {
        guard !isRemovingDAWRouting else { return false }
        return audioManager.availableDevices.contains {
            $0.uid == AggregateDeviceManager.aggregateUID
        }
    }

    /// Two lines under the outputs saying which reach the room and which reach the DAW.
    ///
    /// Shown only while the aggregate is the selected device, because the
    /// speakers/DAW split is a property of *that* device. On an ordinary interface
    /// every output goes to the same place and the summary would state the obvious.
    @ViewBuilder
    private var dawRoutingSummary: some View {
        if let channelOrigin {
            SettingsSubRow {
                AggregateRoutingSummary(
                    map: channelOrigin.map,
                    outputs: audioManager.mappedOutputs
                )
            }
        }
    }

    /// Recomputes how the selected device's channels should be named.
    ///
    /// Called rather than computed so the CoreAudio read stays out of the view body.
    /// Only while the aggregate is the selected device: on an ordinary interface the
    /// channels are the user's own hardware, named once by the row above.
    private func refreshChannelOrigin() {
        guard audioManager.selectedDeviceUID == AggregateDeviceManager.aggregateUID else {
            channelOrigin = nil
            return
        }
        channelOrigin = AggregateChannelOrigin.current(in: audioManager.availableDevices)
    }

    /// Tears the aggregate down and steps off it.
    ///
    /// The selection is moved away first: leaving Projector pointed at a device that
    /// is about to stop existing would silence playback with no explanation.
    private func removeDAWRouting() {
        if audioManager.selectedDeviceUID == AggregateDeviceManager.aggregateUID {
            audioManager.selectedDeviceUID = nil
        }
        isRemovingDAWRouting = true

        // The channel names need no clearing: they live on the aggregate itself and are
        // destroyed with it. Nothing Projector wrote touches the user's own devices.
        Task {
            _ = try? await AggregateDeviceManager().removeAggregate()
            audioManager.refreshDevices()
            isRemovingDAWRouting = false
        }
    }

    private var outputChoosers: some View {
        VStack(alignment: .leading, spacing: SettingsDesign.rowSpacing) {
            ForEach(orderedRoles, id: \.id) { role in
                outputRow(role)
            }

            // Extras are the same row shape, labelled with their own name.
            ForEach(additionalOutputs) { output in
                SettingsRow(label: output.name) {
                    assignmentValue(output)
                }
            }

            SettingsSubRow {
                Button {
                    pendingOutputRole = .additional
                } label: {
                    Label("Add additional output", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .settingsButton()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One output: its label, then either its value or the control that sets it.
    ///
    /// Both states are the same row shape (rule 6), so setting an output changes
    /// what the row says rather than how the column looks.
    private func outputRow(_ role: OutputRole) -> some View {
        SettingsRow(label: role.fixedName ?? "Output") {
            if let output = assignedOutput(for: role) {
                assignmentValue(output)
            } else {
                Button {
                    pendingOutputRole = role
                } label: {
                    Text("Choose...")
                }
                .settingsChooserButton()
            }
        }
    }

    private func assignmentValue(_ output: MappedAudioOutput) -> some View {
        SettingsValue(
            // Dropped once the device name is in the value: the row is one fixed width,
            // and "Projector Virtual 1-2" plus "stereo" plus the clear button does not
            // fit in it. The range is the same fact anyway - a pair is stereo.
            value: outputChannelLabel(output),
            qualifier: channelOrigin == nil
                ? (output.channelCount == 2 ? "stereo" : "mono")
                : nil,
            clearLabel: "Clear \(output.name)",
            onClear: { audioManager.removeOutput(id: output.id) }
        )
    }

    private func assignedOutput(for role: OutputRole) -> MappedAudioOutput? {
        audioManager.mappedOutputs.first { role.matches($0) }
    }

    /// The named roles in the order their channels appear on the device.
    ///
    /// Sorted rather than fixed because the rows now show channel numbers, and a fixed
    /// order made that column read 17-18, 3-4, 1-2 on the aggregate - descending, for no
    /// reason a user could see. Sorting matches the port list below, which is in port
    /// order, so the two agree.
    ///
    /// Unassigned roles keep their canonical order at the end: they have no channel to
    /// sort by, and the alternative is a row that jumps the moment it is filled in.
    private var orderedRoles: [OutputRole] {
        let canonical: [OutputRole] = [.stereoOut, .music, .dialogueEffects]
        let assigned = canonical.compactMap { role -> (OutputRole, Int)? in
            guard let output = assignedOutput(for: role) else { return nil }
            return (role, output.channelStart)
        }
        let unassigned = canonical.filter { assignedOutput(for: $0) == nil }
        return assigned.sorted { $0.1 < $1.1 }.map(\.0) + unassigned
    }

    /// Outputs that fill no named role.
    private var additionalOutputs: [MappedAudioOutput] {
        audioManager.mappedOutputs.filter { output in
            !OutputRole.stereoOut.matches(output)
                && !OutputRole.dialogueEffects.matches(output)
                && !OutputRole.music.matches(output)
        }
    }

    // MARK: - Profiles

    /// Profiles, boxed at the top of the section (rule: section-wide controls
    /// are not rows).
    ///
    /// One line: pick a profile, or save the current outputs as one. The naming
    /// field and the origin note appear only when they apply, so the box stays a
    /// single row in the common case.
    private var profileBox: some View {
        SettingsBox(title: "Profile") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    profilePicker

                    Button("Save") { saveProfile(replacingSelected: true) }
                        .settingsInlineButton()
                        .disabled(selectedProfileId == nil || audioManager.mappedOutputs.isEmpty)
                        .help("Overwrite the selected profile with the outputs below")

                    Button("New...") { isNamingProfile = true }
                        .settingsInlineButton()
                        .disabled(audioManager.mappedOutputs.isEmpty)
                        .help("Save the outputs below as a new profile")

                    Button(role: .destructive) {
                        if let id = selectedProfileId {
                            settings.deleteAudioOutputProfile(id: id)
                            selectedProfileId = nil
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .settingsInlineButton()
                    .disabled(selectedProfileId == nil)
                    .help("Delete the selected profile")

                    Spacer(minLength: 0)
                }

                if isNamingProfile {
                    HStack(spacing: Spacing.sm) {
                        TextField("Profile name", text: $newProfileName)
                            .textFieldStyle(.roundedBorder)
                            .settingsControlWidth()
                            .onSubmit { saveProfile(replacingSelected: false) }

                        Button("Save") { saveProfile(replacingSelected: false) }
                            .settingsInlineButton()
                            .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)

                        Button("Cancel") {
                            isNamingProfile = false
                            newProfileName = ""
                        }
                        .settingsInlineButton()

                        Spacer(minLength: 0)
                    }
                }

                if let origin = selectedProfileOriginName {
                    Text("Saved from \(origin)")
                        .font(SettingsDesign.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var profilePicker: some View {
        SettingsMenu(selection: selectedProfileName) {
            Button("None") { selectedProfileId = nil }
            ForEach(settings.audioOutputProfiles) { profile in
                Button(profile.name) {
                    selectedProfileId = profile.id
                    requestApply(profile)
                }
            }
        }
        .accessibilityLabel("Audio output profile")
    }

    private var selectedProfileName: String {
        guard let id = selectedProfileId,
              let profile = settings.audioOutputProfiles.first(where: { $0.id == id })
        else { return "None" }
        return profile.name
    }

    private var selectedDeviceName: String {
        guard let uid = audioManager.selectedDeviceUID,
              let device = audioManager.availableDevices.first(where: { $0.uid == uid })
        else { return "System Default" }
        return device.name
    }

    private var selectedProfileOriginName: String? {
        guard let id = selectedProfileId,
              let profile = settings.audioOutputProfiles.first(where: { $0.id == id })
        else { return nil }
        return profile.createdForDeviceName
    }

    private var profileWarningMessage: String {
        guard let profile = pendingProfile else { return "" }
        let origin = profile.createdForDeviceName ?? "another audio device"
        var message = "This profile was created for \(origin). We recommend you check your outputs."
        if !audioManager.deviceSatisfies(profile) {
            message += "\n\nIt addresses up to channel \(profile.highestChannel), but this device has \(audioManager.selectedDeviceChannelCount)."
        }
        return message
    }

    /// Apply a profile, warning first if it came from a different device.
    ///
    /// The warning never blocks: moving a session between a studio interface and
    /// a laptop is what profiles are for. It exists because the channel numbers
    /// were chosen against a different layout, so they are worth a glance.
    private func requestApply(_ profile: AudioOutputProfile) {
        pendingProfile = profile
        if audioManager.profileWasBuiltElsewhere(profile) || !audioManager.deviceSatisfies(profile) {
            showProfileDeviceWarning = true
        } else {
            applyPendingProfile()
        }
    }

    private func applyPendingProfile() {
        guard let profile = pendingProfile else { return }
        audioManager.applyProfile(profile)
        pendingProfile = nil
    }

    private func saveProfile(replacingSelected: Bool) {
        if replacingSelected, let id = selectedProfileId,
           let existing = settings.audioOutputProfiles.first(where: { $0.id == id }) {
            settings.saveAudioOutputProfile(audioManager.makeProfile(named: existing.name, id: id))
            return
        }
        let name = newProfileName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let profile = audioManager.makeProfile(named: name)
        settings.saveAudioOutputProfile(profile)
        selectedProfileId = profile.id
        newProfileName = ""
        isNamingProfile = false
    }

    /// Channel numbers as the user picked them: 1-based.
    ///
    /// `channelStart` is a 0-based buffer offset, so printing it raw labelled
    /// the first stereo pair "Out 0-1" while the chooser that set it offered
    /// "1-2".
    /// Where an assigned output goes, as the row shows it.
    ///
    /// On the aggregate this names the device carrying the channels rather than saying
    /// "Out": the row's own label already says which stem it is, so the useful half of
    /// the answer is whether it reaches the room or the DAW - which "Out 33-34" does not
    /// say and "Projector Virtual 1-2" does.
    private func outputChannelLabel(_ output: MappedAudioOutput) -> String {
        let first = output.channelStart + 1

        if let channelOrigin {
            return channelOrigin.label(
                firstChannel: first,
                channelCount: output.channelCount
            )
        }

        if output.channelCount <= 1 {
            return "Out \(first)"
        }
        return "Out \(first)-\(first + output.channelCount - 1)"
    }

    // MARK: - Display Section

    private var displaySectionContent: some View {
        VStack(alignment: .leading, spacing: SettingsDesign.rowSpacing) {
            SettingsRow(label: "Timecode") {
                Toggle("Show overlay", isOn: $settings.showTimecodeOverlay)
                    .font(SettingsDesign.value)
                    .toggleStyle(.checkbox)
            }

            if settings.showTimecodeOverlay {
                SettingsRow(label: "Position") {
                    SettingsMenu(selection: settings.timecodeOverlayPosition.rawValue) {
                        ForEach(TimecodeOverlayPosition.allCases) { position in
                            Button(position.rawValue) {
                                settings.timecodeOverlayPosition = position
                            }
                        }
                    }
                    .accessibilityLabel("Timecode overlay position")
                }

                SettingsRow(label: "Opacity") {
                    HStack(spacing: Spacing.sm) {
                        Slider(value: $settings.timecodeOverlayOpacity, in: 0.3...1.0)
                            .settingsControlWidth()
                            .accessibilityLabel("Overlay opacity")
                            .accessibilityValue("\(Int(settings.timecodeOverlayOpacity * 100)) percent")

                        Text("\(Int(settings.timecodeOverlayOpacity * 100))%")
                            .font(SettingsDesign.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}

// MARK: - Choose Output Sheet

/// Mono or stereo, then which channel it starts on.
///
/// Two steps in one sheet rather than two sheets: the channel list depends on
/// the mono/stereo answer (a stereo pair needs a free channel beside it), so
/// asking them together lets the list update as the choice changes instead of
/// offering channels that will not work.
// MARK: - Output Roles

/// What an output is for.
///
/// DX/SFX and MX are named roles because a scoring session almost always needs
/// exactly those two, so the common setup is two clicks rather than naming
/// things by hand. Anything else is `additional`, where the user supplies a name.
enum OutputRole: Identifiable, Hashable {
    case stereoOut
    case dialogueEffects
    case music
    case additional

    var id: String {
        switch self {
        case .stereoOut:       return MappedAudioOutput.stereoOutRoleId
        case .dialogueEffects: return MappedAudioOutput.dialogueEffectsRoleId
        case .music:           return MappedAudioOutput.musicRoleId
        case .additional:      return "additional"
        }
    }

    /// Name given to the output. `additional` has none - the user types one.
    var fixedName: String? {
        switch self {
        case .stereoOut:       return "Stereo Out"
        case .dialogueEffects: return "DX/SFX"
        case .music:           return "MX"
        case .additional:      return nil
        }
    }

    var title: String {
        switch self {
        case .stereoOut:       return "Choose a Stereo Output"
        case .dialogueEffects: return "Choose a DX/SFX Output"
        case .music:           return "Choose an MX Output"
        case .additional:      return "Add an Output"
        }
    }

    /// Names that mean this role in mappings saved before `roleId` existed.
    ///
    /// `stereoOut` is listed here too, for a narrower reason: outputs seeded
    /// before the role existed were saved with no `roleId`, so they are adopted
    /// by name rather than being orphaned into the extras list.
    private var legacyNames: Set<String> {
        switch self {
        case .stereoOut:       return ["stereo out", "stereo", "stereo-out"]
        case .dialogueEffects: return ["dx/sfx", "dx", "sfx", "dx-sfx"]
        case .music:           return ["mx", "music"]
        case .additional:      return []
        }
    }

    /// Whether an output fills this role.
    ///
    /// Prefers the stored `roleId`; falls back to the name so mappings made
    /// before roles existed are adopted rather than orphaned.
    func matches(_ output: MappedAudioOutput) -> Bool {
        if let roleId = output.roleId { return roleId == id }
        return legacyNames.contains(output.name.lowercased())
    }
}

// MARK: - Naming a Role in a Filename

extension OutputRole {
    /// Words in a stem's filename that name this role.
    ///
    /// Deliberately abbreviations rather than substrings: matching "dx" anywhere
    /// in the name would claim `Dxxx_alt.wav` and every `MIXDOWN`, so a word has
    /// to stand on its own between separators to count.
    private static let namingWords: [(role: OutputRole, words: Set<String>)] = [
        (.dialogueEffects, ["dx", "dia", "dial", "dialog", "dialogue", "sfx", "fx", "efx"]),
        (.music, ["mx", "mus", "music"])
    ]

    /// The role a filename names, or `nil` if it names none or more than one.
    ///
    /// A name that says both - `R1_DX_and_MX.wav` - returns `nil` rather than
    /// picking the first: guessing wrong routes a stem to the wrong bus, which is
    /// worse than leaving it for the user to answer.
    ///
    /// - Parameter filename: The file's last path component, with or without an
    ///   extension. The extension is stripped, so `.mx` files do not read as music.
    /// - Returns: The single role named, or `nil`.
    static func named(in filename: String) -> OutputRole? {
        let words = words(in: (filename as NSString).deletingPathExtension)
        let matched = namingWords.filter { !$0.words.isDisjoint(with: words) }
        guard matched.count == 1 else { return nil }
        return matched.first?.role
    }

    /// Split a filename into the words a person would read in it.
    ///
    /// Separators break words, and so does a capital following a lowercase or a
    /// digit, so `Reel1MX` and `R1_MX` both yield "mx".
    private static func words(in name: String) -> Set<String> {
        var words: Set<String> = []
        var current = ""
        var previous: Character?

        for character in name {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.insert(current.lowercased()) }
                current = ""
                previous = nil
                continue
            }
            if let previous, previous.isLowercase || previous.isNumber, character.isUppercase {
                if !current.isEmpty { words.insert(current.lowercased()) }
                current = ""
            }
            current.append(character)
            previous = character
        }
        if !current.isEmpty { words.insert(current.lowercased()) }

        return words
    }
}

// MARK: - Choose Output Sheet

struct ChooseOutputSheet: View {
    let role: OutputRole
    @ObservedObject var audioManager: AudioOutputManager

    /// Which device carries each channel, when the selected one is built from several.
    ///
    /// `nil` for an ordinary interface, where every channel comes from the device
    /// already named in the row above and repeating it would only add noise.
    var channelOrigin: AggregateChannelOrigin?

    let onCancel: () -> Void
    let onChoose: (_ name: String, _ firstChannel: Int, _ isStereo: Bool) -> Void

    @State private var isStereo = true
    @State private var firstChannel: Int?
    @State private var customName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsDesign.rowSpacing) {
            Text(role.title)
                .font(SettingsDesign.sectionTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Spacing.xs)

            // Same rows as the panel behind it. A sheet that sets a setting
            // should look like the settings it is editing.
            if role.fixedName == nil {
                SettingsRow(label: "Name") {
                    TextField("e.g. Stems, Cue, Foldback", text: $customName)
                        .textFieldStyle(.roundedBorder)
                        .settingsControlWidth()
                }
            }

            SettingsRow(label: "Format") {
                Picker("", selection: $isStereo) {
                    Text("Mono").tag(false)
                    Text("Stereo").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .settingsControlWidth()
            }

            SettingsRow(label: isStereo ? "Channels" : "Channel") {
                if selectableChannels.isEmpty {
                    Text("No free \(isStereo ? "pair" : "channel") on this device.")
                        .font(SettingsDesign.caption)
                        .foregroundColor(.secondary)
                } else {
                    SettingsMenu(selection: firstChannel.map(channelLabel) ?? "Choose...") {
                        ForEach(selectableChannels, id: \.self) { channel in
                            Button(channelLabel(channel)) { firstChannel = channel }
                        }
                    }
                }
            }

            Spacer(minLength: Spacing.lg)

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                    .settingsInlineButton()
                Spacer()
                Button("Add") {
                    guard let channel = firstChannel else { return }
                    onChoose(resolvedName, channel, isStereo)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(firstChannel == nil || resolvedName.isEmpty)
            }
        }
        .padding()
        .frame(width: 380, height: role.fixedName == nil ? 260 : 220)
        .onChangeCompat(of: isStereo) { _ in
            // The previous pick may not survive the format change - a channel
            // that works as mono can be the last one, with no partner for a pair.
            if let channel = firstChannel, !selectableChannels.contains(channel) {
                firstChannel = nil
            }
        }
    }

    private var resolvedName: String {
        role.fixedName ?? customName.trimmingCharacters(in: .whitespaces)
    }

    /// Channels this output could start on: free, and with a free partner if stereo.
    ///
    /// Channels already claimed by another output are excluded rather than shown
    /// and rejected, so the list only ever offers something that will work.
    private var selectableChannels: [Int] {
        let existing = audioManager.mappedOutputs.first { $0.name == role.fixedName }
        return audioManager.availableChannelNumbers.filter { channel in
            guard !audioManager.channelIsAssigned(channel, excluding: existing?.id) else { return false }
            guard isStereo else { return true }
            let partner = channel + 1
            guard partner <= audioManager.selectedDeviceChannelCount else { return false }
            return !audioManager.channelIsAssigned(partner, excluding: existing?.id)
        }
    }

    /// How a channel is offered in the menu.
    ///
    /// On Projector's aggregate the bare number is unusable: "33-34" names no device the
    /// user owns and appears nowhere in their DAW. There it is replaced by the device
    /// that actually carries the channel, numbered the way that device counts - which is
    /// the number the DAW shows for the loopback half, and the number printed on the
    /// interface for the other.
    private func channelLabel(_ channel: Int) -> String {
        let count = isStereo ? Self.stereoChannelCount : 1

        if let channelOrigin {
            return channelOrigin.label(firstChannel: channel, channelCount: count)
        }
        return isStereo ? "\(channel)-\(channel + 1)" : "\(channel)"
    }

    /// Channels a stereo output occupies.
    private static let stereoChannelCount = 2
}

// MARK: - Settings Design System
//
// Every size, weight and control style in Settings is named here. Read a token
// from `SettingsDesign` and build rows from the components below; do not choose
// a font, width or button style at the call site.
//
// This exists because the alternative was tried and failed within a single
// session: two dropdown widths, three clear buttons, a prominent button beside
// a bordered one, and a window where the Audio section used label-beside-control
// while Display used label-above-control with different fonts.
//
// RULES
//  1. LEFT-ALIGNED. Nothing centred, no leading Spacer.
//  2. ONE CONTROL WIDTH for every menu, field and picker: `SettingsDesign.controlWidth`.
//  3. A SETTING IS A ROW: fixed-width label, then its control. Same shape whether
//     the setting has a value or not.
//  4. ONE CLEAR AFFORDANCE: `SettingsClearButton`.
//  5. A CHOSEN VALUE REPLACES ITS CHOOSER, in place, in the same row shape.
//  6. ONE BUTTON WEIGHT PER GROUP - peers look like peers.
//  7. SECONDARY CONTENT INDENTS TO THE CONTROL COLUMN, never to the label.

/// Every dimension and text style in Settings.
enum SettingsDesign {
    // Type
    /// Section headers: "Audio", "Display".
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    /// The label at the head of a row.
    static let rowLabel = Font.system(size: 12, weight: .medium)
    /// A value shown instead of a control.
    static let value = Font.system(size: 12, weight: .regular)
    /// Supporting text: units, qualifiers, hints.
    static let caption = Font.system(size: 11, weight: .regular)

    // Metrics
    /// Width of the label column. Every control starts after it.
    static let labelWidth: CGFloat = 96
    /// Width of every menu, picker, field and column button.
    static let controlWidth: CGFloat = 200
    /// Height of a control, so a chosen value and a chooser match the pickers
    /// beside them. Matches AppKit's bordered control height.
    static let controlHeight: CGFloat = 26
    /// Corner radius shared by controls and value chips.
    static let cornerRadius: CGFloat = 5

    /// Inset of text inside a control. Matches the label inset AppKit gives a
    /// bordered button, so a chosen value lines up with the chooser it replaced.
    static let controlTextInset: CGFloat = 10

    /// Width of an explanatory popover.
    ///
    /// Narrower than the window it opens over, so it reads as an aside rather than a
    /// second panel, and wide enough to keep prose off single-word lines.
    static let popoverWidth: CGFloat = 320

    /// Fill and border for a setting still waiting to be answered.
    ///
    /// Paired with `chosenFill`: yellow means pending, green means set, so the
    /// column can be read at a glance without reading any of the labels.
    static let pendingFill = AppColors.accentYellow.opacity(0.16)
    static let pendingBorder = AppColors.accentYellow.opacity(0.5)

    /// Fill and border for a setting that has been answered.
    ///
    /// Green rather than grey: at a glance the column should show which routes
    /// are assigned and which are still empty, and grey reads the same as the
    /// unset controls around it.
    static let chosenFill = AppColors.accentGreen.opacity(0.18)
    static let chosenBorder = AppColors.accentGreen.opacity(0.55)
    /// Between rows in a section.
    static let rowSpacing: CGFloat = Spacing.sm
    /// Between a row and secondary content belonging to it.
    static let subRowSpacing: CGFloat = Spacing.xs
    /// Indent that lines secondary content up with the control column.
    static var controlColumnInset: CGFloat { labelWidth + Spacing.sm }
}

/// A fixed-width label beside its control (rule 3).
struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(label)
                .font(SettingsDesign.rowLabel)
                .foregroundColor(.primary)
                .frame(width: SettingsDesign.labelWidth, alignment: .leading)

            content()

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Content belonging to the row above, lined up with the control column (rule 7).
struct SettingsSubRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: Spacing.sm) {
            content()
            Spacer(minLength: 0)
        }
        .padding(.leading, SettingsDesign.controlColumnInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The one clear/reset affordance (rule 4).
struct SettingsClearButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The one "what is this?" affordance: a help button that explains its row.
///
/// Deliberately the same shape as ``SettingsClearButton`` - a bare SF Symbol at the end
/// of the control column, no bezel - so a row can carry either without changing height
/// or gaining a second button weight (rule 6).
///
/// The tooltip says what the button is for; the popover answers it. Both, because a
/// question mark alone does not say whether it opens documentation, a sheet or a web
/// page, and a tooltip cannot hold an explanation worth reading.
struct SettingsHelpButton<Content: View>: View {

    /// Whether the explanation is on screen.
    @Binding var isPresented: Bool

    /// The explanation itself.
    @ViewBuilder var content: () -> Content

    /// Prompt shown on hover, and the button's accessibility label.
    private static var prompt: String { "What is this?" }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "questionmark.circle")
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help(Self.prompt)
        .accessibilityLabel(Self.prompt)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            content()
        }
    }
}

/// A value with its clear button, for a row whose setting is filled (rule 5).
///
/// Drawn as a filled, outlined field rather than bare text. A chosen setting
/// should look chosen: sitting at the same size and position as the control it
/// replaced, so the column keeps one edge and the row reads as answered rather
/// than as a stray line of text.
struct SettingsValue: View {
    let value: String
    var qualifier: String?
    var clearLabel: String?
    var onClear: (() -> Void)?

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(value)
                .font(SettingsDesign.value)
                .foregroundColor(.primary)
                // The row is a fixed width and device names are not. Truncating is the
                // lesser failure: overflowing pushes the clear button out of the row.
                .lineLimit(1)
                .truncationMode(.tail)
                .help(value)

            Spacer(minLength: Spacing.sm)

            // Right-justified: the value is what you read, the format is what
            // you confirm. Trailing them keeps the left edge of every row's
            // content identical whatever the value says.
            if let qualifier {
                Text(qualifier)
                    .font(SettingsDesign.caption)
                    .foregroundColor(.secondary)
            }

            if let onClear, let clearLabel {
                SettingsClearButton(label: clearLabel, action: onClear)
            }
        }
        .padding(.horizontal, SettingsDesign.controlTextInset)
        .frame(width: SettingsDesign.controlWidth,
               height: SettingsDesign.controlHeight,
               alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SettingsDesign.cornerRadius)
                .fill(SettingsDesign.chosenFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsDesign.cornerRadius)
                .stroke(SettingsDesign.chosenBorder, lineWidth: 1)
        )
    }
}

/// A dropdown drawn by us rather than by AppKit.
///
/// SwiftUI's `Picker(.menu)` renders an NSPopUpButton whose bezel is sized by
/// its widest item and ignores any width you propose - so it could not be made
/// to match the Slider or the value chips beside it, from either direction.
/// Owning the label means the column has one width and one chrome, and a menu,
/// a chooser and a chosen value are visibly the same control in three states.
struct SettingsMenu<Content: View>: View {
    let selection: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: Spacing.xs) {
                Text(selection)
                    .font(SettingsDesign.value)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer(minLength: Spacing.xs)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, SettingsDesign.controlTextInset)
            .frame(width: SettingsDesign.controlWidth,
                   height: SettingsDesign.controlHeight,
                   alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsDesign.cornerRadius)
                    .fill(AppColors.surfaceLight)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsDesign.cornerRadius)
                    .stroke(AppColors.borderMedium, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// A bordered group of related settings.
///
/// Used where a set of controls acts on the section as a whole rather than on
/// one row - profiles load and replace everything below them, so they read as a
/// header for the section, not another row in it.
struct SettingsBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(SettingsDesign.sectionTitle)
                .foregroundColor(.primary)
            content()
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SettingsDesign.cornerRadius)
                .fill(AppColors.surfaceSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsDesign.cornerRadius)
                .stroke(AppColors.borderSubtle, lineWidth: 1)
        )
    }
}

/// A chooser that has not been answered yet.
///
/// Deliberately the same size and shape as `SettingsValue`, differing only in
/// colour, so answering a row changes its state rather than its geometry - and
/// a column of yellow and green reads as "still to do" and "done".
struct SettingsChooserButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SettingsDesign.value)
            .foregroundColor(.primary)
            .padding(.horizontal, SettingsDesign.controlTextInset)
            .frame(width: SettingsDesign.controlWidth,
                   height: SettingsDesign.controlHeight,
                   alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsDesign.cornerRadius)
                    .fill(SettingsDesign.pendingFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsDesign.cornerRadius)
                    .stroke(SettingsDesign.pendingBorder, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

extension View {

    /// A pending chooser (rule 5's other half).
    func settingsChooserButton() -> some View {
        buttonStyle(SettingsChooserButtonStyle())
    }

    /// Rule 2: one width for every control in Settings.
    ///
    /// Two frames, BOTH aligned leading - the alignment is the load-bearing
    /// part.
    ///
    /// The inner `maxWidth: .infinity` lets a control that can stretch take the
    /// full column width, so a Slider and a Picker end at the same place instead
    /// of one running 70pt past the other. It must carry `alignment: .leading`:
    /// `.frame(maxWidth:)` centres by default, and without it the control was
    /// centred inside its own frame before any outer alignment could apply -
    /// which is what left every Picker floating mid-column.
    ///
    /// A control that cannot stretch keeps its intrinsic size and sits at the
    /// left edge, which is the guarantee that matters: one column, one left
    /// edge.
    func settingsControlWidth() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .frame(width: SettingsDesign.controlWidth, alignment: .leading)
    }

    /// Rule 6: a control-column button. Same width as every menu beside it, so
    /// the column has one edge rather than three.
    ///
    /// Its label is left-aligned: a button stretched to the column width centres
    /// its text by default, which put "Choose..." in the middle of an otherwise
    /// left-aligned column.
    func settingsButton() -> some View {
        buttonStyle(.bordered)
            .settingsControlWidth()
    }

    /// A button that sits in a group of small actions (Save / New / delete),
    /// where a shared width would look absurd. Weight still matches its peers.
    func settingsInlineButton() -> some View {
        buttonStyle(.bordered)
    }
}

// MARK: - Refresh Button

private struct RefreshIconButton: View {
    let helpText: String
    let action: () -> Void

    @State private var isHovering = false
    @State private var rotation: Double = 0

    var body: some View {
        Button(action: {
            withAnimation(AppAnimations.slow) {
                rotation += 360
            }
            action()
        }) {
            Image(systemName: "arrow.clockwise")
                .font(Typography.icon)
                .rotationEffect(.degrees(rotation))
                .animation(AppAnimations.slow, value: rotation)
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .help(helpText)
        .accessibilityLabel(helpText)
        .onHover { hovering in
            if hovering, !isHovering {
                NSCursor.pointingHand.push()
                isHovering = true
            } else if !hovering, isHovering {
                NSCursor.pop()
                isHovering = false
            }
        }
    }
}
