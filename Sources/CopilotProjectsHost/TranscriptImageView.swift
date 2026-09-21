import AppKit
import ImageIO
import SwiftUI

struct TranscriptImageIdentity: Hashable {
    let sessionId: String
    let imageId: UInt32
    let version: UInt64
}

enum TranscriptImageError: Error {
    case invalidImage
}

actor TranscriptImageDecoder {
    static let shared = TranscriptImageDecoder()
    static let thumbnailDimension = 768
    static let previewDimension = 2_048

    func decode(_ data: Data, maximumDimension: Int) throws -> CGImage {
        try Task.checkCancellation()
        guard (1...Self.previewDimension).contains(maximumDimension),
              RemoteKittyPNGValidation.isStructurallyValid(data),
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw TranscriptImageError.invalidImage
        }
        try Task.checkCancellation()
        return image
    }
}

private struct LoadedTranscriptImage {
    let identity: TranscriptImageIdentity
    let data: Data
    let image: CGImage

    func matches(_ identity: TranscriptImageIdentity, data: Data?) -> Bool {
        self.identity.sessionId == identity.sessionId
            && self.identity.imageId == identity.imageId
            && self.data == data
    }
}

private struct TranscriptImagePreviewItem: Identifiable {
    let id: TranscriptImageIdentity
    let data: Data
}

struct TranscriptImageView: View {
    let identity: TranscriptImageIdentity
    let data: Data?
    @State private var loaded: LoadedTranscriptImage?
    @State private var failed: TranscriptImageIdentity?
    @State private var preview: TranscriptImagePreviewItem?

    private var readyImage: CGImage? {
        guard let loaded, loaded.matches(identity, data: data) else { return nil }
        return loaded.image
    }

    var body: some View {
        Group {
            if let data, let size = RemoteKittyPNGValidation.pixelSize(data) {
                Button {
                    preview = TranscriptImagePreviewItem(id: identity, data: data)
                } label: {
                    ZStack {
                        StudioStyle.raised
                        if let readyImage {
                            Image(decorative: readyImage, scale: 1)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Label(failed == identity ? "Image unavailable" : "Loading image",
                                  systemImage: failed == identity ? "exclamationmark.triangle" : "photo")
                                .font(.caption)
                                .foregroundStyle(StudioStyle.secondaryText)
                        }
                    }
                    .aspectRatio(size, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 280, alignment: .leading)
                    .frame(minHeight: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
                }
                .buttonStyle(.plain)
                .disabled(readyImage == nil)
                .help("Open image preview")
                .accessibilityLabel(failed == identity ? "Transcript image unavailable"
                    : readyImage == nil ? "Loading transcript image" : "Open transcript image")
                .accessibilityIdentifier("transcript-image-\(identity.imageId)-\(identity.version)")
            } else {
                Label("Image unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(StudioStyle.secondaryText)
                    .frame(minHeight: 44)
            }
        }
        .task(id: identity) {
            failed = nil
            guard let data else {
                loaded = nil
                failed = identity
                return
            }
            if let loaded, loaded.matches(identity, data: data) { return }
            self.loaded = nil
            do {
                let image = try await TranscriptImageDecoder.shared.decode(
                    data, maximumDimension: TranscriptImageDecoder.thumbnailDimension
                )
                guard !Task.isCancelled else { return }
                loaded = LoadedTranscriptImage(identity: identity, data: data, image: image)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failed = identity
                NSLog("Transcript image %u could not be decoded: %@", identity.imageId, String(describing: error))
            }
        }
        .sheet(item: $preview) { item in
            TranscriptImagePreview(item: item)
        }
    }
}

private struct TranscriptImagePreview: View {
    let item: TranscriptImagePreviewItem
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var failed = false
    @State private var zoom = 1.0
    @FocusState private var canvasFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Image preview").font(.headline)
                Spacer()
                Slider(value: $zoom, in: 1...4)
                    .frame(width: 140)
                    .disabled(image == nil)
                    .accessibilityLabel("Image zoom")
                    .accessibilityValue("\(Int(zoom * 100)) percent")
                Text("\(Int(zoom * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40)
                Button("Done") { dismiss() }
                    .keyboardShortcut("w", modifiers: .command)
                    .accessibilityIdentifier("close-transcript-image")
            }
            GeometryReader { geometry in
                if let image {
                    let scale = min(geometry.size.width / CGFloat(image.width),
                                    geometry.size.height / CGFloat(image.height), 1)
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: CGFloat(image.width) * scale * zoom,
                                   height: CGFloat(image.height) * scale * zoom)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    }
                    .focusable()
                    .focused($canvasFocused)
                    .accessibilityLabel("Transcript image preview")
                    .accessibilityIdentifier("transcript-image-preview")
                } else {
                    Label(failed ? "Image unavailable" : "Loading image",
                          systemImage: failed ? "exclamationmark.triangle" : "photo")
                        .foregroundStyle(StudioStyle.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 360, idealWidth: 720, maxWidth: 960,
               minHeight: 280, idealHeight: 520, maxHeight: 720)
        .background(StudioStyle.chrome)
        .onExitCommand { dismiss() }
        .task(id: item.id) {
            do {
                let decoded = try await TranscriptImageDecoder.shared.decode(
                    item.data, maximumDimension: TranscriptImageDecoder.previewDimension
                )
                guard !Task.isCancelled else { return }
                image = decoded
                canvasFocused = true
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
                NSLog("Transcript image preview could not be decoded: %@", String(describing: error))
            }
        }
    }
}
