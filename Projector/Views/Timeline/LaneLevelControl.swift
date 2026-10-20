import SwiftUI
import AppKit

/// The lane level knob in a lane header.
///
/// A small rotary control: an arc track with a value arc and an indicator line,
/// sweeping 270 degrees from the bottom stop (silence) to ``LaneLevel/maxDB``,
/// with a notch at 0 dB. The scale is linear in decibels; see ``LaneLevel``.
///
/// A vertical drag turns it (up is louder; Option or Shift for fine control).
/// The level is applied live through `onChange`, and `onCommit` fires once per
/// gesture with the level it started from, so the caller registers a single
/// undo step. A click without movement changes nothing; double-click resets to
/// 0 dB as its own step.
struct LaneLevelControl: View {
    /// The lane's level as stored: linear gain, `1.0` at 0 dB.
    let level: Float

    /// Applies a level immediately. Called continuously during a drag.
    let onChange: (Float) -> Void

    /// Called once when a change ends, with the level it began from and the
    /// level it ended on.
    let onCommit: (Float, Float) -> Void

    private enum Knob {
        /// Drag distance per decibel. The whole 72 dB range takes 108pt.
        static let pointsPerDB: CGFloat = 1.5
        /// Fine adjustment (Option or Shift) divides the sensitivity by this.
        static let fineDivisor: CGFloat = 5
        /// Smallest drag that counts as turning rather than clicking.
        static let minimumDragDistance: CGFloat = 2
        /// Keyboard and VoiceOver adjustment step.
        static let accessibilityStepDB: Float = 1

        /// Start of the sweep, in degrees clockwise from 3 o'clock (bottom left).
        static let startDegrees = 135.0
        static let sweepDegrees = 270.0
        /// Arc resolution when drawing a sweep as line segments.
        static let degreesPerSegment = 6.0

        static let lineWidth: CGFloat = 2
        static let notchLength: CGFloat = 3
        static let notchWidth: CGFloat = 1
        static let indicatorInset: CGFloat = 4
        static let indicatorWidth: CGFloat = 1.5
        static let readoutOffset: CGFloat = 4
    }

    /// The level when the current drag began, `nil` while not dragging.
    @State private var dragStartLevel: Float?

    /// The dB value the drag has accumulated, before it is stepped and clamped.
    @State private var dragDB: Float = 0

    /// Vertical translation already folded into ``dragDB``.
    @State private var dragLastY: CGFloat = 0

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .frame(width: TimelineLayout.laneKnobSize, height: TimelineLayout.laneKnobSize)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: Knob.minimumDragDistance)
                .onChanged { value in turn(to: value.translation.height) }
                .onEnded { _ in endTurn() }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { _ in resetToUnity() })
        .overlay(alignment: .leading) {
            if dragStartLevel != nil {
                Text(readout)
                    .font(Typography.monoTiny)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: TimelineLayout.laneControlCornerRadius)
                            .fill(Color.black.opacity(0.85))
                    )
                    .offset(x: TimelineLayout.laneKnobSize + Knob.readoutOffset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .help("Lane Level: \(readout) - drag to adjust, double-click to reset to 0 dB")
        .accessibilityElement()
        .accessibilityLabel("Lane Level")
        .accessibilityValue(readout)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(by: Knob.accessibilityStepDB)
            case .decrement: nudge(by: -Knob.accessibilityStepDB)
            @unknown default: break
            }
        }
    }

    private var readout: String {
        LaneLevel.readout(fromLinear: level)
    }

    // MARK: - Drawing

    private func point(center: CGPoint, radius: CGFloat, degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(cos(radians)), y: center.y + radius * CGFloat(sin(radians)))
    }

    private func arc(center: CGPoint, radius: CGFloat, from fraction: Double, to end: Double) -> Path {
        var path = Path()
        guard end > fraction else { return path }
        let startAngle = Knob.startDegrees + Knob.sweepDegrees * fraction
        let endAngle = Knob.startDegrees + Knob.sweepDegrees * end
        path.move(to: point(center: center, radius: radius, degrees: startAngle))
        var angle = startAngle + Knob.degreesPerSegment
        while angle < endAngle {
            path.addLine(to: point(center: center, radius: radius, degrees: angle))
            angle += Knob.degreesPerSegment
        }
        path.addLine(to: point(center: center, radius: radius, degrees: endAngle))
        return path
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - Knob.lineWidth / 2
        let position = LaneLevel.position(fromLinear: level)
        let stroke = StrokeStyle(lineWidth: Knob.lineWidth, lineCap: .round)

        context.stroke(arc(center: center, radius: radius, from: 0, to: 1), with: .color(AppColors.borderMedium), style: stroke)
        context.stroke(arc(center: center, radius: radius, from: 0, to: position), with: .color(.accentColor), style: stroke)

        // The 0 dB notch, drawn across the track so it reads at a glance.
        let unityDegrees = Knob.startDegrees + Knob.sweepDegrees * LaneLevel.position(fromLinear: 1)
        var notch = Path()
        notch.move(to: point(center: center, radius: radius - Knob.notchLength, degrees: unityDegrees))
        notch.addLine(to: point(center: center, radius: radius + Knob.lineWidth / 2, degrees: unityDegrees))
        context.stroke(notch, with: .color(.secondary), lineWidth: Knob.notchWidth)

        let degrees = Knob.startDegrees + Knob.sweepDegrees * position
        var indicator = Path()
        indicator.move(to: center)
        indicator.addLine(to: point(center: center, radius: radius - Knob.indicatorInset + Knob.lineWidth, degrees: degrees))
        context.stroke(indicator, with: .color(.primary), style: StrokeStyle(lineWidth: Knob.indicatorWidth, lineCap: .round))
    }

    // MARK: - Interaction

    private var isFineAdjust: Bool {
        !NSEvent.modifierFlags.isDisjoint(with: [.option, .shift])
    }

    private func turn(to translationY: CGFloat) {
        if dragStartLevel == nil {
            dragStartLevel = level
            let startDB = LaneLevel.dB(fromLinear: level)
            dragDB = startDB.isFinite ? startDB : LaneLevel.floorDB
            dragLastY = 0
        }
        let sensitivity = isFineAdjust ? Knob.pointsPerDB * Knob.fineDivisor : Knob.pointsPerDB
        // Dragging up reduces y, and up is louder.
        dragDB -= Float((translationY - dragLastY) / sensitivity)
        dragDB = min(max(dragDB, LaneLevel.floorDB), LaneLevel.maxDB)
        dragLastY = translationY

        let new = LaneLevel.linear(fromSteppedDB: dragDB)
        if new != level { onChange(new) }
    }

    private func endTurn() {
        if let start = dragStartLevel, start != level {
            onCommit(start, level)
        }
        dragStartLevel = nil
    }

    private func resetToUnity() {
        let unity = LaneLevel.linear(fromDB: LaneLevel.unityDB)
        guard level != unity else { return }
        let old = level
        onChange(unity)
        onCommit(old, unity)
    }

    /// A keyboard or VoiceOver step; each is its own undo entry.
    private func nudge(by deltaDB: Float) {
        let current = LaneLevel.dB(fromLinear: level)
        let base = current.isFinite ? current : LaneLevel.floorDB
        let new = LaneLevel.linear(fromSteppedDB: min(max(base + deltaDB, LaneLevel.floorDB), LaneLevel.maxDB))
        guard new != level else { return }
        let old = level
        onChange(new)
        onCommit(old, new)
    }
}
