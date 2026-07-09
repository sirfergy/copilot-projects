import Foundation
import Darwin
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

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

final class RemoteWriterLeases: @unchecked Sendable {
    private let lock = NSLock()
    private var holders: [String: UUID] = [:]

    func acquire(sessionId: String, connectionId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let holder = holders[sessionId], holder != connectionId { return false }
        holders = holders.filter { $0.value != connectionId || $0.key == sessionId }
        holders[sessionId] = connectionId
        return true
    }

    func holds(sessionId: String, connectionId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return holders[sessionId] == connectionId
    }

    func release(connectionId: UUID) {
        lock.lock()
        holders = holders.filter { $0.value != connectionId }
        lock.unlock()
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
                let http = RemoteHTTPHandler(auth: auth)
                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: 16 * 1_024,
                    shouldUpgrade: { channel, head in
                        guard auth.authorize(head: head, requireOrigin: true),
                              auth.normalizedPath(head.uri) == "/ws" else {
                            return channel.eventLoop.makeSucceededFuture(nil)
                        }
                        return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                    },
                    upgradePipelineHandler: { channel, _ in
                        channel.pipeline.addHandler(
                            RemoteWebSocketHandler(
                                bridge: bridge,
                                leases: leases
                            )
                        )
                    }
                )
                let upgrade = NIOHTTPServerUpgradeConfiguration(
                    upgraders: [upgrader],
                    completionHandler: { context in
                        context.pipeline.removeHandler(http, promise: nil)
                    }
                )
                return child.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: upgrade
                ).flatMap {
                    child.pipeline.addHandler(http)
                }
            }
        channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        guard let port = channel?.localAddress?.port else {
            throw RemoteAccessError.commandFailed("Remote gateway did not receive a port.")
        }
        return port
    }

    func stop() {
        try? channel?.close().wait()
        channel = nil
        try? group.syncShutdownGracefully()
    }
}

struct RemoteRequestAuth: Sendable {
    let expectedHost: String
    let expectedOrigin: String
    let allowedLogin: String
    let pathPrefix: String

    func authorize(head: HTTPRequestHead, requireOrigin: Bool) -> Bool {
        let host = head.headers.first(name: "Host")?.split(separator: ":").first.map(String.init)
        return authorize(
            host: host,
            login: head.headers.first(name: "Tailscale-User-Login"),
            origin: head.headers.first(name: "Origin"),
            requireOrigin: requireOrigin
        )
    }

    func authorize(
        host: String?,
        login: String?,
        origin: String?,
        requireOrigin: Bool
    ) -> Bool {
        guard login == allowedLogin, host == expectedHost else { return false }
        return !requireOrigin || origin == expectedOrigin
    }

    func normalizedPath(_ uri: String) -> String? {
        let path = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        if path == pathPrefix || path == "\(pathPrefix)/" { return "/" }
        if path.hasPrefix("\(pathPrefix)/") {
            return String(path.dropFirst(pathPrefix.count))
        }
        return nil
    }
}

