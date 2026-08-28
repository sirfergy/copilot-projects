const PROMPT_DRAFT_STORAGE_PREFIX = 'copilot-projects-prompt-draft-v2:';
const PROMPT_DRAFT_MAX_LENGTH = 8192;
const PROMPT_DRAFT_MAX_SESSIONS = 100;
const PROMPT_DRAFT_SAVE_DELAY = 200;
const promptDrafts = new Map();

function truncatePromptDraft(value) {
  // String.slice() counts UTF-16 code units, so cutting at exactly
  // PROMPT_DRAFT_MAX_LENGTH can land between the two halves of a
  // surrogate pair (e.g. many emoji), leaving an unpaired high
  // surrogate that renders as a replacement character on the next
  // read. Drop a trailing unpaired high surrogate so truncation
  // always lands on a code-point boundary.
  let sliced = value.slice(0, PROMPT_DRAFT_MAX_LENGTH);
  const lastCode = sliced.charCodeAt(sliced.length - 1);
  if (lastCode >= 0xd800 && lastCode <= 0xdbff) {
    sliced = sliced.slice(0, -1);
  }
  return sliced;
}
// Session ids this tab changed since their last successful per-key write.
const promptDraftDirtySessions = new Set();
// For sessions marked dirty by capacity eviction (not an intentional
// prune/clear), the candidate's live updatedAt observed at the moment
// eviction was decided. The debounced flush can land up to
// PROMPT_DRAFT_SAVE_DELAY later, which is enough time for another tab to
// refresh the same candidate; persistPromptDrafts() re-checks this
// baseline immediately before deleting so that later refresh wins
// instead of being silently destroyed.
const promptDraftEvictionBaseline = new Map();
let promptDraftSaveTimer = null;
let promptDraftStorageWarningShown = false;

function promptDraftStorageKey(sessionId) {
  return `${PROMPT_DRAFT_STORAGE_PREFIX}${encodeURIComponent(sessionId)}`;
}

function sessionIdForPromptDraftStorageKey(key) {
  if (typeof key !== 'string' || !key.startsWith(PROMPT_DRAFT_STORAGE_PREFIX)) {
    return null;
  }
  try {
    const sessionId = decodeURIComponent(key.slice(PROMPT_DRAFT_STORAGE_PREFIX.length));
    return sessionId && promptDraftStorageKey(sessionId) === key ? sessionId : null;
  } catch (_) {
    return null;
  }
}

function warnPromptDraftStorage(error) {
  if (promptDraftStorageWarningShown) return;
  promptDraftStorageWarningShown = true;
  console.warn('Copilot Projects could not persist message drafts.', error);
}

function parseStoredPromptDraft(raw) {
  let decoded = null;
  try {
    decoded = JSON.parse(raw);
  } catch (error) {
    warnPromptDraftStorage(error);
    return null;
  }
  if (!decoded || typeof decoded !== 'object' || Array.isArray(decoded)
      || typeof decoded.value !== 'string' || !decoded.value) {
    warnPromptDraftStorage(new Error('Stored message drafts are invalid.'));
    return null;
  }
  const value = truncatePromptDraft(decoded.value);
  const updatedAt = Number.isFinite(decoded.updatedAt) ? decoded.updatedAt : 0;
  return {
    draft: { value, updatedAt },
    corrected: value !== decoded.value || updatedAt !== decoded.updatedAt
  };
}

