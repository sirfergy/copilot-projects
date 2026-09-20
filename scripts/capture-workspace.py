#!/usr/bin/env python3
"""Run the opt-in native fixture in Actions without inheriting runner secrets."""

import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys


REPO = Path(__file__).resolve().parents[1]
IMAGE_NAMES = {"macos-dark.png", "macos-light.png", "macos-compact.png"}


def capture_environment(root, source_sha, original):
    if original.get("GITHUB_ACTIONS") != "true" or not original.get("RUNNER_TRACKING_ID"):
        raise ValueError("Capture requires an authorized Actions runner with process tracking.")
    sandbox = root / "sandbox"
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(sandbox / "home"),
        "TMPDIR": str(sandbox / "tmp"),
        "LANG": "en_US.UTF-8",
        "SHELL": "/bin/cat",
        "GITHUB_ACTIONS": "true",
        "RUNNER_TRACKING_ID": original["RUNNER_TRACKING_ID"],
        "RUNNER_TEMP": str(root.parent),
        "WORKSPACE_CAPTURE_ROOT": str(root),
        "CAPTURE_SOURCE_SHA": source_sha,
        "COPILOT_PROJECTS_STATE_DIR": str(sandbox / "state"),
        "COPILOT_PROJECTS_SOCKET": str(sandbox / "state" / "control.sock"),
        "COPILOT_PROJECTS_DEFAULT_DIR": str(sandbox / "state"),
        "COPILOT_PROJECTS_NO_INSTALL": "1",
    }
    for key in ("DEVELOPER_DIR", "SDKROOT"):
        if key in original:
            environment[key] = original[key]
    return environment


def verify_capture(root, source_sha):
    report = json.loads((root / "metadata.json").read_text())
    if report.get("completed") is not True or report.get("sourceSHA") != source_sha:
        raise ValueError("The native capture did not complete for the checked-out commit.")
    images = report.get("images", [])
    if len(images) != 3 or {image.get("file") for image in images} != IMAGE_NAMES:
        raise ValueError("The capture must contain exactly the three requested views.")
    for image in images:
        if image.get("renderer") != "metal" or image.get("terminalMarkerVisible") is not True:
            raise ValueError("A capture is missing its rendered Metal terminal.")
        data = (root / "images" / image["file"]).read_bytes()
        if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
            raise ValueError("A required screenshot is not a PNG.")
        dimensions = struct.unpack(">II", data[16:24])
        if dimensions != (image.get("pixelWidth"), image.get("pixelHeight")) or min(dimensions) <= 0:
            raise ValueError("Screenshot dimensions do not match the capture manifest.")


def main():
    if len(sys.argv) != 2:
        raise ValueError("Usage: capture-workspace.py <fresh Actions capture directory>")
    root = Path(sys.argv[1]).resolve(strict=True)
    runner_temp = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    if root.parent != runner_temp or not root.name.startswith("workspace-capture."):
        raise ValueError("Capture output must be a private workspace-capture directory in RUNNER_TEMP.")
    if root.stat().st_mode & 0o077:
        raise ValueError("Capture output must not be accessible to other users.")
    if (root / "metadata.json").exists() or (root / "sandbox").exists():
        raise ValueError("Refusing to reuse an earlier capture directory.")
    source_sha = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=REPO, text=True
    ).strip()
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha) or source_sha != os.environ.get("GITHUB_SHA"):
        raise ValueError("The checkout does not match the Actions source SHA.")
    environment = capture_environment(root, source_sha, os.environ)
    for name in ("home", "state", "tmp"):
        (root / "sandbox" / name).mkdir(parents=True, mode=0o700)
    (root / "images").mkdir(mode=0o700)
    try:
        with (root / "test.log").open("w") as log:
            subprocess.run(
                ["swift", "test", "--skip-build", "--filter",
                 "WorkspaceCaptureTests/testNativeWorkspaceCapture"],
                cwd=REPO, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True,
            )
        verify_capture(root, source_sha)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        (root / "driver-error.txt").write_text(f"{type(error).__name__}: {error}\n")
        raise
    finally:
        shutil.rmtree(root / "sandbox")
    print(f"Captured three native workspace views for {source_sha}.")


if __name__ == "__main__":
    main()
