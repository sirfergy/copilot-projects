import Foundation
import Darwin
import NIOCore
import NIOPosix
import NIOHTTP1
import CopilotProjectsProtocol

fileprivate struct RemoteTerminalRevision: Equatable {
    let contentGeneration: UInt64
    let cols: Int
    let rows: Int
    let terminalScroll: Bool
}

@MainActor
final class RemoteModelBridge: @unchecked Sendable {
    private struct CachedScreen {
        let revision: RemoteTerminalRevision
        let afterLine: Int?
        let screen: RemoteTerminalScreen?
    }

    private weak var model: AppModel?
    private var cachedScreens: [String: CachedScreen] = [:]

    init(model: AppModel) {
        self.model = model
    }

    func workspace() -> RemoteWorkspaceSnapshot? {
        model?.remoteWorkspaceSnapshot()
    }

    fileprivate func screenRevision(sessionId: String) -> RemoteTerminalRevision? {
        guard let model,
              let view = model.controller(for: sessionId)?.terminalView,
              let terminal = view.terminal else { return nil }
        return RemoteTerminalRevision(
            contentGeneration: view.remoteContentGeneration,
            cols: terminal.cols,
            rows: terminal.rows,
            terminalScroll: terminal.isCurrentBufferAlternate
                || model.liveAgentSessions.contains(sessionId)
        )
    }

    fileprivate func screen(
        sessionId: String,
        revision: RemoteTerminalRevision,
        afterLine: Int?
    ) -> RemoteTerminalScreen? {
        guard let model else { return nil }
        if let cached = cachedScreens[sessionId],
           cached.revision == revision,
           cached.afterLine == afterLine {
            return cached.screen
        }
        let screen = model.remoteScreen(sessionId: sessionId, afterLine: afterLine)
        cachedScreens[sessionId] = CachedScreen(
            revision: revision,
            afterLine: afterLine,
            screen: screen
        )
        return screen
    }

    func sendInput(sessionId: String, value: String) {
        model?.sendRemoteInput(sessionId: sessionId, value: value)
    }

    func sendKey(sessionId: String, key: String) {
        model?.sendRemoteKey(sessionId: sessionId, key: key)
    }

    func sendScroll(sessionId: String, delta: Int) {
        model?.sendRemoteScroll(sessionId: sessionId, delta: delta)
    }
}

/// Writer leases ensure only one remote client injects input into a given
/// session at a time. This is single-user by design: `acquire` is a takeover,
/// so the most recently selected device wins and a vanished client can never
/// block another device from taking control.
final class RemoteWriterLeases: @unchecked Sendable {
    // Real sessions number in the dozens; the cap only bounds memory against a
    // buggy/hostile authenticated client POSTing many distinct session ids.
    private static let maxHolders = 512

    private let lock = NSLock()
    private var holders: [String: String] = [:]

    func acquire(sessionId: String, clientId: String) {
        lock.lock()
        if holders[sessionId] == nil, holders.count >= Self.maxHolders {
            holders.removeAll(keepingCapacity: true)
        }
        holders[sessionId] = clientId
        lock.unlock()
    }

    func holds(sessionId: String, clientId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return holders[sessionId] == clientId
    }
}

