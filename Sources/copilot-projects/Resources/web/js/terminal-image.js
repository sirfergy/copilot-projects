// A wire placement's `line`/`column` are relative to the emitted screen
// (see RemoteTerminalImagePlacement's doc comment); the host's full
// retained-history scan can report a placement above or below the
// emitted `lines` window, bounded by this same slack the host itself
// tolerates, so a client must accept (not reject) that bounded range
// rather than only ever trusting in-window placements.
const TERMINAL_IMAGE_RETAINED_LINE_SLACK = 1024;
// Mirrors the host's own `remoteKittyMaxEmittedPlacements` cap
// (RemoteKittyGraphics.swift) as defense-in-depth against a malformed or
// hostile payload, never relying solely on the host to have enforced it.
const TERMINAL_IMAGE_MAX_PLACEMENTS = 64;
const TERMINAL_IMAGE_MAX_RENDERED_NODES = 8;
const TERMINAL_IMAGE_FETCH_TIMEOUT_MS = 15_000;
const TERMINAL_IMAGE_MAX_IN_FLIGHT = 16;
const TERMINAL_IMAGE_MAX_RESPONSE_BYTES = 5 * 1024 * 1024;
const TERMINAL_IMAGE_MAX_POSITIVE_CACHE_ENTRIES = 16;
const TERMINAL_IMAGE_MAX_POSITIVE_CACHE_BYTES = 24 * 1024 * 1024;
const TERMINAL_IMAGE_MAX_NEGATIVE_CACHE_ENTRIES = 128;
const TERMINAL_IMAGE_MAX_BACKOFF_ENTRIES = 128;
const TERMINAL_IMAGE_MAX_DECODED_PIXELS = 16_000_000;
const TERMINAL_IMAGE_MAX_DIMENSION = 4096;
const TERMINAL_IMAGE_MAX_PIXELS = 16_000_000;
// Conversation inline-image transient-failure retry (capacity/backoff).
const CONVERSATION_IMAGE_RETRY_MS = 1_500;
const CONVERSATION_IMAGE_MAX_RETRIES = 3;
const TERMINAL_IMAGE_BACKOFF_BASE_MS = 1000;
const TERMINAL_IMAGE_BACKOFF_MAX_MS = 30_000;

function terminalImageCacheKey(sessionId, imageId, version) {
  return `${sessionId}:${imageId}:${version}`;
}

function terminalImageBackoffDelayMs(failureCount) {
  const exponent = Math.max(0, failureCount - 1);
  return Math.min(
    TERMINAL_IMAGE_BACKOFF_BASE_MS * (2 ** exponent),
    TERMINAL_IMAGE_BACKOFF_MAX_MS
  );
}

// Validates one wire placement against the *emitted* screen it arrived
// with (never a cached/prior screen), converting its screen-relative
// `line` to an absolute, scroll-invariant line number. Returns `null` for
// anything unsafe rather than throwing, so one bad entry can't break the
// rest of an otherwise-valid authoritative array.
function validateTerminalImagePlacement(raw, screen) {
  if (!raw || typeof raw !== 'object') return null;
  const { imageId, contentVersion, contentVersionText, line, column, rows, columns } = raw;
  if (!Number.isSafeInteger(imageId) || imageId < 1 || imageId > 0xFFFFFF) return null;
  const exactVersion = typeof contentVersionText === 'string'
    && /^[1-9][0-9]{0,19}$/.test(contentVersionText)
    ? contentVersionText
    : (Number.isSafeInteger(contentVersion) && contentVersion > 0
      ? String(contentVersion) : null);
  if (!exactVersion) return null;
  if (!Number.isSafeInteger(rows) || rows <= 0 || rows > 1024) return null;
  if (!Number.isSafeInteger(columns) || columns <= 0) return null;
  if (!Number.isSafeInteger(column) || column < 0) return null;
  if (!Number.isSafeInteger(line)) return null;
  const linesLength = Array.isArray(screen?.lines) ? screen.lines.length : 0;
  const lowerBound = -TERMINAL_IMAGE_RETAINED_LINE_SLACK;
  const upperBound = linesLength + TERMINAL_IMAGE_RETAINED_LINE_SLACK;
  if (line < lowerBound || line >= upperBound) return null;
  const rightEdge = column + columns;
  if (!Number.isSafeInteger(rightEdge) || rightEdge > screen.cols) return null;
  if (!Number.isSafeInteger(screen?.firstLine)) return null;
  const absoluteLine = screen.firstLine + line;
  if (!Number.isSafeInteger(absoluteLine)) return null;
  const bottomEdge = absoluteLine + rows;
  if (!Number.isSafeInteger(bottomEdge)) return null;
  return {
    imageId,
    contentVersion: exactVersion,
    absoluteLine,
    column,
    rows,
    columns,
    key: `${imageId}:${exactVersion}:${absoluteLine}:${column}:${rows}:${columns}`
  };
}

