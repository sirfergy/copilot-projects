import Darwin
import Foundation
import CopilotProjectsCore
import CopilotProjectsProtocol

/// Prompt image attachments resolved directly from a Copilot session's
/// `events.jsonl` `user.message` file attachments for the turns in a
/// `TranscriptSnapshot`. Stateless: no cross-session or cross-turn cache.
struct TranscriptPromptAttachments: Equatable, Sendable {
    private static let maxAttachmentsPerTurn = 8
    private static let maxBytesPerImage = 5 * 1_024 * 1_024
    private static let maxTotalBytes = 32 * 1_024 * 1_024

    struct Item: Equatable, Identifiable, Sendable {
        let identity: TranscriptImageIdentity
        let data: Data?
        var id: TranscriptImageIdentity { identity }
    }

    var sessionId: String = ""
    var copilotSessionId: String = ""
    var orderedTurnIds: [String] = []
    var scannedEventsPath: String = ""
    var scannedEventsIdentity: String = ""
    var scannedEventsBytes: Int = 0
    var resolvedTurnIds: Set<String> = []
    var pathsByTurnId: [String: [String]] = [:]
    var itemsByTurnId: [String: [Item]] = [:]
    var watchedFiles: [String: String] = [:]

    func items(forTurnId turnId: String, sessionId expectedSessionId: String, copilotSessionId expectedCopilotId: String) -> [Item] {
        guard !expectedSessionId.isEmpty,
              !expectedCopilotId.isEmpty,
              expectedSessionId == sessionId,
              expectedCopilotId == copilotSessionId else {
            return []
        }
        return itemsByTurnId[turnId] ?? []
    }

    func hasWatchedFileChanges() -> Bool {
        if !scannedEventsIdentity.isEmpty {
            var st = stat()
            guard lstat(scannedEventsPath, &st) == 0,
                  (st.st_mode & S_IFMT) == S_IFREG,
                  "\(st.st_dev):\(st.st_ino)" == scannedEventsIdentity,
                  Int(st.st_size) >= scannedEventsBytes else {
                return true
            }
        }
        for (path, token) in watchedFiles where Self.fileStatToken(atPath: path) != token {
            return true
        }
        return false
    }