function loadPromptDrafts() {
  const storageKeys = [];
  try {
    for (let index = 0; index < localStorage.length; index += 1) {
      const key = localStorage.key(index);
      if (typeof key === 'string' && key.startsWith(PROMPT_DRAFT_STORAGE_PREFIX)) {
        storageKeys.push(key);
      }
    }
  } catch (error) {
    warnPromptDraftStorage(error);
    return;
  }

  const loaded = [];
  const invalidKeys = [];
  for (const key of storageKeys) {
    const sessionId = sessionIdForPromptDraftStorageKey(key);
    if (!sessionId) {
      invalidKeys.push(key);
      continue;
    }
    let raw = null;
    try {
      raw = localStorage.getItem(key);
    } catch (error) {
      promptDrafts.clear();
      warnPromptDraftStorage(error);
      return;
    }
    const parsed = raw ? parseStoredPromptDraft(raw) : null;
    if (!parsed) {
      invalidKeys.push(key);
      continue;
    }
    loaded.push({ sessionId, key, ...parsed });
  }

  loaded.sort((left, right) => left.draft.updatedAt - right.draft.updatedAt);
  const retained = loaded.slice(-PROMPT_DRAFT_MAX_SESSIONS);
  const excess = loaded.slice(0, -PROMPT_DRAFT_MAX_SESSIONS);
  for (const entry of retained) {
    promptDrafts.set(entry.sessionId, entry.draft);
    if (entry.corrected) promptDraftDirtySessions.add(entry.sessionId);
  }
  for (const entry of excess) {
    promptDraftDirtySessions.add(entry.sessionId);
    promptDraftEvictionBaseline.set(entry.sessionId, {
      value: entry.draft.value,
      updatedAt: entry.draft.updatedAt,
    });
  }

  for (const key of invalidKeys) {
    try {
      localStorage.removeItem(key);
    } catch (error) {
      warnPromptDraftStorage(error);
    }
  }
  if (promptDraftDirtySessions.size) schedulePromptDraftPersistence();
}

function persistPromptDrafts() {
  if (promptDraftSaveTimer !== null) {
    clearTimeout(promptDraftSaveTimer);
    promptDraftSaveTimer = null;
  }
  if (!promptDraftDirtySessions.size) return;

  const dirtySessions = Array.from(promptDraftDirtySessions);
  const deletions = dirtySessions.filter((sessionId) => !promptDrafts.has(sessionId));
  const writes = dirtySessions.filter((sessionId) => promptDrafts.has(sessionId));
  for (const sessionId of [...deletions, ...writes]) {
    const isWrite = promptDrafts.has(sessionId);
    if (!isWrite && promptDraftEvictionBaseline.has(sessionId)) {
      // This deletion came from capacity-based eviction. Re-check the
      // live value right before deleting - the debounce window since
      // the eviction decision is enough time for another tab to have
      // refreshed this same candidate, and that refresh must win.
      const baseline = promptDraftEvictionBaseline.get(sessionId);
      let raw = null;
      let readFailed = false;
      try {
        raw = localStorage.getItem(promptDraftStorageKey(sessionId));
      } catch (error) {
        warnPromptDraftStorage(error);
        readFailed = true;
      }
      if (readFailed) {
        // Could not verify whether another tab touched this candidate
        // since the eviction decision was made - proceeding to delete
        // anyway would bypass the freshness guard entirely on exactly
        // the failure it exists to protect against. Leave it dirty and
        // retry the recheck on the next flush instead.
        continue;
      }
      const stored = raw ? parseStoredPromptDraft(raw) : null;
      // Compare the exact stored record against the exact baseline
      // snapshot rather than only `updatedAt > baseline`: Date.now()
      // is millisecond-resolution, so another tab can write a
      // different value within the same millisecond the baseline was
      // captured in, and a timestamp-only comparison would treat that
      // as unchanged. An exact mismatch on either field means some
      // write happened since the decision, regardless of ordering.
      if (
        stored &&
        (stored.draft.value !== baseline.value ||
          stored.draft.updatedAt !== baseline.updatedAt)
      ) {
        // Changed elsewhere since the eviction decision - decline this
        // deletion and leave storage untouched.
        promptDraftDirtySessions.delete(sessionId);
        promptDraftEvictionBaseline.delete(sessionId);
        continue;
      }
    }
    try {
      if (isWrite) {
        localStorage.setItem(
          promptDraftStorageKey(sessionId),
          JSON.stringify(promptDrafts.get(sessionId))
        );
      } else {
        localStorage.removeItem(promptDraftStorageKey(sessionId));
      }
      promptDraftDirtySessions.delete(sessionId);
      promptDraftEvictionBaseline.delete(sessionId);
    } catch (error) {
      warnPromptDraftStorage(error);
    }
  }
}

function schedulePromptDraftPersistence() {
  if (promptDraftSaveTimer !== null) clearTimeout(promptDraftSaveTimer);
  promptDraftSaveTimer = setTimeout(
    persistPromptDrafts,
    PROMPT_DRAFT_SAVE_DELAY
  );
}

function draftForSession(sessionId) {
  return sessionId ? (promptDrafts.get(sessionId)?.value || '') : '';
}

