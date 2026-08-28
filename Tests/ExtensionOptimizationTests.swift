import XCTest
@testable import CopilotProjectsCore

/// Guards for the two background-overhead optimizations in the embedded Copilot
/// extension: the 5s poll's snapshot write rate, and the transcript byte-budget
/// trim. Both run the *real* extension source under Node — the poll tests boot
/// the whole extension against a fake SDK session, and the transcript tests
/// extract the shipped `encodedTranscriptWithinBudget` verbatim — so a
/// regression in the shipped script fails here rather than in production.
final class ExtensionOptimizationTests: XCTestCase {

    // MARK: - Transcript byte budget

    /// The trim is driven by exact encoded-byte accounting instead of
    /// re-encoding the whole document after every removal, so the arithmetic
    /// has to agree with `JSON.stringify` byte for byte: separating commas,
    /// UTF-8 (not UTF-16) sizes, JSON escaping and lone surrogates included.
    /// Every boundary below is asserted at ±1 byte, and the reduction order
    /// (non-foreground turns, then in-progress non-foreground payload, then
    /// foreground turns, never the resume marker or the in-progress turn as a
    /// whole) must be exactly what it was before.
    func testTranscriptBudgetTrimsOnExactEncodedByteBoundaries() throws {
        try requireNodeForJavaScriptTests()
        let summary = try runTranscriptHarness(
            name: "budget",
            assertions: Self.transcriptBudgetAssertions
        )
        XCTAssertGreaterThan(summary["fullBytes"] as? Int ?? 0, 0)
    }

