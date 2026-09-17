#!/usr/bin/env python3
"""Exercise the release entrypoint without building, signing, or network access."""

import json
import importlib.util
import fcntl
import multiprocessing
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
import unittest
from unittest import mock


RELEASE = Path(__file__).with_name("release.sh")
REAL_GIT = shutil.which("git")
KEYCHAIN_SPEC = importlib.util.spec_from_file_location("keychain_search", RELEASE.with_name("keychain-search.py"))
keychain_search = importlib.util.module_from_spec(KEYCHAIN_SPEC)
KEYCHAIN_SPEC.loader.exec_module(keychain_search)
MOCK = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys

command = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["COMMAND_LOG"], "a") as log:
    log.write(json.dumps([os.getcwd(), command, args]) + "\n")
if os.environ.get("FAIL_COMMAND") == " ".join([command] + args[:2]):
    sys.exit(1)
if command == "git":
    if args[:1] == ["fetch"] or "push" in args:
        sys.exit(0)
    if args[:1] == ["ls-remote"]:
        tag = os.environ.get("MOCK_LATEST_TAG")
        if tag:
            print(os.environ["MOCK_LATEST_SHA"] + "\trefs/tags/" + tag)
        sys.exit(0)
    sys.exit(subprocess.call([os.environ["REAL_GIT"]] + args))
if command == "security":
    if not os.environ.get("MOCK_NO_IDENTITY"):
        print('1) TEST "Developer ID Application: Release Test"')
elif command == "swift":
    if "--show-bin-path" in args:
        print(os.environ["MOCK_BUILD_PATH"])
elif command == "clang":
    output = Path(args[args.index("-o") + 1])
    output.write_text("#!/bin/sh\nexit 0\n")
    output.chmod(0o755)
elif command == "hdiutil":
    Path(args[-1]).write_text("test dmg")
elif command == "ditto":
    Path(args[-1]).write_text("test zip")
elif command == "gh":
    if args[:2] == ["release", "view"]:
        if args[2] != os.environ.get("MOCK_LATEST_TAG"):
            sys.exit(1)
        assets = [{"name": "Copilot-Projects-" + args[2][1:] + ".dmg", "size": 1}]
        if os.environ.get("MOCK_RELEASE_INCOMPLETE"):
            assets = []
        print(json.dumps({"isDraft": False, "publishedAt": "2026-01-01", "assets": assets}))
    elif any("/git/ref/tags/" in a for a in args):
        sys.exit(0 if os.environ.get("MOCK_TAG_EXISTS") else 1)
    elif "--slurp" in args:
        print("[[]]")
    elif args[:3] == ["api", "-X", "POST"] and args[3].endswith("/releases"):
        if os.environ.get("MOCK_NO_RELEASE_ID"):
            print('{"upload_url":"https://uploads.example.invalid/assets{?name}"}')
        elif os.environ.get("MOCK_BAD_UPLOAD_URL"):
            print('{"id":42}')
        else:
            print('{"id":42,"upload_url":"https://uploads.example.invalid/assets{?name}"}')
    elif args[-1].endswith("/releases/42"):
        print('{"draft":true}')
"""

BUILD = """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$PWD|$VERSION|$CODESIGN_IDENTITY|$*" > dist-build.txt
printf '%s' "${CODESIGN_KEYCHAIN:-}" > dist-keychain.txt
mkdir -p 'dist/Copilot Projects.app'
case "${BUILD_CHANGE:-}" in
  dirty) echo changed >> tracked ;;
  head) git commit --allow-empty -qm 'changed during build' ;;
  origin) git remote set-url origin https://github.com/example/wrong.git ;;
