import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import fs from "node:fs";
import { registerHooks, syncBuiltinESMExports } from "node:module";
import { createHash, randomUUID } from "node:crypto";
import { join } from "node:path";
import { PassThrough } from "node:stream";
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
const originalOpenSync = fs.openSync;
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
fs.readFileSync = (path, ...args) => {
  const result = realReadFileSync(path, ...args);
  const runtime = [...runtimes].find((entry) =>
    String(path).startsWith(entry.root)
  );
  runtime?.afterRead?.(String(path));
  return result;
};
fs.openSync = (path, ...args) => {
  const fd = originalOpenSync(path, ...args);
  const runtime = [...runtimes].find((entry) =>
    String(path).startsWith(entry.root)
  );
  runtime?.afterOpen?.(String(path));
  return fd;
};
fs.createReadStream = (path, ...args) => {
  const runtime = [...runtimes].find((entry) =>
    String(path).startsWith(entry.root)
  );
  const durable = runtime && String(path).endsWith("events.jsonl");
  if (durable) runtime.beforeDurableRead?.(String(path));
  const stream = originalCreateReadStream(path, ...args);
  if (durable) {
    stream.once("close", () => { runtime.durableReadsFinished += 1; });
  }
  return stream;
};
syncBuiltinESMExports();

const fakeSDKURL = `data:text/javascript,${encodeURIComponent(`
  export async function joinSession() {
    const join = globalThis.__copilotProjectsTrackerJoin;
    if (join) return join();
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
  fs.openSync = originalOpenSync;
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
    this.activityHandler = async () => ({ abortable: this.processing, hasActiveWork: this.processing });
    this.abortHandler = async () => this.emit("session.idle", { aborted: true });
    this.enqueueHandler = async () => ({ queued: true });
    this.commandListHandler = async () => ({ commands: [] });
    this.scheduleListHandler = async () => ({ entries: [] });
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
        list: async () => this.scheduleListHandler({ sessionId: this.sessionId }),
      },
      permissions: {
        getMode: async () => ({ mode: "manual" }),
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
        if (method === "session.eventLog.read") {
          this.questionEventCalls.push(params);
          return this.questionEventHandler(params);
        }
        this.runtimeCalls.push({ method, ...params });
        if (method === "session.metadata.snapshot") return this.metadataHandler(params);
        if (method === "session.metadata.isProcessing") return this.processingHandler(params);
        if (method === "session.metadata.activity") return this.activityHandler(params);
        if (method === "session.usage.getMetrics") return this.usageHandler(params);
        if (method === "session.workspaces.diff") return this.diffHandler(params);
        if (method === "session.model.getCurrent") return { modelId: "gpt-5.6-sol" };
        if (method === "session.model.list") return this.modelListHandler();
        if (method === "session.commands.list") return this.commandListHandler(params);
        if (method === "session.schedule.list") return this.scheduleListHandler(params);
        this.workflowCalls.push({ method, ...params });
        if (method === "session.commands.enqueue") return this.enqueueHandler(params);
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

async function createRuntime(t, configure = () => {}, { ready = true } = {}) {
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
  await configure(runtime.session, runtime);
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
    if (!ready) {
      await waitFor(() => runtime.intervalCallback, "tracker did not finish starting");
    } else {
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
    }
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

const hookReloadRace = "Request session.resume failed with message: session construction failed: "
  + "workspace changed while reloading native hooks";

function rpcFrame(body) {
  return Buffer.from(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
}

// Backoff sleeps, without the retry-window timers raced against each attempt
// or the harness's own short polls.
function backoff(delays) {
  return delays.filter((delay) => delay >= 250 && delay <= 4_000);
}

// Runs the tracker against a fake SDK whose joins attach a reader to stdin
// synchronously, as the real SDK does, over a stdin the test controls.
async function withJoinAttempts(join, body, { expireRetryWindow = false } = {}) {
  const recordedDelays = [];
  const savedSetTimeout = globalThis.setTimeout;
  const savedStdin = Object.getOwnPropertyDescriptor(process, "stdin");
  const input = new PassThrough();
  Object.defineProperty(process, "stdin", { configurable: true, get: () => input });
  globalThis.__copilotProjectsTrackerJoin = join;
  globalThis.setTimeout = (callback, delay, ...args) => {
    recordedDelays.push(delay);
    const immediate = expireRetryWindow || !(delay > 4_000);
    return savedSetTimeout(callback, immediate ? 0 : delay, ...args);
  };
  try {
    return await body(recordedDelays, input);
  } finally {
    globalThis.setTimeout = savedSetTimeout;
    delete globalThis.__copilotProjectsTrackerJoin;
    Object.defineProperty(process, "stdin", savedStdin);
    input.destroy();
  }
}

test("a join that loses the hook-reload race resumes on the next frame boundary", {
  timeout: 10_000,
}, async (t) => {
  const delivered = rpcFrame(JSON.stringify({ jsonrpc: "2.0", method: "session.lifecycle", params: {} }));
  const split = rpcFrame(JSON.stringify({ jsonrpc: "2.0", id: 1, result: { protocolVersion: 3 } }));
  const staleInput = () => {};
  const staleOutput = () => {};
  const keptInput = () => {};
  let attempts = 0;
  let session = null;
  let received = Buffer.alloc(0);
  await withJoinAttempts(async () => {
    attempts += 1;
    const stdin = process.stdin;
    // Pipe input arrives on a later turn than the one that attaches the reader.
    const nextTurn = () => new Promise((resolve) => setImmediate(resolve));
    if (attempts <= 2) {
      stdin.on("data", staleInput);
      process.stdout.on("close", staleOutput);
      await nextTurn();
      if (attempts === 1) stdin.write(Buffer.concat([delivered, split.subarray(0, 20)]));
      await nextTurn();
      throw new Error(hookReloadRace);
    }
    assert.equal(stdin.listeners("data").includes(staleInput), false);
    assert.equal(process.stdout.listeners("close").includes(staleOutput), false);
    assert.equal(stdin.listeners("end").includes(keptInput), true);
    stdin.on("data", (chunk) => { received = Buffer.concat([received, chunk]); });
    await nextTurn();
    stdin.write(split.subarray(20));
    await waitFor(() => received.length >= split.length, "the retried reader got no frame");
    return session;
  }, async (delays, input) => {
    input.on("end", keptInput);
    const runtime = await createRuntime(t, (fakeSession) => { session = fakeSession; });
    assert.equal(attempts, 3);
    assert.deepEqual(received, split);
    assert.deepEqual(backoff(delays).slice(0, 2), [250, 500]);
    assert.equal(
      realReadFileSync(join(runtime.sessions, `${runtime.appSessionId}.copilot-session`), "utf8"),
      runtime.copilotSessionId
    );
  });
});

test("a join error outside the hook-reload race still fails the load", async (t) => {
  let attempts = 0;
  await withJoinAttempts(async () => {
    attempts += 1;
    process.stdin.on("data", () => {});
    throw new Error("Request session.resume failed with message: permission denied");
  }, async () => {
    await assert.rejects(createRuntime(t), /permission denied/);
  });
  assert.equal(attempts, 1);
});

test("a join is not retried when the SDK has no stdin reader to follow", async (t) => {
  let attempts = 0;
  await withJoinAttempts(async () => {
    attempts += 1;
    throw new Error(hookReloadRace);
  }, async () => {
    await assert.rejects(createRuntime(t), /workspace changed while reloading native hooks/);
  });
  assert.equal(attempts, 1);
});

test("hook-reload races are retried on a bounded backoff before failing", async (t) => {
  let attempts = 0;
  await withJoinAttempts(async () => {
    attempts += 1;
    process.stdin.on("data", () => {});
    throw new Error(hookReloadRace);
  }, async (delays) => {
    await assert.rejects(createRuntime(t), /workspace changed while reloading native hooks/);
    assert.deepEqual(backoff(delays), [250, 500, 1_000, 2_000, 4_000]);
  });
  assert.equal(attempts, 6);
});

test("a retried join that never settles is abandoned within the retry window", {
  timeout: 10_000,
}, async (t) => {
  let attempts = 0;
  await withJoinAttempts(async () => {
    attempts += 1;
    process.stdin.on("data", () => {});
    if (attempts === 1) throw new Error(hookReloadRace);
    return new Promise(() => {});
  }, async (delays) => {
    await assert.rejects(
      createRuntime(t),
      /retry window elapsed after: .*workspace changed while reloading native hooks/
    );
    assert.equal(delays[0], 250);
    assert.ok(delays[1] > 0 && delays[1] <= 20_000);
  }, { expireRetryWindow: true });
  assert.equal(attempts, 2);
});

test("tracker never reads permission mode", async (t) => {
  let reads = 0;
  const runtime = await createRuntime(t, (session) => {
    session.rpc.permissions = {
      getMode: async () => { reads += 1; return { mode: "allow-all" }; },
      getAllowAll: async () => { reads += 1; return { enabled: true }; },
    };
  });
  await runtime.session.emit("session.permissions_changed", { mode: "allow-all" });
  runtime.session.sessionId = uuid();
  await runtime.session.emit("session.start", { sessionId: runtime.session.sessionId });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(reads, 0);
});

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

test("bounce enqueues the registered command for its owner once without sending a prompt", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
  });
  assert.ok((await workflowReady(runtime)).capabilities.includes("session-bounce"));
  const request = workflowHandoff(runtime, "session-bounce", {});
  await waitFor(() => receipt(runtime, request.operationId)?.state === "applied", "bounce not queued");
  assert.deepEqual(runtime.session.workflowCalls, [{
    method: "session.commands.enqueue", sessionId: runtime.copilotSessionId, command: "/bounce",
  }]);
  assert.deepEqual(runtime.session.closeCalls, []);
  assert.deepEqual(readSnapshot(runtime).workflow.capabilities, []);
  assert.equal(readSnapshot(runtime).workflow.bounceRequested, true);
  assert.equal(readSnapshot(runtime).availableModels, undefined);
  const acceptedSnapshots = runtime.activityWrites.filter(snapshot =>
    snapshot.operationReceipts.some(item => item.operationId === request.operationId && item.state === "accepted")
  );
  assert.ok(acceptedSnapshots.length > 0);
  assert.ok(acceptedSnapshots.every(snapshot =>
    snapshot.workflow.bounceRequested === true && snapshot.availableModels === undefined
      && snapshot.workflow.capabilities.length === 0
  ));
  writeHandoff(runtime, request.path, request.payload);
  trigger(runtime, `${runtime.appSessionId}.session-bounce.json`);
  const second = workflowHandoff(runtime, "session-bounce", {});
  await waitFor(() => receipt(runtime, second.operationId)?.state === "rejected", "second bounce not rejected");
  assert.equal(runtime.session.workflowCalls.length, 1);
});

test("bounce discovery fails closed without disabling existing native workflows", {
  concurrency: false,
}, async (t) => {
  for (const catalog of [null, {}, { commands: [] }, { commands: [{ name: "restart" }] },
    { commands: [{ name: "bounce", kind: "skill" }] }]) {
    const runtime = await createRuntime(t, (session) => {
      session.commandListHandler = async () => catalog;
    });
    assert.equal((await workflowReady(runtime)).capabilities.includes("session-bounce"), false);
    const request = workflowHandoff(runtime, "session-bounce", {});
    await waitFor(() => receipt(runtime, request.operationId)?.state === "rejected", "unsupported bounce not rejected");
    assert.deepEqual(runtime.session.workflowCalls, []);
  }
  const runtime = await createRuntime(t, (session) => {
    session.commandListHandler = async () => { throw Object.assign(new Error("unsupported"), { code: -32601 }); };
  });
  assert.equal((await workflowReady(runtime)).capabilities.includes("session-bounce"), false);
});

test("bounce rejects while initial question recovery is pending and until the recovered question completes", {
  concurrency: false,
}, async (t) => {
  let release;
  const runtime = await createRuntime(t, (session) => {
    session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
    session.questionEvents.push(questionEvent("elicitation.requested", pendingURLQuestion("recovering")));
    const read = session.questionEventHandler;
    session.questionEventHandler = (params) => session.questionEventCalls.length === 1
      ? new Promise(resolve => { release = () => resolve(read(params)); })
      : read(params);
  });
  t.after(() => release?.());
  await workflowReady(runtime);
  assert.equal(runtime.session.processing, false);
  assert.equal(runtime.session.questionEventCalls[0].sessionId, runtime.copilotSessionId);
  assert.deepEqual(readSnapshot(runtime).trackedElicitations, []);
  const pending = workflowHandoff(runtime, "session-bounce", {});
  await waitFor(() => ["applied", "rejected"].includes(receipt(runtime, pending.operationId)?.state),
    "bounce did not settle while question recovery was pending");
  assert.equal(receipt(runtime, pending.operationId).state, "rejected");
  assert.deepEqual(runtime.session.workflowCalls, []);

  release();
  await waitFor(() => readSnapshot(runtime).trackedElicitations.length === 1, "question was not recovered");
  const unanswered = workflowHandoff(runtime, "session-bounce", {});
  await waitFor(() => receipt(runtime, unanswered.operationId)?.state === "rejected",
    "unanswered recovered question did not block bounce");
  assert.deepEqual(runtime.session.workflowCalls, []);

  await runtime.session.emit("elicitation.completed", { requestId: "recovering" }, {}, false);
  runtime.intervalCallback();
  await waitFor(() => readSnapshot(runtime).trackedElicitations.length === 0, "completion was not recovered");
  const ready = workflowHandoff(runtime, "session-bounce", {});
  await waitFor(() => receipt(runtime, ready.operationId)?.state === "applied", "completed recovery kept bounce blocked");
  assert.equal(runtime.session.workflowCalls.length, 1);
});

