import SwiftUI
import Foundation
import UniformTypeIdentifiers

/// Builds the drag payload for a media item.
///
/// The payload carries a single file URL. A multi-item drag is represented by
/// `DragContext`, which the drop handlers consult first - the pasteboard alone
/// cannot express a selection of more than one file.
enum MediaDragProvider {
    static func provider(for item: MediaItem) -> NSItemProvider {
        let provider = NSItemProvider(item: item.url as NSURL, typeIdentifier: UTType.fileURL.identifier)
        provider.suggestedName = item.url.lastPathComponent
        if item.type == .audio {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.audio.identifier, visibility: .all) { completion in
                completion(Data(), nil)
                return nil
            }
        } else if item.type == .video {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.movie.identifier, visibility: .all) { completion in
                completion(Data(), nil)
                return nil
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: [
            "id": item.id.uuidString,
            "url": item.url.absoluteString,
            "type": item.type.rawValue,
            "duration": item.duration
        ]) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.projectorMediaItem.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }
}

extension UTType {
    static let projectorMediaItem = UTType(exportedAs: "com.projector.media-item")
}

// The media panel renders `MediaGridCell` (FileManagerView.swift) or
// `MediaListRow` (below). Any further row view must begin drags through the
// multi-item path, or a multi-selection drops as a single clip.

// MARK: - List View

/// How the media panel lays out its items.
enum MediaPanelViewMode: String {
    /// Thumbnails filling columns, scrolling sideways.
    case grid
    /// One row per file with its technical details, scrolling down.
    case list
}

/// A column of the media list, in display order.
enum MediaListColumn: String, CaseIterable, Codable {
    case name, duration, format, rate, codec, bitrate, status

    var title: String {
        switch self {
        case .name: return "Name"
        case .duration: return "Duration"
        case .format: return "Format"
        case .rate: return "Rate"
        case .codec: return "Codec"
        case .bitrate: return "Bitrate"
        case .status: return "Status"
        }
    }

    /// Width before the user has resized anything.
    var defaultWidth: CGFloat {
        switch self {
        case .name: return FileManagerLayout.listNameDefaultWidth
        case .duration: return FileManagerLayout.listDurationWidth
        case .format: return FileManagerLayout.listFormatWidth
        case .rate: return FileManagerLayout.listRateWidth
        case .codec: return FileManagerLayout.listCodecWidth
        case .bitrate: return FileManagerLayout.listBitrateWidth
        case .status: return FileManagerLayout.listStatusWidth
        }
    }

    /// Narrowest a column can be dragged.
    var minimumWidth: CGFloat {
        self == .name ? FileManagerLayout.listNameMinWidth : FileManagerLayout.listColumnMinWidth
    }
}

/// The media list's column widths, as the user has dragged them.
///
/// Stored as JSON in user defaults: a viewing preference, like the grid/list choice,
/// so it belongs to the app rather than to any one project.
struct MediaListColumnWidths: Equatable {
    private var widths: [MediaListColumn: CGFloat] = [:]

    subscript(column: MediaListColumn) -> CGFloat {
        get { widths[column] ?? column.defaultWidth }
        set { widths[column] = max(column.minimumWidth, newValue) }
    }

    /// Width of every column plus the gaps between them.
    var totalWidth: CGFloat {
        MediaListColumn.allCases.reduce(0) { $0 + self[$1] }
            + Spacing.sm * CGFloat(MediaListColumn.allCases.count - 1)
    }

    /// Restores widths from their stored form. Unreadable data yields the defaults.
    init(storage: String = "") {
        guard let data = storage.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else { return }
        for (key, width) in decoded {
            if let column = MediaListColumn(rawValue: key) { self[column] = CGFloat(width) }
        }
    }

    /// The stored form: JSON keyed by column name.
    var storage: String {
        let plain = Dictionary(uniqueKeysWithValues: widths.map { ($0.key.rawValue, Double($0.value)) })
        guard let data = try? JSONEncoder().encode(plain) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Column titles above the media list, each with a handle on its trailing edge
/// that resizes it.
struct MediaListHeader: View {
    @Binding var widths: MediaListColumnWidths
    /// The active sort, or `nil` while the list is in its default order.
    let sort: MediaListSort?
    /// Called when a column title is clicked.
    let onSort: (MediaListColumn) -> Void
    /// Called when a resize drag ends, so the widths are stored once, not per frame.
    let onResizeEnded: () -> Void

    /// Width of a column when its current drag began.
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MediaListColumn.allCases, id: \.self) { column in
                titleButton(for: column)
                resizeHandle(for: column)
            }
        }
        .font(Typography.label)
        .foregroundColor(.secondary)
        .padding(.horizontal, Spacing.sm)
        .frame(height: FileManagerLayout.listRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    /// A column title that sorts the list when clicked, with a chevron on the
    /// active column showing the direction. The chevron points the way the
    /// values run down the list, as Finder's does: down for A at the top.
    private func titleButton(for column: MediaListColumn) -> some View {
        let activeSort = sort?.column == column ? sort : nil
        return Button(action: { onSort(column) }) {
            HStack(spacing: Spacing.xs) {
                Text(column.title)
                    .lineLimit(1)
                if let activeSort {
                    Image(systemName: activeSort.ascending ? "chevron.down" : "chevron.up")
                        .font(Typography.caption)
                }
            }
            .foregroundColor(activeSort == nil ? .secondary : .primary)
            .frame(width: widths[column], alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(column.title)")
        .accessibilityValue(activeSort.map { $0.ascending ? "ascending" : "descending" } ?? "")
    }

    /// The gap after a column, which is also its grab area. It is exactly the
    /// rows' column spacing, so header and rows stay aligned.
    private func resizeHandle(for column: MediaListColumn) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: Spacing.sm)
            .overlay(Divider().frame(height: FileManagerLayout.listHeaderDividerHeight))
            .contentShape(Rectangle())
            .cursor(.resizeLeftRight)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartWidth ?? widths[column]
                        dragStartWidth = start
                        widths[column] = start + value.translation.width
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        onResizeEnded()
                    }
            )
            .help("Drag to resize \(column.title)")
    }
}

