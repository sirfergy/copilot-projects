import Foundation
import Darwin
import NIOCore
import NIOPosix
import NIOHTTP1

@MainActor
final class RemoteModelBridge {
    private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func workspace() -> RemoteWorkspaceSnapshot {
        model.remoteWorkspaceSnapshot()
    }

    func screen(sessionId: String) -> RemoteTerminalScreen? {
        model.remoteScreen(sessionId: sessionId)
    }

    func sendInput(sessionId: String, value: String) {
        model.sendRemoteInput(sessionId: sessionId, value: value)
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
        allowedLogin: String,
        pathPrefix: String
    ) throws -> Int {
        if let port = channel?.localAddress?.port { return port }
        let auth = RemoteRequestAuth(
            expectedHost: expectedHost,
            expectedOrigin: expectedOrigin,
            allowedLogin: allowedLogin,
            pathPrefix: pathPrefix
        )
        let leases = RemoteWriterLeases()
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { child in
                child.pipeline.configureHTTPServerPipeline().flatMap {
                    child.pipeline.addHandler(
                        RemoteHTTPHandler(auth: auth, bridge: bridge, leases: leases)
                    )
                }
            }
        channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        guard let port = channel?.localAddress?.port else {
            throw RemoteAccessError.commandFailed("Remote gateway did not receive a port.")
        }
        return port
    }

    func stop() {
        channel?.close(promise: nil)
        channel = nil
        group.shutdownGracefully { _ in }
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
    let allowedLogin: String
    let pathPrefix: String

    func authorize(head: HTTPRequestHead, originPolicy: RemoteOriginPolicy) -> Bool {
        let host = head.headers.first(name: "Host")?
            .split(separator: ":").first.map(String.init)
        return authorize(
            host: host,
            login: head.headers.first(name: "Tailscale-User-Login"),
            origin: head.headers.first(name: "Origin"),
            originPolicy: originPolicy
        )
    }

    func authorize(
        host: String?,
        login: String?,
        origin: String?,
        originPolicy: RemoteOriginPolicy
    ) -> Bool {
        guard login == allowedLogin, host == expectedHost else { return false }
        switch originPolicy {
        case .requireMatch:
            return origin == expectedOrigin
        case .matchIfPresent:
            return origin == nil || origin == expectedOrigin
        }
    }

    func normalizedPath(_ uri: String) -> String? {
        let path = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        if path == pathPrefix || path == "\(pathPrefix)/" { return "/" }
        if path.hasPrefix("\(pathPrefix)/") {
            return String(path.dropFirst(pathPrefix.count))
        }
        return nil
    }

    /// When the token root is requested without a trailing slash, returns the
    /// path to redirect to (with the slash) so relative asset URLs resolve under
    /// the token prefix. Returns nil for every other path.
    func trailingSlashRedirect(_ uri: String) -> String? {
        let path = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        return path == pathPrefix ? "\(pathPrefix)/" : nil
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
    "default-src 'self'; connect-src 'self'; style-src 'self'; script-src 'self'"
private let remoteMaxBodyBytes = 16 * 1_024

private final class RemoteHTTPHandler:
    ChannelInboundHandler, @unchecked Sendable
{
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let auth: RemoteRequestAuth
    private let bridge: RemoteModelBridge
    private let leases: RemoteWriterLeases

    private var head: HTTPRequestHead?
    private var body: [UInt8] = []
    private var bodyTooLarge = false

    // Event-stream state (set once the connection becomes an SSE stream).
    private var streaming = false
    private var streamSessionId: String?
    private var refreshTask: RepeatedTask?
    private var lastWorkspace: RemoteWorkspaceSnapshot?
    private var lastScreen: RemoteTerminalScreen?

    init(auth: RemoteRequestAuth, bridge: RemoteModelBridge, leases: RemoteWriterLeases) {
        self.auth = auth
        self.bridge = bridge
        self.leases = leases
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
            guard path == "/control",
                  auth.authorize(head: head, originPolicy: .requireMatch) else {
                respond(context: context, method: head.method, status: .forbidden,
                        contentType: "text/plain", body: "Forbidden")
                return
            }
            handleControl(context: context)
            return
        }

        guard auth.authorize(head: head, originPolicy: .matchIfPresent) else {
            respond(context: context, method: head.method, status: .forbidden,
                    contentType: "text/plain", body: "Forbidden")
            return
        }

        // Redirect the bare token root to a trailing slash so relative asset
        // URLs (app.css/app.js) resolve under the token prefix instead of
        // resolving to the parent path and 403ing.
        if let target = auth.trailingSlashRedirect(head.uri) {
            redirect(context: context, method: head.method, to: target)
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
        case "/events":
            if head.method == .HEAD {
                respond(context: context, method: .HEAD, status: .ok,
                        contentType: "text/event-stream", body: "")
            } else {
                startEventStream(context: context, head: head)
            }
        default:
            respond(context: context, method: head.method, status: .notFound,
                    contentType: "text/plain", body: "Not found")
        }
    }

    // MARK: - Control (POST)

    private func handleControl(context: ChannelHandlerContext) {
        guard !bodyTooLarge,
              let message = try? JSONDecoder().decode(
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
        default:
            respond(context: context, method: .POST, status: .badRequest,
                    contentType: "text/plain", body: "Bad request")
        }
    }

    // MARK: - Event stream (SSE)

    private func startEventStream(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let query = RemoteRequestAuth.queryItems(head.uri)
        let sessionId = query["s"].flatMap { $0.isEmpty ? nil : $0 }
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
            guard channel.isWritable else { return }
            let streamSessionId = self.streamSessionId
            Task { @MainActor in
                let workspace = self.bridge.workspace()
                let screen = streamSessionId.flatMap { self.bridge.screen(sessionId: $0) }
                channel.eventLoop.execute {
                    guard channel.isWritable else { return }
                    if workspace != self.lastWorkspace {
                        self.lastWorkspace = workspace
                        self.emit(type: "workspace", value: workspace, channel: channel)
                    }
                    if let screen, screen != self.lastScreen {
                        self.lastScreen = screen
                        self.emit(type: "screen", value: screen, channel: channel)
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

    private func emit<T: Codable>(type: String, value: T, channel: Channel) {
        let message = RemoteServerMessage(type: type, data: value)
        guard let data = try? JSONEncoder().encode(message),
              let json = String(data: data, encoding: .utf8) else { return }
        writeChunk("data: \(json)\n\n", channel: channel)
    }

    private func writeChunk(_ text: String, channel: Channel) {
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        channel.writeAndFlush(
            HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil
        )
    }

    // MARK: - Fixed-length responses

    private func redirect(
        context: ChannelHandlerContext,
        method: HTTPMethod,
        to location: String
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Location", value: location)
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Cache-Control", value: "no-store")
        headers.add(name: "Referrer-Policy", value: "no-referrer")
        let response = HTTPResponseHead(version: .http1_1, status: .found, headers: headers)
        context.write(wrapOutboundOut(.head(response)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

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
}
