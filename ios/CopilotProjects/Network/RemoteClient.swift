import Foundation
import Observation
import UIKit
import CopilotProjectsProtocol

enum RemoteConnectionState: Equatable {
    case disconnected
    case authenticating
    case connecting
    case connected
    case reconnecting
    case error(String)
}

enum RemoteClientError: Error {
    case authenticationRequired
    case invalidResponse
    case rejected(Int)
}

private final class AccessRedirectDelegate:
    NSObject, URLSessionTaskDelegate, @unchecked Sendable
{
    private let expectedHost: String

    init(expectedHost: String) {
        self.expectedHost = expectedHost
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(
            request.url?.scheme?.lowercased() == "https"
                && request.url?.host?.lowercased() == expectedHost.lowercased()
                ? request : nil
        )
    }
}

@MainActor
@Observable
final class RemoteClient {
    static let baseURL = URL(string: "https://projects.thefergies.com")!
    private static let clientIDKey = "remoteClientID"

    let authentication: CloudflareSession
    private(set) var connectionState: RemoteConnectionState = .disconnected
    private(set) var workspace: RemoteWorkspaceSnapshot?
    private(set) var terminal = TerminalBuffer()
    private(set) var selectedProjectID: String?
    private(set) var selectedSessionID: String?
    private(set) var writable = false
    private(set) var isActive = true

    private let clientID: String
    private let requestSession: URLSession
    private let streamSession: URLSession
    private var streamTask: Task<Void, Never>?
    private var streamGeneration = 0
    private enum PendingAction {
        case input(String)
        case key(String)
    }

    private var pendingActions: [PendingAction] = []
    private var inputTask: Task<Void, Never>?
    private var acquiringSessionID: String?
    private var pendingScroll = 0
    private var scrollTask: Task<Void, Never>?
    private var pendingDeepLink: AppDeepLink?
    private var pendingAPNsRegistration: APNsRegistration?
    private var registeredAPNsRegistration: APNsRegistration?

