//
//  DiagnosticLog.swift
//  Projector
//
//  Always-on ring buffer of recent events, for building bug reports.
//

import Foundation
import os

/// Sizing and formatting limits for the diagnostic log.
public enum DiagnosticLogConstants {
    /// How many entries are kept before the oldest is overwritten.
    ///
    /// At roughly 120 bytes an entry this is a few hundred kilobytes, which is
    /// small enough to carry for a whole session and long enough to cover the
    /// minutes before a user notices something is wrong and reaches for the
    /// button.
    public static let capacity = 2_000

    /// Longest message stored. Anything past this is truncated at the call
    /// site, so one runaway string cannot dominate the buffer.
    public static let maxMessageLength = 512

    /// Subsystem for the parallel `os.Logger` stream.
    public static let subsystem = "com.keegandewitt.projector"
}

/// The app's diagnostic log: a fixed-size ring of recent entries.
///
/// An actor rather than a lock, so recording never blocks the caller and the
/// buffer needs no synchronisation of its own. Entries are written by
/// ``diagnosticLog(_:_:_:)``, which hops here without waiting.
///
/// ### Cost
///
/// Recording is one `Date()`, one string interpolation, one `os_log` and one
/// detached task. That is cheap for the rate this is designed for - user
/// actions, device changes, imports, errors - and far too expensive for a
/// real-time path. Never call it from an audio render callback, a MIDI
/// quarter-frame handler, or anything that runs per video frame.
public actor DiagnosticLog: DiagnosticLogService {
    /// The instance the whole app records into.
    public static let shared = DiagnosticLog()

    /// Parallel stream to the unified log, so a user can be walked through
    /// Console.app without sending anything, and so entries survive a crash
    /// that takes the in-memory ring with it.
    private static let logger = Logger(
        subsystem: DiagnosticLogConstants.subsystem,
        category: "diagnostics"
    )

    /// Preallocated so recording never grows an array mid-session.
    private var buffer: [DiagnosticEntry?]

    /// Where the next entry goes. Wraps at the end of the buffer.
    private var writeIndex = 0

    /// Entries that have been overwritten and are gone for good.
    private var overwritten = 0

    /// - Parameter capacity: Entries held before the oldest is overwritten.
    public init(capacity: Int = DiagnosticLogConstants.capacity) {
        buffer = Array(repeating: nil, count: max(1, capacity))
    }

    public func record(_ entry: DiagnosticEntry) {
        if buffer[writeIndex] != nil {
            overwritten += 1
        }
        buffer[writeIndex] = entry
        writeIndex = (writeIndex + 1) % buffer.count
    }

    /// Every entry still held, oldest first.
    ///
    /// Sorted by timestamp rather than read in ring order, because entries
    /// reach the actor through independent tasks and can arrive out of order.
    /// The timestamp is taken at the call site, so this is the true sequence.
    public func snapshot() -> [DiagnosticEntry] {
        buffer
            .compactMap { $0 }
            .sorted { $0.timestamp < $1.timestamp }
    }

    public func overwrittenCount() -> Int {
        overwritten
    }

    public func clear() {
        buffer = Array(repeating: nil, count: buffer.count)
        writeIndex = 0
        overwritten = 0
    }

    /// Mirrors an entry to the unified log.
    ///
    /// `nonisolated` so the call site can do this without awaiting the actor.
    fileprivate nonisolated static func mirror(_ entry: DiagnosticEntry) {
        let line = "[\(entry.category.rawValue)] \(entry.message)"
        switch entry.level {
        case .debug:   logger.debug("\(line, privacy: .public)")
        case .info:    logger.info("\(line, privacy: .public)")
        case .warning: logger.warning("\(line, privacy: .public)")
        case .error:   logger.error("\(line, privacy: .public)")
        }
    }
}

// MARK: - Recording

/// Records an event to the diagnostic log.
///
/// Unlike ``debugLog(_:file:function:line:)`` this is **not** compiled out of
/// release builds - a log that only exists in Debug cannot back a bug report
/// sent by a user.
///
/// The message is built and timestamped synchronously, then handed to the actor
/// without waiting, so the caller is never blocked by logging. Because the
/// message is an autoclosure, the interpolation is skipped entirely when the
/// entry is below the recording threshold.
///
/// - Parameters:
///   - level: How serious the event is.
///   - category: The subsystem it came from.
///   - message: The text to record. Truncated to
///     ``DiagnosticLogConstants/maxMessageLength``.
///
/// - Important: Not for real-time paths. See ``DiagnosticLog`` for the cost.
@inline(__always)
public func diagnosticLog(
    _ level: DiagnosticLevel,
    _ category: DiagnosticCategory,
    _ message: @autoclosure () -> String
) {
    guard level >= DiagnosticRecordingThreshold.current else { return }

    // Built here, not inside the task, so the timestamp is when the event
    // happened and the captured values are the ones it happened with.
    let entry = DiagnosticEntry(
        timestamp: Date(),
        level: level,
        category: category,
        message: String(message().prefix(DiagnosticLogConstants.maxMessageLength))
    )

    DiagnosticLog.mirror(entry)

    Task.detached(priority: .utility) {
        await DiagnosticLog.shared.record(entry)
    }
}

/// The lowest level that gets recorded.
///
/// Debug entries are dropped in release builds, which keeps the ring covering a
/// longer stretch of real time for the same memory - a user's report is far more
/// useful showing ten minutes of meaningful events than forty seconds of noise.
enum DiagnosticRecordingThreshold {
    static let current: DiagnosticLevel = {
        #if DEBUG
        return .debug
        #else
        return .info
        #endif
    }()
}
