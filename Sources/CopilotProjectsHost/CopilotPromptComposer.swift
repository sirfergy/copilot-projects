import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers
import CopilotProjectsCore
import CopilotProjectsProtocol

enum DesktopScreenshotAttachmentImage {
    struct NormalizedAttachment: Sendable, Equatable {
        let data: Data
        let mimeType: String
        let displayName: String
        let previewPNGData: Data

        init(
            data: Data,
            mimeType: String,
            displayName: String? = nil,
            previewPNGData: Data = Data()
        ) {
            self.data = data
            self.mimeType = mimeType
            self.displayName = displayName
                .flatMap { RemoteAttachmentContract.sanitizeDisplayName($0, fallbackMimeType: mimeType) }
                ?? RemoteAttachmentContract.defaultDisplayName(forMimeType: mimeType)
            self.previewPNGData = previewPNGData
        }
    }

    enum PasteboardSource {
        case fileURLs([URL])
        case imagePayloads([Data])
    }

    enum AttachmentError: LocalizedError, Equatable {
        case invalid
        case unsupportedModelForImage
        case tooLarge
        case emptyPasteboard
        case tooManyImages(Int)
        case tooManyAttachments(Int)

        var errorDescription: String? {
            switch self {
            case .invalid:
                "Choose a valid screenshot (up to 16 megapixels and 20 MB) or UTF-8 text file (up to 512 KB)."
            case .unsupportedModelForImage:
                "The selected model does not support image attachments. Switch to a vision-capable model or attach text files."
            case .tooLarge:
                "This attachment cannot fit the upload size limit."
            case .emptyPasteboard:
                "Clipboard does not contain a supported file or image."
            case .tooManyImages(let limit):
                "This model allows up to \(limit) screenshot(s) per message."
            case .tooManyAttachments(let limit):
                "This session allows up to \(limit) attachment(s) per message."
            }
        }
    }

    static let maxSourceBytes = 20 * 1_024 * 1_024

    static func normalized(
        _ data: Data,
        limits: RemoteImageCapabilities,
        displayName: String? = nil
    ) throws -> NormalizedAttachment {
        guard limits.isValid,
              !data.isEmpty,
              data.count <= maxSourceBytes,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(source) >= 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              width <= 16_384, height <= 16_384,
              width <= RemoteAttachmentContract.maxPixels / height,
              let previewCGImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: TranscriptImageDecoder.previewDimension,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary),
              let previewPNGData = NSBitmapImageRep(cgImage: previewCGImage)
                  .representation(using: .png, properties: [:]) else {
            throw AttachmentError.invalid
        }

        if let sourceType = CGImageSourceGetType(source) as String?,
           let directMime = sourceType == "public.png" ? "image/png"
               : (sourceType == "public.jpeg" ? "image/jpeg" : nil),
           limits.mimeTypes.contains(directMime),
           data.count <= limits.maxBytes {
            return NormalizedAttachment(
                data: data,
                mimeType: directMime,
                displayName: displayName,
                previewPNGData: previewPNGData
            )
        }