esac
"""


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="release-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.log = self.root / "commands.jsonl"
        self.env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("GIT_", "GH_"))
            and key not in (
                "GITHUB_REPOSITORY", "CODESIGN_IDENTITY", "CODESIGN_KEYCHAIN", "NOTARY_PROFILE",
                "NOTARY_KEYCHAIN", "EXPECTED_PREVIOUS_TAG", "EXPECTED_PREVIOUS_SHA",
            )
        }
        self.env.update({
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_AUTHOR_NAME": "Release Test",
            "GIT_AUTHOR_EMAIL": "release@example.invalid",
            "GIT_COMMITTER_NAME": "Release Test",
            "GIT_COMMITTER_EMAIL": "release@example.invalid",
            "GH_TOKEN": "offline-test-placeholder",
            "REAL_GIT": REAL_GIT,
            "COMMAND_LOG": str(self.log),
            "GITHUB_REPOSITORY": "example/integration",
            "CODESIGN_IDENTITY": "Developer ID Application: Release Test",
            "NOTARY_PROFILE": "offline-test",
        })
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("git", "security", "xcrun", "spctl", "codesign", "hdiutil", "ditto", "gh", "curl", "swift", "clang"):
            self.executable(self.bin / name, MOCK)
        self.env["PATH"] = str(self.bin) + os.pathsep + self.env["PATH"]
        self.public = self.project("public", "https://github.com/sirfergy/copilot-projects.git")
        shutil.copyfile(RELEASE, self.public / "scripts/release.sh")
        self.git(self.public, "add", "scripts/release.sh")
        self.git(self.public, "commit", "-qm", "release entrypoint")
        self.git(self.public, "update-ref", "refs/remotes/origin/main", "HEAD")
        self.project_root = self.project("integration with spaces", "git@github.com:example/integration.git")

    def executable(self, path, content):
        path.write_text(content)
        path.chmod(0o755)

    def git(self, root, *args):
        env = {key: value for key, value in self.env.items()
               if key not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR")}
        return subprocess.check_output(
            [REAL_GIT, "-C", str(root), *args], env=env, text=True,
            stderr=subprocess.STDOUT,
        ).strip()

    def project(self, name, origin):
        root = self.root / name
        (root / "scripts").mkdir(parents=True)
        self.executable(root / "scripts/build-app.sh", BUILD)
        (root / ".gitignore").write_text("dist/\ndist-build.txt\ndist-keychain.txt\n")
        (root / "tracked").write_text("original\n")
        self.git(root, "init", "-q", "--initial-branch=main")
        self.git(root, "add", ".")
        self.git(root, "commit", "-qm", "fixture")
        self.git(root, "remote", "add", "origin", origin)
        self.git(root, "update-ref", "refs/remotes/origin/main", "HEAD")
        return root

    def run_release(self, *args, publish=True, override=True):
        command = ["bash", str(self.public / "scripts/release.sh"), "1.2.3"]
        if override:
            command.append("--project-root=" + str(self.project_root))
        if publish:
            command.append("--publish")
        result = subprocess.run(
            command + list(args), cwd=self.root, env=self.env,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        self.calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result

    def assert_rejected_before_side_effects(self, message, **kwargs):
        result = self.run_release(**kwargs)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stdout)
        self.assertFalse(any(command != "git" or "fetch" in args for _, command, args in self.calls))
        self.assertFalse((self.project_root / "dist-build.txt").exists())

    def test_override_runs_entire_pipeline_in_selected_root(self):
        # Even inherited Git selectors must not validate a different checkout.
        self.env.update(GIT_DIR=str(self.public / ".git"), GIT_WORK_TREE=str(self.public))
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue((self.project_root / "dist/Copilot-Projects-1.2.3.dmg").exists())
        self.assertFalse((self.public / "dist").exists())
        self.assertEqual(
            (self.project_root / "dist-build.txt").read_text().strip(),
            f"{self.project_root}|1.2.3|Developer ID Application: Release Test|--release",
        )
        self.assertTrue(all(cwd == str(self.project_root) for cwd, _, _ in self.calls))
        api_args = [arg for _, cmd, args in self.calls if cmd == "gh" for arg in args]
        self.assertIn("repos/example/integration/releases", api_args)
        self.assertIn("repos/example/integration/git/refs", api_args)
        self.assertIn("sha=" + self.git(self.project_root, "rev-parse", "HEAD"), api_args)
        self.assertFalse(any("sirfergy/copilot-projects" in arg for arg in api_args))
        for command in ("codesign", "spctl", "xcrun", "curl"):
            self.assertTrue(any(cmd == command for _, cmd, _ in self.calls))

    def test_default_root_and_repository_remain_public(self):
        del self.env["GITHUB_REPOSITORY"]
        result = self.run_release(override=False)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue((self.public / "dist/Copilot-Projects-1.2.3.dmg").exists())
        self.assertTrue(any("repos/sirfergy/copilot-projects/releases" in args for _, _, args in self.calls))

    def test_explicit_keychain_scopes_discovery_verification_build_and_dmg(self):
        keychain = str(self.root / "job signing.keychain-db")
        self.env["CODESIGN_KEYCHAIN"] = keychain
        del self.env["CODESIGN_IDENTITY"]
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stdout)
        identities = [args for _, command, args in self.calls if command == "security"]
        self.assertEqual(identities, [
            ["find-identity", "-v", "-p", "codesigning", keychain],
            ["find-identity", "-v", "-p", "codesigning", keychain],
        ])
        self.assertEqual((self.project_root / "dist-keychain.txt").read_text(), keychain)
        signing = [args for _, command, args in self.calls if command == "codesign"]
        self.assertEqual(len(signing), 1)
        self.assertEqual(signing[0][-3:-1], ["--keychain", keychain])

    def test_unavailable_explicit_keychain_cannot_fall_back_to_global_identities(self):
        self.env["CODESIGN_KEYCHAIN"] = "/missing/job.keychain-db"
        self.env["FAIL_COMMAND"] = "security find-identity -v"
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("codesigning identity not found", result.stdout)
        self.assertFalse((self.project_root / "dist-build.txt").exists())
        self.assertFalse(any(command == "codesign" for _, command, _ in self.calls))

    def run_assembler(self):
        shutil.copyfile(RELEASE.with_name("build-app.sh"), self.public / "scripts/build-app.sh")
        shutil.copyfile(RELEASE.with_name("bundle-resources.sh"), self.public / "scripts/bundle-resources.sh")
        build = self.public / ".build/products"
        build.mkdir(parents=True, exist_ok=True)
        for name in ("copilot-projects", "copilot-projects-link"):
            self.executable(build / name, "#!/bin/sh\nexit 0\n")
        tracker = build / "copilot-projects_CopilotProjectsCore.bundle/tracker"
        tracker.mkdir(parents=True, exist_ok=True)
        (tracker / "extension.mjs").write_text("// fixture\n")
        dtach = self.public / "vendor/dtach"
        dtach.mkdir(parents=True, exist_ok=True)
        (dtach / "config.h").touch()
        self.env.update(VERSION="1.2.3", MOCK_BUILD_PATH=str(build))
        self.log.unlink(missing_ok=True)
        result = subprocess.run(
            ["bash", str(self.public / "scripts/build-app.sh"), "--release"],
            env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        self.calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        return result

    def test_actual_assembler_scopes_every_signed_binary_and_preserves_defaults(self):
        for keychain, identity in (
            (str(self.root / "job signing.keychain-db"), None),
            (None, None),
            (str(self.root / "unused.keychain-db"), "-"),
        ):
            with self.subTest(keychain=keychain, identity=identity):
                for key in ("CODESIGN_KEYCHAIN", "CODESIGN_IDENTITY"):
                    self.env.pop(key, None)
                if keychain:
                    self.env["CODESIGN_KEYCHAIN"] = keychain
                if identity:
                    self.env["CODESIGN_IDENTITY"] = identity
                result = self.run_assembler()
                self.assertEqual(result.returncode, 0, result.stdout)
                signing = [args for _, cmd, args in self.calls if cmd == "codesign" and "--sign" in args]
                self.assertEqual(len(signing), 3)
                for args in signing:
                    if keychain and identity != "-":
                        self.assertEqual(args[args.index("--keychain") + 1], keychain)
                    else:
                        self.assertNotIn("--keychain", args)
                lookups = [args for _, cmd, args in self.calls if cmd == "security"]
                expected = ["find-identity", "-v", "-p", "codesigning"]
                self.assertEqual(lookups, [] if identity == "-" else [expected + ([keychain] if keychain else [])])

    def test_empty_explicit_keychain_never_silently_ad_hoc_signs(self):
        self.env.pop("CODESIGN_IDENTITY")
        self.env.update(CODESIGN_KEYCHAIN="/empty/job.keychain-db", MOCK_NO_IDENTITY="1")
        result = self.run_assembler()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("explicit signing keychain contains no Developer ID", result.stdout)
        self.assertFalse(any(cmd in ("swift", "codesign") for _, cmd, _ in self.calls))

    def test_local_build_still_allows_dirty_tree_without_fetching(self):
        (self.project_root / "tracked").write_text("local changes")
        result = self.run_release(publish=False)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any(cmd == "gh" or (cmd == "git" and "fetch" in args) for _, cmd, args in self.calls))
        handoff = next(line.strip() for line in result.stdout.splitlines() if line.startswith("    GITHUB_REPOSITORY="))
        self.assertEqual(shlex.split(handoff), [
            "GITHUB_REPOSITORY=example/integration",
            str(self.public / "scripts/release.sh"), "1.2.3",
            "--project-root=" + str(self.project_root), "--publish",
        ])

    def test_requires_explicit_target_for_override(self):
        del self.env["GITHUB_REPOSITORY"]
        self.assert_rejected_before_side_effects("explicit GITHUB_REPOSITORY")

    def test_rejects_relative_empty_missing_and_nested_roots(self):
        for root, message in (
            ("relative", "requires an absolute repository path"),
            ("", "requires an absolute repository path"),
            (str(self.root / "missing"), "No such file or directory"),
            (str(self.project_root / "scripts"), "must be the Git worktree root"),
        ):
            with self.subTest(root=root):
                result = self.run_release("--project-root=" + root, override=False)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(message, result.stdout)
                self.assertFalse((self.project_root / "dist-build.txt").exists())

    def test_rejects_mismatched_fetch_and_push_urls_including_secondary_urls(self):
        for option in ("url", "pushurl"):
            with self.subTest(option=option):
                self.git(self.project_root, "config", "--add", "remote.origin." + option,
                         "https://github.com/example/wrong.git")
                self.assert_rejected_before_side_effects("does not match")
                self.git(self.project_root, "config", "--unset-all", "remote.origin." + option,
                         "https://github.com/example/wrong.git")

    def test_accepts_supported_url_forms_and_expands_rewrites(self):
        for url in (
            "https://github.com/EXAMPLE/Integration.git/",
            "git@github.com:example/integration",
            "ssh://git@github.com/example/integration.git",
            "test-alias:integration.git",
        ):
            with self.subTest(url=url):
                self.git(self.project_root, "config", "url.https://github.com/example/.insteadOf", "test-alias:")
                self.git(self.project_root, "remote", "set-url", "origin", url)
                result = self.run_release()
                self.assertEqual(result.returncode, 0, result.stdout)

    def test_rejects_unsupported_or_credentialed_urls_without_echoing_them(self):
        for url in (
            "https://github.com.example.invalid/example/integration",
            "https://userinfo@github.com/example/integration",
            "file:///example/integration",
        ):
            with self.subTest(url=url):
                self.git(self.project_root, "remote", "set-url", "origin", url)
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("must identify a GitHub repository", result.stdout)
                self.assertNotIn(url, result.stdout)
                self.assertFalse((self.project_root / "dist-build.txt").exists())

    def test_rejects_dirty_or_untracked_source_before_build(self):
        (self.project_root / "tracked").write_text("dirty")
        self.assert_rejected_before_side_effects("clean project worktree")
        (self.project_root / "tracked").write_text("original\n")
        (self.project_root / "untracked").write_text("untracked")
        self.assert_rejected_before_side_effects("clean project worktree")

    def test_rejects_non_main_head_but_allows_detached_main(self):
        self.git(self.project_root, "checkout", "-q", "--detach")
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.git(self.project_root, "commit", "--allow-empty", "-qm", "feature only")
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("not on origin/main", result.stdout)

    def test_build_cannot_change_head_source_or_origin_before_notarization(self):
        for change, message in (("dirty", "clean project worktree"), ("head", "HEAD changed"), ("origin", "does not match")):
            with self.subTest(change=change):
                self.project_root = self.project("changed-" + change, "git@github.com:example/integration.git")
                self.env["BUILD_CHANGE"] = change
                self.log.unlink(missing_ok=True)
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(message, result.stdout)
                self.assertFalse(any(cmd == "xcrun" and args[:2] == ["notarytool", "submit"] for _, cmd, args in self.calls))

    def test_signing_notary_stapling_and_gatekeeper_fail_closed(self):
        self.env["CODESIGN_IDENTITY"] = "-"
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("requires CODESIGN_IDENTITY", result.stdout)
        self.env["CODESIGN_IDENTITY"] = "Developer ID Application: Release Test"
        for failure in ("xcrun notarytool submit", "xcrun stapler staple", "xcrun stapler validate", "spctl --assess --type"):
            with self.subTest(failure=failure):
                self.env["FAIL_COMMAND"] = failure
                self.log.unlink(missing_ok=True)
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse(any(cmd == "gh" for _, cmd, _ in self.calls))

    def test_failed_upload_cleans_up_only_selected_repository(self):
        self.env["FAIL_COMMAND"] = "curl --fail-with-body --location"
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue(any(args == ["api", "-X", "DELETE", "repos/example/integration/releases/42"] for _, cmd, args in self.calls if cmd == "gh"))
        pushes = [(cwd, args) for cwd, cmd, args in self.calls if cmd == "git" and "push" in args]
        self.assertEqual(len(pushes), 1)
        self.assertEqual(pushes[0][0], str(self.project_root))
        self.assertIn("--force-with-lease=refs/tags/v1.2.3:" + self.git(self.project_root, "rev-parse", "HEAD"), pushes[0][1])
        self.assertEqual(pushes[0][1][-2:], ["origin", ":refs/tags/v1.2.3"])

    def test_bad_upload_response_still_cleans_up_owned_draft(self):
        self.env["MOCK_BAD_UPLOAD_URL"] = "1"
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue(any(args == ["api", "-X", "DELETE", "repos/example/integration/releases/42"] for _, cmd, args in self.calls if cmd == "gh"))

    def test_missing_release_id_never_uses_a_null_cleanup_endpoint(self):
        self.env["MOCK_NO_RELEASE_ID"] = "1"
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any("repos/example/integration/releases/null" in args for _, _, args in self.calls))
        self.assertTrue(any(cmd == "git" and args[-2:] == ["origin", ":refs/tags/v1.2.3"] for _, cmd, args in self.calls))

    def test_predecessor_must_be_unchanged_complete_and_in_selected_repository(self):
        sha = self.git(self.project_root, "rev-parse", "HEAD")
        self.env.update(
            EXPECTED_PREVIOUS_TAG="v1.2.2", EXPECTED_PREVIOUS_SHA=sha,
            MOCK_LATEST_TAG="v1.2.2", MOCK_LATEST_SHA=sha,
        )
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(any(args[:5] == ["release", "view", "v1.2.2", "--repo", "example/integration"] for _, cmd, args in self.calls if cmd == "gh"))
        self.env["EXPECTED_PREVIOUS_SHA"] = "0" * 40
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("predecessor v1.2.2 moved", result.stdout)
        self.env["EXPECTED_PREVIOUS_SHA"] = sha
        self.env["MOCK_RELEASE_INCOMPLETE"] = "1"
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("no longer complete", result.stdout)

    def test_complete_superseding_release_exits_without_publishing(self):
        sha = self.git(self.project_root, "rev-parse", "HEAD")
        self.env.update(
            EXPECTED_PREVIOUS_TAG="v1.2.2", EXPECTED_PREVIOUS_SHA=sha,
            MOCK_LATEST_TAG="v1.2.4", MOCK_LATEST_SHA=sha,
        )
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("superseded by complete descendant release v1.2.4", result.stdout)
        self.assertFalse(any(cmd == "gh" and "POST" in args for _, cmd, args in self.calls))

    def test_existing_version_or_tag_cannot_be_reused(self):
        self.env["MOCK_LATEST_TAG"] = "v1.2.3"
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("release v1.2.3 already exists", result.stdout)
        del self.env["MOCK_LATEST_TAG"]
        self.env["MOCK_TAG_EXISTS"] = "1"
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("tag v1.2.3 already exists", result.stdout)


class KeychainSearchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="keychain-search-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.existing = self.root / "existing public.keychain-db"
        self.job = self.root / "job signing.keychain-db"
        self.existing.touch()
        self.job.touch()
        self.state = [str(self.existing)]
        self.writes = []
        self.deletes = []
        self.lock_file = self.root / "search.lock"
        self.account_lock_path = keychain_search.lock_path
        patcher = mock.patch.object(keychain_search, "lock_path", return_value=self.lock_file)
        patcher.start()
        self.addCleanup(patcher.stop)

    def execute(self, *args):
        if args[:2] == ("security", "delete-keychain"):
            self.deletes.append(args[2])
            self.state.remove(args[2])
            Path(args[2]).unlink()
            return ""
        if "-s" in args:
            self.writes.append(list(args))
            self.state = list(args[args.index("-s") + 1:])
            return ""
        self.assertEqual(args, ("security", "list-keychains", "-d", "user"))
        return "".join("    " + json.dumps(path) + "\n" for path in self.state)

    def test_register_preserves_quoted_paths_and_is_idempotent(self):
        keychain_search.register_keychain(str(self.job), self.execute)
        self.assertEqual(self.writes, [[
            "security", "list-keychains", "-d", "user", "-s", str(self.existing), str(self.job),
        ]])
        keychain_search.register_keychain(str(self.job), self.execute)
        self.assertEqual(len(self.writes), 1)

    def test_empty_malformed_or_relative_lists_never_reach_the_setter(self):
        for raw in (
            "", '    "/broken\n', '"relative.keychain-db"\n', '"/tmp/a" "/tmp/b"\n',
            '    "/Users/sean/Library/Keychains/    "/Users/sean/Library/Keychains/login.keychain-db"\n',
        ):
            with self.subTest(raw=raw):
                def execute(*args):
                    self.assertNotIn("-s", args)
                    return raw
                with self.assertRaises(ValueError):
                    keychain_search.register_keychain(str(self.job), execute)

    def test_missing_job_keychain_never_changes_the_search_list(self):
        self.job.unlink()
        with self.assertRaisesRegex(ValueError, "already exist"):
            keychain_search.register_keychain(str(self.job), self.execute)
        self.assertEqual(self.writes, [])

    def test_concurrent_removal_is_bounded_and_fails_visibly(self):
        def execute(*args):
            if "-s" in args:
                self.writes.append(args)
            return "    " + json.dumps(str(self.existing)) + "\n"
        with self.assertRaisesRegex(RuntimeError, "Concurrent"):
            keychain_search.register_keychain(str(self.job), execute)
        self.assertEqual(len(self.writes), 3)

    def test_lock_identity_uses_account_home_not_job_environment(self):
        with mock.patch.object(keychain_search.pwd, "getpwuid") as account, mock.patch.dict(
            os.environ, {"HOME": str(self.root / "other-home"), "TMPDIR": str(self.root / "job-temp")}
        ):
            account.return_value.pw_dir = str(self.root)
            expected = self.root / ".copilot-projects-keychain-search.lock"
            self.assertEqual(self.account_lock_path(), expected)
            self.assertEqual(self.account_lock_path(), expected)
            account.assert_called_with(os.geteuid())
            for home in ("", str(self.root / "missing-home")):
                account.return_value.pw_dir = home
                with self.assertRaises(ValueError):
                    self.account_lock_path()

    def assert_serialized_mutations(self, delete=False):
        context = multiprocessing.get_context("fork")
        first_read = context.Event()
        release_first = context.Event()
        first_finished = context.Event()
        progress = context.Queue()
        other = self.root / "other signing.keychain-db"
        other.touch()
        state = self.root / "search.json"
        state.write_text(json.dumps(self.state + ([str(other)] if delete else [])))
        real_flock = fcntl.flock

        def first():
            initial = True

            def execute(*args):
                nonlocal initial
                if "-s" in args:
                    state.write_text(json.dumps(list(args[args.index("-s") + 1:])))
                    return ""
                paths = json.loads(state.read_text())
                if initial:
                    initial = False
                    first_read.set()
                    if not release_first.wait(10):
                        raise RuntimeError("First registration was not released")
                return "".join(json.dumps(path) + "\n" for path in paths)

            try:
                keychain_search.register_keychain(str(self.job), execute)
            finally:
                first_finished.set()

        def second():
            initial = True

            def flock(fd, operation):
                try:
                    real_flock(fd, operation | fcntl.LOCK_NB)
                except BlockingIOError:
                    progress.put("blocked")
                    return real_flock(fd, operation)
                progress.put("uncontended")

            def execute(*args):
                nonlocal initial
                paths = json.loads(state.read_text())
                if args[:2] == ("security", "delete-keychain"):
                    paths.remove(str(other))
                    state.write_text(json.dumps(paths))
                    other.unlink()
                    progress.put("deleted")
                    return ""
                if "-s" in args:
                    state.write_text(json.dumps(list(args[args.index("-s") + 1:])))
                    return ""
                if initial:
                    initial = False
                    progress.put("read")
                    if not first_finished.wait(10):
                        raise RuntimeError("First registration did not finish")
                return "".join(json.dumps(path) + "\n" for path in paths)

            with mock.patch.object(fcntl, "flock", side_effect=flock):
                operation = keychain_search.delete_keychain if delete else keychain_search.register_keychain
                operation(str(other), execute)

        processes = []
        try:
            first_process = context.Process(target=first)
            first_process.start()
            processes.append(first_process)
            self.assertTrue(first_read.wait(10), "First process never read the search list")
            second_process = context.Process(target=second)
            second_process.start()
            processes.append(second_process)
            observed = progress.get(timeout=10)
            release_first.set()
            for process in processes:
                process.join(10)
                self.assertFalse(process.is_alive(), "Keychain mutation did not finish")
                self.assertEqual(process.exitcode, 0)
            expected = [str(self.existing), str(self.job)] + ([] if delete else [str(other)])
            self.assertEqual(json.loads(state.read_text()), expected)
            self.assertEqual(observed, "blocked", "The second mutation did not share the first lock")
        finally:
            release_first.set()
            for process in processes:
                if process.is_alive():
                    process.terminate()
                process.join(10)
            progress.close()
            progress.join_thread()

    def test_two_process_registrations_preserve_both_entries(self):
        self.assert_serialized_mutations()

    def test_cleanup_cannot_be_restored_by_inflight_registration(self):
        self.assert_serialized_mutations(delete=True)

    def test_delete_is_native_idempotent_and_preserves_the_lock_inode(self):
        keychain_search.register_keychain(str(self.job), self.execute)
        inode = self.lock_file.stat().st_ino
        self.writes.clear()
        keychain_search.delete_keychain(str(self.job), self.execute)
        keychain_search.delete_keychain(str(self.job), self.execute)
        self.assertEqual(self.deletes, [str(self.job)])
        self.assertEqual(self.state, [str(self.existing)])
        self.assertEqual(self.writes, [])
        self.assertEqual(self.lock_file.stat().st_ino, inode)

    def test_delete_failure_is_visible_and_releases_the_lock(self):
        def execute(*args):
            raise subprocess.CalledProcessError(1, args)

        with self.assertRaises(subprocess.CalledProcessError):
            keychain_search.delete_keychain(str(self.job), execute)
        self.assertTrue(self.job.is_file())
        with self.lock_file.open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_delete_rejects_malformed_or_nonfile_paths(self):
        broken = self.root / "broken.keychain-db"
        broken.symlink_to(self.root / "missing.keychain-db")
        for path in ("relative.keychain-db", str(self.root), str(broken), str(self.job) + "\x01"):
            with self.subTest(path=path):
                with self.assertRaises(ValueError):
                    keychain_search.delete_keychain(path, self.execute)
        self.assertEqual(self.deletes, [])


if __name__ == "__main__":
    unittest.main()
