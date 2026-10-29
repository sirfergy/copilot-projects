#!/usr/bin/env python3
"""Offline contracts for frozen release notes."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location("notes", Path(__file__).with_name("release-notes.py"))
notes = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(notes)


class NotesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.environment = mock.patch.dict(os.environ, {
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        real_output = subprocess.check_output

        def offline_output(args, **kwargs):
            if args[0] == "gh":
                return "[[]]"
            return real_output(args, **kwargs)

        commands = mock.patch.object(subprocess, "check_output", side_effect=offline_output)
        commands.start()
        self.addCleanup(commands.stop)
        self.git("init", "-q", "--initial-branch=main")
        self.commit("Already shipped")
        self.previous = self.git("rev-parse", "HEAD")

    def git(self, *args):
        return notes.git(self.root, *args)

    def commit(self, subject):
        self.git("add", ".")
        self.git("commit", "--allow-empty", "-qm", subject)
        return self.git("rev-parse", "HEAD")

    def generate(self, previous=None):
        return notes.generate(
            self.root, "example/app", previous or self.previous, "2026.10.25.4", "2026.10.25.4"
        )

    def test_exact_range_categorizes_direct_changes(self):
        self.commit("add a feature")
        self.commit("fix: a bug")
        result = self.generate()
        self.assertNotIn("Already shipped", result["markdown"])
        self.assertIn("## Version 2026.10.25.4", result["markdown"])
        self.assertIn("### Features and improvements", result["markdown"])
        self.assertIn("### Fixes", result["markdown"])
        self.assertIn("[Full release notes history](https://github.com/example/app/releases)", result["markdown"])
        self.assertEqual(result["sourceRevision"], self.git("rev-parse", "HEAD"))
        self.assertIn("https://github.com/example/app/commit/", result["markdown"])
        published = notes.current_version_markdown(result)
        self.assertIn("## Features and improvements", published)
        self.assertIn("## Fixes", published)
        self.assertNotIn("## Version ", published)
        self.assertNotIn("/releases)", published)

    def test_merge_title_comes_from_pr_not_trailers_or_branch_commits(self):
        self.git("switch", "-qc", "feature")
        self.commit("Internal implementation")
        self.git("switch", "-q", "main")
        self.git("merge", "--no-ff", "-qm", "Merge pull request #12 from feature\n\nCo-authored-by: Bot", "feature")
        with mock.patch.object(notes, "merged_pull_request", return_value=("Prevent [stale] *notes*", ["bug"], 12, None)) as request:
            result = self.generate()
        request.assert_called_once_with("example/app", self.git("rev-parse", "HEAD"))
        self.assertNotIn("Co-authored-by", result["markdown"])
        self.assertNotIn("Internal implementation", result["markdown"])
        self.assertIn(r"Prevent \[stale\] \*notes\* ([#12](https://github.com/example/app/pull/12))", result["markdown"])
        self.assertEqual(result["plainText"], "Version 2026.10.25.4\nFixes\n- Prevent [stale] *notes*")

    def test_subjects_are_not_mistaken_for_pull_request_identity(self):
        self.commit("Feature (#13)")
        self.commit("merge pull request 14: headline")
        with mock.patch.object(notes, "merged_pull_request", return_value=None) as request:
            result = self.generate()
        self.assertEqual(request.call_count, 2)
        self.assertNotIn("/pull/", result["markdown"])
        self.assertIn(r"Feature \(#13\)", result["markdown"])
        self.assertIn("merge pull request 14", result["markdown"])

    def test_api_must_identify_exact_merged_change(self):
        pr = {"number": 12, "title": "Fix", "merged_at": "2026-10-25", "merge_commit_sha": "a" * 40, "labels": []}
        with mock.patch.object(subprocess, "check_output", return_value=json.dumps([[], [pr]])):
            self.assertEqual(notes.merged_pull_request("example/app", "a" * 40), ("Fix", [], 12, None))
            self.assertIsNone(notes.merged_pull_request("example/app", "b" * 40))
        with mock.patch.object(notes, "merged_pull_request", side_effect=ValueError("API denied")):
            self.commit("Merge pull request #12 from feature")
            with self.assertRaisesRegex(ValueError, "API denied"):
                self.generate()

    def test_angle_brackets_remain_literal_markdown(self):
        self.commit("fix Array<String> rendering")
        self.assertIn(r"Array\<String\>", self.generate()["markdown"])

    def test_newest_merge_waits_briefly_for_its_authoritative_association(self):
        self.commit("Merge pull request #12 from feature")
        with mock.patch.object(notes, "merged_pull_request", side_effect=[None, ("Fix rendering", ["bug"], 12, None)]) as lookup, \
                mock.patch.object(notes.time, "sleep") as sleep:
            result = self.generate()
        self.assertEqual(lookup.call_count, 2)
        sleep.assert_called_once_with(5)
        self.assertIn("Fix rendering", result["markdown"])
        self.assertIn("/pull/12", result["markdown"])

    def test_missing_merge_association_still_has_a_bounded_commit_fallback(self):
        self.commit("Merge pull request #12 from feature")
        with mock.patch.object(notes, "merged_pull_request", return_value=None) as lookup, \
                mock.patch.object(notes.time, "sleep") as sleep:
            result = self.generate()
        self.assertEqual(lookup.call_count, 3)
        self.assertEqual(sleep.call_count, 2)
        self.assertIn("/commit/", result["markdown"])
        self.assertNotIn("/pull/", result["markdown"])

    def test_divergent_predecessor_is_rejected(self):
        self.git("switch", "-qc", "other")
        other = self.commit("Other branch")
        self.git("switch", "-q", "main")
        self.commit("Current branch")
        with self.assertRaises(subprocess.CalledProcessError):
            self.generate(previous=other)

    def test_unchanged_build_is_explicit(self):
        self.assertIn("No source changes", self.generate()["markdown"])

    def test_public_host_pin_context_is_linked_without_reading_private_repos(self):
        def write_pin(revision):
            (self.root / "Package.resolved").write_text(json.dumps({"pins": [{
                "identity": "copilot-projects",
                "location": "https://github.com/sirfergy/copilot-projects.git",
                "state": {"revision": revision},
            }]}))
        write_pin("a" * 40)
        previous = self.commit("Old host")
        write_pin("b" * 40)
        self.commit("Update host")
        self.assertIn("compare/" + "a" * 40 + "..." + "b" * 40, self.generate(previous)["markdown"])

    def test_plain_text_limit_and_markup_independence(self):
        sections = {"Fixes": [(f"Fix {i} " + "\U0001f680" * 100, "https://example.invalid") for i in range(50)]}
        text = notes.plain_text([("2026.10.25.1", sections)])
        self.assertLessEqual(len(text.encode("utf-16-le")) // 2, 4000)
        self.assertIn("More changes", text)
        self.assertNotIn("https", text)
        self.assertNotIn("##", text)

    def write_initial_notes(self, sections):
        path = self.root / notes.INITIAL_NOTES
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(sections))
        return self.commit("Add the first curated notes")

    def test_first_release_uses_committed_curated_notes_without_api_lookups(self):
        self.write_initial_notes({"October 18-25 highlights": [
            ["Find and resume older sessions.", "https://github.com/example/app/pull/12"],
            ["Desktop updates.", "https://github.com/sirfergy/copilot-projects/pull/13"],
        ]})
        (self.root / notes.INITIAL_NOTES).write_text(json.dumps({"Uncommitted": [["Do not publish", None]]}))
        with mock.patch.object(notes, "merged_pull_request", side_effect=AssertionError("Unexpected API lookup")):
            result = self.generate()
            integrated = self.generate_integrated(self.previous)
        self.assertEqual(result["markdown"], integrated["markdown"])
        self.assertIn("October 18-25 highlights", result["markdown"])
        self.assertIn("Find and resume older sessions.", result["plainText"])
        self.assertNotIn("Do not publish", result["markdown"])
        self.assertEqual(result["sourceRevision"], self.git("rev-parse", "HEAD"))

    def test_releases_after_the_first_snapshot_return_to_automatic_changes(self):
        first = self.write_initial_notes({"Highlights": [["The first week's changes.", None]]})
        self.commit("fix the next issue")
        result = self.generate(previous=first)
        self.assertIn("fix the next issue", result["markdown"])
        self.assertNotIn("first week's changes", result["markdown"])

    def test_invalid_curated_notes_fail_instead_of_falling_back_to_automatic(self):
        for sections in [{}, {"Highlights": []}, {"Bad\nheading": [["Text", None]]}, {"Highlights": ["Text"]}]:
            with self.subTest(sections=sections):
                self.write_initial_notes(sections)
                with self.assertRaisesRegex(ValueError, "Initial release note"):
                    self.generate()

    def test_curated_notes_allow_own_and_public_host_links_only(self):
        self.write_initial_notes({"Highlights": [
            ["Shared host improvement.", "https://github.com/sirfergy/copilot-projects/pull/12"],
        ]})
        self.assertIn("Shared host improvement", self.generate()["markdown"])
        self.write_initial_notes({"Highlights": [
            ["Wrong audience.", "https://github.com/private/companion/pull/12"],
        ]})
        with self.assertRaisesRegex(ValueError, "this repository or the public host"):
            self.generate()

    def test_invalid_or_mismatched_notes_fail_validation(self):
        document = self.generate()
        with self.assertRaises(ValueError):
            notes.validate(document, document["version"], "other")
        for key, value in [("schemaVersion", 2), ("markdown", ""), ("repository", "../x"), ("sourceRevision", "main")]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                notes.validate({**document, key: value}, document["version"], document["build"])

    def write_host_pin(self, revision, shared="1"):
        (self.root / "Package.swift").write_text(
            f'.package(url: "https://github.com/sirfergy/copilot-projects.git", revision: "{revision}")\n'
        )
        (self.root / "Package.resolved").write_text(json.dumps({"pins": [
            {"location": "https://github.com/sirfergy/copilot-projects.git", "state": {"revision": revision}},
            {"location": "https://github.com/example/shared.git", "state": {"revision": shared}},
        ]}))

    def generate_integrated(self, previous):
        return notes.generate(
            self.root, "example/app", previous, "2026.10.25.4", "2026.10.25.4", host_root=self.root
        )

    def test_integrated_notes_expand_skipped_versions_and_suppress_only_pure_pin_updates(self):
        self.write_host_pin("a" * 40)
        previous = self.commit("Old desktop")
        self.write_host_pin("b" * 40)
        self.commit("update desktop host to v1")
        self.write_host_pin("c" * 40, shared="2")
        self.commit("update desktop host to v2")
        self.commit("fix a web issue")
        def host_dependencies(root, revision):
            return {"https://github.com/example/shared.git": {
                "location": "https://github.com/example/shared.git",
                "state": {"revision": "1" if revision == "b" * 40 else "2"},
            }}
        with mock.patch.object(notes, "host_dependency_pins", side_effect=host_dependencies), \
                mock.patch.object(notes, "host_changes", return_value=("ahead", [
            ("d" * 40, "add screenshot paste"),
            ("e" * 40, "fix desktop search"),
        ])) as compare:
            result = self.generate_integrated(previous)
        compare.assert_called_once_with(self.root, "a" * 40, "c" * 40)
        self.assertIn("add screenshot paste", result["markdown"])
        self.assertIn("fix desktop search", result["plainText"])
        self.assertIn("fix a web issue", result["plainText"])
        self.assertNotIn("update desktop host", result["markdown"])
        self.assertNotIn("No source changes", result["markdown"])
        self.assertNotIn("View the desktop host changes", result["markdown"])

    def test_mixed_feature_and_pin_changes_remain_visible(self):
        self.write_host_pin("a" * 40)
        previous = self.commit("Old desktop")
        self.write_host_pin("b" * 40)
        (self.root / "feature.txt").write_text("New feature")
        mixed = self.commit("add a web feature and update host")
        self.assertFalse(notes.pure_host_update(self.root, mixed, self.root))
        with mock.patch.object(notes, "host_changes", return_value=("ahead", [("c" * 40, "fix desktop")])):
            self.assertIn("add a web feature", self.generate_integrated(previous)["markdown"])

    def test_manifest_code_changes_are_not_hidden_as_pin_updates(self):
        self.write_host_pin("a" * 40)
        self.commit("Old desktop")
        self.write_host_pin("b" * 40)
        manifest = self.root / "Package.swift"
        manifest.write_text(manifest.read_text() + "newTarget()\n")
        mixed = self.commit("update host and add a target")
        self.assertFalse(notes.pure_host_update(self.root, mixed, self.root))

    def test_independent_dependency_updates_remain_visible_alongside_host_changes(self):
        self.write_host_pin("a" * 40)
        previous = self.commit("Old desktop")
        self.write_host_pin("b" * 40, shared="2")
        self.commit("update desktop and a web-only dependency")
        with mock.patch.object(notes, "host_dependency_pins", return_value={}), \
                mock.patch.object(notes, "host_changes", return_value=("ahead", [("c" * 40, "fix desktop")])):
            result = self.generate_integrated(previous)
        self.assertIn("update desktop and a web-only dependency", result["markdown"])
        self.assertIn("fix desktop", result["markdown"])

    def test_default_consumer_keeps_compare_link_and_unchanged_pin_never_calls_compare(self):
        self.write_host_pin("a" * 40)
        previous = self.commit("Old desktop")
        self.write_host_pin("b" * 40)
        current = self.commit("update desktop")
        with mock.patch.object(notes, "host_changes", side_effect=AssertionError("Unexpected expansion")):
            legacy = self.generate(previous)
            self.assertIn("View the desktop host changes", legacy["markdown"])
            self.commit("fix web only")
            self.assertIn("fix web only", self.generate_integrated(current)["markdown"])

    def test_same_summary_combines_links_but_same_pr_number_in_different_repos_survives(self):
        self.write_host_pin("a" * 40)
        previous = self.commit("Old desktop")
        self.write_host_pin("b" * 40)
        self.commit("update desktop")
        self.commit("fix shared issue")
        with mock.patch.object(notes, "host_changes", return_value=("ahead", [("c" * 40, "fix shared issue")])), \
                mock.patch.object(notes, "merged_pull_request", return_value=(
                    "fix shared issue", ["bug"], 12, "Sessions reconnect reliably."
                )):
            result = self.generate_integrated(previous)
        self.assertEqual(result["markdown"].count("Sessions reconnect reliably."), 1)
        self.assertIn("[#12](https://github.com/example/app/pull/12)", result["markdown"])
        self.assertIn("[copilot-projects#12](https://github.com/sirfergy/copilot-projects/pull/12)", result["markdown"])
        self.assertEqual(result["plainText"], "Version 2026.10.25.4\nFixes\n- Sessions reconnect reliably.")

    def test_summary_uses_explicit_paragraph_and_keeps_title_classification(self):
        examples = [
            ("## Release notes\r\n\r\nSessions reconnect\r\nwithout losing your draft.\r\n\r\nMore text", "Sessions reconnect without losing your draft."),
            ("```\n## Release notes\nNot a note\n```\n## Release note\n<!-- template -->\nA real note.\n## Tests\nNope", "A real note."),
            ("~~~markdown\n## Release notes\nNope\n~~~\n# Release notes\nA note.\n- More details", "A note."),
            ("````markdown\n```markdown\n## Release notes\nExample, not a note.\n```\n````\n## Release notes\nReal summary.", "Real summary."),
            ("## Release notes\n<!-- fill this in -->\n## Tests\nAll pass", None),
            ("## Release notes\nN/A", None),
            ("## Release notes\n- A list is not a paragraph", None),
            ("## Release notes\n\n    swift test", None),
            ("    ## Release notes\n    Example only\n\n## Release notes\nActual summary.", "Actual summary."),
            ("\t## Release notes\n\tExample only", None),
            ("## Release notes\nA wrapped\n    paragraph.", "A wrapped paragraph."),
            ("```html\n<!-- unclosed example\n```\n## Release notes\nReal summary.", "Real summary."),
            ("<!--\n## Release notes\nTemplate only\n-->\n## Release notes\nReal summary.", "Real summary."),
            ('## Release notes\nPaste screenshots.\n<img src="example.png">', "Paste screenshots."),
            ("## Release notes\nPaste screenshots.\n![Preview](example.png)", "Paste screenshots."),
            ("## Release notes\nNone.", None),
            ("## Release notes\nNo user-facing changes.", None),
            (None, None),
        ]
        for body, expected in examples:
            with self.subTest(body=body):
                self.assertEqual(notes.release_summary(body), expected)
        with mock.patch("sys.stderr") as stderr:
            self.assertIsNone(notes.release_summary("## Release notes\n" + "x" * 601))
            self.assertTrue(stderr.write.called)
        pr = {"number": 12, "title": "fix reconnect", "merged_at": "now", "merge_commit_sha": "a" * 40,
              "labels": [], "body": "## Release notes\nSessions reconnect reliably."}
        with mock.patch.object(subprocess, "check_output", return_value=json.dumps([[pr]])):
            self.assertEqual(notes.merged_pull_request("example/app", "a" * 40),
                             ("fix reconnect", [], 12, "Sessions reconnect reliably."))

    def test_desktop_history_uses_exact_git_pins_and_first_parents(self):
        old = self.previous
        self.git("switch", "-qc", "feature")
        feature = self.commit("Internal implementation")
        self.git("switch", "-q", "main")
        self.git("merge", "--no-ff", "-qm", "Merge feature", "feature")
        merged = self.git("rev-parse", "HEAD")
        new = self.commit("fix later")
        self.assertEqual(notes.host_changes(self.root, old, new),
                         ("ahead", [(merged, "Merge feature"), (new, "fix later")]))
        self.assertEqual(notes.host_changes(self.root, feature, new),
                         ("ahead", [(merged, "Merge feature"), (new, "fix later")]))
        self.assertEqual(notes.host_changes(self.root, new, old), ("behind", []))
        self.git("switch", "-qc", "other", old)
        other = self.commit("Other branch")
        self.assertEqual(notes.host_changes(self.root, new, other), ("diverged", []))
        with self.assertRaisesRegex(ValueError, "provided checkout"):
            notes.host_changes(self.root, "a" * 40, new)

    def test_rollback_and_divergence_are_explicit_and_do_not_hide_pin_change(self):
        old, new = "a" * 40, "b" * 40
        self.write_host_pin(old)
        previous = self.commit("Old desktop")
        self.write_host_pin(new)
        self.commit("update desktop")
        for status in ("behind", "diverged"):
            with self.subTest(status=status):
                with mock.patch.object(notes, "host_changes", return_value=(status, [])):
                    result = self.generate_integrated(previous)
                self.assertIn("update desktop", result["plainText"])
                self.assertIn("rolled back" if status == "behind" else "different history", result["plainText"])
                direction = f"{new}...{old}" if status == "behind" else f"{old}...{new}"
                self.assertIn(direction, result["markdown"])

    def test_shallow_history_with_both_pins_is_not_mislabeled_as_divergence(self):
        old = self.previous
        self.commit("Intermediate change")
        new = self.commit("Latest change")
        shallow = self.root / "shallow"
        subprocess.run(["git", "clone", "--quiet", "--depth", "1", self.root.as_uri(), str(shallow)], check=True)
        notes.git(shallow, "fetch", "--quiet", "--depth", "1", "origin", old)
        self.assertEqual(notes.git(shallow, "rev-parse", f"{old}^{{commit}}"), old)
        self.assertEqual(notes.git(shallow, "rev-parse", f"{new}^{{commit}}"), new)
        with self.assertRaisesRegex(ValueError, "history is shallow"):
            notes.host_changes(shallow, old, new)

    def test_host_dependency_lookup_uses_the_exact_committed_lock_not_the_working_copy(self):
        self.write_host_pin("a" * 40, shared="1")
        revision = self.commit("Desktop lock")
        expected = notes.dependency_pins(json.loads((self.root / "Package.resolved").read_text()))
        self.write_host_pin("b" * 40, shared="2")
        self.assertEqual(notes.host_dependency_pins(self.root, revision), expected)

    def test_pin_only_release_gets_desktop_notes_not_a_false_empty_message(self):
        self.write_host_pin("a" * 40)
        previous = self.commit("Old desktop")
        self.write_host_pin("b" * 40)
        self.commit("update desktop host")
        with mock.patch.object(notes, "host_changes", return_value=("ahead", [("c" * 40, "fix the desktop")])), \
                mock.patch.object(notes, "merged_pull_request", return_value=None) as lookup:
            result = self.generate_integrated(previous)
        lookup.assert_called_once_with(notes.HOST_REPOSITORY, "c" * 40)
        self.assertEqual(result["plainText"], "Version 2026.10.25.4\nFixes\n- fix the desktop")

    def test_discovers_last_ten_versions_from_release_tags_newest_first(self):
        self.git("tag", "v0.9.120")
        self.commit("fix legacy 121")
        self.git("tag", "v0.9.121")
        for ordinal in range(1, 11):
            self.commit(f"feat release {ordinal}")
            if ordinal == 2:
                self.git("tag", "v0.9.122")
            self.git("tag", f"v2026.10.25.{ordinal}")
        previous = self.git("rev-parse", "HEAD")
        self.git("switch", "-qc", "diverged", "v0.9.121")
        self.commit("diverged tag commit")
        self.git("tag", "v2026.10.24.1")
        self.git("switch", "-q", "main")
        self.commit("Merge pull request #99 from latest")
        with mock.patch.object(notes, "merged_pull_request", return_value=None) as lookup, \
                mock.patch.object(notes.time, "sleep") as sleep:
            result = notes.generate(self.root, "example/app", previous, "2026.10.25.11", "2026.10.25.11")
        self.assertEqual(sleep.call_count, 2)
        headings = [line for line in result["markdown"].splitlines() if line.startswith("## Version ")]
        self.assertEqual(headings, [f"## Version 2026.10.25.{n}" for n in range(11, 1, -1)])
        self.assertNotIn("diverged tag commit", result["markdown"])
        self.assertNotIn("fix legacy 121", result["markdown"])
        self.assertTrue(
            result["markdown"].endswith(
                "\n\n[Full release notes history](https://github.com/example/app/releases)\n"
            )
        )
        self.assertEqual(lookup.call_count, 12)

    def test_short_tag_chain_includes_initial_curated_release_and_cli_prior_releases(self):
        t0 = self.write_initial_notes({"Highlights": [["Initial curated highlight.", None]]})
        self.git("tag", "v2026.10.25.1")
        t1 = self.commit("fix second release")
        self.git("tag", "v2026.10.25.2")
        self.commit("add third release")
        auto = notes.generate(self.root, "example/app", t1, "2026.10.25.3", "2026.10.25.3")
        headings = [line for line in auto["markdown"].splitlines() if line.startswith("## Version ")]
        self.assertEqual(headings, [
            "## Version 2026.10.25.3", "## Version 2026.10.25.2", "## Version 2026.10.25.1"
        ])
        self.assertIn("Initial curated highlight.", auto["markdown"])
        output = self.root / "out.json"
        with mock.patch("sys.argv", [
            "release-notes.py", "generate", "--root", str(self.root), "--repository", "example/app",
            "--previous", t1, "--version", "1.0", "--build", "3", "--output", str(output),
            "--prior-release", f"1.0 (2)={t0}..{t1}", "--prior-release", f"1.0 (1)={t0}",
        ]):
            notes.main()
        explicit = json.loads(output.read_text())
        self.assertIn("## Version 1.0\n", explicit["markdown"])
        self.assertIn("## Version 1.0 \\(2\\)\n", explicit["markdown"])
        self.assertIn("## Version 1.0 \\(1\\)\n", explicit["markdown"])
        self.assertIn("Initial curated highlight.", explicit["markdown"])
        with mock.patch("sys.argv", [
            "release-notes.py", "validate", "--file", str(output),
            "--version", "1.0", "--build", "3", "--markdown",
        ]), mock.patch("builtins.print") as printed:
            notes.main()
        single = printed.call_args.args[0]
        self.assertIn("## Features and improvements\n\n- add third release", single)
        self.assertNotIn("fix second release", single)
        self.assertNotIn("Initial curated highlight.", single)
        self.assertNotIn("/releases)", single)

    def test_markdown_stays_within_five_hundred_line_rendering_limit(self):
        prior = []
        prev = self.previous
        for idx in range(1, 10):
            rev = self.commit(f"fix v{idx}")
            prior.append(f"2026.10.25.{idx}={prev}..{rev}")
            prev = rev
        self.commit("feat current")
        many_changes = [(f"Change {item}", f"https://github.com/example/app/pull/{item + 1}") for item in range(60)]
        with mock.patch.object(
            notes, "version_sections",
            return_value=({"Features and improvements": many_changes, "Fixes": [], "Other changes": []}, None, False),
        ):
            result = notes.generate(
                self.root, "example/app", prev, "2026.10.25.10", "2026.10.25.10",
                prior_releases=list(reversed(prior)),
            )
        self.assertLessEqual(len(result["markdown"].split("\n")), 500)
        self.assertTrue(
            result["markdown"].endswith(
                "\n\n[Full release notes history](https://github.com/example/app/releases)\n"
            )
        )


if __name__ == "__main__":
    unittest.main()
