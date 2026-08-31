const sessions = document.querySelector('#sessions');
const terminal = document.querySelector('#terminal');
const terminalLines = document.querySelector('#terminal-lines');
const terminalImageOverlay = document.querySelector('#terminal-image-overlay');
const terminalCellProbe = document.querySelector('#terminal-cell-probe');
const connection = document.querySelector('#connection');
const lease = document.querySelector('#lease');
const input = document.querySelector('#input');
const inputDeliveryNotice = document.querySelector('#input-delivery-notice');
const inputDeliveryText = document.querySelector('#input-delivery-text');
const discardPendingInput = document.querySelector('#discard-pending-input');
const transcript = document.querySelector('#transcript');
const promptForm = document.querySelector('#prompt-form');
const prompt = document.querySelector('#prompt');
const promptStatus = document.querySelector('#prompt-status');
const promptSubmit = document.querySelector('#prompt-submit');
const modelLine = document.querySelector('#model-line');
const modelLineName = document.querySelector('#model-line-name');
const modelPicker = document.querySelector('#model-picker');
const modelPickerBody = document.querySelector('#model-picker-body');
const modelPickerTitle = document.querySelector('#model-picker-title');
const modelPickerStatus = document.querySelector('#model-picker-status');
const modelPickerBack = document.querySelector('#model-picker-back');
const modelPickerClose = document.querySelector('#model-picker-close');
const userInput = document.querySelector('#user-input');
const promptQueue = document.querySelector('#prompt-queue');
const notifications = document.querySelector('#notifications');
const content = document.querySelector('#content');
const pivotTabs = Array.from(document.querySelectorAll('.pivot-tab'));
const newSessionButton = document.querySelector('#new-session');
const newSessionProject = document.querySelector('#new-session-project');
const closeSessionButton = document.querySelector('#close-session');
const createStatus = document.querySelector('#create-status');
const base = location.pathname.endsWith('/')
  ? location.pathname : `${location.pathname}/`;
function newUUID() {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
  const bytes = new Uint8Array(16);
  if (globalThis.crypto?.getRandomValues) {
    globalThis.crypto.getRandomValues(bytes);
  } else {
    for (let index = 0; index < bytes.length; index += 1) {
      bytes[index] = Math.floor(Math.random() * 256);
    }
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0'));
  return [
    hex.slice(0, 4).join(''),
    hex.slice(4, 6).join(''),
    hex.slice(6, 8).join(''),
    hex.slice(8, 10).join(''),
    hex.slice(10).join('')
  ].join('-');
}
const clientId = newUUID();
const controlDeliveries = createControlDeliveryAllocator();
const sdkOperations = createOperationController({ newOperationId: newUUID });
const TOOLBAR_KEYS = {
  'esc': 'escape', 'tab': 'tab', 'enter': 'enter',
  'up': 'up', 'down': 'down'
};
let stream = null;
let selected = null;
let writable = false;
let pendingActions = [];
const uncertainTerminalActions = new Map();
let inputFlushToken = null;
let inputRetryTimer = null;
let inputMessage = null;
let lastScreen = null;
let historyStartLine = 0;
let historyLines = [];
// Retained terminal-image placement state: authoritative snapshot from
// the most recent screen event that included a present `images` array
// (see buildTerminalImagePlacements), filtered down to whatever's still
// inside the actually-retained line range after every text update.
let imagePlacements = [];
// key -> {el, placement, cacheKey, pixels}. Persistent across renders:
// `renderLines` never destroys these, only `reconcileImageOverlay` adds/
// repositions/removes them, keyed by a stable placement identity so an
// unchanged, still-visible placement's node/img fetch survives.
const terminalImageNodes = new Map();
// Conversation-mode inline image nodes are owned solely by the cards in
// `transcriptCardCache`: a render only
// releases the nodes of cards it replaced or dropped — after the new DOM is
// in place — so an unchanged image's shared cache entry never drops to a
// zero reference count.
// sessionId:imageId:version -> {url, bytes, width, height, activeNodeCount, lastUsed}
const terminalImagePositiveCache = new Map();
// Exact-match permanently-negative keys (404 only). Insertion-ordered Set
// so the oldest entry can be evicted once the bound is exceeded.
const terminalImageNegativeCache = new Set();
// Exact immutable PNG bytes that passed structural validation but the
// browser decoder rejected. Bounded and permanent for this auth lifetime:
// re-fetching the same version cannot change the result.
const terminalImageDecodeFailures = new Set();
// Images skipped solely because every cache entry was actively visible.
// These retry only after a real capacity change (node release/eviction),
// never on a timer that would redownload bytes into the same full cache.
const terminalImageCapacityBlocked = new Set();
// key -> {failureCount, nextAttemptAt}: bounded cooldown for transient
// (non-404) failures, distinct from the permanent negative cache.
const terminalImageBackoff = new Map();
const terminalImageRetryTimers = new Map();
// key -> {controller, promise}
const terminalImageInFlight = new Map();
// key -> number of visible nodes waiting to mount a completed cache entry.
// Eviction treats these entries as active even before `img.src` is set.
const terminalImagePendingConsumers = new Map();
// Bumped only on session change/terminal refresh/full auth reset — an
// ordinary incremental screen update never bumps this, so an in-flight
// fetch survives an unrelated text-only re-render and reconciles against
// whatever the current state is once it resolves.
let terminalImageGeneration = 0;
let terminalActiveDecodedPixels = 0;
let terminalImageReconcileScheduled = false;
let pendingScroll = 0;
let scrollTimer = null;
let touchY = null;
let consecutiveStreamErrors = 0;
let awaitingPromptStart = false;
let promptFallbackTimer = null;
let transcriptRequestId = 0;
let selectionGeneration = 0;
let conversationRequestGeneration = 0;
let viewMode = 'conversation';
// Per-session queue of Copilot prompts. Conversation mode lets you stack
// multiple messages while the agent is busy; they flush in order as it frees.
const QUEUE_CAP = 25;
const promptQueues = new Map();
const promptFlushes = new Map();
const promptRetryTimers = new Map();
// The host selection supplies the initial default only. The web user's explicit
// project choice is then preserved while that project remains available.
let hostSelectedProjectId = null;
let createTargetProjectId = null;
let availableCreateProjects = [];
let renderedCreateProjectSignature = null;
let createRequestId = null;
let createRequestProjectId = null;
let creating = false;
let pendingCreatedSessionId = null;
const sessionState = new Map();
let workspaceProtocolInfo = null;
let selectedConversationEpoch = null;
// requestId -> card element, and requestId -> the legacy timer or correlated
// receipt operation while an answer is awaiting confirmation.
const userInputCards = new Map();
const submittingUserInputs = new Map();
const latestUserInputAttempts = new Map();
let userInputAttemptSequence = 0;
let userInputCardSequence = 0;
// Parallel bookkeeping for schema-form / url elicitations. Each entry carries
// the parsed form and the in-progress answer values so a workspace refresh
// that doesn't change the request set never wipes a half-filled form.
const elicitationCards = new Map();
const submittingElicitations = new Map();
const latestElicitationAttempts = new Map();
let elicitationAttemptSequence = 0;
let elicitationCardSequence = 0;
let modelOperationId = null;
let modelOperationMessage = '';
let modelOperationIsError = false;
let modelOperationTimer = null;
let lastReportedModelSignature = null;
const RECEIPT_TIMEOUT_MS = 20_000;
const requested = new URLSearchParams(location.search);
let pendingFocusSession = requested.get('session');

function setConnection(state, label) {
  connection.className = `connection ${state}`;
  connection.setAttribute('aria-label', label);
  connection.title = label;
  connection.querySelector('.visually-hidden').textContent = label;
}

// Mirror the iOS session pivot: show one pane at a time. While the terminal
// is hidden we skip rendering incoming screen frames entirely; activating the
// Terminal tab reopens the stream so the gateway resends a fresh snapshot.
function refreshTerminal() {
  lastScreen = null;
  historyStartLine = 0;
  historyLines = [];
  pendingScroll = 0;
  clearTimeout(scrollTimer);
  scrollTimer = null;
  terminal.classList.remove('terminal-scroll');
  terminalLines.textContent = selected ? 'Loading…' : 'Select a session';
  resetTerminalImagesForSessionChange();
  if (selected) openStream();
}
function setViewMode(mode, options) {
  if (mode !== 'terminal' && mode !== 'conversation') return;
  const changed = viewMode !== mode;
  if (changed && mode === 'terminal') {
    const atBottom = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 18;
    pendingTranscriptAnchor = atBottom ? null : transcriptTopAnchor();
  }
  viewMode = mode;
  content.dataset.mode = mode;
  pivotTabs.forEach((tab) => {
    tab.setAttribute('aria-selected', String(tab.dataset.mode === mode));
  });
  if (mode === 'terminal') {
    if (changed) {
      // Free the shared image budget the (now-hidden) conversation images
      // were holding so they can't starve the terminal overlay, and drop the
      // hidden pane's turn cards entirely — a window's worth of markdown DOM
      // must not stay alive behind the terminal.
      clearTranscriptDOM();
      refreshTerminal();
    }
    if (!options?.silent) terminal.focus();
  } else if (mode === 'conversation' && changed) {
    // Nothing was built (or kept) while the pane was hidden, so render fresh
    // from the retained snapshot — or restore the loading notice if no
    // snapshot has arrived for this session yet.
    if (lastRenderedTranscript) renderTranscript(lastRenderedTranscript);
    else if (selected) showTranscriptPlaceholder('Loading completed turns…');
  }
}

function openStream() {
  if (stream) stream.close();
  const query = new URLSearchParams();
  if (selected) query.set('s', selected);
  const suffix = query.toString() ? `?${query.toString()}` : '';
  setConnection('connecting', 'Connecting');
  stream = new EventSource(`${base}events${suffix}`);
  stream.onopen = () => {
    consecutiveStreamErrors = 0;
    setConnection('connected', 'Connected');
  };
  stream.onerror = () => {
    consecutiveStreamErrors += 1;
    setConnection('connecting', 'Reconnecting');
    if (consecutiveStreamErrors === 3) {
      const now = Date.now();
      const lastReload = Number(
        sessionStorage.getItem('copilot-projects-auth-reload') || 0
      );
      if (now - lastReload > 60_000) {
        sessionStorage.setItem('copilot-projects-auth-reload', String(now));
        invalidateConversationOperations();
        resetTerminalImagesForSignOut();
        setTimeout(() => location.reload(), 1000);
      }
    }
  };
  stream.onmessage = onMessage;
}
async function control(message) {
  try {
    return await fetch(`${base}control`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ clientId, ...message })
    });
  } catch (error) {
    setConnection('error', 'Connection error');
    return null;
  }
}
function operationContext(sessionId = selected) {
  const session = sessionId && sessionState.get(sessionId);
  const currentEpoch = nonEmptyOperationToken(session?.conversationEpoch);
  return {
    sessionId,
    session,
    support: negotiatedOperationSupport(workspaceProtocolInfo, session),
    conversationEpoch: currentEpoch
      || (sessionId === selected ? selectedConversationEpoch : null)
  };
}
function operationTargetContext(kind, targetId, sessionId = selected) {
  const context = operationContext(sessionId);
  return {
    sessionId,
    conversationEpoch: context.conversationEpoch,
    kind,
    targetId
  };
}
function operationUnavailableMessage() {
  return 'Copilot controls are temporarily unavailable.';
}
function clearModelOperationState(closePicker) {
  if (modelOperationTimer) clearTimeout(modelOperationTimer);
  modelOperationTimer = null;
  modelSwitchSubmitting = false;
  modelOperationId = null;
  modelOperationMessage = '';
  modelOperationIsError = false;
  if (closePicker && modelPicker.open) closeModelPicker();
}
function invalidateConversationOperations(options = {}) {
  conversationRequestGeneration += 1;
  sdkOperations.invalidateAll();
  resetUserInputCards();
  resetElicitationCards();
  clearModelOperationState(options.closeModelPicker !== false);
}
let closingSession = false;
// The close button targets the selected session, which the client already
// holds the lease for (selectSession acquires it). The gateway rejects a
// close without a held lease, so gating on `writable` matches the server.
function updateCloseSessionState() {
  const canClose = !!selected && writable && sessionState.has(selected);
  closeSessionButton.disabled = !canClose || closingSession;
}
async function closeCurrentSession() {
  if (!selected || !writable || closingSession) return;
  const sessionId = selected;
  closingSession = true;
  updateCloseSessionState();
  try {
    const response = await control({ type: 'close-session', sessionId });
    if (response && response.ok && selected === sessionId) {
      // The session is ending; drop local control now. The next workspace
      // snapshot removes the tab and reconciles selection.
      writable = false;
      lease.textContent = 'view only';
    }
  } finally {
    closingSession = false;
    updateCloseSessionState();
    updatePromptState();
  }
}
function setCreateStatus(text) {
  createStatus.textContent = text || '';
}
function updateNewSessionState() {
  newSessionButton.disabled = !createTargetProjectId || creating;
  newSessionProject.disabled = !availableCreateProjects.length || creating;
}
function clearCreateRequest() {
  createRequestId = null;
  createRequestProjectId = null;
}
function syncCreateProjectOptions(projects, selectedProjectId) {
  availableCreateProjects = projects.map((project) => ({
    id: project.id,
    name: project.name
  }));
  const signature = createProjectSignature(availableCreateProjects);
  if (signature !== renderedCreateProjectSignature) {
    const fragment = document.createDocumentFragment();
    availableCreateProjects.forEach((project) => {
      const option = document.createElement('option');
      option.value = project.id;
      option.textContent = project.name;
      fragment.append(option);
    });
    newSessionProject.replaceChildren(fragment);
    renderedCreateProjectSignature = signature;
  }

  if (!creating) {
    const previousTarget = createTargetProjectId;
    createTargetProjectId = chooseCreateProjectId(
      availableCreateProjects,
      createTargetProjectId,
      selectedProjectId
    );
    if (previousTarget !== createTargetProjectId) {
      if (createRequestProjectId !== createTargetProjectId) {
        clearCreateRequest();
      }
      setCreateStatus('');
    }
  }
  const selectValue = createTargetProjectId || '';
  if (newSessionProject.value !== selectValue) {
    newSessionProject.value = selectValue;
  }
  updateNewSessionState();
}
async function createSession() {
  // A double click is blocked while a request is active, and the button stays
  // disabled without a web-selected project.
  const projectId = createTargetProjectId;
  if (creating || !projectId) return;
  // Retain one request id across retries so a network/5xx retry is idempotent.
  if (!createRequestId || createRequestProjectId !== projectId) {
    createRequestId = newUUID();
    createRequestProjectId = projectId;
  }
  creating = true;
  updateNewSessionState();
  setCreateStatus('Creating session…');
  let response;
  try {
    response = await fetch(`${base}sessions/create`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ requestId: createRequestId, projectId })
    });
  } catch (error) {
    // Network failure: keep the request id so a retry reuses it.
    creating = false;
    syncCreateProjectOptions(availableCreateProjects, hostSelectedProjectId);
    setCreateStatus('Network error — tap New Session to retry');
    return;
  }
  creating = false;
  syncCreateProjectOptions(availableCreateProjects, hostSelectedProjectId);
  if (response.status >= 500) {
    // 5xx (incl. 503 Copilot unavailable): retain the id for an idempotent retry.
    setCreateStatus(
      response.status === 503
        ? 'Copilot is unavailable — tap to retry'
        : 'Host error — tap New Session to retry'
    );
    return;
  }
  if (response.status === 410) {
    // Processed-but-closed: a new explicit click should be a new attempt.
    clearCreateRequest();
    setCreateStatus('That session was already created and closed');
    return;
  }
  if (response.status === 404) {
    clearCreateRequest();
    setCreateStatus('New sessions are not supported by this host');
    return;
  }
  if (response.status === 409) {
    clearCreateRequest();
    setCreateStatus('That session id is already in use');
    return;
  }
  if (response.status === 422) {
    clearCreateRequest();
    setCreateStatus('Cannot create a session (no project or Repos unavailable)');
    return;
  }
  if (!response.ok) {
    clearCreateRequest();
    setCreateStatus('Could not create a session');
    return;
  }
  let payload = null;
  try { payload = await response.json(); } catch (error) { payload = null; }
  // On success clear the request id and remember the created session so it can be
  // selected once the workspace snapshot includes it. Host Mac selection is left
  // untouched.
  clearCreateRequest();
  if (payload && payload.sessionId) {
    pendingCreatedSessionId = payload.sessionId;
    setCreateStatus('Session ready');
    if (sessionState.has(pendingCreatedSessionId)) {
      const sessionId = pendingCreatedSessionId;
      pendingCreatedSessionId = null;
      selectSession(sessionId);
    }
  } else {
    setCreateStatus('Session ready');
  }
}
async function acquire(id) {
  const response = await control({ type: 'acquire', sessionId: id });
  if (selected !== id) return;
  if (response && response.ok) {
    writable = true;
    lease.textContent = 'control enabled';
    syncUserInputCards();
    syncElicitationCards();
    updatePromptState();
    flushInput();
  }
}
// Keep the selected session in the URL so a refresh restores it. The
// initial ?session= param is read into pendingFocusSession on load and
// applied by renderWorkspace once the session is present.
function rememberSelectedSession(id) {
  try {
    const url = new URL(location.href);
    if (id) url.searchParams.set('session', id);
    else url.searchParams.delete('session');
    history.replaceState(history.state, '', url);
  } catch (_) {}
}
function selectSession(id) {
  const previousSession = selected;
  // Only resave the outgoing draft while that session is still part of
  // the current workspace snapshot. If it was removed since it was
  // selected, prunePromptDrafts() already deleted it; resaving it here
  // would undo that prune with a stale textarea value.
  if (previousSession && sessionState.has(previousSession)) {
    setPromptDraft(previousSession, prompt.value);
    persistPromptDrafts();
  }
  invalidateConversationOperations();
  selected = id;
  selectedConversationEpoch = nonEmptyOperationToken(
    sessionState.get(id)?.conversationEpoch
  );
  rememberSelectedSession(id);
  prompt.value = draftForSession(id);
  writable = false;
  selectTerminalInputSession(id);
  pendingScroll = 0;
  lastScreen = null;
  historyStartLine = 0;
  historyLines = [];
  awaitingPromptStart = false;
  resetTranscriptForSession();
  selectionGeneration += 1;
  clearTimeout(promptFallbackTimer);
  promptFallbackTimer = null;
  clearTimeout(scrollTimer);
  scrollTimer = null;
  lease.textContent = 'view only';
  terminalLines.textContent = 'Loading…';
  resetTerminalImagesForSessionChange();
  showTranscriptPlaceholder('Loading completed turns…');
  terminal.classList.remove('terminal-scroll');
  document.querySelectorAll('nav button').forEach((button) => {
    button.classList.toggle('active', button.dataset.id === id);
  });
  openStream();
  acquire(id);
  if (viewMode === 'terminal') terminal.focus();
  syncUserInputCards();
  syncElicitationCards();
  renderQueue();
  updatePromptState();
}
// Selection drops undispatched typing, never the outcome of an attempted write.
function selectTerminalInputSession(sessionId) {
  const uncertain = uncertainTerminalActions.get(sessionId);
  pendingActions = uncertain ? [uncertain] : [];
  inputFlushToken = null;
  clearTimeout(inputRetryTimer);
  inputRetryTimer = null;
  inputMessage = null;
}
function discardQueuedTerminalInput() {
  uncertainTerminalActions.delete(selected);
  selectTerminalInputSession(selected);
  renderInputDeliveryState();
  terminal.focus();
}
function terminalDeliveryMessage() {
  return pendingActions[0]?.blockedReason || inputMessage
    || (pendingActions[0]?.outcomeUnknown ? 'Confirming input delivery...' : '')
    || (controlDeliverySupport(workspaceProtocolInfo).kind === 'unavailable'
      ? CONTROL_DELIVERY_UNAVAILABLE : '');
}
function canAcceptTerminalInput() {
  return !!selected && writable && !closingSession && sessionState.has(selected)
    && !pendingActions[0]?.blockedReason
    && controlDeliverySupport(workspaceProtocolInfo).kind !== 'unavailable';
}
function renderInputDeliveryState() {
  const message = terminalDeliveryMessage();
  inputDeliveryNotice.hidden = !message;
  inputDeliveryText.textContent = message;
  discardPendingInput.hidden = !pendingActions.length;
  document.querySelector('#input-form button').disabled = !canAcceptTerminalInput();
  document.querySelectorAll('#toolbar button').forEach((button) => {
    button.disabled = !canAcceptTerminalInput();
  });
}
// Keep attempted payloads immutable: appending typing to a retry would reuse
// its identity for different bytes. Only an unsent tail can be coalesced.
function sendInput(data) {
  if (!canAcceptTerminalInput() || !data) return false;
  for (const chunk of controlInputChunks(data)) {
    const last = pendingActions.at(-1);
    if (last?.type === 'input' && !last.prepared && last.sessionId === selected
        && new TextEncoder().encode(last.data + chunk).length <= CONTROL_INPUT_MAX_BYTES) {
      last.data += chunk;
    } else {
      pendingActions.push(controlAction(newUUID(), 'input', selected, chunk));
    }
  }
  inputMessage = null;
  flushInput();
  return true;
}
function sendKey(key) {
  if (!canAcceptTerminalInput() || !key) return false;
  pendingActions.push(controlAction(newUUID(), 'key', selected, key));
  inputMessage = null;
  flushInput();
  return true;
}
function sendCommand(value) {
  if (!canAcceptTerminalInput() || !value) return false;
  if (new TextEncoder().encode(value).length > CONTROL_INPUT_MAX_BYTES) {
    inputMessage = 'Command is too large (8 KB maximum).';
    renderInputDeliveryState();
    return false;
  }
  pendingActions.push(controlAction(newUUID(), 'command', selected, value));
  inputMessage = null;
  flushInput();
  return true;
}
function scheduleInputRetry(sessionId, generation) {
  clearTimeout(inputRetryTimer);
  const timer = setTimeout(() => {
    if (inputRetryTimer !== timer) return;
    inputRetryTimer = null;
    if (selected === sessionId && selectionGeneration === generation) flushInput();
  }, 1000);
  inputRetryTimer = timer;
}
async function flushInput() {
  if (inputFlushToken || inputRetryTimer || !pendingActions.length
      || !canAcceptTerminalInput()) return;
  const token = {};
  const generation = selectionGeneration;
  const sessionId = selected;
  inputFlushToken = token;
  try {
    while (inputFlushToken === token && selected === sessionId
        && selectionGeneration === generation && writable && !closingSession
        && pendingActions.length) {
      const action = pendingActions[0];
      if (action.sessionId !== sessionId) {
        action.blockedReason = 'Queued input belongs to another session. Discard it before continuing.';
        return;
      }
      const reason = prepareControlAction(action, workspaceProtocolInfo, null, controlDeliveries);
      if (reason) { action.blockedReason = reason; return; }
      action.outcomeUnknown = true;
      uncertainTerminalActions.set(sessionId, action);
      const response = await control(controlActionMessage(action));
      const index = pendingActions.findIndex((item) => item.id === action.id);
      if (response?.status === 204) {
        if (uncertainTerminalActions.get(sessionId)?.id === action.id) {
          uncertainTerminalActions.delete(sessionId);
        }
        if (index >= 0) pendingActions.splice(index, 1);
      }
      // A late error or finally must not tear down a newer tab's input loop.
      if (inputFlushToken !== token || selected !== sessionId
          || selectionGeneration !== generation || index < 0) return;
      if (response?.status === 204) continue;
      if (response?.status === 400 && action.type === 'command'
          && action.deliveryMode === 'legacy') {
        uncertainTerminalActions.delete(sessionId);
        const replacement = controlInputChunks(action.data)
          .map((data) => controlAction(newUUID(), 'input', sessionId, data));
        replacement.push(controlAction(newUUID(), 'key', sessionId, 'enter'));
        pendingActions.splice(index, 1, ...replacement);
        continue;
      }
      if (response?.status === 409) {
        uncertainTerminalActions.delete(sessionId);
        action.outcomeUnknown = false;
        scheduleInputRetry(sessionId, generation);
        return;
      }
      if (!response || response.status >= 500) {
        if (canReplayControlAction(action, workspaceProtocolInfo, null)) {
          scheduleInputRetry(sessionId, generation);
          return;
        }
      }
      const sameHost = !action.delivery
        || canReplayControlAction(action, workspaceProtocolInfo, null);
      if (response?.status === 403 && sameHost) {
        writable = false;
        lease.textContent = 'view only';
      }
      action.blockedReason = sameHost
        ? controlDeliveryFailure(response?.status) : CONTROL_DELIVERY_UNKNOWN;
      return;
    }
  } finally {
    if (inputFlushToken === token) {
      inputFlushToken = null;
      renderInputDeliveryState();
      flushInput();
    }
  }
}
function sessionQueue(id, create) {
  let q = promptQueues.get(id);
  if (!q && create) { q = []; promptQueues.set(id, q); }
  return q || [];
}
function removeQueuedPrompt(sessionId, itemId) {
  const q = promptQueues.get(sessionId);
  const index = q?.findIndex((item) => item.id === itemId) ?? -1;
  if (index < 0) return;
  q.splice(index, 1);
  if (!q.length) promptQueues.delete(sessionId);
}
function renderQueue() {
  const sessionId = selected;
  const q = sessionId ? sessionQueue(sessionId) : [];
  promptQueue.replaceChildren();
  promptQueue.hidden = q.length === 0;
  q.forEach((entry) => {
    const item = document.createElement('div');
    item.className = 'queue-item';
    item.setAttribute('role', 'listitem');
    const text = document.createElement('span');
    text.className = 'queue-text';
    text.textContent = entry.data;
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.className = 'queue-remove';
    remove.setAttribute('aria-label', 'Remove queued message');
    remove.textContent = '✕';
    remove.onclick = () => {
      removeQueuedPrompt(sessionId, entry.id);
      renderQueue();
      updatePromptState();
    };
    item.append(text, remove);
    promptQueue.append(item);
  });
}
function enqueuePrompt(value) {
  if (!value.trim() || !selected || !writable || !sessionState.has(selected)) return false;
  if (new TextEncoder().encode(value).length > 8192) {
    updatePromptState('Message is too large (8 KB maximum)');
    return false;
  }
  const q = sessionQueue(selected, true);
  if (q.length >= QUEUE_CAP) {
    updatePromptState(`Queue is full (${QUEUE_CAP} max)`);
    return false;
  }
  q.push(controlAction(newUUID(), 'prompt', selected, value));
  renderQueue();
  updatePromptState();
  return true;
}
function schedulePromptRetry(sessionId, itemId) {
  clearTimeout(promptRetryTimers.get(sessionId));
  const timer = setTimeout(() => {
    if (promptRetryTimers.get(sessionId) !== timer) return;
    promptRetryTimers.delete(sessionId);
    if (selected === sessionId && sessionQueue(sessionId)[0]?.id === itemId) {
      updatePromptState();
    }
  }, 1000);
  promptRetryTimers.set(sessionId, timer);
}
// Completion belongs to the original queue item, not the visible tab. UI state
// remains selection-fenced; a successful old-tab ACK still consumes its item.
async function flushQueue() {
  const id = selected;
  if (!id || promptFlushes.has(id) || promptRetryTimers.has(id)) return;
  const entry = sessionQueue(id)[0];
  if (!entry || entry.blockedReason) return;
  const state = sessionState.get(id);
  const replaying = entry.outcomeUnknown && canReplayControlAction(
    entry, workspaceProtocolInfo, nonEmptyOperationToken(state?.conversationEpoch)
  );
  if (!(writable && !closingSession && (replaying || (state?.promptable === true
      && !awaitingPromptStart && !(state.pendingUserInputs || []).length
      && !(state.pendingElicitations || []).length)))) return;
  const token = {};
  const generation = selectionGeneration;
  const conversationGeneration = conversationRequestGeneration;
  promptFlushes.set(id, token);
  promptStatus.textContent = 'Sending…';
  try {
    const reason = prepareControlAction(
      entry, workspaceProtocolInfo, nonEmptyOperationToken(state.conversationEpoch), controlDeliveries
    );
    if (reason) { entry.blockedReason = reason; return; }
    entry.outcomeUnknown = true;
    const response = await control(controlActionMessage(entry));
    const isCurrentItem = sessionQueue(id).some((item) => item.id === entry.id);
    const visible = selected === id && selectionGeneration === generation
      && conversationRequestGeneration === conversationGeneration
      && (!entry.delivery || controlActionContextMatches(entry, workspaceProtocolInfo,
        nonEmptyOperationToken(sessionState.get(id)?.conversationEpoch)));
    if (response?.status === 204) {
      removeQueuedPrompt(id, entry.id);
      if (visible) {
        awaitingPromptStart = true;
        clearTimeout(promptFallbackTimer);
        promptFallbackTimer = setTimeout(() => {
          if (selected !== id || selectionGeneration !== generation
              || conversationRequestGeneration !== conversationGeneration) return;
          awaitingPromptStart = false;
          promptFallbackTimer = null;
          updatePromptState();
        }, 5000);
      }
      return;
    }
    if (!isCurrentItem) return;
    if (response?.status === 409) {
      entry.outcomeUnknown = false;
      schedulePromptRetry(id, entry.id);
    } else if (response?.status === 403) {
      entry.outcomeUnknown = false;
      if (visible) {
        writable = false;
        lease.textContent = 'view only';
      }
    } else if ((!response || response.status >= 500)
        && canReplayControlAction(entry, workspaceProtocolInfo,
          nonEmptyOperationToken(sessionState.get(id)?.conversationEpoch))) {
      schedulePromptRetry(id, entry.id);
    } else {
      entry.blockedReason = controlDeliveryFailure(response?.status);
    }
  } finally {
    if (promptFlushes.get(id) === token) promptFlushes.delete(id);
    if (selected === id) {
      renderQueue();
      updatePromptState();
    }
  }
}
// ---- Model picker -------------------------------------------------------
// The composer line shows only the model name; the picker spells out the full
// selection and drives `set-model` over the same lease-gated /control route
// the native clients use.
let modelPickerModelId = null;
let modelSwitchSubmitting = false;

