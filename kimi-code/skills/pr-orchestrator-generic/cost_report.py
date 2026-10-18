#!/usr/bin/env python3
"""cost_report.py — loop spend visibility: what each run routed and what it cost.

Reads the JSONL audit log that routing.py appends to ($ORCH_COST_LOG, default
~/.orch-cost/routes.jsonl) and, where the host exposes one, the real usage
store:

  claude  ~/.claude/projects/<cwd-slug>/*.jsonl  → USD by model (message.costUSD)
  kimi    ~/.kimi-code/sessions/**/wire.jsonl    → tokens (usage fields; no USD)
  grok/ori                                      → no on-disk usage store (n/a)

CLI:
  cost_report.py usage --host H --since EPOCH [--cwd DIR] [--log PATH] [--append]
      print one JSON line of spend since EPOCH; --append also writes it to the log
  cost_report.py report [--log PATH] [--issue N] [--profile P] [--days N]
      per-issue route/spend summary + under-routing observations
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

DEFAULT_LOG = Path.home() / ".orch-cost" / "routes.jsonl"


def _fmt_tokens(n: float) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}k"
    return str(int(n))


def _claude_slug(cwd: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "-", cwd)


def _iter_jsonl(path: Path, needle: str):
    """Yield parsed objects from lines containing `needle`. Tolerates junk lines."""
    try:
        with path.open(errors="replace") as fh:
            for line in fh:
                if needle not in line:
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue
    except OSError:
        return


def _mtime_at_least(path: Path, since: float) -> bool:
    try:
        return path.stat().st_mtime >= since
    except OSError:
        return False


def claude_usage(since: float, cwd: str = "", projects_root: Path | None = None) -> dict:
    """Sum costUSD by model from Claude transcripts touched since `since`.

    Claude writes cumulative `cost-state` snapshots (totalCostUSD + per-model
    modelUsage); the last snapshot in a file is that session's total. Older
    formats put costUSD on individual entries — fall back to summing those.
    """
    root = projects_root or Path.home() / ".claude" / "projects"
    dirs = [root / _claude_slug(cwd)] if cwd else sorted(root.glob("*"))
    by_model: dict[str, float] = defaultdict(float)
    files = 0
    for d in dirs:
        if not d.is_dir():
            continue
        for f in sorted(d.glob("*.jsonl")):
            if not _mtime_at_least(f, since):
                continue
            files += 1
            last_state: dict = {}
            legacy: dict[str, float] = defaultdict(float)
            for entry in _iter_jsonl(f, '"costUSD"'):
                msg = entry.get("message") or {}
                if entry.get("totalCostUSD") is not None or entry.get("type") == "cost-state":
                    last_state = entry
                    continue
                cost = entry.get("costUSD", msg.get("costUSD"))
                model = msg.get("model") or entry.get("model") or "unknown"
                if isinstance(cost, (int, float)):
                    legacy[model] += cost
            if last_state:
                usage = last_state.get("modelUsage") or {}
                for model, vals in usage.items():
                    cost = vals.get("costUSD") if isinstance(vals, dict) else None
                    if isinstance(cost, (int, float)):
                        by_model[model] += cost
                total = last_state.get("totalCostUSD")
                if not usage and isinstance(total, (int, float)):
                    by_model["unknown"] += total
            else:
                for model, cost in legacy.items():
                    by_model[model] += cost
    return {"available": True, "files": files, "by_model": dict(by_model),
            "cost_usd": round(sum(by_model.values()), 4)}


def kimi_usage(since: float, sessions_root: Path | None = None) -> dict:
    """Sum usage token fields from kimi wire.jsonl files touched since `since`."""
    root = sessions_root or Path.home() / ".kimi-code" / "sessions"
    tokens: dict[str, float] = defaultdict(float)
    files = 0
    if root.is_dir():
        for f in sorted(root.rglob("wire.jsonl")):
            if not _mtime_at_least(f, since):
                continue
            files += 1
            for entry in _iter_jsonl(f, '"usage"'):
                usage = entry.get("usage")
                if not isinstance(usage, dict):
                    continue
                for key, val in usage.items():
                    if isinstance(val, (int, float)):
                        tokens[key] += val
    return {"available": True, "files": files, "tokens": dict(tokens)}


def collect_usage(host: str, since: float, cwd: str = "",
                  projects_root: Path | None = None, sessions_root: Path | None = None) -> dict:
    host = (host or "").lower()
    if host == "claude":
        return claude_usage(since, cwd, projects_root)
    if host == "kimi":
        return kimi_usage(since, sessions_root)
    return {"available": False, "reason": f"no on-disk usage store for host {host!r}"}


def usage_line(u: dict) -> str:
    """One-line, human-readable spend summary (for PR comments)."""
    if not u.get("available"):
        return f"n/a ({u.get('reason', 'unavailable')})"
    if "cost_usd" in u:
        if not u["by_model"]:
            return "$0.00 (claude: no transcripts in window)"
        parts = ", ".join(f"{m} ${v:.2f}" for m, v in sorted(u["by_model"].items()))
        return f"${u['cost_usd']:.2f} (claude: {parts})"
    t = u.get("tokens", {})
    if not t:
        return "0 tokens (kimi: no wire files in window)"
    inn = t.get("input", 0) + t.get("inputOther", 0)
    return (f"{_fmt_tokens(inn)} in / {_fmt_tokens(t.get('output', 0))} out / "
            f"{_fmt_tokens(t.get('inputCacheRead', 0))} cache-read (kimi tokens)")


def append_log(line: dict, log_path: Path) -> None:
    """Append one JSONL line to the audit log (same fail-open contract as routing.py)."""
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("a") as fh:
            fh.write(json.dumps(line) + "\n")
    except OSError:
        pass


def read_log(log_path: Path) -> list[dict]:
    if not log_path.is_file():
        return []
    out = []
    with log_path.open(errors="replace") as fh:
        for line in fh:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(entry, dict):
                out.append(entry)
    return out


def _in_window(entry: dict, days: int) -> bool:
    ts = entry.get("ts", "")
    try:
        when = datetime.fromisoformat(ts)
    except ValueError:
        return False
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return when >= datetime.now(timezone.utc) - timedelta(days=days)


def build_report(entries: list[dict], issue: str = "", profile: str = "", days: int = 30) -> list[str]:
    routes = [e for e in entries if e.get("cmd") in ("route", "cli-args")
              and _in_window(e, days)
              and (not issue or e.get("issue") == issue)
              and (not profile or e.get("profile") == profile)]
    usages = [e for e in entries if e.get("cmd") == "usage"
              and _in_window(e, days)
              and (not issue or e.get("issue") == issue)
              and (not profile or e.get("profile") == profile)]

    issues: dict[str, list[dict]] = defaultdict(list)
    for e in routes:
        issues[e.get("issue") or f"(no issue · {e.get('profile', '?')})"].append(e)

    lines: list[str] = []
    escalated_roles: Counter[str] = Counter()
    total_cost: dict[str, float] = defaultdict(float)
    total_tokens: dict[str, float] = defaultdict(float)

    for key in sorted(issues):
        group = issues[key]
        meta = group[0]
        lines.append(f"Issue {key} ({meta.get('profile', '?')}, {meta.get('host', '?')}) — {meta.get('ts', '?')[:10]}")
        by_role: dict[str, Counter] = defaultdict(Counter)
        for e in group:
            role = e.get("role", "?")
            by_role[role][f"{e.get('tier', '?')}/{e.get('effort', '?')}"] += 1
            if e.get("attempt", 1) >= 2 or (e.get("role") in ("implement", "fix", "review") and e.get("review_iter", 0) >= 3):
                escalated_roles[role] += 1
        summary = " · ".join(
            f"{role} {' '.join(f'{k} ×{v}' for k, v in counts.items())}"
            for role, counts in sorted(by_role.items())
        )
        lines.append(f"  routes: {summary}")
        esc = sorted({r for r in by_role if escalated_roles.get(r)})
        if esc:
            lines.append(f"  ⚠ escalated: {', '.join(esc)} (attempt ≥2 or late review — base tier may be too cheap)")
        for u in usages:
            if (u.get("issue") or f"(no issue · {u.get('profile', '?')})") != key:
                continue
            lines.append(f"  spend: {usage_line(u)}")
            if u.get("cost_usd"):
                total_cost[u.get("host", "?")] += u["cost_usd"]
            for k, v in (u.get("tokens") or {}).items():
                total_tokens[k] += v
        lines.append("")

    if total_cost or total_tokens:
        parts = [f"{h} ${v:.2f}" for h, v in sorted(total_cost.items())]
        if total_tokens:
            inn = total_tokens.get("input", 0) + total_tokens.get("inputOther", 0)
            parts.append(f"kimi {_fmt_tokens(inn)} in / {_fmt_tokens(total_tokens.get('output', 0))} out")
        lines.append(f"TOTAL ({days}d): {' · '.join(parts)}")
    if escalated_roles:
        lines.append("Observations:")
        for role, n in escalated_roles.most_common():
            lines.append(f"  - {role} escalated on {n} run(s) → consider ORCH_ROUTE_{role.upper()} or a higher base tier for that size")
    if not lines:
        lines.append(f"No cost-log entries in the last {days} days ({DEFAULT_LOG}).")
    return lines


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="cost_report.py", description="Loop spend visibility")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_usage = sub.add_parser("usage")
    p_usage.add_argument("--host", default=os.environ.get("ORCH_HOST", ""))
    p_usage.add_argument("--since", type=float, required=True, help="epoch seconds")
    p_usage.add_argument("--cwd", default=os.environ.get("REPO_DIR", os.getcwd()))
    p_usage.add_argument("--log", default=os.environ.get("ORCH_COST_LOG", str(DEFAULT_LOG)))
    p_usage.add_argument("--append", action="store_true", help="also write the line to the audit log")

    p_report = sub.add_parser("report")
    p_report.add_argument("--log", default=os.environ.get("ORCH_COST_LOG", str(DEFAULT_LOG)))
    p_report.add_argument("--issue", default="")
    p_report.add_argument("--profile", default="")
    p_report.add_argument("--days", type=int, default=30)

    args = parser.parse_args(argv[1:])
    log_path = Path(args.log)

    if args.cmd == "usage":
        u = collect_usage(args.host, args.since, args.cwd)
        u.update({
            "cmd": "usage",
            "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "host": (args.host or "").lower(),
            "profile": os.environ.get("ORCH_PROFILE", ""),
            "issue": os.environ.get("ORCH_STATE_ISSUE_N") or os.environ.get("ORCH_ISSUE", ""),
        })
        if args.append:
            append_log(u, log_path)
        print(json.dumps(u))
        return 0

    print("\n".join(build_report(read_log(log_path), args.issue, args.profile, args.days)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
