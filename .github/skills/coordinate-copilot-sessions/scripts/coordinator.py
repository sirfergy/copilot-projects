#!/usr/bin/env python3
"""Coordinator CLI helper for launching, staggering, monitoring, and steering
parallel Copilot Projects sessions without doing track work in the coordinator."""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable, Iterable

MAX_PROMPT_BYTES = 8_192
DEFAULT_APP_BIN = "/Applications/Copilot Projects.app/Contents/MacOS/copilot-projects"
DEFAULT_SOCKET_PATH = str(
    Path.home() / ".local" / "state" / "copilot-projects" / "control.sock"
)

PROJECT_LINE_RE = re.compile(
    r"^(?:(?P<selected>\*)\s+|\s*)\[(?P<status>[^\]]+)\]\s+(?P<name>.+?)\s+\(\d+\s+sessions?\)\s+(?P<id>\S+)\s*$"
)
STATUS_LINE_RE = re.compile(
    r"^(?P<project>.+?)/(?P<title>.+?)\s\s+(?P<status>idle|running|waiting)(?P<unread>\s+\[unread\])?(?:\s+—\s+(?P<status_text>.*))?\s\s+(?P<id>\S+)\s*$"
)


class CoordinatorError(RuntimeError):
    """Raised when a coordinator operation fails validation or execution."""


@dataclass(frozen=True)
class ProjectEntry:
    id: str
    name: str
    status: str
    selected: bool


@dataclass(frozen=True)
class SessionEntry:
    id: str
    project: str
    title: str
    status: str
    unread: bool
    status_text: str | None


def app_binary() -> str:
    override = os.environ.get("COPILOT_PROJECTS_BIN")
    if override:
        return override
    if Path(DEFAULT_APP_BIN).is_file():
        return DEFAULT_APP_BIN
    return "copilot-projects"


def control_socket_path(env: dict[str, str] | None = None) -> str:
    environment = env if env is not None else os.environ
    override = environment.get("COPILOT_PROJECTS_SOCKET", "").strip()
    if override:
        return override
    state_dir = environment.get("COPILOT_PROJECTS_STATE_DIR", "").strip()
    if state_dir:
        return str(Path(state_dir).expanduser() / "control.sock")
    default_socket = Path(DEFAULT_SOCKET_PATH)
    if default_socket.is_socket():
        return str(default_socket)
    forwarded_sockets = [
        path
        for path in (default_socket.parent / "by-session").glob("*/control.sock")
        if path.is_socket()
    ]
    if forwarded_sockets:
        return str(max(forwarded_sockets, key=lambda path: path.stat().st_mtime))
    return DEFAULT_SOCKET_PATH


def validate_prompt_bytes(raw: bytes, source: str = "prompt") -> str:
    if len(raw) == 0:
        raise CoordinatorError(f"{source} must not be empty")
    if len(raw) > MAX_PROMPT_BYTES:
        raise CoordinatorError(
            f"{source} is {len(raw)} bytes, exceeding the {MAX_PROMPT_BYTES}-byte limit"
        )
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise CoordinatorError(f"{source} must be valid UTF-8: {exc}") from exc
    if not text.strip():
        raise CoordinatorError(f"{source} must not be whitespace-only")
    return text


def read_prompt_file(path: str | Path) -> str:
    p = Path(path)
    if not p.is_file():
        raise CoordinatorError(f"prompt file not found: {p}")
    return validate_prompt_bytes(p.read_bytes(), source=str(p))


def parse_projects(output: str) -> list[ProjectEntry]:
    entries: list[ProjectEntry] = []
    for raw_line in output.splitlines():
        line = raw_line.rstrip("\r\n")
        if not line or line.strip() == "(no projects)":
            continue
        match = PROJECT_LINE_RE.match(line)
        if not match:
            continue
        entries.append(
            ProjectEntry(
                id=match.group("id"),
                name=match.group("name"),
                status=match.group("status"),
                selected=match.group("selected") == "*",
            )
        )
    return entries


def parse_status(output: str) -> list[SessionEntry]:
    entries: list[SessionEntry] = []
    for raw_line in output.splitlines():
        line = raw_line.rstrip("\r\n")
        if not line or line.strip() == "(no sessions)":
            continue
        match = STATUS_LINE_RE.match(line)
        if not match:
            continue
        entries.append(
            SessionEntry(
                id=match.group("id"),
                project=match.group("project"),
                title=match.group("title"),
                status=match.group("status"),
                unread=bool(match.group("unread")),
                status_text=match.group("status_text"),
            )
        )
    return entries


