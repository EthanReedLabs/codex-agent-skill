#!/usr/bin/env python3
"""Emit a deterministic JSON snapshot of project files for scope verification."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import sys

SKIP_DIRS = {".codex-agent", ".git", ".hg", ".svn", "__pycache__", ".pytest_cache"}
GIT_FILES = ("HEAD", "config", "index", "packed-refs")


def digest(path: Path) -> str:
    value = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                value.update(chunk)
    except (OSError, PermissionError) as exc:
        return f"!unreadable:{type(exc).__name__}"
    return f"{path.stat().st_mode & 0o7777:o}:{value.hexdigest()}"


def snapshot(root: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for current, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            path = Path(current, name)
            rel = path.relative_to(root).as_posix()
            if path.is_symlink():
                try:
                    result[rel] = "@" + os.readlink(path)
                except OSError as exc:
                    result[rel] = f"!unreadable:{type(exc).__name__}"
            elif path.is_file():
                result[rel] = digest(path)
    git_dir = root / ".git"
    if git_dir.is_dir():
        candidates = [git_dir / name for name in GIT_FILES]
        refs = git_dir / "refs"
        if refs.is_dir():
            candidates.extend(path for path in refs.rglob("*") if path.is_file())
        for path in candidates:
            if path.is_file():
                result[path.relative_to(root).as_posix()] = digest(path)
    elif git_dir.is_file():
        result[".git"] = digest(git_dir)
    return result


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: snapshot.py <project-root>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1]).resolve()
    if not root.is_dir():
        print(f"project root is not a directory: {root}", file=sys.stderr)
        return 2
    json.dump(snapshot(root), sys.stdout, ensure_ascii=False, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
