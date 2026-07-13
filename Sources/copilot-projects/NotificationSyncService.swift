import AppKit
import Foundation
import CopilotProjectsCore
import CopilotProjectsProtocol

private struct StoredNotificationRecord: Codable, Sendable {
    let id: UUID
    let sentAt: Date
    var apnsSent: Bool
    var dismissedAt: Date?
}

final class NotificationLedger: @unchecked Sendable {
    private static let maximumRecords = 512
    private static let retention: TimeInterval = 7 * 24 * 60 * 60

    private let lock = NSLock()
    private let url: URL
    private var records: [UUID: StoredNotificationRecord]

    init(url: URL = Paths.stateDir.appendingPathComponent("notification-ledger.json")) {
        self.url = url
        records = Self.load(from: url)
        pruneLocked(now: Date())
    }

    func record(id: UUID, sentAt: Date, apnsSent: Bool) {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: Date())
        records[id] = StoredNotificationRecord(
            id: id,
            sentAt: sentAt,
            apnsSent: apnsSent,
            dismissedAt: nil
        )
        trimLocked()
        persistLocked()
    }

    func dismiss(id: UUID) -> (newlyDismissed: Bool, apnsSent: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        pruneLocked(now: now)
        if var record = records[id] {
            guard record.dismissedAt == nil else {
                return (false, record.apnsSent)
            }
            record.dismissedAt = now
            records[id] = record
            persistLocked()
            return (true, record.apnsSent)
        }
        records[id] = StoredNotificationRecord(
            id: id,
            sentAt: now,
            apnsSent: true,
            dismissedAt: now
        )
        trimLocked()
        persistLocked()
        return (true, true)
    }

    func dismissalSnapshot() -> NotificationDismissalSnapshot {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: Date())
        return NotificationDismissalSnapshot(ids: records.values
            .filter { $0.dismissedAt != nil }
            .sorted { ($0.dismissedAt ?? .distantPast) < ($1.dismissedAt ?? .distantPast) }
            .map(\.id))
    }

    private func pruneLocked(now: Date) {
        records = records.filter {
            now.timeIntervalSince($0.value.sentAt) <= Self.retention
        }
    }

    private func trimLocked() {
        guard records.count > Self.maximumRecords else { return }
        let excess = records.values
            .sorted { $0.sentAt < $1.sentAt }
            .prefix(records.count - Self.maximumRecords)
        for record in excess { records.removeValue(forKey: record.id) }
    }

    private func persistLocked() {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(records.values)) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func load(from url: URL) -> [UUID: StoredNotificationRecord] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = (try? decoder.decode([StoredNotificationRecord].self, from: data)) ?? []
        return Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }
}

private final class NotificationDeliveryQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tails: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]

    func enqueue(
        id: UUID,
        operation: @Sendable @escaping () async -> Void
    ) {
        let token = UUID()
        lock.lock()
        let previous = tails[id]?.task
        let task = Task.detached {
            await previous?.value
            await operation()
        }
        tails[id] = (token, task)
        lock.unlock()

        Task.detached { [weak self] in
            await task.value
            self?.remove(id: id, token: token)
        }
    }

    private func remove(id: UUID, token: UUID) {
        lock.lock()
        if tails[id]?.token == token {
            tails[id] = nil
        }
        lock.unlock()
    }
}

final class NotificationSyncService: @unchecked Sendable {
    private let ledger: NotificationLedger
    private let webPushService: WebPushService?
    private let apnsService: APNsService?
    private let deliveryQueue = NotificationDeliveryQueue()

    @MainActor var clearLocalNotification: ((UUID) -> Void)?

    init(
        ledger: NotificationLedger = NotificationLedger(),
        webPushService: WebPushService?,
        apnsService: APNsService?
    ) {
        self.ledger = ledger
        self.webPushService = webPushService
        self.apnsService = apnsService
    }

    func post(_ event: NotificationEvent, sendRemote: Bool) {
        let apnsSent = sendRemote && apnsService?.hasDevices == true
        ledger.record(id: event.id, sentAt: event.sentAt, apnsSent: apnsSent)
        guard sendRemote else { return }
        deliveryQueue.enqueue(id: event.id) { [webPushService, apnsService] in
            await withTaskGroup(of: Void.self) { group in
                if let webPushService {
                    group.addTask { await webPushService.send(event) }
                }
                if let apnsService {
                    group.addTask { await apnsService.send(event) }
                }
            }
        }
    }

    func dismiss(_ request: NotificationDismissRequest) {
        let transition = ledger.dismiss(id: request.id)
        Task { @MainActor [weak self] in
            self?.clearLocalNotification?(request.id)
        }
        guard transition.newlyDismissed else {
            return
        }
        let sendsAPNs = transition.apnsSent && apnsService != nil
        guard webPushService != nil || sendsAPNs else { return }
        deliveryQueue.enqueue(id: request.id) { [webPushService, apnsService, sendsAPNs] in
            await withTaskGroup(of: Void.self) { group in
                if let webPushService {
                    group.addTask { await webPushService.sendDismissal(id: request.id) }
                }
                if sendsAPNs, let apnsService {
                    group.addTask {
                        await apnsService.sendDismissal(
                            id: request.id,
                            excludingToken: request.apnsToken,
                            environment: request.apnsEnvironment
                        )
                    }
                }
            }
        }
    }

    func dismissalSnapshot() -> NotificationDismissalSnapshot {
        ledger.dismissalSnapshot()
    }
}

enum DesktopActivity {
    static let anyInputEvent = CGEventType(rawValue: UInt32.max)!

    static func wasRecentlyActive(
        threshold: TimeInterval = 120,
        secondsSinceLastInput: () -> TimeInterval = {
            CGEventSource.secondsSinceLastEventType(
                .hidSystemState,
                eventType: anyInputEvent
            )
        }
    ) -> Bool {
        secondsSinceLastInput() < threshold
    }
}

@MainActor
final class RoutedNotificationPoster: NotificationPosting {
    private let native: any NotificationPosting
    private let sync: NotificationSyncService
    private let isDesktopRecentlyActive: () -> Bool

    init(
        native: any NotificationPosting,
        sync: NotificationSyncService,
        isDesktopRecentlyActive: @escaping () -> Bool = {
            DesktopActivity.wasRecentlyActive()
        }
    ) {
        self.native = native
        self.sync = sync
        self.isDesktopRecentlyActive = isDesktopRecentlyActive
    }

    func post(_ event: NotificationEvent) {
        native.post(event)
        sync.post(event, sendRemote: !isDesktopRecentlyActive())
    }
}
