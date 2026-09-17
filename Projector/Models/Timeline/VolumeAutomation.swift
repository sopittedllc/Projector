import Foundation

/// One breakpoint in a lane's volume envelope.
///
/// `frame` is a signed absolute timeline frame - see
/// ``VolumeAutomation`` for why negative values are valid inside the model
/// even though nothing on screen is ever placed there interactively.
public struct VolumeAutomationPoint: Identifiable, Equatable, Sendable {
    /// Stable identity across edits, so a drag or an undo can address "this
    /// node" rather than "whatever is now at this frame".
    public let id: UUID

    /// Absolute timeline frame. May be negative or beyond the timeline's
    /// current bounds; only interactive placement clamps to what is visible.
    public var frame: Int

    /// Gain at this point, always within ``VolumeAutomation/gainRange``.
    public var gainDB: Float

    /// - Parameters:
    ///   - id: Identity for this point. Defaults to a fresh id.
    ///   - frame: Absolute timeline frame.
    ///   - gainDB: Gain in decibels. Not clamped here - every entry point
    ///     into ``VolumeAutomation`` clamps on the way in, so a point can
    ///     never be constructed outside an envelope with an out-of-range
    ///     value.
    public init(id: UUID = UUID(), frame: Int, gainDB: Float) {
        self.id = id
        self.frame = frame
        self.gainDB = gainDB
    }
}

extension VolumeAutomationPoint: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case frame
        case gainDB
    }

    /// A missing `id` is not a decode failure - a hand-edited save, or a
    /// future writer that drops it, still opens. `VolumeAutomation`'s own
    /// normalization additionally regenerates ids that collide with another
    /// point's, so every decoded point ends up with an id either way.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        frame = try container.decode(Int.self, forKey: .frame)
        gainDB = try container.decode(Float.self, forKey: .gainDB)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(frame, forKey: .frame)
        try container.encode(gainDB, forKey: .gainDB)
    }
}

/// A lane's volume envelope: sorted breakpoints with unique frames, linear
/// in decibels between neighbours, held before the first and after the
/// last. Empty is unity - a lane that has never had a node added is
/// unaffected by this type.
///
/// ## Why frames are signed
///
/// Automation lives at absolute timeline frames, the same grid as clips.
/// `TimelineManager.shiftAllContent(by:)` moves clip positions negative
/// when the timeline's start timecode moves later than existing content, and
/// the shift must be reversible - shifting back has to restore the original
/// points exactly. If frames clamped to zero, a point pushed negative by one
/// shift would be lost, and shifting back would not restore it. So the model
/// accepts any `Int`; only interactive placement (adding or dragging a node
/// with the mouse) clamps to what is visible on the timeline.
public struct VolumeAutomation: Equatable, Sendable {
    /// Attenuation-only: the feature does not add gain, only rides it down.
    /// See the plan's user decision - this is not a mixing/limiting control.
    public static let gainRange: ClosedRange<Float> = -60...0

    /// No change in level.
    public static let unityDB: Float = 0

    /// Sorted by `frame`, ascending, with unique frames. Private setter
    /// because every mutation needs the sort/clamp/dedupe invariants
    /// enforced - direct array mutation would let those drift.
    public private(set) var points: [VolumeAutomationPoint]

    /// Below this, rounding error and pathological inputs (zero, negative,
    /// NaN) could make ``rampCount(forDeltaDB:toleranceDB:)`` behave
    /// unpredictably; clamping to this floor keeps the count bounded at any
    /// delta (23 at 60 dB, the whole range, with the default 0.1 dB
    /// tolerance).
    private static let minimumToleranceDB: Double = 0.01

    /// `20 / ln(10)`: the constant that converts a natural-log ratio into
    /// decibels. Named because it appears twice in ``rampCount``'s closed
    /// form and reads as noise as a literal.
    private static let decibelsPerNeper: Double = 20.0 / log(10.0)

    /// Frames a point may sit on: ±2⁴⁰, about 1.4 million hours at 24 fps.
    /// Frames are signed and unbounded in principle (see the type's
    /// documentation), but `Int.min`/`Int.max` would overflow the frame
    /// arithmetic in ``gainDB(at:)`` and ``move(id:toFrame:gainDB:)``, so
    /// every entry point clamps to this range. No real timeline comes within
    /// a million-fold of it.
    public static let frameRange: ClosedRange<Int> = -(1 << 40) ... (1 << 40)

    /// The largest delta ``rampCount(forDeltaDB:toleranceDB:)`` ever needs to
    /// split: the whole ``gainRange``. A public caller passing more is asking
    /// about a slope the model cannot contain, and is answered as if it had
    /// asked about the full range.
    private static let maximumDeltaDB: Double = Double(gainRange.upperBound - gainRange.lowerBound)

