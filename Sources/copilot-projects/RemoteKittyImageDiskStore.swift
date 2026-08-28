import Foundation
import CopilotProjectsCore

private final class RemoteKittySynchronousBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func store(_ value: Bool) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// One durably-persistable current-selection/placement record — the disk
/// counterpart of `RemoteKittyImageCapture`'s in-memory activation state for
/// exactly one `(imageId, placementId)` pair. `placementId == nil` mirrors
/// the Kitty spec's implicit default placement / a wildcard activation
/// (never an explicit `p=`).
struct RemoteKittyPersistedPlacementSelection: Equatable, Sendable {
    let version: UInt64
    let placementId: UInt32?
    let rows: Int
    let columns: Int
    let x: Int?
    let y: Int?
    let z: Int?
}

/// One `(imageId, version)` entry restored from disk: the exact retained PNG
/// bytes, already revalidated as a structurally-complete PNG.
struct RemoteKittyRestoredImageEntry: Equatable {
    let imageId: UInt32
    let version: UInt64
    let data: Data
}

/// One current-selection record restored from disk, matched against an
/// entry actually present in `RemoteKittyRestoredImageEntry` — never a
/// dangling reference to bytes that were dropped as missing/corrupt.
struct RemoteKittyRestoredSelection: Equatable {
    let imageId: UInt32
    let version: UInt64
    let placementId: UInt32?
    let rows: Int
    let columns: Int
    let x: Int?
    let y: Int?
    let z: Int?
}

/// Everything durably known about one session's Kitty images at restore time.
struct RemoteKittyRestoredSessionImages: Equatable {
    var entries: [RemoteKittyRestoredImageEntry] = []
    var currentSelections: [RemoteKittyRestoredSelection] = []
}

/// Process-wide, schema-versioned disk store durably persisting the exact
/// bytes and current-selection/placement metadata every `RemoteKittyImageCapture`
/// instance retains in memory — so a session's inline images survive an app
/// relaunch (or a reboot that kills the dtach master and starts a brand new
/// shell with an empty SwiftTerm buffer), not just this process's lifetime.
///
/// Every mutation (`persistRetain`, `persistEviction`, `persistClearSession`,
/// `replaceCurrentSelections`, `clearCurrentSelections`) and the async
/// `restore(sessionId:)` read are
/// serialized onto a single FIFO chain of detached background tasks (see
/// `enqueue`, mirroring `NotificationDeliveryQueue`'s pattern elsewhere in
/// this target) — so operations issued in a given order from the main actor
/// are always *applied* in that same order, never interleaved or reordered,
/// while never blocking the main actor on (potentially multi-megabyte) disk
/// I/O. `tombstone(sessionId:)` is the one exception: it writes its marker
/// file synchronously (a tiny, negligible write) so a deliberately-destroyed
/// session's durability guarantee ("can never be resurrected") survives even
/// an *immediate* app exit, before enqueuing the (potentially larger) actual
/// cleanup.
///
/// Enforces a hard *global* cap — `maxTotalBytes`/`maxTotalEntries`, across
/// every session combined — preferring to evict already-superseded (grace)
/// entries over any still-current one, mirroring `RemoteKittyImageCaptureBudget`'s
/// in-memory eviction preference. Every byte read back from disk (at startup
/// cleanup and at restore time) is fail-closed: missing, size-mismatched, or
/// structurally-invalid PNG data is dropped (and its manifest record/file
/// removed) rather than ever installed, replayed, or served.
final class RemoteKittyImageDiskStore: @unchecked Sendable {
    static let shared = RemoteKittyImageDiskStore()

    static let schemaVersion = 1
    static let maxTotalBytes = 32 * 1_024 * 1_024
    static let maxTotalEntries = 32
    static let maxManifestBytes = 1 * 1_024 * 1_024
    static let maxQueuedRetainBytes = 32 * 1_024 * 1_024
    static let maxQueuedMutations = 256
    static let maxQueuedRetainBytesPerSession = 8 * 1_024 * 1_024
    static let maxQueuedMutationsPerSession = 64
    static let maxTrackedRejectedSessions = 256
    /// Bound on persisted current-selection/placement records *per session*
    /// — reuses the same 64-placement scale as the existing in-memory
    /// `remoteKittyMaxEmittedPlacements`/placement-activity bounds.
    static let maxPersistedSelectionsPerSession = 64

    private struct EntryKey: Hashable {
        let sessionId: String
        let imageId: UInt32
        let version: UInt64
    }

    private struct ManifestEntryRecord: Codable, Equatable {
        let sessionId: String
        let imageId: UInt32
        let version: UInt64
        let byteCount: Int
    }

    private struct ManifestSelectionRecord: Codable, Equatable {
        let sessionId: String
        let imageId: UInt32
        let version: UInt64
        let placementId: UInt32?
        let rows: Int
        let columns: Int
        let x: Int?
        let y: Int?
        let z: Int?
    }

    private struct Manifest: Codable {
        var schemaVersion = RemoteKittyImageDiskStore.schemaVersion
        var entries: [ManifestEntryRecord] = []
        var selections: [ManifestSelectionRecord] = []
    }

    private let root: URL
    private let dataDir: URL
    private let tombstoneDir: URL
    private let manifestURL: URL
    private let maxQueuedRetainBytes: Int
    private let maxQueuedMutations: Int

    // Both only ever touched from within `enqueue`'d closures (a single FIFO
    // chain), except `manifest` is also read/written synchronously during
    // `init` (before `.shared`/this instance is ever handed to a caller, so
    // nothing could be concurrently enqueuing yet) — so neither needs its own
    // lock; `chainLock` below guards only the chain bookkeeping itself.
    private var manifest: Manifest

