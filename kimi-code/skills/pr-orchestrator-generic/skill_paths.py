#!/usr/bin/env python3
"""Resolve installed agent skills without duplicating host-specific paths."""
from __future__ import annotations
import os
import sys
from pathlib import Path

ROOTS = (".kimi-code/skills", ".grok/skills", ".grok/bundled/skills", ".agents/skills", ".ori/skills", ".claude/skills")

def candidates(name: str) -> list[Path]:
    if not name or "/" in name or "\\" in name or ".." in name.split("/"):
        raise ValueError("skill name must be a simple skill directory name")
    home = Path.home()
    return [home / root / name / "SKILL.md" for root in ROOTS]

def resolve(name: str) -> Path | None:
    return next((path for path in candidates(name) if path.is_file()), None)

def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: skill_paths.py <skill-name>", file=sys.stderr)
        return 2
    try:
        path = resolve(argv[1])
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    if path is None:
        return 1
    print(path)
    return 0

if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
