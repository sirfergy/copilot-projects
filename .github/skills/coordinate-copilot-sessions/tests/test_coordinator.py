import contextlib
import io
import json
import socket
import tempfile
import threading
import unittest
import uuid
from pathlib import Path
import sys

SCRIPT_DIR = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPT_DIR))

import coordinator  # noqa: E402


class CoordinatorTests(unittest.TestCase):
    def test_skill_frontmatter_is_valid_yaml(self) -> None:
        skill_md = (Path(__file__).resolve().parent.parent / "SKILL.md").read_text(encoding="utf-8")
        self.assertTrue(skill_md.startswith("---\n"))
        _, fm_text, _ = skill_md.split("---", 2)
        self.assertIn("name: coordinate-copilot-sessions\n", fm_text)
        self.assertIn("description: >-\n", fm_text)
        try:
            import yaml  # type: ignore[import-untyped]
        except ImportError:
            desc_lines = [
                line.strip()
                for line in fm_text.splitlines()
                if line.startswith("  ") and line.strip()
            ]
            desc = " ".join(desc_lines)
        else:
            fm = yaml.safe_load(fm_text)
            self.assertEqual(fm["name"], "coordinate-copilot-sessions")
            desc = fm["description"]
        self.assertIsInstance(desc, str)
        self.assertTrue(0 < len(desc) <= 1024)

    def test_validate_prompt_bytes_enforces_limit_and_utf8(self) -> None:
        self.assertEqual(coordinator.validate_prompt_bytes(b"hello"), "hello")
        with self.assertRaises(coordinator.CoordinatorError):
            coordinator.validate_prompt_bytes(b"   ")
        with self.assertRaises(coordinator.CoordinatorError):
            coordinator.validate_prompt_bytes(b"x" * (coordinator.MAX_PROMPT_BYTES + 1))
        with self.assertRaises(coordinator.CoordinatorError):
            coordinator.validate_prompt_bytes(b"\xff\xfe")

    def test_parse_projects_and_resolve(self) -> None:
        sample = (
            "  [idle] General  (2 sessions)  11111111-1111-1111-1111-111111111111\n"
            "* [running] Reliability  (1 session)  22222222-2222-2222-2222-222222222222\n"
        )
        parsed = coordinator.parse_projects(sample)
        self.assertEqual(len(parsed), 2)
        self.assertEqual(parsed[0].name, "General")
        self.assertFalse(parsed[0].selected)
        self.assertEqual(parsed[1].name, "Reliability")
        self.assertTrue(parsed[1].selected)
        # Also parses when leading whitespace on first unselected project line was stripped
        parsed_stripped = coordinator.parse_projects(sample.strip())
        self.assertEqual(len(parsed_stripped), 2)
        self.assertEqual(parsed_stripped[0].id, "11111111-1111-1111-1111-111111111111")

        pid = coordinator.resolve_project(
            name="reliability",
            env={},
            cli_runner=lambda cmd: sample,
        )
        self.assertEqual(pid, "22222222-2222-2222-2222-222222222222")

        created_pid = coordinator.resolve_project(
            name="NewProj",
            create_if_missing=True,
            env={},
            cli_runner=lambda cmd: "33333333-3333-3333-3333-333333333333"
            if cmd[0] == "new-project"
            else sample,
        )
        self.assertEqual(created_pid, "33333333-3333-3333-3333-333333333333")

        dup_sample = (
            "  [idle] Reliability  (1 session)  11111111-1111-1111-1111-111111111111\n"
            "* [running] Reliability  (2 sessions)  22222222-2222-2222-2222-222222222222\n"
        )
        with self.assertRaises(coordinator.CoordinatorError):
            coordinator.resolve_project(name="Reliability", env={}, cli_runner=lambda cmd: dup_sample)
        self.assertEqual(
            coordinator.resolve_project(
                name="22222222-2222-2222-2222-222222222222",
                env={},
                cli_runner=lambda cmd: dup_sample,
            ),
            "22222222-2222-2222-2222-222222222222",
        )

    def test_control_socket_path_falls_back_to_newest_forwarded_session_socket(self) -> None:
        sock_dir = Path("/tmp") / f"cp-state-{uuid.uuid4().hex[:8]}"
        s1_dir = sock_dir / "by-session" / "s1"
        s2_dir = sock_dir / "by-session" / "s2"
        s1_dir.mkdir(parents=True)
        s2_dir.mkdir(parents=True)
        sock1 = s1_dir / "control.sock"
        sock2 = s2_dir / "control.sock"
        srv1 = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv2 = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        orig_default = coordinator.DEFAULT_SOCKET_PATH
        try:
            srv1.bind(str(sock1))
            srv2.bind(str(sock2))
            import os as _os

            _os.utime(sock1, (1000, 1000))
            _os.utime(sock2, (2000, 2000))
            coordinator.DEFAULT_SOCKET_PATH = str(sock_dir / "control.sock")
            self.assertEqual(coordinator.control_socket_path({}), str(sock2))
        finally:
            coordinator.DEFAULT_SOCKET_PATH = orig_default
            srv1.close()
            srv2.close()
            for p in (sock1, sock2):
                if p.exists():
                    p.unlink()

    def test_filter_status_resolves_project_uuid_and_rejects_unknown_or_ambiguous(self) -> None:
        projects = coordinator.parse_projects(
            "  [idle] General  (0 sessions)  11111111-1111-1111-1111-111111111111\n"
            "* [running] Automations  (2 sessions)  890BC39F-0E5A-48C4-B6D1-33C04EBCE74F\n"
        )
        entries = coordinator.parse_status(
            "Automations/Manage PRs  idle [unread]  01A944E8-3ADB-587C-B96C-2A3D3B75E5B2\n"
            "Automations/Weekly Skill Audit  running  87CEFCB8-0B63-5803-A339-34D751C5DCC2\n"
            "Reliability/Track A  idle  99999999-9999-9999-9999-999999999999\n"
        )
        by_uuid = coordinator.filter_status(
            entries, "890BC39F-0E5A-48C4-B6D1-33C04EBCE74F", projects
        )
        self.assertEqual(
            [e.id for e in by_uuid],
            [
                "01A944E8-3ADB-587C-B96C-2A3D3B75E5B2",
                "87CEFCB8-0B63-5803-A339-34D751C5DCC2",
            ],
        )
        # Valid project with 0 sessions returns empty list without raising
        self.assertEqual(
            coordinator.filter_status(
                entries, "11111111-1111-1111-1111-111111111111", projects
            ),
            [],
        )
        # Session UUID match still works
        by_sid = coordinator.filter_status(
            entries, "99999999-9999-9999-9999-999999999999", projects
        )
        self.assertEqual([e.id for e in by_sid], ["99999999-9999-9999-9999-999999999999"])
        # Unknown project/session raises CoordinatorError instead of silent []
        with self.assertRaises(coordinator.CoordinatorError):
            coordinator.filter_status(entries, "nonexistent-project", projects)
        # Duplicate project name in list-projects raises CoordinatorError when filtering by UUID or name
        dup_projects = coordinator.parse_projects(
            "  [idle] Automations  (1 session)  11111111-1111-1111-1111-111111111111\n"
            "* [running] Automations  (2 sessions)  890BC39F-0E5A-48C4-B6D1-33C04EBCE74F\n"
        )
        with self.assertRaises(coordinator.CoordinatorError):
            coordinator.filter_status(
                entries, "890BC39F-0E5A-48C4-B6D1-33C04EBCE74F", dup_projects
            )
        with self.assertRaises(coordinator.CoordinatorError):
            coordinator.filter_status(entries, "Automations", dup_projects)

    def test_launch_batch_staggers_until_each_session_is_running(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            p1 = Path(tmp) / "p1.md"
            p2 = Path(tmp) / "p2.md"
            p1.write_text("Prompt 1", encoding="utf-8")
            p2.write_text("Prompt 2", encoding="utf-8")

            events: list[str] = []
            s1_polls = 0
            s2_polls = 0

            def fake_cli(args: list[str]) -> str:
                nonlocal s1_polls, s2_polls
                if args[0] == "new-copilot-session":
                    title = args[args.index("--title") + 1]
                    events.append(f"launch:{title}")
                    return "S1" if title == "Track 1" else "S2"
                if args[0] == "list-status":
                    if "launch:Track 2" not in events:
                        s1_polls += 1
                        state = "idle" if s1_polls < 2 else "running"
                        events.append(f"poll:S1:{state}")
                        return f"Proj/Track 1  {state}  S1"
                    s2_polls += 1
                    state = "running"
                    events.append(f"poll:S2:{state}")
                    return "Proj/Track 1  running  S1\nProj/Track 2  running — Working  S2"
                raise AssertionError(f"unexpected command: {args}")

            results = coordinator.launch_batch(
                project_id="P1",
                items=[
                    {"title": "Track 1", "prompt_file": str(p1)},
                    {"title": "Track 2", "prompt_file": str(p2)},
                ],
                cli_runner=fake_cli,
                sleep_fn=lambda _: None,
            )

            self.assertEqual([r["session_id"] for r in results], ["S1", "S2"])
            # Track 2 must not launch until Track 1 polled 'running'
            self.assertEqual(
                events,
                [
                    "launch:Track 1",
                    "poll:S1:idle",
                    "poll:S1:running",
                    "launch:Track 2",
                    "poll:S2:running",
                ],
            )

    def test_send_session_prompt_over_unix_socket(self) -> None:
        received: list[dict[str, object]] = []
        sock_file = Path("/tmp") / f"cp-test-{uuid.uuid4().hex[:8]}.sock"
        try:
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(sock_file))
            server.listen(1)

            def handle_one() -> None:
                conn, _ = server.accept()
                with conn:
                    data = conn.recv(4096).decode("utf-8").strip()
                    received.append(json.loads(data))
                    conn.sendall(b'{"ok":true,"code":"queued","text":"S1"}\n')

            t = threading.Thread(target=handle_one, daemon=True)
            t.start()

            res = coordinator.send_session_prompt(
                session_id="S1",
                project_id="P1",
                prompt="Please simplify the fallback in foo.ts",
                socket_path=str(sock_file),
            )
            t.join(timeout=2)

            t = threading.Thread(target=handle_one, daemon=True)
            t.start()
            with contextlib.redirect_stdout(io.StringIO()):
                rc = coordinator.main(
                    ["send", "--session", "S1", "--prompt", "Stop", "--socket", str(sock_file), "--steer"]
                )
            t.join(timeout=2)
            server.close()

            self.assertTrue(res["ok"])
            self.assertEqual(res["code"], "queued")
            self.assertEqual(len(received), 2)
            self.assertEqual(received[0]["command"], "send-session-prompt")
            self.assertEqual(received[0]["sessionId"], "S1")
            self.assertEqual(received[0]["projectId"], "P1")
            self.assertEqual(received[0]["prompt"], "Please simplify the fallback in foo.ts")
            self.assertNotIn("promptMode", received[0])
            self.assertEqual(rc, 0)
            self.assertEqual(received[1].get("promptMode"), "immediate")
        finally:
            if sock_file.exists():
                sock_file.unlink()

    def test_send_unparks_a_parked_session_then_sends_the_same_request_once_more(self) -> None:
        received: list[dict[str, object]] = []
        replies = [
            b'{"ok":false,"code":"parked","error":"The session is parked."}\n',
            b'{"ok":true,"code":"resumed"}\n',
            b'{"ok":true,"code":"queued","text":"S1"}\n',
        ]
        sock_file = Path("/tmp") / f"cp-test-{uuid.uuid4().hex[:8]}.sock"
        try:
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(sock_file))
            server.listen(1)

            def serve() -> None:
                for reply in replies:
                    conn, _ = server.accept()
                    with conn:
                        received.append(json.loads(conn.recv(4096).decode("utf-8").strip()))
                        conn.sendall(reply)

            t = threading.Thread(target=serve, daemon=True)
            t.start()
            res = coordinator.send_session_prompt(
                session_id="S1", project_id="P1", prompt="Rebase and push", socket_path=str(sock_file)
            )
            t.join(timeout=2)
            server.close()

            self.assertEqual(res["code"], "queued")
            self.assertEqual(
                [r["command"] for r in received],
                ["send-session-prompt", "unpark-session", "send-session-prompt"],
            )
            self.assertEqual(received[1], {"command": "unpark-session", "sessionId": "S1", "projectId": "P1"})
            self.assertEqual(received[2], received[0], "the same request, so it cannot be delivered twice")
        finally:
            if sock_file.exists():
                sock_file.unlink()

    def test_send_reports_why_a_parked_session_did_not_come_back_and_retries_nothing_else(self) -> None:
        def refuse(code: str, message: str) -> coordinator.CoordinatorError:
            error = coordinator.CoordinatorError(f"control socket error ({code}): {message}")
            error.code = code
            return error

        sent: list[str] = []

        def parked_then_stuck(req: dict[str, object], _socket: object) -> dict[str, object]:
            sent.append(str(req["command"]))
            if req["command"] == "unpark-session":
                raise refuse("", "Copilot didn't start again in this session.")
            raise refuse("parked", "The session is parked.")

        with self.assertRaisesRegex(coordinator.CoordinatorError, "didn't start again.*reuse --request-id"):
            coordinator.send_session_prompt(session_id="S1", prompt="Go", sender=parked_then_stuck)
        self.assertEqual(sent, ["send-session-prompt", "unpark-session"])

        sent.clear()

        def busy(req: dict[str, object], _socket: object) -> dict[str, object]:
            sent.append(str(req["command"]))
            raise refuse("busy", "The session is waiting for your input in the terminal.")

        with self.assertRaisesRegex(coordinator.CoordinatorError, "waiting for your input"):
            coordinator.send_session_prompt(session_id="S1", prompt="Go", sender=busy)
        self.assertEqual(sent, ["send-session-prompt"], "only a parked session is unparked")

    def test_launch_session_resolves_parent_from_env(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            prompt_path = Path(tmp) / "p.md"
            prompt_path.write_text("Child task prompt", encoding="utf-8")
            seen_cmds: list[list[str]] = []

            def fake_cli(args: list[str]) -> str:
                seen_cmds.append(args)
                return "S-CHILD"

            res = coordinator.launch_session_and_wait(
                project_id="P1",
                title="Child 1",
                prompt_file=prompt_path,
                wait_running=False,
                env={"COPILOT_PROJECTS_SESSION": "S-PARENT"},
                cli_runner=fake_cli,
            )

            self.assertEqual(res["parent_session_id"], "S-PARENT")
            self.assertEqual(len(seen_cmds), 1)
            self.assertNotIn("--parent-session", seen_cmds[0])
            self.assertNotIn("--no-parent", seen_cmds[0])

    def test_launch_session_explicit_parent_and_legacy_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            prompt_path = Path(tmp) / "p.md"
            prompt_path.write_text("Child task prompt", encoding="utf-8")
            seen_cmds: list[list[str]] = []

            def fake_legacy_cli(args: list[str]) -> str:
                seen_cmds.append(args)
                if "--parent-session" in args:
                    raise coordinator.CoordinatorError(
                        "copilot-projects new-copilot-session failed: unexpected --parent-session"
                    )
                return "S-CHILD"

            res = coordinator.launch_session_and_wait(
                project_id="P1",
                title="Child 1",
                prompt_file=prompt_path,
                wait_running=False,
                parent_session_id="S-EXPLICIT",
                env={"COPILOT_PROJECTS_SESSION": "S-ENV"},
                cli_runner=fake_legacy_cli,
            )

            self.assertEqual(res["parent_session_id"], "S-EXPLICIT")
            self.assertEqual(len(seen_cmds), 2)
            self.assertIn("--parent-session", seen_cmds[0])
            self.assertEqual(
                seen_cmds[0][seen_cmds[0].index("--parent-session") + 1],
                "S-EXPLICIT",
            )
            self.assertNotIn("--parent-session", seen_cmds[1])

            # Also verify --no-parent legacy fallback and that unrelated errors propagate.
            seen_cmds.clear()

            def fake_legacy_no_parent(args: list[str]) -> str:
                seen_cmds.append(args)
                if "--no-parent" in args:
                    raise coordinator.CoordinatorError(
                        "copilot-projects new-copilot-session failed: unexpected --no-parent"
                    )
                return "S-CHILD-2"

            res_no_parent = coordinator.launch_session_and_wait(
                project_id="P1",
                title="Child 2",
                prompt_file=prompt_path,
                wait_running=False,
                no_parent=True,
                env={"COPILOT_PROJECTS_SESSION": "S-ENV"},
                cli_runner=fake_legacy_no_parent,
            )
            self.assertIsNone(res_no_parent["parent_session_id"])
            self.assertEqual(len(seen_cmds), 2)
            self.assertIn("--no-parent", seen_cmds[0])
            self.assertNotIn("--no-parent", seen_cmds[1])

            seen_cmds.clear()

            def fake_unrelated_error(args: list[str]) -> str:
                seen_cmds.append(args)
                raise coordinator.CoordinatorError(
                    f"copilot-projects {' '.join(args)} failed: unknown project P1"
                )

            with self.assertRaises(coordinator.CoordinatorError):
                coordinator.launch_session_and_wait(
                    project_id="P1",
                    title="Child 3",
                    prompt_file=prompt_path,
                    wait_running=False,
                    parent_session_id="S-EXPLICIT",
                    cli_runner=fake_unrelated_error,
                )
            self.assertEqual(len(seen_cmds), 1)

    def test_launch_session_retries_transient_list_status_busy_errors(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            prompt_path = Path(tmp) / "p.md"
            prompt_path.write_text("Child task prompt", encoding="utf-8")
            polls = 0

            def fake_cli(args: list[str]) -> str:
                nonlocal polls
                if args[0] == "new-copilot-session":
                    return "S-BUSY"
                if args[0] == "list-status":
                    polls += 1
                    if polls == 1:
                        raise coordinator.CoordinatorError(
                            "copilot-projects list-status failed: copilot-projects: the app is busy"
                        )
                    if polls == 2:
                        raise coordinator.CoordinatorError(
                            "copilot-projects list-status failed: copilot-projects: io error: read failed (errno 35)"
                        )
                    return "Proj/Child 1  running  S-BUSY"
                raise AssertionError(f"unexpected command: {args}")

            res = coordinator.launch_session_and_wait(
                project_id="P1",
                title="Child 1",
                prompt_file=prompt_path,
                wait_running=True,
                cli_runner=fake_cli,
                sleep_fn=lambda _: None,
            )
            self.assertEqual(res["session_id"], "S-BUSY")
            self.assertEqual(res["status"], "running")
            self.assertEqual(polls, 3)

    def test_launch_session_no_parent_flag_and_manifest_overrides(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            prompt_path = Path(tmp) / "p.md"
            prompt_path.write_text("Child task prompt", encoding="utf-8")
            seen_cmds: list[list[str]] = []

            def fake_cli(args: list[str]) -> str:
                seen_cmds.append(args)
                if args[0] == "new-copilot-session":
                    return f"S{len(seen_cmds)}"
                return (
                    "Proj/Child 1  running  S1\n"
                    "Proj/Child 2  running  S3\n"
                    "Proj/Child 3  running  S5"
                )

            results = coordinator.launch_batch(
                project_id="P1",
                items=[
                    {"title": "Child 1", "prompt_file": str(prompt_path), "no_parent": True},
                    {
                        "title": "Child 2",
                        "prompt_file": str(prompt_path),
                        "parent_session_id": "S-ITEM-PARENT",
                    },
                    {"title": "Child 3", "prompt_file": str(prompt_path)},
                ],
                parent_session_id="S-BATCH-PARENT",
                env={"COPILOT_PROJECTS_SESSION": "S-ENV"},
                cli_runner=fake_cli,
                sleep_fn=lambda _: None,
            )

            self.assertIsNone(results[0]["parent_session_id"])
            self.assertEqual(results[1]["parent_session_id"], "S-ITEM-PARENT")
            self.assertEqual(results[2]["parent_session_id"], "S-BATCH-PARENT")
            launch_cmds = [c for c in seen_cmds if c[0] == "new-copilot-session"]
            self.assertIn("--no-parent", launch_cmds[0])
            self.assertNotIn("--parent-session", launch_cmds[0])
            self.assertIn("--parent-session", launch_cmds[1])
            self.assertEqual(
                launch_cmds[1][launch_cmds[1].index("--parent-session") + 1],
                "S-ITEM-PARENT",
            )
            self.assertIn("--parent-session", launch_cmds[2])
            self.assertEqual(
                launch_cmds[2][launch_cmds[2].index("--parent-session") + 1],
                "S-BATCH-PARENT",
            )

            parser = coordinator.build_parser()
            for subcmd, flag, val in (
                ("launch", "--prompt-file", str(prompt_path)),
                ("launch-batch", "--manifest", str(prompt_path)),
            ):
                extra = ["--title", "T"] if subcmd == "launch" else []
                with self.assertRaises(SystemExit):
                    parser.parse_args(
                        [
                            subcmd,
                            "--project",
                            "P1",
                            *extra,
                            flag,
                            val,
                            "--parent-session",
                            "S1",
                            "--no-parent",
                        ]
                    )


if __name__ == "__main__":
    unittest.main()
