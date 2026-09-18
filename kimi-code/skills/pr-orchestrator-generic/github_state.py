#!/usr/bin/env python3
"""Ship-loop durable state record (phase machine).

The worker and the orchestrator both need one canonical, machine-readable
view of "how far did the last run get, and what should the next run do".
GitHub comments are the durable store (no local DB): every phase boundary
appends a single-line state marker to the open PR — or to the issue before a
PR exists.

Marker format (one line, flat key=value, alnum+underscore values so shell
parsing stays trivial — NO spaces, NO `--` inside the HTML comment):

  <!-- ship-loop-state phase=<understand|implement|review|test_gate|ui_gate|
       qa_gate|ready> status=<ok|failed|blocked|needs_input>
       attempt=<1-based run> next=<next_phase or ready> pr=<PR number> -->

Read invariants (enforced here):
  * the LATEST marker wins — a later human comment can carry its own marker,
    but state markers are only written by the loop, so last-marker-wins is
    correct;
  * `phase=ready status=ok` is the ONLY shape the worker treats as done, and
    it must be paired with a non-draft PR by the caller;
  * `status=failed` keeps the last `next` — that is the resume point.

CLI (env REPO_MATCH=owner/repo):
  read-issue <issue>      print "k=v ..." of the latest state on the issue
  read-pr <pr>            print latest state found on the PR comments
  append-issue <issue> <k=v> [<k=v> ...]
  append-pr <pr> <k=v> [<k=v> ...]
  verify <pr> <k=v>...    exit 0 iff the PR's latest state contains EVERY
                          given key=value; exit 1 otherwise.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

_START = "<!-- ship-loop-state"
_END = "-->"
_FIELD = re.compile(r"([a-z][a-z0-9_]*)=([a-z0-9_]+)")


def _marker_fields_on_line(line: str) -> dict:
    """Pure: latest marker fields found on ONE line, else {}."""
    start = line.find(_START)
    if start == -1:
        return {}
    end = line.find(_END, start)
    if end == -1:
        return {}
    span = line[start + len(_START):end]
    return {k: v for k, v in _FIELD.findall(span)}


def extract_latest(comment_bodies) -> dict:
    """Pure: latest marker from an ordered (oldest→newest) list of bodies."""
    latest: dict = {}
    for body in comment_bodies or []:
        found: dict = {}
        for line in (body or "").splitlines():
            fields = _marker_fields_on_line(line)
            if fields:
                found = fields
        if found:
            latest = found
    return latest


def _gh(args):
    r = subprocess.run(["gh", *args], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr or r.stdout or "gh failed\n")
        sys.exit(1)
    return json.loads(r.stdout or "null")


def _repo():
    try:
        return os.environ["REPO_MATCH"]
    except KeyError:
        sys.stderr.write("github_state.py: set REPO_MATCH=owner/repo\n")
        sys.exit(2)


def _read_latest(kind, n):
    obj = "pr" if kind == "pr" else "issue"
    comments = _gh([
        obj, "view", str(n), "--repo", _repo(), "--json", "comments",
        "-q", "[.comments[]?.body]",
    ]) or []
    return extract_latest(comments)


def _append(kind, n, kv):
    labels = " ".join(f"{k}={v}" for k, v in kv.items())
    body = f"⏳ ship-loop state: {labels} (see docs/github-loop.md)\n\n" \
           f"{_START} {labels} {_END}"
    obj = "pr" if kind == "pr" else "issue"
    subprocess.run(
        ["gh", obj, "comment", str(n), "--repo", _repo(), "--body", body],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True,
    )


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd in ("read-pr", "read-issue"):
        kind = "pr" if cmd == "read-pr" else "issue"
        latest = _read_latest(kind, int(sys.argv[2]))
        if latest:
            print(" ".join(f"{k}={v}" for k, v in latest.items()))
        return

    if cmd in ("append-pr", "append-issue"):
        kind = "pr" if cmd == "append-pr" else "issue"
        kv = {}
        for raw in sys.argv[3:]:
            k, _, v = raw.partition("=")
            if k:
                kv[k] = v
        _append(kind, int(sys.argv[2]), kv)
        return

    if cmd == "verify":
        pr = int(sys.argv[2])
        latest = _read_latest("pr", pr)
        ok = True
        for raw in sys.argv[3:]:
            k, _, v = raw.partition("=")
            if latest.get(k) != v:
                ok = False
        sys.exit(0 if ok else 1)

    sys.stderr.write(__doc__)
    sys.exit(2)


if __name__ == "__main__":
    main()