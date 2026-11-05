import Darwin
import Foundation
import ImageIO
import CopilotProjectsCore
import CopilotProjectsProtocol

/// Prompt image attachments resolved directly from a Copilot session's
/// `events.jsonl` `user.message` attachments for the turns in a
/// `TranscriptSnapshot`. Stateless: no cross-session or cross-turn cache.
struct TranscriptPromptAttachments: Equatable, Sendable {
    private static let maxAttachmentsPerTurn = 8
    private static let maxBytesPerImage = 5 * 1_024 * 1_024
    private static let maxTotalBytes = 32 * 1_024 * 1_024
    private static let maxEventLineBytes = 64 * 1_024 * 1_024
    private static let decodePayloadsKey = CodingUserInfoKey(rawValue: "decodePayloads")!

    struct Span: Equatable, Sendable { let offset: Int; let length: Int }
    struct Ref: Equatable, Sendable { let path: String?; let assetId: String?; let inline: Span?; let index: Int }

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
    var refsByTurnId: [String: [Ref]] = [:]
    var assetSpans: [String: Span] = [:]
    var itemsByTurnId: [String: [Item]] = [:]
    var watchedFiles: [String: String] = [:]

    func items(forTurnId turnId: String, sessionId expectedSessionId: String, copilotSessionId expectedCopilotId: String) -> [Item] {
        guard !expectedSessionId.isEmpty, !expectedCopilotId.isEmpty,
              expectedSessionId == sessionId, expectedCopilotId == copilotSessionId else { return [] }
        return itemsByTurnId[turnId] ?? []
    }

