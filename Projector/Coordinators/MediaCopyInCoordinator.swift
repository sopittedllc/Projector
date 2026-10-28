//
//  MediaCopyInCoordinator.swift
//  Projector
//
//  Queues imported media for copying into the project and repoints the library,
//  timeline reels and audio clips at the copies.
//

import Foundation
import Combine

// MARK: - Constants

/// Tunables for the copy-in coordinator.
enum MediaCopyInConstants {
    /// How long the "Copied N files" note stays up after a batch finishes.
    static let finishedNoteDuration: TimeInterval = 6

    /// Nanoseconds in a second, for `Task.sleep`.
    static let nanosecondsPerSecond: Double = 1_000_000_000

    /// Why Optimize is unavailable while media is being copied in.
    static let optimizeBlockedHelp = "Waiting for media to finish copying into the project"
}

// MARK: - Failure

/// A file that could not be brought into the project and stays where it was.
struct MediaCopyFailure: Equatable {
    /// File name of the original.
    let name: String

    /// Why the copy failed, in words for the user.
    let reason: String

    /// Lists failed files for an alert body.
    ///
    /// - Parameter failures: The files that could not be copied.
    /// - Returns: One `name: reason` line per failure, in order, separated by newlines.
    static func summary(of failures: [MediaCopyFailure]) -> String {
        failures.map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
    }
}

// MARK: - Coordinator

/// Brings every imported file into the project's `Media/` folder and keeps every
/// reference to it pointing at the copy.
///
/// ## The flow
///
/// Import stays instant: a file is placed and plays from wherever it was dropped
/// from. Importing it also queues it here; when its copy finishes, the media
/// library item, every video reel and every audio clip (including a video's own
/// audio) that referenced the original are repointed at the copy - the same swap
/// `OptimizationViewModel.updateReferences` performs for optimized media.
/// The project is then saved once the queue drains, so the new paths survive a quit.
///
/// ## Why there is no watch list
///
/// A clone finishes in milliseconds - often before the caller that imported the
/// file has added its reel. Two rules cover every ordering, with no timer:
///
/// 1. Callers place using the library item's *current* URL (the copy if it has landed,
///    otherwise the original), and call ``settle(itemID:placedAt:)`` once the reel or
///    clip exists. If the copy landed during the placement's awaits, settle moves what
///    was just created onto the copy. A duplicate drop or a late reel therefore
///    never names an outside file once a copy exists.
/// 2. When a copy lands, ``apply(_:copyURL:)`` repoints everything that exists then.
///
/// A reel created after a copy lands names the copy (rule 1); one created before is
/// repointed on landing (rule 2); one created in between is caught by settle.
///
/// ## Optimize
///
/// Optimizing reads and may move the files the library names, and an item mid-copy
/// still names the user's original on an outside drive. ``isCopying`` is true until
/// the queue drains; the optimize UI is disabled meanwhile.
///
/// ## Untitled projects
///
/// Nothing can be copied until the project has a folder, so the view layer asks for
/// a save before it lets an import start. If a file arrives anyway it simply stays
/// external until the project is next opened, when ``projectOpened()`` brings it in.
@MainActor
final class MediaCopyInCoordinator: ObservableObject {

    // MARK: - Types

    /// What the media bay should show.
    enum Status: Equatable {
        /// Nothing is being copied.
        case idle
        /// Files are being copied.
        case copying(filesTotal: Int, filesDone: Int, fraction: Double)
        /// A batch just finished.
        case finished(count: Int)
    }

    /// One file waiting to be copied.
    private struct Job {
        /// The file being brought in.
        let source: URL
        /// The library item to repoint, if the file came from one.
        let itemID: UUID?
        /// Other library items with the same source, repointed when this job lands.
        var extraItemIDs: [UUID] = []
        /// Size of the source, for progress. Known once ``scanned``.
        var bytes: Int64 = 0
        /// Size and date of the source before it was copied. Known once ``scanned``.
        var fingerprint: MediaFingerprint?
        /// Whether the file has been read off the main actor for ``bytes`` and ``fingerprint``.
        var scanned = false
    }