    init(authentication: CloudflareSession) {
        self.authentication = authentication
        if let value = UserDefaults.standard.string(forKey: Self.clientIDKey) {
            clientID = value
        } else {
            let value = UUID().uuidString
            UserDefaults.standard.set(value, forKey: Self.clientIDKey)
            clientID = value
        }
        let delegate = AccessRedirectDelegate(
            expectedHost: Self.baseURL.host!
        )
        let requestConfiguration = URLSessionConfiguration.ephemeral
        requestConfiguration.timeoutIntervalForRequest = 30
        requestConfiguration.timeoutIntervalForResource = 60
        requestConfiguration.httpCookieStorage = nil
        requestConfiguration.httpShouldSetCookies = false
        requestSession = URLSession(
            configuration: requestConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
        let streamConfiguration = URLSessionConfiguration.ephemeral
        streamConfiguration.timeoutIntervalForRequest = 24 * 60 * 60
        streamConfiguration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        streamConfiguration.httpCookieStorage = nil
        streamConfiguration.httpShouldSetCookies = false
        streamSession = URLSession(
            configuration: streamConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active {
            start()
        } else {
            streamGeneration += 1
            streamTask?.cancel()
            streamTask = nil
            inputTask?.cancel()
            inputTask = nil
            scrollTask?.cancel()
            scrollTask = nil
            pendingScroll = 0
            pendingActions = []
            pendingScroll = 0
            connectionState = .disconnected
        }
    }

    func start() {
        guard isActive else { return }
        guard authentication.isAuthenticated else {
            connectionState = .authenticating
            authentication.needsLogin = true
            return
        }
        restartStream()
    }

    func select(projectID: String?, sessionID: String) {
        if selectedProjectID == projectID, selectedSessionID == sessionID {
            if !writable, acquiringSessionID == nil {
                acquire(sessionID: sessionID)
            }
            return
        }
        selectedProjectID = projectID
        selectedSessionID = sessionID
        writable = false
        pendingActions = []
        terminal.reset()
        restartStream()
        acquire(sessionID: sessionID)
    }

    private func acquire(sessionID: String) {
        acquiringSessionID = sessionID
        Task {
            let status = try? await postControl(
                RemoteClientMessage(
                    type: "acquire",
                    clientId: clientID,
                    sessionId: sessionID
                )
            )
            guard acquiringSessionID == sessionID else { return }
            acquiringSessionID = nil
            if selectedSessionID == sessionID, status == 204 {
                writable = true
            }
        }
    }

    func follow(_ deepLink: AppDeepLink) {
        guard let workspace else {
            pendingDeepLink = deepLink
            return
        }
        let session = workspace.projects
            .flatMap(\.sessions)
            .first { $0.id == deepLink.sessionId }
        if let session {
            let project = workspace.projects.first {
                $0.sessions.contains(where: { $0.id == session.id })
            }
            select(projectID: project?.id, sessionID: session.id)
        } else if let projectID = deepLink.projectId,
                  let project = workspace.projects.first(where: { $0.id == projectID }),
                  let sessionID = project.selectedSessionId ?? project.sessions.first?.id {
            select(projectID: project.id, sessionID: sessionID)
        }
    }

    func sendInput(_ value: String) {
        guard writable, !value.isEmpty else { return }
        enqueueInput(value)
    }

    func sendCommand(_ value: String) {
        guard writable, !value.isEmpty else { return }
        enqueueInput(value)
        pendingActions.append(.key("enter"))
        startInputFlush()
    }

    func sendKey(_ key: String) {
        guard writable else { return }
        pendingActions.append(.key(key))
        startInputFlush()
    }

    func sendScroll(_ delta: Int) {
        guard writable, terminal.mode == .terminal, delta != 0 else { return }
        pendingScroll += delta
        scheduleScrollFlush()
    }

    private func scheduleScrollFlush() {
        guard scrollTask == nil else { return }
        scrollTask = Task {
            defer { scrollTask = nil }
            while isActive, writable, pendingScroll != 0 {
                do {
                    try await Task.sleep(for: .milliseconds(40))
                } catch {
                    return
                }
                let value = max(-8, min(8, pendingScroll))
                pendingScroll -= value
                guard value != 0 else { return }
                _ = try? await postControl(RemoteClientMessage(
                    type: "scroll",
                    clientId: clientID,
                    sessionId: selectedSessionID,
                    delta: value
                ))
            }
        }
    }

    func registerAPNs(
        token: String,
        environment: CopilotProjectsProtocol.APNsEnvironment
    ) async throws {
        let registration = CopilotProjectsProtocol.APNsRegistration(
            token: token,
            environment: environment,
            label: UIDevice.current.name
        )
        pendingAPNsRegistration = registration
        try await attemptAPNsRegistration(registration)
    }

    private func attemptAPNsRegistration(
        _ registration: APNsRegistration
    ) async throws {
        guard registeredAPNsRegistration != registration else { return }
        let data = try JSONEncoder().encode(registration)
        let response = try await request(
            path: "/apns/subscribe",
            method: "POST",
            body: data
        )
        guard response.statusCode == 204 else {
            throw RemoteClientError.rejected(response.statusCode)
        }
        guard pendingAPNsRegistration == registration else { return }
        registeredAPNsRegistration = registration
        pendingAPNsRegistration = nil
    }

    private func restartStream() {
        streamGeneration += 1
        let generation = streamGeneration
        streamTask?.cancel()
        streamTask = Task { await streamLoop(generation: generation) }
    }

    private func streamLoop(generation: Int) async {
        var delay: UInt64 = 1
        while isActive, generation == streamGeneration {
            guard authentication.isAuthenticated else {
                connectionState = .authenticating
                authentication.needsLogin = true
                return
            }
            do {
                connectionState = delay == 1 ? .connecting : .reconnecting
                try await consumeStream()
                delay = 1
            } catch is CancellationError {
                return
            } catch RemoteClientError.authenticationRequired {
                authentication.markExpired()
                connectionState = .authenticating
                return
            } catch {
                connectionState = .reconnecting
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
            }
        }
    }

    private func consumeStream() async throws {
        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent("events"),
            resolvingAgainstBaseURL: false
        )!
        if let selectedSessionID {
            components.queryItems = [URLQueryItem(name: "s", value: selectedSessionID)]
        }
        var request = try authenticatedRequest(url: components.url!, method: "GET")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await streamSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteClientError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if [302, 401, 403].contains(http.statusCode) {
                throw RemoteClientError.authenticationRequired
            }
            throw RemoteClientError.rejected(http.statusCode)
        }
        connectionState = .connected
        if let pendingAPNsRegistration {
            Task { try? await attemptAPNsRegistration(pendingAPNsRegistration) }
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let data = Data(line.dropFirst(6).utf8)
            try handleEvent(data)
        }
    }

