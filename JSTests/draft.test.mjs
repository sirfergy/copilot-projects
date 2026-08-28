import assert from "node:assert/strict";
import test from "node:test";

import { bindings, loadFragments, localStorageShim } from "./support/fragments.mjs";

const NAMES = [
  "PROMPT_DRAFT_STORAGE_PREFIX",
  "PROMPT_DRAFT_MAX_LENGTH",
  "PROMPT_DRAFT_MAX_SESSIONS",
  "promptDrafts",
  "promptDraftDirtySessions",
  "promptDraftEvictionBaseline",
  "truncatePromptDraft",
  "promptDraftStorageKey",
  "sessionIdForPromptDraftStorageKey",
  "parseStoredPromptDraft",
  "persistPromptDrafts",
];

/// Loads draft.js against a seeded storage. The fragment calls
/// `loadPromptDrafts()` on evaluation, so seeding happens up front and the
/// scheduled debounce is captured instead of arming a real timer.
function draft(seed = {}) {
  const localStorage = localStorageShim(seed);
  const scheduled = [];
  const context = loadFragments(["draft"], {
    localStorage,
    setTimeout: (callback, delay) => {
      scheduled.push({ callback, delay });
      return scheduled.length;
    },
    clearTimeout: (handle) => {
      if (handle) scheduled[handle - 1] = null;
    },
    console: { warn() {}, error() {}, log() {} },
  });
  return { localStorage, scheduled, ...bindings(context, NAMES) };
}

function storedDraft(value, updatedAt) {
  return JSON.stringify({ value, updatedAt });
}

test("truncatePromptDraft never splits a surrogate pair", () => {
  const { truncatePromptDraft, PROMPT_DRAFT_MAX_LENGTH } = draft();

  const shortValue = "hello";
  assert.equal(truncatePromptDraft(shortValue), shortValue);

  const exact = "a".repeat(PROMPT_DRAFT_MAX_LENGTH);
  assert.equal(truncatePromptDraft(`${exact}overflow`).length, PROMPT_DRAFT_MAX_LENGTH);

  // "🙂" is two UTF-16 code units, so a cut at the limit lands mid-pair.
  const straddling = `${"a".repeat(PROMPT_DRAFT_MAX_LENGTH - 1)}🙂`;
  const truncated = truncatePromptDraft(straddling);
  assert.equal(truncated.length, PROMPT_DRAFT_MAX_LENGTH - 1);
  assert.ok(!truncated.includes("\ufffd"));
  assert.equal([...truncated].pop(), "a", "the unpaired high surrogate is dropped");
});

test("prompt draft storage keys round-trip and reject ambiguous encodings", () => {
  const { promptDraftStorageKey, sessionIdForPromptDraftStorageKey, PROMPT_DRAFT_STORAGE_PREFIX } =
    draft();

  for (const sessionId of ["plain", "a b", "with:colon", "emoji-🙂", "percent-%"]) {
    assert.equal(
      sessionIdForPromptDraftStorageKey(promptDraftStorageKey(sessionId)),
      sessionId,
      `${sessionId} must round-trip`
    );
  }

  assert.equal(sessionIdForPromptDraftStorageKey("some-other-key"), null);
  assert.equal(sessionIdForPromptDraftStorageKey(null), null);
  assert.equal(
    sessionIdForPromptDraftStorageKey(`${PROMPT_DRAFT_STORAGE_PREFIX}%zz`),
    null,
    "an undecodable key is not a session id"
  );
  assert.equal(
    sessionIdForPromptDraftStorageKey(`${PROMPT_DRAFT_STORAGE_PREFIX}a b`),
    null,
    "a key that does not re-encode to itself is rejected rather than aliased"
  );
  assert.equal(sessionIdForPromptDraftStorageKey(PROMPT_DRAFT_STORAGE_PREFIX), null);
});

test("parseStoredPromptDraft rejects malformed records and reports corrections", () => {
  const { parseStoredPromptDraft, PROMPT_DRAFT_MAX_LENGTH } = draft();

  assert.equal(parseStoredPromptDraft("{not json"), null);
  assert.equal(parseStoredPromptDraft("[]"), null);
  assert.equal(parseStoredPromptDraft('{"value":""}'), null);
  assert.equal(parseStoredPromptDraft('{"value":42}'), null);

  const clean = parseStoredPromptDraft(storedDraft("hello", 5));
  assert.equal(clean.draft.value, "hello");
  assert.equal(clean.draft.updatedAt, 5);
  assert.equal(clean.corrected, false);

  const oversized = parseStoredPromptDraft(storedDraft("a".repeat(PROMPT_DRAFT_MAX_LENGTH + 10), 5));
  assert.equal(oversized.draft.value.length, PROMPT_DRAFT_MAX_LENGTH);
  assert.equal(oversized.corrected, true, "a truncated record must be rewritten");

  const undatedRecord = parseStoredPromptDraft('{"value":"hi"}');
  assert.equal(undatedRecord.draft.updatedAt, 0);
  assert.equal(undatedRecord.corrected, true);
});

