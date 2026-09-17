# Copilot Projects: usage and development

A deliberately small macOS terminal app that organizes CLI sessions by **project**.
Projects are listed vertically in a sidebar; each project's terminal sessions are laid
out horizontally. It keeps the parts of [cmux](https://github.com/manaflow-ai/cmux) that
matter most for working with coding agents — **status indicators** and **notifications** —
and drops everything else.

This repository builds the standalone desktop app. Web access, tunnel authentication,
and remote push delivery are optional integrations maintained and built separately;
they are not dependencies or resources of the public desktop distribution.

See the [project overview](../README.md) for installation and a quick tour.

It replaces cmux's Ghostty integration with
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)'s native Metal renderer,
with a CoreGraphics fallback. The result is a few Swift files instead of hundreds.

## Features

- **Projects (vertical sidebar):** a project is just a named group of sessions. Create one
  with `⌘N` (name it; no folder required). Jump to one with **`⌘1`–`⌘9`**.
- **Sessions (browser-style tabs):** each project shows a horizontal tab strip; one terminal
  is visible at a time. Start Copilot with `⌘T` or a plain shell with `⌥⌘T`, switch with a click / **`⌃Tab`** (next) / `⌃⇧Tab`
  (prev) / **`⌃1`–`⌃9`** / `⌘⇧[` / `⌘⇧]`, close with `⌘W` or the tab's ✕. Background tabs keep
  running. Hold **⌘** (projects) or **⌃** (tabs) to see the number on each.
- **Prompt-first sessions:** the **+ Copilot** dropdown, Session menu, and project context
  menu offer **Start with Prompt…**. Compose multiple lines, then use `⌘Return` to launch
  an interactive session (not a one-shot/headless command). Cancel creates no tab.
  Startup checks retain the draft on failure; after a tab opens, **Copy Starting Prompt**
  in its context menu recovers the prompt until that tab closes or the app quits.
  Prompts are never retried automatically. All new desktop Copilot sessions use
  `--allow-all`, with or without a starting prompt.
- **Local PR reviews:** the shield button beside **+ Copilot** accepts a GitHub pull request
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
- **Question recovery:** the tracker also reads question events on its five-second heartbeat,
  so a missed live notification does not leave clients stuck on **Open terminal**.
  Text, choices, and other supported forms use the original response ID. This works with
  the existing CLI event API; no new CLI version is required for missed-event recovery.
  An optional pending-question snapshot API also recovers older prompts on supporting CLIs.
  If completions free slots after bounded staging overflows, the tracker replays that
  window before selecting the remaining forms; staging and per-heartbeat read limits stay unchanged.
  If a question has already left the CLI's in-memory event history and no snapshot is
  available, it remains answerable through **Open terminal** rather than a guessed response ID.
- **Notifications:** native macOS banners identify the originating project/session and
  automatically alert when Copilot has a question, needs permission, or finishes a task.
  Task completions include a short, plain-text preview of the completed turn's response
  on Mac. Optional integrations receive the same event. Previews are derived locally (no extra model call),
  omit code blocks, and fall back to the generic alert when the matching transcript
  is unavailable. Response previews can appear on your devices' lock screens.
  Clicking one focuses that session. Unread sessions get a bell
  badge + a Dock badge count. Completed tabs show one blue attention dot, not two.
  Returning to the Mac app marks the selected session read without
  needing to switch tabs.
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

With Copilot CLI 1.0.84 or newer on SDK protocol 3, the tracker offers native
session controls to the desktop and optional integrations. Separately built iOS and web composers
can **Run after current task** or **Steer current task** without clearing the
desktop CLI draft. **Stop task** requests cancellation without closing the tab,
shell, or dtach session. Terminal controls remain available for other TUIs and
unsupported CLI versions.

Native actions retain the writer lease, conversation identity, and SDK operation
receipt checks. HTTP acceptance is not completion. A send's `applied` receipt
means Copilot accepted the message, not that it finished the task. Unknown
outcomes are never automatically resubmitted or downgraded to terminal input.
The web queue removes the confirmed message when its receipt arrives, without
another click or tab switch; messages still awaiting confirmation stay visible.
Stop has its own handoff lane, so an unresolved send cannot block cancellation.