    /// A library item already inside the project, offered as a possible earlier copy.
    private struct CopyCandidate: Sendable {
        let url: URL
        let importedFrom: URL?
        let fingerprint: MediaFingerprint?
    }

    /// What the disk said about the outside media, read off the main actor.
    private struct Survey: Sendable {
        struct Item: Sendable {
            let id: UUID
            let url: URL
        }
        struct Reference: Sendable {
            let source: URL
            let existingCopy: URL?
        }
        var items: [Item] = []
        var references: [Reference] = []
    }

    // MARK: - Published State

    /// Progress for the media bay's note.
    @Published private(set) var status: Status = .idle

    /// Whether any file is waiting to be copied or being copied.
    ///
    /// Observable through ``status``: views and view models that watch the status see
    /// this change.
    var isCopying: Bool {
        if case .copying = status { return true }
        return false
    }

    // MARK: - Callbacks

    /// Called once per batch with the files that could not be copied.
    var onFailures: (([MediaCopyFailure]) -> Void)?

    // MARK: - Dependencies

    private let mediaLibrary: ProjectMediaLibrary
    private let timelineManager: TimelineManager
    private let projectDocument: ProjectDocument
    private let copier: ProjectMediaCopier

    // MARK: - Queue State

    private var queue: [Job] = []
    private var inFlight: Job?
    private var worker: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    /// Bumped when a different project replaces this one, so work for the old
    /// project knows to stand down.
    private var generation = 0

    // MARK: - Batch Accounting

    private var batchFilesTotal = 0
    private var batchFilesDone = 0
    private var batchCopied = 0
    private var batchBytesTotal: Int64 = 0
    private var batchBytesDone: Int64 = 0
    private var currentFileBytes: Int64 = 0
    private var batchFailures: [MediaCopyFailure] = []
    private var finishedNoteToken = UUID()

    // MARK: - Initialization

    /// Creates the coordinator and starts watching the library and timeline.
    ///
    /// - Parameters:
    ///   - mediaLibrary: The project's media library.
    ///   - timelineManager: The timeline whose reels and clips are repointed.
    ///   - projectDocument: Supplies the project location and is saved after a batch.
    ///   - copier: The copy service; injectable for tests.
    init(
        mediaLibrary: ProjectMediaLibrary,
        timelineManager: TimelineManager,
        projectDocument: ProjectDocument,
        copier: ProjectMediaCopier = ProjectMediaCopier()
    ) {
        self.mediaLibrary = mediaLibrary
        self.timelineManager = timelineManager
        self.projectDocument = projectDocument
        self.copier = copier

        let updates = copier.progressUpdates
        progressTask = Task { [weak self] in
            for await progress in updates {
                self?.receive(progress)
            }
        }
    }

    deinit {
        progressTask?.cancel()
    }

    // MARK: - Entry Points

    /// Queues a newly imported item for copying.
    ///
    /// Does nothing if the project is unsaved (there is no folder yet) or the
    /// file is already inside the project.
    ///
    /// - Parameter item: The item `ProjectMediaLibrary` just imported.
    func enqueue(_ item: MediaItem) {
        add(source: item.url, itemID: item.id)
    }

