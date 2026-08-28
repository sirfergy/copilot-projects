// Contract tests: the shipped client fragments are run against the same
// canonical wire examples the Swift contract tests read through
// `ProtocolFixtures.data(named:)`. Everything here loads the real resource
// files and the real fixture JSON — no SDK session is joined, nothing is
// installed, and no asset is rewritten.
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

import { bindings, fixture, fixtureText, fixturesDir, loadFragments, plain } from "./support/fragments.mjs";

const CANONICAL_FIXTURES = [
  "legacy-workspace",
  "receipt-workspace",
  "unavailable-workspace",
  "image-version",
  "windowed-transcript",
];

test("every canonical fixture is present and parses", () => {
  for (const name of CANONICAL_FIXTURES) {
    const path = join(fixturesDir, `${name}.json`);
    assert.ok(existsSync(path), `${path} is missing`);
    assert.doesNotThrow(() => JSON.parse(fixtureText(name)), `${name}.json must be valid JSON`);
  }
});

// MARK: - terminal image versions

test("the image-version fixture only survives via its exact textual version", () => {
  const { validateTerminalImagePlacement } = bindings(loadFragments(["terminal-image"]), [
    "validateTerminalImagePlacement",
  ]);
  const raw = fixture("image-version");
  const screen = { cols: 80, firstLine: 7, lines: new Array(24).fill("") };

  // JSON.parse cannot represent UInt64.max - 1: the numeric field is already
  // lossy by the time any client sees it, which is exactly why the wire also
  // carries the exact text.
  assert.notEqual(String(raw.contentVersion), raw.contentVersionText);
  assert.equal(Number.isSafeInteger(raw.contentVersion), false);

  const placement = plain(validateTerminalImagePlacement(raw, screen));
  assert.equal(
    placement.contentVersion,
    "18446744073709551614",
    "the client must carry the exact version text, never the rounded number"
  );
  assert.equal(placement.imageId, 42);
  assert.equal(placement.absoluteLine, 7, "line 0 maps onto the screen's firstLine");
  assert.equal(placement.key, "42:18446744073709551614:7:0:1:1");

  // Without the exact text there is no safe version left to key a cache on, so
  // the placement is dropped rather than silently keyed on a rounded value.
  const { contentVersionText, ...withoutText } = raw;
  assert.equal(validateTerminalImagePlacement(withoutText, screen), null);
});

test("a lossy numeric version can never alias an exact one in the cache key", () => {
  const { terminalImageCacheKey, buildTerminalImagePlacements } = bindings(
    loadFragments(["terminal-image"]),
    ["terminalImageCacheKey", "buildTerminalImagePlacements"]
  );
  const raw = fixture("image-version");
  const screen = { cols: 80, firstLine: 7, lines: new Array(24).fill("") };

  const neighbour = { ...raw, contentVersionText: "18446744073709551615" };
  const built = plain(buildTerminalImagePlacements({ ...screen, images: [raw, neighbour] }));
  assert.equal(built.length, 2, "two adjacent 64-bit versions must not collapse into one");
  assert.notEqual(
    terminalImageCacheKey("tab", built[0].imageId, built[0].contentVersion),
    terminalImageCacheKey("tab", built[1].imageId, built[1].contentVersion)
  );
});

// MARK: - windowed transcript

test("the windowed-transcript fixture reports its withheld turns", () => {
  const { transcriptWithheldTurnCount, transcriptCardKey, transcriptCardSignature } = bindings(
    loadFragments(["transcript"]),
    ["transcriptWithheldTurnCount", "transcriptCardKey", "transcriptCardSignature"]
  );
  const snapshot = fixture("windowed-transcript");

  assert.equal(snapshot.totalTurns, 4);
  assert.equal(snapshot.turns.length, 1);
  assert.equal(
    transcriptWithheldTurnCount(snapshot),
    3,
    "'Show earlier' has to know how many turns the window left behind"
  );

  // A snapshot that omits totalTurns (a host that predates the windowed
  // response) must read as "nothing withheld" rather than a negative count.
  const { totalTurns, ...unwindowed } = snapshot;
  assert.equal(transcriptWithheldTurnCount(unwindowed), 0);
  assert.equal(transcriptWithheldTurnCount({ ...snapshot, totalTurns: 1 }), 0);

  const turn = snapshot.turns[0];
  assert.equal(transcriptCardKey(snapshot.copilotSessionId, turn.id), "conversation\u0000turn-4");
  const signature = transcriptCardSignature(turn);
  assert.equal(
    transcriptCardSignature(turn),
    signature,
    "an unchanged turn must produce a stable signature so its card is reused"
  );
  assert.notEqual(
    transcriptCardSignature({ ...turn, userContent: "Changed" }),
    signature,
    "changed content must rebuild the card"
  );
});

// MARK: - workspace payloads

test("session creation picks a project from every canonical workspace payload", () => {
  const { chooseCreateProjectId, createProjectSignature } = bindings(
    loadFragments(["session-creation"]),
    ["chooseCreateProjectId", "createProjectSignature"]
  );

  for (const name of ["legacy-workspace", "receipt-workspace", "unavailable-workspace"]) {
    const workspace = fixture(name);
    const projects = workspace.projects;

    assert.equal(
      chooseCreateProjectId(projects, null, null),
      "project",
      `${name}: falls back to the first project`
    );
    assert.equal(
      chooseCreateProjectId(projects, "project", "other"),
      "project",
      `${name}: a valid current selection wins`
    );
    assert.equal(
      chooseCreateProjectId(projects, "gone", workspace.selectedProjectId),
      workspace.selectedProjectId,
      `${name}: a stale current selection defers to the host's selection`
    );
    assert.equal(
      chooseCreateProjectId(projects, "gone", "also-gone"),
      "project",
      `${name}: two stale ids still land on a real project`
    );
    assert.equal(chooseCreateProjectId([], "project", "project"), null, `${name}: no projects`);

    assert.equal(
      createProjectSignature(projects),
      '[["project","Example"]]',
      `${name}: the signature covers only id and name`
    );
  }
});

test("the project signature ignores fields the picker does not render", () => {
  const { createProjectSignature } = bindings(loadFragments(["session-creation"]), [
    "createProjectSignature",
  ]);

  // legacy and receipt workspaces differ in session status, promptability, and
  // operation support, but the create-session picker only lists projects — so
  // it must not churn when unrelated session state changes.
  assert.equal(
    createProjectSignature(fixture("legacy-workspace").projects),
    createProjectSignature(fixture("receipt-workspace").projects)
  );
  assert.notEqual(
    createProjectSignature(fixture("legacy-workspace").projects),
    createProjectSignature([{ id: "project", name: "Renamed" }])
  );
});
