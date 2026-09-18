#!/usr/bin/env python3
"""REST label heals + leftover report for the ship loop.

Extracted from loop-common.sh heredocs so the decision rules are unit-tested.

CLI (env: REPO_MATCH=owner/repo, optional READY_LABEL / TRIAGE_LABEL):
  heal-triage       promote triage:ready-to-implement orphans → +ready
                    prints "N N N" (or empty)
  heal-dep-blocks   -blocked +ready when blocked only for sibling deps
                    prints "N N N" (or empty)
  heal-unlabeled-scoped
                    scoped issues that lost every ship/park label → +ready
                    prints "N N N" (or empty)
  strip-closed-awaiting
                    remove `awaiting-merge` from closed issues
                    prints "N N N" (or empty)
  leftovers         print parked / waiting queues (never "Done" if any remain)
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

EPIC_TITLE = re.compile(r"^\s*(epic\b|\[epic\])", re.I)
SHIP_GATE = re.compile(r"(?im)^##\s*Ship gate\s*\(external\)")
EXTERNAL = re.compile(
    r"(?i)\b(places\s+budget|api\s+budget|budget\s+approved|legal\s+hold|"
    r"vendor\s+outage|human\s+approval|owner\s+decision)\b"
)
DEP_LANG = re.compile(
    r"(?i)(##\s*Depends on\b|depends on\b|do not start until\s*#\d|"
    r"blocked on #\d|parent epic:\s*#\d)"
)
# gh-scope-issue output shape — proof the issue went through the pipeline.
SCOPED_SECTION = re.compile(r"(?im)^##\s*(Depends on|Acceptance Criteria|Proposed Scope)\s*$")
# Every label that places an issue in a queue or a park. An open issue with
# none of these is invisible to scope-loop, pr-loop, and the leftover report.
SHIP_OR_PARK = {
    "ready", "agent-working", "agent-failed", "needs-input", "blocked",
    "awaiting-merge", "scoping", "tracking", "epic", "no-ai", "no-agent",
}


def is_epic_title(title: str) -> bool:
    return bool(EPIC_TITLE.search(title or ""))


def label_names(issue) -> set:
    return {l.get("name") for l in (issue.get("labels") or []) if l.get("name")}


def should_promote_triage(issue, *, ready="ready", triage="triage:ready-to-implement") -> bool:
    """True when triage:ready-to-implement sits without a ship/park label."""
    if is_epic_title(issue.get("title") or ""):
        return False
    names = label_names(issue)
    if triage not in names:
        return False
    park = {ready, "agent-working", "agent-failed", "blocked", "needs-input"}
    return not (names & park)


def should_heal_dep_block(issue, *, ready="ready") -> bool:
    """True when `blocked` is only a sibling/code-dep park (not an external gate)."""
    if is_epic_title(issue.get("title") or ""):
        return False
    names = label_names(issue)
    if "blocked" not in names:
        return False
    if names & {ready, "agent-working", "agent-failed", "needs-input"}:
        return False
    body = issue.get("body") or ""
    if SHIP_GATE.search(body) or EXTERNAL.search(body):
        return False
    return bool(DEP_LANG.search(body))


def should_heal_unlabeled_scoped(issue, *, ready="ready"):
    """True when a scoped issue lost every ship/park label.

    Happens when a run mis-parks (e.g. awaiting-merge applied to a run that
    produced no PR) and a human later removes the park label without adding a
    queue label. The scoped body shape (gh-scope-issue output) proves it went
    through the pipeline; restoring `ready` re-queues it (dependency deferral
    in ready_queue still applies). Raw unscoped ideas keep label `*(none)*`
    and stay with scope-loop.
    """
    if is_epic_title(issue.get("title") or ""):
        return False
    if label_names(issue) & SHIP_OR_PARK:
        return False
    return bool(SCOPED_SECTION.search(issue.get("body") or ""))


def _gh_json(args):
    r = subprocess.run(["gh", *args], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr or r.stdout or "gh failed\n")
        return []
    return json.loads(r.stdout or "[]")


def _gh_edit(repo, n, *args):
    subprocess.run(
        ["gh", "issue", "edit", str(n), "--repo", repo, *args],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def _gh_comment(repo, n, body):
    subprocess.run(
        ["gh", "issue", "comment", str(n), "--repo", repo, "--body", body],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def heal_triage(repo, *, ready="ready", triage="triage:ready-to-implement", apply=True):
    issues = _gh_json([
        "issue", "list", "--repo", repo, "--state", "open",
        "--label", triage, "--limit", "100",
        "--json", "number,title,labels",
    ])
    promoted = []
    for it in issues:
        if not should_promote_triage(it, ready=ready, triage=triage):
            continue
        n = it["number"]
        if apply:
            _gh_edit(repo, n, "--add-label", ready)
        promoted.append(str(n))
    return promoted


def heal_dep_blocks(repo, *, ready="ready", apply=True):
    issues = _gh_json([
        "issue", "list", "--repo", repo, "--state", "open",
        "--label", "blocked", "--limit", "100",
        "--json", "number,title,labels,body",
    ])
    promoted = []
    comment = (
        "Auto-heal: removed `blocked` (code dependency is not a park reason). "
        "Ship order lives in `## Depends on`; pr-loop topo-sorts the `ready` queue. "
        "See docs/github-loop.md — Dependencies vs park."
    )
    for it in issues:
        if not should_heal_dep_block(it, ready=ready):
            continue
        n = it["number"]
        if apply:
            _gh_edit(repo, n, "--remove-label", "blocked", "--add-label", ready)
            _gh_comment(repo, n, comment)
        promoted.append(str(n))
    return promoted


def heal_unlabeled_scoped(repo, *, ready="ready", apply=True):
    issues = _gh_json([
        "issue", "list", "--repo", repo, "--state", "open",
        "--limit", "100",
        "--json", "number,title,labels,body",
    ])
    healed = []
    for it in issues:
        if not should_heal_unlabeled_scoped(it, ready=ready):
            continue
        n = it["number"]
        if apply:
            _gh_edit(repo, n, "--add-label", ready)
        healed.append(str(n))
    return healed


def strip_closed_awaiting(repo, *, apply=True):
    """`awaiting-merge` on a closed issue is stale — the merge already landed."""
    issues = _gh_json([
        "issue", "list", "--repo", repo, "--state", "closed",
        "--label", "awaiting-merge", "--limit", "100",
        "--json", "number",
    ])
    stripped = []
    for it in issues:
        n = it["number"]
        if apply:
            _gh_edit(repo, n, "--remove-label", "awaiting-merge")
        stripped.append(str(n))
    return stripped


def leftovers(repo, *, ready="ready"):
    """Snapshot of parked / waiting work. Empty dict values omitted from print."""
    issues = _gh_json([
        "issue", "list", "--repo", repo, "--state", "open", "--limit", "100",
        "--json", "number,title,labels",
    ])
    buckets = {
        "needs-input": [],
        "blocked": [],
        "agent-failed": [],
        "agent-working": [],
        "awaiting-merge": [],
        "ready": [],
    }
    for it in issues:
        if is_epic_title(it.get("title") or ""):
            continue
        names = label_names(it)
        n = it["number"]
        title = (it.get("title") or "")[:60]
        line = f"#{n} {title}"
        for key in ("needs-input", "blocked", "agent-failed", "agent-working", "awaiting-merge"):
            if key in names:
                buckets[key].append(line)
        if ready in names and not (
            names & {"agent-working", "agent-failed", "blocked", "needs-input", "awaiting-merge"}
        ):
            buckets["ready"].append(line)
    return buckets


def format_leftovers(buckets):
    lines = ["Leftovers (not Done while any of these remain):"]
    any_left = False
    for key in ("needs-input", "blocked", "agent-failed", "agent-working", "awaiting-merge", "ready"):
        items = buckets.get(key) or []
        if not items:
            continue
        any_left = True
        lines.append(f"  {key} ({len(items)}):")
        for item in items:
            lines.append(f"    {item}")
    if not any_left:
        return "Leftovers: none — queues empty."
    if buckets.get("awaiting-merge"):
        lines.append("  land stacked: gh stack merge <top-pr> --yes --squash")
    if buckets.get("needs-input"):
        lines.append("  drain questions: answer on the issue, then -needs-input +ready")
    if buckets.get("agent-failed"):
        lines.append("  retry (manual restart): gh issue edit N --remove-label agent-failed --add-label ready")
        lines.append("  note: agent-failed WITH a draft PR auto-resumes on the next pr-loop run")
    return "\n".join(lines)


def main():
    repo = os.environ.get("REPO_MATCH") or os.environ.get("REPO")
    if not repo:
        sys.stderr.write("labels.py: set REPO_MATCH=owner/repo\n")
        sys.exit(2)
    ready = os.environ.get("READY_LABEL", "ready")
    triage = os.environ.get("TRIAGE_LABEL", "triage:ready-to-implement")
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""

    if cmd == "heal-triage":
        print(" ".join(heal_triage(repo, ready=ready, triage=triage)))
        return
    if cmd == "heal-dep-blocks":
        print(" ".join(heal_dep_blocks(repo, ready=ready)))
        return
    if cmd == "heal-unlabeled-scoped":
        print(" ".join(heal_unlabeled_scoped(repo, ready=ready)))
        return
    if cmd == "strip-closed-awaiting":
        print(" ".join(strip_closed_awaiting(repo)))
        return
    if cmd == "leftovers":
        print(format_leftovers(leftovers(repo, ready=ready)))
        return
    sys.stderr.write(__doc__)
    sys.exit(2)


if __name__ == "__main__":
    main()