test("bounce rejects failed, unavailable, malformed, and incomplete question recovery", {
  concurrency: false,
}, async (t) => {
  for (const failure of ["failed", "unavailable", "malformed", "incomplete"]) {
    const runtime = await createRuntime(t, (session) => {
      session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
      session.questionEventHandler = async () => {
        if (failure === "failed") throw new Error("question recovery failed");
        if (failure === "unavailable") throw Object.assign(new Error("unavailable"), { code: -32601 });
        if (failure === "malformed") return { events: [] };
        return { events: [], cursor: String(session.questionEventCalls.length), hasMore: true, cursorStatus: "ok" };
      };
    });
    await workflowReady(runtime);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(runtime.session.processing, false);
    const request = workflowHandoff(runtime, "session-bounce", {});
    await waitFor(() => ["applied", "rejected"].includes(receipt(runtime, request.operationId)?.state),
      "bounce did not settle after question recovery failed");
    assert.equal(receipt(runtime, request.operationId).state, "rejected", failure);
    assert.deepEqual(runtime.session.workflowCalls, [], failure);
  }
});

test("bounce cannot reuse question recovery from a previous conversation", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
  });
  await workflowReady(runtime);
  const oldID = runtime.session.sessionId;
  const nextID = uuid();
  let finishOld;
  let finishNew;
  const emptyPage = { events: [], cursor: "tail", hasMore: false, cursorStatus: "ok" };
  runtime.session.questionEventHandler = ({ sessionId }) => {
    if (sessionId === oldID && !finishOld) return new Promise(resolve => { finishOld = resolve; });
    if (sessionId !== oldID && !finishNew) return new Promise(resolve => { finishNew = resolve; });
    return Promise.resolve(emptyPage);
  };
  t.after(() => { finishOld?.(emptyPage); finishNew?.(emptyPage); });
  runtime.intervalCallback();
  await waitFor(() => finishOld, "old question recovery did not start");
  runtime.session.sessionId = nextID;
  await runtime.session.emit("session.start", { sessionId: nextID });
  await waitFor(() => finishNew, "current question recovery did not start");
  finishOld(emptyPage);
  await workflowReady(runtime);
  const pending = workflowHandoff(runtime, "session-bounce", {});
  await waitFor(() => receipt(runtime, pending.operationId)?.state === "rejected",
    "old recovery admitted bounce into the new conversation");
  assert.deepEqual(runtime.session.workflowCalls, []);
  finishNew(emptyPage);
  await new Promise(resolve => setImmediate(resolve));
  const ready = workflowHandoff(runtime, "session-bounce", {});
  await waitFor(() => receipt(runtime, ready.operationId)?.state === "applied", "current recovery did not admit bounce");
  assert.equal(runtime.session.workflowCalls[0].sessionId, nextID);
});

test("bounce waits for oversized questions that cannot be displayed remotely", {
  concurrency: false,
}, async (t) => {
  for (const kind of ["elicitation", "user_input"]) {
    for (const recovered of [false, true]) {
      const data = kind === "elicitation"
        ? { ...pendingURLQuestion("oversized"), message: "x".repeat(16_385) }
        : { requestId: "oversized", question: "x".repeat(16_385), choices: ["Continue"] };
      const runtime = await createRuntime(t, (session) => {
        session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
        if (recovered) session.questionEvents.push(questionEvent(`${kind}.requested`, data));
      });
      await workflowReady(runtime);
      if (!recovered) await runtime.session.emit(`${kind}.requested`, data);
      assert.equal(runtime.session.processing, false);
      const field = kind === "elicitation" ? "trackedElicitations" : "trackedUserInputs";
      assert.deepEqual(readSnapshot(runtime)[field], []);
      const pending = workflowHandoff(runtime, "session-bounce", {});
      await waitFor(() => ["applied", "rejected"].includes(receipt(runtime, pending.operationId)?.state),
        "bounce did not settle with a terminal-only question");
      assert.equal(receipt(runtime, pending.operationId).state, "rejected", `${kind} recovered=${recovered}`);
      assert.deepEqual(runtime.session.workflowCalls, []);

      await runtime.session.emit(`${kind}.completed`, { requestId: "oversized" }, {}, !recovered);
      if (recovered) runtime.intervalCallback();
      await new Promise(resolve => setImmediate(resolve));
      const ready = workflowHandoff(runtime, "session-bounce", {});
      await waitFor(() => receipt(runtime, ready.operationId)?.state === "applied",
        "completed terminal-only question kept bounce blocked");
      assert.equal(runtime.session.workflowCalls.length, 1);
    }
  }
});

test("heartbeat bounce waits for question recovery without delaying exact receipt replay", {
  concurrency: false,
}, async (t) => {
  for (const delayed of [false, true]) {
    const runtime = await createRuntime(t, (session) => {
      session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
    });
    await workflowReady(runtime);
    const emptyPage = { events: [], cursor: "tail", hasMore: false, cursorStatus: "ok" };
    let finish;
    if (delayed) runtime.session.questionEventHandler = () => finish
      ? Promise.resolve(emptyPage)
      : new Promise(resolve => { finish = resolve; });
    t.after(() => finish?.(emptyPage));
    const fields = operationFields(runtime, "session-bounce");
    const path = join(runtime.sessions, `${runtime.appSessionId}.session-bounce.json`);
    const payload = {
      schemaVersion: 1, copilotSessionId: runtime.copilotSessionId,
      ...fields, action: { kind: "session-bounce" },
    };
    writeHandoff(runtime, path, payload);
    runtime.intervalCallback();
    if (delayed) {
      await waitFor(() => finish, "heartbeat question recovery did not start");
      assert.equal(receipt(runtime, fields.operationId), undefined);
      assert.deepEqual(runtime.session.workflowCalls, []);
      finish(emptyPage);
    }
    await waitFor(() => ["applied", "rejected"].includes(receipt(runtime, fields.operationId)?.state),
      "heartbeat did not dispatch bounce after recovery");
    assert.equal(receipt(runtime, fields.operationId).state, "applied");
    assert.equal(runtime.session.workflowCalls.length, 1);

    const applied = receipt(runtime, fields.operationId);
    runtime.session.questionEventHandler = () => new Promise(resolve => { finish = resolve; });
    writeHandoff(runtime, path, payload);
    runtime.intervalCallback();
    await waitFor(() => !realExistsSync(path), "receipt replay waited for question recovery");
    assert.deepEqual(receipt(runtime, fields.operationId), applied);
    assert.equal(runtime.session.workflowCalls.length, 1);
  }
});

test("watcher bounce refreshes questions missed after startup without a heartbeat", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
  });
  await workflowReady(runtime);
  const reads = runtime.session.questionEventCalls.length;
  await runtime.session.emit("elicitation.requested", pendingURLQuestion("missed"), {}, false);
  assert.deepEqual(readSnapshot(runtime).trackedElicitations, []);
  const request = workflowHandoff(runtime, "session-bounce", {});
  await waitFor(() => ["applied", "rejected"].includes(receipt(runtime, request.operationId)?.state),
    "watcher bounce did not settle");
  assert.equal(receipt(runtime, request.operationId).state, "rejected");
  assert.ok(runtime.session.questionEventCalls.length > reads);
  assert.equal(readSnapshot(runtime).trackedElicitations[0].requestId, "missed");
  assert.deepEqual(runtime.session.workflowCalls, []);
});

test("heartbeat rejects bounce after failed or unsupported question recovery", {
  concurrency: false,
}, async (t) => {
  for (const code of [undefined, -32601]) {
    const runtime = await createRuntime(t, (session) => {
      session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
    });
    await workflowReady(runtime);
    runtime.session.questionEventHandler = async () => {
      throw Object.assign(new Error("question recovery failed"), { code });
    };
    const fields = operationFields(runtime, "session-bounce");
    const path = join(runtime.sessions, `${runtime.appSessionId}.session-bounce.json`);
    writeHandoff(runtime, path, {
      schemaVersion: 1, copilotSessionId: runtime.copilotSessionId,
      ...fields, action: { kind: "session-bounce" },
    });
    runtime.intervalCallback();
    await waitFor(() => receipt(runtime, fields.operationId)?.state === "rejected",
      "failed question recovery left the bounce handoff outstanding");
    assert.equal(realExistsSync(path), false);
    assert.deepEqual(runtime.session.workflowCalls, []);
  }
});

test("stalled question reads reject watcher and polling bounce without releasing recovery ownership", {
  concurrency: false,
}, async (t) => {
  for (const watcher of [false, true]) {
    const runtime = await createRuntime(t, (session) => {
      session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
    });
    await workflowReady(runtime);
    const read = runtime.session.questionEventHandler;
    const reads = runtime.session.questionEventCalls.length;
    const emptyPage = { events: [], cursor: "0", hasMore: false, cursorStatus: "ok" };
    let finish;
    runtime.session.questionEventHandler = () => new Promise(resolve => { finish = resolve; });
    t.after(() => finish?.(emptyPage));
    const fields = operationFields(runtime, "session-bounce");
    const path = join(runtime.sessions, `${runtime.appSessionId}.session-bounce.json`);
    const payload = {
      schemaVersion: 1, copilotSessionId: runtime.copilotSessionId,
      ...fields, action: { kind: "session-bounce" },
    };
    writeHandoff(runtime, path, payload);
    if (watcher) trigger(runtime, `${runtime.appSessionId}.session-bounce.json`);
    else runtime.intervalCallback();
    await waitFor(() => finish, "question read did not stall");
    await waitFor(() => receipt(runtime, fields.operationId)?.state === "rejected",
      "stalled recovery did not reject bounce within the existing recovery deadline", 4_000);
    assert.equal(realExistsSync(path), false);
    assert.deepEqual(runtime.session.workflowCalls, []);
    runtime.intervalCallback();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(runtime.session.questionEventCalls.length, reads + 1, "Recovery single-flight ownership was released");
    finish(emptyPage);
    runtime.session.questionEventHandler = read;
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(runtime.session.workflowCalls, [], "Late recovery executed an expired bounce");
    writeHandoff(runtime, path, payload);
    trigger(runtime, `${runtime.appSessionId}.session-bounce.json`);
    await waitFor(() => !realExistsSync(path), "expired bounce receipt did not replay");
    assert.equal(receipt(runtime, fields.operationId).state, "rejected");
    assert.deepEqual(runtime.session.workflowCalls, []);
    const ready = workflowHandoff(runtime, "session-bounce", {});
    await waitFor(() => receipt(runtime, ready.operationId)?.state === "applied",
      "expired preflight kept a new request reserved after recovery");
    assert.equal(runtime.session.workflowCalls.length, 1);
  }
});

test("a completed native send invalidates bounce preflight before a delayed turn-start event", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
  });
  await workflowReady(runtime);
  const emptyPage = { events: [], cursor: "0", hasMore: false, cursorStatus: "ok" };
  let finishRecovery;
  runtime.session.questionEventHandler = () => new Promise(resolve => { finishRecovery = resolve; });
  t.after(() => finishRecovery?.(emptyPage));
  const bounce = workflowHandoff(runtime, "session-bounce", {});
  await waitFor(() => finishRecovery, "bounce preflight did not wait for question recovery");
  const send = workflowHandoff(runtime, "session-send", { prompt: "new work", mode: "enqueue" });
  await waitFor(() => receipt(runtime, send.operationId)?.state === "applied", "native send did not complete");
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(runtime.session.processing, false, "The turn-start notification must still be delayed");
  assert.equal(receipt(runtime, bounce.operationId), undefined, "The race must finish before preflight expiry");
  finishRecovery(emptyPage);
  await waitFor(() => ["applied", "rejected"].includes(receipt(runtime, bounce.operationId)?.state),
    "bounce did not settle after the intervening send");
  assert.equal(receipt(runtime, bounce.operationId).state, "rejected");
  assert.deepEqual(runtime.session.workflowCalls.map(call => call.method), ["session.send"]);
});

test("a reloaded tracker rejects bounce over unfinished child work reported by the runtime", {
  concurrency: false,
}, async (t) => {
  const child = uuid();
  const runtime = await createRuntime(t, (session) => {
    session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
    session.history = [{
      id: uuid(), type: "subagent.started", timestamp: new Date().toISOString(), agentId: child,
      data: { toolCallId: "unfinished-child", agentName: "explore", agentDisplayName: "Child" },
    }];
    session.activityHandler = async () => ({ abortable: false, hasActiveWork: true });
  });
  await workflowReady(runtime);
  assert.equal(runtime.session.processing, false);
  assert.deepEqual(readSnapshot(runtime).activeSubagents, [], "Reload must not have a live child notification");
  const request = workflowHandoff(runtime, "session-bounce", {});
  await waitFor(() => ["applied", "rejected"].includes(receipt(runtime, request.operationId)?.state),
    "bounce did not settle for unfinished child work");
  assert.equal(receipt(runtime, request.operationId).state, "rejected");
  assert.deepEqual(runtime.session.runtimeCalls
    .filter(call => call.method === "session.metadata.activity")
    .map(call => call.sessionId), [runtime.copilotSessionId]);
  assert.deepEqual(runtime.session.workflowCalls, []);
  runtime.session.activityHandler = async () => ({ abortable: false, hasActiveWork: false });
  const idle = workflowHandoff(runtime, "session-bounce", {});
  await waitFor(() => receipt(runtime, idle.operationId)?.state === "applied",
    "authoritatively idle child work kept bounce blocked");
  assert.equal(runtime.session.workflowCalls.length, 1);
});

test("bounce rejects unknown or unavailable session-wide activity", {
  concurrency: false,
}, async (t) => {
  for (const activity of [undefined, {}, {hasActiveWork: null}, {hasActiveWork: "false"}, new Error("unavailable")]) {
    const runtime = await createRuntime(t, (session) => {
      session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
      session.activityHandler = async () => {
        if (activity instanceof Error) throw Object.assign(activity, { code: -32601 });
        return activity;
      };
    });
    await workflowReady(runtime);
    const request = workflowHandoff(runtime, "session-bounce", {});
    await waitFor(() => ["applied", "rejected"].includes(receipt(runtime, request.operationId)?.state),
      "bounce did not settle with unknown background work");
    assert.equal(receipt(runtime, request.operationId).state, "rejected");
    assert.deepEqual(runtime.session.workflowCalls, []);
  }
});

