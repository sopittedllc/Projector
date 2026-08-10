import SwiftUI
import AVKit
import AVFoundation
import UniformTypeIdentifiers

/// Sizes for the demo sheet. Named, because 0 magic numbers is the house rule.
private enum DemoSheetLayout {
    static let width: CGFloat = 680
    static let height: CGFloat = 720
    static let previewHeight: CGFloat = 260
    static let gainSliderWidth: CGFloat = 180
    static let laneNameWidth: CGFloat = 150
    static let gainReadoutWidth: CGFloat = 64
    static let handleFieldWidth: CGFloat = 64

    /// Levels a review demo plausibly needs. Wider than a mixing desk on
    /// purpose - this is for balancing a rough demo, not for finishing.
    static let gainRange: ClosedRange<Float> = -40...6

    /// Handles offered in seconds. Two minutes is already generous for a demo.
    static let handleRange: ClosedRange<Int> = 0...120
}

/// Builds a review QuickTime: the picture against a stereo mix the user supplies.
///
/// Holds the preview player, so it owns an `AVPlayer` - the one AVFoundation use
/// the UI layer is allowed, via `AVPlayerView`. Everything that touches a
/// composition lives in ``QuickTimeDemoBuilder``.
@MainActor
final class QuickTimeDemoViewModel: ObservableObject {

    // MARK: - Chosen Mix

    @Published private(set) var mixURL: URL?
    @Published private(set) var mixTimecode: String?
    @Published private(set) var mixDurationText: String?

    // MARK: - Choices

    @Published var spec: QuickTimeDemoSpec?

    /// Handles in seconds, which is how a cutting room talks about them. Frames
    /// are what the builder wants, and the conversion happens here.
    @Published var headSeconds: Int = 0
    @Published var tailSeconds: Int = 0

    // MARK: - State

    @Published private(set) var isBuilding = false
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Float = 0
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var exportedURL: URL?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var hasPicture = true

    private var demo: QuickTimeDemo?
    private let timeline: Timeline
    private let timecodeService: EmbeddedTimecodeService
    private let formatTimecode: (Int) -> String

    var canExport: Bool { demo != nil && !isExporting && !isBuilding }

    /// - Parameters:
    ///   - timeline: The timeline to print from.
    ///   - timecodeService: Reads the mix's embedded timecode.
    ///   - formatTimecode: Renders a timeline frame as a timecode, for display.
    init(
        timeline: Timeline,
        timecodeService: EmbeddedTimecodeService,
        formatTimecode: @escaping (Int) -> String
    ) {
        self.timeline = timeline
        self.timecodeService = timecodeService
        self.formatTimecode = formatTimecode
    }

    // MARK: - Choosing the Mix

