# Copilot Projects: usage and development

A deliberately small macOS terminal app that organizes CLI sessions by **project**.
Projects and their sessions occupy separate vertical navigation columns beside
the working terminal. It keeps the parts of [cmux](https://github.com/manaflow-ai/cmux) that
matter most for working with coding agents — **status indicators** and **notifications** —
and drops everything else.

See the [project overview](../README.md) for installation and a quick tour.

It replaces cmux's Ghostty integration with
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)'s native Metal renderer,
with a CoreGraphics fallback. The result is a few Swift files instead of hundreds.

## Features

- **Projects (vertical sidebar):** a project is just a named group of sessions. Create one
  with `⌘N` (name it; no folder required). Jump to one with **`⌘1`–`⌘9`**.
  Use **`⌘0`**, the View menu, or the session-header button to hide/show the project column.
  Drag the divider beside Projects or Sessions to resize that column. Widths are
  remembered across launches, and hiding/showing Projects preserves its width.
  Hover a truncated project name to read it in full.
- **Sessions (vertical browser):** the selected project's sessions appear beside the project
  column, with their names and explicit state. One terminal is visible at a time.
  Start Copilot with `⌘T` or a plain shell with `⌥⌘T`, switch with a click / **`⌃Tab`** (next) / `⌃⇧Tab`
  (prev) / **`⌃1`–`⌃9`** / `⌘⇧[` / `⌘⇧]`, or end with `⌘W`, the row's ✕,
  or a double-click on the session selector. Sessions with active or pending work
  still ask for confirmation before ending.
  Drag a row to reorder it or onto another project to move it (show Projects first
  if that column is hidden). Background sessions keep
  running. Hold **⌘** (projects) or **⌃** (sessions) to see numbered hints.
- **Find Session (`⌘K`):** search every project's live sessions and recent ended Copilot CLI
  sessions by name, project, folder, or conversation text; matches update as you type, and
  browsing lists **Recent Ended Sessions** below live ones. After a pause, Luna (`gpt-6-luna`)
  adds meaning-based suggestions across both live and ended sessions through a tool-less
  `copilot -p` run in a throwaway `COPILOT_HOME` seeded only with your signed-in account, so it
  never adds sessions to your Copilot history. `↑`/`↓` or `⌃N`/`⌃P` move, Return opens a live
  session or resumes an ended one in its matching project (or the current project) with
  `copilot --resume` in the folder it worked in, and Escape clears then closes.
- **Pull Requests (`⇧⌘P`):** opens Copilot Pull Requests, a separate app nested in
  `Copilot Projects.app/Contents/Helpers/`, with its own Dock icon and `⌘Tab` entry
  (Control-click its Dock icon ▸ **Options ▸ Keep in Dock** to keep it there). It shows
  your open pull requests, one row per goal and one column per stage (Draft, Checks,
  Review, Ready), with what needs you called out. Goals are inferred from the live
  session whose Copilot event log names each pull request's head branch, and can be
  regrouped by hand. A goal no live session drives offers **Resume Session** when an
  ended Copilot session worked on it: found through the Copilot CLI's local session
  store, it reopens with `copilot --resume` in a new tab in the folder it worked in.
  Sessions whose folder is gone, or that another Copilot CLI has open, aren't offered.
  It uses your `gh` accounts and the GitHub GraphQL API, and reads sessions from
  Copilot Projects over the control socket (`list-sessions`, `reveal-session`,
  `start-copilot-session`, `resume-copilot-session`, `send-session-prompt`), so it
  never touches terminals itself. Pull requests linked to a live session also offer
  reason-aware dispatch actions (**Ask Session to Fix Checks**, **Ask Session to Resolve
  Conflicts**, **Ask Session to Address Feedback**, **Ask Session to Update Branch**,
  **Ask Session to Check Status**) and **Send Prompt to Session…** (`P`, or `⇧P` for the
  primary action) to queue a prompt in that session and focus it. A session whose
  Copilot isn't running, or isn't reporting that it can take a message, refuses the prompt.
  Only one copy per state directory writes its goals; see the README for the rules.
- **Notifications (`⇧⌘N`):** opens Copilot Notifications, a separate app nested beside
  Copilot Pull Requests, with its own Dock icon, Dock badge, and `⌘Tab` entry. It keeps
  running after its window closes so the badge and banners stay current, and Copilot
  Projects starts it in the background once you've opened it (**Start Notifications with
  Copilot Projects** in the app menu turns that off). It mirrors the GitHub inbox of every
  `gh` account in lanes by reason, banded **To you**, **Via your teams**, **Watching**, and
  **Quiet** (CI and the rest, never badged), with columns **Since you looked**, **Today**,
  **This week**, and **Older**. Review requests are split by each pull request's
  review-request history. Opening a thread marks it read on GitHub; `E` marks it done.
  Pull request threads a live session works on offer **Go to Session**; pull request
  threads with no live session offer **Review in Copilot** (`R`, or choose a project
  from the context menu) to launch a local adversarial review in Copilot Projects and
  link the resulting session to the thread.