        guard let normalizedCGImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4_096,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else {
            throw AttachmentError.invalid
        }
        let bitmap = NSBitmapImageRep(cgImage: normalizedCGImage)
        if limits.mimeTypes.contains("image/png"),
           let png = bitmap.representation(using: .png, properties: [:]),
           png.count <= limits.maxBytes {
            return NormalizedAttachment(
                data: png,
                mimeType: "image/png",
                displayName: displayName,
                previewPNGData: previewPNGData
            )
        }
        if limits.mimeTypes.contains("image/jpeg") {
            for factor in [0.9, 0.75, 0.6] {
                if let jpeg = bitmap.representation(
                    using: .jpeg,
                    properties: [.compressionFactor: factor]
                ), jpeg.count <= limits.maxBytes {
                    return NormalizedAttachment(
                        data: jpeg,
                        mimeType: "image/jpeg",
                        displayName: displayName,
                        previewPNGData: previewPNGData
                    )
                }
            }
        }
        throw AttachmentError.tooLarge
    }

    static func normalizedFile(
        _ url: URL,
        imageLimits: RemoteImageCapabilities?,
        allowTextFiles: Bool = true
    ) throws -> NormalizedAttachment {
        if let textMime = canonicalTextMimeType(for: url) {
            guard allowTextFiles else {
                throw AttachmentError.invalid
            }
            let rawData = try readTextFileData(url)
            guard let validatedData = RemoteAttachmentContract.validateTextData(rawData) else {
                throw RemoteAttachmentError.unsupportedText
            }
            return NormalizedAttachment(
                data: validatedData,
                mimeType: textMime,
                displayName: url.lastPathComponent,
                previewPNGData: Data()
            )
        }
        if isSupportedImageFileURL(url) {
            guard let imageLimits, imageLimits.isValid else {
                throw AttachmentError.unsupportedModelForImage
            }
            let rawData = try readImageFileData(url)
            return try normalized(rawData, limits: imageLimits, displayName: url.lastPathComponent)
        }
        throw RemoteAttachmentError.unsupportedText
    }

    static func allowedPickerContentTypes(allowImages: Bool, allowTextFiles: Bool) -> [UTType] {
        var types: [UTType] = []
        if allowImages {
            types.append(contentsOf: [.png, .jpeg, .image])
        }
        if allowTextFiles {
            for fallbackType in pickerTextContentTypes {
                if !types.contains(fallbackType) {
                    types.append(fallbackType)
                }
            }
            let extraExtensions = RemoteAttachmentContract.extensionToTextMimeType.keys.sorted()
            for ext in extraExtensions {
                if let utType = UTType(filenameExtension: ext), !types.contains(utType) {
                    types.append(utType)
                }
            }
        }
        return types
    }

    private static let pickerTextContentTypes: [UTType] = [
        .json, .plainText, .sourceCode, .script, .xml, .yaml, .commaSeparatedText, .tabSeparatedText, .html,
    ]

    static func hasPasteboardImage(
        _ pasteboard: NSPasteboard = .general,
        allowImages: Bool = true,
        allowTextFiles: Bool = true
    ) -> Bool {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], urls.contains(where: {
            isSupportedAttachmentFileURL($0, allowImages: allowImages, allowTextFiles: allowTextFiles)
        }) {
            return true
        }
        guard allowImages else { return false }
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            NSPasteboard.PasteboardType("public.jpeg"),
            .tiff,
        ]
        return (pasteboard.pasteboardItems ?? []).contains { item in
            imageTypes.contains { item.types.contains($0) }
        }
    }

    static func pasteboardSources(
        from pasteboard: NSPasteboard = .general,
        remainingCapacity: Int,
        maxImages: Int,
        allowImages: Bool = true,
        allowTextFiles: Bool = true
    ) throws -> PasteboardSource {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            if !allowImages && urls.contains(where: isSupportedImageFileURL) {
                throw AttachmentError.unsupportedModelForImage
            }
            if !allowTextFiles && urls.contains(where: isSupportedTextFileURL) {
                throw AttachmentError.invalid
            }
            let matchingURLs = urls.filter {
                isSupportedAttachmentFileURL($0, allowImages: allowImages, allowTextFiles: allowTextFiles)
            }
            if !matchingURLs.isEmpty {
                guard matchingURLs.count <= remainingCapacity else {
                    throw allowTextFiles
                        ? AttachmentError.tooManyAttachments(maxImages)
                        : AttachmentError.tooManyImages(maxImages)
                }
                return .fileURLs(matchingURLs)
            }
        }
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            NSPasteboard.PasteboardType("public.jpeg"),
            .tiff,
        ]
        let items = (pasteboard.pasteboardItems ?? []).filter { item in
            imageTypes.contains { item.types.contains($0) }
        }
        if !items.isEmpty && !allowImages {
            throw AttachmentError.unsupportedModelForImage
        }
        guard allowImages, !items.isEmpty else {
            throw AttachmentError.emptyPasteboard
        }
        guard items.count <= remainingCapacity else {
            throw AttachmentError.tooManyImages(maxImages)
        }
        var payloads: [Data] = []
        for item in items {
            guard let matchedType = imageTypes.first(where: { item.types.contains($0) }),
                  let data = item.data(forType: matchedType),
                  !data.isEmpty,
                  data.count <= maxSourceBytes else {
                throw AttachmentError.invalid
            }
            payloads.append(data)
        }
        return .imagePayloads(payloads)
    }

    static func readImageFileData(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentTypeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.isDirectory != true,
              values.isPackage != true,
              let size = values.fileSize,
              size > 0, size <= maxSourceBytes else {
            throw AttachmentError.invalid
        }
        if let contentType = values.contentType, !contentType.conforms(to: .image) {
            throw AttachmentError.invalid
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.count <= maxSourceBytes else {
            throw AttachmentError.invalid
        }
        return data
    }

    static func readTextFileData(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .isPackageKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.isDirectory != true,
              values.isPackage != true,
              let size = values.fileSize,
              size > 0 else {
            throw RemoteAttachmentError.unsupportedText
        }
        guard size <= RemoteAttachmentContract.maxTextBytes else {
            throw RemoteAttachmentError.tooLarge
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw RemoteAttachmentError.unsupportedText
        }
        guard data.count <= RemoteAttachmentContract.maxTextBytes else {
            throw RemoteAttachmentError.tooLarge
        }
        return data
    }

    static func canonicalTextMimeType(for url: URL) -> String? {
        if !url.pathExtension.isEmpty,
           let mapped = RemoteAttachmentContract.canonicalTextMimeType(forExtension: url.pathExtension) {
            return mapped
        }
        guard let utType = (!url.pathExtension.isEmpty ? UTType(filenameExtension: url.pathExtension) : nil)
                ?? (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType,
              !utType.conforms(to: .image) else {
            return nil
        }
        if let ext = utType.preferredFilenameExtension,
           let mapped = RemoteAttachmentContract.canonicalTextMimeType(forExtension: ext) {
            return mapped
        }
        if pickerTextContentTypes.contains(where: { utType.conforms(to: $0) }) {
            return "text/plain"
        }
        return nil
    }

    static func isSupportedTextFileURL(_ url: URL) -> Bool {
        guard !url.hasDirectoryPath, canonicalTextMimeType(for: url) != nil else {
            return false
        }
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
           values.isDirectory == true || values.isPackage == true {
            return false
        }
        return true
    }

    static func isSupportedAttachmentFileURL(
        _ url: URL,
        allowImages: Bool = true,
        allowTextFiles: Bool = true
    ) -> Bool {
        (allowTextFiles && isSupportedTextFileURL(url))
            || (allowImages && isSupportedImageFileURL(url))
    }

    static func isSupportedImageFileURL(_ url: URL) -> Bool {
        guard !url.hasDirectoryPath, canonicalTextMimeType(for: url) == nil else {
            return false
        }
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey]) {
            if values.isDirectory == true || values.isPackage == true {
                return false
            }
            if let type = values.contentType {
                return type.conforms(to: .image)
            }
        }
        guard !url.pathExtension.isEmpty,
              let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }
}

