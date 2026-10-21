import Foundation

// MARK: - Shared Display Text

extension MediaItem {
    /// Resolution for video, channel layout for audio; `nil` when never read.
    var formatText: String? {
        type == .video ? dimensionsString : audioFormatString
    }

    /// The Format cell's text.
    var formatDisplayText: String { formatText ?? MediaListText.unknown }

    /// Frame rate for video, sample rate (Hz) for audio; `nil` when never read.
    /// The Rate column sorts by this value directly.
    var rateValue: Double? {
        let value = type == .video ? frameRate : sampleRate
        guard let value, value > 0 else { return nil }
        return value
    }

    /// The Rate cell's text.
    var rateDisplayText: String {
        guard let value = rateValue else { return MediaListText.unknown }
        return type == .video ? MediaListText.frameRate(value) : MediaListText.sampleRate(value)
    }

    /// The codec as read at import. For audio the container names the format
    /// (WAV is PCM, M4A is AAC); for video it does not - a .mov can hold H.264,
    /// ProRes or DNxHR - so an unread video codec is `nil`, shown as unknown.
    var codecText: String? {
        if let codecName { return codecName }
        return type == .audio ? fileExtension.uppercased() : nil
    }

    /// The Codec cell's text.
    var codecDisplayText: String { codecText ?? MediaListText.unknown }

    /// The Status cell's text; `nil` (a blank cell) when there is nothing to say.
    var statusText: String? {
        switch OptimizationStatusHelper.status(for: self) {
        case .optimized: return MediaListText.optimized
        case .needsOptimization(let reason): return reason.shortLabel
        case .noAction: return nil
        }
    }
}

// MARK: - Sort

/// How the media list is ordered once the user has clicked a column title.
///
/// Until then the media panel uses ``standard``: Name, A at the top. Pure value
/// logic with no UI, so the ordering rules can be tested directly.
///
/// Behaves like an `NSTableView` sort descriptor or Finder's list view:
/// - Each column sorts by one key. Name, Format, Codec and Status compare the
///   text the cell displays with `localizedStandardCompare`; Duration, Rate
///   (fps for video, Hz for audio) and Bitrate compare numbers.
/// - A missing value (nil or never read) compares as the smallest, as Foundation
///   sort descriptors treat nil: first ascending, last descending.
/// - Descending is exactly the reverse of ascending.
/// - Ties break by name ascending, then by id, in both directions, so the order
///   is stable.
struct MediaListSort: Equatable {
    /// The column being sorted on.
    var column: MediaListColumn

    /// `true` for A to Z / smallest first.
    var ascending: Bool

    /// What one item contributes to a column's comparison.
    private enum Key {
        /// The file never said. Compares smaller than every present value.
        case missing
        case number(Double)
        /// Text compared the way Finder compares names.
        case text(String)
    }

    /// The order in effect before any column title has been clicked: Name, A to Z.
    static let standard = MediaListSort(column: .name, ascending: true)

    // MARK: Clicking

    /// The sort that results from clicking a column title.
    ///
    /// A new column starts ascending; clicking the active column flips direction.
    ///
    /// - Parameters:
    ///   - column: The column whose title was clicked.
    ///   - current: The sort in effect, or `nil` for none, which starts the clicked column ascending.
    /// - Returns: The sort to apply.
    static func afterClicking(_ column: MediaListColumn, current: MediaListSort?) -> MediaListSort {
        guard let current, current.column == column else {
            return MediaListSort(column: column, ascending: true)
        }
        return MediaListSort(column: column, ascending: !current.ascending)
    }

    // MARK: Ordering

    /// Returns `items` in this sort's order.
    ///
    /// - Parameter items: The items to order.
    /// - Returns: A new array; the input is not modified.
    func sorted(_ items: [MediaItem]) -> [MediaItem] {
        items.sorted(by: areInOrder)
    }

    /// Whether `lhs` belongs before `rhs`.
    ///
    /// - Parameters:
    ///   - lhs: The first item.
    ///   - rhs: The second item.
    /// - Returns: `true` when `lhs` sorts first.
    func areInOrder(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        let primary = compare(key(for: lhs), key(for: rhs))
        if primary != .orderedSame {
            return (primary == .orderedAscending) == ascending
        }
        return breaksTie(lhs, rhs)
    }

    /// Ascending comparison of two keys; missing is smaller than anything present.
    private func compare(_ lhs: Key, _ rhs: Key) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.missing, .missing):
            return .orderedSame
        case (.missing, _):
            return .orderedAscending
        case (_, .missing):
            return .orderedDescending
        case let (.number(lhsValue), .number(rhsValue)):
            if lhsValue == rhsValue { return .orderedSame }
            return lhsValue < rhsValue ? .orderedAscending : .orderedDescending
        case let (.text(lhsText), .text(rhsText)):
            return lhsText.localizedStandardCompare(rhsText)
        default:
            return .orderedSame
        }
    }

    /// Name ascending, then id. Independent of direction so equal rows do not
    /// reshuffle when the direction flips.
    private func breaksTie(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        let result = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if result != .orderedSame { return result == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func key(for item: MediaItem) -> Key {
        switch column {
        case .name:
            return .text(item.displayName)
        case .duration:
            return .number(item.duration)
        case .format:
            return item.formatText.map(Key.text) ?? .missing
        case .rate:
            return item.rateValue.map(Key.number) ?? .missing
        case .codec:
            return item.codecText.map(Key.text) ?? .missing
        case .bitrate:
            return item.bitrate.map { Key.number(Double($0)) } ?? .missing
        case .status:
            return item.statusText.map(Key.text) ?? .missing
        }
    }

    // MARK: Storage

    /// Separates column and direction in the stored form.
    private static let storageSeparator = ":"
    private static let ascendingToken = "asc"
    private static let descendingToken = "desc"

    /// The stored form, e.g. `"name:asc"`.
    var storage: String {
        [column.rawValue, ascending ? Self.ascendingToken : Self.descendingToken]
            .joined(separator: Self.storageSeparator)
    }

    /// Restores a sort from its stored form.
    ///
    /// - Parameter storage: A string produced by ``storage``.
    /// - Returns: The sort, or `nil` for empty or unreadable text. See
    ///   ``restoredOrStandard(from:)`` for the form that falls back to ``standard``.
    static func restored(from storage: String) -> MediaListSort? {
        let parts = storage.components(separatedBy: storageSeparator)
        guard parts.count == 2,
              let column = MediaListColumn(rawValue: parts[0]),
              parts[1] == ascendingToken || parts[1] == descendingToken else { return nil }
        return MediaListSort(column: column, ascending: parts[1] == ascendingToken)
    }

    /// Restores a sort from its stored form, falling back to ``standard``.
    ///
    /// - Parameter storage: A string produced by ``storage``, possibly empty or garbage.
    /// - Returns: The stored sort, or ``standard`` when the text is empty or unreadable.
    static func restoredOrStandard(from storage: String) -> MediaListSort {
        restored(from: storage) ?? standard
    }
}
