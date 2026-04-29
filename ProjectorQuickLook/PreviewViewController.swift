//
//  PreviewViewController.swift
//  ProjectorQuickLook
//
//  QuickLook preview for .projector project files.
//  Displays project metadata in a clean preview panel.
//

import Cocoa
import Quartz

class PreviewViewController: NSViewController, QLPreviewingController {

    // MARK: - Preview Data Model

    /// Minimal structures for parsing project.json
    private struct ProjectData: Codable {
        let version: Int
        let timeline: TimelineData
        let mediaLibrary: [MediaItemData]?
    }

    private struct TimelineData: Codable {
        let config: TimelineConfigData
        let videoReels: [VideoReelData]
        let audioLanes: [AudioLaneData]
    }

    private struct TimelineConfigData: Codable {
        let startTimecode: TimecodeData?
        let endTimecode: TimecodeData?
        let frameRate: FrameRateData?
    }

    private struct TimecodeData: Codable {
        let hours: Int?
        let minutes: Int?
        let seconds: Int?
        let frames: Int?
    }

    private struct FrameRateData: Codable {
        let rate: Double?
        let stringValue: String?
    }

    private struct VideoReelData: Codable {
        let displayName: String?
        let durationFrames: Int?
    }

    private struct AudioLaneData: Codable {
        let name: String?
        let clips: [AudioClipData]
    }

    private struct AudioClipData: Codable {
        let displayName: String?
    }

    private struct MediaItemData: Codable {
        let type: String?
    }

    // MARK: - UI Elements

    private let containerStack = NSStackView()

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Configure the main stack
        containerStack.orientation = .vertical
        containerStack.alignment = .centerX
        containerStack.spacing = 12
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(containerStack)

        NSLayoutConstraint.activate([
            containerStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            containerStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            containerStack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, multiplier: 0.9),
            containerStack.widthAnchor.constraint(lessThanOrEqualToConstant: 400)
        ])

        self.view = container
    }

    func preparePreviewOfFile(at url: URL) async throws {
        // Parse the project file
        let projectDataURL = url.appendingPathComponent("project.json")

        guard FileManager.default.fileExists(atPath: projectDataURL.path) else {
            await showFallbackIcon()
            return
        }

        do {
            let data = try Data(contentsOf: projectDataURL)
            let project = try JSONDecoder().decode(ProjectData.self, from: data)

            await MainActor.run {
                buildPreviewUI(for: project, projectName: url.deletingPathExtension().lastPathComponent)
            }
        } catch {
            await showFallbackIcon()
        }
    }

    // MARK: - UI Building

    @MainActor
    private func buildPreviewUI(for project: ProjectData, projectName: String) {
        // Clear existing content
        containerStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Project icon
        if let iconImage = Bundle.main.image(forResource: "DocumentIcon") {
            let imageView = NSImageView(image: iconImage)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.widthAnchor.constraint(equalToConstant: 80).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: 80).isActive = true
            containerStack.addArrangedSubview(imageView)
        }

        // Project name
        let nameLabel = createLabel(projectName, style: .title)
        containerStack.addArrangedSubview(nameLabel)

        // Add some spacing
        containerStack.addArrangedSubview(createSpacer(8))

        // Stats container
        let statsStack = NSStackView()
        statsStack.orientation = .vertical
        statsStack.alignment = .leading
        statsStack.spacing = 6

        // Video reels
        let videoCount = project.timeline.videoReels.count
        statsStack.addArrangedSubview(createStatRow(
            icon: "film",
            text: "\(videoCount) video reel\(videoCount == 1 ? "" : "s")"
        ))

        // Audio lanes and clips
        let laneCount = project.timeline.audioLanes.count
        let clipCount = project.timeline.audioLanes.reduce(0) { $0 + $1.clips.count }
        statsStack.addArrangedSubview(createStatRow(
            icon: "speaker.wave.3",
            text: "\(laneCount) audio lane\(laneCount == 1 ? "" : "s"), \(clipCount) clip\(clipCount == 1 ? "" : "s")"
        ))

        // Frame rate
        if let frameRate = project.timeline.config.frameRate {
            let rateString = frameRate.stringValue ?? String(format: "%.2f", frameRate.rate ?? 0)
            statsStack.addArrangedSubview(createStatRow(
                icon: "clock",
                text: "\(rateString) fps"
            ))
        }

        // Duration from end timecode
        if let end = project.timeline.config.endTimecode {
            let timecodeString = formatTimecode(end)
            if !timecodeString.isEmpty && timecodeString != "00:00:00:00" {
                statsStack.addArrangedSubview(createStatRow(
                    icon: "timer",
                    text: "Duration: \(timecodeString)"
                ))
            }
        }

        // Media library count
        if let mediaCount = project.mediaLibrary?.count, mediaCount > 0 {
            statsStack.addArrangedSubview(createStatRow(
                icon: "folder",
                text: "\(mediaCount) media file\(mediaCount == 1 ? "" : "s") in library"
            ))
        }

        containerStack.addArrangedSubview(statsStack)

        // Version info
        containerStack.addArrangedSubview(createSpacer(12))
        let versionLabel = createLabel("Projector v\(project.version) project", style: .caption)
        versionLabel.textColor = .tertiaryLabelColor
        containerStack.addArrangedSubview(versionLabel)
    }

    @MainActor
    private func createLabel(_ text: String, style: LabelStyle) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle

        switch style {
        case .title:
            label.font = .systemFont(ofSize: 16, weight: .semibold)
            label.textColor = .labelColor
        case .body:
            label.font = .systemFont(ofSize: 13, weight: .regular)
            label.textColor = .secondaryLabelColor
        case .caption:
            label.font = .systemFont(ofSize: 11, weight: .regular)
            label.textColor = .tertiaryLabelColor
        }

        return label
    }

    private enum LabelStyle {
        case title, body, caption
    }

    @MainActor
    private func createStatRow(icon: String, text: String) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8

        let iconView = NSImageView()
        if let sfSymbol = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            iconView.image = sfSymbol
            iconView.contentTintColor = .secondaryLabelColor
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 16).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let textLabel = NSTextField(labelWithString: text)
        textLabel.font = .systemFont(ofSize: 12, weight: .regular)
        textLabel.textColor = .secondaryLabelColor

        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(textLabel)

        return stack
    }

    @MainActor
    private func createSpacer(_ height: CGFloat) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: height).isActive = true
        return spacer
    }

    private func formatTimecode(_ tc: TimecodeData) -> String {
        let h = tc.hours ?? 0
        let m = tc.minutes ?? 0
        let s = tc.seconds ?? 0
        let f = tc.frames ?? 0
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, f)
    }

    @MainActor
    private func showFallbackIcon() async {
        containerStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if let iconImage = Bundle.main.image(forResource: "DocumentIcon") {
            let imageView = NSImageView(image: iconImage)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.widthAnchor.constraint(equalToConstant: 128).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: 128).isActive = true
            containerStack.addArrangedSubview(imageView)
        }

        let label = createLabel("Projector Project", style: .body)
        containerStack.addArrangedSubview(label)
    }
}
