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
    import { mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
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
        let transcriptTurnEndTimer = null;

        const MAX_TRANSCRIPT_TURNS = 100;
        const MAX_TRANSCRIPT_BYTES = 5 * 1024 * 1024;
        const MAX_TRANSCRIPT_TEXT = 50_000;
        const MAX_TRANSCRIPT_METADATA_TEXT = 512;
        const TRANSCRIPT_TURN_END_GRACE_MS = 1_000;

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

        function publishTranscript() {
            const snapshot = {
                schemaVersion: 1,
                updatedAt: new Date().toISOString(),
                copilotSessionId: boundedMetadataText(session.sessionId),
                turns: transcriptTurns,
            };
            let encoded = JSON.stringify(snapshot);
            while (Buffer.byteLength(encoded) > MAX_TRANSCRIPT_BYTES
                    && transcriptTurns.length > 0) {
                transcriptTurns.shift();
                encoded = JSON.stringify(snapshot);
            }
            const temporaryPath = `${transcriptPath}.${process.pid}.tmp`;
            try {
                writeFileSync(temporaryPath, encoded, { mode: 0o600 });
                renameSync(temporaryPath, transcriptPath);
            } catch {
                removeFile(temporaryPath);
            }
        }

        function startTranscriptTurn(event, visibleUser) {
            const source = event.data.source || null;
            pendingTranscriptTurn = {
                id: boundedMetadataText(event.id),
                startedAt: normalizedTimestamp(event.timestamp),
                endedAt: null,
                kind: source?.startsWith("schedule-")
                    ? "scheduled"
                    : visibleUser ? "foreground" : "automated",
                userContent: visibleUser ? boundedText(event.data.content) : "",
                assistantMessages: [],
                tools: [],
                isAborted: false,
                hasTurnEnd: false,
                turnEndAt: null,
            };
        }

        function ensureSyntheticTranscriptTurn(event) {
            if (pendingTranscriptTurn) return;
            pendingTranscriptTurn = {
                id: boundedMetadataText(event.id),
                startedAt: normalizedTimestamp(event.timestamp),
                endedAt: null,
                kind: "automated",
                userContent: "",
                assistantMessages: [],
                tools: [],
                isAborted: false,
                hasTurnEnd: false,
                turnEndAt: null,
            };
        }

        function finishTranscriptTurn(aborted, endedAt, publishNow) {
            const turn = pendingTranscriptTurn;
            pendingTranscriptTurn = null;
            clearTimeout(transcriptTurnEndTimer);
            transcriptTurnEndTimer = null;
            if (!turn) return;
            turn.isAborted = aborted === true;
            turn.endedAt = endedAt
                ? normalizedTimestamp(endedAt)
                : turn.turnEndAt || turn.startedAt;
            delete turn.hasTurnEnd;
            delete turn.turnEndAt;
            if (!turn.userContent
                    && turn.assistantMessages.length === 0
                    && turn.tools.length === 0) return;
            transcriptTurns.push(turn);
            if (transcriptTurns.length > MAX_TRANSCRIPT_TURNS) {
                transcriptTurns.splice(
                    0,
                    transcriptTurns.length - MAX_TRANSCRIPT_TURNS
                );
            }
            if (publishNow) publishTranscript();
        }

        function scheduleTranscriptTurnEndFallback() {
            clearTimeout(transcriptTurnEndTimer);
            transcriptTurnEndTimer = null;
            const turn = pendingTranscriptTurn;
            if (!turn?.hasTurnEnd) return;
            transcriptTurnEndTimer = setTimeout(() => {
                transcriptTurnEndTimer = null;
                if (pendingTranscriptTurn?.id !== turn.id
                        || !pendingTranscriptTurn.hasTurnEnd) return;
                finishTranscriptTurn(false, turn.turnEndAt, true);
            }, TRANSCRIPT_TURN_END_GRACE_MS);
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
            if (pendingTranscriptTurn?.hasTurnEnd
                    && event.type !== "assistant.turn_end"
                    && event.type !== "session.idle") {
                finishTranscriptTurn(
                    false,
                    pendingTranscriptTurn.turnEndAt || event.timestamp,
                    live
                );
            }

            switch (event.type) {
            case "user.message": {
                const source = event.data.source || null;
                const visibleUser = source === null || source.startsWith("schedule-");
                if (visibleUser) {
                    finishTranscriptTurn(false, event.timestamp, live);
                    startTranscriptTurn(event, true);
                } else if (!pendingTranscriptTurn) {
                    startTranscriptTurn(event, false);
                }
                break;
            }
            case "assistant.message":
                ensureSyntheticTranscriptTurn(event);
                if (event.data.content) {
                    if (pendingTranscriptTurn.assistantMessages.length >= 20) {
                        pendingTranscriptTurn.assistantMessages.shift();
                    }
                    pendingTranscriptTurn.assistantMessages.push({
                        id: boundedMetadataText(event.data.messageId || event.id),
                        timestamp: normalizedTimestamp(event.timestamp),
                        content: boundedText(event.data.content),
                    });
                }
                break;
            case "tool.execution_start": {
                ensureSyntheticTranscriptTurn(event);
                const toolId = boundedMetadataText(event.data.toolCallId);
                const existing = pendingTranscriptTurn.tools.find(
                    (tool) => tool.id === toolId
                );
                if (!existing && pendingTranscriptTurn.tools.length < 100) {
                    pendingTranscriptTurn.tools.push({
                        id: toolId,
                        name: boundedMetadataText(event.data.toolName),
                        title: boundedMetadataText(toolTitle(event.data)),
                        success: null,
                    });
                }
                break;
            }
            case "tool.execution_complete": {
                ensureSyntheticTranscriptTurn(event);
                const toolId = boundedMetadataText(event.data.toolCallId);
                let tool = pendingTranscriptTurn.tools.find(
                    (candidate) => candidate.id === toolId
                );
                if (!tool && pendingTranscriptTurn.tools.length < 100) {
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
                break;
            }
            case "assistant.turn_end":
                if (pendingTranscriptTurn) {
                    pendingTranscriptTurn.hasTurnEnd = true;
                    pendingTranscriptTurn.turnEndAt = normalizedTimestamp(event.timestamp);
                    if (live) scheduleTranscriptTurnEndFallback();
                }
                break;
            case "session.idle":
                finishTranscriptTurn(
                    event.data.aborted === true,
                    event.timestamp,
                    live
                );
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

        // Clear a previous Copilot session's drawer immediately, then rebuild this
        // session's completed history below.
        publishTranscript();
        try {
            const history = await session.getEvents();
            for (const event of history) processTranscriptEvent(event, false, true);
        } catch {}
        transcriptInitialized = true;
        for (const event of queuedTranscriptEvents) {
            processTranscriptEvent(event, false, true);
        }
        queuedTranscriptEvents.length = 0;
        transcriptEventIds.clear();
        publishTranscript();
        scheduleTranscriptTurnEndFallback();

        await refreshSchedules();
        const timer = setInterval(refreshSchedules, 5_000);

        function cleanup() {
            clearInterval(timer);
            clearTimeout(transcriptTurnEndTimer);
            removeFile(snapshotPath);
            removeFile(scheduledTurnPath);
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
