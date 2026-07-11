import Foundation
import CryptoKit
import Security
import Darwin
import CopilotProjectsCore
import CopilotProjectsProtocol

struct APNsConfiguration: Sendable {
    static let keyIDKey = "remoteAccess.apnsKeyID"
    static let teamIDKey = "remoteAccess.apnsTeamID"
    static let topicKey = "remoteAccess.apnsTopic"
    static let keychainService = "com.obvioussean.copilot-projects.apns"
    static let keychainAccount = "provider-key"

    let keyID: String
    let teamID: String
    let topic: String
    let privateKeyPEM: String

    static func load(defaults: UserDefaults = .standard) -> APNsConfiguration? {
        guard let keyID = defaults.string(forKey: keyIDKey),
              let teamID = defaults.string(forKey: teamIDKey),
              let topic = defaults.string(forKey: topicKey),
              let data = keychainData(),
              let privateKey = String(data: data, encoding: .utf8),
              !keyID.isEmpty, !teamID.isEmpty, !topic.isEmpty else {
            return nil
        }
        return APNsConfiguration(
            keyID: keyID,
            teamID: teamID,
            topic: topic,
            privateKeyPEM: privateKey
        )
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
}

struct StoredAPNsDevice: Codable, Equatable, Sendable {
    let token: String
    let environment: APNsEnvironment
    let label: String?
    let createdAt: Date
}

final class APNsDeviceStore: @unchecked Sendable {
    private static let maximumDevices = 16
    private let lock = NSLock()
    private let url: URL
    private var devices: [StoredAPNsDevice]

    init(url: URL = Paths.stateDir.appendingPathComponent("apns-devices.json")) {
        self.url = url
        devices = Self.load(from: url)
    }

    func all() -> [StoredAPNsDevice] {
        lock.lock()
        defer { lock.unlock() }
        return devices
    }

    func add(_ registration: APNsRegistration) throws {
        let token = registration.token.lowercased()
        guard token.count >= 64,
              token.count <= 200,
              token.count.isMultiple(of: 2),
              token.allSatisfy(\.isHexDigit) else {
            throw APNsServiceError.invalidRegistration
        }
        lock.lock()
        defer { lock.unlock() }
        devices.removeAll {
            $0.token == token && $0.environment == registration.environment
        }
        devices.append(StoredAPNsDevice(
            token: token,
            environment: registration.environment,
            label: registration.label.map {
                String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            },
            createdAt: Date()
        ))
        if devices.count > Self.maximumDevices {
            devices.removeFirst(devices.count - Self.maximumDevices)
        }
        try persistLocked()
    }

    func remove(token: String, environment: APNsEnvironment) {
        lock.lock()
        defer { lock.unlock() }
        let count = devices.count
        devices.removeAll {
            $0.token == token.lowercased() && $0.environment == environment
        }
        if devices.count != count { try? persistLocked() }
    }

    private func persistLocked() throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(devices)
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString)"
        )
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw APNsServiceError.persistenceFailed
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw APNsServiceError.persistenceFailed
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw APNsServiceError.persistenceFailed
        }
    }

    private static func load(from url: URL) -> [StoredAPNsDevice] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([StoredAPNsDevice].self, from: data)) ?? []
    }
}

enum APNsServiceError: Error {
    case invalidRegistration
    case persistenceFailed
    case invalidPrivateKey
}

enum APNsDelivery: Sendable {
    case delivered
    case badDevice
    case providerTokenExpired
    case failed(String)
}

protocol APNsSending: Sendable {
    func send(
        payload: RemoteNotificationPayload,
        device: StoredAPNsDevice
    ) async -> APNsDelivery
}

