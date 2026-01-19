import Foundation

/// A container for cues that supports multiple sources.
///
/// CueSheet provides a way to organize cues that may come from different sources:
/// - Local cues created within the app
/// - External sources like Google Sheets or CSV files
///
/// ## Overview
///
/// Each project can have multiple cue sheets, allowing you to maintain separate
/// cue lists for different purposes (e.g., "Main Cues", "Lighting Cues", etc.)
/// or from different external sources.
///
/// ## Example
///
/// ```swift
/// var sheet = CueSheet(name: "Main Cues")
/// sheet.addCue(Cue(number: 1, title: "Opening", startFrame: 0, endFrame: 100))
/// sheet.renumberCues()  // Ensures sequential numbering
/// ```
struct CueSheet: Identifiable, Codable, Equatable {
    /// Unique identifier for this cue sheet
    let id: UUID

    /// Display name for this cue sheet
    var name: String

    /// Collection of cues in this sheet
    var cues: [Cue]

    /// Source of the cue sheet (local or external)
    var source: CueSheetSource

    /// Last time this sheet was synced with its external source
    var lastSyncedAt: Date?

    // MARK: - Computed Properties

    /// Cues sorted by start frame
    var sortedCues: [Cue] {
        cues.sorted { $0.startFrame < $1.startFrame }
    }

    // MARK: - Initialization

    /// Creates a new cue sheet.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (defaults to new UUID)
    ///   - name: Display name for the sheet
    ///   - cues: Initial cues (defaults to empty)
    ///   - source: Source type (defaults to local)
    ///   - lastSyncedAt: Last sync timestamp (defaults to nil)
    init(
        id: UUID = UUID(),
        name: String = "Main Cue Sheet",
        cues: [Cue] = [],
        source: CueSheetSource = .local,
        lastSyncedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.cues = cues
        self.source = source
        self.lastSyncedAt = lastSyncedAt
    }

    // MARK: - Mutations

    /// Adds a cue to the sheet.
    ///
    /// - Parameter cue: The cue to add
    mutating func addCue(_ cue: Cue) {
        cues.append(cue)
    }

    /// Removes a cue by ID.
    ///
    /// - Parameter id: The ID of the cue to remove
    mutating func removeCue(id: UUID) {
        cues.removeAll { $0.id == id }
    }

    /// Updates an existing cue.
    ///
    /// - Parameter cue: The cue with updated values
    mutating func updateCue(_ cue: Cue) {
        if let index = cues.firstIndex(where: { $0.id == cue.id }) {
            cues[index] = cue
        }
    }

    /// Renumbers all cues sequentially based on start frame order.
    ///
    /// This ensures cue numbers are sequential (1, 2, 3...) based on
    /// their chronological order on the timeline.
    mutating func renumberCues() {
        let sorted = cues.sorted { $0.startFrame < $1.startFrame }
        for (index, cue) in sorted.enumerated() {
            if let cueIndex = cues.firstIndex(where: { $0.id == cue.id }) {
                cues[cueIndex].number = index + 1
            }
        }
    }
}

// MARK: - CueSheetSource

/// Source type for a cue sheet.
///
/// Tracks where cues originated from to support sync with external systems.
enum CueSheetSource: Codable, Equatable {
    /// Created locally within the app
    case local

    /// Imported from or synced with Google Sheets
    case googleSheets(sheetId: String, range: String)

    /// Imported from a CSV file
    case csv(url: URL)
}
