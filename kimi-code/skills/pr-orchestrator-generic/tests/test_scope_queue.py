#!/usr/bin/env python3
"""Regression tests for scope_queue.py (scope-loop pick filter).

Covers the bug where pr-loop parks a ticket as awaiting-merge (and
strips ready), then the next scope-loop re-grooms it because that
label was not a skip — including tickets that already have an open PR.

Run:  python3 tests/test_scope_queue.py   (from the skill dir, stdlib only)
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import scope_queue  # noqa: E402


def issue(n, title="Do the thing", labels=()):
    return {
        "number": n,
        "title": title,
        "labels": [{"name": name} for name in labels],
    }


def pr(number, *, body="", title="", head=""):
    return {
        "number": number,
        "body": body,
        "title": title,
        "headRefName": head,
    }


class SelectScopeQueueTest(unittest.TestCase):
    def pick(self, issues, open_prs=(), ready_label="ready"):
        return scope_queue.select_scope_issue_numbers(
            issues, list(open_prs), ready_label=ready_label,
        )

    def test_plain_open_issue_is_queued(self):
        self.assertEqual(self.pick([issue(10, labels=("enhancement", "priority/P2"))]), [10])

    def test_ready_skipped(self):
        self.assertEqual(self.pick([issue(10, labels=("ready",))]), [])

    def test_awaiting_merge_skipped_even_without_ready(self):
        # pr-loop strips ready when it parks. This is the re-scope footgun.
        self.assertEqual(
            self.pick([issue(1320, labels=("bug", "priority/P2", "awaiting-merge"))]),
            [],
        )

    def test_open_pr_closes_keyword_skipped(self):
        issues = [issue(1320, labels=("bug",))]
        prs = [pr(1323, body="Closes #1320\n\n## Summary", head="feature/1320-pnl")]
        self.assertEqual(self.pick(issues, prs), [])

    def test_open_pr_branch_name_skipped(self):
        issues = [issue(12, labels=("enhancement",))]
        prs = [pr(99, body="", title="top layer", head="feature/12-top")]
        self.assertEqual(self.pick(issues, prs), [])

    def test_unrelated_open_pr_does_not_skip(self):
        issues = [issue(50, labels=("bug",))]
        prs = [pr(99, body="Closes #49", head="feature/49-other")]
        self.assertEqual(self.pick(issues, prs), [50])

    def test_epic_title_skipped(self):
        self.assertEqual(self.pick([issue(1, title="Epic: tracking")]), [])
        self.assertEqual(self.pick([issue(2, title="[Epic] also")]), [])

    def test_needs_input_and_blocked_skipped(self):
        self.assertEqual(self.pick([issue(3, labels=("needs-input",))]), [])
        self.assertEqual(self.pick([issue(4, labels=("blocked",))]), [])

    def test_agent_labels_skipped(self):
        self.assertEqual(self.pick([issue(5, labels=("agent-working",))]), [])
        self.assertEqual(self.pick([issue(6, labels=("agent-failed",))]), [])

    def test_preserves_list_order(self):
        issues = [
            issue(1325, labels=("enhancement",)),
            issue(1320, labels=("awaiting-merge",)),
            issue(10, labels=("bug",)),
        ]
        prs = [pr(11, body="Fixes #10")]
        self.assertEqual(self.pick(issues, prs), [1325])

    def test_custom_ready_label(self):
        self.assertEqual(
            self.pick([issue(7, labels=("ship",))], ready_label="ship"),
            [],
        )
        self.assertEqual(
            self.pick([issue(8, labels=("ready",))], ready_label="ship"),
            [8],
        )


if __name__ == "__main__":
    unittest.main()