actor APNsProvider: APNsSending {
    private let configuration: APNsConfiguration
    private let privateKey: P256.Signing.PrivateKey
    private let session: URLSession
    private var cachedToken: (value: String, createdAt: Date)?

    init(configuration: APNsConfiguration) throws {
        self.configuration = configuration
        do {
            privateKey = try P256.Signing.PrivateKey(
                pemRepresentation: configuration.privateKeyPEM
            )
        } catch {
            throw APNsServiceError.invalidPrivateKey
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
    }

    func send(
        payload: RemoteNotificationPayload,
        device: StoredAPNsDevice
    ) async -> APNsDelivery {
        await send(
            payload: payload,
            device: device,
            retryingProviderToken: false
        )
    }

    private func send(
        payload: RemoteNotificationPayload,
        device: StoredAPNsDevice,
        retryingProviderToken: Bool
    ) async -> APNsDelivery {
        let host = device.environment == .sandbox
            ? "api.sandbox.push.apple.com"
            : "api.push.apple.com"
        guard let url = URL(
            string: "https://\(host)/3/device/\(device.token)"
        ) else {
            return .badDevice
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        do {
            request.setValue(
                "bearer \(try providerToken())",
                forHTTPHeaderField: "authorization"
            )
        } catch {
            return .failed(error.localizedDescription)
        }
        request.setValue(configuration.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue(
            payload.id.uuidString,
            forHTTPHeaderField: "apns-collapse-id"
        )
        let sent = payload.sentAt.formatted(date: .omitted, time: .shortened)
        let title = Self.truncatedUTF8(payload.title, maximumBytes: 512)
        let body = Self.truncatedUTF8(
            "\(payload.body)\nSent at \(sent)",
            maximumBytes: 1_500
        )
        let aps: [String: Any] = [
            "alert": ["title": title, "body": body],
            "sound": "default",
            "thread-id": payload.sessionId ?? "copilot-projects",
        ]
        var object: [String: Any] = [
            "aps": aps,
            "id": payload.id.uuidString,
            "sentAt": ISO8601DateFormatter().string(from: payload.sentAt),
        ]
        if let kind = payload.kind?.rawValue { object["kind"] = kind }
        if let projectID = payload.projectId { object["projectId"] = projectID }
        if let sessionID = payload.sessionId { object["sessionId"] = sessionID }
        request.httpBody = try? JSONSerialization.data(withJSONObject: object)
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return .failed("Invalid APNs response")
            }
            if response.statusCode == 200 { return .delivered }
            let reason = (try? JSONSerialization.jsonObject(with: data))
                .flatMap { $0 as? [String: Any] }?["reason"] as? String
            if response.statusCode == 410
                || reason == "BadDeviceToken"
                || reason == "DeviceTokenNotForTopic" {
                return .badDevice
            }
            if response.statusCode == 403,
               reason == "ExpiredProviderToken",
               !retryingProviderToken {
                cachedToken = nil
                return await send(
                    payload: payload,
                    device: device,
                    retryingProviderToken: true
                )
            }
            return .failed(reason ?? "APNs \(response.statusCode)")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func providerToken(now: Date = Date()) throws -> String {
        if let cachedToken,
           now.timeIntervalSince(cachedToken.createdAt) < 45 * 60 {
            return cachedToken.value
        }
        let header: [String: Any] = [
            "alg": "ES256",
            "kid": configuration.keyID,
        ]
        let claims: [String: Any] = [
            "iss": configuration.teamID,
            "iat": Int(now.timeIntervalSince1970),
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header)
        let claimsData = try JSONSerialization.data(withJSONObject: claims)
        let input = "\(base64URL(headerData)).\(base64URL(claimsData))"
        let signature = try privateKey.signature(for: Data(input.utf8))
        let token = "\(input).\(base64URL(signature.rawRepresentation))"
        cachedToken = (token, now)
        return token
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func truncatedUTF8(
        _ value: String,
        maximumBytes: Int
    ) -> String {
        var result = ""
        var count = 0
        for character in value {
            let text = String(character)
            guard count + text.utf8.count <= maximumBytes else { break }
            result.append(character)
            count += text.utf8.count
        }
        return result
    }
}

final class APNsService: @unchecked Sendable {
    private let store: APNsDeviceStore
    private let provider: any APNsSending

    static func production(
        defaults: UserDefaults = .standard,
        store: APNsDeviceStore = APNsDeviceStore()
    ) throws -> APNsService? {
        guard let configuration = APNsConfiguration.load(defaults: defaults) else {
            return nil
        }
        return APNsService(
            store: store,
            provider: try APNsProvider(configuration: configuration)
        )
    }

    init(store: APNsDeviceStore, provider: any APNsSending) {
        self.store = store
        self.provider = provider
    }

    func register(data: Data) throws {
        guard data.count <= 4_096,
              let registration = try? JSONDecoder().decode(
                APNsRegistration.self,
                from: data
              ) else {
            throw APNsServiceError.invalidRegistration
        }
        try store.add(registration)
    }

    func unregister(data: Data) throws {
        guard data.count <= 4_096,
              let registration = try? JSONDecoder().decode(
                APNsRegistration.self,
                from: data
              ) else {
            throw APNsServiceError.invalidRegistration
        }
        store.remove(
            token: registration.token,
            environment: registration.environment
        )
    }

    func send(_ event: NotificationEvent) async {
        let payload = RemoteNotificationPayload(
            id: event.id,
            kind: event.kind,
            title: event.title,
            body: event.webBody,
            projectId: event.projectId,
            sessionId: event.sessionId,
            sentAt: event.sentAt
        )
        let provider = self.provider
        await withTaskGroup(of: (StoredAPNsDevice, APNsDelivery).self) { group in
            for device in store.all() {
                group.addTask {
                    (device, await provider.send(payload: payload, device: device))
                }
            }
            for await (device, result) in group {
                switch result {
                case .delivered:
                    break
                case .badDevice:
                    store.remove(
                        token: device.token,
                        environment: device.environment
                    )
                case .providerTokenExpired:
                    break
                case .failed(let message):
                    NSLog("copilot-projects: APNs failed: %@", message)
                }
            }
        }
    }
}

@MainActor
final class APNsNotificationPoster: NotificationPosting {
    private let service: APNsService

    init(service: APNsService) {
        self.service = service
    }

    func post(_ event: NotificationEvent) {
        let service = self.service
        Task.detached { await service.send(event) }
    }
}
