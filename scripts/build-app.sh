#!/usr/bin/env bash
# Assemble Copilot Projects.app from the SwiftPM build product.
#
#   scripts/build-app.sh            # debug build -> dist/Copilot Projects.app
#   scripts/build-app.sh --release  # release build
#   scripts/build-app.sh --launch   # build then open the app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/bundle-resources.sh"
source "$ROOT/scripts/release-version.sh"

CONFIG="debug"
LAUNCH=0
OVERRIDE_BINARY=""
EXTRA_RESOURCES=""
OUTPUT_APP=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --release) CONFIG="release" ;;
    --debug)   CONFIG="debug" ;;
    --launch)  LAUNCH=1 ;;
    --binary) OVERRIDE_BINARY="${2:?--binary needs an executable}"; shift ;;
    --resources) EXTRA_RESOURCES="${2:?--resources needs a directory}"; shift ;;
    --output) OUTPUT_APP="${2:?--output needs an .app path}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

APP_NAME="Copilot Projects"
# Bundle id carries the project name and is also the UserDefaults domain.
BUNDLE_ID="com.obvioussean.copilot-projects"
EXE_NAME="copilot-projects"

# SwiftPM, and the version derivation below, need this when the user's global
# git sets safe.bareRepository=explicit.
GIT_CONFIG_INDEX="${GIT_CONFIG_COUNT:-0}"
export "GIT_CONFIG_KEY_$GIT_CONFIG_INDEX=safe.bareRepository"
export "GIT_CONFIG_VALUE_$GIT_CONFIG_INDEX=all"
export GIT_CONFIG_COUNT="$((GIT_CONFIG_INDEX + 1))"

git_describe_version_tag() {
  local tag describe commits best_tags="" best_commits=""

  # Release tags are vYYYY.M.D.N or legacy vX.Y.Z.
  while IFS= read -r tag; do
    is_release_tag "$tag" || continue
    describe="$(git describe --tags --long --match "$tag" 2>/dev/null)" || continue
    commits="${describe#*-}"
    commits="${commits%%-*}"
    [[ "$commits" =~ ^[0-9]+$ ]] || continue

    if [ -z "$best_commits" ] || [ "$commits" -lt "$best_commits" ]; then
      best_tags="$tag"
      best_commits="$commits"
    elif [ "$commits" -eq "$best_commits" ]; then
      best_tags="$best_tags"$'\n'"$tag"
    fi
  done < <(git for-each-ref --merged HEAD --sort=-creatordate --format='%(refname:short)' refs/tags 2>/dev/null)

  [ -n "$best_tags" ] || return 1
  # Equally near tags (e.g. two releases of one commit) describe from the highest,
  # so a dev build never orders below a release it contains.
  tag="$(printf '%s\n' "$best_tags" | latest_release_tag)"
  git describe --tags --long --match "$tag" 2>/dev/null
}

git_worktree_is_dirty() {
  [ -n "$(git status --porcelain --untracked-files=normal --ignore-submodules 2>/dev/null)" ]
}

# Version: an explicit VERSION (e.g. from release.sh) wins for both strings.
# Otherwise derive from the latest git tag so local/dev builds are versioned
# correctly instead of silently falling back to 0.1.0. The marketing string is
# the tag; the build string uses Apple's development suffix so a dev build off
# a release is distinguishable from the tagged release itself. Compared
# numerically segment by segment, 2026.10.8.3d2 orders after v2026.10.8.3 and
# before any later release (2026.10.8.4, 2026.10.9.1), and legacy 0.9.121dN
# builds order below every date version.
if [ -n "${VERSION:-}" ]; then
  SHORT_VERSION="$VERSION"
  BUILD_VERSION="$VERSION"
elif DESCRIBE="$(git_describe_version_tag)"; then
  SHORT_VERSION="${DESCRIBE#v}"; SHORT_VERSION="${SHORT_VERSION%%-*}"   # e.g. 2026.10.8.3
  COMMITS="${DESCRIBE#*-}"; COMMITS="${COMMITS%%-*}"                    # e.g. 2
  DIRTY_OFFSET=0
  if git_worktree_is_dirty; then
    DIRTY_OFFSET=1
  fi
  DEV_COUNT=$((COMMITS + DIRTY_OFFSET))
  if [ "${DEV_COUNT:-0}" -gt 0 ] 2>/dev/null; then
    if [ "$DEV_COUNT" -gt 255 ]; then
      echo "error: $DEV_COUNT development versions since v$SHORT_VERSION exceeds CFBundleVersion's development suffix limit; set VERSION explicitly." >&2
      exit 1
    fi
    BUILD_VERSION="${SHORT_VERSION}d${DEV_COUNT}"                      # e.g. 2026.10.8.3d2
  else
    BUILD_VERSION="$SHORT_VERSION"
  fi
