#!/usr/bin/env bash
# Build a distributable Copilot Projects.app and (optionally) publish a GitHub
# release with a drag-to-Applications DMG.
#
#   scripts/release.sh 2026.10.8.1            # build dist/Copilot-Projects-2026.10.8.1.dmg locally
#   scripts/release.sh 2026.10.8.1 --publish  # also create the GitHub release + tag
#   GITHUB_REPOSITORY=owner/repo scripts/release.sh 2026.10.8.1 --project-root=/absolute/repo --publish
#
# Versions are YYYY.M.D.N (see scripts/release-version.sh).
# --publish uses the active `gh` account; run it as the account that owns $REPO.
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$SCRIPT_ROOT/scripts/release-version.sh"

REPO="${GITHUB_REPOSITORY:-sirfergy/copilot-projects}"
APP_NAME="Copilot Projects"

VERSION=""
PUBLISH=0
PROJECT_ROOT=""
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --project-root=*)
      PROJECT_ROOT="${arg#*=}"
      [[ "$PROJECT_ROOT" == /* ]] || {
        echo "error: --project-root requires an absolute repository path" >&2
        exit 1
      }
      [ -n "${GITHUB_REPOSITORY:-}" ] || {
        echo "error: --project-root requires an explicit GITHUB_REPOSITORY" >&2
        exit 1
      }
      ;;
    -*) echo "unknown arg: $arg" >&2; exit 1 ;;
    *)  VERSION="$arg" ;;
  esac
done
[ -n "$VERSION" ] || { echo "usage: scripts/release.sh <version> [--project-root=/absolute/repo] [--publish]" >&2; exit 1; }
VERSION="${VERSION#v}"   # accept either 2026.10.8.1 or v2026.10.8.1
is_date_release_version "$VERSION" || {
  echo "error: version must be YYYY.M.D.N without leading zeros (optionally prefixed with v)" >&2
  exit 1
}
TAG="v$VERSION"
# How long to keep waiting on one notary submission, and the pause between status
# checks. Apple's queue can sit far past a single `notarytool --wait`.
NOTARY_WAIT_MINUTES="${NOTARY_WAIT_MINUTES:-40}"
NOTARY_POLL_SECONDS="${NOTARY_POLL_SECONDS:-15}"
[[ "$NOTARY_WAIT_MINUTES" =~ ^[0-9]+$ && "$NOTARY_POLL_SECONDS" =~ ^[0-9]+$ ]] || {
  echo "error: NOTARY_WAIT_MINUTES and NOTARY_POLL_SECONDS must be whole numbers" >&2
  exit 1
}
# Force base 10 so a leading zero (e.g. 08) is not parsed as octal mid-release.
NOTARY_WAIT_MINUTES=$((10#$NOTARY_WAIT_MINUTES))
NOTARY_POLL_SECONDS=$((10#$NOTARY_POLL_SECONDS))

ROOT="$(cd "${PROJECT_ROOT:-$SCRIPT_ROOT}" && pwd -P)"
cd "$ROOT"
# Repository selectors inherited from a caller must not redirect the selected root.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

# SwiftPM + git need this when the user's global git sets safe.bareRepository=explicit.
GIT_CONFIG_INDEX="${GIT_CONFIG_COUNT:-0}"
export "GIT_CONFIG_KEY_$GIT_CONFIG_INDEX=safe.bareRepository"
export "GIT_CONFIG_VALUE_$GIT_CONFIG_INDEX=all"
export GIT_CONFIG_COUNT="$((GIT_CONFIG_INDEX + 1))"

verify_project_root() {
  local toplevel
  toplevel="$(git rev-parse --show-toplevel)" || return 1
  [ "$(cd "$toplevel" && pwd -P)" = "$ROOT" ] || {
    echo "error: project root must be the Git worktree root" >&2
    return 1
  }
  [ -x "$ROOT/scripts/build-app.sh" ] || {
    echo "error: project root must provide executable scripts/build-app.sh" >&2
    return 1
  }
}

verify_publish_source() {
  local direction urls url repository expected worktree_status
  verify_project_root || return 1
  [[ "$REPO" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9_.-]+$ ]] || {
    echo "error: GITHUB_REPOSITORY must be owner/repository" >&2
    return 1
  }
  expected="$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')"
  for direction in fetch push; do
    if [ "$direction" = fetch ]; then
      urls="$(git remote get-url --all origin)" || return 1
    else
      urls="$(git remote get-url --push --all origin)" || return 1
    fi
    while IFS= read -r url; do
      case "$url" in
        https://github.com/*) repository="${url#https://github.com/}" ;;
        git@github.com:*) repository="${url#git@github.com:}" ;;
        ssh://git@github.com/*) repository="${url#ssh://git@github.com/}" ;;
        *) echo "error: origin $direction URL must identify a GitHub repository" >&2; return 1 ;;
      esac
      repository="${repository%/}"
      repository="${repository%.git}"
      [ "$(printf '%s' "$repository" | tr '[:upper:]' '[:lower:]')" = "$expected" ] || {
        echo "error: origin $direction repository does not match GITHUB_REPOSITORY" >&2
        return 1
      }
    done <<< "$urls"
  done
  [ "$(git rev-parse HEAD)" = "$SHA" ] || {
    echo "error: project HEAD changed during release" >&2
    return 1
  }
  worktree_status="$(git status --porcelain --untracked-files=normal)" || return 1
  [ -z "$worktree_status" ] || {
    echo "error: --publish requires a clean project worktree" >&2
    return 1
  }
}

if [ -n "$PROJECT_ROOT" ]; then
  verify_project_root
fi
if [ "$PUBLISH" = "1" ]; then
  SHA="$(git rev-parse HEAD)"
  verify_publish_source
  git fetch origin main --quiet
  git merge-base --is-ancestor "$SHA" origin/main || {
    echo "error: refusing to publish $SHA because it is not on origin/main" >&2
    exit 1
  }
fi

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
CODESIGN_KEYCHAIN="${CODESIGN_KEYCHAIN:-}"
IDENTITY_ARGS=(-v -p codesigning)
if [ -n "$CODESIGN_KEYCHAIN" ]; then
  IDENTITY_ARGS+=("$CODESIGN_KEYCHAIN")
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-}"
NOTARY_ARGS=()

if [ -n "$NOTARY_PROFILE" ]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  if [ -n "$NOTARY_KEYCHAIN" ]; then
    NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
  fi
elif [ -n "$NOTARY_KEYCHAIN" ]; then
  echo "error: NOTARY_KEYCHAIN requires NOTARY_PROFILE" >&2
  exit 1
fi

# Prefer a stable Developer ID Application identity (keeps macOS permission grants
# across builds and is required to notarize). Override by setting CODESIGN_IDENTITY,
# or CODESIGN_IDENTITY=- to force ad-hoc for a throwaway local build.
if [ -z "$CODESIGN_IDENTITY" ]; then
  CODESIGN_IDENTITY="$(security find-identity "${IDENTITY_ARGS[@]}" 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
  if [ -n "$CODESIGN_KEYCHAIN" ] && [ -z "$CODESIGN_IDENTITY" ]; then
    echo "error: explicit signing keychain contains no Developer ID identity" >&2
    exit 1
  fi
  CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
fi

if [ "$PUBLISH" = "1" ]; then
  [[ "$CODESIGN_IDENTITY" == Developer\ ID\ Application:* ]] || {
    echo "error: --publish requires CODESIGN_IDENTITY='Developer ID Application: …'" >&2
    exit 1
  }
  security find-identity "${IDENTITY_ARGS[@]}" | grep -Fq "\"$CODESIGN_IDENTITY\"" || {
    echo "error: codesigning identity not found: $CODESIGN_IDENTITY" >&2
    exit 1
  }
  [ "${#NOTARY_ARGS[@]}" -gt 0 ] || {
    echo "error: --publish requires notarization credentials" >&2
    exit 1
  }
  xcrun notarytool history "${NOTARY_ARGS[@]}" >/dev/null
fi

echo "==> building release app (v$VERSION)"
VERSION="$VERSION" CODESIGN_IDENTITY="$CODESIGN_IDENTITY" CODESIGN_KEYCHAIN="$CODESIGN_KEYCHAIN" \
  ./scripts/build-app.sh --release

if [ "$PUBLISH" = "1" ]; then
  verify_publish_source
fi
APP="$ROOT/dist/$APP_NAME.app"
[ -d "$APP" ] || { echo "error: $APP missing after build" >&2; exit 1; }

echo "==> packaging DMG"
DMG="$ROOT/dist/Copilot-Projects-$VERSION.dmg"
STAGING="$(mktemp -d)"
NOTES_FILE=""
APP_ZIP=""
TAG_CREATED=0
RELEASE_CREATED=0
RELEASE_ID=""
cleanup() {
  status=$?
  if [ "$status" -ne 0 ] && [ "$TAG_CREATED" = "1" ]; then
    cleanup_partial_release
  fi
  rm -rf "$STAGING"
  [ -z "$NOTES_FILE" ] || rm -f "$NOTES_FILE"
  [ -z "$APP_ZIP" ] || rm -f "$APP_ZIP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Upload once, then keep waiting on that same submission until it settles or the
# budget runs out. Failing at the first timeout only makes the next attempt queue
# a fresh build behind the one Apple is still processing.
notarize() {
  local artifact="$1" submission id info status deadline slice
  submission="$(xcrun notarytool submit "$artifact" "${NOTARY_ARGS[@]}" --output-format json)"
  id="$(jq -er '.id | strings | select(length > 0)' <<< "$submission")" || {
    echo "error: notarytool submit returned no submission id for $artifact" >&2
    return 1
  }
  echo "  notary submission $id"
  deadline=$((SECONDS + NOTARY_WAIT_MINUTES * 60))
  while :; do
    # `wait` gives up at its own timeout while Apple keeps processing, so its exit
    # status is advisory; the submission's recorded status decides. Each wait is
    # capped at 5m and at whatever remains of the budget.
    slice=$((deadline - SECONDS))
    slice=$((slice > 300 ? 300 : slice < 1 ? 1 : slice))
    xcrun notarytool wait "$id" "${NOTARY_ARGS[@]}" --timeout "${slice}s" >/dev/null 2>&1 || true
    info="$(xcrun notarytool info "$id" "${NOTARY_ARGS[@]}" --output-format json)"
    status="$(jq -r '.status // empty' <<< "$info")"
    case "$status" in
      Accepted)
        echo "  notary submission $id accepted"
        return 0
        ;;
      "In Progress")
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo "error: notary submission $id still in progress after ${NOTARY_WAIT_MINUTES}m" >&2
          return 1
        fi
        echo "  notary submission $id still in progress"
        sleep "$NOTARY_POLL_SECONDS"
        ;;
      *)
        xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" >&2 || true
        echo "error: notary submission $id finished as ${status:-unknown}" >&2
        return 1
        ;;
    esac
  done
}
if [ "$CODESIGN_IDENTITY" != "-" ] && [ "${#NOTARY_ARGS[@]}" -gt 0 ]; then
  echo "==> notarizing app"
  APP_ZIP="$ROOT/dist/Copilot-Projects-$VERSION.zip"
  rm -f "$APP_ZIP"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  notarize "$APP_ZIP"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=4 "$APP"
fi

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # drag-to-install target
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
if [ "$CODESIGN_IDENTITY" != "-" ] && [ "${#NOTARY_ARGS[@]}" -gt 0 ]; then
  echo "==> signing and notarizing DMG"
  SIGN_ARGS=(--force --timestamp --sign "$CODESIGN_IDENTITY")
  if [ -n "$CODESIGN_KEYCHAIN" ]; then
    SIGN_ARGS+=(--keychain "$CODESIGN_KEYCHAIN")
  fi
  codesign "${SIGN_ARGS[@]}" "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
fi
echo "  $DMG"

if [ "$PUBLISH" = "0" ]; then
  echo "==> built locally (no --publish). To publish the GitHub release:"
  printf '    GITHUB_REPOSITORY=%q %q %q --project-root=%q --publish\n' \
    "$REPO" "$SCRIPT_ROOT/scripts/release.sh" "$VERSION" "$ROOT"
  exit 0
fi

command -v gh >/dev/null || { echo "error: gh CLI not found" >&2; exit 1; }

echo "==> publishing GitHub release $TAG to $REPO"
NOTES_FILE="$(mktemp)"
cat > "$NOTES_FILE" <<NOTES
## Install

1. Download \`Copilot-Projects-$VERSION.dmg\` below and open it.
2. Drag **Copilot Projects** onto **Applications**.
3. Launch it normally. The app and DMG are Developer ID signed, notarized, and stapled.

Requires macOS 26+ on Apple Silicon.
NOTES

delete_owned_tag() {
  local ref="refs/tags/$TAG"
  if git \
    -c credential.helper= \
    -c 'credential.helper=!gh auth git-credential' \
    push --porcelain \
    --force-with-lease="$ref:$SHA" \
    origin ":$ref" >/dev/null; then
    TAG_CREATED=0
    return 0
  fi
  echo "warning: preserving $TAG because the remote ref is absent or no longer owned by $SHA" >&2
  return 1
}

cleanup_partial_release() {
  local release_state releases match is_draft
  if [ "$RELEASE_CREATED" = "1" ]; then
    [ -n "$RELEASE_ID" ] || return
    release_state="$(
      gh api "repos/$REPO/releases/$RELEASE_ID"
    )" || return
    if [ "$(jq -r '.draft' <<< "$release_state")" = "true" ]; then
      if gh api -X DELETE "repos/$REPO/releases/$RELEASE_ID" >/dev/null 2>&1; then
        delete_owned_tag || true
        RELEASE_CREATED=0
      fi
    fi
    return
  fi

  # This run owns only the tag. Never delete a release that another publisher
  # may have created for the same name; delete the tag only when no published
  # release currently owns it.
  releases="$(
    gh api --paginate --slurp "repos/$REPO/releases?per_page=100"
  )" || return
  match="$(
    jq -c --arg tag "$TAG" \
      '[.[][] | select(.tag_name == $tag)][0] // empty' \
      <<< "$releases"
  )"
  if [ -z "$match" ]; then
    delete_owned_tag || true
    return
  fi
  is_draft="$(jq -r '.draft' <<< "$match")"
  if [ "$is_draft" = "true" ]; then
    delete_owned_tag || true
  fi
}

# Legacy vX.Y.Z tags remain predecessors; date tags always order above them.
latest_remote_release_tag() {
  local refs
  refs="$(git ls-remote --tags --refs origin 'v*')" || return 1
  awk '{ sub("^refs/tags/", "", $2); print $2 }' <<< "$refs" | latest_release_tag
}

remote_tag_commit() {
  local refs direct peeled
  refs="$(
    git ls-remote --tags origin \
      "refs/tags/$1" \
      "refs/tags/$1^{}"
  )" || return 1
  direct="$(awk '$2 !~ /\^\{\}$/ { print $1; exit }' <<< "$refs")"
  peeled="$(awk '$2 ~ /\^\{\}$/ { print $1; exit }' <<< "$refs")"
  printf '%s\n' "${peeled:-$direct}"
}

release_is_complete() {
  local release expected_asset
  expected_asset="Copilot-Projects-${1#v}.dmg"
  release="$(
    gh release view "$1" \
      --repo "$REPO" \
      --json assets,isDraft,publishedAt
  )" || return 1
  jq -e --arg asset "$expected_asset" \
    '.isDraft == false
     and .publishedAt != null
     and any(.assets[]; .name == $asset and .size > 0)' \
    <<< "$release" >/dev/null
}

verify_expected_predecessor() {
  if [ -n "${EXPECTED_PREVIOUS_TAG:-}" ]; then
    local latest_tag latest_sha expected_sha
    latest_tag="$(latest_remote_release_tag)" || {
      echo "error: could not list remote release tags" >&2
      return 1
    }
    latest_sha="$(remote_tag_commit "$latest_tag")" || return 1
    git fetch origin "refs/tags/$latest_tag" --quiet || {
      echo "error: could not fetch latest release tag $latest_tag" >&2
      return 1
    }
    git merge-base --is-ancestor "$latest_sha" origin/main || {
      echo "error: latest release $latest_tag is not on origin/main" >&2
      return 1
    }
    expected_sha="${EXPECTED_PREVIOUS_SHA:-}"
    if [ "$latest_tag" = "$EXPECTED_PREVIOUS_TAG" ]; then
      [ -n "$expected_sha" ] && [ "$latest_sha" = "$expected_sha" ] || {
        echo "error: predecessor $EXPECTED_PREVIOUS_TAG moved from ${expected_sha:-unknown} to $latest_sha" >&2
        return 1
      }
      release_is_complete "$latest_tag" || {
        echo "error: predecessor release $latest_tag is no longer complete" >&2
        return 1
      }
      return 0
    fi
    if git merge-base --is-ancestor "$SHA" "$latest_sha" \
      && release_is_complete "$latest_tag"; then
      echo "==> superseded by complete descendant release $latest_tag"
      return 2
    fi
    echo "error: latest release changed from $EXPECTED_PREVIOUS_TAG to ${latest_tag:-none}" >&2
    return 1
  fi
  return 0
}
# Revalidate immediately before publishing so a queued/manual run cannot release
# a commit that was force-pushed off main while tests, signing, or notarization ran.
verify_publish_source
git fetch origin main --quiet
git merge-base --is-ancestor "$SHA" origin/main || {
  echo "error: refusing to publish $SHA because it is no longer on origin/main" >&2
  exit 1
}
if verify_expected_predecessor; then
  :
else
  predecessor_status=$?
  [ "$predecessor_status" -eq 2 ] && exit 0
  exit "$predecessor_status"
fi
if ! existing_release="$(
  gh release view "$TAG" \
    --repo "$REPO" \
    --json databaseId,isDraft
)"; then
  releases="$(
    gh api --paginate --slurp "repos/$REPO/releases?per_page=100"
  )" || {
    echo "error: could not verify whether release $TAG already exists" >&2
    exit 1
  }
  existing_release="$(
    jq -c --arg tag "$TAG" \
      '[.[][] | select(.tag_name == $tag)][0] // empty' \
      <<< "$releases"
  )"
fi
if [ -n "$existing_release" ]; then
  echo "error: release $TAG already exists" >&2
  exit 1
fi
if gh api "repos/$REPO/git/ref/tags/$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists in $REPO" >&2
  exit 1
fi
gh api -X POST "repos/$REPO/git/refs" \
  -f ref="refs/tags/$TAG" \
  -f sha="$SHA" >/dev/null
TAG_CREATED=1
release_response="$(
  gh api -X POST "repos/$REPO/releases" \
    -f tag_name="$TAG" \
    -f target_commitish="$SHA" \
    -f name="Copilot Projects $VERSION" \
    -f body="$(cat "$NOTES_FILE")" \
    -F draft=true
)"
RELEASE_ID="$(jq -er '.id | numbers' <<< "$release_response")"
RELEASE_CREATED=1
UPLOAD_URL="$(jq -er '.upload_url | sub("\\{.*$"; "")' <<< "$release_response")"
API_TOKEN="${GH_TOKEN:-$(gh auth token)}"
curl --fail-with-body --location \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -H "Content-Type: application/x-apple-diskimage" \
  --data-binary "@$DMG" \
  "$UPLOAD_URL?name=$(basename "$DMG")" >/dev/null
gh api -X PATCH "repos/$REPO/releases/$RELEASE_ID" -F draft=false >/dev/null
TAG_CREATED=0
RELEASE_CREATED=0
RELEASE_ID=""

echo "==> done: https://github.com/$REPO/releases/tag/$TAG"
