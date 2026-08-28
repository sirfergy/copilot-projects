const REMOTE_OPERATION_SUPPORT = Object.freeze({
  LEGACY: 'legacy',
  RECEIPTS: 'receipts',
  UNAVAILABLE: 'unavailable'
});
const REMOTE_OPERATION_STATES = new Set([
  'accepted', 'applied', 'rejected', 'indeterminate'
]);

function nonEmptyOperationToken(value) {
  return typeof value === 'string' && value.length > 0 ? value : null;
}

function negotiatedOperationSupport(protocolInfo, session) {
  const capabilities = Array.isArray(protocolInfo?.capabilities)
    ? protocolInfo.capabilities : [];
  const hostSupportsReceipts = capabilities.includes('sdk-operation-receipts');
  switch (session?.operationSupport) {
    case REMOTE_OPERATION_SUPPORT.LEGACY:
      return REMOTE_OPERATION_SUPPORT.LEGACY;
    case REMOTE_OPERATION_SUPPORT.UNAVAILABLE:
      return REMOTE_OPERATION_SUPPORT.UNAVAILABLE;
    case REMOTE_OPERATION_SUPPORT.RECEIPTS:
      return hostSupportsReceipts && nonEmptyOperationToken(session?.conversationEpoch)
        ? REMOTE_OPERATION_SUPPORT.RECEIPTS
        : REMOTE_OPERATION_SUPPORT.UNAVAILABLE;
    case undefined:
    case null:
      return hostSupportsReceipts
        ? REMOTE_OPERATION_SUPPORT.UNAVAILABLE
        : REMOTE_OPERATION_SUPPORT.LEGACY;
    default:
      return REMOTE_OPERATION_SUPPORT.UNAVAILABLE;
  }
}

function isSyntheticDurableElicitation(request) {
  return typeof request?.requestId === 'string'
    && request.requestId.startsWith('synthetic::durable-ask-user::');
}

function remoteOperationControlMessage(type, sessionId, data, plan) {
  const message = { type, sessionId, data };
  if (plan.mode === REMOTE_OPERATION_SUPPORT.RECEIPTS) {
    message.requestId = plan.record.operationId;
    message.conversationEpoch = plan.record.conversationEpoch;
  }
  return message;
}

function remoteOperationMessage(record) {
  if (!record) return '';
  if (record.state === 'submitting') return 'Sending\u2026';
  if (record.state === 'accepted') return 'Waiting for Copilot\u2026';
  if (record.state === 'indeterminate') {
    return record.kind === 'set-model'
      ? 'Model switch outcome is unknown \u2014 check the terminal.'
      : 'Outcome unknown \u2014 check the terminal before trying again.';
  }
  if (record.state === 'rejected') {
    if (record.errorCode === 'target-unavailable') {
      return 'The conversation changed before Copilot could apply this. You can try again.';
    }
    return record.kind === 'set-model'
      ? 'Copilot rejected the model switch. You can try again.'
      : 'Copilot rejected the answer. You can try again.';
  }
  return '';
}

