# Copilot Projects

A deliberately small macOS terminal app that organizes CLI sessions by **project**.
Projects are listed vertically in a sidebar; each project's terminal sessions are laid
out horizontally. It keeps the parts of [cmux](https://github.com/manaflow-ai/cmux) that
matter most for working with coding agents — **status indicators** and **notifications** —
and drops everything else.

![Copilot Projects — vertical project sidebar, terminal sessions as horizontal tabs](docs/screenshot.png)

It replaces cmux's Ghostty integration with
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)'s native Metal renderer,
with a CoreGraphics fallback. The result is a few Swift files instead of hundreds.

## Features

- **Projects (vertical sidebar):** a project is just a named group of sessions. Create one
  with `⌘N` (name it; no folder required). Jump to one with **`⌘1`–`⌘9`**.
- **Sessions (browser-style tabs):** each project shows a horizontal tab strip; one terminal
  is visible at a time. Add a tab with `⌘T`, switch with a click / **`⌃Tab`** (next) / `⌃⇧Tab`
  (prev) / **`⌃1`–`⌃9`** / `⌘⇧[` / `⌘⇧]`, close with `⌘W` or the tab's ✕. Background tabs keep
  running. Hold **⌘** (projects) or **⌃** (tabs) to see the number on each.
- **Status:** each session reports `idle` / `running` / `waiting`. Running and waiting
  counts appear in the sidebar; a blue dot on the session tab marks work that finished
  while you were away. With the Copilot CLI hooks installed (below), this is driven automatically.
- **Completed-turn drawer:** Copilot CLI remains the native interactive terminal, while a
  collapsible drawer overlays its right edge with independently scrollable completed turns.
  Live work, permissions, shortcuts, and input stay entirely in the CLI.
- **Schedules + background work:** queued scheduled prompts show a clock with cadence/next-run
  details; active scheduled turns and subagents use a separate background indicator instead of
  making the foreground session look busy.
- **Private remote control:** expose a mobile web terminal behind Cloudflare Access + GitHub SSO,
  with scrollback, safe clickable links, project/session status, live screen snapshots, and a
  single remote writer lease.
- **Notifications:** native macOS banners identify the originating project/session and
  automatically alert when Copilot has a question, needs permission, or finishes a task.
  Clicking one focuses that session. Remote web push provides the same timestamped events to
  subscribed browsers and installed iPhone/iPad Home Screen apps. Unread sessions get a bell
  badge + a Dock badge count.
- **Control socket + CLI:** the same `copilot-projects` binary is also a CLI that talks to the
  running app over a Unix socket — ideal for agent hooks.
