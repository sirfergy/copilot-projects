import assert from "node:assert/strict";
import fs from "node:fs";
import { registerHooks, syncBuiltinESMExports } from "node:module";
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import test from "node:test";

import {
  repositoryRoot,
  trackerResourceDir,
} from "./support/fragments.mjs";

const extensionPath = join(trackerResourceDir, "extension.mjs");
const runtimeParent = join(repositoryRoot, "JSTests", ".tracker-operation-runtime");
const runtimes = new Set();
const originalDateNow = Date.now;
const originalSetInterval = globalThis.setInterval;
const originalClearInterval = globalThis.clearInterval;
const originalWatch = fs.watch;
const originalWriteFileSync = fs.writeFileSync;
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
  return originalWriteFileSync(path, ...args);
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
      sendRequest: async () => ({ sessionId: this.sessionId }),
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

  async emit(type, data = {}, extra = {}) {
    const event = {
      id: randomUUID(),
      type,
      timestamp: new Date().toISOString(),
      data,
      ...extra,
    };
    const pending = [];
    for (const listener of this.namedListeners.get(type) ?? []) {
      pending.push(listener(event));
    }
    for (const listener of this.genericListeners) {
      pending.push(listener(event));
    }
    await Promise.all(pending.filter((value) => value?.then));
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
  };
  runtime.session = new FakeSession(runtime.copilotSessionId);
  configure(runtime.session);
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

  try {
    await import(`${pathToFileURL(extensionPath).href}?runtime=${uuid()}`);
  } finally {
    globalThis.setInterval = savedSetInterval;
    globalThis.clearInterval = savedClearInterval;
    delete globalThis.__copilotProjectsTrackerSession;
    restoreEnvironment(savedEnvironment);
    removeAddedProcessListeners(listenersBefore);
  }

  runtime.snapshotPath = join(
    sessions,
    `${runtime.appSessionId}.agent-activity.json`
  );
  runtime.userInputPath = join(
    sessions,
    `${runtime.appSessionId}.user-input-response.json`
  );
  runtime.elicitationPath = join(
    sessions,
    `${runtime.appSessionId}.elicitation-response.json`
  );
  runtime.modelPath = join(
    sessions,
    `${runtime.appSessionId}.set-model-request.json`
  );
  runtime.ownerPath = join(
    sessions,
    `${runtime.appSessionId}.transcript-owner.json`
  );
  await waitFor(
    () => realExistsSync(runtime.snapshotPath),
    "tracker did not publish its initial snapshot"
  );
  await waitFor(
    () => readSnapshot(runtime).availableModels?.length === 1,
    "tracker did not publish the fake SDK model catalog"
  );

  t.after(() => {
    runtimes.delete(runtime);
    realRmSync(root, { recursive: true, force: true });
  });
  return runtime;
}

function readSnapshot(runtime) {
  return JSON.parse(realReadFileSync(runtime.snapshotPath, "utf8"));
}

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

function requestClose(runtime) {
  const name = `${runtime.appSessionId}.close-session-request`;
  realWriteFileSync(join(runtime.sessions, name), "");
  trigger(runtime, name);
}

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
      const requestId = `request-${uuid()}`;
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

test("terminal receipts expire at 64 while accepted receipts remain and bound new work", {
  concurrency: false,
}, async (t) => {
  let clock = 1_000_000;
  Date.now = () => clock;
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
  let terminalReceipts = readSnapshot(terminalRuntime).operationReceipts;
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
  terminalReceipts = readSnapshot(terminalRuntime).operationReceipts;
  assert.deepEqual(terminalReceipts, []);

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