test("loadPromptDrafts adopts valid records and purges unusable keys", () => {
  const prefix = "copilot-projects-prompt-draft-v2:";
  const { promptDrafts, localStorage } = draft({
    [`${prefix}alpha`]: storedDraft("first", 10),
    [`${prefix}beta`]: storedDraft("second", 20),
    [`${prefix}broken`]: "{not json",
    [`${prefix}a b`]: storedDraft("ambiguous key", 30),
    "unrelated-key": "left alone",
  });

  assert.equal(promptDrafts.get("alpha").value, "first");
  assert.equal(promptDrafts.get("beta").value, "second");
  assert.equal(promptDrafts.has("a b"), false);
  assert.equal(localStorage.getItem(`${prefix}broken`), null, "unparseable entries are removed");
  assert.equal(localStorage.getItem(`${prefix}a b`), null, "ambiguous keys are removed");
  assert.equal(localStorage.getItem("unrelated-key"), "left alone", "foreign keys are untouched");
});

test("loadPromptDrafts evicts the oldest drafts past the session cap", () => {
  const prefix = "copilot-projects-prompt-draft-v2:";
  const seed = {};
  const total = 105;
  for (let index = 0; index < total; index += 1) {
    seed[`${prefix}session-${index}`] = storedDraft(`draft ${index}`, index + 1);
  }
  const { promptDrafts, promptDraftDirtySessions, promptDraftEvictionBaseline, scheduled, PROMPT_DRAFT_MAX_SESSIONS } =
    draft(seed);

  assert.equal(promptDrafts.size, PROMPT_DRAFT_MAX_SESSIONS);
  assert.equal(promptDrafts.has("session-0"), false, "the oldest draft is evicted");
  assert.equal(promptDrafts.has(`session-${total - 1}`), true, "the newest draft is retained");
  for (let index = 0; index < total - PROMPT_DRAFT_MAX_SESSIONS; index += 1) {
    assert.ok(promptDraftDirtySessions.has(`session-${index}`));
    assert.equal(promptDraftEvictionBaseline.get(`session-${index}`).updatedAt, index + 1);
  }
  assert.ok(
    scheduled.some((entry) => entry && entry.delay > 0),
    "a debounced flush is scheduled for the evicted keys"
  );
});

test("persistPromptDrafts declines an eviction another tab has since refreshed", () => {
  const prefix = "copilot-projects-prompt-draft-v2:";
  const seed = {};
  for (let index = 0; index < 102; index += 1) {
    seed[`${prefix}session-${index}`] = storedDraft(`draft ${index}`, index + 1);
  }
  const { localStorage, persistPromptDrafts, promptDraftDirtySessions, promptDraftEvictionBaseline } =
    draft(seed);

  assert.ok(promptDraftEvictionBaseline.has("session-0"));
  assert.ok(promptDraftEvictionBaseline.has("session-1"));

  // Another tab refreshes one of the eviction candidates inside the debounce
  // window; the other is untouched.
  localStorage.setItem(`${prefix}session-0`, storedDraft("refreshed elsewhere", 9999));

  persistPromptDrafts();

  assert.equal(
    localStorage.getItem(`${prefix}session-0`),
    storedDraft("refreshed elsewhere", 9999),
    "a refreshed candidate survives the eviction"
  );
  assert.equal(localStorage.getItem(`${prefix}session-1`), null, "an unchanged candidate is deleted");
  assert.equal(promptDraftDirtySessions.has("session-0"), false);
  assert.equal(promptDraftDirtySessions.has("session-1"), false);
  assert.equal(promptDraftEvictionBaseline.size, 0);
});

test("persistPromptDrafts keeps a candidate dirty when the freshness re-read fails", () => {
  const prefix = "copilot-projects-prompt-draft-v2:";
  const seed = {};
  for (let index = 0; index < 101; index += 1) {
    seed[`${prefix}session-${index}`] = storedDraft(`draft ${index}`, index + 1);
  }
  const { localStorage, persistPromptDrafts, promptDraftDirtySessions } = draft(seed);

  localStorage.getItem = () => {
    throw new Error("storage unavailable");
  };
  persistPromptDrafts();

  assert.ok(
    promptDraftDirtySessions.has("session-0"),
    "an unverifiable eviction is retried rather than deleted blind"
  );
});
