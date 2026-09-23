import assert from "node:assert/strict";
import fs from "node:fs";
import { registerHooks, syncBuiltinESMExports } from "node:module";
import { createHash, randomUUID } from "node:crypto";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import test from "node:test";

import {
  repositoryRoot,
  trackerResourceDir,
} from "./support/tracker.mjs";

const extensionPath = join(trackerResourceDir, "extension.mjs");
const runtimeParent = join(repositoryRoot, "JSTests", ".tracker-operation-runtime");
const runtimes = new Set();
const originalDateNow = Date.now;
const originalSetInterval = globalThis.setInterval;
const originalClearInterval = globalThis.clearInterval;
const originalWatch = fs.watch;
const originalWriteFileSync = fs.writeFileSync;
const originalCreateReadStream = fs.createReadStream;
const realMkdirSync = fs.mkdirSync.bind(fs);
const realReadFileSync = fs.readFileSync.bind(fs);
const realWriteFileSync = fs.writeFileSync.bind(fs);
const realRmSync = fs.rmSync.bind(fs);
const realExistsSync = fs.existsSync.bind(fs);

fs.watch = (path, callback) => {
  const runtime = [...runtimes].find((entry) =>
    String(path).startsWith(entry.root)
  );
  if (!runtime) return originalWatch(path, callback);
  runtime.watchCallback = callback;
  return { close() {} };
};
fs.writeFileSync = (path, ...args) => {
  const runtime = [...runtimes].find((entry) =>
    String(path).startsWith(entry.root)
  );
  if (runtime?.failWrite?.(String(path))) {
    throw new Error("injected tracker write failure");
  }
  const result = originalWriteFileSync(path, ...args);
  if (runtime && String(path).includes(".agent-activity.json.")) {
    runtime.activityWrites.push(JSON.parse(String(args[0])));
  }
  return result;
};
fs.createReadStream = (path, ...args) => {
  const stream = originalCreateReadStream(path, ...args);
  const runtime = [...runtimes].find((entry) =>
    String(path).startsWith(entry.root)
  );
  if (runtime && String(path).endsWith("events.jsonl")) {
    stream.once("close", () => { runtime.durableReadsFinished += 1; });
  }
  return stream;
};
syncBuiltinESMExports();

const fakeSDKURL = `data:text/javascript,${encodeURIComponent(`
  export async function joinSession() {
    return globalThis.__copilotProjectsTrackerSession;
  }
`)}`;
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === "@github/copilot-sdk/extension") {
      return { url: fakeSDKURL, shortCircuit: true };
    }
    return nextResolve(specifier, context);
  },
});

test.after(() => {
  Date.now = originalDateNow;
  globalThis.setInterval = originalSetInterval;
  globalThis.clearInterval = originalClearInterval;
  fs.watch = originalWatch;
  fs.writeFileSync = originalWriteFileSync;
  fs.createReadStream = originalCreateReadStream;
  syncBuiltinESMExports();
  realRmSync(runtimeParent, { recursive: true, force: true });
});

class FakeSession {
  constructor(sessionId) {
    this.sessionId = sessionId;
    this.namedListeners = new Map();
    this.genericListeners = [];
    this.userInputCalls = [];
    this.elicitationCalls = [];
    this.modelSwitchCalls = [];
    this.closeCalls = [];
    this.history = [];
    this.pendingQuestionCalls = [];
    this.questionEvents = [];
    this.questionEventCalls = [];
    this.questionEventHandler = async ({ cursor, max }) => {
      const offset = Number(cursor ?? 0);
      const events = this.questionEvents.slice(offset, offset + max);
      return {
        events,
        cursor: String(offset + events.length),
        hasMore: offset + events.length < this.questionEvents.length,
        cursorStatus: "ok",
      };
    };
    this.pendingQuestionsHandler = async () => ({
      userInputRequests: [], elicitationRequests: [],
    });
    this.processing = false;
    this.runtimeCalls = [];
    this.workflowCalls = [];
    this.statusHandler = async () => ({ version: "1.0.84-8", protocolVersion: 3 });
    this.sessionLimits = null;
    this.metadataHandler = async ({ sessionId }) => ({
      sessionId, isRemote: false, sessionLimits: this.sessionLimits,
      workspace: { branch: "fixture", repository: "fixture/repo" },
    });
    this.sendHandler = async () => ({ messageId: randomUUID() });
    this.usageHandler = async () => ({ totalNanoAiu: 2_000_000_000 });
    this.diffHandler = async () => ({
      requestedMode: "session", mode: "unstaged", isFallback: true,
      unavailableReason: "file-change-tracking-disabled", changes: [],
    });
    this.budgetHandler = async () => ({ success: true });
    this.processingHandler = async () => ({ processing: this.processing });
    this.abortHandler = async () => this.emit("session.idle", { aborted: true });
    this.enqueueHandler = async () => ({ queued: true });
    this.userInputHandler = async () => ({ success: true });
    this.elicitationHandler = async () => ({ success: true });
    this.modelSwitchHandler = async (request) => ({
      status: "applied", modelId: request.modelId, deferred: false,
    });
    this.modelListHandler = async () => ({
      list: [{
        id: "gpt-5.6-sol",
        name: "GPT-5.6 Sol",
        capabilities: { supports: { reasoning_effort: ["high"] } },
        billing: { token_prices: { long_context: {} } },
        model_picker_enabled: true,
      }],
    });
    this.rpc = {
      ui: {
        handlePendingUserInput: async (request) => {
          this.userInputCalls.push(request);
          return this.userInputHandler(request);
        },
        handlePendingElicitation: async (request) => {
          this.elicitationCalls.push(request);
          return this.elicitationHandler(request);
        },
      },
      model: {
        list: async () => this.modelListHandler(),
        switchTo: async (request) => {
          this.modelSwitchCalls.push(request);
          return this.modelSwitchHandler(request);
        },
      },
      schedule: {
        list: async () => ({ entries: [] }),
      },
      permissions: {
        getAllowAll: async () => ({ enabled: false }),
      },
      eventLog: {
        registerInterest: async ({ eventType }) => ({
          handle: `interest-${eventType}`,
        }),
        releaseInterest: async () => ({ success: true }),
      },
      commands: {
        enqueue: async (request) => {
          this.closeCalls.push({ ...request, sessionId: this.sessionId });
          return this.enqueueHandler(request);
        },
      },
    };
    this.connection = {
      sendRequest: async (method, params) => {
        if (method === "status.get") return this.statusHandler();
        if (method === "session.getForeground") {
          return { sessionId: this.foregroundSessionId ?? this.sessionId };
        }
        if (method === "session.ui.pendingRequests") {
          this.pendingQuestionCalls.push(params);
          return this.pendingQuestionsHandler(params);
        }
        if (method === "session.eventLog.read") {
          this.questionEventCalls.push(params);
          return this.questionEventHandler(params);
        }
        this.runtimeCalls.push({ method, ...params });
        if (method === "session.metadata.snapshot") return this.metadataHandler(params);
        if (method === "session.metadata.isProcessing") return this.processingHandler(params);
        if (method === "session.usage.getMetrics") return this.usageHandler(params);
        if (method === "session.workspaces.diff") return this.diffHandler(params);
        if (method === "session.model.getCurrent") return { modelId: "gpt-5.6-sol" };
        if (method === "session.model.list") return this.modelListHandler();
        this.workflowCalls.push({ method, ...params });
        if (method === "session.send") return this.sendHandler(params);
        if (method === "session.abort") {
          await this.abortHandler();
          return { success: true };
        }
        if (method === "session.options.update") {
          this.sessionLimits = params.sessionLimits;
          return { success: true };
        }
        if (method === "session.ui.handlePendingSessionLimitsExhausted") {
          return this.budgetHandler(params);
        }
        throw Object.assign(new Error(`Unknown RPC: ${method}`), { code: -32601 });
      },
    };
  }

  on(type, callback) {
    if (typeof type === "function") {
      this.genericListeners.push(type);
      return;
    }
    const listeners = this.namedListeners.get(type) ?? [];
    listeners.push(callback);
    this.namedListeners.set(type, listeners);
  }

  async emit(type, data = {}, extra = {}, deliver = true) {
    if (!extra.agentId && type === "assistant.turn_start") this.processing = true;
    if (!extra.agentId && (type === "assistant.idle" || type === "session.idle")) {
      this.processing = false;
    }
    const event = {
      id: randomUUID(),
      type,
      timestamp: new Date().toISOString(),
      data,
      ...extra,
    };
    if (/^(user_input|elicitation)\.(requested|completed)$/.test(type)) {
      this.questionEvents.push(event);
    }
    if (!deliver) return event;
    const pending = [];
    for (const listener of this.namedListeners.get(type) ?? []) {
      pending.push(listener(event));
    }
    for (const listener of this.genericListeners) {
      pending.push(listener(event));
    }
    await Promise.all(pending.filter((value) => value?.then));
    return event;
  }

  async getEvents() {
    return this.history;
  }

  async abort() {
    return this.abortHandler();
  }
}

function uuid() {
  return randomUUID();
}

function saveEnvironment(keys) {
  return Object.fromEntries(keys.map((key) => [key, process.env[key]]));
}

