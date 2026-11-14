# Launching a Fleet (Workflow Steps 1–3)

Load this before launching child sessions in Parallel Fleet Coordination mode, and read all three steps before running the first command.

`SKILL_DIR` is the directory the skill's `SKILL.md` was loaded from (for example `~/.copilot/skills/coordinate-copilot-sessions` or `<repo>/.github/skills/coordinate-copilot-sessions`).

## 1. Resolve target project & pre-create disjoint worktrees

Resolve the target Copilot Projects project ID (defaults to `$COPILOT_PROJECTS_PROJECT`, or looks up / creates a named project):

```bash
# Current project from $COPILOT_PROJECTS_PROJECT (or active project in list-projects):
PROJECT_ID=$(python3 "$SKILL_DIR/scripts/coordinator.py" resolve-project)

# Named project (adds --create to create it if missing):
PROJECT_ID=$(python3 "$SKILL_DIR/scripts/coordinator.py" resolve-project --name "Reliability" --create)
```

For parallel coding tracks on the same repository, **always fetch `origin` first** (never trust a cached `origin/main` or `origin/master` ref), pin `BASE_SHA` from the freshly fetched remote-tracking ref, and pre-create a separate worktree and branch (`../<repo>-<slug>`) with a **disjoint file scope** for each track so sessions never contend on the same checkout or files or build against stale signatures/flags:

```bash
git -C "$REPO_DIR" fetch --quiet origin "+refs/heads/$BASE:refs/remotes/origin/$BASE" || exit 1
BASE_SHA=$(git -C "$REPO_DIR" rev-parse --verify "refs/remotes/origin/$BASE^{commit}") || exit 1
git -C "$REPO_DIR" worktree add -b "$HEAD_BRANCH" "$WORKTREE" "$BASE_SHA" || exit 1
```

## 2. Write self-contained child prompt files (`<= 8192` bytes)

Write one UTF-8 prompt file per track in the coordinator's session `files/` directory using [`references/child-prompt-template.md`](child-prompt-template.md). Every child prompt must be `<= 8192` bytes and include:
- Exact worktree path, repository, base branch + `BASE_SHA`, head branch, and GitHub account (when multiple `gh` accounts are configured).
- Strict non-overlapping file scope (`ONLY modify/create these paths`).
- Premise verification check (stop without opening a PR if disproven or already fixed).
- Explicit **anti-bloat / anti-over-engineering** contract (`<= 15` net production lines when addressing review feedback; prefer deleting/simplifying over adding guards/fallbacks/abstractions).
- Mandatory validation + PR lifecycle (targeted tests/linters, local review, opening the PR, and driving it through code review, CI, and `gh pr ready`).

## 3. Stagger session launches sequentially

Launch one session at a time, waiting for each session to reach `running` in `list-status` before launching the next. When launched in the same project on a grouping-capable `copilot-projects` build, spawned child sessions automatically group under the coordinator session via `$COPILOT_PROJECTS_SESSION` (or you can pass `--parent-session <id>` / `--no-parent` explicitly; `launch` and `launch-batch` record the requested `parent_session_id` in their JSON output and fall back to launching without the flag if an older `copilot-projects` binary rejects `--parent-session` / `--no-parent`). If `launch` exits with `read failed (errno 35)` under high load, the session was usually still created: poll `status` for the request ID printed in the error instead of relaunching. The session ID is that ID in upper case; use it as `status` prints it.

```bash
# Single session (blocks until session transitions to running):
python3 "$SKILL_DIR/scripts/coordinator.py" launch \
  --project "$PROJECT_ID" \
  --title "Track 1: ..." \
  --prompt-file "$SESSION_FILES/prompt-1.md"

# Or launch a batch sequentially from a JSON manifest:
python3 "$SKILL_DIR/scripts/coordinator.py" launch-batch \
  --project "$PROJECT_ID" \
  --manifest "$SESSION_FILES/launch-manifest.json"
```

`launch-manifest.json` format:
```json
[
  {
    "title": "Track 1: ...",
    "prompt_file": "/abs/path/to/prompt-1.md",
    "worktree": "/abs/path/to/repo-track-1"
  }
]
```