function currentModelInfo() {
  const state = selected && sessionState.get(selected);
  return (state && state.model) || null;
}
function availableModelOptions() {
  const state = selected && sessionState.get(selected);
  return (state && Array.isArray(state.availableModels)) ? state.availableModels : [];
}
function effortLabel(model) {
  const effort = model && model.reasoningEffort;
  if (!effort) return 'Default';
  return effort.charAt(0).toUpperCase() + effort.slice(1);
}
function contextLabel(model) {
  return model && model.contextTier === 'long_context' ? 'Long context' : 'Default';
}
// The session reports its active model as either the id or the display name.
function isCurrentModel(model) {
  const current = currentModelInfo();
  if (!current || !current.name) return false;
  return current.name === model.id || current.name === model.name;
}
function modelSwitchErrorMessage(status) {
  if (status === 403) return 'View only';
  if (status === 409) return 'Another model switch is still processing';
  if (status === 422) return 'Model switch was not accepted';
  return 'Model switch failed';
}
function modelControlsAvailable() {
  return writable
    && operationContext().support !== REMOTE_OPERATION_SUPPORT.UNAVAILABLE
    && !modelSwitchSubmitting;
}
function updateModelPickerStatus() {
  if (modelOperationMessage) {
    setModelPickerStatus(modelOperationMessage, modelOperationIsError);
  } else if (!writable) {
    setModelPickerStatus('View only \u2014 control is on another device');
  } else if (operationContext().support === REMOTE_OPERATION_SUPPORT.UNAVAILABLE) {
    setModelPickerStatus(operationUnavailableMessage(), true);
  } else {
    setModelPickerStatus('');
  }
}
// Never fall back to the first advertised level: several models list "none"
// first, so that would silently disable reasoning. Keep the session's current
// level when re-configuring the active model, otherwise defer to Copilot.
function initialEffort(model) {
  const supported = Array.isArray(model.supportedReasoningEfforts)
    ? model.supportedReasoningEfforts : [];
  const current = isCurrentModel(model)
    ? (currentModelInfo() || {}).reasoningEffort : null;
  return [current, model.defaultReasoningEffort]
    .find((value) => !!value && supported.includes(value)) || '';
}
// Category order mirrors the CLI picker's tabs; unknown/absent categories fall
// into a trailing "Other" group, preserving preferred-first order within each.
function modelSections(options) {
  const order = ['powerful', 'versatile', 'lightweight'];
  const titles = {
    powerful: 'Powerful', versatile: 'Versatile', lightweight: 'Lightweight'
  };
  const grouped = new Map();
  const seen = [];
  for (const model of options) {
    const key = order.includes(model.category) ? model.category : 'other';
    if (!grouped.has(key)) { grouped.set(key, []); seen.push(key); }
    grouped.get(key).push(model);
  }
  if (seen.length === 1 && seen[0] === 'other') {
    return [{ title: '', models: grouped.get('other') }];
  }
  const ordered = order.filter((key) => grouped.has(key))
    .concat(seen.filter((key) => !order.includes(key)));
  return ordered.map((key) => ({
    title: titles[key] || 'Other', models: grouped.get(key)
  }));
}

function renderModelLine() {
  const model = currentModelInfo();
  const name = (model && model.name) || '';
  const signature = model ? JSON.stringify([
    model.name || '',
    model.reasoningEffort || '',
    model.contextTier || '',
  ]) : null;
  if (signature && lastReportedModelSignature
      && signature !== lastReportedModelSignature) {
    const record = sdkOperations.recordForTarget(
      operationTargetContext('set-model', 'model-picker')
    );
    if (record?.state === 'indeterminate') {
      sdkOperations.discard(record.operationId);
      clearModelOperationState(false);
    }
  }
  lastReportedModelSignature = signature;
  const interactive = availableModelOptions().length > 0
    && operationContext().support !== REMOTE_OPERATION_SUPPORT.UNAVAILABLE;
  const controlsUnavailable = availableModelOptions().length > 0 && !interactive;
  modelLine.hidden = !name;
  if (!name) {
    if (modelPicker.open) closeModelPicker();
    return;
  }
  modelLineName.textContent = name;
  modelLine.dataset.interactive = interactive ? 'true' : 'false';
  modelLine.disabled = !interactive;
  modelLine.title = controlsUnavailable ? operationUnavailableMessage() : '';
  const summary = [name, model.reasoningEffort]
    .filter(Boolean)
    .concat(model.contextTier === 'long_context' ? ['long context'] : [])
    .join(' \u00b7 ');
  // Screen-reader users can't glance at the sheet, so keep the full state here.
  modelLine.setAttribute(
    'aria-label',
    interactive
      ? `Model ${summary}. Change model`
      : controlsUnavailable
        ? `Model ${summary}. ${operationUnavailableMessage()}`
        : `Model ${summary}`
  );
  if (modelPicker.open) renderModelPicker();
}