    /// The scenario the audit measured: a single turn holding the 250-message
    /// cap, well over the 5 MiB budget. Shedding one message at a time used to
    /// re-encode the whole multi-megabyte document after every removal — ~114
    /// whole-document encodes and hundreds of megabytes of throwaway strings
    /// for one publish. Byte accounting bounds the whole-document encodes to a
    /// constant (measured through an instrumented `JSON.stringify`, so the
    /// production code carries no instrumentation of its own).
    func testTranscriptBudgetTrimsWithoutRepeatedWholeDocumentEncodes() throws {
        try requireNodeForJavaScriptTests()
        let summary = try runTranscriptHarness(
            name: "volume",
            assertions: Self.transcriptVolumeAssertions
        )
        let initialBytes = try XCTUnwrap(summary["initialBytes"] as? Int)
        let finalBytes = try XCTUnwrap(summary["finalBytes"] as? Int)
        XCTAssertGreaterThan(initialBytes, 5 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(finalBytes, 5 * 1_024 * 1_024)
        // Whole-document (>= 1 MiB) encodes: the fast-path probe and the final
        // encode. The previous implementation needed one per dropped message.
        XCTAssertLessThanOrEqual(summary["largeEncodes"] as? Int ?? .max, 3)
        XCTAssertLessThanOrEqual(
            summary["stringifyBytes"] as? Int ?? .max,
            initialBytes * 4
        )
        XCTAssertLessThan(summary["remainingMessages"] as? Int ?? .max, 250)
    }

    // MARK: - Poll heartbeat

    /// The host treats the snapshot's `updatedAt` as proof the session is still
    /// alive (its staleness thresholds are 10s and 15s). Liveness therefore
    /// cannot ride on the refresh RPCs: `schedule.list` can hang forever, and
    /// while it is outstanding the single-flight guard suppresses every later
    /// refresh. With both RPCs hung the poll must still republish every tick.
    func testPollPublishesHeartbeatWhileRefreshRpcsHang() throws {
        try requireNodeForJavaScriptTests()
        let summary = try runExtensionHarness(
            name: "heartbeat-hang",
            prelude: Self.hangingRpcPrelude,
            epilogue: Self.hangingRpcEpilogue
        )
        // The hung call keeps its single-flight lock forever, so the RPC is
        // never retried — and the heartbeat still advances on every tick.
        XCTAssertEqual(summary["scheduleListCalls"] as? Int, 1)
        XCTAssertGreaterThanOrEqual(summary["distinctHeartbeats"] as? Int ?? 0, 2)
    }

    /// Steady state: the schedule list and the model catalog come back
    /// unchanged on every tick. That used to publish the identical snapshot
    /// twice per tick (once per refresh); now the poll publishes the heartbeat
    /// itself and the refreshes publish only on an actual change.
    func testPollWritesOneSnapshotPerUnchangedTickAndRepublishesOnChange() throws {
        try requireNodeForJavaScriptTests()
        let summary = try runExtensionHarness(
            name: "heartbeat-steady",
            prelude: Self.steadyRpcPrelude,
            epilogue: Self.steadyRpcEpilogue,
            countSnapshotWrites: true
        )
        let steadyTicks = try XCTUnwrap(summary["steadyTicks"] as? Int)
        let steadyWrites = try XCTUnwrap(summary["steadyWrites"] as? Int)
        XCTAssertGreaterThanOrEqual(steadyTicks, 2)
        // Exactly one heartbeat per tick, plus at most one write straddling the
        // sampling window. Before the change this was two per tick.
        XCTAssertLessThanOrEqual(steadyWrites, steadyTicks + 1)
        XCTAssertGreaterThanOrEqual(steadyWrites, steadyTicks)
        XCTAssertEqual(summary["heartbeatAdvanced"] as? Bool, true)
        // The catalog still reaches the host, and a genuinely changed schedule
        // list still publishes on top of the tick's heartbeat.
        XCTAssertEqual(summary["publishedModels"] as? Int, 1)
        XCTAssertEqual(summary["publishedSchedules"] as? Int, 2)
        let changeTicks = try XCTUnwrap(summary["changeTicks"] as? Int)
        let changeWrites = try XCTUnwrap(summary["changeWrites"] as? Int)
        XCTAssertGreaterThanOrEqual(changeTicks, 2)
        XCTAssertGreaterThanOrEqual(changeWrites, changeTicks + 2)
    }

    /// A failing refresh still reports immediately, and a later success still
    /// clears the terminal-disconnect error even though the schedule entries
    /// themselves never changed — the recovery must not be swallowed by the
    /// change-only publish.
    func testScheduleRefreshRepublishesAfterTerminalDisconnectRecovers() throws {
        try requireNodeForJavaScriptTests()
        let summary = try runExtensionHarness(
            name: "heartbeat-disconnect",
            prelude: Self.disconnectRpcPrelude,
            epilogue: Self.disconnectRpcEpilogue
        )
        XCTAssertEqual(summary["sawError"] as? Bool, true)
        XCTAssertEqual(summary["errorCleared"] as? Bool, true)
    }

    // MARK: - Harnesses

    /// Extracts the shipped transcript-budget function (plus the text helpers
    /// it calls) and runs it under Node with an instrumented `JSON.stringify`.
    private func runTranscriptHarness(
        name: String,
        assertions: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        // Markers never carry leading whitespace: the script is a raw literal
        // whose indentation is stripped when Swift builds the string, so the
        // shipped `CopilotExtension.script` is not indented like the source
        // file it lives in. The `function ` prefixes keep each marker on the
        // declaration rather than a call site.
        let helpers = try extensionSlice(
            from: "function truncatedText(",
            to: "function restoreMatchingTranscript(",
            file: file,
            line: line
        )
        let budget = try extensionSlice(
            from: "function encodedTranscriptWithinBudget(",
            to: "function writeTranscriptSnapshot(",
            file: file,
            line: line
        )
        return try runNodeHarness(
            name: "transcript-\(name)",
            source: Self.transcriptPrelude + helpers + budget + assertions,
            environment: [:],
            file: file,
            line: line
        )
    }

    /// Boots the whole extension against a fake SDK session. The poll interval
    /// is shortened so a handful of ticks fit in a test, and (optionally) the
    /// snapshot write is counted — both are rewrites of the test's private copy
    /// of the script, never of the shipped source.
    private func runExtensionHarness(
        name: String,
        prelude: String,
        epilogue: String,
        countSnapshotWrites: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        var script = CopilotExtension.script
        for (original, replacement) in [
            (
                #"import { joinSession } from "@github/copilot-sdk/extension";"#,
                "const joinSession = async () => fakeSession;"
            ),
            (
                "const DURABLE_RECONCILE_POLL_MS = 5_000;",
                "const DURABLE_RECONCILE_POLL_MS = 80;"
            ),
        ] {
            XCTAssertTrue(
                script.contains(original),
                "extension script no longer contains: \(original)",
                file: file,
                line: line
            )
            script = script.replacingOccurrences(of: original, with: replacement)
        }
        if countSnapshotWrites {
            XCTAssertTrue(
                script.contains(Self.snapshotWriteCall),
                "extension script no longer writes the snapshot as expected",
                file: file,
                line: line
            )
            script = script.replacingOccurrences(
                of: Self.snapshotWriteCall,
                with: "globalThis.__snapshotWrites = "
                    + "(globalThis.__snapshotWrites || 0) + 1; "
                    + Self.snapshotWriteCall
            )
        }
        let root = harnessRoot(name: name)
        return try runNodeHarness(
            name: name,
            source: prelude + script + epilogue,
            root: root,
            environment: [
                "HOME": root.path,
                "COPILOT_HOME": root.appendingPathComponent("copilot").path,
                "COPILOT_PROJECTS_SESSION": Self.appSessionId,
                "COPILOT_PROJECTS_SOCKET": root.appendingPathComponent("app.sock").path,
                "COPILOT_PROJECTS_ROOT": root.path,
            ],
            file: file,
            line: line
        )
    }

    /// Slices the shipped script between two markers. Markers must be given
    /// without leading whitespace: `CopilotExtension.script` is a raw multi-line
    /// literal, so Swift strips the source file's indentation and the runtime
    /// string is not indented the way the file reads. The end marker is searched
    /// after the start so a marker that also appears earlier cannot invert the
    /// range.
    private func extensionSlice(
        from: String,
        to: String,
        file: StaticString,
        line: UInt
    ) throws -> String {
        let script = CopilotExtension.script
        XCTAssertFalse(
            from.hasPrefix(" ") || to.hasPrefix(" "),
            "extension markers must not depend on source indentation",
            file: file,
            line: line
        )
        let start = try XCTUnwrap(
            script.range(of: from),
            "extension script no longer contains: \(from)",
            file: file,
            line: line
        )
        let end = try XCTUnwrap(
            script.range(of: to, range: start.upperBound..<script.endIndex),
            "extension script no longer contains: \(to)",
            file: file,
            line: line
        )
        let slice = String(script[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(
            slice.isEmpty,
            "empty slice between \(from) and \(to)",
            file: file,
            line: line
        )
        return slice
    }

    private func harnessRoot(name: String) -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(
                ".build/copilot-extension-\(name)-\(UUID().uuidString)"
            )
    }

    @discardableResult
    private func runNodeHarness(
        name: String,
        source: String,
        root: URL? = nil,
        environment: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let directory = root ?? harnessRoot(name: name)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = directory.appendingPathComponent("\(name).mjs")
        try source.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", scriptURL.path]
        process.environment = ProcessInfo.processInfo.environment
            .merging(environment) { _, new in new }
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Read before waiting: a summary larger than the pipe buffer would
        // otherwise deadlock the harness against a full pipe.
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(data: errorOutput, encoding: .utf8) ?? "node harness failed",
            file: file,
            line: line
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: output) as? [String: Any],
            String(data: errorOutput, encoding: .utf8) ?? "no harness summary",
            file: file,
            line: line
        )
    }

