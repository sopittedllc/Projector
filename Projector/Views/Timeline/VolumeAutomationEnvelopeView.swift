import AppKit
import SwiftUI

/// The volume-automation editor: an `NSView` embedded in the SwiftUI
/// timeline via `NSViewRepresentable`.
///
/// ## Why AppKit
///
/// This editor lives inside the timeline's `ScrollView`, next to a marquee
/// `DragGesture` and per-clip `DragGesture`s on the views around it. SwiftUI
/// resolves overlapping gestures through its own arbitration, which is not a
/// fit for something that needs exact hit-testing against small circular
/// targets, `NSEvent.clickCount` to tell a double-click from two single
/// clicks, and a right-click context menu that differs depending on what is
/// under the cursor. An `NSView` that returns itself from `hitTest(_:)` takes
/// mouse events directly, ahead of SwiftUI's gesture recognisers, so a node
/// drag can never be reinterpreted as a marquee selection or a lane reorder.
/// It also lets trackpad scrolling reach the enclosing `NSScrollView`
/// untouched, simply by not overriding `scrollWheel(with:)`.
struct VolumeAutomationEnvelopeView: NSViewRepresentable {
    /// The envelope to draw and edit.
    let automation: VolumeAutomation

    /// Horizontal scale: points per timeline frame.
    let pixelsPerFrame: CGFloat

    /// Timeline length, in frames. Interactive placement clamps to
    /// `0...durationFrames`.
    let durationFrames: Int

    /// The lane's colour, already converted from SwiftUI so this view has no
    /// need to touch `Color` itself.
    let laneColor: NSColor

    /// Current playhead frame, so an accessibility "add node at playhead"
    /// action and other playhead-relative behaviour has something to insert
    /// at without this view needing its own notion of transport state.
    let playheadFrame: Int

    /// Renders an absolute frame as a timecode string, for the "Set Level…"
    /// popover's read-only timecode and each node's accessibility label.
    let formatTimecode: (Int) -> String

    /// Called once, at the start of an edit gesture (a drag, a menu command),
    /// before any mutation - the call site uses this to capture undo state.
    let onBeginEdit: () -> Void

    /// Called when a mouse gesture that began with ``onBeginEdit`` is over,
    /// whether or not it changed anything. The timeline uses the pair to
    /// know a node drag is in progress: AppKit offers every mouse-down to
    /// the gesture recognizers of *ancestor* views before this view's own
    /// `mouseDown`, so the tracks area's marquee drag would otherwise start
    /// underneath a node drag. Menu commands fire begin and end together.
    let onEndEdit: () -> Void

    /// Called on every change while a drag is in progress. Drawing only: the
    /// plan's "apply on release" decision means playback must not hear this.
    let onPreview: (VolumeAutomation) -> Void

    /// Called once an edit is finished and should take effect, along with a
    /// human-readable name for the Edit menu ("Move Node", "Add Node",
    /// "Delete Node", "Reset Automation", "Set Level") - the call site uses
    /// it to name the registered undo step.
    let onCommit: (VolumeAutomation, String) -> Void

    /// Called when "Remove Automation" is chosen from the empty-space
    /// context menu - removing the envelope entirely, not just clearing its
    /// points, which is why this is a separate callback from ``onCommit``
    /// rather than a commit of an empty envelope. Bracketed by
    /// ``onBeginEdit``/``onEndEdit`` exactly like every other menu command.
    let onRemove: () -> Void

    /// Called when "Set Level…" is chosen from a node's context menu. The
    /// row uses the point's id, current gain and frame, and its rect in this
    /// view's own coordinate space, to present a popover anchored at the
    /// node. This is not itself an edit - only committing from the popover
    /// is - so it is not bracketed by ``onBeginEdit``/``onEndEdit``.
    let onSetLevel: (_ pointId: UUID, _ currentDB: Float, _ frame: Int, _ nodeRect: CGRect) -> Void

    func makeNSView(context: Context) -> VolumeAutomationEnvelopeNSView {
        let view = VolumeAutomationEnvelopeNSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: VolumeAutomationEnvelopeNSView, context: Context) {
        configure(nsView)
    }