function setModelPickerStatus(message, isError) {
  modelPickerStatus.textContent = message || '';
  modelPickerStatus.classList.toggle('error', !!isError && !!message);
}

function modelCurrentSummary() {
  const current = currentModelInfo();
  if (!current || !current.name) return null;
  const list = document.createElement('dl');
  list.className = 'model-current';
  for (const [label, value] of [
    ['Model', current.name],
    ['Reasoning effort', effortLabel(current)],
    ['Context', contextLabel(current)]
  ]) {
    const row = document.createElement('div');
    row.className = 'model-current-row';
    const dt = document.createElement('dt');
    dt.textContent = label;
    const dd = document.createElement('dd');
    dd.textContent = value;
    row.append(dt, dd);
    list.append(row);
  }
  return list;
}

function renderModelList() {
  modelPickerModelId = null;
  modelPickerTitle.textContent = 'Model';
  modelPickerBack.hidden = true;
  modelPickerBody.replaceChildren();
  const summary = modelCurrentSummary();
  if (summary) {
    const heading = document.createElement('div');
    heading.className = 'model-group-title';
    heading.textContent = 'Current';
    modelPickerBody.append(heading, summary);
  }
  for (const section of modelSections(availableModelOptions())) {
    if (section.title) {
      const heading = document.createElement('div');
      heading.className = 'model-group-title';
      heading.textContent = section.title;
      modelPickerBody.append(heading);
    }
    for (const model of section.models) {
      const row = document.createElement('button');
      row.type = 'button';
      row.className = 'model-row';
      row.disabled = model.disabled === true || !modelControlsAvailable();
      const name = document.createElement('span');
      name.className = 'model-row-name';
      name.textContent = model.name;
      row.append(name);
      if (model.disabled === true) {
        const note = document.createElement('span');
        note.className = 'model-row-note';
        note.textContent = 'Unavailable';
        row.append(note);
      }
      if (isCurrentModel(model)) {
        const check = document.createElement('span');
        check.className = 'model-row-check';
        check.textContent = '\u2713';
        check.setAttribute('aria-label', 'Current model');
        row.append(check);
      }
      row.onclick = () => renderModelOptions(model);
      modelPickerBody.append(row);
    }
  }
  updateModelPickerStatus();
}

function renderModelOptions(model) {
  modelPickerModelId = model.id;
  modelPickerTitle.textContent = model.name;
  modelPickerBack.hidden = false;
  modelPickerBody.replaceChildren();

  const efforts = Array.isArray(model.supportedReasoningEfforts)
    ? model.supportedReasoningEfforts : [];
  let effortSelect = null;
  if (efforts.length) {
    const field = document.createElement('div');
    field.className = 'model-field';
    const label = document.createElement('label');
    label.textContent = 'Reasoning effort';
    label.htmlFor = 'model-effort';
    effortSelect = document.createElement('select');
    effortSelect.id = 'model-effort';
    const fallback = document.createElement('option');
    fallback.value = '';
    fallback.textContent = 'Default';
    effortSelect.append(fallback);
    for (const level of efforts) {
      const option = document.createElement('option');
      option.value = level;
      option.textContent = level.charAt(0).toUpperCase() + level.slice(1);
      effortSelect.append(option);
    }
    effortSelect.value = initialEffort(model);
    const hint = document.createElement('div');
    hint.className = 'model-hint';
    hint.textContent = "Default lets Copilot pick the model's usual level.";
    field.append(label, effortSelect, hint);
    modelPickerBody.append(field);
  }

  let longContext = null;
  if (model.longContextAvailable === true) {
    const field = document.createElement('div');
    field.className = 'model-field';
    const toggle = document.createElement('label');
    toggle.className = 'model-toggle';
    longContext = document.createElement('input');
    longContext.type = 'checkbox';
    longContext.checked = isCurrentModel(model)
      && (currentModelInfo() || {}).contextTier === 'long_context';
    const text = document.createElement('span');
    text.textContent = 'Long context';
    toggle.append(longContext, text);
    const hint = document.createElement('div');
    hint.className = 'model-hint';
    hint.textContent = 'Accept larger inputs at long-context pricing.';
    field.append(toggle, hint);
    modelPickerBody.append(field);
  }

  const apply = document.createElement('button');
  apply.type = 'button';
  apply.className = 'model-apply';
  apply.textContent = `Switch to ${model.name}`;
  apply.disabled = model.disabled === true || !modelControlsAvailable();
  apply.onclick = () => submitModelSwitch(model, {
    reasoningEffort: effortSelect ? (effortSelect.value || null) : null,
    contextTier: longContext ? (longContext.checked ? 'long_context' : 'default') : null
  });
  modelPickerBody.append(apply);
  updateModelPickerStatus();
}

function renderModelPicker() {
  const options = availableModelOptions();
  const target = modelPickerModelId
    && options.find((model) => model.id === modelPickerModelId);
  if (target) renderModelOptions(target); else renderModelList();
}

async function submitModelSwitch(model, selection) {
  if (modelSwitchSubmitting) return;
  const sessionId = selected;
  if (!sessionId || !writable) return;
  const context = operationContext(sessionId);
  const data = JSON.stringify({
    modelId: model.id,
    reasoningEffort: selection.reasoningEffort,
    contextTier: selection.contextTier
  });
  const plan = sdkOperations.prepare({
    sessionId,
    conversationEpoch: context.conversationEpoch,
    support: context.support,
    kind: 'set-model',
    targetId: 'model-picker',
    payloadContext: data
  });
  if (plan.mode === REMOTE_OPERATION_SUPPORT.UNAVAILABLE) {
    modelOperationMessage = operationUnavailableMessage();
    modelOperationIsError = true;
    updateModelPickerStatus();
    return;
  }
  if (plan.mode === 'capacity') {
    modelOperationMessage = 'Too many Copilot operations are still pending.';
    modelOperationIsError = true;
    updateModelPickerStatus();
    return;
  }
  if (plan.mode === 'duplicate') {
    modelSwitchSubmitting = plan.record.state !== 'rejected';
    modelOperationId = plan.record.operationId;
    modelOperationMessage = remoteOperationMessage(plan.record);
    modelOperationIsError = plan.record.state !== 'accepted'
      && plan.record.state !== 'submitting';
    renderModelPicker();
    return;
  }
  modelSwitchSubmitting = true;
  modelOperationId = plan.record?.operationId || null;
  modelOperationMessage = 'Sending\u2026';
  modelOperationIsError = false;
  setModelPickerStatus('Switching\u2026');
  if (plan.mode === REMOTE_OPERATION_SUPPORT.RECEIPTS) {
    modelOperationTimer = setTimeout(() => {
      if (modelOperationId !== plan.record.operationId) return;
      const previousState = plan.record.state;
      const record = sdkOperations.markIndeterminate(
        plan.record.operationId,
        'receipt-timeout'
      );
      if (record) applyOperationTransition({
        record,
        previousState,
        state: 'indeterminate'
      });
    }, RECEIPT_TIMEOUT_MS);
  }
  const submittedGeneration = conversationRequestGeneration;
  const response = await control(remoteOperationControlMessage(
    'set-model', sessionId, data, plan
  ));
  if (selected !== sessionId
      || conversationRequestGeneration !== submittedGeneration) return;
  if (plan.mode === REMOTE_OPERATION_SUPPORT.LEGACY) {
    modelSwitchSubmitting = false;
    modelOperationId = null;
    modelOperationMessage = '';
    if (response?.status === 204) {
      closeModelPicker();
      return;
    }
    if (response?.status === 403) {
      writable = false;
      lease.textContent = 'view only';
      updatePromptState();
    }
    modelOperationMessage = modelSwitchErrorMessage(response ? response.status : 0);
    modelOperationIsError = true;
    updateModelPickerStatus();
    return;
  }
  const result = sdkOperations.resolveHTTP(
    plan.record.operationId, response?.status ?? null
  );
  if (result.outcome === 'stale' || result.outcome === 'settled') return;
  if (result.outcome === 'accepted') {
    modelOperationMessage = remoteOperationMessage(result.record);
    modelOperationIsError = false;
    renderModelPicker();
    return;
  }
  if (result.outcome === 'rejected') {
    modelSwitchSubmitting = false;
    modelOperationId = null;
    if (response.status === 403) {
      writable = false;
      lease.textContent = 'view only';
      updatePromptState();
    }
    modelOperationMessage = modelSwitchErrorMessage(response.status);
    modelOperationIsError = true;
    renderModelPicker();
    return;
  }
  if (result.record) {
    modelOperationMessage = remoteOperationMessage(result.record);
    modelOperationIsError = true;
    renderModelPicker();
  }
}

function openModelPicker() {
  if (!availableModelOptions().length) return;
  renderModelList();
  if (!modelPicker.open) modelPicker.showModal();
}
function closeModelPicker() {
  modelPickerModelId = null;
  setModelPickerStatus('');
  if (modelPicker.open) modelPicker.close();
}

modelLine.onclick = openModelPicker;
modelPickerBack.onclick = () => renderModelList();
modelPickerClose.onclick = () => closeModelPicker();
modelPicker.addEventListener('close', () => {
  modelPickerModelId = null;
  setModelPickerStatus('');
});