/// One media file as a row of the media list.
///
/// Selection, double-click and dragging behave exactly as they do on
/// `MediaGridCell`; in particular a drag starts through `DragContext`, so a
/// multi-selection drops as every selected file, not just the one under the cursor.
struct MediaListRow: View {
    let item: MediaItem
    let widths: MediaListColumnWidths
    let isSelected: Bool
    /// Draws the alternate-row stripe.
    let isStriped: Bool
    /// All selected items (for multi-select drag support)
    let selectedItems: [MediaItem]
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    let onDragStateChange: (Bool) -> Void

    @State private var isDragging = false
    @EnvironmentObject private var dragContext: DragContext

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Spacing.sm) {
                // Every column always draws a cell, even an empty one. A missing
                // cell shortens the row and shifts every column after it.
                ForEach(MediaListColumn.allCases, id: \.self) { column in
                    cell(for: column)
                        .frame(width: widths[column], alignment: .leading)
                }
            }
            .padding(.horizontal, Spacing.sm)
            .frame(height: FileManagerLayout.listRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded { _ in
                    onDoubleClick()
                }
        )
        .opacity(isDragging ? 0.5 : 1.0)
        .onDrag {
            isDragging = true
            onDragStateChange(true)
            dragContext.begin(selectedItems)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isDragging = false
            }
            return MediaDragProvider.provider(for: item)
        }
        .help(item.url.lastPathComponent)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.2) }
        return isStriped ? Color.primary.opacity(FileManagerLayout.listStripeOpacity) : .clear
    }

    @ViewBuilder
    private func cell(for column: MediaListColumn) -> some View {
        switch column {
        case .name:
            nameCell
        case .status:
            statusCell
        default:
            Text(text(for: column))
                .font(Typography.bodySmall)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .monospacedDigit()
        }
    }

    private var nameCell: some View {
        HStack(spacing: Spacing.sm) {
            thumbnail
            Text(item.displayName)
                .font(Typography.body)
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var thumbnail: some View {
        Group {
            if let data = item.thumbnailData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(
                        Image(systemName: item.type == .video ? "video" : "music.note.list")
                            .font(Typography.caption)
                            .foregroundColor(.secondary)
                    )
            }
        }
        .frame(width: FileManagerLayout.listThumbnailWidth, height: FileManagerLayout.listThumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.xs / 2))
    }

    /// Optimization state, worded the way the grid badge's tooltip words it.
    /// Blank, not absent, when there is nothing to say.
    @ViewBuilder
    private var statusCell: some View {
        switch OptimizationStatusHelper.status(for: item) {
        case .optimized:
            Text(MediaListText.optimized)
                .font(Typography.bodySmall)
                .foregroundColor(.secondary)
        case .needsOptimization(let reason):
            Label(reason.shortLabel, systemImage: reason.icon)
                .font(Typography.bodySmall)
                .foregroundColor(reason.color)
                .lineLimit(1)
                .help("\(reason.shortLabel) - optimization recommended")
        case .noAction:
            Color.clear
        }
    }

    private func text(for column: MediaListColumn) -> String {
        switch column {
        case .duration:
            return item.formattedDuration
        case .format:
            return item.formatDisplayText
        case .rate:
            return item.rateDisplayText
        case .codec:
            return item.codecDisplayText
        case .bitrate:
            return item.formattedBitrate ?? MediaListText.unknown
        case .name, .status:
            return ""
        }
    }
}

/// Wording for media list cells.
enum MediaListText {
    /// Shown where a detail was never read from the file.
    static let unknown = "—"

    /// The Status cell's text for an already optimized item.
    static let optimized = "Optimized"

    private static let hertzPerKilohertz = 1000.0

    /// "24 fps", "23.976 fps", "29.97 fps": up to three places, trailing zeros dropped.
    static func frameRate(_ fps: Double) -> String {
        var formatted = String(format: "%.3f", fps)
        while formatted.hasSuffix("0") { formatted.removeLast() }
        if formatted.hasSuffix(".") { formatted.removeLast() }
        return "\(formatted) fps"
    }

    /// "48 kHz", "44.1 kHz".
    static func sampleRate(_ hertz: Double) -> String {
        let kilohertz = hertz / hertzPerKilohertz
        let formatted = kilohertz.rounded() == kilohertz
            ? String(Int(kilohertz))
            : String(format: "%.1f", kilohertz)
        return "\(formatted) kHz"
    }
}
