---
name: coordinate-copilot-sessions
description: >-
  Use when the user asks to spawn, launch, coordinate, or spin off top-level Copilot Projects
  sessions/tabs — either to coordinate parallel work ("do X in a new session", "spawn separate
  sessions", "open a session for each", "queue up a session per item", "do these in parallel in
  the X project") or to fork a side question/tangent into a standalone tab ("extract this into a
  new session", "spin this off into a new session / tab", "fork this tangent / side question into
  a new session", "move this side quest to a new session so we don't distract from X"). Owns two
  modes: (1) Parallel Fleet Coordination, where the opening session stays strictly read-only,
  pre-creates disjoint worktrees, staggers child launches until running, steers via
  send-session-prompt, audits diffs for bloat, and drives PRs to ready-to-merge; and (2) Spin Off
  / Fork a Tangent (--no-parent), which hands off a self-contained <=8 KB prompt to the target
  project and returns focus to the current session.
---

# Coordinate or Spin Off Copilot Projects Sessions

This skill owns **both** modes of spawning top-level **Copilot Projects** tabs (rather than internal `task` subagents):

1. **Parallel Fleet Coordination (coordinator mode):** The opening session acts as a strictly read-only **coordinator** over child sessions (`--parent-session` / default `$COPILOT_PROJECTS_SESSION`). Launching the tabs is the start of the job, not the handoff — the coordinator staggers launches, monitors progress, steers via `send-session-prompt`, audits diffs for bloat, reconciles cross-PR review threads, and drives every track to ready-to-merge without ever editing or running tests inside a child track's worktree.
2. **Spin Off / Fork a Tangent (standalone handoff mode):** When the user wants to extract a side question, tangent, or follow-up track into a separate tab so the current session stays focused on its primary topic, launch a standalone top-level tab (`--no-parent`) in the most appropriate target project with a self-contained handoff prompt (`<= 8192` bytes), wait until it reaches `running`, report the Project, Tab Title, and Session ID, and immediately return focus to the current session's main work.

## When to Use This Skill

### Parallel Fleet Coordination
- "Do X in a new session."
- "Open a session for each item in the X project."
- "Spawn separate sessions to fix these in parallel."
- "Queue up a session per tag/track so we can do this faster."
- "Orchestrate the sessions you opened to get them to green."

### Spin Off / Fork a Tangent
- "Extract this into a new session."
- "Spin this off into a new session / tab."
- "Fork this tangent / side question into a new session."
- "Move this side quest to a new session so we don't distract from X."

## Hard Rules for the Coordinator

1. **Coordinator is strictly read-only on child worktrees (both newly spawned and already-open sessions):**
   - The coordinator may pre-create disjoint worktrees (`git worktree add -b <branch> ../<repo>-<slug> "$BASE_SHA"`) before launching child sessions, and may run read-only inspection (`git status`, `git diff`, `git log`, `gh pr view`/`list`) afterward.
   - Once a child session is launched (or when attaching to already-open child tabs), **never** edit files, run builds/tests, commit, push, or launch PR-management subagents for a child track from the coordinator session.
   - Route **all** follow-up work (unstuck nudges, PR review/CI iterations, conflict resolution, bloat trimming) to the spawned session via `coordinator.py send` (`send-session-prompt`).
   - **Never signal a child's processes to steer or unblock it.** A prompt queued while a child waits on a background watcher stays queued until that watcher exits; wait, or ask the child to stop its own watcher with `coordinator.py send --steer`. A CLI's child processes include its extensions (`extension_bootstrap.mjs`, the Copilot Projects tracker among them), which look like ordinary background processes in `ps` and don't respawn when killed. Killing the tracker disables that session's transcript, questions, and prompt delivery until `/restart` is run in its terminal. If a process must be stopped, read that PID's full command line first and never signal an extension.
2. **Stagger launches sequentially — wait for `running` before opening the next:**
   - Never fire multiple `new-copilot-session` commands in parallel or in a tight loop. Booting multiple Copilot CLI + MCP server trees simultaneously overloads the machine and causes startup timeouts.
   - Always use `coordinator.py launch` or `coordinator.py launch-batch`, which launches one session and polls `list-status` until that session transitions to `running` before returning.
3. **Zero bloat / zero over-engineering gate:**
   - Bake anti-bloat rules into every child prompt (see [`references/child-prompt-template.md`](references/child-prompt-template.md)).
   - Before declaring any child PR done, inspect its full merge-base diff (`git diff <merge-base>..HEAD`) from the coordinator. If the child added speculative edge-case guards, redundant fallbacks, dead plumbing, unnecessary abstractions, or cross-track duplication, send a `send-session-prompt` to that child session instructing it what to delete/simplify and re-validate. Before each audit, read [`references/diff-audit.md`](references/diff-audit.md) for what else to specifically check for and reject.
4. **Cross-PR contract & review-thread reconciliation (multi-PR / cross-service fleets):**
   - When sibling child sessions touch coupled layers (e.g., proxy + backend, API + UI, producer + consumer), never audit their diffs or review threads only in isolation.
   - Inspect **all review threads (including resolved/dismissed ones)** and post-review commits across every sibling PR together. If one child narrowed a contract or excluded unsafe cases in response to review feedback while a sibling child dismissed the equivalent finding (e.g., claiming "downstream enforces it") or drifted out of sync, treat that divergence as a blocking bug and steer the sibling session via `coordinator.py send` to align the contract.
5. **Keep a coordinator `manage_schedule` until no child track is active and every finished `idle` tab is closed:**
   - Child tabs are separate processes: no `<system_notification>` wakes the coordinator when one finishes a turn, hits a merge conflict, or stops its own schedule.
   - While any child session is active, keep a recurring `manage_schedule` (e.g., `interval: "15m"`) that polls `coordinator.py status`, audits new diffs, steers idle/conflicting children, closes finished `idle` tabs (`copilot-projects close-session`; a tab is finished only when every PR it owns is merged or closed, so a parked draft or a PR waiting on review keeps its tab, and "close the child sessions" from the user means the finished ones), and reads the coordinator's `workflow.pendingMessages` in `agent-activity.json`. To reopen a tab closed too early that ran on the Mac, send `resume-copilot-session` over the control socket (`projectId`, a UUID `requestId`, and the tab's `copilotSessionId`, which is not its session ID: read it from the tab's `agent-activity.json` before closing, because closing deletes that file); it returns under a new session ID with its history, so re-link it with `set-parent-session`. It finds only sessions whose history is on the Mac: for a tab that ran on a remote host, or when that ID was not noted, ask the user to use **Reopen Closed Session** in the app. Never wait on a background shell instead (a watcher script, `gh run watch`, a sleep loop): prompts queued for the coordinator are not delivered until that shell exits. An unanswered `ask_user` form holds the turn open too, and the app refuses prompts sent to a session that is waiting for input: first send every steer that does not need the answer; if the user is not replying now, end the turn listing the open decisions and ask on their next message.
   - Create the schedule in the same turn as the last launch, and re-read this `SKILL.md` from disk before each new fleet: a copy loaded earlier may predate newer rules.
   - Before reporting a fleet done or stopping the schedule, list the sessions whose `parentSessionId` in the app's `state.json` (on the Mac that runs the app, in `$COPILOT_PROJECTS_STATE_DIR`, default `~/.local/state/copilot-projects`) is the coordinator, and close or account for each. That finds children only in the coordinator's own project, only when the coordinator is not itself grouped under a parent, and only those launched grouped under it (not with `--no-parent`, another `--parent-session`, or on a build without grouping). Otherwise, or where that file is not on the coordinator's machine (a tab on a remote SSH host), account for every session `coordinator.py status --project` lists, for each project launched into, instead; a file that cannot be read is not an empty list. A watch list kept by hand misses a child from an earlier fleet or a duplicate launch.
6. **Drive every PR to ready-to-merge:**
   - Oversee all spawned sessions until every track's PR has passed local tests and code review, has `0` unresolved review threads, green CI, no merge conflicts (`MERGEABLE`), and is marked ready for review (`gh pr ready`, unless the user explicitly requested drafts) — or is closed cleanly if verification disproved the premise.

## Workflow

`SKILL_DIR` is the directory this `SKILL.md` was loaded from (for example `~/.copilot/skills/coordinate-copilot-sessions` or `<repo>/.github/skills/coordinate-copilot-sessions`).

Read each reference from disk when its step says to, again for each new fleet (the **Hard Rule #5** re-read covers these files).

1. **Resolve target project & pre-create disjoint worktrees.** Before launching, read [`references/launch.md`](references/launch.md) in full; it holds steps 1–3. This step covers the project ID, the `origin` fetch and `BASE_SHA` pin, and disjoint worktrees.
2. **Write self-contained child prompt files (`<= 8192` bytes).** Before writing a child prompt, read step 2 of `references/launch.md`: what every child prompt must include.
3. **Stagger session launches sequentially.** Before any `launch` or `launch-batch`, read step 3 of `references/launch.md`: the commands, the manifest format, and the `errno 35` case.
4. **Monitor progress & steer child sessions via `send-session-prompt`.** On every tick, and before any `coordinator.py send`, read [`references/monitor.md`](references/monitor.md); it holds steps 4–5. This step covers `status`, `send`, how sent prompts queue, when to `--steer`, and stalled children.
5. **Audit child diffs for bloat, reconcile cross-PR contracts, & drive to ready-to-merge.** Step 5 of `references/monitor.md` has the audit steps and the completion checks. On every audit, also read [`references/diff-audit.md`](references/diff-audit.md): the **Hard Rule #3** checklist.

## Mode 2: Spin Off / Fork a Tangent (Standalone Handoff)

Use this mode when a conversation uncovers a side question, skill idea, or follow-up track and the user wants to move it into its own tab without distracting from the current session's main work.

Read [`references/spin-off-handoff.md`](references/spin-off-handoff.md) before launching and follow its three steps. Do **not** poll, coordinate, or steer the spun-off tangent from the originating session.

## Remote SSH Host & Local macOS Parity

On remote SSH hosts configured in Copilot Projects, `~/.local/bin/copilot-projects` forwards `list-projects`, `list-status`, `new-copilot-session`, `close-session`, and `new-project` over the SSH-forwarded `$COPILOT_PROJECTS_SOCKET` (falling back to the newest `~/.local/state/copilot-projects/by-session/*/control.sock`). Forwarding transports control commands; it does **not** select the child's execution host. Child sessions use the target project's default host, or the local Mac if none is set. Resolve the host containing the pre-created worktrees or handoff artifacts and pass `--host <host-id>` to `coordinator.py launch` / `launch-batch` (or set `"host": "<host-id>"` per manifest item). Only omit this option after verifying that the target project's default host is correct, and include the execution host in each child or handoff prompt.

## References

- [`references/launch.md`](references/launch.md) — Workflow steps 1–3.
- [`references/monitor.md`](references/monitor.md) — Workflow steps 4–5.
- [`references/diff-audit.md`](references/diff-audit.md) — the Hard Rule #3 checklist.
- [`references/child-prompt-template.md`](references/child-prompt-template.md) — standard `<= 8192`-byte child prompt template.
- [`references/spin-off-handoff.md`](references/spin-off-handoff.md) — Mode 2 steps: target project, handoff prompt contents, and the `--no-parent` launch.
- Helper tests: `python3 -m unittest discover -s tests -p 'test_*.py'` from this skill's directory.