    /// Bisection steps for ``maximumRampDeltaDB(forToleranceDB:)``: 48
    /// halvings of a 60 dB bracket resolve the answer to ~2⁻⁴⁰ dB, far
    /// beyond Float.
    private static let maxDeltaBisectionSteps = 48

    /// Below this a ramp is numerically a hold and its error is zero; it
    /// keeps ``maximumRampErrorDB(forDeltaDB:)`` away from `0/0`.
    private static let negligibleDeltaDB: Double = 1e-9

    /// - Parameter points: Initial breakpoints, in any order. Normalized on
    ///   construction exactly as decode normalizes, so this initializer and
    ///   `init(from:)` can never disagree about what a valid envelope looks
    ///   like.
    public init(points: [VolumeAutomationPoint] = []) {
        self.points = Self.normalized(points)
    }

    /// No gain anywhere (empty, or every point at 0 dB). Not "flat": a
    /// constant −12 dB envelope is flat but is not unity.
    public var isUnity: Bool {
        points.allSatisfy { $0.gainDB == Self.unityDB }
    }

    /// Gain at an arbitrary frame: linear interpolation in decibels between
    /// the two neighbouring points, held at the first point's gain before it
    /// and the last point's gain after it. `0 dB` for an empty envelope.
    ///
    /// - Parameter frame: Any frame, including negative or beyond the
    ///   timeline's current bounds.
    /// - Returns: Gain in decibels, always within ``gainRange``.
    public func gainDB(at frame: Int) -> Float {
        guard let first = points.first, let last = points.last else { return Self.unityDB }
        if frame <= first.frame { return first.gainDB }
        if frame >= last.frame { return last.gainDB }

        for index in 1..<points.count {
            let previous = points[index - 1]
            let next = points[index]
            guard frame <= next.frame else { continue }
            // `previous.frame < frame` here: frames are unique and sorted, and
            // the guards above already returned for `frame == first.frame`.
            // Differences are taken in Double: frames are clamped to
            // `frameRange`, so they cannot overflow, but Double keeps that
            // true even if the range is ever widened.
            let span = Double(next.frame) - Double(previous.frame)
            let t = Float((Double(frame) - Double(previous.frame)) / span)
            return previous.gainDB + (next.gainDB - previous.gainDB) * t
        }
        // Unreachable: `frame` is bracketed by `first` and `last` above, so
        // the loop always returns before falling through.
        return last.gainDB
    }

    /// Convenience over ``gainDB(at:)`` for callers that want a scalar to
    /// multiply a sample by rather than a decibel value.
    ///
    /// - Parameter frame: Any frame.
    /// - Returns: A linear gain, `1.0` at 0 dB.
    public func linearGain(at frame: Int) -> Float {
        Self.linearVolume(fromDB: gainDB(at: frame))
    }

    /// Converts decibels to the linear scalar AVFoundation and the mixer
    /// want. Moved here from `QuickTimeDemoBuilder` so there is one
    /// definition shared by playback, export and this model.
    ///
    /// - Parameter dB: Level in decibels.
    /// - Returns: A linear volume, `1.0` at 0 dB.
    public static func linearVolume(fromDB dB: Float) -> Float {
        pow(10, dB / 20)
    }

    /// Adds a point, or - if one already sits on that exact frame - replaces
    /// its gain in place, keeping its id. Interactive callers pass
    /// `frame >= 0`; the model itself accepts any `Int`.
    ///
    /// - Parameters:
    ///   - frame: Frame to place the point at.
    ///   - gainDB: Desired gain; clamped to ``gainRange``, non-finite
    ///     replaced with ``unityDB``.
    /// - Returns: The point that now exists at `frame` (new or updated).
    @discardableResult
    public mutating func insert(frame: Int, gainDB: Float) -> VolumeAutomationPoint {
        let clamped = Self.clampGain(gainDB)
        let frame = Self.clampFrame(frame)
        if let index = points.firstIndex(where: { $0.frame == frame }) {
            points[index].gainDB = clamped
            return points[index]
        }
        let point = VolumeAutomationPoint(frame: frame, gainDB: clamped)
        points.append(point)
        points.sort { $0.frame < $1.frame }
        return point
    }

