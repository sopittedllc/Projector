import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import SwiftTimecodeCore
import AppKit
import Iconoir

/// Configures the window title with a logo
struct WindowTitleConfigurator: NSViewRepresentable {
    let title: String
    let isEdited: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureWindowTitle(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindowTitle(nsView.window)
        }
    }

    private func configureWindowTitle(_ window: NSWindow?) {
        guard let window = window else { return }

        // Hide the system title - we'll show our own
        window.titleVisibility = .hidden

        // Update the window title (for Window menu, etc.)
        let displayTitle = "PROJECTOR: " + title + (isEdited ? " *" : "")
        window.title = displayTitle

        // Find the titlebar container and add our custom title with logo
        guard let titlebarContainer = window.standardWindowButton(.closeButton)?.superview?.superview else { return }

        // Look for an existing custom title view or create one
        configureTitleWithLogo(in: titlebarContainer, window: window)
    }

    private func configureTitleWithLogo(in container: NSView, window: NSWindow) {
        // Check if we already added our custom view (identified by accessibilityIdentifier)
        let customViewID = "ProjectorTitleView"
        if let existingView = findViewWithIdentifier(customViewID, in: container) as? NSStackView {
            // Update existing view
            if let textField = existingView.arrangedSubviews.last as? NSTextField {
                let displayTitle = "PROJECTOR: " + title + (isEdited ? " *" : "")
                textField.stringValue = displayTitle
                if isEdited {
                    textField.font = NSFont.systemFont(ofSize: 13, weight: .semibold).italic()
                } else {
                    textField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
                }
            }
            return
        }

        // Find the original title text field
        guard let originalTitle = findTitleTextField(in: container, title: title) else { return }

        // Hide the original title
        originalTitle.isHidden = true

        // Create our custom title view with logo
        let stackView = NSStackView()
        stackView.setAccessibilityIdentifier(customViewID)
        stackView.orientation = .horizontal
        stackView.spacing = 6
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // Add logo
        let logoView = NSImageView()
        logoView.image = NSImage(named: "TitlebarLogo")
        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logoView.widthAnchor.constraint(equalToConstant: 16),
            logoView.heightAnchor.constraint(equalToConstant: 16)
        ])
        stackView.addArrangedSubview(logoView)

        // Add title text
        let titleField = NSTextField(labelWithString: "PROJECTOR: " + title + (isEdited ? " *" : ""))
        titleField.font = isEdited ? NSFont.systemFont(ofSize: 13, weight: .semibold).italic() : NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.alignment = .center
        stackView.addArrangedSubview(titleField)

        // Add to the same superview as the original title
        if let superview = originalTitle.superview {
            superview.addSubview(stackView)

            // Center the stack view where the original title was
            NSLayoutConstraint.activate([
                stackView.centerXAnchor.constraint(equalTo: superview.centerXAnchor),
                stackView.centerYAnchor.constraint(equalTo: originalTitle.centerYAnchor)
            ])
        }
    }

    private func findViewWithIdentifier(_ identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        for subview in view.subviews {
            if let found = findViewWithIdentifier(identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    private func findTitleTextField(in view: NSView, title: String) -> NSTextField? {
        for subview in view.subviews {
            if let textField = subview as? NSTextField,
               textField.stringValue.contains(title) || textField.stringValue == "Untitled Projector Project" {
                return textField
            }
            if let found = findTitleTextField(in: subview, title: title) {
                return found
            }
        }
        return nil
    }
}

extension NSFont {
    func italic() -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: 0) ?? self
    }
}

/// Info about a missing file that needs to be located
struct MissingFileInfo: Identifiable {
    let id: UUID
    let originalPath: String
    let type: MissingFileType
    var newURL: URL?

    enum MissingFileType {
        case mediaItem
        case videoReel
        case audioClip(laneId: UUID)
    }
}

/// Main application content view
struct ContentView: View {
    // MARK: - Managers
    @StateObject private var playbackEngine = PlaybackEngine()
    @StateObject private var timelineManager = TimelineManager()
    @StateObject private var mediaLibrary = ProjectMediaLibrary()
    @StateObject private var waveformCache = WaveformCache()
    @StateObject private var midiManager = MIDIManager()
    @StateObject private var audioManager = AudioOutputManager()
    @StateObject private var projectDocument = ProjectDocument()
    @ObservedObject private var settings = AppSettings.shared

    // MARK: - UI State
    @State private var showSettings = false
    @State private var isDropTargeted = false
    @State private var isLoadingMedia = false
    @State private var loadError: String?
    @State private var showErrorAlert = false
    @State private var videoThumbnails: [UUID: ThumbnailStrip] = [:]
    @State private var showFileManager = true
    @State private var isTimelineExpanded = false
    @State private var timelineZoomLevel: CGFloat = 1.0
    @State private var isFullScreen = false

    // Missing files state
    @State private var showMissingFilesAlert = false
    @State private var missingFiles: [MissingFileInfo] = []
    @State private var currentMissingFileIndex = 0

    // FPS conflict state
    @State private var showFPSConflictAlert = false
    @State private var pendingVideoURL: URL?
    @State private var pendingVideoFPS: TimecodeFrameRate?

