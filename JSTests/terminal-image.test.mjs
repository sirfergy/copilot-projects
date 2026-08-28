import assert from "node:assert/strict";
import test from "node:test";

import { bindings, loadFragments, plain } from "./support/fragments.mjs";

const NAMES = [
  "TERMINAL_IMAGE_RETAINED_LINE_SLACK",
  "TERMINAL_IMAGE_MAX_PLACEMENTS",
  "TERMINAL_IMAGE_MAX_DIMENSION",
  "TERMINAL_IMAGE_BACKOFF_BASE_MS",
  "TERMINAL_IMAGE_BACKOFF_MAX_MS",
  "terminalImageCacheKey",
  "terminalImageBackoffDelayMs",
  "validateTerminalImagePlacement",
  "buildTerminalImagePlacements",
  "validateTerminalImagePngBytes",
];

function terminalImage() {
  return bindings(loadFragments(["terminal-image"]), NAMES);
}

const screen = { cols: 80, firstLine: 1000, lines: new Array(24).fill("") };

function placement(overrides = {}) {
  return {
    imageId: 7,
    contentVersion: 3,
    line: 2,
    column: 0,
    rows: 4,
    columns: 10,
    ...overrides,
  };
}

function pngBytes({ width = 4, height = 4, type = "IHDR", chunkLength = 13 } = {}) {
  const bytes = new Uint8Array(8 + 8 + 13);
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 0);
  const writeUInt32BE = (offset, value) => {
    bytes[offset] = (value >>> 24) & 0xff;
    bytes[offset + 1] = (value >>> 16) & 0xff;
    bytes[offset + 2] = (value >>> 8) & 0xff;
    bytes[offset + 3] = value & 0xff;
  };
  writeUInt32BE(8, chunkLength);
  for (let index = 0; index < 4; index += 1) bytes[12 + index] = type.charCodeAt(index);
  writeUInt32BE(16, width);
  writeUInt32BE(20, height);
  return bytes;
}

test("terminalImageCacheKey is stable and version-scoped", () => {
  const { terminalImageCacheKey } = terminalImage();

  assert.equal(terminalImageCacheKey("s1", 7, "3"), "s1:7:3");
  assert.notEqual(terminalImageCacheKey("s1", 7, "3"), terminalImageCacheKey("s1", 7, "4"));
});

test("terminalImageBackoffDelayMs grows exponentially and saturates", () => {
  const { terminalImageBackoffDelayMs, TERMINAL_IMAGE_BACKOFF_BASE_MS, TERMINAL_IMAGE_BACKOFF_MAX_MS } =
    terminalImage();

  assert.equal(terminalImageBackoffDelayMs(0), TERMINAL_IMAGE_BACKOFF_BASE_MS);
  assert.equal(terminalImageBackoffDelayMs(1), TERMINAL_IMAGE_BACKOFF_BASE_MS);
  assert.equal(terminalImageBackoffDelayMs(2), TERMINAL_IMAGE_BACKOFF_BASE_MS * 2);
  assert.equal(terminalImageBackoffDelayMs(3), TERMINAL_IMAGE_BACKOFF_BASE_MS * 4);
  assert.equal(terminalImageBackoffDelayMs(50), TERMINAL_IMAGE_BACKOFF_MAX_MS);
});

test("validateTerminalImagePlacement converts screen-relative lines to absolute", () => {
  const { validateTerminalImagePlacement } = terminalImage();

  const result = plain(validateTerminalImagePlacement(placement(), screen));
  assert.equal(result.absoluteLine, 1002);
  assert.equal(result.contentVersion, "3");
  assert.equal(result.key, "7:3:1002:0:4:10");
});

test("validateTerminalImagePlacement prefers the exact textual content version", () => {
  const { validateTerminalImagePlacement } = terminalImage();

  const exact = plain(
    validateTerminalImagePlacement(
      placement({ contentVersion: 3, contentVersionText: "18446744073709551615" }),
      screen
    )
  );
  assert.equal(exact.contentVersion, "18446744073709551615");

  // A malformed textual version falls back to the numeric one rather than
  // being trusted verbatim.
  const fallback = plain(
    validateTerminalImagePlacement(
      placement({ contentVersion: 3, contentVersionText: "0" }),
      screen
    )
  );
  assert.equal(fallback.contentVersion, "3");
});