    private let chainLock = NSLock()
    private var chainTail: Task<Void, Never>?
    private var queuedRetainBytes = 0
    private var queuedMutations = 0
    private var queuedRetainBytesBySession: [String: Int] = [:]
    private var queuedMutationsBySession: [String: Int] = [:]
    private var persistenceDisabledSessionIds: Set<String> = []
    private var overflowCleanupScheduledSessionIds: Set<String> = []
    private var futureRetainsDisabled = false
    private var manifestPersistCount = 0
    private let activationLock = NSLock()
    private var activated = false

    // A thread-safe mirror of "which session ids currently have at least one
    // persisted entry", kept in lockstep with `manifest.entries` by every
    // mutation below (`refreshSessionIndexLocked`). Exists solely so
    // `hasPersistedEntriesSynchronously` can answer instantly, off the serial
    // chain, from the main actor — letting a session with nothing at all to
    // restore (the overwhelming common case: every brand-new session, and
    // every existing test that never wrote anything to this store) skip the
    // async restore/buffering dance entirely, rather than unconditionally
    // paying for it (and the non-deterministic scheduling delay of a
    // `Task`) even when it can only ever resolve to "nothing to do".
    private let sessionIndexLock = NSLock()
    private var sessionIdsWithEntries: Set<String> = []
    private let tombstonedSessionIdsLock = NSLock()
    private var tombstonedSessionIds: Set<String> = []

    init(
        root: URL = Paths.kittyImagesDir,
        maxQueuedRetainBytes: Int = RemoteKittyImageDiskStore.maxQueuedRetainBytes,
        maxQueuedMutations: Int = RemoteKittyImageDiskStore.maxQueuedMutations
    ) {
        self.root = root
        self.maxQueuedRetainBytes = maxQueuedRetainBytes
        self.maxQueuedMutations = maxQueuedMutations
        dataDir = root.appendingPathComponent("data", isDirectory: true)
        tombstoneDir = root.appendingPathComponent("tombstones", isDirectory: true)
        manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        manifest = Self.loadManifestFailClosed(at: manifestURL)
        // Deliberately does NOT eagerly create any directory here: every
        // real write path below (`writeAtomically`, `persistManifest`,
        // `writeTombstoneMarkerSynchronously`) creates exactly the directory
        // it needs, lazily, immediately before writing. A store that's
        // constructed but never actually persists anything (e.g. `.shared`
        // touched only by a session that never turns out to have any
        // durable image, or by a test never constructed with an isolated
        // root) must never leave so much as an empty directory behind on
        // disk purely from being instantiated.
        refreshSessionIndexLocked()
    }

    /// Starts startup reconciliation exactly once. Production calls this only
    /// after acquiring the app's single-instance lock, so a rejected secondary
    /// process can never mutate the primary process's image store.
    func activate() {
        activationLock.lock()
        guard !activated else {
            activationLock.unlock()
            return
        }
        activated = true
        activationLock.unlock()
        enqueue { [self] in performStartupCleanup() }
    }

    /// Thread-safe, synchronous, and instant: true iff `sessionId` currently
    /// has at least one persisted entry anywhere in the manifest. Safe to
    /// call from any thread/actor without going through the serial chain.
    func hasPersistedEntriesSynchronously(sessionId: String) -> Bool {
        sessionIndexLock.lock()
        defer { sessionIndexLock.unlock() }
        return sessionIdsWithEntries.contains(sessionId)
    }

    /// Recomputes `sessionIdsWithEntries` from the current `manifest.entries`
    /// — called at the end of every operation (only ever from within an
    /// `enqueue`d closure, or `init`) that can add or remove entries.
    /// Manifest sizes are small (bounded by `maxTotalEntries`), so a full
    /// recompute is cheap and simpler than trying to incrementally patch a
    /// set that multiple call sites would otherwise each have to keep
    /// perfectly in sync by hand.
    private func refreshSessionIndexLocked() {
        let sessionIds = Set(manifest.entries.map(\.sessionId))
        sessionIndexLock.lock()
        sessionIdsWithEntries = sessionIds
        sessionIndexLock.unlock()
    }

    // MARK: - Serial background chain

    private func enqueue(_ operation: @Sendable @escaping () -> Void) {
        chainLock.lock()
        enqueueLocked(operation)
        chainLock.unlock()
    }

    private func enqueueLocked(_ operation: @Sendable @escaping () -> Void) {
        let previous = chainTail
        let task = Task.detached(priority: .utility) {
            _ = await previous?.value
            operation()
        }
        chainTail = task
    }

