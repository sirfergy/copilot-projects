import Foundation
import Security
import WebPush
import Darwin
import CopilotProjectsCore
import CopilotProjectsProtocol

struct WebPushRegistration: Codable, Sendable {
    let subscription: Subscriber
    let label: String?
    let capabilities: [String]?
}

private struct StoredWebPushSubscription: Codable, Sendable {
    let subscription: Subscriber
    let label: String?
    let capabilities: [String]?
    let createdAt: Date
}

protocol WebPushSending: Sendable {
    func send(
        data: Data,
        to subscriber: Subscriber,
        eventID: UUID
    ) async throws
}

private struct LiveWebPushSender: WebPushSending {
    let manager: WebPushManager

    func send(
        data: Data,
        to subscriber: Subscriber,
        eventID: UUID
    ) async throws {
        try await manager.send(
            data: data,
            to: subscriber,
            encodableDeduplicationTopic: eventID.uuidString,
            expiration: .hours(24),
            urgency: .high
        )
    }
}

final class WebPushSubscriptionStore: @unchecked Sendable {
    private static let maximumSubscriptions = 16
    private static let clearActionCapability = "clear-action"
    private let lock = NSLock()
    private let url: URL
    private var subscriptions: [StoredWebPushSubscription]

    init(url: URL = Paths.stateDir.appendingPathComponent("web-push-subscriptions.json")) {
        self.url = url
        subscriptions = Self.load(from: url)
    }

    func all() -> [Subscriber] {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions.map(\.subscription)
    }

    func clearActionSubscribers() -> [Subscriber] {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions
            .filter { $0.capabilities?.contains(Self.clearActionCapability) == true }
            .map(\.subscription)
    }

    func add(_ registration: WebPushRegistration) throws {
        guard Self.validEndpoint(registration.subscription.endpoint) else {
            throw WebPushServiceError.invalidSubscription
        }
        let label = registration.label.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        }
        let capabilities = registration.capabilities?.compactMap { value -> String? in
            let capability = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !capability.isEmpty, capability.utf8.count <= 64 else { return nil }
            return capability
        }
        lock.lock()
        defer { lock.unlock() }
        subscriptions.removeAll {
            $0.subscription.endpoint == registration.subscription.endpoint
        }
        subscriptions.append(StoredWebPushSubscription(
            subscription: registration.subscription,
            label: label,
            capabilities: capabilities,
            createdAt: Date()
        ))
        if subscriptions.count > Self.maximumSubscriptions {
            subscriptions.removeFirst(subscriptions.count - Self.maximumSubscriptions)
        }
        try persistLocked()
    }

    func remove(endpoint: URL) {
        lock.lock()
        defer { lock.unlock() }
        let previousCount = subscriptions.count
        subscriptions.removeAll { $0.subscription.endpoint == endpoint }
        if subscriptions.count != previousCount {
            try? persistLocked()
        }
    }

    private func persistLocked() throws {
        let directoryURL = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw WebPushServiceError.persistenceFailed
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(subscriptions)
        let temporaryURL = directoryURL
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw WebPushServiceError.persistenceFailed
        }
        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw WebPushServiceError.persistenceFailed
        }
        guard rename(temporaryURL.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw WebPushServiceError.persistenceFailed
        }
    }

    private static func load(from url: URL) -> [StoredWebPushSubscription] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([StoredWebPushSubscription].self, from: data)) ?? []
    }

    private static func validEndpoint(_ endpoint: URL) -> Bool {
        guard endpoint.scheme?.lowercased() == "https",
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.port == nil || endpoint.port == 443,
              endpoint.absoluteString.utf8.count <= 2_048,
              let host = endpoint.host?.lowercased(),
              !host.isEmpty,
              host != "localhost",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !isIPAddress(host),
              allowedPushServiceHost(host) else {
            return false
        }
        return true
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 { return true }
        var ipv6 = in6_addr()
        return inet_pton(AF_INET6, host, &ipv6) == 1
    }

    private static func allowedPushServiceHost(_ host: String) -> Bool {
        host == "fcm.googleapis.com"
            || host == "updates.push.services.mozilla.com"
            || host.hasSuffix(".push.apple.com")
            || host.hasSuffix(".notify.windows.com")
    }
}

enum WebPushServiceError: Error {
    case invalidSubscription
    case persistenceFailed
    case unavailable
}

struct WebPushStatus: Codable, Sendable {
    let subscriptions: Int
    let lastAttemptAt: Date?
    let lastSuccessAt: Date?
    let lastError: String?
}

final class WebPushService: @unchecked Sendable {
    private static let keychainService = "com.obvioussean.copilot-projects.web-push"
    private static let keychainAccount = "vapid-configuration"

    let publicKey: String
    private let store: WebPushSubscriptionStore
    private let sender: any WebPushSending
    private let managerTask: Task<Void, Never>?
    private let statusLock = NSLock()
    private var lastAttemptAt: Date?
    private var lastSuccessAt: Date?
    private var lastError: String?

    static func production(
        contactEmail: String,
        store: WebPushSubscriptionStore = WebPushSubscriptionStore()
    ) throws -> WebPushService {
        let configuration = try loadOrCreateVAPIDConfiguration(
            contactEmail: contactEmail
        )
        let manager = WebPushManager(
            vapidConfiguration: configuration,
            backgroundActivityLogger: nil
        )
        let task = Task.detached {
            do {
                try await manager.run()
            } catch {
                NSLog("copilot-projects: WebPush manager stopped: %@", "\(error)")
            }
        }
        return WebPushService(
            publicKey: manager.nextVAPIDKeyID.description,
            store: store,
            sender: LiveWebPushSender(manager: manager),
            managerTask: task
        )
    }