    /// Queues everything the project references from outside its folders.
    ///
    /// Covers library items and any reel or clip still naming an outside file -
    /// which includes projects "consolidated" by the old Consolidate Media, whose
    /// timeline kept the original paths. Files that cannot be read are skipped; the
    /// missing-file flow owns those. The disk is read off the main actor.
    func enqueueExternalMedia() async {
        guard let projectURL = projectDocument.fileURL else { return }
        let started = generation

        let libraryItems = mediaLibrary.externalMediaItems(projectURL: projectURL)
            .map { Survey.Item(id: $0.id, url: $0.url) }
        let referencedSources = referencedExternalSources(projectURL: projectURL)
        let candidates = mediaLibrary.items
            .filter { ProjectFolders.contains($0.url, projectURL: projectURL) }
            .map { CopyCandidate(url: $0.url, importedFrom: $0.importedFromURL, fingerprint: $0.importedFingerprint) }

        let survey = await Task.detached(priority: .utility) {
            Self.survey(items: libraryItems, referencedSources: referencedSources, candidates: candidates)
        }.value

        // The project may have been replaced or moved while the disk was read.
        guard started == generation, projectDocument.fileURL == projectURL else { return }

        for entry in survey.items {
            guard let current = mediaLibrary.item(withId: entry.id),
                  Self.path(of: current.url) == Self.path(of: entry.url) else { continue }
            add(source: entry.url, itemID: entry.id)
        }

        var repointedWithoutCopy = false
        for reference in survey.references where !isQueued(reference.source) {
            if let existing = reference.existingCopy {
                // Already copied by the old Consolidate Media; only the timeline
                // was left behind. Reuse that copy rather than duplicating gigabytes.
                repoint(from: reference.source, to: existing, itemID: nil)
                repointedWithoutCopy = true
            } else {
                add(source: reference.source, itemID: nil)
            }
        }

        if repointedWithoutCopy && worker == nil {
            saveProject()
        }
    }

    /// Call when a project has finished opening: clears debris and brings media in.
    ///
    /// The sweep finishes before anything is queued, so it can never remove a file
    /// this open is about to write.
    func projectOpened() async {
        guard let projectURL = projectDocument.fileURL else { return }
        let started = generation
        await copier.sweepStalePartials(projectURL: projectURL)
        guard started == generation else { return }
        await enqueueExternalMedia()
    }

    /// Stops all work and forgets the queue, because a different project is replacing this one.
    func reset() {
        generation += 1
        worker?.cancel()
        worker = nil
        queue.removeAll()
        inFlight = nil
        resetBatch()
        status = .idle
    }

    /// Waits until the queue has drained. For tests.
    func waitUntilIdle() async {
        await worker?.value
    }

    // MARK: - Queueing

    /// Adds a file to the queue.
    ///
    /// A source that is already queued is not copied twice; its item is added to the
    /// queued job so it is repointed when that job lands.
    ///
    /// - Returns: `true` if a new job was queued; `false` if the project is unsaved, the
    ///   file is already inside the project, or it is already queued.
    @discardableResult
    private func add(source: URL, itemID: UUID?, extraItemIDs: [UUID] = []) -> Bool {
        guard let projectURL = projectDocument.fileURL else { return false }
        guard !ProjectFolders.contains(source, projectURL: projectURL) else { return false }
        guard !isQueued(source) else {
            let others = (itemID.map { [$0] } ?? []) + extraItemIDs
            attach(others, toJobFor: source)
            return false
        }

        queue.append(Job(source: source, itemID: itemID, extraItemIDs: extraItemIDs))
        batchFilesTotal += 1
        publishStatus()
        startWorkerIfNeeded()
        return true
    }

    /// Adds items to the queued or in-flight job for `source`, skipping ones it already covers.
    private func attach(_ ids: [UUID], toJobFor source: URL) {
        let path = Self.path(of: source)
        func merged(_ job: Job) -> Job {
            var job = job
            let known = Set([job.itemID].compactMap { $0 } + job.extraItemIDs)
            job.extraItemIDs += ids.filter { !known.contains($0) }
            return job
        }
        if let index = queue.firstIndex(where: { Self.path(of: $0.source) == path }) {
            queue[index] = merged(queue[index])
        } else if let current = inFlight, Self.path(of: current.source) == path {
            inFlight = merged(current)
        }
    }

    private func isQueued(_ source: URL) -> Bool {
        let path = Self.path(of: source)
        return queue.contains { Self.path(of: $0.source) == path }
            || inFlight.map { Self.path(of: $0.source) == path } == true
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        let started = generation
        worker = Task { [weak self] in
            await self?.drain(generation: started)
        }
    }

