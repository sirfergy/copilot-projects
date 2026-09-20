#!/usr/bin/env python3
"""Check capture isolation and evidence validation without accessing a desktop."""

import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "capture_workspace", Path(__file__).with_name("capture-workspace.py")
)
capture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capture)


class CaptureDriverTests(unittest.TestCase):
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
            images = []
            for name in capture.IMAGE_NAMES:
                (root / "images" / name).write_bytes(
                    b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR"
                    + struct.pack(">II", 1280, 800) + b"\x08\x06\x00\x00\x00" + b"\x00" * 4
                )
                images.append({
                    "file": name, "renderer": "metal", "terminalMarkerVisible": True,
                    "pixelWidth": 1280, "pixelHeight": 800,
                })
            report = {"completed": True, "sourceSHA": "a" * 40, "images": images}
            manifest = root / "metadata.json"
            manifest.write_text(json.dumps(report))
            capture.verify_capture(root, "a" * 40)
            for change in (
                {"completed": False}, {"sourceSHA": "b" * 40}, {"images": images[:2]},
                {"images": [dict(image, terminalMarkerVisible=False) for image in images]},
                {"images": [dict(image, renderer="coretext") for image in images]},
                {"images": [dict(image, pixelWidth=1) for image in images]},
            ):
                manifest.write_text(json.dumps(report | change))
                with self.assertRaises(ValueError):
                    capture.verify_capture(root, "a" * 40)
            manifest.write_text(json.dumps(report))
            (root / "images" / images[0]["file"]).unlink()
            with self.assertRaises(FileNotFoundError):
                capture.verify_capture(root, "a" * 40)


if __name__ == "__main__":
    unittest.main()
