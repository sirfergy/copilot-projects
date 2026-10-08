#!/usr/bin/env bash
# Smoke-test an assembled Copilot Projects.app: prove the SwiftPM resource
# bundles the runtime loads are actually inside the app, resolvable from the
# exact paths PackagedResource searches, and byte-identical to the reviewed
# sources, and that the nested Copilot Pull Requests app is intact and signed.
#
#   scripts/verify-app-resources.sh ["/path/to/Copilot Projects.app"]
#
# Runs entirely from `/`, so nothing here can accidentally pass because the
# process happened to be started in the package directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/bundle-resources.sh"
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

for bundle in "$CORE_BUNDLE"; do
  if [ ! -d "$bundle" ]; then
    echo "error: missing packaged resource bundle $bundle" >&2
    echo "       (scripts/build-app.sh copies these into Contents/Resources)" >&2
    exit 1
  fi
done
CORE_RESOURCES="$(bundle_resources "$CORE_BUNDLE")"

# A resource bundle at the .app root would mean the app is relying on SwiftPM's
# Bundle.module main-bundle path instead of its own sealed Resources directory.
for stray in "$APP"/*.bundle; do
  [ -e "$stray" ] || continue
  echo "error: unexpected resource bundle at the app root: $stray" >&2
  exit 1
done

# path-inside-the-app : matching source file
PACKAGED=(
  "$CORE_RESOURCES/tracker/extension.mjs:$ROOT/Sources/CopilotProjectsCore/Resources/tracker/extension.mjs"
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
  node --check "$CORE_RESOURCES/tracker/extension.mjs"
  echo "ok: packaged JavaScript parses"
else
  echo "note: node not found; skipped the packaged JavaScript syntax check" >&2
fi

# Copilot Pull Requests ships nested in the app, with its own identity and icon.
plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}
PR_APP="$APP/Contents/Helpers/Copilot Pull Requests.app"
PR_INFO="$PR_APP/Contents/Info.plist"
if [ ! -f "$PR_INFO" ]; then
  echo "error: missing nested app $PR_APP" >&2
  exit 1
fi
HOST_ID="$(plist_value "$APP/Contents/Info.plist" CFBundleIdentifier)"
PR_ID="$(plist_value "$PR_INFO" CFBundleIdentifier)"
if [ -z "$HOST_ID" ] || [ "$PR_ID" != "$HOST_ID.pull-requests" ]; then
  echo "error: Copilot Pull Requests has bundle id '$PR_ID', expected '$HOST_ID.pull-requests'" >&2
  exit 1
fi
if [ "$(plist_value "$PR_INFO" CopilotProjectsHostBundleIdentifier)" != "$HOST_ID" ]; then
  echo "error: Copilot Pull Requests doesn't name its host's bundle id" >&2
  exit 1
fi
PR_EXE="$PR_APP/Contents/MacOS/$(plist_value "$PR_INFO" CFBundleExecutable)"
if [ "$PR_EXE" = "$PR_APP/Contents/MacOS/" ] || [ ! -x "$PR_EXE" ]; then
  echo "error: Copilot Pull Requests executable is missing or not executable: $PR_EXE" >&2
  exit 1
fi
PR_ICON="$PR_APP/Contents/Resources/$(plist_value "$PR_INFO" CFBundleIconFile).icns"
if [ ! -s "$PR_ICON" ]; then
  echo "error: Copilot Pull Requests icon is missing: $PR_ICON" >&2
  exit 1
fi
codesign --verify --strict "$PR_APP"
echo "ok: $PR_APP"

"$APP/Contents/MacOS/copilot-projects" check-assets

echo "All packaged resources present in $APP"