def filter_status(
    entries: list[SessionEntry],
    needle: str,
    projects: list[ProjectEntry],
) -> list[SessionEntry]:
    if not needle or not needle.strip():
        return list(entries)
    norm = needle.strip().lower()
    by_id = next((p for p in projects if p.id.lower() == norm), None)
    target_name: str | None = None
    if by_id is not None:
        target_name = by_id.name.lower()
    elif any(p.name.lower() == norm for p in projects):
        target_name = norm

    if target_name is not None:
        same_name = [p for p in projects if p.name.lower() == target_name]
        if len(same_name) > 1:
            raise CoordinatorError(
                f"project filter {needle!r} maps to ambiguous project name {same_name[0].name!r}"
            )
        return [e for e in entries if e.project.lower() == target_name]

    direct = [e for e in entries if e.id.lower() == norm]
    if direct:
        return direct
    raise CoordinatorError(f"project or session {needle!r} not found")


def run_cli(args: list[str]) -> str:
    cmd = [app_binary(), *args]
    proc = subprocess.run(cmd, text=True, capture_output=True, check=False)
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or f"exit {proc.returncode}").strip()
        raise CoordinatorError(f"copilot-projects {' '.join(args)} failed: {err}")
    return proc.stdout.rstrip("\r\n")


def send_control_request(
    payload: dict[str, object],
    socket_path: str | None = None,
    timeout: float = 5.0,
) -> dict[str, object]:
    sock_path = socket_path or control_socket_path()
    line = json.dumps(payload, separators=(",", ":")) + "\n"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        try:
            sock.connect(sock_path)
            sock.sendall(line.encode("utf-8"))
            chunks: list[bytes] = []
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b"\n" in chunk:
                    break
        except OSError as exc:
            raise CoordinatorError(
                f"control socket request to {sock_path} failed: {exc}"
            ) from exc
    raw_resp = b"".join(chunks).decode("utf-8", errors="replace").strip()
    if not raw_resp:
        raise CoordinatorError("empty response from control socket")
    first_line = raw_resp.splitlines()[0]
    try:
        resp = json.loads(first_line)
    except json.JSONDecodeError as exc:
        raise CoordinatorError(f"invalid JSON from control socket: {first_line}") from exc
    if not resp.get("ok"):
        code = resp.get("code")
        err = resp.get("error") or "unknown error"
        suffix = f" ({code})" if code else ""
        raise CoordinatorError(f"control socket error{suffix}: {err}")
    return resp


def resolve_project(
    name: str | None = None,
    create_if_missing: bool = False,
    env: dict[str, str] | None = None,
    cli_runner: Callable[[list[str]], str] = run_cli,
) -> str:
    environment = env if env is not None else os.environ
    projects = parse_projects(cli_runner(["list-projects"]))
    if name:
        lower = name.strip().lower()
        by_id = next((p for p in projects if p.id.lower() == lower), None)
        if by_id is not None:
            return by_id.id
        matches = [p for p in projects if p.name.lower() == lower]
        if len(matches) > 1:
            raise CoordinatorError(f"project name {name!r} is ambiguous; use a project ID")
        if matches:
            return matches[0].id
        if create_if_missing:
            created = cli_runner(["new-project", name.strip()]).strip()
            if not created:
                raise CoordinatorError(f"new-project {name!r} returned an empty project ID")
            return created
        raise CoordinatorError(f"project {name!r} not found in list-projects")

    env_project = environment.get("COPILOT_PROJECTS_PROJECT", "").strip()
    if env_project:
        for p in projects:
            if p.id == env_project:
                return p.id
        return env_project

    for p in projects:
        if p.selected:
            return p.id
    if projects:
        return projects[0].id
    raise CoordinatorError("no projects found in Copilot Projects")


def _is_unsupported_parent_flag_error(exc: CoordinatorError) -> bool:
    detail = str(exc).rsplit(" failed: ", 1)[-1].lower()
    return "unexpected --parent-session" in detail or "unexpected --no-parent" in detail


