import AppKit
import MetalKit
import SwiftTerm

/// A `LocalProcessTerminalView` that makes the scroll wheel work inside
/// full-screen TUIs.
///
/// SwiftTerm's stock `scrollWheel` only ever scrolls its *own* scrollback
/// buffer, which is empty while an app owns the alternate screen (copilot, vim,
/// less, …) — so the wheel looks dead and the app never sees it. SwiftTerm's
/// `scrollWheel` is `public` (not `open`), so we can't override it; instead a
/// local event monitor (see `AppDelegate`) calls `forwardScroll` first.
///
/// We mirror what real terminals do:
///  1. App has mouse reporting on → translate the wheel into mouse wheel
///     button events (button 4/5).
///  2. App is on the alternate screen without mouse reporting → "alternate
///     scroll": send cursor up/down keys so pagers/TUIs scroll.
///  3. Otherwise (normal shell) → let SwiftTerm scroll its own scrollback.
final class ProjectsTerminalView: LocalProcessTerminalView {
    private var scrollAccum: CGFloat = 0
    private(set) var rendererName = "unconfigured"
    private(set) var remoteContentGeneration: UInt64 = 0
    private var rendererConfigured = false
    private var surfaceRefreshGeneration = 0
    /// True from the moment a remote prompt's paste is written until its submit
    /// Enter fires, so an overlapping remote prompt can't interleave its paste
    /// bytes into a half-submitted one. Main-actor only.
    private var isSubmittingRemotePrompt = false
    /// SwiftTerm emits focus events on first-responder transitions. Inspect the
    /// responder directly instead of its `hasFocus` getter, which also folds in
    /// whether the window is key and can disagree with the last wire event.
    private var hasActualTerminalFocus: Bool {
        window?.firstResponder === self
    }
    /// Captures this session's Kitty inline images for remote clients. One
    /// instance per terminal view (never shared/global), fed on the main actor.
    /// Replaced (once) by `configureImagePersistence` with a session/disk-store
    /// -aware instance before any PTY bytes can possibly arrive.
    private(set) var kittyImageCapture = RemoteKittyImageCapture()