    private func handleEvent(_ data: Data) throws {
        struct Header: Decodable { let type: String }
        switch try JSONDecoder().decode(Header.self, from: data).type {
        case "workspace":
            workspace = try JSONDecoder().decode(
                RemoteServerMessage<RemoteWorkspaceSnapshot>.self,
                from: data
            ).data
            if selectedProjectID == nil {
                selectedProjectID = workspace?.selectedProjectId
            }
            if let pendingDeepLink {
                self.pendingDeepLink = nil
                follow(pendingDeepLink)
            }
        case "screen":
            let screen = try JSONDecoder().decode(
                RemoteServerMessage<RemoteTerminalScreen>.self,
                from: data
            ).data
            guard screen.sessionId == selectedSessionID else { return }
            terminal.apply(screen)
        default:
            break
        }
    }

    private func flushInput() async {
        defer { inputTask = nil }
        while isActive, writable, !pendingActions.isEmpty {
            let sessionID = selectedSessionID
            let action = pendingActions.removeFirst()
            do {
                let message: RemoteClientMessage
                switch action {
                case .input(let value):
                    message = RemoteClientMessage(
                        type: "input",
                        clientId: clientID,
                        sessionId: sessionID,
                        data: value
                    )
                case .key(let key):
                    message = RemoteClientMessage(
                        type: "key",
                        clientId: clientID,
                        sessionId: sessionID,
                        data: key
                    )
                }
                let status = try await postControl(message)
                if status == 403 {
                    writable = false
                    pendingActions = []
                    return
                }
            } catch {
                guard isActive, selectedSessionID == sessionID else { return }
                pendingActions.insert(action, at: 0)
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func enqueueInput(_ value: String) {
        if let last = pendingActions.last, case .input(let current) = last {
            pendingActions[pendingActions.count - 1] = .input(current + value)
        } else {
            pendingActions.append(.input(value))
        }
        startInputFlush()
    }

    private func startInputFlush() {
        guard inputTask == nil else { return }
        inputTask = Task { await flushInput() }
    }

    @discardableResult
    private func postControl(_ message: RemoteClientMessage) async throws -> Int {
        let data = try JSONEncoder().encode(message)
        let response = try await request(
            path: "/control",
            method: "POST",
            body: data
        )
        if [302, 401].contains(response.statusCode) {
            throw RemoteClientError.authenticationRequired
        }
        return response.statusCode
    }

    private func request(
        path: String,
        method: String,
        body: Data?
    ) async throws -> HTTPURLResponse {
        let url = Self.baseURL.appendingPathComponent(path)
        var request = try authenticatedRequest(url: url, method: method)
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await requestSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteClientError.invalidResponse
        }
        if [302, 401].contains(http.statusCode) {
            throw RemoteClientError.authenticationRequired
        }
        return http
    }

    private func authenticatedRequest(
        url: URL,
        method: String
    ) throws -> URLRequest {
        guard let cookie = authentication.cookieHeader else {
            throw RemoteClientError.authenticationRequired
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        if method != "GET" && method != "HEAD" {
            request.setValue(
                Self.baseURL.absoluteString,
                forHTTPHeaderField: "Origin"
            )
        }
        return request
    }
}
