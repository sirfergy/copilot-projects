# Monitoring, Steering & Auditing Child Sessions (Workflow Steps 4–5)

Load this on every tick of the coordinator's `manage_schedule` and before sending a follow-up to a child session. Hard Rule numbers refer to [`SKILL.md`](../SKILL.md).

`SKILL_DIR` is the directory the skill's `SKILL.md` was loaded from (for example `~/.copilot/skills/coordinate-copilot-sessions` or `<repo>/.github/skills/coordinate-copilot-sessions`). `PROJECT_ID` is resolved in step 1 ([`references/launch.md`](launch.md)).

## 4. Monitor progress & steer child sessions via `send-session-prompt`

Check all sessions and their worktrees (read-only):

```bash
python3 "$SKILL_DIR/scripts/coordinator.py" status --project "$PROJECT_ID"
```

When a child session needs a follow-up (e.g., it went `idle` before opening/cleaning its PR, needs to address review/CI feedback, hit a merge conflict, or needs to trim bloat), send the instruction directly to that spawned session:

```bash
python3 "$SKILL_DIR/scripts/coordinator.py" send \
  --project "$PROJECT_ID" \
  --session "$CHILD_SESSION_ID" \
  --prompt "Inspect the merge-base diff, remove the redundant fallback in foo.ts, re-run tests, and push."
```

Never perform those edits or test runs in the coordinator session. `send-session-prompt` **queues**: the child takes the prompt only once it is fully idle (no turn, background agent or background shell) — which can be long after `list-status` shows `idle`, because a child waiting on background work still reads `idle` — so it may arrive stale. Before sending, read the child's `<SESSION_ID>.agent-activity.json` in the `sessions/` folder of the app's state directory (on the Mac that runs the app, in `$COPILOT_PROJECTS_STATE_DIR`, default `~/.local/state/copilot-projects`) for `foregroundTurnActive`, `activeSubagents`, and `workflow.pendingMessages`: send only what stays correct if delivered late, and never re-send while a message is pending. Per **Hard Rule #5**, keep a 15m recurring `manage_schedule` active while any child session is active.

`coordinator.py send --steer` does not queue: the prompt lands in the running turn, or starts a turn at once when none is running. Use it for a ruling the child needs before it goes further, or for a child that is never idle. Queue anything that can wait for the child's next stop, because a steer lands in the middle of what the child is doing. If it replaces an earlier message, say so plainly in it. An app left running from before it learned `--steer` ignores it and queues the prompt, so restart the app after updating; a steer the app refuses is never queued instead. The reply's `code` (`queued` or `applied`) is the same for both kinds: it says the child's tracker was handed the prompt, not how it was delivered. Until it is delivered, the child's `workflow.pendingMessages` lists it with `mode` `immediate` for a steer and `enqueue` for a queued prompt.

**Parked children.** `status` shows a parked child as `idle` with `status_text` `Parked`: the app stopped its Copilot to free memory and kept the tab and the conversation. `Parking…` and `Resuming…` are the moments in between, and `Couldn't resume` means Copilot did not start again. Send to a parked child as to any other: `coordinator.py send` (with or without `--steer`) asks the app to start its Copilot again, waits until it can take a prompt (a few seconds, two minutes at most), and then sends the prompt. Its `agent-activity.json` dates from before it was parked, so the read before sending does not apply. If the send says Copilot didn't start again, tell the user and keep the tab. An app from before `unpark-session` refuses the prompt as busy and starts Copilot anyway: send again after a few seconds.

**Stalled children.** A child that is `idle` with an unfinished PR lifecycle is stalled: read its last message, then send a follow-up. A child waiting on a background shell (a CI watcher, for example) keeps a queued prompt queued until that shell exits. To start a prompt that is already queued there, or to take it back, list the child's pending prompts with `copilot-projects queued-prompts --session "$CHILD_SESSION_ID"` and pass the prompt's `messageId` to `--send-now` or `--remove`: sent now, it starts at once while the shell keeps running (seen on Copilot CLI 1.0.113 outside the app, not yet on a live child). Per **Hard Rule #1**, do not signal the child's processes to hurry it: wait for the watcher, or `send --steer` asking the child to stop its own watcher (expected to reach it, but not yet tried on a child waiting on a background shell). The one exception is a wait that can never end on its own, such as `gh pr checks --watch` once every automated check has finished and only a status a human must clear is pending. Then, if that steer did not reach the child, read the waiting PID's full command line, confirm it is that watcher and not an extension, stop it with `kill <PID>`, and send the follow-up.

## 5. Audit child diffs for bloat, reconcile cross-PR contracts, & drive to ready-to-merge

For every child PR opened by the fleet (including PRs that are already CI-green when the coordinator attaches):
1. Inspect `git -C "$WORKTREE" diff --stat "$(git -C "$WORKTREE" merge-base "origin/$BASE" HEAD)"` and read the full diff (read-only).
2. Verify there is **no bloat or over-engineering** (**Hard Rule #3**). The checklist is in [`references/diff-audit.md`](diff-audit.md); read it before auditing. If bloat is present, use `coordinator.py send` to have the owning session simplify the diff and re-run validation.
3. **Reconcile review threads and boundary assumptions across sibling PRs:** Read all review threads (including resolved/dismissed ones) across all PRs in the batch. Verify that no child dismissed a real security, authorization, or side-effect finding by punting to a companion PR ("the downstream/upstream service handles that"), and that any contract refinement made in one PR during review is reflected consistently in its sibling PRs.
4. Confirm `0` unresolved review threads on `HEAD`, green CI, `MERGEABLE`, and `isDraft == false` (`gh pr ready`, unless drafts were requested) before reporting completion.