function restoreEnvironment(saved) {
  for (const [key, value] of Object.entries(saved)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
}

function removeAddedProcessListeners(before) {
  for (const event of Object.keys(before)) {
    for (const listener of process.rawListeners(event)) {
      if (before[event].has(listener)) continue;
      process.removeListener(event, listener.listener ?? listener);
    }
  }
}

async function waitFor(predicate, message, timeoutMs = 2_000) {
  const deadline = originalDateNow() + timeoutMs;
  while (originalDateNow() <= deadline) {
    const value = predicate();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.fail(message);
}

async function createRuntime(t, configure = () => {}) {
  const root = join(runtimeParent, uuid());
  const sessions = join(root, "sessions");
  realMkdirSync(sessions, { recursive: true });
  const runtime = {
    root,
    sessions,
    appSessionId: uuid(),
    copilotSessionId: uuid(),
    watchCallback: null,
    intervalCallback: null,
    failWrite: null,
    activityWrites: [],
    durableReadsFinished: 0,
  };
  runtime.session = new FakeSession(runtime.copilotSessionId);
  configure(runtime.session, runtime);
  runtimes.add(runtime);

  const environmentKeys = [
    "COPILOT_PROJECTS_SESSION",
    "COPILOT_PROJECTS_SOCKET",
    "COPILOT_EXTENSION_PARENT_PID",
    "COPILOT_HOME",
    "HOME",
  ];
  const savedEnvironment = saveEnvironment(environmentKeys);
  const listenersBefore = Object.fromEntries(
    ["SIGTERM", "SIGINT", "exit"].map((event) => [
      event,
      new Set(process.rawListeners(event)),
    ])
  );
  const savedSetInterval = globalThis.setInterval;
  const savedClearInterval = globalThis.clearInterval;
  process.env.COPILOT_PROJECTS_SESSION = runtime.appSessionId;
  process.env.COPILOT_PROJECTS_SOCKET = join(root, "dtach.sock");
  delete process.env.COPILOT_EXTENSION_PARENT_PID;
  process.env.COPILOT_HOME = join(root, "copilot-home");
  process.env.HOME = join(root, "home");
  globalThis.__copilotProjectsTrackerSession = runtime.session;
  globalThis.setInterval = (callback) => {
    runtime.intervalCallback = callback;
    return { unref() {} };
  };
  globalThis.clearInterval = () => {};

  runtime.snapshotPath = join(sessions, `${runtime.appSessionId}.agent-activity.json`);
  runtime.userInputPath = join(sessions, `${runtime.appSessionId}.user-input-response.json`);
  runtime.elicitationPath = join(sessions, `${runtime.appSessionId}.elicitation-response.json`);
  runtime.modelPath = join(sessions, `${runtime.appSessionId}.set-model-request.json`);
  runtime.ownerPath = join(sessions, `${runtime.appSessionId}.transcript-owner.json`);
  try {
    await import(`${pathToFileURL(extensionPath).href}?runtime=${uuid()}`);
    await waitFor(
      () => realExistsSync(runtime.snapshotPath),
      "tracker did not publish its initial snapshot"
    );
    await waitFor(
      () => readSnapshot(runtime).availableModels?.length === 1,
      "tracker did not publish the fake SDK model catalog"
    );
    await waitFor(
      () => readSnapshot(runtime).workflow?.observedAtMilliseconds > 0,
      "tracker did not settle its initial workflow observation"
    );
  } finally {
    globalThis.setInterval = savedSetInterval;
    globalThis.clearInterval = savedClearInterval;
    delete globalThis.__copilotProjectsTrackerSession;
    restoreEnvironment(savedEnvironment);
    removeAddedProcessListeners(listenersBefore);
  }

  t.after(() => {
    runtimes.delete(runtime);
    realRmSync(root, { recursive: true, force: true });
  });
  return runtime;
}

function readSnapshot(runtime) {
  return JSON.parse(realReadFileSync(runtime.snapshotPath, "utf8"));
}

test("scheduled activity does not accept late intents while its agents drain", async (t) => {
  const runtime = await createRuntime(t);
  const emit = (...args) => runtime.session.emit(...args);
  await emit("user.message", { content: "Scheduled check", source: "schedule-check" });
  await emit("assistant.turn_start", { turnId: "0" });
  await emit("assistant.intent", { intent: "Checking the build" });
  assert.equal(readSnapshot(runtime).currentIntent, "Checking the build");
  await emit("subagent.started", { agentDisplayName: "Build" }, { agentId: "build" });
  await emit("assistant.idle");
  assert.equal(readSnapshot(runtime).scheduledTurnActive, true);
  await emit("assistant.intent", { intent: "Late stale action" });
  assert.equal(readSnapshot(runtime).currentIntent, "Build");
  await emit("assistant.turn_start", { turnId: "0" });
  await emit("assistant.intent", { intent: "Checking new results" });
  assert.equal(readSnapshot(runtime).currentIntent, "Checking new results");
});

test("live activity follows root intents and clears at work boundaries", async (t) => {
  const runtime = await createRuntime(t);
  const emit = (...args) => runtime.session.emit(...args);
  assert.equal(readSnapshot(runtime).currentIntent, null);
  await emit("assistant.turn_start", { turnId: "0" });
  await emit("assistant.intent", { intent: "  Running\n tests  " });
  assert.equal(readSnapshot(runtime).currentIntent, "Running tests");
  await emit("assistant.intent", { intent: "Child work" }, { agentId: "child" });
  await emit("assistant.turn_start", { turnId: "0" }, { agentId: "child" });
  await emit("assistant.idle", {}, { agentId: "child" });
  await emit("assistant.turn_end", { turnId: "0" });
  await emit("assistant.turn_start", { turnId: "1" });
  assert.equal(readSnapshot(runtime).currentIntent, "Running tests");
  await emit("assistant.intent", { intent: "" });
  assert.equal(readSnapshot(runtime).currentIntent, null);
  await emit("assistant.intent", { intent: "x".repeat(2000) });
  assert.equal(readSnapshot(runtime).currentIntent.length, 512);
  await emit("assistant.intent", { intent: " \n\t " });
  assert.equal(readSnapshot(runtime).currentIntent, null);
  await emit("assistant.intent", { intent: "Reviewing changes" });
  await emit("assistant.turn_start", { turnId: "0" });
  assert.equal(readSnapshot(runtime).currentIntent, null);
  await emit("assistant.intent", { intent: "Checking results" });
  await emit("subagent.started", { agentDisplayName: "Reviewer" }, { agentId: "reviewer" });
  await emit("assistant.idle");
  assert.equal(readSnapshot(runtime).currentIntent, "Reviewer");
  await emit("assistant.intent", { intent: "Late stale action" });
  assert.equal(readSnapshot(runtime).currentIntent, "Reviewer");
  await emit("session.idle");
  assert.equal(readSnapshot(runtime).currentIntent, null);
  await emit("assistant.turn_start", { turnId: "0" });
  await emit("assistant.intent", { intent: "Old work" });
  await emit("user.message", { content: "New work" });
  assert.equal(readSnapshot(runtime).currentIntent, null);
  await emit("assistant.intent", { intent: "Other old work" });
  runtime.session.sessionId = uuid();
  await emit("session.start", { sessionId: runtime.session.sessionId });
  assert.equal(readSnapshot(runtime).currentIntent, null);
});

test("background status uses short task descriptions and follows the remaining agents", async (t) => {
  const runtime = await createRuntime(t);
  const emit = (...args) => runtime.session.emit(...args);
  await emit("assistant.turn_start", { turnId: "0" });
  await emit("assistant.intent", { intent: "Starting the preview" });
  await emit("subagent.started", {
    agentName: "task",
    agentDisplayName: "UX activity preview",
    agentDescription: "  Previewing background\nactivity indicator  ",
    prompt: "This full task prompt must not become the status",
  }, { agentId: "preview" });
  assert.equal(readSnapshot(runtime).currentIntent, "Starting the preview");
  await emit("assistant.idle");
  assert.equal(readSnapshot(runtime).currentIntent, "Previewing background activity indicator");
  await emit("assistant.intent", { intent: "Child inner activity" }, { agentId: "preview" });
  assert.equal(readSnapshot(runtime).currentIntent, "Previewing background activity indicator");
  await emit("subagent.started", {
    agentDisplayName: "Review",
    agentDescription: "Checking test results",
  }, { agentId: "review" });
  assert.equal(readSnapshot(runtime).currentIntent, "Previewing background activity indicator (+1 more)");
  await emit("subagent.completed", {}, { agentId: "preview" });
  assert.equal(readSnapshot(runtime).currentIntent, "Checking test results");
  await emit("subagent.failed", {}, { agentId: "review" });
  assert.equal(readSnapshot(runtime).currentIntent, null);
});

test("unknown background tasks do not hide useful labels or leak MCP task prompts", async (t) => {
  const runtime = await createRuntime(t);
  const emit = (...args) => runtime.session.emit(...args);
  await emit("assistant.turn_start", {}, { agentId: "unknown" });
  assert.equal(readSnapshot(runtime).currentIntent, "Waiting for background agents");
  await emit("subagent.started", {
    agentDisplayName: " \n ", agentDescription: "\t",
  }, { agentId: "blank" });
  assert.equal(readSnapshot(runtime).currentIntent, "Waiting for background agents");
  await emit("subagent.started", {
    agentName: "mcp-task",
    agentDisplayName: "  Looking up documentation ",
    agentDescription: "Full prompt with private task details",
  }, { agentId: "mcp" });
  assert.equal(readSnapshot(runtime).currentIntent, "Looking up documentation (+2 more)");
  assert.equal(readSnapshot(runtime).workflow.agents.find((agent) => agent.id === "mcp").description, "");
  await emit("assistant.idle", {}, { agentId: "mcp" });
  assert.equal(readSnapshot(runtime).currentIntent, "Waiting for background agents");
  await emit("assistant.idle", {}, { agentId: "unknown" });
  await emit("assistant.idle", {}, { agentId: "blank" });
  assert.equal(readSnapshot(runtime).currentIntent, null);
});

test("background descriptions stay bounded and never become the next root intent", async (t) => {
  const runtime = await createRuntime(t);
  const emit = (...args) => runtime.session.emit(...args);
  await emit("subagent.started", { agentDescription: "x".repeat(600) }, { agentId: "first" });
  await emit("subagent.started", { agentDisplayName: "Second task" }, { agentId: "second" });
  assert.equal(readSnapshot(runtime).currentIntent.length, 512);
  assert.ok(readSnapshot(runtime).currentIntent.endsWith(" (+1 more)"));
  await emit("assistant.turn_start", { turnId: "1" });
  assert.equal(readSnapshot(runtime).currentIntent, null);
  await emit("assistant.intent", { intent: "Coordinating the next step" });
  assert.equal(readSnapshot(runtime).currentIntent, "Coordinating the next step");
  await emit("assistant.idle");
  assert.equal(readSnapshot(runtime).currentIntent.length, 512);
  await emit("user.message", { content: "Scheduled check", source: "schedule-check" });
  assert.equal(readSnapshot(runtime).currentIntent, null);
  await emit("assistant.turn_start", { turnId: "0" });
  await emit("assistant.idle");
  await emit("assistant.idle", {}, { agentId: "first" });
  assert.equal(readSnapshot(runtime).currentIntent, "Second task");
  await emit("session.idle");
  assert.equal(readSnapshot(runtime).currentIntent, null);
  await emit("subagent.started", { agentDescription: "Previous conversation" }, { agentId: "old" });
  assert.equal(readSnapshot(runtime).currentIntent, "Previous conversation");
  runtime.session.sessionId = uuid();
  await emit("session.start", { sessionId: runtime.session.sessionId });
  assert.equal(readSnapshot(runtime).currentIntent, null);
});

function receipt(runtime, operationId) {
  return readSnapshot(runtime).operationReceipts.find(
    (entry) => entry.operationId === operationId
  );
}

function writeHandoff(runtime, path, payload) {
  realWriteFileSync(path, JSON.stringify(payload), { mode: 0o600 });
}

function trigger(runtime, filename) {
  assert.equal(typeof runtime.watchCallback, "function");
  runtime.watchCallback("rename", filename);
}

function operationFields(runtime, kind, operationId = `operation-${uuid()}`, fill = "a") {
  const snapshot = readSnapshot(runtime);
  return {
    operationId,
    conversationEpoch: snapshot.conversationEpoch,
    kind,
    payloadFingerprint: fill.repeat(64),
  };
}

async function workflowReady(runtime) {
  return waitFor(() => {
    const workflow = readSnapshot(runtime).workflow;
    return workflow?.capabilities.includes("session-send") && workflow.sendReady && workflow;
  }, "native workflow did not become available");
}

function workflowHandoff(runtime, kind, action, fields = operationFields(runtime, kind)) {
  const path = join(runtime.sessions, `${runtime.appSessionId}.${kind}.json`);
  const payload = {
    schemaVersion: 1, copilotSessionId: readSnapshot(runtime).copilotSessionId,
    ...fields, action: { kind, ...action },
  };
  writeHandoff(runtime, path, payload);
  trigger(runtime, `${runtime.appSessionId}.${kind}.json`);
  return { path, payload, operationId: fields.operationId };
}

test("native send uses explicit owner and mode, and exact replay cannot submit twice", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await workflowReady(runtime);
  for (const mode of ["enqueue", "immediate"]) {
    const request = workflowHandoff(runtime, "session-send", { prompt: "Keep my desktop draft", mode });
    await waitFor(() => receipt(runtime, request.operationId)?.state === "applied", "send not accepted");
    const count = runtime.session.workflowCalls.length;
    writeHandoff(runtime, request.path, request.payload);
    trigger(runtime, `${runtime.appSessionId}.session-send.json`);
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.equal(runtime.session.workflowCalls.length, count);
    const call = runtime.session.workflowCalls.at(-1);
    assert.equal(call.method, "session.send");
    assert.equal(call.sessionId, runtime.copilotSessionId);
    assert.equal(call.mode, mode);
    assert.equal(call.prompt, "Keep my desktop draft");
    assert.equal(Object.hasOwn(call, "source"), false);
  }
  assert.deepEqual(runtime.session.closeCalls, []);
});

test("native send receipts survive long disconnects without replaying messages", {
  concurrency: false,
}, async (t) => {
  let clock = originalDateNow();
  Date.now = () => clock;
  t.after(() => { Date.now = originalDateNow; });
  for (const mode of ["enqueue", "immediate"]) {
    const runtime = await createRuntime(t);
    await workflowReady(runtime);
    const request = workflowHandoff(runtime, "session-send", { prompt: "Send once", mode });
    await waitFor(() => receipt(runtime, request.operationId)?.state === "applied", "send not accepted");
    const applied = receipt(runtime, request.operationId);

    clock += 6 * 60 * 60 * 1_000;
    runtime.intervalCallback();
    await waitFor(
      () => readSnapshot(runtime).workflow?.observedAtMilliseconds === clock,
      "workflow did not refresh after reconnect"
    );
    await workflowReady(runtime);
    assert.deepEqual(receipt(runtime, request.operationId), applied);

    writeHandoff(runtime, request.path, request.payload);
    trigger(runtime, `${runtime.appSessionId}.session-send.json`);
    await waitFor(() => !realExistsSync(request.path), "replayed handoff was not acknowledged");
    assert.deepEqual(receipt(runtime, request.operationId), applied);
    assert.equal(runtime.session.workflowCalls.filter((call) => call.method === "session.send").length, 1);

    runtime.session.sessionId = uuid();
    await runtime.session.emit("session.start", { sessionId: runtime.session.sessionId });
    assert.equal(receipt(runtime, request.operationId), undefined);
    writeHandoff(runtime, request.path, request.payload);
    trigger(runtime, `${runtime.appSessionId}.session-send.json`);
    await waitFor(() => !realExistsSync(request.path), "old-conversation handoff was not discarded");
    assert.equal(runtime.session.workflowCalls.filter((call) => call.method === "session.send").length, 1);
  }
});

test("screenshots are captured as blobs for the exact conversation and cannot replay", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.modelListHandler = async () => ({ list: [{
      id: "gpt-5.6-sol", capabilities: {
        supports: { vision: true },
        limits: { vision: { max_prompt_images: 4, max_prompt_image_size: 2097152,
          supported_media_types: ["image/png", "image/jpeg"] } },
      },
    }] });
  });
  await workflowReady(runtime);
  const id = uuid();
  const bytes = Buffer.from("fixture image bytes");
  const directory = join(runtime.sessions, "attachments-v1");
  realMkdirSync(directory);
  const fields = operationFields(runtime, "session-send");
  const metadata = {
    id, sessionId: runtime.appSessionId, conversationEpoch: fields.conversationEpoch,
    mimeType: "image/png", byteCount: bytes.length, expiresAtMilliseconds: Date.now() + 60000,
  };
  realWriteFileSync(join(directory, `${id}.image`), bytes);
  realWriteFileSync(join(directory, `${id}.json`), JSON.stringify({
    attachment: metadata, sha256: createHash("sha256").update(bytes).digest("hex"),
  }));
  const request = workflowHandoff(runtime, "session-send", {
    prompt: "Inspect this screenshot", mode: "enqueue", attachmentIds: [id],
  }, fields);
  trigger(runtime, `${runtime.appSessionId}.session-send.json`);
  await waitFor(() => receipt(runtime, request.operationId)?.state === "applied", "attachment not delivered");
  const sends = runtime.session.workflowCalls.filter((call) => call.method === "session.send");
  assert.equal(sends.length, 1);
  assert.equal(sends[0].sessionId, runtime.copilotSessionId);
  assert.equal(sends[0].attachments[0].data, bytes.toString("base64"));
  assert.equal(sends[0].attachments[0].type, "blob");
  realRmSync(directory, { recursive: true });
  writeHandoff(runtime, request.path, request.payload);
  trigger(runtime, `${runtime.appSessionId}.session-send.json`);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(runtime.session.workflowCalls.filter((call) => call.method === "session.send").length, 1);
});

test("missing images, foreign epochs, and unsupported models reject the whole prompt", {
  concurrency: false,
}, async (t) => {
  for (const scenario of ["missing", "foreign", "model"]) {
    const runtime = await createRuntime(t, (session) => {
      session.modelListHandler = async () => ({ list: [{
        id: "gpt-5.6-sol", capabilities: {
          supports: { vision: scenario !== "model" },
          limits: { vision: { max_prompt_images: 4, max_prompt_image_size: 2097152,
            supported_media_types: ["image/png"] } },
        },
      }] });
    });
    await workflowReady(runtime);
    const id = uuid(), directory = join(runtime.sessions, "attachments-v1");
    realMkdirSync(directory);
    if (scenario === "foreign") {
      realWriteFileSync(join(directory, `${id}.json`), JSON.stringify({
        attachment: { id, sessionId: runtime.appSessionId, conversationEpoch: "other" },
      }));
    }
    const request = workflowHandoff(runtime, "session-send", {
      prompt: "Must never send text alone", mode: "immediate", attachmentIds: [id],
    });
    await waitFor(() => receipt(runtime, request.operationId)?.state === "rejected", scenario);
    assert.equal(runtime.session.workflowCalls.some((call) => call.method === "session.send"), false);
  }
});

test("native stop is independent of an unresolved send and never closes the terminal", {
  concurrency: false,
}, async (t) => {
  let completeSend;
  const runtime = await createRuntime(t, (session) => {
    session.sendHandler = () => new Promise((resolve) => { completeSend = resolve; });
  });
  await workflowReady(runtime);
  const send = workflowHandoff(runtime, "session-send", { prompt: "work", mode: "enqueue" });
  await waitFor(() => completeSend, "send not invoked");
  const stop = workflowHandoff(runtime, "session-abort", {});
  await waitFor(() => receipt(runtime, stop.operationId)?.state === "applied", "stop blocked behind send");
  assert.deepEqual(runtime.session.closeCalls, []);
  completeSend({ messageId: "accepted-send" });
  await waitFor(() => receipt(runtime, send.operationId)?.state === "applied", "send outcome missing");
});

test("native sends are fenced by permissions and budget decisions", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await workflowReady(runtime);
  await runtime.session.emit("permission.requested", { requestId: "permission-1" });
  const permission = workflowHandoff(runtime, "session-send", { prompt: "continue", mode: "immediate" });
  await waitFor(() => receipt(runtime, permission.operationId)?.state === "rejected", "permission fence missing");
  await runtime.session.emit("permission.completed", { requestId: "permission-1" });
  await runtime.session.emit("session_limits_exhausted.requested", {
    requestId: "budget-1", usedAiCredits: 32, maxAiCredits: 30,
  });
  const budget = workflowHandoff(runtime, "session-send", { prompt: "continue", mode: "enqueue" });
  await waitFor(() => receipt(runtime, budget.operationId)?.state === "rejected", "budget fence missing");
  assert.equal(runtime.session.workflowCalls.filter((call) => call.method === "session.send").length, 0);
});

test("native actions after rotation never use the SDK's stale join-time session", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await workflowReady(runtime);
  const old = operationFields(runtime, "session-send");
  const next = uuid();
  runtime.session.foregroundSessionId = next;
  await runtime.session.emit("session.start", { sessionId: next });
  await workflowReady(runtime);
  const action = workflowHandoff(runtime, "session-send", { prompt: "new conversation", mode: "enqueue" });
  await waitFor(() => receipt(runtime, action.operationId)?.state === "applied", "rotated send missing");
  assert.equal(runtime.session.workflowCalls.at(-1).sessionId, next);
  const count = runtime.session.workflowCalls.length;
  workflowHandoff(runtime, "session-send", { prompt: "old conversation", mode: "enqueue" }, old);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(runtime.session.workflowCalls.length, count);
});

