import Darwin
import Foundation
import ImageIO
import CopilotProjectsCore
import CopilotProjectsProtocol

/// Prompt image attachments and the images tools returned, resolved directly from a
/// Copilot session's `events.jsonl` (`user.message` attachments and
/// `tool.execution_complete` results) for the turns in a `TranscriptSnapshot`.
/// Stateless: no cross-session or cross-turn cache.
struct TranscriptPromptAttachments: Equatable, Sendable {
    private static let maxAttachmentsPerTurn = 8
    private static let maxBytesPerImage = 5 * 1_024 * 1_024
    private static let maxTotalBytes = 32 * 1_024 * 1_024
    private static let maxEventLineBytes = 64 * 1_024 * 1_024
    private static let decodePayloadsKey = CodingUserInfoKey(rawValue: "decodePayloads")!

    struct Span: Hashable, Sendable {
        let offset: Int
        let length: Int
    }

    struct Ref: Equatable, Sendable {
        let path: String?
        let assetId: String?
        let inline: Span?
        let index: Int
        /// Set on an image a tool returned: the `toolCallId` of the tool row it belongs under.
        var toolCallId: String? = nil
    }

    struct Item: Equatable, Identifiable, Sendable {
        let identity: TranscriptImageIdentity
        let data: Data?
        var contentHash: UInt64? = nil
        var pixelSize: CGSize? = nil
        var grayscaleGrid: [UInt8]? = nil
        var toolCallId: String? = nil
        var id: TranscriptImageIdentity { identity }
    }

    var sessionId: String = ""
    var copilotSessionId: String = ""
    var orderedTurnIds: [String] = []
    /// Ids of the tool rows the snapshot shows as finished. When they change, `events.jsonl` has
    /// completions that were not read or joined yet, so the previous result cannot be reused.
    var completedToolIds: [String] = []
    var scannedEventsPath: String = ""
    var scannedEventsIdentity: String = ""
    var scannedEventsBytes: Int = 0
    var resolvedTurnIds: Set<String> = []
    var refsByTurnId: [String: [Ref]] = [:]
    var assetSpans: [String: Span] = [:]
    var payloadBytesBySpan: [Span: Int] = [:]
    var itemsByTurnId: [String: [Item]] = [:]
    /// Image results of root tool calls by `toolCallId`, recorded as the scan meets them and
    /// joined to the snapshot's tool rows afterwards. The tracker builds the snapshot from
    /// `events.jsonl`, so a completion can be read here before the snapshot shows its tool.
    var toolRefsByCallId: [String: [Ref]] = [:]
    var toolItemsByTurnId: [String: [Item]] = [:]
    var watchedFiles: [String: String] = [:]

