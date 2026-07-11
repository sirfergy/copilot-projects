import Foundation
import CopilotProjectsCore

enum RemoteAccessError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message
        }
    }
}

struct RemoteAccessConfiguration: Sendable {
    static let hostnameKey = "remoteAccess.hostname"
    static let teamDomainKey = "remoteAccess.cloudflareTeamDomain"
    static let audienceKey = "remoteAccess.cloudflareAudience"
    static let allowedEmailKey = "remoteAccess.allowedEmail"

    let hostname: String
    let localPort: Int
    let access: CloudflareAccessConfig

    var origin: String { "https://\(hostname)" }
    var url: String { "\(origin)/" }

    static func load(defaults: UserDefaults = .standard) -> RemoteAccessConfiguration? {
        func value(forKey key: String) -> String? {
            guard let raw = defaults.string(forKey: key) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let hostname = value(forKey: hostnameKey),
              let teamDomain = value(forKey: teamDomainKey),
              let audience = value(forKey: audienceKey),
              let allowedEmail = value(forKey: allowedEmailKey) else {
            return nil
        }
        let access = CloudflareAccessConfig(
            teamDomain: teamDomain,
            audTag: audience,
            allowedEmail: allowedEmail
        )
        guard access.certsURL != nil else { return nil }
        return RemoteAccessConfiguration(
            hostname: hostname,
            localPort: 49_272,
            access: access
        )
    }
}

@MainActor
final class RemoteAccessController {
    static let enabledKey = "remoteAccessEnabled"

    private let defaults: UserDefaults
    private let webPushService: WebPushService?
    private let apnsService: APNsService?
    private var gateway: RemoteGateway?
    private var verifier: CloudflareAccessVerifier?
    private var activeConfiguration: RemoteAccessConfiguration?
    private var enableTask: Task<Void, Never>?
    private var keyRefreshTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var operationGeneration = 0
    private(set) var url: String?
    private(set) var state = "disabled"

    init(
        defaults: UserDefaults = .standard,
        webPushService: WebPushService? = nil,
        apnsService: APNsService? = nil
    ) {
        self.defaults = defaults
        self.webPushService = webPushService
        self.apnsService = apnsService
    }

    var enabled: Bool {
        defaults.bool(forKey: Self.enabledKey)
    }

    func startIfEnabled(model: AppModel) {
        guard enabled else { return }
        guard let configuration = RemoteAccessConfiguration.load(defaults: defaults) else {
            defaults.set(false, forKey: Self.enabledKey)
            state = "not configured"
            return
        }
        enable(model: model, configuration: configuration)
    }

    func command(_ action: String, model: AppModel) -> ControlResponse {
        switch action {
        case "enable":
            guard let configuration = RemoteAccessConfiguration.load(defaults: defaults) else {
                defaults.set(false, forKey: Self.enabledKey)
                state = "not configured"
                return .failure(
                    "remote access is not configured; see README.md#remote-access"
                )
            }
            defaults.set(true, forKey: Self.enabledKey)
            enable(model: model, configuration: configuration)
            return .success("Remote access is enabling.")
        case "disable":
            defaults.set(false, forKey: Self.enabledKey)
            stopGateway()
            state = "disabled"
            return .success("Remote access is disabled.")
        case "status":
            let configuration = activeConfiguration
                ?? RemoteAccessConfiguration.load(defaults: defaults)
            let statusURL: String
            if let url {
                statusURL = url
            } else if enabled {
                statusURL = configuration?.url ?? "not configured"
            } else {
                statusURL = "disabled"
            }
            let localOrigin = configuration.map {
                "http://127.0.0.1:\($0.localPort)"
            } ?? "not configured"
            let authDescription = configuration.map {
                "Cloudflare Access (\($0.access.allowedEmail))"
            } ?? "not configured"
            return .success([
                "enabled: \(enabled)",
                "state: \(state)",
                "url: \(statusURL)",
                "origin: \(localOrigin)",
                "auth: \(authDescription)",
            ].joined(separator: "\n"))
        default:
            return .failure("usage: copilot-projects remote enable|disable|status")
        }
    }

    func stopGateway() {
        operationGeneration += 1
        enableTask?.cancel()
        enableTask = nil
        keyRefreshTask?.cancel()
        keyRefreshTask = nil
        verifier = nil
        activeConfiguration = nil
        let stoppedGateway = gateway
        gateway = nil
        url = nil
        if let stoppedGateway {
            queueShutdown(stoppedGateway)
        }
    }

    private func enable(model: AppModel, configuration: RemoteAccessConfiguration) {
        guard gateway == nil, enableTask == nil else { return }
        operationGeneration += 1
        let generation = operationGeneration
        state = "enabling"
        let verifier = CloudflareAccessVerifier(config: configuration.access)

        enableTask = Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            defer {
                if operationGeneration == generation {
                    enableTask = nil
                }
            }

            if let shutdownTask {
                await shutdownTask.value
            }
            guard shouldContinue(generation: generation) else { return }

            var retryDelay: UInt64 = 2
            while !(await verifier.refreshKeys()) {
                guard shouldContinue(generation: generation) else { return }
                state = "waiting for Cloudflare Access keys"
                do {
                    try await Task.sleep(nanoseconds: retryDelay * 1_000_000_000)
                } catch {
                    return
                }
                retryDelay = min(retryDelay * 2, 300)
            }
            guard shouldContinue(generation: generation) else { return }

            let gateway = RemoteGateway()
            let bridge = RemoteModelBridge(model: model)
            let webPushService = self.webPushService
            let apnsService = self.apnsService
            let startResult = await Task.detached {
                Result {
                    try gateway.start(
                        bridge: bridge,
                        expectedHost: configuration.hostname,
                        expectedOrigin: configuration.origin,
                        verifier: verifier,
                        port: configuration.localPort,
                        webPushService: webPushService,
                        apnsService: apnsService
                    )
                }
            }.value
            guard shouldContinue(generation: generation) else {
                queueShutdown(gateway)
                return
            }

            switch startResult {
            case .failure(let error):
                await gateway.stop()
                state = "error: \(error.localizedDescription)"
            case .success:
                self.gateway = gateway
                self.verifier = verifier
                activeConfiguration = configuration
                url = configuration.url
                state = "enabled"
                startKeyRefresh(for: verifier)
            }
        }
    }

    private func startKeyRefresh(for verifier: CloudflareAccessVerifier) {
        keyRefreshTask?.cancel()
        keyRefreshTask = Task.detached { [weak verifier] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 6 * 60 * 60 * 1_000_000_000)
                } catch {
                    return
                }
                guard let verifier else { return }
                _ = await verifier.refreshKeys()
            }
        }
    }

    private func shouldContinue(generation: Int) -> Bool {
        enabled && operationGeneration == generation && !Task.isCancelled
    }

    private func queueShutdown(_ gateway: RemoteGateway) {
        let priorShutdown = shutdownTask
        shutdownTask = Task.detached {
            if let priorShutdown {
                await priorShutdown.value
            }
            await gateway.stop()
        }
    }
}
