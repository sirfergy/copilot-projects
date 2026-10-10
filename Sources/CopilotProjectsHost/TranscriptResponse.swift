import Foundation
import CopilotProjectsProtocol

enum TranscriptResponse {
    static func encodedResponse(
        snapshot: TranscriptSnapshot,
        images: [RemoteKittyImageCapture.RetainedImageInfo],
        limit: Int?,
        after cursor: TranscriptCursor? = nil
    ) -> Data? {
        // Associate before windowing so dropped turns cannot donate images to
        // the oldest visible turn.
        let augmented = TranscriptImageAssociation.attach(images: images, to: snapshot)
        let windowed = augmented.remoteWindow(limit: limit, after: cursor)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(windowed)
    }
}
