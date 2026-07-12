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
    const copilotSessionId = process.env.SESSION_ID;
    const validSessionId = /^[0-9A-Fa-f-]{36}$/.test(appSessionId || "");
    const validCopilotSessionId = /^[0-9A-Fa-f-]{36}$/.test(copilotSessionId || "");

    const session = await joinSession();

    if (validSessionId && socketPath) {
        const sessionsDir = join(dirname(socketPath), "sessions");
        const snapshotPath = join(sessionsDir, `${appSessionId}.agent-activity.json`);
        const scheduledTurnPath = join(sessionsDir, `${appSessionId}.scheduled-turn`);
        const copilotSessionPath = join(sessionsDir, `${appSessionId}.copilot-session`);
        const allowAllPath = join(sessionsDir, `${appSessionId}.copilot-allow-all`);
        const activeSubagents = new Map();
        let foregroundTurnActive = false;
        let scheduledTurnActive = false;
        let currentTurnKind = null;
        let idleGeneration = 0;
        let lastIdleAborted = false;
        let lastIdleTurnKind = null;
        let schedules = [];

        function removeFile(path) {
            try {
                rmSync(path, { force: true });
            } catch {}
        }

        function writeMarker(path, value) {
            const temporaryPath = `${path}.${process.pid}.tmp`;
            try {
                writeFileSync(temporaryPath, value);
                renameSync(temporaryPath, path);
            } catch {
                removeFile(temporaryPath);
            }
        }

        function setAllowAllMarker(enabled) {
            removeFile(allowAllPath);
            if (enabled && validCopilotSessionId) {
                writeMarker(allowAllPath, copilotSessionId);
            }
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
        if (validCopilotSessionId) {
            writeMarker(copilotSessionPath, copilotSessionId);
        }

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

        async function refreshSchedules() {
            try {
                const result = await session.rpc.schedule.list();
                schedules = result.entries;
                publish();
            } catch (error) {
                publish(error);
            }
        }

        async function refreshAllowAll() {
            // Fail closed if the RPC is unavailable: a stale marker must never grant
            // full permissions to a different session in the same tab.
            removeFile(allowAllPath);
            try {
                const result = await session.rpc.permissions.getAllowAll();
                setAllowAllMarker(result.enabled === true);
            } catch {}
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

        session.on("session.permissions_changed", (event) => {
            if (event.agentId) return;
            const mode = event.data.allowAllPermissionMode;
            setAllowAllMarker(
                mode === "on"
                    || (mode == null && event.data.allowAllPermissions === true)
            );
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

        await refreshAllowAll();
        await refreshSchedules();
        const timer = setInterval(refreshSchedules, 5_000);

        function cleanup() {
            clearInterval(timer);
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
