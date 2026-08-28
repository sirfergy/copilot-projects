import assert from "node:assert/strict";
import test from "node:test";

import { bindings, fixture, loadFragments, plain } from "./support/fragments.mjs";

const NAMES = [
  "REMOTE_OPERATION_SUPPORT",
  "negotiatedOperationSupport",
  "isSyntheticDurableElicitation",
  "remoteOperationControlMessage",
  "remoteOperationMessage",
  "createOperationController",
];

function operationClient(ids = []) {
  const loaded = bindings(loadFragments(["operations"]), NAMES);
  let next = 0;
  return {
    ...loaded,
    controller: loaded.createOperationController({
      newOperationId: () => ids[next++] || `operation-${next}`,
    }),
    issuedCount: () => next,
  };
}

function session(workspace) {
  return workspace.projects[0].sessions[0];
}

function receiptPlan(controller, overrides = {}) {
  return controller.prepare({
    sessionId: "tab",
    conversationEpoch: "tracker-instance:2",
    support: "receipts",
    kind: "answer-user-input",
    targetId: "question-1",
    payloadContext: '{"requestId":"question-1","answer":"Yes","wasFreeform":false}',
    ...overrides,
  });
}

test("operation support negotiation matches the shared Swift contract", () => {
  const { negotiatedOperationSupport } = operationClient();
  const legacy = fixture("legacy-workspace");
  const receipts = fixture("receipt-workspace");
  const unavailable = fixture("unavailable-workspace");

  assert.equal(negotiatedOperationSupport(legacy.protocolInfo, session(legacy)), "legacy");
  assert.equal(
    negotiatedOperationSupport(receipts.protocolInfo, session(receipts)),
    "receipts"
  );
  assert.equal(
    negotiatedOperationSupport(unavailable.protocolInfo, session(unavailable)),
    "unavailable"
  );
  assert.equal(
    negotiatedOperationSupport(receipts.protocolInfo, {
      ...session(receipts),
      operationSupport: undefined,
    }),
    "unavailable",
    "a receipt-capable host cannot silently fall back when tracker state is absent"
  );
  assert.equal(
    negotiatedOperationSupport(receipts.protocolInfo, {
      ...session(receipts),
      operationSupport: "receipts",
      conversationEpoch: "",
    }),
    "unavailable"
  );
  assert.equal(
    negotiatedOperationSupport(receipts.protocolInfo, {
      ...session(receipts),
      operationSupport: "future-mode",
    }),
    "unavailable",
    "unknown support modes fail closed"
  );
  assert.equal(
    negotiatedOperationSupport(receipts.protocolInfo, {
      ...session(receipts),
      operationSupport: "legacy",
    }),
    "legacy",
    "an explicit legacy tracker remains legacy"
  );
});

test("receipt requests keep the old data JSON and add only outer correlation", () => {
  const { controller, remoteOperationControlMessage } = operationClient(["operation-1"]);
  const data = '{"requestId":"question-1","answer":"Yes","wasFreeform":false}';
  const plan = receiptPlan(controller, { payloadContext: data });
  const message = plain(
    remoteOperationControlMessage("answer-user-input", "tab", data, plan)
  );

  assert.deepStrictEqual(message, {
    type: "answer-user-input",
    sessionId: "tab",
    data,
    requestId: "operation-1",
    conversationEpoch: "tracker-instance:2",
  });
  assert.equal(message.data, data);
  assert.ok(!("payloadFingerprint" in message));
});

