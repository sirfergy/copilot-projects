#!/usr/bin/env python3
"""Freeze the changes in an exact build, without publishing or changing refs."""

import argparse
import datetime
import json
from pathlib import Path
import re
import subprocess
import sys
import time


MAX_BYTES = 256 * 1024
MAX_LINES = 500
MAX_VERSIONS = 10
INITIAL_NOTES = "release-notes/initial.json"
HOST_REPOSITORY = "sirfergy/copilot-projects"


def git(root, *args):
    return subprocess.check_output(
        ["git", "-C", str(root), *args], text=True, encoding="utf-8"
    ).strip()


def escape(text):
    return re.sub(r"([\\`*\[\]()_~<>])", r"\\\1", " ".join(text.split()))


def category(title, labels):
    labels = {label.lower() for label in labels}
    if labels & {"bug", "fix", "bugfix"} or re.match(
        r"^(fix(?:es)?|prevent|correct|repair|restore|ignore|debounce)\b",
        title, re.IGNORECASE
    ):
        return "Fixes"
    if labels & {"enhancement", "feature"} or re.match(
        r"^(feat|add|enable|support|introduce|improve|extend|implement)\b",
        title, re.IGNORECASE
    ):
        return "Features and improvements"
    return "Other changes"


def release_summary(body):
    if not body:
        return None
    active = False
    fence = None
    comment = False
    paragraph = []
    for line in body.splitlines():
        if not fence:
            visible = []
            while line:
                if comment:
                    end = line.find("-->")
                    if end < 0:
                        line = ""
                    else:
                        comment, line = False, line[end + 3:]
                else:
                    start = line.find("<!--")
                    if start < 0:
                        visible.append(line)
                        break
                    visible.append(line[:start])
                    comment, line = True, line[start + 4:]
            line = "".join(visible)
        stripped = line.strip()
        expanded = line.expandtabs(4)
        if stripped and len(expanded) - len(expanded.lstrip(" ")) >= 4:
            if fence or not active:
                continue
            if not paragraph:
                break
            paragraph.append(stripped)
            continue
        marker = re.match(r"^(`{3,}|~{3,})", stripped)
        if marker:
            if fence is None:
                if active:
                    break
                fence = marker[1]
            elif (
                marker[1][0] == fence[0]
                and len(marker[1]) >= len(fence)
                and not stripped[len(marker[1]):].strip()
            ):
                fence = None
            continue
        if fence:
            continue
        heading = re.match(r"^#{1,6}\s+(.+?)\s*#*\s*$", stripped)
        if heading:
            if active:
                break
            active = heading[1].casefold() in {"release notes", "release note"}
            continue
        if not active:
            continue
        if not stripped:
            if paragraph:
                break
            continue
        if re.match(r"^(?:[-+*]\s|\d+[.)]\s|[><|]|!\[|[-*_]{3,}$)", stripped):
            break
        paragraph.append(stripped)
    summary = " ".join(paragraph)
    if summary.casefold().rstrip(".!") in {"", "n/a", "none", "tbd", "-", "no user-facing changes"}:
        return None
    if len(summary) > 600:
        print("warning: Release notes summary exceeds 600 characters; using the PR title", file=sys.stderr)
        return None
    return summary


def merged_pull_request(repository, revision):
    raw = subprocess.check_output(
        ["gh", "api", "--paginate", "--slurp",
         f"repos/{repository}/commits/{revision}/pulls?per_page=100"], text=True
    )
    matches = [
        pr for page in json.loads(raw) for pr in page
        if pr.get("merged_at") and pr.get("merge_commit_sha") == revision
    ]
    if not matches:
        return None
    if len(matches) != 1:
        raise ValueError(f"Multiple merged pull requests identify commit {revision}")
    pr = matches[0]
    title = pr.get("title")
    if not isinstance(title, str) or not title.strip():
        raise ValueError(f"Merged PR for {revision} has no title")
    number = pr.get("number")
    if type(number) is not int or number <= 0:
        raise ValueError(f"Merged PR for {revision} has no valid number")
    return title, [label["name"] for label in pr.get("labels", [])], number, release_summary(pr.get("body"))


def host_pin(root, revision):
    # Only copy public dependency context into companion notes, never the reverse.
    files = git(root, "ls-tree", "--name-only", revision, "Package.resolved").splitlines()
    if not files:
        return None
    resolved = json.loads(git(root, "show", f"{revision}:Package.resolved"))
    for pin in resolved.get("pins", []):
        if pin.get("location", "").removesuffix(".git") == "https://github.com/sirfergy/copilot-projects":
            value = pin["state"]["revision"]
            if not re.fullmatch(r"[0-9a-f]{40}", value):
                raise ValueError("Invalid public host pin")
            return value
    return None


