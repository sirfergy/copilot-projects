// Only the most recent turns are fetched and rendered up front so a long
// transcript neither ships its whole history on every revision nor freezes
// the tab building hundreds of markdown-parsed cards in one synchronous
// pass; "Show earlier" widens the window a bounded batch at a time.
const TRANSCRIPT_RENDER_LIMIT = 50;
const TRANSCRIPT_RENDER_STEP = 50;
// Matches the host's own `?limit=` ceiling (and its per-session snapshot
// cap), so the window can never grow past what one response can carry.
const TRANSCRIPT_MAX_RENDER_LIMIT = 200;
let transcriptRenderLimit = TRANSCRIPT_RENDER_LIMIT;
// Last transcript snapshot received for the selected session. Renders are
// skipped entirely while the Conversation pane is hidden, so this is what
// revealing it renders from. Session-scoped: cleared in
// resetTranscriptForSession().
let lastRenderedTranscript = null;
// `sessionId\u0000turnId` -> {card, signature, imageNodes}. A turn whose
// rendered content is unchanged keeps its existing DOM — including its
// already-parsed markdown and its mounted inline images — so a 2Hz revision
// stream only builds the turns that actually changed. Bounded by the render
// window: every render evicts the entries it didn't use, so this is never a
// growing global memo.
const transcriptCardCache = new Map();
// Scroll anchor captured when "Show earlier" is clicked, so the widened
// window lands on the same content even though the older turns arrive from a
// later fetch (and even if a revision renders in between).
let pendingTranscriptAnchor = null;
// The "Show earlier" control is created once and updated in place (label,
// disabled state, and the action for the current render), so re-rendering
// while it holds keyboard focus never blurs it out from under the user.
let transcriptShowEarlier = null;

function transcriptCardKey(sessionId, turnId) {
  return `${sessionId}\u0000${turnId}`;
}

// Everything a card renders, so a cached card is reused only when the next
// snapshot would have produced identical DOM. Inline images are part of it:
// a changed/added/removed image ref must rebuild the card (and re-mount its
// image nodes) rather than silently keep stale pixels.
function transcriptCardSignature(turn) {
  return JSON.stringify([
    turn.kind || '',
    !!turn.isAborted,
    turn.userContent || '',
    (turn.assistantMessages || []).map((message) => [
      message.id || '', message.content || ''
    ]),
    (turn.tools || []).map((tool) => [
      tool.id || '', tool.name || '', tool.title || '', tool.success ?? null
    ]),
    (Array.isArray(turn.images) ? turn.images : []).map((raw) => {
      const ref = normalizeConversationImageRef(raw);
      return ref ? `${ref.imageId}:${ref.contentVersion}` : 'invalid';
    })
  ]);
}

function releaseTranscriptCardEntry(entry) {
  const releasing = entry.imageNodes;
  // Swap the list out first: a release can run reconciliation callbacks, and
  // none of them may see (or re-walk) a list being mutated underneath them.
  entry.imageNodes = [];
  releasing.forEach(releaseConversationImageNode);
}

// Drops every cached card and the image references those cards hold. Used
// whenever the transcript DOM is replaced by something that isn't a render
// (session switch, hidden pane, error placeholder), so no cache entry is
// ever left owning a reference to a node that isn't mounted.
function clearTranscriptCardCache() {
  const releasing = Array.from(transcriptCardCache.values());
  transcriptCardCache.clear();
  transcriptShowEarlier = null;
  releasing.forEach(releaseTranscriptCardEntry);
}

// Hides the conversation pane's content: the cached cards, the image
// references they hold, AND the rendered DOM itself, so a hidden pane never
// keeps a window's worth of heavy turn cards alive. `lastRenderedTranscript`
// is deliberately kept — revealing the pane rebuilds from it.
function clearTranscriptDOM() {
  clearTranscriptCardCache();
  transcript.replaceChildren();
}

// Replaces the conversation DOM with a single status line (loading, or a
// load failure), dropping whatever cards were up.
function showTranscriptPlaceholder(message) {
  clearTranscriptCardCache();
  const notice = document.createElement('div');
  notice.className = 'transcript-empty';
  notice.textContent = message;
  transcript.replaceChildren(notice);
}