def launch_session_and_wait(
    project_id: str,
    title: str,
    prompt_file: str | Path,
    request_id: str | None = None,
    wait_running: bool = True,
    timeout_seconds: float = 90.0,
    poll_interval_seconds: float = 1.5,
    parent_session_id: str | None = None,
    no_parent: bool = False,
    host: str | None = None,
    env: dict[str, str] | None = None,
    cli_runner: Callable[[list[str]], str] = run_cli,
    sleep_fn: Callable[[float], None] = time.sleep,
) -> dict[str, object]:
    read_prompt_file(prompt_file)
    environment = env if env is not None else os.environ
    effective_parent = (
        None
        if no_parent
        else (parent_session_id or environment.get("COPILOT_PROJECTS_SESSION", "")).strip()
        or None
    )
    req_uuid = str(uuid.UUID(request_id)) if request_id else str(uuid.uuid4())
    base_cmd = [
        "new-copilot-session",
        "--project",
        project_id,
        "--request-id",
        req_uuid,
        "--title",
        title,
        "--prompt-file",
        str(Path(prompt_file).resolve()),
    ]
    if host and host.strip():
        base_cmd.extend(["--host", host.strip()])
    parent_args: list[str] = []
    if no_parent:
        parent_args = ["--no-parent"]
    elif (parent_session_id or "").strip() and effective_parent is not None:
        parent_args = ["--parent-session", effective_parent]

    try:
        session_id = cli_runner([*base_cmd, *parent_args]).strip()
    except CoordinatorError as exc:
        # Older copilot-projects binaries predate parent-session support altogether
        # (--parent-session, --no-parent, and COPILOT_PROJECTS_SESSION) and fail
        # argument parsing with "unexpected --parent-session" / "unexpected --no-parent".
        # Intentionally fall back to launching without the flag so coordinator workflows
        # keep working before the updated app binary is installed, while still recording
        # the coordinator-side effective_parent in the returned launch metadata.
        if not parent_args or not _is_unsupported_parent_flag_error(exc):
            raise
        session_id = cli_runner(base_cmd).strip()
    if not session_id:
        raise CoordinatorError("new-copilot-session returned an empty session ID")

    observed_status = "launched"
    elapsed = 0.0
    if wait_running:
        deadline = time.monotonic() + timeout_seconds
        start_mono = time.monotonic()
        while True:
            try:
                status_output = cli_runner(["list-status"])
            except CoordinatorError as exc:
                err_lower = str(exc).lower()
                if time.monotonic() < deadline and any(
                    t in err_lower for t in ("the app is busy", "errno 35", "timed out")
                ):
                    sleep_fn(poll_interval_seconds)
                    continue
                raise CoordinatorError(
                    f"{exc}; session {session_id} was already launched; "
                    f"if retrying launch, reuse --request-id {req_uuid}"
                ) from exc
            entries = parse_status(status_output)
            match = next((s for s in entries if s.id == session_id), None)
            if match is not None:
                observed_status = match.status
                # 'running' means the CLI + MCP servers booted and accepted the initial prompt.
                # Also accept 'waiting' if the session immediately asked a question/permission.
                if match.status in ("running", "waiting"):
                    elapsed = round(time.monotonic() - start_mono, 2)
                    break
            if time.monotonic() >= deadline:
                raise CoordinatorError(
                    f"timed out after {timeout_seconds:.0f}s waiting for session {session_id} "
                    f"({title!r}) to reach 'running' (last status: {observed_status!r}); "
                    f"if retrying launch, reuse --request-id {req_uuid}"
                )
            sleep_fn(poll_interval_seconds)

    return {
        "session_id": session_id,
        "project_id": project_id,
        "parent_session_id": effective_parent,
        "request_id": req_uuid,
        "title": title,
        "prompt_file": str(Path(prompt_file).resolve()),
        "status": observed_status,
        "startup_seconds": elapsed,
    }