def host_changes(root, previous, revision):
    if git(root, "rev-parse", "--is-shallow-repository") == "true":
        raise ValueError("Desktop host history is shallow; provide a complete checkout")

    def contains(older, newer):
        result = subprocess.run(["git", "-C", str(root), "merge-base", "--is-ancestor", older, newer])
        if result.returncode not in (0, 1):
            raise ValueError("Could not compare desktop host pins in the provided checkout")
        return result.returncode == 0

    if not contains(previous, revision):
        return ("behind" if contains(revision, previous) else "diverged"), []
    history = git(root, "log", "--first-parent", "--reverse", "--format=%H%x09%s", f"{previous}..{revision}")
    return "ahead", [tuple(line.split("\t", 1)) for line in history.splitlines()]


def dependency_pins(lock):
    pins = {pin["location"]: pin for pin in lock["pins"]}
    if len(pins) != len(lock["pins"]):
        raise ValueError("Dependency lock contains duplicate locations")
    return pins


def host_dependency_pins(root, revision):
    return dependency_pins(json.loads(git(root, "show", f"{revision}:Package.resolved")))


def pure_host_update(root, revision, host_root):
    parents = git(root, "rev-list", "--parents", "-n", "1", revision).split()[1:]
    if not parents:
        return False
    previous = parents[0]
    paths = set(git(root, "diff", "--name-only", previous, revision).splitlines())
    if paths != {"Package.swift", "Package.resolved"}:
        return False
    old_pin, new_pin = host_pin(root, previous), host_pin(root, revision)
    if not old_pin or not new_pin or old_pin == new_pin:
        return False
    before = git(root, "show", f"{previous}:Package.swift")
    after = git(root, "show", f"{revision}:Package.swift")
    if old_pin not in before or before.replace(old_pin, new_pin) != after:
        return False
    before_lock = json.loads(git(root, "show", f"{previous}:Package.resolved"))
    after_lock = json.loads(git(root, "show", f"{revision}:Package.resolved"))
    before_pins, after_pins = dependency_pins(before_lock), dependency_pins(after_lock)
    for lock in (before_lock, after_lock):
        lock.pop("pins")
        lock.pop("originHash", None)
    if before_lock != after_lock:
        return False
    host_url = next(
        location for location in before_pins
        if location.removesuffix(".git") == f"https://github.com/{HOST_REPOSITORY}"
    )
    before_pins[host_url]["state"]["revision"] = new_pin
    changed = {
        location for location in before_pins.keys() | after_pins.keys()
        if before_pins.get(location) != after_pins.get(location)
    }
    if host_url in changed:
        return False
    if changed:
        old_dependencies = host_dependency_pins(host_root, old_pin)
        new_dependencies = host_dependency_pins(host_root, new_pin)
        if any(
            before_pins.get(location) != old_dependencies.get(location)
            or after_pins.get(location) != new_dependencies.get(location)
            for location in changed
        ):
            return False
    return True


def plain_text(versions):
    blocks = [
        f"Version {label}\n" + "\n\n".join(
            heading + "\n" + "\n".join("- " + title for title, _ in changes)
            for heading, changes in sections.items() if changes
        )
        for label, sections in versions
    ]
    text = "\n\n".join(blocks)
    if len(text.encode("utf-16-le")) // 2 <= 4000:
        return text
    suffix = "\n\nMore changes are available in What's New in the app."
    available = 4000 - len(suffix.encode("utf-16-le")) // 2
    prefix = text.encode("utf-16-le")[:available * 2].decode("utf-16-le", errors="ignore")
    return prefix.rsplit("\n", 1)[0] + suffix


def markdown_change(title, urls, repository=None):
    text = "- " + escape(title)
    if not urls:
        return text
    if isinstance(urls, str):
        urls = [urls]
    links = []
    for url in urls:
        source = "/".join(url.split("/")[3:5])
        reference = (
            (source.rsplit("/", 1)[1] if repository and source != repository else "")
            + "#" + url.rsplit("/", 1)[1] if "/pull/" in url else
            "View changes" if "/compare/" in url else url.rsplit("/", 1)[1][:7]
        )
        links.append(f"[{reference}]({url})")
    return f"{text} ({', '.join(links)})"