test("bounce rechecks live processing and command registration before dispatch", {
  concurrency: false,
}, async (t) => {
  for (const change of ["processing", "removed", "question"]) {
    const runtime = await createRuntime(t, (session) => {
      session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
    });
    await workflowReady(runtime);
    if (change === "processing") runtime.session.processing = true;
    if (change === "removed") runtime.session.commandListHandler = async () => ({ commands: [] });
    if (change === "question") {
      runtime.session.commandListHandler = async () => {
        runtime.session.emit("session_limits_exhausted.requested", {
          requestId: "budget", maxAiCredits: 30, usedAiCredits: 30,
        });
        return { commands: [{ name: "bounce", kind: "client" }] };
      };
    }
    const request = workflowHandoff(runtime, "session-bounce", {});
    await waitFor(() => receipt(runtime, request.operationId)?.state === "rejected", "unsafe bounce not rejected");
    assert.deepEqual(runtime.session.workflowCalls, []);
  }
});

test("bounce rejects payloads and keeps an ambiguous dispatch from executing again", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
    session.enqueueHandler = async () => { throw new Error("connection closed after enqueue"); };
  });
  await workflowReady(runtime);
  const invalid = workflowHandoff(runtime, "session-bounce", { prompt: "/quit" });
  await waitFor(() => receipt(runtime, invalid.operationId)?.state === "rejected", "payload not rejected");
  assert.deepEqual(runtime.session.workflowCalls, []);
  const request = workflowHandoff(runtime, "session-bounce", {});
  await waitFor(() => receipt(runtime, request.operationId)?.state === "indeterminate", "unknown bounce not retained");
  const retry = workflowHandoff(runtime, "session-bounce", {});
  await waitFor(() => receipt(runtime, retry.operationId)?.state === "rejected", "ambiguous bounce retried");
  assert.equal(runtime.session.workflowCalls.length, 1);
});

test("a definitive bounce refusal leaves the conversation usable", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
    session.enqueueHandler = async () => ({ queued: false });
  });
  await workflowReady(runtime);
  const request = workflowHandoff(runtime, "session-bounce", {});
  await waitFor(() => receipt(runtime, request.operationId)?.state === "rejected", "bounce refusal not reported");
  assert.ok((await workflowReady(runtime)).capabilities.includes("session-bounce"));
  assert.equal(readSnapshot(runtime).workflow.bounceRequested, false);
});

test("duplicate bounce watcher events during preflight neither reject nor execute twice", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
  });
  await workflowReady(runtime);
  let release;
  runtime.session.commandListHandler = () => new Promise((resolve) => { release = resolve; });
  const request = workflowHandoff(runtime, "session-bounce", {});
  await waitFor(() => release, "preflight did not start");
  trigger(runtime, `${runtime.appSessionId}.session-bounce.json`);
  assert.equal(receipt(runtime, request.operationId), undefined);
  release({ commands: [{ name: "bounce", kind: "client" }] });
  await waitFor(() => receipt(runtime, request.operationId)?.state === "applied", "bounce not queued");
  assert.equal(runtime.session.workflowCalls.length, 1);
});

test("an unsupported enqueue RPC does not latch unrelated session controls off", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
    session.enqueueHandler = async () => { throw Object.assign(new Error("unsupported"), { code: -32601 }); };
  });
  await workflowReady(runtime);
  const request = workflowHandoff(runtime, "session-bounce", {});
  await waitFor(() => receipt(runtime, request.operationId)?.state === "rejected", "unsupported RPC not rejected");
  assert.equal((await workflowReady(runtime)).capabilities.includes("session-bounce"), false);
  assert.equal(readSnapshot(runtime).workflow.bounceRequested, false);
});

test("bounce waits for live schedules instead of trusting the empty startup cache", {
  concurrency: false,
}, async (t) => {
  let release;
  const runtime = await createRuntime(t, (session) => {
    session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
    session.rpc.schedule.list = async () => new Promise(() => {});
    session.scheduleListHandler = () => new Promise(resolve => { release = resolve; });
  });
  await workflowReady(runtime);
  assert.deepEqual(readSnapshot(runtime).schedules, []);
  const request = workflowHandoff(runtime, "session-bounce", {});
  await waitFor(() => release, "bounce did not request live schedules");
  assert.equal(receipt(runtime, request.operationId), undefined);
  assert.deepEqual(runtime.session.workflowCalls, []);
  const read = runtime.session.runtimeCalls.find(call => call.method === "session.schedule.list");
  assert.equal(read.sessionId, runtime.copilotSessionId);
  release({ entries: [{ id: "scheduled-work" }] });
  await waitFor(() => receipt(runtime, request.operationId)?.state === "rejected", "scheduled bounce was not rejected");
  assert.deepEqual(runtime.session.workflowCalls, []);
});

test("unavailable or malformed schedule observations cannot admit bounce", {
  concurrency: false,
}, async (t) => {
  for (const result of [null, {}, { entries: "unknown" }, new Error("schedule query failed")]) {
    const runtime = await createRuntime(t, (session) => {
      session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
      session.rpc.schedule.list = async () => ({ entries: [] });
      session.scheduleListHandler = async () => {
        if (result instanceof Error) throw result;
        return result;
      };
    });
    await workflowReady(runtime);
    const request = workflowHandoff(runtime, "session-bounce", {});
    await waitFor(() => receipt(runtime, request.operationId)?.state === "rejected", "unknown schedules were accepted");
    assert.deepEqual(runtime.session.workflowCalls, []);
  }
});

test("failed acceptance publication rolls back the bounce fence without invoking RPC", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
  });
  await workflowReady(runtime);
  let failedWrites = 0;
  runtime.failWrite = path => {
    if (!path.includes(".agent-activity.json")) return false;
    failedWrites++;
    return true;
  };
  const request = workflowHandoff(runtime, "session-bounce", {});
  await waitFor(() => failedWrites > 0, "acceptance write did not fail");
  assert.deepEqual(runtime.session.workflowCalls, []);
  assert.equal(realExistsSync(request.path), true);
  runtime.failWrite = null;
  await runtime.session.emit("session.usage_info", { currentTokens: 1, tokenLimit: 10 });
  assert.equal(readSnapshot(runtime).workflow.bounceRequested, false);
  assert.ok(readSnapshot(runtime).availableModels.length > 0);
});

test("bounce fences new model switches, including legacy, but preserves exact replay", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.commandListHandler = async () => ({ commands: [{ name: "bounce", kind: "client" }] });
  });
  await workflowReady(runtime);
  const fields = operationFields(runtime, "set-model");
  const payload = {
    schemaVersion: 1, copilotSessionId: runtime.copilotSessionId,
    modelId: "gpt-5.6-sol", ...fields,
  };
  writeHandoff(runtime, runtime.modelPath, payload);
  trigger(runtime, `${runtime.appSessionId}.set-model-request.json`);
  await waitFor(() => receipt(runtime, fields.operationId)?.state === "applied", "initial model switch failed");
  const bounce = workflowHandoff(runtime, "session-bounce", {});
  await waitFor(() => receipt(runtime, bounce.operationId)?.state === "applied", "bounce not queued");
  writeHandoff(runtime, runtime.modelPath, payload);
  trigger(runtime, `${runtime.appSessionId}.set-model-request.json`);
  await waitFor(() => !realExistsSync(runtime.modelPath), "exact replay was not consumed");
  assert.equal(receipt(runtime, fields.operationId).state, "applied");
  const next = operationFields(runtime, "set-model");
  writeHandoff(runtime, runtime.modelPath, { ...payload, ...next });
  trigger(runtime, `${runtime.appSessionId}.set-model-request.json`);
  await waitFor(() => receipt(runtime, next.operationId)?.state === "rejected", "new model switch escaped fence");
  assert.equal(receipt(runtime, next.operationId).errorCode, "target-unavailable");
  writeHandoff(runtime, runtime.modelPath, {
    schemaVersion: 1, copilotSessionId: runtime.copilotSessionId, modelId: "gpt-5.6-sol",
  });
  trigger(runtime, `${runtime.appSessionId}.set-model-request.json`);
  await waitFor(() => !realExistsSync(runtime.modelPath), "legacy switch was not refused");
  assert.equal(runtime.session.modelSwitchCalls.length, 1);
});

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
    } else if (scenario === "model") {
      const bytes = Buffer.from("fixture image bytes");
      const fields = operationFields(runtime, "session-send");
      realWriteFileSync(join(directory, `${id}.image`), bytes);
      realWriteFileSync(join(directory, `${id}.json`), JSON.stringify({
        attachment: {
          id, sessionId: runtime.appSessionId, conversationEpoch: fields.conversationEpoch,
          mimeType: "image/png", byteCount: bytes.length, expiresAtMilliseconds: Date.now() + 60000,
        },
        sha256: createHash("sha256").update(bytes).digest("hex"),
      }));
    }
    const request = workflowHandoff(runtime, "session-send", {
      prompt: "Must never send text alone", mode: "immediate", attachmentIds: [id],
    });
    await waitFor(() => receipt(runtime, request.operationId)?.state === "rejected", scenario);
    assert.equal(runtime.session.workflowCalls.some((call) => call.method === "session.send"), false);
  }
});

test("JSON and Markdown file attachments are delivered on non-vision models and reject invalid text", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.modelListHandler = async () => ({ list: [{
      id: "gpt-5.6-sol", capabilities: {
        supports: { vision: false },
      },
    }] });
  });
  await workflowReady(runtime);
  assert.equal(readSnapshot(runtime).workflow.capabilities.includes("file-attachments-v1"), true);

  const directory = join(runtime.sessions, "attachments-v1");
  realMkdirSync(directory);
  const fields = operationFields(runtime, "session-send");

  const jsonId = uuid();
  const jsonBytes = Buffer.from('{"service":"copilot-projects","enabled":true}\n', "utf8");
  realWriteFileSync(join(directory, `${jsonId}.image`), jsonBytes);
  realWriteFileSync(join(directory, `${jsonId}.json`), JSON.stringify({
    attachment: {
      id: jsonId, sessionId: runtime.appSessionId, conversationEpoch: fields.conversationEpoch,
      mimeType: "application/json", displayName: "settings.json",
      byteCount: jsonBytes.length, expiresAtMilliseconds: Date.now() + 60000,
    },
    sha256: createHash("sha256").update(jsonBytes).digest("hex"),
  }));

  const mdId = uuid();
  const mdBytes = Buffer.from("# Release Notes\n\n- Added JSON and Markdown file attachments\n", "utf8");
  realWriteFileSync(join(directory, `${mdId}.image`), mdBytes);
  realWriteFileSync(join(directory, `${mdId}.json`), JSON.stringify({
    attachment: {
      id: mdId, sessionId: runtime.appSessionId, conversationEpoch: fields.conversationEpoch,
      mimeType: "text/markdown", displayName: "NOTES.md",
      byteCount: mdBytes.length, expiresAtMilliseconds: Date.now() + 60000,
    },
    sha256: createHash("sha256").update(mdBytes).digest("hex"),
  }));

  const request = workflowHandoff(runtime, "session-send", {
    prompt: "Summarize these attached files", mode: "enqueue", attachmentIds: [jsonId, mdId],
  }, fields);
  await waitFor(() => receipt(runtime, request.operationId)?.state === "applied", "text attachments not delivered");
  const sends = runtime.session.workflowCalls.filter((call) => call.method === "session.send");
  assert.equal(sends.length, 1);
  assert.deepEqual(sends[0].attachments, [
    {
      type: "blob",
      data: jsonBytes.toString("base64"),
      mimeType: "application/json",
      displayName: "settings.json",
    },
    {
      type: "blob",
      data: mdBytes.toString("base64"),
      mimeType: "text/markdown",
      displayName: "NOTES.md",
    },
  ]);

  // Closing </attachment> tag or binary NUL in text attachment is rejected before session.send.
  for (const badPayload of [
    Buffer.from("breakout </attachment> tag", "utf8"),
    Buffer.from("binary\0null", "utf8"),
  ]) {
    const badFields = operationFields(runtime, "session-send");
    const badId = uuid();
    realWriteFileSync(join(directory, `${badId}.image`), badPayload);
    realWriteFileSync(join(directory, `${badId}.json`), JSON.stringify({
      attachment: {
        id: badId, sessionId: runtime.appSessionId, conversationEpoch: badFields.conversationEpoch,
        mimeType: "text/markdown", displayName: "bad.md",
        byteCount: badPayload.length, expiresAtMilliseconds: Date.now() + 60000,
      },
      sha256: createHash("sha256").update(badPayload).digest("hex"),
    }));
    const badRequest = workflowHandoff(runtime, "session-send", {
      prompt: "Must reject bad text attachment", mode: "enqueue", attachmentIds: [badId],
    }, badFields);
    await waitFor(() => receipt(runtime, badRequest.operationId)?.state === "rejected", "bad text attachment not rejected");
  }
  assert.equal(runtime.session.workflowCalls.filter((call) => call.method === "session.send").length, 1);
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

