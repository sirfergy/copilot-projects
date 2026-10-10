import Foundation
import CopilotProjectsProtocol

enum TranscriptResponse {
    /// The `/transcript` body for `sessionId`, or `nil` when the transcript
    /// kept changing under every read. The gateway answers `nil` with an
    /// error status, so clients keep what they have instead of replacing it
    /// with an empty snapshot, and fetch again on the next revision.
    static func encodedResponse(
        sessionId: String,
        images: [RemoteKittyImageCapture.RetainedImageInfo],
        limit: Int?,
        after cursor: TranscriptCursor?,
        duringRead: ((_ attempt: Int) -> Void)? = nil
    ) -> Data? {
        guard let snapshot = TranscriptController.loadRemoteSnapshotIfSettled(
            sessionId: sessionId,
            duringRead: duringRead
        ) else {
            return nil
        }
        return encodedResponse(snapshot: snapshot, images: images, limit: limit, after: cursor)
    }

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