def collect_changes(repository, history, sections, seen, pr_cache=None, retry_newest=True):
    for sha, subject in history:
        cache_key = (repository, sha)
        if pr_cache is not None and cache_key in pr_cache:
            pr = pr_cache[cache_key]
        else:
            pr = merged_pull_request(repository, sha)
            if pr is None and retry_newest and sha == history[-1][0] and subject.startswith("Merge pull request #"):
                for _ in range(2):
                    time.sleep(5)
                    pr = merged_pull_request(repository, sha)
                    if pr is not None:
                        break
            if pr_cache is not None:
                pr_cache[cache_key] = pr
        if pr:
            title, labels, number, summary = pr
            url = f"https://github.com/{repository}/pull/{number}"
            text = summary or title
        else:
            title, labels, text = subject, [], subject
            url = f"https://github.com/{repository}/commit/{sha}"
        text = " ".join(text.split())
        if not text or re.match(r"^(co-authored-by|copilot-session|signed-off-by):", text, re.I):
            raise ValueError(f"Commit {sha} has no usable change title")
        key = text.casefold()
        if key in seen:
            if url not in seen[key][1]:
                seen[key][1].append(url)
        else:
            entry = (text, [url])
            seen[key] = entry
            sections[category(title, labels)].append(entry)


def initial_sections(root, repository, previous, revision):
    if not git(root, "ls-tree", "--name-only", revision, "--", INITIAL_NOTES):
        return None
    if previous and git(root, "ls-tree", "--name-only", previous, "--", INITIAL_NOTES):
        return None
    sections = json.loads(git(root, "show", f"{revision}:{INITIAL_NOTES}"))
    if not isinstance(sections, dict) or not sections:
        raise ValueError("Initial release notes must contain named sections")
    allowed_repositories = {repository, "sirfergy/copilot-projects"}
    for heading, entries in sections.items():
        if not heading.strip() or "\n" in heading or "\r" in heading or not isinstance(entries, list) or not entries:
            raise ValueError("Initial release notes require nonempty, single-line sections")
        for entry in entries:
            if not isinstance(entry, list) or len(entry) != 2 or not isinstance(entry[0], str) or not entry[0].strip():
                raise ValueError("Initial release note entries must be [text, link-or-null]")
            if entry[1] is not None:
                if not isinstance(entry[1], str):
                    raise ValueError("Initial release note links must be strings")
                link = re.fullmatch(
                    r"https://github\.com/([^/]+/[^/]+)/(?:pull/[1-9][0-9]*|commit/[0-9a-f]{40})",
                    entry[1]
                )
                if not link or link[1] not in allowed_repositories:
                    raise ValueError("Initial release note links must reference this repository or the public host")
    return sections


def release_tag_key(tag):
    if not tag.startswith("v"):
        return None
    version = tag[1:]
    match = re.fullmatch(
        r"([1-9][0-9]{3})\.(1[0-2]|[1-9])\.(3[01]|[12][0-9]|[1-9])\.([1-9][0-9]*)",
        version,
    )
    if match:
        year, month, day, ordinal = (int(part) for part in match.groups())
        try:
            datetime.date(year, month, day)
        except ValueError:
            return None
        return (1, year, month, day, ordinal)
    match = re.fullmatch(r"([0-9]+)\.([0-9]+)\.([0-9]+)", version)
    if match:
        return (0, *(int(part) for part in match.groups()), 0)
    return None


def discover_prior_releases(root, repository, previous):
    tags = sorted(
        (tag for tag in git(root, "tag", "--list", "v*").splitlines() if release_tag_key(tag)),
        key=release_tag_key,
    )
    by_commit = {}
    for tag in tags:
        by_commit[git(root, "rev-parse", "--verify", f"{tag}^{{commit}}")] = tag
    if previous not in by_commit:
        return []
    limit_key = release_tag_key(by_commit[previous])
    ordered = sorted(
        ((sha, tag) for sha, tag in by_commit.items() if release_tag_key(tag) <= limit_key),
        key=lambda item: release_tag_key(item[1]),
    )
    chain = [ordered[-1]]
    for sha, tag in reversed(ordered[:-1]):
        if subprocess.run(["git", "-C", str(root), "merge-base", "--is-ancestor", sha, chain[-1][0]]).returncode == 0:
            chain.append((sha, tag))
            if len(chain) == MAX_VERSIONS:
                break
    chain.reverse()
    transitions = [
        (chain[i][1][1:], chain[i - 1][0], chain[i][0])
        for i in range(len(chain) - 1, 0, -1)
    ]
    if len(transitions) < MAX_VERSIONS - 1 and initial_sections(root, repository, None, chain[0][0]) is not None:
        transitions.append((chain[0][1][1:], None, chain[0][0]))
    return transitions