    /// The turn's prompt images, or with `fromTools` the images its tools returned.
    func items(
        forTurnId turnId: String,
        sessionId expectedSessionId: String,
        copilotSessionId expectedCopilotId: String,
        fromTools: Bool = false
    ) -> [Item] {
        guard !expectedSessionId.isEmpty,
              !expectedCopilotId.isEmpty,
              expectedSessionId == sessionId,
              expectedCopilotId == copilotSessionId else {
            return []
        }
        return (fromTools ? toolItemsByTurnId : itemsByTurnId)[turnId] ?? []
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
        // Turns of every kind have tool rows, automated turns included.
        let toolTurns = snapshot.turns.filter { !$0.tools.isEmpty }
        var result = TranscriptPromptAttachments(
            sessionId: sessionId,
            copilotSessionId: copilotId,
            orderedTurnIds: orderedTurnIds,
            completedToolIds: toolTurns.flatMap { $0.tools.filter { $0.success != nil }.map(\.id) }
        )
        guard !sessionId.isEmpty, !copilotId.isEmpty, !wantedTurnIds.isEmpty || !toolTurns.isEmpty else {
            return result
        }
        let prior = (previous?.sessionId == sessionId && previous?.copilotSessionId == copilotId) ? previous : nil
        if let prior,
           prior.orderedTurnIds == orderedTurnIds,
           prior.completedToolIds == result.completedToolIds,
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
            result.toolRefsByCallId = prior.toolRefsByCallId
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
        let toolPrefix = Array("{\"type\":\"tool.execution_complete\"".utf8)
        let toolNeedle = Array("\"binaryResultsForLlm\"".utf8)
        let decoder = JSONDecoder()
        func scanRange(_ lower: Int, _ upper: Int, assetsOnly: Set<String>? = nil) -> Int {
            guard lower < upper, fseeko(fp, off_t(lower), SEEK_SET) == 0 else { return lower }
            clearerr(fp)
            var cursor = lower
            while cursor < upper {
                let lineStart = cursor
                let n = getline(&linePtr, &lineCap, fp)
                guard n > 0, let ptr = linePtr else { break }
                defer {
                    if lineCap > 256 * 1_024 {
                        free(linePtr)
                        linePtr = nil
                        lineCap = 0
                    }
                }
                let lineLen = min(n, upper - cursor)
                guard lineLen > 0, ptr[lineLen - 1] == 0x0A else { break }
                cursor += lineLen
                guard lineLen >= 24, lineLen <= Self.maxEventLineBytes else { continue }
                let hasTypePrefix = memcmp(ptr, typePrefix, typePrefix.count) == 0
                let isAsset = hasTypePrefix
                    ? (lineLen >= assetPrefix.count && memcmp(ptr, assetPrefix, assetPrefix.count) == 0)
                    : memmem(ptr, lineLen, assetNeedle, assetNeedle.count) != nil
                let isUser = assetsOnly == nil && (hasTypePrefix
                    ? memcmp(ptr, userPrefix, userPrefix.count) == 0
                    : memmem(ptr, lineLen, userNeedle, userNeedle.count) != nil)
                // 0.12% of completions carry a binary result, so only those are decoded.
                let isTool = assetsOnly == nil
                    && lineLen >= toolPrefix.count
                    && memcmp(ptr, toolPrefix, toolPrefix.count) == 0
                    && memmem(ptr, lineLen, toolNeedle, toolNeedle.count) != nil
                guard isUser || isAsset || isTool else { continue }
                autoreleasepool {
                    let lineSlice = Data(bytesNoCopy: ptr, count: lineLen - 1, deallocator: .none)
                    guard let event = try? decoder.decode(RawUserMessageEvent.self, from: lineSlice),
                          let data = event.data else { return }
                    let span = Span(offset: lineStart, length: lineLen - 1)
                    if event.type == "session.binary_asset",
                       let id = data.assetId,
                       !id.isEmpty,
                       data.hasData,
                       assetsOnly?.contains(id) != false {
                        result.assetSpans[id] = span
                        return
                    }
                    // Root calls only: the transcript has no row for a sub-agent's tool. Recorded
                    // whether or not the snapshot shows the tool yet (see `toolRefsByCallId`).
                    if isTool, event.agentId == nil, let callId = data.toolCallId {
                        let refs = (data.binaryResults ?? []).enumerated().compactMap { index, binary -> Ref? in
                            guard binary.type == "image", let assetId = binary.assetId else { return nil }
                            return Ref(path: nil, assetId: assetId, inline: nil, index: index, toolCallId: callId)
                        }
                        result.toolRefsByCallId[callId] = refs.isEmpty ? nil : refs
                        return
                    }
                    guard assetsOnly == nil,
                          event.type == "user.message",
                          event.agentId == nil,
                          let turnId = event.id,
                          wantedTurnIds.contains(turnId),
                          data.source == nil || data.source?.hasPrefix("schedule-") == true else { return }
                    result.resolvedTurnIds.insert(turnId)
                    let refs = Array(
                        (data.attachments ?? [])
                            .enumerated()
                            .compactMap { Self.attachmentRef(for: $1, span: span, index: $0) }
                            .prefix(Self.maxAttachmentsPerTurn)
                    )
                    result.refsByTurnId[turnId] = refs.isEmpty ? nil : refs
                }
                if let assetsOnly, assetsOnly.isSubset(of: result.assetSpans.keys) { break }
            }
            return cursor
        }
        let sameEventsFile = startOffset > 0 && prior?.scannedEventsIdentity == eventsIdentity
        if sameEventsFile, let prior {
            result.assetSpans = prior.assetSpans
            result.payloadBytesBySpan = prior.payloadBytesBySpan
        }
        let consumedEnd = scanRange(startOffset, eventsSize)
        if startOffset > 0,
           let prior,
           !wantedTurnIds.subtracting(prior.orderedTurnIds).isSubset(of: result.resolvedTurnIds) {
            _ = scanRange(0, startOffset)
        }
        let promptAssets = Set(result.refsByTurnId.values.flatMap { $0.compactMap(\.assetId) })
        let wantedAssets = promptAssets.union(result.toolRefsByCallId.values.flatMap { $0.compactMap(\.assetId) })
        // An asset the previous load already looked for is not looked for again: 53 real tool
        // results name an asset that is not in the file, and each load would re-read from byte 0.
        let priorWanted = Set(prior?.refsByTurnId.values.flatMap { $0.compactMap(\.assetId) } ?? [])
            .union(prior?.toolRefsByCallId.values.flatMap { $0.compactMap(\.assetId) } ?? [])
        let unsearched = wantedAssets.subtracting(result.assetSpans.keys).subtracting(priorWanted)
        if startOffset > 0, !unsearched.isEmpty {
            _ = scanRange(0, startOffset, assetsOnly: unsearched)
        }
        result.assetSpans = result.assetSpans.filter { wantedAssets.contains($0.key) }
        // Only a prompt's asset can still arrive: a tool's asset is written before its completion.
        if !wantedTurnIds.isSubset(of: result.resolvedTurnIds)
            || consumedEnd < eventsSize
            || !promptAssets.isSubset(of: result.assetSpans.keys) {
            result.watchedFiles[eventsPath] = eventsToken
        }
        result.scannedEventsIdentity = eventsIdentity
        result.scannedEventsBytes = consumedEnd

        let payloadDecoder = JSONDecoder()
        payloadDecoder.userInfo[Self.decodePayloadsKey] = true
        var remainingBudget = Self.maxTotalBytes
        // Prompt turns first, then tool turns, each newest first, so tool images only take the
        // budget prompt images leave. 12 real sessions hold over 8 MB of tool images; sharing the
        // budget in turn order would let those screenshots push older prompt images out.
        let passes = activeTurns.reversed().map { (turn: $0, fromTools: false) }
            + toolTurns.reversed().map { (turn: $0, fromTools: true) }
        for (turn, fromTools) in passes {
            let store: WritableKeyPath<TranscriptPromptAttachments, [String: [Item]]> =
                fromTools ? \.toolItemsByTurnId : \.itemsByTurnId
            func turnRefs(in attachments: TranscriptPromptAttachments?) -> [Ref] {
                fromTools
                    ? turn.tools.flatMap { attachments?.toolRefsByCallId[$0.id] ?? [] }
                    : attachments?.refsByTurnId[turn.id] ?? []
            }
            let refs = turnRefs(in: result)
            guard !refs.isEmpty, result[keyPath: store][turn.id] == nil else { continue }
            var sourcesUnchanged = true
            for ref in refs {
                if let path = ref.path {
                    let token = Self.fileStatToken(atPath: path)
                    result.watchedFiles[path] = token
                    if prior?.watchedFiles[path] != token { sourcesUnchanged = false }
                }
                if let id = ref.assetId,
                   !sameEventsFile || prior?.assetSpans[id] != result.assetSpans[id] {
                    sourcesUnchanged = false
                }
                if ref.inline != nil, !sameEventsFile {
                    sourcesUnchanged = false
                }
            }
            if sourcesUnchanged,
               let priorItems = prior?[keyPath: store][turn.id],
               turnRefs(in: prior) == refs,
               priorItems.count == refs.count,
               priorItems.allSatisfy({ $0.data != nil }),
               priorItems.reduce(0, { $0 + ($1.data?.count ?? 0) }) <= remainingBudget {
                remainingBudget -= priorItems.reduce(0, { $0 + ($1.data?.count ?? 0) })
                result[keyPath: store][turn.id] = priorItems
                continue
            }
            var items: [Item] = []
            var inlineCache: (span: Span, attachments: [RawAttachment]?)?
            for (index, ref) in refs.enumerated() {
                let cap = min(Self.maxBytesPerImage, remainingBudget)
                let loaded: (data: Data, token: String, hash: UInt64, size: CGSize)? = autoreleasepool {
                    if let id = ref.assetId,
                       let span = result.assetSpans[id],
                       let asset = Self.readValidatedAsset(
                           fd: eventsFD,
                           span: span,
                           id: id,
                           turnId: turn.id,
                           index: 0,
                           inlineCache: &inlineCache,
                           payloadBytesBySpan: &result.payloadBytesBySpan,
                           decoder: payloadDecoder,
                           maxBytes: cap
                       ) {
                        return asset
                    }
                    if let span = ref.inline,
                       let inline = Self.readValidatedAsset(
                           fd: eventsFD,
                           span: span,
                           id: nil,
                           turnId: turn.id,
                           index: ref.index,
                           inlineCache: &inlineCache,
                           payloadBytesBySpan: &result.payloadBytesBySpan,
                           decoder: payloadDecoder,
                           maxBytes: cap
                       ) {
                        return inline
                    }
                    guard let path = ref.path else { return nil }
                    return Self.readValidatedImage(
                        atPath: path,
                        maxModifiedAt: turn.startedAt,
                        maxBytes: cap
                    )
                }
                if let data = loaded?.data {
                    remainingBudget -= data.count
                }
                // A tool image is one result of one tool call; ids starting at 2 << 24 keep it
                // apart from prompt images (1 << 24) and Kitty captures (up to 0xFFFFFF).
                let occurrence = ref.toolCallId.map { "\($0)\0\(ref.index)" } ?? "\(index)"
                let occurrenceKey = "\(copilotId)\0\(turn.id)\0\(occurrence)"
                let imageId = (UInt32(truncatingIfNeeded: Self.fnv1a64(occurrenceKey.utf8)) & 0x00FF_FFFF)
                    | (fromTools ? 2 << 24 : 1 << 24)
                let version = loaded.map { Self.fnv1a64("\(occurrenceKey)\0\($0.token)".utf8) | (1 << 63) }
                    ?? (Self.fnv1a64("\(occurrenceKey)\0missing".utf8) & ~(1 << 63))
                // The grid is only read when a prompt image is matched against its terminal copy.
                let isTranscoded = !fromTools
                    && loaded.map { $0.data.starts(with: [0xFF, 0xD8]) || max($0.size.width, $0.size.height) > 896 } == true
                items.append(Item(
                    identity: TranscriptImageIdentity(sessionId: sessionId, imageId: imageId, version: version),
                    data: loaded?.data, contentHash: loaded?.hash, pixelSize: loaded?.size,
                    grayscaleGrid: isTranscoded ? loaded.flatMap { Self.grayscaleGrid($0.data) } : nil,
                    toolCallId: ref.toolCallId
                ))
            }
            if !items.isEmpty {
                result[keyPath: store][turn.id] = items
            }
        }
        return result
    }