test("old runtime and missing budget metadata never advertise unsupported controls", {
  concurrency: false,
}, async (t) => {
  const old = await createRuntime(t, (session) => {
    session.statusHandler = async () => ({ version: "1.0.70", protocolVersion: 3 });
  });
  await waitFor(() => readSnapshot(old).workflow?.error, "missing unsupported state");
  assert.deepEqual(readSnapshot(old).workflow.capabilities, []);
  assert.equal(readSnapshot(old).workflow.legacyPromptFallback, true);
  const current = await createRuntime(t, (session) => {
    session.metadataHandler = async ({ sessionId }) => ({ sessionId, isRemote: false });
  });
  await workflowReady(current);
  assert.equal(readSnapshot(current).workflow.capabilities.includes("set-session-budget"), false);
});

test("unknown native outcomes are not replayed and missing methods disable only their action", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.sendHandler = async () => { throw new Error("reply lost"); };
  });
  await workflowReady(runtime);
  const request = workflowHandoff(runtime, "session-send", { prompt: "once", mode: "enqueue" });
  await waitFor(() => receipt(runtime, request.operationId)?.state === "indeterminate", "unknown not preserved");
  writeHandoff(runtime, request.path, request.payload);
  trigger(runtime, `${runtime.appSessionId}.session-send.json`);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(runtime.session.workflowCalls.filter((call) => call.method === "session.send").length, 1);
  runtime.session.sendHandler = async () => {
    throw Object.assign(new Error("method not found"), { code: -32601 });
  };
  const absent = workflowHandoff(runtime, "session-send", { prompt: "not supported", mode: "enqueue" });
  await waitFor(() => receipt(runtime, absent.operationId)?.state === "rejected", "missing method not rejected");
  assert.equal(readSnapshot(runtime).workflow.capabilities.includes("session-send"), false);
  assert.equal(readSnapshot(runtime).workflow.capabilities.includes("session-abort"), true);
});

test("budget changes read back the exact limit and answers use the current pending id", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await workflowReady(runtime);
  const invalid = workflowHandoff(runtime, "set-session-budget", { maxAiCredits: 1 });
  await waitFor(() => receipt(runtime, invalid.operationId)?.state === "rejected", "invalid minimum accepted");
  const set = workflowHandoff(runtime, "set-session-budget", { maxAiCredits: 30 });
  await waitFor(() => receipt(runtime, set.operationId)?.state === "applied", "budget change not verified");
  assert.deepEqual(runtime.session.sessionLimits, { maxAiCredits: 30 });
  await runtime.session.emit("session_limits_exhausted.requested", {
    requestId: "budget-current", usedAiCredits: 31, maxAiCredits: 30,
  });
  const stale = workflowHandoff(runtime, "answer-session-budget", { requestId: "budget-old", additionalAiCredits: 10 });
  await waitFor(() => receipt(runtime, stale.operationId)?.state === "rejected", "stale decision accepted");
  const answer = workflowHandoff(runtime, "answer-session-budget", { requestId: "budget-current", additionalAiCredits: 10 });
  await waitFor(() => receipt(runtime, answer.operationId)?.state === "applied", "budget decision missing");
  const call = runtime.session.workflowCalls.find((entry) =>
    entry.method === "session.ui.handlePendingSessionLimitsExhausted"
  );
  assert.deepEqual(call.response, { action: "add", additionalAiCredits: 10 });
  const unset = workflowHandoff(runtime, "set-session-budget", { maxAiCredits: null });
  await waitFor(() => receipt(runtime, unset.operationId)?.state === "applied", "budget removal missing");
  assert.equal(runtime.session.sessionLimits, null);
});

test("usage uses accumulated runtime totals without summing child or ephemeral usage", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await workflowReady(runtime);
  await runtime.session.emit("assistant.usage", { cost: 90, inputTokens: 100 }, { agentId: uuid() });
  await runtime.session.emit("session.usage_info", { currentTokens: 400, tokenLimit: 1000 });
  assert.equal(readSnapshot(runtime).workflow.totalAiCredits, 2);
  assert.equal(readSnapshot(runtime).workflow.contextTokens, 400);
  runtime.session.usageHandler = async () => { throw new Error("usage unavailable"); };
  await runtime.session.emit("session.usage_checkpoint", { totalNanoAiu: 9e9 });
  await waitFor(() => readSnapshot(runtime).workflow.totalAiCredits === null, "usage failure fabricated a total");
});

test("completed tasks preserve transcripts without diff capture or result sidecars", {
  concurrency: false,
}, async (t) => {
  let diffCalls = 0;
  const runtime = await createRuntime(t, (session) => {
    session.diffHandler = async () => { diffCalls += 1; return null; };
  });
  await workflowReady(runtime);
  const sidecar = join(runtime.sessions, `${runtime.appSessionId}.task-result.json`);
  const transcript = join(runtime.sessions, `${runtime.appSessionId}.transcript.json`);
  for (const status of ["finished", "blocked", "stopped"]) {
    const turnId = uuid();
    await runtime.session.emit("user.message", { content: status }, { id: turnId });
    await runtime.session.emit("assistant.turn_start");
    await runtime.session.emit("tool.execution_start", {
      toolCallId: turnId, toolName: "bash", arguments: { command: "npm test" },
    });
    await runtime.session.emit("tool.execution_complete", {
      toolCallId: turnId, success: true, result: { contents: [{ type: "shell_exit", exitCode: 0 }] },
    });
    await runtime.session.emit("assistant.message", { messageId: turnId, content: `Response: ${status}` });
    await runtime.session.emit("session.task_complete", { summary: status, success: status !== "blocked" });
    await runtime.session.emit("session.idle", { aborted: status === "stopped" });
    await waitFor(() => JSON.parse(realReadFileSync(transcript, "utf8")).turns
      .find((turn) => turn.id === turnId)?.endedAt, "completed turn missing");
    const saved = JSON.parse(realReadFileSync(transcript, "utf8"));
    assert.ok(saved.turns.find((turn) => turn.id === turnId).assistantMessages
      .some((message) => message.content === `Response: ${status}`));
    assert.equal(realExistsSync(sidecar), false);
    assert.equal(diffCalls, 0);
  }
  realWriteFileSync(sidecar, "retained legacy artifact");
  await runtime.session.emit("session.idle");
  const next = uuid();
  runtime.session.foregroundSessionId = next;
  await runtime.session.emit("session.start", { sessionId: next });
  await workflowReady(runtime);
  assert.equal(realReadFileSync(sidecar, "utf8"), "retained legacy artifact");
  assert.equal(diffCalls, 0);
});

test("live deltas are replaced by final messages without duplicate transcript text", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await runtime.session.emit("user.message", { content: "stream" });
  await runtime.session.emit("assistant.message_delta", { messageId: "stream-1", deltaContent: "par" });
  await runtime.session.emit("assistant.message_delta", { messageId: "stream-1", deltaContent: "tial" });
  await runtime.session.emit("assistant.message", { messageId: "stream-1", content: "complete" });
  await runtime.session.emit("session.idle");
  const path = join(runtime.sessions, `${runtime.appSessionId}.transcript.json`);
  await waitFor(() => JSON.parse(realReadFileSync(path, "utf8")).turns.length, "transcript missing");
  const messages = JSON.parse(realReadFileSync(path, "utf8")).turns.at(-1).assistantMessages;
  assert.deepEqual(messages.map((message) => message.content), ["complete"]);
});

test("live transcripts omit blank assistant messages without dropping tools", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await runtime.session.emit("user.message", { content: "review" });
  await runtime.session.emit("assistant.turn_start");
  await runtime.session.emit("assistant.message", { messageId: "reply", content: "Review complete." });
  const blanks = ["", "", " ", "\t", "\n", "\r\n", " \t\n "];
  for (const [index, content] of blanks.entries()) {
    const toolCallId = `tool-${index}`;
    await runtime.session.emit("assistant.message", {
      messageId: `blank-${index}`, content, toolRequests: [{ toolCallId }],
    });
    await runtime.session.emit("tool.execution_start", { toolCallId, toolName: "view" });
    await runtime.session.emit("tool.execution_complete", { toolCallId, success: true });
  }
  const path = join(runtime.sessions, `${runtime.appSessionId}.transcript.json`);
  const turn = await waitFor(() => {
    const turn = JSON.parse(realReadFileSync(path, "utf8")).turns.at(-1);
    return turn?.tools.length === blanks.length && turn.tools.every((tool) => tool.success) && turn;
  }, "tool-only messages did not reach the live transcript");
  assert.equal(turn.endedAt, null);
  assert.deepEqual(turn.assistantMessages.map(({ id, content }) => ({ id, content })), [
    { id: "reply", content: "Review complete." },
  ]);
  await runtime.session.emit("session.idle");
  const completed = await waitFor(() => {
    const turn = JSON.parse(realReadFileSync(path, "utf8")).turns.at(-1);
    return turn?.endedAt && turn;
  }, "completed transcript missing");
  assert.deepEqual(completed.assistantMessages, turn.assistantMessages);
  assert.deepEqual(completed.tools, turn.tools);
});

test("blank live deltas preserve whitespace and identity when text arrives", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await runtime.session.emit("user.message", { content: "stream" });
  await runtime.session.emit("assistant.turn_start");
  await runtime.session.emit("assistant.message_delta", { messageId: "stream", deltaContent: " \n" });
  await runtime.session.emit("tool.execution_start", { toolCallId: "marker", toolName: "view" });
  const path = join(runtime.sessions, `${runtime.appSessionId}.transcript.json`);
  const readTurn = () => JSON.parse(realReadFileSync(path, "utf8")).turns.at(-1);
  await waitFor(() => readTurn()?.tools.length === 1, "live transcript not published");
  assert.deepEqual(readTurn().assistantMessages, []);

  await runtime.session.emit("assistant.message_delta", { messageId: "stream", deltaContent: "Reply" });
  await waitFor(() => readTurn().assistantMessages.some((message) => message.content === " \nReply"),
    "leading whitespace or streamed text was lost", 4_000);
  const finalContent = " \nReply complete.\n";
  await runtime.session.emit("assistant.message", { messageId: "stream", content: finalContent });
  await waitFor(() => readTurn().assistantMessages.some((message) => message.content === finalContent),
    "final text did not replace streamed text");
  assert.deepEqual(readTurn().assistantMessages.map(({ id, content }) => ({ id, content })), [
    { id: "stream", content: finalContent },
  ]);

  await runtime.session.emit("assistant.message_delta", { messageId: "discarded", deltaContent: "partial" });
  await waitFor(() => readTurn().assistantMessages.some((message) => message.id === "discarded"),
    "partial text missing", 4_000);
  await runtime.session.emit("assistant.message", { messageId: "discarded", content: "" });
  await waitFor(() => !readTurn().assistantMessages.some((message) => message.id === "discarded"),
    "empty final message left a stale partial or blank bubble");
});

test("an unknown native send outcome upgrades when its exact late SDK reply arrives", {
  concurrency: false,
}, async (t) => {
  let finish;
  const runtime = await createRuntime(t, (session) => {
    session.sendHandler = () => new Promise((resolve) => { finish = resolve; });
  });
  await workflowReady(runtime);
  const setTimeout = globalThis.setTimeout;
  globalThis.setTimeout = (callback, delay, ...args) =>
    setTimeout(callback, delay === 10_000 ? 5 : delay, ...args);
  t.after(() => { globalThis.setTimeout = setTimeout; });
  const request = workflowHandoff(runtime, "session-send", { prompt: "once", mode: "enqueue" });
  await waitFor(() => receipt(runtime, request.operationId)?.state === "indeterminate", "deadline not reported");
  finish({ messageId: "late-success" });
  await waitFor(() => receipt(runtime, request.operationId)?.state === "applied", "late authoritative reply lost");
  assert.equal(runtime.session.workflowCalls.filter((call) => call.method === "session.send").length, 1);
});

test("durable history streams the pending turn and live text follows newer input", {
  concurrency: false,
}, async (t) => {
  const event = (id, type, data) => ({ id, type, timestamp: new Date().toISOString(), data });
  const pendingID = uuid();
  const runtime = await createRuntime(t, (session, fixture) => {
    const directory = join(fixture.root, "copilot-home", "session-state", fixture.copilotSessionId);
    realMkdirSync(directory, { recursive: true });
    realWriteFileSync(join(directory, "events.jsonl"), [
      event("old-user", "user.message", { content: "old task" }),
      event("old-final", "assistant.message", { messageId: "old", content: "old result" }),
      event("old-idle", "session.idle", {}),
      event(pendingID, "user.message", { content: "current task" }),
      event("current-start", "assistant.turn_start", {}),
    ].map((entry) => JSON.stringify(entry)).join("\n") + "\n");
  });
  const home = process.env.COPILOT_HOME;
  process.env.COPILOT_HOME = join(runtime.root, "copilot-home");
  t.after(() => {
    if (home === undefined) delete process.env.COPILOT_HOME;
    else process.env.COPILOT_HOME = home;
  });
  await workflowReady(runtime);
  await runtime.session.emit("assistant.message_delta", { messageId: "current", deltaContent: "live text" });
  const transcript = join(runtime.sessions, `${runtime.appSessionId}.transcript.json`);
  await waitFor(() => JSON.parse(realReadFileSync(transcript, "utf8")).turns
    .find((turn) => turn.id === pendingID)?.assistantMessages.some((message) => message.content === "live text"),
  "durable-authoritative transcript did not expose live text", 4_000);
  const liveID = uuid();
  await runtime.session.emit("user.message", { content: "new input before journal catches up" }, { id: liveID });
  await runtime.session.emit("assistant.message_delta", { messageId: "new-live", deltaContent: "new live text" });
  const journal = join(runtime.root, "copilot-home", "session-state", runtime.copilotSessionId, "events.jsonl");
  fs.appendFileSync(journal, [
    event("previous-idle", "session.idle", {}),
    event(liveID, "user.message", { content: "new input before journal catches up" }),
    event("new-start", "assistant.turn_start", {}),
  ].map((entry) => JSON.stringify(entry)).join("\n") + "\n");
  await runtime.session.emit("assistant.message", { messageId: "new-live", content: "new final text" });
  await waitFor(() => JSON.parse(realReadFileSync(transcript, "utf8")).turns
    .find((turn) => turn.id === liveID)?.assistantMessages.some((message) => message.content === "new final text"),
  "live text did not follow the new turn after the journal caught up", 4_000);
  const previousTurn = JSON.parse(realReadFileSync(transcript, "utf8")).turns.find((turn) => turn.id === pendingID);
  assert.equal(previousTurn.assistantMessages.some((message) => message.content.startsWith("new ")), false);
});

function requestClose(runtime) {
  const name = `${runtime.appSessionId}.close-session-request`;
  realWriteFileSync(join(runtime.sessions, name), "");
  trigger(runtime, name);
}

function pendingURLQuestion(requestId = "url-request", toolCallId = "call-url") {
  return {
    requestId,
    toolCallId,
    message: "Paste a URL",
    requestedSchema: {
      type: "object",
      properties: { url: { type: "string", title: "URL" } },
    },
  };
}

function questionEvent(type, data) {
  return { id: uuid(), type, timestamp: new Date().toISOString(), data };
}

function writeDurableQuestion(runtime, question = pendingURLQuestion()) {
  const directory = join(
    runtime.root, "copilot-home", "session-state", runtime.copilotSessionId
  );
  realMkdirSync(directory, { recursive: true });
  const event = {
    id: uuid(),
    type: "tool.execution_start",
    timestamp: "2026-09-01T01:00:00.000Z",
    data: {
      toolName: "ask_user",
      toolCallId: question.toolCallId,
      arguments: {
        message: question.message,
        requestedSchema: { properties: question.requestedSchema.properties },
      },
    },
  };
  const path = join(directory, "events.jsonl");
  realWriteFileSync(path, `${JSON.stringify(event)}\n`);
  return { path, event };
}