@MainActor
final class DesktopSessionPromptComposer: ObservableObject {
    struct StagedAttachment: Identifiable, Equatable, Sendable {
        let id: String
        let attachment: RemoteAttachment
        let data: Data
        let previewPNGData: Data
        let previewImageId: UInt32
        let previewVersion: UInt64

        var displayName: String {
            attachment.displayName ?? RemoteAttachmentContract.defaultDisplayName(forMimeType: attachment.mimeType)
        }

        var isImage: Bool {
            attachment.isImage
        }
    }

    let sessionId: String
    let attachmentStore: RemoteAttachmentStore
    @Published var prompt: String = ""
    @Published var mode: RemotePromptMode = .immediate
    @Published var isPromptFieldFocused = false
    @Published private(set) var attachments: [StagedAttachment] = []
    @Published private(set) var attachedEpoch: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isSending = false
    @Published private(set) var isAttaching = false
    @Published private(set) var pendingOperationId: String?
    private var pendingOperationEpoch: String?
    private var previewSequence: UInt32 = 0
    private var attachGeneration: UInt64 = 0

    init(
        sessionId: String,
        attachmentStore: RemoteAttachmentStore = RemoteAttachmentStore()
    ) {
        self.sessionId = sessionId
        self.attachmentStore = attachmentStore
    }

    func imageLimits(
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date = Date()
    ) -> RemoteImageCapabilities? {
        guard operation.support == .receipts,
              let epoch = operation.conversationEpoch,
              RemoteAttachmentContract.validScope(sessionId: sessionId, conversationEpoch: epoch),
              let workflow,
              workflow.supports(.send, at: now),
              workflow.capabilities.contains(RemoteAttachmentContract.capability),
              let limits = workflow.imageAttachments,
              limits.isValid else {
            return nil
        }
        return limits
    }

    func supportsFileAttachments(
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date = Date()
    ) -> Bool {
        guard operation.support == .receipts,
              let epoch = operation.conversationEpoch,
              RemoteAttachmentContract.validScope(sessionId: sessionId, conversationEpoch: epoch),
              let workflow,
              workflow.supports(.send, at: now),
              workflow.capabilities.contains(RemoteAttachmentContract.fileCapability) else {
            return false
        }
        return true
    }

    func maxAttachmentCount(
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date = Date()
    ) -> Int {
        if supportsFileAttachments(workflow: workflow, operation: operation, now: now) {
            return RemoteAttachmentContract.maxAttachments
        }
        return imageLimits(workflow: workflow, operation: operation, now: now)?.maxImages ?? 0
    }

    func canAttach(
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date = Date()
    ) -> Bool {
        guard !isSending, !isAttaching, pendingOperationId == nil,
              let epoch = operation.conversationEpoch else {
            return false
        }
        let maxCount = maxAttachmentCount(workflow: workflow, operation: operation, now: now)
        guard maxCount > 0, attachments.count < maxCount else { return false }
        return attachments.isEmpty || attachedEpoch == epoch
    }

    func attachHelpText(
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date = Date()
    ) -> String {
        let limits = imageLimits(workflow: workflow, operation: operation, now: now)
        let allowText = supportsFileAttachments(workflow: workflow, operation: operation, now: now)
        if let limits, allowText {
            return "Attach files (JSON, Markdown, code, text up to 512 KB) or screenshots (up to \(limits.maxImages) images, \(limits.maxBytes / 1_024) KB each)."
        }
        if let limits {
            return "Attach PNG or JPEG screenshots (up to \(limits.maxImages) images, \(limits.maxBytes / 1_024) KB each)."
        }
        if allowText {
            return "Attach JSON, Markdown, code, or text files (up to \(RemoteAttachmentContract.maxAttachments) files, 512 KB each)."
        }
        return "Requires an active Copilot session with attachment support."
    }

