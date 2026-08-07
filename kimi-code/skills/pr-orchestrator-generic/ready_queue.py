#!/usr/bin/env python3
"""Eligible-queue computation for pr-loop (extracted from loop-common.sh).

Reads open issues carrying the ready label, filters skips, parses
"## Depends on" relationships, and prints the pick order.

Env interface (unchanged from the loop-common.sh heredoc):
  REPO_MATCH   owner/repo
  READY_LABEL  queue label (default: ready)
  MODE         "pick" (print next issue number) | "list" (print full queue)
             | "base" (print the branch issue ISSUE_N must build on)
  ISSUE_N      issue number for MODE=base

Fixes vs the old inline version:
  * parse_depends_on: a "## Depends on" section whose first line declares
    none ("None", "_None_", "_None_ — independent of #123") yields NO deps.
    The old `\bnone\b` check never matched "_None_" (underscore is a regex
    word character), so companion/context #N mentions became real deps and
    parked issues. The section is also excluded from the prose regex scans
    so it is never double-parsed.
  * dep_status: MERGED (a dep referencing a pull request) counts as
    satisfied, and unresolvable refs (neither issue nor PR) no longer defer
    an issue forever — they are treated as satisfied with a stderr note.

Stack-through mode:
  * dep_status "pr_open": a dep whose issue is still OPEN but already has an
    open PR closing it (or carries the `awaiting-merge` label) is SATISFIED —
    the dependent builds on that PR's branch instead of waiting for a merge.
    This is what lets pr-loop drain a whole dependency chain without a human
    merge between steps.
  * MODE=base resolves which branch the next issue must fork from: the head
    branch of the topmost open-PR dep, else the repo default branch.
"""

import json
import os
import re
import subprocess
import sys
from collections import defaultdict

import pr_chain  # canonical open-PR graph (issue↔PR matching lives there)

# Set by main() from REPO_MATCH; tests may set it directly.
repo = ""

LABEL_PRIORITIES = ("priority/P0", "priority/P1", "priority/P2", "priority/P3")
SKIP = {"blocked", "agent-failed", "agent-working", "tracking", "epic", "no-ai", "no-agent", "awaiting-merge"}
state_cache = {}
_pr_index = None  # {issue_n: {"pr": int, "head": str}} — built once per run


