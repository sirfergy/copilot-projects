import XCTest
@testable import copilot_projects
import CopilotProjectsCore
import CopilotProjectsProtocol
import Security

/// Runtime coverage for the remote transcript optimizations: the optional
/// `?limit=` window on `GET /transcript` (server), and the web client's
/// windowed fetch, per-turn card reuse, hidden-pane skip, and stale-response
/// gating (executed under Node against a small DOM shim rather than asserted as
/// source text).
final class RemoteTranscriptOptimizationTests: XCTestCase {

    // MARK: - Fixtures

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func fixtureTurn(index: Int) -> TranscriptTurn {
        TranscriptTurn(
            id: "turn-\(index)",
            startedAt: Self.epoch.addingTimeInterval(Double(index) * 100),
            endedAt: Self.epoch.addingTimeInterval(Double(index) * 100 + 50),
            kind: "foreground",
            userContent: "ask \(index)",
            assistantMessages: [
                TranscriptAssistantMessage(
                    id: "message-\(index)",
                    timestamp: Self.epoch.addingTimeInterval(Double(index) * 100 + 10),
                    content: "reply \(index)"
                )
            ],
            tools: [],
            isAborted: false
        )
    }

    private func fixtureSnapshot(turnCount: Int) -> TranscriptSnapshot {
        TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Self.epoch,
            copilotSessionId: "copilot-session",
            turns: (0..<turnCount).map(fixtureTurn(index:))
        )
    }

    /// One retained image per turn index, displayed just after that turn began.
    private func fixtureImages(forTurnIndexes indexes: [Int]) -> [RemoteKittyImageCapture.RetainedImageInfo] {
        indexes.map { index in
            RemoteKittyImageCapture.RetainedImageInfo(
                imageId: UInt32(index + 1),
                version: UInt64(index + 1) << 32 | 7,
                displayedAt: Self.epoch.addingTimeInterval(Double(index) * 100 + 5)
            )
        }
    }

    private func decode(_ data: Data) throws -> TranscriptSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptSnapshot.self, from: data)
    }

    // MARK: - Request shaping

    func testTranscriptLimitQueryAcceptsBoundedWindowsAndRejectsGarbage() {
        // Absent: legacy clients (iOS, older web) keep the full-transcript shape.
        XCTAssertEqual(RemoteTranscriptRequest.limit(query: ["s": "session"]), .absent)
        XCTAssertEqual(RemoteTranscriptRequest.limit(query: ["limit": "1"]), .turns(1))
        XCTAssertEqual(RemoteTranscriptRequest.limit(query: ["limit": "50"]), .turns(50))
        XCTAssertEqual(RemoteTranscriptRequest.limit(query: ["limit": "200"]), .turns(200))
        XCTAssertEqual(TranscriptSnapshot.maximumRemoteTurnLimit, 200)
        for invalid in ["", "0", "201", "999", "-1", "+5", "1.5", "abc", " 5", "5 ", "0050", "1e2"] {
            XCTAssertEqual(
                RemoteTranscriptRequest.limit(query: ["limit": invalid]),
                .invalid,
                "expected \(invalid.debugDescription) to be rejected"
            )
        }
    }

    // MARK: - Response payload

    func testTranscriptResponseAppliesWindowAfterImageAssociation() throws {
        let snapshot = fixtureSnapshot(turnCount: 6)
        // Images displayed during turns 1 and 4 — one inside the window a
        // `limit=2` response returns, one only in the dropped prefix.
        let images = fixtureImages(forTurnIndexes: [1, 4])

        let fullData = try XCTUnwrap(RemoteTranscriptRequest.encodedResponse(
            snapshot: snapshot, images: images, limit: nil
        ))
        let full = try decode(fullData)
        // The legacy shape is preserved byte-for-byte: no window, no metadata.
        XCTAssertNil(full.totalTurns)
        XCTAssertFalse(
            String(decoding: fullData, as: UTF8.self).contains("totalTurns"),
            "an unlimited response must not carry window metadata"
        )
        XCTAssertEqual(full.turns.count, 6)
        XCTAssertEqual(full.turns[1].images?.map(\.imageId), [2])
        XCTAssertEqual(full.turns[4].images?.map(\.imageId), [5])

        let limited = try decode(try XCTUnwrap(RemoteTranscriptRequest.encodedResponse(
            snapshot: snapshot, images: images, limit: 2
        )))
        XCTAssertEqual(limited.totalTurns, 6)
        XCTAssertEqual(limited.turns.map(\.id), ["turn-4", "turn-5"])
        // Association ran against the full transcript, so a windowed turn's
        // images are exactly the ones the unlimited response reports…
        XCTAssertEqual(limited.turns[0].images, full.turns[4].images)
        XCTAssertEqual(limited.turns[1].images, full.turns[5].images)
        // …and the image displayed during a dropped turn is not re-anchored onto
        // whatever turn happens to be oldest in the window.
        let windowedImageIds = limited.turns.flatMap { $0.images?.map(\.imageId) ?? [] }
        XCTAssertEqual(windowedImageIds, [5])

        // Every window agrees with the unlimited response, turn for turn.
        for limit in 1...6 {
            let windowed = try decode(try XCTUnwrap(RemoteTranscriptRequest.encodedResponse(
                snapshot: snapshot, images: images, limit: limit
            )))
            XCTAssertEqual(windowed.turns.count, limit)
            XCTAssertEqual(windowed.totalTurns, 6)
            for turn in windowed.turns {
                let original = try XCTUnwrap(full.turns.first { $0.id == turn.id })
                XCTAssertEqual(turn, original)
            }
        }

        // A window wider than the transcript returns everything, still tagged so
        // the client can tell "this is all of it" from "the host ignored me".
        let wide = try decode(try XCTUnwrap(RemoteTranscriptRequest.encodedResponse(
            snapshot: snapshot, images: images, limit: 200
        )))
        XCTAssertEqual(wide.turns.map(\.id), full.turns.map(\.id))
        XCTAssertEqual(wide.totalTurns, 6)

        // The pure slice keeps the legacy default when constructed directly.
        XCTAssertNil(fixtureSnapshot(turnCount: 3).totalTurns)
        XCTAssertEqual(fixtureSnapshot(turnCount: 3).limitedToMostRecentTurns(1).totalTurns, 3)
        XCTAssertEqual(
            fixtureSnapshot(turnCount: 3).limitedToMostRecentTurns(1).turns.map(\.id),
            ["turn-2"]
        )
    }

    // MARK: - HTTP endpoint

    @MainActor
    func testRemoteGatewayTranscriptEndpointHonorsLimitQuery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        let session = Session(id: sessionId, title: "Transcript Window", cwd: root.path)
        let project = Project(id: "pid", name: "Project", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: "pid"))
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        Paths.ensureStateDir()
        try encoder.encode(fixtureSnapshot(turnCount: 6)).write(
            to: URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionId))
        )

        let verifier = CloudflareAccessVerifier(
            config: CloudflareAccessConfig(
                teamDomain: "team.cloudflareaccess.com",
                audTag: "expected-aud",
                allowedEmail: "user@example.com"
            ),
            now: { Date() },
            fetch: { _ in nil }
        )
        let (privateKey, publicKey) = try Self.rsaKeyPair()
        verifier.installKey(kid: "test-key", key: publicKey)
        let token = try Self.accessToken(
            kid: "test-key",
            claims: [
                "iss": "https://team.cloudflareaccess.com",
                "aud": "expected-aud",
                "email": "user@example.com",
                "exp": Date().timeIntervalSince1970 + 3_600,
            ],
            privateKey: privateKey
        )

        let gateway = RemoteGateway()
        let port = try gateway.start(
            bridge: RemoteModelBridge(model: model),
            expectedHost: "127.0.0.1",
            expectedOrigin: "https://projects.example.com",
            verifier: verifier,
            port: 0,
            webPushService: nil,
            apnsService: nil
        )

        do {
            // No `limit`: the legacy full-transcript response older clients expect.
            let (legacyStatus, legacyBody) = try await Self.httpGet(
                port: port, path: "/transcript?s=\(sessionId)", token: token
            )
            XCTAssertEqual(legacyStatus, 200)
            let legacy = try decode(legacyBody)
            XCTAssertEqual(legacy.turns.count, 6)
            XCTAssertNil(legacy.totalTurns)

            // A window returns only the most recent turns plus the total.
            let (windowStatus, windowBody) = try await Self.httpGet(
                port: port, path: "/transcript?s=\(sessionId)&limit=2", token: token
            )
            XCTAssertEqual(windowStatus, 200)
            let windowed = try decode(windowBody)
            XCTAssertEqual(windowed.turns.map(\.id), ["turn-4", "turn-5"])
            XCTAssertEqual(windowed.totalTurns, 6)
            XCTAssertLessThan(windowBody.count, legacyBody.count)

            let (wideStatus, wideBody) = try await Self.httpGet(
                port: port, path: "/transcript?s=\(sessionId)&limit=200", token: token
            )
            XCTAssertEqual(wideStatus, 200)
            XCTAssertEqual(try decode(wideBody).turns.count, 6)

            // Invalid windows fail cleanly instead of being clamped or ignored.
            for invalid in ["0", "201", "abc", "-1", "", "1000"] {
                let (status, _) = try await Self.httpGet(
                    port: port,
                    path: "/transcript?s=\(sessionId)&limit=\(invalid)",
                    token: token
                )
                XCTAssertEqual(status, 400, "limit=\(invalid) should be rejected")
            }
        } catch {
            await gateway.stop()
            throw error
        }
        await gateway.stop()
    }

    // MARK: - Web client (executed under Node)

    func testTranscriptWebClientWindowingCardReuseAndStaleResponses() throws {
        try Self.requireNode()
        let harness = Self.domShim
            + Self.javascriptFunction(named: "normalizeConversationImageRef")
            + RemoteWebAssets.transcriptJavascript
            + Self.javascriptFunction(named: "setViewMode")
            + Self.transcriptAssertions
        let output = try Self.runNode(script: harness)
        XCTAssertEqual(output.status, 0, output.stderr)
    }

    // MARK: - Node plumbing

    private static func requireNode() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw XCTSkip("Node.js is not installed") }
    }

    /// Runs `script` through `node -` (stdin), so no scratch file is needed.
    private static func runNode(script: String) throws -> (status: Int32, stderr: String) {
        let process = Process()
        let input = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-"]
        process.standardInput = input
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: errorData, as: UTF8.self))
    }

    /// Lifts one top-level client function out of the shipped bundle so the test
    /// exercises the real implementation rather than a lookalike.
    /// Lifts one top-level client function out of the shipped bundle so the test
    /// exercises the real implementation rather than a lookalike. The end of the
    /// function is its closing brace at the same indentation as its `function`
    /// keyword, so this works whatever indentation the bundle happens to use.
    private static func javascriptFunction(named name: String) -> String {
        let source = RemoteWebAssets.javascript
        guard let start = source.range(of: "function \(name)(") else {
            XCTFail("function \(name) not found in the client bundle")
            return ""
        }
        let lineStart = source[..<start.lowerBound].lastIndex(of: "\n")
            .map { source.index(after: $0) } ?? source.startIndex
        let indent = String(source[lineStart..<start.lowerBound])
        guard let end = source.range(
            of: "\n\(indent)}\n",
            range: start.upperBound..<source.endIndex
        ) else {
            XCTFail("end of function \(name) not found in the client bundle")
            return ""
        }
        return String(source[lineStart..<end.upperBound])
    }

    // MARK: - HTTP plumbing

    private static func httpGet(
        port: Int,
        path: String,
        token: String
    ) async throws -> (Int, Data) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)")))
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.setValue(token, forHTTPHeaderField: "Cf-Access-Jwt-Assertion")
        let (data, response) = try await session.data(for: request)
        return (try XCTUnwrap((response as? HTTPURLResponse)?.statusCode), data)
    }

    private static func rsaKeyPair() throws -> (privateKey: SecKey, publicKey: SecKey) {
        var creationError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey([
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2_048,
        ] as CFDictionary, &creationError),
            let publicKey = SecKeyCopyPublicKey(privateKey) else {
            if let creationError { throw creationError.takeRetainedValue() as Error }
            throw NSError(domain: "RemoteTranscriptOptimizationTests", code: 1)
        }
        return (privateKey, publicKey)
    }

    private static func accessToken(
        kid: String,
        claims: [String: Any],
        privateKey: SecKey
    ) throws -> String {
        let header: [String: Any] = ["alg": "RS256", "kid": kid, "typ": "JWT"]
        let signingInput = [
            try base64URL(JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])),
            try base64URL(JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])),
        ].joined(separator: ".")
        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(signingInput.utf8) as CFData,
            &signingError
        ) as Data? else {
            if let signingError { throw signingError.takeRetainedValue() as Error }
            throw NSError(domain: "RemoteTranscriptOptimizationTests", code: 2)
        }
        return "\(signingInput).\(base64URL(signature))"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - JavaScript harness

    /// Just enough DOM for the transcript slice to run for real: node identity
    /// with parent links, `insertBefore`/`remove`, focus tracking that blurs on
    /// detach exactly as a browser does, class-token `querySelectorAll`, and a
    /// synthetic layout where every child of `#transcript` is 100px tall.
    /// Detach and insert counts make "this render did not touch that node"
    /// directly assertable.
    private static let domShim = #"""
    const assert = require('node:assert/strict');

    let createdElements = 0;
    let domMutations = 0;

    function blurIfDetaching(node) {
      const active = document.activeElement;
      if (active && (active === node || node.contains(active))) {
        document.activeElement = null;
      }
    }

    class FakeNode {
      constructor(tagName) {
        this.tagName = tagName;
        this.children = [];
        this.parent = null;
        this.dataset = {};
        this.className = '';
        this.attributes = {};
        this.listeners = new Map();
        this.disabled = false;
        this.detachCount = 0;
        this._text = undefined;
      }
      get childElementCount() { return this.children.length; }
      get firstElementChild() { return this.children[0] || null; }
      get nextElementSibling() {
        if (!this.parent) return null;
        const index = this.parent.children.indexOf(this);
        return index < 0 ? null : (this.parent.children[index + 1] || null);
      }
      get isConnected() {
        let node = this;
        while (node) {
          if (node === transcript) return true;
          node = node.parent;
        }
        return false;
      }
      contains(other) {
        let node = other;
        while (node) {
          if (node === this) return true;
          node = node.parent;
        }
        return false;
      }
      detachChild(child) {
        const index = this.children.indexOf(child);
        if (index < 0) return;
        blurIfDetaching(child);
        this.children.splice(index, 1);
        child.parent = null;
        child.detachCount += 1;
        // Only the reconciliation surface (`#transcript`'s own children) counts;
        // building a card's internals is not a mutation of the rendered list.
        if (this === transcript) domMutations += 1;
      }
      insertAt(node, index) {
        if (node.parent) node.parent.detachChild(node);
        node.parent = this;
        this.children.splice(index, 0, node);
        if (this === transcript) domMutations += 1;
      }
      append(...nodes) {
        for (const node of nodes) {
          if (node.tagName === '#fragment') {
            const moving = [...node.children];
            node.children = [];
            moving.forEach((child) => {
              child.parent = null;
              this.insertAt(child, this.children.length);
            });
          } else {
            this.insertAt(node, this.children.length);
          }
        }
      }
      insertBefore(node, reference) {
        const index = reference ? this.children.indexOf(reference) : this.children.length;
        this.insertAt(node, index < 0 ? this.children.length : index);
      }
      remove() {
        if (this.parent) this.parent.detachChild(this);
      }
      replaceChildren(...nodes) {
        [...this.children].forEach((child) => this.detachChild(child));
        this.append(...nodes);
        if (this === transcript && !this.children.length) this.scrollTop = 0;
      }
      focus(options) {
        document.activeElement = this;
        this.lastFocusOptions = options;
      }
      setAttribute(name, value) { this.attributes[name] = value; }
      removeAttribute(name) { delete this.attributes[name]; }
      addEventListener(name, handler) { this.listeners.set(name, handler); }
      dispatch(name) {
        const handler = this.listeners.get(name);
        if (handler) handler({});
      }
      get textContent() {
        if (this._text !== undefined) return this._text;
        return this.children.map((child) => child.textContent).join('');
      }
      set textContent(value) {
        [...this.children].forEach((child) => this.detachChild(child));
        this._text = value;
      }
      matches(token) { return String(this.className).split(/\s+/).includes(token); }
      querySelectorAll(selector) {
        const token = selector.replace('.', '');
        const results = [];
        const walk = (node) => {
          for (const child of node.children || []) {
            if (child.matches && child.matches(token)) results.push(child);
            walk(child);
          }
        };
        walk(this);
        return results;
      }
      getBoundingClientRect() {
        if (content.dataset.mode === 'terminal') return { top: 0, bottom: 0 };
        if (this === transcript) return { top: 0, bottom: transcript.clientHeight };
        const index = transcript.children.indexOf(this);
        if (index < 0) return { top: 0, bottom: 0 };
        const top = index * 100 - transcript.scrollTop;
        return { top, bottom: top + 100 };
      }
    }

    class FakeTextNode {
      constructor(text) { this._text = text; }
      get textContent() { return this._text; }
      contains() { return false; }
    }

    globalThis.document = {
      activeElement: null,
      createElement(tag) { createdElements += 1; return new FakeNode(tag); },
      createDocumentFragment() { return new FakeNode('#fragment'); },
      createTextNode(text) { return new FakeTextNode(text); },
    };

    const transcript = new FakeNode('div');
    transcript.scrollTop = 0;
    transcript.clientHeight = 400;
    Object.defineProperty(transcript, 'scrollHeight', {
      get() { return this.children.length * 100; },
    });

    // Surrounding client state the slice reads (declared in the main bundle).
    const base = '/app/';
    const content = { dataset: { mode: 'conversation' } };
    const pivotTabs = [];
    const terminal = new FakeNode('div');
    function refreshTerminal() {}
    let selected = 'session-a';
    let viewMode = 'conversation';
    let transcriptRequestId = 0;

    let markdownCalls = 0;
    function appendMarkdown(parent, text) {
      markdownCalls += 1;
      parent.append(document.createTextNode(text));
    }

    // Conversation image nodes, mirroring the real mount/release accounting
    // (shared decoded-pixel budget, per-key reference counts) so budget leaks
    // and premature evictions are observable. The bundle owns these nodes only
    // through `transcriptCardCache`, so the harness keeps no parallel list.
    const TERMINAL_IMAGE_MAX_DECODED_PIXELS = 1000;
    let terminalActiveDecodedPixels = 0;
    const imagePixelsByKey = new Map();
    const imageRefCounts = new Map();
    const imageEvents = [];
    function imagePixelsFor(key) { return imagePixelsByKey.get(key) ?? 200; }
    function createConversationImageNode(sessionId, ref) {
      const key = `${sessionId}:${ref.imageId}:${ref.contentVersion}`;
      const el = document.createElement('img');
      const figure = document.createElement('figure');
      figure.append(el);
      const node = { el, figure, key, cacheKey: null, pixels: 0, released: false };
      const pixels = imagePixelsFor(key);
      if (terminalActiveDecodedPixels + pixels <= TERMINAL_IMAGE_MAX_DECODED_PIXELS) {
        node.cacheKey = key;
        node.pixels = pixels;
        terminalActiveDecodedPixels += pixels;
        el.dataset.cacheKey = key;
        el.attributes.src = `blob:${key}`;
        imageRefCounts.set(key, (imageRefCounts.get(key) || 0) + 1);
        imageEvents.push(`mount:${key}`);
      } else {
        imageEvents.push(`blocked:${key}`);
      }
      return node;
    }
    function releaseConversationImageNode(node) {
      if (node.released) return;
      node.released = true;
      delete node.el.dataset.cacheKey;
      if (!node.cacheKey) return;
      const key = node.cacheKey;
      terminalActiveDecodedPixels = Math.max(0, terminalActiveDecodedPixels - node.pixels);
      node.cacheKey = null;
      node.pixels = 0;
      const remaining = Math.max(0, (imageRefCounts.get(key) || 0) - 1);
      imageRefCounts.set(key, remaining);
      imageEvents.push(`release:${key}`);
      // The shared cache evicts the moment a key's active node count hits zero,
      // so a release ordered before its replacement mounts drops live bytes.
      if (remaining === 0) imageEvents.push(`evict:${key}`);
    }

    // Manually-resolved fetch so a response can be delivered late (or never).
    const fetchCalls = [];
    globalThis.fetch = (url) => {
      let deliver = null;
      const promise = new Promise((resolve) => { deliver = resolve; });
      fetchCalls.push({
        url,
        respond(snapshot) { deliver({ ok: true, json: async () => snapshot }); },
        fail() { deliver({ ok: false, json: async () => ({}) }); },
      });
      return promise;
    };
    const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

    """#

    private static let transcriptAssertions = #"""

    function makeTurn(id, options = {}) {
      return {
        id,
        startedAt: '2026-01-01T00:00:00Z',
        endedAt: null,
        kind: 'foreground',
        userContent: options.userContent ?? `ask ${id}`,
        assistantMessages: options.assistantMessages
          ?? [{ id: `${id}-m`, timestamp: '', content: `reply ${id}` }],
        tools: options.tools ?? [],
        isAborted: false,
        images: options.images,
      };
    }
    function makeTurns(count, prefix = 't') {
      return Array.from({ length: count }, (_, index) => makeTurn(`${prefix}${index}`));
    }
    function makeSnapshot(turns, totalTurns) {
      const value = {
        schemaVersion: 3, updatedAt: '', copilotSessionId: 'copilot', turns,
      };
      if (totalTurns !== undefined) value.totalTurns = totalTurns;
      return value;
    }
    function cards() { return transcript.children.filter((child) => child.matches('turn')); }
    function cardFor(turnId) {
      return transcript.children.find((child) => child.dataset.turnId === turnId) || null;
    }
    function showEarlierButton() {
      return transcript.children.find((child) => child.matches('show-earlier')) || null;
    }
    // The cards are the only owner of conversation image nodes; the harness
    // derives from the cache exactly like the bundle does.
    function mountedImageNodes() {
      const nodes = [];
      transcriptCardCache.forEach((entry) => entry.imageNodes.forEach((n) => nodes.push(n)));
      return nodes;
    }

    (async () => {
      // --- Unchanged turns keep their card, DOM, and parsed markdown ---------
      const first = makeSnapshot(makeTurns(3));
      renderTranscript(first);
      const initialCards = cards();
      assert.equal(initialCards.length, 3);
      const markdownAfterFirst = markdownCalls;
      assert.ok(markdownAfterFirst > 0, 'first render must parse markdown');

      // A fresh snapshot object with identical content (what a 2Hz revision
      // stream delivers) must reuse every card node — no markdown reparse, and
      // no detach/reattach of any card.
      renderTranscript(makeSnapshot(makeTurns(3)));
      assert.deepEqual(cards(), initialCards, 'unchanged turns must reuse their cards');
      assert.equal(markdownCalls, markdownAfterFirst, 'unchanged turns must not reparse');
      assert.deepEqual(
        initialCards.map((card) => card.detachCount),
        [0, 0, 0],
        'an unchanged, in-order card must never leave the DOM'
      );

      // Only the turn that actually changed is rebuilt, and only its node moves.
      const mutationsBeforeStream = domMutations;
      const streaming = makeTurns(3);
      streaming[2] = makeTurn('t2', {
        assistantMessages: [{ id: 't2-m', timestamp: '', content: 'reply t2 (more)' }],
      });
      renderTranscript(makeSnapshot(streaming));
      const streamedCards = cards();
      assert.equal(streamedCards[0], initialCards[0]);
      assert.equal(streamedCards[1], initialCards[1]);
      assert.notEqual(streamedCards[2], initialCards[2], 'changed turn must rebuild');
      assert.equal(initialCards[0].detachCount, 0, 'reused card stayed connected');
      assert.equal(initialCards[1].detachCount, 0, 'reused card stayed connected');
      assert.equal(
        domMutations - mutationsBeforeStream,
        2,
        'one changed turn costs exactly one removal and one insert'
      );
      assert.ok(markdownCalls > markdownAfterFirst);

      // A new turn appended reuses the earlier ones and builds only the new card.
      const markdownBeforeAppend = markdownCalls;
      const appended = streaming.concat([makeTurn('t3')]);
      renderTranscript(makeSnapshot(appended));
      assert.equal(cards().length, 4);
      assert.equal(cards()[0], initialCards[0]);
      assert.equal(initialCards[0].detachCount, 0);
      assert.equal(markdownCalls - markdownBeforeAppend, 2, 'only the new turn parses');
      // The card cache never outgrows the rendered window.
      assert.equal(transcriptCardCache.size, 4);

      // --- Focus survives live updates, front trim, and "Show earlier" ------
      resetTranscriptForSession();
      transcriptRenderLimit = 3;
      renderTranscript(makeSnapshot(makeTurns(3, 'f')));
      const focusedCard = cardFor('f1');
      const focusedChild = focusedCard.children[0];
      focusedChild.focus();
      assert.equal(document.activeElement, focusedChild);

      // A revision that changes a *different* turn must not blur.
      const live = makeTurns(3, 'f');
      live[2] = makeTurn('f2', {
        assistantMessages: [{ id: 'f2-m', timestamp: '', content: 'streaming…' }],
      });
      renderTranscript(makeSnapshot(live));
      assert.equal(document.activeElement, focusedChild, 'live update must not steal focus');
      assert.equal(focusedCard.detachCount, 0);
      assert.equal(focusedChild.isConnected, true);

      // Front trim: the window slides, dropping the oldest card. The focused
      // card keeps its position in the list, so it must not be touched.
      renderTranscript(makeSnapshot(live.concat([makeTurn('f3')])));
      assert.equal(cardFor('f0'), null, 'the trimmed turn is gone');
      assert.equal(cards().length, 3);
      assert.equal(document.activeElement, focusedChild, 'front trim must not steal focus');
      assert.equal(focusedCard.detachCount, 0);

      // "Show earlier": older cards are inserted *before* the retained ones.
      transcriptRenderLimit = 6;
      renderTranscript(makeSnapshot(makeTurns(6, 'f')));
      assert.equal(cards().length, 6);
      assert.equal(cardFor('f1'), focusedCard, 'the focused card is the same node');
      assert.equal(document.activeElement, focusedChild, 'expansion must not steal focus');
      assert.equal(focusedCard.detachCount, 0);

      // Focus outside the transcript is never disturbed or restored.
      const outsider = document.createElement('input');
      outsider.focus();
      renderTranscript(makeSnapshot(makeTurns(7, 'f')));
      assert.equal(document.activeElement, outsider, 'foreign focus must be left alone');

      // --- Inline images: refs survive reuse, replacements mount first -------
      resetTranscriptForSession();
      imageEvents.length = 0;
      const imageRef = { imageId: 7, contentVersion: 11, contentVersionText: '11' };
      const withImage = [makeTurn('i0'), makeTurn('i1', { images: [imageRef] })];
      renderTranscript(makeSnapshot(withImage));
      assert.deepEqual(imageEvents, ['mount:session-a:7:11']);
      assert.equal(mountedImageNodes().length, 1);

      // Re-render with identical content: the mounted node is kept, so the
      // shared cache entry never sees a release at all.
      renderTranscript(makeSnapshot([makeTurn('i0'), makeTurn('i1', { images: [imageRef] })]));
      assert.deepEqual(imageEvents, ['mount:session-a:7:11'], 'unchanged image must be kept');
      assert.equal(imageRefCounts.get('session-a:7:11'), 1);

      // A new version rebuilds the card: the replacement mounts before the old
      // node is released, and the old key only reaches zero afterwards.
      const nextRef = { imageId: 7, contentVersion: 12, contentVersionText: '12' };
      renderTranscript(makeSnapshot([makeTurn('i0'), makeTurn('i1', { images: [nextRef] })]));
      assert.deepEqual(imageEvents, [
        'mount:session-a:7:11',
        'mount:session-a:7:12',
        'release:session-a:7:11',
        'evict:session-a:7:11',
      ]);
      assert.equal(imageRefCounts.get('session-a:7:12'), 1);

      // Same turn, same image, but a *content* change still keeps the image ref
      // alive across the rebuild (mount before release, never a spurious zero).
      imageEvents.length = 0;
      renderTranscript(makeSnapshot([
        makeTurn('i0'),
        makeTurn('i1', { userContent: 'edited', images: [nextRef] }),
      ]));
      assert.deepEqual(imageEvents, ['mount:session-a:7:12', 'release:session-a:7:12']);
      assert.equal(imageRefCounts.get('session-a:7:12'), 1, 'ref must never hit zero');

      // --- A decode failure hands the decoded-pixel budget back --------------
      resetTranscriptForSession();
      imageEvents.length = 0;
      assert.equal(terminalActiveDecodedPixels, 0);
      const failingRef = { imageId: 21, contentVersion: 5, contentVersionText: '5' };
      const failingKey = 'session-a:21:5';
      const neighborRef = { imageId: 22, contentVersion: 6, contentVersionText: '6' };
      const neighborKey = 'session-a:22:6';
      const laterRef = { imageId: 23, contentVersion: 7, contentVersionText: '7' };
      const laterKey = 'session-a:23:7';
      imagePixelsByKey.set(failingKey, 400);
      imagePixelsByKey.set(neighborKey, 300);
      imagePixelsByKey.set(laterKey, 600);
      renderTranscript(makeSnapshot([
        makeTurn('d0', { images: [failingRef] }),
        makeTurn('d1', { images: [neighborRef] }),
      ]));
      const failingNode = mountedImageNodes().find((node) => node.key === failingKey);
      assert.equal(failingNode.cacheKey, failingKey);
      assert.equal(terminalActiveDecodedPixels, 700);

      // The browser rejects the (structurally valid) bytes, so the shared entry
      // is invalidated. The conversation node must hand its pixels back even
      // though its card is unchanged — otherwise the budget stays charged for an
      // image nothing displays until that card happens to change.
      clearConversationImageCacheKey(failingKey);
      assert.equal(terminalActiveDecodedPixels, 300, 'invalidation frees the budget');
      assert.equal(failingNode.cacheKey, null);
      assert.equal(failingNode.pixels, 0);
      assert.equal(failingNode.el.attributes.src, undefined, 'no revoked URL is left');
      assert.equal(failingNode.el.dataset.cacheKey, undefined);
      clearConversationImageCacheKey(failingKey);
      assert.equal(terminalActiveDecodedPixels, 300, 'clearing is idempotent');

      // Releasing that node later must not decrement the budget a second time.
      renderTranscript(makeSnapshot([
        makeTurn('d0', { userContent: 'edited' }),
        makeTurn('d1', { images: [neighborRef] }),
      ]));
      assert.equal(terminalActiveDecodedPixels, 300, 'no double decrement on release');

      // With the budget genuinely freed, a later image that could not have fit
      // alongside the leak now mounts.
      renderTranscript(makeSnapshot([
        makeTurn('d2', { images: [laterRef] }),
        makeTurn('d1', { images: [neighborRef] }),
      ]));
      assert.ok(
        imageEvents.includes(`mount:${laterKey}`),
        'freed budget lets a later image mount'
      );
      assert.equal(terminalActiveDecodedPixels, 900);
      resetTranscriptForSession();
      assert.equal(terminalActiveDecodedPixels, 0);

      // --- Hidden conversation pane holds no DOM and does no work -----------
      renderTranscript(makeSnapshot([
        makeTurn('h0', { images: [{ imageId: 9, contentVersion: 3, contentVersionText: '3' }] }),
        makeTurn('h1'), ...makeTurns(8, 'hidden-tail'),
      ]));
      assert.equal(cards().length, 10);
      assert.equal(imageRefCounts.get('session-a:9:3'), 1);
      const hiddenSnapshot = lastRenderedTranscript;
      transcript.scrollTop = 100;
      const hiddenAnchor = transcriptTopAnchor();

      setViewMode('terminal', { silent: true });
      assert.deepEqual(pendingTranscriptAnchor, hiddenAnchor, 'anchor is captured before CSS hides the pane');
      assert.equal(transcript.children.length, 0, 'a hidden pane keeps no cards in the DOM');
      assert.equal(transcriptCardCache.size, 0);
      assert.equal(mountedImageNodes().length, 0);
      assert.equal(imageRefCounts.get('session-a:9:3'), 0, 'hidden images release their refs');
      assert.equal(lastRenderedTranscript, hiddenSnapshot, 'the snapshot is retained');

      const domBefore = createdElements;
      const markdownBefore = markdownCalls;
      const mutationsBefore = domMutations;
      renderTranscript(makeSnapshot(makeTurns(6, 'h')));
      renderTranscript(makeSnapshot(makeTurns(7, 'h')));
      assert.equal(createdElements, domBefore, 'hidden pane must not build DOM');
      assert.equal(markdownCalls, markdownBefore, 'hidden pane must not parse markdown');
      assert.equal(domMutations, mutationsBefore, 'hidden pane must not touch the DOM');
      assert.equal(transcript.children.length, 0, 'and must stay empty');
      assert.equal(lastRenderedTranscript.turns.length, 7, 'latest snapshot is retained');

      // Revealing restores the reading position despite DOM disposal and updates.
      setViewMode('conversation', { silent: true });
      assert.equal(cards().length, 7);
      assert.equal(cardFor(hiddenAnchor.turnId).getBoundingClientRect().top, hiddenAnchor.top);
      assert.ok(createdElements > domBefore);
      transcript.scrollTop = transcript.scrollHeight - transcript.clientHeight;
      setViewMode('terminal', { silent: true });
      assert.equal(pendingTranscriptAnchor, null, 'bottom-following is not anchored');
      renderTranscript(makeSnapshot(makeTurns(8, 'h')));
      setViewMode('conversation', { silent: true });
      assert.equal(transcript.scrollTop, transcript.scrollHeight, 'bottom-following resumes after reveal');

      // --- Windowed fetch + "Show earlier" ---------------------------------
      resetTranscriptForSession();
      assert.equal(transcriptRenderLimit, 50);
      fetchCalls.length = 0;
      fetchTranscript({ sessionId: 'session-a' });
      assert.equal(fetchCalls.length, 1);
      assert.equal(fetchCalls[0].url, '/app/transcript?s=session-a&limit=50');
      fetchCalls[0].respond(makeSnapshot(makeTurns(50, 'w'), 120));
      await flush();
      assert.equal(cards().length, 50, 'only the requested window renders');
      assert.equal(showEarlierButton().textContent, 'Show earlier (70 more)');

      // Park the viewport mid-list so the anchor is a specific turn.
      transcript.scrollTop = 600;
      const anchorCard = transcript.children[6];
      const anchorTurnId = anchorCard.dataset.turnId;
      assert.ok(anchorTurnId);
      // Clicking keeps focus on the control itself: it is reused, not rebuilt.
      const earlierControl = showEarlierButton();
      earlierControl.focus();
      earlierControl.dispatch('click');
      assert.equal(transcriptRenderLimit, 100, 'window widens by one bounded step');
      assert.equal(fetchCalls.length, 2, 'withheld turns are refetched');
      assert.equal(fetchCalls[1].url, '/app/transcript?s=session-a&limit=100');

      // A revision lands while the wider window is in flight: it must not shrink
      // the chosen window, and the stale narrower response must not overwrite it.
      const beforeStale = cards().length;
      fetchCalls[0].respond(makeSnapshot(makeTurns(50, 'w'), 120));
      await flush();
      assert.equal(cards().length, beforeStale, 'stale narrow response ignored');
      assert.equal(transcriptRenderLimit, 100);

      fetchCalls[1].respond(makeSnapshot(makeTurns(100, 'w'), 120));
      await flush();
      assert.equal(cards().length, 100);
      assert.equal(showEarlierButton(), earlierControl, 'the control node is reused');
      assert.equal(document.activeElement, earlierControl, 'expansion keeps its own focus');
      assert.equal(showEarlierButton().textContent, 'Show earlier (20 more)');
      // The anchored turn is back at the exact viewport offset it was captured at.
      const restored = cardFor(anchorTurnId);
      assert.ok(restored, 'anchored turn is still rendered');
      assert.equal(restored.getBoundingClientRect().top, 0);

      // The window stops at the host's ceiling instead of growing without bound.
      showEarlierButton().dispatch('click');
      assert.equal(transcriptRenderLimit, 150);
      assert.equal(fetchCalls.length, 3);
      fetchCalls[2].respond(makeSnapshot(makeTurns(150, 'w'), 220));
      await flush();
      showEarlierButton().dispatch('click');
      assert.equal(transcriptRenderLimit, 200);
      assert.equal(fetchCalls.length, 4);
      fetchCalls[3].respond(makeSnapshot(makeTurns(200, 'w'), 220));
      await flush();
      const capped = showEarlierButton();
      assert.equal(capped.disabled, true, 'at the ceiling there is nothing to click');
      assert.equal(capped.textContent, '20 earlier turns not shown');
      capped.dispatch('click');
      assert.equal(transcriptRenderLimit, 200);
      assert.equal(fetchCalls.length, 4, 'a capped window issues no further fetch');

      // --- Older host: ignores `limit`, omits `totalTurns` -------------------
      resetTranscriptForSession();
      fetchCalls.length = 0;
      fetchTranscript({ sessionId: 'session-a' });
      fetchCalls[0].respond(makeSnapshot(makeTurns(120, 'o')));
      await flush();
      assert.equal(cards().length, 50, 'a full transcript is still trimmed client-side');
      assert.equal(showEarlierButton().textContent, 'Show earlier (70 more)');
      assert.equal(cards()[49].dataset.turnId, 'o119', 'newest turns are the ones kept');
      showEarlierButton().dispatch('click');
      assert.equal(transcriptRenderLimit, 100);
      assert.equal(fetchCalls.length, 1, 'nothing to refetch when nothing was withheld');
      assert.equal(cards().length, 100, 'the reveal renders from the snapshot in hand');

      // --- Stale-response guards -------------------------------------------
      const currentRequest = transcriptRequestId;
      assert.equal(transcriptResponseIsCurrent('session-a', currentRequest, 100), true);
      assert.equal(transcriptResponseIsCurrent('session-b', currentRequest, 100), false);
      assert.equal(transcriptResponseIsCurrent('session-a', currentRequest - 1, 100), false);
      assert.equal(transcriptResponseIsCurrent('session-a', currentRequest, 50), false);

      // --- Session switch drops session-scoped state and image ownership ----
      imageEvents.length = 0;
      renderTranscript(makeSnapshot([
        makeTurn('s0', { images: [{ imageId: 3, contentVersion: 4, contentVersionText: '4' }] }),
      ]));
      assert.equal(imageRefCounts.get('session-a:3:4'), 1);
      assert.equal(transcriptShowEarlier, null, 'removing the control releases its old snapshot closure');
      fetchCalls.length = 0;
      fetchTranscript({ sessionId: 'session-a' });
      const inFlight = fetchCalls[0];

      selected = 'session-b';
      resetTranscriptForSession();
      assert.equal(transcriptCardCache.size, 0, 'card cache is session-scoped');
      assert.equal(lastRenderedTranscript, null, 'retained snapshot is session-scoped');
      assert.equal(transcriptShowEarlier, null, 'the old control must not retain its snapshot closure');
      assert.equal(mountedImageNodes().length, 0);
      assert.equal(imageRefCounts.get('session-a:3:4'), 0, 'image refs are handed back');
      assert.equal(terminalActiveDecodedPixels, 0, 'and so is the decoded-pixel budget');
      assert.equal(transcriptRenderLimit, 50, 'the window resets for the new session');

      // The previous session's in-flight response can never land on the new one.
      const cardsAfterSwitch = cards().length;
      inFlight.respond(makeSnapshot(makeTurns(4, 'x'), 4));
      await flush();
      assert.equal(cards().length, cardsAfterSwitch, 'stale session response ignored');
      assert.equal(lastRenderedTranscript, null);

      // A render for the new session starts from an empty cache and keys its
      // cards to that session, so no cross-session card can ever be reused.
      renderTranscript(makeSnapshot([makeTurn('s0')]));
      assert.equal(transcriptCardCache.size, 1);
      assert.ok(transcriptCardCache.has(transcriptCardKey('session-b', 's0')));

      // --- Empty transcript -------------------------------------------------
      renderTranscript(makeSnapshot([]));
      assert.equal(cards().length, 0);
      assert.equal(transcriptCardCache.size, 0);
      assert.equal(transcript.children[0].textContent, 'Completed turns will appear here.');

      // --- Placeholders drop the cards they replace -------------------------
      renderTranscript(makeSnapshot([makeTurn('p0')]));
      assert.equal(cards().length, 1);
      showTranscriptPlaceholder('Could not load completed turns.');
      assert.equal(cards().length, 0);
      assert.equal(transcriptCardCache.size, 0);
      assert.equal(transcript.children[0].textContent, 'Could not load completed turns.');
    })().catch((error) => {
      console.error(error);
      process.exitCode = 1;
    });
    """#
}
