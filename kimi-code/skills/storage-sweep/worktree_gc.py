#!/usr/bin/env python3
"""Classify and (on request) remove git worktrees across every repo under CODE_ROOTS.

Covers Claude Code's in-repo `<repo>/.claude/worktrees/*`, plus any other linked
worktree. Default mode is READ-ONLY. A worktree is only ever SAFE to remove when
nothing about it looks alive or unique:

  KEEP    primary checkout, locked, dirty, mid-rebase/merge, open PR, commits on no
          remote, live process cwd, recent commit / recent Claude session / recent
          git activity, or PR status unknown while the branch is unmerged.
  REVIEW  clean + idle + pushed to a remote, but not merged and no PR record.
  SAFE    clean + idle + fully merged (ancestor of the default branch, or its PR
          is MERGED/CLOSED with no open PR).

  worktree_gc.py                         report
  worktree_gc.py --idle-days 1           shorter idle window
  worktree_gc.py --apply PATH...         remove SAFE paths (re-verified at delete time)
  worktree_gc.py --apply PATH... --include-review
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

HOME = Path.home()
DEFAULT_ROOTS = ["01_code", "code", "src", "dev", "Projects", "projects"]


def run(args: list[str], cwd: str | Path | None = None, timeout: int = 60) -> tuple[int, str]:
    try:
        p = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""
    return p.returncode, p.stdout.strip()


def git(repo: str | Path, *args: str) -> tuple[int, str]:
    # --no-optional-locks: `git status` must not refresh the index, or our own scan
    # would bump the mtime we use as the "last activity" signal.
    return run(["git", "--no-optional-locks", "-C", str(repo), *args])


def du_kb(path: str | Path) -> int:
    rc, out = run(["du", "-sk", str(path)], timeout=300)
    return int(out.split()[0]) if rc == 0 and out else 0


def human(kb: int) -> str:
    return f"{kb / 1048576:.1f}G" if kb >= 1048576 else f"{kb / 1024:.0f}M" if kb >= 1024 else f"{kb}K"


def live_cwds() -> list[str]:
    """Working directories of every process we can see (one lsof call)."""
    rc, out = run(["lsof", "-a", "-d", "cwd", "-Fn"], timeout=30)
    return [l[1:] for l in out.splitlines() if l.startswith("n")] if rc == 0 else []


def claude_session_mtime(path: Path) -> float:
    """Newest Claude Code transcript for this checkout (~/.claude/projects/<encoded>)."""
    enc = re.sub(r"[^A-Za-z0-9]", "-", str(path))
    d = HOME / ".claude" / "projects" / enc
    try:
        return max((f.stat().st_mtime for f in d.glob("*.jsonl")), default=0.0)
    except OSError:
        return 0.0


def default_branch(repo: Path) -> str:
    rc, out = git(repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    if rc == 0 and out:
        return out
    for cand in ("origin/main", "origin/master"):
        if git(repo, "rev-parse", "--verify", "-q", cand)[0] == 0:
            return cand
    return "origin/main"


def pr_states(repo: Path) -> dict[str, set[str]] | None:
    """branch -> {OPEN, MERGED, CLOSED}; None when gh is unavailable (=> unknown)."""
    rc, out = run(
        ["gh", "pr", "list", "--state", "all", "--limit", "300", "--json", "headRefName,state"],
        cwd=repo,
        timeout=60,
    )
    if rc != 0:
        return None
    try:
        rows = json.loads(out or "[]")
    except json.JSONDecodeError:
        return None
    states: dict[str, set[str]] = {}
    for r in rows:
        states.setdefault(r["headRefName"], set()).add(r["state"])
    return states


@dataclass
class Verdict:
    repo: str
    path: str
    branch: str
    status: str  # KEEP | REVIEW | SAFE
    reasons: list[str] = field(default_factory=list)
    size_kb: int = 0
    idle_days: float = 0.0


def registered_worktrees(repo: Path) -> list[dict]:
    rc, out = git(repo, "worktree", "list", "--porcelain")
    if rc != 0:
        return []
    items, cur = [], {}
    for line in out.splitlines() + [""]:
        if not line:
            if cur:
                items.append(cur)
            cur = {}
            continue
        k, _, v = line.partition(" ")
        cur[k] = v or True
    return items


def classify(repo: Path, wt: dict, ctx: dict, idle_days: float) -> Verdict:
    path = Path(wt["worktree"])
    branch = wt.get("branch", "").removeprefix("refs/heads/") or "(detached)"
    v = Verdict(str(repo), str(path), branch, "KEEP")
    keep = v.reasons

    if path == repo:
        keep.append("primary checkout")
        return v
    if not path.exists():
        v.status, v.reasons = "SAFE", ["directory missing (stale registration)"]
        return v
    if "locked" in wt:
        keep.append("locked")

    # --- liveness: anything that suggests someone is using it right now
    sp = str(path)
    if any(c == sp or c.startswith(sp + "/") for c in ctx["cwds"]):
        keep.append("live process in directory")
    _, gitdir = git(path, "rev-parse", "--absolute-git-dir")
    now = time.time()
    last = 0.0
    rc, ct = git(path, "log", "-1", "--format=%ct")
    if rc == 0 and ct.isdigit():
        last = float(ct)
    for name in ("HEAD", "index"):
        try:
            last = max(last, (Path(gitdir) / name).stat().st_mtime)
        except OSError:
            pass
    last = max(last, claude_session_mtime(path))
    v.idle_days = (now - last) / 86400 if last else 9999.0
    if v.idle_days < idle_days:
        keep.append(f"active {v.idle_days * 24:.0f}h ago (< {idle_days:g}d idle window)")

    # --- unique work
    if git(path, "status", "--porcelain")[1]:
        keep.append("uncommitted changes")
    for marker in ("rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD"):
        if (Path(gitdir) / marker).exists():
            keep.append(f"operation in progress ({marker})")
    rc, n = git(path, "rev-list", "--count", "HEAD", "--not", "--remotes")
    if rc != 0 or not n.isdigit():
        keep.append("cannot verify pushed state")
    elif int(n) > 0:
        keep.append(f"{n} commit(s) on no remote")

    # --- merge / PR state
    merged = git(path, "merge-base", "--is-ancestor", "HEAD", ctx["default"][str(repo)])[0] == 0
    states = ctx["prs"][str(repo)]
    pr = states.get(branch, set()) if states is not None else None
    if pr and "OPEN" in pr:
        keep.append("open PR")
    elif states is None and not merged:
        keep.append("PR status unknown (gh unavailable) and branch unmerged")

    if keep:
        return v
    if merged:
        v.status, v.reasons = "SAFE", ["merged into " + ctx["default"][str(repo)]]
    elif pr and pr & {"MERGED", "CLOSED"}:
        v.status, v.reasons = "SAFE", [f"PR {'/'.join(sorted(pr))}"]
    else:
        v.status, v.reasons = "REVIEW", ["pushed but unmerged, no PR record"]
    return v


def find_repos(roots: list[Path]) -> list[Path]:
    repos: list[Path] = []
    for root in roots:
        if not root.is_dir():
            continue
        for dirpath, dirnames, _ in os.walk(root):
            depth = Path(dirpath).relative_to(root).parts
            if ".git" in dirnames:  # primary checkout
                repos.append(Path(dirpath))
                dirnames[:] = [d for d in dirnames if d != ".git"]
            dirnames[:] = [
                d for d in dirnames
                if d not in {"node_modules", ".venv", ".next", "target", ".claude", ".tmp", ".git"}
            ]
            if len(depth) >= 3:
                dirnames[:] = []
    return repos


def orphans(repo: Path, registered: set[str]) -> list[Path]:
    d = repo / ".claude" / "worktrees"
    if not d.is_dir():
        return []
    return [p for p in sorted(d.iterdir()) if p.is_dir() and str(p) not in registered]


def build_ctx(repos: list[Path], use_gh: bool) -> dict:
    return {
        "cwds": live_cwds(),
        "default": {str(r): default_branch(r) for r in repos},
        "prs": {str(r): (pr_states(r) if use_gh else None) for r in repos},
    }


def scan(roots: list[Path], idle_days: float, use_gh: bool = True) -> tuple[list[Verdict], list[tuple[Path, int]]]:
    repos = [r for r in find_repos(roots) if len(registered_worktrees(r)) > 1 or (r / ".claude/worktrees").is_dir()]
    ctx = build_ctx(repos, use_gh)
    out: list[Verdict] = []
    orph: list[tuple[Path, int]] = []
    for repo in repos:
        wts = registered_worktrees(repo)
        for wt in wts:
            v = classify(repo, wt, ctx, idle_days)
            if v.status != "KEEP" or Path(v.path) != repo:
                v.size_kb = du_kb(v.path) if Path(v.path).exists() and Path(v.path) != repo else 0
            out.append(v)
        for o in orphans(repo, {wt["worktree"] for wt in wts}):
            orph.append((o, du_kb(o)))
    return out, orph


def report(verdicts: list[Verdict], orph: list[tuple[Path, int]]) -> None:
    order = {"SAFE": 0, "REVIEW": 1, "KEEP": 2}
    shown = [v for v in verdicts if v.reasons != ["primary checkout"]]
    for st in ("SAFE", "REVIEW", "KEEP"):
        rows = sorted((v for v in shown if v.status == st), key=lambda v: -v.size_kb)
        if not rows:
            continue
        total = sum(v.size_kb for v in rows)
        print(f"\n## {st}  ({len(rows)} worktrees, {human(total)})")
        for v in rows:
            print(f"{human(v.size_kb):>7}  {v.path}  [{v.branch}]")
            print(f"         {'; '.join(v.reasons)}")
    if orph:
        print(f"\n## ORPHAN DIRS  (in .claude/worktrees but not registered with git; {human(sum(k for _, k in orph))})")
        for p, kb in orph:
            print(f"{human(kb):>7}  {p}")
    print(f"\nreclaimable now: SAFE={human(sum(v.size_kb for v in shown if v.status == 'SAFE'))}"
          f"  REVIEW={human(sum(v.size_kb for v in shown if v.status == 'REVIEW'))}")


def apply(paths: list[str], roots: list[Path], idle_days: float, include_review: bool, use_gh: bool) -> int:
    verdicts, _ = scan(roots, idle_days, use_gh)
    by_path = {v.path: v for v in verdicts}
    allowed = {"SAFE", "REVIEW"} if include_review else {"SAFE"}
    rc = 0
    for raw in paths:
        p = str(Path(raw).expanduser().resolve())
        v = by_path.get(p)
        if v is None or v.reasons == ["primary checkout"]:
            print(f"SKIP  {raw}: not a known non-primary worktree"); rc = 1; continue
        if v.status not in allowed:
            print(f"SKIP  {raw}: now {v.status} ({'; '.join(v.reasons)})"); rc = 1; continue
        repo = v.repo
        if Path(p).exists():
            r, msg = git(repo, "worktree", "remove", "--force", p)
            if r != 0 and Path(p).exists():
                shutil.rmtree(p, ignore_errors=True)
        git(repo, "worktree", "prune")
        if v.branch != "(detached)":
            git(repo, "branch", "-d", v.branch)  # -d refuses unmerged branches; failure is fine
        print(f"REMOVED {p} ({human(v.size_kb)})")
    return rc


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--roots", nargs="*", help="code roots (default: CODE_ROOTS env or common dirs under ~)")
    ap.add_argument("--idle-days", type=float, default=float(os.environ.get("IDLE_DAYS", 2)))
    ap.add_argument("--no-gh", action="store_true", help="skip PR lookup (unmerged branches become KEEP)")
    ap.add_argument("--apply", nargs="+", metavar="PATH", help="remove these paths if still SAFE")
    ap.add_argument("--include-review", action="store_true", help="with --apply: also allow REVIEW")
    a = ap.parse_args()

    env_roots = os.environ.get("CODE_ROOTS", "").split()
    roots = [Path(r).expanduser() for r in (a.roots or env_roots or [str(HOME / r) for r in DEFAULT_ROOTS])]
    if a.apply:
        return apply(a.apply, roots, a.idle_days, a.include_review, not a.no_gh)
    verdicts, orph = scan(roots, a.idle_days, not a.no_gh)
    report(verdicts, orph)
    return 0


if __name__ == "__main__":
    sys.exit(main())
