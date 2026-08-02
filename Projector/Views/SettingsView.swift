import SwiftUI
import AppKit

/// Settings window for audio and display configuration.
///
/// Provides accordion-style sections for:
/// - Audio: Output device selection and channel mapping
/// - Display: Timecode overlay configuration
struct SettingsView: View {
    @ObservedObject var audioManager: AudioOutputManager
    @ObservedObject var settings = AppSettings.shared

    @Binding var isPresented: Bool

    // Accordion section states - default to expanded
    @State private var audioExpanded = true
    @State private var displayExpanded = true

    @State private var pendingOutputRole: OutputRole?
    @State private var selectedProfileId: UUID?
    @State private var isNamingProfile = false
    @State private var newProfileName = ""
    @State private var pendingProfile: AudioOutputProfile?
    @State private var showProfileDeviceWarning = false

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
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
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

            if audioManager.selectedDeviceChannelCount == 0 {
                Text("No output channels detected for this device.")
                    .font(SettingsDesign.caption)
                    .foregroundColor(.secondary)
            } else {
                outputChoosers
            }
        }
        .sheet(item: $pendingOutputRole) { role in
            ChooseOutputSheet(
                role: role,
                audioManager: audioManager,
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

            RefreshIconButton(helpText: "Refresh Devices") {
                audioManager.refreshDevices()
            }
        }
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
    private var outputChoosers: some View {
        VStack(alignment: .leading, spacing: SettingsDesign.rowSpacing) {
            outputRow(.stereoOut)
            outputRow(.music)
            outputRow(.dialogueEffects)

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
            value: outputChannelLabel(output),
            qualifier: output.channelCount == 2 ? "stereo" : "mono",
            clearLabel: "Clear \(output.name)",
            onClear: { audioManager.removeOutput(id: output.id) }
        )
    }

    private func assignedOutput(for role: OutputRole) -> MappedAudioOutput? {
        audioManager.mappedOutputs.first { role.matches($0) }
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
    private func outputChannelLabel(_ output: MappedAudioOutput) -> String {
        let first = output.channelStart + 1
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
        case .dialogueEffects: return "dx-sfx"
        case .music:           return "mx"
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

    private func channelLabel(_ channel: Int) -> String {
        isStereo ? "\(channel)-\(channel + 1)" : "\(channel)"
    }
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
