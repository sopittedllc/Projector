//
//  DiagnosticLogServiceProtocol.swift
//  Projector
//
//  THE CONTRACT for in-app diagnostic logging.
//

import Foundation

/// How serious a diagnostic entry is.
///
/// Ordered, so a report can be filtered down to "warnings and worse" without
/// the caller knowing the case list.
public enum DiagnosticLevel: Int, Sendable, Comparable, CaseIterable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: DiagnosticLevel, rhs: DiagnosticLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Fixed-width tag for the exported report, so the log column stays aligned.
    public var tag: String {
        switch self {
        case .debug:   return "DEBUG"
        case .info:    return "INFO "
        case .warning: return "WARN "
        case .error:   return "ERROR"
        }
    }
}

/// The part of the app an entry came from.
///
/// Deliberately coarse. The point is to let whoever reads a report jump to the
/// subsystem that failed, not to mirror the type hierarchy.
public enum DiagnosticCategory: String, Sendable, CaseIterable {
    case app
    case project
    case media
    case playback
    case audio
    case midi
    case timeline
    case export
}

/// One line in the diagnostic log.
public struct DiagnosticEntry: Sendable, Equatable {
    /// When the event happened, captured at the call site rather than when the
    /// entry reaches the buffer - see ``DiagnosticLogService`` for why.
    public let timestamp: Date
    public let level: DiagnosticLevel
    public let category: DiagnosticCategory
    public let message: String

    public init(
        timestamp: Date,
        level: DiagnosticLevel,
        category: DiagnosticCategory,
        message: String
    ) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

/// A bounded, always-on log that a bug report can be built from.
///
/// Implementations keep a fixed number of recent entries and overwrite the
/// oldest, so a session of any length costs the same memory and never touches
/// the disk while running.
///
/// Recording is asynchronous, which means entries can arrive out of order.
/// Callers stamp ``DiagnosticEntry/timestamp`` before handing the entry over,
/// and ``snapshot()`` sorts by it, so the exported log reads in the order things
/// actually happened rather than the order the tasks were scheduled.
public protocol DiagnosticLogService: Actor {
    /// Stores an entry, overwriting the oldest one if the buffer is full.
    func record(_ entry: DiagnosticEntry)

    /// Every entry still held, oldest first.
    func snapshot() -> [DiagnosticEntry]

    /// How many entries have been overwritten and are no longer recoverable.
    ///
    /// Reported in the bug report so a truncated log is never mistaken for a
    /// quiet one.
    func overwrittenCount() -> Int

    /// Drops every entry. Used when a report has been sent.
    func clear()
}