// Clears every conversation image node displaying `key` after that entry's
// bytes were invalidated (a real decode failure). The node stops pointing at
// a revoked object URL and, crucially, hands back the decoded-pixel budget it
// was holding — otherwise those pixels stay charged until the owning card
// happens to change, blocking later images from mounting. Resetting
// `cacheKey`/`pixels` here also makes a later release a no-op for the budget,
// so nothing is ever decremented twice.
function clearConversationImageCacheKey(key) {
  transcriptCardCache.forEach((entry) => entry.imageNodes.forEach((node) => {
    if (node.cacheKey !== key) return;
    terminalActiveDecodedPixels = Math.max(0, terminalActiveDecodedPixels - node.pixels);
    node.cacheKey = null;
    node.pixels = 0;
    delete node.el.dataset.cacheKey;
    node.el.removeAttribute('src');
  }));
}

// Session-scoped transcript state: the cached cards (and their image
// references), the retained snapshot, the pending anchor, and the fetch
// window. Runs on every selection change, before anything renders for the
// new session, and bumps the request generation so a response for the
// previous session can never land on the new one.
function resetTranscriptForSession() {
  clearTranscriptCardCache();
  lastRenderedTranscript = null;
  pendingTranscriptAnchor = null;
  transcriptRenderLimit = TRANSCRIPT_RENDER_LIMIT;
  transcriptRequestId += 1;
}

// How many older turns the host holds beyond the ones it returned. A host
// that honored `?limit=` reports `totalTurns`; an older host ignores the
// query and omits the field, in which case nothing was withheld and the
// whole transcript is trimmed client-side instead.
function transcriptWithheldTurnCount(snapshot) {
  const returned = snapshot?.turns?.length || 0;
  const total = snapshot?.totalTurns;
  if (!Number.isSafeInteger(total) || total <= returned) return 0;
  return total - returned;
}

// First turn card intersecting the viewport top, with its current position,
// so a re-render can restore the viewport to the same content.
function transcriptTopAnchor() {
  const containerTop = transcript.getBoundingClientRect().top;
  for (const card of transcript.querySelectorAll('.turn')) {
    const rect = card.getBoundingClientRect();
    if (rect.bottom > containerTop) {
      return { turnId: card.dataset.turnId, top: rect.top };
    }
  }
  return null;
}

// The focused element when it lives inside the transcript, so a render can
// tell whether it is responsible for focus at all. Focus anywhere else (the
// prompt, the terminal, the tab strip) is never touched.
function transcriptFocusedElement() {
  const active = document.activeElement;
  if (!active || active === transcript) return null;
  return transcript.contains(active) ? active : null;
}

// Reconciles the transcript's children to exactly `desired`, in order,
// without detaching anything that is already where it belongs. Detaching a
// reused card — which a `replaceChildren(fragment)` swap does to every card,
// even unchanged ones — blurs whatever inside it had keyboard focus and
// drops the browser's layout for it, so a 2Hz revision stream would fight
// the reader. Removals run first, then one forward pass inserts only nodes
// that are new or genuinely out of order.
function reconcileTranscriptChildren(desired) {
  const wanted = new Set(desired);
  Array.from(transcript.children).forEach((child) => {
    if (!wanted.has(child)) child.remove();
  });
  let cursor = transcript.firstElementChild;
  for (const node of desired) {
    if (cursor === node) {
      cursor = cursor.nextElementSibling;
      continue;
    }
    transcript.insertBefore(node, cursor);
  }
}

// The reusable "Show earlier" control. `activate` is null once the window is
// at the host's per-response ceiling: the remaining turns aren't reachable,
// so the control reports them instead of offering a no-op action.
function transcriptShowEarlierControl(earlierCount, activate) {
  if (!transcriptShowEarlier) {
    const control = document.createElement('button');
    control.type = 'button';
    control.className = 'show-earlier';
    control.addEventListener('click', () => {
      if (control.activate) control.activate();
    });
    transcriptShowEarlier = control;
  }
  transcriptShowEarlier.activate = activate;
  transcriptShowEarlier.disabled = !activate;
  transcriptShowEarlier.textContent = activate
    ? `Show earlier (${earlierCount} more)`
    : `${earlierCount} earlier turn${earlierCount === 1 ? '' : 's'} not shown`;
  return transcriptShowEarlier;
}

function transcriptMessage(label, text, className) {
  const container = document.createElement('div');
  container.className = `message ${className}`;
  const heading = document.createElement('span');
  heading.className = 'message-label';
  heading.textContent = label;
  container.append(heading);
  appendMarkdown(container, text);
  return container;
}