    /// Moves an existing point, clamping its new frame strictly between its
    /// neighbours so nodes can never cross or coincide, and its gain to
    /// ``gainRange``.
    ///
    /// - Parameters:
    ///   - id: The point to move. A no-op if no point has this id.
    ///   - toFrame: Desired frame.
    ///   - gainDB: Desired gain.
    public mutating func move(id: UUID, toFrame: Int, gainDB: Float) {
        guard let index = points.firstIndex(where: { $0.id == id }) else { return }

        let lowerBound = index > 0 ? points[index - 1].frame + 1 : Self.frameRange.lowerBound
        let upperBound = index < points.count - 1 ? points[index + 1].frame - 1 : Self.frameRange.upperBound

        // Neighbours already adjacent (no frame strictly between them) -
        // there is nowhere to move to without crossing, so the frame holds.
        let clampedFrame = lowerBound <= upperBound
            ? min(max(toFrame, lowerBound), upperBound)
            : points[index].frame

        points[index].frame = clampedFrame
        points[index].gainDB = Self.clampGain(gainDB)
    }

    /// Sets a point's gain without moving it.
    ///
    /// - Parameters:
    ///   - id: The point to change. A no-op if no point has this id.
    ///   - gainDB: Desired gain; clamped to ``gainRange``.
    public mutating func setGain(id: UUID, gainDB: Float) {
        guard let index = points.firstIndex(where: { $0.id == id }) else { return }
        points[index].gainDB = Self.clampGain(gainDB)
    }

    /// Removes one point.
    ///
    /// - Parameter id: The point to remove. A no-op if no point has this id.
    public mutating func remove(id: UUID) {
        points.removeAll { $0.id == id }
    }

    /// Removes every point, returning the envelope to unity.
    public mutating func removeAll() {
        points.removeAll()
    }

    /// Applies a frame transform to every point - used by
    /// `TimelineManager.regridContent(from:to:)` and `shiftAllContent(by:)`
    /// with the same transform they apply to clips, so an envelope tracks a
    /// frame-rate change or a timeline-start shift exactly as clips do.
    ///
    /// The transform need not be monotonic and its results are kept even
    /// when negative, since a shift can legitimately push a point before
    /// frame 0 and a later, opposite shift must restore it exactly. If the
    /// transform collapses two points onto the same frame, the point that
    /// was later on the timeline before the transform is kept, matching
    /// decode's "last one wins" rule for duplicate frames.
    ///
    /// - Parameter transform: Maps an old frame to a new one.
    public mutating func mapFrames(_ transform: (Int) -> Int) {
        let transformed = points.map { point -> VolumeAutomationPoint in
            var moved = point
            moved.frame = Self.clampFrame(transform(point.frame))
            return moved
        }
        // `points` is sorted ascending going in, so iterating it in order
        // and overwriting by frame leaves the later (higher pre-transform
        // frame) point as the last write - the "later one" the doc above
        // promises.
        var byFrame: [Int: VolumeAutomationPoint] = [:]
        for point in transformed {
            byFrame[point.frame] = point
        }
        points = byFrame.values.sorted { $0.frame < $1.frame }
    }

    /// One piece of a piecewise-linear envelope, covering `[startFrame,
    /// endFrame)`.
    public struct Segment: Equatable, Sendable {
        /// First frame this segment covers, inclusive.
        public let startFrame: Int
        /// First frame past this segment - the next segment's `startFrame`,
        /// or the end of the requested span for the last one.
        public let endFrame: Int
        /// Gain at `startFrame`.
        public let startDB: Float
        /// Gain at `endFrame`.
        public let endDB: Float

        /// A flat piece (before the first point, after the last, or between
        /// two points at equal gain) rather than a slope.
        public var isHold: Bool { startDB == endDB }
    }