    private func enqueueMutation(
        sessionId: String,
        retainedBytes: Int = 0,
        failClosedOnDrop: Bool = true,
        operation: @Sendable @escaping () -> Void
    ) {
        chainLock.lock()
        if persistenceDisabledSessionIds.contains(sessionId) || isTombstoned(sessionId: sessionId) {
            chainLock.unlock()
            return
        }
        if retainedBytes > 0, futureRetainsDisabled {
            chainLock.unlock()
            return
        }
        let sessionQueuedMutations = queuedMutationsBySession[sessionId] ?? 0
        let sessionQueuedBytes = queuedRetainBytesBySession[sessionId] ?? 0
        guard sessionQueuedMutations < Self.maxQueuedMutationsPerSession,
              sessionQueuedBytes + retainedBytes <= Self.maxQueuedRetainBytesPerSession
        else {
            disableSessionFailClosedLocked(sessionId)
            chainLock.unlock()
            NSLog("copilot-projects: disabling Kitty image persistence for overloaded session \(sessionId)")
            return
        }
        guard queuedMutations < maxQueuedMutations,
              queuedRetainBytes + retainedBytes <= maxQueuedRetainBytes
        else {
            if failClosedOnDrop {
                disableSessionFailClosedLocked(sessionId)
            }
            chainLock.unlock()
            NSLog("copilot-projects: dropping Kitty image persistence mutation under global queue pressure")
            return
        }
        queuedMutations += 1
        queuedRetainBytes += retainedBytes
        queuedMutationsBySession[sessionId] = sessionQueuedMutations + 1
        queuedRetainBytesBySession[sessionId] = sessionQueuedBytes + retainedBytes
        enqueueLocked { [weak self] in
            operation()
            guard let self else { return }
            self.chainLock.lock()
            self.queuedMutations -= 1
            self.queuedRetainBytes -= retainedBytes
            let remainingMutations = (self.queuedMutationsBySession[sessionId] ?? 1) - 1
            let remainingBytes = (self.queuedRetainBytesBySession[sessionId] ?? retainedBytes)
                - retainedBytes
            if remainingMutations > 0 {
                self.queuedMutationsBySession[sessionId] = remainingMutations
            } else {
                self.queuedMutationsBySession.removeValue(forKey: sessionId)
            }
            if remainingBytes > 0 {
                self.queuedRetainBytesBySession[sessionId] = remainingBytes
            } else {
                self.queuedRetainBytesBySession.removeValue(forKey: sessionId)
            }
            self.chainLock.unlock()
        }
        chainLock.unlock()
    }

    private func disableSessionFailClosedLocked(_ sessionId: String) {
        if persistenceDisabledSessionIds.count >= Self.maxTrackedRejectedSessions,
           let oldest = persistenceDisabledSessionIds.first {
            persistenceDisabledSessionIds.remove(oldest)
        }

        persistenceDisabledSessionIds.insert(sessionId)

        tombstonedSessionIdsLock.lock()
        if tombstonedSessionIds.count >= Self.maxTrackedRejectedSessions,
           let oldest = tombstonedSessionIds.first {
            tombstonedSessionIds.remove(oldest)
        }
        tombstonedSessionIds.insert(sessionId)
        tombstonedSessionIdsLock.unlock()
        _ = writeTombstoneMarkerSynchronously(sessionId: sessionId)

        if overflowCleanupScheduledSessionIds.insert(sessionId).inserted {
            enqueueLocked { [weak self] in
                guard let self else { return }
                if self.performTombstoneCleanup(sessionId: sessionId) {
                    self.removeTombstoneMarker(sessionId: sessionId)
                }
                self.chainLock.lock()
                self.overflowCleanupScheduledSessionIds.remove(sessionId)
                self.chainLock.unlock()
            }
        }
    }

    private func disableFutureRetainsAfterCleanupFailure() {
        chainLock.lock()
        futureRetainsDisabled = true
        chainLock.unlock()
    }

    private func failClosedSessionAfterPersistenceFailure(_ sessionId: String) {
        chainLock.lock()
        persistenceDisabledSessionIds.insert(sessionId)
        chainLock.unlock()
        tombstonedSessionIdsLock.lock()
        tombstonedSessionIds.insert(sessionId)
        tombstonedSessionIdsLock.unlock()
        _ = writeTombstoneMarkerSynchronously(sessionId: sessionId)
        _ = performTombstoneCleanup(sessionId: sessionId)
    }

