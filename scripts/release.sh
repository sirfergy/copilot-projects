#!/usr/bin/env bash
# Build a distributable Copilot Projects.app and (optionally) publish a GitHub
# release with a drag-to-Applications DMG.
#
#   scripts/release.sh 0.1.0            # build dist/Copilot-Projects-0.1.0.dmg locally
#   scripts/release.sh 0.1.0 --publish  # also create the GitHub release + tag
#
# --publish uses the active `gh` account; run it as the account that owns $REPO.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REPO="${GITHUB_REPOSITORY:-sirfergy/copilot-projects}"
APP_NAME="Copilot Projects"

VERSION=""
PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    -*) echo "unknown arg: $arg" >&2; exit 1 ;;
    *)  VERSION="$arg" ;;
  esac
done
[ -n "$VERSION" ] || { echo "usage: scripts/release.sh <version> [--publish]" >&2; exit 1; }
VERSION="${VERSION#v}"   # accept either 0.1.0 or v0.1.0
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "error: version must be X.Y.Z (optionally prefixed with v)" >&2
  exit 1
}
TAG="v$VERSION"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# Prefer a stable Developer ID Application identity (keeps macOS permission grants
# across builds and is required to notarize). Override by setting CODESIGN_IDENTITY,
# or CODESIGN_IDENTITY=- to force ad-hoc for a throwaway local build.
if [ -z "$CODESIGN_IDENTITY" ]; then
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
  CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
fi

if [ "$PUBLISH" = "1" ]; then
  [[ "$CODESIGN_IDENTITY" == Developer\ ID\ Application:* ]] || {
    echo "error: --publish requires CODESIGN_IDENTITY='Developer ID Application: …'" >&2
    exit 1
  }
  security find-identity -v -p codesigning | grep -Fq "\"$CODESIGN_IDENTITY\"" || {
    echo "error: codesigning identity not found: $CODESIGN_IDENTITY" >&2
    exit 1
  }
  [ -n "$NOTARY_PROFILE" ] || {
    echo "error: --publish requires NOTARY_PROFILE" >&2
    exit 1
  }
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null
fi

# SwiftPM + git need this when the user's global git sets safe.bareRepository=explicit.
GIT_CONFIG_INDEX="${GIT_CONFIG_COUNT:-0}"
export "GIT_CONFIG_KEY_$GIT_CONFIG_INDEX=safe.bareRepository"
export "GIT_CONFIG_VALUE_$GIT_CONFIG_INDEX=all"
export GIT_CONFIG_COUNT="$((GIT_CONFIG_INDEX + 1))"

echo "==> building release app (v$VERSION)"
VERSION="$VERSION" CODESIGN_IDENTITY="$CODESIGN_IDENTITY" \
  ./scripts/build-app.sh --release

APP="$ROOT/dist/$APP_NAME.app"
[ -d "$APP" ] || { echo "error: $APP missing after build" >&2; exit 1; }

echo "==> packaging DMG"
DMG="$ROOT/dist/Copilot-Projects-$VERSION.dmg"
STAGING="$(mktemp -d)"
NOTES_FILE=""
APP_ZIP=""
RELEASE_CREATED=0
cleanup() {
  status=$?
  if [ "$status" -ne 0 ] && [ "$RELEASE_CREATED" = "1" ]; then
    cleanup_partial_release
  fi
  rm -rf "$STAGING"
  [ -z "$NOTES_FILE" ] || rm -f "$NOTES_FILE"
  [ -z "$APP_ZIP" ] || rm -f "$APP_ZIP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$CODESIGN_IDENTITY" != "-" ] && [ -n "$NOTARY_PROFILE" ]; then
  echo "==> notarizing app"
  APP_ZIP="$ROOT/dist/Copilot-Projects-$VERSION.zip"
  rm -f "$APP_ZIP"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  xcrun notarytool submit "$APP_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=4 "$APP"
fi

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # drag-to-install target
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
if [ "$CODESIGN_IDENTITY" != "-" ] && [ -n "$NOTARY_PROFILE" ]; then
  echo "==> signing and notarizing DMG"
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
fi
echo "  $DMG"

if [ "$PUBLISH" = "0" ]; then
  echo "==> built locally (no --publish). To publish the GitHub release:"
  echo "    scripts/release.sh $VERSION --publish"
  exit 0
fi

command -v gh >/dev/null || { echo "error: gh CLI not found" >&2; exit 1; }

echo "==> publishing GitHub release $TAG to $REPO"
SHA="$(git rev-parse HEAD)"
NOTES_FILE="$(mktemp)"
cat > "$NOTES_FILE" <<NOTES
## Install

1. Download \`Copilot-Projects-$VERSION.dmg\` below and open it.
2. Drag **Copilot Projects** onto **Applications**.
3. Launch it normally. The app and DMG are Developer ID signed, notarized, and stapled.

Requires macOS 26+ on Apple Silicon.
NOTES

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "error: release $TAG already exists" >&2
  exit 1
fi
if gh api "repos/$REPO/git/ref/tags/$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists in $REPO" >&2
  exit 1
fi

cleanup_partial_release() {
  if [ "$(gh release view "$TAG" --repo "$REPO" --json isDraft --jq .isDraft 2>/dev/null || true)" = "true" ]; then
    gh release delete "$TAG" --repo "$REPO" --yes --cleanup-tag >/dev/null 2>&1 || true
  fi
}
RELEASE_CREATED=1
gh release create "$TAG" \
  --repo "$REPO" \
  --target "$SHA" \
  --title "Copilot Projects $VERSION" \
  --notes-file "$NOTES_FILE" \
  --draft
gh release upload "$TAG" "$DMG" --repo "$REPO"
gh release edit "$TAG" --repo "$REPO" --draft=false
RELEASE_CREATED=0

echo "==> done: https://github.com/$REPO/releases/tag/$TAG"
