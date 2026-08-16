#!/usr/bin/env python3
"""Canonical open-PR chain graph for pr-loop.

One place that loads the open-PR set and answers every chain question the
loop asks. Replaces the four inline python heredocs that used to re-derive
this in loop-common.sh (each with its own branch-parsing quirks).

Pure functions take the PR list + default branch and are unit-testable;
main() is the thin IO layer the bash wrappers call.

CLI (env: REPO_MATCH=owner/repo):
  for-issue <N>    print "<pr>\\t<url>\\t<isDraft>" for the open PR closing
                   issue N (explicit Closes #N in body/title wins over the
                   feature/<N>- branch convention); empty output when none
  already-landed <N>  exit 0 when a closed PR closed N and no open PR remains
  closes-from-text    stdin → space-separated issue numbers (Closes / branch)
  in-stack <PR>    exit 0 when PR has an open parent and/or child PR
  chain-up-to <PR> print PR numbers space-separated, stack bottom .. PR;
                   empty + exit 1 when PR unknown
  stale-bases      print open PR numbers whose base is not the default branch
                   and is not the head of any open PR (parent merged/closed)
"""

import json
import os
import re
import subprocess
import sys

# --- Pure graph logic (no IO) ------------------------------------------------

_CLOSE_RE = re.compile(r"(?i)(?:closes|fixes|resolves)\s+#(\d+)")
_BRANCH_RE = re.compile(r"(?i)(?:^|/)(?:feature|fix|chore|issue)[/-](\d+)(?:[-/]|$)")


def issues_closed_by(pr):
    """Issue numbers an open PR claims to close (body/title keywords + branch)."""
    blob = f"{pr.get('body') or ''}\n{pr.get('title') or ''}"
    nums = {int(x) for x in _CLOSE_RE.findall(blob)}
    m = _BRANCH_RE.search(pr.get("headRefName") or "")
    if m:
        nums.add(int(m.group(1)))
    return nums


def issue_pr_index(prs):
    """issue number -> {"pr": int, "head": str} for every open PR."""
    idx = {}
    for pr in prs:
        for n in issues_closed_by(pr):
            idx.setdefault(n, {"pr": pr["number"], "head": pr.get("headRefName") or ""})
    return idx


# Same matching as the old land-trailer heredoc (body + title + headRefName blob).
_TEXT_BRANCH_RE = re.compile(r"(?i)(?:feature|fix|chore|issue)[/-](\d+)(?:[-/]|$)")


def issues_referenced_in(text):
    """Issue numbers referenced by Closes/Fixes/Resolves or feature/N- branch text."""
    nums = {int(x) for x in _CLOSE_RE.findall(text or "")}
    for m in _TEXT_BRANCH_RE.finditer(text or ""):
        nums.add(int(m.group(1)))
    return nums


def is_already_landed(issue_n, open_prs, closed_prs):
    """True when a closed PR closed the issue and no open PR still targets it."""
    if pr_for_issue(open_prs, issue_n):
        return False
    return pr_for_issue(closed_prs, issue_n) is not None


def pr_for_issue(prs, n):
    """The open PR closing issue N, two-pass: explicit close keywords in
    body/title first, then branch-name / bare-#N-in-title convention."""
    pat_close = re.compile(rf"(?i)(?:closes|fixes|resolves)\s+#0*{re.escape(str(n))}\b")
    pat_branch = re.compile(rf"(?i)(?:^|/)(?:feature|fix|chore|issue)[/-]0*{re.escape(str(n))}(?:[-/]|$)")
    for prefer_body in (True, False):
        for pr in prs:
            body = pr.get("body") or ""
            title = pr.get("title") or ""
            head = pr.get("headRefName") or ""
            if prefer_body:
                if pat_close.search(body) or pat_close.search(title):
                    return pr
            else:
                if pat_branch.search(head) or re.search(rf"(?i)\b#0*{re.escape(str(n))}\b", title):
                    return pr
    return None