    /// True from construction until this session's durable image restore
    /// (see `configureImagePersistence`) completes or is abandoned. While
    /// true, incoming PTY bytes are buffered (never fed to
    /// `kittyImageCapture.ingest`/`super.dataReceived`) so a live retransmit
    /// or delete can never interleave with the restore replay — see
    /// `bufferDuringImageRestore`. A session never configured for
    /// persistence (`configureImagePersistence` never called — e.g. any
    /// existing test that constructs this view directly) stays `false`
    /// forever, matching prior (pre-persistence) behavior exactly.
    private(set) var isRestoringImages = false
    private var pendingImageRestoreBuffer: [UInt8] = []
    /// Injectable so tests can prove overflow-abandonment deterministically
    /// with a tiny cap, instead of needing megabytes of real data to exceed
    /// the real process-wide default. Defaults to the real shared singleton.
    private var restoreBufferBudget: RemoteKittyRestoreBufferBudget = .shared
    /// Exposed only so tests can deterministically await this session's
    /// disk-restore Task instead of relying on a sleep. Not used by any
    /// production call site.
    private(set) var imageRestoreTaskForTesting: Task<Void, Never>?
    private var restoredSelectionsAwaitingPlacement: [RemoteKittyRestoredSelection] = []
    private var restoredPlacementReplayGeneration = 0
    private var restoredPlacementBufferWasAlternate: Bool?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        remoteContentGeneration &+= 1
        guard !isRestoringImages else {
            bufferDuringImageRestore(slice)
            return
        }
        kittyImageCapture.ingest(slice)
        super.dataReceived(slice: slice)
        scheduleRestoredPlacementReplayIfNeeded()
    }

    /// Wires this view up to durable Kitty-image persistence for `sessionId`
    /// and kicks off its async disk restore. Must be called exactly once,
    /// strictly before any PTY bytes can arrive (i.e. before the owning
    /// `TerminalController` starts the shell/dtach process) — `TerminalController
    /// .init` guarantees this ordering. A no-op on any later call, so it's
    /// safe to call defensively.
    func configureImagePersistence(
        sessionId: String,
        diskStore: RemoteKittyImageDiskStore = .shared,
        restoreBufferBudget: RemoteKittyRestoreBufferBudget? = nil
    ) {
        guard !isRestoringImages, kittyImageCapture.sessionId != sessionId else { return }
        kittyImageCapture = RemoteKittyImageCapture(sessionId: sessionId, diskStore: diskStore)
        // `restoreBufferBudget`'s default can't be spelled as `= .shared` in
        // the parameter list itself: default-argument expressions aren't
        // evaluated in the enclosing (main-actor) isolation context, so
        // referencing a main-actor-isolated static there is a Swift 6
        // isolation error (mirrors `RemoteKittyImageCapture.init`'s own
        // `budget` parameter for the same reason). Resolving it here, inside
        // this already-main-actor-isolated method body, is equivalent for
        // every real caller.
        self.restoreBufferBudget = restoreBufferBudget ?? .shared
        // The overwhelmingly common case — a brand-new session, or any
        // session that has simply never had a Kitty image persisted for it —
        // has nothing at all to restore. Skip the async restore/buffering
        // path entirely rather than unconditionally pay for it (and its
        // inherently non-deterministic `Task` scheduling) only to resolve to
        // a no-op: `dataReceived` behaves exactly as it did before this
        // feature existed for every such session.
        guard diskStore.hasPersistedEntriesSynchronously(sessionId: sessionId) else { return }
        isRestoringImages = true
        imageRestoreTaskForTesting = Task { @MainActor [weak self] in
            let result = await diskStore.restore(sessionId: sessionId)
            guard let self, self.isRestoringImages, self.kittyImageCapture.sessionId == sessionId else {
                return // abandoned (buffer overflow) or superseded: ignore this late result
            }
            self.completeImageRestore(result)
        }
    }

    /// Buffers PTY bytes that arrive while this session's disk image-restore
    /// is still pending, under the (possibly test-injected)
    /// `RemoteKittyRestoreBufferBudget` hard cap — never feeding them to
    /// `kittyImageCapture.ingest`/`super.dataReceived` yet, so a live
    /// retransmit or delete can never interleave with (and corrupt) the
    /// eventual restore replay. Reservation failure (this session's share of
    /// the shared cap would overflow) abandons restoration for *this session
    /// only*: every other still-restoring session is unaffected, and this
    /// session's buffered-then-live stream is flushed through the normal path
    /// immediately, in original order — the late disk-restore result (once it
    /// eventually arrives) is then ignored (see `configureImagePersistence`).
    private func bufferDuringImageRestore(_ slice: ArraySlice<UInt8>) {
        guard restoreBufferBudget.reserve(slice.count) else {
            abandonImageRestore(flushingLive: slice)
            return
        }
        pendingImageRestoreBuffer.append(contentsOf: slice)
    }

    private func abandonImageRestore(flushingLive slice: ArraySlice<UInt8>) {
        isRestoringImages = false
        let buffered = pendingImageRestoreBuffer
        pendingImageRestoreBuffer = []
        restoreBufferBudget.release(buffered.count)
        if !buffered.isEmpty {
            kittyImageCapture.ingest(buffered[...])
            super.dataReceived(slice: buffered[...])
        }
        kittyImageCapture.ingest(slice)
        super.dataReceived(slice: slice)
    }

    private func completeImageRestore(_ result: RemoteKittyRestoredSessionImages) {
        isRestoringImages = false
        applyRestoredImages(result)
        let buffered = pendingImageRestoreBuffer
        pendingImageRestoreBuffer = []
        restoreBufferBudget.release(buffered.count)
        if !buffered.isEmpty {
            kittyImageCapture.ingest(buffered[...])
            super.dataReceived(slice: buffered[...])
            scheduleRestoredPlacementReplayIfNeeded()
        }
    }

    /// Installs every restored `(imageId, version)` entry and current
    /// selection directly into `kittyImageCapture`'s in-memory state (never
    /// through `ingest`, which would mint fresh versions and recursively
    /// re-persist), replays each restored current selection's exact pixels
    /// and placement directly into SwiftTerm (never through `dataReceived`),
    /// then refreshes this view's own content generation once so any cached
    /// remote screen/revision is invalidated to reflect the newly-restored
    /// availability.
    private func applyRestoredImages(_ result: RemoteKittyRestoredSessionImages) {
        guard !result.entries.isEmpty else { return }
        kittyImageCapture.beginRestoring()
        for entry in result.entries {
            kittyImageCapture.restoreEntry(imageId: entry.imageId, version: entry.version, data: entry.data)
        }
        for selection in result.currentSelections {
            kittyImageCapture.restoreCurrentSelection(
                imageId: selection.imageId,
                version: selection.version,
                placementId: selection.placementId,
                rows: selection.rows,
                columns: selection.columns,
                x: selection.x,
                y: selection.y,
                z: selection.z
            )
        }
        kittyImageCapture.finishRestoring()
        let currentSelections = result.currentSelections.filter {
            kittyImageCapture.currentVersion(
                for: $0.imageId,
                placementId: $0.placementId ?? 0
            ) == $0.version
        }
        var transmitted: Set<RestoredImageKey> = []
        for selection in currentSelections {
            let key = RestoredImageKey(imageId: selection.imageId, version: selection.version)
            guard transmitted.insert(key).inserted,
                  let data = kittyImageCapture.imageData(
                      imageId: selection.imageId,
                      version: selection.version
                  )
            else { continue }
            terminal?.feed(byteArray: RemoteKittyReplayEncoding.transmitOnlyFrames(
                imageId: selection.imageId,
                data: data
            ))
        }
        restoredSelectionsAwaitingPlacement = currentSelections
        restoredPlacementBufferWasAlternate = nil
        remoteContentGeneration &+= 1
        refreshSurface()
    }

    private struct RestoredImageKey: Hashable {
        let imageId: UInt32
        let version: UInt64
    }

    /// Virtual placement records are buffer-specific in SwiftTerm. Delay their
    /// replay until the live dtach redraw has gone quiet, so a startup
    /// `CSI ?1049h` switch lands first and the restored records are attached to
    /// the buffer that actually contains the placeholder cells. Keep the
    /// selections around so a later normal/alternate-buffer switch can replay
    /// them once into that newly-active buffer too.
    private func scheduleRestoredPlacementReplayIfNeeded() {
        guard !restoredSelectionsAwaitingPlacement.isEmpty, terminal != nil else { return }
        let isAlternate = terminal?.isCurrentBufferAlternate ?? false
        guard restoredPlacementBufferWasAlternate != isAlternate else { return }
        restoredPlacementReplayGeneration += 1
        let generation = restoredPlacementReplayGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self,
                  self.restoredPlacementReplayGeneration == generation
            else { return }
            self.replayRestoredPlacementsNow()
        }
    }

    private func replayRestoredPlacementsNow() {
        guard let terminal else { return }
        let activeBufferIsAlternate = terminal.isCurrentBufferAlternate
        guard restoredPlacementBufferWasAlternate != activeBufferIsAlternate else { return }

        var currentSelections: [RemoteKittyRestoredSelection] = []
        for restored in restoredSelectionsAwaitingPlacement {
            guard let current = kittyImageCapture.currentPersistedSelection(
                imageId: restored.imageId,
                placementId: restored.placementId
            ),
                current.version == restored.version
            else { continue }
            currentSelections.append(RemoteKittyRestoredSelection(
                imageId: restored.imageId,
                version: current.version,
                placementId: current.placementId,
                rows: current.rows,
                columns: current.columns,
                x: current.x,
                y: current.y,
                z: current.z
            ))
        }
        restoredSelectionsAwaitingPlacement = currentSelections
        for selection in currentSelections {
            terminal.feed(byteArray: RemoteKittyReplayEncoding.placementFrame(
                imageId: selection.imageId,
                placementId: replayPlacementId(
                    for: selection,
                    among: currentSelections
                ),
                rows: selection.rows,
                columns: selection.columns,
                x: selection.x,
                y: selection.y,
                z: selection.z
            ))
        }
        restoredPlacementBufferWasAlternate = activeBufferIsAlternate
        refreshSurface()
    }

    private func replayPlacementId(
        for selection: RemoteKittyRestoredSelection,
        among selections: [RemoteKittyRestoredSelection]
    ) -> UInt32 {
        if let placementId = selection.placementId, placementId > 0 {
            return placementId
        }
        let explicitIds = Set(selections.compactMap {
            $0.imageId == selection.imageId ? $0.placementId : nil
        })
        var candidate = UInt32.max
        while explicitIds.contains(candidate), candidate > 1 {
            candidate -= 1
        }
        return candidate
    }

    var restoredPlacementBufferWasAlternateForTesting: Bool? {
        restoredPlacementBufferWasAlternate
    }

    func replayRestoredPlacementsForTesting() {
        replayRestoredPlacementsNow()
    }

    /// Releases any startup bytes reserved for a restore that is being torn
    /// down before its async disk load completes. Dropping them is correct:
    /// this terminal client is closing, while its dtach master remains the
    /// source of truth for the next attachment.
    func cancelImageRestore() {
        restoredPlacementReplayGeneration += 1
        restoredSelectionsAwaitingPlacement.removeAll(keepingCapacity: false)
        restoredPlacementBufferWasAlternate = nil
        imageRestoreTaskForTesting?.cancel()
        imageRestoreTaskForTesting = nil
        guard isRestoringImages || !pendingImageRestoreBuffer.isEmpty else { return }
        isRestoringImages = false
        restoreBufferBudget.release(pendingImageRestoreBuffer.count)
        pendingImageRestoreBuffer.removeAll(keepingCapacity: false)
    }

    /// Normal app termination must preserve any PTY bytes already buffered by
    /// this view before the process reader is stopped. Abandon the disk restore
    /// but flush those bytes through the normal capture/terminal path first;
    /// the late restore result is ignored because `isRestoringImages` is false.
    func flushImageRestoreBufferForTermination() {
        imageRestoreTaskForTesting?.cancel()
        imageRestoreTaskForTesting = nil
        guard isRestoringImages || !pendingImageRestoreBuffer.isEmpty else { return }
        isRestoringImages = false
        let buffered = pendingImageRestoreBuffer
        pendingImageRestoreBuffer.removeAll(keepingCapacity: false)
        restoreBufferBudget.release(buffered.count)
        guard !buffered.isEmpty else { return }
        kittyImageCapture.ingest(buffered[...])
        super.dataReceived(slice: buffered[...])
    }

    /// Awaits this session's disk-restore `Task` directly (not a sleep), so
    /// tests can deterministically observe post-restore state. A no-op if
    /// `configureImagePersistence` never engaged the async path at all (the
    /// common "nothing to restore" case) — not used by any production call
    /// site.
    func waitForImageRestoreForTesting() async {
        await imageRestoreTaskForTesting?.value
    }

    func sendRemoteInput(_ value: String) {
        send(Array(value.utf8))
    }

    @discardableResult
    func sendRemoteCommand(_ value: String, forceFocusReporting: Bool) -> Bool {
        guard !isSubmittingRemotePrompt,
              let terminal,
              let bytes = Self.remoteCommandBytes(
                value,
                keyboardEnhancementFlags: terminal.keyboardEnhancementFlags,
                scopedFocus: forceFocusReporting && !hasActualTerminalFocus
              ) else {
            return false
        }
        send(bytes)
        return true
    }

    @discardableResult
    func sendRemotePrompt(_ value: String) -> Bool {
        guard !isSubmittingRemotePrompt,
              terminal != nil else {
            return false
        }
        let startedWithScopedFocus = !hasActualTerminalFocus
        guard let paste = Self.remotePromptPasteBytes(
            value,
            scopedFocus: startedWithScopedFocus
        ) else { return false }
        // Deliver the bracketed paste, then submit Enter. The Copilot TUI commits
        // pasted text to its input asynchronously, so Enter sent too soon fires
        // before the text lands and leaves the prompt unsubmitted.
        // There is no commit acknowledgement, so we wait a floor long enough for
        // the paste to commit, and only *extend* past it (never shorten below it)
        // while terminal output is still streaming — a slow/loaded commit keeps
        // emitting — capped so a continuously redrawing TUI still submits. The
        // in-flight flag rejects an overlapping prompt (the caller keeps it queued
        // and retries) so two pastes can't interleave before the first submits.
        isSubmittingRemotePrompt = true
        send(paste)
        let floorTicks = Self.promptSubmitFloorTicks(byteCount: paste.count)
        let maxTicks = Self.promptSubmitMaxTicks(byteCount: paste.count)
        Task { @MainActor [weak self] in
            guard let self else { return }
            var submitted = false
            defer {
                self.isSubmittingRemotePrompt = false
                if startedWithScopedFocus,
                   !submitted,
                   !self.hasActualTerminalFocus,
                   self.terminal != nil {
                    self.send(Self.remoteFocusOutBytes)
                }
            }
            var lastGeneration = self.remoteContentGeneration
            var quietTicks = 0
            for tick in 0 ..< maxTicks {
                do {
                    try await Task.sleep(for: Self.promptSubmitPollInterval)
                } catch {
                    return // cancelled: don't submit an unsettled paste
                }
                guard self.terminal != nil else { return }
                let generation = self.remoteContentGeneration
                if generation != lastGeneration {
                    lastGeneration = generation
                    quietTicks = 0
                } else {
                    quietTicks += 1
                }
                // Submit once past the floor and terminal output has been quiet
                // for the settle window; keep waiting while output still streams.
                if tick + 1 >= floorTicks, quietTicks >= Self.promptSubmitSettleTicks {
                    break
                }
            }
            guard let terminal = self.terminal else { return }
            self.send(Self.remoteSubmitBytes(
                keyboardEnhancementFlags: terminal.keyboardEnhancementFlags,
                scopedFocus: !self.hasActualTerminalFocus
            ))
            submitted = true
        }
        return true
    }

    /// How often to poll terminal-output activity while waiting to submit.
    static let promptSubmitPollInterval: Duration = .milliseconds(30)
    /// Consecutive quiet polls that let a submit fire once past the floor
    /// (≈ `promptSubmitSettleTicks` × `promptSubmitPollInterval`).
    static let promptSubmitSettleTicks = 3

    /// Minimum wait before submitting, in poll ticks — long enough for the paste
    /// to commit even under load (comfortably above the old fixed delay). Scales
    /// with paste size (a single-threaded TUI ingests large pastes slower) and is
    /// bounded. 30ms ticks: 10 (300ms) … 20 (600ms).
    nonisolated static func promptSubmitFloorTicks(byteCount: Int) -> Int {
        let base = 10
        let extra = min(max(0, byteCount - 1_024) / 960, 10)
        return base + extra
    }

    /// Upper bound on the wait, in poll ticks: the floor plus a bounded settle
    /// extension so a continuously redrawing TUI still submits.
    nonisolated static func promptSubmitMaxTicks(byteCount: Int) -> Int {
        promptSubmitFloorTicks(byteCount: byteCount) + 17
    }

    nonisolated static let remoteFocusInBytes = Array("\u{1b}[I".utf8)
    nonisolated static let remoteFocusOutBytes = Array("\u{1b}[O".utf8)

    /// An unmodified Enter press encoded the same way SwiftTerm does: report-all
    /// Kitty mode requires CSI-u, while every other negotiated mode uses CR.
    nonisolated static func remoteEnterBytes(
        keyboardEnhancementFlags: KittyKeyboardFlags
    ) -> [UInt8] {
        keyboardEnhancementFlags.contains(.reportAllKeys)
            ? Array("\u{1b}[13u".utf8)
            : [0x0d]
    }

    nonisolated static func remoteSubmitBytes(
        keyboardEnhancementFlags: KittyKeyboardFlags,
        scopedFocus: Bool
    ) -> [UInt8] {
        var bytes = scopedFocus ? remoteFocusInBytes : []
        bytes.append(contentsOf: remoteEnterBytes(
            keyboardEnhancementFlags: keyboardEnhancementFlags
        ))
        if scopedFocus {
            bytes.append(contentsOf: remoteFocusOutBytes)
        }
        return bytes
    }

    nonisolated static func remoteCommandTextBytes(_ value: String) -> [UInt8]? {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              normalized.utf8.count <= 8_192 else { return nil }
        for scalar in normalized.unicodeScalars {
            if scalar.value == 0x7f
                || (scalar.value < 0x20 && scalar != "\n" && scalar != "\t")
                || (0x80 ... 0x9f).contains(scalar.value) {
                return nil
            }
        }
        return Array(normalized.utf8)
    }

    nonisolated static func remoteCommandBytes(
        _ value: String,
        keyboardEnhancementFlags: KittyKeyboardFlags,
        scopedFocus: Bool
    ) -> [UInt8]? {
        guard let command = remoteCommandTextBytes(value) else { return nil }
        var bytes = scopedFocus ? remoteFocusInBytes : []
        bytes.append(contentsOf: command)
        bytes.append(contentsOf: remoteEnterBytes(
            keyboardEnhancementFlags: keyboardEnhancementFlags
        ))
        if scopedFocus {
            bytes.append(contentsOf: remoteFocusOutBytes)
        }
        return bytes
    }

    /// The bracketed-paste byte sequence for a remote prompt. Enter is encoded
    /// separately after the paste settles so active keyboard protocols are respected.
    nonisolated static func remotePromptPasteBytes(
        _ value: String,
        scopedFocus: Bool = false
    ) -> [UInt8]? {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              normalized.utf8.count <= 8_192 else { return nil }
        for scalar in normalized.unicodeScalars {
            if scalar.value == 0x7f
                || (scalar.value < 0x20 && scalar != "\n" && scalar != "\t")
                || (0x80 ... 0x9f).contains(scalar.value) {
                return nil
            }
        }
        var bytes = scopedFocus ? remoteFocusInBytes : []
        bytes.append(contentsOf: [0x1b, 0x1b])
        bytes.append(contentsOf: "\u{1b}[200~".utf8)
        bytes.append(contentsOf: normalized.utf8)
        bytes.append(contentsOf: "\u{1b}[201~".utf8)
        return bytes
    }

    func sendRemoteKey(_ key: String, forceFocusReporting: Bool = false) {
        if key == "enter", forceFocusReporting,
           let terminal {
            send(Self.remoteSubmitBytes(
                keyboardEnhancementFlags: terminal.keyboardEnhancementFlags,
                scopedFocus: !hasActualTerminalFocus
            ))
            return
        }
        let selector: Selector?
        switch key {
        case "enter": selector = #selector(insertNewline(_:))
        case "escape": selector = #selector(cancelOperation(_:))
        case "backspace": selector = #selector(deleteBackward(_:))
        case "tab": selector = #selector(insertTab(_:))
        case "up": selector = #selector(moveUp(_:))
        case "down": selector = #selector(moveDown(_:))
        case "left": selector = #selector(moveLeft(_:))
        case "right": selector = #selector(moveRight(_:))
        default: selector = nil
        }
        if let selector { doCommand(by: selector) }
    }

    /// Forwards a web-client wheel gesture into a TUI without attaching or
    /// resizing another PTY. Positive deltas mean up/older, matching the desktop
    /// `forwardScroll` convention.
    @discardableResult
    func sendRemoteScroll(delta: Int, agentLive: Bool) -> Bool {
        guard let terminal, delta != 0 else { return false }
        let up = delta > 0
        let count = min(abs(delta), 8)

        if agentLive || (allowMouseReporting && terminal.mouseMode != .off) {
            let flags = terminal.encodeButton(
                button: up ? 4 : 5,
                release: false,
                shift: false,
                meta: false,
                control: false
            )
            let col = max(0, terminal.cols / 2)
            let row = max(0, terminal.rows / 2)
            for _ in 0 ..< count {
                terminal.sendEvent(buttonFlags: flags, x: col, y: row)
            }
            return true
        }

        guard terminal.isCurrentBufferAlternate else { return false }
        let sequence: [UInt8] = up
            ? (terminal.applicationCursor
                ? [0x1b, 0x4f, 0x41]
                : [0x1b, 0x5b, 0x41])
            : (terminal.applicationCursor
                ? [0x1b, 0x4f, 0x42]
                : [0x1b, 0x5b, 0x42])
        for _ in 0 ..< count { send(sequence) }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureRendererIfNeeded()
    }

    private func configureRendererIfNeeded() {
        guard window != nil, !rendererConfigured else { return }
        rendererConfigured = true

        let requested = ProcessInfo.processInfo.environment["COPILOT_PROJECTS_RENDERER"]?
            .lowercased()
        guard requested != "coregraphics" else {
            rendererName = "coregraphics"
            disableFullRedrawOnAnyChanges = false
            return
        }
        do {
            try setUseMetal(true)
            rendererName = "metal"
        } catch {
            rendererName = "coregraphics-fallback"
            disableFullRedrawOnAnyChanges = false
            NSLog("copilot-projects: Metal renderer unavailable, using CoreGraphics: \(error)")
        }
    }

    /// Ask the active surface to render its current model after being revealed.
    /// SwiftTerm's Metal view is intentionally paused and redraws on demand.
    func refreshSurface() {
        configureRendererIfNeeded()
        if isUsingMetalRenderer,
           let metalView: MTKView = firstDescendant(of: MTKView.self) {
            // `terminal.updateFullScreen()` marks the terminal's rows dirty but
            // does NOT reach the Metal renderer's rebuild path: `metalDirtyRange`
            // is only set inside the view's `updateDisplay()`, which this
            // reveal/redraw path never calls, and the renderer only does a full
            // rebuild when its cache signature changes or `rowCache` is empty. For
            // an idle, unchanged buffer neither holds, so a plain `setNeedsDisplay`
            // just repaints the *cached* rows. If a transient CoreText failure ever
            // baked empty glyph buffers into those rows (or poisoned the
            // never-cleared empty-ink cache), the surface stays blank — only the
            // textureless cursor quad paints — and no reveal/redraw recovers it
            // short of a restart. Dropping the row + empty-ink caches forces the
            // next draw to rebuild every visible row from the current model,
            // re-rasterizing any wrongly-memoized glyph (the valid glyph atlas is
            // retained, so healthy glyphs are not re-rasterized).
            invalidateMetalRenderCaches()
            surfaceRefreshGeneration += 1
            let generation = surfaceRefreshGeneration
            metalView.setNeedsDisplay(metalView.bounds)
            // A paused MTKView can be asked to draw before its just-unhidden
            // CAMetalLayer has a drawable. Retry once after AppKit commits the
            // visibility/layout transaction; rapid switches invalidate older retries.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.surfaceRefreshGeneration == generation,
                      self.window != nil,
                      !self.isHiddenOrHasHiddenAncestor,
                      self.bounds.width > 0,
                      self.bounds.height > 0,
                      let currentMetalView: MTKView = self.firstDescendant(of: MTKView.self),
                      currentMetalView.bounds.width > 0,
                      currentMetalView.bounds.height > 0
                else { return }
                // Re-invalidate: if the immediate draw already ran and rebuilt the
                // rows empty (e.g. the transient failure was still in effect), the
                // rows are cached again and this retry would otherwise be a no-op
                // (idle buffer ⇒ no signature change, rows cacheValid). Cheap: the
                // glyph atlas is retained.
                self.invalidateMetalRenderCaches()
                currentMetalView.setNeedsDisplay(currentMetalView.bounds)
            }
        } else {
            terminal?.updateFullScreen()
            needsDisplay = true
            display()
        }
    }

    /// Strong manual recovery for a surface that stayed blank after reveal:
    /// invalidate the full model, draw the paused Metal view immediately, and
    /// retain the normal deferred retry for a temporarily unavailable drawable.
    func forceRedraw() {
        refreshSurface()
        if isUsingMetalRenderer,
           let metalView: MTKView = firstDescendant(of: MTKView.self) {
            metalView.draw()
        }
    }

    private func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        firstDescendant(of: type, below: self)
    }

    private func firstDescendant<T: NSView>(of type: T.Type, below view: NSView) -> T? {
        for child in view.subviews {
            if let match = child as? T { return match }
            if let match = firstDescendant(of: type, below: child) { return match }
        }
        return nil
    }

    /// Returns true if the wheel event was handled (and so should be consumed).
    /// Returns false to let SwiftTerm scroll its own buffer. `agentLive` is true
    /// when a copilot agent owns this session: such a session is a mouse-reporting
    /// TUI even when SwiftTerm's mode looks off after a dtach-resume desync, so the
    /// wheel is forwarded as mouse events regardless.
    func forwardScroll(_ event: NSEvent, agentLive: Bool) -> Bool {
        guard let terminal = terminal else { return false }

        // Accumulate fractional/precise deltas so a single trackpad flick (dozens
        // of tiny events) doesn't fire dozens of steps. Positive = up.
        let cellH = bounds.height > 0 ? bounds.height / CGFloat(max(terminal.rows, 1)) : 18
        let lines = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / max(cellH, 1)
            : event.scrollingDeltaY
        guard lines != 0 else { return false }

        if (lines > 0) != (scrollAccum > 0) { scrollAccum = 0 }
        scrollAccum += lines
        let steps = Int(scrollAccum)
        guard steps != 0 else { return true }   // consumed; still accumulating
        scrollAccum -= CGFloat(steps)

        let up = steps > 0
        let count = min(abs(steps), 8)

        if agentLive || (allowMouseReporting && terminal.mouseMode != .off) {
            // 1. App reads the mouse (or is a live agent TUI) → send wheel buttons.
            let mods = event.modifierFlags
            let flags = terminal.encodeButton(
                button: up ? 4 : 5, release: false,
                shift: mods.contains(.shift), meta: mods.contains(.option), control: mods.contains(.control))
            let pos = gridPosition(for: event)
            for _ in 0 ..< count { terminal.sendEvent(buttonFlags: flags, x: pos.col, y: pos.row) }
            return true
        }

        if terminal.isCurrentBufferAlternate {
            // 2. Alt-screen app without mouse reporting → alternate-scroll: send
            //    cursor up/down keys (application-cursor aware).
            let seq: [UInt8] = up
                ? (terminal.applicationCursor ? [0x1b, 0x4f, 0x41] : [0x1b, 0x5b, 0x41])   // ESC O A / ESC [ A
                : (terminal.applicationCursor ? [0x1b, 0x4f, 0x42] : [0x1b, 0x5b, 0x42])   // ESC O B / ESC [ B
            for _ in 0 ..< count { send(seq) }
            return true
        }

        // 3. Normal shell buffer → scroll SwiftTerm's own scrollback directly and
        //    consume the event. (Returning the event for SwiftTerm's scrollWheel
        //    to handle lets SwiftUI swallow it first, so scrolling looked dead.)
        guard canScroll else { return false }
        if up { scrollUp(lines: count) } else { scrollDown(lines: count) }
        return true
    }

    /// Forward a plain click (button-0 press + release) to a mouse-reporting
    /// agent so its own click handling fires. The Copilot CLI tracks markdown-link
    /// rectangles and opens the URL when it receives the click — it does NOT emit
    /// OSC 8 — so without this, markdown links are dead. Only plain clicks are
    /// forwarded (drags still select text locally), mirroring Terminal.app.
    func forwardClick(_ event: NSEvent) {
        guard let terminal = terminal else { return }
        // A resumed session's terminal reverts to the default x10 mouse protocol (dtach
        // replays nothing; the CLI doesn't re-emit ?1006h on reattach), so a forwarded
        // click would be x10-encoded and the CLI's SGR-based link handler ignores it —
        // markdown links go dead until the CLI restarts. Re-assert SGR so the click
        // encodes the way the CLI expects. Idempotent, and only live-agent clicks reach here.
        terminal.feed(byteArray: Array("\u{1b}[?1006h".utf8))
        let pos = gridPosition(for: event)
        let mods = event.modifierFlags
        let shift = mods.contains(.shift), meta = mods.contains(.option), ctrl = mods.contains(.control)
        let press = terminal.encodeButton(button: 0, release: false, shift: shift, meta: meta, control: ctrl)
        terminal.sendEvent(buttonFlags: press, x: pos.col, y: pos.row)
        let release = terminal.encodeButton(button: 0, release: true, shift: shift, meta: meta, control: ctrl)
        terminal.sendEvent(buttonFlags: release, x: pos.col, y: pos.row)
    }

    /// On-screen cell under the pointer.
    private func gridPosition(for event: NSEvent) -> (col: Int, row: Int) {
        guard let terminal = terminal, bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        let p = convert(event.locationInWindow, from: nil)
        let cellW = bounds.width / CGFloat(terminal.cols)
        let cellH = bounds.height / CGFloat(terminal.rows)
        let col = min(max(0, Int(p.x / max(cellW, 1))), terminal.cols - 1)
        let row = min(max(0, Int((bounds.height - p.y) / max(cellH, 1))), terminal.rows - 1)
        return (col, row)
    }

    /// True when the pointer for `event` is over this terminal view. Uses
    /// `hitTest` (robust against the SwiftUI/representable nesting) rather than
    /// manual bounds math.
    func containsPointer(for event: NSEvent) -> Bool {
        guard let win = event.window ?? window,
              let hit = win.contentView?.hitTest(event.locationInWindow) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }

    // MARK: - Copy: strip the CLI's scrollbar gutter

    /// Glyphs the Copilot CLI (and similar TUIs) use to paint a vertical
    /// scrollbar in the terminal's last column: heavy vertical + block/shade
    /// elements. The light `│` (U+2502), double `║`, and dotted box verticals are
    /// deliberately EXCLUDED — those are what tables, `git log --graph`, and panel
    /// borders use, so that common box content isn't mistaken for a scrollbar.
    /// (A heavy/block border hugging the last column could still match, but that's
    /// rare and further guarded by the detection threshold + margin rule below.)
    private static let scrollbarGlyphs: Set<Character> = [
        "\u{2503}",                                                    // ┃ heavy vertical (the Copilot scrollbar)
        "\u{2588}", "\u{2589}", "\u{258A}", "\u{258B}", "\u{258C}",    // █ ▉ ▊ ▋ ▌
        "\u{258D}", "\u{258E}", "\u{258F}", "\u{2590}", "\u{2595}",    // ▍ ▎ ▏ ▐ ▕
        "\u{2591}", "\u{2592}", "\u{2593}",                            // ░ ▒ ▓ (shaded tracks)
    ]

    /// The Copilot CLI (and other TUIs) paint a vertical scrollbar in the last
    /// column; SwiftTerm's selection copies that column verbatim, so a multi-line
    /// copy ends every line with a stray bar (e.g. `┃`). Detect the scrollbar from
    /// the live buffer's last column and strip the gutter from the clipboard.
    /// Detection means the text is only ever touched when a scrollbar is actually
    /// present — ordinary copies pass through unchanged.
    override func copy(_ sender: Any) {
        super.copy(sender)
        guard let terminal = terminal else { return }
        let pasteboard = NSPasteboard.general
        guard let raw = pasteboard.string(forType: .string), !raw.isEmpty else { return }
        let bars = Self.scrollbarColumnGlyphs(in: terminal)
        guard !bars.isEmpty else { return }
        let cleaned = Self.strippingScrollbarGutter(raw, bars: bars)
        if cleaned != raw {
            pasteboard.clearContents()
            pasteboard.setString(cleaned, forType: .string)
        }
    }

    /// Glyphs occupying the last column on a meaningful run of visible rows — an
    /// actual scrollbar track/thumb, not an incidental box-drawing character. The
    /// threshold is on the COMBINED occupancy (track + thumb), and every glyph
    /// actually seen in that column is returned, so a thumb drawn with a different
    /// (brighter) glyph than the track is stripped too rather than left behind.
    private static func scrollbarColumnGlyphs(in terminal: Terminal) -> Set<Character> {
        let cols = terminal.cols, rows = terminal.rows
        guard cols > 1, rows > 0 else { return [] }
        var counts: [Character: Int] = [:]
        for r in 0 ..< rows {
            if let ch = terminal.getCharacter(col: cols - 1, row: r), scrollbarGlyphs.contains(ch) {
                counts[ch, default: 0] += 1
            }
        }
        let total = counts.values.reduce(0, +)
        return total >= max(3, rows / 5) ? Set(counts.keys) : []
    }

    /// Remove a trailing scrollbar gutter from each line: the bar glyph plus the
    /// whitespace margin separating it from content. Requires at least one space
    /// (or an otherwise-blank line); a bar directly adjacent to content is kept.
    /// Light/double table borders are excluded from `scrollbarGlyphs` above.
    nonisolated static func strippingScrollbarGutter(_ text: String, bars: Set<Character>) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            var tail = line.endIndex
            while tail > line.startIndex {
                let p = line.index(before: tail)
                let c = line[p]
                if c == " " || c == "\t" { tail = p } else { break }
            }
            guard tail > line.startIndex else { return line }            // empty / all whitespace
            let barIdx = line.index(before: tail)
            guard bars.contains(line[barIdx]) else { return line }       // no scrollbar at line end
            var content = barIdx
            var margin = 0
            while content > line.startIndex {
                let p = line.index(before: content)
                if line[p] == " " || line[p] == "\t" { margin += 1; content = p } else { break }
            }
            if content == line.startIndex || margin >= 1 {
                return line[line.startIndex ..< content]                 // strip the gutter + margin
            }
            return line                                                  // bar adjacent to content -> keep
        }.joined(separator: "\n")
    }

    /// Hide SwiftTerm's OSC 9;4 progress bar (`TerminalProgressBarView`): a 2pt
    /// accent bar pinned to the top edge that the Copilot CLI triggers while
    /// working, which reads as a stray blue line (the tab spinner already signals
    /// "running"). `apply()` only toggles `isHidden`/layer colors, never
    /// `alphaValue`, so zeroing alpha hides it for good without yanking it out of
    /// the hierarchy mid-insertion.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if String(describing: type(of: subview)) == "TerminalProgressBarView" {
            subview.alphaValue = 0
        } else if subview is NSScroller {
            // The CLI (a full-screen TUI) draws its own scrollbar, so SwiftTerm's
            // native scroller is redundant. updateScroller only toggles isEnabled,
            // never isHidden, so hiding it here sticks.
            subview.isHidden = true
        }
    }
}

