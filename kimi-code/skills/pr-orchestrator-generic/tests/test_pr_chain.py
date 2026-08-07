#!/usr/bin/env python3
"""Unit tests for pr_chain.py (canonical open-PR graph for pr-loop).

Run:  python3 tests/test_pr_chain.py   (from the skill dir, stdlib only)
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import pr_chain  # noqa: E402

DEFAULT = "master"

# A small stack: 10 (→ master) ← 11 ← 12, plus a sibling 13 (→ feature/10),
# a lone PR 20 (→ master), and a stale PR 30 whose parent branch is gone.
PRS = [
    {"number": 10, "url": "u10", "isDraft": False,
     "headRefName": "feature/10-base", "baseRefName": "master",
     "body": "Closes #10", "title": "base layer"},
    {"number": 11, "url": "u11", "isDraft": False,
     "headRefName": "feature/11-mid", "baseRefName": "feature/10-base",
     "body": "Closes #11", "title": "mid layer"},
    {"number": 12, "url": "u12", "isDraft": True,
     "headRefName": "feature/12-top", "baseRefName": "feature/11-mid",
     "body": "", "title": "top layer"},  # no Closes — branch-name match only
    {"number": 13, "url": "u13", "isDraft": False,
     "headRefName": "feature/13-sibling", "baseRefName": "feature/10-base",
     "body": "", "title": "sibling of 11"},
    {"number": 20, "url": "u20", "isDraft": False,
     "headRefName": "fix/20-lone", "baseRefName": "master",
     "body": "", "title": "Fix the thing (#20)"},
    {"number": 30, "url": "u30", "isDraft": False,
     "headRefName": "feature/30-orphan", "baseRefName": "feature/9-gone",
     "body": "Closes #30", "title": "parent merged"},
]


class IssueMatchingTest(unittest.TestCase):
    def test_issues_closed_by_body_and_branch(self):
        idx = pr_chain.issue_pr_index(PRS)
        self.assertEqual(idx[10]["pr"], 10)
        self.assertEqual(idx[12]["pr"], 12)   # branch-name only
        self.assertEqual(idx[20]["pr"], 20)   # fix/ branch + (#20) title

    def test_pr_for_issue_prefers_explicit_close_over_branch(self):
        # Issue 11: PR 11 closes it explicitly; a hypothetical PR whose branch
        # merely mentions 11 must not win over the body match.
        impostor = dict(PRS[1], number=99, headRefName="feature/11-impostor",
                        body="", title="")
        pr = pr_chain.pr_for_issue(PRS + [impostor], 11)
        self.assertEqual(pr["number"], 11)

    def test_pr_for_issue_branch_fallback(self):
        pr = pr_chain.pr_for_issue(PRS, 12)
        self.assertEqual(pr["number"], 12)

    def test_pr_for_issue_none(self):
        self.assertIsNone(pr_chain.pr_for_issue(PRS, 999))


class ChainGraphTest(unittest.TestCase):
    def setUp(self):
        self.g = pr_chain.ChainGraph(PRS, DEFAULT)

    def test_in_stack_parent_and_child(self):
        self.assertTrue(self.g.in_stack(10))   # has children
        self.assertTrue(self.g.in_stack(11))   # parent + child
        self.assertTrue(self.g.in_stack(12))   # has parent
        self.assertTrue(self.g.in_stack(13))   # sibling still counts (parent)
        self.assertFalse(self.g.in_stack(20))  # lone PR → not stacked
        self.assertFalse(self.g.in_stack(999))

    def test_chain_up_to(self):
        self.assertEqual(self.g.chain_up_to(12), [10, 11, 12])
        self.assertEqual(self.g.chain_up_to(10), [10])
        self.assertEqual(self.g.chain_up_to(13), [10, 13])
        self.assertEqual(self.g.chain_up_to(20), [20])
        self.assertEqual(self.g.chain_up_to(999), [])

    def test_stale_based(self):
        # 30's base (feature/9-gone) is no open PR's head → stale.
        # 11/12/13 base onto live open heads → fine. 10/20 target master → fine.
        self.assertEqual(self.g.stale_based(), [30])


if __name__ == "__main__":
    unittest.main(verbosity=2)