    /// Awaits a no-op enqueued at the tail of the current chain — every prior
    /// enqueued mutation is guaranteed complete once this returns. Exposed
    /// only for tests, which otherwise have no deterministic way to observe
    /// completion of fire-and-forget persistence calls without a brittle
    /// sleep.
    func barrierForTesting() async {
        await flush()
    }

    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enqueue { continuation.resume() }
        }
    }

    // MARK: - Mutations (fire-and-forget, serialized)

    /// Mirrors one freshly-retained `(imageId, version)` entry's exact bytes
    /// onto disk, asynchronously.
    func persistRetain(
        sessionId: String,
        imageId: UInt32,
        version: UInt64,
        data: Data,
        currentSelections: [RemoteKittyPersistedPlacementSelection] = []
    ) {
        enqueueMutation(
            sessionId: sessionId,
            retainedBytes: data.count,
            failClosedOnDrop: false
        ) { [self] in
            performPersistRetain(
                sessionId: sessionId,
                imageId: imageId,
                version: version,
                data: data,
                currentSelections: currentSelections
            )
        }
    }

    /// Mirrors one entry's removal (local grace-cache eviction, cross-session
    /// budget eviction, or an explicit per-id delete) onto disk,
    /// asynchronously.
    func persistEviction(sessionId: String, imageId: UInt32, version: UInt64) {
        enqueueMutation(sessionId: sessionId, failClosedOnDrop: true) { [self] in
            performPersistEviction(sessionId: sessionId, imageId: imageId, version: version)
        }
    }

    /// Mirrors a full clear (`d=A`, or deliberate session destruction) of
    /// every retained entry/selection for `sessionId` onto disk,
    /// asynchronously.
    func persistClearSession(sessionId: String) {
        enqueueMutation(sessionId: sessionId, failClosedOnDrop: true) { [self] in
            _ = performOrdinaryClearSession(sessionId: sessionId)
        }
    }

    /// Replaces every persisted current-selection record for
    /// `(sessionId, imageId)` with exactly `selections` (an empty array
    /// clears every persisted selection for this id), asynchronously. A
    /// selection whose `version` isn't an entry actually retained on disk for
    /// this `(sessionId, imageId)` is silently dropped — never a dangling
    /// reference.
    func replaceCurrentSelections(
        sessionId: String,
        imageId: UInt32,
        selections: [RemoteKittyPersistedPlacementSelection]
    ) {
        enqueueMutation(sessionId: sessionId, failClosedOnDrop: true) { [self] in
            performReplaceCurrentSelections(sessionId: sessionId, imageId: imageId, selections: selections)
        }
    }

    /// Clears every persisted current-selection record for the specified
    /// image ids in one FIFO mutation and one manifest persist. This is the
    /// durable counterpart of a single Kitty placement-clear operation that
    /// naturally affects multiple ids.
    func clearCurrentSelections(sessionId: String, imageIds: Set<UInt32>) {
        guard !imageIds.isEmpty else { return }
        enqueueMutation(sessionId: sessionId, failClosedOnDrop: true) { [self] in
            performClearCurrentSelections(sessionId: sessionId, imageIds: imageIds)
        }
    }

    /// Synchronously (before returning) writes a durable marker recording
    /// that `sessionId` was deliberately destroyed — surviving even an
    /// immediate app exit — then asynchronously enqueues removal of every
    /// manifest entry/data file for it, finally removing the marker once
    /// that cleanup completes. Callers must invoke this *before* proceeding
    /// with any other teardown of the session (see `SessionArtifacts.destroy`),
    /// so a late callback/write racing the teardown can never resurrect data
    /// this call already durably committed to discard.
    @discardableResult
    func tombstone(sessionId: String) -> Bool {
        tombstonedSessionIdsLock.lock()
        if tombstonedSessionIds.count >= Self.maxTrackedRejectedSessions,
           let oldest = tombstonedSessionIds.first {
            tombstonedSessionIds.remove(oldest)
        }
        tombstonedSessionIds.insert(sessionId)
        tombstonedSessionIdsLock.unlock()
        guard writeTombstoneMarkerSynchronously(sessionId: sessionId) else {
            let semaphore = DispatchSemaphore(value: 0)
            let cleaned = RemoteKittySynchronousBool()
            enqueue { [self] in
                cleaned.store(performTombstoneCleanup(sessionId: sessionId))
                semaphore.signal()
            }
            semaphore.wait()
            if !cleaned.load() {
                NSLog("copilot-projects: could not synchronously purge Kitty images for \(sessionId)")
            }
            return cleaned.load()
        }
        enqueue { [self] in
            if performTombstoneCleanup(sessionId: sessionId) {
                removeTombstoneMarker(sessionId: sessionId)
            }
        }
        return true
    }

    // MARK: - Restore (async; never mutates in-memory capture state itself)

    /// Reads back every durably-retained entry and current-selection record
    /// for `sessionId`, revalidating each entry's bytes as a structurally
    /// complete PNG (fail-closed: anything missing/corrupt is dropped from
    /// the manifest and never returned) and dropping any selection that
    /// doesn't reference a validated entry. Never returns anything for a
    /// tombstoned session (defensive; startup cleanup already reconciles
    /// tombstones eagerly).
    func restore(sessionId: String) async -> RemoteKittyRestoredSessionImages {
        await withCheckedContinuation { (continuation: CheckedContinuation<RemoteKittyRestoredSessionImages, Never>) in
            enqueue { [self] in
                continuation.resume(returning: performRestore(sessionId: sessionId))
            }
        }
    }

    // MARK: - Testing accessors (serialized like every other read)

    func totalEntryCountForTesting() async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            enqueue { [self] in continuation.resume(returning: manifest.entries.count) }
        }
    }

    func totalByteCountForTesting() async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            enqueue { [self] in continuation.resume(returning: manifest.entries.reduce(0) { $0 + $1.byteCount }) }
        }
    }

    func selectionCountForTesting(sessionId: String) async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            enqueue { [self] in
                continuation.resume(returning: manifest.selections.filter { $0.sessionId == sessionId }.count)
            }
        }
    }

    func entryExistsForTesting(sessionId: String, imageId: UInt32, version: UInt64) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            enqueue { [self] in
                let exists = manifest.entries.contains {
                    $0.sessionId == sessionId && $0.imageId == imageId && $0.version == version
                }
                continuation.resume(returning: exists)
            }
        }
    }

    func isTombstonedForTesting(sessionId: String) -> Bool {
        isTombstoned(sessionId: sessionId)
    }

    func tombstoneMarkerExistsForTesting(sessionId: String) -> Bool {
        FileManager.default.fileExists(
            atPath: tombstoneDir.appendingPathComponent(
                Self.token(for: sessionId),
                isDirectory: false
            ).path
        )
    }

    func isPersistenceDisabledForTesting(sessionId: String) -> Bool {
        chainLock.lock()
        defer { chainLock.unlock() }
        return persistenceDisabledSessionIds.contains(sessionId)
    }

    var queuedRetainBytesForTesting: Int {
        chainLock.lock()
        defer { chainLock.unlock() }
        return queuedRetainBytes
    }

    func manifestPersistCountForTesting() async -> Int {
        await withCheckedContinuation { continuation in
            enqueue { [self] in
                continuation.resume(returning: manifestPersistCount)
            }
        }
    }

    /// The exact on-disk path an entry's bytes are (or would be) stored at.
    /// Pure/synchronous (path computation only touches no shared state), so
    /// safe to call from any thread. Exposed only so tests can directly
    /// corrupt/truncate/replace an entry's bytes on disk to exercise
    /// fail-closed revalidation; not used by any production call site.
    func dataFileURLForTesting(sessionId: String, imageId: UInt32, version: UInt64) -> URL {
        dataFileURL(sessionId: sessionId, imageId: imageId, version: version)
    }

    private func isTombstoned(sessionId: String) -> Bool {
        tombstonedSessionIdsLock.lock()
        let isTombstonedInMemory = tombstonedSessionIds.contains(sessionId)
        tombstonedSessionIdsLock.unlock()
        if isTombstonedInMemory { return true }
        return FileManager.default.fileExists(
            atPath: tombstoneDir.appendingPathComponent(
                Self.token(for: sessionId),
                isDirectory: false
            ).path
        )
    }

    // MARK: - Implementation (only ever run from within `enqueue`, or `init`)

    private func performPersistRetain(
        sessionId: String,
        imageId: UInt32,
        version: UInt64,
        data: Data,
        currentSelections: [RemoteKittyPersistedPlacementSelection]
    ) {
        guard !isTombstoned(sessionId: sessionId) else { return }
        // Defense in depth: never trust bytes onto disk that don't pass the
        // same structural check a live transmission's own decode already
        // required — even though every real caller already validated this
        // exact `data` before ever calling `persistRetain`.
        guard RemoteKittyPNGValidation.isStructurallyValid(data) else { return }
        guard data.count <= Self.maxTotalBytes else { return }
        let originalManifest = manifest
        var victims: [ManifestEntryRecord] = []
        if let existing = manifest.entries.firstIndex(where: {
            $0.sessionId == sessionId && $0.imageId == imageId && $0.version == version
        }) {
            victims.append(removeEntryRecord(at: existing))
        }
        let normalizedSelections = currentSelections
            .filter { $0.version == version && $0.rows > 0 && $0.columns > 0 }
            .prefix(Self.maxPersistedSelectionsPerSession)
        let isCurrent = !normalizedSelections.isEmpty
        guard let capacityVictims = makeRoomForRetain(
            byteCount: data.count,
            isCurrent: isCurrent
        ) else {
            manifest = originalManifest
            return
        }
        victims.append(contentsOf: capacityVictims)
        let fileURL = dataFileURL(sessionId: sessionId, imageId: imageId, version: version)
        guard writeAtomically(data: data, to: fileURL) else {
            manifest = originalManifest
            return
        }
        manifest.entries.append(ManifestEntryRecord(
            sessionId: sessionId, imageId: imageId, version: version, byteCount: data.count
        ))
        manifest.selections.removeAll { $0.sessionId == sessionId && $0.imageId == imageId }
        for selection in normalizedSelections {
            manifest.selections.append(ManifestSelectionRecord(
                sessionId: sessionId,
                imageId: imageId,
                version: version,
                placementId: selection.placementId,
                rows: selection.rows,
                columns: selection.columns,
                x: selection.x,
                y: selection.y,
                z: selection.z
            ))
        }
        enforceSelectionBound(sessionId: sessionId)
        guard persistManifest() else {
            manifest = originalManifest
            refreshSessionIndexLocked()
            if !originalManifest.entries.contains(where: {
                $0.sessionId == sessionId && $0.imageId == imageId && $0.version == version
            }) {
                try? FileManager.default.removeItem(at: fileURL)
            }
            return
        }
        for victim in victims where !(
            victim.sessionId == sessionId
                && victim.imageId == imageId
                && victim.version == version
        ) {
            let victimURL = dataFileURL(
                sessionId: victim.sessionId,
                imageId: victim.imageId,
                version: victim.version
            )
            do {
                try FileManager.default.removeItem(at: victimURL)
            } catch {
                if (error as NSError).code != NSFileNoSuchFileError {
                    NSLog("copilot-projects: could not remove evicted Kitty image \(victimURL.path): \(error)")
                    disableFutureRetainsAfterCleanupFailure()
                }
            }
        }
    }

    private func performPersistEviction(sessionId: String, imageId: UInt32, version: UInt64) {
        guard !isTombstoned(sessionId: sessionId) else { return }
        guard let index = manifest.entries.firstIndex(where: {
            $0.sessionId == sessionId && $0.imageId == imageId && $0.version == version
        }) else { return }
        removeEntry(at: index)
        persistManifest()
    }

    @discardableResult
    private func performTombstoneCleanup(sessionId: String) -> Bool {
        let removedFiles = purgeSession(sessionId: sessionId)
        return persistManifest() && removedFiles
    }

    @discardableResult
    private func performOrdinaryClearSession(sessionId: String) -> Bool {
        let originalManifest = manifest
        let removed = manifest.entries.filter { $0.sessionId == sessionId }
        manifest.entries.removeAll { $0.sessionId == sessionId }
        manifest.selections.removeAll { $0.sessionId == sessionId }
        guard persistManifest() else {
            manifest = originalManifest
            refreshSessionIndexLocked()
            failClosedSessionAfterPersistenceFailure(sessionId)
            return false
        }
        for entry in removed {
            let url = dataFileURL(
                sessionId: entry.sessionId,
                imageId: entry.imageId,
                version: entry.version
            )
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                if (error as NSError).code != NSFileNoSuchFileError {
                    NSLog("copilot-projects: could not remove cleared Kitty image \(url.path): \(error)")
                    disableFutureRetainsAfterCleanupFailure()
                }
            }
        }
        return true
    }

    private func performReplaceCurrentSelections(
        sessionId: String,
        imageId: UInt32,
        selections: [RemoteKittyPersistedPlacementSelection]
    ) {
        guard !isTombstoned(sessionId: sessionId) else { return }
        let originalManifest = manifest
        manifest.selections.removeAll { $0.sessionId == sessionId && $0.imageId == imageId }
        for selection in selections {
            // Only persist a selection whose exact (imageId, version) is
            // actually a retained disk entry — never a dangling reference to
            // bytes that were never (or no longer) written.
            guard manifest.entries.contains(where: {
                $0.sessionId == sessionId && $0.imageId == imageId && $0.version == selection.version
            }) else { continue }
            manifest.selections.append(ManifestSelectionRecord(
                sessionId: sessionId, imageId: imageId, version: selection.version,
                placementId: selection.placementId, rows: selection.rows, columns: selection.columns,
                x: selection.x, y: selection.y, z: selection.z
            ))
        }
        // Bound total persisted selections *for this session* to the
        // existing placement scale, trimming the oldest entries belonging to
        // *other* image ids first so a burst of activity on one id can never
        // starve every other id's selection.
        enforceSelectionBound(sessionId: sessionId)
        guard persistManifest() else {
            manifest = originalManifest
            refreshSessionIndexLocked()
            failClosedSessionAfterPersistenceFailure(sessionId)
            return
        }
    }

    private func performClearCurrentSelections(sessionId: String, imageIds: Set<UInt32>) {
        guard !isTombstoned(sessionId: sessionId) else { return }
        let originalManifest = manifest
        manifest.selections.removeAll {
            $0.sessionId == sessionId && imageIds.contains($0.imageId)
        }
        guard persistManifest() else {
            manifest = originalManifest
            refreshSessionIndexLocked()
            failClosedSessionAfterPersistenceFailure(sessionId)
            return
        }
    }

    private func enforceSelectionBound(sessionId: String) {
        let sessionIndices = manifest.selections.indices.filter {
            manifest.selections[$0].sessionId == sessionId
        }
        if sessionIndices.count > Self.maxPersistedSelectionsPerSession {
            let excess = sessionIndices.count - Self.maxPersistedSelectionsPerSession
            for index in sessionIndices.prefix(excess).sorted(by: >) {
                manifest.selections.remove(at: index)
            }
        }
    }

    private func performRestore(sessionId: String) -> RemoteKittyRestoredSessionImages {
        guard !isTombstoned(sessionId: sessionId) else {
            return RemoteKittyRestoredSessionImages()
        }
        var validKeys: Set<EntryKey> = []
        var restoredEntries: [RemoteKittyRestoredImageEntry] = []
        var keptEntries: [ManifestEntryRecord] = []
        var manifestChanged = false
        for entry in manifest.entries {
            guard entry.sessionId == sessionId else {
                keptEntries.append(entry)
                continue
            }
            let path = dataFileURL(sessionId: entry.sessionId, imageId: entry.imageId, version: entry.version)
            guard let data = readValidatedData(entry: entry, at: path)
            else {
                // Corrupt/missing/size-mismatched: drop fail-closed rather
                // than ever install, replay, or serve it.
                try? FileManager.default.removeItem(at: path)
                manifestChanged = true
                continue
            }
            keptEntries.append(entry)
            restoredEntries.append(RemoteKittyRestoredImageEntry(imageId: entry.imageId, version: entry.version, data: data))
            validKeys.insert(EntryKey(sessionId: sessionId, imageId: entry.imageId, version: entry.version))
        }
        if manifestChanged { manifest.entries = keptEntries }

        var keptSelections: [ManifestSelectionRecord] = []
        var restoredSelections: [RemoteKittyRestoredSelection] = []
        for selection in manifest.selections {
            guard selection.sessionId == sessionId else {
                keptSelections.append(selection)
                continue
            }
            guard validKeys.contains(EntryKey(sessionId: sessionId, imageId: selection.imageId, version: selection.version))
            else {
                manifestChanged = true
                continue
            }
            keptSelections.append(selection)
            restoredSelections.append(RemoteKittyRestoredSelection(
                imageId: selection.imageId, version: selection.version, placementId: selection.placementId,
                rows: selection.rows, columns: selection.columns, x: selection.x, y: selection.y, z: selection.z
            ))
        }
        if manifestChanged {
            manifest.selections = keptSelections
            persistManifest()
        }

        return RemoteKittyRestoredSessionImages(entries: restoredEntries, currentSelections: restoredSelections)
    }

    @discardableResult
    private func purgeSession(sessionId: String) -> Bool {
        let targeted = manifest.entries.filter { $0.sessionId == sessionId }
        var removedKeys: Set<EntryKey> = []
        var removedAllFiles = true
        for entry in targeted {
            let url = dataFileURL(
                sessionId: entry.sessionId,
                imageId: entry.imageId,
                version: entry.version
            )
            guard FileManager.default.fileExists(atPath: url.path) else {
                removedKeys.insert(EntryKey(
                    sessionId: entry.sessionId,
                    imageId: entry.imageId,
                    version: entry.version
                ))
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                removedKeys.insert(EntryKey(
                    sessionId: entry.sessionId,
                    imageId: entry.imageId,
                    version: entry.version
                ))
            } catch {
                removedAllFiles = false
                NSLog("copilot-projects: could not remove persisted Kitty image \(url.path): \(error)")
            }
        }
        manifest.entries.removeAll {
            removedKeys.contains(EntryKey(
                sessionId: $0.sessionId,
                imageId: $0.imageId,
                version: $0.version
            ))
        }
        manifest.selections.removeAll {
            removedKeys.contains(EntryKey(
                sessionId: $0.sessionId,
                imageId: $0.imageId,
                version: $0.version
            ))
        }
        return removedAllFiles
    }

    /// Enforces the hard global cap, preferring to evict already-superseded
    /// (not currently selected) entries — oldest-first — over any current
    /// one, only reaching into current entries if no superseded entry
    /// remains anywhere in the process and the cap is still exceeded.
    private func enforceGlobalBounds() {
        func isCurrent(_ entry: ManifestEntryRecord) -> Bool {
            manifest.selections.contains {
                $0.sessionId == entry.sessionId && $0.imageId == entry.imageId && $0.version == entry.version
            }
        }
        while manifest.entries.count > Self.maxTotalEntries
            || manifest.entries.reduce(0, { $0 + $1.byteCount }) > Self.maxTotalBytes {
            guard !manifest.entries.isEmpty else { break }
            let victimIndex = manifest.entries.firstIndex(where: { !isCurrent($0) }) ?? 0
            removeEntry(at: victimIndex)
        }
    }

    private func makeRoomForRetain(
        byteCount: Int,
        isCurrent: Bool
    ) -> [ManifestEntryRecord]? {
        var victims: [ManifestEntryRecord] = []
        while manifest.entries.count + 1 > Self.maxTotalEntries
            || manifest.entries.reduce(0, { $0 + $1.byteCount }) + byteCount > Self.maxTotalBytes {
            let supersededIndex = manifest.entries.firstIndex { entry in
                !manifest.selections.contains {
                    $0.sessionId == entry.sessionId
                        && $0.imageId == entry.imageId
                        && $0.version == entry.version
                }
            }
            if let supersededIndex {
                victims.append(removeEntryRecord(at: supersededIndex))
            } else if isCurrent, !manifest.entries.isEmpty {
                victims.append(removeEntryRecord(at: 0))
            } else {
                return nil
            }
        }
        return victims
    }

    private func removeEntry(at index: Int) {
        let victim = removeEntryRecord(at: index)
        try? FileManager.default.removeItem(
            at: dataFileURL(
                sessionId: victim.sessionId,
                imageId: victim.imageId,
                version: victim.version
            )
        )
    }

    private func removeEntryRecord(at index: Int) -> ManifestEntryRecord {
        let victim = manifest.entries.remove(at: index)
        manifest.selections.removeAll {
            $0.sessionId == victim.sessionId
                && $0.imageId == victim.imageId
                && $0.version == victim.version
        }
        return victim
    }

    // MARK: - Startup cleanup (fail-closed)

    private func performStartupCleanup() {
        let reconciledTombstones = reconcileTombstones()
        let beforeEntryCount = manifest.entries.count
        let beforeSelectionCount = manifest.selections.count

        var keptEntries: [ManifestEntryRecord] = []
        for entry in manifest.entries {
            let path = dataFileURL(sessionId: entry.sessionId, imageId: entry.imageId, version: entry.version)
            guard readValidatedData(entry: entry, at: path) != nil
            else {
                try? FileManager.default.removeItem(at: path)
                continue
            }
            keptEntries.append(entry)
        }
        manifest.entries = keptEntries
        let keptKeys = Set(keptEntries.map {
            EntryKey(sessionId: $0.sessionId, imageId: $0.imageId, version: $0.version)
        })
        manifest.selections = manifest.selections.filter {
            keptKeys.contains(EntryKey(sessionId: $0.sessionId, imageId: $0.imageId, version: $0.version))
        }
        for sessionId in Set(manifest.selections.map(\.sessionId)) {
            enforceSelectionBound(sessionId: sessionId)
        }
        removeOrphanAndStagingFiles(referencedBy: keptEntries)
        enforceGlobalBounds()

        // Never touch disk (not even to write a trivially-empty manifest) if
        // nothing about it actually changed — a store that's merely
        // constructed (e.g. `.shared` touched by a session that turns out to
        // have nothing persisted, or by any test that never configures an
        // isolated root) must leave no trace on disk purely from existing.
        guard !reconciledTombstones.isEmpty
            || manifest.entries.count != beforeEntryCount
            || manifest.selections.count != beforeSelectionCount
        else { return }
        if persistManifest() {
            for sessionId in reconciledTombstones {
                removeTombstoneMarker(sessionId: sessionId)
                tombstonedSessionIdsLock.lock()
                tombstonedSessionIds.remove(sessionId)
                tombstonedSessionIdsLock.unlock()
            }
        }
    }

    private func readValidatedData(
        entry: ManifestEntryRecord,
        at url: URL
    ) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue == entry.byteCount,
              size.intValue > 0,
              size.intValue <= Self.maxTotalBytes,
              let data = try? Data(contentsOf: url),
              data.count == entry.byteCount,
              RemoteKittyPNGValidation.isStructurallyValid(data)
        else { return nil }
        return data
    }

    /// Purges every tombstoned session found in `tombstoneDir` and removes
    /// its marker, returning whether anything was actually reconciled (so
    /// `performStartupCleanup` can skip an unnecessary manifest write when
    /// there was nothing to do).
    private func reconcileTombstones() -> [String] {
        guard let markers = try? FileManager.default.contentsOfDirectory(atPath: tombstoneDir.path),
              !markers.isEmpty
        else { return [] }
        var sessionIds: [String] = []
        for marker in markers {
            guard let sessionId = Self.decodeToken(marker) else { continue }
            tombstonedSessionIdsLock.lock()
            if tombstonedSessionIds.count >= Self.maxTrackedRejectedSessions,
               let oldest = tombstonedSessionIds.first {
                tombstonedSessionIds.remove(oldest)
            }
            tombstonedSessionIds.insert(sessionId)
            tombstonedSessionIdsLock.unlock()
            if purgeSession(sessionId: sessionId) {
                sessionIds.append(sessionId)
            }
        }
        return sessionIds
    }

    private func removeOrphanAndStagingFiles(referencedBy entries: [ManifestEntryRecord]) {
        let referenced = Set(entries.map { dataFileName(sessionId: $0.sessionId, imageId: $0.imageId, version: $0.version) })
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dataDir.path) else { return }
        for file in files where !referenced.contains(file) {
            try? FileManager.default.removeItem(atPath: dataDir.appendingPathComponent(file).path)
        }
    }

    // MARK: - Tombstones

    private func writeTombstoneMarkerSynchronously(sessionId: String) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: tombstoneDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let path = tombstoneDir.appendingPathComponent(
                Self.token(for: sessionId),
                isDirectory: false
            ).path
            guard FileManager.default.createFile(
                atPath: path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return true
        } catch {
            NSLog("copilot-projects: could not durably tombstone Kitty images for \(sessionId): \(error)")
            return false
        }
    }

    private func removeTombstoneMarker(sessionId: String) {
        let url = tombstoneDir.appendingPathComponent(
            Self.token(for: sessionId),
            isDirectory: false
        )
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            NSLog("copilot-projects: could not remove Kitty image tombstone \(url.path): \(error)")
        }
    }

    // MARK: - Disk layout helpers

    /// Hex-encodes `sessionId`'s UTF-8 bytes so it can never contain a path
    /// separator or traversal sequence regardless of its content, even
    /// though every real session id is already a plain UUID string.
    private static func token(for sessionId: String) -> String {
        sessionId.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private static func decodeToken(_ hex: String) -> String? {
        guard hex.count % 2 == 0, !hex.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private func dataFileName(sessionId: String, imageId: UInt32, version: UInt64) -> String {
        "\(Self.token(for: sessionId))__\(String(imageId, radix: 16))__\(String(version, radix: 16)).png"
    }

    private func dataFileURL(sessionId: String, imageId: UInt32, version: UInt64) -> URL {
        dataDir.appendingPathComponent(
            dataFileName(sessionId: sessionId, imageId: imageId, version: version),
            isDirectory: false
        )
    }

    /// Atomic write via a staging temp file (`.tmp-<uuid>`) renamed into
    /// place only once fully written — so a crash/kill mid-write can never
    /// leave a partially-written file masquerading as a real manifest entry;
    /// startup cleanup also removes any staging leftovers it does find (via
    /// `removeOrphanAndStagingFiles`, since a staging file is never
    /// referenced by any manifest entry).
    private func writeAtomically(data: Data, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let staging = dataDir.appendingPathComponent(
            ".tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try data.write(to: staging, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: staging, to: url)
            return true
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return false
        }
    }

    @discardableResult
    private func persistManifest() -> Bool {
        manifestPersistCount += 1
        refreshSessionIndexLocked()
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(manifest)
            guard data.count <= Self.maxManifestBytes else {
                NSLog("copilot-projects: refusing oversized Kitty image manifest (\(data.count) bytes)")
                return false
            }
            try data.write(to: manifestURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: manifestURL.path
            )
            return true
        } catch {
            NSLog("copilot-projects: could not persist Kitty image manifest: \(error)")
            return false
        }
    }

    private static func loadManifestFailClosed(at url: URL) -> Manifest {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue <= maxManifestBytes,
              let data = try? Data(contentsOf: url) else { return Manifest() }
        guard let decoded = try? JSONDecoder().decode(Manifest.self, from: data),
              decoded.schemaVersion == RemoteKittyImageDiskStore.schemaVersion,
              decoded.entries.count <= maxTotalEntries,
              decoded.selections.count <= maxTotalEntries * maxPersistedSelectionsPerSession,
              decoded.entries.allSatisfy({
                  !$0.sessionId.isEmpty
                      && $0.sessionId.utf8.count <= 64
                      && $0.imageId >= 1
                      && $0.imageId <= 0xFFFFFF
                      && $0.version > 0
                      && $0.byteCount > 0
                      && $0.byteCount <= maxTotalBytes
              }),
              decoded.selections.allSatisfy({
                  !$0.sessionId.isEmpty
                      && $0.sessionId.utf8.count <= 64
                      && $0.imageId >= 1
                      && $0.imageId <= 0xFFFFFF
                      && $0.version > 0
                      && $0.rows > 0
                      && $0.columns > 0
                      && $0.rows <= 4_096
                      && $0.columns <= 4_096
              })
        else {
            // Unreadable or schema-mismatched: fail closed to an empty store
            // rather than ever trust a torn/incompatible file.
            return Manifest()
        }
        var totalBytes = 0
        for entry in decoded.entries {
            let (sum, overflow) = totalBytes.addingReportingOverflow(entry.byteCount)
            guard !overflow, sum <= maxTotalBytes else { return Manifest() }
            totalBytes = sum
        }
        var normalized = decoded
        normalized.selections = decoded.selections.map { selection in
            ManifestSelectionRecord(
                sessionId: selection.sessionId,
                imageId: selection.imageId,
                version: selection.version,
                placementId: selection.placementId.flatMap { $0 > 0 ? $0 : nil },
                rows: selection.rows,
                columns: selection.columns,
                x: selection.x,
                y: selection.y,
                z: selection.z
            )
        }
        return normalized
    }
}
