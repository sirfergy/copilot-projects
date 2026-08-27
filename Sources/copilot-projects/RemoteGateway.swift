import Foundation
import Darwin
import CryptoKit
import NIOCore
import NIOPosix
import NIOHTTP1
import CopilotProjectsProtocol

struct RemoteTerminalRevision: Equatable, Sendable {
    let contentGeneration: UInt64
    /// The advertising session's own `RemoteKittyImageCapture.imageAvailabilityGeneration`
    /// at the moment this revision was computed. Bumped not only by that
    /// session's own capture activity but also whenever the process-wide
    /// `RemoteKittyImageCaptureBudget` reclaims one of *this* session's
    /// currently-advertised images to satisfy a different session's request —
    /// so a cached screen here is correctly invalidated by cross-session
    /// global eviction, even though nothing about this session's own terminal
    /// content changed. Without this, a stale cached screen could keep
    /// advertising a placement whose backing image the global budget already
    /// evicted, and a client fetching it would 404.
    let imageAvailabilityGeneration: UInt64
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

    func hasSession(_ sessionId: String) -> Bool {
        model?.projects.contains {
            $0.sessions.contains { $0.id == sessionId }
        } == true
    }

    /// Create (or idempotently resolve) a remote session. `.unavailable` when the
    /// model is gone so the gateway answers 503 rather than crashing.
    func createSession(_ request: RemoteCreateSessionRequest) -> RemoteSessionCreationOutcome {
        model?.createRemoteSession(request) ?? .unavailable
    }

    func createAdversarialReviewSession(
        _ request: RemoteCreateSessionRequest
    ) -> RemoteSessionCreationOutcome {
        model?.createRemoteAdversarialReviewSession(request) ?? .unavailable
    }

    func screenRevision(sessionId: String) -> RemoteTerminalRevision? {
        guard let model,
              let view = model.controller(for: sessionId)?.terminalView,
              !view.isRestoringImages,
              let terminal = view.terminal else { return nil }
        return RemoteTerminalRevision(
            contentGeneration: view.remoteContentGeneration,
            imageAvailabilityGeneration: view.kittyImageCapture.imageAvailabilityGeneration,
            cols: terminal.cols,
            rows: terminal.rows,
            terminalScroll: terminal.isCurrentBufferAlternate
                || model.liveAgentSessions.contains(sessionId)
        )
    }

    func screen(
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

    func sendCommand(
        sessionId: String,
        requestId: String,
        value: String
    ) -> RemoteCommandResult {
        model?.sendRemoteCommand(
            sessionId: sessionId,
            requestId: requestId,
            value: value
        ) ?? .invalid
    }

    func sendScroll(sessionId: String, delta: Int) {
        model?.sendRemoteScroll(sessionId: sessionId, delta: delta)
    }

    func markRead(sessionId: String) {
        model?.markSessionRead(sessionId: sessionId)
    }

    func closeSession(sessionId: String) -> Bool {
        model?.closeRemoteSession(sessionId: sessionId) ?? false
    }

    func moveSession(
        sessionId: String,
        toProjectId targetProjectId: String
    ) -> RemoteSessionMoveResult {
        model?.moveRemoteSession(
            sessionId: sessionId,
            toProjectId: targetProjectId
        ) ?? .missing
    }

    /// The transcript revision, folded together with the session's current
    /// image-availability generation so that capturing, displaying, evicting, or
    /// restoring an inline image (none of which touch the transcript file) still
    /// changes the revision and prompts clients to re-fetch `/transcript` — where
    /// the per-turn image associations are computed. Without this, conversation
    /// images would only refresh when the CLI happened to rewrite the transcript.
    func transcriptRevision(sessionId: String) -> RemoteTranscriptRevision {
        let base = TranscriptController.remoteRevision(sessionId: sessionId)
        guard let view = model?.controller(for: sessionId)?.terminalView else {
            return base
        }
        return RemoteTranscriptRevision(
            sessionId: base.sessionId,
            generation: "\(base.generation)#img\(view.kittyImageCapture.imageAvailabilityGeneration)"
        )
    }

    /// The currently-advertised inline images for `sessionId` paired with their
    /// display time, or `nil` if the session/view is gone. Read on the main
    /// actor (capture state is main-actor isolated); the caller joins this
    /// bounded metadata against the transcript turns off-actor.
    func retainedImageMetadata(sessionId: String) -> [RemoteKittyImageCapture.RetainedImageInfo]? {
        model?.controller(for: sessionId)?.terminalView.kittyImageCapture.retainedImageMetadata()
    }

    func sendPrompt(sessionId: String, value: String) -> RemotePromptResult {
        model?.sendRemotePrompt(sessionId: sessionId, value: value) ?? .invalid
    }

    func answerUserInput(
        sessionId: String,
        answer: RemoteUserInputAnswer
    ) -> RemoteUserInputResult {
        model?.answerUserInput(sessionId: sessionId, answer: answer) ?? .invalid
    }

    func answerElicitation(
        sessionId: String,
        answer: RemoteElicitationAnswer
    ) -> RemoteUserInputResult {
        model?.answerElicitation(sessionId: sessionId, answer: answer) ?? .invalid
    }

    func setModel(
        sessionId: String,
        selection: RemoteModelSelection
    ) -> RemoteUserInputResult {
        model?.setModel(sessionId: sessionId, selection: selection) ?? .invalid
    }

    /// The exact retained PNG bytes for `(imageId, version)` in `sessionId`'s
    /// terminal, or `nil` if the session, id, or exact version isn't (or is no
    /// longer) available.
    func terminalImageData(
        sessionId: String,
        imageId: UInt32,
        version: UInt64
    ) -> Data? {
        model?.controller(for: sessionId)?.terminalView.kittyImageCapture.imageData(
            imageId: imageId,
            version: version
        )
    }

    /// True while `sessionId`'s durable Kitty-image restore is still
    /// pending — used to answer an exact-image request with a retryable
    /// status instead of a definitive 404 (see `RemoteGateway
    /// .handleTerminalImage`), since a request for a version a client
    /// already knows about from before an app relaunch could otherwise
    /// briefly (and wrongly) look permanently gone until the restore
    /// finishes replaying it.
    func isRestoringImages(sessionId: String) -> Bool {
        model?.controller(for: sessionId)?.terminalView.isRestoringImages ?? false
    }
}

/// Writer leases ensure only one remote client injects input into a given
/// session at a time. This is single-user by design: `acquire` is a takeover,
/// so the most recently selected device wins and a vanished client can never
/// block another device from taking control.
final class RemoteWriterLeases: @unchecked Sendable {
    private struct PromptSubmission {
        let submittedAt: Date
        let expiresAt: Date
    }