    /// Ask for the stereo mix the demo is built around.
    func chooseMix() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the stereo mix to print against picture."
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.wav, .aiff, .audio]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        await load(mix: url)
    }

    /// Read the mix's timecode and duration, then build the first preview.
    ///
    /// A file with no timecode is refused rather than placed at a guess: the
    /// whole point is that the mix lands where the picture is, and "somewhere"
    /// is worse than a clear refusal.
    private func load(mix url: URL) async {
        errorMessage = nil
        statusMessage = nil
        exportedURL = nil
        isBuilding = true
        defer { isBuilding = false }

        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else {
            errorMessage = QuickTimeDemoError.mixUnreadable(url).localizedDescription
            return
        }

        guard let detected = await timecodeService.detectTimecode(from: url, bookmark: nil) else {
            errorMessage = QuickTimeDemoError.mixHasNoTimecode.localizedDescription
            return
        }

        let rate = timeline.config.frameRate
        // A timecode *address* on the timeline's grid, then made relative to
        // where the timeline starts - the same conversion an import uses.
        let absoluteFrames = detected.convertedFrames(to: rate.fps)
        let startFrame = max(0, absoluteFrames - timeline.config.startTimecode.frameCount.wholeFrames)
        let durationFrames = Int((duration.seconds * rate.fps).rounded())

        mixURL = url
        mixTimecode = detected.formattedTimecode
        mixDurationText = Self.durationText(seconds: duration.seconds)

        // The setup remembered from the last demo, in any project. A lane the
        // user has never seen before is not in there, and falls back to the
        // original default: excluded at unity. The mix is the thing being
        // judged, so a lane arrives silent unless it was deliberately kept.
        let remembered = AppSettings.shared.quickTimeDemoDefaults
        headSeconds = remembered.headSeconds
        tailSeconds = remembered.tailSeconds

        spec = QuickTimeDemoSpec(
            wavURL: url,
            wavStartFrame: startFrame,
            wavDurationFrames: durationFrames,
            wavGainDB: remembered.mixGainDB,
            lanes: timeline.audioLanes.map { lane in
                let saved = remembered.lanes[lane.name]
                return QuickTimeDemoLaneChoice(
                    id: lane.id,
                    name: lane.name,
                    isIncluded: saved?.isIncluded ?? false,
                    gainDB: saved?.gainDB ?? 0
                )
            },
            headFrames: 0,
            tailFrames: 0
        )

        await rebuild()
    }

    // MARK: - Building

    /// Reassemble the composition and hand it to the preview player.
    ///
    /// Needed whenever *what* is in the demo changes - lanes coming in or out,
    /// or the handles. A level change goes through ``applyLevels()`` instead so
    /// the preview keeps playing.
    func rebuild() async {
        guard var spec else { return }
        let rate = timeline.config.frameRate
        let previousStartFrame = demo?.span.startFrame
        let previousTime = player?.currentTime()

        spec.headFrames = Int(Double(headSeconds) * rate.fps)
        spec.tailFrames = Int(Double(tailSeconds) * rate.fps)
        self.spec = spec
        rememberChoices()

        isBuilding = true
        defer { isBuilding = false }
        errorMessage = nil

        do {
            let built = try await QuickTimeDemoBuilder.makeDemo(timeline: timeline, spec: spec)
            demo = built
            hasPicture = built.hasPicture

            let item = AVPlayerItem(asset: built.composition)
            item.audioMix = built.audioMix
            let player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .pause
            self.player = player

            // Only the handles reach this now, and they move the span's start -
            // so the same moment of picture sits at a different time in the new
            // composition. Shifting by that difference keeps the preview where
            // the user left it instead of throwing them back to the head.
            if let previousTime, let previousStartFrame {
                let shift = Double(previousStartFrame - built.span.startFrame) / rate.fps
                let target = CMTimeAdd(previousTime, CMTime(seconds: shift, preferredTimescale: 600))
                if target.seconds > 0 {
                    await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        } catch {
            demo = nil
            player = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Apply the current levels and inclusions to the demo already playing.
    ///
    /// Both are properties of the *mix*, not of the composition - every lane is
    /// in the composition either way - so neither needs a rebuild and the preview
    /// keeps playing the moment being judged.
    func applyLevels() {
        guard let demo, let spec else { return }
        player?.currentItem?.audioMix = QuickTimeDemoBuilder.makeAudioMix(for: demo, spec: spec)
        rememberChoices()
    }

    /// Keep this setup for the next demo, in this and every other project.
    ///
    /// Called from both paths that change a choice - ``rebuild()`` for lanes and
    /// handles, ``applyLevels()`` for faders - rather than from the export, so a
    /// setup arrived at and then abandoned is still the one offered next time.
    /// That matches how the sheet is actually used: the balance is found by ear
    /// long before anyone commits to writing a file.
    ///
    /// Lanes are merged into what is already stored rather than replacing it, so
    /// a project that happens to contain only music does not forget the dialogue
    /// setting made in the last one.
    private func rememberChoices() {
        guard let spec else { return }

        var defaults = AppSettings.shared.quickTimeDemoDefaults
        defaults.headSeconds = headSeconds
        defaults.tailSeconds = tailSeconds
        defaults.mixGainDB = spec.wavGainDB
        for lane in spec.lanes {
            defaults.lanes[lane.name] = QuickTimeDemoDefaults.Lane(
                isIncluded: lane.isIncluded,
                gainDB: lane.gainDB
            )
        }

        AppSettings.shared.saveQuickTimeDemoDefaults(defaults)
    }

    /// Which lanes actually have audio inside the demo's span.
    ///
    /// A lane whose clips all fall outside it cannot contribute, and a toggle
    /// that silently does nothing is worse than one that is visibly unavailable.
    var lanesWithAudio: Set<UUID> {
        Set(demo?.laneTrackIDs.keys ?? [:].keys)
    }

    // MARK: - Export

    /// Ask where to write, then encode.
    func export() async {
        guard let demo, let spec else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = Self.suggestedName(for: spec.wavURL)
        panel.message = "Choose where to write the demo."
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        exportProgress = 0
        errorMessage = nil
        statusMessage = nil
        exportedURL = nil
        defer { isExporting = false }

        // The levels on screen, not the ones the composition happened to be
        // built with - a fader moved since then applied to the preview only.
        let mixed = QuickTimeDemo(
            composition: demo.composition,
            audioMix: QuickTimeDemoBuilder.makeAudioMix(for: demo, spec: spec),
            span: demo.span,
            hasPicture: demo.hasPicture,
            mixTrackID: demo.mixTrackID,
            laneTrackIDs: demo.laneTrackIDs
        )

        do {
            try await QuickTimeDemoBuilder.export(mixed, to: destination) { [weak self] progress in
                self?.exportProgress = progress
            }
            exportedURL = destination
            statusMessage = "Exported \(destination.lastPathComponent)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealExport() {
        guard let exportedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
    }

    // MARK: - Display

    /// The demo's own length, for the summary line.
    var demoDurationText: String? {
        guard let demo else { return nil }
        let seconds = Double(demo.span.durationFrames) / timeline.config.frameRate.fps
        return Self.durationText(seconds: seconds)
    }

    /// Where the demo begins on the timeline, as timecode.
    var demoStartTimecode: String? {
        guard let demo else { return nil }
        return formatTimecode(demo.span.startFrame)
    }

    private static func durationText(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func suggestedName(for mixURL: URL) -> String {
        mixURL.deletingPathExtension().lastPathComponent + " Demo.mov"
    }
}

// MARK: - Sheet

/// Pick a mix, balance it against the timeline's lanes, preview, export.
struct QuickTimeDemoSheet: View {
    @ObservedObject var viewModel: QuickTimeDemoViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    // Only until a mix is chosen. Once one is, the header carries
                    // its name and the preview says where it sits, so keeping a
                    // picker and a duplicate summary on screen is clutter over
                    // the controls that are actually being used.
                    if viewModel.spec == nil {
                        mixPrompt
                    } else {
                        previewSection
                        handlesSection
                        levelsSection
                    }

                    if let errorMessage = viewModel.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(Typography.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding()
            }

            Divider()
            footer
        }
        .frame(width: DemoSheetLayout.width, height: DemoSheetLayout.height)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "film.stack")
                .font(Typography.iconMedium)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                Text("Create QT Demo")
                    .font(Typography.title)

                if let name = viewModel.mixURL?.lastPathComponent {
                    Text(name)
                        .font(Typography.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            // The only trace of the picker once a mix is chosen.
            if viewModel.mixURL != nil {
                Button("Change…") {
                    Task { await viewModel.chooseMix() }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .disabled(viewModel.isExporting)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.sm)
    }

    // MARK: Mix

    private var mixPrompt: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button("Choose Mix…") {
                Task { await viewModel.chooseMix() }
            }

            Text("A stereo bounce with timecode in its metadata. Its timecode places it against picture, and its length sets the demo's.")
                .font(Typography.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("Preview")
                    .font(Typography.heading)
                Spacer()
                if viewModel.isBuilding {
                    ProgressView().controlSize(.small)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black)

                if let player = viewModel.player {
                    DemoPreviewPlayer(player: player)
                } else {
                    Text("Nothing to preview yet.")
                        .font(Typography.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(height: DemoSheetLayout.previewHeight)

            if !viewModel.hasPicture {
                Label(
                    "No picture in this range - the demo will be black.",
                    systemImage: "exclamationmark.circle"
                )
                .font(Typography.caption)
                .foregroundColor(.orange)
            }

            if let start = viewModel.demoStartTimecode, let duration = viewModel.demoDurationText {
                Text("Demo starts at \(start) · \(duration) long")
                    .font(Typography.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: Handles

    private var handlesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Handles")
                .font(Typography.heading)

            HStack(spacing: Spacing.lg) {
                handleField("Head", value: $viewModel.headSeconds)
                handleField("Tail", value: $viewModel.tailSeconds)
                Spacer()
            }

            Text("Extra picture before and after the mix, in seconds.")
                .font(Typography.caption)
                .foregroundColor(.secondary)
        }
    }

    private func handleField(_ label: String, value: Binding<Int>) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(label)
                .font(Typography.body)
            Stepper(
                value: value,
                in: DemoSheetLayout.handleRange
            ) {
                Text("\(value.wrappedValue)s")
                    .font(Typography.mono)
                    .frame(width: DemoSheetLayout.handleFieldWidth, alignment: .leading)
            }
            .onChangeCompat(of: value.wrappedValue) { _ in
                Task { await viewModel.rebuild() }
            }
        }
    }

    // MARK: Levels

    private var levelsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Levels")
                .font(Typography.heading)

            if let spec = viewModel.spec {
                // One list: the mix reads as the first fader rather than as a
                // separate thing above the others, because balancing it against
                // the lanes is the whole job.
                gainRow(
                    name: "Your mix",
                    isIncluded: .constant(true),
                    showsToggle: true,
                    isToggleEnabled: false,
                    gain: Binding(
                        get: { spec.wavGainDB },
                        set: { newValue in
                            viewModel.spec?.wavGainDB = newValue
                            viewModel.applyLevels()
                        }
                    )
                )

                if spec.lanes.isEmpty {
                    Text("This project has no audio lanes to add.")
                        .font(Typography.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(spec.lanes) { lane in
                        laneRow(lane)
                    }
                }
            }
        }
    }

    private func laneRow(_ lane: QuickTimeDemoLaneChoice) -> some View {
        let hasAudio = viewModel.lanesWithAudio.contains(lane.id)

        return gainRow(
            name: lane.name,
            isIncluded: Binding(
                get: { lane.isIncluded && hasAudio },
                set: { newValue in
                    guard let index = viewModel.spec?.lanes.firstIndex(where: { $0.id == lane.id }) else { return }
                    viewModel.spec?.lanes[index].isIncluded = newValue
                    // Every lane is already in the composition, so this is a mix
                    // change like the faders - no rebuild, no interrupted preview.
                    viewModel.applyLevels()
                }
            ),
            showsToggle: true,
            isToggleEnabled: hasAudio,
            gain: Binding(
                get: { lane.gainDB },
                set: { newValue in
                    guard let index = viewModel.spec?.lanes.firstIndex(where: { $0.id == lane.id }) else { return }
                    viewModel.spec?.lanes[index].gainDB = newValue
                    viewModel.applyLevels()
                }
            ),
            isEnabled: lane.isIncluded && hasAudio,
            note: hasAudio ? nil : "nothing in this range"
        )
    }

    private func gainRow(
        name: String,
        isIncluded: Binding<Bool>,
        showsToggle: Bool,
        isToggleEnabled: Bool = true,
        gain: Binding<Float>,
        isEnabled: Bool = true,
        note: String? = nil
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            if showsToggle {
                Toggle("", isOn: isIncluded)
                    .labelsHidden()
                    .disabled(!isToggleEnabled)
                    .help(isToggleEnabled ? "Include this lane in the demo" : "Always included")
            }

            Text(name)
                .font(Typography.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: DemoSheetLayout.laneNameWidth, alignment: .leading)

            Slider(
                value: gain,
                in: DemoSheetLayout.gainRange
            )
            .frame(width: DemoSheetLayout.gainSliderWidth)
            .disabled(!isEnabled)

            Text(String(format: "%+.1f dB", gain.wrappedValue))
                .font(Typography.mono)
                .foregroundColor(isEnabled ? .primary : .secondary)
                .frame(width: DemoSheetLayout.gainReadoutWidth, alignment: .trailing)

            if let note {
                Text(note)
                    .font(Typography.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Spacing.sm) {
            if viewModel.isExporting {
                ProgressView(value: viewModel.exportProgress)
                    .frame(width: DemoSheetLayout.gainSliderWidth)
                Text(String(format: "%.0f%%", viewModel.exportProgress * 100))
                    .font(Typography.mono)
                    .foregroundColor(.secondary)
            } else if let status = viewModel.statusMessage {
                Label(status, systemImage: "checkmark.circle")
                    .font(Typography.caption)
                    .foregroundColor(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Button("Show in Finder") { viewModel.revealExport() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Close") { isPresented = false }
                .keyboardShortcut(.cancelAction)

            Button("Export…") {
                Task { await viewModel.export() }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canExport)
        }
        .padding()
    }
}

/// The preview player, with QuickTime's own controls so scrubbing comes free.
///
/// `AVPlayerView` rather than a bare `AVPlayerLayer`: this is a review preview,
/// and a review preview without a scrubber is not much use.
private struct DemoPreviewPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
