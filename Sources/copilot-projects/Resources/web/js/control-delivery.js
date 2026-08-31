const CONTROL_DELIVERY_CAPABILITY = 'replay-safe-control';
const CONTROL_DELIVERY_MAX_SEQUENCE = Number.MAX_SAFE_INTEGER;
const CONTROL_INPUT_MAX_BYTES = 8192;
const CONTROL_DELIVERY_UNKNOWN =
  'Delivery could not be confirmed. Check the terminal before sending again.';
const CONTROL_DELIVERY_UNAVAILABLE =
  'Replay-safe controls are temporarily unavailable. Reconnect to the Mac.';

function controlDeliverySupport(protocolInfo) {
  if (!Array.isArray(protocolInfo?.capabilities)
      || !protocolInfo.capabilities.includes(CONTROL_DELIVERY_CAPABILITY)) {
    return {kind: 'legacy', epoch: null};
  }
  const epoch = protocolInfo.controlDeliveryEpoch;
  if (typeof epoch !== 'string'
      || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(epoch)) {
    return {kind: 'unavailable', epoch: null};
  }
  return {kind: 'replay-safe', epoch: epoch.toUpperCase()};
}

function createControlDeliveryAllocator() {
  let currentEpoch = null;
  const sequences = new Map();
  return {
    prune(liveSessionIds) {
      for (const id of sequences.keys()) {
        if (!liveSessionIds.has(id)) sequences.delete(id);
      }
    },
    next(epoch, sessionId, type) {
      if (epoch !== currentEpoch) {
        currentEpoch = epoch;
        sequences.clear();
      }
      let lanes = sequences.get(sessionId);
      if (!lanes) {
        lanes = {prompt: 0, terminal: 0};
        sequences.set(sessionId, lanes);
      }
      const lane = type === 'prompt' ? 'prompt' : 'terminal';
      if (lanes[lane] >= CONTROL_DELIVERY_MAX_SEQUENCE) return null;
      lanes[lane] += 1;
      return {epoch, sequence: lanes[lane]};
    }
  };
}

function controlAction(id, type, sessionId, data) {
  return {
    id, type, sessionId, data,
    prepared: false, outcomeUnknown: false,
    deliveryMode: null, delivery: null, conversationEpoch: null,
    blockedReason: null
  };
}

function controlActionContextMatches(action, protocolInfo, conversationEpoch) {
  const support = controlDeliverySupport(protocolInfo);
  return action.deliveryMode === 'replay-safe'
    && support.kind === 'replay-safe'
    && action.delivery?.epoch === support.epoch
    && (action.type !== 'prompt' || action.conversationEpoch === (conversationEpoch || null));
}

function canReplayControlAction(action, protocolInfo, conversationEpoch) {
  return controlActionContextMatches(action, protocolInfo, conversationEpoch)
    && (action.type !== 'prompt' || !!action.conversationEpoch);
}

// Once prepared, neither identity nor payload may be rebound for a retry.
function prepareControlAction(action, protocolInfo, conversationEpoch, allocator) {
  if (action.blockedReason) return action.blockedReason;
  const support = controlDeliverySupport(protocolInfo);
  if (support.kind === 'unavailable') return CONTROL_DELIVERY_UNAVAILABLE;
  if (action.prepared) {
    if (action.deliveryMode === 'replay-safe'
        && (!controlActionContextMatches(action, protocolInfo, conversationEpoch)
          || (action.outcomeUnknown && !canReplayControlAction(action, protocolInfo, conversationEpoch)))) {
      return 'The host or conversation changed before delivery was confirmed. Check the terminal before sending again.';
    }
    if (action.deliveryMode === 'legacy' && action.outcomeUnknown) {
      return CONTROL_DELIVERY_UNKNOWN;
    }
    return null;
  }
  if (support.kind === 'replay-safe') {
    const delivery = allocator.next(support.epoch, action.sessionId, action.type);
    if (!delivery) return 'The delivery sequence is exhausted. Reload before sending more input.';
    action.delivery = delivery;
  }
  action.deliveryMode = support.kind;
  action.conversationEpoch = action.type === 'prompt' && conversationEpoch
    ? conversationEpoch : null;
  action.prepared = true;
  return null;
}

function controlActionMessage(action) {
  const message = {
    type: action.type, sessionId: action.sessionId,
    requestId: action.id, data: action.data
  };
  if (action.delivery) message.delivery = action.delivery;
  if (action.conversationEpoch) message.conversationEpoch = action.conversationEpoch;
  return message;
}

function controlDeliveryFailure(status) {
  switch (status) {
    case 410:
    case 412:
      return CONTROL_DELIVERY_UNKNOWN;
    case 429:
      return 'The Mac cannot retain more delivery history. Check the terminal and restart the Mac app before retrying.';
    case 400:
    case 413:
    case 422:
      return 'The input was not accepted. Check it before sending again.';
    case 403:
      return 'Control moved to another device. Check the terminal before sending again.';
    case 404:
      return 'This session is no longer available.';
    default:
      return CONTROL_DELIVERY_UNKNOWN;
  }
}

function controlInputChunks(value) {
  const encoder = new TextEncoder();
  const chunks = [];
  let chunk = '';
  let bytes = 0;
  for (const scalar of value) {
    const count = encoder.encode(scalar).length;
    if (bytes + count > CONTROL_INPUT_MAX_BYTES) {
      chunks.push(chunk);
      chunk = '';
      bytes = 0;
    }
    chunk += scalar;
    bytes += count;
  }
  if (chunk) chunks.push(chunk);
  return chunks;
}