    func attachmentsBlockedReason(
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date = Date()
    ) -> String? {
        guard !attachments.isEmpty else { return nil }
        guard operation.support == .receipts,
              let currentEpoch = operation.conversationEpoch,
              attachedEpoch == currentEpoch else {
            return "Attachments belong to an earlier conversation. Remove and reattach them."
        }
        guard let workflow, workflow.supports(.send, at: now) else {
            return "This session cannot send attachments right now."
        }
        let stagedAttachments = attachments.map(\.attachment)
        let limits = imageLimits(workflow: workflow, operation: operation, now: now)
        if stagedAttachments.contains(where: \.isImage) && limits == nil {
            return "This model or session cannot send screenshots right now. Remove them or switch to a vision-capable model."
        }
        guard RemoteAttachmentContract.accepts(
            stagedAttachments,
            capabilities: workflow.capabilities,
            imageLimits: limits,
            at: now
        ) else {
            return "Attachments expired or exceed this model's limits. Remove and reattach them."
        }
        return nil
    }

    func canSend(
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date = Date()
    ) -> Bool {
        guard !isSending, !isAttaching, pendingOperationId == nil,
              operation.support == .receipts,
              let epoch = operation.conversationEpoch,
              !epoch.isEmpty,
              let workflow,
              workflow.supports(.send, at: now),
              workflow.sendReady,
              SessionInputValidation.isValidPrompt(prompt),
              attachmentsBlockedReason(workflow: workflow, operation: operation, now: now) == nil else {
            return false
        }
        return true
    }

    func syncConversationEpoch(_ currentEpoch: String?) {
        if let currentEpoch, let pendingOperationEpoch, pendingOperationEpoch != currentEpoch {
            pendingOperationId = nil
            self.pendingOperationEpoch = nil
            statusMessage = "The conversation changed. Check the terminal before sending again."
        }
    }

    func reconcileReceipts(
        _ receipts: [RemoteOperationReceipt]?,
        conversationEpoch: String?
    ) {
        syncConversationEpoch(conversationEpoch)
        guard let pendingId = pendingOperationId,
              let receipt = receipts?.first(where: {
                  $0.operationId == pendingId
                      && $0.kind == RemoteSessionActionKind.send.rawValue
                      && ($0.state == .applied || $0.state == .rejected)
              }) else {
            return
        }
        pendingOperationId = nil
        pendingOperationEpoch = nil
        if receipt.state == .applied {
            prompt = ""
            attachments = []
            attachedEpoch = nil
            statusMessage = nil
        } else {
            statusMessage = "Copilot did not accept this message. Review and try again."
        }
    }

    func attachImageData(
        _ rawDataList: [Data],
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date = Date()
    ) async {
        await attachSources(
            .imagePayloads(rawDataList),
            workflow: workflow,
            operation: operation,
            now: now
        )
    }

    func attachFiles(
        _ urls: [URL],
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date = Date()
    ) async {
        await attachSources(
            .fileURLs(urls),
            workflow: workflow,
            operation: operation,
            now: now
        )
    }