function createOperationController(options = {}) {
  const newOperationId = options.newOperationId;
  const maxRecords = Number.isSafeInteger(options.maxRecords)
    && options.maxRecords > 0 ? options.maxRecords : 64;
  if (typeof newOperationId !== 'function') {
    throw new TypeError('newOperationId must be a function');
  }

  const records = new Map();
  let generation = 0;

  function recordIsTerminal(record) {
    return record.state === 'applied' || record.state === 'rejected';
  }

  function removeRecord(operationId) {
    const record = records.get(operationId);
    if (!record) return null;
    record.payloadContext = null;
    records.delete(operationId);
    return record;
  }

  function makeRoom() {
    for (const [operationId, record] of records) {
      if (records.size < maxRecords) break;
      if (recordIsTerminal(record)) removeRecord(operationId);
    }
    return records.size < maxRecords;
  }

  function recordsForTarget(sessionId, conversationEpoch, kind, targetId) {
    return [...records.values()].filter((record) =>
      record.sessionId === sessionId
      && record.conversationEpoch === conversationEpoch
      && record.kind === kind
      && record.targetId === targetId
    );
  }

  function latestForTarget(sessionId, conversationEpoch, kind, targetId) {
    return recordsForTarget(sessionId, conversationEpoch, kind, targetId).at(-1) || null;
  }

  function prepare({
    sessionId,
    conversationEpoch,
    support,
    kind,
    targetId,
    payloadContext,
    forceLegacy = false
  }) {
    if (forceLegacy) {
      return { mode: REMOTE_OPERATION_SUPPORT.LEGACY, record: null };
    }
    if (support === REMOTE_OPERATION_SUPPORT.UNAVAILABLE) {
      return { mode: REMOTE_OPERATION_SUPPORT.UNAVAILABLE, record: null };
    }
    if (support === REMOTE_OPERATION_SUPPORT.LEGACY) {
      return { mode: REMOTE_OPERATION_SUPPORT.LEGACY, record: null };
    }
    if (support !== REMOTE_OPERATION_SUPPORT.RECEIPTS
        || !nonEmptyOperationToken(conversationEpoch)) {
      return { mode: REMOTE_OPERATION_SUPPORT.UNAVAILABLE, record: null };
    }

    const existing = latestForTarget(
      sessionId, conversationEpoch, kind, targetId
    );
    if (existing && existing.state !== 'rejected') {
      return { mode: 'duplicate', record: existing };
    }
    if (existing) removeRecord(existing.operationId);
    if (!makeRoom()) return { mode: 'capacity', record: null };

    const operationId = newOperationId();
    if (!nonEmptyOperationToken(operationId) || records.has(operationId)) {
      return { mode: REMOTE_OPERATION_SUPPORT.UNAVAILABLE, record: null };
    }
    const record = {
      operationId,
      conversationEpoch,
      sessionId,
      kind,
      targetId,
      state: 'submitting',
      errorCode: null,
      updatedAtMilliseconds: null,
      generation,
      payloadContext
    };
    records.set(operationId, record);
    return { mode: REMOTE_OPERATION_SUPPORT.RECEIPTS, record };
  }

  function currentRecord(operationId) {
    const record = records.get(operationId);
    return record?.generation === generation ? record : null;
  }

  function markHostAccepted(operationId) {
    const record = currentRecord(operationId);
    if (!record || record.state !== 'submitting') return null;
    record.state = 'accepted';
    return record;
  }

  function markIndeterminate(operationId, errorCode = 'http-outcome-unknown') {
    const record = currentRecord(operationId);
    if (!record || recordIsTerminal(record)) return null;
    record.state = 'indeterminate';
    record.errorCode = errorCode;
    record.payloadContext = null;
    return record;
  }

  function rejectSubmission(operationId) {
    return removeRecord(operationId);
  }
  function discard(operationId) {
    return removeRecord(operationId);
  }

  function resolveHTTP(operationId, status) {
    const record = currentRecord(operationId);
    if (!record) return { outcome: 'stale', record: null };
    if (recordIsTerminal(record) || record.state === 'indeterminate') {
      return { outcome: 'settled', record };
    }
    if (status === 204) {
      return { outcome: 'accepted', record: markHostAccepted(operationId) || record };
    }
    if ([400, 403, 409, 422].includes(status)) {
      return { outcome: 'rejected', record: rejectSubmission(operationId) };
    }
    return {
      outcome: 'indeterminate',
      record: markIndeterminate(operationId)
    };
  }

  function newestMatchingReceipt(record, receipts) {
    let newest = null;
    for (const receipt of Array.isArray(receipts) ? receipts : []) {
      if (receipt?.operationId !== record.operationId
          || receipt?.conversationEpoch !== record.conversationEpoch
          || receipt?.kind !== record.kind) continue;
      const updatedAt = Number.isFinite(receipt.updatedAtMilliseconds)
        ? receipt.updatedAtMilliseconds : -1;
      if (!newest || updatedAt >= newest.updatedAt) {
        newest = { receipt, updatedAt };
      }
    }
    return newest?.receipt || null;
  }

  function reconcile(session, protocolInfo) {
    const support = negotiatedOperationSupport(protocolInfo, session);
    const epoch = nonEmptyOperationToken(session?.conversationEpoch);
    if (support !== REMOTE_OPERATION_SUPPORT.RECEIPTS || !epoch) return [];

    const transitions = [];
    for (const record of records.values()) {
      if (record.generation !== generation
          || record.sessionId !== session.id
          || record.conversationEpoch !== epoch) continue;
      const receipt = newestMatchingReceipt(record, session.operationReceipts);
      if (!receipt) continue;
      const state = REMOTE_OPERATION_STATES.has(receipt.state)
        ? receipt.state : 'indeterminate';
      if (recordIsTerminal(record) || record.state === 'indeterminate') continue;
      if (state === 'accepted' && record.state === 'accepted') continue;
      const previousState = record.state;
      record.state = state;
      record.errorCode = typeof receipt.errorCode === 'string'
        ? receipt.errorCode : null;
      record.updatedAtMilliseconds = Number.isFinite(receipt.updatedAtMilliseconds)
        ? receipt.updatedAtMilliseconds : null;
      if (state !== 'accepted') record.payloadContext = null;
      transitions.push({ record, previousState, state });
    }
    return transitions;
  }

  function recordForTarget({
    sessionId, conversationEpoch, kind, targetId
  }) {
    return latestForTarget(sessionId, conversationEpoch, kind, targetId);
  }

  function shouldPreserveTarget(context) {
    const record = recordForTarget(context);
    return !!record && (
      record.state === 'submitting'
      || record.state === 'accepted'
      || record.state === 'indeterminate'
    );
  }

  function shouldSuppressTarget(context) {
    return recordForTarget(context)?.state === 'applied';
  }

  function pruneSettledTargets({
    sessionId, conversationEpoch, kind, visibleTargetIds
  }) {
    const visible = visibleTargetIds instanceof Set
      ? visibleTargetIds : new Set(visibleTargetIds || []);
    for (const [operationId, record] of records) {
      if (record.sessionId !== sessionId
          || record.conversationEpoch !== conversationEpoch
          || record.kind !== kind
          || visible.has(record.targetId)) continue;
      if (record.state === 'applied'
          || record.state === 'rejected'
          || record.state === 'indeterminate') {
        removeRecord(operationId);
      }
    }
  }

  function invalidateAll() {
    generation += 1;
    for (const operationId of [...records.keys()]) removeRecord(operationId);
  }

  return {
    prepare,
    resolveHTTP,
    discard,
    markHostAccepted,
    markIndeterminate,
    rejectSubmission,
    reconcile,
    recordForTarget,
    shouldPreserveTarget,
    shouldSuppressTarget,
    pruneSettledTargets,
    invalidateAll,
    generation: () => generation,
    records: () => [...records.values()]
  };
}