    func hasWatchedFileChanges() -> Bool {
        if !scannedEventsIdentity.isEmpty {
            var st = stat()
            guard lstat(scannedEventsPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
                  "\(st.st_dev):\(st.st_ino)" == scannedEventsIdentity, Int(st.st_size) >= scannedEventsBytes else { return true }
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
           Set(prior.itemsByTurnId.keys) == wantedTurnIds.intersection(prior.refsByTurnId.keys),
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
            result.refsByTurnId = prior.refsByTurnId.filter { wantedTurnIds.contains($0.key) }
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
        let assetPrefix = Array("{\"type\":\"session.binary_asset\"".utf8)
        let assetNeedle = Array("\"session.binary_asset\"".utf8)
        let decoder = JSONDecoder()
        func scanRange(_ lower: Int, _ upper: Int, assetsOnly: Set<String>? = nil) -> Int {
            guard lower < upper, fseeko(fp, off_t(lower), SEEK_SET) == 0 else { return lower }
            clearerr(fp)
            var cursor = lower
            while cursor < upper {
                let lineStart = cursor
                let n = getline(&linePtr, &lineCap, fp)
                guard n > 0, let ptr = linePtr else { break }
                defer { if lineCap > 256 * 1_024 { free(linePtr); linePtr = nil; lineCap = 0 } }
                let lineLen = min(n, upper - cursor)
                guard lineLen > 0, ptr[lineLen - 1] == 0x0A else { break }
                cursor += lineLen
                guard lineLen >= 24, lineLen <= Self.maxEventLineBytes else { continue }
                let hasTypePrefix = memcmp(ptr, typePrefix, typePrefix.count) == 0
                let isAsset = hasTypePrefix ? (lineLen >= assetPrefix.count && memcmp(ptr, assetPrefix, assetPrefix.count) == 0) : memmem(ptr, lineLen, assetNeedle, assetNeedle.count) != nil
                let isUser = assetsOnly == nil && (hasTypePrefix ? memcmp(ptr, userPrefix, userPrefix.count) == 0 : memmem(ptr, lineLen, userNeedle, userNeedle.count) != nil)
                guard isUser || isAsset else { continue }
                autoreleasepool {
                    let lineSlice = Data(bytesNoCopy: ptr, count: lineLen - 1, deallocator: .none)
                    guard let event = try? decoder.decode(RawUserMessageEvent.self, from: lineSlice), let data = event.data else { return }
                    let span = Span(offset: lineStart, length: lineLen - 1)
                    if event.type == "session.binary_asset", let id = data.assetId, !id.isEmpty, data.hasData, assetsOnly?.contains(id) != false {
                        result.assetSpans[id] = span
                        return
                    }
                    guard assetsOnly == nil, event.type == "user.message", event.agentId == nil,
                          let turnId = event.id, wantedTurnIds.contains(turnId),
                          data.source == nil || data.source?.hasPrefix("schedule-") == true else { return }
                    result.resolvedTurnIds.insert(turnId)
                    let refs = Array((data.attachments ?? []).enumerated().compactMap { Self.attachmentRef(for: $1, span: span, index: $0) }.prefix(Self.maxAttachmentsPerTurn))
                    result.refsByTurnId[turnId] = refs.isEmpty ? nil : refs
                }
                if let assetsOnly, assetsOnly.isSubset(of: result.assetSpans.keys) { break }
            }
            return cursor
        }
        let sameEventsFile = startOffset > 0 && prior?.scannedEventsIdentity == eventsIdentity
        if sameEventsFile, let priorSpans = prior?.assetSpans {
            result.assetSpans = priorSpans
        }
        let consumedEnd = scanRange(startOffset, eventsSize)
        if startOffset > 0, let prior, !wantedTurnIds.subtracting(prior.orderedTurnIds).isSubset(of: result.resolvedTurnIds) {
            _ = scanRange(0, startOffset)
        }
        let wantedAssets = Set(result.refsByTurnId.values.flatMap { $0.compactMap(\.assetId) })
        let priorWanted = Set(prior?.refsByTurnId.values.flatMap { $0.compactMap(\.assetId) } ?? [])
        let unsearched = wantedAssets.subtracting(result.assetSpans.keys).subtracting(priorWanted)
        if startOffset > 0, !unsearched.isEmpty {
            _ = scanRange(0, startOffset, assetsOnly: unsearched)
        }
        result.assetSpans = result.assetSpans.filter { wantedAssets.contains($0.key) }
        if !wantedTurnIds.isSubset(of: result.resolvedTurnIds) || consumedEnd < eventsSize || !wantedAssets.isSubset(of: result.assetSpans.keys) {
            result.watchedFiles[eventsPath] = eventsToken
        }
        result.scannedEventsIdentity = eventsIdentity
        result.scannedEventsBytes = consumedEnd

        let payloadDecoder = JSONDecoder()
        payloadDecoder.userInfo[Self.decodePayloadsKey] = true
        var remainingBudget = Self.maxTotalBytes
        for turn in activeTurns.reversed() {
            guard let refs = result.refsByTurnId[turn.id],
                  result.itemsByTurnId[turn.id] == nil else { continue }
            var sourcesUnchanged = true
            for ref in refs {
                if let path = ref.path {
                    let token = Self.fileStatToken(atPath: path)
                    result.watchedFiles[path] = token
                    if prior?.watchedFiles[path] != token { sourcesUnchanged = false }
                }
                if let id = ref.assetId, !sameEventsFile || prior?.assetSpans[id] != result.assetSpans[id] { sourcesUnchanged = false }
                if ref.inline != nil, !sameEventsFile { sourcesUnchanged = false }
            }
            if sourcesUnchanged,
               let priorItems = prior?.itemsByTurnId[turn.id],
               prior?.refsByTurnId[turn.id] == refs,
               priorItems.count == refs.count,
               priorItems.allSatisfy({ $0.data != nil }),
               priorItems.reduce(0, { $0 + ($1.data?.count ?? 0) }) <= remainingBudget {
                remainingBudget -= priorItems.reduce(0, { $0 + ($1.data?.count ?? 0) })
                result.itemsByTurnId[turn.id] = priorItems
                continue
            }
            var items: [Item] = []
            var inlineCache: (span: Span, attachments: [RawAttachment]?)?
            for (index, ref) in refs.enumerated() {
                let cap = min(Self.maxBytesPerImage, remainingBudget)
                let loaded: (data: Data, token: String)? = autoreleasepool {
                    if let id = ref.assetId, let span = result.assetSpans[id],
                       let asset = Self.readValidatedAsset(fd: eventsFD, span: span, id: id, turnId: turn.id, index: 0, inlineCache: &inlineCache, decoder: payloadDecoder, maxBytes: cap) { return asset }
                    if let span = ref.inline,
                       let inline = Self.readValidatedAsset(fd: eventsFD, span: span, id: nil, turnId: turn.id, index: ref.index, inlineCache: &inlineCache, decoder: payloadDecoder, maxBytes: cap) { return inline }
                    guard let path = ref.path else { return nil }
                    return Self.readValidatedImage(atPath: path, maxModifiedAt: turn.startedAt, maxBytes: cap)
                }
                if let data = loaded?.data { remainingBudget -= data.count }
                let occurrenceKey = "\(copilotId)\0\(turn.id)\0\(index)"
                let imageId = (UInt32(truncatingIfNeeded: Self.fnv1a64(occurrenceKey.utf8)) & 0x00FF_FFFF) | (1 << 24)
                let version = loaded.map { Self.fnv1a64("\(occurrenceKey)\0\($0.token)".utf8) | (1 << 63) }
                    ?? (Self.fnv1a64("\(occurrenceKey)\0missing".utf8) & ~(1 << 63))
                items.append(Item(identity: TranscriptImageIdentity(sessionId: sessionId, imageId: imageId, version: version), data: loaded?.data))
            }
            if !items.isEmpty { result.itemsByTurnId[turn.id] = items }
        }
        return result
    }

    static func pixelSize(_ data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) >= 1, let type = CGImageSourceGetType(src) as String?,
              type == "public.png"
                  || (type == "public.jpeg" && data.lastIndex(where: { $0 != 0 }).map({ $0 >= 1 && data[$0 - 1] == 0xFF && data[$0] == 0xD9 }) == true),
              CGImageSourceGetStatus(src) == .statusComplete, CGImageSourceGetStatusAtIndex(src, 0) == .statusComplete,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              (1...16_384).contains(w), (1...16_384).contains(h), w <= RemoteAttachmentContract.maxPixels / h else { return nil }
        return (5...8).contains(props[kCGImagePropertyOrientation] as? Int ?? 1) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    private static func attachmentRef(for attachment: RawAttachment, span: Span, index: Int) -> Ref? {
        let assetId = (attachment.assetId?.isEmpty == false) ? attachment.assetId : nil
        guard !attachment.hasTaggedFilesEntry,
              attachment.type == "file" || attachment.type == "blob" || (attachment.type == nil && assetId != nil) else { return nil }
        let exts = [attachment.path, attachment.displayName].compactMap { ($0?.isEmpty == false) ? URL(fileURLWithPath: $0!).pathExtension.lowercased() : nil }.filter { !$0.isEmpty }
        let hasImageExt = exts.contains { ["png", "jpg", "jpeg"].contains($0) }
        if let mime = attachment.mimeType?.lowercased(), !mime.isEmpty {
            guard mime == "image/png" || mime == "image/jpeg" || (attachment.type == "file" && hasImageExt) else { return nil }
        } else if !hasImageExt && !(exts.isEmpty && (attachment.type == "blob" || assetId != nil)) { return nil }
        let inline = attachment.hasInlineData ? span : nil
        let path = (attachment.type == "file" && attachment.path?.isEmpty == false) ? attachment.path : nil
        guard path != nil || assetId != nil || inline != nil || attachment.type == "blob" else { return nil }
        return Ref(path: path, assetId: assetId, inline: inline, index: index)
    }

    private static func readValidatedAsset(
        fd: Int32, span: Span, id: String?, turnId: String, index: Int, inlineCache: inout (span: Span, attachments: [RawAttachment]?)?, decoder: JSONDecoder, maxBytes: Int
    ) -> (data: Data, token: String)? {
        guard maxBytes > 0 else { return nil }
        func decodeLine() -> RawUserMessageEvent? {
            var line = Data(count: span.length)
            guard line.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, span.length, off_t(span.offset)) }) == span.length else { return nil }
            return try? decoder.decode(RawUserMessageEvent.self, from: line)
        }
        let base64: String?
        if let id {
            guard let ev = decodeLine(), let d = ev.data, ev.type == "session.binary_asset", d.assetId == id,
                  d.type == nil || d.type == "image", ["image/png", "image/jpeg", nil].contains(d.mimeType?.lowercased()) else { return nil }
            base64 = d.data
        } else {
            if inlineCache?.span != span {
                guard let ev = decodeLine(), ev.type == "user.message", ev.id == turnId else { return nil }
                inlineCache = (span, ev.data?.attachments)
            }
            base64 = (inlineCache?.attachments?.indices.contains(index) == true) ? inlineCache?.attachments?[index].data : nil
        }
        guard let base64, !base64.isEmpty, base64.utf8.count <= ((maxBytes + 2) / 3) * 4,
              let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              !data.isEmpty, data.count <= maxBytes, Self.pixelSize(data) != nil else { return nil }
        return (data, "\(id ?? "inline"):\(span.offset):\(span.length):\(index):\(Self.fnv1a64(data))")
    }

    private static func readValidatedImage(
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
              Self.pixelSize(buffer) != nil else { return nil }
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
        let assetId: String?
        let type: String?
        let mimeType: String?
        let data: String?
        let hasData: Bool

        private enum CodingKeys: String, CodingKey { case source, attachments, assetId, type, mimeType, data }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try c.decodeIfPresent(String.self, forKey: .source)
            attachments = try c.decodeIfPresent([RawAttachment].self, forKey: .attachments)
            assetId = try c.decodeIfPresent(String.self, forKey: .assetId)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
            data = (decoder.userInfo[TranscriptPromptAttachments.decodePayloadsKey] as? Bool == true) ? try c.decodeIfPresent(String.self, forKey: .data) : nil
            hasData = c.contains(.data) && ((try? c.decodeNil(forKey: .data)) != true)
        }
    }

    private struct RawAttachment: Decodable {
        let type: String?
        let path: String?
        let displayName: String?
        let mimeType: String?
        let assetId: String?
        let data: String?
        let hasInlineData: Bool
        let hasTaggedFilesEntry: Bool

        private enum CodingKeys: String, CodingKey {
            case type, path, displayName, mimeType, assetId, data, taggedFilesEntry
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            path = try c.decodeIfPresent(String.self, forKey: .path)
            displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
            assetId = try c.decodeIfPresent(String.self, forKey: .assetId)
            let decodePayloads = (decoder.userInfo[TranscriptPromptAttachments.decodePayloadsKey] as? Bool) == true
            data = decodePayloads ? try c.decodeIfPresent(String.self, forKey: .data) : nil
            hasInlineData = c.contains(.data) && ((try? c.decodeNil(forKey: .data)) != true)
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