    @discardableResult
    func pasteFromPasteboard(
        _ pasteboard: NSPasteboard = .general,
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date = Date()
    ) async -> Bool {
        guard !isSending, !isAttaching, pendingOperationId == nil else {
            statusMessage = "Wait for the current action to finish before attaching files."
            return false
        }
        let limits = imageLimits(workflow: workflow, operation: operation, now: now)
        let allowText = supportsFileAttachments(workflow: workflow, operation: operation, now: now)
        let maxCount = maxAttachmentCount(workflow: workflow, operation: operation, now: now)
        guard maxCount > 0 else {
            statusMessage = "Select an active session with native controls before attaching files."
            return false
        }
        let remaining = max(0, maxCount - attachments.count)
        do {
            let source = try DesktopScreenshotAttachmentImage.pasteboardSources(
                from: pasteboard,
                remainingCapacity: remaining,
                maxImages: maxCount,
                allowImages: limits != nil,
                allowTextFiles: allowText
            )
            let beforeCount = attachments.count
            await attachSources(source, workflow: workflow, operation: operation, now: now)
            return attachments.count > beforeCount
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    private func attachSources(
        _ source: DesktopScreenshotAttachmentImage.PasteboardSource,
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date
    ) async {
        let itemCount: Int = switch source {
        case .fileURLs(let urls): urls.count
        case .imagePayloads(let payloads): payloads.count
        }
        guard itemCount > 0 else { return }
        guard !isSending, !isAttaching, pendingOperationId == nil else {
            statusMessage = "Wait for the current action to finish before attaching files."
            return
        }
        let limits = imageLimits(workflow: workflow, operation: operation, now: now)
        let allowText = supportsFileAttachments(workflow: workflow, operation: operation, now: now)
        let maxCount = maxAttachmentCount(workflow: workflow, operation: operation, now: now)
        guard maxCount > 0, let epoch = operation.conversationEpoch else {
            statusMessage = "Select an active session with native controls before attaching files."
            return
        }
        if !attachments.isEmpty && attachedEpoch != epoch {
            statusMessage = "Attachments belong to an earlier conversation. Remove saved attachments before attaching new ones."
            return
        }
        guard attachments.count + itemCount <= maxCount else {
            statusMessage = "This session allows up to \(maxCount) attachment(s) per message."
            return
        }
        let existingImageCount = attachments.filter(\.isImage).count
        let targetSessionId = sessionId
        let store = attachmentStore
        attachGeneration &+= 1
        let generation = attachGeneration
        isAttaching = true
        defer {
            if attachGeneration == generation {
                isAttaching = false
            }
        }
        let result: Result<[(RemoteAttachment, DesktopScreenshotAttachmentImage.NormalizedAttachment)], Error> =
            await Task.detached {
                var stored: [(RemoteAttachment, DesktopScreenshotAttachmentImage.NormalizedAttachment)] = []
                do {
                    let normalizedList: [DesktopScreenshotAttachmentImage.NormalizedAttachment]
                    switch source {
                    case .fileURLs(let urls):
                        normalizedList = try urls.map {
                            try DesktopScreenshotAttachmentImage.normalizedFile(
                                $0,
                                imageLimits: limits,
                                allowTextFiles: allowText
                            )
                        }
                    case .imagePayloads(let rawDataList):
                        guard let limits else {
                            throw DesktopScreenshotAttachmentImage.AttachmentError.unsupportedModelForImage
                        }
                        normalizedList = try rawDataList.map {
                            try DesktopScreenshotAttachmentImage.normalized($0, limits: limits)
                        }
                    }
                    let newImageCount = normalizedList.filter {
                        RemoteAttachmentContract.isImageMimeType($0.mimeType)
                    }.count
                    if newImageCount > 0 {
                        guard let limits, existingImageCount + newImageCount <= limits.maxImages else {
                            throw DesktopScreenshotAttachmentImage.AttachmentError.tooManyImages(
                                limits?.maxImages ?? 0
                            )
                        }
                    }
                    for normalized in normalizedList {
                        let id = UUID().uuidString.lowercased()
                        let isImage = RemoteAttachmentContract.isImageMimeType(normalized.mimeType)
                        let metadata = try store.store(
                            normalized.data,
                            id: id,
                            sessionId: targetSessionId,
                            conversationEpoch: epoch,
                            mimeType: normalized.mimeType,
                            displayName: normalized.displayName,
                            now: now,
                            limits: isImage ? limits : nil
                        )
                        stored.append((metadata, normalized))
                    }
                    return .success(stored)
                } catch {
                    for (metadata, _) in stored {
                        try? FileManager.default.removeItem(at: store.root.appendingPathComponent("\(metadata.id).image"))
                        try? FileManager.default.removeItem(at: store.root.appendingPathComponent("\(metadata.id).json"))
                    }
                    return .failure(error)
                }
            }.value
        guard attachGeneration == generation else {
            if case .success(let stored) = result {
                for (metadata, _) in stored {
                    removeStoredFiles(id: metadata.id)
                }
            }
            return
        }
        switch result {
        case .success(let stored):
            let currentNewImages = stored.filter { $0.0.isImage }.count
            let imageCountValid = currentNewImages == 0 || (
                limits != nil && attachments.filter(\.isImage).count + currentNewImages <= (limits?.maxImages ?? 0)
            )
            guard attachments.isEmpty || attachedEpoch == epoch,
                  attachments.count + stored.count <= maxCount,
                  imageCountValid else {
                for (metadata, _) in stored {
                    removeStoredFiles(id: metadata.id)
                }
                statusMessage = "The conversation changed while attaching files. Try again."
                return
            }
            if attachments.isEmpty {
                attachedEpoch = epoch
            }
            for (metadata, normalized) in stored {
                attachments.append(makeStagedAttachment(metadata: metadata, normalized: normalized))
            }
            statusMessage = nil
        case .failure(let error):
            statusMessage = error.localizedDescription
        }
    }

    func removeAttachment(id: String) {
        guard !isSending, pendingOperationId == nil else { return }
        attachments.removeAll { $0.id == id }
        removeStoredFiles(id: id)
        if attachments.isEmpty {
            attachedEpoch = nil
        }
        statusMessage = nil
    }

    func clearAttachments(force: Bool = false) {
        guard force || (!isSending && pendingOperationId == nil) else { return }
        let ids = attachments.map(\.id)
        attachGeneration &+= 1
        isAttaching = false
        attachments = []
        attachedEpoch = nil
        statusMessage = nil
        for id in ids {
            removeStoredFiles(id: id)
        }
    }

    func dismissStatusMessage() {
        statusMessage = nil
    }

    func previewItem(for item: StagedAttachment) -> TranscriptImagePreviewItem {
        TranscriptImagePreviewItem(
            id: TranscriptImageIdentity(
                sessionId: sessionId,
                imageId: item.previewImageId,
                version: item.previewVersion
            ),
            data: item.previewPNGData
        )
    }

    func send(
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult,
        now: Date = Date()
    ) async {
        syncConversationEpoch(operation.conversationEpoch)
        if let blocked = attachmentsBlockedReason(workflow: workflow, operation: operation, now: now) {
            statusMessage = blocked
            return
        }
        guard canSend(workflow: workflow, operation: operation, now: now),
              let submittedEpoch = operation.conversationEpoch else {
            return
        }
        let action = RemoteSessionAction(
            kind: .send,
            prompt: prompt,
            mode: mode,
            attachmentIds: attachments.isEmpty ? nil : attachments.map(\.id)
        )
        guard action.isValid else {
            statusMessage = "Enter a valid prompt of at most 8,192 UTF-8 bytes."
            return
        }
        isSending = true
        statusMessage = "Waiting for Copilot to confirm..."
        if !attachments.isEmpty {
            let ids = attachments.map(\.id)
            let store = attachmentStore
            let targetSessionId = sessionId
            let verified = await Task.detached {
                ids.allSatisfy { id in
                    (try? store.image(
                        id: id,
                        sessionId: targetSessionId,
                        conversationEpoch: submittedEpoch,
                        now: now
                    )) != nil
                }
            }.value
            guard verified else {
                isSending = false
                statusMessage = "Attachment is missing or expired. Remove and reattach it."
                return
            }
        }
        let result = await onAction(action)
        isSending = false
        switch result.state {
        case .applied:
            prompt = ""
            attachments = []
            attachedEpoch = nil
            pendingOperationId = nil
            pendingOperationEpoch = nil
            statusMessage = nil
        case .indeterminate:
            pendingOperationId = result.operationId
            pendingOperationEpoch = submittedEpoch
            statusMessage = result.message ?? "Couldn't confirm the outcome. Inspect the terminal before trying again."
        case .rejected, .accepted:
            pendingOperationId = nil
            pendingOperationEpoch = nil
            statusMessage = result.message ?? "Copilot did not accept this message."
        }
    }

    private func makeStagedAttachment(
        metadata: RemoteAttachment,
        normalized: DesktopScreenshotAttachmentImage.NormalizedAttachment
    ) -> StagedAttachment {
        previewSequence &+= 1
        // Keep attachment preview IDs outside Kitty's 24-bit 1...0xFFFFFF namespace.
        let imageId = 0x0100_0000 &+ (previewSequence & 0x00FF_FFFF)
        return StagedAttachment(
            id: metadata.id,
            attachment: metadata,
            data: normalized.data,
            previewPNGData: normalized.previewPNGData,
            previewImageId: imageId,
            previewVersion: UInt64(previewSequence)
        )
    }

    private func removeStoredFiles(id: String) {
        guard RemoteAttachmentContract.validID(id) else { return }
        let fm = FileManager.default
        let imageURL = attachmentStore.root.appendingPathComponent("\(id).image")
        let metadataURL = attachmentStore.root.appendingPathComponent("\(id).json")
        if fm.fileExists(atPath: imageURL.path) {
            try? fm.removeItem(at: imageURL)
        }
        if fm.fileExists(atPath: metadataURL.path) {
            try? fm.removeItem(at: metadataURL)
        }
    }
}

@MainActor
final class CopilotPromptComposer: NSObject, NSTextViewDelegate {
    enum Outcome {
        case started, cancelled, newTerminal
    }

    let alert = NSAlert()
    let textView: NSTextView
    let availableHosts: [RemoteHostInfo]
    private(set) var selectedHostId: String?
    private var hostPopUpButton: NSPopUpButton?
    private let instructions = "Write the first prompt for an interactive Copilot session. "
        + "Return adds a line; Command-Return starts Copilot. "
        + "If startup fails, use the tab's Copy Starting Prompt menu before closing the tab or quitting."

    init(
        availableHosts: [RemoteHostInfo] = [.local],
        selectedHostId: String? = nil
    ) {
        self.availableHosts = availableHosts
        self.selectedHostId = selectedHostId ?? availableHosts.first?.id
        let (scrollView, textView) = Self.makePromptEditorScrollView(
            initialText: "",
            font: .systemFont(ofSize: NSFont.systemFontSize)
        )
        self.textView = textView
        super.init()
        textView.setAccessibilityLabel("Starting prompt")
        textView.delegate = self
        alert.messageText = "Start Copilot with a Prompt"
        alert.addButton(withTitle: "Start Copilot")
        alert.addButton(withTitle: "Cancel")
        let terminalButton = alert.addButton(withTitle: "New Terminal")
        terminalButton.isHidden = true
        terminalButton.keyEquivalent = ""
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[0].keyEquivalentModifierMask = .command
        alert.buttons[1].keyEquivalent = "\u{1b}"
        let hasRemoteSelection = self.selectedHostId.map {
            $0.caseInsensitiveCompare(RemoteHostInfo.localId) != .orderedSame
        } == true
        if availableHosts.count > 1 || hasRemoteSelection {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 214))
            let label = NSTextField(labelWithString: "Host:")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            label.frame = NSRect(x: 0, y: 188, width: 40, height: 20)
            let popUp = NSPopUpButton(frame: NSRect(x: 44, y: 186, width: 220, height: 24), pullsDown: false)
            for host in availableHosts {
                let title = host.isLocal ? host.displayName : "\(host.displayName) (\(host.sshTarget ?? host.id))"
                popUp.addItem(withTitle: title)
                popUp.lastItem?.representedObject = host.id
            }
            if let initialId = self.selectedHostId {
                if let idx = availableHosts.firstIndex(where: { $0.id.caseInsensitiveCompare(initialId) == .orderedSame }) {
                    popUp.selectItem(at: idx)
                } else {
                    popUp.addItem(withTitle: "Unavailable (\(initialId))")
                    popUp.lastItem?.representedObject = initialId
                    popUp.selectItem(at: popUp.numberOfItems - 1)
                }
            }
            self.selectedHostId = popUp.selectedItem?.representedObject as? String
            popUp.target = self
            popUp.action = #selector(hostSelectionChanged(_:))
            popUp.setAccessibilityLabel("Execution host")
            self.hostPopUpButton = popUp
            scrollView.frame = NSRect(x: 0, y: 0, width: 440, height: 180)
            container.addSubview(label)
            container.addSubview(popUp)
            container.addSubview(scrollView)
            alert.accessoryView = container
        } else {
            alert.accessoryView = scrollView
        }
        alert.window.initialFirstResponder = textView
        updateValidation()
    }