- **Resumable sessions:** each terminal runs under a bundled [dtach](https://github.com/crigler/dtach),
  so quitting/relaunching/crashing the app does **not** kill your shells or in-flight agents.
  Relaunch reattaches. You can also `ssh` into the machine and `copilot-projects attach` to reconnect
  from another host.
- **Persistence:** projects/sessions are restored on relaunch.

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

`build-app.sh` runs `swift build`, assembles `dist/Copilot Projects.app`, precompiles
SwiftTerm's Metal shaders, and signs the nested executables inner-first. Local builds
default to ad-hoc signing; set `CODESIGN_IDENTITY` for Developer ID signing.

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

`scripts/release.sh` builds an Apple Silicon optimized app and drag-to-Applications DMG.
Publishing requires a Developer ID identity and a `notarytool` Keychain profile:

```bash
./scripts/release.sh 0.1.0             # -> dist/Copilot-Projects-0.1.0.dmg (local only)
CODESIGN_IDENTITY="Developer ID Application: …" \
NOTARY_PROFILE="copilot-projects-notary" \
./scripts/release.sh 0.1.0 --publish
```

`--publish` refuses ad-hoc artifacts, notarizes and staples both the app and DMG, runs
Gatekeeper checks, then uses the active `gh` account to publish. The Actions workflow
also fails closed until equivalent signing/notarization credentials are configured.

## CLI

Inside a copilot-projects terminal, `COPILOT_PROJECTS_PROJECT` / `COPILOT_PROJECTS_SESSION` /
`COPILOT_PROJECTS_SOCKET` are set, so commands auto-target the current session.

```bash
copilot-projects set-status running               # set the current session's status
copilot-projects set-status waiting --text "review my diff"
copilot-projects notify "Build finished" "All tests green"
copilot-projects list-projects
copilot-projects list-status
copilot-projects new-project myapp                # name only; --cwd optional
copilot-projects new-session --project <id> --cwd /tmp
copilot-projects focus --session <id>             # bring app forward + select
copilot-projects remote enable                    # enable the Cloudflare Access origin
copilot-projects remote status                    # print its private URL and state
copilot-projects remote disable
copilot-projects doctor                           # diagnose state/session/runtime health
copilot-projects version                          # print installed version
copilot-projects install-hooks                    # wire up Copilot CLI status hooks
copilot-projects help
```

Targeting flags (`--project`, `--session`) override the environment defaults.

### Remote access

Remote access is opt-in. The local gateway listens on `127.0.0.1:49272`; a separately managed
Cloudflare Tunnel maps the protected public hostname to that origin:

```bash
# Configure the Cloudflare Access application, then relaunch the app.
defaults write com.obvioussean.copilot-projects remoteAccess.hostname "projects.example.com"
defaults write com.obvioussean.copilot-projects remoteAccess.cloudflareTeamDomain \
  "your-team.cloudflareaccess.com"
defaults write com.obvioussean.copilot-projects remoteAccess.cloudflareAudience "your-access-aud-tag"
defaults write com.obvioussean.copilot-projects remoteAccess.allowedEmail "you@example.com"

copilot-projects remote enable
copilot-projects remote status
```

All four settings are required. Remote access fails closed and remains disabled when any setting
is missing.

When enabled, the status command prints the protected URL. Cloudflare Access performs GitHub SSO at the edge,
then injects a signed identity JWT into each forwarded request. The app independently verifies
that JWT's RS256 signature, issuer, audience, expiration, and allowed email; it also requires the
expected host and same-origin POSTs. Direct requests to the localhost origin without a valid
Access token are rejected.

The mobile web client can list projects, select a terminal, and acquire the single remote writer
lease. Its completed-turn pane mirrors the desktop drawer and includes a message composer. Sending
is enabled only when a fresh server-side check confirms Copilot is alive, fully idle, and has no
scheduled/background work; it clears any unsent desktop draft before submitting the message
through the native CLI input path. The full terminal remains available for permissions and other
TUI interactions. Remote clients do not resize the PTY because dtach shares one terminal size with
the desktop.

When Copilot asks a structured `ask_user` question, the extension heartbeat surfaces it (with its
verbatim choices) as a native question card in the remote client, temporarily replacing the
message composer. Choosing an option — or typing free-form text when the question allows it — is
delivered back to the exact live Copilot session over a lease-gated control message; a question
whose choices or payload are too large is never exposed remotely so the terminal fallback stays
exact. Answers are re-validated host-side against the fresh heartbeat before an atomic, private
response file hands them to the extension.

Normal-buffer sessions expose a bounded, independently scrollable history without moving the
desktop terminal viewport. Active Copilot/full-screen sessions forward web wheel gestures to the
existing TUI only while the remote client holds the writer lease. Terminal `http://`/`https://`
links are rendered as safe new-tab links.

Web Push is optional. Tap the bell in the remote toolbar to subscribe. Safari on iPhone/iPad
requires adding the site to the Home Screen first (iOS/iPadOS 16.4+); desktop Safari/Edge/Chrome
can subscribe directly. The app generates and keeps its VAPID private key in the macOS Keychain
and stores browser subscriptions under the private state directory. Web and native notifications
include the time the event was sent; clicking a web notification opens and selects its session.

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

So the status dot tracks a coding agent without any manual calls, copilot-projects installs a
[Copilot CLI hook](https://docs.github.com/copilot) bridge into `~/.copilot/hooks/`
(`copilot-projects-hook.sh` + `copilot-projects.json`) the first time the app launches. It maps the
agent lifecycle to status:

| Copilot CLI event | status |
| --- | --- |
| `sessionStart` | `idle` |
| `userPromptSubmitted` | `running` |
| `preToolUse` / `postToolUse` | `running` |
| `notification` (`elicitation_dialog` / `permission_prompt`) | `waiting` |
| `agentStop` | `idle` |
| `sessionEnd` | `idle` |
| `notification` (`session_idle`, supported by newer CLI versions) | authoritative `idle` after background work drains |

The hook no-ops outside a copilot-projects terminal (it checks `COPILOT_PROJECTS_SESSION`), so it
coexists with other integrations (e.g. cmux) and is safe to leave installed globally. Manage
it with `copilot-projects install-hooks` / `uninstall-hooks`. Start a new Copilot CLI session to
pick up changes.

The companion Copilot extension records completed root turns through the supported Copilot SDK
event API. It atomically writes a bounded per-tab transcript snapshot after each turn, including
stopped turns and compact tool summaries but excluding raw tool arguments and results. Copilot
Projects renders that snapshot in the drawer without parsing private CLI session files or
changing the terminal's PTY size.

The app also installs a read-only Copilot extension at
`~/.copilot/extensions/copilot-projects-tracker/extension.mjs`. It uses Copilot's session event
stream and `session.rpc.schedule.list()` to report queued schedules, foreground turns, and active
subagents. Existing CLI sessions need `/restart` (or a new session) after installing/upgrading the
extension.

While the app is running, the first elicitation or permission prompt and each successfully
completed turn also post a native macOS banner. The banner includes the project and session name,
and clicking it focuses the originating session. Repeated waiting events are suppressed, as are
completion alerts for aborted turns. `agentStop` signals completion on current CLI versions; the
app holds the banner while background agents remain active, and a later `session_idle` clears that
state without posting a duplicate.

**Status precedence.** Hook events are authoritative. Newer CLI versions emit `session_idle`
only after the root turn and all background work drain, including `aborted: true` for Esc-cancel.
After a session proves it supports that signal, Copilot Projects disables footer scraping for
that CLI process. Older versions keep the bounded footer classifier as a compatibility fallback;
the process-tree check remains a crash fallback. Tune detected process names with
`COPILOT_PROJECTS_AGENT_PROCESSES` (comma-separated, default `copilot`) or disable the liveness
check with `COPILOT_PROJECTS_LIVENESS=0`.

For other agents, call the CLI from their hooks directly:

```bash
copilot-projects set-status running
copilot-projects set-status waiting --text "needs approval"
copilot-projects notify "Agent needs input"
copilot-projects set-status idle
```

## Resumability & SSH reattach

Each session's shell runs under a bundled arm64 [dtach](https://github.com/crigler/dtach)
(GPLv2; source vendored in `vendor/dtach`). dtach forwards raw bytes — it is **not** a second
terminal emulator — so keyboard, title (OSC 0/2) and cwd (OSC 7) all stay native; SwiftTerm is
the only emulator.

- **Quit / relaunch / crash:** the dtach master daemonizes away from the app, so shells +
  agents keep running. Relaunch reattaches (`dtach -A`).
- **Close a tab (⌘W / ✕):** *ends* that session (kills its dtach master).
- **Reconnect from another host:**
  ```bash
  ssh you@mac
  copilot-projects ls                 # list sessions + ids
  copilot-projects attach <id|prefix> # raw reattach in this terminal (Ctrl-\ to detach)
  ```
- **Tradeoff:** scrollback *history* doesn't survive a detach (a full-screen TUI like copilot
  repaints on reattach; a plain shell starts fresh). Live scrollback while attached is normal.

Sockets live under `~/.local/state/copilot-projects/sessions/` on fresh installs. An install
migrated from the old `copilot-mux` name intentionally keeps using
`~/.local/state/copilot-mux/`, because live dtach masters have those socket paths baked into
their argv. `copilot-projects doctor` prints the active path and distinguishes the normal
master/client process pair from real orphaned masters. If the bundled dtach is missing,
sessions fall back to plain shells. Override it with `COPILOT_PROJECTS_DTACH`.

## Renderer

SwiftTerm's Metal renderer is the default. Set `COPILOT_PROJECTS_RENDERER=coregraphics`
before launching to use the fallback renderer. The dependency is pinned to an exact upstream
revision containing fixes for stale Metal rows/cursor, window reparenting, hidden-scroller
layout, and synchronized output.

## How it works

- One executable, two roles (`Sources/copilot-projects/main.swift`): a recognized subcommand runs
  the CLI client; anything else launches the SwiftUI app.
- `Sources/CopilotProjectsCore` is Foundation-only: paths, the JSON-line wire protocol, the socket
  client, and CLI parsing.
- `AppModel` is the SwiftUI coordinator. Versioned state persistence, activity evidence,
  control-command routing, session artifacts, and instance locking are separate components.
  Live SwiftTerm views stay outside the observable graph.
- `ControlServer` listens on `~/.local/state/copilot-projects/control.sock` (mode 0600 in a 0700
  dir); each connection is one JSON request → one JSON response.
- State is persisted to `~/.local/state/copilot-projects/state.json`.
  Existing pre-rebrand installs may use the legacy path described above. Writes are atomic,
  preserve a known-good backup, and never overwrite unreadable state with an empty workspace.

Override locations with `COPILOT_PROJECTS_SOCKET` and `COPILOT_PROJECTS_STATE_DIR` to run an isolated
instance. An app launched with either override does not replace the global CLI symlink or Copilot
hooks.

## License

MIT.