function updatePromptState(message) {
  updateCloseSessionState();
  renderInputDeliveryState();
  renderModelLine();
  const state = selected && sessionState.get(selected);
  const pendingInputs = (state && state.pendingUserInputs) || [];
  const pendingElicits = (state && state.pendingElicitations) || [];
  const hasQuestions = pendingInputs.length > 0 || pendingElicits.length > 0;
  promptForm.classList.toggle('hidden', hasQuestions);
  if (hasQuestions) {
    promptSubmit.disabled = true;
    promptStatus.textContent = message || 'Answer Copilot\u2019s question below';
    flushQueue();
    return;
  }
  if (awaitingPromptStart && state?.promptable === false) {
    awaitingPromptStart = false;
    clearTimeout(promptFallbackTimer);
    promptFallbackTimer = null;
  }
  const q = selected ? (promptQueues.get(selected) || []) : [];
  promptSubmit.disabled = !(selected && writable
    && prompt.value.trim() && q.length < QUEUE_CAP);
  if (message) {
    promptStatus.textContent = message;
  } else if (!selected) {
    promptStatus.textContent = 'Select a Copilot session';
  } else if (!writable) {
    promptStatus.textContent = 'View only';
  } else if (q[0]?.blockedReason) {
    promptStatus.textContent = q[0].blockedReason;
  } else if (q.length) {
    promptStatus.textContent = `${q.length} queued`;
  } else if (awaitingPromptStart) {
    promptStatus.textContent = 'Sending…';
  } else if (state?.background) {
    promptStatus.textContent = 'Background work active';
  } else if (state?.status === 'waiting') {
    promptStatus.textContent = 'Use the terminal to answer Copilot';
  } else if (state?.status === 'running') {
    promptStatus.textContent = 'Copilot is working';
  } else if (state?.promptable === true) {
    promptStatus.textContent = 'Ready';
  } else {
    promptStatus.textContent = 'Start Copilot in this session';
  }
  flushQueue();
}
function clearUserInputSubmission(requestId, operationId) {
  const entry = submittingUserInputs.get(requestId);
  if (!entry || (operationId && entry.operationId !== operationId)) return;
  if (entry.timer) clearTimeout(entry.timer);
  submittingUserInputs.delete(requestId);
  latestUserInputAttempts.delete(requestId);
}
function clearElicitationSubmission(requestId, operationId) {
  const entry = submittingElicitations.get(requestId);
  if (!entry || (operationId && entry.operationId !== operationId)) return;
  if (entry.timer) clearTimeout(entry.timer);
  submittingElicitations.delete(requestId);
  latestElicitationAttempts.delete(requestId);
}
function applyOperationTransition(transition) {
  const { record, state } = transition;
  if (record.kind === 'answer-user-input') {
    if (state === 'applied' || state === 'rejected' || state === 'indeterminate') {
      clearUserInputSubmission(record.targetId, record.operationId);
    }
    setCardStatus(record.targetId, remoteOperationMessage(record));
    setCardSubmitting(
      record.targetId,
      state === 'accepted' || state === 'indeterminate'
    );
    return;
  }
  if (record.kind === 'answer-elicitation') {
    if (state === 'applied' || state === 'rejected' || state === 'indeterminate') {
      clearElicitationSubmission(record.targetId, record.operationId);
    }
    setElicitationStatus(record.targetId, remoteOperationMessage(record));
    const entry = elicitationCards.get(record.targetId);
    if (entry) entry.refresh();
    return;
  }
  if (record.kind !== 'set-model' || modelOperationId !== record.operationId) return;
  if (modelOperationTimer) clearTimeout(modelOperationTimer);
  modelOperationTimer = null;
  if (state === 'applied') {
    sdkOperations.discard(record.operationId);
    clearModelOperationState(false);
    closeModelPicker();
    return;
  }
  modelSwitchSubmitting = state !== 'rejected';
  if (state === 'rejected') modelOperationId = null;
  modelOperationMessage = remoteOperationMessage(record);
  modelOperationIsError = state === 'rejected' || state === 'indeterminate';
  if (modelPicker.open) renderModelPicker();
}
function reconcileSelectedOperationReceipts() {
  const state = selected && sessionState.get(selected);
  if (!state) return;
  sdkOperations.reconcile(state, workspaceProtocolInfo)
    .forEach(applyOperationTransition);
}
function updateSelectedConversationEpoch() {
  const state = selected && sessionState.get(selected);
  if (!state) return;
  const nextEpoch = nonEmptyOperationToken(state.conversationEpoch);
  if (nextEpoch && selectedConversationEpoch
      && nextEpoch !== selectedConversationEpoch) {
    selectedConversationEpoch = nextEpoch;
    invalidateConversationOperations();
    awaitingPromptStart = false;
    clearTimeout(promptFallbackTimer);
    promptFallbackTimer = null;
    resetTranscriptForSession();
    if (viewMode === 'conversation') {
      showTranscriptPlaceholder('Loading completed turns\u2026');
    } else {
      clearTranscriptDOM();
    }
    fetchTranscript({ sessionId: selected });
    return;
  }
  if (nextEpoch) selectedConversationEpoch = nextEpoch;
}
function renderWorkspace(data) {
  const active = selected;
  const activeWasPresent = !!active && sessionState.has(active);
  workspaceProtocolInfo = data?.protocolInfo || null;
  const nextProjectId = data.selectedProjectId || null;
  hostSelectedProjectId = nextProjectId;
  syncCreateProjectOptions(data.projects, hostSelectedProjectId);
  sessionState.clear();
  sessions.replaceChildren();
  data.projects.forEach((project) => {
    const heading = document.createElement('h3');
    heading.textContent = project.name;
    sessions.append(heading);
    project.sessions.forEach((session) => {
      sessionState.set(session.id, session);
      const button = document.createElement('button');
      button.dataset.id = session.id;
      button.className = session.id === active ? 'active' : '';
      button.textContent = session.title;
      const detail = document.createElement('small');
      const states = [session.status];
      if (session.background) states.push('background');
      if (session.scheduled) states.push('scheduled');
      if (session.unread) states.push('unread');
      detail.textContent = states.join(' · ');
      button.append(detail);
      button.onclick = () => selectSession(session.id);
      sessions.append(button);
    });
  });
  if (activeWasPresent && !sessionState.has(active)) {
    invalidateConversationOperations();
    selectedConversationEpoch = null;
  }
  const liveSessionIds = new Set(sessionState.keys());
  prunePromptDrafts(liveSessionIds);
  controlDeliveries.prune(liveSessionIds);
  for (const id of uncertainTerminalActions.keys()) {
    if (!liveSessionIds.has(id)) uncertainTerminalActions.delete(id);
  }
  for (const id of promptQueues.keys()) {
    if (liveSessionIds.has(id)) continue;
    promptQueues.delete(id);
    promptFlushes.delete(id);
    clearTimeout(promptRetryTimers.get(id));
    promptRetryTimers.delete(id);
  }
  updateNewSessionState();
  // Select a just-created session once the host's snapshot includes it, without
  // ever changing the host Mac's own selection.
  if (pendingCreatedSessionId && sessionState.has(pendingCreatedSessionId)) {
    const sessionId = pendingCreatedSessionId;
    pendingCreatedSessionId = null;
    selectSession(sessionId);
  }
  if (pendingFocusSession) {
    const target = document.querySelector(
      `nav button[data-id="${CSS.escape(pendingFocusSession)}"]`
    );
    if (target) {
      const sessionId = pendingFocusSession;
      pendingFocusSession = null;
      selectSession(sessionId);
    }
  }
  updateSelectedConversationEpoch();
  reconcileSelectedOperationReceipts();
  syncUserInputCards();
  syncElicitationCards();
  updatePromptState();
}
function currentUserInputs() {
  return (selected && sessionState.get(selected)?.pendingUserInputs) || [];
}
function sessionHasUserInput(sessionId, requestId) {
  return (sessionState.get(sessionId)?.pendingUserInputs || [])
    .some((request) => request.requestId === requestId);
}
function resetUserInputCards() {
  submittingUserInputs.forEach((entry) => clearTimeout(entry.timer));
  submittingUserInputs.clear();
  latestUserInputAttempts.clear();
  userInputCards.clear();
  userInput.replaceChildren();
}
function setCardStatus(requestId, text) {
  const status = userInputCards.get(requestId)?.querySelector('.user-input-status');
  if (status) status.textContent = text || '';
}
function setCardSubmitting(requestId, submitting) {
  const card = userInputCards.get(requestId);
  if (!card) return;
  const unavailable = operationContext().support
    === REMOTE_OPERATION_SUPPORT.UNAVAILABLE;
  card.querySelectorAll('button, textarea').forEach((element) => {
    element.disabled = submitting || !writable || unavailable;
  });
}
function refreshUserInputCardStates() {
  for (const requestId of userInputCards.keys()) {
    setCardSubmitting(requestId, submittingUserInputs.has(requestId));
  }
}
// Untrusted question/choice text is only ever inserted with textContent.
function buildUserInputCard(request) {
  const card = document.createElement('article');
  card.className = 'user-input-card';
  card.dataset.requestId = request.requestId;
  const questionId = `user-input-question-${++userInputCardSequence}`;
  card.setAttribute('aria-labelledby', questionId);
  const head = document.createElement('div');
  head.className = 'user-input-head';
  const heading = document.createElement('span');
  heading.textContent = 'Copilot needs your input';
  head.append(heading);
  if (request.agentId) {
    const agent = document.createElement('span');
    agent.className = 'user-input-agent';
    agent.textContent = 'Subagent';
    head.append(agent);
  }
  card.append(head);
  const question = document.createElement('div');
  question.className = 'user-input-question';
  question.id = questionId;
  question.textContent = request.question;
  card.append(question);
  const choices = Array.isArray(request.choices) ? request.choices : [];
  if (choices.length) {
    const group = document.createElement('div');
    group.className = 'user-input-choices';
    group.setAttribute('role', 'group');
    group.setAttribute('aria-labelledby', questionId);
    choices.forEach((choice) => {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'user-input-choice';
      button.textContent = choice;
      button.setAttribute('aria-describedby', questionId);
      button.onclick = () => submitUserInput(request.requestId, choice, false);
      group.append(button);
    });
    card.append(group);
  }
  if (request.allowFreeform) {
    const freeform = document.createElement('form');
    freeform.className = 'user-input-freeform';
    freeform.setAttribute('aria-labelledby', questionId);
    const fieldLabel = document.createElement('span');
    fieldLabel.className = 'visually-hidden';
    fieldLabel.id = `${questionId}-answer-label`;
    fieldLabel.textContent = 'Type an answer';
    const field = document.createElement('textarea');
    field.rows = 2;
    field.maxLength = 8192;
    field.setAttribute('aria-labelledby', `${fieldLabel.id} ${questionId}`);
    field.placeholder = 'Type an answer';
    const submit = document.createElement('button');
    submit.type = 'submit';
    submit.textContent = 'Send answer';
    submit.setAttribute('aria-describedby', questionId);
    freeform.append(fieldLabel, field, submit);
    freeform.onsubmit = (event) => {
      event.preventDefault();
      const value = field.value;
      if (!value.trim()) return;
      submitUserInput(request.requestId, value, true);
    };
    card.append(freeform);
  }
  const status = document.createElement('div');
  status.className = 'user-input-status';
  status.setAttribute('role', 'status');
  status.setAttribute('aria-live', 'polite');
  card.append(status);
  return card;
}
// Only rebuild when the set of request IDs changes so a half-typed freeform
// answer isn't wiped by an unrelated workspace update. A card is removed only
// once the workspace snapshot no longer includes its request.
function syncUserInputCards() {
  const context = operationContext();
  const rawPending = currentUserInputs();
  const rawIds = new Set(rawPending.map((request) => request.requestId));
  sdkOperations.pruneSettledTargets({
    sessionId: selected,
    conversationEpoch: context.conversationEpoch,
    kind: 'answer-user-input',
    visibleTargetIds: rawIds
  });
  const pending = rawPending.filter((request) => !sdkOperations.shouldSuppressTarget(
    operationTargetContext('answer-user-input', request.requestId)
  ));
  const ids = new Set(pending.map((request) => request.requestId));
  for (const [requestId, card] of [...userInputCards]) {
    const target = operationTargetContext('answer-user-input', requestId);
    if (!ids.has(requestId) && !sdkOperations.shouldPreserveTarget(target)) {
      card.remove();
      userInputCards.delete(requestId);
      const entry = submittingUserInputs.get(requestId);
      if (entry) {
        clearTimeout(entry.timer);
        submittingUserInputs.delete(requestId);
      }
      latestUserInputAttempts.delete(requestId);
    }
  }
  pending.forEach((request) => {
    let card = userInputCards.get(request.requestId);
    if (!card) {
      card = buildUserInputCard(request);
      userInputCards.set(request.requestId, card);
      userInput.append(card);
    }
    const target = operationTargetContext('answer-user-input', request.requestId);
    const record = sdkOperations.recordForTarget(target);
    setCardSubmitting(
      request.requestId,
      submittingUserInputs.has(request.requestId)
        || sdkOperations.shouldPreserveTarget(target)
    );
    if (record) {
      setCardStatus(request.requestId, remoteOperationMessage(record));
    } else if (context.support === REMOTE_OPERATION_SUPPORT.UNAVAILABLE) {
      setCardStatus(request.requestId, operationUnavailableMessage());
    } else {
      const status = card.querySelector('.user-input-status');
      if (status?.textContent === operationUnavailableMessage()) status.textContent = '';
    }
  });
}
async function submitUserInput(requestId, answer, wasFreeform) {
  if (!selected || !writable || submittingUserInputs.has(requestId)) return;
  if (new TextEncoder().encode(answer).length > 8192) {
    setCardStatus(requestId, 'Answer is too large (8 KB maximum)');
    return;
  }
  const submittedSession = selected;
  const submittedGeneration = selectionGeneration;
  const submittedConversationGeneration = conversationRequestGeneration;
  const data = JSON.stringify({ requestId, answer, wasFreeform });
  const context = operationContext(submittedSession);
  const plan = sdkOperations.prepare({
    sessionId: submittedSession,
    conversationEpoch: context.conversationEpoch,
    support: context.support,
    kind: 'answer-user-input',
    targetId: requestId,
    payloadContext: data
  });
  if (plan.mode === REMOTE_OPERATION_SUPPORT.UNAVAILABLE) {
    setCardStatus(requestId, operationUnavailableMessage());
    setCardSubmitting(requestId, false);
    return;
  }
  if (plan.mode === 'capacity') {
    setCardStatus(requestId, 'Too many Copilot operations are still pending.');
    return;
  }
  if (plan.mode === 'duplicate') {
    setCardStatus(requestId, remoteOperationMessage(plan.record));
    setCardSubmitting(requestId, plan.record.state !== 'rejected');
    return;
  }
  const token = ++userInputAttemptSequence;
  latestUserInputAttempts.set(requestId, token);
  // Only an older host lacks receipts. Keep its existing guarded 15-second
  // workspace fallback; receipt-mode controls remain disabled until an exact
  // tracker outcome arrives.
  const timer = plan.mode === REMOTE_OPERATION_SUPPORT.LEGACY
    ? setTimeout(() => {
      const entry = submittingUserInputs.get(requestId);
      if (!entry || entry.token !== token) return;
      submittingUserInputs.delete(requestId);
      if (selected === submittedSession
          && conversationRequestGeneration === submittedConversationGeneration
          && sessionHasUserInput(submittedSession, requestId)) {
        setCardSubmitting(requestId, false);
        setCardStatus(
          requestId,
          'Still waiting \u2014 check the terminal before trying again.'
        );
      }
    }, 15000)
    : setTimeout(() => {
      const entry = submittingUserInputs.get(requestId);
      if (!entry || entry.token !== token
          || entry.operationId !== plan.record.operationId) return;
      const previousState = plan.record.state;
      const record = sdkOperations.markIndeterminate(
        plan.record.operationId,
        'receipt-timeout'
      );
      if (record) applyOperationTransition({
        record,
        previousState,
        state: 'indeterminate'
      });
    }, RECEIPT_TIMEOUT_MS);
  submittingUserInputs.set(requestId, {
    timer,
    token,
    operationId: plan.record?.operationId || null,
    mode: plan.mode
  });
  setCardSubmitting(requestId, true);
  setCardStatus(requestId, 'Sending\u2026');
  const response = await control(remoteOperationControlMessage(
    'answer-user-input', submittedSession, data, plan
  ));
  if (selected !== submittedSession
      || selectionGeneration !== submittedGeneration
      || conversationRequestGeneration !== submittedConversationGeneration) return;
  if (latestUserInputAttempts.get(requestId) !== token) return;
  if (plan.mode === REMOTE_OPERATION_SUPPORT.LEGACY) {
    if (response?.status === 204) {
      setCardStatus(requestId, 'Waiting for Copilot\u2026');
      return;
    }
    if (!response || response.status >= 500
        || (response.status >= 200 && response.status < 300)) {
      setCardStatus(requestId, 'Delivery outcome unknown \u2014 check the terminal.');
      return;
    }
  } else {
    const result = sdkOperations.resolveHTTP(
      plan.record.operationId, response?.status ?? null
    );
    if (result.outcome === 'stale' || result.outcome === 'settled') return;
    if (result.outcome === 'accepted' || result.outcome === 'indeterminate') {
      if (result.record) {
        setCardStatus(requestId, remoteOperationMessage(result.record));
      }
      return;
    }
  }
  clearUserInputSubmission(requestId);
  setCardSubmitting(requestId, false);
  if (response?.status === 403) {
    writable = false;
    lease.textContent = 'view only';
    refreshUserInputCardStates();
    setCardStatus(requestId, 'Control moved to another device');
  } else if (response?.status === 409) {
    setCardStatus(requestId, 'Another answer is still processing \u2014 try again.');
  } else if (response?.status === 422) {
    setCardStatus(requestId, 'Answer was not accepted');
  } else {
    setCardStatus(requestId, 'Answer was not sent');
  }
}
// ---- Schema-form / url elicitations (elicitation.requested) --------------
// Mirrors the iOS ElicitationForm/ElicitationCard: only a bounded, flat subset
// of JSON Schema is rendered natively; anything outside it falls back to the
// terminal so we never render arbitrary or nested schema.
const ELICITATION_MAX_FIELDS = 32;
const ELICITATION_MAX_CHOICES = 50;
function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
function nonNegativeInt(value) {
  if (typeof value !== 'number' || !Number.isFinite(value)
    || value < 0 || !Number.isInteger(value)) {
    return null;
  }
  return value;
}
function labeledElicitationChoices(entries) {
  if (!Array.isArray(entries) || entries.length > ELICITATION_MAX_CHOICES) return null;
  const choices = [];
  const seen = new Set();
  for (const entry of entries) {
    if (!isPlainObject(entry)) return null;
    if (!Object.keys(entry).every((key) => key === 'const' || key === 'title')) return null;
    if (typeof entry.const !== 'string' || seen.has(entry.const)) return null;
    seen.add(entry.const);
    let title = entry.const;
    if ('title' in entry) {
      if (typeof entry.title !== 'string') return null;
      title = entry.title;
    }
    choices.push({ value: entry.const, title });
  }
  return choices.length ? choices : null;
}
function bareElicitationChoices(values) {
  if (!Array.isArray(values) || values.length > ELICITATION_MAX_CHOICES) return null;
  const choices = [];
  const seen = new Set();
  for (const entry of values) {
    if (typeof entry !== 'string' || seen.has(entry)) return null;
    seen.add(entry);
    choices.push({ value: entry, title: entry });
  }
  return choices.length ? choices : null;
}
function elicitationChoiceSet(items) {
  const supportedItemKeys = new Set([
    'anyOf', 'oneOf', 'enum', 'type', 'title', 'description'
  ]);
  if (!Object.keys(items).every((key) => supportedItemKeys.has(key))) return null;
  if ('type' in items && items.type !== 'string') return null;
  const alternatives = Array.isArray(items.anyOf) ? items.anyOf
    : Array.isArray(items.oneOf) ? items.oneOf : null;
  if (alternatives) {
    if ('enum' in items) return null;
    return labeledElicitationChoices(alternatives);
  }
  if (Array.isArray(items.enum)) return bareElicitationChoices(items.enum);
  return null;
}
function elicitationStringKind(prop) {
  let minLength = null;
  if ('minLength' in prop) {
    minLength = nonNegativeInt(prop.minLength);
    if (minLength === null) return null;
  }
  let maxLength = null;
  if ('maxLength' in prop) {
    maxLength = nonNegativeInt(prop.maxLength);
    if (maxLength === null) return null;
  }
  if (minLength !== null && maxLength !== null && minLength > maxLength) return null;
  return { type: 'string', minLength, maxLength };
}
function elicitationArrayKind(prop) {
  if (!isPlainObject(prop.items)) return null;
  const choices = elicitationChoiceSet(prop.items);
  if (!choices) return null;
  let minItems = null;
  if ('minItems' in prop) {
    minItems = nonNegativeInt(prop.minItems);
    if (minItems === null) return null;
  }
  let maxItems = null;
  if ('maxItems' in prop) {
    maxItems = nonNegativeInt(prop.maxItems);
    if (maxItems === null) return null;
  }
  if (minItems !== null && maxItems !== null && minItems > maxItems) return null;
  return { type: 'stringMultiSelect', choices, minItems, maxItems };
}
function elicitationFieldKind(prop) {
  if ('$ref' in prop) return null;
  const banned = [
    'anyOf', 'allOf', 'not', 'if', 'then', 'else', 'const', 'format', 'pattern',
    'minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum', 'multipleOf'
  ];
  for (const key of banned) {
    if (key in prop) return null;
  }
  if (Array.isArray(prop.oneOf)) {
    if ('enum' in prop) return null;
    if ('minLength' in prop || 'maxLength' in prop) return null;
    if (prop.type !== 'string') return null;
    const choices = labeledElicitationChoices(prop.oneOf);
    return choices ? { type: 'stringOneOf', choices } : null;
  }
  if (Array.isArray(prop.enum)) {
    if ('minLength' in prop || 'maxLength' in prop) return null;
    if (prop.type !== 'string') return null;
    if (prop.enum.length > ELICITATION_MAX_CHOICES) return null;
    const options = [];
    const seen = new Set();
    for (const entry of prop.enum) {
      if (typeof entry !== 'string') return null;
      options.push(entry);
      seen.add(entry);
    }
    if (seen.size !== options.length) return null;
    return options.length ? { type: 'stringEnum', options } : null;
  }
  if (typeof prop.type !== 'string') return null;
  const type = prop.type;
  if (type !== 'string' && ('minLength' in prop || 'maxLength' in prop)) return null;
  switch (type) {
    case 'boolean': return { type: 'bool' };
    case 'integer': return { type: 'number', isInteger: true };
    case 'number': return { type: 'number', isInteger: false };
    case 'string': return elicitationStringKind(prop);
    case 'array': return elicitationArrayKind(prop);
    default: return null;
  }
}
function parseElicitationForm(schema) {
  if (!isPlainObject(schema)) return null;
  const supportedRootKeys = new Set([
    '$schema', 'type', 'title', 'description', 'properties', 'required',
    'additionalProperties'
  ]);
  if (!Object.keys(schema).every((key) => supportedRootKeys.has(key))) return null;
  if ('type' in schema && schema.type !== 'object') return null;
  const properties = schema.properties;
  if (!isPlainObject(properties)) return null;
  const propertyKeys = Object.keys(properties);
  if (!propertyKeys.length || propertyKeys.length > ELICITATION_MAX_FIELDS) return null;
  const required = new Set();
  if ('required' in schema) {
    if (!Array.isArray(schema.required)) return null;
    for (const name of schema.required) {
      if (typeof name !== 'string') return null;
      required.add(name);
    }
  }
  for (const name of required) {
    if (!(name in properties)) return null;
  }
  const fields = [];
  // JSON object key order isn't guaranteed across the wire, so sort keys for a
  // stable, deterministic field order (matches the iOS client).
  for (const key of propertyKeys.slice().sort()) {
    const prop = properties[key];
    if (!isPlainObject(prop)) return null;
    const kind = elicitationFieldKind(prop);
    if (!kind) return null;
    const title = typeof prop.title === 'string' ? prop.title : key;
    const description = typeof prop.description === 'string' ? prop.description : null;
    fields.push({
      key, title, description, kind,
      required: required.has(key),
      hasDefault: 'default' in prop,
      defaultValue: 'default' in prop ? prop.default : undefined
    });
  }
  return fields.length ? { fields } : null;
}
function terminalDefaultBoolean(request) {
  if (request.mode !== 'terminal-default'
      || !isPlainObject(request.schema)
      || request.schema['x-copilot-projects-terminal-default'] !== true
      || Object.keys(request.schema).length !== 2
      || !isPlainObject(request.schema.properties)) return null;
  const keys = Object.keys(request.schema.properties);
  if (keys.length !== 1) return null;
  const field = request.schema.properties[keys[0]];
  if (!isPlainObject(field)
      || field.type !== 'boolean'
      || typeof field.default !== 'boolean') return null;
  return { key: keys[0], value: field.default };
}
function elicitationAccepts(kind, value) {
  switch (kind.type) {
    case 'stringEnum':
      return typeof value === 'string' && kind.options.includes(value);
    case 'stringOneOf':
      return typeof value === 'string'
        && kind.choices.some((choice) => choice.value === value);
    case 'bool':
      return typeof value === 'boolean';
    case 'number':
      if (typeof value !== 'number' || !Number.isFinite(value)) return false;
      return kind.isInteger ? value === Math.round(value) : true;
    case 'string': {
      if (typeof value !== 'string') return false;
      const length = [...value].length;
      if (kind.minLength !== null && length < kind.minLength) return false;
      if (kind.maxLength !== null && length > kind.maxLength) return false;
      return true;
    }
    case 'stringMultiSelect': {
      if (!Array.isArray(value)) return false;
      const seen = new Set();
      for (const item of value) {
        if (typeof item !== 'string') return false;
        if (!kind.choices.some((choice) => choice.value === item)) return false;
        if (seen.has(item)) return false;
        seen.add(item);
      }
      if (kind.minItems !== null && value.length < kind.minItems) return false;
      if (kind.maxItems !== null && value.length > kind.maxItems) return false;
      return true;
    }
    default:
      return false;
  }
}
// Build the accepted-answer payload, or null while any present value is invalid
// or a required field is missing.
function validatedElicitationContent(form, values, touched) {
  const payload = {};
  for (const field of form.fields) {
    if (!(field.key in values)) {
      if (field.required) return null;
      continue;
    }
    const value = values[field.key];
    if (!elicitationAccepts(field.kind, value)) return null;
    if (field.required || touched.has(field.key) || field.hasDefault) {
      payload[field.key] = value;
    }
  }
  return payload;
}
function seedElicitationDefaults(entry) {
  if (!entry.form) return;
  for (const field of entry.form.fields) {
    if (field.hasDefault && elicitationAccepts(field.kind, field.defaultValue)) {
      entry.values[field.key] = field.defaultValue;
    } else if (field.required) {
      switch (field.kind.type) {
        case 'stringEnum':
          if (field.kind.options.length) entry.values[field.key] = field.kind.options[0];
          break;
        case 'stringOneOf':
          if (field.kind.choices.length) {
            entry.values[field.key] = field.kind.choices[0].value;
          }
          break;
        case 'bool':
          entry.values[field.key] = false;
          break;
        case 'string':
          entry.values[field.key] = '';
          break;
        case 'stringMultiSelect':
          entry.values[field.key] = [];
          break;
        case 'number':
          break;  // required numbers must be filled by the user
      }
    }
  }
}
function elicitationValuesEqual(a, b) {
  if (a === undefined && b === undefined) return true;
  return a === b;
}
function parseElicitationNumber(text) {
  const trimmed = text.trim();
  if (!trimmed) return null;
  if (!/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(trimmed)) return null;
  const value = Number(trimmed);
  return Number.isFinite(value) ? value : null;
}
function formatElicitationNumber(value) {
  if (value === Math.round(value) && Math.abs(value) < 1e15) {
    return String(Math.round(value));
  }
  return String(value);
}
function elicitationStringLengthRequirement(kind) {
  if (kind.type !== 'string') return null;
  const { minLength, maxLength } = kind;
  if (minLength !== null && maxLength !== null) {
    return `Use ${minLength}\u2013${maxLength} code points.`;
  }
  if (minLength !== null) {
    return `Use at least ${minLength} ${minLength === 1 ? 'code point' : 'code points'}.`;
  }
  if (maxLength !== null) {
    return `Use at most ${maxLength} ${maxLength === 1 ? 'code point' : 'code points'}.`;
  }
  return null;
}
function safeWebURL(rawURL) {
  if (typeof rawURL !== 'string' || !rawURL) return null;
  let url;
  try {
    url = new URL(rawURL);
  } catch (error) {
    return null;
  }
  const scheme = url.protocol.toLowerCase();
  if (scheme !== 'https:' && scheme !== 'http:') return null;
  if (!url.host) return null;
  return url.href;
}
function currentElicitations() {
  return (selected && sessionState.get(selected)?.pendingElicitations) || [];
}
function sessionHasElicitation(sessionId, requestId) {
  return (sessionState.get(sessionId)?.pendingElicitations || [])
    .some((request) => request.requestId === requestId);
}
function resetElicitationCards() {
  submittingElicitations.forEach((entry) => clearTimeout(entry.timer));
  submittingElicitations.clear();
  latestElicitationAttempts.clear();
  elicitationCards.clear();
}
function setElicitationStatus(requestId, text) {
  const status = elicitationCards.get(requestId)?.card
    .querySelector('.user-input-status');
  if (status) status.textContent = text || '';
}
function refreshElicitationControls(entry) {
  const submitting = submittingElicitations.has(entry.request.requestId);
  const blocked = sdkOperations.shouldPreserveTarget(
    operationTargetContext('answer-elicitation', entry.request.requestId)
  );
  const unavailable = !entry.syntheticLegacy
    && operationContext().support === REMOTE_OPERATION_SUPPORT.UNAVAILABLE;
  const disabled = submitting || blocked || !writable || unavailable;
  entry.card.querySelectorAll(
    'select, input, textarea, .elicitation-multi-option, .elicitation-decline'
  ).forEach((element) => { element.disabled = disabled; });
  entry.card.querySelectorAll('.elicitation-multi-option').forEach((button) => {
    button.style.opacity = disabled ? '0.5' : '1';
  });
  if (entry.submitButton) {
    if (entry.isURLMode) {
      entry.submitButton.disabled = disabled;
    } else if (entry.terminalDefault) {
      entry.submitButton.disabled = disabled;
    } else if (entry.form) {
      entry.submitButton.disabled = disabled
        || validatedElicitationContent(entry.form, entry.values, entry.touched) === null;
    }
  }
}
function refreshElicitationCardStates() {
  for (const entry of elicitationCards.values()) {
    refreshElicitationControls(entry);
  }
}
function selectedMultiStrings(entry, key) {
  const value = entry.values[key];
  if (!Array.isArray(value)) return [];
  return value.filter((item) => typeof item === 'string');
}
function toggleElicitationChoice(entry, field, value) {
  const kind = field.kind;
  const selected = new Set(selectedMultiStrings(entry, field.key));
  if (selected.has(value)) {
    selected.delete(value);
  } else {
    if (kind.maxItems !== null && selected.size >= kind.maxItems) return;
    selected.add(value);
  }
  entry.values[field.key] = kind.choices
    .map((choice) => choice.value)
    .filter((choiceValue) => selected.has(choiceValue));
  entry.touched.add(field.key);
}
function buildElicitationChoiceSelect(entry, field, controlId, options) {
  const select = document.createElement('select');
  select.id = controlId;
  select.className = 'elicitation-control';
  options.forEach((option) => {
    const element = document.createElement('option');
    element.textContent = option.title;
    select.append(element);
  });
  select.onchange = () => {
    const chosen = options[select.selectedIndex];
    if (chosen.value === undefined) delete entry.values[field.key];
    else entry.values[field.key] = chosen.value;
    entry.touched.add(field.key);
    entry.refresh();
  };
  entry.controlSyncers.push(() => {
    const current = entry.values[field.key];
    let index = options.findIndex((option) =>
      elicitationValuesEqual(option.value, current));
    if (index < 0) index = 0;
    select.selectedIndex = index;
  });
  return select;
}
function buildElicitationControl(entry, field, controlId) {
  const kind = field.kind;
  switch (kind.type) {
    case 'stringEnum': {
      const options = kind.options.map((option) =>
        ({ value: option, title: option === '' ? 'Empty string' : option }));
      if (!field.required) options.unshift({ value: undefined, title: 'Not set' });
      return buildElicitationChoiceSelect(entry, field, controlId, options);
    }
    case 'stringOneOf': {
      const options = kind.choices.map((choice) =>
        ({ value: choice.value, title: choice.title }));
      if (!field.required) options.unshift({ value: undefined, title: 'Not set' });
      return buildElicitationChoiceSelect(entry, field, controlId, options);
    }
    case 'bool': {
      if (field.required) {
        const label = document.createElement('label');
        label.className = 'elicitation-check';
        const input = document.createElement('input');
        input.type = 'checkbox';
        input.id = controlId;
        input.onchange = () => {
          entry.values[field.key] = input.checked;
          entry.touched.add(field.key);
          entry.refresh();
        };
        entry.controlSyncers.push(() => {
          input.checked = entry.values[field.key] === true;
        });
        const caption = document.createElement('span');
        caption.textContent = 'Enabled';
        label.append(input, caption);
        return label;
      }
      return buildElicitationChoiceSelect(entry, field, controlId, [
        { value: undefined, title: 'Not set' },
        { value: true, title: 'True' },
        { value: false, title: 'False' }
      ]);
    }
    case 'number': {
      const input = document.createElement('input');
      input.type = 'text';
      input.inputMode = kind.isInteger ? 'numeric' : 'decimal';
      input.id = controlId;
      input.className = 'elicitation-control';
      input.oninput = () => {
        entry.touched.add(field.key);
        const number = parseElicitationNumber(input.value);
        if (number !== null) entry.values[field.key] = number;
        else if (input.value.trim() === '') delete entry.values[field.key];
        // Keep the raw text so the user can keep editing; validation rejects it.
        else entry.values[field.key] = input.value;
        entry.refresh();
      };
      entry.controlSyncers.push(() => {
        const value = entry.values[field.key];
        if (typeof value === 'number' && Number.isFinite(value)) {
          input.value = formatElicitationNumber(value);
        } else if (typeof value === 'string') {
          input.value = value;
        } else {
          input.value = '';
        }
      });
      return input;
    }
    case 'string': {
      const wrap = document.createElement('div');
      const textarea = document.createElement('textarea');
      textarea.id = controlId;
      textarea.className = 'elicitation-control';
      textarea.rows = 2;
      textarea.oninput = () => {
        entry.touched.add(field.key);
        const text = textarea.value;
        if (!field.required && text === '' && !elicitationAccepts(kind, '')) {
          delete entry.values[field.key];
        } else {
          entry.values[field.key] = text;
        }
        entry.refresh();
      };
      entry.controlSyncers.push(() => {
        const value = entry.values[field.key];
        textarea.value = typeof value === 'string' ? value : '';
      });
      wrap.append(textarea);
      const requirement = elicitationStringLengthRequirement(kind);
      if (requirement) {
        const hint = document.createElement('div');
        hint.className = 'elicitation-hint';
        hint.textContent = requirement;
        wrap.append(hint);
      }
      return wrap;
    }
    case 'stringMultiSelect': {
      const group = document.createElement('div');
      group.className = 'elicitation-multi';
      group.setAttribute('role', 'group');
      const syncGroup = () => {
        const selected = new Set(selectedMultiStrings(entry, field.key));
        group.querySelectorAll('.elicitation-multi-option').forEach((button) => {
          const on = selected.has(button.dataset.value);
          button.setAttribute('aria-pressed', on ? 'true' : 'false');
          const box = button.querySelector('.elicitation-multi-box');
          if (box) box.textContent = on ? '\u2611' : '\u2610';
        });
      };
      kind.choices.forEach((choice) => {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'elicitation-multi-option';
        button.dataset.value = choice.value;
        button.setAttribute('aria-pressed', 'false');
        const box = document.createElement('span');
        box.className = 'elicitation-multi-box';
        box.setAttribute('aria-hidden', 'true');
        box.textContent = '\u2610';
        const caption = document.createElement('span');
        caption.textContent = choice.title;
        button.append(box, caption);
        button.onclick = () => {
          toggleElicitationChoice(entry, field, choice.value);
          syncGroup();
          entry.refresh();
        };
        group.append(button);
      });
      entry.controlSyncers.push(syncGroup);
      return group;
    }
    default:
      return document.createElement('div');
  }
}
function buildElicitationField(entry, field) {
  const wrap = document.createElement('div');
  wrap.className = 'elicitation-field';
  const controlId = `elicitation-field-${++elicitationCardSequence}`;
  const title = document.createElement('label');
  title.className = 'elicitation-field-title';
  title.setAttribute('for', controlId);
  title.textContent = field.title;
  if (field.required) {
    const marker = document.createElement('span');
    marker.className = 'elicitation-field-req';
    marker.textContent = ' *';
    title.append(marker);
  }
  wrap.append(title);
  if (field.description) {
    const description = document.createElement('div');
    description.className = 'elicitation-field-desc';
    description.textContent = field.description;
    wrap.append(description);
  }
  wrap.append(buildElicitationControl(entry, field, controlId));
  return wrap;
}
function buildElicitationActions(entry, acceptLabel, includeAccept) {
  const actions = document.createElement('div');
  actions.className = 'elicitation-actions';
  const decline = document.createElement('button');
  decline.type = 'button';
  decline.className = 'elicitation-decline';
  decline.textContent = 'Decline';
  decline.onclick = () => submitElicitation(entry.request.requestId, 'decline');
  actions.append(decline);
  if (includeAccept) {
    const spacer = document.createElement('span');
    spacer.className = 'spacer';
    const accept = document.createElement('button');
    accept.type = 'button';
    accept.className = 'elicitation-submit';
    accept.textContent = acceptLabel;
    accept.onclick = () => submitElicitation(entry.request.requestId, 'accept');
    actions.append(spacer, accept);
    entry.submitButton = accept;
  }
  return actions;
}
function buildElicitationURLControls(entry, card) {
  const request = entry.request;
  const link = safeWebURL(request.url);
  if (link) {
    const urlText = document.createElement('div');
    urlText.className = 'elicitation-url';
    urlText.textContent = link;
    card.append(urlText);
    const open = document.createElement('a');
    open.className = 'elicitation-open';
    open.href = link;
    open.target = '_blank';
    open.rel = 'noopener noreferrer';
    open.textContent = 'Open in browser';
    card.append(open);
    card.append(buildElicitationActions(entry, 'Done', true));
  } else {
    const fallback = document.createElement('div');
    fallback.className = 'elicitation-fallback';
    fallback.textContent = 'Open this link in the Copilot terminal.';
    card.append(fallback);
    if (typeof request.url === 'string' && request.url) {
      const raw = document.createElement('div');
      raw.className = 'elicitation-url';
      raw.textContent = request.url;
      card.append(raw);
    }
    card.append(buildElicitationActions(entry, 'Done', false));
  }
}
function buildTerminalDefaultControls(entry, card) {
  const fallback = document.createElement('div');
  fallback.className = 'elicitation-fallback';
  fallback.textContent =
    'This question is being handled in the terminal. You can safely accept '
    + 'the highlighted default here or use the terminal for another answer.';
  card.append(fallback);
  const actions = document.createElement('div');
  actions.className = 'elicitation-actions';
  const open = document.createElement('button');
  open.type = 'button';
  open.className = 'elicitation-open';
  open.textContent = 'Open terminal';
  open.onclick = () => setViewMode('terminal');
  const spacer = document.createElement('span');
  spacer.className = 'spacer';
  const accept = document.createElement('button');
  accept.type = 'button';
  accept.className = 'elicitation-submit';
  accept.textContent = `Use default: ${entry.terminalDefault.value ? 'Yes' : 'No'}`;
  accept.onclick = () => submitElicitation(entry.request.requestId, 'accept');
  actions.append(open, spacer, accept);
  card.append(actions);
  entry.submitButton = accept;
}
// Untrusted message/field text is only ever inserted with textContent.
function buildElicitationCard(request) {
  const form = parseElicitationForm(request.schema);
  const entry = {
    request,
    form,
    terminalDefault: terminalDefaultBoolean(request),
    syntheticLegacy: isSyntheticDurableElicitation(request),
    isURLMode: request.mode === 'url'
      || (typeof request.url === 'string' && request.url.length > 0),
    values: {},
    touched: new Set(),
    controlSyncers: [],
    card: null,
    submitButton: null,
    refresh: () => {}
  };
  const card = document.createElement('article');
  card.className = 'user-input-card elicitation-card';
  card.dataset.requestId = request.requestId;
  const messageId = `elicitation-message-${++elicitationCardSequence}`;
  card.setAttribute('aria-labelledby', messageId);
  const head = document.createElement('div');
  head.className = 'user-input-head';
  const heading = document.createElement('span');
  heading.textContent = 'Copilot needs your input';
  head.append(heading);
  if (request.agentId) {
    const agent = document.createElement('span');
    agent.className = 'user-input-agent';
    agent.textContent = 'Subagent';
    head.append(agent);
  }
  card.append(head);
  const message = document.createElement('div');
  message.className = 'user-input-question';
  message.id = messageId;
  message.textContent = request.message || '';
  card.append(message);
  if (entry.isURLMode) {
    buildElicitationURLControls(entry, card);
  } else if (entry.terminalDefault) {
    buildTerminalDefaultControls(entry, card);
  } else if (entry.form) {
    const fields = document.createElement('div');
    fields.className = 'elicitation-fields';
    entry.form.fields.forEach((field) => {
      fields.append(buildElicitationField(entry, field));
    });
    card.append(fields);
    card.append(buildElicitationActions(entry, 'Send answer', true));
  } else {
    // Outside the supported flat-schema subset: keep it answerable in the
    // terminal rather than rendering arbitrary/nested schema.
    const fallback = document.createElement('div');
    fallback.className = 'elicitation-fallback';
    fallback.textContent = 'Answer this one in the Copilot terminal.';
    card.append(fallback);
    const open = document.createElement('button');
    open.type = 'button';
    open.className = 'elicitation-open';
    open.textContent = 'Open terminal';
    open.onclick = () => setViewMode('terminal');
    card.append(open);
  }
  const status = document.createElement('div');
  status.className = 'user-input-status';
  status.setAttribute('role', 'status');
  status.setAttribute('aria-live', 'polite');
  card.append(status);
  entry.card = card;
  entry.refresh = () => refreshElicitationControls(entry);
  if (!entry.isURLMode && entry.form) seedElicitationDefaults(entry);
  entry.controlSyncers.forEach((sync) => sync());
  entry.refresh();
  return entry;
}
// Only build a card once per request ID so an in-progress form isn't wiped by
// an unrelated workspace update; a card is removed only when the snapshot drops
// its request.
function syncElicitationCards() {
  const context = operationContext();
  const rawPending = currentElicitations();
  const rawIds = new Set(rawPending.map((request) => request.requestId));
  sdkOperations.pruneSettledTargets({
    sessionId: selected,
    conversationEpoch: context.conversationEpoch,
    kind: 'answer-elicitation',
    visibleTargetIds: rawIds
  });
  const pending = rawPending.filter((request) => !sdkOperations.shouldSuppressTarget(
    operationTargetContext('answer-elicitation', request.requestId)
  ));
  const ids = new Set(pending.map((request) => request.requestId));
  for (const [requestId, entry] of [...elicitationCards]) {
    const target = operationTargetContext('answer-elicitation', requestId);
    if (!ids.has(requestId) && !sdkOperations.shouldPreserveTarget(target)) {
      entry.card.remove();
      elicitationCards.delete(requestId);
      const submitting = submittingElicitations.get(requestId);
      if (submitting) {
        clearTimeout(submitting.timer);
        submittingElicitations.delete(requestId);
      }
      latestElicitationAttempts.delete(requestId);
    }
  }
  pending.forEach((request) => {
    let entry = elicitationCards.get(request.requestId);
    if (!entry) {
      entry = buildElicitationCard(request);
      elicitationCards.set(request.requestId, entry);
      userInput.append(entry.card);
    }
    entry.refresh();
    const record = sdkOperations.recordForTarget(
      operationTargetContext('answer-elicitation', request.requestId)
    );
    if (record) {
      setElicitationStatus(request.requestId, remoteOperationMessage(record));
    } else if (!entry.syntheticLegacy
        && context.support === REMOTE_OPERATION_SUPPORT.UNAVAILABLE) {
      setElicitationStatus(request.requestId, operationUnavailableMessage());
    } else {
      const status = entry.card.querySelector('.user-input-status');
      if (status?.textContent === operationUnavailableMessage()) status.textContent = '';
    }
  });
}
async function submitElicitation(requestId, action) {
  if (!selected || !writable || submittingElicitations.has(requestId)) return;
  const entry = elicitationCards.get(requestId);
  if (!entry) return;
  let content = null;
  if (action === 'accept' && entry.terminalDefault) {
    content = {
      [entry.terminalDefault.key]: entry.terminalDefault.value
    };
  } else if (action === 'accept' && entry.form) {
    content = validatedElicitationContent(entry.form, entry.values, entry.touched);
    if (content === null) return;
    let encoded;
    try {
      encoded = JSON.stringify(content);
    } catch (error) {
      setElicitationStatus(requestId, 'Answer was not sent');
      return;
    }
    if (new TextEncoder().encode(encoded).length > 32768) {
      setElicitationStatus(
        requestId, 'Answer is too large to send \u2014 shorten it and try again.'
      );
      return;
    }
  }
  const payload = { requestId, action };
  if (action === 'accept' && content !== null) payload.content = content;
  const submittedSession = selected;
  const submittedGeneration = selectionGeneration;
  const submittedConversationGeneration = conversationRequestGeneration;
  const data = JSON.stringify(payload);
  const context = operationContext(submittedSession);
  const plan = sdkOperations.prepare({
    sessionId: submittedSession,
    conversationEpoch: context.conversationEpoch,
    support: context.support,
    kind: 'answer-elicitation',
    targetId: requestId,
    payloadContext: data,
    forceLegacy: entry.syntheticLegacy
  });
  if (plan.mode === REMOTE_OPERATION_SUPPORT.UNAVAILABLE) {
    setElicitationStatus(requestId, operationUnavailableMessage());
    entry.refresh();
    return;
  }
  if (plan.mode === 'capacity') {
    setElicitationStatus(requestId, 'Too many Copilot operations are still pending.');
    return;
  }
  if (plan.mode === 'duplicate') {
    setElicitationStatus(requestId, remoteOperationMessage(plan.record));
    entry.refresh();
    return;
  }
  const token = ++elicitationAttemptSequence;
  latestElicitationAttempts.set(requestId, token);
  const timer = plan.mode === REMOTE_OPERATION_SUPPORT.LEGACY
    ? setTimeout(() => {
      const submitting = submittingElicitations.get(requestId);
      if (!submitting || submitting.token !== token) return;
      submittingElicitations.delete(requestId);
      if (selected === submittedSession
          && conversationRequestGeneration === submittedConversationGeneration
          && sessionHasElicitation(submittedSession, requestId)) {
        entry.refresh();
        setElicitationStatus(
          requestId,
          'Still waiting \u2014 check the terminal before trying again.'
        );
      }
    }, 15000)
    : setTimeout(() => {
      const submitting = submittingElicitations.get(requestId);
      if (!submitting || submitting.token !== token
          || submitting.operationId !== plan.record.operationId) return;
      const previousState = plan.record.state;
      const record = sdkOperations.markIndeterminate(
        plan.record.operationId,
        'receipt-timeout'
      );
      if (record) applyOperationTransition({
        record,
        previousState,
        state: 'indeterminate'
      });
    }, RECEIPT_TIMEOUT_MS);
  submittingElicitations.set(requestId, {
    timer,
    token,
    operationId: plan.record?.operationId || null,
    mode: plan.mode
  });
  entry.refresh();
  setElicitationStatus(requestId, 'Sending\u2026');
  const response = await control(remoteOperationControlMessage(
    'answer-elicitation', submittedSession, data, plan
  ));
  if (selected !== submittedSession
      || selectionGeneration !== submittedGeneration
      || conversationRequestGeneration !== submittedConversationGeneration) return;
  if (latestElicitationAttempts.get(requestId) !== token) return;
  if (plan.mode === REMOTE_OPERATION_SUPPORT.LEGACY) {
    if (response?.status === 204) {
      setElicitationStatus(requestId, 'Waiting for Copilot\u2026');
      return;
    }
    if (!response || response.status >= 500
        || (response.status >= 200 && response.status < 300)) {
      setElicitationStatus(
        requestId, 'Delivery outcome unknown \u2014 check the terminal.'
      );
      return;
    }
  } else {
    const result = sdkOperations.resolveHTTP(
      plan.record.operationId, response?.status ?? null
    );
    if (result.outcome === 'stale' || result.outcome === 'settled') return;
    if (result.outcome === 'accepted' || result.outcome === 'indeterminate') {
      if (result.record) {
        setElicitationStatus(requestId, remoteOperationMessage(result.record));
      }
      return;
    }
  }
  clearElicitationSubmission(requestId);
  entry.refresh();
  if (response?.status === 403) {
    writable = false;
    lease.textContent = 'view only';
    refreshElicitationCardStates();
    setElicitationStatus(requestId, 'Control moved to another device');
  } else if (response?.status === 409) {
    setElicitationStatus(requestId, 'Another answer is still processing \u2014 try again.');
  } else if (response?.status === 422) {
    setElicitationStatus(requestId, 'Answer was not accepted');
  } else {
    setElicitationStatus(requestId, 'Answer was not sent');
  }
}
const LINK_PATTERN = /\[[^\]\r\n]+\]\((https?:\/\/[^\s)]+)\)|https?:\/\/[^\s<>()\[\]]+/gi;
function appendLinkedText(parent, text) {
  let cursor = 0;
  for (const match of text.matchAll(LINK_PATTERN)) {
    if (match.index > cursor) {
      parent.append(document.createTextNode(text.slice(cursor, match.index)));
    }
    const raw = match[0];
    const href = match[1] || raw;
    let url = null;
    try { url = new URL(href); } catch (_) {}
    if (url && (url.protocol === 'https:' || url.protocol === 'http:')) {
      const anchor = document.createElement('a');
      anchor.className = 'terminal-link';
      anchor.href = url.href;
      anchor.target = '_blank';
      anchor.rel = 'noopener noreferrer';
      anchor.textContent = raw;
      anchor.onclick = (event) => event.stopPropagation();
      parent.append(anchor);
    } else {
      parent.append(document.createTextNode(raw));
    }
    cursor = match.index + raw.length;
  }
  if (cursor < text.length) {
    parent.append(document.createTextNode(text.slice(cursor)));
  }
}

