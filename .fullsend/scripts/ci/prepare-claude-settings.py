#!/usr/bin/env python3
"""Remove the unused local assessment directory from disposable CI settings."""
import json
import sys
from pathlib import Path


def prepare(root):
    path = Path(root) / ".claude/settings.json"
    if not path.exists():
        return
    settings = json.loads(path.read_text())
    permissions = settings.get("permissions", {})
    directories = permissions.get("additionalDirectories", [])
    if "/tmp/strat-assess" not in directories:
        return
    remaining = [value for value in directories if value != "/tmp/strat-assess"]
    if remaining:
        permissions["additionalDirectories"] = remaining
    else:
        permissions.pop("additionalDirectories")
    path.write_text(json.dumps(settings, indent=2) + "\n")


if __name__ == "__main__":
    prepare(sys.argv[1])