    private static let appSessionId = "12345678-1234-1234-1234-123456789abc"

    /// The snapshot write, matched without leading whitespace so the test does
    /// not depend on how the raw literal is indented in the source file.
    private static let snapshotWriteCall =
        "writeFileSync(temporaryPath, JSON.stringify(snapshot), { mode: 0o600 });"
}

// MARK: - Harness fixtures

extension ExtensionOptimizationTests {

    /// Module scope for the extracted transcript helpers: the constants and
    /// mutable state the shipped function closes over, plus an instrumented
    /// `JSON.stringify` so the test can count serialization work without the
    /// production script carrying any instrumentation.
    fileprivate static let transcriptPrelude = #"""
    const MAX_TRANSCRIPT_TEXT = 50_000;
    const MAX_TRANSCRIPT_METADATA_TEXT = 512;
    let MAX_TRANSCRIPT_BYTES = 5 * 1024 * 1024;
    let copilotSessionId = "11111111-1111-4111-8111-111111111111";
    let latestResumeTranscriptTurnId = null;
    let transcriptTurns = [];

    const realStringify = JSON.stringify;
    let stringifyCalls = 0;
    let stringifyBytes = 0;
    let largeEncodes = 0;
    let largeEncodeThreshold = Infinity;
    JSON.stringify = function (...args) {
        const result = realStringify.apply(JSON, args);
        if (typeof result === "string") {
            stringifyCalls += 1;
            const length = Buffer.byteLength(result);
            stringifyBytes += length;
            if (length >= largeEncodeThreshold) largeEncodes += 1;
        }
        return result;
    };
    function resetCounters(threshold = Infinity) {
        stringifyCalls = 0;
        stringifyBytes = 0;
        largeEncodes = 0;
        largeEncodeThreshold = threshold;
    }

