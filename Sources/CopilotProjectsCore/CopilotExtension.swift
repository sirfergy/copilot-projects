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
    import { execFileSync } from "node:child_process";
    import { dirname, join } from "node:path";
    import {
        existsSync as fileExistsSync,
        mkdirSync, readFileSync, renameSync, rmSync, watch, writeFileSync
    } from "node:fs";
    import { joinSession } from "@github/copilot-sdk/extension";

    const environmentAppSessionId = process.env.COPILOT_PROJECTS_SESSION;
    const socketPath = process.env.COPILOT_PROJECTS_SOCKET;
    const sessionIdPattern = /^[0-9A-Fa-f-]{36}$/;

    // The environment can be stale or cross-contaminated in a long-lived shell.
    // Ask the installed native helper to resolve this process through the actual
    // dtach socket ancestry. If the helper is installed but cannot prove ownership,
    // fail closed; only old installs without the helper retain the env fallback.
    const sessionResolverPath = (() => {
        const home = typeof process.env.HOME === "string" ? process.env.HOME : "";
        const candidates = home ? [join(home, ".local/bin/copilot-projects")] : [];
        return candidates.find((candidate) => fileExistsSync(candidate)) || null;
    })();

    // Resolve the app (tab) session id a pid belongs to via the native helper's
    // dtach-socket ancestry walk. Returns a valid session id, "" when the pid
    // resolves to no managed tab (e.g. an orphan reparented to launchd), or null
    // when resolution is unavailable/failed. Callers MUST treat null as "unknown"
    // and never as a match. Results are cached per pid only briefly: a pid's
    // ancestry CAN change (a live owner reparented to launchd stops resolving to
    // its tab — the exact failure this repairs), so the cache is time-bounded to
    // avoid re-running the resolver on every throttled publish while still letting
    // a reparented owner become displaceable within one TTL.
    const resolvedTabCache = new Map(); // pid -> { value, at }
    const RESOLVED_TAB_TTL_MS = 5_000;
    function resolveSessionForPid(pid) {
        if (!sessionResolverPath || !Number.isInteger(pid) || pid <= 0) return null;
        const cached = resolvedTabCache.get(pid);
        if (cached && Date.now() - cached.at < RESOLVED_TAB_TTL_MS) return cached.value;
        let result;
        try {
            const resolved = execFileSync(
                sessionResolverPath,
                ["resolve-session", "--pid", String(pid)],
                { encoding: "utf8", timeout: 1_000, stdio: ["ignore", "pipe", "ignore"] }
            ).trim();
            result = sessionIdPattern.test(resolved) ? resolved : "";
        } catch (error) {
            // `resolve-session` exits non-zero (status 1, no output) when the pid
            // belongs to no managed tab — a definitive "no tab", not a failure, so
            // treat it as "" (displaceable). Only a spawn failure or timeout (no
            // numeric exit status) is genuinely unknown -> null, so we stay
            // conservative and never displace a live owner on a flaky lookup. The
            // unknown case is not cached, so a transient failure isn't remembered.
            result = (error && typeof error.status === "number") ? "" : null;
        }
        if (result !== null) resolvedTabCache.set(pid, { value: result, at: Date.now() });
        return result;
    }

    function resolveAppSessionId() {
        if (!sessionResolverPath) {
            return {
                sessionId: sessionIdPattern.test(environmentAppSessionId || "")
                    ? environmentAppSessionId
                    : "",
                native: false,
            };
        }
        const resolved = resolveSessionForPid(process.pid);
        return { sessionId: resolved === null ? "" : resolved, native: true };
    }

    const appSessionResolution = resolveAppSessionId();
    const appSessionId = appSessionResolution.sessionId;
    const validSessionId = /^[0-9A-Fa-f-]{36}$/.test(appSessionId || "");

    const session = await joinSession();
    const copilotSessionId = typeof session.sessionId === "string"
        ? session.sessionId
        : "";
    const validCopilotSessionId = /^[0-9A-Fa-f-]{36}$/.test(copilotSessionId);

    if (validSessionId && socketPath) {
        const sessionsDir = join(dirname(socketPath), "sessions");
        const snapshotPath = join(sessionsDir, `${appSessionId}.agent-activity.json`);
        const transcriptPath = join(sessionsDir, `${appSessionId}.transcript.json`);
        const transcriptOwnerPath = join(sessionsDir, `${appSessionId}.transcript-owner.json`);
        const transcriptOwnerLockPath = `${transcriptOwnerPath}.lock`;
        const scheduledTurnPath = join(sessionsDir, `${appSessionId}.scheduled-turn`);
        const copilotSessionPath = join(sessionsDir, `${appSessionId}.copilot-session`);
        const allowAllPath = join(sessionsDir, `${appSessionId}.copilot-allow-all`);
        const userInputResponsePath = join(
            sessionsDir, `${appSessionId}.user-input-response.json`
        );
        const userInputResponseName = `${appSessionId}.user-input-response.json`;
        const elicitationResponsePath = join(
            sessionsDir, `${appSessionId}.elicitation-response.json`
        );
        const elicitationResponseName = `${appSessionId}.elicitation-response.json`;
        // Host-written model switch request; same single-outstanding lifecycle as
        // the user-input/elicitation responses. The host validates against the
        // published catalog before writing; we re-validate the session binding
        // before switching over RPC.
        const setModelRequestPath = join(
            sessionsDir, `${appSessionId}.set-model-request.json`
        );
        const setModelRequestName = `${appSessionId}.set-model-request.json`;
        const activeSubagents = new Map();
        // All outstanding structured questions (root and subagent), keyed by
        // requestId. Starts empty every launch: stale question state is never
        // resurrected from disk, only rebuilt from live events.
        const pendingUserInputs = new Map();
        const inFlightUserInputResponses = new Set();
        // Outstanding elicitations (schema-form / url questions), keyed by
        // requestId. Same lifecycle as pendingUserInputs: rebuilt from live
        // events, never resurrected from disk.
        const pendingElicitations = new Map();
        const inFlightElicitationResponses = new Set();
        let foregroundTurnActive = false;
        // Wall-clock time of the most recent `foregroundTurnActive` transition
        // (root turn_start/turn_end/session.idle). Distinct from `updatedAt`,
        // which every publish() rewrites (heartbeats, questions, model/subagent
        // events). The macOS client seeds its status-event clock from THIS value
        // so those unrelated republishes can't advance the clock past a delayed
        // status hook. At each transition it's set to `normalizedTimestamp(
        // event.timestamp)` — the CLI event's causal time — matching the time
        // base the status hooks use (`payload_timestamp` reads the same event
        // `timestamp`), so it's directly comparable to the status-event clock.
        // The initial value predates any turn and never seeds a clock (recovery/
        // demotion require a real transition first).
        let foregroundTransitionAt = new Date().toISOString();
        let scheduledTurnActive = false;
        let currentTurnKind = null;
        let idleGeneration = 0;
        let lastIdleAborted = false;
        let lastIdleTurnKind = null;
        let currentModel = null;
        // Compact, host-facing catalog of switchable models, refreshed from
        // `session.rpc.model.list()`. Null until the first successful fetch so the
        // client shows the read-only model line rather than an empty picker.
        let availableModels = null;
        // Guards against processing two set-model requests concurrently for the
        // same file write burst (mirrors inFlightUserInputResponses).
        let inFlightSetModelRequest = false;
        let schedules = [];
        const transcriptTurns = [];
        const transcriptEventIds = new Set();
        const queuedTranscriptEvents = [];
        let pendingTranscriptTurn = null;
        let transcriptAssistantTurnActive = false;
        let latestResumeTranscriptTurnId = null;
        let transcriptInitialized = false;
        let transcriptPublishTimer = null;
        let sharedFilesOwnershipInitializedFor = null;
        let allowAllRefreshQueued = false;
        let allowAllUpdateGeneration = 0;

        const MAX_TRANSCRIPT_TURNS = 200;
        const MAX_TRANSCRIPT_BYTES = 5 * 1024 * 1024;
        const MAX_TRANSCRIPT_TEXT = 50_000;
        const MAX_TRANSCRIPT_METADATA_TEXT = 512;
        const MAX_TRANSCRIPT_ASSISTANT_MESSAGES = 250;
        const MAX_TRANSCRIPT_TOOLS = 400;
        const TRANSCRIPT_PUBLISH_THROTTLE_MS = 400;

        const MAX_USER_INPUT_QUESTION_BYTES = 16_384;
        const MAX_USER_INPUT_CHOICE_BYTES = 8_192;
        const MAX_USER_INPUT_CHOICES = 50;
        const MAX_USER_INPUT_TOTAL_BYTES = 32_768;
        const MAX_USER_INPUT_ANSWER_BYTES = 8_192;
        const MAX_USER_INPUTS = 50;

        const MAX_ELICITATION_MESSAGE_BYTES = 16_384;
        const MAX_ELICITATION_SCHEMA_BYTES = 32_768;
        const MAX_ELICITATION_SCHEMA_DEPTH = 8;
        const MAX_ELICITATION_URL_BYTES = 4_096;
        const MAX_ELICITATION_CONTENT_BYTES = 32_768;
        const MAX_ELICITATIONS = 50;

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

        // A live-looking pid doesn't prove it's the same process that wrote the
        // marker: after a reboot (or once the pid counter wraps) an unrelated
        // process can be reassigned that exact pid, and `processAlive` alone
        // would treat that unrelated process as the still-live owner forever,
        // permanently blocking every new session for this tab from claiming or
        // publishing shared files. Cross-check the system boot time recorded
        // alongside the pid; a boot time mismatch proves the recorded process
        // is gone even though the pid number happens to be in use again.
        let cachedBootTime;
        function currentBootTime() {
            if (cachedBootTime !== undefined) return cachedBootTime;
            try {
                cachedBootTime = execFileSync(
                    "sysctl",
                    ["-n", "kern.boottime"],
                    { encoding: "utf8", timeout: 1_000, stdio: ["ignore", "pipe", "ignore"] }
                ).trim();
            } catch {
                cachedBootTime = null;
            }
            return cachedBootTime;
        }

        function ownerProcessAlive(owner) {
            if (!processAlive(owner.pid)) return false;
            if (typeof owner.bootTime !== "string" || !owner.bootTime) {
                // Marker predates boot-time tracking; fall back to pid-only.
                return true;
            }
            const current = currentBootTime();
            // Fail open (as elsewhere) if we can't determine the current boot
            // time rather than spuriously reclaiming a live owner.
            return current === null || current === owner.bootTime;
        }

        // A live pid alone does not entitle a marker to keep this tab's shared
        // files: an orphaned or cross-tab copilot (e.g. one that grabbed the
        // marker via a stale COPILOT_PROJECTS_SESSION before native dtach
        // resolution existed, then was reparented to launchd) would otherwise
        // block this tab's real interactive session from ever claiming ownership
        // and republishing its transcript. Only an owner that actually belongs to
        // THIS app session may hold the claim. We make this judgment ONLY when our
        // own identity is natively resolved; otherwise we stay conservative and
        // never displace a live owner. A same-tab peer (e.g. a `copilot -p`
        // classifier under the same dtach master) still resolves to this tab and
        // is honored, preserving the original anti-clobber protection.
        function ownerBelongsToThisTab(owner) {
            if (!appSessionResolution.native || !validSessionId) return true;
            if (typeof owner.appSessionId === "string"
                    && sessionIdPattern.test(owner.appSessionId)) {
                return owner.appSessionId === appSessionId;
            }
            const resolved = resolveSessionForPid(owner.pid);
            if (resolved === null) return true; // unknown -> do not displace
            return resolved === appSessionId;
        }

        // The marker keeps its claim only while its process is alive AND still
        // belongs to this tab. Everything else (dead, or alive-but-foreign) is
        // displaceable by this tab's own session.
        function ownerHoldsClaim(owner) {
            return ownerProcessAlive(owner) && ownerBelongsToThisTab(owner);
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

        function ownerMarkerPayload() {
            return {
                ...(appSessionResolution.native ? {appSessionId} : {}),
                copilotSessionId: session.sessionId,
                pid: process.pid,
                bootTime: currentBootTime() ?? undefined,
            };
        }

        function writeOwnerMarker() {
            try {
                writeFileSync(
                    transcriptOwnerPath,
                    JSON.stringify(ownerMarkerPayload()),
                    { flag: "wx", mode: 0o600 }
                );
                return true;
            } catch {
                return false;
            }
        }

        // Replaces an existing marker via write-then-rename so a concurrent
        // reader never observes a moment with no marker present at all (as a
        // plain remove-then-recreate would produce). `renameSync` within the
        // same directory is atomic on the filesystems this app supports.
        function replaceOwnerMarker() {
            const temporaryPath = `${transcriptOwnerPath}.${process.pid}.tmp`;
            try {
                writeFileSync(
                    temporaryPath,
                    JSON.stringify(ownerMarkerPayload()),
                    { mode: 0o600 }
                );
                renameSync(temporaryPath, transcriptOwnerPath);
                return true;
            } catch {
                try { rmSync(temporaryPath, { force: true }); } catch {}
                return false;
            }
        }

        function withTranscriptOwnerLock(action) {
            try {
                writeFileSync(
                    transcriptOwnerLockPath,
                    JSON.stringify({
                        ...(appSessionResolution.native ? {appSessionId} : {}),
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

        function reclaimDisplaceableOwner(expectedOwner) {
            return withTranscriptOwnerLock(() => {
                const owner = recordedOwner();
                if (!owner) return writeOwnerMarker();
                if (ownerMatchesCurrentProcess(owner)) return true;
                if (ownerHoldsClaim(owner)) return false;
                if (!ownerMatches(owner, expectedOwner)) return false;
                return replaceOwnerMarker();
            });
        }

        // Claiming: returns true if this process may write shared files. Claims
        // ownership atomically (exclusive create) when the marker is absent,
        // held by a dead process, or held by a live process that does not belong
        // to this tab (an orphaned/cross-tab copilot). Reclamation is serialized
        // so a process that read the stale marker cannot delete a fresh winner's
        // marker. Returns false only if a live owner that belongs to THIS tab
        // holds it or the claim is lost.
        function ownsSharedFiles() {
            for (let attempt = 0; attempt < 3; attempt += 1) {
                const owner = recordedOwner();
                if (owner) {
                    if (ownerMatchesCurrentProcess(owner)) {
                        activateSharedFilesOwnership();
                        return true;
                    }
                    if (ownerHoldsClaim(owner)) return false;
                    if (reclaimDisplaceableOwner(owner)) {
                        activateSharedFilesOwnership(true);
                        return true;
                    }
                } else if (writeOwnerMarker()) {
                    activateSharedFilesOwnership(true);
                    return true;
                } else {
                    // Lost the create race; re-read and re-evaluate.
                }
            }
            const owns = ownerMatchesCurrentProcess(recordedOwner());
            if (owns) activateSharedFilesOwnership();
            return owns;
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

        function writeMarker(path, value) {
            const temporaryPath = `${path}.${process.pid}.tmp`;
            try {
                writeFileSync(temporaryPath, value);
                renameSync(temporaryPath, path);
            } catch {
                removeFile(temporaryPath);
            }
        }

        function refreshAllowAllSoon() {
            if (allowAllRefreshQueued) return;
            allowAllRefreshQueued = true;
            Promise.resolve()
                .then(() => refreshAllowAll())
                .catch(() => {})
                .finally(() => { allowAllRefreshQueued = false; });
        }

        function activateSharedFilesOwnership(force = false) {
            const ownershipKey = `${copilotSessionId}:${process.pid}`;
            if (!force && sharedFilesOwnershipInitializedFor === ownershipKey) return;
            sharedFilesOwnershipInitializedFor = ownershipKey;
            if (validCopilotSessionId) {
                writeMarker(copilotSessionPath, copilotSessionId);
            }
            refreshAllowAllSoon();
        }

        function applyAllowAllMarker(enabled) {
            if (!ownsSharedFiles()) return;
            removeFile(allowAllPath);
            if (enabled && validCopilotSessionId) {
                writeMarker(allowAllPath, copilotSessionId);
            }
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
        if (validCopilotSessionId && ownsSharedFiles()) {
            writeMarker(copilotSessionPath, copilotSessionId);
        }

        function publish(error) {
            if (!ownsSharedFiles()) return;
            const snapshot = {
                schemaVersion: 1,
                updatedAt: new Date().toISOString(),
                foregroundTurnActive,
                foregroundTransitionAt,
                scheduledTurnActive,
                activeSubagents: [...activeSubagents.values()],
                schedules,
                idleGeneration,
                lastIdleAborted,
                lastIdleTurnKind,
                trackedUserInputs: [...pendingUserInputs.values()],
                trackedElicitations: [...pendingElicitations.values()],
                ...(currentModel ? { model: currentModel } : {}),
                ...(availableModels ? { availableModels } : {}),
                ...(error ? { error: String(error) } : {}),
            };
            const temporaryPath = `${snapshotPath}.${process.pid}.tmp`;
            try {
                // Mode 0600 because the snapshot now carries question text.
                writeFileSync(temporaryPath, JSON.stringify(snapshot), { mode: 0o600 });
                renameSync(temporaryPath, snapshotPath);
            } catch {
                removeFile(temporaryPath);
            }
        }

        function userInputByteLength(value) {
            return typeof value === "string" ? Buffer.byteLength(value) : Infinity;
        }

        // Build a bounded, verbatim question record or return null to reject remote
        // exposure entirely — never truncating a selectable choice, so the terminal
        // fallback stays exact.
        function userInputEntry(event) {
            const data = event?.data;
            if (!data || typeof data !== "object") return null;
            const requestId = data.requestId;
            if (typeof requestId !== "string" || !requestId
                    || requestId.length > 200) return null;
            const question = data.question;
            if (typeof question !== "string") return null;
            let totalBytes = userInputByteLength(question);
            if (totalBytes > MAX_USER_INPUT_QUESTION_BYTES) return null;
            const choices = [];
            if (data.choices != null) {
                if (!Array.isArray(data.choices)) return null;
                if (data.choices.length > MAX_USER_INPUT_CHOICES) return null;
                for (const choice of data.choices) {
                    if (typeof choice !== "string") return null;
                    const bytes = userInputByteLength(choice);
                    if (bytes > MAX_USER_INPUT_CHOICE_BYTES) return null;
                    totalBytes += bytes;
                    if (totalBytes > MAX_USER_INPUT_TOTAL_BYTES) return null;
                    choices.push(choice);
                }
            }
            const agentId = typeof event.agentId === "string" && event.agentId
                ? boundedMetadataText(event.agentId)
                : null;
            return {
                requestId,
                question,
                choices,
                allowFreeform: data.allowFreeform !== false,
                requestedAt: normalizedTimestamp(event.timestamp),
                agentId,
            };
        }

        function boundPendingUserInputs() {
            while (pendingUserInputs.size > MAX_USER_INPUTS) {
                pendingUserInputs.delete(pendingUserInputs.keys().next().value);
            }
        }

        // Answer a pending question from the host-written response file. Invalid or
        // stale responses only remove the response file; the pending question and its
        // exact terminal fallback are preserved. `user_input.completed` stays
        // authoritative for removing a question.
        async function processUserInputResponse() {
            // Only the owner reconciles remote answers: a spawned classifier helper
            // shares this session dir and would otherwise delete the owner's pending
            // response (its session id / pending set won't match), stranding the
            // answer and forcing the terminal fallback.
            if (!ownsSharedFiles()) return;
            let encoded;
            try {
                encoded = readFileSync(userInputResponsePath, "utf8");
            } catch {
                return;
            }
            let response;
            try {
                response = JSON.parse(encoded);
            } catch {
                removeFile(userInputResponsePath);
                return;
            }
            if (!response || typeof response !== "object"
                    || response.schemaVersion !== 1
                    || typeof response.requestId !== "string") {
                removeFile(userInputResponsePath);
                return;
            }
            const requestId = response.requestId;
            if (inFlightUserInputResponses.has(requestId)) return;
            if (response.copilotSessionId !== session.sessionId) {
                removeFile(userInputResponsePath);
                return;
            }
            const pending = pendingUserInputs.get(requestId);
            if (!pending) {
                removeFile(userInputResponsePath);
                return;
            }
            const answer = response.answer;
            if (typeof answer !== "string"
                    || userInputByteLength(answer) > MAX_USER_INPUT_ANSWER_BYTES) {
                removeFile(userInputResponsePath);
                return;
            }
            const wasFreeform = response.wasFreeform === true;
            if (wasFreeform && !pending.allowFreeform) {
                removeFile(userInputResponsePath);
                return;
            }
            if (!wasFreeform && !pending.choices.includes(answer)) {
                removeFile(userInputResponsePath);
                return;
            }
            inFlightUserInputResponses.add(requestId);
            try {
                const result = await session.rpc.ui.handlePendingUserInput({
                    requestId,
                    response: { answer, wasFreeform },
                });
                if (result?.success === true) {
                    pendingUserInputs.delete(requestId);
                    removeFile(userInputResponsePath);
                    publish();
                } else {
                    // Keep the question retryable; drop only the rejected response.
                    removeFile(userInputResponsePath);
                }
            } catch {
                removeFile(userInputResponsePath);
            } finally {
                inFlightUserInputResponses.delete(requestId);
            }
        }

        // Build a bounded elicitation record or return null to reject remote
        // exposure (the terminal keeps handling it). The requestedSchema is passed
        // through verbatim within a byte budget so the client renders exactly what
        // the agent asked; oversized/complex schemas fall back to the terminal.
        function jsonDepth(value, limit = MAX_ELICITATION_SCHEMA_DEPTH + 1) {
            if (limit <= 0) return Infinity;
            if (Array.isArray(value)) {
                let max = 0;
                for (const item of value) {
                    max = Math.max(max, jsonDepth(item, limit - 1));
                    if (max === Infinity) return Infinity;
                }
                return max + 1;
            }
            if (value && typeof value === "object") {
                let max = 0;
                for (const key of Object.keys(value)) {
                    max = Math.max(max, jsonDepth(value[key], limit - 1));
                    if (max === Infinity) return Infinity;
                }
                return max + 1;
            }
            return 0;
        }

        function elicitationEntry(event) {
            const data = event?.data;
            if (!data || typeof data !== "object") return null;
            const requestId = data.requestId;
            if (typeof requestId !== "string" || !requestId
                    || requestId.length > 200) return null;
            const message = data.message;
            if (typeof message !== "string") return null;
            if (userInputByteLength(message) > MAX_ELICITATION_MESSAGE_BYTES) return null;
            const mode = typeof data.mode === "string" ? data.mode : null;
            let url = null;
            if (data.url != null) {
                if (typeof data.url !== "string") return null;
                if (userInputByteLength(data.url) > MAX_ELICITATION_URL_BYTES) return null;
                url = data.url;
            }
            let schema = null;
            if (data.requestedSchema != null) {
                if (typeof data.requestedSchema !== "object") return null;
                let serialized;
                try {
                    serialized = JSON.stringify(data.requestedSchema);
                } catch {
                    return null;
                }
                if (Buffer.byteLength(serialized) > MAX_ELICITATION_SCHEMA_BYTES) return null;
                // Reject pathologically nested schemas: they can pass the byte
                // budget yet exceed the host JSON decoder's nesting limit, which
                // would fail the whole heartbeat decode and drop every pending
                // question. The remote form only renders a flat schema anyway.
                if (jsonDepth(data.requestedSchema) > MAX_ELICITATION_SCHEMA_DEPTH) return null;
                schema = data.requestedSchema;
            }
            // A form-mode elicitation with neither a schema nor a url isn't
            // remotely answerable; leave it to the terminal.
            if (!schema && !url) return null;
            const agentId = typeof event.agentId === "string" && event.agentId
                ? boundedMetadataText(event.agentId)
                : null;
            return {
                requestId,
                message,
                mode,
                url,
                schema,
                elicitationSource: typeof data.elicitationSource === "string"
                    ? boundedMetadataText(data.elicitationSource)
                    : null,
                requestedAt: normalizedTimestamp(event.timestamp),
                agentId,
            };
        }

        function boundPendingElicitations() {
            while (pendingElicitations.size > MAX_ELICITATIONS) {
                pendingElicitations.delete(pendingElicitations.keys().next().value);
            }
        }

        // Answer a pending elicitation from the host-written response file. Mirrors
        // processUserInputResponse: owner-only, validates against the pending record,
        // and keeps the elicitation retryable when a response is rejected.
        async function processElicitationResponse() {
            if (!ownsSharedFiles()) return;
            let encoded;
            try {
                encoded = readFileSync(elicitationResponsePath, "utf8");
            } catch {
                return;
            }
            let response;
            try {
                response = JSON.parse(encoded);
            } catch {
                removeFile(elicitationResponsePath);
                return;
            }
            if (!response || typeof response !== "object"
                    || response.schemaVersion !== 1
                    || typeof response.requestId !== "string") {
                removeFile(elicitationResponsePath);
                return;
            }
            const requestId = response.requestId;
            if (inFlightElicitationResponses.has(requestId)) return;
            if (response.copilotSessionId !== session.sessionId) {
                removeFile(elicitationResponsePath);
                return;
            }
            const pending = pendingElicitations.get(requestId);
            if (!pending) {
                removeFile(elicitationResponsePath);
                return;
            }
            const action = response.action;
            if (action !== "accept" && action !== "decline" && action !== "cancel") {
                removeFile(elicitationResponsePath);
                return;
            }
            const result = { action };
            if (action === "accept") {
                if (pending.mode === "url" || typeof pending.url === "string") {
                    if (response.content != null) {
                        removeFile(elicitationResponsePath);
                        return;
                    }
                } else {
                    const content = response.content;
                    if (!content || typeof content !== "object" || Array.isArray(content)) {
                        removeFile(elicitationResponsePath);
                        return;
                    }
                    let serialized;
                    try {
                        serialized = JSON.stringify(content);
                    } catch {
                        removeFile(elicitationResponsePath);
                        return;
                    }
                    if (Buffer.byteLength(serialized) > MAX_ELICITATION_CONTENT_BYTES) {
                        removeFile(elicitationResponsePath);
                        return;
                    }
                    result.content = content;
                }
            }
            inFlightElicitationResponses.add(requestId);
            try {
                const rpcResult = await session.rpc.ui.handlePendingElicitation({
                    requestId,
                    result,
                });
                if (rpcResult?.success === true) {
                    pendingElicitations.delete(requestId);
                    removeFile(elicitationResponsePath);
                    publish();
                } else {
                    // Resolved elsewhere (terminal / another client) or expired;
                    // drop only the response. elicitation.completed clears the card.
                    removeFile(elicitationResponsePath);
                }
            } catch {
                removeFile(elicitationResponsePath);
            } finally {
                inFlightElicitationResponses.delete(requestId);
            }
        }

        function trimTranscriptTurns(maximumTurns = MAX_TRANSCRIPT_TURNS) {
            // Keep the transcript bounded. Drop the oldest non-foreground turn
            // first, except for the latest resume marker; if only foreground
            // conversation plus that marker remain, sacrifice the oldest
            // foreground turn so the restart boundary is visible.
            while (transcriptTurns.length > maximumTurns) {
                let index = transcriptTurns.findIndex(
                    (turn) => turn.kind !== "foreground"
                        && turn.id !== latestResumeTranscriptTurnId
                );
                if (index === -1) {
                    index = transcriptTurns.findIndex(
                        (turn) => turn.id !== latestResumeTranscriptTurnId
                    );
                }
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
                        && turn.id !== latestResumeTranscriptTurnId
                );
                if (index === -1) break;
                transcriptTurns.splice(index, 1);
                snapshot = build();
                reencode();
            }
            // Phase 2: shed payload from any remaining non-foreground turn (i.e. an
            // in-progress scheduled/automated turn) before touching foreground.
            while (overBudget()
                    && shedOldestPayload(
                        (turn) => turn.kind !== "foreground"
                            && turn.id !== latestResumeTranscriptTurnId
                    )) {
                reencode();
            }
            // Phase 3: drop whole foreground stored turns (oldest), never pending,
            // leaving at least one turn for payload shedding below.
            const minStored = pending ? 0 : 1;
            while (overBudget() && transcriptTurns.length > minStored) {
                const index = transcriptTurns.findIndex(
                    (turn) => turn.id !== latestResumeTranscriptTurnId
                );
                if (index === -1) break;
                transcriptTurns.splice(index, 1);
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

        function appendLatestResumeTurn(event) {
            const prefix = "session-resume-";
            for (let index = transcriptTurns.length - 1; index >= 0; index -= 1) {
                if (transcriptTurns[index].id.startsWith(prefix)) {
                    transcriptTurns.splice(index, 1);
                }
            }
            const timestamp = normalizedTimestamp(event.timestamp);
            latestResumeTranscriptTurnId =
                `${prefix}${boundedMetadataText(event.id)}`;
            transcriptTurns.push({
                id: latestResumeTranscriptTurnId,
                startedAt: timestamp,
                endedAt: timestamp,
                kind: "automated",
                userContent: "",
                assistantMessages: [{
                    id: boundedMetadataText(event.id),
                    timestamp,
                    content: "Session resumed. Terminal startup details are available in Terminal.",
                }],
                tools: [],
                isAborted: false,
            });
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
                    latestResumeTranscriptTurnId = null;
                    finishTranscriptTurn(false, event.timestamp);
                    startTranscriptTurn(event, kind);
                    if (live) publishTranscript();
                }
                // Injected context (skill/system) is not its own turn; the work
                // it triggers folds into the current human turn.
                break;
            }
            case "assistant.turn_start":
                transcriptAssistantTurnActive = true;
                break;
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
                transcriptAssistantTurnActive = false;
                // One agentic loop iteration finished, not the whole request.
                // Do not end the transcript turn here; just flush progress.
                if (live && pendingTranscriptTurn) schedulePublishTranscript();
                break;
            case "session.shutdown":
                const shutdownWasActive = transcriptAssistantTurnActive;
                transcriptAssistantTurnActive = false;
                // Shutdown is a hard boundary even when turn_end was never
                // persisted (crash, kill, reboot). Preserve partial output but
                // mark the interrupted turn as stopped.
                finishTranscriptTurn(shutdownWasActive, event.timestamp);
                if (live) schedulePublishTranscript();
                break;
            case "session.resume":
                const racingLiveTurn = live && transcriptAssistantTurnActive;
                if (!racingLiveTurn) {
                    const resumeWasActive = transcriptAssistantTurnActive;
                    transcriptAssistantTurnActive = false;
                    finishTranscriptTurn(resumeWasActive, event.timestamp);
                    appendLatestResumeTurn(event);
                }
                if (live) schedulePublishTranscript();
                break;
            case "session.idle":
                transcriptAssistantTurnActive = false;
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

        async function refreshAllowAll() {
            if (!ownsSharedFiles()) return;
            const generation = ++allowAllUpdateGeneration;
            // Fail closed if the RPC is unavailable: a stale marker must never grant
            // full permissions to a different session in the same tab.
            removeFile(allowAllPath);
            try {
                const result = await session.rpc.permissions.getAllowAll();
                if (generation === allowAllUpdateGeneration) {
                    applyAllowAllMarker(result.enabled === true);
                }
            } catch {}
        }

        // `rpc.model.list()` types its entries as `unknown[]` and returns the raw
        // CAPI model objects, which are snake_case (`model_picker_category`,
        // `capabilities.supports.reasoning_effort`, `billing.token_prices`) even
        // though the generated SDK `Model` interface documents camelCase. Read
        // both spellings so the catalog stays populated whichever shape arrives.
        function pickKey(source, snakeKey, camelKey) {
            if (!source || typeof source !== "object") return undefined;
            return source[snakeKey] !== undefined ? source[snakeKey] : source[camelKey];
        }

        // Reduce a raw `rpc.model.list()` entry to the compact, host-facing shape
        // the remote picker needs. Drops entries without a usable id/name; bounds
        // strings/count so a pathological catalog can't bloat the 0600 heartbeat.
        function normalizeAvailableModels(rawList) {
            if (!Array.isArray(rawList)) return null;
            const out = [];
            for (const entry of rawList) {
                if (!entry || typeof entry !== "object") continue;
                const id = typeof entry.id === "string" ? entry.id.slice(0, 200) : "";
                const rawName = typeof entry.name === "string" && entry.name.length > 0
                    ? entry.name
                    : id;
                const name = rawName.slice(0, 200);
                if (!id || !name) continue;
                const model = { id, name };
                // Efforts live on the capability block at runtime; the top-level
                // `supportedReasoningEfforts` is the documented camelCase form.
                // `supports.reasoningEffort` is typed as a bool, so only arrays
                // are treated as an effort list.
                const supports = pickKey(entry.capabilities, "supports", "supports");
                const rawEfforts = [
                    pickKey(supports, "reasoning_effort", "reasoningEffort"),
                    pickKey(entry, "supported_reasoning_efforts", "supportedReasoningEfforts"),
                ].find(Array.isArray);
                if (rawEfforts) {
                    const efforts = rawEfforts
                        .filter((value) => typeof value === "string" && value.length > 0)
                        .slice(0, 16);
                    if (efforts.length > 0) model.supportedReasoningEfforts = efforts;
                }
                const defaultEffort = pickKey(
                    entry, "default_reasoning_effort", "defaultReasoningEffort"
                );
                if (typeof defaultEffort === "string" && defaultEffort.length > 0) {
                    model.defaultReasoningEffort = defaultEffort;
                }
                const tokenPrices = pickKey(entry.billing, "token_prices", "tokenPrices");
                model.longContextAvailable = !!pickKey(
                    tokenPrices, "long_context", "longContext"
                );
                // A model is unselectable when policy gates it or the picker
                // excludes it (Auto may still route to picker-disabled models).
                const pickerEnabled = pickKey(
                    entry, "model_picker_enabled", "modelPickerEnabled"
                );
                if ((entry.policy && entry.policy.state === "disabled")
                        || pickerEnabled === false) {
                    model.disabled = true;
                }
                const category = pickKey(
                    entry, "model_picker_category", "modelPickerCategory"
                );
                if (typeof category === "string" && category.length > 0) {
                    model.category = category.slice(0, 60);
                }
                out.push(model);
                if (out.length >= 100) break;
            }
            return out.length > 0 ? out : null;
        }

        async function refreshModels() {
            try {
                const result = await session.rpc.model.list();
                const normalized = normalizeAvailableModels(
                    result && Array.isArray(result.list) ? result.list : null
                );
                // Keep the last good catalog if a refresh returns nothing usable.
                if (normalized) {
                    availableModels = normalized;
                    publish();
                }
            } catch {}
        }

        // Consume a host-written model switch request: validate it targets THIS
        // Copilot session, then switch over RPC. `session.model_change` refreshes
        // the current-model line; we drop the request file whether it succeeds or
        // fails so the client can issue a fresh one (the model is unchanged on
        // failure, so retrying is safe).
        async function processSetModelRequest() {
            if (!ownsSharedFiles() || inFlightSetModelRequest) return;
            let encoded;
            try {
                encoded = readFileSync(setModelRequestPath, "utf8");
            } catch {
                return;
            }
            let request;
            try {
                request = JSON.parse(encoded);
            } catch {
                removeFile(setModelRequestPath);
                return;
            }
            if (!request || typeof request !== "object"
                    || request.schemaVersion !== 1
                    || typeof request.modelId !== "string"
                    || request.modelId.length === 0
                    || request.modelId.length > 200
                    || request.copilotSessionId !== session.sessionId) {
                removeFile(setModelRequestPath);
                return;
            }
            const params = { modelId: request.modelId };
            if (typeof request.reasoningEffort === "string"
                    && request.reasoningEffort.length > 0
                    && request.reasoningEffort.length <= 64) {
                params.reasoningEffort = request.reasoningEffort;
            }
            if (request.contextTier === "default"
                    || request.contextTier === "long_context") {
                params.contextTier = request.contextTier;
            }
            inFlightSetModelRequest = true;
            try {
                await session.rpc.model.switchTo(params);
                removeFile(setModelRequestPath);
                // Quotas / preferred default can shift after a switch.
                await refreshModels();
            } catch {
                removeFile(setModelRequestPath);
            } finally {
                inFlightSetModelRequest = false;
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
            foregroundTransitionAt = normalizedTimestamp(event.timestamp);
            if (scheduledTurnActive) setScheduledTurnMarker(true);
            publish();
        });

        session.on("assistant.turn_end", (event) => {
            if (event.agentId) return;
            foregroundTurnActive = false;
            foregroundTransitionAt = normalizedTimestamp(event.timestamp);
            publish();
        });

        session.on("session.idle", (event) => {
            if (event.agentId) return;
            idleGeneration += 1;
            lastIdleAborted = event.data.aborted === true;
            lastIdleTurnKind = currentTurnKind;
            currentTurnKind = null;
            foregroundTurnActive = false;
            foregroundTransitionAt = normalizedTimestamp(event.timestamp);
            scheduledTurnActive = false;
            activeSubagents.clear();
            publish();
            setTimeout(() => setScheduledTurnMarker(false), 5_000);
        });

        // Track the effective model so remote clients can show it. Seeded from
        // start/resume (selectedModel) and kept current via model_change
        // (newModel). Root agent only; sub-agent model changes are ignored.
        function applyModelInfo(name, reasoningEffort, contextTier) {
            if (typeof name !== "string" || name.length === 0) return;
            const info = { name };
            if (typeof reasoningEffort === "string" && reasoningEffort.length > 0) {
                info.reasoningEffort = reasoningEffort;
            }
            if (typeof contextTier === "string" && contextTier.length > 0) {
                info.contextTier = contextTier;
            }
            currentModel = info;
            publish();
        }

        // Derive the model from a model-bearing event. Used for both live events
        // and the replayed history below, so a session whose model was set before
        // we joined (session.start already fired) is still captured.
        function applyModelFromEvent(event) {
            if (event.agentId) return;
            const data = event.data || {};
            if (event.type === "session.model_change") {
                applyModelInfo(data.newModel, data.reasoningEffort, data.contextTier);
            } else if (event.type === "session.start"
                || event.type === "session.resume") {
                applyModelInfo(data.selectedModel, data.reasoningEffort, data.contextTier);
            }
        }

        session.on("session.start", applyModelFromEvent);
        session.on("session.resume", applyModelFromEvent);
        session.on("session.model_change", applyModelFromEvent);

        session.on("session.permissions_changed", (event) => {
            if (event.agentId) return;
            const mode = event.data.allowAllPermissionMode;
            allowAllUpdateGeneration += 1;
            applyAllowAllMarker(
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

        // Clear stale answer state before any new question can be published, and
        // establish the watcher before exposing questions so the first host answer
        // cannot be stranded during startup.
        if (ownsSharedFiles()) {
            removeFile(userInputResponsePath);
            removeFile(elicitationResponsePath);
            // A switch request from a previous session in this tab must never be
            // executed against the newly joined session.
            removeFile(setModelRequestPath);
        }
        let userInputWatcher = null;
        try {
            userInputWatcher = watch(sessionsDir, (_eventType, filename) => {
                if (!filename || filename === userInputResponseName) {
                    processUserInputResponse();
                }
                if (!filename || filename === elicitationResponseName) {
                    processElicitationResponse();
                }
                if (!filename || filename === setModelRequestName) {
                    processSetModelRequest();
                }
            });
        } catch {}

        const eventInterestHandles = [];
        const inFlightEventInterestRegistrations = new Set();
        let timer = null;

        async function releaseEventInterests() {
            const handles = [...eventInterestHandles];
            for (const handle of handles) {
                let released = false;
                for (let attempt = 0; attempt < 2 && !released; attempt += 1) {
                    try {
                        const result = await session.rpc.eventLog.releaseInterest({ handle });
                        if (result?.success === true) {
                            released = true;
                        } else {
                            throw new Error("releaseInterest returned unsuccessful result");
                        }
                    } catch (error) {
                        if (attempt === 1) {
                            console.error(
                                "[copilot-projects] failed to release event interest:",
                                error
                            );
                        }
                    }
                }
                if (released) {
                    const index = eventInterestHandles.indexOf(handle);
                    if (index !== -1) eventInterestHandles.splice(index, 1);
                }
            }
        }

        async function registerEventInterest(eventType) {
            let registration = null;
            try {
                registration = session.rpc.eventLog.registerInterest({ eventType });
                inFlightEventInterestRegistrations.add(registration);
                const interest = await registration;
                if (interest?.handle) eventInterestHandles.push(interest.handle);
            } catch (error) {
                console.error(
                    "[copilot-projects] failed to register interest in " + eventType + ":",
                    error
                );
            } finally {
                if (registration) inFlightEventInterestRegistrations.delete(registration);
            }
        }

        async function awaitEventInterestRegistrations() {
            const registrations = [...inFlightEventInterestRegistrations];
            if (registrations.length > 0) await Promise.allSettled(registrations);
        }

        function cleanupSharedFiles() {
            if (timer) clearInterval(timer);
            clearTimeout(transcriptPublishTimer);
            if (userInputWatcher) {
                try { userInputWatcher.close(); } catch {}
                userInputWatcher = null;
            }
            // Use the read-only ownership check (never claim during cleanup) so an
            // exiting spawned helper can't wipe a live interactive session's
            // markers. The owner flushes any progress buffered behind the publish
            // throttle before releasing the shared files.
            if (isRecordedOwner()) {
                writeTranscriptSnapshot();
                removeFile(snapshotPath);
                removeFile(scheduledTurnPath);
                // Deliberately keep transcriptOwnerPath: it records this process's
                // appSessionId/copilotSessionId provenance for the transcript that
                // was just flushed. If we deleted it here, a foreign reader that
                // arrives after this exit (but before any new owner claims the
                // file) would find no owner marker and default to allowing the
                // read, silently accepting a wrong-tab snapshot without ever
                // recording the quarantine. Leaving the marker in place lets
                // ownsSharedFiles()/reclaimDeadOwner() reclaim it safely once this
                // pid is confirmed dead, while still letting readers verify
                // provenance in the meantime.
                removeFile(userInputResponsePath);
                removeFile(elicitationResponsePath);
                removeFile(setModelRequestPath);
            }
        }
        let shuttingDown = false;
        async function shutdown(signal) {
            if (shuttingDown) return;
            shuttingDown = true;
            cleanupSharedFiles();
            await awaitEventInterestRegistrations();
            await releaseEventInterests();
            process.exit(signal === "SIGINT" ? 130 : 143);
        }
        process.once("SIGTERM", () => { shutdown("SIGTERM").catch(() => process.exit(143)); });
        process.once("SIGINT", () => { shutdown("SIGINT").catch(() => process.exit(130)); });
        process.once("exit", cleanupSharedFiles);

        session.on("user_input.requested", (event) => {
            const entry = userInputEntry(event);
            // A rejected entry is never exposed remotely; the terminal keeps the
            // exact prompt so nothing is lost.
            if (!entry) return;
            pendingUserInputs.set(entry.requestId, entry);
            boundPendingUserInputs();
            publish();
        });

        session.on("user_input.completed", (event) => {
            const requestId = event.data?.requestId;
            if (typeof requestId === "string" && pendingUserInputs.delete(requestId)) {
                publish();
            }
        });

        session.on("elicitation.requested", (event) => {
            const entry = elicitationEntry(event);
            if (!entry) return;
            pendingElicitations.set(entry.requestId, entry);
            boundPendingElicitations();
            publish();
        });

        session.on("elicitation.completed", (event) => {
            const requestId = event.data?.requestId;
            if (typeof requestId === "string" && pendingElicitations.delete(requestId)) {
                publish();
            }
        });

        // Both user_input.requested and elicitation.requested are gated events: the
        // runtime only delivers them to consumers that register interest, otherwise
        // it keeps its default terminal-only handling. Register AFTER attaching the
        // listeners so a question dispatched immediately can't slip past them.
        for (const eventType of ["user_input.requested", "elicitation.requested"]) {
            if (shuttingDown) break;
            await registerEventInterest(eventType);
        }

        await refreshAllowAll();
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
            for (const event of history) {
                processTranscriptEvent(event, false, true);
                applyModelFromEvent(event);
            }
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
        await refreshModels();

        processUserInputResponse();
        processElicitationResponse();
        processSetModelRequest();

        timer = setInterval(() => {
            refreshSchedules();
            refreshModels();
            processUserInputResponse();
            processElicitationResponse();
            processSetModelRequest();
        }, 5_000);
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