The session drawer and native/web conversation views render live response updates
within their conversation turns. Final messages replace their matching streamed text.

**Usage and background work** shows accumulated session AI credits, the latest
context observation, active agents, and schedules. Session totals and the current
budget accounting window are deliberately separate. Users can opt into an AI-credit
soft limit (minimum 30), remove it, or answer a live exhausted-budget request by
adding credits or cancelling the blocked model request. There is no default limit.
Limits are checked by Copilot after model calls and can be exceeded by the last
call. A new budget request sends a Mac notification and an event to any installed integration.

Capabilities require fresh runtime evidence; unsupported or unavailable operations
stay disabled. A host advertising native workflows treats missing session workflow
state as unknown, not permission to use the legacy composer. Legacy composer sends
require an older host or explicit fallback from a currently available tracker.
Unsupported-runtime proof can remain valid without a recent native-action
observation; raw terminal input is independent of these composer checks.
Older trackers on a newer host remain blocked even with a fresh heartbeat:
restart/reload the tracker to activate the updated workflow metadata, or use Terminal.
Deploy the Mac host before clients using the new protocol.

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

`build-app.sh` runs `swift build`, assembles `dist/Copilot Projects.app`, precompiles
SwiftTerm's Metal shaders, and signs the nested executables inner-first. Local builds
use an available Developer ID identity, falling back to ad-hoc signing. Set
`CODESIGN_IDENTITY=-` to force ad-hoc signing for a validation build.

The runtime assets are regular SwiftPM resources rather than embedded Swift literals. The
tracker remains one atomic `extension.mjs` install. The session-status rules live in the headless `SessionDomain`
package, and the Mac/iOS/PWA protocol examples share `ContractFixtures`.

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
It automatically publishes the next patch version for eligible PR merges to `main`.
To publish a specific new version, dispatch the workflow from `main`:

```bash
gh workflow run release.yml \
  --repo sirfergy/copilot-projects \
  --ref main \
  -f version=X.Y.Z
```

Replace `X.Y.Z` with an unused semantic version. The workflow runs validation and
tests before entering the protected `release` environment for signing and publishing.

#### Local builds and fallback publishing

`scripts/release.sh` builds an Apple Silicon optimized app and drag-to-Applications DMG.

```bash
./scripts/release.sh 0.1.0             # -> dist/Copilot-Projects-0.1.0.dmg (local only)
```

Use direct script publishing only as a fallback when the Actions runner or signing
configuration is unavailable. Run the release validation and tests first; this path
does not run the workflow's validation job or protected environment approvals.
It requires a Developer ID identity and a `notarytool` Keychain profile:

```bash
CODESIGN_IDENTITY="Developer ID Application: …" \
NOTARY_PROFILE="copilot-projects-notary" \
./scripts/release.sh 0.1.0 --publish
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

An integration can reuse the same pipeline without copying release logic:

```bash
GITHUB_REPOSITORY=owner/integration \
CODESIGN_IDENTITY="Developer ID Application: …" \
NOTARY_PROFILE="copilot-projects-notary" \
/absolute/public-checkout/scripts/release.sh 0.1.0 \
  --project-root=/absolute/integration-checkout --publish
```

`--project-root` requires an absolute Git worktree root and an explicit
`GITHUB_REPOSITORY`. That root owns HEAD, `origin`, release tags, predecessor
checks, cleanup, and `dist`. Its executable `scripts/build-app.sh --release` must
honor `VERSION` and `CODESIGN_IDENTITY` and emit `dist/Copilot Projects.app`,
including the existing app identity and resources. Build outputs must be ignored;
tracked source or HEAD changes during the build abort publication. HTTPS,
`git@github.com:owner/repo`, and `ssh://git@github.com/owner/repo` origin URLs are
supported (including Git URL rewrites); unknown hosts or mismatched targets fail
closed. No override keeps the standalone public release behavior, including
dirty/offline local builds without `--publish`.

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

### Optional integrations

The standard app is desktop-only: it includes no HTTP listener, web client,
Cloudflare integration, APNs provider, or web-push service.
The `remote` CLI command reports that the integration is unavailable and leaves
previously saved remote settings unchanged.

