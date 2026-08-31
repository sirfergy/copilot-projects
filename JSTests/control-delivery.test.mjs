import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import {documentShim, loadFragments, plain, readFragment} from './support/fragments.mjs';

const epoch = '00000000-0000-4000-8000-000000000001';
const nextEpoch = '00000000-0000-4000-8000-000000000002';
const protocol = (value = epoch) => ({
  revision: 1, capabilities: ['replay-safe-control'], controlDeliveryEpoch: value,
});

function sourceSection(start, end) {
  const source = readFragment('main');
  const begin = source.indexOf(start);
  const finish = source.indexOf(end, begin);
  assert.ok(begin >= 0 && finish > begin);
  return source.slice(begin, finish);
}

function client(info = protocol()) {
  const {document, FakeNode} = documentShim();
  FakeNode.prototype.replaceChildren = function(...nodes) { this.children = nodes; this._text = undefined; };
  const node = () => {
    const element = new FakeNode('div');
    element.classList = {toggle() {}};
    element.focus = () => {};
    element.value = '';
    return element;
  };
  document.querySelector = () => node();
  document.querySelectorAll = () => [];
  let uuid = 0;
  let timerID = 0;
  const timers = new Map();
  const calls = [];
  const context = loadFragments(['operations', 'control-delivery'], {
    document, selected: 'A', writable: true, closingSession: false,
    selectionGeneration: 0, conversationRequestGeneration: 0,
    workspaceProtocolInfo: info,
    sessionState: new Map([
      ['A', {id: 'A', promptable: true, status: 'idle', conversationEpoch: 'conversation-A'}],
      ['B', {id: 'B', promptable: true, status: 'idle', conversationEpoch: 'conversation-B'}],
    ]),
    pendingActions: [], uncertainTerminalActions: new Map(),
    inputFlushToken: null, inputRetryTimer: null, inputMessage: null,
    promptQueues: new Map(), promptFlushes: new Map(), promptRetryTimers: new Map(),
    awaitingPromptStart: false, promptFallbackTimer: null,
    promptQueue: node(), promptStatus: node(), promptForm: node(), prompt: node(), promptSubmit: node(),
    lease: node(), input: node(), terminal: node(), inputDeliveryNotice: node(),
    inputDeliveryText: node(), discardPendingInput: node(), QUEUE_CAP: 25,
    updateCloseSessionState() {}, renderModelLine() {},
    newUUID: () => `00000000-0000-4000-8000-${String(++uuid).padStart(12, '0')}`,
    setTimeout: (callback, delay) => { const id = ++timerID; timers.set(id, {callback, delay}); return id; },
    clearTimeout: id => timers.delete(id),
    control: async message => { calls.push(plain(message)); return {status: 204, ok: true}; },
  });
  context.controlDeliveries = context.createControlDeliveryAllocator();
  vm.runInContext(sourceSection('function selectTerminalInputSession(', '// ---- Model picker'), context);
  vm.runInContext(sourceSection('function updatePromptState(message)', 'function clearUserInputSubmission('), context);
  return {
    context, calls, timers,
    addPrompt(text, sessionId = context.selected) {
      const item = context.controlAction(context.newUUID(), 'prompt', sessionId, text);
      context.sessionQueue(sessionId, true).push(item);
      return item;
    },
    runRetry() {
      const entry = [...timers.entries()].find(([, timer]) => timer.delay === 1000);
      assert.ok(entry, 'expected a scheduled retry');
      timers.delete(entry[0]);
      entry[1].callback();
    },
  };
}

async function settle() {
  for (let index = 0; index < 20; index += 1) await Promise.resolve();
}

function switchSession(context, id) {
  context.selected = id;
  context.selectionGeneration += 1;
  context.conversationRequestGeneration += 1;
  context.selectTerminalInputSession(id);
  context.awaitingPromptStart = false;
  context.writable = true; // The new selection has acquired its own lease.
}

test('replay support needs both the capability and a valid host epoch', () => {
  const {context: c} = client();
  assert.equal(c.controlDeliverySupport(null).kind, 'legacy');
  assert.equal(c.controlDeliverySupport({capabilities: []}).kind, 'legacy');
  assert.equal(c.controlDeliverySupport(protocol(null)).kind, 'unavailable');
  assert.equal(c.controlDeliverySupport(protocol('not-an-epoch')).kind, 'unavailable');
  assert.deepEqual(plain(c.controlDeliverySupport(protocol())), {kind: 'replay-safe', epoch});
});