/// Process-wide hard cap on bytes buffered across every session currently
/// waiting on its async disk image-restore (see `ProjectsTerminalView
/// .bufferDuringImageRestore`) — independent of any single session's own PTY
/// output volume, so many sessions restoring at once (e.g. right after an app
/// relaunch) can never collectively pin unbounded memory before their loads
/// complete. Main-actor-only, matching every caller.
@MainActor
final class RemoteKittyRestoreBufferBudget {
    /// The real process-wide instance every `ProjectsTerminalView` uses by
    /// default. Tests inject their own isolated instance instead, so an
    /// assertion about this bound is never at the mercy of unrelated tests'
    /// leftover reservations.
    static let shared = RemoteKittyRestoreBufferBudget()

    /// Comfortably larger than any single session's own in-flight Kitty
    /// pending-transmission budget, but still a hard, deliberately small
    /// bound: real shell startup output before a restore completes is tiny,
    /// so hitting this at all should be rare — and correctness (never
    /// interleaving buffered bytes with a stale disk-restore replay) matters
    /// far more than tolerating an unbounded buffer.
    let maxTotalBytes: Int
    private(set) var totalBytes = 0

    init(maxTotalBytes: Int = 16 * 1_024 * 1_024) {
        self.maxTotalBytes = maxTotalBytes
    }

    func reserve(_ bytes: Int) -> Bool {
        guard bytes > 0 else { return true }
        guard totalBytes + bytes <= maxTotalBytes else { return false }
        totalBytes += bytes
        return true
    }

    func release(_ bytes: Int) {
        totalBytes = max(0, totalBytes - bytes)
    }
}
