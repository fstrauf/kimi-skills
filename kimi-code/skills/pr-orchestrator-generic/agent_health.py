#!/usr/bin/env python3
"""agent_health.py — detect agent-CLI quota / rate-limit exhaustion in loop logs.

One home for the exhaustion signatures so scope-loop and pr-loop react the
same way. A non-zero agent exit plus one of these signatures in the log
*tail* means the agent backend is done for this run — every further ticket
would fail identically, so the loop aborts (exit 44) instead of grinding
through the rest of the queue.

CLI:
  agent_health.py quota-check <logfile>
    exit 0 + print the matched line  → exhaustion signature found
    exit 1                           → no signature (ordinary failure)
"""

from __future__ import annotations

import re
import sys

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


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] != "quota-check":
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


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
