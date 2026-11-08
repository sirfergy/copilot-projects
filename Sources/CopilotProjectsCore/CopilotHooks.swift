import Foundation

/// Installs a Copilot CLI hook bridge so a coding agent's lifecycle drives the
/// session status dot automatically. The hook no-ops unless it runs inside a
/// Copilot Projects terminal (where the per-session env is set), so it is safe to
/// have configured globally and coexists with other integrations (e.g. cmux).
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

    /// Maps agent lifecycle events to `copilot-projects set-status`.
    public static let script = #"""
    #!/usr/bin/env bash
    # Copilot Projects <-> Copilot CLI status bridge (managed by Copilot Projects; safe to delete).
    # No-ops unless invoked inside a Copilot Projects terminal.
    set -u

    emit() { printf '{}\n'; }   # neutral hook result

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

    status_record_prompt_timestamp() {
      local record value
      record="$state_dir/sessions/$session_id.status-record.json"
      value="$(sed -n \
        's/.*"promptStatusTimestamp":[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        "$record" 2>/dev/null | head -1)"
      case "$value" in
        ""|*[!0-9]*) printf '' ;;
        *) printf '%s' "$value" ;;
      esac
    }
    persist_status_record() {
      local timestamp prompt_timestamp record record_tmp waiting_context
      timestamp="$2"
      [ -n "$timestamp" ] || return 1
      prompt_timestamp="$timestamp"
      if [ "${3:-}" = "scheduled-active" ]; then
        prompt_timestamp="$(status_record_prompt_timestamp)"
        # No prior foreground clock is unusual, but advancing is the safe fallback:
        # it blocks background-only prompt injection rather than trusting no clock.
        [ -n "$prompt_timestamp" ] || prompt_timestamp="$timestamp"
      fi
      record="$state_dir/sessions/$session_id.status-record.json"
      record_tmp="$record.$$"
      waiting_context=null
      if [ "$1" = "waiting" ]; then
        waiting_context="$(input_wait_context "${4:-}")"
      fi
      case "$waiting_context" in
        null|\{*\}) ;;
        *) waiting_context=null ;;
      esac
      (
        umask 077
        printf '{"schemaVersion":1,"status":"%s","statusTimestamp":%s,"promptStatusTimestamp":%s,"inputWait":%s}\n' \
          "$1" "$timestamp" "$prompt_timestamp" "$waiting_context" > "$record_tmp"
      ) || { rm -f "$record_tmp" 2>/dev/null || true; return 1; }
      mv -f "$record_tmp" "$record" 2>/dev/null \
        || { rm -f "$record_tmp" 2>/dev/null || true; return 1; }
    }
    # Persist status and both ordering clocks as one atomic record (survives an app
    # restart and stays current even while the app isn't running), then notify the
    # live app.
    status() {
      mkdir -p "$state_dir/sessions" 2>/dev/null || true
      if [ -n "${2:-}" ]; then
        persist_status_record "$1" "$2" "${3:-}" "${5:-}" || true
      fi
      # Synchronous (not backgrounded) so rapid transitions — e.g. running→waiting —
      # reach the app in order; backgrounding let them race and the "waiting" dot get
      # overwritten by a late "running". The CLI bounds this call with a socket
      # timeout, so a hung app can't block the hook past its deny-triggering timeout.
      if [ -n "$cli" ]; then
        args=(set-status "$1" --session "$session_id")
        [ -z "${2:-}" ] || args+=(--timestamp "$2")
        [ -z "${3:-}" ] || args+=(--source "$3")
        [ -z "${4:-}" ] || args+=(--notification "$4")
        [ -z "${5:-}" ] || args+=(--copilot-session "$5")
        "$cli" "${args[@]}" >/dev/null 2>&1 || true
      fi
    }
    current_status() {
      local record value
      record="$state_dir/sessions/$session_id.status-record.json"
      value="$(sed -n 's/.*"status":[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$record" 2>/dev/null | head -1)"
      printf '%s' "$value"
    }
    mark_turn_active() {
      mkdir -p "$state_dir/sessions" 2>/dev/null || true
      : > "$state_dir/sessions/$session_id.active-turn"
    }
    consume_active_turn() {
      rm "$state_dir/sessions/$session_id.active-turn" 2>/dev/null
    }
    payload_timestamp() {
      local value kind
      kind="$(printf '%s' "$1" \
        | /usr/bin/plutil -type timestamp - 2>/dev/null)" || return 0
      [ "$kind" = "integer" ] || return 0
      value="$(printf '%s' "$1" \
        | /usr/bin/plutil -extract timestamp raw -o - - 2>/dev/null)" || value=""
      case "$value" in
        ""|*[!0-9]*) printf '' ;;
        *) printf '%s' "$value" ;;
      esac
    }
    payload_notification_type() {
      local value kind key
      key=notificationType
      kind="$(printf '%s' "$1" \
        | /usr/bin/plutil -type "$key" - 2>/dev/null)" || {
          key=notification_type
          kind="$(printf '%s' "$1" \
            | /usr/bin/plutil -type "$key" - 2>/dev/null)" || return 0
        }
      [ "$kind" = "string" ] || return 0
      value="$(printf '%s' "$1" \
        | /usr/bin/plutil -extract "$key" raw -o - - 2>/dev/null)" || value=""
      printf '%s' "$value"
    }
    input_notification_kind() {
      case "$(payload_notification_type "$1")" in
        elicitation_dialog) printf 'elicitation' ;;
        permission_prompt) printf 'permission' ;;
      esac
    }
    is_aborted() {
      printf '%s' "$1" | grep -qE '"aborted"[[:space:]]*:[[:space:]]*true'
    }
    is_scheduled_prompt() {
      printf '%s' "$1" | grep -qE '\[Scheduled prompt #[0-9]+\]'
    }
    scheduled_turn="$state_dir/sessions/$session_id.scheduled-turn"
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

    input_wait_context() {
      local caller owner snapshot_owner epoch snapshot uuid
      uuid='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
      caller="$1"
      owner="$(cat "$state_dir/sessions/$session_id.copilot-session" 2>/dev/null \
        | tr -d '[:space:]')"
      snapshot="$state_dir/sessions/$session_id.agent-activity.json"
      snapshot_owner="$(/usr/bin/plutil -extract copilotSessionId raw -o - "$snapshot" 2>/dev/null)" \
        || snapshot_owner=""
      epoch="$(/usr/bin/plutil -extract conversationEpoch raw -o - "$snapshot" 2>/dev/null)" \
        || epoch=""
      if [[ "$caller" =~ $uuid ]] && [[ "$owner" =~ $uuid ]] \
        && [ "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" \
          = "$(printf '%s' "$snapshot_owner" | tr '[:upper:]' '[:lower:]')" ] \
        && [[ "$epoch" =~ ^[0-9A-Fa-f-]{36}:[0-9]+$ ]]; then
        printf '{"senderSessionId":"%s","rootSessionId":"%s","conversationEpoch":"%s"}' \
          "$caller" "$owner" "$epoch"
      else
        printf 'null'
      fi
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
        [ -z "$current_boot" ] || [ "$owner_boot" = "$current_boot" ] || return 1
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

    case "${1:-}" in
      start)
        payload="$(cat 2>/dev/null || true)"
        rm -f "$state_dir/sessions/$session_id.background-agents" 2>/dev/null || true
        rm -f "$state_dir/sessions/$session_id.active-turn" 2>/dev/null || true
        rm -f "$scheduled_turn" 2>/dev/null || true
        status idle "$(payload_timestamp "$payload")"
        ;;
      running)
        payload="$(cat 2>/dev/null || true)"
        # Child prompts must not start a foreground turn or advance its clock.
        if hook_has_other_owner "$payload"; then emit; exit 0; fi
        if is_scheduled_prompt "$payload"; then
          mkdir -p "$state_dir/sessions" 2>/dev/null || true
          : > "$scheduled_turn"
          rm -f "$state_dir/sessions/$session_id.active-turn" 2>/dev/null || true
          status idle "$(payload_timestamp "$payload")" scheduled-start
        else
          rm -f "$scheduled_turn" 2>/dev/null || true
          mark_turn_active
          status running "$(payload_timestamp "$payload")"
        fi
        ;;
      idle)
        payload="$(cat 2>/dev/null || true)"
        if hook_has_other_owner "$payload"; then emit; exit 0; fi
        if [ -f "$scheduled_turn" ]; then
          : > "$scheduled_turn"
          status idle "$(payload_timestamp "$payload")" scheduled-idle
          rm -f "$scheduled_turn" 2>/dev/null || true
          emit
          exit 0
        fi
        source=""
        if consume_active_turn && ! is_aborted "$payload"; then
          source="agent-stop"
        fi
        status idle "$(payload_timestamp "$payload")" "$source" "" "$(payload_session_id "$payload")"
        ;;
      pre|post)
        payload="$(cat 2>/dev/null || true)"
        # A child shares the terminal, not its foreground prompt or status clock.
        if hook_has_other_owner "$payload"; then emit; exit 0; fi
        if [ -f "$scheduled_turn" ]; then
          : > "$scheduled_turn"
          status idle "$(payload_timestamp "$payload")" scheduled-active
        else
          mark_turn_active
          status running "$(payload_timestamp "$payload")"
        fi
        ;;
      notify)
        payload="$(cat 2>/dev/null || true)"
        timestamp="$(payload_timestamp "$payload")"
        notification="$(input_notification_kind "$payload")"
        [ -n "$notification" ] || { emit; exit 0; }
        previous_status="$(current_status)"
        if [ "$previous_status" = "waiting" ]; then
          status waiting "$timestamp" "" "" "$(payload_session_id "$payload")"
        else
          status waiting "$timestamp" "" "$notification" "$(payload_session_id "$payload")"
        fi
        ;;
      end)
        payload="$(cat 2>/dev/null || true)"
        if hook_has_other_owner "$payload"; then emit; exit 0; fi
        # Copilot reports both an explicit exit and a graceful macOS shutdown as
        # sessionEnd(reason=user_exit). Let the live app clear the resume marker only
        # when it is not terminating; if the app is shutting down or unreachable, the
        # marker survives for post-reboot resume.
        rm -f "$state_dir/sessions/$session_id.background-agents" 2>/dev/null || true
        rm -f "$state_dir/sessions/$session_id.active-turn" 2>/dev/null || true
        rm -f "$scheduled_turn" 2>/dev/null || true
        status idle "$(payload_timestamp "$payload")" session-end "" "$(payload_session_id "$payload")"
        ;;
    esac
    emit
    exit 0
    """#

    /// Copilot CLI hook wiring (one entry per lifecycle event). sessionStart resets
    /// to idle so a fresh agent never reads as running; tool events keep it running;
    /// the notification hook surfaces "waiting" when the agent raises an ask_user /
    /// permission prompt (which fire no tool hook); sessionEnd (`end`) resets to idle
    /// and asks the live app to clear the resume marker unless the app is terminating.
    public static let config = #"""
    {
      "version": 1,
      "hooks": {
        "sessionStart": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-projects-hook.sh\" start", "timeoutSec": 5 }
        ],
        "userPromptSubmitted": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-projects-hook.sh\" running", "timeoutSec": 5 }
        ],
        "preToolUse": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-projects-hook.sh\" pre", "timeoutSec": 10 }
        ],
        "postToolUse": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-projects-hook.sh\" post", "timeoutSec": 10 }
        ],
        "notification": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-projects-hook.sh\" notify", "timeoutSec": 5 }
        ],
        "agentStop": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-projects-hook.sh\" idle", "timeoutSec": 5 }
        ],
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