    static func pixelSize(_ data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(src) >= 1,
              let type = CGImageSourceGetType(src) as String?,
              type == "public.png" || (type == "public.jpeg" && Self.hasJPEGEndMarker(data)),
              CGImageSourceGetStatus(src) == .statusComplete,
              CGImageSourceGetStatusAtIndex(src, 0) == .statusComplete,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              (1...16_384).contains(width),
              (1...16_384).contains(height),
              width <= RemoteAttachmentContract.maxPixels / height
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    private static func hasJPEGEndMarker(_ data: Data) -> Bool {
        guard let end = data.lastIndex(where: { $0 != 0 }), end >= 1 else { return false }
        return data[end - 1] == 0xFF && data[end] == 0xD9
    }

    private static func attachmentRef(
        for attachment: RawAttachment,
        span: Span,
        index: Int
    ) -> Ref? {
        let assetId = (attachment.assetId?.isEmpty == false) ? attachment.assetId : nil
        guard !attachment.hasTaggedFilesEntry,
              attachment.type == "file"
                  || attachment.type == "blob"
                  || (attachment.type == nil && assetId != nil)
        else { return nil }
        let exts = [attachment.path, attachment.displayName].compactMap { raw -> String? in
            guard let raw, !raw.isEmpty else { return nil }
            let ext = URL(fileURLWithPath: raw).pathExtension.lowercased()
            return ext.isEmpty ? nil : ext
        }
        let hasImageExt = exts.contains { $0 == "png" || $0 == "jpg" || $0 == "jpeg" }
        if let mime = attachment.mimeType?.lowercased(), !mime.isEmpty {
            guard mime == "image/png"
                    || mime == "image/jpeg"
                    || (attachment.type == "file" && hasImageExt)
            else { return nil }
        } else if !hasImageExt && !(exts.isEmpty && (attachment.type == "blob" || assetId != nil)) {
            return nil
        }
        let inline = attachment.hasInlineData ? span : nil
        let path = (attachment.type == "file" && attachment.path?.isEmpty == false)
            ? attachment.path
            : nil
        guard path != nil || assetId != nil || inline != nil || attachment.type == "blob" else {
            return nil
        }
        return Ref(path: path, assetId: assetId, inline: inline, index: index)
    }

    private static func readValidatedAsset(
        fd: Int32,
        span: Span,
        id: String?,
        turnId: String,
        index: Int,
        inlineCache: inout (span: Span, attachments: [RawAttachment]?)?,
        payloadBytesBySpan: inout [Span: Int],
        decoder: JSONDecoder,
        maxBytes: Int
    ) -> (data: Data, token: String, hash: UInt64, size: CGSize)? {
        let spanKey = id == nil ? Span(offset: span.offset, length: -1 - index) : span
        guard maxBytes > 0, (payloadBytesBySpan[spanKey] ?? 0) <= maxBytes else { return nil }
        func decodeLine() -> RawUserMessageEvent? {
            var line = Data(count: span.length)
            let readCount = line.withUnsafeMutableBytes {
                pread(fd, $0.baseAddress, span.length, off_t(span.offset))
            }
            guard readCount == span.length else { return nil }
            return try? decoder.decode(RawUserMessageEvent.self, from: line)
        }
        let base64: String?
        if let id {
            guard let ev = decodeLine(),
                  let d = ev.data,
                  ev.type == "session.binary_asset",
                  d.assetId == id,
                  d.type == nil || d.type == "image",
                  ["image/png", "image/jpeg", nil].contains(d.mimeType?.lowercased())
            else { return nil }
            base64 = d.data
        } else {
            if inlineCache?.span != span {
                guard let ev = decodeLine(),
                      ev.type == "user.message",
                      ev.id == turnId
                else { return nil }
                inlineCache = (span, ev.data?.attachments)
            }
            base64 = (inlineCache?.attachments?.indices.contains(index) == true)
                ? inlineCache?.attachments?[index].data
                : nil
        }
        guard let base64, !base64.isEmpty else { return nil }
        let minDecodedBytes = max(1, (base64.utf8.count / 4) * 3 - 2)
        payloadBytesBySpan[spanKey] = minDecodedBytes
        guard base64.utf8.count <= ((maxBytes + 2) / 3) * 4,
              let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              !data.isEmpty
        else { return nil }
        payloadBytesBySpan[spanKey] = data.count
        guard data.count <= maxBytes, let size = Self.pixelSize(data) else { return nil }
        let hash = Self.fnv1a64(data)
        let token = "\(id ?? "inline"):\(span.offset):\(span.length):\(index):\(hash)"
        return (data, token, hash, size)
    }

    private static func readValidatedImage(
        atPath path: String,
        maxModifiedAt: Date,
        maxBytes: Int
    ) -> (data: Data, token: String, hash: UInt64, size: CGSize)? {
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
              let size = Self.pixelSize(buffer) else { return nil }
        let token = Self.statToken(st)
        guard Self.fileStatToken(atPath: path) == token else { return nil }
        return (buffer, token, Self.fnv1a64(buffer), size)
    }

    static func grayscaleGrid(_ data: Data) -> [UInt8]? {
        let side = 64
        var buf = [UInt8](repeating: 0, count: side * side)
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 896,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary),
              let ctx = CGContext(
                  data: &buf, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        return buf
    }

    private static func fileStatToken(atPath path: String) -> String {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return "missing" }
        return Self.statToken(st)
    }

