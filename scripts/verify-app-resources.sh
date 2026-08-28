#!/usr/bin/env bash
# Smoke-test an assembled Copilot Projects.app: prove the SwiftPM resource
# bundles the runtime loads are actually inside the app, resolvable from the
# exact paths PackagedResource searches, and byte-identical to the reviewed
# sources.
#
#   scripts/verify-app-resources.sh ["/path/to/Copilot Projects.app"]
#
# Runs entirely from `/`, so nothing here can accidentally pass because the
# process happened to be started in the package directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/dist/Copilot Projects.app}"

if [ ! -d "$APP" ]; then
  echo "error: $APP does not exist; run scripts/build-app.sh first" >&2
  exit 1
fi
APP="$(cd "$APP" && pwd)"
RES="$APP/Contents/Resources"

# Prove cwd independence: the loader must never fall back to a relative path.
cd /

CORE_BUNDLE="$RES/copilot-projects_CopilotProjectsCore.bundle"
WEB_BUNDLE="$RES/copilot-projects_copilot-projects.bundle"

for bundle in "$CORE_BUNDLE" "$WEB_BUNDLE"; do
  if [ ! -d "$bundle" ]; then
    echo "error: missing packaged resource bundle $bundle" >&2
    echo "       (scripts/build-app.sh copies these next to SwiftTerm_SwiftTerm.bundle)" >&2
    exit 1
  fi
done

# A resource bundle at the .app root would mean the app is relying on SwiftPM's
# Bundle.module main-bundle path instead of its own sealed Resources directory.
for stray in "$APP"/*.bundle; do
  [ -e "$stray" ] || continue
  echo "error: unexpected resource bundle at the app root: $stray" >&2
  exit 1
done

# path-inside-the-app : matching source file
PACKAGED=(
  "$RES/PWAIcon-192.png:$ROOT/Resources/PWAIcon-192.png"
  "$RES/PWAIcon-512.png:$ROOT/Resources/PWAIcon-512.png"
  "$CORE_BUNDLE/tracker/extension.mjs:$ROOT/Sources/CopilotProjectsCore/Resources/tracker/extension.mjs"
  "$WEB_BUNDLE/web/index.html:$ROOT/Sources/copilot-projects/Resources/web/index.html"
  "$WEB_BUNDLE/web/app.css:$ROOT/Sources/copilot-projects/Resources/web/app.css"
  "$WEB_BUNDLE/web/app.webmanifest:$ROOT/Sources/copilot-projects/Resources/web/app.webmanifest"
  "$WEB_BUNDLE/web/service-worker.js:$ROOT/Sources/copilot-projects/Resources/web/service-worker.js"
  "$WEB_BUNDLE/web/js/markdown.js:$ROOT/Sources/copilot-projects/Resources/web/js/markdown.js"
  "$WEB_BUNDLE/web/js/draft.js:$ROOT/Sources/copilot-projects/Resources/web/js/draft.js"
  "$WEB_BUNDLE/web/js/operations.js:$ROOT/Sources/copilot-projects/Resources/web/js/operations.js"
  "$WEB_BUNDLE/web/js/session-creation.js:$ROOT/Sources/copilot-projects/Resources/web/js/session-creation.js"
  "$WEB_BUNDLE/web/js/terminal-image.js:$ROOT/Sources/copilot-projects/Resources/web/js/terminal-image.js"
  "$WEB_BUNDLE/web/js/transcript.js:$ROOT/Sources/copilot-projects/Resources/web/js/transcript.js"
  "$WEB_BUNDLE/web/js/main.js:$ROOT/Sources/copilot-projects/Resources/web/js/main.js"
)

for entry in "${PACKAGED[@]}"; do
  packaged="${entry%%:*}"
  source_file="${entry#*:}"
  if [ ! -s "$packaged" ]; then
    echo "error: packaged resource missing or empty: $packaged" >&2
    exit 1
  fi
  if ! cmp -s "$packaged" "$source_file"; then
    echo "error: packaged resource differs from its source: $packaged" >&2
    exit 1
  fi
  echo "ok: $packaged"
done

if command -v node >/dev/null 2>&1; then
  node --check "$CORE_BUNDLE/tracker/extension.mjs"
  for script in "$WEB_BUNDLE"/web/js/*.js "$WEB_BUNDLE/web/service-worker.js"; do
    node --check "$script"
  done
  echo "ok: packaged JavaScript parses"
else
  echo "note: node not found; skipped the packaged JavaScript syntax check" >&2
fi

"$APP/Contents/MacOS/copilot-projects" check-assets

echo "All packaged resources present in $APP"
