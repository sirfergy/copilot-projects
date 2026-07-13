#!/usr/bin/env bash
# Assemble Copilot Projects.app from the SwiftPM build product.
#
#   scripts/build-app.sh            # debug build -> dist/Copilot Projects.app
#   scripts/build-app.sh --release  # release build
#   scripts/build-app.sh --launch   # build then open the app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="debug"
LAUNCH=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG="release" ;;
    --debug)   CONFIG="debug" ;;
    --launch)  LAUNCH=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

APP_NAME="Copilot Projects"
# Bundle id carries the project name. It is also the UserDefaults domain (saved
# sidebar width, window frame); LegacyDefaults.migrateIfNeeded() copies the old
# domain across on first launch so those survive the rename. macOS keys
# notification authorization to the bundle id, so it re-prompts once.
BUNDLE_ID="com.obvioussean.copilot-projects"
EXE_NAME="copilot-projects"

# SwiftPM, and the version derivation below, need this when the user's global
# git sets safe.bareRepository=explicit.
GIT_CONFIG_INDEX="${GIT_CONFIG_COUNT:-0}"
export "GIT_CONFIG_KEY_$GIT_CONFIG_INDEX=safe.bareRepository"
export "GIT_CONFIG_VALUE_$GIT_CONFIG_INDEX=all"
export GIT_CONFIG_COUNT="$((GIT_CONFIG_INDEX + 1))"

git_describe_version_tag() {
  local tag describe commits best_describe="" best_commits=""

  while IFS= read -r tag; do
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    describe="$(git describe --tags --long --match "$tag" 2>/dev/null)" || continue
    commits="${describe#*-}"
    commits="${commits%%-*}"
    [[ "$commits" =~ ^[0-9]+$ ]] || continue

    if [ -z "$best_commits" ] || [ "$commits" -lt "$best_commits" ]; then
      best_describe="$describe"
      best_commits="$commits"
    fi
  done < <(git for-each-ref --merged HEAD --sort=-creatordate --format='%(refname:short)' refs/tags 2>/dev/null)

  [ -n "$best_describe" ] || return 1
  printf '%s\n' "$best_describe"
}

# Version: an explicit VERSION (e.g. from release.sh) wins for both strings.
# Otherwise derive from the latest git tag so local/dev builds are versioned
# correctly instead of silently falling back to 0.1.0. The marketing string is
# the tag; the build string uses Apple's development suffix so a dev build off
# a release is distinguishable from the tagged release itself.
if [ -n "${VERSION:-}" ]; then
  SHORT_VERSION="$VERSION"
  BUILD_VERSION="$VERSION"
elif DESCRIBE="$(git_describe_version_tag)"; then
  SHORT_VERSION="${DESCRIBE#v}"; SHORT_VERSION="${SHORT_VERSION%%-*}"   # e.g. 0.8.3
  COMMITS="${DESCRIBE#*-}"; COMMITS="${COMMITS%%-*}"                    # e.g. 3
  if [ "${COMMITS:-0}" -gt 0 ] 2>/dev/null; then
    if [ "$COMMITS" -gt 255 ]; then
      echo "error: $COMMITS commits since v$SHORT_VERSION exceeds CFBundleVersion's development suffix limit; set VERSION explicitly." >&2
      exit 1
    fi
    BUILD_VERSION="${SHORT_VERSION}d${COMMITS}"                        # e.g. 0.8.3d3
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
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
  CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
RESOURCE_BUILD_DIR="$BUILD_DIR"
APP_DIR="$ROOT/dist/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
HELPER_APP="$CONTENTS/Helpers/Copilot Projects Link.app"
HELPER_CONTENTS="$HELPER_APP/Contents"
HELPER_MACOS="$HELPER_CONTENTS/MacOS"

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RES" "$HELPER_MACOS"

cp "$BUILD_DIR/$EXE_NAME" "$MACOS/$EXE_NAME"
cp "$BUILD_DIR/copilot-projects-link" "$HELPER_MACOS/copilot-projects-link"

# App icon
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"
fi
for icon in PWAIcon-192.png PWAIcon-512.png; do
  if [ -f "$ROOT/Resources/$icon" ]; then
    cp "$ROOT/Resources/$icon" "$RES/$icon"
  fi
done

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

# Keep the source resource bundle as a fallback, and compile a default Metal
# library that Bundle.main can load without touching SwiftPM's developer-only
# absolute Bundle.module fallback path.
if [ -d "$RESOURCE_BUILD_DIR/SwiftTerm_SwiftTerm.bundle" ]; then
  cp -R "$RESOURCE_BUILD_DIR/SwiftTerm_SwiftTerm.bundle" "$RES/"
  SHADER_SOURCE="$RESOURCE_BUILD_DIR/SwiftTerm_SwiftTerm.bundle/Shaders.metal"
  if [ -f "$SHADER_SOURCE" ]; then
    echo "==> compiling SwiftTerm Metal shaders"
    SHADER_TMP="$(mktemp -d -t copilot-projects-shaders)"
    AIR_FILE="$SHADER_TMP/Shaders.air"
    xcrun -sdk macosx metal -std=metal3.0 -mmacosx-version-min=26.0 \
      -c "$SHADER_SOURCE" -o "$AIR_FILE"
    xcrun -sdk macosx metallib "$AIR_FILE" -o "$RES/default.metallib"
    rm -rf "$SHADER_TMP"
  fi
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

if [ "$CODESIGN_IDENTITY" = "-" ]; then
  echo "==> ad-hoc signing"
  SIGN_ARGS=(--force --sign -)
else
  echo "==> signing with $CODESIGN_IDENTITY"
  SIGN_ARGS=(--force --options runtime --timestamp --sign "$CODESIGN_IDENTITY")
fi
if [ -x "$CONTENTS/Helpers/dtach" ]; then
  codesign "${SIGN_ARGS[@]}" "$CONTENTS/Helpers/dtach"
fi
codesign "${SIGN_ARGS[@]}" "$HELPER_APP"
codesign "${SIGN_ARGS[@]}" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "App path:"
echo "  $APP_DIR"

if [ "$LAUNCH" = "1" ]; then
  open "$APP_DIR"
fi