test("late attach recovers a free-text form and answers its real request exactly once", {
  concurrency: false,
}, async (t) => {
  const question = pendingURLQuestion();
  let durable;
  const runtime = await createRuntime(t, (session, runtime) => {
    durable = writeDurableQuestion(runtime, question);
    session.pendingQuestionsHandler = async () => ({
      userInputRequests: [], elicitationRequests: [question],
    });
  });
  assert.deepEqual(runtime.session.pendingQuestionCalls, [{
    sessionId: runtime.copilotSessionId,
  }]);
  let snapshot = readSnapshot(runtime);
  assert.equal(snapshot.trackedElicitations.length, 1);
  assert.equal(snapshot.trackedElicitations[0].requestId, question.requestId);
  assert.deepEqual(snapshot.trackedElicitations[0].schema, question.requestedSchema);
  await waitFor(() => runtime.durableReadsFinished > 0, "initial durable read did not finish");
  const readsBefore = runtime.durableReadsFinished;
  realWriteFileSync(durable.path, `${JSON.stringify({ ...durable.event, id: uuid() })}\n`, { flag: "a" });
  const writesBefore = runtime.activityWrites.length;
  const savedEnvironment = saveEnvironment(["COPILOT_HOME"]);
  process.env.COPILOT_HOME = join(runtime.root, "copilot-home");
  try {
    runtime.intervalCallback();
    await waitFor(() => runtime.durableReadsFinished > readsBefore, "durable rescan did not finish");
    await new Promise((resolve) => setImmediate(resolve));
  } finally {
    restoreEnvironment(savedEnvironment);
  }
  const newWrites = runtime.activityWrites.slice(writesBefore);
  assert.ok(newWrites.length > 0);
  assert.ok(newWrites.some((entry) =>
    entry.trackedElicitations.some((request) => request.requestId === question.requestId)
  ));
  assert.ok(newWrites.every((entry) =>
    entry.trackedElicitations.every((request) => !request.requestId.startsWith("synthetic::"))
  ));

  const fields = operationFields(runtime, "answer-elicitation");
  writeHandoff(runtime, runtime.elicitationPath, {
    schemaVersion: 1,
    copilotSessionId: runtime.copilotSessionId,
    requestId: question.requestId,
    action: "accept",
    content: { url: "https://example.com" },
    ...fields,
  });
  trigger(runtime, `${runtime.appSessionId}.elicitation-response.json`);
  await waitFor(() => receipt(runtime, fields.operationId)?.state === "applied", "answer not applied");
  runtime.intervalCallback();
  assert.deepEqual(runtime.session.elicitationCalls, [{
    requestId: question.requestId,
    result: { action: "accept", content: { url: "https://example.com" } },
  }]);
  snapshot = readSnapshot(runtime);
  assert.deepEqual(snapshot.trackedElicitations, []);
});

test("recovery excludes racing completions and preserves live and subagent requests", {
  concurrency: false,
}, async (t) => {
  const childId = uuid();
  const runtime = await createRuntime(t, (session) => {
    session.pendingQuestionsHandler = async () => {
      await session.emit("elicitation.completed", { requestId: "completed" });
      await session.emit("user_input.completed", { requestId: "completed-input" });
      await session.emit("elicitation.requested", { ...pendingURLQuestion("live"), message: "New live prompt" });
      await session.emit("elicitation.requested", pendingURLQuestion("child"), { agentId: childId });
      return {
        userInputRequests: [{ requestId: "completed-input", question: "Old input" }],
        elicitationRequests: [
          pendingURLQuestion("completed"),
          pendingURLQuestion("live"),
          pendingURLQuestion("child"),
          pendingURLQuestion("recovered"),
        ],
      };
    };
  });
  const snapshot = readSnapshot(runtime);
  assert.deepEqual(snapshot.trackedUserInputs, []);
  assert.deepEqual(snapshot.trackedElicitations.map((entry) => entry.requestId), [
    "live", "child", "recovered",
  ]);
  assert.equal(snapshot.trackedElicitations[0].message, "New live prompt");
  assert.equal(snapshot.trackedElicitations[1].agentId, childId);
});

test("conversation rotation discards a stale pending-question snapshot", {
  concurrency: false,
}, async (t) => {
  const nextId = uuid();
  const runtime = await createRuntime(t, (session) => {
    session.pendingQuestionsHandler = async ({ sessionId }) => {
      if (sessionId === nextId) {
        return { userInputRequests: [], elicitationRequests: [pendingURLQuestion("new")] };
      }
      session.sessionId = nextId;
      await session.emit("session.start", { sessionId: nextId });
      return { userInputRequests: [], elicitationRequests: [pendingURLQuestion("old")] };
    };
  });
  await waitFor(() => readSnapshot(runtime).trackedElicitations.some((entry) =>
    entry.requestId === "new"
  ), "new conversation question not recovered");
  assert.equal(readSnapshot(runtime).copilotSessionId, nextId);
  assert.deepEqual(readSnapshot(runtime).trackedElicitations.map((entry) => entry.requestId), ["new"]);
  assert.equal(runtime.session.pendingQuestionCalls.length, 2);
});

test("recovered questions remain cached while another tracker owns publication", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  let finish;
  runtime.session.pendingQuestionsHandler = () => new Promise((resolve) => { finish = resolve; });
  runtime.session.sessionId = uuid();
  await runtime.session.emit("session.start", { sessionId: runtime.session.sessionId });
  await waitFor(() => finish, "recovery query was not issued");
  const owner = JSON.parse(realReadFileSync(runtime.ownerPath, "utf8"));
  realWriteFileSync(runtime.ownerPath, JSON.stringify({ ...owner, pid: process.ppid }));
  const writesBefore = runtime.activityWrites.length;
  finish({ userInputRequests: [], elicitationRequests: [pendingURLQuestion()] });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(runtime.activityWrites.length, writesBefore, "a non-owner published the snapshot");

  realWriteFileSync(runtime.ownerPath, JSON.stringify(owner));
  runtime.intervalCallback();
  assert.deepEqual(readSnapshot(runtime).trackedElicitations.map((entry) => entry.requestId), ["url-request"]);
  assert.equal(runtime.session.pendingQuestionCalls.length, 2, "ownership recovery did not need another RPC");
});

test("recovery never evicts live questions to make room for older snapshots", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.pendingQuestionsHandler = async () => {
      for (let index = 0; index < 50; index += 1) {
        await session.emit("elicitation.requested", pendingURLQuestion(`live-${index}`));
        await session.emit("user_input.requested", { requestId: `input-${index}`, question: "Live input" });
      }
      return {
        userInputRequests: [{ requestId: "older-input", question: "Old input" }],
        elicitationRequests: [pendingURLQuestion("older-form")],
      };
    };
  });
  const snapshot = readSnapshot(runtime);
  assert.equal(snapshot.trackedUserInputs.length, 50);
  assert.equal(snapshot.trackedElicitations.length, 50);
  assert.ok(snapshot.trackedUserInputs.every((entry) => entry.requestId.startsWith("input-")));
  assert.ok(snapshot.trackedElicitations.every((entry) => entry.requestId.startsWith("live-")));
});

test("recovery timeout keeps the terminal prompt and safely ignores a late rejection", {
  concurrency: false,
}, async (t) => {
  let rejectLate;
  const runtime = await createRuntime(t, (session, runtime) => {
    writeDurableQuestion(runtime);
    session.pendingQuestionsHandler = () => new Promise((_, reject) => { rejectLate = reject; });
  });
  assert.equal(readSnapshot(runtime).trackedElicitations[0].mode, "terminal");
  rejectLate(new Error("late RPC rejection"));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(readSnapshot(runtime).trackedElicitations[0].mode, "terminal");
});

test("unsupported or failed recovery keeps the original terminal fallback", {
  concurrency: false,
}, async (t) => {
  for (const error of [
    Object.assign(new Error("method not found"), { code: -32601 }),
    new Error("pending store unavailable"),
  ]) {
    const runtime = await createRuntime(t, (session, runtime) => {
      writeDurableQuestion(runtime);
      session.pendingQuestionsHandler = async () => { throw error; };
    });
    const requests = readSnapshot(runtime).trackedElicitations;
    assert.equal(requests.length, 1);
    assert.equal(requests[0].requestId, "synthetic::durable-ask-user::call-url");
    assert.equal(requests[0].mode, "terminal");
  }
});

test("recovering an unrelated question does not suppress a terminal prompt", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session, runtime) => {
    writeDurableQuestion(runtime);
    session.pendingQuestionsHandler = async () => ({
      userInputRequests: [],
      elicitationRequests: [pendingURLQuestion("other", "different-tool")],
    });
  });
  assert.deepEqual(readSnapshot(runtime).trackedElicitations.map((entry) => entry.requestId), [
    "other", "synthetic::durable-ask-user::call-url",
  ]);
});

test("cursor reads recover text, boolean, choice, and multiselect when live notifications disappear", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.pendingQuestionsHandler = async () => {
      throw Object.assign(new Error("old CLI"), { code: -32601 });
    };
  });
  for (const [kind, field, answer] of [
    ["text", { type: "string" }, "https://example.com"],
    ["boolean", { type: "boolean", default: true }, true],
    ["boolean-other", { type: "boolean", default: true }, "Keep the deferred threads open."],
    ["boolean-other-literal", { type: "boolean" }, "false"],
    ["choice", { type: "string", enum: ["a", "b"] }, "b"],
    ["multiple", { type: "array", items: { type: "string", enum: ["a", "b"] } }, ["a", "b"]],
  ]) {
    const requestId = `missing-${kind}`;
    await runtime.session.emit("elicitation.requested", {
      requestId, toolCallId: `call-${kind}`, message: `Question ${kind}`,
      requestedSchema: { type: "object", properties: { answer: field } },
    }, {}, false);
    runtime.intervalCallback();
    const request = await waitFor(() => readSnapshot(runtime).trackedElicitations
      .find((entry) => entry.requestId === requestId), `missing ${kind} form`);
    assert.deepEqual(request.schema.properties.answer, field);
    const fields = operationFields(runtime, "answer-elicitation");
    writeHandoff(runtime, runtime.elicitationPath, {
      schemaVersion: 1, copilotSessionId: runtime.copilotSessionId,
      requestId, action: "accept", content: { answer }, ...fields,
    });
    trigger(runtime, `${runtime.appSessionId}.elicitation-response.json`);
    await waitFor(() => receipt(runtime, fields.operationId)?.state === "applied", "answer not applied");
    assert.deepEqual(runtime.session.elicitationCalls.at(-1).result.content, { answer });
    await runtime.session.emit("elicitation.completed", { requestId, action: "accept" }, {}, false);
    runtime.intervalCallback();
    await waitFor(() => readSnapshot(runtime).trackedElicitations.length === 0, "answered form remained");
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.equal(runtime.session.elicitationCalls.length, 6);
  assert.ok(runtime.session.questionEventCalls.every((call) =>
    call.sessionId === runtime.copilotSessionId && call.includeEphemeral === true
      && call.types.length === 4 && call.agentScope === "all"
  ));
});

test("cursor catch-up never publishes a question completed on a later page", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    const requested = { id: uuid(), type: "elicitation.requested", timestamp: "2026-09-15T00:00:00Z", data: pendingURLQuestion() };
    const completed = { id: uuid(), type: "elicitation.completed", timestamp: "2026-09-15T00:00:01Z", data: { requestId: "url-request" } };
    session.questionEventHandler = async ({ cursor }) => cursor == null
      ? { events: [requested], cursor: "page-two", hasMore: true, cursorStatus: "ok" }
      : { events: [completed], cursor: "tail", hasMore: false, cursorStatus: "ok" };
  });
  await waitFor(() => runtime.session.questionEventCalls.length === 2, "catch-up did not read both pages");
  await new Promise((resolve) => setImmediate(resolve));
  assert.ok(runtime.activityWrites.every((snapshot) => snapshot.trackedElicitations.length === 0));
});

test("cursor replay cannot resurrect a live completion while reading", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  let finish;
  const question = await runtime.session.emit("elicitation.requested", pendingURLQuestion(), {}, false);
  runtime.session.questionEventHandler = () => new Promise((resolve) => { finish = resolve; });
  runtime.intervalCallback();
  await waitFor(() => finish, "cursor read did not start");
  await runtime.session.emit("elicitation.completed", { requestId: question.data.requestId });
  finish({ events: [question], cursor: "tail", hasMore: false, cursorStatus: "ok" });
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(readSnapshot(runtime).trackedElicitations, []);
});

test("cursor replay cannot resurrect an answer applied while reading", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  const question = await runtime.session.emit("elicitation.requested", pendingURLQuestion());
  let finish;
  runtime.session.questionEventHandler = () => new Promise((resolve) => { finish = resolve; });
  runtime.intervalCallback();
  await waitFor(() => finish, "cursor read did not start");
  const fields = operationFields(runtime, "answer-elicitation");
  writeHandoff(runtime, runtime.elicitationPath, {
    schemaVersion: 1, copilotSessionId: runtime.copilotSessionId,
    requestId: question.data.requestId, action: "accept", content: { url: "https://example.com" }, ...fields,
  });
  trigger(runtime, `${runtime.appSessionId}.elicitation-response.json`);
  await waitFor(() => receipt(runtime, fields.operationId)?.state === "applied", "answer not applied");
  finish({ events: [question], cursor: "tail", hasMore: false, cursorStatus: "ok" });
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(readSnapshot(runtime).trackedElicitations, []);
  assert.equal(runtime.session.elicitationCalls.length, 1);
});

test("cursor rotation ignores old pages and recovers the new conversation", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  const oldId = runtime.copilotSessionId;
  const newId = uuid();
  let finish;
  const nextQuestion = { id: uuid(), type: "elicitation.requested", timestamp: new Date().toISOString(), data: pendingURLQuestion("new") };
  runtime.session.questionEventHandler = ({ sessionId }) => sessionId === oldId
    ? new Promise((resolve) => { finish = resolve; })
    : Promise.resolve({ events: [nextQuestion], cursor: "new-tail", hasMore: false, cursorStatus: "ok" });
  runtime.intervalCallback();
  await waitFor(() => finish, "old read did not start");
  runtime.session.sessionId = newId;
  await runtime.session.emit("session.start", { sessionId: newId });
  await waitFor(() => readSnapshot(runtime).trackedElicitations.some((entry) => entry.requestId === "new"), "new cursor not read");
  finish({ events: [{ ...nextQuestion, data: pendingURLQuestion("old") }], cursor: "old-tail", hasMore: false, cursorStatus: "ok" });
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(readSnapshot(runtime).trackedElicitations.map((entry) => entry.requestId), ["new"]);
});

test("an expired cursor is rebased without applying an incomplete page", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  const question = { id: uuid(), type: "elicitation.requested", timestamp: new Date().toISOString(), data: pendingURLQuestion("expired") };
  runtime.session.questionEventHandler = async () => ({
    events: [question], cursor: "expired-tail", hasMore: false, cursorStatus: "expired",
  });
  runtime.intervalCallback();
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(readSnapshot(runtime).trackedElicitations, []);
  runtime.session.questionEventHandler = async ({ cursor }) => {
    assert.equal(cursor, undefined);
    return { events: [], cursor: "rebased", hasMore: false, cursorStatus: "ok" };
  };
  runtime.intervalCallback();
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(readSnapshot(runtime).trackedElicitations, []);
});