    @objc private func hostSelectionChanged(_ sender: NSPopUpButton) {
        if let hostId = sender.selectedItem?.representedObject as? String {
            selectedHostId = hostId
        }
    }

    /// Plain-text prompt editor shared by the starting-prompt composer and the
    /// pull request review prompt editor. Smart substitutions stay off so AppKit
    /// cannot rewrite prompt text.
    fileprivate static func makePromptEditorScrollView(
        initialText: String,
        font: NSFont
    ) -> (NSScrollView, NSTextView) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 180))
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.font = font
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.string = initialText

        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    func textDidChange(_ notification: Notification) {
        updateValidation()
    }

    private func updateValidation() {
        let valid = SessionInputValidation.isValidPrompt(textView.string)
        alert.buttons[0].isEnabled = valid
        alert.informativeText = valid || textView.string.isEmpty
            ? instructions
            : "Enter a nonempty prompt of at most 8,192 UTF-8 bytes, without terminal control characters."
    }

    func run(
        present: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() },
        start: @MainActor (String) throws -> Void
    ) -> Outcome {
        var offersTerminal = false
        while true {
            alert.buttons[2].isHidden = !offersTerminal
            alert.layout()
            alert.window.initialFirstResponder = textView
            let response = present(alert)
            if response == .alertThirdButtonReturn, offersTerminal {
                return .newTerminal
            }
            guard response == .alertFirstButtonReturn else { return .cancelled }
            do {
                try start(textView.string)
                return .started
            } catch {
                // Keep the same editor and its text on synchronous launch failures.
                alert.informativeText = error.localizedDescription
                switch error as? AppModel.CopilotSessionStartError {
                case .copilotUnavailable, .remoteWrapperUnavailable, .backendUnavailable:
                    offersTerminal = true
                default:
                    offersTerminal = false
                }
            }
        }
    }
}