    init(
        publicKey: String,
        store: WebPushSubscriptionStore,
        sender: any WebPushSending,
        managerTask: Task<Void, Never>? = nil
    ) {
        self.publicKey = publicKey
        self.store = store
        self.sender = sender
        self.managerTask = managerTask
    }

    deinit {
        managerTask?.cancel()
    }

    func shutdown() {
        managerTask?.cancel()
    }

    func register(data: Data) throws {
        guard data.count <= 16_384 else {
            throw WebPushServiceError.invalidSubscription
        }
        guard let registration = try? JSONDecoder().decode(
            WebPushRegistration.self,
            from: data
        ) else {
            throw WebPushServiceError.invalidSubscription
        }
        try store.add(registration)
    }

    func unregister(data: Data) throws {
        struct Request: Codable { let endpoint: URL }
        guard data.count <= 4_096,
              let request = try? JSONDecoder().decode(Request.self, from: data) else {
            throw WebPushServiceError.invalidSubscription
        }
        store.remove(endpoint: request.endpoint)
    }

    func status() -> WebPushStatus {
        statusLock.lock()
        defer { statusLock.unlock() }
        return WebPushStatus(
            subscriptions: store.all().count,
            lastAttemptAt: lastAttemptAt,
            lastSuccessAt: lastSuccessAt,
            lastError: lastError
        )
    }

    func send(_ event: NotificationEvent) async {
        let body = Self.truncatedUTF8(event.webBody, maximumBytes: 2_000)
        let title = Self.truncatedUTF8(event.title, maximumBytes: 512)
        await send(payload: RemoteNotificationPayload(
            id: event.id,
            kind: event.kind,
            title: title,
            body: body,
            projectId: event.projectId,
            sessionId: event.sessionId,
            sentAt: event.sentAt
        ))
    }

    func sendDismissal(id: UUID) async {
        await send(payload: RemoteNotificationPayload(
            action: .clear,
            id: id,
            kind: nil,
            title: "",
            body: "",
            projectId: nil,
            sessionId: nil,
            sentAt: Date()
        ), subscribers: store.clearActionSubscribers())
    }

    private func send(
        payload payloadObject: RemoteNotificationPayload,
        subscribers: [Subscriber]? = nil
    ) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let payload = try? encoder.encode(payloadObject),
              payload.count <= WebPushManager.maximumMessageSize else {
            return
        }
        let subscribers = subscribers ?? store.all()
        guard !subscribers.isEmpty else { return }
        updateStatus(attempt: Date(), success: nil, error: nil)
        enum Delivery: Sendable {
            case success(URL)
            case expired(URL)
            case failure(URL, String)
        }
        let sender = self.sender
        await withTaskGroup(of: Delivery.self) { group in
            for subscriber in subscribers {
                group.addTask {
                    do {
                        try await sender.send(
                            data: payload,
                            to: subscriber,
                            eventID: payloadObject.id
                        )
                        return .success(subscriber.endpoint)
                    } catch is BadSubscriberError {
                        return .expired(subscriber.endpoint)
                    } catch {
                        return .failure(
                            subscriber.endpoint,
                            error.localizedDescription
                        )
                    }
                }
            }
            var delivered = false
            var errors: [String] = []
            for await delivery in group {
                switch delivery {
                case .success(let endpoint):
                    NSLog(
                        "copilot-projects: web push accepted by %@",
                        endpoint.host ?? "unknown"
                    )
                    delivered = true
                case .expired(let endpoint):
                    store.remove(endpoint: endpoint)
                    errors.append("Subscription expired")
                case .failure(let endpoint, let message):
                    errors.append(message)
                    NSLog(
                        "copilot-projects: web push failed for %@: %@",
                        endpoint.host ?? "unknown",
                        message
                    )
                }
            }
            updateStatus(
                attempt: nil,
                success: delivered ? Date() : nil,
                error: errors.first
            )
        }
    }

    private func updateStatus(
        attempt: Date?,
        success: Date?,
        error: String?
    ) {
        statusLock.lock()
        if let attempt { lastAttemptAt = attempt }
        if let success { lastSuccessAt = success }
        lastError = error
        statusLock.unlock()
    }

    private static func truncatedUTF8(
        _ value: String,
        maximumBytes: Int
    ) -> String {
        var result = ""
        var byteCount = 0
        for character in value {
            let text = String(character)
            let characterBytes = text.utf8.count
            guard byteCount + characterBytes <= maximumBytes else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result
    }

    private static func loadOrCreateVAPIDConfiguration(
        contactEmail: String
    ) throws -> VAPID.Configuration {
        if let data = keychainData(),
           let configuration = try? JSONDecoder().decode(
            VAPID.Configuration.self,
            from: data
           ) {
            return configuration
        }
        let configuration = VAPID.Configuration(
            key: VAPID.Key(),
            contactInformation: .email(contactEmail)
        )
        let data = try JSONEncoder().encode(configuration)
        try storeKeychainData(data)
        return configuration
    }

    private static func keychainData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
        else { return nil }
        return result as? Data
    }

    private static func storeKeychainData(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status: OSStatus
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(
                query as CFDictionary,
                attributes as CFDictionary
            )
        } else {
            var item = query
            for (key, value) in attributes { item[key] = value }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