private final class RemoteHTTPHandler:
    ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable
{
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let auth: RemoteRequestAuth
    private var head: HTTPRequestHead?

    init(auth: RemoteRequestAuth) {
        self.auth = auth
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
        case .body:
            break
        case .end:
            guard let head else { return }
            self.head = nil
            respond(context: context, head: head)
        }
    }

    private func respond(context: ChannelHandlerContext, head: HTTPRequestHead) {
        guard head.method == .GET || head.method == .HEAD,
              auth.authorize(head: head, requireOrigin: false),
              let path = auth.normalizedPath(head.uri) else {
            write(
                context: context,
                method: head.method,
                status: .forbidden,
                contentType: "text/plain",
                body: "Forbidden"
            )
            return
        }
        switch path {
        case "/":
            write(context: context, method: head.method, status: .ok,
                  contentType: "text/html; charset=utf-8", body: RemoteWebAssets.html)
        case "/app.css":
            write(context: context, method: head.method, status: .ok,
                  contentType: "text/css; charset=utf-8", body: RemoteWebAssets.css)
        case "/app.js":
            write(context: context, method: head.method, status: .ok,
                  contentType: "application/javascript; charset=utf-8",
                  body: RemoteWebAssets.javascript)
        default:
            write(context: context, method: head.method, status: .notFound,
                  contentType: "text/plain", body: "Not found")
        }
    }

    private func write(
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
        headers.add(
            name: "Content-Security-Policy",
            value: "default-src 'self'; connect-src 'self'; style-src 'self'; script-src 'self'"
        )
        let response = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(response)), promise: nil)
        if method != .HEAD {
            var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
            buffer.writeString(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

private final class RemoteWebSocketHandler:
    ChannelInboundHandler, @unchecked Sendable
{
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let id = UUID()
    private let bridge: RemoteModelBridge
    private let leases: RemoteWriterLeases
    private var selectedSessionId: String?
    private var refreshTask: RepeatedTask?
    private var lastWorkspace: RemoteWorkspaceSnapshot?
    private var lastScreen: RemoteTerminalScreen?

    init(bridge: RemoteModelBridge, leases: RemoteWriterLeases) {
        self.bridge = bridge
        self.leases = leases
    }

    func handlerAdded(context: ChannelHandlerContext) {
        refreshTask = context.eventLoop.scheduleRepeatedTask(
            initialDelay: .milliseconds(0),
            delay: .milliseconds(500)
        ) { [weak self, weak channel = context.channel] _ in
            guard let self, let channel else { return }
            let selectedSessionId = self.selectedSessionId
            Task { @MainActor in
                let workspace = self.bridge.workspace()
                let screen = selectedSessionId.flatMap {
                    self.bridge.screen(sessionId: $0)
                }
                channel.eventLoop.execute {
                    if workspace != self.lastWorkspace {
                        self.lastWorkspace = workspace
                        self.send(type: "workspace", value: workspace, channel: channel)
                    }
                    if screen != self.lastScreen, let screen {
                        self.lastScreen = screen
                        self.send(type: "screen", value: screen, channel: channel)
                    }
                }
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .connectionClose:
            context.close(promise: nil)
        case .ping:
            context.writeAndFlush(wrapOutboundOut(
                WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            ), promise: nil)
        case .text:
            var data = frame.unmaskedData
            guard let text = data.readString(length: data.readableBytes),
                  let messageData = text.data(using: .utf8),
                  let message = try? JSONDecoder().decode(
                    RemoteClientMessage.self,
                    from: messageData
                  ) else { return }
            handle(message: message, context: context)
        default:
            break
        }
    }

    private func handle(message: RemoteClientMessage, context: ChannelHandlerContext) {
        switch message.type {
        case "workspace":
            lastWorkspace = nil
        case "select":
            selectedSessionId = message.sessionId
            lastScreen = nil
        case "acquire":
            guard let sessionId = message.sessionId else { return }
            selectedSessionId = sessionId
            let writable = leases.acquire(sessionId: sessionId, connectionId: id)
            sendDictionary(
                ["writable": writable],
                type: "lease",
                channel: context.channel
            )
        case "input":
            guard let sessionId = message.sessionId,
                  let value = message.data,
                  value.utf8.count <= 8_192,
                  leases.holds(sessionId: sessionId, connectionId: id) else {
                return
            }
            Task { @MainActor in
                bridge.sendInput(sessionId: sessionId, value: value)
            }
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        refreshTask?.cancel()
        leases.release(connectionId: id)
        context.fireChannelInactive()
    }

    private func send<T: Codable>(type: String, value: T, channel: Channel) {
        let message = RemoteServerMessage(type: type, data: value)
        guard let data = try? JSONEncoder().encode(message),
              let string = String(data: data, encoding: .utf8) else { return }
        sendText(string, channel: channel)
    }

    private func sendDictionary(
        _ value: [String: Bool],
        type: String,
        channel: Channel
    ) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["type": type, "data": value]
        ), let string = String(data: data, encoding: .utf8) else { return }
        sendText(string, channel: channel)
    }

    private func sendText(_ string: String, channel: Channel) {
        var buffer = channel.allocator.buffer(capacity: string.utf8.count)
        buffer.writeString(string)
        channel.writeAndFlush(
            WebSocketFrame(fin: true, opcode: .text, data: buffer),
            promise: nil
        )
    }
}