    import { ok as check, strictEqual as equal } from "node:assert/strict";

    const clone = (value) => JSON.parse(realStringify(value));
    const itemBytes = (value) => Buffer.byteLength(realStringify(value));
    const documentBytes = (turns, pending) => Buffer.byteLength(realStringify({
        schemaVersion: 3,
        updatedAt: new Date().toISOString(),
        copilotSessionId: boundedMetadataText(copilotSessionId),
        ownerPid: process.pid,
        turns: pending ? [...turns, pending] : turns.slice(),
    }));

    function message(id, content) {
        return { id, timestamp: "2026-07-12T00:00:00.000Z", content };
    }
    function turn(id, kind, messages, tools = []) {
        return {
            id,
            startedAt: "2026-07-12T00:00:00.000Z",
            endedAt: "2026-07-12T00:00:01.000Z",
            kind,
            userContent: "user " + id,
            assistantMessages: messages,
            tools,
            isAborted: false,
        };
    }
    function load(turns, resumeId = null) {
        transcriptTurns = clone(turns);
        latestResumeTranscriptTurnId = resumeId;
        return transcriptTurns;
    }

    """#

    fileprivate static let transcriptBudgetAssertions = #"""

    // --------------------------------------------------------------- boundaries
    // Content deliberately mixes multi-byte code points, escapes and a lone
    // surrogate: every size below is a UTF-8 byte count of the JSON encoding,
    // which a UTF-16 `length`-based accounting would get wrong.
    const unicodeMessages = [
        message("m0", "quote \" backslash \\ tab\t"),
        message("m1", "emoji 😀😀 kanji 漢字 accents ééé"),
        message("m2", "lone surrogate \ud800 and euro €€€"),
    ];
    const baseTurns = [turn("t0", "foreground", clone(unicodeMessages))];

    MAX_TRANSCRIPT_BYTES = Number.MAX_SAFE_INTEGER;
    load(baseTurns);
    resetCounters();
    const untouched = encodedTranscriptWithinBudget(null);
    const fullBytes = Buffer.byteLength(untouched);
    equal(stringifyCalls, 1, "an in-budget transcript costs exactly one encode");
    check(
        fullBytes !== untouched.length,
        "fixture must contain multi-byte content (UTF-8 bytes != UTF-16 length)"
    );

    // Exactly at the budget: nothing is trimmed.
    MAX_TRANSCRIPT_BYTES = fullBytes;
    load(baseTurns);
    resetCounters();
    const atBudget = encodedTranscriptWithinBudget(null);
    equal(Buffer.byteLength(atBudget), fullBytes, "budget == size keeps every byte");
    equal(
        transcriptTurns[0].assistantMessages.length, 3,
        "budget == size sheds nothing"
    );
    equal(stringifyCalls, 1, "budget == size still costs one encode");

    // One byte of headroom: nothing is trimmed.
    MAX_TRANSCRIPT_BYTES = fullBytes + 1;
    load(baseTurns);
    equal(
        Buffer.byteLength(encodedTranscriptWithinBudget(null)), fullBytes,
        "budget == size + 1 keeps every byte"
    );

