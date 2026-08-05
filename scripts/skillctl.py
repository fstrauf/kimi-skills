#!/usr/bin/env python3
"""Skill control plane for this machine.

Declarative registry (skills-registry.yaml) + apply / verify / doctor.

  python3 scripts/skillctl.py list
  python3 scripts/skillctl.py verify          # exit 1 on drift
  python3 scripts/skillctl.py apply           # fix install links
  python3 scripts/skillctl.py apply --dry-run
  python3 scripts/skillctl.py doctor          # verify + unmanaged collisions
  python3 scripts/skillctl.py check           # alias for doctor (CI-friendly)

Stability model:
  - Registry names the *one* canonical path per skill.
  - Install paths are always SKILL.md symlinks to that canonical file.
  - Root links (~/.kimi-code/skills, ~/.agents/skills) point at kimi-skills.
  - verify fails if anything drifts; re-run apply after moving a skill.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
from collections import defaultdict
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    print("PyYAML required: pip install pyyaml / brew install pyyaml", file=sys.stderr)
    sys.exit(2)

HOME = Path.home()
REPO = Path(__file__).resolve().parents[1]
DEFAULT_REGISTRY = REPO / "skills-registry.yaml"


def expand(p: str | Path) -> Path:
    return Path(os.path.expanduser(str(p))).resolve()


def expand_maybe_missing(p: str | Path) -> Path:
    """Expand ~ but do not resolve (broken symlinks still show intended path)."""
    return Path(os.path.expanduser(str(p)))


def short(path: Path | str) -> str:
    s = str(path)
    home = str(HOME)
    if s.startswith(home):
        return "~" + s[len(home) :]
    return s


def load_registry(path: Path) -> dict:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or "skills" not in data:
        raise SystemExit(f"Invalid registry: {path}")
    return data


def skill_md(skill_dir: Path) -> Path:
    return skill_dir / "SKILL.md"


def link_target_of(path: Path) -> Path | None:
    if not path.is_symlink() and not path.exists():
        # broken symlink: Path.is_symlink() is True even if target missing
        pass
    if path.is_symlink():
        raw = os.readlink(path)
        target = Path(raw)
        if not target.is_absolute():
            target = (path.parent / target)
        return target
    return None


def same_file(a: Path, b: Path) -> bool:
    try:
        return a.exists() and b.exists() and a.resolve() == b.resolve()
    except OSError:
        return False


def md5_file(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()[:10]


# ── root links ─────────────────────────────────────────────────────────────


def check_root_links(reg: dict) -> list[str]:
    errors: list[str] = []
    for entry in reg.get("root_links") or []:
        path = expand_maybe_missing(entry["path"])
        want = expand(entry["target"])
        if not path.exists() and not path.is_symlink():
            errors.append(f"root missing: {short(path)} (want -> {short(want)})")
            continue
        if not path.is_symlink():
            errors.append(f"root not a symlink: {short(path)}")
            continue
        got = expand(path)
        if got != want:
            errors.append(
                f"root wrong target: {short(path)} -> {short(got)} (want {short(want)})"
            )
    return errors


def apply_root_links(reg: dict, dry_run: bool) -> list[str]:
    actions: list[str] = []
    for entry in reg.get("root_links") or []:
        path = expand_maybe_missing(entry["path"])
        want = expand(entry["target"])
        if path.is_symlink() and expand(path) == want:
            continue
        actions.append(f"root-link {short(path)} -> {short(want)}")
        if dry_run:
            continue
        if path.is_symlink() or path.exists():
            if path.is_dir() and not path.is_symlink():
                raise SystemExit(
                    f"Refusing to replace real directory with symlink: {path}"
                )
            path.unlink()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(want, target_is_directory=True)
    return actions


# ── skill installs ─────────────────────────────────────────────────────────


def expected_installs(name: str, meta: dict) -> list[Path]:
    """Install directories that should contain SKILL.md -> canonical/SKILL.md."""
    out: list[Path] = []
    for raw in meta.get("install") or []:
        out.append(expand_maybe_missing(raw))
    return out


def check_skill(name: str, meta: dict) -> list[str]:
    errors: list[str] = []
    canon_dir = expand_maybe_missing(meta["canonical"])
    canon_md = skill_md(canon_dir)
    if not canon_md.is_file():
        errors.append(f"{name}: canonical missing {short(canon_md)}")
        return errors
    if canon_md.is_symlink():
        # Allow canonical to be a symlink only if it resolves to a real file;
        # prefer real file at product/universal home.
        if not canon_md.resolve().is_file():
            errors.append(f"{name}: canonical SKILL.md is a broken symlink")
            return errors

    for inst_dir in expected_installs(name, meta):
        inst_md = skill_md(inst_dir)
        if not inst_md.exists() and not inst_md.is_symlink():
            errors.append(f"{name}: install missing {short(inst_md)}")
            continue
        if not inst_md.is_symlink():
            errors.append(
                f"{name}: install is a real file (should be symlink): {short(inst_md)}"
            )
            continue
        if not same_file(inst_md, canon_md):
            tgt = link_target_of(inst_md)
            errors.append(
                f"{name}: install points elsewhere: {short(inst_md)} -> "
                f"{short(tgt) if tgt else '?'} (want {short(canon_md)})"
            )
    return errors


def apply_skill(name: str, meta: dict, dry_run: bool) -> list[str]:
    actions: list[str] = []
    canon_dir = expand_maybe_missing(meta["canonical"])
    canon_md = skill_md(canon_dir)
    if not canon_md.is_file():
        raise SystemExit(f"Cannot apply {name}: canonical missing {canon_md}")

    # Prefer absolute symlink to resolved real file so moves of intermediate
    # dirs don't leave relative traps; resolve once at apply time.
    target = canon_md.resolve()

    for inst_dir in expected_installs(name, meta):
        inst_md = skill_md(inst_dir)
        if inst_md.is_symlink() and same_file(inst_md, canon_md):
            continue
        actions.append(f"link {short(inst_md)} -> {short(target)}")
        if dry_run:
            continue
        inst_dir.mkdir(parents=True, exist_ok=True)
        if inst_md.is_symlink() or inst_md.exists():
            inst_md.unlink()
        inst_md.symlink_to(target)
    return actions


def cleanup_stale(reg: dict, dry_run: bool) -> list[str]:
    actions: list[str] = []
    for raw in reg.get("cleanup") or []:
        path = expand_maybe_missing(raw)
        if path.exists() or path.is_symlink():
            actions.append(f"remove stale {short(path)}")
            if not dry_run:
                path.unlink()
    return actions


# ── Grok config (advisory) ─────────────────────────────────────────────────


def check_grok_config(reg: dict) -> list[str]:
    warnings: list[str] = []
    gc = reg.get("grok_config") or {}
    cfg_path = expand_maybe_missing(gc.get("path", "~/.grok/config.toml"))
    if not cfg_path.is_file():
        warnings.append(f"grok config missing: {short(cfg_path)}")
        return warnings
    text = cfg_path.read_text(encoding="utf-8", errors="replace")
    for expect in gc.get("expect_skills_paths") or []:
        # Accept with or without quotes / expanded home
        needle = str(expect)
        alt = str(expand_maybe_missing(expect))
        if needle not in text and alt not in text and needle.replace("~", "") not in text:
            # also try the literal ~/.kimi-code/skills form
            if "~/.kimi-code/skills" not in text and "kimi-code/skills" not in text:
                warnings.append(
                    f"grok config may lack skills.paths entry for {needle} "
                    f"({short(cfg_path)})"
                )
    return warnings


# ── unmanaged collision scan ───────────────────────────────────────────────


def scan_skill_roots() -> dict[str, list[dict]]:
    """Lightweight scan: name -> instances with real-vs-link info."""
    code = HOME / "01_code"
    roots = [
        HOME / ".grok" / "skills",
        HOME / ".kimi-code" / "skills",
        HOME / ".agents" / "skills",
        REPO / "kimi-code" / "skills",
        REPO / "agents" / "skills",
    ]
    if code.is_dir():
        for repo in code.iterdir():
            if not repo.is_dir() or repo.name.startswith("."):
                continue
            for rel in (".agents/skills", ".grok/skills", ".kimi/skills"):
                p = repo / rel
                if p.exists():
                    roots.append(p)

    by_name: dict[str, list[dict]] = defaultdict(list)
    seen_roots: set[str] = set()
    for root in roots:
        key = str(root.resolve()) if root.exists() else str(root)
        if key in seen_roots:
            continue
        seen_roots.add(key)
        if not root.exists():
            continue
        try:
            children = list(root.iterdir())
        except PermissionError:
            continue
        # root itself may be a skill (rare)
        candidates = []
        if (root / "SKILL.md").exists() or (root / "SKILL.md").is_symlink():
            candidates.append(root)
        for child in children:
            if child.name.startswith("."):
                continue
            if child.is_dir() or child.is_symlink():
                sm = child / "SKILL.md"
                if sm.exists() or sm.is_symlink():
                    candidates.append(child)
        for skill in candidates:
            sm = skill / "SKILL.md"
            # Directory symlink (e.g. pageseeds/.grok/skills/foo -> .agents/...) is not content.
            dir_is_link = skill.is_symlink()
            sm_is_link = sm.is_symlink()
            digest = "MISSING"
            resolved = None
            is_real = False
            if sm_is_link and not sm.exists():
                digest = "BROKEN"
            elif sm.exists() or (sm_is_link and sm.exists()):
                try:
                    resolved = str(sm.resolve())
                    digest = md5_file(sm)
                    # Real content only: regular SKILL.md, skill dir not a symlink.
                    # (Root symlink like ~/.kimi-code/skills still yields is_real True
                    #  for the same inode — de-duped by resolved path below.)
                    is_real = sm.is_file() and not sm_is_link and not dir_is_link
                except OSError:
                    digest = "BROKEN"
            by_name[skill.name].append(
                {
                    "path": skill,
                    "md5": digest,
                    "is_link": dir_is_link or sm_is_link,
                    "is_real": is_real,
                    "resolved": resolved,
                }
            )
    return by_name


def unmanaged_collisions(reg: dict) -> list[str]:
    """Distinct real-file copies of the same skill name (by resolved path)."""
    managed = set(reg.get("skills") or {})
    # Paths we expect to share one resolved file via root install links — not collisions.
    by_name = scan_skill_roots()
    errors: list[str] = []
    for name, insts in sorted(by_name.items()):
        reals = [i for i in insts if i["is_real"] and i["md5"] not in ("BROKEN", "MISSING")]
        # Unique content locations
        by_resolved: dict[str, list] = defaultdict(list)
        for i in reals:
            key = i["resolved"] or str(i["path"])
            by_resolved[key].append(i)
        if len(by_resolved) > 1:
            paths = ", ".join(
                short(insts_for[0]["path"]) for insts_for in by_resolved.values()
            )
            digests = {i["md5"] for i in reals}
            same = "identical" if len(digests) == 1 else "DIVERGED"
            tag = "managed" if name in managed else "unmanaged"
            errors.append(f"multi-real [{tag}] {name} ({same}): {paths}")
        for i in insts:
            if i["md5"] == "BROKEN" and name not in managed:
                errors.append(f"broken unmanaged link: {short(i['path'] / 'SKILL.md')}")
    return errors


# ── commands ───────────────────────────────────────────────────────────────


def cmd_list(reg: dict) -> int:
    print(f"{'name':<36} {'bucket':<4} canonical")
    print("-" * 100)
    for name, meta in sorted((reg.get("skills") or {}).items()):
        print(f"{name:<36} {meta.get('bucket', '?'):<4} {meta['canonical']}")
        for inst in meta.get("install") or []:
            print(f"{'':36} {'':4} install: {inst}")
    return 0


def cmd_verify(reg: dict, *, quiet: bool = False) -> int:
    errors: list[str] = []
    errors.extend(check_root_links(reg))
    for name, meta in sorted((reg.get("skills") or {}).items()):
        errors.extend(check_skill(name, meta))
    for raw in reg.get("cleanup") or []:
        path = expand_maybe_missing(raw)
        if path.exists() or path.is_symlink():
            errors.append(f"stale file still present: {short(path)}")

    warnings = check_grok_config(reg)

    if not quiet:
        if not errors and not warnings:
            print("OK — registry install plane is healthy")
            n = len(reg.get("skills") or {})
            print(f"  skills managed: {n}")
            return 0
        for w in warnings:
            print(f"WARN  {w}")
        for e in errors:
            print(f"ERROR {e}")
        if errors:
            print(f"\n{len(errors)} error(s). Run: python3 scripts/skillctl.py apply")
            return 1
        print("OK with warnings only")
        return 0
    return 1 if errors else 0


def cmd_apply(reg: dict, dry_run: bool) -> int:
    actions: list[str] = []
    actions.extend(apply_root_links(reg, dry_run))
    for name, meta in sorted((reg.get("skills") or {}).items()):
        actions.extend(apply_skill(name, meta, dry_run))
    actions.extend(cleanup_stale(reg, dry_run))

    if not actions:
        print("Nothing to do — already applied")
        return cmd_verify(reg)

    prefix = "DRY-RUN " if dry_run else ""
    for a in actions:
        print(f"{prefix}{a}")
    if dry_run:
        print(f"\n{len(actions)} action(s) would run. Re-run without --dry-run to apply.")
        return 0
    print(f"\nApplied {len(actions)} action(s). Verifying…")
    return cmd_verify(reg)


def cmd_doctor(reg: dict, *, strict: bool = False) -> int:
    print("=== registry verify ===")
    rc = cmd_verify(reg)
    print("\n=== collision scan (distinct real SKILL.md by resolved path) ===")
    collisions = unmanaged_collisions(reg)
    managed_errs = [c for c in collisions if "[managed]" in c]
    unmanaged = [c for c in collisions if "[unmanaged]" in c or c.startswith("broken")]
    if not collisions:
        print("OK — no multi-real skill names found in scanned roots")
    else:
        for c in managed_errs:
            print(f"ERROR {c}")
        for c in unmanaged:
            print(f"WARN  {c}")
        if managed_errs:
            rc = 1
        elif strict and unmanaged:
            rc = 1
        elif unmanaged and rc == 0:
            print(
                "\nManaged plane OK; unmanaged warnings only "
                "(use --strict to fail on those too)."
            )
    print("\n=== tip ===")
    print("After moving a B2 skill: update skills-registry.yaml canonical, then apply.")
    print("Re-check anytime: python3 scripts/skillctl.py doctor")
    return rc


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "-r",
        "--registry",
        type=Path,
        default=DEFAULT_REGISTRY,
        help=f"registry path (default: {DEFAULT_REGISTRY})",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="List managed skills from registry")
    sub.add_parser("verify", help="Check install plane matches registry (exit 1 on drift)")
    p_apply = sub.add_parser("apply", help="Create/fix install symlinks from registry")
    p_apply.add_argument("--dry-run", action="store_true")
    p_doc = sub.add_parser("doctor", help="verify + scan for multi-real / broken unmanaged")
    p_doc.add_argument(
        "--strict",
        action="store_true",
        help="Also fail on unmanaged multi-real / broken links outside registry",
    )
    p_check = sub.add_parser("check", help="Alias for doctor (CI / launchd friendly)")
    p_check.add_argument("--strict", action="store_true")

    args = parser.parse_args()
    reg_path = args.registry if args.registry.is_absolute() else (Path.cwd() / args.registry)
    if not reg_path.is_file():
        # fall back to repo-relative
        reg_path = DEFAULT_REGISTRY
    if not reg_path.is_file():
        raise SystemExit(f"Registry not found: {reg_path}")

    reg = load_registry(reg_path)

    if args.cmd == "list":
        raise SystemExit(cmd_list(reg))
    if args.cmd == "verify":
        raise SystemExit(cmd_verify(reg))
    if args.cmd == "apply":
        raise SystemExit(cmd_apply(reg, dry_run=args.dry_run))
    if args.cmd in ("doctor", "check"):
        raise SystemExit(cmd_doctor(reg, strict=getattr(args, "strict", False)))
    raise SystemExit(f"unknown command {args.cmd}")


if __name__ == "__main__":
    main()