    private func drain(generation started: Int) async {
        while started == generation, !queue.isEmpty {
            await scanQueuedJobs(generation: started)
            guard started == generation, queue.first?.scanned == true else { continue }
            let job = queue.removeFirst()
            await process(job, generation: started)
        }
        guard started == generation else { return }
        finishBatch()
    }

    /// Reads size and date of every queued file off the main actor.
    ///
    /// Sizes feed the progress bar; the fingerprint is what a later import is compared
    /// against to tell the same file from one overwritten in place.
    private func scanQueuedJobs(generation started: Int) async {
        let sources = queue.filter { !$0.scanned }.map(\.source)
        guard !sources.isEmpty else { return }

        let fingerprints = await Task.detached(priority: .utility) {
            sources.map { MediaFingerprint.of($0) }
        }.value
        guard started == generation else { return }

        for (source, fingerprint) in zip(sources, fingerprints) {
            guard let index = queue.firstIndex(where: { !$0.scanned && Self.path(of: $0.source) == Self.path(of: source) })
            else { continue }
            queue[index].scanned = true
            queue[index].fingerprint = fingerprint
            queue[index].bytes = fingerprint?.size ?? 0
            batchBytesTotal += fingerprint?.size ?? 0
        }
        publishStatus()
    }

    private func process(_ job: Job, generation started: Int) async {
        guard let projectURL = projectDocument.fileURL else {
            record(failure: job, reason: "The project has not been saved.")
            return
        }

        inFlight = job
        currentFileBytes = 0
        defer { if started == generation { inFlight = nil } }

        do {
            let copyURL = try await copier.copyIn(job.source, projectURL: projectURL)
            // The user moved on to another project while this was copying.
            guard started == generation else {
                discardLanded(copyURL, of: job)
                return
            }
            // Save As gave the project a new folder mid-copy. This copy sits in the
            // old one and nothing refers to it: drop it and copy again into the new.
            guard projectDocument.fileURL == projectURL else {
                discardLanded(copyURL, of: job)
                inFlight = nil
                batchFilesDone += 1
                batchBytesDone += job.bytes
                currentFileBytes = 0
                let latest = inFlight ?? job
                add(source: job.source, itemID: latest.itemID, extraItemIDs: latest.extraItemIDs)
                return
            }
            apply(inFlight ?? job, copyURL: copyURL)
            batchCopied += 1
            batchFilesDone += 1
            batchBytesDone += job.bytes
            currentFileBytes = 0
            publishStatus()
        } catch {
            guard started == generation else { return }
            if let copyError = error as? MediaCopyError, copyError == .cancelled { return }
            record(failure: job, reason: error.localizedDescription)
        }
    }

    /// Removes a copy nothing will refer to.
    ///
    /// Only a file this job's copy created: if the copier handed back the source itself
    /// (it was already inside the project) nothing is removed.
    private func discardLanded(_ copyURL: URL, of job: Job) {
        guard Self.path(of: copyURL) != Self.path(of: job.source) else { return }
        try? FileManager.default.removeItem(at: copyURL)
    }

    private func record(failure job: Job, reason: String) {
        batchFailures.append(MediaCopyFailure(name: job.source.lastPathComponent, reason: reason))
        diagnosticLog(.error, .media, "Copy into project failed for \(job.source.lastPathComponent): \(reason)")
        batchFilesDone += 1
        batchBytesDone += job.bytes
        currentFileBytes = 0
        publishStatus()
    }

    // MARK: - Repointing

    /// Points the library items and every reference to `job.source` at the copy.
    private func apply(_ job: Job, copyURL: URL) {
        let ids = (job.itemID.map { [$0] } ?? []) + job.extraItemIDs
        for id in ids {
            if let item = mediaLibrary.item(withId: id),
               Self.path(of: item.url) == Self.path(of: job.source) {
                // Only while the item still names the source: an optimize pass that
                // finished first has already moved it to its own output.
                mediaLibrary.recordCopy(id: id, importedFrom: job.source, fingerprint: job.fingerprint, copyURL: copyURL)
            }
            repoint(from: job.source, to: copyURL, itemID: id)
        }
        if ids.isEmpty {
            repoint(from: job.source, to: copyURL, itemID: nil)
        }
    }