/// A review prompt that can be launched for every parsed pull request.
///
/// Only `validated(_:)` and `builtIn` create values. Launch paths therefore
/// render the template and do not re-check it.
public struct PullRequestReviewPrompt: Equatable, Sendable {
    public static let urlPlaceholder = "{url}"
    /// Absent means the user has not customized the prompt, so they keep
    /// receiving later edits to `builtIn`. The name has no dots so it can move
    /// into App-scene `@AppStorage` without rebuilding the scene on every write.
    public static let defaultsKey = "pullRequestReviewPrompt"

    public static let builtIn = PullRequestReviewPrompt(
        uncheckedTemplate:
            "Perform a read-only local adversarial review of {url}. "
            + "Use the adversarial-review skill. Inspect the pull request from a local checkout "
            + "or isolated worktree. Do not edit files, push changes, or post anything to GitHub. "
            + "Report the findings in this session."
    )

    public enum ValidationError: Error, Equatable, Sendable {
        case empty
        case missingURLPlaceholder
        case tooLong(maximumBytes: Int)
        case unsupportedCharacters

        public var message: String {
            switch self {
            case .empty:
                return "Enter a review prompt."
            case .missingURLPlaceholder:
                return "Include \(PullRequestReviewPrompt.urlPlaceholder) where the pull request URL should be inserted."
            case .tooLong(let maximumBytes):
                let limit = maximumBytes.formatted(.number.locale(Locale(identifier: "en_US")))
                return "Keep the prompt to at most \(limit) UTF-8 bytes so the pull request URL fits."
            case .unsupportedCharacters:
                return "Remove terminal control characters from the prompt."
            }
        }
    }

    public let template: String

    public var isBuiltIn: Bool { self == .builtIn }

    private init(uncheckedTemplate: String) {
        template = uncheckedTemplate
    }

    public static func validated(_ rawTemplate: String) -> Result<PullRequestReviewPrompt, ValidationError> {
        let normalized = rawTemplate
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .failure(.empty) }
        let placeholderCount = normalized.components(separatedBy: urlPlaceholder).count - 1
        guard placeholderCount > 0 else { return .failure(.missingURLPlaceholder) }