test('delivery sequences are independent per session/lane and immutable after dispatch', () => {
  const {context: c} = client();
  const first = c.controlAction(c.newUUID(), 'input', 'A', 'first');
  assert.equal(c.prepareControlAction(first, protocol(), null, c.controlDeliveries), null);
  first.outcomeUnknown = true;
  assert.equal(c.prepareControlAction(first, protocol(), null, c.controlDeliveries), null);
  assert.equal(first.delivery.sequence, 1);
  const key = c.controlAction(c.newUUID(), 'key', 'A', 'enter');
  c.prepareControlAction(key, protocol(), null, c.controlDeliveries);
  assert.equal(key.delivery.sequence, 2);
  const prompt = c.controlAction(c.newUUID(), 'prompt', 'A', 'work');
  c.prepareControlAction(prompt, protocol(), 'conversation-A', c.controlDeliveries);
  assert.equal(prompt.delivery.sequence, 1);
  const other = c.controlAction(c.newUUID(), 'input', 'B', 'other');
  c.prepareControlAction(other, protocol(), null, c.controlDeliveries);
  assert.equal(other.delivery.sequence, 1);
  assert.ok(c.prepareControlAction(first, protocol(nextEpoch), null, c.controlDeliveries));
  assert.equal(first.delivery.epoch, epoch, 'never rebind an uncertain old request');
});

test('queued success consumes its original session item without changing another tab', async () => {
  const {context: c, addPrompt} = client();
  const first = addPrompt('same text');
  let acceptA;
  let acceptB;
  c.control = message => new Promise(resolve => {
    if (message.sessionId === 'A') acceptA = resolve;
    else acceptB = resolve;
  });
  const sendingA = c.flushQueue();
  switchSession(c, 'B');
  const second = addPrompt('same text');
  const sendingB = c.flushQueue();
  const bOwner = c.promptFlushes.get('B');
  acceptA({status: 204});
  await sendingA;
  assert.equal(c.sessionQueue('A').length, 0);
  assert.equal(c.sessionQueue('B')[0].id, second.id);
  assert.equal(c.promptFlushes.get('B'), bOwner);
  assert.notEqual(first.id, second.id);
  acceptB({status: 204});
  await sendingB;
  assert.equal(c.sessionQueue('B').length, 0);
});

test('an old ACK cannot delete a later identical prompt after removal and A-B-A', async () => {
  const {context: c, addPrompt} = client();
  const old = addPrompt('identical');
  let acceptOld;
  const sent = [];
  c.control = message => {
    sent.push(plain(message));
    if (message.requestId === old.id) return new Promise(resolve => { acceptOld = resolve; });
    return Promise.resolve({status: 204});
  };
  const pending = c.flushQueue();
  c.removeQueuedPrompt('A', old.id);
  const replacement = addPrompt('identical');
  switchSession(c, 'B');
  switchSession(c, 'A');
  acceptOld({status: 204});
  await pending;
  await settle();
  assert.deepEqual(sent.map(message => message.requestId), [old.id, replacement.id]);
  assert.equal(c.sessionQueue('A').length, 0);
});

test('a lost reliable prompt ACK retries the identical wire request', async () => {
  const probe = client();
  const c = probe.context;
  probe.addPrompt('one logical prompt');
  const sent = [];
  c.control = async message => { sent.push(plain(message)); return sent.length === 1 ? null : {status: 204}; };
  await c.flushQueue();
  assert.equal(c.sessionQueue('A').length, 1);
  probe.runRetry();
  await settle();
  assert.equal(sent.length, 2);
  assert.deepEqual(sent[0], sent[1]);
  assert.equal(c.sessionQueue('A').length, 0);
});

test('a legacy ambiguous prompt is retained and blocked, not blindly retried', async () => {
  const {context: c, addPrompt, timers} = client(null);
  const item = addPrompt('check before resending');
  let calls = 0;
  c.control = async () => { calls += 1; return null; };
  await c.flushQueue();
  c.updatePromptState();
  await settle();
  assert.equal(calls, 1);
  assert.equal(c.sessionQueue('A')[0].id, item.id);
  assert.ok(item.blockedReason.includes('could not be confirmed'));
  assert.equal(timers.size, 0);
});