test("cursor recovery has a bounded page budget and retries without skipping events", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  let page = 0;
  runtime.session.questionEventHandler = async () => ({
    events: [], cursor: `page-${++page}`, hasMore: true, cursorStatus: "ok",
  });
  runtime.intervalCallback();
  await waitFor(() => page === 10, "cursor page budget was not reached");
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(page, 10);
  let resumedCursor;
  runtime.session.questionEventHandler = async ({ cursor }) => {
    resumedCursor = cursor;
    return { events: [], cursor: "recovered", hasMore: false, cursorStatus: "ok" };
  };
  runtime.intervalCallback();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(resumedCursor, `page-${page}`);
});

test("cursor reading is single-flight and does not block heartbeat publication", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  let finish;
  runtime.session.questionEventHandler = () => new Promise((resolve) => { finish = resolve; });
  const before = runtime.session.questionEventCalls.length;
  runtime.intervalCallback();
  await waitFor(() => finish, "cursor read did not start");
  const writes = runtime.activityWrites.length;
  runtime.intervalCallback();
  runtime.intervalCallback();
  assert.equal(runtime.session.questionEventCalls.length, before + 1);
  assert.ok(runtime.activityWrites.length > writes);
  finish({ events: [], cursor: "tail", hasMore: false, cursorStatus: "ok" });
  await new Promise((resolve) => setImmediate(resolve));
});

test("a late first cursor response still applies without blocking tracker startup", {
  concurrency: false,
}, async (t) => {
  let finish;
  const runtime = await createRuntime(t, (session) => {
    session.questionEventHandler = () => new Promise((resolve) => { finish = resolve; });
  });
  await new Promise((resolve) => setTimeout(resolve, 2050));
  runtime.intervalCallback();
  assert.equal(runtime.session.questionEventCalls.length, 1);
  finish({
    events: [{ id: uuid(), type: "elicitation.requested", timestamp: new Date().toISOString(), data: pendingURLQuestion("late") }],
    cursor: "tail", hasMore: false, cursorStatus: "ok",
  });
  await waitFor(() => readSnapshot(runtime).trackedElicitations.some((entry) => entry.requestId === "late"), "late response ignored");
});

test("polled completions clear live cards and preserve input completion ownership", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  const childId = uuid();
  await runtime.session.emit("user_input.requested", { requestId: "input", question: "Choose" }, { agentId: childId });
  await runtime.session.emit("elicitation.requested", pendingURLQuestion());
  await runtime.session.emit("user_input.completed", { requestId: "input" }, { agentId: childId }, false);
  await runtime.session.emit("elicitation.completed", { requestId: "url-request", action: "cancel" }, {}, false);
  runtime.intervalCallback();
  await waitFor(() => readSnapshot(runtime).trackedElicitations.length === 0 && readSnapshot(runtime).trackedUserInputs.length === 0, "completed cards remained");
  const completions = readSnapshot(runtime).inputCompletions;
  assert.equal(typeof completions[childId.toLowerCase()], "number");
  assert.equal(typeof completions[runtime.copilotSessionId.toLowerCase()], "number");
});

test("cursor staging retains the newest pending question after old requests exceed the cap", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    for (let index = 0; index < 70; index++) {
      session.questionEvents.push({
        id: uuid(), type: "elicitation.requested", timestamp: new Date().toISOString(),
        data: pendingURLQuestion(`request-${index}`),
      });
    }
    for (let index = 0; index < 69; index++) {
      session.questionEvents.push({
        id: uuid(), type: "elicitation.completed", timestamp: new Date().toISOString(),
        data: { requestId: `request-${index}` },
      });
    }
  });
  await waitFor(() => readSnapshot(runtime).trackedElicitations.length === 1, "newest question not recovered");
  assert.equal(readSnapshot(runtime).trackedElicitations[0].requestId, "request-69");
});

for (const kind of ["elicitation", "user_input"]) {
  test(`cursor staging overflow recovers older unresolved ${kind} questions`, {
    concurrency: false,
  }, async (t) => {
    const runtime = await createRuntime(t, (session) => {
      for (let index = 0; index < 70; index++) {
        const requestId = `request-${index}`;
        session.questionEvents.push(questionEvent(`${kind}.requested`, kind === "elicitation"
          ? pendingURLQuestion(requestId) : { requestId, question: "Choose", choices: ["Go"] }));
      }
      for (let index = 20; index < 70; index++) {
        session.questionEvents.push(questionEvent(`${kind}.completed`, { requestId: `request-${index}` }));
      }
    });
    const field = kind === "elicitation" ? "trackedElicitations" : "trackedUserInputs";
    await waitFor(() => readSnapshot(runtime)[field].length === 20, "older active questions were lost");
    assert.deepEqual(readSnapshot(runtime)[field].map((entry) => entry.requestId),
      Array.from({ length: 20 }, (_, index) => `request-${index}`));
    assert.ok(runtime.activityWrites.every((snapshot) =>
      snapshot[field].every((entry) => Number(entry.requestId.slice(8)) < 20)));
    const reads = runtime.session.questionEventCalls.length;
    runtime.intervalCallback();
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(runtime.session.questionEventCalls.length, reads + 1);
    assert.equal(runtime.session.questionEventCalls.at(-1).cursor, "120");
  });

  test(`a losing ${kind} answer rejects its receipt without reopening the stale question`, {
    concurrency: false,
  }, async (t) => {
    const runtime = await createRuntime(t);
    const requestId = `already-answered-${kind}`;
    const elicitation = kind === "elicitation";
    const data = elicitation ? pendingURLQuestion(requestId)
      : { requestId, question: "Choose", choices: ["Go"] };
    const field = elicitation ? "trackedElicitations" : "trackedUserInputs";
    await runtime.session.emit(`${kind}.requested`, data, {}, false);
    runtime.intervalCallback();
    await waitFor(() => readSnapshot(runtime)[field].length === 1, "missed question was not recovered");
    runtime.session.elicitationHandler = runtime.session.userInputHandler = async () => ({ success: false });
    const fields = operationFields(runtime, elicitation ? "answer-elicitation" : "answer-user-input");
    const path = elicitation ? runtime.elicitationPath : runtime.userInputPath;
    writeHandoff(runtime, path, {
      schemaVersion: 1, copilotSessionId: runtime.copilotSessionId, requestId,
      ...(elicitation ? { action: "accept", content: { url: "https://example.com" } }
        : { answer: "Go", wasFreeform: false }),
      ...fields,
    });
    trigger(runtime, `${runtime.appSessionId}.${elicitation ? "elicitation" : "user-input"}-response.json`);
    await waitFor(() => receipt(runtime, fields.operationId)?.state === "rejected", "losing answer was not rejected");
    assert.equal(receipt(runtime, fields.operationId).errorCode, "rpc-rejected");
    assert.deepEqual(readSnapshot(runtime)[field], []);
    await runtime.session.emit(`${kind}.requested`, data);
    runtime.intervalCallback();
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(readSnapshot(runtime)[field], []);
  });

  test(`a live ${kind} completion frees an overflowed staging slot before the replay tail`, {
    concurrency: false,
  }, async (t) => {
    let finishTail;
    let delayed = false;
    const runtime = await createRuntime(t, (session) => {
      const events = Array.from({ length: 51 }, (_, index) => {
        const requestId = `request-${index}`;
        return questionEvent(`${kind}.requested`, kind === "elicitation"
          ? pendingURLQuestion(requestId) : { requestId, question: "Choose", choices: ["Go"] });
      });
      session.questionEventHandler = async ({ cursor }) => {
        if (cursor === undefined) {
          return { events, cursor: "after-requests", hasMore: true, cursorStatus: "ok" };
        }
        if (!delayed) {
          delayed = true;
          return new Promise((resolve) => { finishTail = resolve; });
        }
        return { events: [], cursor: "tail", hasMore: false, cursorStatus: "ok" };
      };
    });
    await waitFor(() => finishTail, "tail read did not pause");
    await runtime.session.emit(`${kind}.completed`, { requestId: "request-50" });
    finishTail({ events: [], cursor: "tail", hasMore: false, cursorStatus: "ok" });
    const field = kind === "elicitation" ? "trackedElicitations" : "trackedUserInputs";
    await waitFor(() => readSnapshot(runtime)[field].length === 50, "live completion hid an overflow vacancy");
    assert.deepEqual(readSnapshot(runtime)[field].map((entry) => entry.requestId),
      Array.from({ length: 50 }, (_, index) => `request-${index}`));
    assert.equal(runtime.session.questionEventCalls.length, 4);
  });
}

test("overflow replay preserves the page budget across a full retained question window", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    for (let index = 0; index < 70; index++) {
      session.questionEvents.push(questionEvent("elicitation.requested", pendingURLQuestion(`request-${index}`)));
    }
    for (let index = 0; index < 3_976; index++) {
      session.questionEvents.push(questionEvent("elicitation.completed", { requestId: `unrelated-${index}` }));
    }
    for (let index = 20; index < 70; index++) {
      session.questionEvents.push(questionEvent("elicitation.completed", { requestId: `request-${index}` }));
    }
  });
  let previousReads = 0;
  for (let heartbeat = 0; heartbeat < 10; heartbeat++) {
    await new Promise((resolve) => setImmediate(resolve));
    const reads = runtime.session.questionEventCalls.length;
    assert.ok(reads - previousReads <= 10, "replay exceeded the per-heartbeat page budget");
    previousReads = reads;
    if (readSnapshot(runtime).trackedElicitations.length === 20) break;
    assert.deepEqual(readSnapshot(runtime).trackedElicitations, [], "published before the replay reached its tail");
    runtime.intervalCallback();
  }
  assert.equal(readSnapshot(runtime).trackedElicitations.length, 20);
  assert.equal(runtime.session.questionEventCalls.length, 82);
  assert.ok(runtime.activityWrites.every((snapshot) =>
    snapshot.trackedElicitations.every((entry) => Number(entry.requestId.slice(8)) < 20)));
  runtime.intervalCallback();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(runtime.session.questionEventCalls.at(-1).cursor, "4096");
});

test("overflow replay reselects again when later pages introduce new completions", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    for (let index = 0; index < 70; index++) {
      session.questionEvents.push(questionEvent("elicitation.requested", pendingURLQuestion(`request-${index}`)));
    }
    for (let index = 0; index < 31; index++) {
      session.questionEvents.push(questionEvent("elicitation.completed", {
        requestId: index === 30 ? "request-69" : `unrelated-${index}`,
      }));
    }
    const read = session.questionEventHandler;
    session.questionEventHandler = async (params) => {
      const result = await read(params);
      if (session.questionEventCalls.length === 3) {
        for (let index = 20; index < 70; index++) {
          session.questionEvents.push(questionEvent("elicitation.completed", { requestId: `request-${index}` }));
        }
      }
      return result;
    };
  });
  await waitFor(() => readSnapshot(runtime).trackedElicitations.length === 20, "moving replay tail lost active questions");
  assert.equal(runtime.session.questionEventCalls.length, 6);
  assert.ok(runtime.activityWrites.every((snapshot) =>
    snapshot.trackedElicitations.every((entry) => Number(entry.requestId.slice(8)) < 20)));
});

test("overflow replay starts at the captured cursor and stops with fifty genuinely pending questions", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await runtime.session.emit("elicitation.completed", { requestId: "old" }, {}, false);
  runtime.intervalCallback();
  await new Promise((resolve) => setImmediate(resolve));
  const before = runtime.session.questionEventCalls.length;
  for (let index = 0; index < 70; index++) {
    await runtime.session.emit("elicitation.requested", pendingURLQuestion(`request-${index}`), {
      timestamp: "2026-09-15T00:00:00.000Z",
    }, false);
  }
  runtime.intervalCallback();
  await waitFor(() => readSnapshot(runtime).trackedElicitations.length === 50, "bounded pending set not recovered");
  assert.deepEqual(readSnapshot(runtime).trackedElicitations.map((entry) => entry.requestId),
    Array.from({ length: 50 }, (_, index) => `request-${index + 20}`));
  assert.deepEqual(runtime.session.questionEventCalls.slice(before).map((call) => call.cursor), ["1"]);
  runtime.intervalCallback();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(runtime.session.questionEventCalls.length, before + 2);
  assert.equal(runtime.session.questionEventCalls.at(-1).cursor, "71");
});

for (const kind of ["elicitation", "user_input"]) {
  test(`unrelated ${kind} completions cannot keep a full pending set replaying`, {
    concurrency: false,
  }, async (t) => {
    const runtime = await createRuntime(t, (session) => {
      for (let index = 0; index < 70; index++) {
        session.questionEvents.push(questionEvent("elicitation.requested", pendingURLQuestion(`request-${index}`)));
      }
      const read = session.questionEventHandler;
      session.questionEventHandler = async (params) => {
        session.questionEvents.push(questionEvent(`${kind}.completed`, { requestId: uuid() }));
        return read(params);
      };
    });
    await waitFor(() => readSnapshot(runtime).trackedElicitations.length === 50, "unrelated completions prevented publication");
    assert.equal(runtime.session.questionEventCalls.length, 1);
    runtime.intervalCallback();
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(runtime.session.questionEventCalls.length, 2);
    assert.equal(runtime.session.questionEventCalls.at(-1).cursor, "71");
    assert.equal(readSnapshot(runtime).trackedElicitations.length, 50);
  });
}

test("an expired overflow replay discards its old pass state and restarts retained history", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.questionEvents.push(questionEvent("elicitation.completed", { requestId: "old" }));
  });
  const history = (prefix) => [
    ...Array.from({ length: 51 }, (_, index) =>
      questionEvent("elicitation.requested", pendingURLQuestion(`${prefix}-${index}`))),
    ...Array.from({ length: 31 }, (_, index) =>
      questionEvent("elicitation.completed", { requestId: `${prefix}-${index + 20}` })),
  ];
  runtime.session.questionEvents.push(...history("request"));
  const read = runtime.session.questionEventHandler;
  let reads = 0;
  runtime.session.questionEventHandler = async (params) => {
    if (++reads === 2) {
      runtime.session.questionEvents = history("retained");
      return { events: [], cursor: "expired", hasMore: false, cursorStatus: "expired" };
    }
    return read(params);
  };
  runtime.intervalCallback();
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(readSnapshot(runtime).trackedElicitations, []);
  assert.deepEqual(runtime.session.questionEventCalls.slice(1).map((call) => call.cursor), ["1", "1"]);
  runtime.intervalCallback();
  await waitFor(() => readSnapshot(runtime).trackedElicitations.length === 20, "retained questions not recovered");
  assert.deepEqual(readSnapshot(runtime).trackedElicitations.map((entry) => entry.requestId),
    Array.from({ length: 20 }, (_, index) => `retained-${index}`));
  assert.deepEqual(runtime.session.questionEventCalls.slice(3).map((call) => call.cursor), [undefined, undefined]);
});

test("a duplicate live request cannot replace a polled card or reopen a completed request", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  const event = await runtime.session.emit("elicitation.requested", pendingURLQuestion(), {}, false);
  runtime.intervalCallback();
  await waitFor(() => readSnapshot(runtime).trackedElicitations.length === 1, "polled form missing");
  const before = runtime.activityWrites.length;
  await runtime.session.emit("elicitation.requested", { ...event.data, message: "duplicate mutation" });
  assert.equal(readSnapshot(runtime).trackedElicitations[0].message, event.data.message);
  assert.equal(runtime.activityWrites.length, before);
  await runtime.session.emit("elicitation.completed", { requestId: event.data.requestId });
  await runtime.session.emit("elicitation.requested", event.data);
  assert.deepEqual(readSnapshot(runtime).trackedElicitations, []);
});

