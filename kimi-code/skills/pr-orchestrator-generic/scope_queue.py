#!/usr/bin/env python3
"""Scope-loop queue selection (extracted from scope-all.sh).

Picks open non-epic issues that still need a first scope pass.

Skip (already past "needs scope", or owned by pr-loop):
  labels: ready, agent-working, agent-failed, blocked, needs-input, awaiting-merge
  titles: Epic: / [Epic]
  open PR that closes the issue (same matching as pr_chain.issue_pr_index)

`awaiting-merge` is required: pr-loop parks a shipped-but-unmerged issue by
stripping `ready` and adding that label. Without this skip, the next
scope-loop re-grooms tickets that already have an open PR.

Env interface for the bash caller:
  REPO_MATCH     owner/repo
  READY_LABEL    queue label (default: ready)
  SCOPING_LABEL  legacy enqueue label (default: scoping)
  REQUIRE_LABEL  1 → only issues labeled SCOPING_LABEL
"""

import json
import os
import re
import subprocess
import sys

import pr_chain

EPIC_TITLE = re.compile(r"^\s*(epic\b|\[epic\])", re.I)


def skip_labels(ready_label="ready"):
    return {
        ready_label,
        "agent-working",
        "agent-failed",
        "blocked",
        "needs-input",
        "awaiting-merge",
    }


def select_scope_issue_numbers(issues, open_prs, *, ready_label="ready"):
    """Return issue numbers that still need scoping, in list order."""
    skip = skip_labels(ready_label)
    with_pr = set(pr_chain.issue_pr_index(open_prs or []))
    out = []
    for it in issues:
        title = it.get("title") or ""
        if EPIC_TITLE.search(title):
            continue
        names = {l.get("name") for l in (it.get("labels") or []) if l.get("name")}
        if names & skip:
            continue
        n = it["number"]
        if n in with_pr:
            continue
        out.append(n)
    return out


def _gh_json(args):
    r = subprocess.run(["gh", *args], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr or r.stdout or "gh failed\n")
        sys.exit(0)
    return json.loads(r.stdout or "[]")


def main():
    repo = os.environ["REPO_MATCH"]
    ready = os.environ.get("READY_LABEL", "ready")
    scoping = os.environ.get("SCOPING_LABEL", "scoping")
    require = os.environ.get("REQUIRE_LABEL", "0").strip() in (
        "1", "true", "TRUE", "yes", "YES",
    )

    issue_cmd = [
        "issue", "list",
        "--repo", repo,
        "--state", "open",
        "--limit", "100",
        "--json", "number,title,labels",
    ]
    if require:
        issue_cmd.extend(["--label", scoping])

    issues = _gh_json(issue_cmd)
    open_prs = _gh_json([
        "pr", "list",
        "--repo", repo,
        "--state", "open",
        "--limit", "200",
        "--json", "number,headRefName,body,title",
    ])
    nums = select_scope_issue_numbers(issues, open_prs, ready_label=ready)
    print(" ".join(str(n) for n in nums))


if __name__ == "__main__":
    main()