test("every SDK operation keeps its exact control type and payload", () => {
  const { controller, remoteOperationControlMessage } = operationClient([
    "input-operation",
    "elicitation-operation",
    "model-operation",
  ]);
  const cases = [
    ["answer-user-input", "question-1", '{"answer":"Yes"}'],
    ["answer-elicitation", "elicitation-1", '{"action":"accept"}'],
    ["set-model", "model-picker", '{"modelId":"gpt-5.6-sol"}'],
  ];

  for (const [kind, targetId, data] of cases) {
    const plan = receiptPlan(controller, {
      kind,
      targetId,
      payloadContext: data,
    });
    assert.deepStrictEqual(
      plain(remoteOperationControlMessage(kind, "tab", data, plan)),
      {
        type: kind,
        sessionId: "tab",
        data,
        requestId: plan.record.operationId,
        conversationEpoch: "tracker-instance:2",
      }
    );
  }
});

test("legacy and synthetic durable requests never attach receipt metadata", () => {
  const {
    controller,
    isSyntheticDurableElicitation,
    remoteOperationControlMessage,
  } = operationClient(["must-not-be-issued"]);
  const request = {
    requestId: "synthetic::durable-ask-user::abc",
    mode: "terminal-default",
  };
  assert.equal(isSyntheticDurableElicitation(request), true);
  assert.equal(isSyntheticDurableElicitation({
    requestId: "ordinary-request",
    mode: "terminal-default",
  }), false);
  assert.equal(isSyntheticDurableElicitation({
    requestId: "synthetic::other-source",
  }), false);

  const plan = controller.prepare({
    sessionId: "tab",
    conversationEpoch: "tracker-instance:2",
    support: "receipts",
    kind: "answer-elicitation",
    targetId: request.requestId,
    payloadContext: '{"requestId":"synthetic::durable-ask-user::abc"}',
    forceLegacy: true,
  });
  const message = plain(
    remoteOperationControlMessage("answer-elicitation", "tab", "{}", plan)
  );

  assert.equal(plan.mode, "legacy");
  assert.deepStrictEqual(message, {
    type: "answer-elicitation",
    sessionId: "tab",
    data: "{}",
  });
  assert.equal(controller.records().length, 0);

  const unavailableSynthetic = controller.prepare({
    sessionId: "tab",
    conversationEpoch: null,
    support: "unavailable",
    kind: "answer-elicitation",
    targetId: request.requestId,
    payloadContext: "{}",
    forceLegacy: true,
  });
  assert.equal(
    unavailableSynthetic.mode,
    "legacy",
    "the guarded terminal fallback does not depend on SDK receipt availability"
  );

  const ordinaryLegacy = controller.prepare({
    sessionId: "tab",
    conversationEpoch: null,
    support: "legacy",
    kind: "answer-user-input",
    targetId: "question-1",
    payloadContext: '{"requestId":"question-1"}',
  });
  assert.equal(ordinaryLegacy.mode, "legacy");
  assert.equal(controller.records().length, 0);
});

test("a duplicate click reuses the pending record without issuing another id", () => {
  const { controller, issuedCount } = operationClient(["operation-1", "operation-2"]);
  const first = receiptPlan(controller);
  const duplicate = receiptPlan(controller);

  assert.equal(first.mode, "receipts");
  assert.equal(duplicate.mode, "duplicate");
  assert.equal(duplicate.record.operationId, first.record.operationId);
  assert.equal(issuedCount(), 1, "a duplicate UI action must not clone the RPC");
});

test("HTTP 204 means host-accepted, while every ambiguous result is indeterminate", () => {
  const { controller } = operationClient(["operation-1", "operation-2"]);
  const accepted = receiptPlan(controller);
  assert.equal(
    controller.resolveHTTP(accepted.record.operationId, 204).outcome,
    "accepted"
  );
  assert.equal(accepted.record.state, "accepted");

  const ambiguous = receiptPlan(controller, { targetId: "question-2" });
  assert.equal(
    controller.resolveHTTP(ambiguous.record.operationId, 200).outcome,
    "indeterminate",
    "an unexpected success code is not proof the SDK applied the operation"
  );
  assert.equal(ambiguous.record.payloadContext, null);
  assert.match(
    operationClient().remoteOperationMessage(ambiguous.record),
    /check the terminal/i
  );
});

