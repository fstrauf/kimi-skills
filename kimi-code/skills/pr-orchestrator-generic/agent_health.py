#!/usr/bin/env python3
"""agent_health.py — detect agent-CLI sickness in loop logs.

One home for the health signatures so scope-loop and pr-loop react the
same way.

1. Quota / rate-limit exhaustion:
   A non-zero agent exit plus one of these signatures in the log *tail* means
   the agent backend is done for this run — every further ticket would fail
   identically, so the loop aborts (exit 44) instead of grinding through the
   rest of the queue.

2. Wedged-but-alive agent (stale log):
   The agent CLI is expected to exit when its run finishes. When it does not
   (e.g. it spawned child servers — dev stack, Playwright MCP — that hold its
   stdout pipes open), the log stops growing while the process stays alive.
   Without a watchdog the pr-loop worker would print "running NNNm" forever.
   The worker polls the log's mtime; a log untouched for N minutes with a live
   process is a wedged agent.

CLI:
  agent_health.py quota-check <logfile>
    exit 0 + print the matched line  → exhaustion signature found
    exit 1                           → no signature (ordinary failure)

  agent_health.py stale-check <logfile> <stale-minutes>
    exit 0                           → log older than stale-minutes (wedged)
    exit 1                           → log fresh, or missing / unreadable

  agent_health.py tree-busy <pid> <statefile>
    exit 0                           → pid's process tree burned CPU since the
                                       last sample (working, not wedged)
    exit 1                           → tree idle, or pid gone

Tree-busy complements stale-check: a frozen log with a live process is only a
wedge when the tree is also idle. Long silent phases (delegated implementer
subagents, cold `cargo test` / `pnpm` builds in a fresh worktree) freeze the
log for 15+ minutes while burning CPU — killing them loses finished work.
The state file carries the previous CPU sample between worker heartbeats.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import time

# Case-insensitive signatures of a dead agent backend (quota / credits /
# hard rate limit). Anchored to phrases CLIs actually print — never bare
# numbers like "429" — so issue text quoted into the log is unlikely to
# false-positive. Only the log tail is scanned on top of that (see below).
QUOTA_PATTERNS = [
    r"usage limit",  # grok: "You've reached your free Grok Build usage limit"
    r"quota (exceeded|exhausted)",
    r"out of (quota|credits)",
    r"insufficient (credits|balance|quota|funds)",
    r"rate ?limit (exceeded|reached)",
    r"too many requests",
    r"payment required",
    r"billing (error|issue|required)",
]

# Exhaustion kills the CLI, so the error sits at the end of the log. Scanning
# only the tail keeps a ticket that merely *quotes* quota text mid-run (e.g.
# an issue body about API quotas) from tripping the detector.
TAIL_LINES = 40


def detect_quota_error(text: str) -> str | None:
    """Return the first tail line matching an exhaustion signature, else None."""
    for line in text.splitlines()[-TAIL_LINES:]:
        for pat in QUOTA_PATTERNS:
            if re.search(pat, line, re.IGNORECASE):
                return line.strip()
    return None


def log_is_stale(log_path: str, stale_minutes: int, now: float | None = None) -> bool:
    """True when the agent log has not been modified for >= stale_minutes.

    A missing/unreadable log is never "stale" — the agent may simply not have
    started writing yet (empty or just-created file). The worker only consults
    this after the process has been alive for a while, so an empty log that
    *stays* empty eventually counts as stale once its mtime ages past the
    threshold.
    """
    try:
        mtime = os.path.getmtime(log_path)
    except OSError:
        return False
    if now is None:
        now = time.time()
    return (now - mtime) >= stale_minutes * 60


def _parse_ps_time(value: str) -> float:
    """Parse ps TIME ([[dd-]hh:]mm:ss[.hs]) into seconds.

    Linux prints HH:MM:SS; macOS prints MM:SS.hs (hundredths). The fraction
    is dropped — heartbeat deltas are minutes, not hundredths.
    """
    value = value.split(".", 1)[0]
    days = 0
    if "-" in value:
        day_part, value = value.split("-", 1)
        days = int(day_part)
    parts = [int(p) for p in value.split(":")]
    if len(parts) == 2:
        hours, minutes, seconds = 0, parts[0], parts[1]
    else:
        hours, minutes, seconds = parts[-3], parts[-2], parts[-1]
    return days * 86400 + hours * 3600 + minutes * 60 + seconds


def parse_ps_table(text: str) -> dict[int, tuple[int, float]]:
    """Parse `ps -Ao pid=,ppid=,time=` output into {pid: (ppid, cpu_seconds)}."""
    table: dict[int, tuple[int, float]] = {}
    for line in text.splitlines():
        fields = line.split()
        if len(fields) != 3:
            continue
        try:
            pid, ppid = int(fields[0]), int(fields[1])
            table[pid] = (ppid, _parse_ps_time(fields[2]))
        except ValueError:
            continue
    return table


def tree_cpu_seconds(table: dict[int, tuple[int, float]], root_pid: int) -> float | None:
    """Total CPU seconds of root_pid and all its descendants.

    None when root_pid is absent from the table (process already gone).
    """
    if root_pid not in table:
        return None
    children: dict[int, list[int]] = {}
    for pid, (ppid, _) in table.items():
        children.setdefault(ppid, []).append(pid)
    total = 0.0
    stack = [root_pid]
    while stack:
        pid = stack.pop()
        total += table[pid][1]
        stack.extend(children.get(pid, ()))
    return total


def tree_is_busy(state_path: str, current_total: float) -> bool:
    """Compare current CPU total against the stored sample; store the new one.

    The first sample (no readable state) counts as busy — the worker re-checks
    one heartbeat later against a real baseline, so a wedged tree is granted
    at most one extra heartbeat before the kill.
    """
    previous: float | None = None
    try:
        with open(state_path) as fh:
            previous = float(fh.read().strip())
    except (OSError, ValueError):
        previous = None
    try:
        with open(state_path, "w") as fh:
            fh.write(f"{current_total}\n")
    except OSError:
        # No state -> no future baseline; report honestly for this sample.
        return previous is not None and current_total > previous
    if previous is None:
        return True
    return current_total > previous


def _tree_busy_cli(pid_text: str, state_path: str) -> int:
    try:
        root_pid = int(pid_text)
    except ValueError:
        return 1
    try:
        out = subprocess.run(
            ["ps", "-Ao", "pid=,ppid=,time="],
            capture_output=True, text=True, check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return 1
    total = tree_cpu_seconds(parse_ps_table(out), root_pid)
    if total is None:
        return 1
    return 0 if tree_is_busy(state_path, total) else 1


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2

    if argv[1] == "quota-check":
        if len(argv) != 3:
            print(__doc__, file=sys.stderr)
            return 2
        try:
            with open(argv[2], errors="replace") as fh:
                text = fh.read()
        except OSError:
            return 1
        hit = detect_quota_error(text)
        if hit is None:
            return 1
        print(hit)
        return 0

    if argv[1] == "stale-check":
        if len(argv) != 4:
            print(__doc__, file=sys.stderr)
            return 2
        try:
            minutes = float(argv[3])
        except ValueError:
            print(__doc__, file=sys.stderr)
            return 2
        return 0 if log_is_stale(argv[2], minutes) else 1

    if argv[1] == "tree-busy":
        if len(argv) != 4:
            print(__doc__, file=sys.stderr)
            return 2
        return _tree_busy_cli(argv[2], argv[3])

    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
