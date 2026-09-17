import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:http";
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
  const server = createServer(async (request, response) => {
    let body = "";
    for await (const chunk of request) body += chunk;
    const input = JSON.parse(body || "{}");
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