// Line height prefers an actually-rendered `.terminal-line` (the real,
// current font metrics); falls back to the hidden probe (e.g. before any
// line has ever rendered), then a nonzero hardcoded default so a
// measurement glitch can never divide-by-zero downstream.
function measuredLineHeight() {
  const rendered = terminalLines.querySelector('.terminal-line')
    ?.getBoundingClientRect().height;
  if (rendered && rendered > 0) return rendered;
  const probe = terminalCellProbe?.getBoundingClientRect().height;
  if (probe && probe > 0) return probe;
  return 16;
}
// Cell width has no equivalent "real rendered line" source (a line's
// width varies with its content), so it's always measured from the
// dedicated fixed-length probe.
const TERMINAL_CELL_PROBE_LENGTH = 32;
function measuredCellWidth() {
  const rect = terminalCellProbe?.getBoundingClientRect();
  if (rect && rect.width > 0) return rect.width / TERMINAL_CELL_PROBE_LENGTH;
  return 8;
}

function terminalImageBackoffActive(key) {
  const entry = terminalImageBackoff.get(key);
  if (!entry || entry.nextAttemptAt <= Date.now()) return false;
  scheduleTerminalImageRetry(key, entry.nextAttemptAt, terminalImageGeneration);
  return true;
}

function scheduleTerminalImageRetry(key, nextAttemptAt, generation) {
  clearTimeout(terminalImageRetryTimers.get(key));
  const delay = Math.max(0, nextAttemptAt - Date.now());
  const timer = setTimeout(() => {
    terminalImageRetryTimers.delete(key);
    if (terminalImageGeneration !== generation || !selected) return;
    const stillCurrent = imagePlacements.some((placement) => (
      terminalImageCacheKey(
        selected, placement.imageId, placement.contentVersion
      ) === key
    ));
    if (stillCurrent) scheduleTerminalImageReconcile();
  }, delay);
  terminalImageRetryTimers.set(key, timer);
}

