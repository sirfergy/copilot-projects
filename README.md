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
- **Local PR reviews:** the shield button beside **New Session** accepts a GitHub pull request
  URL and opens a new Copilot CLI tab with a local adversarial-review prompt.
- **Status:** each session reports `idle` / `running` / `waiting`. Running and waiting
  counts appear in the sidebar; a blue dot on the session tab marks work that finished
  while you were away. With the Copilot CLI hooks installed (below), this is driven automatically.
- **Completed-turn drawer:** Copilot CLI remains the native interactive terminal, while a
  collapsible drawer overlays its right edge with independently scrollable completed turns
  rendered as Markdown. Live work, permissions, shortcuts, and input stay entirely in the CLI.
- **Schedules + background work:** queued scheduled prompts show a clock with cadence/next-run
  details; active scheduled turns and subagents use a separate background indicator instead of
  making the foreground session look busy.
- **Private remote control:** expose a mobile web terminal behind Cloudflare Access + GitHub SSO,
  with scrollback, safe clickable links, project/session status, live screen snapshots, and a
  single remote writer lease.
- **Notifications:** native macOS banners identify the originating project/session and
  automatically alert when Copilot has a question, needs permission, or finishes a task.
  Task completions include a short, plain-text preview of the completed turn's response
  on Mac, native iOS, and web push. Previews are derived locally (no extra model call),
  omit code blocks, and fall back to the generic alert when the matching transcript
  is unavailable. Response previews can appear on your devices' lock screens.
  Clicking one focuses that session. Remote web push provides the same timestamped events to
  subscribed browsers and installed iPhone/iPad Home Screen apps. Unread sessions get a bell
  badge + a Dock badge count. Completed tabs show one blue attention dot, not two.
  Returning to the Mac app marks the selected session read across devices without
  needing to switch tabs.
- **Control socket + CLI:** the same `copilot-projects` binary is also a CLI that talks to the
  running app over a Unix socket — ideal for agent hooks.