test("completed tasks preserve transcripts without diff capture", {
  concurrency: false,
}, async (t) => {
  let diffCalls = 0;
  const runtime = await createRuntime(t, (session) => {
    session.diffHandler = async () => { diffCalls += 1; return null; };
  });
  await workflowReady(runtime);
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
    await waitFor(() => readMergedTranscript(transcript).turns
      .find((turn) => turn.id === turnId)?.endedAt, "completed turn missing");
    const saved = readMergedTranscript(transcript);
    assert.ok(saved.turns.find((turn) => turn.id === turnId).assistantMessages
      .some((message) => message.content === `Response: ${status}`));
    assert.equal(diffCalls, 0);
  }
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
  await waitFor(() => readMergedTranscript(path).turns.length, "transcript missing");
  const messages = readMergedTranscript(path).turns.at(-1).assistantMessages;
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
    const turn = readMergedTranscript(path).turns.at(-1);
    return turn?.tools.length === blanks.length && turn.tools.every((tool) => tool.success) && turn;
  }, "tool-only messages did not reach the live transcript");
  assert.equal(turn.endedAt, null);
  assert.deepEqual(turn.assistantMessages.map(({ id, content }) => ({ id, content })), [
    { id: "reply", content: "Review complete." },
  ]);
  await runtime.session.emit("session.idle");
  const completed = await waitFor(() => {
    const turn = readMergedTranscript(path).turns.at(-1);
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
  const readTurn = () => readMergedTranscript(path).turns.at(-1);
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

const MAX_RECENTLY_DROPPED_BYTES = 256 * 1024;

function transcriptFile(runtime) {
  return join(runtime.sessions, `${runtime.appSessionId}.transcript.json`);
}

function readTranscript(runtime) {
  try {
    return readMergedTranscript(transcriptFile(runtime));
  } catch {
    return null;
  }
}

function liveTranscriptFile(path) {
  return path.replace(/\.transcript\.json$/, ".transcript-live.json");
}

// The transcript as the host reads it: the sealed file plus the live file's
// in-progress turn when that file extends the sealed revision (or the
// previous one it names) and does not repeat a sealed turn.
function readMergedTranscript(path) {
  // The live file first, as the host reads it.
  let live = null;
  try {
    live = JSON.parse(realReadFileSync(liveTranscriptFile(path), "utf8"));
  } catch {}
  const sealed = JSON.parse(realReadFileSync(path, "utf8"));
  if (sealed.schemaVersion !== 4) return sealed;
  const turn = live?.turn;
  const accepted = live?.schemaVersion === 1
    && live.copilotSessionId === sealed.copilotSessionId
    && (live.baseRevision === sealed.revision || live.baseRevision === sealed.previousRevision)
    && typeof turn?.id === "string"
    && !sealed.turns.some((stored) => stored.id === turn.id);
  return accepted ? { ...sealed, turns: [...sealed.turns, turn] } : sealed;
}

// Completed root turns as SDK history: a human message and its idle each.
function humanHistory(prefix, contents, startMilliseconds = 1_700_000_000_000) {
  return contents.flatMap((content, index) => {
    const at = (offset) => new Date(startMilliseconds + index * 1_000 + offset).toISOString();
    return [
      { id: `${prefix}-${index}`, type: "user.message", timestamp: at(0),
        data: { source: null, content } },
      { id: `${prefix}-idle-${index}`, type: "session.idle", timestamp: at(500),
        data: { aborted: false } },
    ];
  });
}

function numbered(prefix, count, padding = "") {
  return Array.from({ length: count }, (_, index) => `${prefix} ${index}${padding}`);
}

test("count-cap evictions publish the ten most recently dropped turns", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.history = humanHistory("human", numbered("human", 215));
  });
  const snapshot = await waitFor(() => {
    const value = readTranscript(runtime);
    return value?.turns.length === 200 && value;
  }, "replayed transcript missing");
  assert.equal(snapshot.turns[0].id, "human-15");
  // Oldest eviction first, bounded to the ten most recent.
  assert.deepEqual(
    snapshot.droppedTurns.map((turn) => turn.id),
    Array.from({ length: 10 }, (_, index) => `human-${index + 5}`)
  );
  assert.deepEqual(snapshot.droppedTurns[0], {
    ...snapshot.droppedTurns[0], userContent: "human 5", kind: "foreground",
  });

  // A live turn that pushes another one out joins the buffer immediately.
  await runtime.session.emit("user.message", { content: "live" }, { id: "live" });
  await runtime.session.emit("session.idle", { aborted: false });
  const live = await waitFor(() => {
    const value = readTranscript(runtime);
    return value?.turns.at(-1)?.id === "live" && value?.turns.at(-1)?.endedAt && value;
  }, "live turn missing");
  assert.equal(live.turns.length, 200);
  assert.deepEqual(
    live.droppedTurns.map((turn) => turn.id),
    Array.from({ length: 10 }, (_, index) => `human-${index + 6}`)
  );
});

test("the dropped-turn buffer stays within its serialized byte bound", {
  concurrency: false,
}, async (t) => {
  const big = numbered("big", 10, ` ${"x".repeat(40_000)}`);
  const runtime = await createRuntime(t, (session) => {
    session.history = [
      ...humanHistory("big", big),
      ...humanHistory("small", numbered("small", 200), 1_700_100_000_000),
    ];
  });
  const snapshot = await waitFor(() => {
    const value = readTranscript(runtime);
    return value?.turns[0]?.id === "small-0" && value;
  }, "replayed transcript missing");
  const sizes = snapshot.droppedTurns.map((turn) => Buffer.byteLength(JSON.stringify(turn)));
  const total = sizes.reduce((sum, size) => sum + size, 0);
  assert.ok(total <= MAX_RECENTLY_DROPPED_BYTES, `buffer holds ${total} bytes`);
  // Every big turn has the same size, so exactly as many as fit survive, and
  // they are the most recent evictions.
  const fit = Math.floor(MAX_RECENTLY_DROPPED_BYTES / Math.max(...sizes));
  assert.ok(fit < 10, "fixture must exceed the byte bound before the count bound");
  assert.deepEqual(
    snapshot.droppedTurns.map((turn) => turn.id),
    Array.from({ length: fit }, (_, index) => `big-${10 - fit + index}`)
  );
});

test("superseded resume markers are not buffered as dropped turns", {
  concurrency: false,
}, async (t) => {
  const resumed = await createRuntime(t, (session) => {
    session.history = [
      ...humanHistory("human", numbered("human", 3)),
      { id: "resume-old", type: "session.resume",
        timestamp: new Date(1_700_000_010_000).toISOString(), data: {} },
      { id: "resume-latest", type: "session.resume",
        timestamp: new Date(1_700_000_011_000).toISOString(), data: {} },
    ];
  });
  const withResume = await waitFor(() => {
    const value = readTranscript(resumed);
    return value?.turns.some((turn) => turn.id === "session-resume-resume-latest") && value;
  }, "resume marker missing");
  assert.deepEqual(
    withResume.turns.filter((turn) => turn.id.startsWith("session-resume-")).map((turn) => turn.id),
    ["session-resume-resume-latest"]
  );
  assert.equal("droppedTurns" in withResume, false);
});

test("a stale resume marker the count cap evicts is not buffered", {
  concurrency: false,
}, async (t) => {
  // Human messages after the resume clear its "latest" protection, so the
  // count cap evicts the marker first among the non-foreground turns.
  const runtime = await createRuntime(t, (session) => {
    session.history = [
      ...humanHistory("before", numbered("before", 5)),
      { id: "resume-stale", type: "session.resume",
        timestamp: new Date(1_700_000_010_000).toISOString(), data: {} },
      ...humanHistory("after", numbered("after", 200), 1_700_000_020_000),
    ];
  });
  const snapshot = await waitFor(() => {
    const value = readTranscript(runtime);
    return value?.turns[0]?.id === "after-0" && value;
  }, "replayed transcript missing");
  assert.equal(snapshot.turns.some((turn) => turn.id.startsWith("session-resume-")), false);
  assert.deepEqual(
    snapshot.droppedTurns.map((turn) => turn.id),
    ["before-0", "before-1", "before-2", "before-3", "before-4"]
  );
});

test("a conversation rotation clears the dropped-turn buffer", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.history = humanHistory("human", numbered("human", 205));
  });
  await waitFor(() => readTranscript(runtime)?.droppedTurns?.length === 5, "dropped turns missing");

  const next = uuid();
  runtime.session.foregroundSessionId = next;
  runtime.session.history = humanHistory("next", numbered("next", 2), 1_700_200_000_000);
  await runtime.session.emit("session.start", { sessionId: next });
  const rotated = await waitFor(() => {
    const value = readTranscript(runtime);
    return value?.copilotSessionId === next && value.turns.length === 2 && value;
  }, "rotated transcript missing");
  assert.equal("droppedTurns" in rotated, false);
});

test("a restarted tracker restores its dropped-turn buffer with the transcript", {
  concurrency: false,
}, async (t) => {
  const turn = (id, offset) => ({
    id,
    startedAt: new Date(1_700_000_000_000 + offset).toISOString(),
    endedAt: new Date(1_700_000_000_500 + offset).toISOString(),
    kind: "foreground",
    userContent: id,
    assistantMessages: [],
    tools: [],
    isAborted: false,
  });
  const dropped = [turn("evicted-1", 0), turn("evicted-2", 1_000)];
  const runtime = await createRuntime(t, (session, runtime) => {
    // No SDK history: the restored snapshot is all the tracker has.
    session.getEvents = async () => { throw new Error("history unavailable"); };
    realWriteFileSync(
      join(runtime.sessions, `${runtime.appSessionId}.transcript.json`),
      JSON.stringify({
        schemaVersion: 3,
        updatedAt: new Date(1_700_000_010_000).toISOString(),
        copilotSessionId: runtime.copilotSessionId,
        turns: [turn("kept-1", 5_000), turn("kept-2", 6_000)],
        droppedTurns: dropped,
      })
    );
  });
  await waitFor(() => readTranscript(runtime)?.ownerPid === process.pid, "restored transcript not republished");
  const restored = readTranscript(runtime);
  assert.deepEqual(restored.turns.map((entry) => entry.id), ["kept-1", "kept-2"]);
  assert.deepEqual(restored.droppedTurns, dropped);
});

function transcriptFileIdentity(path) {
  const stats = fs.statSync(path, { bigint: true });
  return `${stats.ino}:${stats.size}:${stats.mtimeNs}`;
}

async function startPendingTurn(runtime, content = "first") {
  await runtime.session.emit("user.message", { content: "work" });
  await runtime.session.emit("assistant.turn_start");
  await runtime.session.emit("assistant.message", { messageId: content, content });
  return waitFor(() => {
    const turn = readTranscript(runtime)?.turns.at(-1);
    return turn?.endedAt === null
      && turn.assistantMessages.some((message) => message.content === content)
      && turn;
  }, "in-progress turn missing");
}

test("an in-progress turn rewrites only the live transcript file", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  const sealedPath = transcriptFile(runtime);
  const livePath = liveTranscriptFile(sealedPath);
  await startPendingTurn(runtime);
  const sealedBefore = transcriptFileIdentity(sealedPath);
  const liveBefore = transcriptFileIdentity(livePath);
  const sealed = JSON.parse(realReadFileSync(sealedPath, "utf8"));
  assert.equal(sealed.schemaVersion, 4);
  assert.equal(sealed.turns.some((turn) => turn.endedAt === null), false);

  await runtime.session.emit("tool.execution_start", { toolCallId: "tool", toolName: "view" });
  await runtime.session.emit("tool.execution_complete", { toolCallId: "tool", success: true });
  await waitFor(() => readTranscript(runtime)?.turns.at(-1)?.tools[0]?.success, "tool update missing");
  assert.equal(transcriptFileIdentity(sealedPath), sealedBefore, "the sealed file was rewritten mid-turn");
  assert.notEqual(transcriptFileIdentity(livePath), liveBefore);

  await runtime.session.emit("session.idle");
  await waitFor(() => !realExistsSync(livePath), "the live file outlived its turn");
  const finished = JSON.parse(realReadFileSync(sealedPath, "utf8")).turns.at(-1);
  assert.ok(finished.endedAt);
  assert.deepEqual(finished.tools.map((tool) => tool.id), ["tool"]);
});

test("a publish that changes nothing rewrites neither transcript file", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await startPendingTurn(runtime);
  const writes = [];
  runtime.failWrite = (path) => {
    if (path.includes(".transcript")) writes.push(path);
    return false;
  };
  // A loop iteration ending flushes progress without changing the turn.
  await runtime.session.emit("assistant.turn_end");
  await new Promise((resolve) => setTimeout(resolve, 600));
  assert.deepEqual(writes, []);

  await runtime.session.emit("assistant.message", { messageId: "second", content: "second" });
  await waitFor(() => writes.length > 0, "a changed turn was not published");
  assert.ok(writes.every((path) => path.includes(".transcript-live.json.")), writes.join(","));
});

test("a restarted tracker restores the in-progress turn from a matching live file", {
  concurrency: false,
}, async (t) => {
  const turn = (id, endedAt) => ({
    id,
    startedAt: new Date(1_700_000_000_000).toISOString(),
    endedAt,
    kind: "foreground",
    userContent: id,
    assistantMessages: [],
    tools: [],
    isAborted: false,
  });
  for (const [baseRevision, expected] of [
    ["sealed-revision", ["kept", "pending"]],
    ["previous-revision", ["kept", "pending"]],
    ["unrelated-revision", ["kept"]],
  ]) {
    const runtime = await createRuntime(t, (session, runtime) => {
      session.getEvents = async () => { throw new Error("history unavailable"); };
      const sealedPath = join(runtime.sessions, `${runtime.appSessionId}.transcript.json`);
      realWriteFileSync(sealedPath, JSON.stringify({
        schemaVersion: 4,
        copilotSessionId: runtime.copilotSessionId,
        ownerPid: 1,
        turns: [turn("kept", new Date(1_700_000_000_500).toISOString())],
        updatedAt: new Date(1_700_000_010_000).toISOString(),
        revision: "sealed-revision",
        previousRevision: "previous-revision",
      }));
      realWriteFileSync(liveTranscriptFile(sealedPath), JSON.stringify({
        schemaVersion: 1,
        copilotSessionId: runtime.copilotSessionId,
        baseRevision,
        updatedAt: new Date(1_700_000_010_000).toISOString(),
        turn: turn("pending", null),
      }));
    });
    const restored = await waitFor(() => {
      const value = readTranscript(runtime);
      return value?.ownerPid === process.pid && value;
    }, "restored transcript not republished");
    assert.deepEqual(restored.turns.map((entry) => entry.id), expected, baseRevision);
    assert.equal(realExistsSync(liveTranscriptFile(transcriptFile(runtime))), false, baseRevision);
  }
});

