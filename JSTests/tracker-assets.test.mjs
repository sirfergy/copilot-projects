import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";
import { trackerResourceDir } from "./support/tracker.mjs";

const extension = join(trackerResourceDir, "extension.mjs");

test("the tracker extension is a valid ES module", () => {
  assert.doesNotThrow(() => execFileSync(process.execPath, ["--check", extension]));
});

// Copilot CLI 1.0.113 renamed the SDK package it resolves for extensions.
for (const sdk of ["@microsoft/copilot-sdk/extension", "@github/copilot-sdk/extension"]) {
  test(`the tracker joins the session of a Copilot CLI that provides ${sdk}`, () => {
    const fakeSDK = `
      import { writeSync } from "node:fs";
      export const joinSession = () => {
        writeSync(1, "joined");
        process.exit(0);
      };
    `;
    const loader = `
      import { registerHooks } from "node:module";
      registerHooks({
        resolve(specifier, context, nextResolve) {
          if (specifier !== ${JSON.stringify(sdk)}) return nextResolve(specifier, context);
          return { url: ${JSON.stringify(`data:text/javascript,${encodeURIComponent(fakeSDK)}`)}, shortCircuit: true };
        },
      });
      await import(${JSON.stringify(pathToFileURL(extension).href)});
    `;
    assert.equal(
      execFileSync(process.execPath, ["--input-type=module", "-e", loader], {
        encoding: "utf8",
        // Without a home the tracker finds no native helper to run before it joins.
        env: { ...process.env, HOME: "" },
      }),
      "joined"
    );
  });
}
