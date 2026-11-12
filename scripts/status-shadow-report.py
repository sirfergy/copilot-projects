#!/usr/bin/env python3
"""Summarise the status shadow log. Reads it and prints; writes nothing.

status-shadow.jsonl records where the status a session showed differed from the
status its tracker alone would have given.

Temporary: deleted together with Sources/CopilotProjectsHost/StatusShadow.swift.
"""

import argparse
import collections
import json
import os
import time
from pathlib import Path


def entries(paths):
    for path in paths:
        for raw in path.read_text(encoding="utf-8").splitlines():
            yield json.loads(raw), raw


def unfinished(started, last, latest):
    for begun, raw in started.values():
        yield begun, raw, last, latest


def disagreements(log, now):
    """Yields (start entry, its raw line, end in ms, latest possible end in ms).

    The latest possible end is None when an end line was logged. A disagreement
    with none is unfinished: it held at least until the last line its app launch
    logged, and at most until the next launch began, or until now in the latest
    launch. Nothing is logged while a comparison stays the same, so the log cannot
    tell a quiet app from one that has quit.
    """
    started = {}
    run = last = None
    for entry, raw in log:
        if entry["run"] != run:
            yield from unfinished(started, last, entry["run"])
            started.clear()
            run = entry["run"]
        last = entry["t"]
        key = (entry["what"], entry["sid"])
        if key in started:
            begun, begun_raw = started.pop(key)
            yield begun, begun_raw, entry["t"], None
        if not entry.get("over") and entry["shown"] != entry["tracker"]:
            started[key] = (entry, raw)
    yield from unfinished(started, last, now)


def kind(entry):
    return f'{entry["what"]}: shown {entry["shown"]}, tracker-only {entry["tracker"]} (tracker {entry["state"]})'


def span(milliseconds):
    seconds = milliseconds / 1000
    if seconds < 60:
        return f"{seconds:.1f}s"
    minutes, seconds = divmod(int(seconds), 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h {minutes:02d}m" if hours else f"{minutes}m {seconds:02d}s"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--state-dir", type=Path, default=Path(
        os.environ.get("COPILOT_PROJECTS_STATE_DIR") or Path.home() / ".local/state/copilot-projects"))
    parser.add_argument("--lasting", type=float, default=30, metavar="SECONDS",
                        help="a disagreement at least this long is lasting, not a transition (default 30)")
    parser.add_argument("--samples", type=int, default=2, help="log lines to show per kind (default 2)")
    args = parser.parse_args()

    current = args.state_dir / "status-shadow.jsonl"
    paths = [path for path in (current.with_name(current.name + ".1"), current) if path.exists()]
    read = list(entries(paths))
    # A line with `alive` was logged when the footer stood in for a stale tracker.
    # That is another rule, so the app launches that logged one are left out.
    older = {entry["run"] for entry, _ in read if "alive" in entry}
    log = [item for item in read if item[0]["run"] not in older]
    if older:
        print(f"Left out {len(read) - len(log)} lines logged before tracker-only status held a stale reading.")
    if not log:
        print(f"Nothing to report from {current}: no disagreement has been logged under the current rule.")
        return
    ended = collections.defaultdict(list)
    open_ended = collections.defaultdict(list)
    for begun, raw, end, latest in disagreements(log, int(time.time() * 1000)):
        if latest is None:
            ended[kind(begun)].append((end - begun["t"], begun["sid"], raw))
        else:
            open_ended[kind(begun)].append(
                (latest - begun["t"], end - begun["t"], begun["sid"], begun["t"], raw))

    def lasting(found):
        return [item for item in found if item[0] >= args.lasting * 1000]

    def total(found):
        return span(sum(item[0] for item in found))

    stamp = lambda ms: time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ms / 1000))
    first, last = log[0][0]["t"], log[-1][0]["t"]
    print(" + ".join(str(path) for path in paths))
    print(f"{len(log)} lines from {stamp(first)} to {stamp(last)} ({span(last - first)}), "
          f"{len({entry['run'] for entry, _ in log})} app launches, "
          f"{len({entry['sid'] for entry, _ in log})} sessions with a disagreement")
    print(f"Lasting: an ended disagreement that held {args.lasting:g}s or longer. Unfinished ones "
          "have no end line and are\nlisted last with the least and most time they can have held.")
    if len(paths) > 1:
        print("The log has rotated: disagreements that began before the first line here may be missing.")
    print()

    ordered = sorted(ended.items(), key=lambda item: (
        -sum(length for length, *_ in lasting(item[1])), -sum(length for length, *_ in item[1])))
    for title, wanted in (("LASTING", True), ("TRANSITIONS ONLY", False)):
        print(title)
        shown = [(name, found) for name, found in ordered if bool(lasting(found)) == wanted]
        for name, found in shown:
            print(f"  {name}")
            print(f"    {len(found)} disagreements in {len({item[1] for item in found})} sessions, "
                  f"{total(found)} in total, longest {span(max(found)[0])}")
            if wanted:
                print(f"    lasting: {len(lasting(found))} for {total(lasting(found))}")
            for length, _, raw in sorted(found, reverse=True)[:args.samples]:
                print(f"    {span(length)}: {raw}")
        if not shown:
            print("  none")
        print()

    print("UNFINISHED")
    for name, found in sorted(open_ended.items(), key=lambda item: -max(item[1])[0]):
        print(f"  {name}")
        print(f"    {len(found)} disagreements in {len({item[2] for item in found})} sessions")
        for most, least, _, start, raw in sorted(found, reverse=True)[:args.samples]:
            print(f"    since {stamp(start)}, at least {span(least)}, at most {span(most)}: {raw}")
    if not open_ended:
        print("  none")


if __name__ == "__main__":
    main()