test("epoch or auth invalidation fences a late HTTP response and clears payloads", () => {
  const { controller } = operationClient(["operation-1"]);
  const plan = receiptPlan(controller);
  assert.ok(plan.record.payloadContext);

  controller.invalidateAll();

  assert.equal(plan.record.payloadContext, null);
  assert.equal(controller.records().length, 0);
  assert.equal(
    controller.resolveHTTP(plan.record.operationId, 204).outcome,
    "stale"
  );

  const nextEpoch = receiptPlan(controller, {
    conversationEpoch: "tracker-instance:3",
  });
  assert.equal(nextEpoch.mode, "receipts");
  assert.notEqual(nextEpoch.record.operationId, plan.record.operationId);
  assert.equal(
    controller.reconcile({
      id: "tab",
      operationSupport: "receipts",
      conversationEpoch: "tracker-instance:3",
      operationReceipts: [{
        operationId: plan.record.operationId,
        conversationEpoch: "tracker-instance:2",
        kind: "answer-user-input",
        state: "applied",
        updatedAtMilliseconds: 1,
      }],
    }, fixture("receipt-workspace").protocolInfo).length,
    0,
    "an old epoch receipt cannot complete the new conversation's operation"
  );
});

test("receipt matching is exact and independent of receipt array order", () => {
  const { controller } = operationClient(["operation-1"]);
  const plan = receiptPlan(controller);
  controller.resolveHTTP(plan.record.operationId, 204);
  const transitions = controller.reconcile({
    id: "tab",
    operationSupport: "receipts",
    conversationEpoch: "tracker-instance:2",
    operationReceipts: [
      {
        operationId: "operation-1",
        conversationEpoch: "wrong-epoch",
        kind: "answer-user-input",
        state: "rejected",
        updatedAtMilliseconds: 30,
      },
      {
        operationId: "operation-1",
        conversationEpoch: "tracker-instance:2",
        kind: "set-model",
        state: "rejected",
        updatedAtMilliseconds: 40,
      },
      {
        operationId: "operation-1",
        conversationEpoch: "tracker-instance:2",
        kind: "answer-user-input",
        state: "applied",
        updatedAtMilliseconds: 20,
      },
      {
        operationId: "operation-1",
        conversationEpoch: "tracker-instance:2",
        kind: "answer-user-input",
        state: "accepted",
        updatedAtMilliseconds: 10,
      },
    ],
  }, fixture("receipt-workspace").protocolInfo);

  assert.equal(transitions.length, 1);
  assert.equal(transitions[0].state, "applied");
  assert.equal(plan.record.state, "applied");
  assert.equal(plan.record.payloadContext, null);
});

test("the canonical receipt fixture drives every terminal state by operation id", () => {
  const workspace = fixture("receipt-workspace");
  const receiptSession = session(workspace);
  const ids = receiptSession.operationReceipts.map((receipt) => receipt.operationId);
  const { controller } = operationClient(ids);
  const plans = [
    receiptPlan(controller, { kind: "answer-user-input", targetId: "input" }),
    receiptPlan(controller, { kind: "answer-elicitation", targetId: "elicitation" }),
    receiptPlan(controller, { kind: "set-model", targetId: "model-a" }),
    receiptPlan(controller, { kind: "set-model", targetId: "model-b" }),
  ];

  controller.reconcile(receiptSession, workspace.protocolInfo);

  assert.deepStrictEqual(
    plans.map((plan) => plan.record.state),
    ["accepted", "applied", "rejected", "indeterminate"]
  );
});

test("accepted operations survive question disappearance until a terminal receipt", () => {
  const { controller } = operationClient(["operation-1"]);
  const plan = receiptPlan(controller);
  controller.resolveHTTP(plan.record.operationId, 204);
  const target = {
    sessionId: "tab",
    conversationEpoch: "tracker-instance:2",
    kind: "answer-user-input",
    targetId: "question-1",
  };

  assert.equal(controller.shouldPreserveTarget(target), true);
  controller.pruneSettledTargets({ ...target, visibleTargetIds: new Set() });
  assert.equal(controller.records().length, 1);
});