// Builds one turn card (and mounts its inline images). Only ever called for
// a turn whose content differs from the cached card's, so this is the one
// place markdown is parsed.
function buildTranscriptCard(sessionId, turn, signature) {
  const card = document.createElement('article');
  card.className = 'turn';
  card.dataset.turnId = turn.id;
  const header = document.createElement('div');
  header.className = 'turn-header';
  const kind = document.createElement('span');
  kind.textContent = turn.kind === 'scheduled'
    ? 'Scheduled' : turn.kind === 'automated' ? 'Automated' : 'You';
  header.append(kind);
  if (turn.isAborted) {
    const stopped = document.createElement('span');
    stopped.className = 'stopped';
    stopped.textContent = 'Stopped';
    header.append(stopped);
  }
  card.append(header);
  if (turn.userContent) {
    card.append(transcriptMessage('You', turn.userContent, 'user'));
  }
  (turn.assistantMessages || []).forEach((message) => {
    card.append(transcriptMessage('Copilot', message.content, 'assistant'));
  });
  if (turn.tools?.length) {
    const tools = document.createElement('div');
    tools.className = 'tools';
    const successful = turn.tools.filter((tool) => tool.success === true).length;
    tools.textContent = `${turn.tools.length} tool${turn.tools.length === 1 ? '' : 's'}`
      + (successful ? ` · ${successful} completed` : '');
    card.append(tools);
  }
  const imageNodes = [];
  // Renders only run in conversation mode, so mounting here can never hold
  // the shared image budget for a hidden pane.
  if (Array.isArray(turn.images) && turn.images.length && sessionId) {
    const gallery = document.createElement('div');
    gallery.className = 'conversation-images';
    turn.images.forEach((raw) => {
      const ref = normalizeConversationImageRef(raw);
      if (!ref) return;
      const node = createConversationImageNode(sessionId, ref);
      imageNodes.push(node);
      gallery.append(node.figure);
    });
    if (gallery.childElementCount) card.append(gallery);
  }
  return { card, signature, imageNodes };
}

