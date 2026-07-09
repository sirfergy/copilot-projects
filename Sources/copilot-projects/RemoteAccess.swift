import Foundation
import CopilotProjectsCore
import Darwin

enum RemoteAccessError: LocalizedError {
    case tailscaleNotFound
    case tailscaleNotRunning
    case missingIdentity
    case conflictingServeConfig(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .tailscaleNotFound:
            return "Tailscale is not installed."
        case .tailscaleNotRunning:
            return "Tailscale is not connected."
        case .missingIdentity:
            return "Tailscale did not report a DNS name and user identity."
        case .conflictingServeConfig(let config):
            return "Tailscale Serve already has unrelated configuration:\n\(config)"
        case .commandFailed(let message):
            return message
        }
    }
}

private struct TailscaleStatus: Decodable {
    struct SelfNode: Decodable {
        let DNSName: String
        let UserID: Int64
    }

    struct User: Decodable {
        let LoginName: String
    }

    let BackendState: String
    let SelfNode: SelfNode
    let User: [String: User]

    private enum CodingKeys: String, CodingKey {
        case BackendState
        case SelfNode = "Self"
        case User
    }
}

private struct TailscaleServe: Sendable {
    static let httpsPort = 8_443

    let executable: String

    static func detect() throws -> TailscaleServe {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ]
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw RemoteAccessError.tailscaleNotFound
        }
        return TailscaleServe(executable: executable)
    }

    func identity() throws -> (host: String, login: String) {
        let output = try run(["status", "--json"])
        let status = try JSONDecoder().decode(TailscaleStatus.self, from: Data(output.utf8))
        guard status.BackendState == "Running" else {
            throw RemoteAccessError.tailscaleNotRunning
        }
        let host = status.SelfNode.DNSName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty,
              let login = status.User[String(status.SelfNode.UserID)]?.LoginName,
              !login.isEmpty else {
            throw RemoteAccessError.missingIdentity
        }
        return (host, login)
    }

    func enable(port: Int, path: String) throws {
        let existing = (try? run(["serve", "status"])) ?? ""
        for line in existing.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { continue }
            let oldPath = String(fields[1])
            guard oldPath.hasPrefix("/copilot-projects") else { continue }
            _ = try? run([
                "serve", "--bg", "--yes",
                "--set-path=\(oldPath)",
                "off",
            ])
        }
        _ = try run([
            "serve", "--bg", "--yes",
            "--https=\(Self.httpsPort)",
            "127.0.0.1:\(port)",
        ])
    }

    func disable(path: String) throws {
        let existing = (try? run(["serve", "status"])) ?? ""
        guard existing.contains(":\(Self.httpsPort)") else { return }
        _ = try run([
            "serve", "--bg", "--yes",
            "--https=\(Self.httpsPort)",
            "off",
        ])
    }

    func serveStatus() -> String {
        (try? run(["serve", "status"])) ?? "unavailable"
    }

    private func run(_ arguments: [String]) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-projects-tailscale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        if completed.wait(timeout: .now() + 15) == .timedOut {
            process.terminate()
            _ = completed.wait(timeout: .now() + 2)
            throw RemoteAccessError.commandFailed(
                "Tailscale command timed out: \(arguments.joined(separator: " "))"
            )
        }
        try stdout.synchronize()
        try stderr.synchronize()
        let output = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let error = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            throw RemoteAccessError.commandFailed(
                [output, error].filter { !$0.isEmpty }.joined(separator: "\n")
            )
        }
        return output
    }
}

@MainActor
final class RemoteAccessController {
    static let enabledKey = "remoteAccessEnabled"
    static let routeTokenKey = "remoteAccessRouteToken"

    private var gateway: RemoteGateway?
    private(set) var url: String?
    private(set) var state = "disabled"

    var enabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func startIfEnabled(model: AppModel) {
        guard enabled else { return }
        enable(model: model)
    }

    func command(_ action: String, model: AppModel) -> String {
        switch action {
        case "enable":
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            enable(model: model)
            return "Remote access is enabling."
        case "disable":
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            stopGateway()
            state = "disabling"
            let path = routePath
            Task.detached {
                try? TailscaleServe.detect().disable(path: path)
                await MainActor.run { self.state = "disabled" }
            }
            return "Remote access is disabling."
        case "status":
            return [
                "enabled: \(enabled)",
                "state: \(state)",
                "url: \(url ?? "(not running)")",
            ].joined(separator: "\n")
        default:
            return "usage: copilot-projects remote enable|disable|status"
        }
    }

    func stopGateway() {
        let stoppedGateway = gateway
        gateway = nil
        url = nil
        if let stoppedGateway {
            Task.detached { stoppedGateway.stop() }
        }
    }

    private func enable(model: AppModel) {
        guard gateway == nil, state != "enabling" else { return }
        state = "enabling"
        Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            let result = await Task.detached {
                Result { () -> (TailscaleServe, host: String, login: String) in
                    let tailscale = try TailscaleServe.detect()
                    let identity = try tailscale.identity()
                    return (tailscale, identity.host, identity.login)
                }
            }.value
            switch result {
            case .failure(let error):
                state = "error: \(error.localizedDescription)"
            case .success(let value):
                let gateway = RemoteGateway()
                let bridge = RemoteModelBridge(model: model)
                do {
                    let path = routePath
                    let origin = "https://\(value.host):\(TailscaleServe.httpsPort)"
                    let startResult = await Task.detached {
                        Result {
                            try gateway.start(
                                bridge: bridge,
                                expectedHost: value.host,
                                expectedOrigin: origin,
                                allowedLogin: value.login,
                                pathPrefix: path
                            )
                        }
                    }.value
                    let port = try startResult.get()
                    self.gateway = gateway
                    url = "\(origin)\(path)/"
                    let serveResult = await Task.detached {
                        Result { try value.0.enable(port: port, path: path) }
                    }.value
                    if case .failure(let error) = serveResult {
                        stopGateway()
                        state = "error: \(error.localizedDescription)"
                    } else {
                        state = "enabled"
                    }
                } catch {
                    await Task.detached { gateway.stop() }.value
                    state = "error: \(error.localizedDescription)"
                }
            }
        }
    }

    private var routePath: String {
        if let value = UserDefaults.standard.string(forKey: Self.routeTokenKey),
           !value.isEmpty {
            return "/copilot-projects-\(value)"
        }
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(value, forKey: Self.routeTokenKey)
        return "/copilot-projects-\(value)"
    }
}
