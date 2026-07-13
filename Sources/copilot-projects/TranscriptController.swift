import Foundation
import Combine
import Darwin
import CopilotProjectsCore
import CopilotProjectsProtocol

@MainActor
final class TranscriptController: ObservableObject {
    private struct FileSignature: Equatable, Sendable {
        let size: UInt64
        let modifiedAt: TimeInterval
        let fileNumber: UInt64
    }

    private struct LoadResult: Sendable {
        let signature: FileSignature?
        let snapshot: TranscriptSnapshot?
    }

    @Published private(set) var snapshot: TranscriptSnapshot?

    let sessionId: String

    private var directorySource: DispatchSourceFileSystemObject?
    private var fallbackTimer: Timer?
    private var signature: FileSignature?
    private var reloadGeneration = 0
    private var started = false

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    deinit {
        directorySource?.cancel()
        fallbackTimer?.invalidate()
    }

    func start() {
        guard !started else { return }
        started = true
        watchSessionsDirectory()
        reload()
    }

    private func watchSessionsDirectory() {
        Paths.ensureStateDir()
        let descriptor = open(Paths.sessionsDir.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in self?.reload(after: 0.03) }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            directorySource = source
        }

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    private func reload(after delay: TimeInterval = 0) {
        reloadGeneration += 1
        let generation = reloadGeneration
        let previousSignature = signature
        let path = Paths.transcriptSnapshotPath(sessionId: sessionId)
        Task.detached {
            if delay > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            }
            guard let result = Self.load(
                path: path,
                previousSignature: previousSignature
            ) else { return }
            await MainActor.run { [weak self] in
                guard let self, generation == reloadGeneration else { return }
                signature = result.signature
                snapshot = result.snapshot
            }
        }
    }

    nonisolated private static func load(
        path: String,
        previousSignature: FileSignature?
    ) -> LoadResult? {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            guard previousSignature != nil else { return nil }
            return LoadResult(signature: nil, snapshot: nil)
        }
        let signature = FileSignature(
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modifiedAt: (attributes[.modificationDate] as? Date)?
                .timeIntervalSinceReferenceDate ?? 0,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?
                .uint64Value ?? 0
        )
        guard signature != previousSignature else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        let decoder = transcriptDecoder()
        guard let snapshot = try? decoder.decode(TranscriptSnapshot.self, from: data),
              snapshot.schemaVersion == 3 else {
            return LoadResult(signature: signature, snapshot: nil)
        }
        return LoadResult(signature: signature, snapshot: snapshot)
    }

    nonisolated static func remoteRevision(sessionId: String) -> RemoteTranscriptRevision {
        let path = Paths.transcriptSnapshotPath(sessionId: sessionId)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        else {
            return RemoteTranscriptRevision(sessionId: sessionId, generation: "missing")
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate ?? 0
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?
            .uint64Value ?? 0
        return RemoteTranscriptRevision(
            sessionId: sessionId,
            generation: "\(fileNumber):\(size):\(modified)"
        )
    }

    nonisolated static func loadRemoteSnapshot(sessionId: String) -> TranscriptSnapshot {
        let path = Paths.transcriptSnapshotPath(sessionId: sessionId)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.count <= 6 * 1_024 * 1_024 else {
            return emptyRemoteSnapshot()
        }
        let decoder = transcriptDecoder()
        guard let snapshot = try? decoder.decode(TranscriptSnapshot.self, from: data),
              snapshot.schemaVersion == 3 else {
            return emptyRemoteSnapshot()
        }
        return snapshot
    }

    nonisolated private static func emptyRemoteSnapshot() -> TranscriptSnapshot {
        TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Date(),
            copilotSessionId: "",
            turns: []
        )
    }

    nonisolated private static func transcriptDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = try? fractional.parse(value) {
                return date
            }

            if let date = try? plain.parse(value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 timestamp: \(value)"
            )
        }
        return decoder
    }
}
