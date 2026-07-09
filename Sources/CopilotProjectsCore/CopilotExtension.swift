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
        const scheduledTurnPath = join(sessionsDir, `${appSessionId}.scheduled-turn`);
        const activeSubagents = new Map();
        let foregroundTurnActive = false;
        let scheduledTurnActive = false;
        let currentTurnKind = null;
        let idleGeneration = 0;
        let lastIdleAborted = false;
        let lastIdleTurnKind = null;
        let schedules = [];

        mkdirSync(sessionsDir, { recursive: true });

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
            writeFileSync(temporaryPath, JSON.stringify(snapshot));
            renameSync(temporaryPath, snapshotPath);
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

        session.on("user.message", (event) => {
            if (event.agentId) return;
            lastIdleTurnKind = null;
            currentTurnKind = event.data.source?.startsWith("schedule-")
                ? "scheduled"
                : "foreground";
            if (currentTurnKind === "scheduled") {
                writeFileSync(scheduledTurnPath, "");
            } else {
                rmSync(scheduledTurnPath, { force: true });
            }
        });

        session.on("assistant.turn_start", (event) => {
            if (event.agentId) return;
            lastIdleTurnKind = null;
            scheduledTurnActive = currentTurnKind === "scheduled";
            foregroundTurnActive = !scheduledTurnActive;
            if (scheduledTurnActive) writeFileSync(scheduledTurnPath, "");
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
            setTimeout(() => rmSync(scheduledTurnPath, { force: true }), 5_000);
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

        await refreshSchedules();
        const timer = setInterval(refreshSchedules, 5_000);

        function cleanup() {
            clearInterval(timer);
            rmSync(snapshotPath, { force: true });
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