function selectPromptDraftEvictionCandidate() {
  // promptDrafts already reflects everything this tab knows about,
  // including edits it made but hasn't flushed to storage yet - a
  // live-storage-only scan would miss those pending sessions and
  // wrongly conclude there's room to spare. But promptDrafts alone
  // would miss sessions another tab created that this tab never
  // loaded, which is the actual gap: two tabs that each start from an
  // empty store and only ever create their own disjoint sessions would
  // both judge the cap against their own map alone and never notice
  // storage growing well past it. Combine both views - this tab's own
  // record takes precedence for anything it knows, and live storage
  // fills in only the sessions it doesn't - so the cap is judged
  // against every session that exists anywhere, not just the ones a
  // single tab happens to have loaded or created.
  const candidates = [];
  const known = new Set();
  for (const [sessionId, draft] of promptDrafts.entries()) {
    candidates.push({ sessionId, draft });
    known.add(sessionId);
  }

  const storageKeys = [];
  try {
    for (let index = 0; index < localStorage.length; index += 1) {
      const key = localStorage.key(index);
      if (typeof key === 'string' && key.startsWith(PROMPT_DRAFT_STORAGE_PREFIX)) {
        storageKeys.push(key);
      }
    }
  } catch (error) {
    warnPromptDraftStorage(error);
    // Fall back to this tab's own view alone rather than skipping
    // eviction entirely - it still enforces the cap against what this
    // tab actually knows.
    if (candidates.length < PROMPT_DRAFT_MAX_SESSIONS) return null;
    candidates.sort((left, right) => left.draft.updatedAt - right.draft.updatedAt);
    return candidates[0];
  }

  for (const key of storageKeys) {
    const sessionId = sessionIdForPromptDraftStorageKey(key);
    // A session already staged for eviction (promptDraftEvictionBaseline)
    // is still physically present in storage until this tab's next
    // flush actually deletes it, so a naive re-scan would keep finding
    // and re-picking that same not-yet-removed entry on every
    // subsequent call instead of progressing to the next-oldest
    // candidate - one net-new session added would never make more than
    // one eviction happen no matter how many more were added after it.
    // Treat anything already staged as already gone for this decision.
    if (!sessionId || known.has(sessionId) || promptDraftEvictionBaseline.has(sessionId)) {
      continue;
    }
    let raw = null;
    try {
      raw = localStorage.getItem(key);
    } catch (error) {
      warnPromptDraftStorage(error);
      continue;
    }
    const parsed = raw ? parseStoredPromptDraft(raw) : null;
    if (!parsed) continue;
    candidates.push({ sessionId, draft: parsed.draft });
  }

  if (candidates.length < PROMPT_DRAFT_MAX_SESSIONS) {
    // Storage isn't actually at cap once every tab's sessions are
    // counted; nothing needs to be evicted to make room for a new one.
    return null;
  }

  candidates.sort((left, right) => left.draft.updatedAt - right.draft.updatedAt);
  return candidates[0];
}

function setPromptDraft(sessionId, value) {
  if (!sessionId) return;
  const normalized = truncatePromptDraft(String(value ?? ''));
  if (!normalized) {
    if (!promptDrafts.delete(sessionId)) return;
    promptDraftDirtySessions.add(sessionId);
    schedulePromptDraftPersistence();
    return;
  }
  if (promptDrafts.get(sessionId)?.value === normalized) return;
  if (promptDrafts.has(sessionId)) {
    promptDrafts.delete(sessionId);
  } else {
    const evicted = selectPromptDraftEvictionCandidate();
    if (evicted) {
      promptDraftEvictionBaseline.set(evicted.sessionId, {
        value: evicted.draft.value,
        updatedAt: evicted.draft.updatedAt,
      });
      promptDrafts.delete(evicted.sessionId);
      promptDraftDirtySessions.add(evicted.sessionId);
    }
  }
  promptDrafts.set(sessionId, { value: normalized, updatedAt: Date.now() });
  promptDraftDirtySessions.add(sessionId);
  schedulePromptDraftPersistence();
}

function prunePromptDrafts(activeSessionIds) {
  let changed = false;
  for (const sessionId of promptDrafts.keys()) {
    if (activeSessionIds.has(sessionId)) continue;
    promptDrafts.delete(sessionId);
    promptDraftDirtySessions.add(sessionId);
    changed = true;
  }
  if (changed) schedulePromptDraftPersistence();
}

loadPromptDrafts();