- **Prompt-first sessions:** the **+** split button's dropdown, Session menu, and project context
  menu offer **Start with Prompt…**. Compose multiple lines, then use `⌘Return` to launch
  an interactive session (not a one-shot/headless command). Cancel creates no session.
  Startup checks retain the draft on failure; after a session opens, **Copy Starting Prompt**
  in its context menu recovers the prompt, including after a restart or a reopened tab.
  Prompts are never retried automatically. New and restored Copilot sessions never pass
  `--allow-all`; tool approvals follow your normal Copilot CLI permission settings.
- **Local PR reviews:** choose **Review Pull Request…** from the **+** split button's
  dropdown, paste a GitHub pull request URL, and open a new Copilot CLI session in the
  current project. The session starts with the prompt from **Copilot Projects ▸ Pull
  Request Review Prompt…**. Put `{url}` where the pull request URL goes. **Restore
  Default** returns the built-in adversarial-review prompt. Copilot Notifications and the
  CLI use that same prompt.
- **Status:** each session reports `idle` / `running` / `waiting`. Running and waiting
  labeled symbol counts appear in the project column; a blue dot on the session row marks work that finished
  while you were away, and a red exclamation with **Request failed** marks a session whose latest
  request ended in a Copilot error (hover it for the CLI's message); the project column counts
  those sessions behind the same red exclamation. The failure clears when the
  next request starts. Clicking any active count in the top-right fleet status bar
  (`waiting`, `failed`, `ready`, `running`, `background`, `scheduled`) jumps to the
  next session in that state across all projects, and **Session ▸ Next Session Needing
  Attention** (`⇧⌘A`) cycles across projects in urgency order (`waiting` → `failed` →
  `unread` / `finished`). Within one urgency it goes in workspace order (projects in
  order, then each project's sessions in order), starting after the current session and
  wrapping around. When the session it went to no longer needs you, it carries
  on from there instead of starting over. The session's tracker (below) drives this automatically.
- **Transcript view:** Copilot CLI remains the native interactive terminal, while a
  collapsible drawer overlays its right edge with independently scrollable turns
  rendered as Markdown, or fills the terminal area. Copilot's questions can be answered
  and messages sent from it; permissions and shortcuts stay in the CLI. See
  [Transcript view](../README.md#transcript-view).
- **Schedules + background work:** queued scheduled prompts show a clock with cadence/next-run
  details; active scheduled turns and subagents use a separate background indicator instead of
  making the foreground session look busy.
- **Question recovery:** the tracker also reads question events on its five-second heartbeat,
  so a missed live notification does not leave a question answerable only in the terminal.
  Text, choices, and other supported forms use the original response ID. This works with
  the existing CLI event API; no new CLI version is required for missed-event recovery.
  If completions free slots after bounded staging overflows, the tracker replays that
  window before selecting the remaining forms; staging and per-heartbeat read limits stay unchanged.
  If a question has already left the CLI's in-memory event history, it remains answerable
  in the terminal rather than through a guessed response ID.
- **Notifications:** native macOS banners identify the originating project/session and
  automatically alert when Copilot has a question, needs permission, or finishes a task.
  Task completions include a short, plain-text preview of the completed turn's response.
  Previews are derived locally (no extra model call),
  omit code blocks, and fall back to the generic alert when the matching transcript
  is unavailable. Response previews can appear on your lock screen.
  When the session's tracker supports receipt-backed operations, question alerts show the
  pending question as a plain-text preview, followed by its numbered choices when they fit a
  notification (at most four short choices on a question with one answer field), and wait
  briefly (under four seconds) for the tracker to publish a pending question. Older trackers keep the generic question alert. Banners are
  tap-to-open: clicking one focuses that session.
  Once a question is answered, in the terminal or in the app, the app
  withdraws its alert. It waits for
  positive evidence: a newer tracker snapshot of the same conversation without that request,
  the tab moving to another Copilot conversation, the session closing, or, when no tracker
  vouches for the question, the turn ending (just leaving the wait is enough when no tracker
  is running and none listed it). A permission prompt during a pending question keeps the
  alert. Permission and completion alerts are not withdrawn automatically. Unread sessions
  get a bell badge + a Dock badge count. Completed sessions show one blue attention dot, not two.
  Returning to the Mac app marks the selected session read without
  needing to switch sessions. To come back to a session later, choose **Mark as Unread**
  from its context menu (or press `⇧⌘U` for the current session). The mark survives
  relaunch and returning to the app, and clears when you go back to that session or choose
  **Mark as Read**. Both menus offer **Mark as Read** instead while a session shows an
  unread or finished indicator, so `⇧⌘U` toggles the current session.
- **Control socket + CLI:** the same `copilot-projects` binary is also a CLI that talks to the
  running app over a Unix socket — ideal for agent hooks.
- **Resumable sessions:** each terminal runs under a bundled [dtach](https://github.com/crigler/dtach),
  so quitting/relaunching/crashing the app does **not** kill your shells or in-flight agents.
  Relaunch reattaches. You can also `ssh` into the machine and `copilot-projects attach` to reconnect
  from another host.
- **Persistence:** projects/sessions are restored on relaunch.
- **Window lifetime:** closing the last window quits by default. Enable **Keep Running When
  Window Closes** to keep sessions available from the menu bar; Dock reopen,
  menu-bar Open, notifications, and CLI focus all restore the main window. **Quit Copilot
  Projects** still performs the normal graceful detach and persistence drain.

## Native session workflows

With Copilot CLI 1.0.84 or newer on SDK protocol 3 or 4, the tracker offers native
session controls to the app. This also requires Copilot CLI
experimental features; see [Copilot CLI integration](#copilot-cli-integration-automatic-status).
The transcript composer
can **Run after current task** or **Steer current task** without clearing the
CLI's draft. **Stop task** requests cancellation without closing the session,
shell, or dtach session. Terminal controls remain available for other TUIs and
unsupported CLI versions.

In the desktop transcript, a prompt Copilot has not started yet is marked **Queued** and
offers **Send now** and **Take back**. Send now delivers it as a steer: into the running
turn, or as a turn at once when none is running, so a prompt queued behind a background
shell stops waiting. It is unavailable while Copilot waits on a question. Take back removes
the prompt from Copilot's queue and puts its text in the message field, ahead of any draft.
If Copilot starts the prompt first, either action answers "That prompt is no longer
queued." and the prompt runs. Text longer than 8,192 characters comes back cut,
attachments do not come back, and a prompt sent to Copilot as part of a batch is refused
both. `copilot-projects queued-prompts` does the same from a
script; see [the README](../README.md#command-line-access).

Native actions retain the conversation identity and SDK operation
receipt checks. A send's `applied` receipt
means Copilot accepted the message, not that it finished the task. Unknown
outcomes are never automatically resubmitted as a new operation or downgraded to
terminal input.
Stop has its own handoff lane, so an unresolved send cannot block cancellation.

The tracker retains the latest 64 completed operation receipts for the current
conversation, without a time limit. This history ends when
the Copilot conversation or tracker process changes, and older receipts can be
evicted by later operations. An unavailable receipt remains an unknown outcome,
not permission to send it again as a new operation. Updating the tracker cannot
recover receipts that already expired.

The session drawer renders live response updates
within its conversation turns. Final messages replace their matching streamed text.
The transcript's working line shows the CLI's live `assistant.intent` description.
The tracker clears old activity on new work, conversation changes, and session idle.
While only agents remain, it shows the first available short task description (or
agent name), plus a count of other active agents. The text follows the remaining
agents as they finish. "Waiting for background agents" is used only when their labels
are unknown. MCP tasks use their short display name rather than their full prompt;
agents launched directly from a definition may report their configured description.
Missing or stale activity shows "Copilot is working…" or "Background work active".
Newly observed empty or whitespace-only assistant messages are omitted from live
and completed transcripts; their tool activity remains visible.

**Usage and background work** shows accumulated session AI credits, the latest
context observation, active agents, and schedules. Session totals and the current
budget accounting window are deliberately separate. Users can opt into an AI-credit
soft limit (minimum 30), remove it, or answer a live exhausted-budget request by
adding credits or cancelling the blocked model request. There is no default limit.
Limits are checked by Copilot after model calls and can be exceeded by the last
call. A new budget request sends a Mac notification.

Capabilities require fresh runtime evidence; unsupported or unavailable operations
stay disabled. Evidence is fresh for 15 seconds after the tracker observes it, and
the tracker publishes each heartbeat's observation as soon as it is taken.
The app judges this on its own clock before taking any session action. An action
also needs its capability listed and no restart pending, and each action's own
conditions still apply, such as the session being ready to take a send.
A session whose workflow state is missing, stale, or unsupported offers no composer
send: a message is never typed into the terminal on the composer's behalf.
Raw terminal input is independent of these checks.
Older trackers on a newer app remain blocked even with a fresh heartbeat:
restart/reload the tracker to activate the updated workflow metadata, or use Terminal.

In the desktop transcript composer, `/restart` on its own restarts the session
instead of going to Copilot as a message, and is offered as a suggestion once the
draft starts with `/`. It makes the request described under
[Session restart](../README.md#session-restart); nothing is typed into the terminal.
The composer refuses, and says why, while the session is parked, Copilot is not
idle, or the session's tracker is not offering a restart; in the last case run
`/restart` in the session's terminal. **Restart Session** in a session's context
menu, and in the Session menu for the selected session, makes the same request
and is disabled under the same conditions.

`/rename <new name>` in the composer, and **Rename…** in a session's context menu,
rename a Copilot session: the app asks the session's tracker, Copilot takes the name
at once, working or not, and the tab takes it when Copilot sets its terminal title.
Nothing is typed into the terminal. A name has at most 100 characters and no double
quotes or tabs. The composer refuses, and says why, while the session is parked, a
restart is pending, the session has no terminal, or its tracker is not offering a
rename; in the last case run `/rename` in the session's terminal. **Rename…** is
disabled under the same conditions, and says why if one arises while its dialog is
open.

The app parses a question's schema into a form, and the question card shows its
fields in order: one choice, several choices, yes or no, a number, or text, with the
title, description, default, and limits the schema gives. Where the question allows
typed answers (an agent's own question; an MCP server's form does not), the card also
takes any non-blank text for a choice or a yes-or-no field, and one typed entry among
several choices. For a text field's format the app
checks `email`, `uri`, `date` and `date-time`, and accepts any text for another. The
app checks every answer against the agent's schema. A question that asks you to open
a link, and one the terminal is asking with a default answer, have their own controls
on the card. A question whose schema is outside that subset is answered in the terminal.

An optional offline integration test exercises the installed CLI/SDK pair against
a loopback model fixture, without real model requests:

```bash
COPILOT_WORKFLOW_SDK=/path/to/copilot-sdk \
COPILOT_WORKFLOW_CLI=/path/to/copilot \
node --test JSTests/workflow-runtime.test.mjs
```

## Install

Download the latest `Copilot-Projects-<version>.dmg` from
[Releases](https://github.com/sirfergy/copilot-projects/releases), open it, and drag
**Copilot Projects** onto **Applications**.

Release builds are Developer ID signed, notarized, and stapled for normal
Gatekeeper installation.

Requires macOS 26+ on Apple Silicon.

## Build & run

Requires Xcode 26+, macOS 26+.

```bash
./scripts/build-app.sh --launch        # debug build -> dist/Copilot Projects.app, then open it
./scripts/build-app.sh --release        # optimized build
```

`build-app.sh` runs `swift build`, assembles `dist/Copilot Projects.app` (with the
Copilot Projects Link, Copilot Pull Requests, and Copilot Notifications helper apps
under `Contents/Helpers/`), precompiles SwiftTerm's Metal shaders, and signs the nested
executables inner-first. `swift run copilot-projects` has no helpers, so Pull Requests
and Notifications explain that they need the built app. Local builds
use an available Developer ID identity, falling back to ad-hoc signing. Set
`CODESIGN_IDENTITY=-` to force ad-hoc signing for a validation build.

The runtime assets are regular SwiftPM resources rather than embedded Swift literals. The
tracker remains one atomic `extension.mjs` install. The session-status rules live in the headless `SessionDomain`
package, and the protocol examples share `ContractFixtures`.

```bash
swift test --package-path Packages/SessionDomain
./scripts/check-tracker.sh
swift test
CODESIGN_IDENTITY=- ./scripts/build-app.sh --release
./scripts/verify-app-resources.sh
```

On first launch the app symlinks its binary to `~/.local/bin/copilot-projects`. Put that on your
`PATH` to use the CLI from anywhere:

```bash
export PATH="$HOME/.local/bin:$PATH"
copilot-projects ping            # -> pong
```

> **Note:** if `swift build` fails with `cannot use bare repository … safe.bareRepository is
> 'explicit'`, your global git config blocks SwiftPM's clone. `build-app.sh` already injects
> an override; to run `swift build` directly, prefix it with
> `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all`.

### Cutting a release

The [Release workflow](../.github/workflows/release.yml) is the primary publisher.
It automatically publishes the next version for eligible PR merges to `main`.
Releases run one at a time. A merge that lands while one is running waits for it,
and a later merge or manual dispatch replaces the waiting run, which then shows as
cancelled. The remaining run releases the commit that triggered it, with notes
covering every merge since the previous release. GitHub does not guarantee the
order of runs queued seconds apart; if the newest merge is left unreleased, the
next merge releases it, or dispatch the workflow manually.

Versions are `YYYY.M.D.N`, tagged `vYYYY.M.D.N`: the date in Pacific time
(`America/Los_Angeles`) when the workflow computes the version, then the release's
ordinal that day. Month, day, and `N` have no leading zeros, so `v2026.10.8.3` is
the third release on October 8, 2026. The next release on the same Pacific day
increments `N`; the first release of a later day, or the first after a legacy
`vX.Y.Z` tag, is `.1`. Legacy tags remain valid predecessors and always order
below date tags. If the latest release tag is dated after today, the workflow
fails instead of publishing a lower version. The rules live in
[`scripts/release-version.sh`](../scripts/release-version.sh).

To publish the next version manually, dispatch the workflow from `main`:

```bash
gh workflow run release.yml \
  --repo sirfergy/copilot-projects \
  --ref main \
  -f version=YYYY.M.D.N
```

Replace `YYYY.M.D.N` with the version an automatic release would pick now; the
workflow rejects any other version and names the expected one. Dispatch only when
no Release run is running or waiting: a dispatch replaces the waiting run, and is
rejected if the running release publishes that version first. Publishing with
`scripts/release.sh --publish` likewise refuses a version dated after today. The
workflow runs validation and tests before entering the protected `release`
environment for signing and publishing.

#### Local builds and fallback publishing

`scripts/release.sh` builds an Apple Silicon optimized app and drag-to-Applications DMG.

```bash
./scripts/release.sh 2026.10.8.1       # -> dist/Copilot-Projects-2026.10.8.1.dmg (local only)
```

Use direct script publishing only as a fallback when the Actions runner or signing
configuration is unavailable. Run the release validation and tests first; this path
does not run the workflow's validation job or protected environment approvals.
It requires a Developer ID identity and a `notarytool` Keychain profile:

```bash
CODESIGN_IDENTITY="Developer ID Application: …" \
NOTARY_PROFILE="copilot-projects-notary" \
./scripts/release.sh 2026.10.8.1 --publish
```

On shared build machines, set `CODESIGN_KEYCHAIN` to the job's signing keychain
and `NOTARY_KEYCHAIN` to the keychain containing its notarization profile.
Signing then uses that keychain for identity discovery, app/helpers, and the DMG.
The signing keychain must also be registered in the invoking user's search list:
`codesign --keychain` narrows identity selection but does not enable unlisted
keychains. The Release workflow safely appends its job keychain, verifies a real
signature before building, and uses the same helper to delete only that keychain
afterward:

```bash
python3 scripts/keychain-search.py /absolute/job.keychain-db
python3 scripts/keychain-search.py --delete /absolute/job.keychain-db
```

Both operations share a short per-user advisory lock around the search-list
mutation, not the build, signing, or job lifetime. The persistent lock file is
`.copilot-projects-keychain-search.lock` in the macOS account's home directory;
it is not removed between calls. Cleanup uses native keychain deletion and never
restores a stale search-list snapshot. An already absent job keychain is a
successful cleanup. External tools that bypass this helper do not participate in
its lock, so independent signing pipelines using them still require separate
macOS accounts. Leaving `CODESIGN_KEYCHAIN` unset preserves local signing behavior.

Publishing requires a clean checkout whose HEAD is reachable from `origin/main`.
The configured `GITHUB_REPOSITORY` (default `sirfergy/copilot-projects`) must match
every effective `origin` fetch and push URL before building or notarizing.
HTTPS, `git@github.com:owner/repo`, and `ssh://git@github.com/owner/repo` origin URLs are
supported (including Git URL rewrites); unknown hosts or mismatched targets fail
closed. Tracked source or HEAD changes during the build abort publication.
Local builds without `--publish` can be dirty or offline.

`--publish` refuses ad-hoc artifacts, notarizes and staples both the app and DMG, runs
Gatekeeper checks, then uses the active `gh` account to publish. Each artifact is uploaded
to the notary service once; the script then keeps polling that same submission for up to
`NOTARY_WAIT_MINUTES` (default 40) every `NOTARY_POLL_SECONDS` (default 15) instead of
failing at the first `notarytool` timeout. The Actions workflow
uses a protected `release` environment and fails closed unless these environment secrets
are configured:

| Secret | Value |
| --- | --- |
| `MACOS_DEVELOPER_ID_P12_BASE64` | Base64-encoded PKCS#12 export containing one Developer ID Application certificate and private key |
| `MACOS_DEVELOPER_ID_P12_PASSWORD` | Password for the PKCS#12 export |
| `APPLE_NOTARY_KEY_P8_BASE64` | Base64-encoded App Store Connect team API private key |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect API issuer ID |

Configure required reviewers and restrict deployments to `main` on the `release`
environment before adding the secrets. The workflow imports credentials only after tests
pass, removes the source files immediately after use, and deletes its temporary signing
keychain at the end of the job.

## CLI

Inside a copilot-projects terminal, `COPILOT_PROJECTS_PROJECT` / `COPILOT_PROJECTS_SESSION` /
`COPILOT_PROJECTS_SOCKET` are set, so commands auto-target the current session.

```bash
copilot-projects notify "Build finished" "All tests green"
copilot-projects list-projects
copilot-projects list-hosts                       # list This Mac + ~/.ssh/config hosts
copilot-projects list-status
copilot-projects new-project myapp                # name only; --cwd and --default-host optional
copilot-projects set-default-host woodhaven --project <id>
copilot-projects new-session --project <id> --cwd /tmp --host woodhaven
copilot-projects focus --session <id>             # bring app forward + select
copilot-projects send-session-prompt --session <id> --prompt "…"   # queue; add --steer to reach a running task
copilot-projects queued-prompts --session <id>    # pending prompts as JSON; --send-now or --remove <messageId>
copilot-projects doctor                           # diagnose state/session/runtime health
copilot-projects version                          # print installed version
copilot-projects install-hooks                    # install the Copilot CLI hook and the tracker
copilot-projects help
```

Targeting flags (`--project`, `--session`) override the environment defaults.

`copilot-projects install-cli [--dir DIRECTORY]` installs a launcher pointing to the real
running executable (default: `~/.local/bin`). It is safe to repeat through that launcher;
existing correct links and the executable itself are left untouched. Other symlinks are
replaced atomically. Conflicting regular files and directories are refused: move them
aside yourself or choose a different `--dir`. The app's automatic
launcher setup and the first step of `install-hooks` use the same behavior.

### Notification deep links

External notifications can focus an existing project or session through the
`copilot-projects` URL scheme:

```text
copilot-projects://focus?project=<project-id>
copilot-projects://focus?session=<session-id>
copilot-projects://focus?project=<project-id>&session=<session-id>
```

When a session is supplied it determines the owning project, so it takes precedence
over a mismatched project id. Unknown ids still activate the app without changing
the current selection.

Launch Copilot Projects once after installing so macOS registers the bundled
deep-link helper.

## Copilot CLI integration (automatic status)

The status dot tracks Copilot without any manual calls: each session's tracker (the extension
described below) publishes what the coordinator is doing, and the app shows it.

copilot-projects also installs a [Copilot CLI hook](https://docs.github.com/copilot) bridge into
`~/.copilot/hooks/` (`copilot-projects-hook.sh` + `copilot-projects.json`) the first time the app
launches. It registers one event, `sessionEnd`: when the tab's own Copilot exits while the app
is running, the hook runs `copilot-projects session-ended` and the app forgets which
conversation that tab resumes. A known non-owner's `sessionEnd` is ignored.

The hook no-ops outside a copilot-projects terminal (it checks `COPILOT_PROJECTS_SESSION`), so it
coexists with other integrations (e.g. cmux) and is safe to leave installed globally. Manage
it with `copilot-projects install-hooks` / `uninstall-hooks`. Changing hook registration requires
a new CLI session; an existing registration reads script-only updates on its next invocation.
A Copilot session that registered other events with an earlier release keeps calling the
script for them until it restarts, and the script ignores them.

App-managed Copilot launches and recorded-session resumes use a Ghostty-compatible profile so
Copilot CLI emits inline images through SwiftTerm's Kitty graphics support. The profile is scoped
to the Copilot process; plain shells and unrelated TUIs keep their original terminal identity.
For a manual shell launch with inline images, run
`/usr/bin/env -u TERM_PROGRAM_VERSION TERM_PROGRAM=ghostty copilot`. Existing Copilot processes
must be restarted with that profile; relaunching the app only reattaches their dtach master.
Independent of that local rendering, each terminal session bounds-checks and retains the same
Kitty-transmitted PNGs (fail-closed on anything outside the exact subset Copilot CLI emits).

A new Copilot session whose launch names no model, on this Mac or another host, is started
with `--model` and `--reasoning-effort` set to the default model and effort saved in the CLI's
`settings.json` on this Mac: `model`, which `/model --global <id>` saves, and `effortLevel`,
which `/settings effortLevel <level>` saves. `new-copilot-session --model` names one, and that
is used instead. Started without a model, a session takes an organization's default model in
place of the saved one. Because they are given at launch, the flags also take the place of a
repository's default model, effort and context tier (`/model --repo` or `--local`), and of an
effort a custom agent names. Nothing is passed when no model is saved, which includes a saved
model that is the CLI's own default; when it is `auto`; when `modelProviderId` names a
provider other than `copilot`; or when the app's environment sets `COPILOT_MODEL`,
`COPILOT_PROVIDER_BASE_URL` or `COPILOT_PROVIDER_GHES_HOST`. One of those set only in a shell
profile, or on the other host, is not seen, and the flags take its place too. A resumed
session keeps the model it had.

If the saved model is not available, Copilot says so when it starts and does not run the
session's prompt. An effort the saved model does not offer is refused the same way or not
applied, depending on the CLI version. Save a model and effort that work, then start a new
session: the tab that failed keeps the arguments it was started with.

The companion Copilot extension records completed root turns through the supported Copilot SDK
event API. It atomically writes a bounded per-tab transcript snapshot after each turn, including
stopped turns, failed requests with the CLI's error message, and compact tool summaries but
excluding raw tool arguments and results. The one exception is `ask_user`: its question stays in
its turn as a Copilot message, and an accepted answer opens the next turn as that turn's prompt,
in the CLI's own `Title: value` lines (that turn's id starts with `ask-user-answer-`). A declined,
cancelled, empty or failed question adds nothing. The snapshot is two files: finished turns in
`<tab>.transcript.json`, rewritten only when they change, and the turn in progress in
`<tab>.transcript-live.json`, rewritten as it streams. A publish that changes neither file
writes nothing. The host merges the two, using the live file only when it names the revision of
the finished-turns file it extends. A failure the agent recovers from on its own (a retry,
or a background agent restarting work) is cleared; model-catalog and other background notices
are not shown. Copilot
Projects renders that snapshot in the drawer without changing the terminal's PTY size. For
images only, the Mac drawer also reads the session's own `events.jsonl`: the images attached
to a prompt and the images a tool returned. The transcript holds at most
200 turns, and its two files together at most 5 MB.

The app also installs a read-only Copilot extension at
`~/.copilot/extensions/copilot-projects-tracker/extension.mjs`. It uses Copilot's session event
stream and SDK metadata queries to report queued schedules, coordinator activity, and active
subagents. Copilot CLI currently loads extensions only when experimental features are enabled.
Run `/experimental on` once before starting app-managed sessions, or pass
`--experimental` when launching Copilot manually. Without it, terminal reattach still works, but
a session shows Idle whatever it is doing, posts no alerts, and takes no prompt from the app,
and the transcript view, tracker-backed session details, native session
controls, and reboot conversation resume are unavailable. Existing CLI sessions must use
`/restart` after enabling experimental features. When the app upgrades the tracker, a session
already running a tracker with hot reload asks Copilot to reload its extensions once it is idle
on two consecutive heartbeats (about ten seconds), which restarts that session's other extensions
too. Sessions whose tracker predates hot reload, or whose Copilot does not support it, still need
an extension reload or `/restart`. `/restart` also loads the installed tracker, so a session that
needs both needs only `/restart`; hot reload never restarts Copilot itself. Wait for current work
and interactive prompts to finish before restarting.
Relaunching Copilot Projects only reattaches the terminals; extensions reload only when that
launch installs a different tracker, as above.
Copilot can reject the tracker's join while it is still reloading hooks for a session that just
started. The tracker retries that race for up to 20 seconds. Any other join failure, or a race that
outlasts that window, leaves the session without tracker metadata until you reload the extension or
use `/restart`.

While the app is running, a session that starts waiting on a question or a permission prompt,
and each completed turn, post a native macOS banner. The banner includes the project and session
name, and clicking it focuses the originating session. A question's banner posts as soon as the
tracker lists it. A permission prompt's banner posts once the prompt has stayed up for a second,
so one that is approved automatically posts nothing. Further prompts within the same wait post
nothing, and neither does an aborted turn. A turn is complete when the tracker ends it, so one
that starts and ends between two reads of the snapshot (under half a second) posts nothing. The app
holds both the banner and the Finished/blue-dot indicator while background agents remain active,
even when the main agent is idle. The SDK's root `session.idle` clears the background indication
once that work drains. A scheduled turn completes without a banner.

**Where status comes from.** A session's status, and whether it takes a prompt, come from its
tracker alone:

- A fresh snapshot from the tab's owner with a usable reading decides. The reading is the
  coordinator's processing state, which the tracker observes over the SDK, fenced to its current
  conversation and to the query's start time. On a CLI that has no such reading (an unsupported
  or remote runtime), the tracker's turn events stand in. A working coordinator is Running, an
  idle one is Idle, and a scheduled turn shows as Idle (it can read Running for a heartbeat
  first, until the tracker has marked it scheduled). A session takes a prompt when its
  coordinator is idle with nothing pending. Background agents do not make an idle coordinator
  busy.
- A fresh snapshot of the tab's owner that lists a question, a permission request or a budget
  request shows Waiting for input, whatever its reading.
- A stale snapshot, a reading older than 15 seconds or one the tracker withdrew as a turn began,
  a failed query, and a snapshot written by another Copilot in the tab all leave the last status
  showing and offer no send.
- The tracker counts as gone when the agent process has exited, when the tracker reports that it
  lost its connection to the CLI, or when the missing-tracker warning has been up (45 seconds
  with a Copilot running and no healthy tracker). The session then shows Idle and offers no
  send; when the tracker died under a running Copilot, that lasts until the session is
  restarted. A turn that was running leaves the Finished dot without a banner. A gone
  tracker's listed questions are not shown as waiting or answered from the app.

Root `assistant.idle` refreshes the tracker's observation; an individual model iteration's
`assistant.turn_end` is not proof the coordinator finished. If no root idle event arrives, a
heartbeat observation that finds the coordinator idle for the second observation running, with
no message or turn start in between, ends the tracker's foreground turn. One idle reading while
the turn is still active reads Idle and takes a prompt for as long as it lasts, but the turn's
timer keeps running and nothing is marked finished.

The elapsed-turn timer starts at the tracker's turn start and survives a relaunch while the
snapshot on disk still shows the same request. Status is not saved: after a relaunch every
session reads Idle until its tracker's next snapshot is read. A question or permission prompt
that is already pending at that first read shows as Waiting and posts no banner, whether it was
asked before the relaunch or while the app was closed.

The terminal footer and the Copilot CLI hooks are not read for status or for sending. Tune the
process names the agent-process check looks for with `COPILOT_PROJECTS_AGENT_PROCESSES`
(comma-separated, default `copilot`) or disable the check with `COPILOT_PROJECTS_LIVENESS=0`;
with it disabled, a missing agent process is never taken as a gone tracker, and
`close-session` asks no Copilot whether it is idle.

Other tools' hooks can still post a banner for the current session:

```bash
copilot-projects notify "Agent needs input"
```

## Resumability & SSH reattach

Each session's shell runs under a bundled arm64 [dtach](https://github.com/crigler/dtach)
(GPLv2; source vendored in `vendor/dtach`). dtach forwards raw bytes — it is **not** a second
terminal emulator — so keyboard, title (OSC 0/2) and cwd (OSC 7) all stay native; SwiftTerm is
the only emulator.

- **Quit / relaunch / crash:** the dtach master daemonizes away from the app, so shells +
  agents keep running. Relaunch reattaches (`dtach -A`).
- **End a session (⌘W / ✕):** stops its processes and removes its row. A single idle
  session ends immediately. Reported active or pending work requires confirmation.
- **End Project:** ends its sessions and removes the group, not project files.
  Multiple sessions require confirmation even when idle. Cancel changes nothing;
  sessions added while a confirmation is open are not silently included.
- **Park a session (opt-in):** stops its dtach master, Copilot and tracker, and keeps the
  row, the transcript and the resume marker. Opening the session, or
  `copilot-projects unpark-session`, runs `copilot --resume` in the same row. See "Park
  idle sessions" in the README.
- **Reconnect from another host:**
  ```bash
  ssh you@mac
  copilot-projects ls                 # list sessions + ids
  copilot-projects attach <id|prefix> # raw reattach in this terminal (Ctrl-\ to detach)
  ```
- **Tradeoff:** scrollback *history* doesn't survive a detach (a full-screen TUI like copilot
  repaints on reattach; a plain shell starts fresh). Live scrollback while attached is normal.

Sockets live under `~/.local/state/copilot-projects/sessions/`. `copilot-projects doctor`
prints the active path and distinguishes the normal master/client process pair from real
orphaned masters. If the bundled dtach is missing, sessions fall back to plain shells.
Override it with `COPILOT_PROJECTS_DTACH`.

An app update does not replace already-running dtach masters. Backend fixes apply
to newly created sessions; old sessions keep their original helper and inherited
terminal handles until they end. Let active work finish before closing and
recreating an affected session.

## Renderer

SwiftTerm's Metal renderer is the default. Set `COPILOT_PROJECTS_RENDERER=coregraphics`
before launching to use the fallback renderer. The dependency is pinned to an immutable
SwiftTerm revision. Three recently selected terminals retain warm Metal surfaces; parking
other surfaces does not stop their processes, parser, or scrollback. Metal initialization
failures use CoreGraphics. A teardown failure is logged without claiming the Metal surface
was successfully parked.

The Mac host reads copied terminal snapshots rather than mutable terminal internals. Raw
process output passes through an ordered main-actor consumer so Kitty capture, durable-image
restoration and parser feeds retain their ordering independently of the render thread.

## How it works

- The small executable entrypoint calls `CopilotProjectsApplication` in `Sources/CopilotProjectsHost`:
  a recognized subcommand runs the CLI client; no arguments launches the SwiftUI app.
  Unknown commands are rejected.
- `Sources/CopilotProjectsCore` is Foundation-only: paths, the JSON-line wire protocol, the socket
  client, and CLI parsing.
- `AppModel` is the SwiftUI coordinator. Versioned state persistence, activity evidence,
  control-command routing, session artifacts, and instance locking are separate components.
  Live SwiftTerm views stay outside the observable graph.
- `ControlServer` listens on `~/.local/state/copilot-projects/control.sock` (mode 0600 in a 0700
  dir); each connection is one JSON request → one JSON response.
- State is persisted to `~/.local/state/copilot-projects/state.json`. Writes are atomic, preserve
  a known-good backup, and never overwrite unreadable state with an empty workspace.
- Permanent closes are accepted in `state.json.closing` before images, tracker commands, or tabs
  change. Startup replays interrupted closes even when recovering a backup; the intent is removed
  only after teardown and both state copies exclude the closed sessions. An unreadable intent
  stops workspace recovery rather than resurrecting sessions. Do not delete it to bypass an error.

Override locations with `COPILOT_PROJECTS_SOCKET` and `COPILOT_PROJECTS_STATE_DIR` to run an isolated
instance. An app launched with either override does not replace the global CLI symlink or Copilot
hooks. It opens its own Copilot Pull Requests and Copilot Notifications; when only the socket
moves out of the state directory, those copies keep their state and locks under
`pull-requests/socket-<hash>/` and `notifications/socket-<hash>/`.

## License

[MIT](../LICENSE). The bundled `dtach` helper is licensed under GPLv2; its source is
included in [`vendor/dtach`](../vendor/dtach).
## Release notes

Choose **Help > What's New** to read the changes bundled with the installed
version. This does not interrupt the workspace automatically after updates.
Development builds without bundled notes say so instead of fetching notes for
a newer release.

The first release containing `release-notes/initial.json` uses its hand-written
October 18-25 highlights for both the published notes and What's New. The source
is read from the build's Git commit, not an uncommitted working copy. Keep this
archive file tracked: once the preceding release contains it, subsequent releases
return to automatic notes. Each section contains `[text, GitHub-link-or-null]`
entries; malformed content fails generation rather than silently replacing it.
Links stay within this repository.

Subsequent published builds generate notes from first-parent commits since the
previous complete release, and include up to the last ten versions in What's New
with a link to the full release notes history on GitHub Releases. Merged pull
requests use their GitHub titles and labels; direct commits use their subjects.
Features, fixes, and other changes are grouped automatically. Write descriptive
titles; `bug`/`fix` and `enhancement`/`feature` labels take precedence over
title-prefix classification.

The version-stamped snapshot is signed into the app, while `validate --markdown`
writes only the current version's changes into the GitHub release body before
the existing install instructions. API failures, mismatched
versions, and changed release predecessors fail publication rather than silently
publishing stale or empty notes. `scripts/test-release-notes.py` exercises the
generator without network access.

### Writing a user-facing summary

Add a short plain-text paragraph under `## Release notes` in a pull request body:

```markdown
## Release notes

Paste screenshots directly into the session composer without switching apps.
```

The generator uses that paragraph instead of the PR title. Titles and labels
still determine the category. It ignores HTML comments and headings inside fenced
examples, takes only the first paragraph, and falls back to the title for an
absent/empty section, placeholders such as `N/A`, or non-paragraph content.
Summaries longer than 600 characters produce a warning and use the title.
Keep summaries self-contained and free of Markdown, mentions, and relative issue
references; the generator attaches the originating PR link automatically.
No model rewrites or invents release-note claims.

Like PR titles, summaries are read when the release is generated. Once generated,
the snapshot is frozen; later edits to a PR body do not change an installed app's
notes or retroactively update a published release.