test("a restarted tracker reads the live file first, so a sealed rewrite between the reads keeps the turn", {
  concurrency: false,
}, async (t) => {
  const turn = (id, endedAt, content = id) => ({
    id,
    startedAt: new Date(1_700_000_000_000).toISOString(),
    endedAt,
    kind: "foreground",
    userContent: content,
    assistantMessages: [],
    tools: [],
    isAborted: false,
  });
  const ended = new Date(1_700_000_000_500).toISOString();
  const sealedDocument = (runtime, turns, revision, previousRevision) => JSON.stringify({
    schemaVersion: 4,
    copilotSessionId: runtime.copilotSessionId,
    ownerPid: 1,
    turns,
    updatedAt: new Date(1_700_000_010_000).toISOString(),
    revision,
    previousRevision,
  });
  const liveDocument = (runtime, baseRevision, content) => JSON.stringify({
    schemaVersion: 1,
    copilotSessionId: runtime.copilotSessionId,
    baseRevision,
    updatedAt: new Date(1_700_000_010_000).toISOString(),
    turn: turn("pending", null, content),
  });
  // What the tracker writes between the restore's two reads: the turn
  // sealed with the live file gone, or a sealed advance mid-turn that names
  // the live file's previous base before the live file is rewritten.
  const rewrites = {
    sealed: (runtime, sealedPath) => {
      realWriteFileSync(sealedPath, sealedDocument(
        runtime, [turn("kept", ended), turn("pending", ended)], "r2", "r2"
      ));
      realRmSync(liveTranscriptFile(sealedPath));
    },
    advanced: (runtime, sealedPath) => {
      realWriteFileSync(sealedPath, sealedDocument(runtime, [turn("kept", ended)], "r2", "r1"));
      realWriteFileSync(liveTranscriptFile(sealedPath), liveDocument(runtime, "r2", "second"));
    },
  };
  for (const [name, rewrite] of Object.entries(rewrites)) {
    const runtime = await createRuntime(t, (session, runtime) => {
      session.getEvents = async () => { throw new Error("history unavailable"); };
      const sealedPath = join(runtime.sessions, `${runtime.appSessionId}.transcript.json`);
      realWriteFileSync(sealedPath, sealedDocument(runtime, [turn("kept", ended)], "r1", "r1"));
      realWriteFileSync(liveTranscriptFile(sealedPath), liveDocument(runtime, "r1", "first"));
      let rewritten = false;
      runtime.afterRead = (path) => {
        if (rewritten || !/\.transcript(-live)?\.json$/.test(path)) return;
        rewritten = true;
        rewrite(runtime, sealedPath);
      };
    });
    const restored = await waitFor(() => {
      const value = readTranscript(runtime);
      return value?.ownerPid === process.pid && value;
    }, "restored transcript not republished");
    assert.deepEqual(restored.turns.map((entry) => entry.id), ["kept", "pending"], name);
  }
});

test("a failed live write after the sealed file advances keeps the turn visible", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  const sealedPath = transcriptFile(runtime);
  await startPendingTurn(runtime, "first");
  const first = JSON.parse(realReadFileSync(sealedPath, "utf8"));
  assert.equal(
    JSON.parse(realReadFileSync(liveTranscriptFile(sealedPath), "utf8")).baseRevision,
    first.revision
  );

  // Another process replaces the sealed file, so the next publish rewrites
  // it under a new revision, and the live rewrite that should follow fails.
  realWriteFileSync(`${sealedPath}.foreign`, realReadFileSync(sealedPath));
  fs.renameSync(`${sealedPath}.foreign`, sealedPath);
  runtime.failWrite = (path) => path.includes(".transcript-live.json.");
  await runtime.session.emit("assistant.message", { messageId: "second", content: "second" });
  const advanced = await waitFor(() => {
    const value = JSON.parse(realReadFileSync(sealedPath, "utf8"));
    return value.revision !== first.revision && value;
  }, "the sealed file was not republished");
  assert.equal(advanced.previousRevision, first.revision);
  assert.deepEqual(
    readTranscript(runtime).turns.at(-1).assistantMessages.map((message) => message.content),
    ["first"],
    "the last published state of the turn stays visible"
  );

  runtime.failWrite = null;
  await runtime.session.emit("assistant.message", { messageId: "third", content: "third" });
  await waitFor(() => readTranscript(runtime)?.turns.at(-1)?.assistantMessages
    .some((message) => message.content === "third"), "the live file was not repaired");
});

test("a conversation rotation discards the previous conversation's live file", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await startPendingTurn(runtime);
  const livePath = liveTranscriptFile(transcriptFile(runtime));
  assert.ok(realExistsSync(livePath));

  const next = uuid();
  runtime.session.foregroundSessionId = next;
  runtime.session.history = humanHistory("next", numbered("next", 2), 1_700_200_000_000);
  await runtime.session.emit("session.start", { sessionId: next });
  await waitFor(() => readTranscript(runtime)?.copilotSessionId === next, "rotated transcript missing");
  assert.equal(realExistsSync(livePath), false);
});

test("losing durable authority before its baseline keeps the restored dropped-turn buffer", {
  concurrency: false,
}, async (t) => {
  const turn = (id, offset) => ({
    id,
    startedAt: new Date(1_700_000_000_000 + offset).toISOString(),
    endedAt: new Date(1_700_000_000_500 + offset).toISOString(),
    kind: "foreground",
    userContent: id,
    assistantMessages: [],
    tools: [],
    isAborted: false,
  });
  const dropped = [turn("evicted-1", 0), turn("evicted-2", 1_000)];
  const runtime = await createRuntime(t, (session, runtime) => {
    realWriteFileSync(
      join(runtime.sessions, `${runtime.appSessionId}.transcript.json`),
      JSON.stringify({
        schemaVersion: 3,
        updatedAt: new Date(1_700_000_010_000).toISOString(),
        copilotSessionId: runtime.copilotSessionId,
        turns: [turn("kept-1", 5_000), turn("kept-2", 6_000)],
        droppedTurns: dropped,
      })
    );
    const directory = join(runtime.root, "copilot-home", "session-state", runtime.copilotSessionId);
    realMkdirSync(directory, { recursive: true });
    realWriteFileSync(join(directory, "events.jsonl"), `${JSON.stringify({
      id: uuid(), type: "session.info", timestamp: new Date().toISOString(), data: {},
    })}\n`);
    // The durable file vanishes as its first replay opens it: that replay
    // fails before completing a baseline, and the next one loses authority
    // and falls back to the restored state.
    runtime.beforeDurableRead = (path) => realRmSync(path, { force: true });
  });
  const savedEnvironment = saveEnvironment(["COPILOT_HOME"]);
  process.env.COPILOT_HOME = join(runtime.root, "copilot-home");
  t.after(() => restoreEnvironment(savedEnvironment));
  // Startup ends by scheduling that next replay on a zero-delay timer, which
  // fires (and synchronously loses authority) before this longer one.
  await new Promise((resolve) => setTimeout(resolve, 20));

  await runtime.session.emit("user.message", { content: "live" }, { id: "live" });
  await runtime.session.emit("session.idle", { aborted: false });
  const published = await waitFor(() => {
    const value = readTranscript(runtime);
    return value?.turns.at(-1)?.id === "live" && value?.turns.at(-1)?.endedAt && value;
  }, "live turn missing");
  assert.deepEqual(published.turns.map((entry) => entry.id), ["kept-1", "kept-2", "live"]);
  assert.deepEqual(published.droppedTurns, dropped);
});

function snapshotTurn(id, offset) {
  return {
    id,
    startedAt: new Date(1_700_000_000_000 + offset).toISOString(),
    endedAt: new Date(1_700_000_000_500 + offset).toISOString(),
    kind: "foreground",
    userContent: id,
    assistantMessages: [],
    tools: [],
    isAborted: false,
  };
}

function writeRestoredTranscript(runtime, turns, droppedTurns) {
  realWriteFileSync(transcriptFile(runtime), JSON.stringify({
    schemaVersion: 3,
    updatedAt: new Date(1_700_000_010_000).toISOString(),
    copilotSessionId: runtime.copilotSessionId,
    turns,
    droppedTurns,
  }));
}

function durableJournal(runtime) {
  return join(runtime.root, "copilot-home", "session-state", runtime.copilotSessionId, "events.jsonl");
}

// `createRuntime` restores COPILOT_HOME once startup returns; the 5s poll
// must keep resolving this runtime's journal, never the developer's.
function pinCopilotHome(t, runtime) {
  const savedEnvironment = saveEnvironment(["COPILOT_HOME"]);
  process.env.COPILOT_HOME = join(runtime.root, "copilot-home");
  t.after(() => restoreEnvironment(savedEnvironment));
}

// Runs 5s polls that find no durable journal around live turns: one that
// completes between polls and one still streaming while a poll runs. Losing
// durable authority does not publish, so a final live turn forces the
// transcript out before anything is asserted.
async function liveTurnsAcrossMissingJournalPolls(runtime, earlierTurnIds) {
  const poll = async () => {
    runtime.intervalCallback();
    // The poll reconciles on a zero-delay timer.
    await new Promise((resolve) => setTimeout(resolve, 20));
  };
  await poll();
  await runtime.session.emit("user.message", { content: "live 1" }, { id: "live-1" });
  await runtime.session.emit("assistant.turn_start");
  await runtime.session.emit("assistant.message", { messageId: "reply-1", content: "done 1" });
  await runtime.session.emit("session.idle", { aborted: false });
  await poll();
  await runtime.session.emit("user.message", { content: "live 2" }, { id: "live-2" });
  await runtime.session.emit("assistant.turn_start");
  await runtime.session.emit("assistant.message_delta", { messageId: "reply-2", deltaContent: "partial" });
  await poll();
  await runtime.session.emit("assistant.message", { messageId: "reply-2", content: "done 2" });
  await runtime.session.emit("session.idle", { aborted: false });
  await poll();
  await runtime.session.emit("user.message", { content: "live 3" }, { id: "live-3" });
  await runtime.session.emit("session.idle", { aborted: false });
  const published = await waitFor(() => {
    const value = readTranscript(runtime);
    return value?.turns.at(-1)?.id === "live-3" && value.turns.at(-1).endedAt && value;
  }, "final live turn missing");
  assert.deepEqual(
    published.turns.map((turn) => turn.id),
    [...earlierTurnIds, "live-1", "live-2", "live-3"]
  );
  const replies = (id) => published.turns.find((turn) => turn.id === id).assistantMessages
    .map((message) => message.content);
  assert.deepEqual(replies("live-1"), ["done 1"]);
  assert.deepEqual(replies("live-2"), ["done 2"]);
  return published;
}

test("polls without a durable journal keep SDK history, its model, and live turns", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session) => {
    session.history = [
      { id: "model", type: "session.model_change", timestamp: new Date(1_699_999_999_000).toISOString(),
        data: { newModel: "fixture-model", reasoningEffort: "high" } },
      ...humanHistory("history", ["history 0", "history 1"]),
    ];
  });
  pinCopilotHome(t, runtime);
  await waitFor(() => readTranscript(runtime)?.turns.length === 2, "SDK history missing");

  await liveTurnsAcrossMissingJournalPolls(runtime, ["history-0", "history-1"]);
  assert.deepEqual(readSnapshot(runtime).model, { name: "fixture-model", reasoningEffort: "high" });
});

test("polls without a durable journal keep a restored transcript and its dropped turns", {
  concurrency: false,
}, async (t) => {
  const dropped = [snapshotTurn("evicted-1", 0), snapshotTurn("evicted-2", 1_000)];
  const runtime = await createRuntime(t, (session, runtime) => {
    session.getEvents = async () => { throw new Error("history unavailable"); };
    writeRestoredTranscript(runtime, [snapshotTurn("kept-1", 5_000), snapshotTurn("kept-2", 6_000)], dropped);
  });
  pinCopilotHome(t, runtime);
  await waitFor(() => readTranscript(runtime)?.ownerPid === process.pid, "restored transcript not republished");

  const published = await liveTurnsAcrossMissingJournalPolls(runtime, ["kept-1", "kept-2"]);
  assert.deepEqual(published.droppedTurns, dropped);
});

test("polls after a completed durable baseline loses its journal keep later live turns", {
  concurrency: false,
}, async (t) => {
  const event = (id, type, data) => ({ id, type, timestamp: new Date().toISOString(), data });
  const durableTurn = (id) => [
    event(id, "user.message", { content: `${id} task` }),
    event(`${id}-reply`, "assistant.message", { messageId: `${id}-reply`, content: `${id} result` }),
    event(`${id}-idle`, "session.idle", {}),
  ].map((entry) => `${JSON.stringify(entry)}\n`).join("");
  const runtime = await createRuntime(t, (session, runtime) => {
    const journal = durableJournal(runtime);
    realMkdirSync(join(journal, ".."), { recursive: true });
    realWriteFileSync(journal, durableTurn("durable"));
  });
  pinCopilotHome(t, runtime);
  await waitFor(() => runtime.durableReadsFinished > 0
    && readTranscript(runtime)?.turns.at(-1)?.id === "durable"
    && readTranscript(runtime).turns.at(-1).endedAt, "durable baseline missing");

  // An incremental read after the baseline does not refresh the fallback,
  // so rolling back on this loss would drop the appended turn.
  const readsBefore = runtime.durableReadsFinished;
  fs.appendFileSync(durableJournal(runtime), durableTurn("appended"));
  runtime.intervalCallback();
  await waitFor(() => runtime.durableReadsFinished > readsBefore
    && readTranscript(runtime)?.turns.at(-1)?.id === "appended"
    && readTranscript(runtime).turns.at(-1).endedAt, "incremental durable turn missing");

  realRmSync(durableJournal(runtime), { force: true });
  await liveTurnsAcrossMissingJournalPolls(runtime, ["durable", "appended"]);
});

