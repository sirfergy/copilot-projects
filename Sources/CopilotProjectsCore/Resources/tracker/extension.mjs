import { execFileSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { isDeepStrictEqual } from "node:util";
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
    const workflowKinds = [
        "session-send", "session-abort", "set-session-budget", "answer-session-budget",
    ];
    const workflowPaths = new Map(workflowKinds.map((kind) => [
        kind, join(sessionsDir, `${appSessionId}.${kind}.json`),
    ]));
    const closeSessionRequestPath = join(
        sessionsDir, `${appSessionId}.close-session-request`
    );
    const closeSessionRequestName = `${appSessionId}.close-session-request`;
    const activeSubagents = new Map();
    // All outstanding structured questions (root and subagent), keyed by
    // requestId. Rebuilt from live events and the runtime's pending snapshot,
    // never resurrected from disk.
    const pendingUserInputs = new Map();
    const inFlightUserInputResponses = new Set();
    // Outstanding elicitations (schema-form / url questions), keyed by
    // requestId. Same lifecycle as pendingUserInputs.
    const pendingElicitations = new Map();
    const recoveredQuestionToolCallIds = new Set();
    const completedQuestionRequests = new Set();
    let pendingQuestionRecovery = null;
    let questionEventStream = null;
    const inFlightElicitationResponses = new Set();
    const operationReceipts = new Map();
    const activeOperationKeys = new Set();
    // Passive observation only: NEVER register interest / call setRequired for
    // permission events, or this extension would take prompt ownership away
    // from the CLI's terminal UI.
    const pendingPermissionRequests = new Map();
    const completedPermissionRequests = new Map();
    const inputCompletions = new Map();
    let terminalDisconnectError = null;
    let foregroundTurnActive = false;
    let currentIntent = null;
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
    let foregroundTransitionAt = null;
    let runtimeActivity = {
        processing: null, observedAtMilliseconds: null,
        idleAtMilliseconds: null, error: "pending",
    };
    let runtimeActivityUnsupported = false;
    let runtimeActivityRevision = 0;
    let runtimeActivityRefresh = null;
    let runtimeIdleAtMilliseconds = null;
    let sessionIdleAtMilliseconds = null;
    let shuttingDown = false;
    let scheduledTurnActive = false;
    let currentTurnKind = null;
    let idleGeneration = 0;
    let closeActivityIdleBaseline = idleGeneration;
    let closeActivityState = "pending";
    let closeActivityPendingSince = Date.now();
    let closeActivityRetryTimer = null;
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
    let closeSessionRequestInFlight = false;
    let closeSessionExitQueued = false;
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
    let transcriptDeltaPublishTimer = null;
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
    const trackerInstanceId = randomUUID();
    let conversationEpoch = `${trackerInstanceId}:${conversationGeneration}`;
    let workflowRuntime = null;
    let workflowRefresh = null;
    let workflowRefreshAt = 0;
    let workflowObservation = null;
    let workflowContext = null;
    let pendingBudgetRequest = null;
    const pendingBudgetIds = new Set();
    const liveMessageStreams = new Map();
    let workflowLiveTurnId = null;
    const unavailableWorkflowActions = new Set();
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
    const PENDING_QUESTIONS_TIMEOUT_MS = 2_000;
    const QUESTION_EVENT_TYPES = [
        "user_input.requested", "user_input.completed",
        "elicitation.requested", "elicitation.completed",
    ];
    const MAX_QUESTION_COMPLETIONS = 4_096;
    const QUESTION_EVENT_PAGE_SIZE = 100;
    const MAX_QUESTION_EVENT_PAGES = 10;
    const DURABLE_REPLAY_TIMEOUT_MS = 5_000;
    const DURABLE_RECONCILE_DEBOUNCE_MS = 200;
    const DURABLE_RECONCILE_POLL_MS = 5_000;
    const TRANSCRIPT_PUBLISH_THROTTLE_MS = 400;
    const CLOSE_ABORT_TIMEOUT_MS = 3_000;
    const CLOSE_IDLE_TIMEOUT_MS = 5_000;
    const CLOSE_ENQUEUE_TIMEOUT_MS = 3_000;
    const CLOSE_ACTIVITY_PENDING_TIMEOUT_MS = 1_000;

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
    const OPERATION_RECEIPT_VERSION = 1;
    const MAX_ACCEPTED_OPERATION_RECEIPTS = 64;
    const MAX_TERMINAL_OPERATION_RECEIPTS = 64;
    const OPERATION_KINDS = new Set([
        "answer-user-input",
        "answer-elicitation",
        "set-model",
        ...workflowKinds,
    ]);

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

    function promiseWithTimeout(promise, timeoutMs, message) {
        let timeout = null;
        const timeoutPromise = new Promise((_, reject) => {
            timeout = setTimeout(() => reject(new Error(message)), timeoutMs);
            timeout.unref?.();
        });
        return Promise.race([promise, timeoutPromise])
            .finally(() => {
                if (timeout) clearTimeout(timeout);
            });
    }

    async function waitForSessionIdle(afterGeneration) {
        const deadline = Date.now() + CLOSE_IDLE_TIMEOUT_MS;
        while (idleGeneration <= afterGeneration && Date.now() < deadline) {
            await new Promise((resolve) => setTimeout(resolve, 25));
        }
        return idleGeneration > afterGeneration;
    }

    function latestRootTurnKind(events) {
        let turnKind = null;
        for (const event of events) {
            if (!event || typeof event !== "object" || event.agentId) continue;
            if (event.type === "user.message") {
                turnKind = classifyUserMessage(event) ?? turnKind;
            } else if (event.type === "assistant.turn_start") {
                turnKind ??= "foreground";
            } else if (event.type === "session.idle"
                    || event.type === "session.start"
                    || event.type === "session.resume"
                    || event.type === "session.shutdown") {
                turnKind = null;
            }
        }
        return turnKind;
    }

    function clearCloseActivityRetry() {
        if (closeActivityRetryTimer === null) return;
        clearTimeout(closeActivityRetryTimer);
        closeActivityRetryTimer = null;
    }

    function retryCloseAfterActivityTimeout() {
        if (closeActivityRetryTimer !== null) return;
        const generation = conversationGeneration;
        const elapsed = Date.now() - closeActivityPendingSince;
        closeActivityRetryTimer = setTimeout(() => {
            closeActivityRetryTimer = null;
            if (generation === conversationGeneration) {
                processCloseSessionRequest();
            }
        }, Math.max(0, CLOSE_ACTIVITY_PENDING_TIMEOUT_MS - elapsed));
        closeActivityRetryTimer.unref?.();
    }

    async function processCloseSessionRequest() {
        if (closeSessionRequestInFlight
                || closeSessionExitQueued
                || !ownsSharedFiles()
                || !fileExistsSync(closeSessionRequestPath)) {
            return;
        }
        const activityActive = currentTurnKind !== null
            || foregroundTurnActive
            || scheduledTurnActive;
        let activityState = closeActivityState;
        if (!activityActive && activityState === "pending") {
            if (Date.now() - closeActivityPendingSince
                    < CLOSE_ACTIVITY_PENDING_TIMEOUT_MS) {
                retryCloseAfterActivityTimeout();
                return;
            }
            closeActivityState = "unknown";
            activityState = "unknown";
        }
        clearCloseActivityRetry();
        const generation = conversationGeneration;
        closeSessionRequestInFlight = true;
        try {
            const idleGenerationBeforeAbort = idleGeneration;
            if (activityActive || activityState === "unknown") {
                try {
                    await promiseWithTimeout(
                        session.abort(),
                        CLOSE_ABORT_TIMEOUT_MS,
                        "session abort timed out"
                    );
                } catch (error) {
                    if (activityState !== "unknown") throw error;
                }
                const becameIdle = await waitForSessionIdle(idleGenerationBeforeAbort);
                if (generation !== conversationGeneration || !ownsSharedFiles()) return;
                if (!becameIdle && activityState !== "unknown") {
                    throw new Error("session did not become idle after abort");
                }
            }
            const result = await promiseWithTimeout(
                session.rpc.commands.enqueue({command: "/exit print"}),
                CLOSE_ENQUEUE_TIMEOUT_MS,
                "exit command enqueue timed out"
            );
            if (generation !== conversationGeneration || !ownsSharedFiles()) return;
            if (result?.queued !== true) {
                throw new Error("exit command was not queued");
            }
            // The app removes the request only after this tracker process exits
            // (or after its bounded force-cleanup fallback). Keeping it here lets
            // a failed attempt retry from the periodic poll.
            closeSessionExitQueued = true;
        } catch (error) {
            console.error(
                "[copilot-projects] failed to request graceful CLI exit:",
                error
            );
        } finally {
            if (generation === conversationGeneration) {
                closeSessionRequestInFlight = false;
            }
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
        refreshRuntimeActivity(true);
    }

    async function refreshForegroundAuthority() {
        const generation = conversationGeneration;
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
            if (generation !== conversationGeneration) {
                return;
            }
            const wasActive = foregroundSessionActive;
            foregroundSessionActive = response?.sessionId === copilotSessionId;
            // Confirming polls are not new foreground transitions. A stale
            // connection must not outbid the conversation that replaced it
            // every time its heartbeat runs.
            if (foregroundSessionActive && !wasActive) {
                foregroundObservationStartedAt = observedAt;
            }
            shouldActivate = foregroundHandlingReady
                && foregroundSessionActive
                && (!wasActive || !isRecordedOwner());
        } catch {
            // Older SDK servers have no foreground query. The existing
            // owner election remains authoritative in that compatibility mode.
        } finally {
            if (timeout) clearTimeout(timeout);
            if (generation !== conversationGeneration) {
                refreshForegroundAuthoritySoon();
            }
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

    function operationExecutionKey(epoch, operationId) {
        return `${epoch}\u0000${operationId}`;
    }

    function validOperationToken(value, maximumBytes) {
        return typeof value === "string"
            && value.length > 0
            && Buffer.byteLength(value) <= maximumBytes
            && /^[\x21-\x7e]+$/.test(value);
    }

    function operationContextCurrent(context) {
        return context.generation === conversationGeneration
            && context.conversationEpoch === conversationEpoch
            && context.copilotSessionId === copilotSessionId;
    }

    function operationAuthorityCurrent(context) {
        return operationContextCurrent(context) && ownsSharedFiles();
    }

    function removeCapturedHandoff(path, encoded, context = null) {
        if (context && !operationAuthorityCurrent(context)) return false;
        try {
            if (readFileSync(path, "utf8") !== encoded) return false;
            rmSync(path, { force: true });
            return true;
        } catch {
            return false;
        }
    }

    function pruneOperationReceipts() {
        // A mobile client may miss the outcome while offline. Retain bounded
        // confirmation and replay history until eviction or conversation reset.
        const terminal = [...operationReceipts.values()]
            .filter((receipt) => receipt.state !== "accepted");
        terminal.sort(
            (left, right) => left.updatedAtMilliseconds - right.updatedAtMilliseconds
        );
        while (terminal.length > MAX_TERMINAL_OPERATION_RECEIPTS) {
            operationReceipts.delete(terminal.shift().operationId);
        }
    }

    function operationReceiptSnapshot() {
        pruneOperationReceipts();
        return [...operationReceipts.values()].map((receipt) => ({
            operationId: receipt.operationId,
            conversationEpoch: receipt.conversationEpoch,
            kind: receipt.kind,
            state: receipt.state,
            updatedAtMilliseconds: receipt.updatedAtMilliseconds,
            ...(receipt.errorCode ? { errorCode: receipt.errorCode } : {}),
            payloadFingerprint: receipt.payloadFingerprint,
        }));
    }

    function parseOperationMetadata(response, expectedKind) {
        const fields = [
            response.operationId,
            response.conversationEpoch,
            response.kind,
            response.payloadFingerprint,
        ];
        if (fields.every((value) => value === undefined)) {
            return { mode: "legacy" };
        }
        if (fields.some((value) => value === undefined)
                || !validOperationToken(response.operationId, 128)
                || !validOperationToken(response.conversationEpoch, 512)
                || !OPERATION_KINDS.has(response.kind)
                || !/^[0-9a-f]{64}$/.test(response.payloadFingerprint)) {
            return { mode: "invalid" };
        }
        const context = {
            generation: conversationGeneration,
            copilotSessionId,
            conversationEpoch: response.conversationEpoch,
            operationId: response.operationId,
            kind: response.kind,
            payloadFingerprint: response.payloadFingerprint,
        };
        if (response.conversationEpoch !== conversationEpoch
                || response.copilotSessionId !== copilotSessionId) {
            return { mode: "stale", context };
        }
        pruneOperationReceipts();
        const existing = operationReceipts.get(response.operationId);
        if (existing) {
            const same = existing.conversationEpoch === response.conversationEpoch
                && existing.kind === response.kind
                && existing.payloadFingerprint === response.payloadFingerprint;
            if (!same || response.kind !== expectedKind) {
                return { mode: "conflict", context };
            }
            if (existing.state !== "accepted") {
                return { mode: "terminal", context };
            }
            const key = operationExecutionKey(
                response.conversationEpoch,
                response.operationId
            );
            return {
                // An accepted receipt without this process's active execution
                // key may already have reached the SDK before ownership was
                // lost. Re-invoking would risk applying it twice.
                mode: activeOperationKeys.has(key) ? "inflight" : "indeterminate",
                context,
            };
        }
        if (response.kind !== expectedKind) return { mode: "invalid", context };
        const acceptedCount = [...operationReceipts.values()]
            .filter((receipt) => receipt.state === "accepted").length;
        if (acceptedCount >= MAX_ACCEPTED_OPERATION_RECEIPTS) {
            return { mode: "busy", context };
        }
        return { mode: "new", context };
    }

    function publishAcceptedReceipt(context) {
        const receipt = {
            operationId: context.operationId,
            conversationEpoch: context.conversationEpoch,
            kind: context.kind,
            state: "accepted",
            updatedAtMilliseconds: Date.now(),
            payloadFingerprint: context.payloadFingerprint,
        };
        operationReceipts.set(context.operationId, receipt);
        if (publish()) return true;
        if (operationReceipts.get(context.operationId) === receipt) {
            operationReceipts.delete(context.operationId);
        }
        return false;
    }

    function publishTerminalReceipt(context, state, errorCode = null) {
        if (!operationAuthorityCurrent(context)) return false;
        const previous = operationReceipts.get(context.operationId);
        if (!previous
                || previous.conversationEpoch !== context.conversationEpoch
                || previous.kind !== context.kind
                || previous.payloadFingerprint !== context.payloadFingerprint) {
            return false;
        }
        operationReceipts.set(context.operationId, {
            operationId: previous.operationId,
            conversationEpoch: previous.conversationEpoch,
            kind: previous.kind,
            state,
            updatedAtMilliseconds: Date.now(),
            ...(errorCode ? { errorCode } : {}),
            payloadFingerprint: previous.payloadFingerprint,
        });
        pruneOperationReceipts();
        return publish();
    }

    function rpcReceiptOutcome(result) {
        if (result?.success === true) {
            return { state: "applied", errorCode: null };
        }
        if (result?.success === false) {
            return { state: "rejected", errorCode: "rpc-rejected" };
        }
        return { state: "indeterminate", errorCode: "rpc-indeterminate" };
    }

    function modelSwitchReceiptOutcome(result, requestedModelId) {
        // switchTo returns model metadata, not the boolean success used by UI
        // answers. Even status "applied" can describe a deferred queue entry.
        if (result?.deferred === undefined || result.deferred === false) {
            switch (result?.status) {
            case "cancelled":
            case "confirmation_required":
                return { state: "rejected", errorCode: "rpc-rejected" };
            case undefined: // Older runtimes returned only modelId and deferred.
            case "applied":
            case "unchanged":
                if (result?.modelId === requestedModelId) {
                    return { state: "applied", errorCode: null };
                }
            }
        }
        return { state: "indeterminate", errorCode: "rpc-indeterminate" };
    }

    function publishRejectedPreflight(context, errorCode, path, encoded) {
        if (!operationAuthorityCurrent(context)) return false;
        if (!operationReceipts.has(context.operationId)) {
            operationReceipts.set(context.operationId, {
                operationId: context.operationId,
                conversationEpoch: context.conversationEpoch,
                kind: context.kind,
                state: "rejected",
                updatedAtMilliseconds: Date.now(),
                errorCode,
                payloadFingerprint: context.payloadFingerprint,
            });
            pruneOperationReceipts();
            const published = publish();
            if (published) removeCapturedHandoff(path, encoded, context);
            return published;
        }
        const published = publishTerminalReceipt(
            context,
            "rejected",
            errorCode
        );
        if (published) removeCapturedHandoff(path, encoded, context);
        return published;
    }

    function invalidateRuntimeActivity() {
        runtimeActivityRevision += 1;
        runtimeIdleAtMilliseconds = null;
        sessionIdleAtMilliseconds = null;
        if (!runtimeActivityUnsupported) {
            runtimeActivity = {
                processing: null, observedAtMilliseconds: null,
                idleAtMilliseconds: null, error: "pending",
            };
        }
    }

    function recordInputCompletion(owner, event) {
        if (!sessionIdPattern.test(owner || "")) return;
        const timestamp = Date.parse(normalizedTimestamp(event.timestamp));
        if (!Number.isFinite(timestamp)) return;
        const key = owner.toLowerCase();
        const previous = inputCompletions.get(key);
        inputCompletions.delete(key);
        inputCompletions.set(key, Math.max(previous ?? timestamp, timestamp));
        while (inputCompletions.size > 128) {
            inputCompletions.delete(inputCompletions.keys().next().value);
        }
        // Child activity does not invalidate a coordinator observation. Only a
        // matching input wait needs a fresh read after this completion.
        let record;
        try {
            record = JSON.parse(readFileSync(
                join(sessionsDir, `${appSessionId}.status-record.json`), "utf8"
            ));
        } catch (error) {
            if (error?.code !== "ENOENT") {
                console.error("[copilot-projects] could not read input wait context:", error);
            }
            return;
        }
        if (record?.status === "waiting"
            && typeof record.inputWait?.senderSessionId === "string"
            && typeof record.inputWait?.rootSessionId === "string"
            && record.inputWait.senderSessionId.toLowerCase() === key
            && record.inputWait.rootSessionId.toLowerCase() === copilotSessionId.toLowerCase()
            && record.inputWait?.conversationEpoch === conversationEpoch
            && Number.isSafeInteger(record.statusTimestamp)
            && record.statusTimestamp <= timestamp) {
            runtimeActivityRevision += 1;
            refreshRuntimeActivity(true);
        }
    }

    async function refreshRuntimeActivity(forcePublish = false) {
        if (shuttingDown || runtimeActivityUnsupported
            || !validCopilotSessionId || !ownsSharedFiles()) return;
        if (runtimeActivityRefresh?.generation === conversationGeneration) {
            runtimeActivityRefresh.forcePublish ||= forcePublish;
            return;
        }
        const token = {
            generation: conversationGeneration,
            revision: runtimeActivityRevision,
            sessionId: copilotSessionId,
            epoch: conversationEpoch,
            forcePublish,
        };
        runtimeActivityRefresh = token;
        const observedAtMilliseconds = Date.now();
        let timeout = null;
        const current = () => !shuttingDown
            && token.generation === conversationGeneration
            && token.revision === runtimeActivityRevision
            && token.sessionId === copilotSessionId
            && token.epoch === conversationEpoch
            && ownsSharedFiles();
        try {
            const params = { sessionId: token.sessionId };
            const values = await Promise.race([
                Promise.all([
                    session.connection.sendRequest("session.metadata.snapshot", params),
                    session.connection.sendRequest("session.metadata.isProcessing", params),
                ]),
                new Promise((_, reject) => {
                    timeout = setTimeout(
                        () => reject(new Error("runtime activity query timed out")),
                        2_000
                    );
                }),
            ]);
            if (!current()) return;
            const [metadata, processing] = values;
            if (metadata?.sessionId !== token.sessionId
                || typeof metadata?.isRemote !== "boolean") {
                throw new Error("invalid runtime session metadata");
            }
            if (metadata.isRemote) {
                const changed = runtimeActivity?.error !== "remote";
                if (changed) {
                    console.error("[copilot-projects] remote session uses legacy activity signals");
                }
                runtimeActivity = {
                    processing: null, observedAtMilliseconds,
                    idleAtMilliseconds: null, error: "remote",
                };
                if (changed || token.forcePublish) publish();
                return;
            }
            if (typeof processing?.processing !== "boolean") {
                throw new Error("invalid runtime activity response");
            }
            const changed = runtimeActivity?.processing !== processing.processing
                || runtimeActivity?.error != null;
            runtimeActivity = {
                processing: processing.processing,
                observedAtMilliseconds,
                idleAtMilliseconds: runtimeIdleAtMilliseconds,
                error: null,
            };
            if (workflowObservation && workflowRuntime) {
                workflowObservation.observedAtMilliseconds = observedAtMilliseconds;
                workflowObservation.limitsKnown = Object.hasOwn(metadata, "sessionLimits")
                    && (metadata.sessionLimits === null || finiteNonnegative(metadata.sessionLimits?.maxAiCredits));
                workflowObservation.maxAiCredits = workflowObservation.limitsKnown
                    ? metadata.sessionLimits?.maxAiCredits ?? null : null;
            }
            // Unchanged observations ride the next heartbeat; actual transitions
            // and input completions publish immediately.
            if (changed || token.forcePublish) publish();
        } catch (error) {
            if (!current()) return;
            if (error?.code === -32601) {
                runtimeActivityUnsupported = true;
                runtimeActivity = {
                    processing: null, observedAtMilliseconds,
                    idleAtMilliseconds: null, error: "unsupported",
                };
                console.error("[copilot-projects] runtime activity API unavailable; using legacy signals");
                publish();
                return;
            }
            const message = String(error);
            const changed = runtimeActivity?.error !== message;
            if (changed) {
                console.error("[copilot-projects] runtime activity query failed:", error);
            }
            runtimeActivity = {
                processing: null,
                observedAtMilliseconds, idleAtMilliseconds: null, error: message,
            };
            if (changed || token.forcePublish) publish(error);
        } finally {
            if (timeout) clearTimeout(timeout);
            if (runtimeActivityRefresh === token) {
                runtimeActivityRefresh = null;
                if (!shuttingDown && token.generation === conversationGeneration
                    && token.revision !== runtimeActivityRevision) {
                    queueMicrotask(() => refreshRuntimeActivity(true));
                }
            }
        }
    }

    function workflowContextToken() {
        return { generation: conversationGeneration, copilotSessionId, conversationEpoch };
    }

    function workflowRPC(method, params, context) {
        if (method === "status.get") return session.connection.sendRequest(method, {});
        return session.connection.sendRequest(method, {
            ...params, sessionId: context.copilotSessionId,
        });
    }

    async function workflowRead(method, params, context) {
        let timeout;
        try {
            return await Promise.race([
                workflowRPC(method, params, context),
                new Promise((_, reject) => {
                    timeout = setTimeout(() => reject(new Error("workflow-read-timeout")), 3_000);
                }),
            ]);
        } finally {
            clearTimeout(timeout);
        }
    }

    function finiteNonnegative(value) {
        return typeof value === "number" && Number.isFinite(value) && value >= 0;
    }

    function workflowHasPendingInput() {
        return pendingUserInputs.size > 0 || pendingElicitations.size > 0
            || pendingPermissionRequests.size > 0 || durableAskUser !== null
            || pendingBudgetIds.size > 0;
    }

    function workflowSnapshot() {
        const observation = workflowObservation;
        const fresh = observation && runtimeActivity?.error == null
            && !terminalDisconnectError && Date.now() - observation.observedAtMilliseconds <= 15_000;
        const capabilities = fresh ? observation.capabilities.filter(
            (kind) => !unavailableWorkflowActions.has(kind)
        ) : [];
        return {
            version: 1,
            observedAtMilliseconds: observation?.observedAtMilliseconds ?? 0,
            capabilities,
            sendReady: fresh === true && !workflowHasPendingInput(),
            imageAttachments: fresh ? availableModels?.find(
                (model) => model.id === currentModel?.name
            )?.imageAttachments ?? null : null,
            legacyPromptFallback: workflowRuntime === false || runtimeActivityUnsupported
                || observation?.legacyPromptFallback === true
                || unavailableWorkflowActions.has("session-send"),
            totalAiCredits: observation?.totalAiCredits ?? null,
            contextTokens: workflowContext?.currentTokens ?? null,
            contextTokenLimit: workflowContext?.tokenLimit ?? null,
            limitsKnown: observation?.limitsKnown === true,
            maxAiCredits: observation?.maxAiCredits ?? null,
            budgetRequest: pendingBudgetRequest,
            agents: [...activeSubagents.values()].slice(0, 64).map(({ id, name, description }) => ({
                id: String(id), name, description,
            })),
            schedules: schedules.slice(0, 32).map((entry) =>
                boundedMetadataText(entry.description || entry.prompt || entry.id || "Scheduled work")
            ),
            error: observation ? observation.error : "Runtime information is not available yet",
        };
    }

    async function refreshWorkflow(force = false) {
        if (shuttingDown || !ownsSharedFiles()
                || runtimeActivityUnsupported
                || workflowRefresh?.generation === conversationGeneration
                || (!force && workflowObservation && Date.now() - workflowRefreshAt < 30_000)) return;
        const context = workflowContextToken();
        workflowRefresh = context;
        const observedAtMilliseconds = Date.now();
        workflowRefreshAt = observedAtMilliseconds;
        try {
            if (workflowRuntime === null) {
                const status = await workflowRead("status.get", {}, context);
                const version = /^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$/.exec(status?.version || "");
                workflowRuntime = status?.protocolVersion === 3 && version !== null
                    && Number(version[1]) === 1
                    && (Number(version[2]) > 0 || Number(version[3]) >= 84);
            }
            if (!workflowRuntime) throw new Error("unsupported-runtime");
            const metadata = await workflowRead("session.metadata.snapshot", {}, context);
            if (metadata?.sessionId !== context.copilotSessionId || typeof metadata.isRemote !== "boolean") {
                throw new Error("unsupported-session");
            }
            if (metadata.isRemote) {
                throw Object.assign(new Error("remote-session"), { legacyPromptFallback: true });
            }
            const limitsKnown = Object.hasOwn(metadata, "sessionLimits")
                && (metadata.sessionLimits === null
                    || finiteNonnegative(metadata.sessionLimits?.maxAiCredits));
            let totalAiCredits = null;
            let usageError = null;
            try {
                const metrics = await workflowRead("session.usage.getMetrics", {}, context);
                if (finiteNonnegative(metrics?.totalNanoAiu)) {
                    totalAiCredits = metrics.totalNanoAiu / 1e9;
                } else {
                    usageError = "Session credit usage is unavailable";
                }
            } catch (error) {
                usageError = "Session credit usage is unavailable";
                console.error("[copilot-projects] workflow usage query failed:", error);
            }
            if (!operationAuthorityCurrent(context)) return;
            workflowObservation = {
                observedAtMilliseconds,
                capabilities: [
                    "session-send", "session-abort", "answer-session-budget", "image-attachments-v1",
                    ...(limitsKnown ? ["set-session-budget"] : []),
                ],
                totalAiCredits, limitsKnown,
                maxAiCredits: metadata.sessionLimits?.maxAiCredits ?? null,
                error: usageError,
            };
            publish();
        } catch (error) {
            if (!operationAuthorityCurrent(context)) return;
            workflowObservation = {
                observedAtMilliseconds, capabilities: [], limitsKnown: false,
                legacyPromptFallback: error?.legacyPromptFallback === true || error?.code === -32601,
                error: "Native workflows require a supported local Copilot runtime",
            };
            console.error("[copilot-projects] workflow metadata query failed:", error);
            publish();
        } finally {
            if (workflowRefresh === context) workflowRefresh = null;
        }
    }

    function validWorkflowAction(action, kind) {
        if (!action || action.kind !== kind) return false;
        if (action.attachmentIds != null && (kind !== "session-send"
                || !Array.isArray(action.attachmentIds)
                || action.attachmentIds.length < 1 || action.attachmentIds.length > 4
                || new Set(action.attachmentIds).size !== action.attachmentIds.length
                || !action.attachmentIds.every((id) =>
                    typeof id === "string"
                    && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)))) {
            return false;
        }
        const absent = (...keys) => keys.every((key) => action[key] == null);
        switch (kind) {
        case "session-send":
            return typeof action.prompt === "string" && action.prompt.trim().length > 0
                && Buffer.byteLength(action.prompt) <= 8_192
                && ["enqueue", "immediate"].includes(action.mode)
                && absent("maxAiCredits", "requestId", "additionalAiCredits");
        case "session-abort":
            return absent("prompt", "mode", "maxAiCredits", "requestId", "additionalAiCredits");
        case "set-session-budget":
            return absent("prompt", "mode", "requestId", "additionalAiCredits")
                && (action.maxAiCredits == null
                    || (finiteNonnegative(action.maxAiCredits) && action.maxAiCredits >= 30));
        case "answer-session-budget":
            return absent("prompt", "mode", "maxAiCredits")
                && typeof action.requestId === "string" && action.requestId.length > 0
                && Buffer.byteLength(action.requestId) <= 200
                && (action.additionalAiCredits == null
                    || (finiteNonnegative(action.additionalAiCredits) && action.additionalAiCredits > 0));
        default:
            return false;
        }
    }

    function imageCapabilities(entry) {
        if (entry?.capabilities?.supports?.vision !== true) return null;
        const vision = entry.capabilities.limits?.vision;
        const count = pickKey(vision, "max_prompt_images", "maxPromptImages");
        const bytes = pickKey(vision, "max_prompt_image_size", "maxPromptImageSize");
        const types = pickKey(vision, "supported_media_types", "supportedMediaTypes");
        if (!Number.isSafeInteger(count) || count < 1
                || !Number.isSafeInteger(bytes) || bytes < 1 || !Array.isArray(types)) return null;
        const mimeTypes = ["image/png", "image/jpeg"].filter((type) => types.includes(type));
        return mimeTypes.length ? {
            maxImages: Math.min(4, count), maxBytes: Math.min(2 * 1024 * 1024, bytes), mimeTypes,
        } : null;
    }

    async function loadImageAttachments(action, context) {
        if (!action.attachmentIds) return undefined;
        // Read-only preflight runs before accepting the operation. A missing
        // image or unsupported model rejects the WHOLE message, never just its images.
        const current = await workflowRead("session.model.getCurrent", {}, context);
        const catalog = await workflowRead("session.model.list", {}, context);
        const limits = imageCapabilities(catalog?.list?.find((model) => model.id === current?.modelId));
        if (!limits || action.attachmentIds.length > limits.maxImages) {
            throw new Error("The selected model does not support these screenshots");
        }
        const root = join(sessionsDir, "attachments-v1");
        if (!lstatSync(root).isDirectory() || lstatSync(root).isSymbolicLink()) {
            throw new Error("Invalid screenshot store");
        }
        const readBounded = (path, max) => {
            const stat = lstatSync(path);
            if (!stat.isFile() || stat.size < 1 || stat.size > max) throw new Error("Invalid screenshot file");
            const bytes = readFileSync(path);
            if (bytes.length > max) throw new Error("Screenshot is too large");
            return bytes;
        };
        const attachments = action.attachmentIds.map((id) => {
            const record = JSON.parse(readBounded(join(root, `${id}.json`), 4096));
            const metadata = record.attachment;
            if (metadata?.id !== id || metadata.sessionId !== appSessionId
                    || metadata.conversationEpoch !== context.conversationEpoch
                    || !Number.isSafeInteger(metadata.expiresAtMilliseconds)
                    || metadata.expiresAtMilliseconds <= Date.now()
                    || !limits.mimeTypes.includes(metadata.mimeType)
                    || !Number.isSafeInteger(metadata.byteCount)
                    || metadata.byteCount < 1 || metadata.byteCount > limits.maxBytes) {
                throw new Error("Screenshot is expired or belongs to another conversation");
            }
            const bytes = readBounded(join(root, `${id}.image`), limits.maxBytes);
            if (bytes.length !== metadata.byteCount
                    || createHash("sha256").update(bytes).digest("hex") !== record.sha256) {
                throw new Error("Screenshot bytes changed");
            }
            return {
                type: "blob", mimeType: metadata.mimeType,
                displayName: metadata.mimeType === "image/png" ? "Screenshot.png" : "Screenshot.jpg",
                data: bytes.toString("base64"),
            };
        });
        if (!operationAuthorityCurrent(context)) throw new Error("Conversation changed during screenshot preflight");
        return attachments;
    }

    async function invokeWorkflowAction(action, context, attachments) {
        switch (action.kind) {
        case "session-send": {
            const result = await workflowRPC("session.send", {
                prompt: action.prompt, mode: action.mode,
                ...(attachments ? { attachments } : {}),
            }, context);
            return typeof result?.messageId === "string" && result.messageId.length > 0
                ? { state: "applied" } : { state: "indeterminate", errorCode: "rpc-indeterminate" };
        }
        case "session-abort":
            return rpcReceiptOutcome(await workflowRPC("session.abort", {}, context));
        case "set-session-budget": {
            await workflowRPC("session.options.update", {
                sessionLimits: action.maxAiCredits == null ? null : { maxAiCredits: action.maxAiCredits },
            }, context);
            if (!operationAuthorityCurrent(context)) return { state: "indeterminate" };
            const metadata = await workflowRead("session.metadata.snapshot", {}, context);
            return Object.hasOwn(metadata, "sessionLimits")
                && (metadata.sessionLimits?.maxAiCredits ?? null) === (action.maxAiCredits ?? null)
                ? { state: "applied" } : { state: "indeterminate", errorCode: "rpc-indeterminate" };
        }
        case "answer-session-budget":
            return rpcReceiptOutcome(await workflowRPC("session.ui.handlePendingSessionLimitsExhausted", {
                requestId: action.requestId,
                response: action.additionalAiCredits == null
                    ? { action: "cancel" }
                    : { action: "add", additionalAiCredits: action.additionalAiCredits },
            }, context));
        }
    }

    async function processWorkflowAction(kind) {
        if (!ownsSharedFiles()) return;
        const path = workflowPaths.get(kind);
        let encoded;
        try {
            const stat = lstatSync(path);
            if (stat.size > 65_536 || !stat.isFile()) {
                console.error("[copilot-projects] oversized or invalid session action");
                return;
            }
            encoded = readFileSync(path, "utf8");
        } catch (error) {
            if (error?.code !== "ENOENT") {
                console.error("[copilot-projects] could not read session action:", error);
            }
            return;
        }
        let request;
        try { request = JSON.parse(encoded); } catch {
            console.error("[copilot-projects] invalid session action JSON");
            removeCapturedHandoff(path, encoded);
            return;
        }
        if (!request || typeof request !== "object") {
            removeCapturedHandoff(path, encoded);
            return;
        }
        const operation = parseOperationMetadata(request, kind);
        if (["busy", "inflight"].includes(operation.mode)) return;
        if (operation.mode === "terminal") {
            if (publish()) removeCapturedHandoff(path, encoded, operation.context);
            return;
        }
        if (operation.mode === "indeterminate") {
            if (publishTerminalReceipt(operation.context, "indeterminate", "execution-ownership-lost")) {
                removeCapturedHandoff(path, encoded, operation.context);
            }
            return;
        }
        if (operation.mode !== "new") {
            removeCapturedHandoff(path, encoded);
            return;
        }
        const action = request.action;
        const context = operation.context;
        const workflow = workflowSnapshot();
        const valid = request.schemaVersion === 1 && validWorkflowAction(action, kind)
            && workflow.capabilities.includes(kind)
            && (kind !== "session-send" || workflow.sendReady)
            && (kind !== "set-session-budget" || pendingBudgetRequest === null)
            && (kind !== "answer-session-budget"
                || pendingBudgetRequest?.requestId === action.requestId);
        if (!valid || !operationAuthorityCurrent(context)) {
            publishRejectedPreflight(context, "target-unavailable", path, encoded);
            return;
        }
        let attachments;
        if (kind === "session-send" && action.attachmentIds) {
            // Reserve execution before awaits so the filesystem watcher and
            // poll cannot preflight and dispatch the same operation twice.
            const preparingKey = operationExecutionKey(context.conversationEpoch, context.operationId);
            if (activeOperationKeys.has(preparingKey)) return;
            activeOperationKeys.add(preparingKey);
            try {
                attachments = await loadImageAttachments(action, context);
            } catch (error) {
                console.error("[copilot-projects] screenshot preflight failed:", error);
                publishRejectedPreflight(context, "attachments-unavailable", path, encoded);
                return;
            } finally {
                activeOperationKeys.delete(preparingKey);
            }
            if (!operationAuthorityCurrent(context) || workflowHasPendingInput()) {
                publishRejectedPreflight(context, "target-unavailable", path, encoded);
                return;
            }
        }
        if (!publishAcceptedReceipt(context)) return;
        const key = operationExecutionKey(context.conversationEpoch, context.operationId);
        activeOperationKeys.add(key);
        const timeout = setTimeout(() => {
            if (publishTerminalReceipt(context, "indeterminate", "receipt-timeout")) {
                removeCapturedHandoff(path, encoded, context);
            }
        }, 10_000);
        try {
            const outcome = await invokeWorkflowAction(action, context, attachments);
            if (!operationAuthorityCurrent(context)) return;
            if (publishTerminalReceipt(context, outcome.state, outcome.errorCode)) {
                removeCapturedHandoff(path, encoded, context);
            }
            if (kind === "answer-session-budget" && outcome.state !== "indeterminate"
                    && pendingBudgetRequest?.requestId === action.requestId) {
                pendingBudgetRequest = null;
                pendingBudgetIds.delete(action.requestId);
            }
            refreshWorkflow(true);
        } catch (error) {
            if (!operationAuthorityCurrent(context)) return;
            const unsupported = error?.code === -32601;
            if (unsupported) unavailableWorkflowActions.add(kind);
            console.error("[copilot-projects] native session action failed:", error);
            if (publishTerminalReceipt(
                context, unsupported ? "rejected" : "indeterminate",
                unsupported ? "unsupported-runtime" : "rpc-indeterminate"
            )) removeCapturedHandoff(path, encoded, context);
        } finally {
            clearTimeout(timeout);
            activeOperationKeys.delete(key);
        }
    }

    function observeWorkflowEvent(event) {
        const root = !event.agentId;
        if (root && event.type === "user.message" && classifyUserMessage(event)) {
            workflowLiveTurnId = event.id;
            liveMessageStreams.clear();
        }
        if (root && ["assistant.message_delta", "assistant.message"].includes(event.type)
                && typeof event.data.messageId === "string") {
            const id = boundedMetadataText(event.data.messageId);
            const turnId = workflowLiveTurnId || pendingTranscriptTurn?.id;
            if (turnId) {
                const previous = liveMessageStreams.get(id);
                const content = event.type === "assistant.message"
                    ? event.data.content
                    : (previous?.content || "") + (event.data.deltaContent || "");
                liveMessageStreams.set(id, {
                    id, turnId, content: boundedText(content),
                    timestamp: normalizedTimestamp(event.timestamp),
                });
                while (liveMessageStreams.size > 8) {
                    liveMessageStreams.delete(liveMessageStreams.keys().next().value);
                }
                if (event.type === "assistant.message_delta") {
                    if (!transcriptDeltaPublishTimer) {
                        transcriptDeltaPublishTimer = setTimeout(() => {
                            transcriptDeltaPublishTimer = null;
                            publishTranscript();
                        }, 2_000);
                    }
                } else {
                    schedulePublishTranscript();
                }
            }
        }
        if (root && event.type === "session.usage_info") {
            const { currentTokens, tokenLimit } = event.data;
            workflowContext = Number.isSafeInteger(currentTokens) && currentTokens >= 0
                && Number.isSafeInteger(tokenLimit) && tokenLimit > 0
                ? { currentTokens, tokenLimit } : null;
            publish();
        }
        if (event.type === "session_limits_exhausted.requested") {
            const { requestId, maxAiCredits, usedAiCredits } = event.data;
            if (typeof requestId === "string" && requestId.length > 0 && requestId.length <= 200
                    && finiteNonnegative(maxAiCredits) && finiteNonnegative(usedAiCredits)) {
                pendingBudgetIds.add(requestId);
                if (root) pendingBudgetRequest = { requestId, maxAiCredits, usedAiCredits };
                publish();
            }
        }
        if (event.type === "session_limits_exhausted.completed") {
            pendingBudgetIds.delete(event.data.requestId);
            if (pendingBudgetRequest?.requestId === event.data.requestId) pendingBudgetRequest = null;
            publish();
            refreshWorkflow(true);
        }
        if (root && ["session.usage_checkpoint", "session.session_limits_changed"].includes(event.type)) {
            refreshWorkflow(true);
        }
        if (root && event.type === "session.idle") {
            pendingBudgetIds.clear();
            pendingBudgetRequest = null;
            workflowLiveTurnId = null;
            refreshWorkflow(true);
        }
    }

    function isCoordinatorWorking() {
        return runtimeIdleAtMilliseconds === null
            && (foregroundTurnActive || currentTurnKind === "scheduled");
    }

    function currentActivityText() {
        if (isCoordinatorWorking()) return currentIntent;
        if (activeSubagents.size === 0) return null;
        for (const agent of activeSubagents.values()) {
            const description = boundedMetadataText(agent.description).replace(/\s+/g, " ").trim();
            const name = boundedMetadataText(agent.name).replace(/\s+/g, " ").trim();
            const text = description || (name !== "Background agent" ? name : "");
            if (!text) continue;
            const suffix = activeSubagents.size > 1 ? ` (+${activeSubagents.size - 1} more)` : "";
            return truncatedText(text, MAX_TRANSCRIPT_METADATA_TEXT - suffix.length) + suffix;
        }
        return "Waiting for background agents";
    }

    function publish(error) {
        if (!ownsSharedFiles()) return false;
        if (isTerminalDisconnect(error)) {
            terminalDisconnectError = String(error);
        }
        const reportedError = error ? String(error) : terminalDisconnectError;
        const snapshot = {
            schemaVersion: 1,
            updatedAt: new Date().toISOString(),
            foregroundTurnActive,
            currentIntent: currentActivityText(),
            foregroundTransitionAt,
            runtimeActivity,
            inputCompletions: Object.fromEntries(inputCompletions),
            sessionIdleAtMilliseconds,
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
            pendingPermissionRequestIds: [...pendingPermissionRequests.keys()],
            ...(currentModel ? { model: currentModel } : {}),
            ...(availableModels ? { availableModels } : {}),
            copilotSessionId,
            conversationEpoch,
            operationReceiptVersion: OPERATION_RECEIPT_VERSION,
            operationReceipts: operationReceiptSnapshot(),
            workflow: workflowSnapshot(),
            ...(reportedError ? { error: reportedError } : {}),
        };
        const temporaryPath = `${snapshotPath}.${process.pid}.tmp`;
        try {
            // Mode 0600 because the snapshot now carries question text.
            writeFileSync(temporaryPath, JSON.stringify(snapshot), { mode: 0o600 });
            renameSync(temporaryPath, snapshotPath);
            return true;
        } catch {
            removeFile(temporaryPath);
            return false;
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

    // Answer a pending question from the host-written response file. Legacy
    // invalid/stale responses only remove the file; correlated validation
    // failures publish a rejected receipt. Preflight failures and indeterminate
    // RPC outcomes retain the pending question. Explicit boolean RPC results or
    // completion events retire it: success:false means the ID is no longer
    // pending, while the losing answer's receipt remains rejected.
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
            removeCapturedHandoff(userInputResponsePath, encoded);
            return;
        }
        if (!response || typeof response !== "object"
                || response.schemaVersion !== 1
                || typeof response.requestId !== "string"
                || typeof response.copilotSessionId !== "string") {
            removeCapturedHandoff(userInputResponsePath, encoded);
            return;
        }
        const requestId = response.requestId;
        if (response.copilotSessionId !== copilotSessionId) {
            removeCapturedHandoff(userInputResponsePath, encoded);
            return;
        }
        const operation = parseOperationMetadata(response, "answer-user-input");
        if (operation.mode === "invalid"
                || operation.mode === "stale"
                || operation.mode === "conflict") {
            removeCapturedHandoff(userInputResponsePath, encoded);
            return;
        }
        if (operation.mode === "busy" || operation.mode === "inflight") return;
        if (operation.mode === "indeterminate") {
            if (publishTerminalReceipt(
                operation.context,
                "indeterminate",
                "execution-ownership-lost"
            )) {
                removeCapturedHandoff(
                    userInputResponsePath,
                    encoded,
                    operation.context
                );
            }
            return;
        }
        if (operation.mode === "terminal") {
            if (publish()) {
                removeCapturedHandoff(
                    userInputResponsePath,
                    encoded,
                    operation.context
                );
            }
            return;
        }
        const pending = pendingUserInputs.get(requestId);
        const answer = response.answer;
        const wasFreeform = response.wasFreeform;
        const valid = pending
            && typeof answer === "string"
            && userInputByteLength(answer) <= MAX_USER_INPUT_ANSWER_BYTES
            && typeof wasFreeform === "boolean"
            && (wasFreeform
                ? pending.allowFreeform
                : pending.choices.includes(answer));
        if (!valid) {
            if (operation.mode === "legacy") {
                removeCapturedHandoff(userInputResponsePath, encoded);
            } else {
                publishRejectedPreflight(
                    operation.context,
                    "invalid-request",
                    userInputResponsePath,
                    encoded
                );
            }
            return;
        }
        if (operation.mode === "new"
                && !publishAcceptedReceipt(operation.context)) {
            return;
        }

        const executionContext = operation.mode === "legacy"
            ? {
                generation: conversationGeneration,
                copilotSessionId,
                conversationEpoch,
            }
            : operation.context;
        const requestExecutionKey = `${executionContext.generation}\u0000${requestId}`;
        const operationKey = operation.mode === "legacy"
            ? null
            : operationExecutionKey(
                operation.context.conversationEpoch,
                operation.context.operationId
            );
        if (inFlightUserInputResponses.has(requestExecutionKey)) return;
        inFlightUserInputResponses.add(requestExecutionKey);
        if (operationKey) activeOperationKeys.add(operationKey);
        let invoked = false;
        try {
            if (!operationAuthorityCurrent(executionContext)
                    || pendingUserInputs.get(requestId) !== pending) {
                if (operation.mode === "legacy") {
                    removeCapturedHandoff(
                        userInputResponsePath,
                        encoded,
                        executionContext
                    );
                } else {
                    publishRejectedPreflight(
                        operation.context,
                        "target-unavailable",
                        userInputResponsePath,
                        encoded
                    );
                }
                return;
            }
            invoked = true;
            const result = await session.rpc.ui.handlePendingUserInput({
                requestId,
                response: { answer, wasFreeform },
            });
            if (!operationAuthorityCurrent(executionContext)) return;
            // False means the request is no longer pending, not that our answer succeeded.
            const resolved = typeof result?.success === "boolean";
            if (resolved) {
                noteQuestionCompleted(requestId);
                pendingUserInputs.delete(requestId);
            }
            if (operation.mode === "legacy") {
                removeCapturedHandoff(userInputResponsePath, encoded, executionContext);
                if (resolved) publish();
            } else {
                const outcome = rpcReceiptOutcome(result);
                const published = publishTerminalReceipt(
                    operation.context,
                    outcome.state,
                    outcome.errorCode
                );
                if (published) {
                    removeCapturedHandoff(
                        userInputResponsePath,
                        encoded,
                        operation.context
                    );
                }
            }
        } catch {
            if (!operationAuthorityCurrent(executionContext)) return;
            if (operation.mode === "legacy") {
                removeCapturedHandoff(
                    userInputResponsePath,
                    encoded,
                    executionContext
                );
            } else if (invoked) {
                const published = publishTerminalReceipt(
                    operation.context,
                    "indeterminate",
                    "rpc-indeterminate"
                );
                if (published) {
                    removeCapturedHandoff(
                        userInputResponsePath,
                        encoded,
                        operation.context
                    );
                }
            }
        } finally {
            inFlightUserInputResponses.delete(requestExecutionKey);
            if (operationKey) activeOperationKeys.delete(operationKey);
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

    function suppressRecoveredDurableQuestion(toolCallId) {
        if (typeof toolCallId !== "string" || !toolCallId
                || toolCallId.length > 200) return;
        recoveredQuestionToolCallIds.add(toolCallId);
        while (recoveredQuestionToolCallIds.size > MAX_QUESTION_COMPLETIONS) {
            recoveredQuestionToolCallIds.delete(recoveredQuestionToolCallIds.values().next().value);
        }
        const requestId = DURABLE_ASK_USER_PREFIX + toolCallId;
        if (durableAskUser?.requestId === requestId) durableAskUser = null;
        if (durableAskUserScan?.requestId === requestId) durableAskUserScan = null;
    }

    function noteQuestionCompleted(requestId) {
        pendingQuestionRecovery?.completed.add(requestId);
        questionEventStream?.inputs.delete(requestId);
        questionEventStream?.elicitations.delete(requestId);
        // Runtime request IDs are unique; a delayed notification must not reopen an answered form.
        completedQuestionRequests.delete(requestId);
        completedQuestionRequests.add(requestId);
        while (completedQuestionRequests.size > MAX_QUESTION_COMPLETIONS) {
            completedQuestionRequests.delete(completedQuestionRequests.values().next().value);
        }
    }

    function applyQuestionEvent(event, recovered = false) {
        const requestId = event?.data?.requestId;
        if (!QUESTION_EVENT_TYPES.includes(event?.type)
                || typeof requestId !== "string" || !requestId
                || requestId.length > 200 || requestId.startsWith(DURABLE_ASK_USER_PREFIX)) return false;
        const elicitation = event.type.startsWith("elicitation.");
        const pending = elicitation ? pendingElicitations : pendingUserInputs;
        if (event.type.endsWith(".completed")) {
            noteQuestionCompleted(requestId);
            const entry = pending.get(requestId);
            const cleared = (!recovered || entry) ? observeLiveRootQuestion(event) : false;
            if (entry) {
                pending.delete(requestId);
                recordInputCompletion(entry.agentId || copilotSessionId, event);
            }
            return Boolean(entry) || cleared;
        }
        if (completedQuestionRequests.has(requestId)) return false;
        const entry = elicitation ? elicitationEntry(event) : userInputEntry(event);
        const maximum = elicitation ? MAX_ELICITATIONS : MAX_USER_INPUTS;
        if (recovered) {
            if (!entry) return false;
            if (!pending.has(requestId) && pending.size >= maximum) {
                const oldest = [...pending.values()].reduce((oldest, item) =>
                    item.requestedAt < oldest.requestedAt ? item : oldest
                );
                if (entry.requestedAt <= oldest.requestedAt) return false;
                pending.delete(oldest.requestId);
            }
        }
        const cleared = observeLiveRootQuestion(event);
        if (!entry) return cleared;
        if (recovered && !entry.agentId) suppressRecoveredDurableQuestion(event.data.toolCallId);
        if (pending.has(requestId)) return cleared;
        pending.set(requestId, entry);
        if (elicitation) boundPendingElicitations();
        else boundPendingUserInputs();
        return true;
    }

    async function reconcileQuestionEvents() {
        if (shuttingDown) return;
        const generation = conversationGeneration;
        const stream = questionEventStream ??= {
            sessionId: copilotSessionId,
            cursor: undefined,
            startCursor: undefined,
            inputsOverflowed: false,
            elicitationsOverflowed: false,
            inputs: new Map(),
            elicitations: new Map(),
            completed: new Map(),
            inFlight: false,
            unsupported: false,
            error: null,
        };
        if (stream.inFlight || stream.unsupported) return;
        stream.inFlight = true;
        const current = () => !shuttingDown && questionEventStream === stream
            && generation === conversationGeneration && stream.sessionId === copilotSessionId;
        const report = (message) => {
            if (current() && stream.error !== message) {
                stream.error = message;
                console.error("[copilot-projects] question event recovery:", message);
            }
        };
        let timeout = null;
        try {
            if (!ownsSharedFiles()) return;
            if (typeof session.connection?.sendRequest !== "function") {
                throw Object.assign(new Error("question event API unavailable"), { code: -32601 });
            }
            const startedAt = Date.now();
            for (let page = 0; page < MAX_QUESTION_EVENT_PAGES; page++) {
                timeout = setTimeout(
                    () => report("event read is slow; keeping the existing questions while it finishes"),
                    PENDING_QUESTIONS_TIMEOUT_MS
                );
                // Keep the single-flight guard until the RPC settles, even when it is slow.
                const result = await session.connection.sendRequest("session.eventLog.read", {
                    sessionId: stream.sessionId,
                    ...(stream.cursor === undefined ? {} : { cursor: stream.cursor }),
                    types: QUESTION_EVENT_TYPES,
                    agentScope: "all",
                    direction: "forward",
                    includeEphemeral: true,
                    max: QUESTION_EVENT_PAGE_SIZE,
                    waitMs: 0,
                });
                clearTimeout(timeout);
                timeout = null;
                if (!current()) return;
                if (!Array.isArray(result?.events) || result.events.length > QUESTION_EVENT_PAGE_SIZE
                        || typeof result.cursor !== "string" || !result.cursor
                        || typeof result.hasMore !== "boolean"
                        || !["ok", "expired"].includes(result.cursorStatus)) {
                    throw new Error("invalid question event page");
                }
                if (result.cursorStatus === "expired") {
                    stream.cursor = undefined;
                    stream.startCursor = undefined;
                    stream.inputsOverflowed = false;
                    stream.elicitationsOverflowed = false;
                    stream.inputs.clear();
                    stream.elicitations.clear();
                    stream.completed.clear();
                    report("cursor expired; restarting retained question history");
                    return;
                }
                if (result.hasMore && result.cursor === stream.cursor) {
                    throw new Error("question event cursor did not advance");
                }
                // Stage the whole catch-up before publishing: a later page may complete a request.
                for (const event of result.events) {
                    const requestId = event?.data?.requestId;
                    if (!QUESTION_EVENT_TYPES.includes(event?.type)
                            || typeof requestId !== "string" || !requestId || requestId.length > 200
                            || !Number.isFinite(Date.parse(event.timestamp))) continue;
                    if (event.type.endsWith(".completed")) {
                        noteQuestionCompleted(requestId);
                        stream.completed.set(requestId, event);
                        while (stream.completed.size > MAX_QUESTION_COMPLETIONS) {
                            stream.completed.delete(stream.completed.keys().next().value);
                        }
                    } else if (!stream.completed.has(requestId) && !completedQuestionRequests.has(requestId)) {
                        const entry = event.type === "elicitation.requested"
                            ? elicitationEntry(event) : userInputEntry(event);
                        if (!entry) continue;
                        const pending = event.type === "elicitation.requested" ? stream.elicitations : stream.inputs;
                        const maximum = event.type === "elicitation.requested" ? MAX_ELICITATIONS : MAX_USER_INPUTS;
                        if (!pending.has(requestId)) pending.set(requestId, event);
                        while (pending.size > maximum) {
                            if (pending === stream.inputs) stream.inputsOverflowed = true;
                            else stream.elicitationsOverflowed = true;
                            pending.delete(pending.keys().next().value);
                        }
                    }
                }
                stream.cursor = result.cursor;
                if (!result.hasMore && (
                    (stream.inputsOverflowed && stream.inputs.size < MAX_USER_INPUTS)
                    || (stream.elicitationsOverflowed && stream.elicitations.size < MAX_ELICITATIONS)
                )) {
                    // Completions freed capped slots; reselect with their tombstones before publishing.
                    stream.cursor = stream.startCursor;
                    stream.inputsOverflowed = false;
                    stream.elicitationsOverflowed = false;
                    stream.inputs.clear();
                    stream.elicitations.clear();
                } else if (!result.hasMore) {
                    let changed = false;
                    for (const event of stream.completed.values()) {
                        changed = applyQuestionEvent(event, true) || changed;
                    }
                    for (const event of [...stream.inputs.values(), ...stream.elicitations.values()]) {
                        changed = applyQuestionEvent(event, true) || changed;
                    }
                    stream.inputs.clear();
                    stream.elicitations.clear();
                    stream.completed.clear();
                    stream.startCursor = stream.cursor;
                    stream.inputsOverflowed = false;
                    stream.elicitationsOverflowed = false;
                    stream.error = null;
                    if (changed) publish();
                    return;
                }
                if (Date.now() - startedAt >= PENDING_QUESTIONS_TIMEOUT_MS) return;
            }
        } catch (error) {
            if (!current()) return;
            stream.unsupported = error?.code === -32601;
            report(stream.unsupported ? "event API unavailable; keeping terminal fallback" : String(error));
        } finally {
            clearTimeout(timeout);
            stream.inFlight = false;
        }
    }

    async function recoverPendingQuestions(generation) {
        if (generation !== conversationGeneration || shuttingDown) return;
        const recovery = {
            sessionId: copilotSessionId,
            completed: new Set(),
        };
        pendingQuestionRecovery = recovery;
        let timeout = null;
        const current = () => !shuttingDown
            && pendingQuestionRecovery === recovery
            && generation === conversationGeneration
            && recovery.sessionId === copilotSessionId;
        try {
            if (typeof session.connection?.sendRequest !== "function") {
                throw Object.assign(new Error("pending question RPC unavailable"), { code: -32601 });
            }
            const result = await Promise.race([
                session.connection.sendRequest("session.ui.pendingRequests", {
                    sessionId: recovery.sessionId,
                }),
                new Promise((_, reject) => {
                    timeout = setTimeout(
                        () => reject(new Error("pending question recovery timed out")),
                        PENDING_QUESTIONS_TIMEOUT_MS
                    );
                }),
            ]);
            if (!current()) return;
            if (!Array.isArray(result?.userInputRequests)
                    || !Array.isArray(result?.elicitationRequests)) {
                throw new Error("invalid pending question snapshot");
            }
            for (const [items, pending, parse, maximum] of [
                [result.userInputRequests, pendingUserInputs, userInputEntry, MAX_USER_INPUTS],
                [result.elicitationRequests, pendingElicitations, elicitationEntry, MAX_ELICITATIONS],
            ]) {
                for (const data of items.slice(-maximum)) {
                    if (recovery.completed.has(data?.requestId) || completedQuestionRequests.has(data?.requestId)) continue;
                    const entry = parse({ data });
                    if (!entry) continue;
                    // Live events win over an older snapshot, including their agent ownership.
                    if (!pending.has(entry.requestId)) {
                        if (pending.size >= maximum) continue;
                        pending.set(entry.requestId, entry);
                    }
                    if (!pending.get(entry.requestId).agentId) {
                        suppressRecoveredDurableQuestion(data.toolCallId);
                    }
                }
            }
            publish();
        } catch (error) {
            if (!current()) return;
            if (error?.code === -32601) {
                console.error("[copilot-projects] pending snapshot unavailable; using question event recovery");
            } else {
                console.error("[copilot-projects] pending question recovery failed:", error);
            }
        } finally {
            clearTimeout(timeout);
            if (pendingQuestionRecovery === recovery) pendingQuestionRecovery = null;
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
                || toolCallId.length > 200
                || recoveredQuestionToolCallIds.has(toolCallId)) {
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
    // and retains the card on preflight/indeterminate failures. Explicit
    // success:false retires the no-longer-pending request with a rejected receipt.
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
            removeCapturedHandoff(elicitationResponsePath, encoded);
            return;
        }
        if (!response || typeof response !== "object"
                || response.schemaVersion !== 1
                || typeof response.requestId !== "string"
                || typeof response.copilotSessionId !== "string") {
            removeCapturedHandoff(elicitationResponsePath, encoded);
            return;
        }
        const requestId = response.requestId;
        if (requestId.startsWith(DURABLE_ASK_USER_PREFIX)) {
            removeCapturedHandoff(elicitationResponsePath, encoded);
            return;
        }
        if (response.copilotSessionId !== copilotSessionId) {
            removeCapturedHandoff(elicitationResponsePath, encoded);
            return;
        }
        const operation = parseOperationMetadata(response, "answer-elicitation");
        if (operation.mode === "invalid"
                || operation.mode === "stale"
                || operation.mode === "conflict") {
            removeCapturedHandoff(elicitationResponsePath, encoded);
            return;
        }
        if (operation.mode === "busy" || operation.mode === "inflight") return;
        if (operation.mode === "indeterminate") {
            if (publishTerminalReceipt(
                operation.context,
                "indeterminate",
                "execution-ownership-lost"
            )) {
                removeCapturedHandoff(
                    elicitationResponsePath,
                    encoded,
                    operation.context
                );
            }
            return;
        }
        if (operation.mode === "terminal") {
            if (publish()) {
                removeCapturedHandoff(
                    elicitationResponsePath,
                    encoded,
                    operation.context
                );
            }
            return;
        }
        const pending = pendingElicitations.get(requestId);
        const action = response.action;
        let valid = Boolean(pending)
            && (action === "accept" || action === "decline" || action === "cancel");
        const result = { action };
        if (valid && action === "accept") {
            if (pending.mode === "url" || typeof pending.url === "string") {
                if (response.content != null) {
                    valid = false;
                }
            } else {
                const content = response.content;
                if (!content || typeof content !== "object" || Array.isArray(content)) {
                    valid = false;
                }
                let serialized;
                try {
                    serialized = JSON.stringify(content);
                } catch {
                    valid = false;
                }
                if (valid
                        && Buffer.byteLength(serialized)
                            > MAX_ELICITATION_CONTENT_BYTES) {
                    valid = false;
                }
                if (valid) result.content = content;
            }
        } else if (valid && response.content != null) {
            valid = false;
        }
        if (!valid) {
            if (operation.mode === "legacy") {
                removeCapturedHandoff(elicitationResponsePath, encoded);
            } else {
                publishRejectedPreflight(
                    operation.context,
                    "invalid-request",
                    elicitationResponsePath,
                    encoded
                );
            }
            return;
        }
        if (operation.mode === "new"
                && !publishAcceptedReceipt(operation.context)) {
            return;
        }

        const executionContext = operation.mode === "legacy"
            ? {
                generation: conversationGeneration,
                copilotSessionId,
                conversationEpoch,
            }
            : operation.context;
        const requestExecutionKey = `${executionContext.generation}\u0000${requestId}`;
        const operationKey = operation.mode === "legacy"
            ? null
            : operationExecutionKey(
                operation.context.conversationEpoch,
                operation.context.operationId
            );
        if (inFlightElicitationResponses.has(requestExecutionKey)) return;
        inFlightElicitationResponses.add(requestExecutionKey);
        if (operationKey) activeOperationKeys.add(operationKey);
        let invoked = false;
        try {
            if (!operationAuthorityCurrent(executionContext)
                    || pendingElicitations.get(requestId) !== pending) {
                if (operation.mode === "legacy") {
                    removeCapturedHandoff(
                        elicitationResponsePath,
                        encoded,
                        executionContext
                    );
                } else {
                    publishRejectedPreflight(
                        operation.context,
                        "target-unavailable",
                        elicitationResponsePath,
                        encoded
                    );
                }
                return;
            }
            invoked = true;
            const rpcResult = await session.rpc.ui.handlePendingElicitation({
                requestId,
                result,
            });
            if (!operationAuthorityCurrent(executionContext)) return;
            // False means the request is no longer pending, not that our answer succeeded.
            const resolved = typeof rpcResult?.success === "boolean";
            if (resolved) {
                noteQuestionCompleted(requestId);
                pendingElicitations.delete(requestId);
            }
            if (operation.mode === "legacy") {
                removeCapturedHandoff(elicitationResponsePath, encoded, executionContext);
                if (resolved) publish();
            } else {
                const outcome = rpcReceiptOutcome(rpcResult);
                const published = publishTerminalReceipt(
                    operation.context,
                    outcome.state,
                    outcome.errorCode
                );
                if (published) {
                    removeCapturedHandoff(
                        elicitationResponsePath,
                        encoded,
                        operation.context
                    );
                }
            }
        } catch {
            if (!operationAuthorityCurrent(executionContext)) return;
            if (operation.mode === "legacy") {
                removeCapturedHandoff(
                    elicitationResponsePath,
                    encoded,
                    executionContext
                );
            } else if (invoked) {
                const published = publishTerminalReceipt(
                    operation.context,
                    "indeterminate",
                    "rpc-indeterminate"
                );
                if (published) {
                    removeCapturedHandoff(
                        elicitationResponsePath,
                        encoded,
                        operation.context
                    );
                }
            }
        } finally {
            inFlightElicitationResponses.delete(requestExecutionKey);
            if (operationKey) activeOperationKeys.delete(operationKey);
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
        const assistantMessages = turn.assistantMessages.slice();
        for (const stream of liveMessageStreams.values()) {
            if (stream.turnId === turn.id && stream.content.trim().length > 0
                    && !assistantMessages.some((message) => message.id === stream.id)
                    && assistantMessages.length < MAX_TRANSCRIPT_ASSISTANT_MESSAGES) {
                assistantMessages.push({ id: stream.id, timestamp: stream.timestamp, content: stream.content });
            }
        }
        return {
            id: turn.id,
            startedAt: turn.startedAt,
            endedAt: null,
            kind: turn.kind,
            userContent: turn.userContent,
            assistantMessages,
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
    //
    // Reduction is driven by exact encoded-byte accounting instead of
    // re-encoding the whole document after every removal. A transcript that
    // has to shed hundreds of messages used to cost hundreds of full
    // `JSON.stringify` passes over a multi-megabyte document (gigabytes of
    // throwaway string churn for a single publish). Here every item is
    // measured once — `JSON.stringify` of the item itself, counted in UTF-8
    // bytes exactly as the enclosing document counts it, escaping and lone
    // surrogates included — and each removal subtracts that item's bytes
    // plus the separating comma it takes with it, so the running total
    // tracks the final encoding byte for byte.
    function encodedTranscriptWithinBudget(pending) {
        // The envelope, `updatedAt` included, is captured once: all the
        // accounting below is anchored to this exact prefix, and a
        // timestamp that drifted mid-trim would invalidate it.
        const snapshot = {
            schemaVersion: 3,
            updatedAt: new Date().toISOString(),
            copilotSessionId: boundedMetadataText(copilotSessionId),
            ownerPid: process.pid,
            turns: pending ? [...transcriptTurns, pending] : transcriptTurns.slice(),
        };
        let encoded = JSON.stringify(snapshot);
        // Overwhelmingly common case: one encode, exactly as before.
        if (Buffer.byteLength(encoded) <= MAX_TRANSCRIPT_BYTES) return encoded;

        // `n` array members carry `n - 1` separating commas.
        const separators = (count) => (count > 0 ? count - 1 : 0);
        const encodedBytes = (value) => {
            const item = JSON.stringify(value);
            // A member that stringifies to `undefined` is emitted as `null`
            // by the enclosing array.
            return Buffer.byteLength(item === undefined ? "null" : item);
        };
        const sum = (values) => values.reduce((carry, value) => carry + value, 0);
        // Measures one turn: the shell it encodes to with both payload
        // arrays empty, plus every member's own encoded size. A turn from a
        // restored snapshot whose payload is not an array is measured
        // verbatim inside the shell and simply has nothing to shed.
        const measure = (turn) => {
            const messages = Array.isArray(turn.assistantMessages)
                ? turn.assistantMessages
                : null;
            const tools = Array.isArray(turn.tools) ? turn.tools : null;
            const shell = { ...turn };
            if (messages) shell.assistantMessages = [];
            if (tools) shell.tools = [];
            const messageBytes = messages ? messages.map(encodedBytes) : [];
            const toolBytes = tools ? tools.map(encodedBytes) : [];
            return {
                turn,
                messages,
                tools,
                messageBytes,
                toolBytes,
                bytes: Buffer.byteLength(JSON.stringify(shell))
                    + sum(messageBytes) + separators(messageBytes.length)
                    + sum(toolBytes) + separators(toolBytes.length),
            };
        };

        const turns = snapshot.turns;
        const entries = turns.map(measure);
        // `turns` mirrors `transcriptTurns` with `pending` appended, so a
        // stored turn shares its index across both arrays.
        let storedCount = pending ? turns.length - 1 : turns.length;
        let total = Buffer.byteLength(JSON.stringify({ ...snapshot, turns: [] }))
            + sum(entries.map((entry) => entry.bytes))
            + separators(entries.length);
        const overBudget = () => total > MAX_TRANSCRIPT_BYTES;
        const dropStoredTurn = (index) => {
            total -= entries[index].bytes + (turns.length > 1 ? 1 : 0);
            transcriptTurns.splice(index, 1);
            turns.splice(index, 1);
            entries.splice(index, 1);
            storedCount -= 1;
        };
        const droppableStoredIndex = (predicate) => entries.findIndex(
            (entry, index) => index < storedCount && predicate(entry.turn)
        );
        const shedOldestPayload = (predicate) => {
            for (const entry of entries) {
                if (!predicate(entry.turn)) continue;
                for (const [sizes, items] of [
                    [entry.messageBytes, entry.messages],
                    [entry.toolBytes, entry.tools],
                ]) {
                    if (sizes.length === 0) continue;
                    // The comma disappears with the member only while
                    // another member survives beside it.
                    const removed = sizes.shift() + (sizes.length > 0 ? 1 : 0);
                    items.shift();
                    entry.bytes -= removed;
                    total -= removed;
                    return true;
                }
            }
            return false;
        };

        // Phase 1: drop whole non-foreground stored turns (oldest first).
        while (overBudget()) {
            const index = droppableStoredIndex(
                (turn) => turn.kind !== "foreground"
                    && turn.id !== latestResumeTranscriptTurnId
            );
            if (index === -1) break;
            dropStoredTurn(index);
        }
        // Phase 2: shed payload from any remaining non-foreground turn (i.e. an
        // in-progress scheduled/automated turn) before touching foreground.
        while (overBudget()) {
            if (!shedOldestPayload(
                (turn) => turn.kind !== "foreground"
                    && turn.id !== latestResumeTranscriptTurnId
            )) break;
        }
        // Phase 3: drop whole foreground stored turns (oldest), never pending,
        // leaving at least one turn for payload shedding below.
        const minStored = pending ? 0 : 1;
        while (overBudget() && storedCount > minStored) {
            const index = droppableStoredIndex(
                (turn) => turn.id !== latestResumeTranscriptTurnId
            );
            if (index === -1) break;
            dropStoredTurn(index);
        }
        // Phase 4: shed payload from the last remaining turn(s).
        while (overBudget()) {
            if (!shedOldestPayload(() => true)) break;
        }

        encoded = JSON.stringify(snapshot);
        // Reject an impossible budget rather than discard protected turns or
        // overwrite the last good snapshot with an oversized document.
        if (Buffer.byteLength(encoded) > MAX_TRANSCRIPT_BYTES) {
            throw new RangeError("Transcript exceeds its byte budget after trimming");
        }
        return encoded;
    }

    function writeTranscriptSnapshot() {
        const pending = serializedPendingTurn();
        trimTranscriptTurns(pending ? MAX_TRANSCRIPT_TURNS - 1 : MAX_TRANSCRIPT_TURNS);
        const temporaryPath = `${transcriptPath}.${process.pid}.tmp`;
        try {
            const encoded = encodedTranscriptWithinBudget(pending);
            writeFileSync(temporaryPath, encoded, { mode: 0o600 });
            renameSync(temporaryPath, transcriptPath);
        } catch (error) {
            console.error("copilot-projects: could not publish transcript", error);
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
        clearTimeout(transcriptDeltaPublishTimer);
        transcriptDeltaPublishTimer = null;
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
        if (typeof value !== "string" || value.trim().length === 0) return;
        ensureSyntheticTranscriptTurn(event);
        const content = boundedText(value);
        const id = boundedMetadataText(event.data.messageId || event.id);
        const existing = pendingTranscriptTurn.assistantMessages.find((message) => message.id === id);
        if (existing) {
            existing.content = content;
            return;
        }
        if (pendingTranscriptTurn.assistantMessages.length
                >= MAX_TRANSCRIPT_ASSISTANT_MESSAGES) {
            pendingTranscriptTurn.assistantMessages.shift();
        }
        pendingTranscriptTurn.assistantMessages.push({
            id,
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
        while (completedPermissionRequests.size > 128) {
            completedPermissionRequests.delete(
                completedPermissionRequests.keys().next().value
            );
        }
    }

    function applyPermissionEvent(event, live) {
        if (event.type === "session.idle") {
            if (event.agentId) return;
            if (pendingPermissionRequests.size > 0) {
                pendingPermissionRequests.clear();
                if (live) publish();
            }
            return;
        }
        const requestId = event.data?.requestId;
        if (typeof requestId !== "string" || requestId.length === 0) return;
        let changed = false;
        if (event.type === "permission.requested") {
            if (!completedPermissionRequests.has(requestId)
                    && !pendingPermissionRequests.has(requestId)
                    && pendingPermissionRequests.size < 64) {
                pendingPermissionRequests.set(requestId, event.agentId || copilotSessionId);
                changed = true;
            }
        } else if (event.type === "permission.completed") {
            const completed = completedPermissionRequests.get(requestId);
            const owner = pendingPermissionRequests.get(requestId) ?? completed?.owner;
            const certify = live && !completed?.certified && owner !== undefined;
            completedPermissionRequests.set(requestId, {
                owner,
                certified: completed?.certified === true || certify,
            });
            boundCompletedPermissionIds();
            changed = pendingPermissionRequests.delete(requestId) || certify;
            if (certify) recordInputCompletion(owner, event);
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
        observeWorkflowEvent(event);
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
            const entries = result.entries;
            // A successful call also proves the connection recovered, so a
            // cleared terminal disconnect counts as a change even when the
            // entries are identical.
            const changed = terminalDisconnectError !== null
                || !isDeepStrictEqual(entries, schedules);
            schedules = entries;
            terminalDisconnectError = null;
            // The poll's own heartbeat already refreshed `updatedAt` this
            // tick; republishing an identical snapshot would only double the
            // background write rate.
            if (changed) publish();
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
        clearTimeout(transcriptDeltaPublishTimer);
        transcriptDeltaPublishTimer = null;
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
        const pendingQuestions = recoverPendingQuestions(generation);
        reconcileQuestionEvents();
        let history = [];

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
            history = await sdkHistoryWithTimeout();
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
        if (historyLoaded) {
            const restoredTurnKind = latestRootTurnKind(history);
            if (restoredTurnKind !== null
                    && idleGeneration === closeActivityIdleBaseline
                    && currentTurnKind === null
                    && !foregroundTurnActive
                    && !scheduledTurnActive) {
                // History has no durable session.idle event, so it can prove
                // that a turn started but not that it is still live. Keep this
                // uncertainty local to close; don't relabel live activity.
                closeActivityState = "unknown";
            } else {
                closeActivityState = "ready";
            }
        } else if (closeActivityState === "pending") {
            closeActivityState = "unknown";
        }
        clearCloseActivityRetry();
        processCloseSessionRequest();
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
            // These were delivered live while history loaded. History can
            // overlap them, but must not consume their one sender certificate.
            applyPermissionEvent(event, true);
            if (durableTranscriptAuthoritative) {
                applyModelFromEvent(event);
            } else {
                replayHistoryEvent(event, false);
            }
        }
        queuedTranscriptEvents.length = 0;
        await pendingQuestions;
        if (stale()) return;
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
        clearTimeout(transcriptDeltaPublishTimer);
        transcriptDeltaPublishTimer = null;
        conversationEpoch = `${trackerInstanceId}:${conversationGeneration}`;
        workflowObservation = null;
        workflowContext = null;
        pendingBudgetRequest = null;
        pendingBudgetIds.clear();
        workflowLiveTurnId = null;
        liveMessageStreams.clear();
        foregroundSessionActive = false;
        foregroundObservationStartedAt = 0;
        operationReceipts.clear();
        activeOperationKeys.clear();
        activeSubagents.clear();
        pendingUserInputs.clear();
        inFlightUserInputResponses.clear();
        pendingElicitations.clear();
        recoveredQuestionToolCallIds.clear();
        completedQuestionRequests.clear();
        pendingQuestionRecovery = null;
        questionEventStream = null;
        inFlightElicitationResponses.clear();
        pendingPermissionRequests.clear();
        completedPermissionRequests.clear();
        inputCompletions.clear();
        runtimeActivityUnsupported = false;
        invalidateRuntimeActivity();

        foregroundTurnActive = false;
        currentIntent = null;
        scheduledTurnActive = false;
        currentTurnKind = null;
        closeActivityIdleBaseline = idleGeneration;
        closeActivityState = "pending";
        closeActivityPendingSince = Date.now();
        clearCloseActivityRetry();
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
        // Slash-command stop/clear discards the old conversation's queued
        // commands. Permanent tab close intent survives that queue/owner.
        closeSessionRequestInFlight = false;
        closeSessionExitQueued = false;
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
            for (const path of workflowPaths.values()) removeFile(path);
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
        refreshWorkflow();
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
            const images = imageCapabilities(entry);
            if (images) model.imageAttachments = images;
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
                const changed = !isDeepStrictEqual(normalized, availableModels);
                availableModels = normalized;
                // Identical catalogs are the steady state; the poll's
                // heartbeat already published this tick.
                if (changed) publish();
            }
        } catch {
        } finally {
            if (modelsRefreshGeneration === generation) {
                modelsRefreshGeneration = null;
            }
        }
    }

    function validatedModelSwitch(request, requireAdvertisedTarget) {
        if (typeof request.modelId !== "string"
                || request.modelId.length === 0
                || request.modelId.length > 200
                || (request.reasoningEffort !== undefined
                    && (typeof request.reasoningEffort !== "string"
                        || request.reasoningEffort.length === 0
                        || request.reasoningEffort.length > 64))
                || (request.contextTier !== undefined
                    && request.contextTier !== "default"
                    && request.contextTier !== "long_context")) {
            return null;
        }
        if (requireAdvertisedTarget) {
            const target = availableModels?.find(
                (model) => model.id === request.modelId
            );
            if (!target || target.disabled === true) return null;
            if (request.reasoningEffort !== undefined
                    && (!Array.isArray(target.supportedReasoningEfforts)
                        || !target.supportedReasoningEfforts.includes(
                            request.reasoningEffort
                        ))) {
                return null;
            }
            if (request.contextTier === "long_context"
                    && target.longContextAvailable !== true) {
                return null;
            }
        }
        return {
            modelId: request.modelId,
            ...(request.reasoningEffort !== undefined
                ? { reasoningEffort: request.reasoningEffort }
                : {}),
            ...(request.contextTier !== undefined
                ? { contextTier: request.contextTier }
                : {}),
        };
    }

    // Consume a host-written model switch request. Correlated requests publish
    // an accepted receipt before the first RPC and a terminal receipt before
    // refreshing the catalog; legacy requests retain their old no-receipt path.
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
            removeCapturedHandoff(setModelRequestPath, encoded);
            return;
        }
        if (!request || typeof request !== "object"
                || request.schemaVersion !== 1
                || typeof request.copilotSessionId !== "string") {
            removeCapturedHandoff(setModelRequestPath, encoded);
            return;
        }
        if (request.copilotSessionId !== copilotSessionId) {
            removeCapturedHandoff(setModelRequestPath, encoded);
            return;
        }
        const operation = parseOperationMetadata(request, "set-model");
        if (operation.mode === "invalid"
                || operation.mode === "stale"
                || operation.mode === "conflict") {
            removeCapturedHandoff(setModelRequestPath, encoded);
            return;
        }
        if (operation.mode === "busy" || operation.mode === "inflight") return;
        if (operation.mode === "indeterminate") {
            if (publishTerminalReceipt(
                operation.context,
                "indeterminate",
                "execution-ownership-lost"
            )) {
                removeCapturedHandoff(
                    setModelRequestPath,
                    encoded,
                    operation.context
                );
            }
            return;
        }
        if (operation.mode === "terminal") {
            if (publish()) {
                removeCapturedHandoff(
                    setModelRequestPath,
                    encoded,
                    operation.context
                );
            }
            return;
        }
        const params = validatedModelSwitch(
            request,
            operation.mode !== "legacy"
        );
        if (!params) {
            if (operation.mode === "legacy") {
                removeCapturedHandoff(setModelRequestPath, encoded);
            } else {
                publishRejectedPreflight(
                    operation.context,
                    "invalid-request",
                    setModelRequestPath,
                    encoded
                );
            }
            return;
        }
        if (operation.mode === "new"
                && !publishAcceptedReceipt(operation.context)) {
            return;
        }

        const executionContext = operation.mode === "legacy"
            ? {
                generation,
                copilotSessionId,
                conversationEpoch,
            }
            : operation.context;
        const operationKey = operation.mode === "legacy"
            ? null
            : operationExecutionKey(
                operation.context.conversationEpoch,
                operation.context.operationId
            );
        setModelRequestGeneration = generation;
        if (operationKey) activeOperationKeys.add(operationKey);
        let invoked = false;
        try {
            if (!operationAuthorityCurrent(executionContext)
                    || (operation.mode !== "legacy"
                        && !validatedModelSwitch(request, true))) {
                if (operation.mode === "legacy") {
                    removeCapturedHandoff(
                        setModelRequestPath,
                        encoded,
                        executionContext
                    );
                } else {
                    publishRejectedPreflight(
                        operation.context,
                        "target-unavailable",
                        setModelRequestPath,
                        encoded
                    );
                }
                return;
            }
            invoked = true;
            const result = await session.rpc.model.switchTo(params);
            if (!operationAuthorityCurrent(executionContext)) return;
            if (operation.mode === "legacy") {
                removeCapturedHandoff(
                    setModelRequestPath,
                    encoded,
                    executionContext
                );
                refreshModels();
            } else {
                const outcome = modelSwitchReceiptOutcome(result, params.modelId);
                const published = publishTerminalReceipt(
                    operation.context,
                    outcome.state,
                    outcome.errorCode
                );
                if (published) {
                    removeCapturedHandoff(
                        setModelRequestPath,
                        encoded,
                        operation.context
                    );
                }
                if (outcome.state === "applied") refreshModels();
            }
        } catch {
            if (!operationAuthorityCurrent(executionContext)) return;
            if (operation.mode === "legacy") {
                removeCapturedHandoff(
                    setModelRequestPath,
                    encoded,
                    executionContext
                );
            } else if (invoked) {
                const published = publishTerminalReceipt(
                    operation.context,
                    "indeterminate",
                    "rpc-indeterminate"
                );
                if (published) {
                    removeCapturedHandoff(
                        setModelRequestPath,
                        encoded,
                        operation.context
                    );
                }
            }
        } finally {
            if (operationKey) activeOperationKeys.delete(operationKey);
            if (setModelRequestGeneration === generation) {
                setModelRequestGeneration = null;
            }
        }
    }

    session.on("user.message", (event) => {
        if (event.agentId) return;
        currentIntent = null;
        invalidateRuntimeActivity();
        closeActivityState = "ready";
        clearCloseActivityRetry();
        lastIdleTurnKind = null;
        currentTurnKind = event.data.source?.startsWith("schedule-")
            ? "scheduled"
            : "foreground";
        setScheduledTurnMarker(currentTurnKind === "scheduled");
        foregroundTurnActive = currentTurnKind !== "scheduled";
        foregroundTransitionAt = normalizedTimestamp(event.timestamp);
        publish();
        refreshRuntimeActivity(true);
        processCloseSessionRequest();
    });

    session.on("assistant.turn_start", (event) => {
        if (event.agentId) {
            sessionIdleAtMilliseconds = null;
            if (!activeSubagents.has(event.agentId)) {
                activeSubagents.set(event.agentId, {
                    id: event.agentId,
                    name: "Background agent",
                    description: "",
                });
            }
            publish();
            return;
        }
        if (event.data.turnId === "0") currentIntent = null;
        runtimeActivityRevision += 1;
        runtimeIdleAtMilliseconds = null;
        sessionIdleAtMilliseconds = null;
        const needsRefresh = runtimeActivity?.processing !== true;
        if (needsRefresh) invalidateRuntimeActivity();
        closeActivityState = "ready";
        clearCloseActivityRetry();
        lastIdleTurnKind = null;
        scheduledTurnActive = currentTurnKind === "scheduled";
        foregroundTurnActive = !scheduledTurnActive;
        foregroundTransitionAt = normalizedTimestamp(event.timestamp);
        if (scheduledTurnActive) setScheduledTurnMarker(true);
        publish();
        if (needsRefresh) refreshRuntimeActivity(true);
        processCloseSessionRequest();
    });

    session.on("assistant.intent", (event) => {
        if (event.agentId || !isCoordinatorWorking()) return;
        currentIntent = boundedMetadataText(event.data.intent).replace(/\s+/g, " ").trim() || null;
        publish();
    });

    session.on("assistant.idle", (event) => {
        if (event.agentId) {
            activeSubagents.delete(event.agentId);
            publish();
            return;
        }
        const transition = normalizedTimestamp(event.timestamp);
        if (foregroundTransitionAt && transition < foregroundTransitionAt) return;
        runtimeActivityRevision += 1;
        foregroundTurnActive = false;
        currentIntent = null;
        foregroundTransitionAt = transition;
        runtimeIdleAtMilliseconds = Date.parse(transition);
        publish();
        refreshRuntimeActivity(true);
    });

    session.on("session.idle", (event) => {
        if (event.agentId) return;
        const transition = normalizedTimestamp(event.timestamp);
        if (foregroundTransitionAt && transition < foregroundTransitionAt) return;
        runtimeActivityRevision += 1;
        closeActivityState = "ready";
        clearCloseActivityRetry();
        idleGeneration += 1;
        lastIdleAborted = event.data.aborted === true;
        lastIdleTurnKind = currentTurnKind;
        currentTurnKind = null;
        foregroundTurnActive = false;
        currentIntent = null;
        foregroundTransitionAt = transition;
        runtimeIdleAtMilliseconds = Date.parse(foregroundTransitionAt);
        sessionIdleAtMilliseconds = runtimeIdleAtMilliseconds;
        scheduledTurnActive = false;
        activeSubagents.clear();
        pendingPermissionRequests.clear();
        publish();
        refreshRuntimeActivity(true);
        setTimeout(() => setScheduledTurnMarker(false), 5_000);
        processCloseSessionRequest();
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
        sessionIdleAtMilliseconds = null;
        const id = event.agentId || event.data.toolCallId;
        activeSubagents.set(id, {
            id,
            name: boundedMetadataText(event.data.agentDisplayName) || "Background agent",
            // MCP tasks put the full prompt in agentDescription, not the short task label.
            description: event.data.agentName === "mcp-task"
                ? "" : boundedMetadataText(event.data.agentDescription) || "",
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
        for (const path of workflowPaths.values()) removeFile(path);
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
            if (!filename || filename === closeSessionRequestName) {
                processCloseSessionRequest();
            }
            for (const kind of workflowKinds) {
                if (!filename || filename === `${appSessionId}.${kind}.json`) {
                    processWorkflowAction(kind);
                }
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
        clearTimeout(transcriptDeltaPublishTimer);
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
            for (const path of workflowPaths.values()) removeFile(path);
        }
    }
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

    function onQuestionEvent(event) {
        if (applyQuestionEvent(event)) publish();
    }
    session.on("user_input.requested", onQuestionEvent);
    session.on("user_input.completed", onQuestionEvent);
    session.on("elicitation.requested", onQuestionEvent);
    session.on("elicitation.completed", onQuestionEvent);

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
    refreshRuntimeActivity(true);
    refreshWorkflow();

    processUserInputResponse();
    processElicitationResponse();
    processSetModelRequest();
    processCloseSessionRequest();
    for (const kind of workflowKinds) processWorkflowAction(kind);

    timer = setInterval(() => {
        refreshForegroundAuthoritySoon();
        // Cheap safety net first: if the identity moved without a lifecycle
        // event reaching us, everything below must run against the new
        // conversation, not the one we just left.
        if (reconcileSessionIdentityFromSdk()) return;
        // Heartbeat. The host reads `updatedAt` as proof this session is
        // still alive (its staleness thresholds are 10s/15s), so liveness
        // must not ride on an RPC: `schedule.list` can hang, and either
        // refresh can be suppressed outright by its single-flight guard
        // while a previous call is still outstanding. Publishing here and
        // letting the refreshes publish only on an actual change keeps the
        // heartbeat exact while collapsing the steady-state cost from two
        // full snapshot writes per tick to one.
        publish();
        reconcileQuestionEvents();
        refreshRuntimeActivity();
        refreshSchedules();
        refreshModels();
        refreshWorkflow();
        processUserInputResponse();
        processElicitationResponse();
        processSetModelRequest();
        processCloseSessionRequest();
        for (const kind of workflowKinds) processWorkflowAction(kind);
        scheduleDurableReconcile(0);
    }, DURABLE_RECONCILE_POLL_MS);
    foregroundHandlingReady = true;
    activateForegroundSharedFiles();
}
