import Foundation
import CopilotProjectsCore

enum RemoteAccessError: LocalizedError {
    case accessKeysUnavailable
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessKeysUnavailable:
            return "Cloudflare Access signing keys could not be loaded."
        case .commandFailed(let message):
            return message
        }
    }
}

struct RemoteAccessConfiguration: Sendable {
    static let current = RemoteAccessConfiguration(
        hostname: "projects.thefergies.com",
        localPort: 49_271,
        access: CloudflareAccessConfig(
            teamDomain: "thefergies.cloudflareaccess.com",
            audTag: "152bdb4d5f24935c5fde31e7ae219084cd7b608fa9f5dc44d5c967928918d0a8",
            allowedEmail: "obvioussean@github.com"
        )
    )

    let hostname: String
    let localPort: Int
    let access: CloudflareAccessConfig

    var origin: String { "https://\(hostname)" }
    var url: String { "\(origin)/" }
}

@MainActor
final class RemoteAccessController {
    static let enabledKey = "remoteAccessEnabled"

    private let configuration = RemoteAccessConfiguration.current
    private var gateway: RemoteGateway?
    private var verifier: CloudflareAccessVerifier?
    private var enableTask: Task<Void, Never>?
    private var keyRefreshTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var operationGeneration = 0
    private(set) var url: String?
    private(set) var state = "disabled"

    var enabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func startIfEnabled(model: AppModel) {
        guard enabled else { return }
        enable(model: model)
    }

    func command(_ action: String, model: AppModel) -> ControlResponse {
        switch action {
        case "enable":
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            enable(model: model)
            return .success("Remote access is enabling.")
        case "disable":
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            stopGateway()
            state = "disabled"
            return .success("Remote access is disabled.")
        case "status":
            return .success([
                "enabled: \(enabled)",
                "state: \(state)",
                "url: \(url ?? configuration.url)",
                "origin: http://127.0.0.1:\(configuration.localPort)",
                "auth: Cloudflare Access (\(configuration.access.allowedEmail))",
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
        let stoppedGateway = gateway
        gateway = nil
        url = nil
        if let stoppedGateway {
            queueShutdown(stoppedGateway)
        }
    }

    private func enable(model: AppModel) {
        guard gateway == nil, enableTask == nil else { return }
        operationGeneration += 1
        let generation = operationGeneration
        state = "enabling"
        let configuration = self.configuration
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
            let startResult = await Task.detached {
                Result {
                    try gateway.start(
                        bridge: bridge,
                        expectedHost: configuration.hostname,
                        expectedOrigin: configuration.origin,
                        verifier: verifier,
                        port: configuration.localPort
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