test('a definitive legacy busy response may retry without changing identity', async () => {
  const probe = client(null);
  const c = probe.context;
  probe.addPrompt('wait for idle');
  const sent = [];
  c.control = async message => { sent.push(plain(message)); return {status: sent.length === 1 ? 409 : 204}; };
  await c.flushQueue();
  probe.runRetry();
  await settle();
  assert.deepEqual(sent[0], sent[1]);
  assert.equal(c.sessionQueue('A').length, 0);
});

test('a previously refused legacy request cannot bypass advertised unavailable delivery', async () => {
  const probe = client(null);
  const c = probe.context;
  probe.addPrompt('wait safely');
  let calls = 0;
  c.control = async () => { calls += 1; return {status: 409}; };
  await c.flushQueue();
  c.workspaceProtocolInfo = protocol(null);
  probe.runRetry();
  await settle();
  assert.equal(calls, 1);
  assert.match(c.sessionQueue('A')[0].blockedReason, /temporarily unavailable/);
});

test('host or conversation replacement blocks an uncertain prompt with its old identity intact', async () => {
  for (const change of ['host', 'conversation']) {
    const {context: c, addPrompt, timers} = client();
    const item = addPrompt('original context');
    let finish;
    c.control = () => new Promise(resolve => { finish = resolve; });
    const pending = c.flushQueue();
    if (change === 'host') c.workspaceProtocolInfo = protocol(nextEpoch);
    else c.sessionState.get('A').conversationEpoch = 'replacement';
    finish(null);
    await pending;
    assert.ok(item.blockedReason);
    assert.equal(item.delivery.epoch, epoch);
    assert.equal(item.conversationEpoch, 'conversation-A');
    assert.equal(timers.size, 0);
  }
});

test('retrying input is not coalesced with later typing and preserves order', async () => {
  const probe = client();
  const c = probe.context;
  const sent = [];
  let failFirst;
  c.control = message => {
    sent.push(plain(message));
    return sent.length === 1 ? new Promise(resolve => { failFirst = resolve; }) : Promise.resolve({status: 204});
  };
  assert.equal(c.sendInput('a'), true);
  assert.equal(c.sendInput('b'), true);
  assert.equal(c.pendingActions.length, 2);
  failFirst(null);
  await settle();
  probe.runRetry();
  await settle();
  assert.deepEqual(sent.map(message => message.data), ['a', 'a', 'b']);
  assert.deepEqual(sent[0], sent[1]);
  assert.notEqual(sent[1].requestId, sent[2].requestId);
  assert.deepEqual(sent.map(message => message.delivery.sequence), [1, 1, 2]);
  assert.equal(c.pendingActions.length, 0);
});

test('stale input refusal/finally cannot clear a new tab queue or its lease', async () => {
  const {context: c} = client();
  let finishA;
  let finishB;
  c.control = message => new Promise(resolve => {
    if (message.sessionId === 'A') finishA = resolve;
    else finishB = resolve;
  });
  c.sendInput('A text');
  switchSession(c, 'B');
  c.sendInput('B text');
  const ownerB = c.inputFlushToken;
  finishA({status: 403});
  await settle();
  assert.equal(c.writable, true);
  assert.equal(c.inputFlushToken, ownerB);
  assert.equal(c.pendingActions[0].data, 'B text');
  finishB({status: 204});
  await settle();
  assert.equal(c.pendingActions.length, 0);
});

test('a late old-host refusal does not revoke the replacement host lease', async () => {
  for (const kind of ['input', 'prompt']) {
    const {context: c, addPrompt} = client();
    let finish;
    c.control = () => new Promise(resolve => { finish = resolve; });
    let sending;
    if (kind === 'prompt') { addPrompt('old host'); sending = c.flushQueue(); }
    else c.sendInput('old host');
    c.workspaceProtocolInfo = protocol(nextEpoch);
    finish({status: 403});
    if (sending) await sending;
    await settle();
    assert.equal(c.writable, true);
    const item = kind === 'prompt' ? c.sessionQueue('A')[0] : c.pendingActions[0];
    assert.ok(item.blockedReason);
    assert.equal(item.delivery.epoch, epoch);
  }
});