    /// Re-assigns every input on every update, since `NSViewRepresentable`
    /// gives no way to know which ones actually changed - only whether the
    /// envelope or the horizontal scale did, which decides whether a redraw
    /// is needed at all.
    private func configure(_ view: VolumeAutomationEnvelopeNSView) {
        let scaleChanged = view.pixelsPerFrame != pixelsPerFrame || view.durationFrames != durationFrames
        let envelopeChanged = view.automation != automation
        // A reorder changes the lane's colour index without touching the envelope.
        let colorChanged = view.laneColor != laneColor

        view.automation = automation
        view.pixelsPerFrame = pixelsPerFrame
        view.durationFrames = durationFrames
        view.laneColor = laneColor
        view.playheadFrame = playheadFrame
        view.formatTimecode = formatTimecode
        view.onBeginEdit = onBeginEdit
        view.onEndEdit = onEndEdit
        view.onPreview = onPreview
        view.onCommit = onCommit
        view.onRemove = onRemove
        view.onSetLevel = onSetLevel

        if scaleChanged || envelopeChanged || colorChanged {
            view.needsDisplay = true
        }
    }
}

/// The `NSView` behind ``VolumeAutomationEnvelopeView``.
///
/// Draws a piecewise-linear-in-dB envelope and lets the user add, move,
/// rename and delete its nodes with the mouse. Coordinates are the view's own
/// bounds: x is `frame * pixelsPerFrame` (the caller lays this view out at
/// the full, unscrolled content width - see `AudioLaneView.clipOffset(for:)`
/// for the equivalent clip-coordinate convention), y maps ``VolumeAutomation``'s
/// `-60...0` dB range onto an editable band inset from the top and bottom by
/// ``TimelineLayout/automationNodeHitRadius``.
final class VolumeAutomationEnvelopeNSView: NSView {
    /// One in-progress mouse edit: a working copy of the envelope, the point
    /// being dragged, and the envelope this edit started from - captured so
    /// `mouseUp` can decide whether anything actually changed without racing
    /// against SwiftUI re-rendering ``automation`` mid-drag as ``onPreview``
    /// flows back down through the view hierarchy.
    private struct EditTransaction {
        var working: VolumeAutomation
        var draggedId: UUID
        /// Whether this drag's node was created by the same mouse-down that
        /// began the transaction, rather than an existing node picked up.
        var insertedByThisMouseDown: Bool
        let original: VolumeAutomation
    }

    /// The envelope this view draws. Set by
    /// ``VolumeAutomationEnvelopeView/configure(_:)`` on every SwiftUI
    /// update.
    var automation = VolumeAutomation()
    var pixelsPerFrame: CGFloat = 1
    var durationFrames: Int = 0
    var laneColor: NSColor = .labelColor
    var playheadFrame: Int = 0
    var formatTimecode: (Int) -> String = { "\($0)" }
    var onBeginEdit: () -> Void = {}
    var onEndEdit: () -> Void = {}
    var onPreview: (VolumeAutomation) -> Void = { _ in }
    var onCommit: (VolumeAutomation, String) -> Void = { _, _ in }
    var onRemove: () -> Void = {}
    var onSetLevel: (_ pointId: UUID, _ currentDB: Float, _ frame: Int, _ nodeRect: CGRect) -> Void = { _, _, _, _ in }

    private var activeTransaction: EditTransaction?

    /// The dragged node's mouse position on the previous ``mouseDragged(with:)``
    /// call (or the initial ``mouseDown(with:)`` that started the drag) - the
    /// anchor for Option-drag's fine control, which moves gain by a delta
    /// since the *last* event rather than mapping the cursor's absolute
    /// position. `nil` outside a drag.
    private var lastDragPoint: NSPoint?

    /// The id of the node inserted by the previous mouse-down, so a
    /// following double-click can tell "the node I am about to double-click
    /// is the one this same gesture just created" from "this node already
    /// existed" (plan §5.4's double-click rule).
    private var lastInsertedId: UUID?