def launch_batch(
    project_id: str,
    items: Iterable[dict[str, object]],
    timeout_seconds: float = 90.0,
    poll_interval_seconds: float = 1.5,
    parent_session_id: str | None = None,
    no_parent: bool = False,
    host: str | None = None,
    env: dict[str, str] | None = None,
    cli_runner: Callable[[list[str]], str] = run_cli,
    sleep_fn: Callable[[float], None] = time.sleep,
) -> list[dict[str, object]]:
    item_list = list(items)
    if not item_list:
        raise CoordinatorError("launch-batch manifest must contain at least one item")
    # Pre-validate all prompt files before launching the first session so a bad file
    # on track N doesn't surface mid-batch.
    for idx, item in enumerate(item_list, start=1):
        title = str(item.get("title") or "").strip()
        prompt_file = str(item.get("prompt_file") or "").strip()
        if not title or not prompt_file:
            raise CoordinatorError(
                f"manifest item #{idx} requires non-empty 'title' and 'prompt_file'"
            )
        read_prompt_file(prompt_file)

    results: list[dict[str, object]] = []
    for item in item_list:
        item_parent_raw = item.get("parent_session_id")
        item_parent = (
            str(item_parent_raw).strip()
            if item_parent_raw is not None and str(item_parent_raw).strip()
            else None
        )
        if "no_parent" in item and item["no_parent"] is not None:
            item_no_parent = bool(item["no_parent"])
        elif item_parent is not None:
            item_no_parent = False
        else:
            item_no_parent = no_parent
        item_host = str(item.get("host") or "").strip() or host
        res = launch_session_and_wait(
            project_id=project_id,
            title=str(item["title"]).strip(),
            prompt_file=str(item["prompt_file"]).strip(),
            request_id=str(item["request_id"]).strip() if item.get("request_id") else None,
            wait_running=True,
            timeout_seconds=timeout_seconds,
            poll_interval_seconds=poll_interval_seconds,
            parent_session_id=None if item_no_parent else (item_parent or parent_session_id),
            no_parent=item_no_parent,
            host=item_host,
            env=env,
            cli_runner=cli_runner,
            sleep_fn=sleep_fn,
        )
        if item.get("worktree"):
            res["worktree"] = str(item["worktree"])
        results.append(res)
    return results