final class RemoteGateway: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?

    func start(
        bridge: RemoteModelBridge,
        expectedHost: String,
        expectedOrigin: String,
        verifier: CloudflareAccessVerifier,
        port: Int,
        webPushService: WebPushService? = nil,
        apnsService: APNsService? = nil,
        notificationSync: NotificationSyncService? = nil
    ) throws -> Int {
        if let boundPort = channel?.localAddress?.port { return boundPort }
        let auth = RemoteRequestAuth(
            expectedHost: expectedHost,
            expectedOrigin: expectedOrigin,
            verifier: verifier
        )
        let leases = RemoteWriterLeases()
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { child in
                do {
                    try Self.markCloseOnExec(child)
                } catch {
                    return child.eventLoop.makeFailedFuture(error)
                }
                return child.pipeline.configureHTTPServerPipeline().flatMap {
                    child.pipeline.addHandler(
                        RemoteHTTPHandler(
                            auth: auth,
                            bridge: bridge,
                            leases: leases,
                            webPushService: webPushService,
                            apnsService: apnsService,
                            notificationSync: notificationSync
                        )
                    )
                }
            }
        channel = try bootstrap.bind(host: "127.0.0.1", port: port).wait()
        if let channel {
            do {
                try channel.eventLoop.submit {
                    try Self.markCloseOnExec(channel)
                }.wait()
            } catch {
                try? channel.close().wait()
                self.channel = nil
                throw error
            }
        }
        guard let boundPort = channel?.localAddress?.port else {
            throw RemoteAccessError.commandFailed("Remote gateway did not receive a port.")
        }
        return boundPort
    }

    private static func markCloseOnExec(_ channel: Channel) throws {
        let marked: Void? = try channel.pipeline.syncOperations
            .withUnsafeTransportIfAvailable(of: CInt.self) { descriptor in
                let flags = fcntl(descriptor, F_GETFD)
                guard flags >= 0,
                      fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                    throw IOError(errnoCode: errno, reason: "fcntl(FD_CLOEXEC)")
                }
            }
        guard marked != nil else {
            throw RemoteAccessError.commandFailed(
                "Remote gateway socket handle was unavailable."
            )
        }
    }

    func stop() async {
        let closingChannel = channel
        channel = nil
        await withCheckedContinuation { continuation in
            let shutdown = {
                self.group.shutdownGracefully { _ in
                    continuation.resume()
                }
            }
            if let closingChannel {
                closingChannel.close().whenComplete { _ in shutdown() }
            } else {
                shutdown()
            }
        }
    }
}

enum RemoteOriginPolicy {
    /// Reject when Origin is present and does not match, but tolerate an absent
    /// one (browsers omit Origin on some same-origin GET/EventSource requests).
    case matchIfPresent
    /// Require an exact Origin match. Browsers always send Origin on POST.
    case requireMatch
}

struct RemoteRequestAuth: Sendable {
    let expectedHost: String
    let expectedOrigin: String
    let verifier: CloudflareAccessVerifier

    func authorize(head: HTTPRequestHead, originPolicy: RemoteOriginPolicy) -> Bool {
        authorizationExpiration(head: head, originPolicy: originPolicy) != nil
    }

    func authorizationExpiration(
        head: HTTPRequestHead,
        originPolicy: RemoteOriginPolicy
    ) -> Date? {
        let host = head.headers.first(name: "Host")?
            .split(separator: ":").first.map(String.init)
        return authorizationExpiration(
            host: host,
            token: head.headers.first(name: "Cf-Access-Jwt-Assertion"),
            origin: head.headers.first(name: "Origin"),
            originPolicy: originPolicy
        )
    }

    func authorize(
        host: String?,
        token: String?,
        origin: String?,
        originPolicy: RemoteOriginPolicy
    ) -> Bool {
        authorizationExpiration(
            host: host,
            token: token,
            origin: origin,
            originPolicy: originPolicy
        ) != nil
    }

    func authorizationExpiration(
        host: String?,
        token: String?,
        origin: String?,
        originPolicy: RemoteOriginPolicy
    ) -> Date? {
        guard host?.lowercased() == expectedHost.lowercased(),
              let token else {
            return nil
        }
        let originMatches = origin?.lowercased() == expectedOrigin.lowercased()
        switch originPolicy {
        case .requireMatch:
            guard originMatches else { return nil }
        case .matchIfPresent:
            guard origin == nil || originMatches else { return nil }
        }
        return verifier.verifiedExpiration(token: token)
    }

    func normalizedPath(_ uri: String) -> String? {
        let path = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        return path.hasPrefix("/") ? path : nil
    }

    static func queryItems(_ uri: String) -> [String: String] {
        guard let query = uri.split(separator: "?", maxSplits: 1).dropFirst().first else {
            return [:]
        }
        var items: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let value = parts.count > 1
                ? (String(parts[1]).removingPercentEncoding ?? String(parts[1]))
                : ""
            items[key] = value
        }
        return items
    }
}

private let remoteCSP =
    "default-src 'self'; connect-src 'self'; style-src 'self'; script-src 'self'; "
    + "worker-src 'self'; manifest-src 'self'; img-src 'self'; "
    + "frame-ancestors 'none'; base-uri 'none'"
private let remoteMaxBodyBytes = 16 * 1_024
private let remoteWorkspaceRefreshInterval: TimeInterval = 2

