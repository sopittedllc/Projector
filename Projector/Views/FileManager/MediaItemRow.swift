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

// The media panel renders `MediaGridCell` (FileManagerView.swift). Any row view
// added here must begin drags through the multi-item path, or a multi-selection
// drops as a single clip.