def parse_prior_release(root, value, upper_bound):
    label, sep, spec = value.partition("=")
    if not sep or not spec:
        raise ValueError(f"Invalid prior release: {value}")
    if ".." in spec:
        prev_spec, _, rev_spec = spec.partition("..")
        if not prev_spec or not rev_spec or ".." in rev_spec:
            raise ValueError(f"Invalid prior release range: {value}")
    else:
        prev_spec, rev_spec = None, spec
    label = label.strip()
    if not label or "\n" in label or "\r" in label or not rev_spec or upper_bound is None:
        raise ValueError("Invalid prior release")
    rev_sha = git(root, "rev-parse", "--verify", f"{rev_spec}^{{commit}}")
    subprocess.run(
        ["git", "-C", str(root), "merge-base", "--is-ancestor", rev_sha, upper_bound],
        check=True,
    )
    if prev_spec is None:
        return label, None, rev_sha
    prev_sha = git(root, "rev-parse", "--verify", f"{prev_spec}^{{commit}}")
    subprocess.run(
        ["git", "-C", str(root), "merge-base", "--is-ancestor", prev_sha, rev_sha],
        check=True,
    )
    return label, prev_sha, rev_sha


def version_sections(root, repository, previous, revision, host_root, pr_cache, retry_newest):
    initial = initial_sections(root, repository, previous, revision)
    history = "" if initial is not None else git(
        root, "log", "--first-parent", "--reverse", "--format=%H%x09%s",
        f"{previous}..{revision}" if previous else revision
    )
    sections = initial if initial is not None else {
        "Features and improvements": [], "Fixes": [], "Other changes": [],
    }
    history = [tuple(line.split("\t", 1)) for line in history.splitlines()]
    desktop_history = []
    if previous and initial is None:
        old_host, new_host = host_pin(root, previous), host_pin(root, revision)
        if old_host and new_host and old_host != new_host:
            if host_root is not None:
                status, desktop_history = host_changes(host_root, old_host, new_host)
                if status == "ahead":
                    history = [(sha, subject) for sha, subject in history if not pure_host_update(root, sha, host_root)]
                else:
                    description = (
                        "Desktop host rolled back to an earlier revision; compare the removed changes"
                        if status == "behind" else "Desktop host changed to a different history; compare revisions"
                    )
                    left, right = (new_host, old_host) if status == "behind" else (old_host, new_host)
                    sections["Desktop host changes"] = [(
                        description, f"https://github.com/{HOST_REPOSITORY}/compare/{left}...{right}"
                    )]
            else:
                sections["Desktop host changes"] = [(
                    "View the desktop host changes included in this build",
                    f"https://github.com/{HOST_REPOSITORY}/compare/{old_host}...{new_host}"
                )]
    seen = {}
    collect_changes(repository, history, sections, seen, pr_cache, retry_newest)
    collect_changes(HOST_REPOSITORY, desktop_history, sections, seen, pr_cache, retry_newest)
    if not any(sections.values()):
        sections["Other changes"].append(("No source changes since the previous build.", None))
    return sections, (repository if host_root is not None and initial is None else None), initial is not None


def current_version_markdown(document):
    markdown = document["markdown"].strip()
    history_link = f"[Full release notes history](https://github.com/{document['repository']}/releases)"
    if markdown.endswith(history_link):
        markdown = markdown[:-len(history_link)].rstrip()
    if markdown.startswith("## Version "):
        _, _, markdown = markdown.partition("\n\n")
        markdown = markdown.split("\n\n## Version ", 1)[0]
        markdown = re.sub(r"(?m)^### ", "## ", markdown)
    return markdown + "\n"


def within_markdown_limits(markdown):
    return (
        len(markdown.split("\n")) <= MAX_LINES
        and markdown.count("|") <= 1000
        and sum(markdown.count(marker) for marker in "*_~`[<") <= 2000
        and len(markdown.encode("utf-8")) <= MAX_BYTES // 2
    )