    // Real sessions number in the dozens; the cap only bounds memory against a
    // buggy/hostile authenticated client POSTing many distinct session ids.
    private static let maxHolders = 512
    private static let promptSubmissionTimeout: TimeInterval = 5

    private let lock = NSLock()
    private var holders: [String: String] = [:]
    private var promptSubmissions: [String: PromptSubmission] = [:]

    func acquire(sessionId: String, clientId: String) {
        lock.lock()
        if holders[sessionId] == nil, holders.count >= Self.maxHolders {
            holders.removeAll(keepingCapacity: true)
            promptSubmissions.removeAll(keepingCapacity: true)
        }
        holders[sessionId] = clientId
        lock.unlock()
    }

    func holds(sessionId: String, clientId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return holders[sessionId] == clientId
    }

    func withHeldLease<Result>(
        sessionId: String,
        clientId: String,
        perform: () -> Result
    ) -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard holders[sessionId] == clientId else { return nil }
        return perform()
    }

    func submitPrompt(
        sessionId: String,
        clientId: String,
        now: Date = Date(),
        perform: () -> RemotePromptResult
    ) -> RemotePromptResult {
        lock.lock()
        defer { lock.unlock() }
        guard holders[sessionId] == clientId else { return .forbidden }
        if let submission = promptSubmissions[sessionId] {
            guard submission.expiresAt <= now else { return .busy }
            promptSubmissions[sessionId] = nil
        }
        let result = perform()
        if result == .sent {
            promptSubmissions[sessionId] = PromptSubmission(
                submittedAt: now,
                expiresAt: now.addingTimeInterval(Self.promptSubmissionTimeout)
            )
        }
        return result
    }