    // One byte over: exactly the oldest message (and its comma) goes.
    const firstMessageCost = itemBytes(unicodeMessages[0]) + 1;
    MAX_TRANSCRIPT_BYTES = fullBytes - 1;
    load(baseTurns);
    const overByOne = encodedTranscriptWithinBudget(null);
    equal(
        Buffer.byteLength(overByOne), fullBytes - firstMessageCost,
        "budget == size - 1 sheds exactly one message plus its separator"
    );
    equal(transcriptTurns[0].assistantMessages.length, 2, "exactly one message shed");
    check(
        Buffer.byteLength(overByOne) <= MAX_TRANSCRIPT_BYTES,
        "result honors the hard budget"
    );

    // Landing exactly on the post-shed size must not shed a second message.
    MAX_TRANSCRIPT_BYTES = fullBytes - firstMessageCost;
    load(baseTurns);
    const exactlyOneShed = encodedTranscriptWithinBudget(null);
    equal(
        transcriptTurns[0].assistantMessages.length, 2,
        "budget equal to the post-shed size sheds exactly one message"
    );
    equal(
        Buffer.byteLength(exactlyOneShed), fullBytes - firstMessageCost,
        "post-shed size is exact"
    );

    // One byte below that: a second message goes, again exactly.
    const secondMessageCost = itemBytes(unicodeMessages[1]) + 1;
    MAX_TRANSCRIPT_BYTES = fullBytes - firstMessageCost - 1;
    load(baseTurns);
    const twoShed = encodedTranscriptWithinBudget(null);
    equal(transcriptTurns[0].assistantMessages.length, 1, "exactly two messages shed");
    equal(
        Buffer.byteLength(twoShed), fullBytes - firstMessageCost - secondMessageCost,
        "two-message shed size is exact"
    );

    // ----------------------------------------------------------------- priority
    const scheduledTurn = turn(
        "scheduled", "scheduled", [message("s0", "scheduled work")]
    );
    const foregroundOne = turn("fg1", "foreground", [message("f0", "first answer")]);
    const resumeTurn = turn("resume", "automated", [message("r0", "Session resumed.")]);
    const foregroundTwo = turn("fg2", "foreground", [message("f1", "second answer")]);
    const storedTurns = [scheduledTurn, foregroundOne, resumeTurn, foregroundTwo];
    const pendingTurn = turn("pending", "scheduled", [
        message("p0", "pending one"),
        message("p1", "pending two"),
    ]);

    MAX_TRANSCRIPT_BYTES = Number.MAX_SAFE_INTEGER;
    load(storedTurns, "resume");
    const fullWithPending = Buffer.byteLength(
        encodedTranscriptWithinBudget(clone(pendingTurn))
    );

    // A single byte over budget sacrifices the scheduled turn, nothing else.
    MAX_TRANSCRIPT_BYTES = fullWithPending - 1;
    load(storedTurns, "resume");
    let pending = clone(pendingTurn);
    encodedTranscriptWithinBudget(pending);
    equal(
        transcriptTurns.map((entry) => entry.id).join(","), "fg1,resume,fg2",
        "non-foreground stored turns are sacrificed first"
    );
    equal(pending.assistantMessages.length, 2, "pending payload survives phase 1");

    // Tighter: the in-progress non-foreground turn sheds payload before any
    // foreground turn is touched.
    MAX_TRANSCRIPT_BYTES = fullWithPending
        - itemBytes(scheduledTurn) - 1
        - itemBytes(pendingTurn.assistantMessages[0]) - 1;
    load(storedTurns, "resume");
    pending = clone(pendingTurn);
    encodedTranscriptWithinBudget(pending);
    equal(
        transcriptTurns.map((entry) => entry.id).join(","), "fg1,resume,fg2",
        "foreground turns survive while pending payload can still be shed"
    );
    equal(pending.assistantMessages.length, 1, "pending sheds exactly one message");

    // Tighter still: foreground turns go, oldest first; the resume marker and the
    // in-progress turn are never dropped whole. This budget is the tightest the
    // reduction order can actually reach — the envelope plus both protected turns
    // stripped of payload.
    const stripped = (entry) => ({ ...entry, assistantMessages: [], tools: [] });
    MAX_TRANSCRIPT_BYTES = documentBytes(
        [stripped(resumeTurn)], stripped(pendingTurn)
    );
    load(storedTurns, "resume");
    pending = clone(pendingTurn);
    const squeezed = encodedTranscriptWithinBudget(pending);
    equal(
        Buffer.byteLength(squeezed), MAX_TRANSCRIPT_BYTES,
        "reduction lands exactly on the reachable floor"
    );
    const survivors = JSON.parse(squeezed).turns.map((entry) => entry.id);
    check(survivors.includes("resume"), "the resume marker is never dropped");
    check(survivors.includes("pending"), "the in-progress turn is never dropped");
    check(!survivors.includes("fg1"), "the oldest foreground turn is dropped first");