    /// Moves every reel and audio clip naming `source` to `destination`.
    ///
    /// Audio clips are included whatever their source type, because a video's own
    /// audio clip names the same file as its reel.
    ///
    /// - Parameters:
    ///   - source: The file the references name now.
    ///   - destination: The copy they should name.
    ///   - itemID: When given, references that belong to a *different* library item are
    ///     left alone, so two items that once shared a source path are not confused.
    func repoint(from source: URL, to destination: URL, itemID: UUID?) {
        let sourcePath = Self.path(of: source)

        func belongs(_ owner: UUID?) -> Bool {
            guard let itemID, let owner else { return true }
            return owner == itemID
        }

        for reel in timelineManager.timeline.videoReels
        where Self.path(of: reel.sourceURL) == sourcePath && belongs(reel.mediaItemId) {
            timelineManager.updateVideoReelURL(id: reel.id, newURL: destination)
        }
        for lane in timelineManager.timeline.audioLanes {
            for clip in lane.clips where Self.path(of: clip.sourceURL) == sourcePath && belongs(clip.mediaItemId) {
                timelineManager.updateAudioClipURL(clipId: clip.id, inLane: lane.id, newURL: destination)
            }
        }
    }

    /// Moves what a caller just placed onto the item's copy if the copy landed meanwhile.
    ///
    /// Call after the reel or clip exists, passing the URL it was created with (the
    /// item's `url` when the caller read it). Does nothing while the item still names
    /// that URL.
    ///
    /// - Parameters:
    ///   - itemID: The library item the reel or clip belongs to.
    ///   - placedAt: The URL the reel or clip was created with.
    /// - Returns: The item's current URL, or `placedAt` if the item is unknown.
    @discardableResult
    func settle(itemID: UUID, placedAt: URL) -> URL {
        guard let item = mediaLibrary.item(withId: itemID) else { return placedAt }
        if Self.path(of: item.url) != Self.path(of: placedAt) {
            repoint(from: placedAt, to: item.url, itemID: itemID)
        }
        return item.url
    }

    // MARK: - Finding What Is Outside

    /// Distinct outside files that reels and clips name, in timeline order.
    private func referencedExternalSources(projectURL: URL) -> [URL] {
        var sources: [URL] = []
        var seen = Set<String>()

        func consider(_ url: URL) {
            guard !ProjectFolders.contains(url, projectURL: projectURL),
                  seen.insert(Self.path(of: url)).inserted else { return }
            sources.append(url)
        }

        timelineManager.timeline.videoReels.forEach { consider($0.sourceURL) }
        timelineManager.timeline.audioLanes.forEach { lane in
            lane.clips.forEach { consider($0.sourceURL) }
        }
        return sources
    }

    /// Reads the disk for `enqueueExternalMedia`. Runs off the main actor.
    private nonisolated static func survey(
        items: [Survey.Item],
        referencedSources: [URL],
        candidates: [CopyCandidate]
    ) -> Survey {
        var result = Survey()
        result.items = items.filter { MissingFileResolutionService.isReachable($0.url) }
        for source in referencedSources where MissingFileResolutionService.isReachable(source) {
            result.references.append(
                Survey.Reference(source: source, existingCopy: existingCopy(of: source, among: candidates))
            )
        }
        return result
    }

