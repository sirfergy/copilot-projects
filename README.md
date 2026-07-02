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
  counts appear in the sidebar; a blue dot marks work that finished while you were away.
  With the Copilot CLI hooks installed (below), this is driven automatically.
- **Notifications:** post a native macOS banner from any session; clicking it focuses the
  originating project/session. Unread sessions get a bell badge + a Dock badge count.
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

The app is ad-hoc signed (not notarized), so macOS Gatekeeper quarantines the download.
Clear it once, then launch normally:

```bash
xattr -dr com.apple.quarantine "/Applications/Copilot Projects.app"
```

Requires macOS 13+. Apple Silicon (arm64).

## Build & run

Requires Xcode 15+ (Swift 5.9+), macOS 13+.

```bash
./scripts/build-app.sh --launch        # debug build -> dist/Copilot Projects.app, then open it
./scripts/build-app.sh --release        # optimized build
```

`build-app.sh` runs `swift build`, assembles `dist/Copilot Projects.app` (with `Info.plist`,
the SwiftTerm resource bundle, and an ad-hoc code signature so notifications work), and
prints the app path.

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

The primary release path is **Actions → Release → Run workflow**. Enter an `X.Y.Z`
version while dispatching from `main`; the workflow validates the version/tag, runs the
tests on an Apple Silicon runner, builds the app and DMG, and publishes the GitHub release.

`scripts/release.sh` is the local fallback. It builds the optimized `.app`, packages a
drag-to-Applications DMG, and (with `--publish`) creates the GitHub release + tag:

```bash
./scripts/release.sh 0.1.0             # -> dist/Copilot-Projects-0.1.0.dmg (local only)
./scripts/release.sh 0.1.0 --publish   # also publishes the GitHub release
```

`--publish` uses the active `gh` account, so run it as the account that owns the repo. The
DMG is ad-hoc signed (not notarized); the generated release notes tell users to clear the
download quarantine once with `xattr`.

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
copilot-projects doctor                           # diagnose state/session/runtime health
copilot-projects version                          # print installed version
copilot-projects install-hooks                    # wire up Copilot CLI status hooks
copilot-projects help
```

Targeting flags (`--project`, `--session`) override the environment defaults.

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

Each session's shell runs under a bundled, universal [dtach](https://github.com/crigler/dtach)
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

Override locations with `COPILOT_PROJECTS_SOCKET` and `COPILOT_PROJECTS_STATE_DIR` (useful for running
an isolated instance).

## License

MIT.
