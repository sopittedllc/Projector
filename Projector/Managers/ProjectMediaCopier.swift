//
//  ProjectMediaCopier.swift
//  Projector
//
//  Copies imported media into the project's Media folder.
//  Logic layer: no SwiftUI.
//

import Foundation
import Darwin

// MARK: - Constants

/// Tunables for copying media into a project.
enum MediaCopyConstants {
    /// Bytes of headroom required on the destination volume beyond the file itself.
    ///
    /// A copy that fills the disk to the last byte leaves the Mac - and the
    /// project's own save - unable to write anything, so the check asks for more
    /// than the file needs.
    static let freeSpaceMargin: Int64 = 512 * 1024 * 1024

    /// Smallest change in copied bytes worth reporting.
    ///
    /// `copyfile` calls back once per megabyte. Forwarding each one would flood
    /// the main actor for a multi-gigabyte file with updates nobody can see.
    static let progressReportStride: Int64 = 8 * 1024 * 1024

    /// Prefix of the hidden name a copy has while it is still being written.
    static let partialPrefix = "."

    /// Marks a hidden name as one this app made, between the file's name and a
    /// per-copy token.
    ///
    /// Specific on purpose: the stale-file sweep deletes whatever matches, so it
    /// must not match a file a user happens to call `.something.partial`.
    static let partialMarker = ".projector-copy-"

    /// Suffix of the hidden name a copy has while it is still being written.
    static let partialSuffix = ".partial"
}

// MARK: - Progress

/// How far along the file currently being copied is.
struct MediaCopyProgress: Sendable, Equatable {
    /// The file being copied (the original, not the copy).
    let sourceURL: URL

    /// Bytes written so far.
    let bytesCopied: Int64

    /// Size of the source file.
    let bytesTotal: Int64
}

// MARK: - Errors

/// Why a file could not be copied into the project.
enum MediaCopyError: LocalizedError, Equatable {
    /// The source cannot be read: missing, offline, or no permission.
    case sourceUnreadable

    /// The destination volume does not have room for the file.
    case insufficientSpace(needed: Int64, available: Int64)

    /// The copy was cancelled before it finished.
    case cancelled

    /// The system reported an error while copying.
    case copyFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .sourceUnreadable:
            return "The file could not be read. It may have moved or its drive may be disconnected."
        case .insufficientSpace(let needed, let available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "Not enough free space (needs \(formatter.string(fromByteCount: needed)), "
                + "\(formatter.string(fromByteCount: max(available, 0))) available)."
        case .cancelled:
            return "The copy was cancelled."
        case .copyFailed(let code):
            return "The copy failed: \(String(cString: strerror(code)))."
        }
    }
}

// MARK: - Cancellation / progress state shared with the copy thread