function setTerminalImageBackoff(key, failureCount, generation) {
  const nextAttemptAt = Date.now() + terminalImageBackoffDelayMs(failureCount);
  terminalImageBackoff.delete(key);
  terminalImageBackoff.set(key, { failureCount, nextAttemptAt });
  while (terminalImageBackoff.size > TERMINAL_IMAGE_MAX_BACKOFF_ENTRIES) {
    const oldest = terminalImageBackoff.keys().next().value;
    terminalImageBackoff.delete(oldest);
    clearTimeout(terminalImageRetryTimers.get(oldest));
    terminalImageRetryTimers.delete(oldest);
  }
  scheduleTerminalImageRetry(key, nextAttemptAt, generation);
}

function terminalImagePositiveCacheBytes() {
  let total = 0;
  terminalImagePositiveCache.forEach((entry) => { total += entry.bytes; });
  return total;
}

// Only ever revokes/evicts entries with `activeNodeCount === 0` — an
// entry currently referenced by a visible `<img>` node is never a
// candidate, no matter how stale, so eviction can never pull a blob URL
// out from under something on screen.
function makeRoomInTerminalImagePositiveCache(extraBytes) {
  const withinBudget = () => (
    terminalImagePositiveCache.size < TERMINAL_IMAGE_MAX_POSITIVE_CACHE_ENTRIES
    && terminalImagePositiveCacheBytes() + extraBytes <= TERMINAL_IMAGE_MAX_POSITIVE_CACHE_BYTES
  );
  if (withinBudget()) return true;
  let evictedAny = false;
  const evictable = [...terminalImagePositiveCache.entries()]
    .filter(([key, entry]) => entry.activeNodeCount === 0
      && (terminalImagePendingConsumers.get(key) || 0) === 0)
    .sort((a, b) => a[1].lastUsed - b[1].lastUsed);
  for (const [key, entry] of evictable) {
    URL.revokeObjectURL(entry.url);
    terminalImagePositiveCache.delete(key);
    evictedAny = true;
    if (withinBudget()) {
      if (evictedAny) retryCapacityBlockedTerminalImages();
      return true;
    }
  }
  if (evictedAny) retryCapacityBlockedTerminalImages();
  return withinBudget();
}

function addTerminalImageNegativeCacheEntry(key) {
  terminalImageNegativeCache.delete(key);
  terminalImageNegativeCache.add(key);
  while (terminalImageNegativeCache.size > TERMINAL_IMAGE_MAX_NEGATIVE_CACHE_ENTRIES) {
    const oldest = terminalImageNegativeCache.values().next().value;
    terminalImageNegativeCache.delete(oldest);
  }
}

function addBoundedTerminalImageKey(set, key) {
  set.delete(key);
  set.add(key);
  while (set.size > TERMINAL_IMAGE_MAX_NEGATIVE_CACHE_ENTRIES) {
    set.delete(set.values().next().value);
  }
}

function blockTerminalImageOnCapacity(key) {
  addBoundedTerminalImageKey(terminalImageCapacityBlocked, key);
}

function retryCapacityBlockedTerminalImages() {
  if (!terminalImageCapacityBlocked.size) return;
  terminalImageCapacityBlocked.clear();
  scheduleTerminalImageReconcile();
}

// Bounded loader: at most `TERMINAL_IMAGE_MAX_IN_FLIGHT` concurrent
// requests, a 15s abort timeout, and every terminal outcome (positive,
// permanent 404, or transient cooldown) recorded so repeated
// reconciliation passes never refetch something already known-bad this
// soon. Resolves to the cache entry, or `null` if the image isn't
// currently available (never rejects).
function loadTerminalImage(sessionId, placement) {
  const key = terminalImageCacheKey(sessionId, placement.imageId, placement.contentVersion);
  const cached = terminalImagePositiveCache.get(key);
  if (cached) {
    cached.lastUsed = Date.now();
    return Promise.resolve(cached);
  }
  if (terminalImageNegativeCache.has(key)) return Promise.resolve(null);
  if (terminalImageDecodeFailures.has(key)) return Promise.resolve(null);
  if (terminalImageCapacityBlocked.has(key)) return Promise.resolve(null);
  if (terminalImageBackoffActive(key)) return Promise.resolve(null);
  const existing = terminalImageInFlight.get(key);
  if (existing) return existing.promise;
  if (terminalImageInFlight.size >= TERMINAL_IMAGE_MAX_IN_FLIGHT) {
    return Promise.resolve(null);
  }
  if (!makeRoomInTerminalImagePositiveCache(0)) {
    // No cache room and nothing inactive to evict for it: skip the fetch
    // entirely until a node release makes a real entry evictable.
    blockTerminalImageOnCapacity(key);
    return Promise.resolve(null);
  }
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), TERMINAL_IMAGE_FETCH_TIMEOUT_MS);
  const generation = terminalImageGeneration;
  const promise = fetchTerminalImageBytes(
    base, sessionId, placement.imageId, placement.contentVersion, controller.signal
  ).then((result) => {
    if (terminalImageGeneration !== generation) return null;
    if (!makeRoomInTerminalImagePositiveCache(result.bytes.byteLength)) {
      blockTerminalImageOnCapacity(key);
      return null;
    }
    const url = URL.createObjectURL(new Blob([result.bytes], { type: 'image/png' }));
    const entry = {
      url,
      bytes: result.bytes.byteLength,
      width: result.width,
      height: result.height,
      activeNodeCount: 0,
      lastUsed: Date.now()
    };
    terminalImagePositiveCache.set(key, entry);
    terminalImageBackoff.delete(key);
    clearTimeout(terminalImageRetryTimers.get(key));
    terminalImageRetryTimers.delete(key);
    return entry;
  }).catch((error) => {
    if (terminalImageGeneration !== generation) return null;
    if (error?.code === 'not-found') {
      addTerminalImageNegativeCacheEntry(key);
    } else {
      const failureCount = (terminalImageBackoff.get(key)?.failureCount || 0) + 1;
      setTerminalImageBackoff(key, failureCount, generation);
    }
    return null;
  }).finally(() => {
    clearTimeout(timeoutId);
    if (terminalImageInFlight.get(key)?.promise === promise) {
      terminalImageInFlight.delete(key);
    }
    if (terminalImageGeneration === generation) {
      scheduleTerminalImageReconcile();
    }
  });
  terminalImageInFlight.set(key, { controller, promise });
  return promise;
}