    /// Full coverage of `[startFrame, endFrame)` as a sequence of holds and
    /// node-to-node slopes: a leading hold from `startFrame` to the first
    /// point inside the span, one piece per pair of neighbouring points, and
    /// a trailing hold to `endFrame`. The first segment always starts at
    /// `startFrame` and the last always ends at `endFrame`, so a caller can
    /// build export instructions or draw the editor without special-casing
    /// the ends of the requested span.
    ///
    /// An empty envelope, or one with a single point, is constant across
    /// every frame, so it always yields exactly one hold for the whole span
    /// - even if the single point's frame falls inside `[startFrame,
    /// endFrame)` - rather than splitting at a frame where nothing changes.
    ///
    /// - Parameters:
    ///   - startFrame: First frame of the span, inclusive.
    ///   - endFrame: First frame past the span. Frames beyond either end of
    ///     this method's own points are evaluated via ``gainDB(at:)``, so a
    ///     span that starts before the first point or ends after the last
    ///     one still returns a fully covering hold.
    /// - Returns: Empty if `endFrame <= startFrame`; otherwise never empty.
    public func segments(from startFrame: Int, to endFrame: Int) -> [Segment] {
        guard endFrame > startFrame else { return [] }

        if points.count <= 1 {
            // Constant everywhere - one hold, regardless of where the
            // (at most one) point sits relative to the span.
            let level = gainDB(at: startFrame)
            return [Segment(startFrame: startFrame, endFrame: endFrame, startDB: level, endDB: level)]
        }

        // Knots: the span's own endpoints plus every point strictly inside
        // the span. `gainDB(at:)` at the endpoints already equals a
        // coincident point's gain, so there is never a duplicate frame here
        // even when a point sits exactly on `startFrame` or `endFrame`.
        var knots: [(frame: Int, gainDB: Float)] = [(startFrame, gainDB(at: startFrame))]
        for point in points where point.frame > startFrame && point.frame < endFrame {
            knots.append((point.frame, point.gainDB))
        }
        knots.append((endFrame, gainDB(at: endFrame)))

        var result: [Segment] = []
        result.reserveCapacity(knots.count - 1)
        for index in 1..<knots.count {
            let previous = knots[index - 1]
            let current = knots[index]
            result.append(Segment(
                startFrame: previous.frame,
                endFrame: current.frame,
                startDB: previous.gainDB,
                endDB: current.gainDB
            ))
        }
        return result
    }

    /// The largest deviation, in decibels, of a single linear-amplitude ramp
    /// from the linear-in-decibels line it approximates.
    ///
    /// AVFoundation's `setVolumeRamp` interpolates amplitude linearly, so a
    /// ramp is the chord of an exponential and always sits *above* the curve.
    /// For a ramp of `d` dB, with `q = ln10·d/20`, the chord/curve ratio in
    /// nepers is `log1p(u·expm1(q)) − q·u`, maximised at `u = 1/q − 1/expm1(q)`
    /// (slightly before the midpoint). This is that maximum, in decibels.
    /// Even in `d`, so the sign does not matter.
    ///
    /// - Parameter delta: The change in decibels across one ramp.
    /// - Returns: The maximum error in decibels; `0` for a hold.
    public static func maximumRampErrorDB(forDeltaDB delta: Float) -> Float {
        Float(maximumRampError(forDeltaDB: Double(abs(delta))))
    }

    private static func maximumRampError(forDeltaDB delta: Double) -> Double {
        guard delta.isFinite, delta > negligibleDeltaDB else { return 0 }
        let q = delta / decibelsPerNeper
        let expm1q = expm1(q)
        let u = 1 / q - 1 / expm1q
        return decibelsPerNeper * (log1p(u * expm1q) - q * u)
    }

    /// The widest single ramp, in decibels, whose maximum error stays within
    /// `toleranceDB`. Found by bisection on ``maximumRampErrorDB(forDeltaDB:)``,
    /// which is monotonic in the delta, so the bound is exact for any
    /// tolerance rather than a midpoint approximation with a safety margin.
    ///
    /// - Parameter toleranceDB: Maximum allowed deviation. Clamped to
    ///   `>= minimumToleranceDB`; non-finite or smaller values are treated as
    ///   that floor.
    /// - Returns: A delta in `(0, maximumDeltaDB]`.
    public static func maximumRampDeltaDB(forToleranceDB toleranceDB: Float) -> Float {
        let exact = maximumRampDelta(forToleranceDB: clampedTolerance(toleranceDB))
        // Round *down* to Float: rounding up would hand back a delta whose
        // error is a hair over the tolerance, which is the one thing this
        // function promises not to do.
        let rounded = Float(exact)
        return Double(rounded) > exact ? rounded.nextDown : rounded
    }

    private static func clampedTolerance(_ toleranceDB: Float) -> Double {
        toleranceDB.isFinite && Double(toleranceDB) >= minimumToleranceDB
            ? Double(toleranceDB)
            : minimumToleranceDB
    }

    private static func maximumRampDelta(forToleranceDB tolerance: Double) -> Double {
        // The error at the full range may already be within tolerance, in
        // which case one ramp covers everything.
        guard maximumRampError(forDeltaDB: maximumDeltaDB) > tolerance else { return maximumDeltaDB }
        var low = 0.0
        var high = maximumDeltaDB
        for _ in 0..<maxDeltaBisectionSteps {
            let mid = (low + high) / 2
            if maximumRampError(forDeltaDB: mid) <= tolerance {
                low = mid
            } else {
                high = mid
            }
        }
        return low
    }