test("polls after an incomplete durable replay rolls back keep later live turns", {
  concurrency: false,
}, async (t) => {
  const dropped = [snapshotTurn("evicted-1", 0), snapshotTurn("evicted-2", 1_000)];
  const runtime = await createRuntime(t, (session, runtime) => {
    writeRestoredTranscript(runtime, [snapshotTurn("kept-1", 5_000), snapshotTurn("kept-2", 6_000)], dropped);
    const journal = durableJournal(runtime);
    realMkdirSync(join(journal, ".."), { recursive: true });
    realWriteFileSync(journal, `${JSON.stringify({
      id: uuid(), type: "session.info", timestamp: new Date().toISOString(), data: {},
    })}\n`);
    // The first replay fails mid-read; startup's follow-up reconcile then
    // loses authority and rolls back to the restored state.
    runtime.beforeDurableRead = (path) => realRmSync(path, { force: true });
  });
  pinCopilotHome(t, runtime);
  await waitFor(() => runtime.durableReadsFinished > 0, "durable replay never started");
  await new Promise((resolve) => setTimeout(resolve, 20));

  const published = await liveTurnsAcrossMissingJournalPolls(runtime, ["kept-1", "kept-2"]);
  assert.deepEqual(published.droppedTurns, dropped);
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
  await waitFor(() => readMergedTranscript(transcript).turns
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
  await waitFor(() => readMergedTranscript(transcript).turns
    .find((turn) => turn.id === liveID)?.assistantMessages.some((message) => message.content === "new final text"),
  "live text did not follow the new turn after the journal caught up", 4_000);
  const previousTurn = readMergedTranscript(transcript).turns.find((turn) => turn.id === pendingID);
  assert.equal(previousTurn.assistantMessages.some((message) => message.content.startsWith("new ")), false);
});

function transcriptTurnsOf(runtime) {
  return readTranscript(runtime)?.turns ?? [];
}

const queryFailure = {
  errorType: "query",
  message: "Execution failed: 400 internal server error (Request ID: 00000-f881)",
  statusCode: 400,
  providerCallId: "00000-f881",
};

test("a failed request marks its turn and the session until the next request", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  const request = await runtime.session.emit("user.message", { content: "record my voice" });
  await runtime.session.emit("assistant.turn_start", { turnId: "60" });
  await runtime.session.emit("assistant.message", { messageId: "progress", content: "Capturing playback." });
  await runtime.session.emit("tool.execution_start", { toolCallId: "capture", toolName: "bash" });
  await runtime.session.emit("tool.execution_complete", { toolCallId: "capture", success: true });
  await runtime.session.emit("assistant.turn_end", { turnId: "60" });
  await runtime.session.emit("assistant.turn_start", { turnId: "61" });
  await runtime.session.emit("assistant.turn_end", { turnId: "61" });
  const failure = await runtime.session.emit("session.error", queryFailure);
  await runtime.session.emit("session.idle");

  const failed = await waitFor(() => {
    const turn = transcriptTurnsOf(runtime).find((entry) => entry.id === request.id);
    return turn?.endedAt && turn.error && turn;
  }, "the failed request was not marked");
  const expected = {
    message: queryFailure.message,
    errorType: "query",
    timestamp: failure.timestamp,
    statusCode: 400,
  };
  assert.deepEqual(failed.error, expected);
  assert.deepEqual(failed.assistantMessages.map((message) => message.content), ["Capturing playback."]);
  assert.equal(failed.tools.length, 1);
  await waitFor(() => readSnapshot(runtime).lastTurnError, "the session did not report the failure");
  assert.deepEqual(readSnapshot(runtime).lastTurnError, expected);

  const next = await runtime.session.emit("user.message", { content: "Keep going!" });
  assert.equal(readSnapshot(runtime).lastTurnError, undefined);
  await waitFor(() => transcriptTurnsOf(runtime).some((turn) => turn.id === next.id),
    "the next request did not reach the transcript");
  const turns = transcriptTurnsOf(runtime);
  assert.deepEqual(turns.find((turn) => turn.id === request.id).error, expected);
  assert.equal("error" in turns.find((turn) => turn.id === next.id), false);
});

test("failures the agent recovers from within a request are cleared", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  const request = await runtime.session.emit("user.message", { content: "retry" });
  await runtime.session.emit("assistant.turn_start", { turnId: "1" });
  await runtime.session.emit("assistant.turn_end", { turnId: "1" });
  await runtime.session.emit("session.error", queryFailure);
  await runtime.session.emit("assistant.turn_start", { turnId: "2" });
  await runtime.session.emit("assistant.message", { messageId: "done", content: "Done after all." });
  await runtime.session.emit("session.idle");
  const turn = await waitFor(() => {
    const entry = transcriptTurnsOf(runtime).find((candidate) => candidate.id === request.id);
    return entry?.endedAt && entry;
  }, "the recovered request did not finish");
  assert.equal("error" in turn, false);
  assert.equal(readSnapshot(runtime).lastTurnError, undefined);
});

test("failures outside a request get their own entry, and diagnostics are ignored", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  const request = await runtime.session.emit("user.message", { content: "finish" });
  await runtime.session.emit("assistant.message", { messageId: "answer", content: "Finished." });
  await runtime.session.emit("session.idle");
  await waitFor(() => transcriptTurnsOf(runtime).find((turn) => turn.id === request.id)?.endedAt,
    "the request did not finish");

  await runtime.session.emit("session.error", {
    errorType: "model-provider-labels", message: "Failed to read model provider attribution",
  });
  await runtime.session.emit("session.error", {
    errorType: "persistence", message: "Failed to persist session events",
  }, { ephemeral: true });
  await runtime.session.emit("session.error", {
    errorType: "model_call", message: "Retrying",
  });
  await runtime.session.emit("session.error", queryFailure, { agentId: "background-1" });
  const gate = await runtime.session.emit("session.error", {
    errorType: "authentication",
    message: "You must be logged in to send messages. Please run /login",
  });

  const standalone = await waitFor(
    () => transcriptTurnsOf(runtime).find((turn) => turn.id === gate.id),
    "the out-of-request failure did not get its own entry"
  );
  assert.equal(standalone.kind, "automated");
  assert.equal(standalone.userContent, "");
  assert.equal(standalone.endedAt, gate.timestamp);
  assert.deepEqual(standalone.error, {
    message: "You must be logged in to send messages. Please run /login",
    errorType: "authentication",
    timestamp: gate.timestamp,
  });
  const turns = transcriptTurnsOf(runtime);
  assert.equal(turns.filter((turn) => turn.error).length, 1);
  assert.equal("error" in turns.find((turn) => turn.id === request.id), false);
  await waitFor(() => readSnapshot(runtime).lastTurnError?.errorType === "authentication",
    "the session did not report the out-of-request failure");
});

test("durable replay attributes failures by the live request boundary", {
  concurrency: false,
}, async (t) => {
  const event = (id, type, data, offset) => ({
    id, type, timestamp: new Date(Date.UTC(2026, 9, 10, 23, 37, offset)).toISOString(), data,
  });
  const runtime = await createRuntime(t, (session, fixture) => {
    const directory = join(fixture.root, "copilot-home", "session-state", fixture.copilotSessionId);
    realMkdirSync(directory, { recursive: true });
    realWriteFileSync(join(directory, "events.jsonl"), [
      event("done", "user.message", { content: "earlier" }, 0),
      event("done-answer", "assistant.message", { messageId: "a", content: "Earlier answer." }, 1),
      // A pre-send gate after an answer is its own entry.
      event("gate-error", "session.error", {
        errorType: "authentication", message: "You must be logged in to send messages.",
      }, 1.5),
      // The reported shape: progress, a failed retry, then the error.
      event("failed", "user.message", { content: "record my voice" }, 2),
      event("failed-start", "assistant.turn_start", { turnId: "60" }, 3),
      event("failed-progress", "assistant.message", { messageId: "p", content: "Capturing playback." }, 4),
      event("failed-end", "assistant.turn_end", { turnId: "60" }, 5),
      event("failed-retry", "assistant.turn_start", { turnId: "61" }, 6),
      event("failed-retry-end", "assistant.turn_end", { turnId: "61" }, 7),
      event("failed-error", "session.error", queryFailure, 8),
      // A background agent restarts the loop before the request ends.
      event("recovered", "user.message", { content: "fan out" }, 9),
      event("recovered-progress", "assistant.message", { messageId: "r", content: "Waiting on agents." }, 10),
      event("recovered-error", "session.error", { ...queryFailure, statusCode: 500 }, 11),
      event("recovered-wake", "system.notification", { content: "Agent finished" }, 12),
      event("recovered-start", "assistant.turn_start", { turnId: "1" }, 13),
      event("recovered-answer", "assistant.message", { messageId: "s", content: "Completed." }, 14),
      event("recovered-end", "assistant.turn_end", { turnId: "1" }, 14.5),
      // A prompt hook fails before the next request is sent.
      event("hook-start", "hook.start", { hookType: "userPromptTransformed" }, 15),
      event("hook-end", "hook.end", { hookType: "userPromptTransformed", success: false }, 16),
      event("hook-error", "session.error", { errorType: "query", message: "Prompt hook failed" }, 17),
      // A request with no answer yet owns the failure that follows it.
      event("unanswered", "user.message", { content: "try again" }, 18),
      event("unanswered-start", "assistant.turn_start", { turnId: "0" }, 19),
      event("unanswered-end", "assistant.turn_end", { turnId: "0" }, 20),
      event("unanswered-error", "session.error", { ...queryFailure, statusCode: 503 }, 21),
      // A sessionStart hook runs after the prompt's message; its failure is
      // that request's.
      event("starting", "user.message", { content: "new session" }, 21.2),
      event("starting-hook", "hook.start", { hookType: "sessionStart" }, 21.4),
      event("starting-hook-end", "hook.end", { hookType: "sessionStart", success: false }, 21.6),
      event("starting-error", "session.error", { errorType: "query", message: "sessionStart hook failed" }, 21.8),
      // A Mission Control prompt starts a new request without a user turn.
      event("remote", "user.message", { content: "remote", source: "command-1" }, 22),
      event("remote-start", "assistant.turn_start", { turnId: "0" }, 23),
      event("remote-answer", "assistant.message", { messageId: "m", content: "Remote reply." }, 24),
    ].map((entry) => JSON.stringify(entry)).join("\n") + "\n");
  });
  const home = process.env.COPILOT_HOME;
  process.env.COPILOT_HOME = join(runtime.root, "copilot-home");
  t.after(() => {
    if (home === undefined) delete process.env.COPILOT_HOME;
    else process.env.COPILOT_HOME = home;
  });
  await workflowReady(runtime);

  // A restarted tracker never saw these requests live.
  const turns = await waitFor(() => {
    const current = transcriptTurnsOf(runtime);
    return current.some((turn) => turn.assistantMessages.some((m) => m.content === "Remote reply."))
      && current;
  }, "cold replay did not finish", 4_000);
  const byId = (id) => turns.find((turn) => turn.id === id);
  assert.equal("error" in byId("done"), false);
  assert.equal(byId("gate-error")?.kind, "automated");
  assert.equal(byId("gate-error").error.errorType, "authentication");
  assert.equal(byId("failed").error?.statusCode, 400);
  assert.equal("error" in byId("recovered"), false, "a recovered failure must clear");
  assert.equal(byId("hook-error")?.kind, "automated");
  assert.equal(byId("hook-error").error.message, "Prompt hook failed");
  assert.equal(byId("unanswered").error?.statusCode, 503);
  assert.equal(byId("starting").error?.message, "sessionStart hook failed");
  const remote = turns.find((turn) => turn.assistantMessages.some((m) => m.content === "Remote reply."));
  assert.notEqual(remote.id, "unanswered");
  assert.equal("error" in remote, false);
  for (const id of ["failed-error", "recovered-error", "unanswered-error", "starting-error"]) {
    assert.equal(byId(id), undefined, id);
  }
  await waitFor(() => readSnapshot(runtime).workflow, "the heartbeat did not settle", 4_000);
  assert.equal(readSnapshot(runtime).lastTurnError, undefined);

  // Delivered live inside a request, the failure belongs to that request.
  const journal = join(runtime.root, "copilot-home", "session-state", runtime.copilotSessionId, "events.jsonl");
  const append = (...events) => fs.appendFileSync(
    journal, events.map((entry) => JSON.stringify(entry)).join("\n") + "\n"
  );
  const request = await runtime.session.emit("user.message", { content: "Keep going!" });
  const start = await runtime.session.emit("assistant.turn_start", { turnId: "0" });
  const end = await runtime.session.emit("assistant.turn_end", { turnId: "0" });
  const live = await runtime.session.emit("session.error", queryFailure);
  append(request, start, end, live);
  const marked = await waitFor(
    () => transcriptTurnsOf(runtime).find((turn) => turn.id === request.id)?.error,
    "the live failure did not mark its request", 4_000
  );
  assert.equal(marked.timestamp, live.timestamp);
  assert.equal(transcriptTurnsOf(runtime).some((turn) => turn.id === live.id), false);

  // Durable replay never sees the idle that ended it; live delivery knows the
  // next failure came after the request, so it is its own entry.
  await runtime.session.emit("session.idle");
  const hook = await runtime.session.emit("session.error", {
    errorType: "query", message: "userPromptTransformed hook failed",
  });
  append(hook);
  const standalone = await waitFor(
    () => transcriptTurnsOf(runtime).find((turn) => turn.id === hook.id),
    "the post-request failure did not get its own entry", 4_000
  );
  assert.equal(standalone.error.message, "userPromptTransformed hook failed");
  assert.deepEqual(transcriptTurnsOf(runtime).find((turn) => turn.id === request.id).error, marked);
});