test("an indeterminate target is released once the workspace removes it", () => {
  const { controller } = operationClient(["operation-1"]);
  const plan = receiptPlan(controller);
  controller.markIndeterminate(plan.record.operationId, "receipt-timeout");
  const target = {
    sessionId: "tab",
    conversationEpoch: "tracker-instance:2",
    kind: "answer-user-input",
    targetId: "question-1",
  };
  assert.equal(controller.shouldPreserveTarget(target), true);

  controller.pruneSettledTargets({ ...target, visibleTargetIds: new Set() });

  assert.equal(controller.records().length, 0);
  assert.equal(receiptPlan(controller).mode, "receipts");
});

test("applied clears UI state, rejected permits explicit retry, and unknown blocks it", () => {
  const { controller, issuedCount } = operationClient([
    "operation-applied",
    "operation-rejected",
    "operation-retry",
    "operation-unknown",
  ]);
  const protocolInfo = fixture("receipt-workspace").protocolInfo;

  const applied = receiptPlan(controller, { targetId: "applied-question" });
  controller.reconcile({
    id: "tab",
    operationSupport: "receipts",
    conversationEpoch: "tracker-instance:2",
    operationReceipts: [{
      operationId: applied.record.operationId,
      conversationEpoch: "tracker-instance:2",
      kind: "answer-user-input",
      state: "applied",
      updatedAtMilliseconds: 1,
    }],
  }, protocolInfo);
  assert.equal(controller.shouldSuppressTarget({
    sessionId: "tab",
    conversationEpoch: "tracker-instance:2",
    kind: "answer-user-input",
    targetId: "applied-question",
  }), true);

  const rejected = receiptPlan(controller, { targetId: "retry-question" });
  controller.reconcile({
    id: "tab",
    operationSupport: "receipts",
    conversationEpoch: "tracker-instance:2",
    operationReceipts: [{
      operationId: rejected.record.operationId,
      conversationEpoch: "tracker-instance:2",
      kind: "answer-user-input",
      state: "rejected",
      updatedAtMilliseconds: 2,
      errorCode: "invalid-request",
    }],
  }, protocolInfo);
  const retry = receiptPlan(controller, { targetId: "retry-question" });
  assert.equal(retry.mode, "receipts");
  assert.notEqual(retry.record.operationId, rejected.record.operationId);

  const unknown = receiptPlan(controller, { targetId: "unknown-question" });
  controller.reconcile({
    id: "tab",
    operationSupport: "receipts",
    conversationEpoch: "tracker-instance:2",
    operationReceipts: [{
      operationId: unknown.record.operationId,
      conversationEpoch: "tracker-instance:2",
      kind: "answer-user-input",
      state: "future-state",
      updatedAtMilliseconds: 3,
    }],
  }, protocolInfo);
  const blocked = receiptPlan(controller, { targetId: "unknown-question" });
  assert.equal(unknown.record.state, "indeterminate");
  assert.equal(blocked.mode, "duplicate");
  assert.equal(blocked.record.operationId, unknown.record.operationId);
  assert.equal(issuedCount(), 4);
});

test("bounded pending records reject new work instead of evicting live operations", () => {
  const { createOperationController } = operationClient();
  let next = 0;
  const controller = createOperationController({
    maxRecords: 2,
    newOperationId: () => `operation-${++next}`,
  });

  assert.equal(receiptPlan(controller, { targetId: "one" }).mode, "receipts");
  assert.equal(receiptPlan(controller, { targetId: "two" }).mode, "receipts");
  assert.equal(receiptPlan(controller, { targetId: "three" }).mode, "capacity");
  assert.equal(controller.records().length, 2);
});