    /// How many equal linear-amplitude ramp pieces a slope of `deltaDB` must
    /// be split into so that no point on the piecewise-linear-amplitude
    /// approximation strays more than `toleranceDB` from the true
    /// linear-in-decibels line. This is the export renderer's way of keeping
    /// `setVolumeRamp`'s amplitude-linear bow inside a stated tolerance.
    ///
    /// Splitting `deltaDB` into `n = max(1, ceil(|deltaDB| / maxDelta))`
    /// equal pieces keeps every piece at or under
    /// ``maximumRampDeltaDB(forToleranceDB:)``, hence within tolerance - the
    /// error is monotonic in the piece's delta.
    ///
    /// - Parameters:
    ///   - delta: The change in decibels the ramp must cover. `0`, or a
    ///     non-finite value (which is not a slope), needs no ramp. Magnitudes
    ///     beyond the whole ``gainRange`` are treated as the whole range.
    ///   - toleranceDB: Maximum allowed deviation, in decibels; clamped as
    ///     for ``maximumRampDeltaDB(forToleranceDB:)``, which keeps the count
    ///     bounded (≤ 23 at a 60 dB change with the default 0.1 dB tolerance).
    /// - Returns: `0` if `delta` is zero or non-finite; otherwise at least `1`.
    public static func rampCount(forDeltaDB delta: Float, toleranceDB: Float) -> Int {
        guard delta.isFinite, delta != 0 else { return 0 }

        let magnitude = min(abs(Double(delta)), maximumDeltaDB)
        let maxDeltaDB = maximumRampDelta(forToleranceDB: clampedTolerance(toleranceDB))

        let count = Int(ceil(magnitude / maxDeltaDB))
        return max(1, count)
    }

    /// Clamps a candidate gain to ``gainRange``, replacing a non-finite
    /// value (NaN from a bad calculation upstream, or an infinity) with
    /// ``unityDB`` rather than propagating it - a silently-clamped extreme
    /// would still be a real, if wrong, level, while a non-finite one is not
    /// a level at all.
    private static func clampGain(_ gain: Float) -> Float {
        guard gain.isFinite else { return unityDB }
        return min(max(gain, gainRange.lowerBound), gainRange.upperBound)
    }

    /// Clamps a frame to ``frameRange`` - see that constant for why.
    private static func clampFrame(_ frame: Int) -> Int {
        min(max(frame, frameRange.lowerBound), frameRange.upperBound)
    }

    /// Enforces every invariant this type promises - sorted by frame, unique
    /// frames (last one in decoded/insertion order wins), gains within
    /// range, ids present and unique - from a single place, so the
    /// memberwise initializer and `init(from:)` can never disagree about
    /// what counts as a valid envelope.
    ///
    /// - Parameter points: Candidate points, in any order.
    /// - Returns: Sorted, deduplicated, clamped points.
    private static func normalized(_ points: [VolumeAutomationPoint]) -> [VolumeAutomationPoint] {
        // Swift's sort is stable, so points that share a frame keep their
        // original relative order here - which is exactly "last in decoded
        // order" once the loop below overwrites earlier entries.
        let sortedByFrame = points
            .map { point -> VolumeAutomationPoint in
                var clamped = point
                clamped.frame = clampFrame(point.frame)
                return clamped
            }
            .sorted { $0.frame < $1.frame }

        var pointByFrame: [Int: VolumeAutomationPoint] = [:]
        var frameOrder: [Int] = []
        for point in sortedByFrame {
            if pointByFrame[point.frame] == nil {
                frameOrder.append(point.frame)
            }
            pointByFrame[point.frame] = point
        }

        var seenIds = Set<UUID>()
        var result: [VolumeAutomationPoint] = []
        result.reserveCapacity(frameOrder.count)
        for frame in frameOrder {
            // Always present - `frameOrder` holds `pointByFrame`'s own keys.
            guard var point = pointByFrame[frame] else { continue }
            point.gainDB = clampGain(point.gainDB)
            if seenIds.contains(point.id) {
                point = VolumeAutomationPoint(frame: point.frame, gainDB: point.gainDB)
            }
            seenIds.insert(point.id)
            result.append(point)
        }
        return result
    }
}

extension VolumeAutomation: Codable {
    private enum CodingKeys: String, CodingKey {
        case points
    }

    /// Runs every decoded envelope through ``normalized(_:)`` - the same
    /// pass the memberwise initializer uses - so a hand-edited or
    /// older-build save can never produce an envelope this type's own API
    /// could not have produced itself.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPoints = try container.decode([VolumeAutomationPoint].self, forKey: .points)
        points = Self.normalized(decodedPoints)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points, forKey: .points)
    }
}