test("a later request without a user turn neither clears nor inherits a failure", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session, fixture) => {
    const directory = join(fixture.root, "copilot-home", "session-state", fixture.copilotSessionId);
    realMkdirSync(directory, { recursive: true });
    realWriteFileSync(join(directory, "events.jsonl"), JSON.stringify({
      id: "earlier", type: "user.message", timestamp: new Date().toISOString(),
      data: { content: "earlier" },
    }) + "\n");
  });
  const home = process.env.COPILOT_HOME;
  process.env.COPILOT_HOME = join(runtime.root, "copilot-home");
  t.after(() => {
    if (home === undefined) delete process.env.COPILOT_HOME;
    else process.env.COPILOT_HOME = home;
  });
  await workflowReady(runtime);
  const journal = join(runtime.root, "copilot-home", "session-state", runtime.copilotSessionId, "events.jsonl");
  // Durable mode: every event but the ephemeral idle reaches the journal.
  const emit = async (type, data, extra) => {
    const event = await runtime.session.emit(type, data, extra);
    if (type !== "session.idle") fs.appendFileSync(journal, JSON.stringify(event) + "\n");
    return event;
  };
  const turnWith = (content) => transcriptTurnsOf(runtime).find((turn) =>
    turn.assistantMessages.some((message) => message.content === content));

  const failed = await emit("user.message", { content: "record my voice" });
  await emit("assistant.turn_start", { turnId: "0" });
  await emit("assistant.message", { messageId: "progress", content: "Capturing playback." });
  await emit("assistant.turn_end", { turnId: "0" });
  await emit("session.error", queryFailure);
  await emit("session.idle");
  const failure = await waitFor(
    () => transcriptTurnsOf(runtime).find((turn) => turn.id === failed.id)?.error,
    "the failure was not recorded", 4_000
  );

  // A remote command is not a transcript boundary, but it is a new request.
  await emit("user.message", { content: "remote", source: "command-1" });
  await emit("assistant.turn_start", { turnId: "0" });
  await emit("assistant.message", { messageId: "remote", content: "Remote reply." });
  await emit("assistant.turn_end", { turnId: "0" });
  const reply = await waitFor(() => turnWith("Remote reply."), "the remote reply was not recorded", 4_000);
  assert.notEqual(reply.id, failed.id);
  assert.equal("error" in reply, false);
  assert.deepEqual(transcriptTurnsOf(runtime).find((turn) => turn.id === failed.id).error, failure);
  await emit("session.idle");
  await waitFor(() => readSnapshot(runtime).lastTurnError === undefined,
    "the earlier failure still marked the session", 4_000);

  await emit("user.message", { content: "remote again", source: "command-2" });
  await emit("assistant.turn_start", { turnId: "0" });
  await emit("assistant.turn_end", { turnId: "0" });
  await emit("session.error", { ...queryFailure, statusCode: 503 });
  await emit("session.idle");
  const second = await waitFor(
    () => transcriptTurnsOf(runtime).find((turn) => turn.error?.statusCode === 503),
    "the second failure was not recorded", 4_000
  );
  assert.notEqual(second.id, failed.id);
  assert.notEqual(second.id, reply.id);
  assert.equal("error" in transcriptTurnsOf(runtime).find((turn) => turn.id === reply.id), false);
});

test("background agents keep a failure quiet until the request ends", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await runtime.session.emit("user.message", { content: "fan out" });
  await runtime.session.emit("assistant.turn_start", { turnId: "0" });
  await runtime.session.emit("assistant.turn_start", { turnId: "0" }, { agentId: "reviewer" });
  await runtime.session.emit("assistant.turn_end", { turnId: "0" });
  await runtime.session.emit("session.error", queryFailure);
  await runtime.session.emit("assistant.idle");
  assert.equal(readSnapshot(runtime).foregroundTurnActive, false);
  assert.equal(readSnapshot(runtime).lastTurnError, undefined);
  await runtime.session.emit("session.idle");
  await waitFor(() => readSnapshot(runtime).lastTurnError?.statusCode === 400,
    "the failure did not appear once the request ended");
});

test("a tracker started mid-request does not split it at the next turn start", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t, (session, fixture) => {
    const directory = join(fixture.root, "copilot-home", "session-state", fixture.copilotSessionId);
    realMkdirSync(directory, { recursive: true });
    realWriteFileSync(join(directory, "events.jsonl"), [
      { id: "running", type: "user.message", data: { content: "long task" } },
      { id: "running-start", type: "assistant.turn_start", data: { turnId: "0" } },
      { id: "running-progress", type: "assistant.message", data: { messageId: "a", content: "Working." } },
      { id: "running-end", type: "assistant.turn_end", data: { turnId: "0" } },
    ].map((entry) => JSON.stringify({ ...entry, timestamp: new Date().toISOString() })).join("\n") + "\n");
  });
  const home = process.env.COPILOT_HOME;
  process.env.COPILOT_HOME = join(runtime.root, "copilot-home");
  t.after(() => {
    if (home === undefined) delete process.env.COPILOT_HOME;
    else process.env.COPILOT_HOME = home;
  });
  await workflowReady(runtime);
  const journal = join(runtime.root, "copilot-home", "session-state", runtime.copilotSessionId, "events.jsonl");
  for (const [type, data] of [
    ["assistant.turn_start", { turnId: "1" }],
    ["assistant.message", { messageId: "b", content: "Still the same request." }],
  ]) {
    fs.appendFileSync(journal, JSON.stringify(await runtime.session.emit(type, data)) + "\n");
  }
  const turn = await waitFor(() => transcriptTurnsOf(runtime).find((entry) =>
    entry.assistantMessages.some((message) => message.content === "Still the same request.")),
  "the continuation was not recorded", 4_000);
  assert.equal(turn.id, "running");
});

test("an attached shell keeps a failure quiet until the request ends", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await runtime.session.emit("user.message", { content: "build in the background" });
  await runtime.session.emit("assistant.turn_start", { turnId: "0" });
  await runtime.session.emit("assistant.turn_end", { turnId: "0" });
  await runtime.session.emit("session.error", queryFailure);
  await runtime.session.emit("assistant.idle");
  assert.equal(readSnapshot(runtime).foregroundTurnActive, false);
  assert.equal(readSnapshot(runtime).lastTurnError, undefined);
  await runtime.session.emit("session.idle");
  assert.equal(readSnapshot(runtime).lastTurnError?.statusCode, 400,
    "the idle publish must already see the request as ended");
});

for (const durable of [false, true]) {
  test(`a queued prompt's hook failure never marks the request before it (${durable ? "durable" : "live"})`, {
    concurrency: false,
  }, async (t) => {
    const runtime = await createRuntime(t, (session, fixture) => {
      if (!durable) return;
      const directory = join(fixture.root, "copilot-home", "session-state", fixture.copilotSessionId);
      realMkdirSync(directory, { recursive: true });
      realWriteFileSync(join(directory, "events.jsonl"), JSON.stringify({
        id: "earlier", type: "user.message", timestamp: new Date().toISOString(),
        data: { content: "earlier" },
      }) + "\n");
    });
    let journal = null;
    if (durable) {
      const home = process.env.COPILOT_HOME;
      process.env.COPILOT_HOME = join(runtime.root, "copilot-home");
      t.after(() => {
        if (home === undefined) delete process.env.COPILOT_HOME;
        else process.env.COPILOT_HOME = home;
      });
      await workflowReady(runtime);
      journal = join(runtime.root, "copilot-home", "session-state", runtime.copilotSessionId, "events.jsonl");
    }
    const emit = async (type, data, extra) => {
      const event = await runtime.session.emit(type, data, extra);
      if (journal && type !== "session.idle") fs.appendFileSync(journal, JSON.stringify(event) + "\n");
      return event;
    };
    const first = await emit("user.message", { content: "first" });
    await emit("assistant.turn_start", { turnId: "0" });
    await emit("assistant.message", { messageId: "a", content: "First answer." });
    await emit("assistant.turn_end", { turnId: "0" });
    // The queued prompt's hook runs before the request above goes idle.
    await emit("hook.start", { hookType: "userPromptTransformed" });
    await emit("hook.end", { hookType: "userPromptTransformed", success: false });
    const hook = await emit("session.error", { errorType: "query", message: "Prompt hook failed" });
    await emit("session.idle");
    const entry = await waitFor(
      () => transcriptTurnsOf(runtime).find((turn) => turn.id === hook.id),
      "the queued prompt's failure did not get its own entry", 4_000
    );
    assert.equal(entry.error.message, "Prompt hook failed");
    assert.equal("error" in transcriptTurnsOf(runtime).find((turn) => turn.id === first.id), false);
  });
}

test("a failure outlives the turn cap and a later resume notice", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  for (let index = 0; index < 200; index += 1) {
    await runtime.session.emit("user.message", { content: `request ${index}` });
    await runtime.session.emit("assistant.message", { messageId: `answer-${index}`, content: "Done." });
    await runtime.session.emit("session.idle");
  }
  const gate = await runtime.session.emit("session.error", {
    errorType: "authentication", message: "You must be logged in to send messages.",
  });
  const turns = await waitFor(() => {
    const current = transcriptTurnsOf(runtime);
    return current.at(-1)?.id === gate.id && current;
  }, "the failure was trimmed from a full transcript");
  assert.equal(turns.length, 200);
  assert.equal(turns[0].userContent, "request 1");
  await waitFor(() => readSnapshot(runtime).lastTurnError?.errorType === "authentication",
    "a full transcript hid the failure");

  await runtime.session.emit("session.resume", {});
  await waitFor(() => transcriptTurnsOf(runtime).at(-1)?.id.startsWith("session-resume-"),
    "the resume notice did not appear");
  await runtime.session.emit("session.usage_info", { currentTokens: 1, tokenLimit: 10 });
  assert.equal(readSnapshot(runtime).lastTurnError?.errorType, "authentication",
    "a resume notice is not a request that succeeded");
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
    session.questionEvents.push({
      ...questionEvent("elicitation.requested", question),
      // Older than the durable ask_user, so suppression relies on the matching toolCallId.
      timestamp: "2026-08-31T23:59:59.000Z",
    });
  });
  await waitFor(() => readSnapshot(runtime).trackedElicitations.length === 1
    && readSnapshot(runtime).trackedElicitations[0].requestId === question.requestId,
  "late attach did not recover the real form");
  let snapshot = readSnapshot(runtime);
  assert.equal(snapshot.trackedElicitations.length, 1);
  assert.equal(snapshot.trackedElicitations[0].requestId, question.requestId);
  assert.deepEqual(snapshot.trackedElicitations[0].schema, {
    ...question.requestedSchema,
    "x-copilot-projects-property-order": ["url"],
  });
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

test("published form schemas record the agent's property order and drop forged orders", {
  concurrency: false,
}, async (t) => {
  const question = {
    requestId: "ordered",
    message: "Where does it happen?",
    requestedSchema: {
      type: "object",
      properties: {
        where: { type: "string" },
        symptom: { type: "string" },
        example: { type: "string" },
      },
      "x-copilot-projects-property-order": ["example"],
    },
  };
  const unorderable = (requestId, extra) => ({
    requestId,
    message: "Anything else?",
    requestedSchema: {
      type: "object",
      ...extra,
      "x-copilot-projects-property-order": ["forged"],
    },
  });
  const runtime = await createRuntime(t, (session) => {
    for (const data of [
      question,
      unorderable("no-properties", {}),
      unorderable("array-properties", { properties: [] }),
    ]) {
      session.questionEvents.push(questionEvent("elicitation.requested", data));
    }
  });
  await waitFor(() => readSnapshot(runtime).trackedElicitations.length === 3,
    "recovered forms were not published");
  const entries = readSnapshot(runtime).trackedElicitations;
  const schemaFor = (requestId) =>
    entries.find((entry) => entry.requestId === requestId)?.schema;
  assert.deepEqual(schemaFor("ordered")["x-copilot-projects-property-order"], [
    "where", "symptom", "example",
  ]);
  assert.deepEqual(schemaFor("ordered").properties, question.requestedSchema.properties);
  assert.deepEqual(schemaFor("no-properties"), { type: "object" });
  assert.deepEqual(schemaFor("array-properties"), { type: "object", properties: [] });
});

test("unsupported or failed cursor recovery keeps the original terminal fallback", {
  concurrency: false,
}, async (t) => {
  for (const error of [
    Object.assign(new Error("method not found"), { code: -32601 }),
    new Error("event log unavailable"),
  ]) {
    const runtime = await createRuntime(t, (session, runtime) => {
      writeDurableQuestion(runtime);
      session.questionEventHandler = async () => { throw error; };
    });
    await waitFor(() => runtime.session.questionEventCalls.length > 0, "cursor read was not attempted");
    await new Promise((resolve) => setImmediate(resolve));
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
    session.questionEvents.push({
      ...questionEvent("elicitation.requested", pendingURLQuestion("other", "different-tool")),
      // Older than the durable ask_user, so only a matching toolCallId could suppress it.
      timestamp: "2026-08-31T23:59:59.000Z",
    });
  });
  await waitFor(() => readSnapshot(runtime).trackedElicitations.length === 2,
    "unrelated question was not recovered");
  assert.deepEqual(readSnapshot(runtime).trackedElicitations.map((entry) => entry.requestId), [
    "other", "synthetic::durable-ask-user::call-url",
  ]);
});