- **Resumable sessions:** each terminal runs under a bundled [dtach](https://github.com/crigler/dtach),
  so quitting/relaunching/crashing the app does **not** kill your shells or in-flight agents.
  Relaunch reattaches. You can also `ssh` into the machine and `copilot-projects attach` to reconnect
  from another host.
- **Persistence:** projects/sessions are restored on relaunch.
- **Window lifetime:** closing the last window quits by default. Enable **Keep Running When
  Window Closes** to keep remote access and sessions available from the menu bar; Dock reopen,
  menu-bar Open, notifications, and CLI focus all restore the main window. **Quit Copilot
  Projects** still performs the normal graceful detach and persistence drain.

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

The runtime assets are regular SwiftPM resources rather than embedded Swift literals. The
tracker remains one atomic `extension.mjs` install, while the PWA is assembled from reviewed
HTML/CSS/JavaScript files. The session-status rules live in the headless `SessionDomain`
package, and the Mac/iOS/PWA protocol examples share `ContractFixtures`.

```bash
swift test --package-path Packages/SessionDomain
./scripts/check-web-assets.sh
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

`copilot-projects install-cli [--dir DIRECTORY]` installs a launcher pointing to the real
running executable (default: `~/.local/bin`). It is safe to repeat through that launcher;
existing correct links and the executable itself are left untouched. Other symlinks are
replaced atomically. Conflicting regular files and directories are refused: move them
aside yourself or choose a different `--dir`. The app's automatic
launcher setup and the first step of `install-hooks` use the same behavior.

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

The native iOS client signs in through the system authentication browser so GitHub passkeys are
available. After Cloudflare verifies the user, `/auth/ios` encrypts the verified application JWT
to an ephemeral key generated by that specific login attempt before returning it to the app.
The bearer token is never placed in the callback URL in plaintext. Deploy the gateway update
before distributing an iOS build that uses this route; older iOS clients continue to work.

The mobile web client can list projects, select a terminal, and acquire the single remote writer
lease. Its Markdown-rendered completed-turn pane mirrors the desktop drawer and includes a message
composer with per-session drafts that survive session switches and reloads. Sending is enabled only
when a fresh server-side check confirms Copilot is alive, fully idle, and has no
scheduled/background work; it clears any unsent desktop draft before submitting the message through
the native CLI input path. The full terminal remains available for permissions and other TUI
interactions, with an on-screen Enter key alongside the other terminal controls. Remote clients do
not resize the PTY because dtach shares one terminal size with the desktop.

Updated clients negotiate `replay-safe-control` and a host-lifetime delivery epoch.
Prompt, input, key, and command retries retain their request ID and ordered delivery
sequence; an acknowledged prompt is removed from its original queue even after a tab
switch. The host acknowledges an exact replay without injecting it again. This is
replay-safe host acceptance, not proof that a shell command or Copilot turn finished.

A host restart, expired receipt, or ambiguous reply from an older host pauses delivery
instead of blindly repeating an action. Inspect the terminal before using **Discard
queued input** to continue; discarding does not retract input already accepted by the
host. Tab switches discard undispatched typing but retain an uncertain terminal
write for its originating session until acknowledged or explicitly discarded. An
uncertain queued prompt stays visible until removed; automatic replay requires a
known, unchanged conversation epoch. Older clients remain compatible, but need
updating (or a web-page reload) to gain replay-safe delivery.

The header's **New Session** controls let the remote user choose any project without changing the
Mac's selected project or tab. Creation is idempotent: the client generates one request id per
chosen project, retained across a network/5xx retry and cleared on success or when the host reports
the earlier session was already created and closed. The new session opens `$HOME/Repos` and
launches Copilot once on its fresh dtach master (resolving the CLI from an explicit override, then
`$HOME/.local/bin/copilot`, then the app's `PATH`). App-managed launches and resumes pass
`--no-remote --no-remote-export`: Copilot Projects remains their remote control plane and the
session does not depend on GitHub's remote event storage, including when a resumed session
previously persisted remote steering. The host records each creation in a private, bounded ledger
so a retried or replayed request is answered — 201 created, 200 existing, 409 collision,
410 already-closed, 422 unknown project or missing Repos, 503 Copilot unavailable — without ever
creating (or resurrecting) a second session. Hosts without this endpoint return 404, which the
client surfaces as unsupported.

When Copilot asks a structured `ask_user` question, the extension heartbeat surfaces it (with its
verbatim choices) as a native question card in the remote client, temporarily replacing the
message composer. Choosing an option — or typing free-form text when the question allows it — is
delivered back to the exact live Copilot session over a lease-gated control message; a question
whose choices or payload are too large is never exposed remotely so the terminal fallback stays
exact. Answers are re-validated host-side against the fresh heartbeat before an atomic, private
response file hands them to the extension.

Receipt-capable clients bind SDK answers, elicitations, and model switches to the current
conversation epoch. HTTP acceptance only means the host queued the handoff: the UI reports
success only after an `applied` receipt, permits an explicit retry after `rejected`, and blocks
automatic retry after `indeterminate` because the SDK may already have applied the operation.
Known older hosts keep the legacy optimistic path; a new host with missing or unknown tracker
metadata fails closed instead of silently downgrading.

The remote client also answers schema-form `elicitation.requested` questions the same way the
native iOS client does. A bounded, flat subset of the request's `requestedSchema`
(enum/`oneOf` choices, multi-select arrays, booleans, numbers, and length-bounded strings) is
rendered as a native form with Decline/Send-answer actions; url-mode requests offer a safe
new-tab **Open in browser** link with Decline/Done. Send stays disabled until every required
field holds a type-valid value, the submitted content is re-validated against the same subset,
and anything outside it (nested/`$ref`/unsupported schema, or a non-http(s) url) falls back to
"answer this one in the Copilot terminal" so arbitrary schema is never rendered. Accept, decline,
and cancel are delivered to the live session over the same lease-gated control message.

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
| `preToolUse` / `postToolUse` | Known non-owner: ignored. Owner or unknown identity: `running` (scheduled activity: `idle`). |
| `notification` (`elicitation_dialog` / `permission_prompt`) | `waiting` |
| `agentStop` | `idle` |
| `sessionEnd` | `idle` |
| `notification` (`session_idle`, supported by newer CLI versions) | authoritative `idle` after background work drains |

The hook no-ops outside a copilot-projects terminal (it checks `COPILOT_PROJECTS_SESSION`), so it
coexists with other integrations (e.g. cmux) and is safe to leave installed globally. Manage
it with `copilot-projects install-hooks` / `uninstall-hooks`. Start a new Copilot CLI session to
pick up changes.

App-managed Copilot launches and recorded-session resumes use a Ghostty-compatible profile so
Copilot CLI emits inline images through SwiftTerm's Kitty graphics support. The profile is scoped
to the Copilot process; plain shells and unrelated TUIs keep their original terminal identity.
For a manual shell launch with inline images, run
`/usr/bin/env -u TERM_PROGRAM_VERSION TERM_PROGRAM=ghostty copilot`. Existing Copilot processes
must be restarted with that profile; relaunching the app only reattaches their dtach master.
Independent of that local rendering, each terminal session bounds-checks and retains the same
Kitty-transmitted PNGs (fail-closed on anything outside the exact subset Copilot CLI emits) so a
remote client can fetch a captured image's exact bytes over the authenticated gateway once its
placement appears in a `screen` event; the image bytes themselves are never inlined into the SSE
JSON stream.

The companion Copilot extension records completed root turns through the supported Copilot SDK
event API. It atomically writes a bounded per-tab transcript snapshot after each turn, including
stopped turns and compact tool summaries but excluding raw tool arguments and results. Copilot
Projects renders that snapshot in the drawer without parsing private CLI session files or
changing the terminal's PTY size. The remote web view fetches the latest 50 turns and loads
older retained turns with **Show earlier**. The transcript endpoint accepts an optional
`limit` from 1 to 200 and includes `totalTurns` for a windowed response; clients that omit
`limit` continue to receive the full snapshot.

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

Sockets live under `~/.local/state/copilot-projects/sessions/`. `copilot-projects doctor`
prints the active path and distinguishes the normal master/client process pair from real
orphaned masters. If the bundled dtach is missing, sessions fall back to plain shells.
Override it with `COPILOT_PROJECTS_DTACH`.

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

### Renderer diagnostics

The fork records diagnostic events in unified logging under the static subsystem
`org.tirania.SwiftTerm`, category `MetalDiagnostics`. The process filter excludes test runs:

```sh
log show --last 1d --style compact --predicate 'process == "copilot-projects" AND subsystem == "org.tirania.SwiftTerm" AND category == "MetalDiagnostics"'
```

Events cover transient rasterization failures, actual Metal command errors, delayed completion
observations after a refused draw, and existing idle-wait timeouts. At most the first five events
of each kind per process are recorded (20 total); terminal contents, glyph identities, session
IDs, and paths are not logged.

A slow-completion warning means the completion callback has not been observed for more than
five seconds, **not** that a GPU hang is proven. Delay checks occur only on a subsequent draw
refusal or existing idle wait, not while a terminal is fully idle. This logging adds no timers,
watchdogs, automatic retries, or recovery policy.

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
- State is persisted to `~/.local/state/copilot-projects/state.json`. Writes are atomic, preserve
  a known-good backup, and never overwrite unreadable state with an empty workspace.

Override locations with `COPILOT_PROJECTS_SOCKET` and `COPILOT_PROJECTS_STATE_DIR` to run an isolated
instance. An app launched with either override does not replace the global CLI symlink or Copilot
hooks.

## License

MIT.
