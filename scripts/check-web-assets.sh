#!/usr/bin/env bash
# Syntax-check the packaged web/extension assets and run the Node unit tests
# that exercise the pure client helpers.
#
#   scripts/check-web-assets.sh
#
# These assets are plain files under Sources/*/Resources, so this runs without
# building anything Swift.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WEB="Sources/copilot-projects/Resources/web"
TRACKER="Sources/CopilotProjectsCore/Resources/tracker"
# The order RemoteWebAssets.javascript concatenates in.
FRAGMENTS=(markdown draft operations control-delivery session-creation terminal-image transcript main)

if ! command -v node >/dev/null 2>&1; then
  echo "error: node is required to check the web assets" >&2
  exit 1
fi
NODE_VERSION="$(node -p 'process.versions.node')"
IFS=. read -r NODE_MAJOR NODE_MINOR _ <<<"$NODE_VERSION"
if (( NODE_MAJOR < 22 || (NODE_MAJOR == 22 && NODE_MINOR < 15) )); then
  echo "error: Node 22.15+ is required for the JavaScript test hooks (found $NODE_VERSION)" >&2
  exit 1
fi

echo "==> node --check on packaged assets"
node --check "$TRACKER/extension.mjs"
node --check "$WEB/service-worker.js"
for fragment in "${FRAGMENTS[@]}"; do
  node --check "$WEB/js/$fragment.js"
done

echo "==> node --check on the assembled /app.js response"
WORK="$ROOT/.build/js-asset-check"
mkdir -p "$WORK"
# Mirrors PackagedResource.text + RemoteWebAssets.javascript: each fragment
# loses its single trailing newline, then the fragments are joined with a
# newline boundary so a trailing `//` comment cannot swallow the next file.
node --input-type=module -e '
import { mkdirSync, writeFileSync } from "node:fs";
import { assembledJavaScript } from "./JSTests/support/fragments.mjs";
mkdirSync(".build/js-asset-check", { recursive: true });
writeFileSync(".build/js-asset-check/app.js", assembledJavaScript());
'
node --check "$WORK/app.js"

echo "==> node --test JSTests"
node --test "JSTests/**/*.test.mjs"