else
  SHORT_VERSION="0.1.0"
  BUILD_VERSION="0.1.0"
fi

# macOS keys granted permissions (TCC: Accessibility, Automation, Notifications,
# …) on the app's designated requirement, which includes the signing identity.
# An ad-hoc signature changes every build, so each local build looks like a new
# app and the user must re-grant everything. Default to a stable Developer ID
# Application identity when one is in the keychain so local builds keep their
# grants across rebuilds. Set CODESIGN_IDENTITY explicitly to override, or
# CODESIGN_IDENTITY=- to force ad-hoc.
CODESIGN_KEYCHAIN="${CODESIGN_KEYCHAIN:-}"
IDENTITY_ARGS=(-v -p codesigning)
if [ -n "$CODESIGN_KEYCHAIN" ]; then
  IDENTITY_ARGS+=("$CODESIGN_KEYCHAIN")
fi
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
  CODESIGN_IDENTITY="$(security find-identity "${IDENTITY_ARGS[@]}" 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
  if [ -n "$CODESIGN_KEYCHAIN" ] && [ -z "$CODESIGN_IDENTITY" ]; then
    echo "error: explicit signing keychain contains no Developer ID identity" >&2
    exit 1
  fi
  CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
RESOURCE_BUILD_DIR="$BUILD_DIR"
APP_DIR="${OUTPUT_APP:-$ROOT/dist/$APP_NAME.app}"
if [[ "$APP_DIR" != /* || "$APP_DIR" != *.app || "$APP_DIR" == "$ROOT" ]]; then
  echo "error: output must be an absolute .app path outside the repository root" >&2
  exit 1
fi
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
HELPER_APP="$CONTENTS/Helpers/Copilot Projects Link.app"
HELPER_CONTENTS="$HELPER_APP/Contents"
HELPER_MACOS="$HELPER_CONTENTS/MacOS"
# Copilot Pull Requests: the Pull Requests window as its own app, so it has its
# own Dock icon and ⌘Tab entry. Copilot Projects opens it from inside its bundle.
PR_APP_NAME="Copilot Pull Requests"
PR_EXE_NAME="copilot-pull-requests"
PR_APP="$CONTENTS/Helpers/$PR_APP_NAME.app"
PR_CONTENTS="$PR_APP/Contents"
PR_MACOS="$PR_CONTENTS/MacOS"
PR_RES="$PR_CONTENTS/Resources"
PR_ICON="$ROOT/Resources/PullRequestsIcon.icns"

if [ ! -s "$PR_ICON" ]; then
  echo "error: $PR_ICON is missing; run scripts/make-icns.sh" >&2
  exit 1
fi

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RES" "$HELPER_MACOS" "$PR_MACOS" "$PR_RES"

cp "${OVERRIDE_BINARY:-$BUILD_DIR/$EXE_NAME}" "$MACOS/$EXE_NAME"
cp "$BUILD_DIR/copilot-projects-link" "$HELPER_MACOS/copilot-projects-link"
cp "$BUILD_DIR/$PR_EXE_NAME" "$PR_MACOS/$PR_EXE_NAME"
chmod 755 "$PR_MACOS/$PR_EXE_NAME"
# The helper's own icon, in its own Resources, so the Dock and ⌘Tab show it.
cp "$PR_ICON" "$PR_RES/PullRequestsIcon.icns"

# App icon
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"
fi

# Build + bundle the dtach helper (resumability backend).
DTACH_SRC="$ROOT/vendor/dtach"
if [ -d "$DTACH_SRC" ]; then
  echo "==> building dtach helper (arm64)"
  ( cd "$DTACH_SRC"
    [ -f config.h ] || ./configure >/dev/null 2>&1
    clang -O2 -arch arm64 -I. -o dtach-arm64 \
      main.c master.c attach.c )
  if [ -f "$DTACH_SRC/dtach-arm64" ]; then
    mkdir -p "$CONTENTS/Helpers"
    cp "$DTACH_SRC/dtach-arm64" "$CONTENTS/Helpers/dtach"
    chmod +x "$CONTENTS/Helpers/dtach"
  else
    echo "warning: dtach build failed — resumability will fall back to plain shells"
  fi
fi

# SwiftTerm embeds its shader source and compiles it at runtime unless
# Bundle.main already has a default Metal library. Precompile that library from
# the resolved checkout so terminals skip the runtime compile.
SHADER_SOURCE="$ROOT/.build/checkouts/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal"
if [ ! -f "$SHADER_SOURCE" ]; then
  echo "error: $SHADER_SOURCE is missing; update build-app.sh for SwiftTerm's shader layout." >&2
  exit 1
fi
echo "==> compiling SwiftTerm Metal shaders"
SHADER_TMP="$(mktemp -d -t copilot-projects-shaders)"
AIR_FILE="$SHADER_TMP/Shaders.air"
xcrun -sdk macosx metal -std=metal3.0 -mmacosx-version-min=26.0 \
  -c "$SHADER_SOURCE" -o "$AIR_FILE"
xcrun -sdk macosx metallib "$AIR_FILE" -o "$RES/default.metallib"
rm -rf "$SHADER_TMP"

# SwiftPM resource bundles the standalone host loads at runtime.
# They are resolved from Contents/Resources only — there is no developer-path
# fallback — so a bundle that failed to make it into the .app must fail the
# build here rather than at first use on a user's machine.
REQUIRED_RESOURCE_BUNDLES=(
  "copilot-projects_CopilotProjectsCore.bundle"
)
for bundle in "${REQUIRED_RESOURCE_BUNDLES[@]}"; do
  if [ ! -d "$RESOURCE_BUILD_DIR/$bundle" ]; then
    echo "error: $RESOURCE_BUILD_DIR/$bundle is missing; the SwiftPM target lost its resources declaration." >&2
    exit 1
  fi
  rm -rf "$RES/$bundle"
  cp -R "$RESOURCE_BUILD_DIR/$bundle" "$RES/"
done

# The specific assets the runtime asks for by name, so a renamed or dropped file
# is caught while assembling instead of by a trap in the running app.
REQUIRED_RESOURCE_FILES=(
  "$(bundle_resources "$RES/copilot-projects_CopilotProjectsCore.bundle")/tracker/extension.mjs"
)
for required in "${REQUIRED_RESOURCE_FILES[@]}"; do
  if [ ! -s "$required" ]; then
    echo "error: packaged resource $required is missing or empty" >&2
    exit 1
  fi
done

if [ -n "$EXTRA_RESOURCES" ]; then
  if [ ! -d "$EXTRA_RESOURCES" ]; then
    echo "error: integration resource directory is missing: $EXTRA_RESOURCES" >&2
    exit 1
  fi
  cp -R "$EXTRA_RESOURCES/." "$RES/"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$EXE_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSMicrophoneUsageDescription</key><string>Copilot Projects needs microphone access so Copilot sessions running in its terminals can use voice input.</string>
</dict>
</plist>
PLIST

cat > "$HELPER_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Copilot Projects Link</string>
  <key>CFBundleExecutable</key><string>copilot-projects-link</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.link</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>$BUNDLE_ID.link</string>
      <key>CFBundleURLSchemes</key>
      <array><string>copilot-projects</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Same version as the host: the two ship and update together. The host's
# bundle id names the defaults domain that keeps the Owners setting.
cat > "$PR_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$PR_APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$PR_APP_NAME</string>
  <key>CFBundleExecutable</key><string>$PR_EXE_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.pull-requests</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>PullRequestsIcon</string>
  <key>CopilotProjectsHostBundleIdentifier</key><string>$BUNDLE_ID</string>
</dict>
</plist>
PLIST

if [ "$CODESIGN_IDENTITY" = "-" ]; then
  echo "==> ad-hoc signing"
  SIGN_ARGS=(--force --sign -)
else
  echo "==> signing with $CODESIGN_IDENTITY"
  SIGN_ARGS=(--force --options runtime --timestamp --sign "$CODESIGN_IDENTITY")
  if [ -n "$CODESIGN_KEYCHAIN" ]; then
    SIGN_ARGS+=(--keychain "$CODESIGN_KEYCHAIN")
  fi
fi

# Entitlements for the main app: microphone device access. Required under the
# hardened runtime (--options runtime) in addition to NSMicrophoneUsageDescription,
# so Copilot sessions spawned in the app's terminals — whose TCC mic prompts are
# attributed to this responsible app — can use the microphone. Written outside the
# .app bundle: --entitlements embeds it into the signature, so it must NOT be a
# sealed bundle resource (removing it post-sign would invalidate the signature).
ENTITLEMENTS="$(mktemp -t copilot-projects-entitlements.XXXXXX)"
trap 'rm -f "$ENTITLEMENTS"' EXIT
cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
PLIST

if [ -x "$CONTENTS/Helpers/dtach" ]; then
  codesign "${SIGN_ARGS[@]}" "$CONTENTS/Helpers/dtach"
fi
codesign "${SIGN_ARGS[@]}" "$HELPER_APP"
codesign "${SIGN_ARGS[@]}" "$PR_APP"
codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" "$APP_DIR"
rm -f "$ENTITLEMENTS"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
"$MACOS/$EXE_NAME" check-assets

echo "App path:"
echo "  $APP_DIR"

if [ "$LAUNCH" = "1" ]; then
  open "$APP_DIR"
fi