// Invalidates a shared cache entry after a real browser decode failure
// (structurally-valid-but-undecodable PNG bytes): revokes its one object
// URL exactly once and clears it from every node currently displaying it,
// so nothing visible is left pointing at a revoked URL.
function invalidateTerminalImageCacheEntry(key) {
  const entry = terminalImagePositiveCache.get(key);
  if (entry) {
    URL.revokeObjectURL(entry.url);
    terminalImagePositiveCache.delete(key);
  }
  addBoundedTerminalImageKey(terminalImageDecodeFailures, key);
  terminalImageNodes.forEach((node) => {
    if (node.cacheKey !== key) return;
    terminalActiveDecodedPixels = Math.max(0, terminalActiveDecodedPixels - node.pixels);
    node.cacheKey = null;
    node.pixels = 0;
    node.el.removeAttribute('src');
  });
  // Conversation cards hold the *same* shared entry, so they must hand back
  // their pixels too — otherwise a decode failure leaves the budget charged
  // for images nothing displays until the owning card happens to change.
  clearConversationImageCacheKey(key);
  retryCapacityBlockedTerminalImages();
  // A different visible node may have been waiting only on the aggregate
  // decoded-pixel cap (not compressed-cache capacity). Invalidating this
  // image frees those pixels, so always reconcile even when the
  // capacity-blocked set is empty.
  scheduleTerminalImageReconcile();
}

function mountTerminalImageSource(node, cacheEntry, key) {
  node.cacheKey = key;
  node.pixels = cacheEntry.width * cacheEntry.height;
  cacheEntry.activeNodeCount += 1;
  cacheEntry.lastUsed = Date.now();
  terminalActiveDecodedPixels += node.pixels;
  node.el.onerror = () => invalidateTerminalImageCacheEntry(key);
  node.el.src = cacheEntry.url;
}

// Kicks off (or reuses) the bounded load for one placement. Safe to call
// repeatedly (every reconciliation pass) for a node that isn't mounted
// yet — `loadTerminalImage` itself is cheap once cached/negative/backed
// off. The async continuation re-checks *current* state before touching
// anything: a full session/generation change drops it outright, but an
// unrelated text-only render in between must not — it reconciles against
// whatever node/placement is current for this key at completion time.
function attachTerminalImageSource(node, placement) {
  if (node.cacheKey || node.loadingKey || !selected) return;
  const sessionId = selected;
  const generation = terminalImageGeneration;
  const key = terminalImageCacheKey(
    sessionId, placement.imageId, placement.contentVersion
  );
  node.loadingKey = key;
  terminalImagePendingConsumers.set(
    key, (terminalImagePendingConsumers.get(key) || 0) + 1
  );
  loadTerminalImage(sessionId, placement).then((cacheEntry) => {
    if (terminalImageGeneration !== generation) return;
    const current = terminalImageNodes.get(placement.key);
    if (!current || current.el !== node.el || current.cacheKey
        || current.loadingKey !== key) return;
    if (!cacheEntry) return;
    if (terminalImagePositiveCache.get(key) !== cacheEntry) return;
    const pixels = cacheEntry.width * cacheEntry.height;
    if (terminalActiveDecodedPixels + pixels > TERMINAL_IMAGE_MAX_DECODED_PIXELS) return;
    mountTerminalImageSource(current, cacheEntry, key);
  }).finally(() => {
    const remaining = Math.max(
      0, (terminalImagePendingConsumers.get(key) || 1) - 1
    );
    if (remaining) terminalImagePendingConsumers.set(key, remaining);
    else terminalImagePendingConsumers.delete(key);
    if (node.loadingKey === key) node.loadingKey = null;
  });
}

function createTerminalImageNode(placement) {
  const el = document.createElement('img');
  el.className = 'terminal-image';
  el.alt = '';
  el.draggable = false;
  el.setAttribute('aria-hidden', 'true');
  terminalImageOverlay.append(el);
  const node = { el, cacheKey: null, loadingKey: null, pixels: 0 };
  attachTerminalImageSource(node, placement);
  return node;
}

function releaseTerminalImageNode(node) {
  node.el.remove();
  if (node.cacheKey) {
    const cacheEntry = terminalImagePositiveCache.get(node.cacheKey);
    if (cacheEntry) {
      cacheEntry.activeNodeCount = Math.max(0, cacheEntry.activeNodeCount - 1);
    }
    terminalActiveDecodedPixels = Math.max(0, terminalActiveDecodedPixels - node.pixels);
  }
  retryCapacityBlockedTerminalImages();
}

// --- Conversation-mode inline images -------------------------------------
// Reuses the exact same bounded positive/negative/in-flight cache and byte
// fetch as terminal images (deduping by sessionId:imageId:version), but with
// its own node lifecycle because the transcript DOM is rebuilt each render.

// Picks the JS-safe exact version string (UInt64 can exceed 2^53, so the
// wire carries a decimal `contentVersionText`), mirroring terminal
// placements. Returns null for anything unsafe so one bad ref can't break
// the turn.
function normalizeConversationImageRef(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const { imageId, contentVersion, contentVersionText } = raw;
  if (!Number.isSafeInteger(imageId) || imageId < 1 || imageId > 0xFFFFFF) return null;
  const exactVersion = typeof contentVersionText === 'string'
    && /^[1-9][0-9]{0,19}$/.test(contentVersionText)
    ? contentVersionText
    : (Number.isSafeInteger(contentVersion) && contentVersion > 0
      ? String(contentVersion) : null);
  if (!exactVersion) return null;
  return { imageId, contentVersion: exactVersion };
}

// Mounts a decoded image into a conversation node, enforcing the same
// shared decoded-pixel budget terminal mounts respect so conversation
// images can never starve the terminal overlay. Returns whether it mounted;
// a `false` (over budget) leaves the node blank to be retried on a later
// render once budget frees.
function mountConversationImage(node, cacheEntry, key) {
  const pixels = cacheEntry.width * cacheEntry.height;
  if (terminalActiveDecodedPixels + pixels > TERMINAL_IMAGE_MAX_DECODED_PIXELS) {
    return false;
  }
  node.cacheKey = key;
  node.pixels = pixels;
  cacheEntry.activeNodeCount += 1;
  cacheEntry.lastUsed = Date.now();
  terminalActiveDecodedPixels += pixels;
  node.el.onerror = () => invalidateTerminalImageCacheEntry(key);
  node.el.src = cacheEntry.url;
  // Lets the fullscreen viewer find (and pin) this decoded entry on click.
  node.el.dataset.cacheKey = key;
  return true;
}

function releaseConversationImageNode(node) {
  node.released = true;
  delete node.el.dataset.cacheKey;
  if (node.cacheKey) {
    const cacheEntry = terminalImagePositiveCache.get(node.cacheKey);
    if (cacheEntry) {
      cacheEntry.activeNodeCount = Math.max(0, cacheEntry.activeNodeCount - 1);
    }
    terminalActiveDecodedPixels = Math.max(0, terminalActiveDecodedPixels - node.pixels);
    node.cacheKey = null;
    node.pixels = 0;
  }
  retryCapacityBlockedTerminalImages();
}

// Builds one inline conversation image node. A cache hit mounts
// synchronously (so an unchanged image keeps a non-zero reference across the
// render swap); otherwise a bounded loader mounts it on completion. A
// transient/capacity miss (null result or a full decoded-pixel budget) is
// retried a few times with backoff so a temporary failure doesn't leave the
// image permanently blank until the next unrelated transcript revision —
// every attempt re-checks the node isn't released and the session/generation
// hasn't moved on.
function createConversationImageNode(sessionId, ref) {
  const figure = document.createElement('figure');
  figure.className = 'conversation-image';
  const el = document.createElement('img');
  el.className = 'conversation-image-img';
  el.alt = 'Terminal image';
  el.loading = 'lazy';
  el.draggable = false;
  figure.append(el);
  const node = { el, figure, cacheKey: null, pixels: 0, released: false };
  const key = terminalImageCacheKey(sessionId, ref.imageId, ref.contentVersion);
  const cached = terminalImagePositiveCache.get(key);
  if (cached) {
    cached.lastUsed = Date.now();
    if (mountConversationImage(node, cached, key)) return node;
  }
  const generation = terminalImageGeneration;
  const attempt = (remaining) => {
    if (node.released || node.cacheKey) return;
    if (terminalImageGeneration !== generation) return;
    loadTerminalImage(sessionId, ref).then((cacheEntry) => {
      if (node.released || node.cacheKey) return;
      if (terminalImageGeneration !== generation) return;
      if (cacheEntry
          && terminalImagePositiveCache.get(key) === cacheEntry
          && mountConversationImage(node, cacheEntry, key)) {
        return;
      }
      if (remaining > 0) {
        setTimeout(() => attempt(remaining - 1), CONVERSATION_IMAGE_RETRY_MS);
      }
    });
  };
  attempt(CONVERSATION_IMAGE_MAX_RETRIES);
  return node;
}

// --- Fullscreen image viewer (lightbox) --------------------------------
// Clicking an inline conversation image opens it fullscreen with scroll/
// pinch zoom and drag pan. While open, the decoded cache entry is pinned
// (activeNodeCount bumped) so eviction can't revoke its blob URL underneath.
const imageLightbox = document.querySelector('#image-lightbox');
const imageLightboxImg = imageLightbox
  ? imageLightbox.querySelector('.image-lightbox-img') : null;
const imageLightboxClose = imageLightbox
  ? imageLightbox.querySelector('.image-lightbox-close') : null;
const LIGHTBOX_MIN_SCALE = 1;
const LIGHTBOX_MAX_SCALE = 8;
const lightboxState = {
  pinnedKey: null, scale: 1, tx: 0, ty: 0, moved: false,
  pointers: new Map(), pinch: null, pan: null, lastFocus: null,
};

function pinLightboxEntry(key) {
  if (!key) return;
  const entry = terminalImagePositiveCache.get(key);
  if (!entry) return;
  entry.activeNodeCount += 1;
  entry.lastUsed = Date.now();
  lightboxState.pinnedKey = key;
}

function unpinLightboxEntry() {
  const key = lightboxState.pinnedKey;
  lightboxState.pinnedKey = null;
  if (!key) return;
  const entry = terminalImagePositiveCache.get(key);
  if (entry) entry.activeNodeCount = Math.max(0, entry.activeNodeCount - 1);
  retryCapacityBlockedTerminalImages();
}

function applyLightboxTransform() {
  if (!imageLightboxImg) return;
  const zoomed = lightboxState.scale > 1.001;
  imageLightbox.classList.toggle('zoomed', zoomed);
  if (!zoomed) { lightboxState.tx = 0; lightboxState.ty = 0; }
  imageLightboxImg.style.transform =
    `translate(${lightboxState.tx}px, ${lightboxState.ty}px) scale(${lightboxState.scale})`;
}

function clampLightboxScale(s) {
  return Math.min(LIGHTBOX_MAX_SCALE, Math.max(LIGHTBOX_MIN_SCALE, s));
}

// Cursor/point relative to the image's untransformed top-left.
function lightboxLocalPoint(clientX, clientY) {
  const r = imageLightboxImg.getBoundingClientRect();
  return { x: clientX - r.left + lightboxState.tx,
           y: clientY - r.top + lightboxState.ty };
}

// Zoom to nextScale while keeping content point under (qx,qy) fixed.
function zoomLightboxAt(nextScale, qx, qy) {
  const s0 = lightboxState.scale;
  const s1 = clampLightboxScale(nextScale);
  if (s1 === s0) return;
  lightboxState.tx = qx - (s1 / s0) * (qx - lightboxState.tx);
  lightboxState.ty = qy - (s1 / s0) * (qy - lightboxState.ty);
  lightboxState.scale = s1;
  applyLightboxTransform();
}

function openImageLightbox(imgEl) {
  if (!imageLightbox || !imgEl) return;
  const src = imgEl.currentSrc || imgEl.src;
  if (!src) return;
  lightboxState.scale = 1; lightboxState.tx = 0; lightboxState.ty = 0;
  lightboxState.moved = false; lightboxState.pinch = null; lightboxState.pan = null;
  lightboxState.pointers.clear();
  pinLightboxEntry(imgEl.dataset ? imgEl.dataset.cacheKey : null);
  imageLightboxImg.src = src;
  imageLightbox.classList.add('open');
  imageLightbox.classList.remove('zoomed', 'panning');
  imageLightbox.setAttribute('aria-hidden', 'false');
  lightboxState.lastFocus = document.activeElement;
  applyLightboxTransform();
  if (imageLightboxClose) imageLightboxClose.focus();
}

function closeImageLightbox() {
  if (!imageLightbox || !imageLightbox.classList.contains('open')) return;
  imageLightbox.classList.remove('open', 'zoomed', 'panning');
  imageLightbox.setAttribute('aria-hidden', 'true');
  if (imageLightboxImg) imageLightboxImg.removeAttribute('src');
  lightboxState.pointers.clear();
  lightboxState.pinch = null; lightboxState.pan = null;
  unpinLightboxEntry();
  const prev = lightboxState.lastFocus;
  lightboxState.lastFocus = null;
  if (prev && typeof prev.focus === 'function') prev.focus();
}

function toggleLightboxZoom(evt) {
  if (lightboxState.moved) return;
  if (lightboxState.scale > 1.001) {
    lightboxState.scale = 1; lightboxState.tx = 0; lightboxState.ty = 0;
    applyLightboxTransform();
  } else {
    const q = lightboxLocalPoint(evt.clientX, evt.clientY);
    zoomLightboxAt(2.5, q.x, q.y);
  }
}

function lightboxPointerMid() {
  let sx = 0, sy = 0;
  lightboxState.pointers.forEach((p) => { sx += p.x; sy += p.y; });
  const n = lightboxState.pointers.size || 1;
  return { x: sx / n, y: sy / n };
}

function lightboxPointerDist() {
  const pts = [...lightboxState.pointers.values()];
  if (pts.length < 2) return 0;
  return Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
}

if (imageLightbox && imageLightboxImg) {
  // Open from any inline conversation image click.
  transcript.addEventListener('click', (event) => {
    const target = event.target;
    if (target && target.classList
        && target.classList.contains('conversation-image-img')) {
      event.preventDefault();
      openImageLightbox(target);
    }
  });

  if (imageLightboxClose) {
    imageLightboxClose.addEventListener('click', closeImageLightbox);
  }
  // Click on the dark backdrop (but not the image/close) dismisses.
  imageLightbox.addEventListener('click', (event) => {
    if (event.target === imageLightbox) closeImageLightbox();
  });
  // Tap/click the image toggles fit <-> zoomed (unless it was a drag).
  imageLightboxImg.addEventListener('click', toggleLightboxZoom);

  imageLightbox.addEventListener('wheel', (event) => {
    event.preventDefault();
    const q = lightboxLocalPoint(event.clientX, event.clientY);
    const factor = event.deltaY < 0 ? 1.15 : 1 / 1.15;
    zoomLightboxAt(lightboxState.scale * factor, q.x, q.y);
  }, { passive: false });

  imageLightboxImg.addEventListener('pointerdown', (event) => {
    imageLightboxImg.setPointerCapture(event.pointerId);
    lightboxState.pointers.set(event.pointerId,
      { x: event.clientX, y: event.clientY });
    lightboxState.moved = false;
    if (lightboxState.pointers.size === 2) {
      lightboxState.pan = null;
      lightboxState.pinch = { dist: lightboxPointerDist(), scale: lightboxState.scale };
    } else if (lightboxState.pointers.size === 1) {
      lightboxState.pan = { tx: lightboxState.tx, ty: lightboxState.ty,
        x: event.clientX, y: event.clientY };
    }
  });

  imageLightboxImg.addEventListener('pointermove', (event) => {
    const p = lightboxState.pointers.get(event.pointerId);
    if (!p) return;
    p.x = event.clientX; p.y = event.clientY;
    if (lightboxState.pointers.size >= 2 && lightboxState.pinch) {
      const dist = lightboxPointerDist();
      if (lightboxState.pinch.dist > 0 && dist > 0) {
        const mid = lightboxPointerMid();
        const q = lightboxLocalPoint(mid.x, mid.y);
        zoomLightboxAt(lightboxState.pinch.scale * (dist / lightboxState.pinch.dist),
          q.x, q.y);
      }
      lightboxState.moved = true;
    } else if (lightboxState.pan && lightboxState.scale > 1.001) {
      const dx = event.clientX - lightboxState.pan.x;
      const dy = event.clientY - lightboxState.pan.y;
      if (Math.abs(dx) > 3 || Math.abs(dy) > 3) {
        lightboxState.moved = true;
        imageLightbox.classList.add('panning');
      }
      lightboxState.tx = lightboxState.pan.tx + dx;
      lightboxState.ty = lightboxState.pan.ty + dy;
      applyLightboxTransform();
    }
  });

  const endPointer = (event) => {
    lightboxState.pointers.delete(event.pointerId);
    if (lightboxState.pointers.size < 2) lightboxState.pinch = null;
    if (lightboxState.pointers.size === 0) {
      lightboxState.pan = null;
      imageLightbox.classList.remove('panning');
    }
  };
  imageLightboxImg.addEventListener('pointerup', endPointer);
  imageLightboxImg.addEventListener('pointercancel', endPointer);

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && imageLightbox.classList.contains('open')) {
      event.preventDefault();
      closeImageLightbox();
    }
  });
}