function renderTranscript(snapshot) {
  lastRenderedTranscript = snapshot;
  // The Conversation pane is hidden: keep the snapshot, build nothing. The
  // terminal pane is what the user is watching, and revealing this one
  // re-renders from `lastRenderedTranscript` (see setViewMode).
  if (viewMode !== 'conversation') return;
  const sessionId = selected;
  // A "Show earlier" click anchors explicitly; it must win over the
  // stick-to-bottom heuristic so the revealed batch doesn't scroll away.
  const pendingAnchor = pendingTranscriptAnchor;
  pendingTranscriptAnchor = null;
  const wasAtBottom = !pendingAnchor
    && transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 18;
  // Capture a stable scroll anchor — the first turn intersecting the viewport
  // top — so trimming older turns (a new SSE turn slides the capped window) or
  // revealing them ("Show earlier") keeps the viewport on the same content
  // instead of jumping. Only needed when the user has scrolled up.
  let anchorId = pendingAnchor?.turnId ?? null;
  let anchorTop = pendingAnchor?.top ?? 0;
  if (!wasAtBottom && anchorId === null) {
    const anchor = transcriptTopAnchor();
    anchorId = anchor?.turnId ?? null;
    anchorTop = anchor?.top ?? 0;
  }
  const desired = [];
  const allTurns = snapshot?.turns || [];
  const total = allTurns.length;
  if (!total) {
    const empty = document.createElement('div');
    empty.className = 'transcript-empty';
    empty.textContent = 'Completed turns will appear here.';
    desired.push(empty);
  }
  // Turns the host withheld because it honored the requested window (zero
  // when an older host ignored `limit` and returned everything).
  const withheld = transcriptWithheldTurnCount(snapshot);
  // Cap the rendered turns to the most recent window; older turns are
  // revealed on demand so a long transcript never builds its whole DOM (and
  // re-parses every message's markdown) in one blocking pass. A host that
  // applied the window already returned exactly this many turns, so this
  // trims nothing; an older host's full transcript is trimmed here.
  const hiddenCount = Math.max(0, total - transcriptRenderLimit);
  const turns = hiddenCount > 0 ? allTurns.slice(hiddenCount) : allTurns;
  const earlierCount = hiddenCount + withheld;
  if (earlierCount > 0) {
    const atCeiling = transcriptRenderLimit >= TRANSCRIPT_MAX_RENDER_LIMIT;
    desired.push(transcriptShowEarlierControl(earlierCount, atCeiling ? null : () => {
      if (transcriptRenderLimit >= TRANSCRIPT_MAX_RENDER_LIMIT) return;
      pendingTranscriptAnchor = transcriptTopAnchor();
      transcriptRenderLimit += TRANSCRIPT_RENDER_STEP;
      if (transcriptRenderLimit > TRANSCRIPT_MAX_RENDER_LIMIT) {
        transcriptRenderLimit = TRANSCRIPT_MAX_RENDER_LIMIT;
      }
      if (withheld > 0 && sessionId) {
        // The older turns were never fetched: widen the request. The
        // currently rendered cards stay up until it resolves.
        fetchTranscript({ sessionId });
      } else {
        renderTranscript(snapshot);
      }
    }));
  } else {
    transcriptShowEarlier = null;
  }
  // Reuse the cached card for every turn whose rendered content is
  // unchanged; only genuinely changed turns are rebuilt.
  const retained = new Map();
  turns.forEach((turn) => {
    const key = transcriptCardKey(sessionId, turn.id);
    const signature = transcriptCardSignature(turn);
    const cached = transcriptCardCache.get(key);
    const entry = cached?.signature === signature
      ? cached
      : buildTranscriptCard(sessionId, turn, signature);
    retained.set(key, entry);
    desired.push(entry.card);
  });
  // Cards replaced by a rebuild, or dropped from the window entirely, are
  // released only after the new DOM (and the replacement image nodes it
  // already mounted) is in place, so an unchanged image's shared cache entry
  // never hits a zero reference count in between.
  const releasing = [];
  transcriptCardCache.forEach((entry, key) => {
    if (retained.get(key) !== entry) releasing.push(entry);
  });
  transcriptCardCache.clear();
  retained.forEach((entry, key) => transcriptCardCache.set(key, entry));
  const focusedBefore = transcriptFocusedElement();
  reconcileTranscriptChildren(desired);
  // Only a genuinely reordered node gets moved, and only such a move can
  // blur focus the transcript owned. Restore it (without scrolling) instead
  // of dropping the reader to the document body; focus is never taken when
  // it wasn't already inside a card that survived this render.
  if (focusedBefore
      && focusedBefore.isConnected
      && document.activeElement !== focusedBefore) {
    focusedBefore.focus({ preventScroll: true });
  }
  releasing.forEach(releaseTranscriptCardEntry);
  if (wasAtBottom) {
    transcript.scrollTop = transcript.scrollHeight;
  } else if (anchorId !== null) {
    // Restore the anchored turn to its prior viewport position.
    let restored = false;
    for (const card of transcript.querySelectorAll('.turn')) {
      if (card.dataset.turnId === anchorId) {
        transcript.scrollTop += card.getBoundingClientRect().top - anchorTop;
        restored = true;
        break;
      }
    }
    // The anchored turn was trimmed off the top (user parked at the very top
    // of an actively-streaming, capped session) — keep them at the top rather
    // than letting the viewport drift by one turn.
    if (!restored) transcript.scrollTop = 0;
  }
}

// A response applies only when the selection, the request generation, AND
// the window it was requested for are all still current: expanding the
// window or switching sessions must never be overwritten by an in-flight
// response for the narrower/previous one.
function transcriptResponseIsCurrent(sessionId, requestId, limit) {
  return selected === sessionId
    && requestId === transcriptRequestId
    && limit === transcriptRenderLimit;
}

async function fetchTranscript(revision) {
  const sessionId = revision.sessionId;
  const limit = transcriptRenderLimit;
  const requestId = ++transcriptRequestId;
  try {
    const response = await fetch(
      `${base}transcript?s=${encodeURIComponent(sessionId)}&limit=${limit}`,
      { cache: 'no-store' }
    );
    if (!response.ok
        || !transcriptResponseIsCurrent(sessionId, requestId, limit)) return;
    const snapshot = await response.json();
    if (transcriptResponseIsCurrent(sessionId, requestId, limit)) {
      renderTranscript(snapshot);
    }
  } catch {
    if (transcriptResponseIsCurrent(sessionId, requestId, limit)) {
      showTranscriptPlaceholder('Could not load completed turns.');
    }
  }
}