def gh_json(args):
    r = subprocess.run(
        ["gh", *args],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        sys.stderr.write(r.stderr or r.stdout or "gh failed\n")
        sys.exit(1)
    return json.loads(r.stdout or "null")


def _section_declares_none(section: str) -> bool:
    """True when the Depends-on section's first line declares 'no deps'.

    Accepts markdown decoration: None, _None_, *None*, "— none —", and
    trailing prose ("_None_ — independent of #123"). `\bnone\b` cannot be
    used here: "_" is a word character, so it never matches "_None_".
    """
    first = next((ln.strip() for ln in section.splitlines() if ln.strip()), "")
    return bool(re.match(r"(?i)^[*_\-—–\s]*none(?:[\s*_\-—–.:]|$)", first))


def parse_depends_on(body, self_n):
    if not body:
        return set()
    deps = set()
    rest = body
    m = re.search(r"(?ims)^##\s*Depends on\s*\n(.*?)(?=^##\s|\Z)", body)
    if m:
        section = m.group(1)
        if not _section_declares_none(section):
            deps.update(int(x) for x in re.findall(r"#(\d+)", section))
        # The section is authoritatively handled above — never let the prose
        # scans below re-parse it (that is where phantom deps came from).
        rest = body[: m.start()] + body[m.end():]
    for mm in re.finditer(r"(?im)^(?!.*parent\s+epic).*depends on[:\s]+([^\n]+)", rest):
        deps.update(int(x) for x in re.findall(r"#(\d+)", mm.group(1)))
    for mm in re.finditer(
        r"(?i)(?:do not start|blocked|until|after(?:\s+merging)?)\s[^\n]{0,80}",
        rest,
    ):
        deps.update(int(x) for x in re.findall(r"#(\d+)", mm.group(0)))
    deps.discard(self_n)
    return deps


def issue_meta(n):
    if n in state_cache:
        return state_cache[n]
    try:
        data = gh_json([
            "issue", "view", str(n), "--repo", repo,
            "--json", "number,state,labels,title",
        ])
    except SystemExit:
        data = {"number": n, "state": "UNKNOWN", "labels": [], "title": ""}
    state_cache[n] = data or {}
    return state_cache[n]


def open_pr_index():
    """Map issue number -> {"pr", "head"} for open PRs that close it.

    Fetch goes through this module's gh_json (test-fakeable); the matching
    rules are pr_chain.issue_pr_index — the single canonical implementation.
    Tests may seed `_pr_index` directly.
    """
    global _pr_index
    if _pr_index is not None:
        return _pr_index
    try:
        prs = gh_json([
            "pr", "list", "--repo", repo, "--state", "open", "--limit", "200",
            "--json", "number,headRefName,body,title",
        ])
    except SystemExit:
        prs = []
    _pr_index = pr_chain.issue_pr_index(prs or [])
    return _pr_index


def dep_status(dep):
    meta = issue_meta(dep)
    st = (meta.get("state") or "").upper()
    # CLOSED issue or MERGED pull request (gh resolves PR numbers with state
    # MERGED) — the dependency has landed.
    if st in ("CLOSED", "MERGED"):
        return "ok"
    if st == "OPEN":
        title = (meta.get("title") or "")
        if re.match(r"(?i)^\s*(epic\b|\[epic\])", title):
            return "ok"
        labs = {l["name"] for l in (meta.get("labels") or [])}
        if "ready" in labs or "agent-working" in labs:
            return "wait_ready"
        # Work done, merge pending: an open PR closes this dep (or the loop
        # parked it with `awaiting-merge`). Dependents stack onto the PR's
        # branch instead of waiting for a human merge.
        if "awaiting-merge" in labs or dep in open_pr_index():
            return "pr_open"
        return "wait_other"
    # Unresolvable ref (not an issue or PR — typo, deleted, or transferred).
    # Never park the dependent forever: treat as satisfied, but say so.
    sys.stderr.write(
        f"note: dep #{dep} of {repo} is unresolvable (not an issue/PR); "
        "treating as satisfied\n"
    )
    return "ok"


def compute_queue(ready_label):
    issues = gh_json([
        "issue", "list", "--repo", repo, "--state", "open",
        "--label", ready_label, "--limit", "100",
        "--json", "number,labels,title,body",
    ])

    candidates = []
    for issue in issues:
        n = issue["number"]
        labels = {l["name"] for l in (issue.get("labels") or [])}
        if labels & SKIP:
            continue
        title = (issue.get("title") or "").strip()
        if re.match(r"(?i)^\s*(epic\b|\[epic\])", title):
            continue
        prs = gh_json([
            "pr", "list", "--repo", repo, "--state", "open",
            "--search", f"Closes #{n} in:body", "--json", "number",
        ])
        if prs:
            continue
        rank = next((i for i, p in enumerate(LABEL_PRIORITIES) if p in labels), 99)
        rank_label = {0: "P0", 1: "P1", 2: "P2", 3: "P3"}.get(rank, "no-priority")
        deps = parse_depends_on(issue.get("body") or "", n)
        candidates.append({
            "n": n, "rank": rank, "rank_label": rank_label,
            "title": title[:60], "deps": deps,
        })

    ready_nums = {c["n"] for c in candidates}

    pickable = []
    deferred = []
    for c in candidates:
        blocking = []
        statuses = {}
        for d in sorted(c["deps"]):
            s = dep_status(d)
            statuses[d] = s
            if s in ("ok", "pr_open"):
                continue
            if s == "wait_ready" and d in ready_nums:
                continue
            if s == "wait_ready":
                blocking.append(f"#{d}(in-flight)")
                continue
            blocking.append(f"#{d}({s})")
        c["dep_statuses"] = statuses
        if blocking:
            c["block_reason"] = ",".join(blocking)
            deferred.append(c)
        else:
            pickable.append(c)

    pickable_nums = {c["n"] for c in pickable}
    by_n = {c["n"]: c for c in pickable}
    indeg = {c["n"]: 0 for c in pickable}
    edges = defaultdict(list)
    for c in pickable:
        for d in c["deps"]:
            if d in pickable_nums:
                edges[d].append(c["n"])
                indeg[c["n"]] += 1

    ready_q = [c["n"] for c in pickable if indeg[c["n"]] == 0]
    ready_q.sort(key=lambda n: (by_n[n]["rank"], n))
    ordered = []
    while ready_q:
        n = ready_q.pop(0)
        ordered.append(by_n[n])
        for m in sorted(edges[n], key=lambda x: (by_n[x]["rank"], x)):
            indeg[m] -= 1
            if indeg[m] == 0:
                ready_q.append(m)
                ready_q.sort(key=lambda x: (by_n[x]["rank"], x))

    if len(ordered) < len(pickable):
        seen = {c["n"] for c in ordered}
        rest = [c for c in pickable if c["n"] not in seen]
        rest.sort(key=lambda c: (c["rank"], c["n"]))
        ordered.extend(rest)

    return ordered, deferred


def default_branch():
    r = subprocess.run(
        ["gh", "repo", "view", repo, "--json", "defaultBranchRef",
         "-q", ".defaultBranchRef.name"],
        capture_output=True, text=True,
    )
    return r.stdout.strip() or "main"


def _issue_body(n):
    try:
        data = gh_json(["issue", "view", str(n), "--repo", repo, "--json", "body"])
    except SystemExit:
        return ""
    return (data or {}).get("body") or ""


def base_branch_for_issue(n):
    """Branch issue N must fork from: the head of its topmost open-PR dep.

    With several open-PR deps, the topmost is the one no other candidate
    depends on (its branch transitively contains the others). Falls back to
    the highest issue number, then to the repo default branch when no dep
    has an open PR.
    """
    deps = parse_depends_on(_issue_body(n), n)
    idx = open_pr_index()
    cands = [d for d in deps if d in idx and dep_status(d) == "pr_open"]
    if not cands:
        return default_branch()
    if len(cands) == 1:
        return idx[cands[0]]["head"]
    dep_sets = {d: parse_depends_on(_issue_body(d), d) for d in cands}
    tops = [d for d in cands if not any(d in dep_sets[o] for o in cands if o != d)]
    pick = max(tops) if tops else max(cands)
    return idx[pick]["head"]


def main():
    global repo
    repo = os.environ["REPO_MATCH"]
    ready_label = os.environ.get("READY_LABEL", "ready")
    mode = os.environ.get("MODE", "pick")

    if mode == "base":
        print(base_branch_for_issue(int(os.environ["ISSUE_N"])))
        return

    ordered, deferred = compute_queue(ready_label)

    if mode == "pick":
        if ordered:
            print(ordered[0]["n"])
    else:
        for c in ordered:
            dep_s = ""
            if c["deps"]:
                parts = []
                for d in sorted(c["deps"]):
                    mark = "(pr-open)" if c.get("dep_statuses", {}).get(d) == "pr_open" else ""
                    parts.append(f"#{d}{mark}")
                dep_s = " deps=[" + ",".join(parts) + "]"
            print(f"#{c['n']} ({c['rank_label']}){dep_s} {c['title']}")
        for c in deferred:
            print(
                f"#{c['n']} ({c['rank_label']}) DEFERRED[{c.get('block_reason','')}] {c['title']}"
            )


if __name__ == "__main__":
    main()