function terminalImageViewportRange() {
  const lineHeight = measuredLineHeight();
  const start = historyStartLine + Math.floor(terminal.scrollTop / lineHeight);
  const end = start + Math.ceil(terminal.clientHeight / lineHeight) + 1;
  return { start, end };
}

function visibleTerminalImagePlacements() {
  const { start, end } = terminalImageViewportRange();
  const cellWidth = measuredCellWidth();
  const firstColumn = Math.max(0, Math.floor(terminal.scrollLeft / cellWidth));
  const lastColumn = firstColumn + Math.ceil(terminal.clientWidth / cellWidth) + 1;
  return imagePlacements
    .filter((placement) => placement.absoluteLine < end
      && placement.absoluteLine + placement.rows > start
      && placement.column < lastColumn
      && placement.column + placement.columns > firstColumn)
    .slice(0, TERMINAL_IMAGE_MAX_RENDERED_NODES);
}

// Renders/reconciles at most `TERMINAL_IMAGE_MAX_RENDERED_NODES` actual
// DOM nodes based on the current viewport: nodes for placements that
// fell out of view are removed, nodes for still-visible placements are
// repositioned in place (never recreated) by their stable key, and newly
// visible placements get a fresh node.
function reconcileTerminalImageOverlay() {
  const visible = visibleTerminalImagePlacements();
  const nextKeys = new Set(visible.map((placement) => placement.key));
  [...terminalImageNodes.entries()].forEach(([key, node]) => {
    if (!nextKeys.has(key)) {
      releaseTerminalImageNode(node);
      terminalImageNodes.delete(key);
    }
  });
  const cellWidth = measuredCellWidth();
  const lineHeight = measuredLineHeight();
  visible.forEach((placement) => {
    let node = terminalImageNodes.get(placement.key);
    if (!node) {
      node = createTerminalImageNode(placement);
      terminalImageNodes.set(placement.key, node);
    } else {
      attachTerminalImageSource(node, placement);
    }
    node.el.style.top = `${(placement.absoluteLine - historyStartLine) * lineHeight}px`;
    node.el.style.left = `${placement.column * cellWidth}px`;
    node.el.style.width = `${placement.columns * cellWidth}px`;
    node.el.style.height = `${placement.rows * lineHeight}px`;
  });
}

function scheduleTerminalImageReconcile() {
  if (terminalImageReconcileScheduled) return;
  terminalImageReconcileScheduled = true;
  requestAnimationFrame(() => {
    terminalImageReconcileScheduled = false;
    reconcileTerminalImageOverlay();
  });
}

// Clears placement state and every currently-mounted overlay node, but
// leaves the positive/negative/backoff caches alone — a session switch
// may switch right back, and cached bytes/outcomes for a still-live
// session remain valid.
function clearTerminalImageDisplayState() {
  [...terminalImageNodes.values()].forEach(releaseTerminalImageNode);
  terminalImageNodes.clear();
  clearTranscriptDOM();
  imagePlacements = [];
  terminalActiveDecodedPixels = 0;
  terminalImageOverlay.replaceChildren();
}

// Session change / terminal refresh: bump the generation so any
// completion still in flight for the *previous* session can never
// repopulate cleared state, then abort every in-flight request — none of
// them can possibly belong to the session we're switching to, since it
// hasn't requested anything yet.
function resetTerminalImagesForSessionChange() {
  closeImageLightbox();
  terminalImageGeneration += 1;
  terminalImageInFlight.forEach((request) => request.controller.abort());
  terminalImageInFlight.clear();
  terminalImagePendingConsumers.clear();
  clearTerminalImageDisplayState();
}

// Full auth reset / sign-out: additionally revoke every retained object
// URL and wipe every cache, so nothing survives into whatever session
// reconnects next.
function resetTerminalImagesForSignOut() {
  resetTerminalImagesForSessionChange();
  terminalImagePositiveCache.forEach((entry) => URL.revokeObjectURL(entry.url));
  terminalImagePositiveCache.clear();
  terminalImageNegativeCache.clear();
  terminalImageDecodeFailures.clear();
  terminalImageCapacityBlocked.clear();
  terminalImageBackoff.clear();
  terminalImageRetryTimers.forEach(clearTimeout);
  terminalImageRetryTimers.clear();
}

function renderLines(screen) {
  const wasAtBottom =
    terminal.scrollHeight - terminal.scrollTop - terminal.clientHeight < 12;
  const previousTop = historyStartLine + Math.floor(
    terminal.scrollTop / measuredLineHeight()
  );

  if (screen.scrollMode === 'terminal' || screen.reset || !lastScreen
      || lastScreen.scrollMode !== screen.scrollMode) {
    historyStartLine = screen.firstLine;
    historyLines = [...screen.lines];
  } else {
    const trim = Math.max(0, screen.historyStartLine - historyStartLine);
    if (trim) {
      historyLines.splice(0, trim);
      historyStartLine += trim;
    }
    const offset = screen.firstLine - historyStartLine;
    if (offset < 0 || offset > historyLines.length) {
      historyStartLine = screen.firstLine;
      historyLines = [...screen.lines];
    } else {
      historyLines.splice(offset, screen.lines.length, ...screen.lines);
    }
  }
  while (historyLines.length
      && historyStartLine + historyLines.length > screen.liveTopLine + screen.rows) {
    historyLines.pop();
  }

  // Authoritative on any modern host (a present `images` array, `[]`
  // included) fully replaces placement state every screen event, live or
  // incremental history alike; only an old host that omits the field
  // entirely (`images == null`) leaves prior placement state untouched.
  if (Array.isArray(screen.images)) {
    imagePlacements = buildTerminalImagePlacements(screen);
  }
  // Whichever branch above ran, bound placement state to the line range
  // this client actually still retains — including the reset branch a
  // few lines up, where `historyStartLine`/`historyLines` were just
  // replaced wholesale.
  const retainedStart = historyStartLine;
  const retainedEnd = historyStartLine + historyLines.length;
  imagePlacements = imagePlacements.filter((placement) => (
    placement.absoluteLine < retainedEnd
    && placement.absoluteLine + placement.rows > retainedStart
  ));

  const fragment = document.createDocumentFragment();
  historyLines.forEach((line) => {
    const row = document.createElement('div');
    row.className = 'terminal-line';
    appendLinkedText(row, line);
    fragment.append(row);
  });
  terminalLines.replaceChildren(fragment);
  terminal.classList.toggle('terminal-scroll', screen.scrollMode === 'terminal');

  const lineHeight = measuredLineHeight();
  const saved = selected && sessionScroll.get(selected);
  if (screen.scrollMode === 'terminal' || wasAtBottom || saved?.atBottom) {
    terminal.scrollTop = terminal.scrollHeight;
  } else {
    const topLine = saved?.topLine ?? previousTop;
    terminal.scrollTop = Math.max(0, topLine - historyStartLine) * lineHeight;
  }
  lastScreen = screen;
  scheduleTerminalImageReconcile();
}

const sessionScroll = new Map();
terminal.addEventListener('scroll', () => {
  scheduleTerminalImageReconcile();
  if (!selected || lastScreen?.scrollMode !== 'history') return;
  const lineHeight = measuredLineHeight();
  const atBottom =
    terminal.scrollHeight - terminal.scrollTop - terminal.clientHeight < 12;
  sessionScroll.set(selected, {
    atBottom,
    topLine: historyStartLine + Math.floor(terminal.scrollTop / lineHeight)
  });
});
window.addEventListener('resize', () => scheduleTerminalImageReconcile());

function requestTerminalScroll(delta) {
  if (!selected || !writable || lastScreen?.scrollMode !== 'terminal') return;
  pendingScroll += delta;
  clearTimeout(scrollTimer);
  scrollTimer = setTimeout(() => {
    const value = Math.sign(pendingScroll)
      * Math.min(Math.abs(pendingScroll), 8);
    pendingScroll = 0;
    if (value) control({
      type: 'scroll',
      sessionId: selected,
      delta: value
    }).then((response) => {
      if (response?.status === 403) {
        writable = false;
        lease.textContent = 'view only';
        updatePromptState();
      }
    });
  }, 16);
}

terminal.addEventListener('wheel', (event) => {
  if (lastScreen?.scrollMode !== 'terminal') return;
  event.preventDefault();
  // Wire convention: positive means up/toward older content.
  requestTerminalScroll(event.deltaY > 0 ? -3 : 3);
}, {passive:false});

terminal.addEventListener('touchstart', (event) => {
  if (lastScreen?.scrollMode === 'terminal') {
    touchY = event.touches[0]?.clientY ?? null;
  }
}, {passive:true});
terminal.addEventListener('touchmove', (event) => {
  if (lastScreen?.scrollMode !== 'terminal' || touchY == null) return;
  event.preventDefault();
  const next = event.touches[0]?.clientY ?? touchY;
  const delta = next - touchY;
  if (Math.abs(delta) >= 18) {
    requestTerminalScroll(delta > 0 ? 2 : -2);
    touchY = next;
  }
}, {passive:false});
terminal.addEventListener('touchend', () => { touchY = null; });

function onMessage(event) {
  const message = JSON.parse(event.data);
  if (message.type === 'workspace') renderWorkspace(message.data);
  if (message.type === 'screen' && message.data.sessionId === selected) {
    if (viewMode === 'terminal') renderLines(message.data);
  }
  if (message.type === 'dismissed-notifications') {
    clearDismissedNotifications(message.data.ids || []);
  }
  if (message.type === 'transcript' && message.data.sessionId === selected) {
    if (awaitingPromptStart) {
      awaitingPromptStart = false;
      clearTimeout(promptFallbackTimer);
      promptFallbackTimer = null;
      updatePromptState();
    }
    fetchTranscript(message.data);
  }
}

async function clearDismissedNotifications(ids) {
  if (!('serviceWorker' in navigator) || !ids.length) return;
  const registration = await navigator.serviceWorker.ready;
  const dismissed = new Set(ids);
  const notifications = await registration.getNotifications();
  notifications.forEach((notification) => {
    if (dismissed.has(notification.tag)) notification.close();
  });
}
terminal.addEventListener('keydown', (event) => {
  if (!writable) return;
  const specialKey = {
    Enter:'enter', Backspace:'backspace', Tab:'tab', Escape:'escape',
    ArrowUp:'up', ArrowDown:'down', ArrowRight:'right', ArrowLeft:'left'
  };
  const key = specialKey[event.key];
  if (key) {
    event.preventDefault();
    sendKey(key);
    return;
  }
  let data = null;
  if (!data && event.ctrlKey && event.key.length === 1) {
    data = String.fromCharCode(event.key.toUpperCase().charCodeAt(0) - 64);
  } else if (!data && event.key.length === 1 && !event.metaKey) {
    data = event.key;
  }
  if (data) { event.preventDefault(); sendInput(data); }
});
document.querySelectorAll('#toolbar button').forEach((button) => {
  button.onclick = () => {
    if (button.dataset.key === 'ctrl-c') sendInput('\u0003');
    else sendKey(TOOLBAR_KEYS[button.dataset.key]);
  };
});
pivotTabs.forEach((tab) => {
  tab.onclick = () => setViewMode(tab.dataset.mode);
});
document.querySelector('#pivot-tabs').addEventListener('keydown', (event) => {
  if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
  event.preventDefault();
  const current = pivotTabs.findIndex(
    (tab) => tab.dataset.mode === viewMode
  );
  const step = event.key === 'ArrowRight' ? 1 : -1;
  const next = pivotTabs[(current + step + pivotTabs.length) % pivotTabs.length];
  if (next) { setViewMode(next.dataset.mode, {silent:true}); next.focus(); }
});
newSessionButton.onclick = () => { createSession(); };
closeSessionButton.onclick = () => { closeCurrentSession(); };
newSessionProject.onchange = () => {
  const nextProjectId = newSessionProject.value || null;
  if (createTargetProjectId === nextProjectId) return;
  createTargetProjectId = nextProjectId;
  if (createRequestProjectId !== createTargetProjectId) {
    clearCreateRequest();
  }
  setCreateStatus('');
  updateNewSessionState();
};
updateNewSessionState();
document.querySelector('#input-form').onsubmit = (event) => {
  event.preventDefault();
  if (sendCommand(input.value)) input.value = '';
  terminal.focus();
};
input.addEventListener('input', () => {
  inputMessage = null;
  renderInputDeliveryState();
});
discardPendingInput.onclick = discardQueuedTerminalInput;
// Enter sends the prompt; Shift+Enter inserts a newline (chat-composer style).
prompt.addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    promptForm.requestSubmit();
  }
});
prompt.addEventListener('input', () => {
  // Mirror the selectSession() guard: don't resurrect a draft for a
  // session that was just pruned from the workspace snapshot while its
  // composer is still visible and the user keeps typing into it.
  if (selected && sessionState.has(selected)) {
    setPromptDraft(selected, prompt.value);
  }
  updatePromptState();
});
promptForm.onsubmit = (event) => {
  event.preventDefault();
  if (enqueuePrompt(prompt.value)) {
    prompt.value = '';
    setPromptDraft(selected, '');
    persistPromptDrafts();
    updatePromptState();
  }
};
window.addEventListener('pagehide', persistPromptDrafts);
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'hidden') persistPromptDrafts();
});

function base64URLToBytes(value) {
  const padded = value.replace(/-/g, '+').replace(/_/g, '/')
    + '='.repeat((4 - value.length % 4) % 4);
  const raw = atob(padded);
  return Uint8Array.from(raw, (character) => character.charCodeAt(0));
}

function bytesToBase64URL(value) {
  const bytes = new Uint8Array(value);
  let raw = '';
  bytes.forEach((byte) => { raw += String.fromCharCode(byte); });
  return btoa(raw).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function registerSubscription(subscription, publicKey) {
  const response = await fetch(`${base}push/subscribe`, {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify({
      subscription: {
        ...subscription.toJSON(),
        applicationServerKey: publicKey
      },
      label: navigator.userAgent.slice(0, 120),
      capabilities: ['clear-action']
    })
  });
  if (!response.ok) throw new Error(`Subscription failed (${response.status})`);
  notifications.className = 'enabled';
  notifications.title = 'Web notifications enabled';
  notifications.setAttribute('aria-label', 'Web notifications enabled');
}

async function setupNotifications(requestPermission) {
  const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent);
  const standalone = matchMedia('(display-mode: standalone)').matches
    || navigator.standalone === true;
  if (!('serviceWorker' in navigator) || !('PushManager' in window)
      || !('Notification' in window)) {
    notifications.className = 'unsupported';
    notifications.title = 'Web notifications are not supported';
    return;
  }
  if (isIOS && !standalone) {
    notifications.className = 'unsupported';
    notifications.title = 'Add this app to the Home Screen to enable notifications';
    return;
  }
  const registration = await navigator.serviceWorker.register(`${base}sw.js`);
  let subscription = await registration.pushManager.getSubscription();
  const keyResponse = await fetch(`${base}push/public-key`);
  if (!keyResponse.ok) throw new Error('Push service unavailable');
  const {applicationServerKey} = await keyResponse.json();

  if (subscription?.options?.applicationServerKey
      && bytesToBase64URL(subscription.options.applicationServerKey)
        !== applicationServerKey) {
    await subscription.unsubscribe();
    subscription = null;
  }
  if (!subscription && requestPermission) {
    const permission = await Notification.requestPermission();
    if (permission !== 'granted') {
      notifications.className = 'denied';
      notifications.title = 'Web notification permission denied';
      return;
    }
    subscription = await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: base64URLToBytes(applicationServerKey)
    });
  }
  if (subscription) {
    await registerSubscription(subscription, applicationServerKey);
  }
}

notifications.onclick = async () => {
  try {
    await setupNotifications(true);
  } catch (error) {
    notifications.className = 'denied';
    notifications.title = `Web notifications failed: ${error.message}`;
  }
};
setupNotifications(false).catch(() => {});

navigator.serviceWorker?.addEventListener('message', (event) => {
  if (event.data?.type !== 'focus-session') return;
  pendingFocusSession = event.data.sessionId || null;
  if (pendingFocusSession) {
    const target = document.querySelector(
      `nav button[data-id="${CSS.escape(pendingFocusSession)}"]`
    );
    if (target) {
      const sessionId = pendingFocusSession;
      pendingFocusSession = null;
      selectSession(sessionId);
    }
  }
});

openStream();
