import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { crc32, deflateSync } from "node:zlib";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import test from "node:test";

// Opt-in, offline wire-contract test against an installed CLI/SDK pair.
test("native workflow RPCs target the requested session", {
  skip: !process.env.COPILOT_WORKFLOW_SDK,
  timeout: 60_000,
}, async (t) => {
  const { CopilotClient, RuntimeConnection, ToolSet } = await import(
    pathToFileURL(join(process.env.COPILOT_WORKFLOW_SDK, "index.js")).href
  );
  const root = await mkdtemp(join(tmpdir(), "copilot-workflow-rpc-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  execFileSync("git", ["init", "--quiet", root]);
  const requests = [];
  const server = createServer(async (request, response) => {
    let body = "";
    for await (const chunk of request) body += chunk;
    const input = JSON.parse(body || "{}");
    requests.push(input);
    const id = "offline-workflow-fixture";
    if (input.stream) {
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      response.write(`data: ${JSON.stringify({
        id, object: "chat.completion.chunk", model: "fixture",
        choices: [{ index: 0, delta: { role: "assistant", content: "fixture" }, finish_reason: null }],
      })}\n\n`);
      response.end(`data: ${JSON.stringify({
        id, object: "chat.completion.chunk", model: "fixture",
        choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
      })}\n\ndata: [DONE]\n\n`);
    } else {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify({
        id, object: "chat.completion", model: "fixture",
        choices: [{ index: 0, message: { role: "assistant", content: "fixture" }, finish_reason: "stop" }],
        usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
      }));
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const client = new CopilotClient({
    connection: RuntimeConnection.forStdio({
      path: process.env.COPILOT_WORKFLOW_CLI || "copilot",
    }),
    mode: "empty",
    useLoggedInUser: false,
    baseDirectory: join(root, "copilot-home"),
    workingDirectory: root,
  });
  await client.start();
  t.after(() => client.stop());
  const config = {
    model: "fixture",
    availableTools: new ToolSet(),
    modelCapabilities: {
      supports: { vision: true },
      limits: { vision: { supported_media_types: ["image/png", "image/jpeg"],
        max_prompt_images: 4, max_prompt_image_size: 2097152 } },
    },
    workingDirectory: root,
    provider: {
      type: "openai",
      baseUrl: `http://127.0.0.1:${server.address().port}/v1`,
      apiKey: "offline-fixture",
      wireApi: "completions",
    },
  };
  const first = await client.createSession(config);
  const second = await client.createSession(config);
  const connection = first.connection;
  const call = (method, params = {}) => connection.sendRequest(method, {
    sessionId: second.sessionId, ...params,
  });
  const metadata = await call("session.metadata.snapshot");
  assert.equal(metadata.sessionId, second.sessionId);
  assert.equal(metadata.isRemote, false);
  assert.ok(Object.hasOwn(metadata, "sessionLimits"));
  await call("session.options.update", { sessionLimits: { maxAiCredits: 30 } });
  assert.equal((await call("session.metadata.snapshot")).sessionLimits.maxAiCredits, 30);
  assert.equal((await first.rpc.metadata.snapshot()).sessionLimits, null);
  for (const mode of ["enqueue", "immediate"]) {
    const idle = new Promise((resolve) => {
      const unsubscribe = second.on("session.idle", () => {
        unsubscribe();
        resolve();
      });
    });
    const result = await call("session.send", {
      prompt: `Reply fixture ${mode}. Do not use tools.`, mode,
    });
    assert.equal(typeof result.messageId, "string");
    await idle;
  }
  const events = await second.getEvents();
  assert.equal(events.filter((event) =>
    event.type === "user.message" && event.data.content.startsWith("Reply fixture")
  ).length, 2);
  assert.equal((await first.getEvents()).some((event) =>
    event.type === "user.message" && event.data.content.startsWith("Reply fixture")
  ), false);
  // Exercise the real protocol's maximum frame, not merely a tiny image or
  // a session event which could report acceptance after silently omitting it.
  const png = maximumScreenshotPNG();
  assert.equal(png.length, 2097152);
  for (const mode of ["enqueue", "immediate"]) {
    const idle = new Promise((resolve) => {
      const unsubscribe = second.on("session.idle", () => { unsubscribe(); resolve(); });
    });
    const before = requests.length;
    await call("session.send", {
      prompt: `Inspect all four screenshots (${mode}).`, mode,
      attachments: Array.from({ length: 4 }, (_, i) => ({
        type: "blob", mimeType: "image/png", displayName: `Screenshot-${i}.png`,
        data: png.toString("base64"),
      })),
    });
    await idle;
    const images = requests.slice(before).flatMap((request) => request.messages ?? [])
      .filter((message) => message.role === "user" && Array.isArray(message.content))
      .at(-1)?.content.filter((part) => part.type === "image_url") ?? [];
    assert.equal(images.length, 4, "all image bytes must reach the provider");
    assert.ok(images.every((image) => image.image_url.url.startsWith("data:image/png;base64,")));
  }
  const metrics = await call("session.usage.getMetrics");
  assert.equal(typeof metrics.totalUserRequests, "number");
  const abort = await call("session.abort");
  assert.equal(typeof abort.success, "boolean");
  const expiredBudget = await call("session.ui.handlePendingSessionLimitsExhausted", {
    requestId: "not-pending", response: { action: "cancel" },
  });
  assert.equal(expiredBudget.success, false);
  await call("session.options.update", { sessionLimits: null });
  assert.equal((await call("session.metadata.snapshot")).sessionLimits, null);
  console.log("Verified runtime:", await client.getStatus());
});

test("live selected model matches its own image-capability catalog", {
  skip: !process.env.COPILOT_WORKFLOW_SDK || !process.env.COPILOT_WORKFLOW_MODEL,
  timeout: 60_000,
}, async (t) => {
  const { CopilotClient, RuntimeConnection, ToolSet } = await import(
    pathToFileURL(join(process.env.COPILOT_WORKFLOW_SDK, "index.js")).href
  );
  const root = await mkdtemp(join(tmpdir(), "copilot-image-model-"));
  const client = new CopilotClient({
    connection: RuntimeConnection.forStdio({ path: process.env.COPILOT_WORKFLOW_CLI || "copilot" }),
    mode: "empty", useLoggedInUser: true, baseDirectory: root, workingDirectory: root,
  });
  t.after(async () => {
    await client.stop();
    await rm(root, { recursive: true, force: true });
  });
  await client.start();
  const session = await client.createSession({
    model: process.env.COPILOT_WORKFLOW_MODEL, availableTools: new ToolSet(), workingDirectory: root,
  });
  const current = await session.connection.sendRequest("session.model.getCurrent", { sessionId: session.sessionId });
  const catalog = await session.connection.sendRequest("session.model.list", { sessionId: session.sessionId });
  assert.equal(typeof current.modelId, "string");
  assert.ok(current.modelId.length > 0);
  const selected = catalog.list.find((model) => model.id === current.modelId);
  assert.ok(selected, "selected model must be found by ID, not display name");
  assert.equal(selected.capabilities?.supports?.vision, true);
  const limits = selected.capabilities?.limits?.vision;
  assert.ok(limits.max_prompt_images > 0);
  assert.ok(limits.max_prompt_image_size > 0);
  assert.ok(limits.supported_media_types.includes("image/png"));
});

function maximumScreenshotPNG() {
  function chunk(type, bytes) {
    const body = Buffer.concat([Buffer.from(type), bytes]);
    const length = Buffer.alloc(4), checksum = Buffer.alloc(4);
    length.writeUInt32BE(bytes.length); checksum.writeUInt32BE(crc32(body));
    return Buffer.concat([length, body, checksum]);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(700, 0); header.writeUInt32BE(700, 4);
  header[8] = 8; header[9] = 6;
  const pixels = Buffer.alloc((700 * 4 + 1) * 700);
  let random = 1234567;
  for (let y = 0; y < 700; y++) {
    for (let x = 1; x <= 2800; x++) {
      random = (Math.imul(random, 1664525) + 1013904223) >>> 0;
      pixels[y * 2801 + x] = random >>> 24;
    }
  }
  const parts = [Buffer.from("89504e470d0a1a0a", "hex"), chunk("IHDR", header),
    chunk("IDAT", deflateSync(pixels))];
  const end = chunk("IEND", Buffer.alloc(0));
  const padding = Buffer.alloc(2097152 - Buffer.concat(parts).length - end.length - 12, 65);
  padding.write("Comment\0");
  return Buffer.concat([...parts, chunk("tEXt", padding), end]);
}