    func observePromptUnavailable(sessionId: String, observedAt: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard let submission = promptSubmissions[sessionId],
              submission.submittedAt <= observedAt else { return }
        promptSubmissions[sessionId] = nil
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
        notificationSync: NotificationSyncService? = nil,
        imageResponseBudget: RemoteImageResponseBudget = .shared
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
                            notificationSync: notificationSync,
                            imageResponseBudget: imageResponseBudget
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

enum RemoteIOSAuthentication {
    struct Request {
        let state: String
        let encodedClientPublicKey: String
        let clientPublicKey: Curve25519.KeyAgreement.PublicKey
    }

    static let path = "/auth/ios"
    static let callbackScheme = "copilot-projects"
    static let callbackHost = "auth"
    static let keyDerivationInfo = Data(
        "copilot-projects-ios-auth-v1".utf8
    )

    static func request(
        state: String?,
        encodedClientPublicKey: String?
    ) -> Request? {
        guard let state,
              UUID(uuidString: state) != nil,
              let encodedClientPublicKey,
              let clientPublicKeyData = base64URLDecode(
                encodedClientPublicKey
              ),
              clientPublicKeyData.count == 32,
              let clientPublicKey = try? Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: clientPublicKeyData
              ) else {
            return nil
        }
        return Request(
            state: state,
            encodedClientPublicKey: encodedClientPublicKey,
            clientPublicKey: clientPublicKey
        )
    }

    static func confirmationPage(for request: Request) -> String {
        """
        <!doctype html>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Continue to Copilot Projects</title>
        <main>
          <h1>Continue to Copilot Projects?</h1>
          <p>Your verified Cloudflare session will be returned securely to the app.</p>
          <form method="post" action="\(path)">
            <input type="hidden" name="state" value="\(request.state)">
            <input type="hidden" name="key" value="\(request.encodedClientPublicKey)">
            <button type="submit">Continue to Copilot Projects</button>
          </form>
        </main>
        """
    }

    static func callbackLocation(
        token: String,
        request: Request
    ) -> String? {
        guard token.utf8.count <= 16_384 else {
            return nil
        }

        let serverPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        guard let sharedSecret = try? serverPrivateKey.sharedSecretFromKeyAgreement(
            with: request.clientPublicKey
        ) else {
            return nil
        }
        let encryptionKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(request.state.utf8),
            sharedInfo: keyDerivationInfo,
            outputByteCount: 32
        )
        guard let sealed = try? ChaChaPoly.seal(
            Data(token.utf8),
            using: encryptionKey
        ) else {
            return nil
        }

        let serverPublicKey = base64URLEncode(
            serverPrivateKey.publicKey.rawRepresentation
        )
        let payload = base64URLEncode(sealed.combined)
        var components = URLComponents()
        components.scheme = callbackScheme
        components.host = callbackHost
        components.percentEncodedFragment =
            "state=\(request.state)&key=\(serverPublicKey)&payload=\(payload)"
        return components.string
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        guard string.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }) else {
            return nil
        }
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: 4 - padding)
        }
        return Data(base64Encoded: base64)
    }
}

private let remoteCSP =
    "default-src 'self'; connect-src 'self'; style-src 'self'; script-src 'self'; "
    + "worker-src 'self'; manifest-src 'self'; img-src 'self' blob:; "
    + "frame-ancestors 'none'; base-uri 'none'"
// Remote answers are nested JSON; an 8 KiB raw answer can expand substantially
// when control characters are escaped in the inner payload and outer envelope.
private let remoteMaxBodyBytes = 80 * 1_024
private let remoteMaxEncodedUserInputAnswerBytes = 64 * 1_024
private let remoteWorkspaceRefreshInterval: TimeInterval = 2

struct RemoteEventStreamOptions: Equatable {
    let sessionId: String?
    let streamsTerminal: Bool

