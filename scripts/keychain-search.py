#!/usr/bin/env python3
"""Coordinate job-keychain registration and native deletion for one macOS user."""

from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import pwd
import shlex
import subprocess
import sys


def absolute_path(value):
    path = Path(value)
    if not path.is_absolute() or any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ValueError("Keychain paths must be absolute and contain no control characters")
    return path


def lock_path():
    home = Path(pwd.getpwuid(os.geteuid()).pw_dir)
    if not home.is_absolute() or not home.is_dir():
        raise ValueError("The macOS account must have an existing absolute home directory")
    return home / ".copilot-projects-keychain-search.lock"


@contextmanager
def keychain_lock():
    # Keep the inode: unlinking it would let later callers acquire a different lock.
    with os.fdopen(os.open(lock_path(), os.O_CREAT | os.O_RDWR, 0o600), "r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def search_paths(text):
    paths = []
    for line in text.splitlines():
        if not line.strip():
            continue
        values = shlex.split(line)
        if len(values) != 1:
            raise ValueError("Malformed keychain search-list entry")
        value = values[0]
        absolute_path(value)
        paths.append(value)
    if not paths or not any(Path(path).is_file() for path in paths):
        raise ValueError("No existing keychain is reachable; repair the user's search list first")
    return paths


def command(*args):
    return subprocess.check_output(args, text=True)


def register_keychain(keychain, execute=command):
    with keychain_lock():
        target = absolute_path(keychain)
        if not target.is_file():
            raise ValueError("The job keychain must already exist at an absolute path")
        target = target.resolve()
        for _ in range(3):
            current = search_paths(execute("security", "list-keychains", "-d", "user"))
            if any(Path(path).resolve() == target for path in current):
                return
            execute("security", "list-keychains", "-d", "user", "-s", *current, str(target))
            observed = search_paths(execute("security", "list-keychains", "-d", "user"))
            if any(Path(path).resolve() == target for path in observed):
                return
        raise RuntimeError("Concurrent search-list changes prevented job-keychain registration")


def delete_keychain(keychain, execute=command):
    with keychain_lock():
        target = absolute_path(keychain)
        if not os.path.lexists(target):
            return
        if not target.is_file():
            raise ValueError("The job keychain must be a file")
        execute("security", "delete-keychain", str(target.resolve()))


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--delete":
        delete_keychain(sys.argv[2])
        print("Job signing keychain is absent; no search-list snapshot was restored.")
    elif len(sys.argv) == 2:
        register_keychain(sys.argv[1])
        print("Job signing keychain is registered; existing search paths were preserved.")
    else:
        raise ValueError("Usage: keychain-search.py [--delete] /absolute/job.keychain-db")
