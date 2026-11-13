import Foundation

/// Installs a Copilot CLI hook that tells the running app when a tab's Copilot
/// exits, so the app forgets which conversation that tab resumes. Status comes
/// from the session's tracker, not from here. The hook no-ops unless it runs
/// inside a Copilot Projects terminal (where the per-session env is set), so it is
/// safe to have configured globally and coexists with other integrations (e.g. cmux).
public enum CopilotHooks {
    public static var hooksDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/hooks", isDirectory: true)
    }

    public static var scriptURL: URL { hooksDir.appendingPathComponent("copilot-projects-hook.sh") }
    public static var configURL: URL { hooksDir.appendingPathComponent("copilot-projects.json") }

    /// True when the Copilot CLI hooks directory exists (CLI installed + used).
    public static var copilotPresent: Bool {
        FileManager.default.fileExists(atPath: hooksDir.path)
    }

    /// Reports `sessionEnd` to the app with `copilot-projects session-ended`.
    public static let script = #"""
    #!/usr/bin/env bash
    # Copilot Projects <-> Copilot CLI bridge (managed by Copilot Projects; safe to delete).
    # No-ops unless invoked inside a Copilot Projects terminal.
    set -u

    emit() { printf '{}\n'; }   # neutral hook result

    # A Copilot session started before this script was installed keeps calling it
    # for the events it registered then, until that session restarts.
    [ "${1:-}" = "end" ] || { emit; exit 0; }

    environment_session_id="${COPILOT_PROJECTS_SESSION:-}"
    socket="${COPILOT_PROJECTS_SOCKET:-}"
    if [ -z "$environment_session_id" ] && [ -z "$socket" ]; then
      emit
      exit 0
    fi

    # Derive the state dir from the socket env when present.
    if [ -n "$socket" ]; then
      state_dir="$(dirname "$socket")"
    else
      state_dir="$HOME/.local/state/copilot-projects"
    fi

    # A long-lived or nested shell can carry another tab's stale session env. The
    # native helper resolves the hook's parent through the actual dtach socket
    # ancestry. If the installed resolver cannot prove ownership, fail closed; only
    # old installs without the resolver retain the environment fallback.
    resolver="$HOME/.local/bin/copilot-projects"
    if [ -x "$resolver" ]; then
      session_id="$("$resolver" resolve-session --pid "$PPID" 2>/dev/null)" \
        || { emit; exit 0; }
    else
      session_id="$environment_session_id"
    fi
    # The session id becomes a filesystem path component below; a hostile env or
    # malformed resolver output must not escape the sessions directory.
    case "$session_id" in *[!0-9A-Fa-f-]*) emit; exit 0 ;; esac
    [ ${#session_id} -eq 36 ] || { emit; exit 0; }

    cli="$(command -v copilot-projects 2>/dev/null || true)"
    [ -z "$cli" ] && [ -x "$HOME/.local/bin/copilot-projects" ] && cli="$HOME/.local/bin/copilot-projects"

    # Extract the Copilot CLI session id (carried by hook payloads as "sessionId")
    # so sessionEnd can only clear resume markers for the process that owns them.
    payload_session_id() {
      local cid uuid
      uuid='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
      cid="$(printf '%s' "$1" \
        | /usr/bin/plutil -extract sessionId raw -o - - 2>/dev/null)" || return 0
      [[ "$cid" =~ $uuid ]] && printf '%s' "$cid"
      return 0
    }

    hook_has_other_owner() {
      local owner caller uuid
      uuid='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
      owner="$(cat "$state_dir/sessions/$session_id.copilot-session" 2>/dev/null \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ "$owner" =~ $uuid ]] || return 1
      # Tool arguments can contain other sessionIds; only the top-level identity
      # describes the hook sender. Unknown identities retain legacy behavior.
      caller="$(printf '%s' "$1" \
        | /usr/bin/plutil -extract sessionId raw -o - - 2>/dev/null)" || return 1
      [[ "$caller" =~ $uuid ]] || return 1
      [ "$(printf '%s' "$caller" | tr '[:upper:]' '[:lower:]')" \
        != "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" ]
    }

    # A nested `copilot` process (e.g. `copilot -p` or an SDK-spawned `copilot --server`
    # child) shares the tab's dtach ancestry, so `resolve-session` maps it to this tab.
    # While the tab's recorded owner CLI (`parentPid` in `transcript-owner.json`) is
    # alive on this boot, only hooks spawned by that owner CLI (directly or through
    # shell/sandbox wrappers) belong to this tab. In-process `task` subagents and `/new`
    # rotations still run inside `owner_parent_pid` and pass.
    hook_has_other_owner_process() {
      local owner_file owner_parent_pid owner_session owner_boot current_boot current_pid depth comm
      owner_file="$state_dir/sessions/$session_id.transcript-owner.json"
      [ -f "$owner_file" ] || return 1
      owner_parent_pid="$(sed -n \
        's/.*"parentPid":[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        "$owner_file" 2>/dev/null | head -1)"
      case "$owner_parent_pid" in
        ""|0|1|*[!0-9]*) return 1 ;;
      esac
      [ "$PPID" -eq "$owner_parent_pid" ] && return 1
      kill -0 "$owner_parent_pid" 2>/dev/null || return 1
      owner_session="$(sed -n \
        's/.*"appSessionId":[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$owner_file" 2>/dev/null | head -1)"
      if [ -n "$owner_session" ] \
        && [ "$(printf '%s' "$owner_session" | tr '[:upper:]' '[:lower:]')" \
          != "$(printf '%s' "$session_id" | tr '[:upper:]' '[:lower:]')" ]; then
        return 1
      fi
      owner_boot="$(sed -n \
        's/.*"bootTime":[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$owner_file" 2>/dev/null | head -1)"
      if [ -n "$owner_boot" ]; then
        current_boot="$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null || true)"
        if [ -n "$current_boot" ]; then
          # usec moves within one boot (see bootTimeSeconds in the tracker), so
          # compare whole seconds with the same 5-second tolerance.
          owner_boot="${owner_boot#*sec = }"
          owner_boot="${owner_boot%%,*}"
          current_boot="${current_boot#*sec = }"
          current_boot="${current_boot%%,*}"
          case "$owner_boot$current_boot" in ""|*[!0-9]*) return 1 ;; esac
          [ "$((owner_boot - current_boot))" -le 5 ] || return 1
          [ "$((current_boot - owner_boot))" -le 5 ] || return 1
        fi
      fi
      current_pid="$PPID"
      depth=0
      while [ "$depth" -lt 6 ]; do
        case "$current_pid" in
          ""|0|1|*[!0-9]*) return 1 ;;
        esac
        [ "$current_pid" -eq "$owner_parent_pid" ] && return 1
        comm="$(ps -o comm= -p "$current_pid" 2>/dev/null)" || return 1
        comm="${comm##*/}"
        comm="${comm#-}"
        case "$comm" in
          sh|bash|zsh|dash|ksh|fish|env|sandbox-exec)
            current_pid="$(ps -o ppid= -p "$current_pid" 2>/dev/null | tr -d '[:space:]')" || return 1
            depth=$((depth + 1))
            ;;
          *)
            break
            ;;
        esac
      done
      return 0
    }

    if hook_has_other_owner_process; then emit; exit 0; fi

    payload="$(cat 2>/dev/null || true)"
    if hook_has_other_owner "$payload"; then emit; exit 0; fi
    # Copilot reports both an explicit exit and a graceful macOS shutdown as
    # sessionEnd(reason=user_exit). Let the live app clear the resume marker only
    # when it is not terminating; if the app is shutting down or unreachable, the
    # marker survives for post-reboot resume.
    if [ -n "$cli" ]; then
      args=(session-ended --session "$session_id")
      copilot_session="$(payload_session_id "$payload")"
      [ -z "$copilot_session" ] || args+=(--copilot-session "$copilot_session")
      "$cli" "${args[@]}" >/dev/null 2>&1 || true
    fi
    emit
    exit 0
    """#

    /// Copilot CLI hook wiring: `sessionEnd` asks the live app to clear the resume
    /// marker, which it does unless it is terminating.
    public static let config = #"""
    {
      "version": 1,
      "hooks": {
        "sessionEnd": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-projects-hook.sh\" end", "timeoutSec": 5 }
        ]
      }
    }
    """#

    @discardableResult
    public static func install() throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        try Data(config.utf8).write(to: configURL, options: .atomic)
        return "Installed Copilot CLI hooks in \(hooksDir.path) "
            + "(copilot-projects-hook.sh, copilot-projects.json). Start a new Copilot CLI session to pick them up."
    }

    public static func uninstall() {
        let fm = FileManager.default
        for url in [scriptURL, configURL] {
            try? fm.removeItem(at: url)
        }
    }

    /// Best-effort install used at app launch. Only writes when something is out of
    /// date, so it won't churn a version-controlled `~/.copilot`.
    public static func installIfPossible() {
        guard copilotPresent, !upToDate() else { return }
        _ = try? install()
    }

    private static func upToDate() -> Bool {
        guard let s = try? String(contentsOf: scriptURL, encoding: .utf8), s == script,
              let c = try? String(contentsOf: configURL, encoding: .utf8), c == config
        else { return false }
        return true
    }
}