    init(uri: String) {
        let query = RemoteRequestAuth.queryItems(uri)
        sessionId = query["s"].flatMap {
            $0.isEmpty || $0.utf8.count > 64 ? nil : $0
        }
        // Existing clients do not send this parameter, so only an explicit zero
        // opts out of terminal snapshots.
        streamsTerminal = query["terminal"] != "0"
    }
}

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
    private let imageResponseBudget: RemoteImageResponseBudget

    private var head: HTTPRequestHead?
    private var body: [UInt8] = []
    private var bodyTooLarge = false

    // Event-stream state (set once the connection becomes an SSE stream).
    private var streaming = false
    private var streamSessionId: String?
    private var streamsTerminal = true
    private var refreshTask: RepeatedTask?
    private var refreshInFlight = false
    private var lastWorkspaceRefreshAt = Date.distantPast
    private var lastWorkspace: RemoteWorkspaceSnapshot?
    private var lastScreenRevision: RemoteTerminalRevision?
    private var lastScreen: RemoteTerminalScreen?
    private var lastHistoryEndLine: Int?
    private var lastDismissalSnapshot: NotificationDismissalSnapshot?
    private var lastTranscriptRevision: RemoteTranscriptRevision?

    init(
        auth: RemoteRequestAuth,
        bridge: RemoteModelBridge,
        leases: RemoteWriterLeases,
        webPushService: WebPushService?,
        apnsService: APNsService?,
        notificationSync: NotificationSyncService?,
        imageResponseBudget: RemoteImageResponseBudget
    ) {
        self.auth = auth
        self.bridge = bridge
        self.leases = leases
        self.webPushService = webPushService
        self.apnsService = apnsService
        self.notificationSync = notificationSync
        self.imageResponseBudget = imageResponseBudget
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
            case "/\(RemoteSessionContract.createPath)":
                handleCreateSession(context: context, isReview: false)
            case "/\(RemoteSessionContract.reviewPath)":
                handleCreateSession(context: context, isReview: true)
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
            case RemoteIOSAuthentication.path:
                let form = String(bytes: body, encoding: .utf8)
                let parameters = form.map {
                    RemoteRequestAuth.queryItems("/?\($0)")
                }
                guard head.headers.first(name: "Content-Type")?
                        .lowercased()
                        .hasPrefix("application/x-www-form-urlencoded") == true,
                      !bodyTooLarge,
                      let parameters,
                      let request = RemoteIOSAuthentication.request(
                        state: parameters["state"],
                        encodedClientPublicKey: parameters["key"]
                      ),
                      let token = head.headers.first(
                        name: "Cf-Access-Jwt-Assertion"
                      ),
                      let location =
                        RemoteIOSAuthentication.callbackLocation(
                            token: token,
                            request: request
                        ) else {
                    respond(context: context, method: head.method,
                            status: .badRequest,
                            contentType: "text/plain", body: "Bad request")
                    return
                }
                redirect(context: context, location: location)
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
        case RemoteIOSAuthentication.path:
            guard head.method == .GET else {
                respond(context: context, method: head.method,
                        status: .methodNotAllowed,
                        contentType: "text/plain", body: "Method not allowed")
                return
            }
            let query = RemoteRequestAuth.queryItems(head.uri)
            guard let request = RemoteIOSAuthentication.request(
                    state: query["state"],
                    encodedClientPublicKey: query["key"]
                  ) else {
                respond(context: context, method: head.method,
                        status: .badRequest,
                        contentType: "text/plain", body: "Bad request")
                return
            }
            respond(
                context: context,
                method: head.method,
                status: .ok,
                contentType: "text/html; charset=utf-8",
                body: RemoteIOSAuthentication.confirmationPage(
                    for: request
                )
            )
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
        case "/transcript":
            handleTranscript(context: context, head: head)
        case "/\(RemoteTerminalImageContract.path)":
            handleTerminalImage(context: context, head: head)
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

    private func handleTranscript(
        context: ChannelHandlerContext,
        head: HTTPRequestHead
    ) {
        let query = RemoteRequestAuth.queryItems(head.uri)
        guard let sessionId = query["s"],
              !sessionId.isEmpty,
              sessionId.utf8.count <= 64 else {
            respond(context: context, method: head.method, status: .badRequest,
                    contentType: "text/plain", body: "Bad request")
            return
        }
        let channel = context.channel
        let method = head.method
        Task { @MainActor in
            guard self.bridge.hasSession(sessionId) else {
                channel.eventLoop.execute {
                    self.respond(
                        channel: channel,
                        method: method,
                        status: .notFound,
                        contentType: "text/plain",
                        body: Data("Not found".utf8)
                    )
                }
                return
            }
            let imageMetadata = self.bridge.retainedImageMetadata(sessionId: sessionId) ?? []
            let encodedData = await Task.detached {
                let snapshot = TranscriptController.loadRemoteSnapshot(sessionId: sessionId)
                let augmented = TranscriptImageAssociation.attach(
                    images: imageMetadata,
                    to: snapshot
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                return try? encoder.encode(augmented)
            }.value
            guard let data = encodedData else {
                channel.eventLoop.execute {
                    self.respond(
                        channel: channel,
                        method: method,
                        status: .internalServerError,
                        contentType: "text/plain",
                        body: Data("Encoding failed".utf8)
                    )
                }
                return
            }
            channel.eventLoop.execute {
                self.respond(
                    channel: channel,
                    method: method,
                    status: .ok,
                    contentType: "application/json",
                    body: data
                )
            }
        }
    }

    /// Serves the exact PNG bytes for a captured Kitty inline image placement.
    /// Requires the session, id, and version to match exactly (no partial/latest
    /// fallback), so a client always renders precisely the bytes a `screen`
    /// event advertised. Never embeds image bytes in the SSE JSON itself.
    private func handleTerminalImage(
        context: ChannelHandlerContext,
        head: HTTPRequestHead
    ) {
        let query = RemoteRequestAuth.queryItems(head.uri)
        guard let sessionId = query["s"],
              !sessionId.isEmpty,
              sessionId.utf8.count <= 64,
              let idString = query["i"],
              idString.utf8.count <= 16,
              let imageId = UInt32(idString),
              imageId >= 1, imageId <= 0xFFFFFF,
              let versionString = query["v"],
              versionString.utf8.count <= 20,
              let version = UInt64(versionString) else {
            respond(context: context, method: head.method, status: .badRequest,
                    contentType: "text/plain", body: "Bad request")
            return
        }
        let channel = context.channel
        let method = head.method
        Task { @MainActor in
            guard self.bridge.hasSession(sessionId) else {
                channel.eventLoop.execute {
                    self.respond(
                        channel: channel,
                        method: method,
                        status: .notFound,
                        contentType: "text/plain",
                        body: Data("Not found".utf8)
                    )
                }
                return
            }
            guard let data = self.bridge.terminalImageData(
                sessionId: sessionId,
                imageId: imageId,
                version: version
            ) else {
                // A retryable status — never a definitive 404 — while this
                // session's durable image restore is still pending: the
                // exact `(imageId, version)` a client already knows about
                // from before an app relaunch may simply not have finished
                // replaying yet, and a client must never cache that as
                // "permanently gone".
                let pending = self.bridge.isRestoringImages(sessionId: sessionId)
                channel.eventLoop.execute {
                    self.respond(
                        channel: channel,
                        method: method,
                        status: pending ? .serviceUnavailable : .notFound,
                        contentType: "text/plain",
                        body: Data((pending ? "Restoring" : "Not found").utf8)
                    )
                }
                return
            }
            channel.eventLoop.execute {
                self.respondWithTerminalImage(channel: channel, method: method, data: data)
            }
        }
    }

    /// Serves `data` as the terminal-image response body, enforcing the
    /// process/gateway-wide `imageResponseBudget` (finding: image response
    /// backpressure). A `HEAD` request never reserves anything — `respond`
    /// never queues an actual body for it regardless of `Content-Length` —
    /// but every `GET` first requires the channel to currently be writable
    /// (rejecting outright, rather than adding to an already-backed-up
    /// connection's outbound buffer) and reserves `data.count` bytes of the
    /// shared budget before ever copying/writing it. Excess demand — either
    /// a channel that isn't accepting more writes, or a shared budget that's
    /// already fully reserved by other concurrent image responses — is
    /// rejected with 503/429 instead of being queued. The reservation is
    /// released exactly once, only when the body write's own future
    /// completes or fails (see `respond(channel:...:onBodyWriteComplete:)`),
    /// never merely once this function returns.
    private func respondWithTerminalImage(channel: Channel, method: HTTPMethod, data: Data) {
        guard method != .HEAD else {
            respond(channel: channel, method: method, status: .ok, contentType: "image/png", body: data)
            return
        }
        guard channel.isWritable else {
            respond(channel: channel, method: method, status: .serviceUnavailable,
                    contentType: "text/plain", body: Data("Unavailable".utf8))
            return
        }
        guard imageResponseBudget.reserve(bytes: data.count) else {
            respond(channel: channel, method: method, status: .tooManyRequests,
                    contentType: "text/plain", body: Data("Too many requests".utf8))
            return
        }
        let budget = imageResponseBudget
        let reservedBytes = data.count
        respond(
            channel: channel,
            method: method,
            status: .ok,
            contentType: "image/png",
            body: data,
            onBodyWriteComplete: { _ in
                budget.release(bytes: reservedBytes)
            }
        )
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

    /// Authenticated same-origin session creation, independent of the writer lease so
    /// it works for empty projects. The AppModel mutation runs on the MainActor via a
    /// hop off the NIO event loop; the reply is written back on the channel's loop.
    private func handleCreateSession(
        context: ChannelHandlerContext,
        isReview: Bool
    ) {
        guard !bodyTooLarge else {
            respond(context: context, method: .POST, status: .payloadTooLarge,
                    contentType: "text/plain", body: "too large")
            return
        }
        guard let request = try? JSONDecoder().decode(
                RemoteCreateSessionRequest.self, from: Data(body)
              ),
              !request.projectId.isEmpty,
              request.projectId.utf8.count <= 200 else {
            respond(context: context, method: .POST, status: .badRequest,
                    contentType: "text/plain", body: "Bad request")
            return
        }
        let channel = context.channel
        let bridge = self.bridge
        Task { @MainActor in
            let outcome = isReview
                ? bridge.createAdversarialReviewSession(request)
                : bridge.createSession(request)
            channel.eventLoop.execute {
                self.respondCreateSession(channel: channel, outcome: outcome)
            }
        }
    }

    private func respondCreateSession(
        channel: Channel,
        outcome: RemoteSessionCreationOutcome
    ) {
        func send(_ status: HTTPResponseStatus, json response: RemoteCreateSessionResponse) {
            guard let data = try? JSONEncoder().encode(response) else {
                respond(channel: channel, method: .POST, status: .internalServerError,
                        contentType: "text/plain", body: Data("Encoding failed".utf8))
                return
            }
            respond(channel: channel, method: .POST, status: status,
                    contentType: "application/json", body: data)
        }
        func send(_ status: HTTPResponseStatus, text: String) {
            respond(channel: channel, method: .POST, status: status,
                    contentType: "text/plain", body: Data(text.utf8))
        }
        switch outcome {
        case .created(let response):
            send(.created, json: response)
        case .existing(let response):
            send(.ok, json: response)
        case .conflict:
            send(.conflict, text: "Session id already used in another project")
        case .gone:
            send(.gone, text: "Session was already created and has been closed")
        case .unknownProject:
            send(.unprocessableEntity, text: "Unknown project")
        case .invalid:
            send(.unprocessableEntity, text: "Repos working directory is unavailable")
        case .badRequest:
            send(.badRequest, text: "Invalid session creation request")
        case .unavailable:
            send(.serviceUnavailable, text: "Copilot is unavailable")
        }
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
        case "mark-read":
            // Read receipt from a remote client viewing the session. No lease
            // required — a view-only client must be able to clear its unread dot.
            // The workspace-snapshot diff propagates the cleared state to every
            // client (and the Mac), so read state syncs across devices.
            let bridge = self.bridge
            Task { @MainActor in
                bridge.markRead(sessionId: sessionId)
            }
            respond(context: context, method: .POST, status: .noContent,
                    contentType: "text/plain", body: "")
        case "close-session":
            let channel = context.channel
            let leases = self.leases
            Task { @MainActor in
                let closed = leases.withHeldLease(
                    sessionId: sessionId,
                    clientId: clientId
                ) {
                    self.bridge.closeSession(sessionId: sessionId)
                }
                channel.eventLoop.execute {
                    let response: (HTTPResponseStatus, String)
                    switch closed {
                    case .some(true):
                        response = (.noContent, "")
                    case .some(false):
                        response = (.notFound, "Session not found")
                    case .none:
                        response = (.forbidden, "view only")
                    }
                    self.respond(
                        channel: channel,
                        method: .POST,
                        status: response.0,
                        contentType: "text/plain",
                        body: Data(response.1.utf8)
                    )
                }
            }
        case "move-session":
            guard let targetProjectId = message.data,
                  !targetProjectId.isEmpty,
                  targetProjectId.utf8.count <= 64 else {
                respond(context: context, method: .POST, status: .badRequest,
                        contentType: "text/plain", body: "Invalid project")
                return
            }
            let channel = context.channel
            Task { @MainActor in
                let result = self.bridge.moveSession(
                    sessionId: sessionId,
                    toProjectId: targetProjectId
                )
                channel.eventLoop.execute {
                    let response: (HTTPResponseStatus, String)
                    switch result {
                    case .moved, .unchanged:
                        response = (.noContent, "")
                    case .missing:
                        response = (.notFound, "Session or project not found")
                    }
                    self.respond(
                        channel: channel,
                        method: .POST,
                        status: response.0,
                        contentType: "text/plain",
                        body: Data(response.1.utf8)
                    )
                }
            }
        case "prompt":
            guard let value = message.data,
                  value.utf8.count <= 8_192,
                  ProjectsTerminalView.remotePromptPasteBytes(value) != nil else {
                respond(context: context, method: .POST, status: .badRequest,
                        contentType: "text/plain", body: "Invalid prompt")
                return
            }
            guard leases.holds(sessionId: sessionId, clientId: clientId) else {
                respond(context: context, method: .POST, status: .forbidden,
                        contentType: "text/plain", body: "view only")
                return
            }
            let channel = context.channel
            let leases = self.leases
            Task { @MainActor in
                let result = leases.submitPrompt(
                    sessionId: sessionId,
                    clientId: clientId
                ) {
                    self.bridge.sendPrompt(sessionId: sessionId, value: value)
                }
                channel.eventLoop.execute {
                    let response: (HTTPResponseStatus, String)
                    switch result {
                    case .sent:
                        response = (.noContent, "")
                    case .forbidden:
                        response = (.forbidden, "view only")
                    case .invalid:
                        response = (.badRequest, "Invalid prompt")
                    case .busy:
                        response = (.conflict, "Copilot is still working")
                    case .noLiveCopilot:
                        response = (.unprocessableEntity, "Copilot is not ready")
                    }
                    self.respond(
                        channel: channel,
                        method: .POST,
                        status: response.0,
                        contentType: "text/plain",
                        body: Data(response.1.utf8)
                    )
                }
            }
        case "answer-user-input":
            guard let payload = message.data,
                  payload.utf8.count <= remoteMaxEncodedUserInputAnswerBytes,
                  let answer = try? JSONDecoder().decode(
                    RemoteUserInputAnswer.self, from: Data(payload.utf8)
                  ),
                  answer.requestId.utf8.count <= 200,
                  answer.answer.utf8.count <= 8_192 else {
                respond(context: context, method: .POST, status: .badRequest,
                        contentType: "text/plain", body: "Bad request")
                return
            }
            guard leases.holds(sessionId: sessionId, clientId: clientId) else {
                respond(context: context, method: .POST, status: .forbidden,
                        contentType: "text/plain", body: "view only")
                return
            }
            let channel = context.channel
            let leases = self.leases
            Task { @MainActor in
                let result = leases.withHeldLease(
                    sessionId: sessionId,
                    clientId: clientId
                ) {
                    self.bridge.answerUserInput(sessionId: sessionId, answer: answer)
                }
                channel.eventLoop.execute {
                    let response: (HTTPResponseStatus, String)
                    switch result {
                    case .some(.accepted):
                        response = (.noContent, "")
                    case .some(.conflict):
                        response = (.conflict, "Another answer is still processing")
                    case .some(.invalid):
                        response = (.unprocessableEntity, "Answer was not accepted")
                    case .none:
                        response = (.forbidden, "view only")
                    }
                    self.respond(
                        channel: channel,
                        method: .POST,
                        status: response.0,
                        contentType: "text/plain",
                        body: Data(response.1.utf8)
                    )
                }
            }
        case "answer-elicitation":
            guard let payload = message.data,
                  payload.utf8.count <= remoteMaxEncodedUserInputAnswerBytes,
                  let answer = try? JSONDecoder().decode(
                    RemoteElicitationAnswer.self, from: Data(payload.utf8)
                  ),
                  answer.requestId.utf8.count <= 200 else {
                respond(context: context, method: .POST, status: .badRequest,
                        contentType: "text/plain", body: "Bad request")
                return
            }
            guard leases.holds(sessionId: sessionId, clientId: clientId) else {
                respond(context: context, method: .POST, status: .forbidden,
                        contentType: "text/plain", body: "view only")
                return
            }
            let channel = context.channel
            let leases = self.leases
            Task { @MainActor in
                let result = leases.withHeldLease(
                    sessionId: sessionId,
                    clientId: clientId
                ) {
                    self.bridge.answerElicitation(sessionId: sessionId, answer: answer)
                }
                channel.eventLoop.execute {
                    let response: (HTTPResponseStatus, String)
                    switch result {
                    case .some(.accepted):
                        response = (.noContent, "")
                    case .some(.conflict):
                        response = (.conflict, "Another answer is still processing")
                    case .some(.invalid):
                        response = (.unprocessableEntity, "Answer was not accepted")
                    case .none:
                        response = (.forbidden, "view only")
                    }
                    self.respond(
                        channel: channel,
                        method: .POST,
                        status: response.0,
                        contentType: "text/plain",
                        body: Data(response.1.utf8)
                    )
                }
            }
        case "set-model":
            guard let payload = message.data,
                  payload.utf8.count <= 4_096,
                  let selection = try? JSONDecoder().decode(
                    RemoteModelSelection.self, from: Data(payload.utf8)
                  ),
                  !selection.modelId.isEmpty,
                  selection.modelId.utf8.count <= 200,
                  (selection.reasoningEffort?.utf8.count ?? 0) <= 64,
                  (selection.contextTier?.utf8.count ?? 0) <= 64 else {
                respond(context: context, method: .POST, status: .badRequest,
                        contentType: "text/plain", body: "Bad request")
                return
            }
            guard leases.holds(sessionId: sessionId, clientId: clientId) else {
                respond(context: context, method: .POST, status: .forbidden,
                        contentType: "text/plain", body: "view only")
                return
            }
            let channel = context.channel
            let leases = self.leases
            Task { @MainActor in
                let result = leases.withHeldLease(
                    sessionId: sessionId,
                    clientId: clientId
                ) {
                    self.bridge.setModel(sessionId: sessionId, selection: selection)
                }
                channel.eventLoop.execute {
                    let response: (HTTPResponseStatus, String)
                    switch result {
                    case .some(.accepted):
                        response = (.noContent, "")
                    case .some(.conflict):
                        response = (.conflict, "Another model switch is still processing")
                    case .some(.invalid):
                        response = (.unprocessableEntity, "Model switch was not accepted")
                    case .none:
                        response = (.forbidden, "view only")
                    }
                    self.respond(
                        channel: channel,
                        method: .POST,
                        status: response.0,
                        contentType: "text/plain",
                        body: Data(response.1.utf8)
                    )
                }
            }
        case "command":
            guard let value = message.data,
                  let requestId = message.requestId,
                  !requestId.isEmpty,
                  requestId.utf8.count <= 64,
                  ProjectsTerminalView.remoteCommandTextBytes(value) != nil else {
                respond(context: context, method: .POST, status: .unprocessableEntity,
                        contentType: "text/plain", body: "Invalid command")
                return
            }
            guard leases.holds(sessionId: sessionId, clientId: clientId) else {
                respond(context: context, method: .POST, status: .forbidden,
                        contentType: "text/plain", body: "view only")
                return
            }
            let channel = context.channel
            let leases = self.leases
            Task { @MainActor in
                let result = leases.withHeldLease(
                    sessionId: sessionId,
                    clientId: clientId
                ) {
                    self.bridge.sendCommand(
                        sessionId: sessionId,
                        requestId: requestId,
                        value: value
                    )
                }
                channel.eventLoop.execute {
                    let response: (HTTPResponseStatus, String)
                    switch result {
                    case .some(.sent):
                        response = (.noContent, "")
                    case .some(.busy):
                        response = (.conflict, "Terminal input is busy")
                    case .some(.invalid):
                        response = (.unprocessableEntity, "Command was not accepted")
                    case .none:
                        response = (.forbidden, "view only")
                    }
                    self.respond(
                        channel: channel,
                        method: .POST,
                        status: response.0,
                        contentType: "text/plain",
                        body: Data(response.1.utf8)
                    )
                }
            }
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
            let channel = context.channel
            let leases = self.leases
            Task { @MainActor in
                let sent = leases.withHeldLease(
                    sessionId: sessionId,
                    clientId: clientId
                ) {
                    self.bridge.sendInput(sessionId: sessionId, value: value)
                    return true
                } ?? false
                channel.eventLoop.execute {
                    self.respond(
                        channel: channel,
                        method: .POST,
                        status: sent ? .noContent : .forbidden,
                        contentType: "text/plain",
                        body: Data()
                    )
                }
            }
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
            let channel = context.channel
            let leases = self.leases
            Task { @MainActor in
                let sent = leases.withHeldLease(
                    sessionId: sessionId,
                    clientId: clientId
                ) {
                    self.bridge.sendKey(sessionId: sessionId, key: key)
                    return true
                } ?? false
                channel.eventLoop.execute {
                    self.respond(
                        channel: channel,
                        method: .POST,
                        status: sent ? .noContent : .forbidden,
                        contentType: "text/plain",
                        body: Data()
                    )
                }
            }
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
                _ = leases.withHeldLease(sessionId: sessionId, clientId: clientId) {
                    self.bridge.sendScroll(sessionId: sessionId, delta: delta)
                }
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
        let options = RemoteEventStreamOptions(uri: head.uri)
        streaming = true
        streamSessionId = options.sessionId
        streamsTerminal = options.streamsTerminal

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
            let streamsTerminal = self.streamsTerminal
            let refreshWorkspace =
                now.timeIntervalSince(self.lastWorkspaceRefreshAt)
                >= remoteWorkspaceRefreshInterval
            let previousScreenRevision = self.lastScreenRevision
            let previousTranscriptRevision = self.lastTranscriptRevision
            let lastHistoryEndLine = self.lastHistoryEndLine
            let bridge = self.bridge
            let dismissalSnapshot = self.notificationSync?.dismissalSnapshot()
            Task.detached {
                let (transcriptSessionId, transcriptRevision):
                    (String?, RemoteTranscriptRevision?) = await MainActor.run {
                    let sessionId = streamSessionId.flatMap {
                        bridge.hasSession($0) ? $0 : nil
                    }
                    let revision = sessionId.map { bridge.transcriptRevision(sessionId: $0) }
                    return (sessionId, revision)
                }
                await MainActor.run {
                    let workspace = refreshWorkspace ? bridge.workspace() : nil
                    let workspaceObservedAt = Date()
                    if let workspace {
                        for project in workspace.projects {
                            // A prompt's dedup guard is cleared once we observe the
                            // foreground actually leave the promptable state (the sent
                            // prompt landed). Key this on `promptable` alone — NOT
                            // `status != "idle"` — because a background subagent keeps
                            // `status == "running"` while the foreground stays
                            // promptable, which would otherwise clear the guard before
                            // the prompt was picked up and let a retry double-send.
                            for session in project.sessions
                            where session.promptable == false {
                                self.leases.observePromptUnavailable(
                                    sessionId: session.id,
                                    observedAt: workspaceObservedAt
                                )
                            }
                        }
                    }
                    let screenRevision = streamsTerminal ? streamSessionId.flatMap {
                        bridge.screenRevision(sessionId: $0)
                    } : nil
                    let screen: RemoteTerminalScreen?
                    if let streamSessionId, let screenRevision,
                       screenRevision != previousScreenRevision {
                        screen = bridge.screen(
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
                        if transcriptRevision != previousTranscriptRevision,
                           let transcriptRevision {
                            self.lastTranscriptRevision = transcriptRevision
                            guard self.emit(
                                type: "transcript",
                                value: transcriptRevision,
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

    private func redirect(
        context: ChannelHandlerContext,
        location: String
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Location", value: location)
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Cache-Control", value: "no-store, max-age=0")
        headers.add(name: "Referrer-Policy", value: "no-referrer")
        headers.add(name: "Content-Security-Policy", value: "default-src 'none'")
        let response = HTTPResponseHead(
            version: .http1_1,
            status: .found,
            headers: headers
        )
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

    /// - Parameter onBodyWriteComplete: If provided, invoked exactly once
    ///   with the result of the body write specifically (not the subsequent
    ///   `.end` frame) — immediately, synchronously, with `.success(())` if
    ///   no body was actually queued (a `HEAD` request or an empty `body`),
    ///   since nothing was reserved for those in the first place. Lets a
    ///   caller release a byte-budget reservation exactly once the bytes it
    ///   guarded have actually left (successfully or not) the channel's own
    ///   outbound buffer, never merely once this call returns.
    private func respond(
        channel: Channel,
        method: HTTPMethod,
        status: HTTPResponseStatus,
        contentType: String,
        body: Data,
        onBodyWriteComplete: (@Sendable (Result<Void, Error>) -> Void)? = nil
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
        channel.write(HTTPServerResponsePart.head(response), promise: nil)
        if method != .HEAD && !body.isEmpty {
            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            if let onBodyWriteComplete {
                let promise = channel.eventLoop.makePromise(of: Void.self)
                promise.futureResult.whenComplete(onBodyWriteComplete)
                channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: promise)
            } else {
                channel.write(
                    HTTPServerResponsePart.body(.byteBuffer(buffer)),
                    promise: nil
                )
            }
        } else {
            onBodyWriteComplete?(.success(()))
        }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
    }
}