    static func load(
        sessionId: String,
        snapshot: TranscriptSnapshot,
        previous: TranscriptPromptAttachments? = nil,
        copilotHome: String? = nil
    ) -> TranscriptPromptAttachments {
        let copilotId = snapshot.copilotSessionId
        let activeTurns = snapshot.turns.filter {
            $0.kind != "automated" && !$0.id.isEmpty && !$0.id.hasPrefix("session-resume-")
        }
        let orderedTurnIds = activeTurns.map(\.id)
        let wantedTurnIds = Set(orderedTurnIds)
        var result = TranscriptPromptAttachments(
            sessionId: sessionId,
            copilotSessionId: copilotId,
            orderedTurnIds: orderedTurnIds
        )
        guard !sessionId.isEmpty, !copilotId.isEmpty, !wantedTurnIds.isEmpty else { return result }
        let prior = (previous?.sessionId == sessionId && previous?.copilotSessionId == copilotId) ? previous : nil
        if let prior,
           prior.orderedTurnIds == orderedTurnIds,
           wantedTurnIds.isSubset(of: prior.resolvedTurnIds),
           Set(prior.itemsByTurnId.keys) == wantedTurnIds.intersection(prior.pathsByTurnId.keys),
           !prior.hasWatchedFileChanges() {
            return prior
        }

        let store = copilotHome.map { CopilotSessionStore(environment: ["COPILOT_HOME": $0]) }
            ?? CopilotSessionStore()
        guard let eventsPath = store.transcriptPath(for: copilotId) else { return result }
        result.scannedEventsPath = eventsPath
        let eventsToken = Self.fileStatToken(atPath: eventsPath)
        let eventsFD = open(eventsPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        var st = stat()
        guard eventsFD >= 0,
              fstat(eventsFD, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size > 0,
              let fp = fdopen(eventsFD, "r") else {
            if eventsFD >= 0 { close(eventsFD) }
            result.watchedFiles[eventsPath] = eventsToken
            return result
        }
        defer { fclose(fp) }

        let eventsSize = Int(st.st_size)
        let eventsIdentity = "\(st.st_dev):\(st.st_ino)"
        let startOffset: Int
        if let prior,
           prior.scannedEventsPath == eventsPath,
           prior.scannedEventsIdentity == eventsIdentity,
           eventsSize >= prior.scannedEventsBytes {
            result.resolvedTurnIds = prior.resolvedTurnIds.intersection(wantedTurnIds)
            result.pathsByTurnId = prior.pathsByTurnId.filter { wantedTurnIds.contains($0.key) }
            startOffset = prior.scannedEventsBytes
        } else {
            startOffset = 0
        }

        var linePtr: UnsafeMutablePointer<CChar>?
        var lineCap = 0
        defer { free(linePtr) }
        let typePrefix = Array("{\"type\":\"".utf8)
        let userPrefix = Array("{\"type\":\"user.message\"".utf8)
        let userNeedle = Array("\"user.message\"".utf8)
        let decoder = JSONDecoder()
        func scanRange(_ lower: Int, _ upper: Int) -> Int {
            guard lower < upper, fseeko(fp, off_t(lower), SEEK_SET) == 0 else { return lower }
            clearerr(fp)
            var cursor = lower
            while cursor < upper {
                let n = getline(&linePtr, &lineCap, fp)
                guard n > 0, let ptr = linePtr else { break }
                let lineLen = min(n, upper - cursor)
                guard lineLen > 0, ptr[lineLen - 1] == 0x0A else { break }
                cursor += lineLen
                guard lineLen >= 24 else { continue }
                let isUser = memcmp(ptr, typePrefix, typePrefix.count) == 0
                    ? memcmp(ptr, userPrefix, userPrefix.count) == 0
                    : memmem(ptr, lineLen, userNeedle, userNeedle.count) != nil
                guard isUser else { continue }
                let lineSlice = Data(bytesNoCopy: ptr, count: lineLen - 1, deallocator: .none)
                if let event = try? decoder.decode(RawUserMessageEvent.self, from: lineSlice),
                   event.type == "user.message",
                   event.agentId == nil,
                   let turnId = event.id,
                   wantedTurnIds.contains(turnId),
                   let data = event.data,
                   data.source == nil || data.source?.hasPrefix("schedule-") == true {
                    result.resolvedTurnIds.insert(turnId)
                    let paths = Array((data.attachments ?? []).filter(Self.isPNGFileAttachment).prefix(Self.maxAttachmentsPerTurn)).compactMap(\.path)
                    result.pathsByTurnId[turnId] = paths.isEmpty ? nil : paths
                }
            }
            return cursor
        }
        let consumedEnd = scanRange(startOffset, eventsSize)
        if startOffset > 0,
           let prior,
           !wantedTurnIds.subtracting(prior.orderedTurnIds).isSubset(of: result.resolvedTurnIds) {
            _ = scanRange(0, startOffset)
        }
        if !wantedTurnIds.isSubset(of: result.resolvedTurnIds) {
            result.watchedFiles[eventsPath] = eventsToken
        }
        result.scannedEventsIdentity = eventsIdentity
        result.scannedEventsBytes = consumedEnd

        var remainingBudget = Self.maxTotalBytes
        for turn in activeTurns.reversed() {
            guard let paths = result.pathsByTurnId[turn.id],
                  result.itemsByTurnId[turn.id] == nil else { continue }
            let currentTokens = paths.map(Self.fileStatToken(atPath:))
            for (path, token) in zip(paths, currentTokens) {
                result.watchedFiles[path] = token
            }
            if let priorItems = prior?.itemsByTurnId[turn.id],
               prior?.pathsByTurnId[turn.id] == paths,
               priorItems.count == paths.count,
               priorItems.allSatisfy({ $0.data != nil }),
               zip(paths, currentTokens).allSatisfy({ prior?.watchedFiles[$0.0] == $0.1 }),
               priorItems.reduce(0, { $0 + ($1.data?.count ?? 0) }) <= remainingBudget {
                remainingBudget -= priorItems.reduce(0, { $0 + ($1.data?.count ?? 0) })
                result.itemsByTurnId[turn.id] = priorItems
                continue
            }
            var items: [Item] = []
            for (index, path) in paths.enumerated() {
                let cap = min(Self.maxBytesPerImage, remainingBudget)
                let loaded = Self.readValidatedPNG(
                    atPath: path,
                    maxModifiedAt: turn.startedAt,
                    maxBytes: cap
                )
                if let data = loaded?.data {
                    remainingBudget -= data.count
                }
                let occurrenceKey = "\(copilotId)\0\(turn.id)\0\(index)"
                let imageId = (UInt32(truncatingIfNeeded: Self.fnv1a64(occurrenceKey.utf8)) & 0x00FF_FFFF) | (1 << 24)
                let version = loaded.map { Self.fnv1a64("\(occurrenceKey)\0\($0.token)".utf8) | (1 << 63) }
                    ?? (Self.fnv1a64("\(occurrenceKey)\0missing".utf8) & ~(1 << 63))
                items.append(Item(
                    identity: TranscriptImageIdentity(sessionId: sessionId, imageId: imageId, version: version),
                    data: loaded?.data
                ))
            }
            if !items.isEmpty {
                result.itemsByTurnId[turn.id] = items
            }
        }
        return result
    }

    private static func isPNGFileAttachment(_ attachment: RawAttachment) -> Bool {
        guard attachment.type == "file", !attachment.hasTaggedFilesEntry,
              let rawPath = attachment.path, !rawPath.isEmpty else { return false }
        return attachment.mimeType?.lowercased() == "image/png"
            || URL(fileURLWithPath: rawPath).pathExtension.lowercased() == "png"
            || attachment.displayName.map { URL(fileURLWithPath: $0).pathExtension.lowercased() == "png" } == true
    }

    private static func readValidatedPNG(
        atPath path: String,
        maxModifiedAt: Date,
        maxBytes: Int
    ) -> (data: Data, token: String)? {
        guard !path.isEmpty, maxBytes > 0 else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        let modifiedTime: TimeInterval
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size > 0,
              st.st_size <= off_t(maxBytes) else { return nil }
        modifiedTime = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
        guard modifiedTime < maxModifiedAt.timeIntervalSince1970 + 0.001,
              let buffer = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd(),
              buffer.count == Int(st.st_size),
              RemoteKittyPNGValidation.isStructurallyValid(buffer) else { return nil }
        let token = Self.statToken(st)
        guard Self.fileStatToken(atPath: path) == token else { return nil }
        return (buffer, token)
    }

    private static func fileStatToken(atPath path: String) -> String {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return "missing" }
        return Self.statToken(st)
    }

    private static func statToken(_ st: stat) -> String {
        "\(st.st_dev):\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec):\(st.st_mtimespec.tv_nsec):\(st.st_ctimespec.tv_sec):\(st.st_ctimespec.tv_nsec)"
    }

    private static func fnv1a64<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash == 0 ? 1 : hash
    }

