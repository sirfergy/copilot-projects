#!/usr/bin/env python3
"""Run the opt-in native fixture in Actions without inheriting runner secrets."""

import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import struct
import subprocess
import sys


REPO = Path(__file__).resolve().parents[1]
APPEARANCES = {
    "macos-dark.png": "NSAppearanceNameDarkAqua",
    "macos-light.png": "NSAppearanceNameAqua",
    "macos-compact.png": "NSAppearanceNameDarkAqua",
    "macos-compact-projects-hidden.png": "NSAppearanceNameDarkAqua",
}
IMAGE_NAMES = set(APPEARANCES)
TRANSCRIPT_IMAGE_NAMES = {
    "macos-transcript-dark.png",
    "macos-transcript-light.png",
    "macos-transcript-preview.png",
}


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
    if report.get("collapseVerified") is not True or report.get("emptyProjectCollapseVerified") is not True:
        raise ValueError("The native project-column collapse was not verified.")
    if report.get("focusedTerminalCollapseVerified") is not True:
        raise ValueError("Project collapse did not preserve the already-focused terminal.")
    if report.get("transcriptImagesVerified") is not True:
        raise ValueError("Transcript image interaction and ownership were not verified.")
    if report.get("guiHostVerified") is not True or report.get("terminalCleanupVerified") is not True:
        raise ValueError("The GUI host lifecycle and terminal cleanup were not verified.")
    images = report.get("images", [])
    if len(images) != len(IMAGE_NAMES) or {image.get("file") for image in images} != IMAGE_NAMES:
        raise ValueError("The capture must contain exactly the requested views.")
    for image in images:
        if image.get("appearance") != APPEARANCES[image["file"]]:
            raise ValueError("A screenshot does not match its requested appearance.")
        if image.get("projectsVisible") != (image["file"] != "macos-compact-projects-hidden.png"):
            raise ValueError("A screenshot does not match its requested navigation state.")
        if image.get("terminalWidth", 0) < 420:
            raise ValueError("A screenshot violates the minimum terminal width.")
        if image.get("renderer") != "metal" or image.get("terminalMarkerVisible") is not True:
            raise ValueError("A capture is missing its rendered Metal terminal.")
        data = (root / "images" / image["file"]).read_bytes()
        if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
            raise ValueError("A required screenshot is not a PNG.")
        dimensions = struct.unpack(">II", data[16:24])
        if dimensions != (image.get("pixelWidth"), image.get("pixelHeight")) or min(dimensions) <= 0:
            raise ValueError("Screenshot dimensions do not match the capture manifest.")
    transcript_images = report.get("transcriptImages", [])
    if len(transcript_images) != len(TRANSCRIPT_IMAGE_NAMES) or {
        image.get("file") for image in transcript_images
    } != TRANSCRIPT_IMAGE_NAMES:
        raise ValueError("The capture must contain the transcript image and preview views.")
    for image in transcript_images:
        if image.get("markerVisible") is not True:
            raise ValueError("A transcript image capture is missing its actual image pixels.")
        data = (root / "images" / image["file"]).read_bytes()
        if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
            raise ValueError("A transcript image capture is not a PNG.")
        dimensions = struct.unpack(">II", data[16:24])
        if dimensions != (image.get("pixelWidth"), image.get("pixelHeight")) or min(dimensions) <= 0:
            raise ValueError("Transcript image dimensions do not match the capture manifest.")


def build_capture_host(root):
    build = Path(subprocess.check_output(
        ["swift", "build", "--show-bin-path"], cwd=REPO, text=True
    ).strip()).resolve(strict=True)
    bundles = list(build.glob("*.xctest"))
    if len(bundles) != 1:
        raise ValueError("Expected exactly one prebuilt SwiftPM test bundle.")
    frameworks = Path(subprocess.check_output(
        ["xcrun", "--show-sdk-platform-path"], text=True
    ).strip()) / "Developer/Library/Frameworks"
    testing_libraries = frameworks.parent.parent / "usr/lib"
    app = root / "sandbox/Workspace Capture.app"
    contents = app / "Contents"
    executable = contents / "MacOS/workspace-capture-host"
    executable.parent.mkdir(parents=True)
    resources = contents / "Resources"
    resources.mkdir()
    for name in ("SwiftTerm_SwiftTerm.bundle", "copilot-projects_CopilotProjectsCore.bundle"):
        shutil.copytree(build / name, resources / name)
    with (contents / "Info.plist").open("wb") as plist:
        plistlib.dump({
            "CFBundleName": "Workspace Capture",
            "CFBundleExecutable": executable.name,
            "CFBundleIdentifier": "com.obvioussean.copilot-projects.workspace-capture",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "NSPrincipalClass": "NSApplication",
            "NSHighResolutionCapable": True,
            "LSMinimumSystemVersion": "26.0",
        }, plist)
    with (root / "build.log").open("a") as log:
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", str(REPO / "scripts/workspace-capture-host.swift"),
            "-F", str(frameworks), "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
            "-Xlinker", "-rpath", "-Xlinker", str(testing_libraries),
            "-o", str(executable),
        ], cwd=REPO, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)],
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=15)
    return executable, bundles[0]


def stop_capture_host(process):
    if process.poll() is not None:
        return
    # These are direct children of this still-live, test-owned application.
    try:
        children = subprocess.run(
            ["ps", "-o", "pid=", "-P", str(process.pid)], text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=5,
        )
        if children.returncode not in (0, 1):
            raise RuntimeError(f"Could not enumerate capture children: {children.stderr}")
        for child in children.stdout.split():
            try:
                os.kill(int(child), signal.SIGTERM)
            except ProcessLookupError:
                pass
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def run_capture_host(command, environment, log):
    process = subprocess.Popen(command, cwd=REPO, env=environment, stdout=log, stderr=subprocess.STDOUT)
    try:
        result = process.wait(timeout=180)
        if result != 0:
            raise subprocess.CalledProcessError(result, command)
    finally:
        stop_capture_host(process)


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
        executable, test_bundle = build_capture_host(root)
        with (root / "test.log").open("w") as log:
            run_capture_host([str(executable), str(test_bundle)], environment, log)
        verify_capture(root, source_sha)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        (root / "driver-error.txt").write_text(f"{type(error).__name__}: {error}\n")
        raise
    finally:
        shutil.rmtree(root / "sandbox")
    print(f"Captured {len(IMAGE_NAMES)} workspace and {len(TRANSCRIPT_IMAGE_NAMES)} transcript-image views for {source_sha}.")


if __name__ == "__main__":
    main()