    // An impossible budget must fail explicitly, never discard protected turns.
    MAX_TRANSCRIPT_BYTES = documentBytes([], null) + 5;
    load(storedTurns, "resume");
    pending = clone(pendingTurn);
    let rejected = false;
    try { encodedTranscriptWithinBudget(pending); }
    catch (error) { rejected = error instanceof RangeError; }
    check(rejected, "an unreachable budget is rejected");
    check(transcriptTurns.some((turn) => turn.id === "resume"), "resume remains protected");
    equal(pending.id, "pending", "pending remains protected");

    // ---------------------------------------------------------------- republish
    // Trimming mutates the shared turn objects, so the next publish is a plain
    // encode with nothing left to do.
    MAX_TRANSCRIPT_BYTES = fullBytes - firstMessageCost - 1;
    load(baseTurns);
    encodedTranscriptWithinBudget(null);
    const retained = clone(transcriptTurns);
    resetCounters();
    const republished = encodedTranscriptWithinBudget(null);
    equal(stringifyCalls, 1, "a republish after trimming costs one encode");
    check(
        Buffer.byteLength(republished) <= MAX_TRANSCRIPT_BYTES,
        "republish stays within budget"
    );
    equal(
        realStringify(clone(transcriptTurns)), realStringify(retained),
        "a republish does not shed anything further"
    );

    console.log(realStringify({ fullBytes }));

    """#

    fileprivate static let transcriptVolumeAssertions = #"""

    const heavyMessages = [];
    for (let index = 0; index < 250; index += 1) {
        heavyMessages.push(
            message("h" + index, ("chunk " + index + " ").repeat(3800))
        );
    }
    load([turn("heavy", "foreground", heavyMessages)]);
    MAX_TRANSCRIPT_BYTES = 5 * 1024 * 1024;
    const initialBytes = documentBytes(transcriptTurns, null);
    check(initialBytes > MAX_TRANSCRIPT_BYTES, "fixture must exceed the budget");

    // Count only encodes of at least 1 MiB: those are whole-document passes,
    // the cost the accounting exists to avoid.
    resetCounters(1024 * 1024);
    const trimmed = encodedTranscriptWithinBudget(null);
    check(
        Buffer.byteLength(trimmed) <= MAX_TRANSCRIPT_BYTES,
        "heavy transcript honors the hard budget: " + Buffer.byteLength(trimmed)
    );
    check(
        transcriptTurns[0].assistantMessages.length < 250,
        "heavy transcript actually shed messages"
    );

    console.log(realStringify({
        initialBytes,
        finalBytes: Buffer.byteLength(trimmed),
        largeEncodes,
        stringifyBytes,
        remainingMessages: transcriptTurns[0].assistantMessages.length,
    }));

    """#
}

// MARK: - Poll harness fixtures

extension ExtensionOptimizationTests {

    /// Shared epilogue helpers: reading the published snapshot, and a sleep.
    fileprivate static let snapshotReaderHelpers = #"""