    private static func statToken(_ st: stat) -> String {
        "\(st.st_dev):\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec):\(st.st_mtimespec.tv_nsec):\(st.st_ctimespec.tv_sec):\(st.st_ctimespec.tv_nsec)"
    }

    static func fnv1a64(_ data: Data) -> UInt64 {
        data.withUnsafeBytes(fnv1a64)
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
        let toolCallId: String?
        let binaryResults: [RawAttachment]?

        private enum CodingKeys: String, CodingKey {
            case source, attachments, assetId, type, mimeType, data, toolCallId, result
        }

        private enum ResultKeys: String, CodingKey {
            case binaryResultsForLlm
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try c.decodeIfPresent(String.self, forKey: .source)
            attachments = try c.decodeIfPresent([RawAttachment].self, forKey: .attachments)
            assetId = try c.decodeIfPresent(String.self, forKey: .assetId)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
            let decodePayloads = (decoder.userInfo[TranscriptPromptAttachments.decodePayloadsKey] as? Bool) == true
            data = decodePayloads ? try c.decodeIfPresent(String.self, forKey: .data) : nil
            hasData = c.contains(.data) && ((try? c.decodeNil(forKey: .data)) != true)
            toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
            let result = try? c.nestedContainer(keyedBy: ResultKeys.self, forKey: .result)
            binaryResults = try result?.decodeIfPresent([RawAttachment].self, forKey: .binaryResultsForLlm)
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

    @MainActor private static var capturedImageHashes: [TranscriptImageIdentity: (hash: UInt64, grid: [UInt8]?)] = [:]

    @MainActor static func timelineItems(
        for turn: TranscriptTurn,
        imageCapture: RemoteKittyImageCapture?,
        promptAttachments: [TranscriptPromptAttachments.Item]
    ) -> [TranscriptTurnTimelineItem] {
        let items = turn.timelineItems(includingBlankAssistantMessages: true)
        var remaining = promptAttachments.filter { $0.data != nil }
        guard let imageCapture, !remaining.isEmpty else { return items }
        return items.filter { item in
            guard case .image(let img) = item, img.afterAssistantMessageId == nil,
                  let data = imageCapture.imageData(imageId: img.imageId, version: img.contentVersion)
            else { return true }
            let id = TranscriptImageIdentity(
                sessionId: imageCapture.sessionId, imageId: img.imageId, version: img.contentVersion
            )
            var sig = capturedImageHashes[id] ?? {
                capturedImageHashes = capturedImageHashes.filter { $0.key.sessionId != id.sessionId || $0.key.imageId != id.imageId }
                if capturedImageHashes.count >= 64 { capturedImageHashes.removeAll(keepingCapacity: true) }
                let entry = (hash: TranscriptPromptAttachments.fnv1a64(data), grid: nil as [UInt8]?)
                capturedImageHashes[id] = entry
                return entry
            }()
            if let i = remaining.firstIndex(where: { ($0.contentHash ?? $0.data.map(TranscriptPromptAttachments.fnv1a64)) == sig.hash }) {
                remaining.remove(at: i)
                return false
            }
            guard let kw = img.pixelWidth, let kh = img.pixelHeight, kw > 0, kh > 0,
                  let i = remaining.firstIndex(where: { att in
                      guard let d = att.data, let sz = att.pixelSize ?? TranscriptPromptAttachments.pixelSize(d) else { return false }
                      let pw = Int(sz.width), ph = Int(sz.height)
                      let sized = (d.starts(with: [0xFF, 0xD8]) && pw <= 896 && ph <= 896 && kw == pw && kh == ph)
                          || ((pw > 896 || ph > 896) && (894...896).contains(max(kw, kh)) && kw <= pw && kh <= ph
                              && abs(pw * kh - ph * kw) <= max(pw, ph))
                      guard sized, let ag = att.grayscaleGrid ?? TranscriptPromptAttachments.grayscaleGrid(d) else { return false }
                      if sig.grid == nil {
                          sig.grid = TranscriptPromptAttachments.grayscaleGrid(data)
                          capturedImageHashes[id] = sig
                      }
                      guard let cg = sig.grid, cg.count == ag.count else { return false }
                      let diffs = zip(ag, cg).map { abs(Int($0) - Int($1)) }
                      return diffs.reduce(0, +) <= ag.count * 3 / 2 && (diffs.max() ?? 0) <= 16
                  })
            else { return true }
            remaining.remove(at: i)
            return false
        }
    }
}
