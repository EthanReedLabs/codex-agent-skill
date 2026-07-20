#!/usr/bin/env python3
"""Extract the first Codex session UUID from a JSONL event stream."""
from __future__ import annotations

import json
from pathlib import Path
import re
import sys

UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
KEYS = {"thread_id", "session_id", "threadId", "sessionId"}


def find(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if key in KEYS and isinstance(item, str) and UUID.fullmatch(item):
                return item.lower()
        for item in value.values():
            found = find(item)
            if found:
                return found
    elif isinstance(value, list):
        for item in value:
            found = find(item)
            if found:
                return found
    return None


def main() -> int:
    if len(sys.argv) != 2:
        return 2
    try:
        with Path(sys.argv[1]).open(encoding="utf-8") as handle:
            for line in handle:
                try:
                    found = find(json.loads(line))
                except json.JSONDecodeError:
                    continue
                if found:
                    print(found)
                    return 0
    except OSError:
        return 1
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