def send_session_prompt(
    session_id: str,
    prompt: str,
    project_id: str | None = None,
    request_id: str | None = None,
    socket_path: str | None = None,
    sender: Callable[[dict[str, object], str | None], dict[str, object]] | None = None,
    steer: bool = False,
) -> dict[str, object]:
    if not session_id or not session_id.strip():
        raise CoordinatorError("session_id is required")
    validated_prompt = validate_prompt_bytes(prompt.encode("utf-8"), source="prompt")
    req_uuid = str(uuid.UUID(request_id)) if request_id else str(uuid.uuid4())
    payload: dict[str, object] = {
        "command": "send-session-prompt",
        "sessionId": session_id.strip(),
        "requestId": req_uuid,
        "prompt": validated_prompt,
    }
    if project_id and project_id.strip():
        payload["projectId"] = project_id.strip()
    if steer:
        payload["promptMode"] = "immediate"

    dispatch = sender or (lambda req, sp: send_control_request(req, socket_path=sp))
    try:
        resp = dispatch(payload, socket_path)
    except CoordinatorError as exc:
        raise CoordinatorError(
            f"{exc}; if retrying the same prompt, reuse --request-id {req_uuid}"
        ) from exc
    return {
        "ok": True,
        "session_id": session_id.strip(),
        "project_id": project_id.strip() if project_id else None,
        "request_id": req_uuid,
        "code": resp.get("code"),
        "text": resp.get("text"),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Coordinate parallel Copilot Projects sessions."
    )
    sub = parser.add_subparsers(dest="subcommand", required=True)

    p_resolve = sub.add_parser("resolve-project", help="Resolve or create a project ID.")
    p_resolve.add_argument("--name", help="Project name or ID to resolve.")
    p_resolve.add_argument(
        "--create",
        action="store_true",
        help="Create the project via new-project if --name is not found.",
    )

    p_launch = sub.add_parser(
        "launch",
        help="Launch one Copilot session and wait until it reaches 'running'.",
    )
    p_launch.add_argument("--project", required=True, help="Target project ID.")
    p_launch.add_argument("--title", required=True, help="Session tab title.")
    p_launch.add_argument("--prompt-file", required=True, help="Path to <=8192B UTF-8 prompt.")
    p_launch.add_argument("--request-id", help="Optional UUID request ID.")
    p_launch.add_argument("--host", help="Optional SSH host override.")
    p_launch.add_argument(
        "--no-wait",
        action="store_true",
        help="Return immediately without waiting for status 'running'.",
    )
    p_launch.add_argument(
        "--timeout",
        type=float,
        default=90.0,
        help="Seconds to wait for session to transition to 'running' (default: 90).",
    )
    p_launch_parent = p_launch.add_mutually_exclusive_group()
    p_launch_parent.add_argument(
        "--parent-session",
        help="Explicit parent session ID override (defaults to $COPILOT_PROJECTS_SESSION).",
    )
    p_launch_parent.add_argument(
        "--no-parent",
        action="store_true",
        help="Do not group the launched session under a parent session.",
    )

    p_batch = sub.add_parser(
        "launch-batch",
        help="Stagger-launch multiple sessions sequentially, waiting for each to reach 'running'.",
    )
    p_batch.add_argument("--project", required=True, help="Target project ID.")
    p_batch.add_argument(
        "--manifest",
        required=True,
        help="JSON file containing a list of {title, prompt_file, request_id?, worktree?, parent_session_id?, no_parent?}.",
    )
    p_batch.add_argument(
        "--timeout",
        type=float,
        default=90.0,
        help="Per-session startup timeout in seconds (default: 90).",
    )
    p_batch.add_argument("--host", help="Optional SSH host override for launched sessions.")
    p_batch_parent = p_batch.add_mutually_exclusive_group()
    p_batch_parent.add_argument(
        "--parent-session",
        help="Explicit parent session ID override for launched sessions (defaults to $COPILOT_PROJECTS_SESSION).",
    )
    p_batch_parent.add_argument(
        "--no-parent",
        action="store_true",
        help="Do not group launched sessions under a parent session.",
    )

    p_send = sub.add_parser(
        "send",
        help="Send a follow-up prompt to a spawned session over the control socket.",
    )
    p_send.add_argument("--session", required=True, help="Target session ID.")
    p_send.add_argument("--project", help="Optional project ID.")
    group = p_send.add_mutually_exclusive_group(required=True)
    group.add_argument("--prompt", help="Prompt text to send.")
    group.add_argument("--prompt-file", help="Path to prompt file (<=8192B UTF-8).")
    p_send.add_argument("--request-id", help="Optional UUID request ID.")
    p_send.add_argument(
        "--steer",
        action="store_true",
        help="Deliver into the running turn, or start one at once, instead of queueing.",
    )
    p_send.add_argument("--socket", help="Optional control socket path override.")

    p_status = sub.add_parser("status", help="List session statuses as JSON.")
    p_status.add_argument("--project", help="Filter by project name or ID.")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.subcommand == "resolve-project":
            pid = resolve_project(name=args.name, create_if_missing=args.create)
            print(pid)
            return 0
        if args.subcommand == "launch":
            res = launch_session_and_wait(
                project_id=args.project,
                title=args.title,
                prompt_file=args.prompt_file,
                request_id=args.request_id,
                wait_running=not args.no_wait,
                timeout_seconds=args.timeout,
                parent_session_id=args.parent_session,
                no_parent=args.no_parent,
                host=args.host,
            )
            print(json.dumps(res, indent=2))
            return 0
        if args.subcommand == "launch-batch":
            manifest_path = Path(args.manifest)
            if not manifest_path.is_file():
                raise CoordinatorError(f"manifest not found: {manifest_path}")
            items = json.loads(manifest_path.read_text(encoding="utf-8"))
            if not isinstance(items, list):
                raise CoordinatorError("manifest root must be a JSON array")
            results = launch_batch(
                project_id=args.project,
                items=items,
                timeout_seconds=args.timeout,
                parent_session_id=args.parent_session,
                no_parent=args.no_parent,
                host=args.host,
            )
            print(json.dumps(results, indent=2))
            return 0
        if args.subcommand == "send":
            prompt_text = (
                args.prompt
                if args.prompt is not None
                else read_prompt_file(args.prompt_file)
            )
            res = send_session_prompt(
                session_id=args.session,
                prompt=prompt_text,
                project_id=args.project,
                request_id=args.request_id,
                socket_path=args.socket,
                steer=args.steer,
            )
            print(json.dumps(res, indent=2))
            return 0
        if args.subcommand == "status":
            entries = parse_status(run_cli(["list-status"]))
            if args.project:
                projects = parse_projects(run_cli(["list-projects"]))
                entries = filter_status(entries, args.project, projects)
            print(json.dumps([asdict(e) for e in entries], indent=2))
            return 0
    except CoordinatorError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