test("cursor recovery answers a legacy free-text question with no live notifications", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await runtime.session.emit("user_input.requested", {
    requestId: "legacy-text", question: "Which URL?", choices: [], allowFreeform: true,
  }, {}, false);
  runtime.intervalCallback();
  await waitFor(() => readSnapshot(runtime).trackedUserInputs.length === 1, "legacy question missing");
  const fields = operationFields(runtime, "answer-user-input");
  writeHandoff(runtime, runtime.userInputPath, {
    schemaVersion: 1, copilotSessionId: runtime.copilotSessionId, requestId: "legacy-text",
    answer: "https://example.com", wasFreeform: true, ...fields,
  });
  trigger(runtime, `${runtime.appSessionId}.user-input-response.json`);
  await waitFor(() => receipt(runtime, fields.operationId)?.state === "applied", "legacy answer failed");
  assert.deepEqual(runtime.session.userInputCalls, [{
    requestId: "legacy-text", response: { answer: "https://example.com", wasFreeform: true },
  }]);
});

test("cursor recovery replaces only an older card when the pending map is full", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  for (let index = 0; index < 50; index++) {
    await runtime.session.emit("elicitation.requested", pendingURLQuestion(`live-${index}`), {
      timestamp: `2026-09-15T00:00:${String(index).padStart(2, "0")}.000Z`,
    });
  }
  await runtime.session.emit("elicitation.requested", pendingURLQuestion("newest"), {
    timestamp: "2026-09-15T00:01:00.000Z",
  }, false);
  runtime.intervalCallback();
  await waitFor(() => readSnapshot(runtime).trackedElicitations.some((entry) => entry.requestId === "newest"), "newest question was dropped");
  assert.equal(readSnapshot(runtime).trackedElicitations.length, 50);
  assert.ok(!readSnapshot(runtime).trackedElicitations.some((entry) => entry.requestId === "live-0"));
  await runtime.session.emit("elicitation.requested", pendingURLQuestion("older"), {
    timestamp: "2026-09-14T00:00:00.000Z",
  }, false);
  runtime.intervalCallback();
  await new Promise((resolve) => setImmediate(resolve));
  assert.ok(!readSnapshot(runtime).trackedElicitations.some((entry) => entry.requestId === "older"));
});

test("unrelated historical completions do not suppress a terminal-only question", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session, runtime) => {
    writeDurableQuestion(runtime);
    session.questionEvents.push({
      id: uuid(), type: "elicitation.completed", timestamp: "2026-09-15T00:00:00.000Z",
      data: { requestId: "unrelated-completed" },
    });
  });
  assert.equal(readSnapshot(runtime).trackedElicitations[0].requestId, "synthetic::durable-ask-user::call-url");
});

test("a polled real question suppresses its terminal fallback even after a later durable rescan", {
  concurrency: false,
}, async (t) => {
  let durable;
  const runtime = await createRuntime(t, (session, runtime) => {
    durable = writeDurableQuestion(runtime);
    session.questionEvents.push({
      id: uuid(), type: "elicitation.requested", timestamp: "2026-08-31T23:59:59.000Z",
      data: pendingURLQuestion(),
    });
  });
  await waitFor(() => readSnapshot(runtime).trackedElicitations.some((entry) => entry.requestId === "url-request"), "real form missing");
  await waitFor(() => runtime.durableReadsFinished > 0, "durable baseline missing");
  const before = runtime.durableReadsFinished;
  realWriteFileSync(durable.path, `${JSON.stringify({ ...durable.event, id: uuid() })}\n`, { flag: "a" });
  const saved = saveEnvironment(["COPILOT_HOME"]);
  process.env.COPILOT_HOME = join(runtime.root, "copilot-home");
  try {
    runtime.intervalCallback();
    await waitFor(() => runtime.durableReadsFinished > before, "durable rescan missing");
    await new Promise((resolve) => setImmediate(resolve));
  } finally {
    restoreEnvironment(saved);
  }
  assert.deepEqual(readSnapshot(runtime).trackedElicitations.map((entry) => entry.requestId), ["url-request"]);
});

test("invalid cursor pages never advance or publish a partial question", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  const question = { id: uuid(), type: "elicitation.requested", timestamp: new Date().toISOString(), data: pendingURLQuestion() };
  for (const invalid of [
    { events: [question], cursor: "bad", hasMore: false, cursorStatus: "unknown" },
    { events: Array(101).fill(question), cursor: "bad", hasMore: false, cursorStatus: "ok" },
  ]) {
    runtime.session.questionEventHandler = async () => invalid;
    runtime.intervalCallback();
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(readSnapshot(runtime).trackedElicitations, []);
  }
  let lastCursor;
  runtime.session.questionEventHandler = async ({ cursor }) => {
    lastCursor = cursor;
    return { events: [question], cursor: "valid-tail", hasMore: false, cursorStatus: "ok" };
  };
  runtime.intervalCallback();
  await waitFor(() => readSnapshot(runtime).trackedElicitations.length === 1, "valid retry failed");
  assert.equal(lastCursor, "0");
});

async function waitForActivity(runtime, predicate) {
  return waitFor(
    () => predicate(readSnapshot(runtime).runtimeActivity),
    "runtime activity did not settle",
    4_000
  );
}

test("runtime activity distinguishes coordinator iterations from background work", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await waitForActivity(runtime, (activity) => activity?.processing === false);
  const child = uuid();
  await runtime.session.emit("subagent.started", { agentDisplayName: "worker" }, { agentId: child });
  await runtime.session.emit("assistant.turn_start", { turnId: "1" });
  await waitForActivity(runtime, (activity) => activity?.processing === true);
  await runtime.session.emit("assistant.turn_end", { turnId: "1" });
  assert.equal(readSnapshot(runtime).foregroundTurnActive, true);
  assert.equal(readSnapshot(runtime).runtimeActivity.processing, true);
  await runtime.session.emit("assistant.idle");
  await waitForActivity(runtime, (activity) => activity?.processing === false);
  assert.equal(readSnapshot(runtime).foregroundTurnActive, false);
  assert.equal(readSnapshot(runtime).activeSubagents.length, 1);
});

test("a child's idle event cannot idle the coordinator", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await runtime.session.emit("assistant.turn_start");
  await waitForActivity(runtime, (activity) => activity?.processing === true);
  await runtime.session.emit("assistant.idle", {}, { agentId: uuid() });
  assert.equal(readSnapshot(runtime).foregroundTurnActive, true);
  assert.equal(readSnapshot(runtime).runtimeActivity.processing, true);
});

test("late idle query cannot overwrite a new foreground turn", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await waitForActivity(runtime, (activity) => activity?.processing === false);
  let finish;
  runtime.session.processingHandler = () => new Promise((resolve) => { finish = resolve; });
  runtime.intervalCallback();
  await waitFor(() => finish, "idle query did not start");
  await runtime.session.emit("assistant.turn_start");
  const firstNewTurnWrite = runtime.activityWrites.length - 1;
  runtime.session.processingHandler = async () => ({ processing: true });
  finish({ processing: false });
  await waitForActivity(runtime, (activity) => activity?.processing === true);
  assert.ok(runtime.activityWrites.slice(firstNewTurnWrite)
    .every((snapshot) => snapshot.runtimeActivity.processing !== false));
});

test("runtime queries use the new owner even when SDK sessionId still points backward", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await waitForActivity(runtime, (activity) => activity?.processing === false);
  let finishOld;
  const oldId = runtime.copilotSessionId;
  runtime.session.processingHandler = ({ sessionId }) => sessionId === oldId
    ? new Promise((resolve) => { finishOld = resolve; })
    : Promise.resolve({ processing: true });
  runtime.intervalCallback();
  await waitFor(() => finishOld, "old query did not start");
  const next = uuid();
  runtime.session.foregroundSessionId = next;
  runtime.session.processing = true;
  const firstNewCall = runtime.session.runtimeCalls.length;
  await runtime.session.emit("session.start", { sessionId: next });
  await waitFor(() => readSnapshot(runtime).copilotSessionId === next, "owner did not rotate");
  finishOld({ processing: false });
  await waitForActivity(runtime, (activity) => activity?.processing === true);
  assert.ok(runtime.session.runtimeCalls.slice(firstNewCall)
    .every((call) => call.sessionId === next));
  assert.equal(runtime.session.sessionId, oldId);
});

test("runtime failures are unknown and a later observation recovers", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await waitForActivity(runtime, (activity) => activity?.processing === false);
  runtime.session.processingHandler = async () => { throw new Error("injected query failure"); };
  runtime.intervalCallback();
  await waitForActivity(runtime, (activity) => activity?.error?.includes("injected query failure"));
  assert.equal(readSnapshot(runtime).runtimeActivity.processing, null);
  runtime.session.processingHandler = async () => ({ processing: false });
  runtime.intervalCallback();
  await waitForActivity(runtime, (activity) => activity?.processing === false && activity.error === null);
});

test("runtime timeout does not republish the old idle observation as fresh", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await waitForActivity(runtime, (activity) => activity?.processing === false);
  runtime.session.processingHandler = () => new Promise(() => {});
  runtime.intervalCallback();
  await waitForActivity(runtime, (activity) => activity?.error?.includes("timed out"));
  assert.equal(readSnapshot(runtime).runtimeActivity.processing, null);
});

test("unsupported runtime API explicitly retains legacy activity behavior", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.processingHandler = async () => {
      throw Object.assign(new Error("method not found"), { code: -32601 });
    };
  });
  await waitForActivity(runtime, (activity) => activity?.error === "unsupported");
  const calls = runtime.session.runtimeCalls.length;
  runtime.intervalCallback();
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(runtime.session.runtimeCalls.length, calls);
});

test("remote sessions never turn the local processing false into idle authority", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.metadataHandler = async ({ sessionId }) => ({ sessionId, isRemote: true });
  });
  await waitForActivity(runtime, (activity) => activity?.error === "remote");
  assert.equal(readSnapshot(runtime).runtimeActivity.processing, null);
  runtime.session.metadataHandler = async ({ sessionId }) => ({ sessionId, isRemote: false });
  runtime.intervalCallback();
  await waitForActivity(runtime, (activity) => activity?.processing === false);
});

test("mismatched runtime response ownership fails closed", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.metadataHandler = async () => ({ sessionId: uuid(), isRemote: false });
  });
  await waitForActivity(runtime, (activity) => activity?.error?.includes("invalid runtime session metadata"));
  assert.equal(readSnapshot(runtime).runtimeActivity.processing, null);
});

test("idle heartbeats issue one bounded scalar observation without extra snapshot churn", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await waitForActivity(runtime, (activity) => activity?.processing === false);
  const calls = runtime.session.runtimeCalls.length;
  const writes = runtime.activityWrites.length;
  runtime.intervalCallback();
  await waitFor(() => runtime.session.runtimeCalls.length >= calls + 2, "poll did not run");
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(runtime.session.runtimeCalls.length - calls, 2);
  assert.equal(runtime.activityWrites.length - writes, 1);
});

test("only observed input completions certify the matching sender", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await waitForActivity(runtime, (activity) => activity?.processing === false);
  const child = uuid();
  await runtime.session.emit("permission.completed", { requestId: "unseen" }, { agentId: child });
  assert.equal(readSnapshot(runtime).inputCompletions[child], undefined);
  await runtime.session.emit("permission.requested", { requestId: "permission" }, { agentId: child });
  assert.deepEqual(readSnapshot(runtime).pendingPermissionRequestIds, ["permission"]);
  await runtime.session.emit("permission.completed", { requestId: "permission" }, { agentId: child });
  await waitFor(() => readSnapshot(runtime).inputCompletions[child], "completion was not published");
  assert.deepEqual(readSnapshot(runtime).pendingPermissionRequestIds, []);
  assert.equal(readSnapshot(runtime).inputCompletions[runtime.copilotSessionId], undefined);
});

for (const sender of ["root", "child"]) {
  for (const historyMode of ["none", "overlap", "historical request"]) {
    test(`startup permission completion certifies ${sender} with ${historyMode} history`, {
      concurrency: false,
    }, async (t) => {
      let owner;
      let completed;
      const runtime = await createRuntime(t, (session) => {
        owner = sender === "root" ? session.sessionId : uuid();
        const extra = sender === "root" ? {} : { agentId: owner };
        const requested = {
          id: uuid(), type: "permission.requested",
          timestamp: new Date().toISOString(),
          data: { requestId: "startup" }, ...extra,
        };
        completed = {
          ...requested, id: uuid(), type: "permission.completed",
        };
        session.getEvents = async () => {
          if (historyMode !== "historical request") {
            await session.emit(requested.type, requested.data, requested);
          }
          await session.emit(completed.type, completed.data, completed);
          return historyMode === "none" ? [] : [requested, completed];
        };
      });
      await waitForActivity(runtime, (activity) => activity?.processing === false);
      const snapshot = readSnapshot(runtime);
      assert.deepEqual(snapshot.pendingPermissionRequestIds, []);
      assert.deepEqual(snapshot.inputCompletions, {
        [owner]: Date.parse(completed.timestamp),
      });
      await runtime.session.emit(completed.type, completed.data, {
        ...completed, timestamp: new Date(Date.parse(completed.timestamp) + 10).toISOString(),
      });
      assert.deepEqual(readSnapshot(runtime).inputCompletions, snapshot.inputCompletions);
    });
  }
}

test("historical-only and unowned startup permission completions do not certify a sender", {
  concurrency: false,
}, async (t) => {
  const child = uuid();
  const runtime = await createRuntime(t, (session) => {
    const requested = {
      id: uuid(), type: "permission.requested", agentId: child,
      timestamp: new Date().toISOString(), data: { requestId: "historical" },
    };
    session.getEvents = async () => {
      await session.emit("permission.completed", { requestId: "unseen" }, { agentId: child });
      return [requested, { ...requested, id: uuid(), type: "permission.completed" }];
    };
  });
  assert.deepEqual(readSnapshot(runtime).pendingPermissionRequestIds, []);
  assert.deepEqual(readSnapshot(runtime).inputCompletions, {});
});

test("conversation rotation drops old input completion certificates", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  const child = uuid();
  await runtime.session.emit("permission.requested", { requestId: "permission" }, { agentId: child });
  await runtime.session.emit("permission.completed", { requestId: "permission" }, { agentId: child });
  await waitFor(() => readSnapshot(runtime).inputCompletions[child], "completion missing");
  const next = uuid();
  runtime.session.sessionId = next;
  await runtime.session.emit("session.start", { sessionId: next });
  await waitFor(() => readSnapshot(runtime).copilotSessionId === next, "rotation missing");
  assert.deepEqual(readSnapshot(runtime).inputCompletions, {});
});

test("reused child agents leave and rejoin background activity independently of the coordinator", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await waitForActivity(runtime, (activity) => activity?.processing === false);
  const child = uuid();
  await runtime.session.emit("subagent.started", {}, { agentId: child });
  await runtime.session.emit("assistant.idle", {}, { agentId: child });
  assert.deepEqual(readSnapshot(runtime).activeSubagents, []);
  await runtime.session.emit("assistant.turn_start", {}, { agentId: child });
  assert.equal(readSnapshot(runtime).activeSubagents[0].id, child);
  assert.equal(typeof readSnapshot(runtime).activeSubagents[0].name, "string");
  assert.equal(typeof readSnapshot(runtime).activeSubagents[0].description, "string");
  assert.equal(readSnapshot(runtime).foregroundTurnActive, false);
});