// Deterministic validate + dedupe + cap: processes the wire array in
// order, keeps the first occurrence of each distinct placement, and stops
// once the cap is reached — so the same input always yields the same
// output regardless of platform/engine.
function buildTerminalImagePlacements(screen) {
  const raw = Array.isArray(screen?.images) ? screen.images : [];
  const seen = new Set();
  const result = [];
  for (const item of raw) {
    if (result.length >= TERMINAL_IMAGE_MAX_PLACEMENTS) break;
    const placement = validateTerminalImagePlacement(item, screen);
    if (!placement || seen.has(placement.key)) continue;
    seen.add(placement.key);
    result.push(placement);
  }
  return result;
}

// Structural PNG validation performed on the raw bytes *before* they're
// ever wrapped in a Blob/object URL or handed to the browser's own image
// decoder: signature, a well-formed IHDR immediately following it, and
// sane/bounded dimensions. Returns `{width, height}` or `null`.
function validateTerminalImagePngBytes(bytes) {
  if (!bytes || typeof bytes.length !== 'number' || bytes.length < 8 + 8 + 13) return null;
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (let index = 0; index < 8; index += 1) {
    if (bytes[index] !== signature[index]) return null;
  }
  const readUInt32BE = (offset) => (
    (bytes[offset] * 0x1000000)
    + (bytes[offset + 1] << 16)
    + (bytes[offset + 2] << 8)
    + bytes[offset + 3]
  );
  const chunkLength = readUInt32BE(8);
  const chunkType = String.fromCharCode(bytes[12], bytes[13], bytes[14], bytes[15]);
  if (chunkType !== 'IHDR' || chunkLength !== 13) return null;
  const width = readUInt32BE(16);
  const height = readUInt32BE(20);
  if (!(width > 0) || !(height > 0)) return null;
  if (width > TERMINAL_IMAGE_MAX_DIMENSION || height > TERMINAL_IMAGE_MAX_DIMENSION) return null;
  const pixels = width * height;
  if (!Number.isSafeInteger(pixels) || pixels > TERMINAL_IMAGE_MAX_PIXELS) return null;
  return { width, height };
}

// Streams a fetch `Response` body into a single `Uint8Array`, rejecting
// as soon as either a declared `Content-Length` or the actual streamed
// total exceeds `maxBytes` — a chunked/unknown-length response can't
// bypass the cap simply by omitting the header.
async function readBoundedTerminalImageBody(response, maxBytes) {
  const declaredLength = Number(response.headers?.get?.('content-length'));
  if (Number.isFinite(declaredLength) && declaredLength > maxBytes) {
    throw new Error('terminal-image-too-large');
  }
  const reader = response.body?.getReader ? response.body.getReader() : null;
  if (!reader) {
    const buffer = await response.arrayBuffer();
    if (buffer.byteLength > maxBytes) throw new Error('terminal-image-too-large');
    return new Uint8Array(buffer);
  }
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel().catch(() => {});
      throw new Error('terminal-image-too-large');
    }
    chunks.push(value);
  }
  const combined = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    combined.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return combined;
}

// Fetches and fully validates one image's exact PNG bytes. Throws an
// `Error` tagged `error.code`: `'not-found'` only for an exact HTTP 404
// (permanently cacheable — the host never repurposes an `(imageId,
// version)` pair), `'transient'` for everything else recoverable (5xx,
// unexpected content type, oversized/streamed-cap, structurally invalid
// PNG) so callers apply a bounded cooldown instead of a permanent
// negative cache entry.
async function fetchTerminalImageBytes(baseURL, sessionId, imageId, version, signal) {
  const query = new URLSearchParams({
    s: sessionId, i: String(imageId), v: String(version)
  });
  const response = await fetch(`${baseURL}terminal-image?${query.toString()}`, {
    signal,
    credentials: 'same-origin'
  });
  if (response.status === 404) {
    const error = new Error('terminal-image-not-found');
    error.code = 'not-found';
    throw error;
  }
  if (!response.ok) {
    const error = new Error(`terminal-image-http-${response.status}`);
    error.code = 'transient';
    throw error;
  }
  const contentType = (response.headers?.get?.('content-type') || '').toLowerCase();
  if (contentType && !contentType.startsWith('image/png')) {
    const error = new Error('terminal-image-unexpected-content-type');
    error.code = 'transient';
    throw error;
  }
  let bytes;
  try {
    bytes = await readBoundedTerminalImageBody(response, TERMINAL_IMAGE_MAX_RESPONSE_BYTES);
  } catch {
    const error = new Error('terminal-image-too-large');
    error.code = 'transient';
    throw error;
  }
  const dimensions = validateTerminalImagePngBytes(bytes);
  if (!dimensions) {
    const error = new Error('terminal-image-invalid-png');
    error.code = 'transient';
    throw error;
  }
  return { bytes, width: dimensions.width, height: dimensions.height };
}