`CopilotProjectsHost` is also a Swift package product. An integrating application
calls `CopilotProjectsApplication.run(makeIntegration:checkIntegrationAssets:)`
to register its optional `HostIntegration` before SwiftUI creates the app delegate.
The typed `SessionHost` boundary keeps live terminals, transcript/image capture,
and replay-safe session mutations owned by the desktop host. CLI-only invocations
do not construct an integration.

Shared `CopilotProjectsProtocol`, `CopilotProjectsUI`, and protocol fixtures remain
public and usable by existing clients. They do not require a private dependency.
An integrating app can reuse `scripts/build-app.sh` with `--binary`, `--resources`,
and `--output`; its executable must include its additional assets in `check-assets`.
The normal build and release do not resolve or bundle optional integrations.

#### Configured remote session creation

An integrating gateway can expose `RemoteSessionContract.configuredCreatePath`
(`sessions/create-configured`) and pass its decoded `RemoteCreateSessionRequest`
to `SessionHost.createConfiguredSession`. In addition to `requestId` and
`projectId`, the request accepts optional `kind` (`copilot` or `terminal`) and `initialPrompt`.
Omitted kind means Copilot; omitted prompt means an unprompted session. Copilot
uses `--allow-all`; a terminal opens a plain shell without requiring Copilot.
Both retain the remote `~/Repos` working-directory and desktop-selection policy.

A supplied prompt must be nonempty after whitespace trimming, at most 8,192
UTF-8 bytes after CRLF/CR normalization to LF, and free of terminal control
characters other than line breaks and tabs. Terminal requests cannot carry a
prompt. Configured creation rejects `pullRequestURL`; the separate review route
accepts its canonical PR URL and rejects `kind` and `initialPrompt`.

Gateways and `SessionHost.createSession` reject launch options on the legacy
`sessions/create` route. Gateways must
expose the configured route only when the host advertises the
`configured-session-creation` protocol capability. Clients must not
fall back to the legacy endpoint when configured creation is unsupported: older
hosts ignore unknown JSON fields and could otherwise silently drop the prompt
or launch Copilot instead of a terminal. Allow enough JSON body space for an
escaped maximum-size prompt.
Custom `SessionHost` implementations that do not honor these options must
publish protocol metadata without `configured-session-creation`.
The public `RemoteProtocolInfo` initializer accepts a filtered
`RemoteProtocolInfo.current.capabilities` array; other capabilities need not be
copied into a hard-coded list.
The default `createConfiguredSession` implementation returns unavailable rather
than falling back to a conformer's legacy `createSession` implementation.

Keep an immutable request body and UUID for an explicit retry after a network
or 5xx error. Do not automatically resubmit prompts, reuse a UUID after changing
the project or launch options, or retain pending retries indefinitely. A matching
retry returns the original session, even if it moved projects; a changed intent
returns 409. Historical sessions without an intent fingerprint accept retries
only through the legacy `sessions/create` route. Configured and review routes
return 409 for those unverifiable historical replays, including optionless
configured requests and old review attempts. The host persists intent hashes,
not starting-prompt text.
An existing terminal socket without a stored intent cannot satisfy a configured
or review create, even if its master may have exited; it returns 409 rather than assuming
the requested intent is safe to repeat. Fresh configured and review
launches clear stale Copilot resume markers before creating a terminal.

Binding survives workspace or ledger repair while either retains the intent.
Closed-session tombstones remain bounded to seven days and 512 records; after
expiry or eviction a UUID can create again. Launch still precedes workspace and
ledger persistence, so this is not an exactly-once guarantee across a crash that
loses all creation evidence and the terminal master.

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
| `userPromptSubmitted` | Known non-owner: ignored. Owner or unknown identity: `running` (scheduled prompt: `idle`). |
| `preToolUse` / `postToolUse` | Known non-owner: ignored. Owner or unknown identity: `running` (scheduled activity: `idle`). |
| `notification` (`elicitation_dialog` / `permission_prompt`) | `waiting`, including prompts from children; accepts current `notificationType` and legacy `notification_type`. |
| `agentStop` / `sessionEnd` | Owner or unknown identity: `idle`. Known non-owner: ignored. |
| Legacy `notification` (`session_idle`) | Owner-only `idle` after background work drains. |