test("new child work invalidates whole-session idle without making the coordinator busy", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await runtime.session.emit("session.idle");
  assert.equal(typeof readSnapshot(runtime).sessionIdleAtMilliseconds, "number");
  const child = uuid();
  await runtime.session.emit("assistant.turn_start", {}, { agentId: child });
  assert.equal(readSnapshot(runtime).sessionIdleAtMilliseconds, null);
  assert.equal(readSnapshot(runtime).foregroundTurnActive, false);
  await runtime.session.emit("assistant.idle", {}, { agentId: child });
  assert.equal(readSnapshot(runtime).sessionIdleAtMilliseconds, null);
});

test("background child iteration churn cannot starve coordinator observations", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await waitForActivity(runtime, (activity) => activity?.processing === false);
  const originalObservation = readSnapshot(runtime).runtimeActivity.observedAtMilliseconds;
  const calls = runtime.session.runtimeCalls.length;
  const finishers = [];
  runtime.session.processingHandler = () => new Promise((resolve) => { finishers.push(resolve); });
  await new Promise((resolve) => setTimeout(resolve, 5));
  runtime.intervalCallback();
  await waitFor(() => finishers.length > 0, "query did not start");
  const child = uuid();
  for (let index = 0; index < 20; index += 1) {
    await runtime.session.emit("assistant.turn_start", {}, { agentId: child });
    await runtime.session.emit("permission.requested", { requestId: `auto-${index}` }, { agentId: child });
    await runtime.session.emit("permission.completed", { requestId: `auto-${index}` }, { agentId: child });
    await runtime.session.emit("assistant.idle", {}, { agentId: child });
  }
  finishers[0]({ processing: false });
  await new Promise((resolve) => setTimeout(resolve, 15));
  try {
    assert.equal(runtime.session.runtimeCalls.length - calls, 2);
    runtime.intervalCallback();
    assert.ok(readSnapshot(runtime).runtimeActivity.observedAtMilliseconds > originalObservation);
  } finally {
    for (const finish of finishers) finish({ processing: false });
  }
});

test("a matching completed input wait reissues an older in-flight observation", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await waitForActivity(runtime, (activity) => activity?.processing === false);
  const child = uuid();
  await runtime.session.emit("permission.requested", { requestId: "permission" }, { agentId: child });
  const at = Date.now();
  writeHandoff(runtime, join(runtime.sessions, `${runtime.appSessionId}.status-record.json`), {
    schemaVersion: 1, status: "waiting", statusTimestamp: at, promptStatusTimestamp: at,
    inputWait: {
      senderSessionId: child,
      rootSessionId: runtime.copilotSessionId,
      conversationEpoch: readSnapshot(runtime).conversationEpoch,
    },
  });

  let finishOld;
  runtime.session.processingHandler = () => new Promise((resolve) => { finishOld = resolve; });
  runtime.intervalCallback();
  await waitFor(() => finishOld, "query did not start");
  await runtime.session.emit("permission.completed", { requestId: "permission" }, { agentId: child });
  const completedAt = readSnapshot(runtime).inputCompletions[child];
  runtime.session.processingHandler = async () => ({ processing: false });
  finishOld({ processing: false });
  await waitForActivity(runtime, (activity) =>
    activity?.processing === false && activity.observedAtMilliseconds >= completedAt);
});

test("whole-session idle clears pending permissions before its first publication", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await runtime.session.emit("permission.requested", { requestId: "aborted" }, { agentId: uuid() });
  const before = runtime.activityWrites.length;
  await runtime.session.emit("session.idle", { aborted: true });
  assert.ok(runtime.activityWrites.slice(before)
    .every((snapshot) => snapshot.pendingPermissionRequestIds.length === 0));
});

test("historical scheduled turns do not contaminate live idle classification on close", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.history = [{
      id: uuid(), type: "user.message", timestamp: new Date().toISOString(),
      data: { content: "old scheduled work", source: "schedule-fixture" },
    }, {
      id: uuid(), type: "assistant.turn_end", timestamp: new Date().toISOString(), data: {},
    }];
  });
  // Close still probes abort because history is uncertain, but the resulting
  // idle must not be attributed to a historic scheduled turn.
  requestClose(runtime);
  await waitFor(() => runtime.session.closeCalls.length === 1, "close was not queued");
  assert.equal(readSnapshot(runtime).lastIdleAborted, true);
  assert.equal(readSnapshot(runtime).lastIdleTurnKind, null);
  assert.equal(readSnapshot(runtime).scheduledTurnActive, false);
  assert.equal(runtime.session.closeCalls[0].command, "/exit print");
});

test("permanent close requeues after rotation discards the old session queue", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  requestClose(runtime);
  await waitFor(() => runtime.session.closeCalls.length === 1, "first close was not queued");
  const next = uuid();
  runtime.session.sessionId = next;
  await runtime.session.emit("session.start", { sessionId: next });
  await waitFor(() => runtime.session.closeCalls.length === 2, "rotated close was not queued");
  requestClose(runtime);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.deepEqual(runtime.session.closeCalls.map((call) => call.sessionId),
    [runtime.copilotSessionId, next]);
});

test("late enqueue completion cannot suppress a rotated close or reset its in-flight guard", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  let finishOld;
  let finishNew;
  runtime.session.enqueueHandler = () => new Promise((resolve) => {
    if (!finishOld) finishOld = resolve;
    else finishNew = resolve;
  });
  requestClose(runtime);
  await waitFor(() => finishOld, "old enqueue did not start");
  const next = uuid();
  runtime.session.sessionId = next;
  await runtime.session.emit("session.start", { sessionId: next });
  await waitFor(() => finishNew, "new enqueue did not start");
  finishOld({ queued: true });
  await new Promise((resolve) => setTimeout(resolve, 10));
  requestClose(runtime);
  assert.equal(runtime.session.closeCalls.length, 2);
  finishNew({ queued: true });
  await new Promise((resolve) => setTimeout(resolve, 10));
  requestClose(runtime);
  assert.equal(runtime.session.closeCalls.length, 2);
});

test("late abort completion cannot enqueue another exit into the new conversation", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  let finishAbort;
  runtime.session.abortHandler = () => new Promise((resolve) => { finishAbort = resolve; });
  await runtime.session.emit("user.message", { content: "work", source: null });
  requestClose(runtime);
  await waitFor(() => finishAbort, "abort did not start");
  const next = uuid();
  runtime.session.sessionId = next;
  await runtime.session.emit("session.start", { sessionId: next });
  await waitFor(() => runtime.session.closeCalls.length === 1, "new close did not enqueue");
  await runtime.session.emit("session.idle", { aborted: true });
  finishAbort();
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.deepEqual(runtime.session.closeCalls.map((call) => call.sessionId), [next]);
});

async function emitUserInput(runtime, requestId, choices = ["Go", "Wait"]) {
  await runtime.session.emit("user_input.requested", {
    requestId,
    question: "Continue?",
    choices,
    allowFreeform: false,
  });
}

async function emitElicitation(runtime, requestId) {
  await runtime.session.emit("elicitation.requested", {
    requestId,
    message: "Pick a fruit",
    mode: "form",
    requestedSchema: {
      type: "object",
      properties: { fruit: { type: "string" } },
    },
  });
}

test("all SDK controls preserve legacy behavior and publish correlated receipts", {
  concurrency: false,
}, async (t) => {
  const cases = [
    {
      name: "answer-user-input",
      suffix: "user-input-response.json",
      path: (runtime) => runtime.userInputPath,
      calls: (runtime) => runtime.session.userInputCalls,
      prepare: (runtime, requestId) => emitUserInput(runtime, requestId),
      payload: (runtime, requestId) => ({
        schemaVersion: 1,
        copilotSessionId: runtime.copilotSessionId,
        requestId,
        answer: "Go",
        wasFreeform: false,
      }),
      setHandler: (runtime, handler) => {
        runtime.session.userInputHandler = handler;
      },
    },
    {
      name: "answer-elicitation",
      suffix: "elicitation-response.json",
      path: (runtime) => runtime.elicitationPath,
      calls: (runtime) => runtime.session.elicitationCalls,
      prepare: (runtime, requestId) => emitElicitation(runtime, requestId),
      payload: (runtime, requestId) => ({
        schemaVersion: 1,
        copilotSessionId: runtime.copilotSessionId,
        requestId,
        action: "accept",
        content: { fruit: "apple" },
      }),
      setHandler: (runtime, handler) => {
        runtime.session.elicitationHandler = handler;
      },
    },
    {
      name: "set-model",
      suffix: "set-model-request.json",
      path: (runtime) => runtime.modelPath,
      calls: (runtime) => runtime.session.modelSwitchCalls,
      prepare: async () => {},
      payload: (runtime) => ({
        schemaVersion: 1,
        copilotSessionId: runtime.copilotSessionId,
        modelId: "gpt-5.6-sol",
        reasoningEffort: "high",
        contextTier: "long_context",
      }),
      setHandler: (runtime, handler) => {
        runtime.session.modelSwitchHandler = handler;
      },
    },
  ];

  for (const entry of cases) {
    await t.test(entry.name, async (t) => {
      const runtime = await createRuntime(t);
      let requestId = `request-${uuid()}`;
      await entry.prepare(runtime, requestId);
      const legacy = entry.payload(runtime, requestId);
      writeHandoff(runtime, entry.path(runtime), legacy);
      trigger(runtime, `${runtime.appSessionId}.${entry.suffix}`);
      await waitFor(
        () => entry.calls(runtime).length === 1
          && !realExistsSync(entry.path(runtime)),
        `${entry.name} legacy handoff did not complete`
      );
      assert.deepEqual(readSnapshot(runtime).operationReceipts, []);

      requestId = `request-${uuid()}`;
      await entry.prepare(runtime, requestId);
      const fields = operationFields(runtime, entry.name);
      let acceptedAtRPC = null;
      entry.setHandler(runtime, async (request) => {
        acceptedAtRPC = receipt(runtime, fields.operationId);
        return entry.name === "set-model"
          ? { status: "applied", modelId: request.modelId, deferred: false }
          : { success: true };
      });
      if (entry.name === "set-model") {
        runtime.session.modelListHandler = () => new Promise(() => {});
      }
      writeHandoff(runtime, entry.path(runtime), {
        ...entry.payload(runtime, requestId),
        ...fields,
      });
      trigger(runtime, `${runtime.appSessionId}.${entry.suffix}`);
      await waitFor(
        () => receipt(runtime, fields.operationId)?.state === "applied",
        `${entry.name} did not publish an applied receipt`
      );
      assert.equal(entry.calls(runtime).length, 2);
      assert.equal(acceptedAtRPC?.state, "accepted");
      assert.equal(acceptedAtRPC?.payloadFingerprint, fields.payloadFingerprint);
      assert.equal(realExistsSync(entry.path(runtime)), false);
    });
  }
});

test("accepted publication failure blocks RPC and identical operations deduplicate", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  const requestId = `request-${uuid()}`;
  await emitUserInput(runtime, requestId);
  const fields = operationFields(runtime, "answer-user-input");
  const payload = {
    schemaVersion: 1,
    copilotSessionId: runtime.copilotSessionId,
    requestId,
    answer: "Go",
    wasFreeform: false,
    ...fields,
  };

  runtime.failWrite = (path) => path.includes(".agent-activity.json.");
  writeHandoff(runtime, runtime.userInputPath, payload);
  trigger(runtime, `${runtime.appSessionId}.user-input-response.json`);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(runtime.session.userInputCalls.length, 0);
  assert.equal(realExistsSync(runtime.userInputPath), true);
  assert.equal(receipt(runtime, fields.operationId), undefined);

  runtime.failWrite = null;
  let resolveRPC;
  runtime.session.userInputHandler = () => new Promise((resolve) => {
    resolveRPC = resolve;
  });
  trigger(runtime, `${runtime.appSessionId}.user-input-response.json`);
  await waitFor(
    () => receipt(runtime, fields.operationId)?.state === "accepted"
      && runtime.session.userInputCalls.length === 1,
    "retry did not publish accepted before invoking"
  );
  const acceptedTimestamp = receipt(runtime, fields.operationId).updatedAtMilliseconds;

  trigger(runtime, `${runtime.appSessionId}.user-input-response.json`);
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(runtime.session.userInputCalls.length, 1);
  assert.equal(
    receipt(runtime, fields.operationId).updatedAtMilliseconds,
    acceptedTimestamp
  );

  writeHandoff(runtime, runtime.userInputPath, {
    ...payload,
    answer: "Wait",
    payloadFingerprint: "b".repeat(64),
  });
  trigger(runtime, `${runtime.appSessionId}.user-input-response.json`);
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(runtime.session.userInputCalls.length, 1);
  assert.equal(receipt(runtime, fields.operationId).payloadFingerprint, "a".repeat(64));

  resolveRPC({ success: true });
  await waitFor(
    () => receipt(runtime, fields.operationId)?.state === "applied",
    "original operation did not become applied"
  );
  const appliedTimestamp = receipt(runtime, fields.operationId).updatedAtMilliseconds;
  writeHandoff(runtime, runtime.userInputPath, payload);
  trigger(runtime, `${runtime.appSessionId}.user-input-response.json`);
  await waitFor(
    () => !realExistsSync(runtime.userInputPath),
    "terminal replay did not remove the duplicate handoff"
  );
  assert.equal(runtime.session.userInputCalls.length, 1);
  assert.equal(
    receipt(runtime, fields.operationId).updatedAtMilliseconds,
    appliedTimestamp
  );
});

test("model receipts interpret switchTo metadata without a model event", {
  concurrency: false,
}, async (t) => {
  const target = "gpt-5.6-sol";
  const applied = { status: "applied", modelId: target, deferred: false };
  const cases = [
    ["applied", applied, "applied"],
    ["unchanged", { ...applied, status: "unchanged" }, "applied"],
    ["legacy model id", { modelId: target }, "applied"],
    ["legacy immediate", { modelId: target, deferred: false }, "applied"],
    ["cancelled", { status: "cancelled", deferred: false }, "rejected"],
    ["confirmation", {
      status: "confirmation_required", modelId: "previous", deferred: false,
      confirmation: { currentTokens: 200, targetLimit: 100 },
    }, "rejected"],
    ["deferred", {
      ...applied, modelId: "previous", deferred: true,
    }, "indeterminate"],
    ["deferred same model", { ...applied, deferred: true }, "indeterminate"],
    ["legacy deferred", { modelId: target, deferred: true }, "indeterminate"],
    ["contradictory deferred cancellation", {
      ...applied, status: "cancelled", deferred: true,
    }, "indeterminate"],
    ["different model", { ...applied, modelId: "previous" }, "indeterminate"],
    ["missing model", { status: "applied", deferred: false }, "indeterminate"],
    ["unknown status", { ...applied, status: "queued" }, "indeterminate"],
    ["null status", { ...applied, status: null }, "indeterminate"],
    ["null deferral", { ...applied, deferred: null }, "indeterminate"],
    ["string deferral", { ...applied, deferred: "false" }, "indeterminate"],
    ["missing result", undefined, "indeterminate"],
    ["null result", null, "indeterminate"],
    ["boolean success", { success: true }, "indeterminate"],
    ["boolean failure", { success: false }, "indeterminate"],
    ["RPC exception", new Error("private RPC details"), "indeterminate"],
  ];
  for (const [name, result, state] of cases) {
    await t.test(name, async (t) => {
      const runtime = await createRuntime(t);
      const fields = operationFields(runtime, "set-model");
      let acceptedAtRPC;
      runtime.session.modelSwitchHandler = async () => {
        acceptedAtRPC = receipt(runtime, fields.operationId)?.state;
        if (result instanceof Error) throw result;
        return result;
      };
      const payload = {
        schemaVersion: 1,
        copilotSessionId: runtime.copilotSessionId,
        modelId: target,
        reasoningEffort: "high",
        contextTier: "long_context",
        ...fields,
      };
      writeHandoff(runtime, runtime.modelPath, payload);
      trigger(runtime, `${runtime.appSessionId}.set-model-request.json`);
      await waitFor(
        () => receipt(runtime, fields.operationId)?.state === state,
        `${name} did not publish a ${state} receipt`
      );
      const outcome = receipt(runtime, fields.operationId);
      assert.equal(acceptedAtRPC, "accepted");
      assert.equal(outcome.kind, "set-model");
      assert.equal(outcome.conversationEpoch, fields.conversationEpoch);
      assert.equal(outcome.payloadFingerprint, fields.payloadFingerprint);
      assert.equal(outcome.errorCode, state === "applied" ? undefined
        : state === "rejected" ? "rpc-rejected" : "rpc-indeterminate");
      assert.equal(JSON.stringify(outcome).includes("private RPC details"), false);
      assert.equal(realExistsSync(runtime.modelPath), false);
      assert.deepEqual(runtime.session.modelSwitchCalls, [{
        modelId: target, reasoningEffort: "high", contextTier: "long_context",
      }]);

      writeHandoff(runtime, runtime.modelPath, payload);
      trigger(runtime, `${runtime.appSessionId}.set-model-request.json`);
      await waitFor(
        () => !realExistsSync(runtime.modelPath),
        `${name} did not remove the replayed handoff`
      );
      assert.equal(runtime.session.modelSwitchCalls.length, 1);
      assert.deepEqual(receipt(runtime, fields.operationId), outcome);
    });
  }
});