    const snapshotFile = `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
        + `${process.env.COPILOT_PROJECTS_SESSION}.agent-activity.json`;
    const readSnapshot = () => JSON.parse(readFileSync(snapshotFile, "utf8"));
    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

    """#

    fileprivate static let hangingRpcPrelude = #"""
    let scheduleListCalls = 0;
    const fakeSession = {
        sessionId: "11111111-1111-4111-8111-111111111111",
        rpc: {
            schedule: {
                list: () => {
                    scheduleListCalls += 1;
                    return new Promise(() => {});
                },
            },
            model: { list: () => new Promise(() => {}) },
            permissions: { getAllowAll: async () => ({ enabled: false }) },
        },
        on() {},
        async getEvents() { return []; },
    };

    """#

    fileprivate static var hangingRpcEpilogue: String {
        snapshotReaderHelpers + #"""

        await sleep(200);
        const first = readSnapshot().updatedAt;
        const heartbeats = new Set();
        for (let index = 0; index < 6; index += 1) {
            await sleep(100);
            heartbeats.add(readSnapshot().updatedAt);
        }
        heartbeats.delete(first);
        console.log(JSON.stringify({
            scheduleListCalls,
            distinctHeartbeats: heartbeats.size,
        }));
        process.exit(0);

        """#
    }

    fileprivate static let steadyRpcPrelude = #"""
    let scheduleListCalls = 0;
    let mutations = 0;
    globalThis.__mutate = false;
    const fakeSession = {
        sessionId: "11111111-1111-4111-8111-111111111111",
        rpc: {
            schedule: {
                list: async () => {
                    scheduleListCalls += 1;
                    const entries = [{ id: "s1", prompt: "daily", cron: "0 9 * * *" }];
                    if (globalThis.__mutate) {
                        mutations += 1;
                        entries.push({
                            id: "s" + mutations,
                            prompt: "weekly",
                            cron: "0 9 * * 1",
                        });
                    }
                    return { entries };
                },
            },
            model: {
                list: async () => ({
                    list: [{ id: "gpt-5", name: "GPT-5", policy: null }],
                }),
            },
            permissions: { getAllowAll: async () => ({ enabled: false }) },
        },
        on() {},
        async getEvents() { return []; },
    };

    """#

    fileprivate static var steadyRpcEpilogue: String {
        snapshotReaderHelpers + #"""

        // Let startup settle (bootstrap publish, first catalog publish) before
        // sampling the steady state.
        await sleep(300);
        const baselineWrites = globalThis.__snapshotWrites || 0;
        const baselineTicks = scheduleListCalls;
        const baselineUpdatedAt = readSnapshot().updatedAt;

        await sleep(600);
        const steadyWrites = (globalThis.__snapshotWrites || 0) - baselineWrites;
        const steadyTicks = scheduleListCalls - baselineTicks;
        const steadySnapshot = readSnapshot();

        // A real change must still publish without waiting for anything: from
        // here every refresh returns a different list, so a change-only publish
        // fires on top of each tick's heartbeat.
        globalThis.__mutate = true;
        const changeBaselineWrites = globalThis.__snapshotWrites || 0;
        const changeBaselineTicks = scheduleListCalls;
        await sleep(400);

        console.log(JSON.stringify({
            steadyWrites,
            steadyTicks,
            changeWrites: (globalThis.__snapshotWrites || 0) - changeBaselineWrites,
            changeTicks: scheduleListCalls - changeBaselineTicks,
            heartbeatAdvanced: steadySnapshot.updatedAt !== baselineUpdatedAt,
            publishedModels: (steadySnapshot.availableModels || []).length,
            publishedSchedules: readSnapshot().schedules.length,
        }));
        process.exit(0);

        """#
    }

    fileprivate static let disconnectRpcPrelude = #"""
    let scheduleListCalls = 0;
    const fakeSession = {
        sessionId: "11111111-1111-4111-8111-111111111111",
        rpc: {
            schedule: {
                list: async () => {
                    scheduleListCalls += 1;
                    // The entries never change, so only the recovered
                    // connection can justify the republish below.
                    if (scheduleListCalls <= 2) {
                        throw new Error("The connection is closed");
                    }
                    return { entries: [] };
                },
            },
            model: { list: async () => ({ list: [] }) },
            permissions: { getAllowAll: async () => ({ enabled: false }) },
        },
        on() {},
        async getEvents() { return []; },
    };

    """#

    fileprivate static var disconnectRpcEpilogue: String {
        snapshotReaderHelpers + #"""

        let sawError = false;
        let errorCleared = false;
        for (let index = 0; index < 60; index += 1) {
            await sleep(50);
            let snapshot;
            try { snapshot = readSnapshot(); } catch { continue; }
            if (typeof snapshot.error === "string" && snapshot.error.length > 0) {
                sawError = true;
            } else if (sawError && scheduleListCalls > 2) {
                errorCleared = true;
                break;
            }
        }
        console.log(JSON.stringify({ sawError, errorCleared, scheduleListCalls }));
        process.exit(0);

        """#
    }
}