/// State shared between the actor and the blocking `copyfile` call.
///
/// `copyfile` runs on its own thread and calls back from it, so the cancel flag
/// is lock-protected. The progress fields are touched only from that thread.
private final class CopyContext: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    /// Last byte count forwarded, so reports go out in strides.
    var lastReported: Int64 = 0

    /// Forwards a byte count to whoever is watching.
    let onProgress: @Sendable (Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64) -> Void) {
        self.onProgress = onProgress
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

// MARK: - ProjectMediaCopier

/// Copies media files into a project's `Media/` folder.
///
/// Every imported file is brought into the project so the project does not
/// depend on whatever drive or folder the file was dropped from. This actor is
/// the copy itself; deciding *which* files, and repointing the timeline at the
/// result, belongs to `MediaCopyInCoordinator`.
///
/// ## How a file is copied
///
/// - On the same APFS volume the file is **cloned**: instant, and it costs no
///   extra space. Anywhere else it is a byte copy with progress.
/// - The copy is written to a hidden `.<name>.projector-copy-<UUID>.partial` file in
///   `Media/` and renamed when complete, so a half-written file is never mistaken
///   for a finished one. ``sweepStalePartials(projectURL:)`` removes any a crash left
///   behind - only names of exactly that shape, and never one being written now.
/// - Free space on the destination is checked first when the copy will use space.
///
/// ## Progress
///
/// ``progressUpdates`` reports bytes for the file in flight. It is lossy by
/// design (newest value wins) - the caller knows when a file finishes because
/// ``copyIn(_:projectURL:)`` returns.
///
/// ## Concurrency
///
/// `copyfile` blocks for the whole copy, so it runs on a detached task rather
/// than inside actor isolation. Cancelling the task that called ``copyIn(_:projectURL:)``
/// stops the copy between megabytes and removes the partial file.
actor ProjectMediaCopier {

    // MARK: Progress stream

    /// Progress of the file currently being copied.
    nonisolated let progressUpdates: AsyncStream<MediaCopyProgress>

    private nonisolated let progressContinuation: AsyncStream<MediaCopyProgress>.Continuation

    // MARK: In-flight bookkeeping

    /// Paths of the `.partial` files being written right now, which the sweep must leave alone.
    private var activePartialPaths: Set<String> = []

    /// Paths of destinations claimed by copies in flight, so two copies never take one name.
    private var reservedDestinationPaths: Set<String> = []

    // MARK: Initialization

    /// Creates a copier with its own progress stream.
    init() {
        var captured: AsyncStream<MediaCopyProgress>.Continuation?
        progressUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { captured = $0 }
        guard let continuation = captured else {
            // `AsyncStream` runs its build closure synchronously, so this cannot happen.
            preconditionFailure("AsyncStream did not provide a continuation")
        }
        progressContinuation = continuation
    }

    deinit {
        progressContinuation.finish()
    }

    // MARK: Copying

    /// Copies a file into the project's Media folder.
    ///
    /// - Parameters:
    ///   - url: The file to bring in.
    ///   - projectURL: The `.projector` package.
    /// - Returns: The copy's URL, or `url` unchanged if it is already inside the
    ///   project.
    /// - Throws: ``MediaCopyError`` if the file cannot be read, will not fit, or
    ///   the copy fails or is cancelled. Nothing is left behind in `Media/` on failure.
    func copyIn(_ url: URL, projectURL: URL) async throws -> URL {
        if ProjectFolders.contains(url, projectURL: projectURL) { return url }

        let fileManager = FileManager.default
        let mediaFolder = ProjectFolders.mediaFolder(forProjectAt: projectURL)
        try fileManager.createDirectory(at: mediaFolder, withIntermediateDirectories: true)

        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard fileManager.isReadableFile(atPath: url.path) else {
            throw MediaCopyError.sourceUnreadable
        }

        let size = Self.fileSize(of: url)
        try Self.checkFreeSpace(forCopyOf: url, size: size, into: mediaFolder)

        let destination = Self.uniqueDestination(for: url, in: mediaFolder, reserved: reservedDestinationPaths)
        let partial = Self.partialURL(for: destination)
        reservedDestinationPaths.insert(destination.path)
        activePartialPaths.insert(partial.path)
        defer {
            reservedDestinationPaths.remove(destination.path)
            activePartialPaths.remove(partial.path)
        }

        let continuation = progressContinuation
        let context = CopyContext { copied in
            continuation.yield(MediaCopyProgress(sourceURL: url, bytesCopied: copied, bytesTotal: size))
        }

        do {
            let wasCloned = try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) {
                    try Self.runCopy(from: url, to: partial, context: context)
                }.value
            } onCancel: {
                context.cancel()
            }
            // A clone is one atomic call, so it can finish after cancellation
            // arrived. The copy exists only because of this call; take it back
            // rather than leave a file in Media/ that nothing refers to.
            if context.isCancelled || Task.isCancelled {
                throw MediaCopyError.cancelled
            }
            try fileManager.moveItem(at: partial, to: destination)
            diagnosticLog(
                .info, .media,
                "Copied \(url.lastPathComponent) into project Media (\(wasCloned ? "clone" : "byte copy"))"
            )
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }

        continuation.yield(MediaCopyProgress(sourceURL: url, bytesCopied: size, bytesTotal: size))
        return destination
    }

    /// Deletes copies a previous session left unfinished.
    ///
    /// Call when a project opens, and finish it before queueing any copy. Only files
    /// named exactly like this copier's in-progress files (see ``isPartialName(_:)``)
    /// are removed, and never one this actor is writing now, so a user's own file
    /// that merely ends in `.partial` is safe.
    ///
    /// - Parameter projectURL: The `.projector` package.
    /// - Returns: How many stale files were removed.
    @discardableResult
    func sweepStalePartials(projectURL: URL) -> Int {
        let fileManager = FileManager.default
        let mediaFolder = ProjectFolders.mediaFolder(forProjectAt: projectURL)
        guard let names = try? fileManager.contentsOfDirectory(atPath: mediaFolder.path) else { return 0 }

        var removed = 0
        for name in names where Self.isPartialName(name) {
            let url = mediaFolder.appendingPathComponent(name)
            guard !activePartialPaths.contains(url.path) else { continue }
            if (try? fileManager.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }

    // MARK: Naming

    /// Where a copy of `source` should land in `folder`.
    ///
    /// Keeps the file's own name; on a clash appends `_1`, `_2`, ... before the
    /// extension. A name is also taken while another copy in flight has claimed it
    /// (`reserved`), so two copies never race for one name.
    ///
    /// - Parameters:
    ///   - source: The file being copied.
    ///   - folder: The destination folder.
    ///   - reserved: Paths claimed by copies still being written.
    /// - Returns: A URL in `folder` that nothing occupies.
    nonisolated static func uniqueDestination(
        for source: URL,
        in folder: URL,
        reserved: Set<String> = []
    ) -> URL {
        let fileManager = FileManager.default
        let baseName = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension

        func candidate(_ counter: Int) -> URL {
            let name: String
            if counter == 0 {
                name = source.lastPathComponent
            } else {
                name = ext.isEmpty ? "\(baseName)_\(counter)" : "\(baseName)_\(counter).\(ext)"
            }
            return folder.appendingPathComponent(name)
        }

        var counter = 0
        var destination = candidate(counter)
        while fileManager.fileExists(atPath: destination.path)
            || reserved.contains(destination.path) {
            counter += 1
            destination = candidate(counter)
        }
        return destination
    }

    /// The hidden in-progress name for a destination.
    ///
    /// - Parameters:
    ///   - destination: The final URL of the copy.
    ///   - token: Makes the name unique to one copy; defaults to a fresh UUID.
    /// - Returns: A sibling URL named `.<name>.projector-copy-<token>.partial`.
    nonisolated static func partialURL(for destination: URL, token: UUID = UUID()) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            MediaCopyConstants.partialPrefix + destination.lastPathComponent
                + MediaCopyConstants.partialMarker + token.uuidString
                + MediaCopyConstants.partialSuffix
        )
    }

    /// Whether a file name is exactly the shape of an in-progress copy this app writes.
    ///
    /// The shape is `.<name>.projector-copy-<UUID>.partial`. Anything looser - any
    /// hidden file ending in `.partial` - could be a user's own file, and the sweep
    /// deletes whatever this accepts.
    ///
    /// - Parameter name: A file name (not a path) from the `Media/` folder.
    /// - Returns: `true` only for names ``partialURL(for:token:)`` could have produced.
    nonisolated static func isPartialName(_ name: String) -> Bool {
        guard name.hasPrefix(MediaCopyConstants.partialPrefix),
              name.hasSuffix(MediaCopyConstants.partialSuffix) else { return false }
        let stem = name
            .dropFirst(MediaCopyConstants.partialPrefix.count)
            .dropLast(MediaCopyConstants.partialSuffix.count)
        guard let marker = stem.range(of: MediaCopyConstants.partialMarker, options: .backwards),
              marker.lowerBound > stem.startIndex else { return false }
        return UUID(uuidString: String(stem[marker.upperBound...])) != nil
    }

    // MARK: Helpers

    private nonisolated static func fileSize(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Throws if the copy will use disk space the destination volume lacks.
    ///
    /// A clone on the same volume costs nothing, so the check applies only when
    /// the volumes differ. If a same-volume copy turns out not to clone (a
    /// non-APFS volume), running out of space surfaces from the copy itself.
    private nonisolated static func checkFreeSpace(forCopyOf source: URL, size: Int64, into folder: URL) throws {
        let sourceVolume = try? source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let folderVolume = try? folder.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        if let sourceVolume, let folderVolume, sourceVolume.isEqual(folderVolume) { return }

        guard let available = try? folder
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { return }

        if available < size + MediaCopyConstants.freeSpaceMargin {
            throw MediaCopyError.insufficientSpace(needed: size + MediaCopyConstants.freeSpaceMargin, available: available)
        }
    }

    /// Runs `copyfile`, blocking until it finishes.
    ///
    /// - Returns: Whether the data was cloned rather than copied.
    private nonisolated static func runCopy(from source: URL, to destination: URL, context: CopyContext) throws -> Bool {
        guard let state = copyfile_state_alloc() else {
            throw MediaCopyError.copyFailed(code: ENOMEM)
        }
        defer { copyfile_state_free(state) }

        // `copyfile` reports data progress for a single file too, once per
        // megabyte (verified for a cross-volume copy; a clone reports nothing
        // because it is one atomic operation).
        let callback: copyfile_callback_t = { what, stage, callbackState, _, _, rawContext in
            guard let rawContext else { return COPYFILE_CONTINUE }
            let context = Unmanaged<CopyContext>.fromOpaque(rawContext).takeUnretainedValue()
            if context.isCancelled { return COPYFILE_QUIT }

            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let callbackState {
                var copied: off_t = 0
                copyfile_state_get(callbackState, UInt32(COPYFILE_STATE_COPIED), &copied)
                let bytes = Int64(copied)
                if bytes - context.lastReported >= MediaCopyConstants.progressReportStride {
                    context.lastReported = bytes
                    context.onProgress(bytes)
                }
            }
            return COPYFILE_CONTINUE
        }

        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())

        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE)
        let result = copyfile(source.path, destination.path, state, flags)
        let failureCode = errno

        guard result == 0 else {
            try? FileManager.default.removeItem(at: destination)
            if context.isCancelled || failureCode == ECANCELED { throw MediaCopyError.cancelled }
            if failureCode == ENOSPC {
                let folder = destination.deletingLastPathComponent()
                let available = (try? folder
                    .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage) ?? 0
                throw MediaCopyError.insufficientSpace(needed: fileSize(of: source), available: available)
            }
            throw MediaCopyError.copyFailed(code: failureCode)
        }

        var cloned: Int32 = 0
        copyfile_state_get(state, UInt32(COPYFILE_STATE_WAS_CLONED), &cloned)
        return cloned != 0
    }
}
