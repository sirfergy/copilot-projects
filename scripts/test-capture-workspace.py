#!/usr/bin/env python3
"""Check capture isolation and evidence validation without accessing a desktop."""

import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest import mock
import subprocess


SPEC = importlib.util.spec_from_file_location(
    "capture_workspace", Path(__file__).with_name("capture-workspace.py")
)
capture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capture)


class CaptureDriverTests(unittest.TestCase):
    def test_host_packages_the_debug_executable_and_resource_bundles(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / "debug"
            build.mkdir()
            (build / "workspace-capture-host").write_bytes(b"debug host")
            for name in ("SwiftTerm_SwiftTerm.bundle", "copilot-projects_CopilotProjectsCore.bundle"):
                (build / name).mkdir()
            with mock.patch.object(capture.subprocess, "check_output", return_value=str(build)), \
                 mock.patch.object(capture.subprocess, "run") as run:
                executable = capture.build_capture_host(root)
            self.assertEqual(executable.name, "workspace-capture-host")
            self.assertEqual(executable.read_bytes(), b"debug host")
            self.assertEqual(run.call_args.args[0][0], "codesign")
            with (executable.parent.parent / "Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            self.assertEqual(info["CFBundlePackageType"], "APPL")
            self.assertEqual(info["CFBundleIdentifier"], "com.obvioussean.copilot-projects.workspace-capture")

    def test_environment_is_replaced_and_tracking_is_preserved(self):
        root = Path("/private/capture")
        original = {
            "GITHUB_ACTIONS": "true", "RUNNER_TRACKING_ID": "owned-processes",
            "GITHUB_TOKEN": "secret", "GH_TOKEN": "secret",
            "ACTIONS_RUNTIME_TOKEN": "secret", "SSH_AUTH_SOCK": "/real/agent",
            "COPILOT_PROJECTS_DTACH": "/real/dtach",
            "COPILOT_PROJECTS_RENDERER": "coretext", "DEVELOPER_DIR": "/Applications/Xcode.app",
        }
        env = capture.capture_environment(root, "a" * 40, original)
        self.assertEqual(env["RUNNER_TRACKING_ID"], "owned-processes")
        self.assertEqual(env["SHELL"], "/bin/cat")
        self.assertEqual(env["COPILOT_PROJECTS_STATE_DIR"], "/private/capture/sandbox/state")
        self.assertEqual(env["HOME"], "/private/capture/sandbox/home")
        self.assertEqual(env["DEVELOPER_DIR"], original["DEVELOPER_DIR"])
        self.assertFalse(set(original) - {
            "GITHUB_ACTIONS", "RUNNER_TRACKING_ID", "DEVELOPER_DIR"
        } & set(env))

    def test_capture_refuses_non_actions_execution(self):
        for env in ({}, {"GITHUB_ACTIONS": "true"}, {"RUNNER_TRACKING_ID": "owned"}):
            with self.assertRaises(ValueError):
                capture.capture_environment(Path("/private/capture"), "a" * 40, env)

    def test_manifest_requires_exact_commit_images_and_terminal_pixels(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "images").mkdir()
            (root / "host-exit-status").write_text("0\n")
            images = []
            for name in capture.IMAGE_NAMES:
                (root / "images" / name).write_bytes(
                    b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR"
                    + struct.pack(">II", 1280, 800) + b"\x08\x06\x00\x00\x00" + b"\x00" * 4
                )
                images.append({
                    "file": name, "renderer": "metal", "terminalMarkerVisible": True,
                    "appearance": capture.APPEARANCES[name],
                    "projectsVisible": name != "macos-compact-projects-hidden.png",
                    "terminalWidth": 600,
                    "pixelWidth": 1280, "pixelHeight": 800,
                })
            report = {
                "completed": True, "collapseVerified": True, "emptyProjectCollapseVerified": True,
                "focusedTerminalCollapseVerified": True, "transcriptImagesVerified": True,
                "guiHostVerified": True, "terminalCleanupVerified": True,
                "inputDispatchVerified": True, "physicalKeyboardValidation": "unverified-headless",
                "sourceSHA": "a" * 40, "images": images,
            }
            transcript_images = []
            for name in capture.TRANSCRIPT_IMAGE_NAMES:
                (root / "images" / name).write_bytes(
                    b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR"
                    + struct.pack(">II", 1280, 800) + b"\x08\x06\x00\x00\x00" + b"\x00" * 4
                )
                transcript_images.append({
                    "file": name, "markerVisible": True, "pixelWidth": 1280, "pixelHeight": 800,
                })
            report["transcriptImages"] = transcript_images
            manifest = root / "metadata.json"
            manifest.write_text(json.dumps(report))
            capture.verify_capture(root, "a" * 40)
            for change in (
                {"completed": False}, {"sourceSHA": "b" * 40}, {"images": images[:2]},
                {"collapseVerified": False},
                {"emptyProjectCollapseVerified": False},
                {"focusedTerminalCollapseVerified": False},
                {"transcriptImagesVerified": False},
                {"guiHostVerified": False}, {"terminalCleanupVerified": False},
                {"inputDispatchVerified": False}, {"physicalKeyboardValidation": "verified"},
                {"transcriptImages": []},
                {"transcriptImages": [dict(image, markerVisible=False) for image in transcript_images]},
                {"transcriptImages": [dict(image, pixelWidth=1) for image in transcript_images]},
                {"images": [dict(image, terminalMarkerVisible=False) for image in images]},
                {"images": [dict(image, renderer="coretext") for image in images]},
                {"images": [dict(image, appearance="wrong") for image in images]},
                {"images": [dict(image, projectsVisible="wrong") for image in images]},
                {"images": [dict(image, terminalWidth=100) for image in images]},
                {"images": [dict(image, pixelWidth=1) for image in images]},
            ):
                manifest.write_text(json.dumps(report | change))
                with self.assertRaises(ValueError):
                    capture.verify_capture(root, "a" * 40)
            manifest.write_text(json.dumps(report))
            (root / "host-exit-status").write_text("1\n")
            with self.assertRaises(ValueError):
                capture.verify_capture(root, "a" * 40)
            (root / "host-exit-status").write_text("0\n")
            (root / "images" / images[0]["file"]).unlink()
            with self.assertRaises(FileNotFoundError):
                capture.verify_capture(root, "a" * 40)

    def test_host_timeout_stops_only_its_process_and_children(self):
        process = mock.Mock(pid=123)
        process.wait.side_effect = [subprocess.TimeoutExpired("host", 180), 0]
        process.poll.side_effect = [None, 0]
        children = subprocess.CompletedProcess([], 0, "456\n", "")
        with mock.patch.object(capture.subprocess, "Popen", return_value=process), \
             mock.patch.object(capture.subprocess, "run", return_value=children) as run, \
             mock.patch.object(capture, "capture_host_pid", return_value=234), \
             mock.patch.object(capture.os, "kill") as kill:
            with self.assertRaises(subprocess.TimeoutExpired):
                capture.run_capture_host(Path("/capture/App.app/Contents/MacOS/host"), Path("/capture"),
                                         {"HOME": "/isolated"}, mock.Mock())
        run.assert_called_once()
        self.assertEqual(run.call_args.args[0], ["ps", "-o", "pid=", "-P", "234"])
        self.assertEqual(kill.call_args_list, [
            mock.call(456, capture.signal.SIGTERM), mock.call(234, capture.signal.SIGTERM),
        ])
        process.terminate.assert_not_called()
        process.kill.assert_not_called()

    def test_host_failure_is_not_a_success_shaped_manifest(self):
        process = mock.Mock()
        process.wait.return_value = 1
        process.poll.return_value = 1
        with mock.patch.object(capture.subprocess, "Popen", return_value=process):
            with self.assertRaises(subprocess.CalledProcessError):
                capture.run_capture_host(Path("/capture/App.app/Contents/MacOS/host"), Path("/capture"),
                                         {}, mock.Mock())
        process.terminate.assert_not_called()

    def test_cleanup_refuses_a_reused_or_unrelated_pid(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "host-pid").write_text("234\n")
            unrelated = subprocess.CompletedProcess([], 0, "/some/other/application\n", "")
            with mock.patch.object(capture.subprocess, "run", return_value=unrelated):
                with self.assertRaises(RuntimeError):
                    capture.capture_host_pid(root, root / "sandbox/App.app/Contents/MacOS/host")


if __name__ == "__main__":
    unittest.main()
