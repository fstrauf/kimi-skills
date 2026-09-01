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
"""

from __future__ import annotations

import os
import re
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

    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