def generate(root, repository, previous, version, build, host_root=None, prior_releases=None):
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*", repository):
        raise ValueError("Repository must be owner/name")
    if not version or not build:
        raise ValueError("Version and build are required")
    revision = git(root, "rev-parse", "HEAD^{commit}")
    if previous:
        previous = git(root, "rev-parse", "--verify", f"{previous}^{{commit}}")
        subprocess.run(
            ["git", "-C", str(root), "merge-base", "--is-ancestor", previous, revision],
            check=True
        )
    pr_cache = {}
    first_sections, first_context, is_initial = version_sections(
        root, repository, previous, revision, host_root, pr_cache, True
    )
    if prior_releases:
        prior_steps = []
        upper_bound = previous or revision
        for item in prior_releases[:MAX_VERSIONS - 1]:
            step = parse_prior_release(root, item, upper_bound)
            prior_steps.append(step)
            upper_bound = step[1]
    elif previous and not is_initial:
        prior_steps = discover_prior_releases(root, repository, previous)[:MAX_VERSIONS - 1]
    else:
        prior_steps = []

    def format_block(label, sections, repo_context):
        body = "\n\n".join(
            "### " + escape(heading) + "\n\n" + "\n".join(
                markdown_change(title, url, repo_context)
                for title, url in changes
            ) for heading, changes in sections.items() if changes
        )
        return f"## Version {escape(label)}\n\n{body}"

    history_link = f"[Full release notes history](https://github.com/{repository}/releases)"
    versions = [(version, first_sections)]
    included_blocks = [format_block(version, first_sections, first_context)]
    for label, step_prev, step_rev in prior_steps:
        sections, repo_context, _ = version_sections(
            root, repository, step_prev, step_rev, host_root, pr_cache, False
        )
        block = format_block(label, sections, repo_context)
        if not within_markdown_limits("\n\n".join([*included_blocks, block, history_link]) + "\n"):
            break
        included_blocks.append(block)
        versions.append((label, sections))
    markdown = "\n\n".join([*included_blocks, history_link]) + "\n"
    document = {
        "schemaVersion": 1, "repository": repository, "version": version, "build": build,
        "sourceRevision": revision, "markdown": markdown, "plainText": plain_text(versions),
    }
    validate(document, version, build)
    return document


def validate(document, version, build):
    if document.get("schemaVersion") != 1:
        raise ValueError("Unsupported release-notes schema")
    if document.get("version") != version or document.get("build") != build:
        raise ValueError("Release notes do not match this version and build")
    if not re.fullmatch(r"[0-9a-f]{40}", document.get("sourceRevision", "")):
        raise ValueError("Invalid release-notes source revision")
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*", document.get("repository", "")):
        raise ValueError("Invalid release-notes repository")
    for key in ("markdown", "plainText"):
        if not isinstance(document.get(key), str) or not document[key].strip():
            raise ValueError(f"Release notes require {key}")
    if not within_markdown_limits(document["markdown"]):
        raise ValueError("Release notes exceed the Markdown rendering limits")
    if len(document["plainText"].encode("utf-16-le")) // 2 > 4000:
        raise ValueError("TestFlight notes exceed 4000 characters")
    if len(json.dumps(document, ensure_ascii=False).encode("utf-8")) > MAX_BYTES:
        raise ValueError("Release notes exceed the bundled size limit")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("generate")
    create.add_argument("--root", type=Path, required=True)
    create.add_argument("--repository", required=True)
    create.add_argument("--previous")
    create.add_argument("--output", type=Path, required=True)
    create.add_argument("--host-root", type=Path,
                        help="Verified public desktop checkout for an integrated desktop build")
    create.add_argument("--prior-release", dest="prior_releases", action="append", default=[])
    check = sub.add_parser("validate")
    check.add_argument("--file", type=Path, required=True)
    check.add_argument("--markdown", action="store_true")
    for command in (create, check):
        command.add_argument("--version", required=True)
        command.add_argument("--build", required=True)
    args = parser.parse_args()
    if args.command == "generate":
        document = generate(args.root, args.repository, args.previous, args.version, args.build,
                            args.host_root, args.prior_releases)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(document, ensure_ascii=False) + "\n", encoding="utf-8")
    else:
        if args.file.stat().st_size > MAX_BYTES:
            raise ValueError("Release notes exceed the bundled size limit")
        document = json.loads(args.file.read_text(encoding="utf-8"))
        validate(document, args.version, args.build)
        if args.markdown:
            print(current_version_markdown(document), end="")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: release notes: {error}", file=sys.stderr)
        sys.exit(1)