class ChainGraph:
    """Parent/child navigation over the open-PR set for one default branch."""

    def __init__(self, prs, default):
        self.default = default
        self.by_num = {p["number"]: p for p in prs}
        self.by_head = {p["headRefName"]: p for p in prs if p.get("headRefName")}

    def has_parent(self, pr):
        base = pr.get("baseRefName") or ""
        return bool(base and base != self.default and base in self.by_head)

    def has_child(self, pr):
        head = pr.get("headRefName") or ""
        return any(
            (p.get("baseRefName") or "") == head
            for p in self.by_num.values()
            if p["number"] != pr["number"]
        )

    def in_stack(self, pr_n):
        pr = self.by_num.get(pr_n)
        return bool(pr) and (self.has_parent(pr) or self.has_child(pr))

    def chain_up_to(self, pr_n):
        """PR numbers from stack bottom up to and including pr_n ([] if unknown)."""
        cur = self.by_num.get(pr_n)
        if not cur:
            return []
        chain = []
        seen = set()
        while cur and cur["number"] not in seen:
            seen.add(cur["number"])
            chain.append(cur["number"])
            base = cur.get("baseRefName") or ""
            if not base or base == self.default:
                break
            cur = self.by_head.get(base)
        chain.reverse()
        return chain

    def stale_based(self):
        """Open PRs whose base branch is no longer owned by an open PR head
        (the parent PR merged or closed) — these need a restack."""
        return [
            p["number"]
            for p in self.by_num.values()
            if (p.get("baseRefName") or "")
            and p["baseRefName"] != self.default
            and p["baseRefName"] not in self.by_head
        ]


# --- IO layer ----------------------------------------------------------------


def gh_json(args):
    r = subprocess.run(["gh", *args], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr or r.stdout or "gh failed\n")
        sys.exit(1)
    return json.loads(r.stdout or "null")


def load_open_prs(repo):
    return gh_json([
        "pr", "list", "--repo", repo, "--state", "open", "--limit", "200",
        "--json", "number,url,isDraft,headRefName,baseRefName,body,title",
    ]) or []


def load_closed_prs(repo, limit=40):
    return gh_json([
        "pr", "list", "--repo", repo, "--state", "closed", "--limit", str(limit),
        "--json", "number,url,isDraft,headRefName,baseRefName,body,title,mergedAt",
    ]) or []


def default_branch(repo):
    r = subprocess.run(
        ["gh", "repo", "view", repo, "--json", "defaultBranchRef",
         "-q", ".defaultBranchRef.name"],
        capture_output=True, text=True,
    )
    return r.stdout.strip() or "main"


def main():
    repo = os.environ["REPO_MATCH"]
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    prs = load_open_prs(repo)

    if cmd == "for-issue":
        pr = pr_for_issue(prs, int(sys.argv[2]))
        if pr:
            print(f"{pr['number']}\t{pr['url']}\t{str(pr.get('isDraft')).lower()}")
        return
    if cmd == "already-landed":
        n = int(sys.argv[2])
        closed = load_closed_prs(repo)
        sys.exit(0 if is_already_landed(n, prs, closed) else 1)
    if cmd == "closes-from-text":
        nums = sorted(issues_referenced_in(sys.stdin.read()))
        print(" ".join(str(n) for n in nums))
        return

    graph = ChainGraph(prs, default_branch(repo))

    if cmd == "in-stack":
        sys.exit(0 if graph.in_stack(int(sys.argv[2])) else 1)
    if cmd == "chain-up-to":
        chain = graph.chain_up_to(int(sys.argv[2]))
        if not chain:
            sys.exit(1)
        print(" ".join(str(n) for n in chain))
        return
    if cmd == "stale-bases":
        for n in graph.stale_based():
            print(n)
        return
    sys.stderr.write(__doc__)
    sys.exit(2)


if __name__ == "__main__":
    main()
