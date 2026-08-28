import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import vm from "node:vm";

import {
  assembledJavaScript,
  fragmentOrder,
  joinJavaScriptFragments,
  readFragment,
  repositoryRoot,
  trackerResourceDir,
  webResourceDir,
} from "./support/fragments.mjs";

const webAssetsFacade = join(repositoryRoot, "Sources/copilot-projects/RemoteWebAssets.swift");

test("every web asset the facade serves exists as a packaged file", () => {
  const required = [
    join(webResourceDir, "index.html"),
    join(webResourceDir, "app.css"),
    join(webResourceDir, "app.webmanifest"),
    join(webResourceDir, "service-worker.js"),
    join(trackerResourceDir, "extension.mjs"),
    ...fragmentOrder.map((name) => join(webResourceDir, "js", `${name}.js`)),
  ];
  for (const path of required) {
    assert.ok(existsSync(path), `${path} is missing`);
    assert.ok(readFileSync(path, "utf8").length > 0, `${path} is empty`);
  }
});

test("packaged text assets end with exactly one trailing newline", () => {
  // `PackagedResource.text` drops a single trailing newline so the loaded value
  // matches the literals these files were extracted from. The facade restores
  // one safe boundary between fragments; a file with two (or zero) trailing
  // newlines would silently change the reviewed source bytes.
  for (const name of fragmentOrder) {
    const source = readFragment(name);
    assert.ok(source.endsWith("\n"), `${name}.js must end with a newline`);
    assert.ok(!source.endsWith("\n\n"), `${name}.js must not end with a blank line`);
  }
});

test("no Swift string-literal scaffolding leaked into the extracted assets", () => {
  const paths = [
    join(webResourceDir, "index.html"),
    join(webResourceDir, "app.css"),
    join(webResourceDir, "service-worker.js"),
    join(trackerResourceDir, "extension.mjs"),
    ...fragmentOrder.map((name) => join(webResourceDir, "js", `${name}.js`)),
  ];
  for (const path of paths) {
    const source = readFileSync(path, "utf8");
    assert.ok(!source.includes('#"""'), `${path} still contains a Swift raw-literal opener`);
    assert.ok(!source.includes('"""#'), `${path} still contains a Swift raw-literal closer`);
    assert.ok(!source.includes("\\#("), `${path} still contains Swift interpolation`);
  }
});

test("the Swift facade and the resource directory agree on fragment order", () => {
  const facade = readFileSync(webAssetsFacade, "utf8");
  const declared = [...facade.matchAll(/=\s*script\("([^"]+)"\)/g)].map((match) => match[1]);
  assert.deepStrictEqual(
    declared,
    fragmentOrder,
    "RemoteWebAssets.javascript's fragment order drifted from JSTests' expectation"
  );
});

test("the assembled /app.js response parses as a single script", () => {
  const assembled = assembledJavaScript();
  assert.doesNotThrow(() => new vm.Script(assembled, { filename: "app.js" }));
});

test("fragment seams end line comments before the next script", () => {
  const context = {};
  vm.runInNewContext(joinJavaScriptFragments([
    "globalThis.firstLoaded = true; // trailing comment\n",
    "globalThis.secondLoaded = true;\n",
  ]), context);
  assert.equal(context.firstLoaded, true);
  assert.equal(context.secondLoaded, true);
});

test("the tracker extension is a valid ES module", () => {
  const extension = join(trackerResourceDir, "extension.mjs");
  // `--check` parses only: the extension is never evaluated here, so no SDK
  // session is joined and nothing is installed by the unit tests.
  assert.doesNotThrow(() => execFileSync(process.execPath, ["--check", extension]));
  const source = readFileSync(extension, "utf8");
  assert.ok(
    source.includes('from "@github/copilot-sdk/extension"'),
    "the extension must still join the Copilot CLI session"
  );
});

test("the web manifest is valid JSON that points at the packaged icons", () => {
  const manifest = JSON.parse(readFileSync(join(webResourceDir, "app.webmanifest"), "utf8"));
  assert.ok(Array.isArray(manifest.icons) && manifest.icons.length > 0);
  for (const icon of manifest.icons) {
    assert.ok(typeof icon.src === "string" && icon.src.length > 0);
  }
});

test("the service worker parses as a classic script", () => {
  const source = readFileSync(join(webResourceDir, "service-worker.js"), "utf8");
  assert.doesNotThrow(() => new vm.Script(source, { filename: "service-worker.js" }));
});
