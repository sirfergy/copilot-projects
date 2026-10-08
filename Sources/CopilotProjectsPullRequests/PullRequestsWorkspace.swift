import AppKit
import Foundation
import CopilotProjectsCore

/// What the Pull Requests app knows about the Copilot Projects workspace.
enum WorkspaceState: Equatable, Sendable {
    /// Before Copilot Projects first answers.
    case connecting
    case connected(WorkspaceSnapshot)
    /// Copilot Projects isn't answering. Its last snapshot, if it ever sent one,
    /// still groups pull requests, but session states are unknown.
    case disconnected(lastGood: WorkspaceSnapshot?)
    /// Copilot Projects answers but can't list its sessions: it is older than this app.
    case incompatibleHost
}

enum WorkspaceFetch: Equatable, Sendable {
    case snapshot(WorkspaceSnapshot)
    case unreachable
    case incompatibleHost
}

/// How Copilot Projects answered a command.
enum WorkspaceCommandResult: Equatable, Sendable {
    case done(code: String?, text: String?)
    case refused(code: String?, message: String)
    case unreachable
    case incompatibleHost
}

/// The workspace the Pull Requests app reads sessions from and acts on.
protocol PullRequestsWorkspace: Sendable {
    func snapshot() async -> WorkspaceFetch
    /// Selects a session in the workspace window without activating the app.
    func revealSession(projectId: String?, sessionId: String) async -> WorkspaceCommandResult
    /// Starts a Copilot session with `prompt`; replaying `requestId` never starts a second one.
    func startCopilotSession(projectId: String, requestId: UUID, prompt: String) async -> WorkspaceCommandResult
}

/// Copilot Projects over its control socket. Each request runs on a dispatch
/// thread, never on the main actor, and the client's timeout bounds it.
actor ControlWorkspaceBridge: PullRequestsWorkspace {
    let socketPath: String
    let timeout: TimeInterval

    init(socketPath: String = Paths.socketPath, timeout: TimeInterval = 3) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    func snapshot() async -> WorkspaceFetch {
        guard case .success(let response) = await send(ControlRequest(command: "list-sessions")) else {
            return .unreachable
        }
        if Self.isUnknownCommand(response) { return .incompatibleHost }
        guard response.ok else { return .unreachable }
        guard let text = response.text,
              let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(text.utf8)),
              snapshot.version >= 1 else { return .incompatibleHost }
        return .snapshot(snapshot)
    }

    func revealSession(projectId: String?, sessionId: String) async -> WorkspaceCommandResult {
        var request = ControlRequest(command: "reveal-session")
        request.projectId = projectId
        request.sessionId = sessionId
        return Self.result(await send(request))
    }

    func startCopilotSession(projectId: String, requestId: UUID, prompt: String) async -> WorkspaceCommandResult {
        var request = ControlRequest(command: "start-copilot-session")
        request.projectId = projectId
        request.requestId = requestId.uuidString
        request.prompt = prompt
        return Self.result(await send(request))
    }

    /// Older versions of Copilot Projects answer commands they don't know this way.
    static func isUnknownCommand(_ response: ControlResponse) -> Bool {
        !response.ok && (response.error ?? "").hasPrefix("unknown command:")
    }

    static func result(_ reply: Result<ControlResponse, Error>) -> WorkspaceCommandResult {
        guard case .success(let response) = reply else { return .unreachable }
        if isUnknownCommand(response) { return .incompatibleHost }
        return response.ok
            ? .done(code: response.code, text: response.text)
            : .refused(code: response.code, message: response.error ?? "Copilot Projects refused the request.")
    }

    private func send(_ request: ControlRequest) async -> Result<ControlResponse, Error> {
        let client = ControlClient(socketPath: socketPath, timeout: timeout)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Result { try client.send(request) })
            }
        }
    }
}

/// Copilot Projects the app: bringing it forward and opening it.
struct PullRequestsHostApp {
    /// Brings the host forward, yielding this app's activation to it. Only works
    /// while this app is active, right after the user acted in it.
    var activate: @MainActor (_ processIdentifier: Int32) -> Void
    /// Opens Copilot Projects; nil when this copy isn't inside it.
    var open: (@MainActor () -> Void)?

    static let none = PullRequestsHostApp(activate: { _ in }, open: nil)

    /// The Copilot Projects.app this copy is bundled in.
    static func system(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PullRequestsHostApp {
        let hostURL = AppDeepLink.parentApplicationURL(forHelperBundleURL: bundle.bundleURL)
        return PullRequestsHostApp(
            activate: { processIdentifier in
                guard let host = NSRunningApplication(processIdentifier: processIdentifier) else { return }
                if !host.activate(from: .current, options: []) {
                    NSLog("copilot-pull-requests: Copilot Projects declined activation")
                }
            },
            open: hostURL.map { url in
                {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    configuration.allowsRunningApplicationSubstitution = false
                    configuration.createsNewApplicationInstance = PullRequestsAppBundle.isIsolated(environment)
                    configuration.environment = PullRequestsAppBundle.forwardedEnvironment(environment)
                    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                        if let error { NSLog("copilot-pull-requests: could not open Copilot Projects: \(error)") }
                    }
                }
            }
        )
    }
}