    var body: some View {
        Group {
            if isFullScreen {
                fullScreenView
            } else {
                normalView
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                midiManager: midiManager,
                audioManager: audioManager,
                timelineManager: timelineManager,
                isPresented: $showSettings
            )
        }
        .alert("Error Loading Video", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loadError ?? "Unknown error")
        }
        .alert("Missing File", isPresented: $showMissingFilesAlert) {
            Button("Locate...") {
                locateMissingFile()
            }
            Button("Skip", role: .destructive) {
                skipMissingFile()
            }
            Button("Skip All", role: .destructive) {
                skipAllMissingFiles()
            }
        } message: {
            if currentMissingFileIndex < missingFiles.count {
                let file = missingFiles[currentMissingFileIndex]
                Text("Cannot find file:\n\(file.originalPath)\n\nWould you like to locate it?")
            }
        }
        .alert("Frame Rate Mismatch", isPresented: $showFPSConflictAlert) {
            Button("Change Project FPS", role: .destructive) {
                handleFPSConflictChangeProject()
            }
            Button("Cancel", role: .cancel) {
                pendingVideoURL = nil
                pendingVideoFPS = nil
            }
        } message: {
            if let fps = pendingVideoFPS {
                Text("This video is \(frameRateDisplayName(fps)) but the project is \(frameRateDisplayName(timelineManager.timeline.config.frameRate)).\n\nChanging the project FPS will remove all existing video reels.")
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, alphaValue: 0.95)
        )
        .overlay {
            // Invisible overlay to cancel timecode editing when clicking outside
            if isStartTCFocused || isDurationFocused {
                Color.black.opacity(0.001)
                    .onTapGesture {
                        cancelTimecodeEditing()
                    }
            }
        }
        .navigationTitle("")
        .background(WindowTitleConfigurator(
            title: projectDocument.displayName,
            isEdited: projectDocument.hasUnsavedChanges
        ))
        .onReceive(NotificationCenter.default.publisher(for: .videoFileSelected)) { notification in
            // Add dropped video to timeline
            if let url = notification.object as? URL {
                Task {
                    await addVideoToTimeline(url: url)
                }
            }
        }
        .onAppear {
            setupMIDICallbacks()
            setupAudioCallback()
            setupTimelineCallbacks()
            restoreSettings()
        }
        // Sync unsaved changes state with AppDelegate for quit confirmation
        .onReceive(projectDocument.$hasUnsavedChanges) { hasChanges in
            AppDelegate.hasUnsavedChanges = hasChanges
        }
        // Save handlers - selector-backed commands bypass AppKit's Save validation
        .onReceive(NotificationCenter.default.publisher(for: .saveProject)) { _ in
            saveProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveProjectAs)) { _ in
            saveProjectAs()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProjectFile)) { notification in
            NSLog(">>> ContentView: received openProjectFile notification")
            if let url = notification.object as? URL {
                NSLog(">>> ContentView: opening project from %@", url.path)
                openProject(from: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProjectFromMenu)) { _ in
            showOpenProjectPanel()
        }
        .onOpenURL { url in
            NSLog(">>> ContentView.onOpenURL: %@", url.path)
            if url.pathExtension.lowercased() == "projector" {
                openProject(from: url)
            }
        }
        // Listen for window full screen changes
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        // Escape key exits full screen
        .onKeyPress(.escape) {
            if isFullScreen {
                exitFullScreen()
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - View Modes

    private var normalView: some View {
        VStack(spacing: 0) {
            // Video content area
            VideoContentViewForEngine(
                playbackEngine: playbackEngine,
                showTimecode: settings.showTimecodeOverlay,
                overlayPosition: settings.timecodeOverlayPosition,
                overlayOpacity: settings.timecodeOverlayOpacity
            )
            .frame(minWidth: 480, minHeight: 200)
            .transaction { $0.animation = nil }
            .overlay {
                // Drop target overlay
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor, lineWidth: 3)
                        .background(Color.accentColor.opacity(0.1))
                        .padding(8)
                }

                // Loading overlay
                if isLoadingMedia {
                    ZStack {
                        Color.black.opacity(0.5)

                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))

                            Text("Loading media...")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        .padding(32)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.black.opacity(0.7))
                        )
                    }
                }
            }

            // Vital Controls bar (always visible)
            vitalControlsBar
                .padding(.horizontal, 16)
                .padding(.top, 8)

            // Timeline accordion
            timelineAccordion
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .onChange(of: mediaLibrary.items.count) { _, newCount in
                    // Auto-expand timeline when media is first imported
                    if newCount > 0 && !isTimelineExpanded {
                        isTimelineExpanded = true
                    }
                }

            // File Manager panel
            if showFileManager {
                FileManagerView(
                    mediaLibrary: mediaLibrary,
                    onAddToVideoTrack: handleAddToVideoTrack,
                    onAddToAudioLane: handleAddToAudioLane
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
        }
    }

    private var fullScreenView: some View {
        ZStack {
            // Black background
            Color.black.ignoresSafeArea()

            // Video player fills the screen
            // Add extra trailing padding when timecode is in bottom-right to avoid overlapping minimize button
            VideoContentViewForEngine(
                playbackEngine: playbackEngine,
                showTimecode: settings.showTimecodeOverlay,
                overlayPosition: settings.timecodeOverlayPosition,
                overlayOpacity: settings.timecodeOverlayOpacity,
                extraTrailingPadding: settings.timecodeOverlayPosition == .bottomRight ? 50 : 0
            )
            .ignoresSafeArea()

            // Minimize button in bottom right corner
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: { exitFullScreen() }) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(
                                Circle()
                                    .fill(Color.black.opacity(0.6))
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(20)
                    .opacity(0.7)
                }
            }
        }
    }

    private func enterFullScreen() {
        guard let window = NSApp.keyWindow else { return }
        isFullScreen = true
        window.toggleFullScreen(nil)
    }

    private func exitFullScreen() {
        guard let window = NSApp.keyWindow else { return }
        isFullScreen = false
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    // MARK: - Vital Controls Bar

    private var vitalControlsBar: some View {
        ZStack {
            // Left-aligned controls
            HStack(spacing: 12) {
                // Start TC
                startTCControl

                // Duration
                durationControl

                // FPS
                fpsControl

                Spacer()
            }

            // Center-aligned transport controls
            HStack {
                transportControls
            }

            // Right-aligned controls
            HStack(spacing: 12) {
                Spacer()

                // Zoom controls
                zoomControls

                // Full screen button
                Button(action: { enterFullScreen() }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Enter Full Screen")

                // Settings button
                Button(action: { showSettings = true }) {
                    Iconoir.settings.asImage
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, alphaValue: 0.8)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }

    @State private var editingStartTCText = ""
    @State private var editingDurationText = ""
    @State private var isHoveringStartTC = false
    @State private var isHoveringDuration = false
    @FocusState private var isStartTCFocused: Bool
    @FocusState private var isDurationFocused: Bool

    private var startTCControl: some View {
        HStack(spacing: 4) {
            Text("Start TC:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            TextField("00:00:00:00", text: $editingStartTCText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 85)
                .focused($isStartTCFocused)
                .onChange(of: editingStartTCText) { _, newValue in
                    let formatted = formatTimecodeInput(newValue)
                    if formatted != newValue {
                        editingStartTCText = formatted
                    }
                }
                .onSubmit {
                    applyStartTimecode()
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(startTCBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isStartTCFocused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .onHover { hovering in
            isHoveringStartTC = hovering
        }
        .onChange(of: isStartTCFocused) { wasFocused, isFocused in
            // Reset to stored value when focus is lost without pressing Enter
            if wasFocused && !isFocused {
                editingStartTCText = timelineManager.timeline.config.startTimecode.stringValue()
            }
        }
        .onAppear {
            editingStartTCText = timelineManager.timeline.config.startTimecode.stringValue()
            // Ensure field is not focused on appear
            DispatchQueue.main.async {
                isStartTCFocused = false
            }
        }
    }

    private var startTCBackground: Color {
        if isStartTCFocused {
            return Color.clear
        } else if isHoveringStartTC {
            return Color.white.opacity(0.1)
        } else {
            return Color(nsColor: .controlBackgroundColor)
        }
    }

    private var durationControl: some View {
        HStack(spacing: 4) {
            Text("Duration:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            TextField("00:00:00:00", text: $editingDurationText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 85)
                .focused($isDurationFocused)
                .onChange(of: editingDurationText) { _, newValue in
                    let formatted = formatTimecodeInput(newValue)
                    if formatted != newValue {
                        editingDurationText = formatted
                    }
                }
                .onSubmit {
                    applyDuration()
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(durationBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isDurationFocused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .onHover { hovering in
            isHoveringDuration = hovering
        }
        .onChange(of: isDurationFocused) { wasFocused, isFocused in
            // Reset to stored value when focus is lost without pressing Enter
            if wasFocused && !isFocused {
                editingDurationText = durationTimecodeString
            }
        }
        .onAppear {
            editingDurationText = durationTimecodeString
        }
    }

    private var durationBackground: Color {
        if isDurationFocused {
            return Color.clear
        } else if isHoveringDuration {
            return Color.white.opacity(0.1)
        } else {
            return Color(nsColor: .controlBackgroundColor)
        }
    }

    private var fpsControl: some View {
        HStack(spacing: 4) {
            Text("FPS:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            Text(frameRateDisplayName(timelineManager.timeline.config.frameRate))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(minWidth: 45)
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .help("Frame rate is set by the video file")
    }

    private var durationTimecodeString: String {
        let durationTC = Timecode(.frames(timelineManager.timeline.config.durationFrames), at: timelineManager.timeline.config.frameRate, by: .clamping)
        return durationTC.stringValue()
    }

    private var transportControls: some View {
        HStack(spacing: 8) {
            Button(action: { playbackEngine.stepBackward() }) {
                Iconoir.skipPrev.asImage
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .disabled(!playbackEngine.hasContent)

            Button(action: { playbackEngine.togglePlayback() }) {
                (playbackEngine.isPlaying ? Iconoir.pauseSolid.asImage : Iconoir.playSolid.asImage)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(!playbackEngine.hasContent)
            .keyboardShortcut(.space, modifiers: [])

            Button(action: { playbackEngine.stepForward() }) {
                Iconoir.skipNext.asImage
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .disabled(!playbackEngine.hasContent)

            Button(action: { playbackEngine.stop() }) {
                Iconoir.square.asImage
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .disabled(!playbackEngine.hasContent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    private let minZoom: CGFloat = 1.0
    private let maxZoom: CGFloat = 10.0

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button(action: { zoomOut() }) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .disabled(timelineZoomLevel <= minZoom)

            Slider(value: $timelineZoomLevel, in: minZoom...maxZoom)
                .frame(width: 80)
                .controlSize(.mini)
                .onTapGesture(count: 2) { resetZoom() }

            Button(action: { zoomIn() }) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .disabled(timelineZoomLevel >= maxZoom)
        }
    }

    private func zoomIn() {
        withAnimation(.easeInOut(duration: 0.2)) {
            timelineZoomLevel = min(maxZoom, timelineZoomLevel * 1.5)
        }
    }

    private func zoomOut() {
        withAnimation(.easeInOut(duration: 0.2)) {
            timelineZoomLevel = max(minZoom, timelineZoomLevel / 1.5)
        }
    }

    private func resetZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            timelineZoomLevel = 1.0
        }
    }

    private func cancelTimecodeEditing() {
        // Reset values and unfocus
        if isStartTCFocused {
            editingStartTCText = timelineManager.timeline.config.startTimecode.stringValue()
            isStartTCFocused = false
        }
        if isDurationFocused {
            editingDurationText = durationTimecodeString
            isDurationFocused = false
        }
    }

    private func formatTimecodeInput(_ input: String) -> String {
        let digits = input.filter { $0.isNumber }
        let limited = String(digits.prefix(8))
        var result = ""
        for (index, char) in limited.enumerated() {
            if index > 0 && index % 2 == 0 {
                result += ":"
            }
            result.append(char)
        }
        return result
    }

    private func applyStartTimecode() {
        // Apply the new value BEFORE unfocusing (so onChange reset uses updated value)
        if let newTC = parseTimecode(editingStartTCText) {
            timelineManager.setTimelineBounds(start: newTC, end: timelineManager.timeline.config.endTimecode)
            editingStartTCText = newTC.stringValue()
        } else {
            editingStartTCText = timelineManager.timeline.config.startTimecode.stringValue()
        }
        isStartTCFocused = false
    }

    private func applyDuration() {
        // Apply the new value BEFORE unfocusing (so onChange reset uses updated value)
        if let durationTC = parseTimecode(editingDurationText) {
            let durationFrames = durationTC.frameCount.wholeFrames
            let newEndFrames = timelineManager.timeline.config.startTimecode.frameCount.wholeFrames + durationFrames
            let newEnd = Timecode(.frames(newEndFrames), at: timelineManager.timeline.config.frameRate, by: .clamping)
            timelineManager.setTimelineBounds(start: timelineManager.timeline.config.startTimecode, end: newEnd)
            editingDurationText = durationTimecodeString
        } else {
            editingDurationText = durationTimecodeString
        }
        isDurationFocused = false
    }

    private func parseTimecode(_ string: String) -> Timecode? {
        let digits = string.filter { $0.isNumber }
        let padded = String(repeating: "0", count: max(0, 8 - digits.count)) + digits
        let trimmed = String(padded.suffix(8))
        guard trimmed.count == 8 else { return nil }

        let h = Int(trimmed.prefix(2)) ?? 0
        let m = Int(trimmed.dropFirst(2).prefix(2)) ?? 0
        let s = Int(trimmed.dropFirst(4).prefix(2)) ?? 0
        let f = Int(trimmed.dropFirst(6).prefix(2)) ?? 0

        return Timecode(
            .components(h: h, m: m, s: s, f: f),
            at: timelineManager.timeline.config.frameRate,
            by: .clamping
        )
    }

    // MARK: - Timeline Accordion

    private let timelineCollapsedHeight: CGFloat = 32
    private let timelineExpandedHeight: CGFloat = 180

    private var timelineAccordion: some View {
        VStack(spacing: 0) {
            // Header bar
            timelineAccordionHeader

            // Content (only when expanded)
            if isTimelineExpanded {
                timelineContent
            }
        }
        .frame(height: isTimelineExpanded ? timelineExpandedHeight : timelineCollapsedHeight, alignment: .top)
        .clipped()
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, alphaValue: 0.8)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }

    private var timelineAccordionHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: isTimelineExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 12)

            Iconoir.videoCamera.asImage
                .frame(width: 14, height: 14)
                .foregroundColor(.secondary)

            Text("Timeline")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)

            Spacer()
        }
        .frame(height: 32)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            isTimelineExpanded.toggle()
        }
    }

    private var timelineContent: some View {
        MultiTrackTimelineView(
            timelineManager: timelineManager,
            playbackEngine: playbackEngine,
            waveformCache: waveformCache,
            audioOutputManager: audioManager,
            thumbnails: videoThumbnails,
            onDropVideoMedia: handleVideoDropOnTimeline,
            onDropAudioMedia: handleAudioDropOnTimeline,
            onSeek: { frame in
                playbackEngine.seekToFrame(frame)
            },
            onSettingsPressed: { showSettings = true },
            showHeader: false,
            zoomLevel: $timelineZoomLevel
        )
    }

    // MARK: - Save Operations

    private func saveProject() {
        if projectDocument.fileURL != nil {
            do {
                try projectDocument.save()
            } catch {
                loadError = error.localizedDescription
                showErrorAlert = true
            }
        } else {
            saveProjectAs()
        }
    }

    private func saveProjectAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.projectorProject]
        panel.nameFieldStringValue = "Untitled.projector"
        panel.title = "Save Project"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try projectDocument.save(to: url)
            } catch {
                loadError = error.localizedDescription
                showErrorAlert = true
            }
        }
    }

    private func showOpenProjectPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.projectorProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open Project"

        if panel.runModal() == .OK, let url = panel.url {
            openProject(from: url)
        }
    }

    private func openProject(from url: URL) {
        do {
            try projectDocument.load(from: url)

            // Restore timeline and media library
            timelineManager.timeline = projectDocument.timeline
            mediaLibrary.load(items: projectDocument.mediaLibrary)

            // Sync to playback engine
            syncTimelineToPlaybackEngine()

            // Check for missing files - if any are found, don't load reels yet
            // (the alert handlers will call loadProjectReels when done)
            if !checkForMissingFiles() {
                // No missing files, load reels immediately
                loadProjectReels()
            }

            NSLog(">>> openProject: loaded timeline with \(projectDocument.timeline.videoReels.count) reels")
        } catch {
            loadError = error.localizedDescription
            showErrorAlert = true
        }
    }

    /// Load the video reels after project is opened (and missing files resolved)
    private func loadProjectReels() {
        if let firstReel = timelineManager.timeline.sortedVideoReels.first {
            Task {
                do {
                    try await playbackEngine.loadReel(firstReel)

                    // Generate thumbnails for all reels
                    for reel in timelineManager.timeline.videoReels {
                        await generateThumbnail(for: reel)
                    }
                } catch {
                    loadError = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }

    // MARK: - Missing File Handling

    /// Check for missing files and show alert if any are found
    /// Returns true if missing files were found (and alert will be shown)
    @discardableResult
    private func checkForMissingFiles() -> Bool {
        var missing: [MissingFileInfo] = []

        // Check media library items
        for item in mediaLibrary.items {
            if !FileManager.default.fileExists(atPath: item.url.path) {
                missing.append(MissingFileInfo(
                    id: item.id,
                    originalPath: item.url.path,
                    type: .mediaItem
                ))
            }
        }

        // Check video reels
        for reel in timelineManager.timeline.videoReels {
            if !FileManager.default.fileExists(atPath: reel.sourceURL.path) {
                missing.append(MissingFileInfo(
                    id: reel.id,
                    originalPath: reel.sourceURL.path,
                    type: .videoReel
                ))
            }
        }

        // Check audio clips
        for lane in timelineManager.timeline.audioLanes {
            for clip in lane.clips {
                if !FileManager.default.fileExists(atPath: clip.sourceURL.path) {
                    missing.append(MissingFileInfo(
                        id: clip.id,
                        originalPath: clip.sourceURL.path,
                        type: .audioClip(laneId: lane.id)
                    ))
                }
            }
        }

        if !missing.isEmpty {
            missingFiles = missing
            currentMissingFileIndex = 0
            showMissingFilesAlert = true
            return true
        }
        return false
    }

    private func locateMissingFile() {
        guard currentMissingFileIndex < missingFiles.count else { return }
        let info = missingFiles[currentMissingFileIndex]

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Locate Missing File"
        panel.message = "Please locate: \(URL(fileURLWithPath: info.originalPath).lastPathComponent)"

        if panel.runModal() == .OK, let newURL = panel.url {
            // Update the reference
            switch info.type {
            case .mediaItem:
                mediaLibrary.updateItemURL(id: info.id, newURL: newURL)
            case .videoReel:
                timelineManager.updateVideoReelURL(id: info.id, newURL: newURL)
            case .audioClip(let laneId):
                timelineManager.updateAudioClipURL(clipId: info.id, inLane: laneId, newURL: newURL)
            }
            projectDocument.markDirty()
        }

        // Move to next missing file
        currentMissingFileIndex += 1
        if currentMissingFileIndex < missingFiles.count {
            showMissingFilesAlert = true
        } else {
            // All missing files handled, now load reels
            missingFiles = []
            loadProjectReels()
        }
    }

    private func skipMissingFile() {
        guard currentMissingFileIndex < missingFiles.count else { return }
        let info = missingFiles[currentMissingFileIndex]

        // Remove the missing item
        switch info.type {
        case .mediaItem:
            mediaLibrary.removeItem(id: info.id)
        case .videoReel:
            timelineManager.removeVideoReel(id: info.id)
        case .audioClip(let laneId):
            timelineManager.removeAudioClip(clipId: info.id, fromLane: laneId)
        }
        projectDocument.markDirty()

        // Move to next missing file
        currentMissingFileIndex += 1
        if currentMissingFileIndex < missingFiles.count {
            showMissingFilesAlert = true
        } else {
            // All missing files handled, now load reels
            missingFiles = []
            loadProjectReels()
        }
    }

    private func skipAllMissingFiles() {
        // Remove all remaining missing items
        for i in currentMissingFileIndex..<missingFiles.count {
            let info = missingFiles[i]
            switch info.type {
            case .mediaItem:
                mediaLibrary.removeItem(id: info.id)
            case .videoReel:
                timelineManager.removeVideoReel(id: info.id)
            case .audioClip(let laneId):
                timelineManager.removeAudioClip(clipId: info.id, fromLane: laneId)
            }
        }
        projectDocument.markDirty()
        missingFiles = []
        // All missing files handled, now load reels
        loadProjectReels()
    }

    // MARK: - Setup

    private func setupMIDICallbacks() {
        let engine = playbackEngine

        // Handle MTC timecode changes for video sync
        midiManager.onTimecodeChanged = { timecode in
            Task { @MainActor in
                // Calculate drift from current position
                let currentSeconds = engine.currentTime
                let mtcSeconds = Double(timecode.frameCount.wholeFrames) / engine.frameRate.fps
                let driftFrames = abs(currentSeconds - mtcSeconds) * engine.frameRate.fps

                // Re-sync if drift exceeds threshold (handles both playback drift and scrubbing)
                if driftFrames > Double(AppSettings.shared.syncDriftThreshold) {
                    print("MTC sync: drift=\(Int(driftFrames)) frames, seeking to \(timecode.stringValue())")
                    engine.seekToMTC(timecode)
                }
            }
        }

        // Handle MMC transport commands
        midiManager.onMMCCommand = { command in
            guard AppSettings.shared.respondToMMC else { return }
            Task { @MainActor in
                switch command {
                case .stop:
                    engine.stop()
                case .play, .deferredPlay:
                    engine.play()
                case .pause:
                    engine.pause()
                case .locate(let timecode):
                    engine.seekToTimecode(timecode)
                case .fastForward, .rewind:
                    break
                }
            }
        }

        // Restore MIDI input selection
        if !settings.selectedMIDIInput.isEmpty {
            midiManager.selectedInputName = settings.selectedMIDIInput
        }
    }

    private func setupAudioCallback() {
        let engine = playbackEngine

        audioManager.onDeviceChanged = { deviceUID in
            Task { @MainActor in
                engine.setAudioOutputDevice(deviceUID)
            }
        }

        // Restore audio device selection
        if !settings.selectedAudioOutput.isEmpty {
            audioManager.selectedDeviceUID = settings.selectedAudioOutput
        }
    }

    private func setupTimelineCallbacks() {
        // Sync timeline changes to playback engine and document
        let engine = playbackEngine
        let document = projectDocument
        let manager = timelineManager
        let library = mediaLibrary

        timelineManager.onTimelineChanged = {
            engine.timeline = manager.timeline
            document.timeline = manager.timeline
        }

        // Sync media library changes to document
        mediaLibrary.onLibraryChanged = {
            document.mediaLibrary = library.exportItems()
        }
    }

    private func restoreSettings() {
        // Apply audio device
        if !settings.selectedAudioOutput.isEmpty {
            playbackEngine.setAudioOutputDevice(settings.selectedAudioOutput)
        }
    }

    /// Sync timeline manager's timeline to project document
    private func syncTimelineToDocument() {
        projectDocument.timeline = timelineManager.timeline
    }

    /// Sync media library to project document
    private func syncMediaLibraryToDocument() {
        projectDocument.mediaLibrary = mediaLibrary.exportItems()
    }

    // MARK: - File Handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }

            Task { @MainActor in
                // Import to media library and add to timeline
                guard ProjectMediaLibrary.isSupported(url: url),
                      let mediaType = ProjectMediaLibrary.mediaType(for: url) else {
                    return
                }

                switch mediaType {
                case .video:
                    await self.addVideoToTimeline(url: url)
                case .audio:
                    // Ensure we have at least one audio lane
                    if self.timelineManager.timeline.audioLanes.isEmpty {
                        _ = self.timelineManager.addAudioLane()
                    }
                    if let lane = self.timelineManager.timeline.audioLanes.first {
                        await self.addAudioToTimeline(url: url, laneId: lane.id)
                    }
                }
            }
        }

        return true
    }

    // MARK: - Timeline Media Handling

    /// Handle video files dropped on the timeline video track
    private func handleVideoDropOnTimeline(_ urls: [URL]) {
        Task {
            for url in urls {
                await addVideoToTimeline(url: url)
            }
        }
    }

    /// Handle audio files dropped on a specific audio lane
    private func handleAudioDropOnTimeline(_ laneIndex: Int, _ urls: [URL]) {
        Task {
            // Ensure the lane exists
            while timelineManager.timeline.audioLanes.count <= laneIndex {
                _ = timelineManager.addAudioLane()
            }

            let lane = timelineManager.timeline.audioLanes[laneIndex]

            for url in urls {
                await addAudioToTimeline(url: url, laneId: lane.id)
            }
        }
    }

    /// Handle media item double-clicked to add to video track
    private func handleAddToVideoTrack(_ item: MediaItem) {
        Task {
            await addVideoToTimeline(url: item.url)
        }
    }

    /// Handle media item double-clicked to add to audio lane
    private func handleAddToAudioLane(_ item: MediaItem, _ laneIndex: Int) {
        Task {
            // Ensure we have at least one audio lane
            if timelineManager.timeline.audioLanes.isEmpty {
                _ = timelineManager.addAudioLane()
            }

            // Clamp to valid lane index
            let validIndex = min(laneIndex, timelineManager.timeline.audioLanes.count - 1)
            let lane = timelineManager.timeline.audioLanes[validIndex]

            await addAudioToTimeline(url: item.url, laneId: lane.id)
        }
    }

    /// Add a video file to the timeline
    private func addVideoToTimeline(url: URL) async {
        isLoadingMedia = true

        do {
            // Detect video frame rate first
            let asset = AVAsset(url: url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw NSError(domain: "Projector", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
            }

            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            let videoFPS = closestTimecodeFrameRate(to: Double(nominalFrameRate))

            // Check for FPS conflict
            let hasExistingReels = !timelineManager.timeline.videoReels.isEmpty
            let projectFPS = timelineManager.timeline.config.frameRate

            if hasExistingReels && videoFPS != projectFPS {
                // FPS conflict - show dialog
                isLoadingMedia = false
                pendingVideoURL = url
                pendingVideoFPS = videoFPS
                showFPSConflictAlert = true
                return
            }

            // If first video, set project FPS to match
            if !hasExistingReels {
                var config = timelineManager.timeline.config
                config.frameRate = videoFPS
                config.startTimecode = Timecode(.frames(config.startTimecode.frameCount.wholeFrames), at: videoFPS, by: .clamping)
                config.endTimecode = Timecode(.frames(config.endTimecode.frameCount.wholeFrames), at: videoFPS, by: .clamping)
                timelineManager.updateConfig(config)
            }

            // Actually add the video
            await addVideoToTimelineUnchecked(url: url)

        } catch {
            isLoadingMedia = false
            loadError = error.localizedDescription
            showErrorAlert = true
        }
    }

    /// Add video without FPS checking (internal use after conflict resolution)
    private func addVideoToTimelineUnchecked(url: URL) async {
        do {
            // Import to media library first (if not already there)
            _ = try await mediaLibrary.importFile(from: url)

            // Calculate where to place the new reel (at end of existing content)
            let placementFrame = timelineManager.timeline.videoReels.map { $0.timelineEndFrame }.max() ?? 0

            // Add the video reel
            let reel = try await timelineManager.addVideoReel(from: url, at: placementFrame)

            // Generate thumbnail
            await generateThumbnail(for: reel)

            // Auto-extract audio track from video and add to audio lane
            await extractAudioFromVideo(reel: reel)

            // Sync timeline to playback engine
            syncTimelineToPlaybackEngine()

            // If this is the first reel, load it
            if timelineManager.timeline.videoReels.count == 1 {
                try await playbackEngine.loadReel(reel)
            }

            isLoadingMedia = false
        } catch {
            isLoadingMedia = false
            loadError = error.localizedDescription
            showErrorAlert = true
        }
    }

    /// Handle user choosing to change project FPS (removes existing reels)
    private func handleFPSConflictChangeProject() {
        guard let url = pendingVideoURL, let fps = pendingVideoFPS else { return }

        // Remove all existing video reels
        for reel in timelineManager.timeline.videoReels {
            timelineManager.removeVideoReel(id: reel.id)
            videoThumbnails.removeValue(forKey: reel.id)
        }

        // Update project FPS
        var config = timelineManager.timeline.config
        config.frameRate = fps
        config.startTimecode = Timecode(.frames(config.startTimecode.frameCount.wholeFrames), at: fps, by: .clamping)
        config.endTimecode = Timecode(.frames(config.endTimecode.frameCount.wholeFrames), at: fps, by: .clamping)
        timelineManager.updateConfig(config)

        // Clear pending state
        pendingVideoURL = nil
        pendingVideoFPS = nil

        // Now add the video
        Task {
            await addVideoToTimelineUnchecked(url: url)
        }
    }

    /// Convert video frame rate to closest TimecodeFrameRate
    private func closestTimecodeFrameRate(to fps: Double) -> TimecodeFrameRate {
        // Common frame rates and their nominal values
        let rates: [(TimecodeFrameRate, Double)] = [
            (.fps23_976, 23.976),
            (.fps24, 24.0),
            (.fps25, 25.0),
            (.fps29_97, 29.97),
            (.fps30, 30.0),
        ]

        var closest = TimecodeFrameRate.fps24
        var minDiff = Double.infinity

        for (rate, nominal) in rates {
            let diff = abs(fps - nominal)
            if diff < minDiff {
                minDiff = diff
                closest = rate
            }
        }

        return closest
    }

    /// Display name for a frame rate
    private func frameRateDisplayName(_ rate: TimecodeFrameRate) -> String {
        switch rate {
        case .fps23_976: return "23.976"
        case .fps24: return "24"
        case .fps25: return "25"
        case .fps29_97: return "29.97"
        case .fps29_97d: return "29.97 DF"
        case .fps30: return "30"
        default: return "\(rate.fps)"
        }
    }

    /// Extract audio track from video reel and add to audio lane
    private func extractAudioFromVideo(reel: VideoReel) async {
        // Check if video has audio tracks
        let asset = AVAsset(url: reel.sourceURL)
        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else { return }

            // Ensure we have at least one audio lane
            let lane: AudioLane
            if timelineManager.timeline.audioLanes.isEmpty {
                lane = timelineManager.addAudioLane(name: "Audio")
            } else {
                lane = timelineManager.timeline.audioLanes[0]
            }

            // Extract the first audio track
            _ = try await timelineManager.extractAudioFromReel(reel.id, trackIndex: 0, toLane: lane.id)
        } catch {
            NSLog(">>> Failed to extract audio from video: \(error)")
        }
    }

    /// Add an audio file to the timeline
    private func addAudioToTimeline(url: URL, laneId: UUID) async {
        do {
            // Import to media library first (if not already there)
            _ = try await mediaLibrary.importFile(from: url)

            // Calculate where to place the new clip (at end of existing clips in lane)
            let lane = timelineManager.timeline.audioLanes.first { $0.id == laneId }
            let placementFrame = lane?.clips.map { $0.timelineEndFrame }.max() ?? 0

            // Add the audio clip
            _ = try await timelineManager.addAudioClip(from: url, toLane: laneId, at: placementFrame)

            // Sync timeline to playback engine
            syncTimelineToPlaybackEngine()
        } catch {
            loadError = error.localizedDescription
            showErrorAlert = true
        }
    }

    /// Generate and cache thumbnail strip for a video reel
    /// Uses batch generation for speed - approximately 1 thumbnail per second
    private func generateThumbnail(for reel: VideoReel) async {
        let asset = AVAsset(url: reel.sourceURL)

        // Get video duration
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            NSLog(">>> ContentView: Failed to load asset duration: \(error)")
            return
        }

        let durationSeconds = duration.seconds
        guard durationSeconds > 0 else { return }

        // Generate approximately 1 thumbnail per second for smooth coverage
        // Cap at 1000 thumbnails max to prevent memory issues
        let maxThumbnails = 1000
        let targetInterval = 1.0
        let actualInterval = max(targetInterval, durationSeconds / Double(maxThumbnails))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 80, height: 45)  // Small for filmstrip
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        // Build times array
        var times: [NSValue] = []
        var currentTime: Double = 0.0
        while currentTime < durationSeconds {
            times.append(NSValue(time: CMTime(seconds: currentTime, preferredTimescale: 600)))
            currentTime += actualInterval
        }

        let startTime = Date()
        let totalCount = times.count
        NSLog(">>> generateThumbnail: generating \(totalCount) thumbnails for \(durationSeconds)s video")

        // Use actor to safely collect thumbnails from async callbacks
        let collector = ThumbnailCollector(sourceDuration: durationSeconds, interval: actualInterval)

        // Use batch generation - much faster than sequential
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var completedCount = 0
            let lock = NSLock()

            generator.generateCGImagesAsynchronously(forTimes: times) { requestedTime, cgImage, actualTime, result, error in
                if let cgImage = cgImage {
                    // Convert to JPEG (much smaller/faster than TIFF)
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    if let tiffData = nsImage.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
                        collector.add(time: requestedTime.seconds, data: jpegData)
                    }
                }

                // Track completion
                lock.lock()
                completedCount += 1
                let done = completedCount >= totalCount
                lock.unlock()

                if done {
                    Task { @MainActor in
                        let elapsed = Date().timeIntervalSince(startTime)
                        let strip = collector.buildStrip()
                        NSLog(">>> generateThumbnail: completed \(strip.count) thumbnails in \(String(format: "%.2f", elapsed))s")

                        if strip.count > 0 {
                            self.videoThumbnails[reel.id] = strip
                        }
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Sync the timeline manager's timeline to the playback engine
    private func syncTimelineToPlaybackEngine() {
        playbackEngine.timeline = timelineManager.timeline
    }

    /// Called from menu File > Open Media
    func openMediaFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .movie,
            .mpeg4Movie,
            .quickTimeMovie,
            .audio,
            .mp3,
            .wav,
            UTType(filenameExtension: "mov")!,
            UTType(filenameExtension: "mp4")!,
            UTType(filenameExtension: "m4v")!,
            UTType(filenameExtension: "aif")!,
            UTType(filenameExtension: "aiff")!
        ]

        panel.begin { response in
            if response == .OK {
                Task { @MainActor in
                    for url in panel.urls {
                        if let mediaType = ProjectMediaLibrary.mediaType(for: url) {
                            switch mediaType {
                            case .video:
                                await self.addVideoToTimeline(url: url)
                            case .audio:
                                if self.timelineManager.timeline.audioLanes.isEmpty {
                                    _ = self.timelineManager.addAudioLane()
                                }
                                if let lane = self.timelineManager.timeline.audioLanes.first {
                                    await self.addAudioToTimeline(url: url, laneId: lane.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