        let maximumBytes = templateBudget(placeholderCount: placeholderCount)
        if let worstCasePrompt = worstCasePrompt(normalized, placeholderCount: placeholderCount),
           SessionInputValidation.isValidPrompt(worstCasePrompt) {
            return .success(PullRequestReviewPrompt(uncheckedTemplate: normalized))
        }
        if containsUnsupportedControls(normalized) {
            return .failure(.unsupportedCharacters)
        }
        return .failure(.tooLong(maximumBytes: maximumBytes))
    }

    public static func stored(in defaults: UserDefaults = .standard) -> PullRequestReviewPrompt {
        guard let raw = defaults.string(forKey: defaultsKey),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .builtIn
        }
        switch validated(raw) {
        case .success(let prompt):
            return prompt
        case .failure(let error):
            logInvalidStoredPrompt(error.message)
            return .builtIn
        }
    }

    private static let invalidStoredPromptLock = NSLock()
    private static var didLogInvalidStoredPrompt = false

    /// A corrupt setting is read on every review launch. Log the first fallback
    /// only, and never write the key back.
    private static func logInvalidStoredPrompt(_ message: String) {
        invalidStoredPromptLock.lock()
        let shouldLog = !didLogInvalidStoredPrompt
        didLogInvalidStoredPrompt = true
        invalidStoredPromptLock.unlock()
        guard shouldLog else { return }
        NSLog(
            "copilot-projects: stored pull request review prompt is invalid (%@); using the built-in prompt",
            message
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        if self == .builtIn {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(template, forKey: Self.defaultsKey)
        }
    }

    public static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    public func prompt(for target: PullRequestReviewTarget) -> String {
        template.replacingOccurrences(of: Self.urlPlaceholder, with: target.url)
    }

    /// Template bytes left after reserving the longest URL `PullRequestReviewTarget.parse`
    /// can produce for every `{url}`. Each placeholder grows by that URL minus `{url}` itself.
    private static func templateBudget(placeholderCount: Int) -> Int {
        let expansion = PullRequestReviewTarget.maximumInputBytes - urlPlaceholder.utf8.count
        let (reserved, overflow) = placeholderCount.multipliedReportingOverflow(by: expansion)
        guard !overflow else { return 0 }
        return max(0, SessionInputValidation.maximumPromptBytes - reserved)
    }

    /// The prompt with every `{url}` replaced by a 2,048-byte URL, or nil when that
    /// rendering cannot fit. Skipping the allocation keeps a corrupt stored template
    /// from building a multi-gigabyte string on the launch path.
    private static func worstCasePrompt(_ template: String, placeholderCount: Int) -> String? {
        let expansion = PullRequestReviewTarget.maximumInputBytes - urlPlaceholder.utf8.count
        let (reserved, overflow) = placeholderCount.multipliedReportingOverflow(by: expansion)
        guard !overflow else { return nil }
        let (renderedCount, renderedOverflow) = template.utf8.count.addingReportingOverflow(reserved)
        guard !renderedOverflow, renderedCount <= SessionInputValidation.maximumPromptBytes else {
            return nil
        }
        let worstCaseURL = String(repeating: "a", count: PullRequestReviewTarget.maximumInputBytes)
        return template.replacingOccurrences(of: urlPlaceholder, with: worstCaseURL)
    }

    private static func containsUnsupportedControls(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control && scalar != "\n" && scalar != "\t"
        }
    }
}

@MainActor
enum PullRequestReviewPromptEditor {
    static func runModal(
        initialPrompt: PullRequestReviewPrompt,
        present: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    ) -> PullRequestReviewPrompt? {
        var draft = initialPrompt.template
        var errorMessage: String?
        let restoreDefault = NSApplication.ModalResponse(
            rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 2
        )
        while true {
            let alert = NSAlert()
            alert.messageText = "Pull Request Review Prompt"
            alert.informativeText = informativeText(errorMessage: errorMessage)
            let (scrollView, textView) = CopilotPromptComposer.makePromptEditorScrollView(
                initialText: draft,
                font: .systemFont(ofSize: NSFont.systemFontSize)
            )
            textView.setAccessibilityLabel("Pull request review prompt")
            textView.setSelectedRange(NSRange(location: 0, length: (draft as NSString).length))
            alert.accessoryView = scrollView
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            let restore = alert.addButton(withTitle: "Restore Default")
            restore.keyEquivalent = ""
            alert.buttons[0].keyEquivalent = "\r"
            alert.buttons[0].keyEquivalentModifierMask = [.command]
            alert.buttons[1].keyEquivalent = "\u{1b}"
            alert.layout()
            alert.window.initialFirstResponder = textView

            let response = present(alert)
            draft = textView.string
            if response == .alertFirstButtonReturn {
                switch PullRequestReviewPrompt.validated(draft) {
                case .success(let prompt):
                    return prompt
                case .failure(let error):
                    errorMessage = error.message
                }
            } else if response == restoreDefault {
                draft = PullRequestReviewPrompt.builtIn.template
                errorMessage = nil
            } else {
                return nil
            }
        }
    }

    private static func informativeText(errorMessage: String?) -> String {
        guard let errorMessage else {
            return "This prompt is sent to Copilot when you start Review Pull Request… "
                + "Include \(PullRequestReviewPrompt.urlPlaceholder) where the pull request URL should be inserted. "
                + "Command-Return saves."
        }
        return errorMessage + " Command-Return saves."
    }
}