private final class RemoteHTTPHandler:
    ChannelInboundHandler, @unchecked Sendable
{
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let auth: RemoteRequestAuth
    private let bridge: RemoteModelBridge
    private let leases: RemoteWriterLeases
    private let webPushService: WebPushService?
    private let apnsService: APNsService?
    private let notificationSync: NotificationSyncService?

    private var head: HTTPRequestHead?
    private var body: [UInt8] = []
    private var bodyTooLarge = false

    // Event-stream state (set once the connection becomes an SSE stream).
    private var streaming = false
    private var streamSessionId: String?
    private var refreshTask: RepeatedTask?
    private var refreshInFlight = false
    private var lastWorkspaceRefreshAt = Date.distantPast
    private var lastWorkspace: RemoteWorkspaceSnapshot?
    private var lastScreenRevision: RemoteTerminalRevision?
    private var lastScreen: RemoteTerminalScreen?
    private var lastHistoryEndLine: Int?
    private var lastDismissalSnapshot: NotificationDismissalSnapshot?

    init(
        auth: RemoteRequestAuth,
        bridge: RemoteModelBridge,
        leases: RemoteWriterLeases,
        webPushService: WebPushService?,
        apnsService: APNsService?,
        notificationSync: NotificationSyncService?
    ) {
        self.auth = auth
        self.bridge = bridge
        self.leases = leases
        self.webPushService = webPushService
        self.apnsService = apnsService
        self.notificationSync = notificationSync
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body.removeAll(keepingCapacity: true)
            bodyTooLarge = false
        case .body(var buffer):
            if body.count + buffer.readableBytes > remoteMaxBodyBytes {
                bodyTooLarge = true
                return
            }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                body.append(contentsOf: bytes)
            }
        case .end:
            guard let head, !streaming else { return }
            self.head = nil
            route(context: context, head: head)
        }
    }

    private func route(context: ChannelHandlerContext, head: HTTPRequestHead) {
        guard head.method == .GET || head.method == .HEAD || head.method == .POST,
              let path = auth.normalizedPath(head.uri) else {
            respond(context: context, method: head.method, status: .forbidden,
                    contentType: "text/plain", body: "Forbidden")
            return
        }

        if head.method == .POST {
            guard auth.authorizationExpiration(
                    head: head,
                    originPolicy: .requireMatch
                  ) != nil else {
                respond(context: context, method: head.method, status: .forbidden,
                        contentType: "text/plain", body: "Forbidden")
                return
            }
            switch path {
            case "/control":
                handleControl(context: context)
            case "/push/subscribe":
                handlePushRegistration(context: context, subscribe: true)
            case "/push/unsubscribe":
                handlePushRegistration(context: context, subscribe: false)
            case "/apns/subscribe":
                handleAPNsRegistration(context: context, subscribe: true)
            case "/apns/unsubscribe":
                handleAPNsRegistration(context: context, subscribe: false)
            case "/\(NotificationSyncContract.dismissPath)":
                handleNotificationDismissal(context: context)
            default:
                respond(context: context, method: head.method, status: .notFound,
                        contentType: "text/plain", body: "Not found")
            }
            return
        }

        guard let authorizationExpiresAt = auth.authorizationExpiration(
            head: head,
            originPolicy: .matchIfPresent
        ) else {
            respond(context: context, method: head.method, status: .forbidden,
                    contentType: "text/plain", body: "Forbidden")
            return
        }

        switch path {
        case "/":
            respond(context: context, method: head.method, status: .ok,
                    contentType: "text/html; charset=utf-8", body: RemoteWebAssets.html)
        case "/app.css":
            respond(context: context, method: head.method, status: .ok,
                    contentType: "text/css; charset=utf-8", body: RemoteWebAssets.css)
        case "/app.js":
            respond(context: context, method: head.method, status: .ok,
                    contentType: "application/javascript; charset=utf-8",
                    body: RemoteWebAssets.javascript)
        case "/manifest.webmanifest":
            respond(context: context, method: head.method, status: .ok,
                     contentType: "application/manifest+json; charset=utf-8",
                     body: RemoteWebAssets.manifest)
        case "/sw.js":
            respond(context: context, method: head.method, status: .ok,
                     contentType: "application/javascript; charset=utf-8",
                     body: RemoteWebAssets.serviceWorker)
        case "/push/public-key":
            guard let publicKey = webPushService?.publicKey,
                  let data = try? JSONSerialization.data(
                     withJSONObject: ["applicationServerKey": publicKey]
                  ),
                  let body = String(data: data, encoding: .utf8) else {
                respond(context: context, method: head.method,
                         status: .serviceUnavailable,
                         contentType: "text/plain", body: "Push unavailable")
                return
            }
            respond(context: context, method: head.method, status: .ok,
                     contentType: "application/json", body: body)
        case "/push/status":
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let status = webPushService?.status(),
                  let data = try? encoder.encode(status),
                  let body = String(data: data, encoding: .utf8) else {
                respond(context: context, method: head.method,
                         status: .serviceUnavailable,
                         contentType: "text/plain", body: "Push unavailable")
                return
            }
            respond(context: context, method: head.method, status: .ok,
                     contentType: "application/json", body: body)
        case "/icon-192.png":
            let icon = RemoteWebAssets.iconPNG(size: 192)
            respondData(
                context: context,
                method: head.method,
                status: icon == nil ? .notFound : .ok,
                contentType: "image/png",
                body: icon ?? Data()
            )
        case "/icon-512.png":
            let icon = RemoteWebAssets.iconPNG(size: 512)
            respondData(
                context: context,
                method: head.method,
                status: icon == nil ? .notFound : .ok,
                contentType: "image/png",
                body: icon ?? Data()
            )
        case "/events":
            if head.method == .HEAD {
                respond(context: context, method: .HEAD, status: .ok,
                        contentType: "text/event-stream", body: "")
            } else {
                startEventStream(
                    context: context,
                    head: head,
                    authorizationExpiresAt: authorizationExpiresAt
                )
            }
        default:
            respond(context: context, method: head.method, status: .notFound,
                    contentType: "text/plain", body: "Not found")
        }
    }

    // MARK: - Control (POST)

    private func handlePushRegistration(
        context: ChannelHandlerContext,
        subscribe: Bool
    ) {
        guard !bodyTooLarge else {
            respond(context: context, method: .POST, status: .payloadTooLarge,
                    contentType: "text/plain", body: "too large")
            return
        }

        guard let webPushService else {
            respond(context: context, method: .POST, status: .serviceUnavailable,
                    contentType: "text/plain", body: "Push unavailable")
            return
        }
        do {
            if subscribe {
                try webPushService.register(data: Data(body))
            } else {
                try webPushService.unregister(data: Data(body))
            }
            respond(context: context, method: .POST, status: .noContent,
                    contentType: "text/plain", body: "")
        } catch WebPushServiceError.invalidSubscription {
            respond(context: context, method: .POST, status: .badRequest,
                    contentType: "text/plain", body: "Bad subscription")
        } catch {
            respond(context: context, method: .POST, status: .serviceUnavailable,
                    contentType: "text/plain", body: "Push unavailable")
        }
    }

    private func handleAPNsRegistration(
        context: ChannelHandlerContext,
        subscribe: Bool
    ) {
        guard !bodyTooLarge else {
            respond(context: context, method: .POST, status: .payloadTooLarge,
                    contentType: "text/plain", body: "too large")
            return
        }

        guard let apnsService else {
            respond(context: context, method: .POST, status: .serviceUnavailable,
                    contentType: "text/plain", body: "APNs unavailable")
            return
        }
        do {
            if subscribe {
                try apnsService.register(data: Data(body))
            } else {
                try apnsService.unregister(data: Data(body))
            }
            respond(context: context, method: .POST, status: .noContent,
                    contentType: "text/plain", body: "")
        } catch APNsServiceError.invalidRegistration {
            respond(context: context, method: .POST, status: .badRequest,
                    contentType: "text/plain", body: "Bad registration")
        } catch {
            respond(context: context, method: .POST, status: .serviceUnavailable,
                    contentType: "text/plain", body: "APNs unavailable")
        }
    }

    private func handleNotificationDismissal(context: ChannelHandlerContext) {
        guard !bodyTooLarge else {
            respond(context: context, method: .POST, status: .payloadTooLarge,
                    contentType: "text/plain", body: "too large")
            return
        }
        guard let notificationSync,
              let request = try? JSONDecoder().decode(
                NotificationDismissRequest.self,
                from: Data(body)
              ) else {
            respond(context: context, method: .POST, status: .badRequest,
                    contentType: "text/plain", body: "Bad request")
            return
        }
        notificationSync.dismiss(request)
        respond(context: context, method: .POST, status: .noContent,
                contentType: "text/plain", body: "")
    }

    private func handleControl(context: ChannelHandlerContext) {
        guard !bodyTooLarge else {
            respond(context: context, method: .POST, status: .payloadTooLarge,
                    contentType: "text/plain", body: "too large")
            return
        }
        guard let message = try? JSONDecoder().decode(
                RemoteClientMessage.self, from: Data(body)
              ),
              let clientId = message.clientId,
              let sessionId = message.sessionId,
              clientId.utf8.count <= 64,
              sessionId.utf8.count <= 64 else {
            respond(context: context, method: .POST, status: .badRequest,
                    contentType: "text/plain", body: "Bad request")
            return
        }
        switch message.type {
        case "acquire":
            leases.acquire(sessionId: sessionId, clientId: clientId)
            respond(context: context, method: .POST, status: .noContent,
                    contentType: "text/plain", body: "")
        case "input":
            guard let value = message.data else {
                respond(context: context, method: .POST, status: .badRequest,
                        contentType: "text/plain", body: "Bad request")
                return
            }
            guard value.utf8.count <= 8_192 else {
                respond(context: context, method: .POST, status: .payloadTooLarge,
                        contentType: "text/plain", body: "too large")
                return
            }
            guard leases.holds(sessionId: sessionId, clientId: clientId) else {
                respond(context: context, method: .POST, status: .forbidden,
                        contentType: "text/plain", body: "view only")
                return
            }
            let leases = self.leases
            Task { @MainActor in
                // Re-check under the lock right before injecting so a takeover
                // between the check above and this hop can't leak a keystroke.
                guard leases.holds(sessionId: sessionId, clientId: clientId) else { return }
                self.bridge.sendInput(sessionId: sessionId, value: value)
            }
            respond(context: context, method: .POST, status: .noContent,
                    contentType: "text/plain", body: "")
        case "key":
            guard let key = message.data,
                  ["enter", "escape", "backspace", "tab",
                   "up", "down", "left", "right"].contains(key) else {
                respond(context: context, method: .POST, status: .badRequest,
                        contentType: "text/plain", body: "Bad request")
                return
            }
            guard leases.holds(sessionId: sessionId, clientId: clientId) else {
                respond(context: context, method: .POST, status: .forbidden,
                        contentType: "text/plain", body: "view only")
                return
            }
            let leases = self.leases
            Task { @MainActor in
                guard leases.holds(sessionId: sessionId, clientId: clientId) else {
                    return
                }
                self.bridge.sendKey(sessionId: sessionId, key: key)
            }
            respond(context: context, method: .POST, status: .noContent,
                    contentType: "text/plain", body: "")
        case "scroll":
            guard let delta = message.delta,
                  delta != 0,
                  abs(delta) <= 20 else {
                respond(context: context, method: .POST, status: .badRequest,
                        contentType: "text/plain", body: "Bad request")
                return
            }
            guard leases.holds(sessionId: sessionId, clientId: clientId) else {
                respond(context: context, method: .POST, status: .forbidden,
                        contentType: "text/plain", body: "view only")
                return
            }
            let leases = self.leases
            Task { @MainActor in
                guard leases.holds(sessionId: sessionId, clientId: clientId) else {
                    return
                }
                self.bridge.sendScroll(sessionId: sessionId, delta: delta)
            }
            respond(context: context, method: .POST, status: .noContent,
                    contentType: "text/plain", body: "")
        default:
            respond(context: context, method: .POST, status: .badRequest,
                    contentType: "text/plain", body: "Bad request")
        }
    }

    // MARK: - Event stream (SSE)

    private func startEventStream(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        authorizationExpiresAt: Date
    ) {
        let query = RemoteRequestAuth.queryItems(head.uri)
        let sessionId = query["s"].flatMap {
            $0.isEmpty || $0.utf8.count > 64 ? nil : $0
        }
        streaming = true
        streamSessionId = sessionId

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-store")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "Transfer-Encoding", value: "chunked")
        headers.add(name: "Referrer-Policy", value: "no-referrer")
        headers.add(name: "Content-Security-Policy", value: remoteCSP)
        let response = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.writeAndFlush(wrapOutboundOut(.head(response)), promise: nil)
        writeChunk("retry: 3000\n\n", channel: context.channel)

        let channel = context.channel
        refreshTask = context.eventLoop.scheduleRepeatedTask(
            initialDelay: .milliseconds(0),
            delay: .milliseconds(500)
        ) { [weak self, weak channel] _ in
            guard let self, let channel else { return }
            let now = Date()
            guard now < authorizationExpiresAt else {
                channel.close(promise: nil)
                return
            }
            guard channel.isWritable, !self.refreshInFlight else { return }
            self.refreshInFlight = true
            let streamSessionId = self.streamSessionId
            let refreshWorkspace =
                now.timeIntervalSince(self.lastWorkspaceRefreshAt)
                >= remoteWorkspaceRefreshInterval
            let previousScreenRevision = self.lastScreenRevision
            let lastHistoryEndLine = self.lastHistoryEndLine
            let dismissalSnapshot = self.notificationSync?.dismissalSnapshot()
            Task { @MainActor in
                let workspace = refreshWorkspace ? self.bridge.workspace() : nil
                let screenRevision = streamSessionId.flatMap {
                    self.bridge.screenRevision(sessionId: $0)
                }
                let screen: RemoteTerminalScreen?
                if let streamSessionId, let screenRevision,
                   screenRevision != previousScreenRevision {
                    screen = self.bridge.screen(
                        sessionId: streamSessionId,
                        revision: screenRevision,
                        afterLine: screenRevision.terminalScroll
                            ? nil
                            : lastHistoryEndLine
                    )
                } else {
                    screen = nil
                }
                channel.eventLoop.execute {
                    self.refreshInFlight = false
                    guard Date() < authorizationExpiresAt else {
                        channel.close(promise: nil)
                        return
                    }
                    guard channel.isWritable else { return }
                    if workspace != nil {
                        self.lastWorkspaceRefreshAt = Date()
                    }
                    if let workspace, workspace != self.lastWorkspace {
                        self.lastWorkspace = workspace
                        guard self.emit(
                            type: "workspace",
                            value: workspace,
                            channel: channel,
                            authorizationExpiresAt: authorizationExpiresAt
                        ) else { return }
                    }
                    if let dismissalSnapshot,
                       dismissalSnapshot != self.lastDismissalSnapshot {
                        self.lastDismissalSnapshot = dismissalSnapshot
                        guard self.emit(
                            type: "dismissed-notifications",
                            value: dismissalSnapshot,
                            channel: channel,
                            authorizationExpiresAt: authorizationExpiresAt
                        ) else { return }
                    }
                    if screenRevision != self.lastScreenRevision {
                        self.lastScreenRevision = screenRevision
                        if let screen, screen != self.lastScreen {
                            self.lastScreen = screen
                            self.lastHistoryEndLine = screen.scrollMode == .history
                                ? screen.firstLine + screen.lines.count
                                : nil
                            guard self.emit(
                                type: "screen",
                                value: screen,
                                channel: channel,
                                authorizationExpiresAt: authorizationExpiresAt
                            ) else { return }
                        }
                    }
                }
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        refreshTask?.cancel()
        refreshTask = nil
        context.fireChannelInactive()
    }

    private func emit<T: Codable>(
        type: String,
        value: T,
        channel: Channel,
        authorizationExpiresAt: Date
    ) -> Bool {
        let message = RemoteServerMessage(type: type, data: value)
        guard let data = try? JSONEncoder().encode(message),
              let json = String(data: data, encoding: .utf8) else { return true }
        guard Date() < authorizationExpiresAt else {
            channel.close(promise: nil)
            return false
        }
        writeChunk("data: \(json)\n\n", channel: channel)
        return true
    }

    private func writeChunk(_ text: String, channel: Channel) {
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        channel.writeAndFlush(
            HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil
        )
    }

    // MARK: - Fixed-length responses

    private func respond(
        context: ChannelHandlerContext,
        method: HTTPMethod,
        status: HTTPResponseStatus,
        contentType: String,
        body: String
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: String(body.utf8.count))
        headers.add(name: "Cache-Control", value: "no-store")
        headers.add(name: "Referrer-Policy", value: "no-referrer")
        headers.add(name: "Content-Security-Policy", value: remoteCSP)
        let response = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(response)), promise: nil)
        if method != .HEAD && !body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
            buffer.writeString(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func respondData(
        context: ChannelHandlerContext,
        method: HTTPMethod,
        status: HTTPResponseStatus,
        contentType: String,
        body: Data
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: String(body.count))
        headers.add(name: "Cache-Control", value: "no-store")
        headers.add(name: "Referrer-Policy", value: "no-referrer")
        headers.add(name: "Content-Security-Policy", value: remoteCSP)
        let response = HTTPResponseHead(
            version: .http1_1,
            status: status,
            headers: headers
        )
        context.write(wrapOutboundOut(.head(response)), promise: nil)
        if method != .HEAD && !body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