    private struct RawUserMessageEvent: Decodable {
        let type: String
        let id: String?
        let agentId: String?
        let data: RawEventData?
    }

    private struct RawEventData: Decodable {
        let source: String?
        let attachments: [RawAttachment]?
    }

    private struct RawAttachment: Decodable {
        let type: String?
        let path: String?
        let displayName: String?
        let mimeType: String?
        let hasTaggedFilesEntry: Bool

        private enum CodingKeys: String, CodingKey {
            case type, path, displayName, mimeType, taggedFilesEntry
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            path = try c.decodeIfPresent(String.self, forKey: .path)
            displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
            hasTaggedFilesEntry = c.contains(.taggedFilesEntry)
                && ((try? c.decode(Bool.self, forKey: .taggedFilesEntry))
                    ?? ((try? c.decodeNil(forKey: .taggedFilesEntry)) != true))
        }
    }
}

/// Pure association of currently-retained inline images to transcript turns.
///
/// An image is attached to the turn active at its retained content's origin —
/// the turn with the greatest `startedAt` that is still `<= displayedAt`.
/// Unchanged, still-advertised retransmissions preserve that origin timestamp.
/// This deliberately uses only `startedAt` (never `endedAt`), so the still-open
/// streaming turn's ever-growing `[startedAt, now]` window can't reshuffle
/// associations between requests: once a turn exists with a `startedAt` at or
/// before an image's display time, that image's turn assignment is stable.
///
/// Images displayed before the first turn began are dropped (nothing to attach
/// them to). Only currently-retained images are ever passed in, so an attached
/// ref's exact `(imageId, version)` is always fetchable — no 404 tombstones.
///
/// The snapshot's recoverable dropped turns take part on the same timeline (see
/// `TranscriptSnapshot.interleaving(dropped:into:)`) and keep their own refs, so
/// an image displayed during a turn the writer since evicted stays with that
/// turn — which remote responses still serve — rather than moving to whichever
/// live turn preceded it.
enum TranscriptImageAssociation {
    static func attach(
        images: [RemoteKittyImageCapture.RetainedImageInfo],
        to snapshot: TranscriptSnapshot
    ) -> TranscriptSnapshot {
        if images.isEmpty,
           snapshot.turns.allSatisfy({ $0.images == nil }),
           (snapshot.droppedTurns ?? []).allSatisfy({ $0.images == nil }) {
            return snapshot
        }
        let timeline = TranscriptSnapshot.interleaving(
            dropped: snapshot.recoverableDroppedTurns,
            into: snapshot.turns
        )
        let turns = timeline.map(\.turn)
        // turnIndex -> imageId -> chosen (newest) info for that turn.
        var byTurn: [Int: [UInt32: RemoteKittyImageCapture.RetainedImageInfo]] = [:]
        if !turns.isEmpty {
            for image in images {
                guard let turnIndex = Self.activeTurnIndex(turns, at: image.displayedAt)
                else { continue }
                var perImage = byTurn[turnIndex] ?? [:]
                if let existing = perImage[image.imageId] {
                    if image.version > existing.version { perImage[image.imageId] = image }
                } else {
                    perImage[image.imageId] = image
                }
                byTurn[turnIndex] = perImage
            }
        }
        // Rebuild EVERY turn from host-computed refs (or nil), never preserving
        // any `images` that were on the decoded snapshot: the CLI writer owns
        // the transcript file but must not be trusted to supply image refs, so
        // the host is the sole authority for this field.
        var liveTurns: [TranscriptTurn] = []
        var droppedTurns: [TranscriptTurn] = []
        for (index, entry) in timeline.enumerated() {
            let turn = entry.turn
            let refs: [TranscriptImageRef]? = byTurn[index].map { perImage in
                perImage.values
                    .sorted {
                        if $0.displayedAt != $1.displayedAt { return $0.displayedAt < $1.displayedAt }
                        return $0.imageId < $1.imageId
                    }
                    .map {
                        let afterMessageId = Self.precedingAssistantMessageId($0.displayedAt, in: turn)
                        return TranscriptImageRef(
                            imageId: $0.imageId,
                            contentVersion: $0.version,
                            displayedAt: Self.wireSafeDisplayedAt(
                                $0.displayedAt,
                                afterAssistantMessageId: afterMessageId,
                                in: turn
                            ),
                            afterAssistantMessageId: afterMessageId,
                            pixelWidth: $0.pixelWidth,
                            pixelHeight: $0.pixelHeight
                        )
                    }
            }
            let rebuilt = TranscriptTurn(
                id: turn.id,
                startedAt: turn.startedAt,
                endedAt: turn.endedAt,
                kind: turn.kind,
                userContent: turn.userContent,
                assistantMessages: turn.assistantMessages,
                tools: turn.tools,
                isAborted: turn.isAborted,
                images: refs,
                error: turn.error,
                reasoningSteps: turn.reasoningSteps
            )
            if entry.isDropped {
                droppedTurns.append(rebuilt)
            } else {
                liveTurns.append(rebuilt)
            }
        }
        return TranscriptSnapshot(
            schemaVersion: snapshot.schemaVersion,
            updatedAt: snapshot.updatedAt,
            copilotSessionId: snapshot.copilotSessionId,
            turns: liveTurns,
            totalTurns: snapshot.totalTurns,
            droppedTurns: droppedTurns.isEmpty ? nil : droppedTurns
        )
    }