test('legacy input ambiguity stops visibly until explicit discard', async () => {
  const {context: c, timers} = client(null);
  let calls = 0;
  c.control = async () => { calls += 1; return null; };
  c.sendKey('enter');
  await settle();
  await c.flushInput();
  assert.equal(calls, 1);
  assert.equal(c.pendingActions.length, 1);
  assert.equal(c.inputDeliveryNotice.hidden, false);
  assert.match(c.inputDeliveryText.textContent, /could not be confirmed/);
  assert.equal(c.sendInput('not silently accepted'), false);
  assert.equal(timers.size, 0);
  c.discardQueuedTerminalInput();
  assert.equal(c.pendingActions.length, 0);
  assert.equal(c.canAcceptTerminalInput(), true);
});

test('known host replacement/expired receipt stops raw input without re-identifying it', async () => {
  for (const status of [410, 412, 422, 429]) {
    const {context: c} = client();
    c.control = async () => ({status});
    c.sendKey('enter');
    const id = c.pendingActions[0].id;
    await settle();
    assert.equal(c.pendingActions[0].id, id);
    assert.ok(c.pendingActions[0].blockedReason);
    assert.equal(c.canAcceptTerminalInput(), false);
  }
});

test('legacy command fallback is only taken after a definitive unsupported response', async () => {
  for (const reliable of [false, true]) {
    const {context: c} = client(reliable ? protocol() : null);
    const sent = [];
    c.control = async message => { sent.push(plain(message)); return {status: sent.length === 1 ? 400 : 204}; };
    c.sendCommand('echo hello');
    await settle();
    assert.deepEqual(sent.map(message => message.type), reliable ? ['command'] : ['command', 'input', 'key']);
    if (reliable) assert.ok(c.pendingActions[0].blockedReason);
  }
});

test('a prompt without a conversation epoch can send once but cannot replay an unknown outcome', async () => {
  for (const status of [204, null]) {
    const {context: c, addPrompt, calls, timers} = client();
    c.sessionState.get('A').conversationEpoch = null;
    addPrompt('legacy tracker');
    c.control = async message => { calls.push(plain(message)); return status ? {status} : null; };
    await c.flushQueue();
    if (status === 204) {
      assert.equal(c.sessionQueue('A').length, 0);
    } else {
      assert.ok(c.sessionQueue('A')[0].blockedReason);
      c.sessionState.get('A').conversationEpoch = 'new conversation';
      c.updatePromptState();
      await settle();
      assert.equal(calls.length, 1);
      assert.equal(timers.size, 0);
    }
    assert.equal(calls[0].conversationEpoch, undefined);
  }
});

test('a nil-epoch prompt can retry a definitive refusal while its context remains unchanged', async () => {
  const probe = client();
  const c = probe.context;
  c.sessionState.get('A').conversationEpoch = null;
  probe.addPrompt('not accepted yet');
  const sent = [];
  c.control = async message => { sent.push(plain(message)); return {status: sent.length === 1 ? 409 : 204}; };
  await c.flushQueue();
  probe.runRetry();
  await settle();
  assert.equal(sent.length, 2);
  assert.deepEqual(sent[0], sent[1]);
  assert.equal(c.sessionQueue('A').length, 0);
});

test('an uncertain prompt reconciles its ACK while Copilot is busy or asking a question', async () => {
  for (const interaction of [null, 'pendingUserInputs', 'pendingElicitations']) {
    const probe = client();
    const c = probe.context;
    probe.addPrompt('already accepted');
    const sent = [];
    c.control = async message => { sent.push(plain(message)); return sent.length === 1 ? null : {status: 204}; };
    await c.flushQueue();
    c.sessionState.get('A').promptable = false;
    if (interaction) c.sessionState.get('A')[interaction] = [{requestId: 'question'}];
    probe.runRetry();
    await settle();
    assert.equal(sent.length, 2);
    assert.deepEqual(sent[0], sent[1]);
    assert.equal(c.sessionQueue('A').length, 0);
    probe.addPrompt('must wait');
    c.updatePromptState();
    await settle();
    assert.equal(sent.length, 2, 'only reconciliation bypasses promptability');
  }
});