    /// A copy of `source` already inside the project that is provably the same file.
    ///
    /// Two kinds of candidate qualify:
    /// - An item that records importing from `source`, while the file at `source` still
    ///   has the size and date recorded then.
    /// - An item with no recorded origin (the old Consolidate Media copied library items
    ///   and left the timeline behind): its name follows the copy rule (`name.ext`,
    ///   `name_1.ext`, ...) and its size *and* modification date equal the source's.
    ///   A copy keeps the source's modification date.
    ///
    /// An item recording a *different* origin never qualifies, and a size match alone is
    /// never enough: reels must not be pointed at a file that merely looks like theirs.
    private nonisolated static func existingCopy(of source: URL, among candidates: [CopyCandidate]) -> URL? {
        guard let sourceFingerprint = MediaFingerprint.of(source) else { return nil }
        let baseName = source.deletingPathExtension().lastPathComponent
        let sourcePath = path(of: source)

        for candidate in candidates where candidate.url.pathExtension == source.pathExtension {
            if let origin = candidate.importedFrom {
                guard path(of: origin) == sourcePath,
                      let recorded = candidate.fingerprint,
                      recorded.matches(sourceFingerprint) else { continue }
                return candidate.url
            }
            guard isCopyName(candidate.url.deletingPathExtension().lastPathComponent, of: baseName),
                  let onDisk = MediaFingerprint.of(candidate.url),
                  onDisk.matches(sourceFingerprint) else { continue }
            return candidate.url
        }
        return nil
    }

    /// Whether `name` is `base` or `base_<number>`, the names copying produces.
    nonisolated static func isCopyName(_ name: String, of base: String) -> Bool {
        if name == base { return true }
        guard name.hasPrefix(base + "_") else { return false }
        let suffix = name.dropFirst(base.count + 1)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    // MARK: - Progress and Status

    private func receive(_ progress: MediaCopyProgress) {
        guard let current = inFlight,
              Self.path(of: current.source) == Self.path(of: progress.sourceURL) else { return }
        currentFileBytes = progress.bytesCopied
        publishStatus()
    }

    private func publishStatus() {
        guard batchFilesTotal > 0 else { return }
        let fraction: Double
        if batchBytesTotal > 0 {
            fraction = min(1, Double(batchBytesDone + currentFileBytes) / Double(batchBytesTotal))
        } else {
            fraction = Double(batchFilesDone) / Double(batchFilesTotal)
        }
        let next = Status.copying(filesTotal: batchFilesTotal, filesDone: batchFilesDone, fraction: fraction)
        if status != next { status = next }
    }

    private func finishBatch() {
        let copied = batchCopied
        let failures = batchFailures
        worker = nil
        resetBatch()

        if copied > 0 {
            saveProject()
            status = .finished(count: copied)
            scheduleFinishedNoteClear()
        } else {
            status = .idle
        }

        if !failures.isEmpty {
            onFailures?(failures)
        }
    }

    private func resetBatch() {
        batchFilesTotal = 0
        batchFilesDone = 0
        batchCopied = 0
        batchBytesTotal = 0
        batchBytesDone = 0
        currentFileBytes = 0
        batchFailures = []
    }

    private func scheduleFinishedNoteClear() {
        let token = UUID()
        finishedNoteToken = token
        Task { [weak self] in
            let nanoseconds = UInt64(
                MediaCopyInConstants.finishedNoteDuration * MediaCopyInConstants.nanosecondsPerSecond
            )
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self, self.finishedNoteToken == token, case .finished = self.status else { return }
            self.status = .idle
        }
    }

    /// Writes the project so the new paths survive a quit.
    private func saveProject() {
        guard projectDocument.fileURL != nil else { return }
        do {
            try projectDocument.save()
        } catch {
            diagnosticLog(.error, .project, "Saving after copying media in failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Messages

    /// Text for the media bay note, or `nil` when there is nothing to say.
    var statusMessage: String? {
        switch status {
        case .idle:
            return nil
        case .copying(let total, _, _):
            return "Copying \(total) \(Self.fileNoun(total)) into the project's Media folder\u{2026}"
        case .finished(let count):
            return "Copied \(count) \(Self.fileNoun(count)) into Media"
        }
    }

    private static func fileNoun(_ count: Int) -> String {
        count == 1 ? "file" : "files"
    }

    // MARK: - Path Comparison

    /// A path for comparing two spellings of one file.
    ///
    /// Standardizes without touching the disk: this runs against every reel on
    /// every timeline change.
    nonisolated static func path(of url: URL) -> String {
        url.standardizedFileURL.path
    }
}
