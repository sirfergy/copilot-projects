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
    import { homedir } from "node:os";
    import { dirname, join } from "node:path";
    import {
        createReadStream, existsSync as fileExistsSync, lstatSync,
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
    const extensionParentPid = Number(process.env.COPILOT_EXTENSION_PARENT_PID);
    const validExtensionParentPid = Number.isSafeInteger(extensionParentPid)
        && extensionParentPid > 1;
    // The Copilot conversation this process is currently tracking. `/new` and
    // `/resume` swap the conversation underneath a single long-lived extension
    // process, so this is the ONE mutable source of truth for the current
    // identity. `session.sessionId` is read only to seed it (and as a last
    // resort when a lifecycle event omits the id); no other reader may consult
    // it, otherwise a rotation would leave part of the extension pinned to the
    // previous conversation.
    let copilotSessionId = typeof session.sessionId === "string"
        ? session.sessionId
        : "";
    let validCopilotSessionId = sessionIdPattern.test(copilotSessionId);
    // Every Copilot session id this process has held. Deliberately uncapped and
    // never evicted: it is what proves an owner marker left under a previous
    // conversation is our own — so `/new` can roll it forward even after an
    // earlier rotation failed to take — and what stops the poll safety net from
    // ever rotating BACKWARD onto a conversation we already left. A bounded set
    // would silently lose both guarantees once enough switches had happened;
    // the entries are 36-byte ids, so unbounded growth is irrelevant here.
    const ownedCopilotSessionIds = new Set(
        validCopilotSessionId ? [copilotSessionId] : []
    );

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
        // Passive observation only: NEVER register interest / call setRequired for
        // permission events, or this extension would take prompt ownership away
        // from the CLI's terminal UI.
        const pendingPermissionRequestIds = new Set();
        const completedPermissionRequestIds = new Set();
        let terminalDisconnectError = null;
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
        // Single-flight guards. These hold the conversation generation that owns
        // the in-flight call rather than a plain boolean: after a `/new` /
        // `/resume` rotation the previous conversation's RPC may still be
        // outstanding, and a boolean would make the new conversation wait for it
        // (leaving the picker/schedules empty until the next 5s poll) and would
        // then be cleared by the OLD call's `finally`, releasing a lock it no
        // longer owns. Overlapping one old and one new call is safe because
        // every result mutation is fenced on `conversationGeneration`.
        let schedulesRefreshGeneration = null;
        let modelsRefreshGeneration = null;
        let setModelRequestGeneration = null;
        let schedules = [];
        const transcriptTurns = [];
        const transcriptEventIds = new Set();
        const queuedTranscriptEvents = [];
        let pendingTranscriptTurn = null;
        let transcriptAssistantTurnActive = false;
        let latestResumeTranscriptTurnId = null;
        let synthesizedTaskCompletionContent = null;
        let transcriptInitialized = false;
        let transcriptPublishTimer = null;
        let durableReconcileTimer = null;
        let durableReconcileRun = null;
        let durableReconcileQueued = false;
        let durableFailureStreak = 0;
        let durableTranscriptAuthoritative = false;
        let durableHistoryIdentity = null;
        let durableDisabledIdentity = null;
        let durableHistoryOffset = 0;
        let durablePending = Buffer.alloc(0);
        let durableDroppingOversizedLine = false;
        let durableBaselineComplete = false;
        let durableFallbackTurns = [];
        let durableFallbackModel = null;
        let durableAskUser = null;
        let durableAskUserScan = null;
        let lastLiveQuestionAt = null;
        let sharedFilesOwnershipInitializedFor = null;
        let allowAllRefreshQueued = false;
        let allowAllUpdateGeneration = 0;
        let foregroundSessionActive = false;
        let foregroundObservationStartedAt = 0;
        let foregroundRefreshQueued = false;
        let foregroundRefreshPending = false;
        let foregroundHandlingReady = false;
        // Monotonic id for the conversation currently loaded into the state
        // above. Bumped by every `/new` / `/resume` identity rotation so async
        // work started for a previous conversation (durable replay, SDK history
        // bootstrap, schedule/model/allow-all refreshes) can detect that it is
        // stale and abort before mutating the new conversation's state.
        let conversationGeneration = 0;
        // Id of the lifecycle event that performed the most recent rotation. The
        // SDK delivers one event to BOTH the named and the generic listener; the
        // one that fires second must not re-enter it as ordinary conversation
        // content, or a `/resume` would append a spurious resume separator to
        // the conversation that was just loaded — making behavior depend on a
        // dispatch order the SDK does not guarantee.
        let rotationConsumedEventId = null;

        const MAX_TRANSCRIPT_TURNS = 200;
        const MAX_TRANSCRIPT_BYTES = 5 * 1024 * 1024;
        const MAX_TRANSCRIPT_TEXT = 50_000;
        const MAX_TRANSCRIPT_METADATA_TEXT = 512;
        const MAX_TRANSCRIPT_ASSISTANT_MESSAGES = 250;
        const MAX_TRANSCRIPT_TOOLS = 400;
        const MAX_TRANSCRIPT_EVENT_IDS = 50_000;
        const MAX_DURABLE_EVENT_BYTES = 4 * 1_024 * 1_024;
        const HISTORY_REPLAY_TIMEOUT_MS = 5_000;
        const DURABLE_REPLAY_TIMEOUT_MS = 5_000;
        const DURABLE_RECONCILE_DEBOUNCE_MS = 200;
        const DURABLE_RECONCILE_POLL_MS = 5_000;
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
        const DURABLE_ASK_USER_PREFIX = "synthetic::durable-ask-user::";

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
                            !== boundedMetadataText(copilotSessionId)
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
                && owner.copilotSessionId === copilotSessionId
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

        function ownerMarkerPayload(claimedAt = Date.now()) {
            return {
                ...(appSessionResolution.native ? {appSessionId} : {}),
                copilotSessionId,
                pid: process.pid,
                bootTime: currentBootTime() ?? undefined,
                ...(validExtensionParentPid
                    ? { parentPid: extensionParentPid }
                    : {}),
                ...(Number.isFinite(claimedAt) && claimedAt > 0
                    ? { claimedAt }
                    : {}),
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
        function replaceOwnerMarker(claimedAt) {
            const temporaryPath = `${transcriptOwnerPath}.${process.pid}.tmp`;
            try {
                writeFileSync(
                    temporaryPath,
                    JSON.stringify(ownerMarkerPayload(claimedAt)),
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
                        copilotSessionId,
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

        // Is this marker one WE wrote for a conversation we have since left
        // (`/new` / `/resume`)? Several Copilot processes legitimately share one
        // app session id, so the pid check is what makes this a self-update: a
        // same-tab helper has a different pid and can never take this path, and
        // therefore can never displace the interactive owner. The session id
        // must be one this process actually held, and (when our tab identity is
        // natively resolved) the marker must name our tab.
        function ownerIsPreviousSelf(owner) {
            return Boolean(owner)
                && owner.pid === process.pid
                && typeof owner.copilotSessionId === "string"
                && owner.copilotSessionId !== copilotSessionId
                && ownedCopilotSessionIds.has(owner.copilotSessionId)
                && (!appSessionResolution.native
                    || owner.appSessionId === appSessionId);
        }

        // The shared snapshot on disk still describes the conversation we just
        // left. Leaving it in place under an owner marker that now names a
        // different Copilot session is exactly the provenance mismatch the host
        // is entitled to quarantine permanently, so discard it. Idempotent, and
        // it only ever touches the host's snapshot — Copilot's durable
        // per-session history is never removed.
        function discardRotatedTranscript() {
            removeFile(transcriptPath);
        }

        // Roll our own marker forward onto the newly adopted conversation. The
        // host's shared snapshot is discarded inside the SAME critical section
        // as the marker write so no reader can sample the previous
        // conversation's transcript under the new marker.
        function rotateOwnerMarker(previousCopilotSessionId) {
            return withTranscriptOwnerLock(() => {
                const owner = recordedOwner();
                if (!ownerIsPreviousSelf(owner)) return false;
                if (owner.copilotSessionId !== previousCopilotSessionId) return false;
                discardRotatedTranscript();
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
                    // Our own marker from a conversation we have left. Without
                    // this, `ownerHoldsClaim` would see a live process that
                    // belongs to this tab (us) and block the rotated
                    // conversation from ever publishing for this tab.
                    if (ownerIsPreviousSelf(owner)) {
                        if (rotateOwnerMarker(owner.copilotSessionId)) {
                            activateSharedFilesOwnership(true);
                            return true;
                        }
                        continue;
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

        // A foreground query is the only authority allowed to displace another
        // live process from this tab. The parent-pid match keeps a nested
        // `copilot -p` process (whose own server also calls itself foreground)
        // from stealing the interactive CLI's shared files.
        function foregroundOwnerBlocksClaim(owner) {
            return Boolean(owner) && ownerHoldsClaim(owner)
                && (owner.copilotSessionId === copilotSessionId
                    || !validExtensionParentPid
                    || owner.parentPid !== extensionParentPid
                    || (Number.isFinite(owner.claimedAt)
                        && foregroundObservationStartedAt <= owner.claimedAt));
        }

        function claimForegroundOwnership() {
            if (!foregroundSessionActive) return false;
            if (isRecordedOwner()) {
                activateSharedFilesOwnership();
                return true;
            }
            if (foregroundOwnerBlocksClaim(recordedOwner())) return false;
            const claimed = withTranscriptOwnerLock(() => {
                const owner = recordedOwner();
                if (ownerMatchesCurrentProcess(owner)) return true;
                if (foregroundOwnerBlocksClaim(owner)) return false;
                // Keep the marker and transcript provenance in lockstep. A
                // reader that sees the new marker alongside the old bytes would
                // permanently quarantine the previous conversation.
                discardRotatedTranscript();
                return replaceOwnerMarker(foregroundObservationStartedAt);
            });
            if (claimed) activateSharedFilesOwnership(true);
            return claimed;
        }

        function activateForegroundSharedFiles() {
            if (!claimForegroundOwnership()) return;
            setScheduledTurnMarker(scheduledTurnActive);
            publish();
            publishTranscript(true);
        }

        async function refreshForegroundAuthority() {
            const observedAt = Date.now();
            let timeout = null;
            let shouldActivate = false;
            try {
                const timeoutPromise = new Promise((_, reject) => {
                    timeout = setTimeout(
                        () => reject(new Error("foreground query timed out")),
                        10_000
                    );
                    timeout.unref?.();
                });
                const response = await Promise.race([
                    session.connection.sendRequest("session.getForeground", {}),
                    timeoutPromise,
                ]);
                if (typeof response?.sessionId !== "string") return;
                const wasActive = foregroundSessionActive;
                foregroundSessionActive = response.sessionId === copilotSessionId;
                foregroundObservationStartedAt = observedAt;
                shouldActivate = foregroundHandlingReady
                    && foregroundSessionActive
                    && (!wasActive || !isRecordedOwner());
            } catch {
                // Older SDK servers have no foreground query. The existing
                // owner election remains authoritative in that compatibility mode.
            } finally {
                if (timeout) clearTimeout(timeout);
            }
            if (shouldActivate) activateForegroundSharedFiles();
        }

        function refreshForegroundAuthoritySoon() {
            if (foregroundRefreshQueued) {
                foregroundRefreshPending = true;
                return;
            }
            foregroundRefreshQueued = true;
            refreshForegroundAuthority()
                .finally(() => {
                    foregroundRefreshQueued = false;
                    if (foregroundRefreshPending) {
                        foregroundRefreshPending = false;
                        refreshForegroundAuthoritySoon();
                    }
                });
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
        refreshForegroundAuthoritySoon();

        function isTerminalDisconnect(error) {
            if (!error) return false;
            const message = String(error).toLowerCase();
            return message.includes("connection is closed")
                || message.includes("connection is disposed");
        }

        function publish(error) {
            if (!ownsSharedFiles()) return;
            if (isTerminalDisconnect(error)) {
                terminalDisconnectError = String(error);
            }
            const reportedError = error ? String(error) : terminalDisconnectError;
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
                trackedElicitations: durableAskUser
                    ? [...pendingElicitations.values(), durableAskUser]
                    : [...pendingElicitations.values()],
                // Always present (including []) so the host can distinguish this
                // extension from an older build that cannot validate prompts.
                pendingPermissionRequestIds: [...pendingPermissionRequestIds],
                ...(currentModel ? { model: currentModel } : {}),
                ...(availableModels ? { availableModels } : {}),
                ...(reportedError ? { error: reportedError } : {}),
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
            if (requestId.startsWith(DURABLE_ASK_USER_PREFIX)) return null;
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
            if (response.copilotSessionId !== copilotSessionId) {
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
            if (requestId.startsWith(DURABLE_ASK_USER_PREFIX)) return null;
            const message = data.message;
            if (typeof message !== "string") return null;
            if (userInputByteLength(message) > MAX_ELICITATION_MESSAGE_BYTES) return null;
            const mode = typeof data.mode === "string" ? data.mode : null;
            if (mode === "terminal-default") return null;
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
                if (Object.prototype.hasOwnProperty.call(
                    schema,
                    "x-copilot-projects-terminal-default"
                )) return null;
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

        function clearDurableAskUser() {
            const changed = durableAskUser !== null
                || durableAskUserScan !== null;
            durableAskUser = null;
            durableAskUserScan = null;
            return changed;
        }

        function observeLiveRootQuestion(event) {
            if (event.agentId) return false;
            const observedAt = normalizedTimestamp(event.timestamp);
            if (!lastLiveQuestionAt || observedAt > lastLiveQuestionAt) {
                lastLiveQuestionAt = observedAt;
            }
            let changed = false;
            if (durableAskUser?.requestedAt <= observedAt) {
                durableAskUser = null;
                changed = true;
            }
            if (durableAskUserScan?.requestedAt <= observedAt) {
                durableAskUserScan = null;
                changed = true;
            }
            return changed;
        }

        function durableAskUserMessage(event) {
            const data = event.data;
            if (!data || typeof data !== "object"
                    || data.toolName !== "ask_user"
                    || data.parentToolCallId != null) {
                return null;
            }
            const message = data.arguments?.message;
            return typeof message === "string" ? message : null;
        }

        function durableAskUserBooleanSchema(event) {
            const schema = event.data?.arguments?.requestedSchema;
            if (!schema || typeof schema !== "object" || Array.isArray(schema)) {
                return null;
            }
            if (Object.keys(schema).some((key) => key !== "properties")) {
                return null;
            }
            const properties = schema.properties;
            if (!properties || typeof properties !== "object"
                    || Array.isArray(properties)
                    || Object.keys(properties).length !== 1) {
                return null;
            }
            const field = properties[Object.keys(properties)[0]];
            if (!field || typeof field !== "object" || Array.isArray(field)
                    || field.type !== "boolean"
                    || Object.keys(field).some((key) =>
                        !["type", "title", "description", "default"].includes(key))
                    || (field.title != null && typeof field.title !== "string")
                    || (field.description != null
                        && typeof field.description !== "string")
                    || typeof field.default !== "boolean") {
                return null;
            }
            const publishedSchema = {
                ...schema,
                "x-copilot-projects-terminal-default": true,
            };
            let serialized;
            try {
                serialized = JSON.stringify(publishedSchema);
            } catch {
                return null;
            }
            if (Buffer.byteLength(serialized) > MAX_ELICITATION_SCHEMA_BYTES) {
                return null;
            }
            return publishedSchema;
        }

        function durableAskUserEntry(event) {
            const message = durableAskUserMessage(event);
            const toolCallId = event.data?.toolCallId;
            if (message === null
                    || userInputByteLength(message)
                        > MAX_ELICITATION_MESSAGE_BYTES
                    || typeof toolCallId !== "string" || !toolCallId
                    || toolCallId.length > 200) {
                return null;
            }
            const requestedAt = normalizedTimestamp(event.timestamp);
            if (lastLiveQuestionAt && requestedAt <= lastLiveQuestionAt) {
                return null;
            }
            const schema = durableAskUserBooleanSchema(event);
            return {
                requestId: DURABLE_ASK_USER_PREFIX + toolCallId,
                message,
                mode: schema ? "terminal-default" : "terminal",
                ...(schema ? { schema } : {}),
                elicitationSource: "durable-ask-user",
                requestedAt,
            };
        }

        function durableHookMayFollowAskUser(event) {
            const type = event.data?.hookType;
            return (event.type === "hook.start" || event.type === "hook.end")
                && (type === "preToolUse" || type === "notification");
        }

        // A root `ask_user` blocks the terminal. When its gated SDK event is
        // missing, expose one read-only terminal card only while the ask start
        // remains the last significant root event in durable history.
        function applyDurableAskUserEvent(event) {
            if (event.agentId) return;
            if (durableAskUserScan && durableHookMayFollowAskUser(event)) {
                return;
            }
            durableAskUserScan = event.type === "tool.execution_start"
                ? durableAskUserEntry(event)
                : null;
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
            if (requestId.startsWith(DURABLE_ASK_USER_PREFIX)) {
                removeFile(elicitationResponsePath);
                return;
            }
            if (inFlightElicitationResponses.has(requestId)) return;
            if (response.copilotSessionId !== copilotSessionId) {
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
                copilotSessionId: boundedMetadataText(copilotSessionId),
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

        function publishTranscript(force = false) {
            if (!ownsSharedFiles()) return;
            if (!force && durableTranscriptAuthoritative
                    && !durableBaselineComplete) {
                return;
            }
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

        function appendTranscriptAssistantMessage(event, value) {
            if (typeof value !== "string" || value.length === 0) return;
            ensureSyntheticTranscriptTurn(event);
            const content = boundedText(value);
            if (pendingTranscriptTurn.assistantMessages.length
                    >= MAX_TRANSCRIPT_ASSISTANT_MESSAGES) {
                pendingTranscriptTurn.assistantMessages.shift();
            }
            pendingTranscriptTurn.assistantMessages.push({
                id: boundedMetadataText(event.data.messageId || event.id),
                timestamp: normalizedTimestamp(event.timestamp),
                content,
            });
        }

        function resetPendingTranscriptTurn() {
            pendingTranscriptTurn = null;
            synthesizedTaskCompletionContent = null;
        }

        function finishTranscriptTurn(aborted, endedAt) {
            const turn = pendingTranscriptTurn;
            resetPendingTranscriptTurn();
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

        function boundCompletedPermissionIds() {
            while (completedPermissionRequestIds.size > 128) {
                completedPermissionRequestIds.delete(
                    completedPermissionRequestIds.values().next().value
                );
            }
        }

        function applyPermissionEvent(event, live) {
            if (event.type === "session.idle") {
                if (event.agentId) return;
                if (pendingPermissionRequestIds.size > 0) {
                    pendingPermissionRequestIds.clear();
                    if (live) publish();
                }
                return;
            }
            const requestId = event.data?.requestId;
            if (typeof requestId !== "string" || requestId.length === 0) return;
            let changed = false;
            if (event.type === "permission.requested") {
                if (!completedPermissionRequestIds.has(requestId)
                        && !pendingPermissionRequestIds.has(requestId)
                        && pendingPermissionRequestIds.size < 64) {
                    pendingPermissionRequestIds.add(requestId);
                    changed = true;
                }
            } else if (event.type === "permission.completed") {
                completedPermissionRequestIds.add(requestId);
                boundCompletedPermissionIds();
                changed = pendingPermissionRequestIds.delete(requestId);
            }
            if (live && changed) publish();
        }

        function rememberTranscriptEvent(event) {
            const id = event?.id;
            if (typeof id !== "string" || id.length === 0) return true;
            if (transcriptEventIds.has(id)) return false;
            transcriptEventIds.add(id);
            while (transcriptEventIds.size > MAX_TRANSCRIPT_EVENT_IDS) {
                transcriptEventIds.delete(transcriptEventIds.values().next().value);
            }
            return true;
        }

        function clearTranscriptEventIds() {
            transcriptEventIds.clear();
        }

        function resetTranscriptReplayState(turns, model) {
            transcriptTurns.length = 0;
            transcriptTurns.push(...turns);
            resetPendingTranscriptTurn();
            transcriptAssistantTurnActive = false;
            latestResumeTranscriptTurnId = null;
            currentModel = model;
            clearTranscriptEventIds();
        }

        function processTranscriptEvent(event, live) {
            if (event.agentId) return;
            if (!rememberTranscriptEvent(event)) return;

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
                if (event.data.content) {
                    const content = boundedText(event.data.content);
                    if (content === synthesizedTaskCompletionContent) {
                        synthesizedTaskCompletionContent = null;
                    } else {
                        appendTranscriptAssistantMessage(event, content);
                        if (live) schedulePublishTranscript();
                    }
                }
                break;
            case "tool.execution_start": {
                ensureSyntheticTranscriptTurn(event);
                const toolId = boundedMetadataText(event.data.toolCallId);
                const existing = pendingTranscriptTurn.tools.find(
                    (tool) => tool.id === toolId
                );
                const askUserMessage = durableAskUserMessage(event);
                const messageId = boundedMetadataText(
                    event.data.messageId || event.id
                );
                if (askUserMessage !== null
                        && !existing
                        && !pendingTranscriptTurn.assistantMessages.some(
                            (message) => message.id === messageId
                        )) {
                    appendTranscriptAssistantMessage(event, askUserMessage);
                }
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
            case "session.task_complete": {
                const summary = typeof event.data.summary === "string"
                    ? boundedText(event.data.summary)
                    : "";
                // Older durable events omit success; like the SDK consumers,
                // treat only an explicit false as rejected/blocked.
                if (event.data.success !== false && summary.length > 0) {
                    ensureSyntheticTranscriptTurn(event);
                    const alreadyPresent = pendingTranscriptTurn.assistantMessages.some(
                        (message) => message.content === summary
                    );
                    if (!alreadyPresent) {
                        appendTranscriptAssistantMessage(event, summary);
                        synthesizedTaskCompletionContent = summary;
                    }
                    if (live) schedulePublishTranscript();
                }
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

        function replayHistoryEvent(
            event,
            includePermissions,
            includePermissionIdle = includePermissions
        ) {
            if (!event || typeof event !== "object"
                    || typeof event.type !== "string") {
                return false;
            }
            try {
                if (includePermissions
                        && (includePermissionIdle
                            || event.type !== "session.idle")) {
                    applyPermissionEvent(event, false);
                }
                applyModelFromEvent(event);
                processTranscriptEvent(event, false);
                return !event.agentId;
            } catch {
                if (typeof event.id === "string") {
                    transcriptEventIds.delete(event.id);
                }
                return false;
            }
        }

        session.on((event) => {
            if (!event.agentId && (event.type === "user.message"
                    || event.type === "session.start"
                    || event.type === "session.resume")) {
                refreshForegroundAuthoritySoon();
            }
            // Any delivered event proves the SDK connection is live again.
            terminalDisconnectError = null;
            // Identity first: a `/new` / `/resume` event must rotate before any
            // of the state below can be attributed to the wrong conversation.
            // The rotation reloads history itself, so the event is not queued.
            if (maybeRotateCopilotSession(event)) return;
            if (typeof event?.id === "string"
                    && event.id === rotationConsumedEventId) {
                return;
            }
            if (!transcriptInitialized) {
                queuedTranscriptEvents.push(event);
            } else {
                applyPermissionEvent(event, true);
                applyModelFromEvent(event);
                if (durableTranscriptAuthoritative) {
                    scheduleDurableReconcile();
                } else {
                    processTranscriptEvent(event, true);
                }
            }
        });

        async function refreshSchedules() {
            const generation = conversationGeneration;
            if (schedulesRefreshGeneration === generation) return;
            schedulesRefreshGeneration = generation;
            try {
                const result = await session.rpc.schedule.list();
                if (generation !== conversationGeneration) return;
                schedules = result.entries;
                terminalDisconnectError = null;
                publish();
            } catch (error) {
                if (generation !== conversationGeneration) return;
                publish(error);
            } finally {
                // Release only OUR lock; a newer generation's refresh keeps its.
                if (schedulesRefreshGeneration === generation) {
                    schedulesRefreshGeneration = null;
                }
            }
        }

        async function refreshAllowAll() {
            if (!ownsSharedFiles()) return;
            const generation = ++allowAllUpdateGeneration;
            const conversation = conversationGeneration;
            // Fail closed if the RPC is unavailable: a stale marker must never grant
            // full permissions to a different session in the same tab.
            removeFile(allowAllPath);
            try {
                const result = await session.rpc.permissions.getAllowAll();
                if (generation === allowAllUpdateGeneration
                        && conversation === conversationGeneration) {
                    applyAllowAllMarker(result.enabled === true);
                }
            } catch {}
        }

        async function sdkHistoryWithTimeout() {
            let timeout;
            const historyPromise = Promise.resolve().then(() => session.getEvents());
            historyPromise.catch(() => {});
            try {
                return await Promise.race([
                    historyPromise,
                    new Promise((_, reject) => {
                        timeout = setTimeout(
                            () => reject(new Error("history replay timed out")),
                            HISTORY_REPLAY_TIMEOUT_MS
                        );
                    }),
                ]);
            } finally {
                clearTimeout(timeout);
            }
        }

        function durableEventsPath() {
            if (!validCopilotSessionId) {
                throw new Error("invalid Copilot session id");
            }
            const copilotHome = process.env.COPILOT_HOME
                || join(homedir(), ".copilot");
            return join(
                copilotHome,
                "session-state",
                copilotSessionId,
                "events.jsonl"
            );
        }

        function durableIdentity(attributes) {
            return [
                attributes.dev,
                attributes.ino,
                attributes.birthtimeMs,
            ].join(":");
        }

        function resetDurableCursor(identity) {
            clearTimeout(transcriptPublishTimer);
            transcriptPublishTimer = null;
            if (durableHistoryIdentity === null || durableBaselineComplete) {
                durableFallbackTurns = [...transcriptTurns];
                durableFallbackModel = currentModel;
            }
            durableHistoryIdentity = identity;
            durableHistoryOffset = 0;
            durablePending = Buffer.alloc(0);
            durableDroppingOversizedLine = false;
            durableBaselineComplete = false;
            durableAskUser = null;
            durableAskUserScan = null;
            resetTranscriptReplayState([], currentModel);
        }

        function loseDurableAuthority(disableCurrentIdentity = false) {
            if (disableCurrentIdentity) {
                durableDisabledIdentity = durableHistoryIdentity;
            }
            if (!durableBaselineComplete) {
                resetTranscriptReplayState(
                    durableFallbackTurns,
                    durableFallbackModel
                );
            }
            durableTranscriptAuthoritative = false;
            durableFailureStreak = 0;
            durableHistoryIdentity = null;
            durableHistoryOffset = 0;
            durablePending = Buffer.alloc(0);
            durableDroppingOversizedLine = false;
            durableBaselineComplete = false;
            if (clearDurableAskUser()) publish();
        }

        function durableHistoryAvailable() {
            try {
                const attributes = lstatSync(durableEventsPath());
                return attributes.isFile();
            } catch {
                return false;
            }
        }

        async function reconcileDurableHistoryOnce() {
            // A `/new` / `/resume` rotation swaps the durable file this replay
            // is streaming AND clears the state it feeds. Anything read for the
            // previous conversation must be discarded rather than appended to
            // the new one, so re-check the generation at every point where the
            // stream would otherwise mutate shared state.
            const generation = conversationGeneration;
            const stale = () => generation !== conversationGeneration;
            const eventsPath = durableEventsPath();
            let attributes;
            try {
                attributes = lstatSync(eventsPath);
            } catch {
                loseDurableAuthority();
                return;
            }
            if (!attributes.isFile()) {
                loseDurableAuthority();
                return;
            }
            const identity = durableIdentity(attributes);
            if (!durableTranscriptAuthoritative
                    && durableDisabledIdentity === identity) {
                return;
            }
            if (durableDisabledIdentity !== identity) {
                durableDisabledIdentity = null;
            }
            if (!durableTranscriptAuthoritative) {
                durableTranscriptAuthoritative = true;
                resetDurableCursor(identity);
            } else if (durableHistoryIdentity !== identity
                    || attributes.size < durableHistoryOffset) {
                resetDurableCursor(identity);
            }

            if (attributes.size === durableHistoryOffset) {
                if (!durableBaselineComplete) {
                    durableBaselineComplete = true;
                    publish();
                    publishTranscript();
                }
                return;
            }

            const input = createReadStream(eventsPath, {
                start: durableHistoryOffset,
                end: attributes.size - 1,
            });
            input.on("error", () => {});
            const timeout = setTimeout(
                () => input.destroy(new Error("durable history replay timed out")),
                DURABLE_REPLAY_TIMEOUT_MS
            );
            let changed = false;
            try {
                for await (const chunk of input) {
                    // Abort before touching any state: the conversation this
                    // stream belongs to is no longer the one being tracked.
                    if (stale()) return;
                    durableHistoryOffset += chunk.length;
                    let offset = 0;
                    while (offset < chunk.length) {
                        const newline = chunk.indexOf(0x0A, offset);
                        const end = newline === -1 ? chunk.length : newline;
                        const segment = chunk.subarray(offset, end);
                        if (durableDroppingOversizedLine) {
                            if (newline !== -1) {
                                durableDroppingOversizedLine = false;
                            }
                        } else if (durablePending.length + segment.length
                                > MAX_DURABLE_EVENT_BYTES) {
                            durablePending = Buffer.alloc(0);
                            durableDroppingOversizedLine = newline === -1;
                            durableAskUserScan = null;
                        } else {
                            durablePending = durablePending.length === 0
                                ? Buffer.from(segment)
                                : Buffer.concat(
                                    [durablePending, segment],
                                    durablePending.length + segment.length
                                );
                            if (newline !== -1) {
                                let text = durablePending.toString("utf8");
                                if (text.endsWith("\r")) text = text.slice(0, -1);
                                try {
                                    const event = JSON.parse(text);
                                    if (event && typeof event === "object") {
                                        applyDurableAskUserEvent(event);
                                        changed = replayHistoryEvent(
                                            event,
                                            true,
                                            false
                                        ) || changed;
                                    }
                                } catch {
                                    // The runtime may be appending the final line
                                    // while the stream reaches EOF.
                                }
                                durablePending = Buffer.alloc(0);
                            }
                        }
                        if (newline === -1) break;
                        offset = newline + 1;
                    }
                }
                const completedBaseline = !durableBaselineComplete;
                if (stale()) return;
                durableBaselineComplete = true;
                const questionChanged =
                    durableAskUser?.requestId !== durableAskUserScan?.requestId;
                durableAskUser = durableAskUserScan;
                if (completedBaseline) {
                    durableFallbackTurns = [...transcriptTurns];
                    durableFallbackModel = currentModel;
                }
                if (changed || completedBaseline || questionChanged) {
                    publish();
                    publishTranscript();
                }
            } finally {
                clearTimeout(timeout);
                input.destroy();
            }
        }

        // Returns a promise that resolves only once a replay has run for the
        // CALLER's conversation generation. When a replay for a conversation we
        // have since left is still streaming, queue another pass and hand back
        // the shared run promise: returning early instead would leave the
        // rotated drawer blank until the next 5s poll. The old stream's own
        // mutations stay fenced by `conversationGeneration`.
        function reconcileDurableHistory() {
            if (durableReconcileRun) {
                durableReconcileQueued = true;
                return durableReconcileRun;
            }
            // The loop body is inlined so the `while` re-check and the release
            // of `durableReconcileRun` happen in one synchronous step; a caller
            // can never observe a run that is about to end but still latched.
            durableReconcileRun = (async () => {
                try {
                    do {
                        durableReconcileQueued = false;
                        const previousOffset = durableHistoryOffset;
                        const generation = conversationGeneration;
                        try {
                            await reconcileDurableHistoryOnce();
                            if (generation !== conversationGeneration) continue;
                            durableFailureStreak = 0;
                        } catch {
                            // A failure recorded against a conversation we have
                            // since left must not disable the new one's history.
                            if (generation !== conversationGeneration) continue;
                            if (durableHistoryOffset > previousOffset) {
                                durableFailureStreak = 0;
                            } else {
                                durableFailureStreak += 1;
                                if (durableFailureStreak >= 3) {
                                    loseDurableAuthority(true);
                                }
                            }
                        }
                    } while (durableReconcileQueued);
                } finally {
                    durableReconcileRun = null;
                }
            })();
            return durableReconcileRun;
        }

        function scheduleDurableReconcile(
            delay = DURABLE_RECONCILE_DEBOUNCE_MS
        ) {
            if (durableReconcileTimer !== null) return;
            durableReconcileTimer = setTimeout(() => {
                durableReconcileTimer = null;
                reconcileDurableHistory();
            }, delay);
        }

        // Loads whichever conversation `copilotSessionId` currently names into
        // the (already cleared) live state, then publishes it. Startup and
        // `/new` / `/resume` rotation share this one path so the two can't
        // drift. Every await is fenced by `generation`: once the conversation
        // rotates again, an older bootstrap aborts instead of landing the
        // previous conversation's history in the new state.
        async function bootstrapConversation(generation, options = {}) {
            const stale = () => generation !== conversationGeneration;
            if (stale()) return;
            const preservedTurns = options.preservedTurns || [];
            // Whatever model is already established survives a history fetch
            // that returns nothing: a brand-new conversation's `getEvents()` is
            // empty and would otherwise blank the model line the rotation event
            // just taught us.
            const preservedModel = currentModel;

            durableTranscriptAuthoritative = durableHistoryAvailable();
            // Startup only: publish a deliberate empty snapshot so a snapshot
            // left by a DIFFERENT Copilot session cannot linger on screen while
            // history loads. Rotation must not repeat it — it has already
            // discarded the shared snapshot for quarantine safety, so the
            // drawer is briefly empty regardless, and a second empty frame
            // would just be redundant churn before history lands.
            if (options.publishEmptyPlaceholder && preservedTurns.length === 0) {
                publishTranscript(true);
            }
            const durableStartup = durableTranscriptAuthoritative
                ? reconcileDurableHistory()
                : null;
            let historyLoaded = false;
            try {
                const history = await sdkHistoryWithTimeout();
                if (stale()) return;
                if (durableTranscriptAuthoritative) {
                    for (const event of history) {
                        if (!event || typeof event !== "object"
                                || typeof event.type !== "string") {
                            continue;
                        }
                        try {
                            applyPermissionEvent(event, false);
                            applyModelFromEvent(event);
                        } catch {}
                    }
                } else {
                    resetTranscriptReplayState([], preservedModel);
                    for (const event of history) {
                        replayHistoryEvent(event, true);
                    }
                }
                historyLoaded = true;
            } catch {
                if (stale()) return;
            }
            if (!durableTranscriptAuthoritative && !historyLoaded) {
                resetTranscriptReplayState(preservedTurns, preservedModel);
            }
            if (durableStartup) {
                try {
                    await durableStartup;
                } catch {
                    if (stale()) return;
                    if (!durableBaselineComplete) {
                        loseDurableAuthority();
                    }
                }
                if (stale()) return;
                if (!durableTranscriptAuthoritative && !historyLoaded) {
                    resetTranscriptReplayState(
                        preservedTurns,
                        preservedModel
                    );
                }
            }
            transcriptInitialized = true;
            for (const event of queuedTranscriptEvents) {
                if (durableTranscriptAuthoritative) {
                    applyPermissionEvent(event, false);
                    applyModelFromEvent(event);
                } else {
                    replayHistoryEvent(event, true);
                }
            }
            queuedTranscriptEvents.length = 0;
            publish();
            if (durableTranscriptAuthoritative) {
                scheduleDurableReconcile(0);
            } else {
                publishTranscript();
            }
        }

        // Drop every scrap of the previous conversation. Per-process resources
        // (response watcher, poll timer, gated event-interest handles, paths)
        // are deliberately untouched: they belong to the extension process, not
        // to the conversation, and the SDK contract does not require
        // re-registering interest when the conversation rotates.
        function resetConversationState(transitionAt) {
            activeSubagents.clear();
            pendingUserInputs.clear();
            inFlightUserInputResponses.clear();
            pendingElicitations.clear();
            inFlightElicitationResponses.clear();
            pendingPermissionRequestIds.clear();
            completedPermissionRequestIds.clear();

            foregroundTurnActive = false;
            scheduledTurnActive = false;
            currentTurnKind = null;
            lastIdleAborted = false;
            lastIdleTurnKind = null;
            foregroundTransitionAt = transitionAt;
            // `idleGeneration` stays monotonic on purpose: the host compares it
            // against a per-tab baseline with `>`, so rewinding it would make
            // the new conversation's first idle look like no idle at all.

            currentModel = null;
            availableModels = null;
            schedules = [];
            lastLiveQuestionAt = null;
            terminalDisconnectError = null;

            clearTimeout(transcriptPublishTimer);
            transcriptPublishTimer = null;
            clearTimeout(durableReconcileTimer);
            durableReconcileTimer = null;
            durableReconcileQueued = false;
            transcriptInitialized = false;
            queuedTranscriptEvents.length = 0;
            resetTranscriptReplayState([], null);

            durableTranscriptAuthoritative = false;
            durableHistoryIdentity = null;
            durableDisabledIdentity = null;
            durableHistoryOffset = 0;
            durablePending = Buffer.alloc(0);
            durableDroppingOversizedLine = false;
            durableBaselineComplete = false;
            durableFailureStreak = 0;
            durableFallbackTurns = [];
            durableFallbackModel = null;
            durableAskUser = null;
            durableAskUserScan = null;

            // Any allow-all answer still in flight belongs to the previous
            // conversation and must not be applied to the new one.
            allowAllUpdateGeneration += 1;
        }

        // The current Copilot conversation id according to a root
        // `session.start` / `session.resume` event. The SDK spells the id
        // differently across payload shapes, so read the event first and only
        // fall back to the (possibly already-rotated) live `session.sessionId`.
        function lifecycleSessionId(event) {
            if (!event || event.agentId) return null;
            if (event.type !== "session.start"
                    && event.type !== "session.resume") {
                return null;
            }
            return [event.data?.sessionId, event.sessionId, session.sessionId]
                .find((candidate) => typeof candidate === "string"
                    && sessionIdPattern.test(candidate)) ?? null;
        }

        // `/new` and `/resume` replace the CLI's conversation without restarting
        // this process. Adopt the new identity, drop everything that described
        // the old one, roll our owner marker forward, and reload the drawer from
        // the new conversation's history. `event` is the lifecycle event that
        // announced the change, or null when the rotation was recovered from the
        // live session object. Returns true when a rotation happened.
        function rotateCopilotSession(nextCopilotSessionId, transitionAt, event) {
            const previousCopilotSessionId = copilotSessionId;
            copilotSessionId = nextCopilotSessionId;
            validCopilotSessionId = true;
            ownedCopilotSessionIds.add(nextCopilotSessionId);
            conversationGeneration += 1;
            const generation = conversationGeneration;
            rotationConsumedEventId = typeof event?.id === "string"
                ? event.id
                : null;

            resetConversationState(transitionAt);
            rotateOwnerMarker(previousCopilotSessionId);
            if (ownsSharedFiles()) {
                // `rotateOwnerMarker` already discarded the snapshot under the
                // lock on the prior-self path. It bails when the marker was
                // absent or held by a dead/foreign owner we reclaimed here
                // instead — in that case the snapshot on disk still belongs to
                // the previous conversation while the marker now names the new
                // one, so discard it before anything can read the pair.
                discardRotatedTranscript();
                setScheduledTurnMarker(false);
                // Every handler re-validates `copilotSessionId` before acting,
                // so these files can never be applied to the wrong
                // conversation — but a remote client that answered the previous
                // conversation would otherwise see its response sit unresolved
                // for up to a full poll interval. Drop them now.
                removeFile(userInputResponsePath);
                removeFile(elicitationResponsePath);
                removeFile(setModelRequestPath);
            }
            if (event) applyModelFromEvent(event);
            // Republish the (now empty) per-conversation state immediately so
            // the host stops showing the previous conversation's subagents and
            // questions while history loads. Only the transcript waits for
            // history; this heartbeat must not.
            publish();
            bootstrapConversation(generation).catch(() => {});
            refreshSchedules();
            refreshModels();
            return true;
        }

        function maybeRotateCopilotSession(event) {
            const resolved = lifecycleSessionId(event);
            if (!resolved || resolved === copilotSessionId) return false;
            return rotateCopilotSession(
                resolved,
                normalizedTimestamp(event.timestamp),
                event
            );
        }

        // Safety net for a lifecycle event we never saw (dropped, or delivered
        // before our listeners attached): the live session object still knows
        // which conversation the CLI is on. Adopt it ONLY when it is a valid id
        // this process has never held — a `session.sessionId` that lags behind
        // must never rotate us backward onto a conversation we already left.
        function reconcileSessionIdentityFromSdk() {
            const live = session.sessionId;
            if (typeof live !== "string"
                    || !sessionIdPattern.test(live)
                    || live === copilotSessionId
                    || ownedCopilotSessionIds.has(live)) {
                return false;
            }
            return rotateCopilotSession(live, new Date().toISOString(), null);
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
            const generation = conversationGeneration;
            if (modelsRefreshGeneration === generation) return;
            modelsRefreshGeneration = generation;
            try {
                const result = await session.rpc.model.list();
                if (generation !== conversationGeneration) return;
                const normalized = normalizeAvailableModels(
                    result && Array.isArray(result.list) ? result.list : null
                );
                // Keep the last good catalog if a refresh returns nothing usable.
                if (normalized) {
                    availableModels = normalized;
                    publish();
                }
            } catch {
            } finally {
                if (modelsRefreshGeneration === generation) {
                    modelsRefreshGeneration = null;
                }
            }
        }

        // Consume a host-written model switch request: validate it targets THIS
        // Copilot session, then switch over RPC. `session.model_change` refreshes
        // the current-model line; we drop the request file whether it succeeds or
        // fails so the client can issue a fresh one (the model is unchanged on
        // failure, so retrying is safe).
        async function processSetModelRequest() {
            const generation = conversationGeneration;
            if (!ownsSharedFiles()
                    || setModelRequestGeneration === generation) return;
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
                    || request.copilotSessionId !== copilotSessionId) {
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
            setModelRequestGeneration = generation;
            try {
                await session.rpc.model.switchTo(params);
                removeFile(setModelRequestPath);
                if (generation !== conversationGeneration) return;
                // Quotas / preferred default can shift after a switch.
                await refreshModels();
            } catch {
                removeFile(setModelRequestPath);
            } finally {
                if (setModelRequestGeneration === generation) {
                    setModelRequestGeneration = null;
                }
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

        // The SDK's dispatch order between the generic listener and these named
        // ones is not contractual, so rotate from whichever fires first;
        // `maybeRotateCopilotSession` is a no-op once the id already matches.
        function handleSessionLifecycleEvent(event) {
            if (maybeRotateCopilotSession(event)) return;
            applyModelFromEvent(event);
        }

        session.on("session.start", handleSessionLifecycleEvent);
        session.on("session.resume", handleSessionLifecycleEvent);
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
            clearTimeout(durableReconcileTimer);
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
            const cleared = observeLiveRootQuestion(event);
            const entry = userInputEntry(event);
            // A rejected entry is never exposed remotely; the terminal keeps the
            // exact prompt so nothing is lost.
            if (!entry) {
                if (cleared) publish();
                return;
            }
            pendingUserInputs.set(entry.requestId, entry);
            boundPendingUserInputs();
            publish();
        });

        session.on("user_input.completed", (event) => {
            const requestId = event.data?.requestId;
            const cleared = observeLiveRootQuestion(event);
            if ((typeof requestId === "string"
                    && pendingUserInputs.delete(requestId)) || cleared) {
                publish();
            }
        });

        session.on("elicitation.requested", (event) => {
            const cleared = observeLiveRootQuestion(event);
            const entry = elicitationEntry(event);
            if (!entry) {
                if (cleared) publish();
                return;
            }
            pendingElicitations.set(entry.requestId, entry);
            boundPendingElicitations();
            publish();
        });

        session.on("elicitation.completed", (event) => {
            const requestId = event.data?.requestId;
            const cleared = observeLiveRootQuestion(event);
            if ((typeof requestId === "string"
                    && pendingElicitations.delete(requestId)) || cleared) {
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

        const startupGeneration = conversationGeneration;
        await refreshAllowAll();
        // A lifecycle event can already have rotated the conversation while we
        // awaited above; that rotation owns the bootstrap from here on, and
        // restoring the previous snapshot into `transcriptTurns` would pollute
        // the conversation it just cleared.
        if (startupGeneration === conversationGeneration) {
            // Keep this Copilot session's last good drawer visible while history
            // is fetched, but clear a snapshot left by a different Copilot
            // session.
            const preservedTranscriptTurns = restoreMatchingTranscript()
                ? [...transcriptTurns]
                : [];
            await bootstrapConversation(startupGeneration, {
                preservedTurns: preservedTranscriptTurns,
                publishEmptyPlaceholder: true,
            });
        }

        refreshSchedules();
        refreshModels();

        processUserInputResponse();
        processElicitationResponse();
        processSetModelRequest();

        timer = setInterval(() => {
            refreshForegroundAuthoritySoon();
            // Cheap safety net first: if the identity moved without a lifecycle
            // event reaching us, everything below must run against the new
            // conversation, not the one we just left.
            if (reconcileSessionIdentityFromSdk()) return;
            refreshSchedules();
            refreshModels();
            processUserInputResponse();
            processElicitationResponse();
            processSetModelRequest();
            scheduleDurableReconcile(0);
        }, DURABLE_RECONCILE_POLL_MS);
        foregroundHandlingReady = true;
        activateForegroundSharedFiles();
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