test("cursor reads recover text, boolean, choice, and multiselect when live notifications disappear", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
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

test("idle heartbeats publish liveness at once and then the observation taken that tick", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await waitForActivity(runtime, (activity) => activity?.processing === false);
  const calls = runtime.session.runtimeCalls.length;
  const writes = runtime.activityWrites.length;
  const previous = readSnapshot(runtime).workflow.observedAtMilliseconds;
  await new Promise((resolve) => setTimeout(resolve, 5));
  const tickStart = Date.now();
  runtime.intervalCallback();
  // Liveness is written before the tick's query can answer.
  assert.equal(runtime.activityWrites.length - writes, 1);
  assert.equal(runtime.activityWrites.at(-1).workflow.observedAtMilliseconds, previous);
  await waitFor(() => runtime.activityWrites.length - writes >= 2, "observation was not published");
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(runtime.session.runtimeCalls.length - calls, 2);
  assert.equal(runtime.activityWrites.length - writes, 2);
  const published = runtime.activityWrites.at(-1);
  assert.ok(published.workflow.observedAtMilliseconds >= tickStart);
  assert.equal(published.runtimeActivity.observedAtMilliseconds, published.workflow.observedAtMilliseconds);
  assert.ok(Date.parse(published.updatedAt) - published.workflow.observedAtMilliseconds < 2_000);
  assert.ok(published.workflow.capabilities.includes("session-send"));
  assert.equal(published.workflow.sendReady, true);
});

test("a hung runtime query never delays a heartbeat's liveness publish", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await waitForActivity(runtime, (activity) => activity?.processing === false);
  let release;
  runtime.session.processingHandler = () => new Promise((resolve) => { release = resolve; });
  const writes = runtime.activityWrites.length;
  const previous = readSnapshot(runtime).workflow.observedAtMilliseconds;
  await new Promise((resolve) => setTimeout(resolve, 5));
  const firstTick = Date.now();
  runtime.intervalCallback();
  assert.equal(runtime.activityWrites.length - writes, 1);
  assert.equal(typeof release, "function", "the tick did not start its query");
  const calls = runtime.session.runtimeCalls.length;
  await new Promise((resolve) => setTimeout(resolve, 5));
  const secondTick = Date.now();
  runtime.intervalCallback();
  assert.equal(runtime.activityWrites.length - writes, 2);
  for (const [index, tick] of [firstTick, secondTick].entries()) {
    const liveness = runtime.activityWrites[writes + index];
    assert.ok(Date.parse(liveness.updatedAt) >= tick);
    assert.equal(liveness.workflow.observedAtMilliseconds, previous);
  }
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(runtime.session.runtimeCalls.length, calls, "the hung query was not single-flight");
  assert.equal(runtime.activityWrites.length - writes, 2);

  release({ processing: false });
  await waitFor(() => runtime.activityWrites.length - writes >= 3, "observation was not published");
  await new Promise((resolve) => setTimeout(resolve, 20));
  // Both ticks joined one query, so it adds one write, not one per tick.
  assert.equal(runtime.activityWrites.length - writes, 3);
  const published = runtime.activityWrites.at(-1);
  assert.ok(published.workflow.observedAtMilliseconds >= firstTick);
  assert.ok(published.workflow.observedAtMilliseconds < secondTick);
});

test("a heartbeat observation that is not newer adds no write", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await waitForActivity(runtime, (activity) => activity?.processing === false);
  const calls = runtime.session.runtimeCalls.length;
  const writes = runtime.activityWrites.length;
  const previous = readSnapshot(runtime).workflow.observedAtMilliseconds;
  Date.now = () => previous;
  t.after(() => { Date.now = originalDateNow; });
  runtime.intervalCallback();
  await waitFor(() => runtime.session.runtimeCalls.length >= calls + 2, "poll did not run");
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(runtime.activityWrites.length - writes, 1);
  assert.equal(readSnapshot(runtime).workflow.observedAtMilliseconds, previous);
});

test("an older runtime read never overwrites a newer workflow observation", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await workflowReady(runtime);
  await waitForActivity(runtime, (activity) => activity?.processing === false);
  let release;
  runtime.session.sessionLimits = { maxAiCredits: 30 };
  runtime.session.processingHandler = () => new Promise((resolve) => { release = resolve; });
  runtime.intervalCallback();
  assert.equal(typeof release, "function", "the tick did not start its query");
  await new Promise((resolve) => setTimeout(resolve, 5));
  runtime.session.sessionLimits = { maxAiCredits: 60 };
  await runtime.session.emit("session.session_limits_changed", {});
  const newer = await waitFor(() => {
    const workflow = readSnapshot(runtime).workflow;
    return workflow.maxAiCredits === 60 && workflow;
  }, "the workflow refresh was not published");
  const writes = runtime.activityWrites.length;
  release({ processing: false });
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(runtime.activityWrites.length, writes, "an older read published");
  runtime.session.processingHandler = async () => ({ processing: false });
  runtime.intervalCallback();
  const liveness = runtime.activityWrites[writes];
  assert.equal(liveness.workflow.observedAtMilliseconds, newer.observedAtMilliseconds);
  assert.equal(liveness.workflow.maxAiCredits, 60);
});

test("turn transitions and transient RPC errors keep fresh workflow capabilities intact", {
  concurrency: false,
}, async (t) => {
  const runtime = await createRuntime(t);
  await workflowReady(runtime);
  await waitForActivity(runtime, (activity) => activity?.processing === false);

  // 1. user.message and assistant.turn_start publish before refreshRuntimeActivity resolves;
  //    neither intermediate write may strip session-send while the observation is fresh.
  let releaseProcessing;
  runtime.session.processingHandler = () => new Promise((resolve) => { releaseProcessing = resolve; });
  const beforeTurnWrites = runtime.activityWrites.length;
  await runtime.session.emit("user.message", { content: "follow up" });
  await runtime.session.emit("assistant.turn_start", { turnId: "0" });
  const turnWrites = runtime.activityWrites.slice(beforeTurnWrites);
  assert.ok(turnWrites.length >= 2);
  for (const snapshot of turnWrites) {
    assert.equal(snapshot.runtimeActivity.error, "pending");
    assert.ok(snapshot.workflow.capabilities.includes("session-send"));
    assert.equal(snapshot.workflow.sendReady, true);
  }
  runtime.session.processingHandler = async () => ({ processing: true });
  releaseProcessing({ processing: true });
  await waitForActivity(runtime, (activity) => activity?.processing === true);

  // 2. A heartbeat metadata read interrupted by a turn transition still advances
  //    workflow observation immediately, even while the follow-up processing retry is in flight.
  const baselineObservedAt = readSnapshot(runtime).workflow.observedAtMilliseconds;
  await new Promise((resolve) => setTimeout(resolve, 5));
  let releaseInterrupted;
  runtime.session.processingHandler = () => new Promise((resolve) => { releaseInterrupted = resolve; });
  runtime.intervalCallback();
  await waitFor(() => releaseInterrupted, "heartbeat query did not start");
  await runtime.session.emit("assistant.idle");
  let releaseRetry;
  runtime.session.processingHandler = () => new Promise((resolve) => { releaseRetry = resolve; });
  releaseInterrupted({ processing: true });
  await waitFor(
    () => readSnapshot(runtime).workflow.observedAtMilliseconds > baselineObservedAt,
    "heartbeat metadata did not advance workflow observation across turn transition"
  );
  await waitFor(() => releaseRetry, "retry query did not start");
  runtime.session.processingHandler = async () => ({ processing: false });
  releaseRetry({ processing: false });
  await waitForActivity(runtime, (activity) => activity?.processing === false);

  // 3. A transient workflow refresh error preserves existing capabilities and retries on the next tick.
  let metadataFailures = 0;
  runtime.session.metadataHandler = async () => {
    metadataFailures += 1;
    throw new Error("workflow-read-timeout");
  };
  await runtime.session.emit("session.usage_checkpoint", { totalNanoAiu: 5e9 });
  await waitFor(() => metadataFailures > 0, "workflow refresh did not attempt metadata read");
  await new Promise((resolve) => setImmediate(resolve));
  assert.ok(readSnapshot(runtime).workflow.capabilities.includes("session-send"));
  runtime.session.sessionLimits = { maxAiCredits: 90 };
  runtime.session.usageHandler = async () => ({ totalNanoAiu: 7e9 });
  runtime.session.metadataHandler = async ({ sessionId }) => ({
    sessionId, isRemote: false, sessionLimits: runtime.session.sessionLimits,
  });
  runtime.intervalCallback();
  await waitFor(
    () => {
      const workflow = readSnapshot(runtime).workflow;
      return workflow.maxAiCredits === 90 && workflow.totalAiCredits === 7;
    },
    "transient workflow refresh failure did not retry on the next heartbeat"
  );

  // 4. An older workflow refresh waiting on usage merges usage without rewinding a newer heartbeat.
  let releaseUsage;
  runtime.session.usageHandler = () => new Promise((resolve) => { releaseUsage = resolve; });
  await runtime.session.emit("session.usage_checkpoint", { totalNanoAiu: 11e9 });
  await waitFor(() => releaseUsage, "workflow usage query did not start");
  await new Promise((resolve) => setTimeout(resolve, 5));
  delete runtime.session.sessionLimits;
  runtime.session.metadataHandler = async ({ sessionId }) => ({ sessionId, isRemote: false });
  runtime.intervalCallback();
  await waitFor(
    () => readSnapshot(runtime).workflow.limitsKnown === false,
    "heartbeat did not update limitsKnown"
  );
  const heartbeatObservedAt = readSnapshot(runtime).workflow.observedAtMilliseconds;
  releaseUsage({ totalNanoAiu: 11e9 });
  await waitFor(
    () => readSnapshot(runtime).workflow.totalAiCredits === 11,
    "workflow refresh did not publish merged usage"
  );
  const merged = readSnapshot(runtime).workflow;
  assert.equal(merged.observedAtMilliseconds, heartbeatObservedAt);
  assert.equal(merged.limitsKnown, false);
  assert.equal(merged.maxAiCredits, null);
  assert.equal(merged.capabilities.includes("set-session-budget"), false);

  // 5. A user.message after a remote-session heartbeat preserves the remote error until locality recovers.
  runtime.session.metadataHandler = async ({ sessionId }) => ({ sessionId, isRemote: true });
  runtime.intervalCallback();
  await waitForActivity(runtime, (activity) => activity?.error === "remote");
  assert.deepEqual(readSnapshot(runtime).workflow.capabilities, []);
  assert.equal(readSnapshot(runtime).workflow.legacyPromptFallback, true);
  let releaseRemoteTurn;
  runtime.session.processingHandler = () => new Promise((resolve) => { releaseRemoteTurn = resolve; });
  await runtime.session.emit("user.message", { content: "still remote" });
  assert.equal(readSnapshot(runtime).runtimeActivity.error, "remote");
  assert.deepEqual(readSnapshot(runtime).workflow.capabilities, []);
  assert.equal(readSnapshot(runtime).workflow.legacyPromptFallback, true);
  releaseRemoteTurn?.({ processing: false });
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

// A displaceable owner forces the tracker through the owner lock to claim.
function seedDeadOwner(runtime) {
  const ownerPath = join(runtime.sessions, `${runtime.appSessionId}.transcript-owner.json`);
  realWriteFileSync(ownerPath, JSON.stringify({
    appSessionId: runtime.appSessionId,
    copilotSessionId: uuid(),
    pid: 0,
  }));
  return ownerPath;
}

test("another process holding the owner lock blocks the claim until it dies", async (t) => {
  let holder;
  let lockPath;
  const runtime = await createRuntime(t, async (_session, runtime) => {
    lockPath = `${seedDeadOwner(runtime)}.flock`;
    // O_EXLOCK is 0x20 in Darwin <fcntl.h>; Node doesn't export it.
    holder = spawn(process.execPath, ["-e", `
      const { openSync, constants: c } = require("node:fs");
      openSync(${JSON.stringify(lockPath)}, c.O_RDWR | c.O_CREAT | c.O_NONBLOCK | 0x20, 0o600);
      process.stdout.write("locked");
      setInterval(() => {}, 1_000);
    `]);
    t.after(() => holder.kill("SIGKILL"));
    const [output] = await once(holder.stdout, "data");
    assert.equal(String(output), "locked");
  }, { ready: false });
  assert.equal(realExistsSync(runtime.snapshotPath), false);
  runtime.intervalCallback();
  assert.equal(realExistsSync(runtime.snapshotPath), false);

  holder.kill("SIGKILL");
  await once(holder, "exit");
  assert.equal(realExistsSync(lockPath), true);
  runtime.intervalCallback();
  await waitFor(
    () => realExistsSync(runtime.snapshotPath),
    "tracker did not claim once the lock holder died"
  );
  assert.equal(
    JSON.parse(realReadFileSync(runtime.ownerPath, "utf8")).copilotSessionId,
    runtime.copilotSessionId
  );
});

test("an owner lock file unlinked before it was locked does not admit a claim", async (t) => {
  let lockPath;
  const runtime = await createRuntime(t, (_session, runtime) => {
    lockPath = `${seedDeadOwner(runtime)}.flock`;
    // Leaves the tracker locking an unlinked file, as when host cleanup lands
    // between the tracker's lookup and its lock.
    runtime.afterOpen = (path) => { if (path === lockPath) realRmSync(path, { force: true }); };
  }, { ready: false });
  runtime.intervalCallback();
  assert.equal(realExistsSync(runtime.snapshotPath), false);

  runtime.afterOpen = null;
  runtime.intervalCallback();
  await waitFor(
    () => realExistsSync(runtime.snapshotPath),
    "tracker did not claim once its lock file stayed linked"
  );
});
