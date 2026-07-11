---
name: release-copilot-projects
description: Use when updating, testing, installing, or releasing this Copilot Projects macOS app — phrases like "publish a Copilot Projects release", "install the latest app", "bump the version", "ship the terminal app", or "release these changes".
---

# Release Copilot Projects

Use the repository's existing tests, build script, release script, and Release
Actions workflow. Do not recreate signing, packaging, notarization, or publishing
logic in ad hoc shell commands.

## Release contract

- Repository: `sirfergy/copilot-projects`
- Supported release target: macOS 26+ on Apple Silicon
- Primary publisher: `.github/workflows/release.yml`
- Local fallback: `scripts/release.sh`
- Release only a commit reachable from `origin/main`
- Every release gets a new semantic version and immutable `vX.Y.Z` tag

## Workflow

### 1. Fetch and inspect

```bash
git fetch origin main --quiet
git status --short --branch
gh pr list -R sirfergy/copilot-projects --state open
```

Do not pull, rebase, or switch a dirty checkout. Use a dedicated worktree for
implementation or local release validation.

If release changes are still on an open PR, invoke `manage-pr` and finish that PR
before publishing.

### 2. Choose the version

```bash
gh release view --repo sirfergy/copilot-projects \
  --json tagName,publishedAt,url
```

Default to a patch bump for fixes and a minor bump for a meaningful feature set.
Never overwrite an existing tag or release asset.

### 3. Validate

From a clean worktree at `origin/main`:

```bash
swift test
git --no-pager diff --check
./scripts/build-app.sh --release
"dist/Copilot Projects.app/Contents/MacOS/copilot-projects" version
```

For rendering, activity-state, remote-terminal, or notification changes, also
launch the local build and exercise the affected CLI/socket/UI path.

### 4. Publish through Actions

The primary path runs tests on the macOS 26 Apple Silicon runner, then delegates
to `scripts/release.sh` for signing, notarization, stapling, packaging, and
publishing.

```bash
trap 'gh auth switch --hostname github.com --user obvioussean >/dev/null 2>&1' EXIT
gh auth switch --hostname github.com --user sirfergy

LAST_RUN_ID="$(gh run list -R sirfergy/copilot-projects \
  --workflow release.yml --branch main --event workflow_dispatch \
  --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
gh workflow run release.yml \
  --repo sirfergy/copilot-projects \
  --ref main \
  -f version=X.Y.Z

RUN_ID=""
for _ in {1..12}; do
  RUN_ID="$(gh run list -R sirfergy/copilot-projects \
    --workflow release.yml --branch main --event workflow_dispatch \
    --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
  if [ -n "$RUN_ID" ] && [ "$RUN_ID" != "$LAST_RUN_ID" ]; then break; fi
  RUN_ID=""
  sleep 5
done
[ -n "$RUN_ID" ] || { echo "release workflow run did not appear" >&2; exit 1; }
gh run watch "$RUN_ID" -R sirfergy/copilot-projects --exit-status
```

Verify the new tag targets the intended `origin/main` commit and the release has
the expected DMG asset.

### 5. Local fallback

Use only when the Actions runner or signing configuration is unavailable:

```bash
CODESIGN_IDENTITY="Developer ID Application: ..." \
NOTARY_PROFILE="copilot-projects-notary" \
./scripts/release.sh X.Y.Z --publish
```

The script must fail closed for ad-hoc signing, notarization, stapling, or
Gatekeeper failures. Never put signing credentials in the repository, a PR, or
shell history.

### 6. Install the exact published release

Download the DMG from the new GitHub release rather than installing an unrelated
local build. Quit the running app, replace `/Applications/Copilot Projects.app`,
launch it once, then verify:

```bash
copilot-projects version
copilot-projects ping
copilot-projects doctor
```

Preserve persisted projects, sessions, authenticated browser profiles, and the
generated Copilot extension during upgrades.

## Code-change path

When a release request includes implementation:

1. use a dedicated branch/worktree;
2. run pre-edit adversarial review for non-trivial behavior changes;
3. invoke `create-pr` before pushing/opening the PR;
4. after pushing, invoke `manage-pr`;
5. publish only after the PR merges and `origin/main` contains the intended
   commit.

## Boundaries

- Do not release from a dirty checkout, detached feature commit, or open PR head.
- Do not reuse an existing version/tag.
- Do not publish with the `obvioussean` work account.
- Do not weaken signing/notarization checks to make a release succeed.