The hook no-ops outside a copilot-projects terminal (it checks `COPILOT_PROJECTS_SESSION`), so it
coexists with other integrations (e.g. cmux) and is safe to leave installed globally. Manage
it with `copilot-projects install-hooks` / `uninstall-hooks`. Changing hook registration requires
a new CLI session; an existing registration reads script-only updates on its next invocation.
The `agent_idle` notification describes a child agent and is never treated as foreground idle.

App-managed Copilot launches and recorded-session resumes use a Ghostty-compatible profile so
Copilot CLI emits inline images through SwiftTerm's Kitty graphics support. The profile is scoped
to the Copilot process; plain shells and unrelated TUIs keep their original terminal identity.
For a manual shell launch with inline images, run
`/usr/bin/env -u TERM_PROGRAM_VERSION TERM_PROGRAM=ghostty copilot`. Existing Copilot processes
must be restarted with that profile; relaunching the app only reattaches their dtach master.
Independent of that local rendering, each terminal session bounds-checks and retains the same
Kitty-transmitted PNGs (fail-closed on anything outside the exact subset Copilot CLI emits).
The host API exposes exact image versions to optional integrations without exposing mutable
terminal views.

The companion Copilot extension records completed root turns through the supported Copilot SDK
event API. It atomically writes a bounded per-tab transcript snapshot after each turn, including
stopped turns and compact tool summaries but excluding raw tool arguments and results. Copilot
Projects renders that snapshot in the drawer without parsing private CLI session files or
changing the terminal's PTY size. The host API supports full or bounded transcript windows
for optional integrations; image association always precedes windowing.

The app also installs a read-only Copilot extension at
`~/.copilot/extensions/copilot-projects-tracker/extension.mjs`. It uses Copilot's session event
stream and SDK metadata queries to report queued schedules, coordinator activity, and active
subagents. Existing CLI sessions must reload the tracker extension or use `/restart` after
installing/upgrading it. Wait for current work and interactive prompts to finish before restarting.
Relaunching Copilot Projects only reattaches the terminals; it does not reload their extensions.

While the app is running, the first elicitation or permission prompt and each successfully
completed turn also post a native macOS banner. The banner includes the project and session name,
and clicking it focuses the originating session. Repeated waiting events are suppressed, as are
completion alerts for aborted turns. The owner's `agentStop` signals completion; the app holds
the banner while background agents remain active. The SDK's root `session.idle` clears the
background indication once that work drains. A child's stop never consumes the foreground's
completion marker or advances its clocks.

**Status precedence.** Pending questions and permissions block sending independently of foreground
and background activity. The tracker observes the local coordinator's processing state over the
SDK, fenced to its current conversation and to the query's start time. Root `assistant.idle`
refreshes that observation; an individual model iteration's `assistant.turn_end` is not proof
the coordinator finished. Background agents do not make an idle coordinator busy.
Permission completions delivered during tracker startup retain their sender certificate even
when SDK history includes the same events; historical-only completions do not create certificates.

The host uses fresh runtime observations for status and prompt eligibility without rewriting
ordering clocks to heartbeat time. Input waits are released only by matching, same-conversation
completion evidence after the wait, with no other input pending. Submitted prompts remain fenced
until the coordinator acknowledges activity. Suppressed permission notifications use the same
sender-scoped completion check before restoring status. Terminal footer checks still protect modal UI,
including when a draft or autopilot changes the visible shortcut hints; unknown and modal
footers do not become permission to inject text.

Confirmed input-wait resolution is persisted at the existing ordering clocks before runtime
reconciliation clears the live wait. Notification debounce controls banner timing, not whether a
completed wait can be saved; suppressed repeat notifications still refresh the retained clocks.

Older trackers and explicitly unsupported/remote CLI runtimes retain the legacy path.
During a mixed-version upgrade, same-conversation snapshots with all pending-input fields
known empty can release legacy waits; missing fields or a changed conversation do not.
A failed or expired observation from a supported tracker is unknown, not idle. The process-tree
check remains a crash fallback. Tune detected process names with
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
hooks.

## License

[MIT](../LICENSE). The bundled `dtach` helper is licensed under GPLv2; its source is
included in [`vendor/dtach`](../vendor/dtach).