test('selection retains the uncertain terminal head but drops undispatched typing', async () => {
  const {context: c, calls} = client();
  let failFirst;
  c.control = message => {
    calls.push(plain(message));
    return calls.length === 1 ? new Promise(resolve => { failFirst = resolve; }) : Promise.resolve({status: 204});
  };
  c.sendInput('uncertain A');
  c.sendInput('unsent tail');
  switchSession(c, 'B');
  c.sendInput('B');
  failFirst(null);
  await settle();
  assert.equal(c.uncertainTerminalActions.get('A').data, 'uncertain A');
  assert.equal(c.pendingActions.length, 0);
  switchSession(c, 'A');
  assert.equal(c.pendingActions.length, 1);
  c.renderInputDeliveryState();
  assert.match(c.inputDeliveryText.textContent, /Confirming input/);
  await c.flushInput();
  assert.deepEqual(calls.map(message => message.data), ['uncertain A', 'B', 'uncertain A']);
  assert.deepEqual(calls[0], calls[2]);
  assert.equal(c.pendingActions.length, 0);
  assert.equal(c.uncertainTerminalActions.size, 0);
  assert.equal(c.inputDeliveryNotice.hidden, true);
});

test('a late accepted terminal write clears its origin without disturbing another tab', async () => {
  const {context: c} = client();
  const replies = new Map();
  c.control = message => new Promise(resolve => replies.set(message.sessionId, resolve));
  c.sendKey('enter');
  switchSession(c, 'B');
  c.sendInput('B');
  const bOwner = c.inputFlushToken;
  replies.get('A')({status: 204});
  await settle();
  assert.equal(c.uncertainTerminalActions.has('A'), false);
  assert.equal(c.pendingActions[0].data, 'B');
  assert.equal(c.inputFlushToken, bOwner);
  replies.get('B')({status: 204});
  await settle();
  switchSession(c, 'A');
  assert.equal(c.pendingActions.length, 0);
});

test('legacy or restarted-host terminal uncertainty survives selection until explicitly discarded', async () => {
  for (const legacy of [true, false]) {
    const {context: c, calls} = client(legacy ? null : protocol());
    let finish;
    c.control = message => { calls.push(plain(message)); return new Promise(resolve => { finish = resolve; }); };
    c.sendKey('enter');
    switchSession(c, 'B');
    finish(null);
    await settle();
    if (!legacy) c.workspaceProtocolInfo = protocol(nextEpoch);
    switchSession(c, 'A');
    await c.flushInput();
    assert.equal(calls.length, 1);
    assert.ok(c.pendingActions[0].blockedReason);
    c.discardQueuedTerminalInput();
    switchSession(c, 'B');
    switchSession(c, 'A');
    assert.equal(c.pendingActions.length, 0);
    assert.equal(c.uncertainTerminalActions.size, 0);
  }
});

test('late terminal success cannot remove a replacement after explicit discard and ABA', async () => {
  const {context: c} = client();
  const replies = [];
  c.control = () => new Promise(resolve => replies.push(resolve));
  c.sendInput('same text');
  switchSession(c, 'B');
  switchSession(c, 'A');
  c.discardQueuedTerminalInput();
  c.sendInput('same text');
  const replacement = c.pendingActions[0];
  replies[0]({status: 204});
  await settle();
  assert.equal(c.pendingActions[0].id, replacement.id);
  assert.equal(c.uncertainTerminalActions.get('A').id, replacement.id);
  replies[1]({status: 204});
  await settle();
  assert.equal(c.pendingActions.length, 0);
  assert.equal(c.uncertainTerminalActions.size, 0);
});

test('UTF-8 input chunks preserve scalars, data and byte limits', async () => {
  const {context: c, calls} = client();
  const text = 'a'.repeat(8191) + '😀'.repeat(3000) + '\u0003';
  const chunks = plain(c.controlInputChunks(text));
  assert.equal(chunks.join(''), text);
  assert.ok(chunks.every(chunk => new TextEncoder().encode(chunk).length <= 8192));
  c.sendInput(text);
  await settle();
  assert.equal(calls.map(message => message.data).join(''), text);
  assert.ok(calls.every(message => new TextEncoder().encode(message.data).length <= 8192));
});

test('oversized command is refused without enqueuing or clearing the draft', () => {
  const {context: c} = client();
  c.input.value = 'x'.repeat(8193);
  assert.equal(c.sendCommand(c.input.value), false);
  assert.equal(c.pendingActions.length, 0);
  assert.equal(c.input.value.length, 8193);
  assert.match(c.inputDeliveryText.textContent, /too large/);
});