test("validateTerminalImagePlacement accepts the retained-history slack window", () => {
  const { validateTerminalImagePlacement, TERMINAL_IMAGE_RETAINED_LINE_SLACK } = terminalImage();

  // A placement above the emitted window (negative line) is legitimate: the
  // host scans its whole retained history, not just the emitted lines.
  assert.ok(validateTerminalImagePlacement(placement({ line: -TERMINAL_IMAGE_RETAINED_LINE_SLACK }), screen));
  assert.equal(
    validateTerminalImagePlacement(
      placement({ line: -TERMINAL_IMAGE_RETAINED_LINE_SLACK - 1 }),
      screen
    ),
    null
  );
  assert.ok(
    validateTerminalImagePlacement(
      placement({ line: screen.lines.length + TERMINAL_IMAGE_RETAINED_LINE_SLACK - 1 }),
      screen
    )
  );
  assert.equal(
    validateTerminalImagePlacement(
      placement({ line: screen.lines.length + TERMINAL_IMAGE_RETAINED_LINE_SLACK }),
      screen
    ),
    null
  );
});

test("validateTerminalImagePlacement rejects malformed and out-of-bounds entries", () => {
  const { validateTerminalImagePlacement } = terminalImage();

  for (const [label, raw] of [
    ["null", null],
    ["non-object", "nope"],
    ["missing image id", placement({ imageId: undefined })],
    ["fractional image id", placement({ imageId: 1.5 })],
    ["image id out of range", placement({ imageId: 0x1000000 })],
    ["no usable version", placement({ contentVersion: 0, contentVersionText: "x" })],
    ["zero rows", placement({ rows: 0 })],
    ["too many rows", placement({ rows: 1025 })],
    ["zero columns", placement({ columns: 0 })],
    ["negative column", placement({ column: -1 })],
    ["overflows the right edge", placement({ column: 75, columns: 10 })],
    ["fractional line", placement({ line: 1.5 })],
  ]) {
    assert.equal(validateTerminalImagePlacement(raw, screen), null, `${label} must be rejected`);
  }

  assert.equal(
    validateTerminalImagePlacement(placement(), { cols: 80, lines: [] }),
    null,
    "a screen without a firstLine cannot produce an absolute line"
  );
});

test("buildTerminalImagePlacements dedupes, drops invalid entries, and caps", () => {
  const { buildTerminalImagePlacements, TERMINAL_IMAGE_MAX_PLACEMENTS } = terminalImage();

  const built = plain(
    buildTerminalImagePlacements({
      ...screen,
      images: [placement(), placement(), placement({ imageId: 8 }), placement({ rows: 0 })],
    })
  );
  assert.equal(built.length, 2, "identical placements collapse and invalid ones are dropped");
  assert.deepStrictEqual(
    built.map((entry) => entry.imageId),
    [7, 8]
  );

  const flood = [];
  for (let index = 1; index <= TERMINAL_IMAGE_MAX_PLACEMENTS + 25; index += 1) {
    flood.push(placement({ imageId: index }));
  }
  const capped = plain(buildTerminalImagePlacements({ ...screen, images: flood }));
  assert.equal(capped.length, TERMINAL_IMAGE_MAX_PLACEMENTS);
  assert.equal(capped[0].imageId, 1, "the cap keeps the first placements in wire order");

  assert.deepStrictEqual(plain(buildTerminalImagePlacements({ ...screen, images: "nope" })), []);
});

test("validateTerminalImagePngBytes checks the signature, IHDR, and bounds", () => {
  const { validateTerminalImagePngBytes, TERMINAL_IMAGE_MAX_DIMENSION } = terminalImage();

  assert.deepStrictEqual(plain(validateTerminalImagePngBytes(pngBytes())), { width: 4, height: 4 });
  assert.equal(validateTerminalImagePngBytes(null), null);
  assert.equal(validateTerminalImagePngBytes(new Uint8Array(8)), null, "too short to hold an IHDR");

  const badSignature = pngBytes();
  badSignature[1] = 0x00;
  assert.equal(validateTerminalImagePngBytes(badSignature), null);

  assert.equal(validateTerminalImagePngBytes(pngBytes({ type: "IDAT" })), null);
  assert.equal(validateTerminalImagePngBytes(pngBytes({ chunkLength: 12 })), null);
  assert.equal(validateTerminalImagePngBytes(pngBytes({ width: 0 })), null);
  assert.equal(
    validateTerminalImagePngBytes(pngBytes({ width: TERMINAL_IMAGE_MAX_DIMENSION + 1 })),
    null
  );
  assert.ok(
    validateTerminalImagePngBytes(pngBytes({ width: TERMINAL_IMAGE_MAX_DIMENSION, height: 3906 })),
    "the largest image inside both the dimension and pixel budgets is accepted"
  );
  assert.equal(
    validateTerminalImagePngBytes(pngBytes({ width: TERMINAL_IMAGE_MAX_DIMENSION, height: 3907 })),
    null,
    "in-bounds dimensions still lose to the total pixel budget"
  );
});
