#!/usr/bin/env python3
"""Scan known skill roots on this machine and print an inventory.

Usage:
  python3 scripts/inventory-skills.py
  python3 scripts/inventory-skills.py --duplicates-only
  python3 scripts/inventory-skills.py --check   # exit 1 on broken links / multi-real

For the managed install plane (registry apply/verify), prefer:
  python3 scripts/skillctl.py doctor
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
from collections import defaultdict
from pathlib import Path

HOME = Path.home()
CODE = HOME / "01_code"


def skill_roots() -> list[Path]:
    roots = [
        HOME / ".grok" / "skills",
        HOME / ".grok" / "bundled" / "skills",
        HOME / ".kimi-code" / "skills",
        HOME / ".agents" / "skills",
        HOME / ".kimi" / "skills",
        HOME / ".claude" / "skills",
        HOME / ".config" / "agents" / "skills",
        HOME / ".codex" / "skills",
        HOME / ".hermes" / "skills",
        CODE / "kimi-skills" / "kimi-code" / "skills",
        CODE / "kimi-skills" / "agents" / "skills",
    ]
    if CODE.exists():
        for repo in CODE.iterdir():
            if not repo.is_dir() or repo.name.startswith("."):
                continue
            for rel in (
                ".kimi/skills",
                ".grok/skills",
                ".agents/skills",
                ".github/skills",
                ".claude/skills",
                ".cursor/skills",
            ):
                p = repo / rel
                if p.exists():
                    roots.append(p)
    # de-dupe while preserving order
    seen: set[str] = set()
    out: list[Path] = []
    for r in roots:
        key = str(r)
        if key not in seen:
            seen.add(key)
            out.append(r)
    return out


def md5_file(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()[:10]


def has_skill_md(path: Path) -> bool:
    """True if SKILL.md exists or is a (possibly broken) symlink."""
    sm = path / "SKILL.md"
    return sm.exists() or sm.is_symlink()


def iter_skills(root: Path):
    if not root.exists() and not root.is_symlink():
        return
    if has_skill_md(root):
        yield root
        return
    try:
        children = sorted(root.iterdir())
    except (PermissionError, OSError):
        return
    for child in children:
        if child.name.startswith("."):
            continue
        if (child.is_dir() or child.is_symlink()) and has_skill_md(child):
            yield child


def short(path: Path | str) -> str:
    s = str(path)
    return s.replace(str(HOME), "~")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--duplicates-only",
        action="store_true",
        help="Only print skill names that appear in more than one location",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit 1 if any broken SKILL.md links or multi-real content copies",
    )
    args = parser.parse_args()

    by_name: dict[str, list[dict]] = defaultdict(list)
    roots = skill_roots()
    broken: list[str] = []
    multi_real: list[str] = []

    for root in roots:
        root_link = root.is_symlink()
        root_target = os.readlink(root) if root_link else None
        for skill in iter_skills(root):
            skill_md = skill / "SKILL.md"
            link_target = None
            if skill_md.is_symlink():
                link_target = os.readlink(skill_md)
            elif skill.is_symlink():
                link_target = os.readlink(skill)
            is_broken = skill_md.is_symlink() and not skill_md.exists()
            try:
                if is_broken:
                    lines, digest = 0, "BROKEN"
                    resolved = "BROKEN"
                    broken.append(f"{short(skill_md)} -> {link_target}")
                else:
                    lines = sum(1 for _ in skill_md.open(encoding="utf-8", errors="replace"))
                    digest = md5_file(skill_md)
                    resolved = str(skill_md.resolve())
            except OSError:
                lines, digest, resolved = 0, "ERR", "ERR"
                broken.append(f"{short(skill_md)} (unreadable)")
            # Real content = regular file in a non-symlink skill dir.
            # Root symlink (~/.kimi-code/skills) still marks is_real; multi-real
            # check de-dupes by resolved path so catalog + install root = one copy.
            is_real = (
                skill_md.is_file()
                and not skill_md.is_symlink()
                and not skill.is_symlink()
                and not is_broken
            )
            name = skill.name
            try:
                if not is_broken and skill_md.is_file():
                    text = skill_md.read_text(encoding="utf-8", errors="replace")
                    if text.startswith("---"):
                        fm = text.split("---", 2)[1]
                        for line in fm.splitlines():
                            if line.startswith("name:"):
                                name = line.split(":", 1)[1].strip().strip("\"'")
            except OSError:
                pass
            by_name[name].append(
                {
                    "path": skill,
                    "lines": lines,
                    "md5": digest,
                    "root_link": root_link,
                    "root_target": root_target,
                    "link_target": link_target,
                    "resolved": resolved,
                    "is_real": is_real,
                    "is_broken": is_broken,
                }
            )

    if not args.duplicates_only or args.check:
        if not args.check or not args.duplicates_only:
            if not args.check:
                print(f"Roots scanned: {len(roots)}")
                print(f"Unique skill names: {len(by_name)}")
                print(f"Instances: {sum(len(v) for v in by_name.values())}")
                print()
                print(f"{'name':<40} {'lines':>5} {'md5':<10} location")
                print("-" * 120)
                for name in sorted(by_name):
                    for inst in by_name[name]:
                        flag = ""
                        if inst["is_broken"]:
                            flag = f" BROKEN -> {inst['link_target']}"
                        elif inst["link_target"]:
                            flag = f" -> {inst['link_target']}"
                        elif inst["root_link"]:
                            flag = f" [root-> {inst['root_target']}]"
                        print(
                            f"{name:<40} {inst['lines']:>5} {inst['md5']:<10} "
                            f"{short(inst['path'])}{flag}"
                        )
                print()

    print("=== DUPLICATES / COLLISIONS ===")
    for name in sorted(by_name):
        insts = by_name[name]
        reals = [i for i in insts if i.get("is_real")]
        # Distinct content locations only (ignore root-symlink double scan)
        distinct_real = {
            i["resolved"]
            for i in reals
            if i.get("resolved") and i["resolved"] not in ("BROKEN", "ERR")
        }
        if len(distinct_real) > 1:
            # one path per resolved
            shown = []
            seen_r: set[str] = set()
            for i in reals:
                r = i.get("resolved")
                if r and r not in seen_r:
                    seen_r.add(r)
                    shown.append(short(i["path"]))
            multi_real.append(f"{name}: " + ", ".join(shown))
        if len(insts) < 2:
            continue
        digests = {i["md5"] for i in insts}
        resolved = {i["resolved"] for i in insts}
        print(
            f"\n## {name}  (n={len(insts)}; "
            f"content_identical={len(digests) == 1}; "
            f"same_resolved={len(resolved) == 1}; "
            f"distinct_real={len(distinct_real)})"
        )
        for i in insts:
            flag = ""
            if i.get("is_broken"):
                flag = f" BROKEN -> {i['link_target']}"
            elif i["link_target"]:
                flag = f" -> {i['link_target']}"
            elif i["root_link"]:
                flag = f" [root-> {i['root_target']}]"
            kind = "REAL" if i.get("is_real") else ("BROKEN" if i.get("is_broken") else "link")
            print(f"   {i['md5']} {i['lines']:>4}L [{kind}] {short(i['path'])}{flag}")

    if broken:
        print("\n=== BROKEN LINKS ===")
        for b in broken:
            print(f"  {b}")

    if multi_real:
        print("\n=== MULTI-REAL (content copies) ===")
        for m in multi_real:
            print(f"  {m}")

    if args.check:
        if broken or multi_real:
            print(
                f"\nCHECK FAILED: {len(broken)} broken, {len(multi_real)} multi-real. "
                "Fix managed skills with: python3 scripts/skillctl.py apply",
                file=sys.stderr,
            )
            sys.exit(1)
        print("\nCHECK OK")
        sys.exit(0)


if __name__ == "__main__":
    main()