test("a deferred model event updates the model without guessing its receipt", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  const fields = operationFields(runtime, "set-model");
  runtime.session.modelSwitchHandler = async () => ({
    status: "applied", modelId: "previous", deferred: true,
  });
  writeHandoff(runtime, runtime.modelPath, {
    schemaVersion: 1,
    copilotSessionId: runtime.copilotSessionId,
    modelId: "gpt-5.6-sol",
    reasoningEffort: "high",
    contextTier: "long_context",
    ...fields,
  });
  trigger(runtime, `${runtime.appSessionId}.set-model-request.json`);
  await waitFor(
    () => receipt(runtime, fields.operationId)?.state === "indeterminate",
    "deferred model switch was treated as applied"
  );
  const outcome = receipt(runtime, fields.operationId);
  await runtime.session.emit("session.model_change", {
    newModel: "gpt-5.6-sol", reasoningEffort: "high", contextTier: "long_context",
  });
  assert.deepEqual(readSnapshot(runtime).model, {
    name: "gpt-5.6-sol", reasoningEffort: "high", contextTier: "long_context",
  });
  assert.deepEqual(receipt(runtime, fields.operationId), outcome);
});

test("rotation fences an old model callback from the new conversation handoff", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  const oldFields = operationFields(runtime, "set-model");
  let resolveOld;
  runtime.session.modelSwitchHandler = () => new Promise((resolve) => {
    resolveOld = resolve;
  });
  writeHandoff(runtime, runtime.modelPath, {
    schemaVersion: 1,
    copilotSessionId: runtime.copilotSessionId,
    modelId: "gpt-5.6-sol",
    reasoningEffort: "high",
    contextTier: "long_context",
    ...oldFields,
  });
  trigger(runtime, `${runtime.appSessionId}.set-model-request.json`);
  await waitFor(
    () => receipt(runtime, oldFields.operationId)?.state === "accepted",
    "old conversation model operation was not accepted"
  );

  const oldEpoch = readSnapshot(runtime).conversationEpoch;
  runtime.copilotSessionId = uuid();
  runtime.session.sessionId = runtime.copilotSessionId;
  await runtime.session.emit("session.resume", {
    sessionId: runtime.copilotSessionId,
    selectedModel: "gpt-5.6-sol",
  });
  await waitFor(
    () => readSnapshot(runtime).conversationEpoch !== oldEpoch,
    "conversation epoch did not rotate"
  );
  await waitFor(
    () => readSnapshot(runtime).availableModels?.length === 1,
    "new conversation model catalog did not refresh"
  );
  const newFields = operationFields(runtime, "set-model");
  const newPayload = {
    schemaVersion: 1,
    copilotSessionId: runtime.copilotSessionId,
    modelId: "gpt-5.6-sol",
    reasoningEffort: "high",
    contextTier: "long_context",
    ...newFields,
  };
  writeHandoff(runtime, runtime.modelPath, newPayload);

  resolveOld({ status: "applied", modelId: "gpt-5.6-sol", deferred: false });
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(realExistsSync(runtime.modelPath), true);
  assert.deepEqual(
    JSON.parse(realReadFileSync(runtime.modelPath, "utf8")),
    newPayload
  );
  assert.equal(receipt(runtime, oldFields.operationId), undefined);

  runtime.session.modelSwitchHandler = async (request) => ({
    status: "applied", modelId: request.modelId, deferred: false,
  });
  trigger(runtime, `${runtime.appSessionId}.set-model-request.json`);
  await waitFor(
    () => receipt(runtime, newFields.operationId)?.state === "applied",
    "new conversation model handoff did not complete"
  );
  assert.equal(runtime.session.modelSwitchCalls.length, 2);
});

test("validation, explicit RPC false, and exceptions map to safe terminal states", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);

  const invalidFields = operationFields(runtime, "answer-user-input");
  writeHandoff(runtime, runtime.userInputPath, {
    schemaVersion: 1,
    copilotSessionId: runtime.copilotSessionId,
    requestId: "missing-question",
    answer: "Go",
    wasFreeform: false,
    ...invalidFields,
  });
  trigger(runtime, `${runtime.appSessionId}.user-input-response.json`);
  await waitFor(
    () => receipt(runtime, invalidFields.operationId)?.state === "rejected",
    "invalid request did not become rejected"
  );
  assert.equal(receipt(runtime, invalidFields.operationId).errorCode, "invalid-request");
  assert.equal(runtime.session.userInputCalls.length, 0);

  const falseRequestId = `request-${uuid()}`;
  await emitUserInput(runtime, falseRequestId);
  runtime.session.userInputHandler = async () => ({ success: false });
  const falseFields = operationFields(runtime, "answer-user-input");
  writeHandoff(runtime, runtime.userInputPath, {
    schemaVersion: 1,
    copilotSessionId: runtime.copilotSessionId,
    requestId: falseRequestId,
    answer: "Go",
    wasFreeform: false,
    ...falseFields,
  });
  trigger(runtime, `${runtime.appSessionId}.user-input-response.json`);
  await waitFor(
    () => receipt(runtime, falseFields.operationId)?.state === "rejected",
    "explicit RPC false did not become rejected"
  );
  assert.equal(receipt(runtime, falseFields.operationId).errorCode, "rpc-rejected");

  const missingResultRequestId = `request-${uuid()}`;
  await emitUserInput(runtime, missingResultRequestId);
  runtime.session.userInputHandler = async () => undefined;
  const missingResultFields = operationFields(runtime, "answer-user-input");
  writeHandoff(runtime, runtime.userInputPath, {
    schemaVersion: 1,
    copilotSessionId: runtime.copilotSessionId,
    requestId: missingResultRequestId,
    answer: "Go",
    wasFreeform: false,
    ...missingResultFields,
  });
  trigger(runtime, `${runtime.appSessionId}.user-input-response.json`);
  await waitFor(
    () => receipt(runtime, missingResultFields.operationId)?.state === "indeterminate",
    "an RPC result without explicit success was treated as applied"
  );
  assert.equal(
    receipt(runtime, missingResultFields.operationId).errorCode,
    "rpc-indeterminate"
  );

  const unknownRequestId = `request-${uuid()}`;
  await emitUserInput(runtime, unknownRequestId);
  runtime.session.userInputHandler = async () => {
    throw new Error("secret transport detail");
  };
  const unknownFields = operationFields(runtime, "answer-user-input");
  writeHandoff(runtime, runtime.userInputPath, {
    schemaVersion: 1,
    copilotSessionId: runtime.copilotSessionId,
    requestId: unknownRequestId,
    answer: "Go",
    wasFreeform: false,
    ...unknownFields,
  });
  trigger(runtime, `${runtime.appSessionId}.user-input-response.json`);
  await waitFor(
    () => receipt(runtime, unknownFields.operationId)?.state === "indeterminate",
    "RPC exception did not become indeterminate"
  );
  assert.equal(
    receipt(runtime, unknownFields.operationId).errorCode,
    "rpc-indeterminate"
  );
  assert.equal(
    JSON.stringify(receipt(runtime, unknownFields.operationId))
      .includes("secret transport detail"),
    false
  );

  const durableFields = operationFields(runtime, "answer-elicitation");
  writeHandoff(runtime, runtime.elicitationPath, {
    schemaVersion: 1,
    copilotSessionId: runtime.copilotSessionId,
    requestId: "synthetic::durable-ask-user::call",
    action: "accept",
    content: { value: true },
    ...durableFields,
  });
  trigger(runtime, `${runtime.appSessionId}.elicitation-response.json`);
  await waitFor(
    () => !realExistsSync(runtime.elicitationPath),
    "durable fallback receipt attempt was not discarded"
  );
  assert.equal(receipt(runtime, durableFields.operationId), undefined);
  assert.equal(runtime.session.elicitationCalls.length, 0);
});

test("terminal receipts remain count-bounded without expiring and accepted receipts bound new work", {
  concurrency: false,
}, async (t) => {
  let clock = 1_000_000;
  Date.now = () => clock;
  t.after(() => { Date.now = originalDateNow; });
  const terminalRuntime = await createRuntime(t);
  for (let index = 0; index < 70; index += 1) {
    clock += 1;
    const fields = operationFields(
      terminalRuntime,
      "answer-user-input",
      `terminal-${index}`
    );
    writeHandoff(terminalRuntime, terminalRuntime.userInputPath, {
      schemaVersion: 1,
      copilotSessionId: terminalRuntime.copilotSessionId,
      requestId: `missing-${index}`,
      answer: "Go",
      wasFreeform: false,
      ...fields,
    });
    trigger(
      terminalRuntime,
      `${terminalRuntime.appSessionId}.user-input-response.json`
    );
    assert.equal(realExistsSync(terminalRuntime.userInputPath), false);
  }
  const terminalReceipts = readSnapshot(terminalRuntime).operationReceipts;
  assert.equal(terminalReceipts.length, 64);
  assert.equal(
    terminalReceipts.some((entry) => entry.operationId === "terminal-0"),
    false
  );
  assert.equal(
    terminalReceipts.some((entry) => entry.operationId === "terminal-69"),
    true
  );
  clock += 120_001;
  terminalRuntime.intervalCallback();
  assert.deepEqual(readSnapshot(terminalRuntime).operationReceipts, terminalReceipts);

  Date.now = originalDateNow;
  const acceptedRuntime = await createRuntime(t);
  acceptedRuntime.session.userInputHandler = () => new Promise(() => {});
  let firstTimestamp = null;
  for (let index = 0; index < 64; index += 1) {
    const requestId = `inflight-request-${index}`;
    await emitUserInput(acceptedRuntime, requestId, ["Go"]);
    const fields = operationFields(
      acceptedRuntime,
      "answer-user-input",
      `inflight-${index}`
    );
    writeHandoff(acceptedRuntime, acceptedRuntime.userInputPath, {
      schemaVersion: 1,
      copilotSessionId: acceptedRuntime.copilotSessionId,
      requestId,
      answer: "Go",
      wasFreeform: false,
      ...fields,
    });
    trigger(
      acceptedRuntime,
      `${acceptedRuntime.appSessionId}.user-input-response.json`
    );
    const accepted = receipt(acceptedRuntime, fields.operationId);
    assert.equal(accepted?.state, "accepted");
    if (index === 0) firstTimestamp = accepted.updatedAtMilliseconds;
    realRmSync(acceptedRuntime.userInputPath, { force: true });
  }
  assert.equal(acceptedRuntime.session.userInputCalls.length, 64);
  acceptedRuntime.intervalCallback();
  assert.equal(
    receipt(acceptedRuntime, "inflight-0").updatedAtMilliseconds,
    firstTimestamp
  );
  assert.equal(readSnapshot(acceptedRuntime).operationReceipts.length, 64);

  const blockedRequestId = "inflight-request-64";
  await emitUserInput(acceptedRuntime, blockedRequestId, ["Go"]);
  const blockedFields = operationFields(
    acceptedRuntime,
    "answer-user-input",
    "inflight-64"
  );
  writeHandoff(acceptedRuntime, acceptedRuntime.userInputPath, {
    schemaVersion: 1,
    copilotSessionId: acceptedRuntime.copilotSessionId,
    requestId: blockedRequestId,
    answer: "Go",
    wasFreeform: false,
    ...blockedFields,
  });
  trigger(
    acceptedRuntime,
    `${acceptedRuntime.appSessionId}.user-input-response.json`
  );
  assert.equal(acceptedRuntime.session.userInputCalls.length, 64);
  assert.equal(receipt(acceptedRuntime, blockedFields.operationId), undefined);
  assert.equal(realExistsSync(acceptedRuntime.userInputPath), true);
});

test("an accepted operation orphaned by ownership loss is never invoked twice", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  const requestId = "ownership-loss-question";
  const fields = operationFields(
    runtime,
    "answer-user-input",
    "ownership-loss-operation"
  );
  let finishRPC;
  runtime.session.userInputHandler = () => new Promise((resolve) => {
    finishRPC = resolve;
  });
  await emitUserInput(runtime, requestId, ["Go"]);
  const payload = {
    schemaVersion: 1,
    copilotSessionId: runtime.copilotSessionId,
    requestId,
    answer: "Go",
    wasFreeform: false,
    ...fields,
  };

  writeHandoff(runtime, runtime.userInputPath, payload);
  trigger(runtime, `${runtime.appSessionId}.user-input-response.json`);
  await waitFor(
    () => receipt(runtime, fields.operationId)?.state === "accepted",
    "the operation was not accepted before the RPC"
  );
  assert.equal(runtime.session.userInputCalls.length, 1);

  const originalOwner = JSON.parse(realReadFileSync(runtime.ownerPath, "utf8"));
  realWriteFileSync(runtime.ownerPath, JSON.stringify({
    copilotSessionId: runtime.copilotSessionId,
    pid: 1,
  }));
  finishRPC({ success: true });
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(
    receipt(runtime, fields.operationId)?.state,
    "accepted",
    "ownership loss must not claim a terminal SDK outcome"
  );
  assert.equal(
    realExistsSync(runtime.userInputPath),
    true,
    "the non-owner must leave the captured handoff for the current owner"
  );

  realWriteFileSync(runtime.ownerPath, JSON.stringify(originalOwner));
  trigger(runtime, `${runtime.appSessionId}.user-input-response.json`);
  await waitFor(
    () => receipt(runtime, fields.operationId)?.state === "indeterminate",
    "the orphaned accepted receipt did not fail closed"
  );
  assert.equal(runtime.session.userInputCalls.length, 1);
  assert.equal(
    receipt(runtime, fields.operationId)?.errorCode,
    "execution-ownership-lost"
  );
  assert.equal(realExistsSync(runtime.userInputPath), false);
});