    private static func precedingAssistantMessageId(
        _ displayedAt: Date,
        in turn: TranscriptTurn
    ) -> String? {
        turn.assistantMessages.last { message in
            !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && message.timestamp <= displayedAt
        }?.id
    }

    /// Preserves sub-second ordering (`displayedAt < message.timestamp`) across
    /// whole-second ISO-8601 wire encoding when an image precedes every
    /// non-blank assistant message in the turn (`afterAssistantMessageId == nil`),
    /// while leaving mid-turn images untouched so they never step back past a
    /// preceding message.
    private static func wireSafeDisplayedAt(
        _ displayedAt: Date,
        afterAssistantMessageId: String?,
        in turn: TranscriptTurn
    ) -> Date {
        guard afterAssistantMessageId == nil else { return displayedAt }
        let wholeSecond = displayedAt.timeIntervalSince1970.rounded(.down)
        let precedesSameSecondMessage = turn.assistantMessages.contains { message in
            displayedAt < message.timestamp
                && message.timestamp.timeIntervalSince1970.rounded(.down) == wholeSecond
        }
        guard precedesSameSecondMessage else { return displayedAt }
        return Date(timeIntervalSince1970: wholeSecond - 1)
    }

    /// Grace window after a turn's `endedAt` during which a multi-chunk Kitty
    /// PNG still flushing through the PTY at `session.idle` time (or whole-second
    /// ISO-8601 rounding) still counts as belonging to that turn.
    private static let postTurnEndGraceSeconds: TimeInterval = 2

    /// Index of the turn active at `time` — the last (chronologically latest)
    /// turn whose `startedAt <= time`, provided that turn is not a synthetic
    /// `session-resume-` marker and had not already ended before `time`.
    static func activeTurnIndex(_ turns: [TranscriptTurn], at time: Date) -> Int? {
        guard let index = turns.lastIndex(where: { $0.startedAt <= time }) else {
            return nil
        }
        let turn = turns[index]
        guard !turn.id.hasPrefix("session-resume-") else {
            return nil
        }
        if let endedAt = turn.endedAt,
           time > endedAt.addingTimeInterval(Self.postTurnEndGraceSeconds) {
            return nil
        }
        return index
    }
}