    /// The node named in a still-open context menu.
    private var pendingMenuNodeId: UUID?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerDraggedTypes()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerDraggedTypes()
    }

    /// Registers the same pasteboard types the lane's own drag-capture view
    /// does (`AudioLaneDragCaptureNSView`), so a file dragged over the
    /// sub-lane is handed to *this* view rather than falling through to the
    /// parent - AppKit gives a drag to the deepest registered view under the
    /// cursor. ``draggingEntered(_:)`` and ``performDragOperation(_:)``
    /// refuse it outright.
    private func registerDraggedTypes() {
        registerForDraggedTypes([
            .fileURL,
            .URL,
            NSPasteboard.PasteboardType("com.projector.media-item"),
            NSPasteboard.PasteboardType("public.item")
        ])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Takes every mouse event itself - see the "Why AppKit" note above.
        self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Cursor

    /// One tracking area over the whole view, rebuilt whenever the bounds
    /// change, so ``mouseMoved(with:)`` can pick the cursor for whatever is
    /// under the pointer. Cursor rects would only give one cursor for the
    /// whole band; the pointer has to change when it reaches a node.
    private var cursorTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    /// The pointer says what a click will do: a finger where a click adds a
    /// node, an open hand over a node that can be picked up, a closed hand
    /// while one is held.
    private func updateCursor(at point: NSPoint) {
        if activeTransaction != nil {
            NSCursor.closedHand.set()
        } else if nodeAt(point) != nil {
            NSCursor.openHand.set()
        } else {
            NSCursor.pointingHand.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if activeTransaction == nil {
            NSCursor.arrow.set()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            // The row is being torn down mid-drag (lane removed, document
            // replaced) - drop the edit rather than committing something the
            // model underneath may no longer have.
            if activeTransaction != nil {
                activeTransaction = nil
                onEndEdit()
            }
        }
    }

    // MARK: - Drops (refused)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }

    // MARK: - Coordinate mapping

    /// Top of the editable band: 0 dB.
    private var topY: CGFloat { TimelineLayout.automationNodeHitRadius }

    /// Bottom of the editable band: -60 dB.
    private var bottomY: CGFloat {
        max(topY, bounds.height - TimelineLayout.automationNodeHitRadius)
    }

    private func xPosition(forFrame frame: Int) -> CGFloat {
        CGFloat(frame) * pixelsPerFrame
    }

    /// Nearest whole frame for a given x. Not clamped - callers that need an
    /// on-timeline frame call ``clampedFrame(_:)`` on the result.
    private func frame(forX x: CGFloat) -> Int {
        guard pixelsPerFrame > 0 else { return 0 }
        return Int((x / pixelsPerFrame).rounded())
    }

    private func clampedFrame(_ frame: Int) -> Int {
        min(max(frame, 0), max(0, durationFrames))
    }

    private func yPosition(forGainDB gainDB: Float) -> CGFloat {
        let range = VolumeAutomation.gainRange
        let span = CGFloat(range.upperBound - range.lowerBound)
        guard span > 0 else { return topY }
        let t = CGFloat(range.upperBound - gainDB) / span
        return topY + t * (bottomY - topY)
    }

    private func gainDB(forY y: CGFloat) -> Float {
        let range = VolumeAutomation.gainRange
        let height = bottomY - topY
        guard height > 0 else { return range.upperBound }
        let t = min(max((y - topY) / height, 0), 1)
        let value = range.upperBound - Float(t) * (range.upperBound - range.lowerBound)
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// The envelope currently on screen: the working copy of an in-progress
    /// drag if there is one, otherwise the committed ``automation``. Drawing
    /// and hit-testing during a drag both read this rather than
    /// ``automation``, so the drawn envelope always matches what the mouse is
    /// doing regardless of whether SwiftUI has re-rendered this view with the
    /// latest ``onPreview`` value yet.
    private var displayedAutomation: VolumeAutomation {
        activeTransaction?.working ?? automation
    }

    /// Finds the node nearest `point`, among those within
    /// ``TimelineLayout/automationNodeHitRadius``. Searches the *committed*
    /// envelope - only used to begin a new gesture, before any transaction
    /// exists.
    private func nodeAt(_ point: NSPoint) -> VolumeAutomationPoint? {
        var best: (point: VolumeAutomationPoint, distance: CGFloat)?
        for candidate in automation.points {
            let dx = xPosition(forFrame: candidate.frame) - point.x
            let dy = yPosition(forGainDB: candidate.gainDB) - point.y
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance <= TimelineLayout.automationNodeHitRadius else { continue }
            if best == nil || distance < best!.distance {
                best = (candidate, distance)
            }
        }
        return best?.point
    }

    /// The rect a node occupies, sized to its mouse hit area rather than its
    /// smaller drawn circle - used both to anchor the "Set Level…" popover
    /// and as each node's accessibility frame, so both line up with the area
    /// that actually responds to clicks.
    private func nodeRect(for point: VolumeAutomationPoint) -> NSRect {
        let radius = TimelineLayout.automationNodeHitRadius
        let center = NSPoint(x: xPosition(forFrame: point.frame), y: yPosition(forGainDB: point.gainDB))
        return NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawReferenceLine(in: dirtyRect)
        drawEnvelope(in: dirtyRect)
        drawNodes(in: dirtyRect)
    }

    /// The dashed 0 dB line across the top of the editable band.
    private func drawReferenceLine(in dirtyRect: NSRect) {
        let y = yPosition(forGainDB: VolumeAutomation.unityDB)
        guard dirtyRect.minY <= y, dirtyRect.maxY >= y else { return }

        let path = NSBezierPath()
        path.move(to: NSPoint(x: dirtyRect.minX, y: y))
        path.line(to: NSPoint(x: dirtyRect.maxX, y: y))
        path.lineWidth = TimelineLayout.automationReferenceLineWidth
        path.setLineDash(TimelineLayout.automationReferenceDash, count: TimelineLayout.automationReferenceDash.count, phase: 0)
        NSColor.tertiaryLabelColor.setStroke()
        path.stroke()
    }

    /// The envelope path, limited to the frames that can affect `dirtyRect` -
    /// its x extent widened by one frame each side - so a long timeline never
    /// walks every breakpoint on every partial-redraw tick.
    private func drawEnvelope(in dirtyRect: NSRect) {
        let startFrame = clampedFrame(frame(forX: dirtyRect.minX) - 1)
        let endFrame = clampedFrame(frame(forX: dirtyRect.maxX) + 1)
        guard endFrame > startFrame else { return }

        let segments = displayedAutomation.segments(from: startFrame, to: endFrame)
        guard let first = segments.first else { return }

        let path = NSBezierPath()
        path.move(to: NSPoint(x: xPosition(forFrame: first.startFrame), y: yPosition(forGainDB: first.startDB)))
        for segment in segments {
            path.line(to: NSPoint(x: xPosition(forFrame: segment.endFrame), y: yPosition(forGainDB: segment.endDB)))
        }
        laneColor.setStroke()
        path.lineWidth = TimelineLayout.automationLineWidth
        path.stroke()
    }

    /// Nodes whose x falls within `dirtyRect`, widened by the hit radius so a
    /// node half-covered by the dirty rect's edge still draws in full.
    private func drawNodes(in dirtyRect: NSRect) {
        let hitRadius = TimelineLayout.automationNodeHitRadius
        let visibleMinX = dirtyRect.minX - hitRadius
        let visibleMaxX = dirtyRect.maxX + hitRadius

        for point in displayedAutomation.points {
            let x = xPosition(forFrame: point.frame)
            guard x >= visibleMinX, x <= visibleMaxX else { continue }

            let isDragged = activeTransaction?.draggedId == point.id
            let radius = isDragged ? TimelineLayout.automationNodeRadius * TimelineLayout.automationDraggedNodeScale : TimelineLayout.automationNodeRadius
            let y = yPosition(forGainDB: point.gainDB)
            let rect = NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            let circle = NSBezierPath(ovalIn: rect)

            laneColor.setFill()
            circle.fill()
            NSColor.windowBackgroundColor.setStroke()
            circle.lineWidth = TimelineLayout.automationNodeRingWidth
            circle.stroke()

            if isDragged {
                drawLabel(forGainDB: point.gainDB, besideNodeAt: NSPoint(x: x, y: y), radius: radius)
            }
        }
    }

    private func drawLabel(forGainDB gainDB: Float, besideNodeAt center: NSPoint, radius: CGFloat) {
        let text = String(format: "%+.1f dB", gainDB)
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: center.x + radius + Spacing.xs, y: center.y - size.height / 2)
        text.draw(at: origin, withAttributes: attributes)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if event.clickCount >= 2 {
            handleDoubleClick(at: point)
            return
        }

        // Only the *previous* mouseDown's insertion is protected from the
        // double-click rule; a fresh single click anywhere forgets it, so a
        // node added a while ago can be double-clicked away like any other.
        lastInsertedId = nil

        if let hit = nodeAt(point) {
            onBeginEdit()
            activeTransaction = EditTransaction(
                working: automation,
                draggedId: hit.id,
                insertedByThisMouseDown: false,
                original: automation
            )
        } else {
            onBeginEdit()
            var working = automation
            let frame = clampedFrame(frame(forX: point.x))
            let gainDB = gainDB(forY: point.y)
            let inserted = working.insert(frame: frame, gainDB: gainDB)
            lastInsertedId = inserted.id
            activeTransaction = EditTransaction(
                working: working,
                draggedId: inserted.id,
                insertedByThisMouseDown: true,
                original: automation
            )
            onPreview(working)
            needsDisplay = true
        }
        lastDragPoint = point
        NSCursor.closedHand.set()
    }

    private func handleDoubleClick(at point: NSPoint) {
        guard let hit = nodeAt(point) else { return }
        guard hit.id != lastInsertedId else {
            // This node was created by the first click of this same
            // double-click; the pair leaves it in place.
            return
        }

        onBeginEdit()
        var working = automation
        working.remove(id: hit.id)
        onCommit(working, "Delete Node")
        onEndEdit()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var transaction = activeTransaction else { return }
        let point = convert(event.locationInWindow, from: nil)
        // The frame mapping is always absolute - only gain changes meaning
        // under Option, per the doc comments on `automationFineDragDBPerPoint`
        // and `automationUnitySnapDB`.
        let frame = clampedFrame(frame(forX: point.x))

        let gainDBValue: Float
        if event.modifierFlags.contains(.option),
           let lastDragPoint,
           let currentGain = transaction.working.points.first(where: { $0.id == transaction.draggedId })?.gainDB {
            // Fine control: move by a delta from the node's own current gain
            // rather than mapping the cursor's absolute position, so the
            // whole 32pt editable band becomes fine-grained instead of the
            // coarse ~1.9 dB/pt the full range gives it. Increasing y is
            // downward (this view is flipped), so moving the mouse down
            // reduces gain.
            let deltaY = Float(point.y - lastDragPoint.y)
            let range = VolumeAutomation.gainRange
            gainDBValue = min(max(currentGain - deltaY * TimelineLayout.automationFineDragDBPerPoint, range.lowerBound), range.upperBound)
        } else {
            let mapped = gainDB(forY: point.y)
            // Snap to unity unless Option is held - a deliberately fine
            // adjustment near 0 dB must never be pulled back to it.
            gainDBValue = abs(mapped - VolumeAutomation.unityDB) <= TimelineLayout.automationUnitySnapDB
                ? VolumeAutomation.unityDB
                : mapped
        }
        lastDragPoint = point

        transaction.working.move(id: transaction.draggedId, toFrame: frame, gainDB: gainDBValue)
        activeTransaction = transaction

        onPreview(transaction.working)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let transaction = activeTransaction else { return }
        activeTransaction = nil
        lastDragPoint = nil

        if transaction.working != transaction.original {
            onCommit(transaction.working, transaction.insertedByThisMouseDown ? "Add Node" : "Move Node")
        }
        onEndEdit()
        needsDisplay = true

        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            updateCursor(at: point)
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Context menus

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()

        if let hit = nodeAt(point) {
            pendingMenuNodeId = hit.id
            let setLevelItem = NSMenuItem(title: "Set Level…", action: #selector(setLevelMenuAction), keyEquivalent: "")
            setLevelItem.target = self
            menu.addItem(setLevelItem)

            let deleteItem = NSMenuItem(title: "Delete Node", action: #selector(deleteNodeMenuAction), keyEquivalent: "")
            deleteItem.target = self
            menu.addItem(deleteItem)
        } else {
            let resetItem = NSMenuItem(title: "Reset Automation", action: #selector(resetAutomationMenuAction), keyEquivalent: "")
            resetItem.target = self
            menu.addItem(resetItem)

            menu.addItem(.separator())

            let removeItem = NSMenuItem(title: "Remove Automation", action: #selector(removeAutomationMenuAction), keyEquivalent: "")
            removeItem.target = self
            menu.addItem(removeItem)
        }

        menu.popUp(positioning: nil, at: point, in: self)
    }

    @objc private func setLevelMenuAction() {
        guard let id = pendingMenuNodeId, let point = automation.points.first(where: { $0.id == id }) else { return }
        pendingMenuNodeId = nil
        // Opening the popover is not itself an edit, so this fires outside
        // onBeginEdit/onEndEdit - only committing from it is (see `onSetLevel`).
        onSetLevel(point.id, point.gainDB, point.frame, nodeRect(for: point))
    }

    @objc private func deleteNodeMenuAction() {
        guard let id = pendingMenuNodeId else { return }
        pendingMenuNodeId = nil

        onBeginEdit()
        var working = automation
        working.remove(id: id)
        onCommit(working, "Delete Node")
        onEndEdit()
        needsDisplay = true
    }

    @objc private func resetAutomationMenuAction() {
        guard !automation.points.isEmpty else { return }

        onBeginEdit()
        var working = automation
        working.removeAll()
        onCommit(working, "Reset Automation")
        onEndEdit()
        needsDisplay = true
    }

    @objc private func removeAutomationMenuAction() {
        onBeginEdit()
        onRemove()
        onEndEdit()
    }

    // MARK: - Accessibility

    /// One `NSAccessibilityElement` per node, reporting its timecode, gain
    /// and rect, with increment/decrement/delete actions wired back to this
    /// view. `NSAccessibilityElement`'s own documentation requires the
    /// vendor to keep these alive as long as the UI they describe is on
    /// screen; returning a fresh array from this accessor each time
    /// AppKit asks is the documented way to satisfy that for content that
    /// can change (nodes added, moved or removed) between calls.
    override func accessibilityChildren() -> [Any]? {
        automation.points.map { point in
            let element = VolumeAutomationNodeAccessibilityElement()
            element.owner = self
            element.pointId = point.id
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(nodeRect(for: point))
            element.setAccessibilityRole(.slider)
            element.setAccessibilityLabel("Volume node, \(formatTimecode(point.frame))")
            element.setAccessibilityValue(String(format: "%+.1f dB", point.gainDB))
            return element
        }
    }

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? { "Volume automation" }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: "Add node at playhead") { [weak self] in
            self?.addNodeAtPlayheadAccessibilityAction() ?? false
        }]
    }

    /// Adjusts one node's gain by `delta` dB (clamped to ``VolumeAutomation/gainRange``
    /// by `setGain` itself), for a node element's increment/decrement action.
    fileprivate func adjustAccessibilityNodeGain(_ pointId: UUID, byDB delta: Float) -> Bool {
        guard let point = automation.points.first(where: { $0.id == pointId }) else { return false }
        onBeginEdit()
        var working = automation
        working.setGain(id: pointId, gainDB: point.gainDB + delta)
        onCommit(working, "Set Level")
        onEndEdit()
        needsDisplay = true
        return true
    }

    /// Removes one node, for a node element's delete action.
    fileprivate func deleteAccessibilityNode(_ pointId: UUID) -> Bool {
        guard automation.points.contains(where: { $0.id == pointId }) else { return false }
        onBeginEdit()
        var working = automation
        working.remove(id: pointId)
        onCommit(working, "Delete Node")
        onEndEdit()
        needsDisplay = true
        return true
    }

    /// Inserts a node at the current playhead, at the envelope's own gain
    /// there, for the view's "Add node at playhead" custom action.
    private func addNodeAtPlayheadAccessibilityAction() -> Bool {
        onBeginEdit()
        var working = automation
        let frame = clampedFrame(playheadFrame)
        let inserted = working.insert(frame: frame, gainDB: working.gainDB(at: frame))
        lastInsertedId = inserted.id
        onCommit(working, "Add Node")
        onEndEdit()
        needsDisplay = true
        return true
    }
}

/// The accessibility element for one automation node - a slider whose
/// increment/decrement move its gain by 1 dB and whose delete action removes
/// it, all forwarded back to the ``VolumeAutomationEnvelopeNSView`` that
/// vends it.
private final class VolumeAutomationNodeAccessibilityElement: NSAccessibilityElement {
    weak var owner: VolumeAutomationEnvelopeNSView?
    var pointId: UUID = UUID()

    override func accessibilityPerformIncrement() -> Bool {
        owner?.adjustAccessibilityNodeGain(pointId, byDB: 1) ?? false
    }

    override func accessibilityPerformDecrement() -> Bool {
        owner?.adjustAccessibilityNodeGain(pointId, byDB: -1) ?? false
    }

    override func accessibilityPerformDelete() -> Bool {
        owner?.deleteAccessibilityNode(pointId) ?? false
    }
}
