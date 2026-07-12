import Foundation

public enum CopilotExtension {
    public static var extensionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/extensions", isDirectory: true)
    }

    public static var extensionDir: URL {
        extensionsDir.appendingPathComponent("copilot-projects-tracker", isDirectory: true)
    }

    public static var scriptURL: URL {
        extensionDir.appendingPathComponent("extension.mjs")
    }

    public static let script = #"""
    import { dirname, join } from "node:path";
    import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
    import { joinSession } from "@github/copilot-sdk/extension";

    const appSessionId = process.env.COPILOT_PROJECTS_SESSION
        || process.env.COPILOT_MUX_SESSION;
    const socketPath = process.env.COPILOT_PROJECTS_SOCKET
        || process.env.COPILOT_MUX_SOCKET;
    const validSessionId = /^[0-9A-Fa-f-]{36}$/.test(appSessionId || "");

    const session = await joinSession();

    if (validSessionId && socketPath) {
        const sessionsDir = join(dirname(socketPath), "sessions");
        const snapshotPath = join(sessionsDir, `${appSessionId}.agent-activity.json`);
        const transcriptPath = join(sessionsDir, `${appSessionId}.transcript.json`);
        const transcriptOwnerPath = join(sessionsDir, `${appSessionId}.transcript-owner.json`);
        const transcriptOwnerLockPath = `${transcriptOwnerPath}.lock`;
        const scheduledTurnPath = join(sessionsDir, `${appSessionId}.scheduled-turn`);
        const activeSubagents = new Map();
        let foregroundTurnActive = false;
        let scheduledTurnActive = false;
        let currentTurnKind = null;
        let idleGeneration = 0;
        let lastIdleAborted = false;
        let lastIdleTurnKind = null;
        let schedules = [];
        const transcriptTurns = [];
        const transcriptEventIds = new Set();
        const queuedTranscriptEvents = [];
        let pendingTranscriptTurn = null;
        let transcriptInitialized = false;
        let transcriptPublishTimer = null;

        const MAX_TRANSCRIPT_TURNS = 200;
        const MAX_TRANSCRIPT_BYTES = 5 * 1024 * 1024;
        const MAX_TRANSCRIPT_TEXT = 50_000;
        const MAX_TRANSCRIPT_METADATA_TEXT = 512;
        const MAX_TRANSCRIPT_ASSISTANT_MESSAGES = 250;
        const MAX_TRANSCRIPT_TOOLS = 400;
        const TRANSCRIPT_PUBLISH_THROTTLE_MS = 400;

        function truncatedText(value, maximumLength) {
            const text = typeof value === "string" ? value : "";
            if (text.length <= maximumLength) return text;
            let truncated = text.slice(0, maximumLength);
            const finalCodeUnit = truncated.charCodeAt(truncated.length - 1);
            if (finalCodeUnit >= 0xD800 && finalCodeUnit <= 0xDBFF) {
                truncated = truncated.slice(0, -1);
            }
            return truncated;
        }

        function boundedText(value) {
            const text = typeof value === "string" ? value : "";
            if (text.length <= MAX_TRANSCRIPT_TEXT) return text;
            return `${truncatedText(text, MAX_TRANSCRIPT_TEXT)}\n… truncated …`;
        }

        function boundedMetadataText(value) {
            return truncatedText(value, MAX_TRANSCRIPT_METADATA_TEXT);
        }

        function restoreMatchingTranscript() {
            try {
                const encoded = readFileSync(transcriptPath, "utf8");
                if (Buffer.byteLength(encoded) > MAX_TRANSCRIPT_BYTES) return false;
                const snapshot = JSON.parse(encoded);
                if (snapshot.schemaVersion !== 3
                        || snapshot.copilotSessionId
                            !== boundedMetadataText(session.sessionId)
                        || !Array.isArray(snapshot.turns)) return false;
                transcriptTurns.push(
                    ...snapshot.turns.slice(-MAX_TRANSCRIPT_TURNS)
                );
                return true;
            } catch {
                return false;
            }
        }

        // Several Copilot processes can share one app session id: a `copilot -p`
        // classifier (or any spawned CLI) inherits COPILOT_PROJECTS_SESSION from
        // the terminal and would otherwise clobber the interactive session's
        // shared files (transcript, agent-activity, scheduled-turn marker) with
        // its own events. Only the process that owns the app session may write
        // them. Ownership is re-evaluated per write and reclaimed whenever the
        // recorded owner is gone, so the live interactive session recovers
        // automatically after a restart.
        function processAlive(pid) {
            if (!Number.isInteger(pid) || pid <= 0) return false;
            try {
                process.kill(pid, 0);
                return true;
            } catch (error) {
                return Boolean(error) && error.code === "EPERM";
            }
        }

        function recordedOwner() {
            try {
                return JSON.parse(readFileSync(transcriptOwnerPath, "utf8"));
            } catch {
                return null;
            }
        }

        function ownerMatchesCurrentProcess(owner) {
            return Boolean(owner)
                && owner.copilotSessionId === session.sessionId
                && owner.pid === process.pid;
        }

        function ownerMatches(left, right) {
            return Boolean(left) && Boolean(right)
                && left.copilotSessionId === right.copilotSessionId
                && left.pid === right.pid;
        }

        // Read-only: are we the process currently recorded as owner? Never claims
        // or writes, so it is safe to call from cleanup without a live different
        // owner losing its marker to an exiting guest.
        function isRecordedOwner() {
            return ownerMatchesCurrentProcess(recordedOwner());
        }

        function writeOwnerMarker() {
            try {
                writeFileSync(
                    transcriptOwnerPath,
                    JSON.stringify({
                        copilotSessionId: session.sessionId,
                        pid: process.pid,
                    }),
                    { flag: "wx", mode: 0o600 }
                );
                return true;
            } catch {
                return false;
            }
        }

        function withTranscriptOwnerLock(action) {
            try {
                writeFileSync(
                    transcriptOwnerLockPath,
                    JSON.stringify({
                        copilotSessionId: session.sessionId,
                        pid: process.pid,
                    }),
                    { flag: "wx", mode: 0o600 }
                );
            } catch {
                return false;
            }
            try {
                return action();
            } finally {
                removeFile(transcriptOwnerLockPath);
            }
        }

        function reclaimDeadOwner(expectedOwner) {
            return withTranscriptOwnerLock(() => {
                const owner = recordedOwner();
                if (!owner) return writeOwnerMarker();
                if (ownerMatchesCurrentProcess(owner)) return true;
                if (processAlive(owner.pid)) return false;
                if (!ownerMatches(owner, expectedOwner)) return false;
                try { rmSync(transcriptOwnerPath, { force: true }); } catch {}
                return writeOwnerMarker();
            });
        }

        // Claiming: returns true if this process may write shared files. Claims
        // ownership atomically (exclusive create) when the marker is absent or
        // held by a dead process. Stale-owner reclamation is serialized so a
        // process that read the stale marker cannot delete a fresh winner's
        // marker. Returns false if another live process owns it or the claim is
        // lost.
        function ownsSharedFiles() {
            for (let attempt = 0; attempt < 3; attempt += 1) {
                const owner = recordedOwner();
                if (owner) {
                    if (ownerMatchesCurrentProcess(owner)) return true;
                    if (processAlive(owner.pid)) return false;
                    if (reclaimDeadOwner(owner)) return true;
                } else if (writeOwnerMarker()) {
                    return true;
                } else {
                    // Lost the create race; re-read and re-evaluate.
                }
            }
            return ownerMatchesCurrentProcess(recordedOwner());
        }

        function normalizedTimestamp(value) {
            const date = new Date(value);
            return Number.isNaN(date.getTime())
                ? new Date().toISOString()
                : date.toISOString();
        }

        function removeFile(path) {
            try {
                rmSync(path, { force: true });
            } catch {}
        }

        function setScheduledTurnMarker(active) {
            if (!ownsSharedFiles()) return;
            try {
                if (active) {
                    writeFileSync(scheduledTurnPath, "");
                } else {
                    rmSync(scheduledTurnPath, { force: true });
                }
            } catch {}
        }

        try {
            mkdirSync(sessionsDir, { recursive: true });
        } catch {}

        function publish(error) {
            if (!ownsSharedFiles()) return;
            const snapshot = {
                schemaVersion: 1,
                updatedAt: new Date().toISOString(),
                foregroundTurnActive,
                scheduledTurnActive,
                activeSubagents: [...activeSubagents.values()],
                schedules,
                idleGeneration,
                lastIdleAborted,
                lastIdleTurnKind,
                ...(error ? { error: String(error) } : {}),
            };
            const temporaryPath = `${snapshotPath}.${process.pid}.tmp`;
            try {
                writeFileSync(temporaryPath, JSON.stringify(snapshot));
                renameSync(temporaryPath, snapshotPath);
            } catch {
                removeFile(temporaryPath);
            }
        }

        function trimTranscriptTurns(maximumTurns = MAX_TRANSCRIPT_TURNS) {
            // Keep the transcript bounded, but never let automated or scheduled
            // activity evict the human conversation: drop the oldest non-foreground
            // turn first, and only fall back to the oldest foreground turn once no
            // other turns remain.
            while (transcriptTurns.length > maximumTurns) {
                let index = transcriptTurns.findIndex(
                    (turn) => turn.kind !== "foreground"
                );
                if (index === -1) index = 0;
                transcriptTurns.splice(index, 1);
            }
        }

        function serializedPendingTurn() {
            const turn = pendingTranscriptTurn;
            if (!turn) return null;
            if (!turn.userContent
                    && turn.assistantMessages.length === 0
                    && turn.tools.length === 0) return null;
            return {
                id: turn.id,
                startedAt: turn.startedAt,
                endedAt: null,
                kind: turn.kind,
                userContent: turn.userContent,
                assistantMessages: turn.assistantMessages,
                tools: turn.tools,
                isAborted: false,
            };
        }

        // Serializes the transcript within the byte budget while protecting the
        // human conversation. Reduction order sacrifices the least valuable
        // content first: whole non-foreground turns, then non-foreground payload
        // (including an in-progress scheduled/automated turn), then whole
        // foreground turns, then foreground payload — never the in-progress
        // turn as a whole. Whole-turn drops mutate transcriptTurns and payload
        // shedding mutates the shared turn objects, so repeated publishes don't
        // redo the work.
        function encodedTranscriptWithinBudget(pending) {
            const build = () => ({
                schemaVersion: 3,
                updatedAt: new Date().toISOString(),
                copilotSessionId: boundedMetadataText(session.sessionId),
                ownerPid: process.pid,
                turns: pending ? [...transcriptTurns, pending] : transcriptTurns.slice(),
            });
            let snapshot = build();
            let encoded = JSON.stringify(snapshot);
            const overBudget = () => Buffer.byteLength(encoded) > MAX_TRANSCRIPT_BYTES;
            const reencode = () => { encoded = JSON.stringify(snapshot); };
            const shedOldestPayload = (predicate) => {
                for (const turn of snapshot.turns) {
                    if (!predicate(turn)) continue;
                    if (turn.assistantMessages.length > 0) {
                        turn.assistantMessages.shift();
                        return true;
                    }
                    if (turn.tools.length > 0) {
                        turn.tools.shift();
                        return true;
                    }
                }
                return false;
            };

            // Phase 1: drop whole non-foreground stored turns (oldest first).
            while (overBudget()) {
                const index = transcriptTurns.findIndex(
                    (turn) => turn.kind !== "foreground"
                );
                if (index === -1) break;
                transcriptTurns.splice(index, 1);
                snapshot = build();
                reencode();
            }
            // Phase 2: shed payload from any remaining non-foreground turn (i.e. an
            // in-progress scheduled/automated turn) before touching foreground.
            while (overBudget()
                    && shedOldestPayload((turn) => turn.kind !== "foreground")) {
                reencode();
            }
            // Phase 3: drop whole foreground stored turns (oldest), never pending,
            // leaving at least one turn for payload shedding below.
            const minStored = pending ? 0 : 1;
            while (overBudget() && transcriptTurns.length > minStored) {
                transcriptTurns.splice(0, 1);
                snapshot = build();
                reencode();
            }
            // Phase 4: shed payload from the last remaining turn(s).
            while (overBudget() && shedOldestPayload(() => true)) {
                reencode();
            }
            return encoded;
        }

        function writeTranscriptSnapshot() {
            const pending = serializedPendingTurn();
            trimTranscriptTurns(pending ? MAX_TRANSCRIPT_TURNS - 1 : MAX_TRANSCRIPT_TURNS);
            const encoded = encodedTranscriptWithinBudget(pending);
            const temporaryPath = `${transcriptPath}.${process.pid}.tmp`;
            try {
                writeFileSync(temporaryPath, encoded, { mode: 0o600 });
                renameSync(temporaryPath, transcriptPath);
            } catch {
                removeFile(temporaryPath);
            }
        }

        function publishTranscript() {
            if (!ownsSharedFiles()) return;
            clearTimeout(transcriptPublishTimer);
            transcriptPublishTimer = null;
            writeTranscriptSnapshot();
        }

        function schedulePublishTranscript() {
            if (transcriptPublishTimer) return;
            transcriptPublishTimer = setTimeout(() => {
                transcriptPublishTimer = null;
                publishTranscript();
            }, TRANSCRIPT_PUBLISH_THROTTLE_MS);
        }

        // A transcript turn spans a whole user request: the visible user message
        // plus every agentic loop iteration (assistant.turn_start/turn_end fire
        // many times per request) until the next visible user message or
        // session.idle. `kind` is "foreground" (typed by a person), "scheduled"
        // (a recurring prompt), or "automated" (assistant activity with no
        // preceding visible message).
        function startTranscriptTurn(event, kind) {
            pendingTranscriptTurn = {
                id: boundedMetadataText(event.id),
                startedAt: normalizedTimestamp(event.timestamp),
                endedAt: null,
                kind,
                userContent: kind === "automated"
                    ? ""
                    : boundedText(event.data.content),
                assistantMessages: [],
                tools: [],
                isAborted: false,
            };
        }

        function ensureSyntheticTranscriptTurn(event) {
            if (pendingTranscriptTurn) return;
            startTranscriptTurn(event, "automated");
        }

        function finishTranscriptTurn(aborted, endedAt) {
            const turn = pendingTranscriptTurn;
            pendingTranscriptTurn = null;
            if (!turn) return;
            turn.isAborted = aborted === true;
            let end = endedAt ? normalizedTimestamp(endedAt) : turn.startedAt;
            // A boundary event (e.g. a queued live idle) can carry a timestamp
            // earlier than this turn's start; never record a negative duration.
            if (end < turn.startedAt) end = turn.startedAt;
            turn.endedAt = end;
            if (!turn.userContent
                    && turn.assistantMessages.length === 0
                    && turn.tools.length === 0) return;
            transcriptTurns.push(turn);
            trimTranscriptTurns();
        }

        // Classifies a root-level user.message. Genuine human input arrives with
        // no source; recurring prompts use "schedule-*". Every other source
        // (skill context, system reminders) is injected machinery that must not
        // become its own turn — its work folds into the current human turn.
        // NB: parentAgentTaskId is set on real human messages too, so it must not
        // be used to suppress input.
        function classifyUserMessage(event) {
            const source = event.data.source;
            if (source === null || source === undefined) return "foreground";
            if (typeof source === "string" && source.startsWith("schedule-")) {
                return "scheduled";
            }
            return null;
        }

        function toolTitle(data) {
            return data.toolDescription?.name
                || data.toolName
                || "Tool";
        }

        function processTranscriptEvent(event, live, reconciling = false) {
            if (event.agentId) return;
            if (reconciling) {
                if (transcriptEventIds.has(event.id)) return;
                transcriptEventIds.add(event.id);
            }

            switch (event.type) {
            case "user.message": {
                const kind = classifyUserMessage(event);
                if (kind) {
                    finishTranscriptTurn(false, event.timestamp);
                    startTranscriptTurn(event, kind);
                    if (live) publishTranscript();
                }
                // Injected context (skill/system) is not its own turn; the work
                // it triggers folds into the current human turn.
                break;
            }
            case "assistant.message":
                ensureSyntheticTranscriptTurn(event);
                if (event.data.content) {
                    if (pendingTranscriptTurn.assistantMessages.length
                            >= MAX_TRANSCRIPT_ASSISTANT_MESSAGES) {
                        pendingTranscriptTurn.assistantMessages.shift();
                    }
                    pendingTranscriptTurn.assistantMessages.push({
                        id: boundedMetadataText(event.data.messageId || event.id),
                        timestamp: normalizedTimestamp(event.timestamp),
                        content: boundedText(event.data.content),
                    });
                    if (live) schedulePublishTranscript();
                }
                break;
            case "tool.execution_start": {
                ensureSyntheticTranscriptTurn(event);
                const toolId = boundedMetadataText(event.data.toolCallId);
                const existing = pendingTranscriptTurn.tools.find(
                    (tool) => tool.id === toolId
                );
                if (!existing
                        && pendingTranscriptTurn.tools.length
                            < MAX_TRANSCRIPT_TOOLS) {
                    pendingTranscriptTurn.tools.push({
                        id: toolId,
                        name: boundedMetadataText(event.data.toolName),
                        title: boundedMetadataText(toolTitle(event.data)),
                        success: null,
                    });
                }
                if (live) schedulePublishTranscript();
                break;
            }
            case "tool.execution_complete": {
                ensureSyntheticTranscriptTurn(event);
                const toolId = boundedMetadataText(event.data.toolCallId);
                let tool = pendingTranscriptTurn.tools.find(
                    (candidate) => candidate.id === toolId
                );
                if (!tool
                        && pendingTranscriptTurn.tools.length
                            < MAX_TRANSCRIPT_TOOLS) {
                    tool = {
                        id: toolId,
                        name: "tool",
                        title: boundedMetadataText(
                            event.data.toolDescription?.name || "Tool"
                        ),
                        success: null,
                    };
                    pendingTranscriptTurn.tools.push(tool);
                }
                if (tool) tool.success = event.data.success === true;
                if (live) schedulePublishTranscript();
                break;
            }
            case "assistant.turn_end":
                // One agentic loop iteration finished, not the whole request.
                // Do not end the transcript turn here; just flush progress.
                if (live && pendingTranscriptTurn) schedulePublishTranscript();
                break;
            case "session.idle":
                finishTranscriptTurn(event.data.aborted === true, event.timestamp);
                if (live) publishTranscript();
                break;
            }
        }

        session.on((event) => {
            if (!transcriptInitialized) {
                queuedTranscriptEvents.push(event);
            } else {
                processTranscriptEvent(event, true);
            }
        });

        async function refreshSchedules() {
            try {
                const result = await session.rpc.schedule.list();
                schedules = result.entries;
                publish();
            } catch (error) {
                publish(error);
            }
        }

        session.on("user.message", (event) => {
            if (event.agentId) return;
            lastIdleTurnKind = null;
            currentTurnKind = event.data.source?.startsWith("schedule-")
                ? "scheduled"
                : "foreground";
            setScheduledTurnMarker(currentTurnKind === "scheduled");
        });

        session.on("assistant.turn_start", (event) => {
            if (event.agentId) return;
            lastIdleTurnKind = null;
            scheduledTurnActive = currentTurnKind === "scheduled";
            foregroundTurnActive = !scheduledTurnActive;
            if (scheduledTurnActive) setScheduledTurnMarker(true);
            publish();
        });

        session.on("assistant.turn_end", (event) => {
            if (event.agentId) return;
            foregroundTurnActive = false;
            publish();
        });

        session.on("session.idle", (event) => {
            if (event.agentId) return;
            idleGeneration += 1;
            lastIdleAborted = event.data.aborted === true;
            lastIdleTurnKind = currentTurnKind;
            currentTurnKind = null;
            foregroundTurnActive = false;
            scheduledTurnActive = false;
            activeSubagents.clear();
            publish();
            setTimeout(() => setScheduledTurnMarker(false), 5_000);
        });

        session.on("subagent.started", (event) => {
            const id = event.agentId || event.data.toolCallId;
            activeSubagents.set(id, {
                id,
                name: event.data.agentDisplayName,
                description: event.data.agentDescription,
                model: event.data.model,
            });
            publish();
        });

        const finishSubagent = (event) => {
            if (event.agentId) {
                activeSubagents.delete(event.agentId);
            } else {
                for (const [id, subagent] of activeSubagents) {
                    if (subagent.name === event.data.agentDisplayName) {
                        activeSubagents.delete(id);
                        break;
                    }
                }
            }
            publish();
        };
        session.on("subagent.completed", finishSubagent);
        session.on("subagent.failed", finishSubagent);

        // Keep this Copilot session's last good drawer visible while history is
        // fetched, but clear a snapshot left by a different Copilot session.
        const preservedTranscriptTurns = restoreMatchingTranscript()
            ? [...transcriptTurns]
            : [];
        if (preservedTranscriptTurns.length === 0) publishTranscript();
        try {
            const history = await session.getEvents();
            transcriptTurns.length = 0;
            pendingTranscriptTurn = null;
            for (const event of history) processTranscriptEvent(event, false, true);
        } catch {
            transcriptTurns.length = 0;
            transcriptTurns.push(...preservedTranscriptTurns);
            pendingTranscriptTurn = null;
            transcriptEventIds.clear();
        }
        transcriptInitialized = true;
        for (const event of queuedTranscriptEvents) {
            processTranscriptEvent(event, false, true);
        }
        queuedTranscriptEvents.length = 0;
        transcriptEventIds.clear();
        publishTranscript();

        await refreshSchedules();
        const timer = setInterval(refreshSchedules, 5_000);

        function cleanup() {
            clearInterval(timer);
            clearTimeout(transcriptPublishTimer);
            // Use the read-only ownership check (never claim during cleanup) so an
            // exiting spawned helper can't wipe a live interactive session's
            // markers. The owner flushes any progress buffered behind the publish
            // throttle before releasing the shared files.
            if (isRecordedOwner()) {
                writeTranscriptSnapshot();
                removeFile(snapshotPath);
                removeFile(scheduledTurnPath);
                removeFile(transcriptOwnerPath);
            }
        }
        process.once("SIGTERM", cleanup);
        process.once("SIGINT", cleanup);
        process.once("exit", cleanup);
    }
    """#

    @discardableResult
    public static func install() throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: extensionDir, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        return "Installed Copilot Projects extension in \(extensionDir.path). "
            + "Restart existing Copilot CLI sessions to activate it."
    }

    public static func uninstall() {
        try? FileManager.default.removeItem(at: extensionDir)
    }

    public static func installIfPossible() {
        guard CopilotHooks.copilotPresent, !upToDate() else { return }
        _ = try? install()
    }

    private static func upToDate() -> Bool {
        (try? String(contentsOf: scriptURL, encoding: .utf8)) == script
    }
}
