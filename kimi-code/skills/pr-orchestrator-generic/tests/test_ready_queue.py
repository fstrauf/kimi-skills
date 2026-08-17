#!/usr/bin/env python3
"""Regression tests for ready_queue.py (pr-loop eligible-queue logic).

Covers the two bugs that parked ready issues:
  1. "_None_" Depends-on sections manufacturing phantom deps (\\bnone\\b
     never matched the markdown-italic form).
  2. dep_status deferring forever on MERGED-PR or unresolvable dep refs.

Run:  python3 tests/test_ready_queue.py   (from the skill dir, stdlib only)
"""

import io
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import ready_queue  # noqa: E402


class ParseDependsOnTest(unittest.TestCase):
    def parse(self, body, self_n=999):
        return ready_queue.parse_depends_on(body, self_n)

    def test_plain_none_section(self):
        self.assertEqual(self.parse("## Depends on\n\nNone\n"), set())

    def test_italic_none_section(self):
        # The original bug: \bnone\b never matched "_None_".
        self.assertEqual(self.parse("## Depends on\n\n_None_\n"), set())

    def test_italic_none_with_trailing_prose(self):
        body = "## Depends on\n\n_None_ — independent of #1204 (other fix). Ship either order.\n"
        self.assertEqual(self.parse(body), set())

    def test_italic_none_with_companion_list(self):
        body = (
            "## Depends on\n\n_None_\n\n"
            "Companion (independent, do not block):\n"
            "- #1204 — option marks\n"
            "- #1205 — cron observability\n"
        )
        self.assertEqual(self.parse(body), set())

    def test_real_section_deps(self):
        body = "## Depends on\n\n- #110 — geo columns (land first)\n- #111\n"
        self.assertEqual(self.parse(body), {110, 111})

    def test_prose_depends_on_outside_section(self):
        body = "Some context.\n\nDepends on: #110 — geo columns\n"
        self.assertEqual(self.parse(body), {110})

    def test_prose_blocked_until(self):
        body = "## Notes\n\nDo not start until #210 lands.\n"
        self.assertEqual(self.parse(body), {210})

    def test_none_section_does_not_shield_real_prose_deps(self):
        body = (
            "## Depends on\n\n_None_\n\n"
            "## Notes\n\nBlocked until #211 merges.\n"
        )
        self.assertEqual(self.parse(body), {211})

    def test_self_reference_discarded(self):
        body = "## Depends on\n\n- #999\n- #110\n"
        self.assertEqual(self.parse(body, self_n=999), {110})

    def test_casual_after_hash_is_not_a_dep(self):
        body = "Cash is always missing after #275 strip.\n"
        self.assertEqual(self.parse(body), set())

    def test_until_in_table_is_not_a_dep(self):
        body = (
            "## Depends on\n\n- #269 — scaffold (open as PR #281)\n\n"
            "## Non-goals\n\nVue views stay until #279.\n"
        )
        self.assertEqual(self.parse(body), {269})

    def test_do_not_list_epic_in_section_is_not_a_dep(self):
        body = "## Depends on\n\n- #269\n\nDo not list #268 (epic).\n"
        self.assertEqual(self.parse(body), {269})

    def test_empty_body(self):
        self.assertEqual(self.parse(""), set())


class DepStatusTest(unittest.TestCase):
    def setUp(self):
        ready_queue.repo = "o/r"
        ready_queue.state_cache.clear()

    def seed(self, n, state, labels=(), title=""):
        ready_queue.state_cache[n] = {
            "number": n,
            "state": state,
            "labels": [{"name": l} for l in labels],
            "title": title,
        }

    def test_closed_issue_ok(self):
        self.seed(1, "CLOSED")
        self.assertEqual(ready_queue.dep_status(1), "ok")

    def test_merged_pr_ok(self):
        # gh resolves PR numbers via issue view with state MERGED.
        self.seed(2, "MERGED")
        self.assertEqual(ready_queue.dep_status(2), "ok")

    def test_open_ready_waits(self):
        self.seed(3, "OPEN", labels=("ready",))
        self.assertEqual(ready_queue.dep_status(3), "wait_ready")

    def test_open_unlabeled_waits_other(self):
        self.seed(4, "OPEN")
        self.assertEqual(ready_queue.dep_status(4), "wait_other")

    def test_open_epic_ok(self):
        self.seed(5, "OPEN", title="Epic: tracking")
        self.assertEqual(ready_queue.dep_status(5), "ok")

    def test_unresolvable_ok_with_note(self):
        self.seed(6, "UNKNOWN")
        err = io.StringIO()
        old = sys.stderr
        sys.stderr = err
        try:
            status = ready_queue.dep_status(6)
        finally:
            sys.stderr = old
        self.assertEqual(status, "ok")
        self.assertIn("unresolvable", err.getvalue())

    def test_open_with_open_pr_is_pr_open(self):
        self.seed(7, "OPEN")
        ready_queue._pr_index = {7: {"pr": 70, "head": "feature/7-x"}}
        try:
            self.assertEqual(ready_queue.dep_status(7), "pr_open")
        finally:
            ready_queue._pr_index = None

    def test_open_awaiting_merge_label_is_pr_open(self):
        self.seed(8, "OPEN", labels=("awaiting-merge",))
        ready_queue._pr_index = {}
        try:
            self.assertEqual(ready_queue.dep_status(8), "pr_open")
        finally:
            ready_queue._pr_index = None


class BaseBranchTest(unittest.TestCase):
    def setUp(self):
        ready_queue.repo = "o/r"
        ready_queue.state_cache.clear()
        ready_queue._pr_index = None
        ready_queue._pr_list = None
        ready_queue._stacks = []
        self._orig_default = ready_queue.default_branch
        ready_queue.default_branch = lambda: "master"

    def tearDown(self):
        ready_queue.default_branch = self._orig_default
        ready_queue._pr_index = None
        ready_queue._pr_list = None
        ready_queue._stacks = None

    def seed(self, n, state="OPEN", labels=()):
        ready_queue.state_cache[n] = {
            "number": n, "state": state,
            "labels": [{"name": l} for l in labels], "title": "",
        }
        if not hasattr(self, "_bodies"):
            self._bodies = {}
        if getattr(self, "_patched", False):
            return
        self._patched = True
        orig = ready_queue.gh_json
        bodies = self._bodies

        def fake(args):
            if args[:2] == ["issue", "view"] and "body" in args:
                return {"body": bodies.get(int(args[2]), "")}
            if args[:2] == ["pr", "list"]:
                return []
            return orig(args)

        ready_queue.gh_json = fake
        self.addCleanup(setattr, ready_queue, "gh_json", orig)

    def test_no_open_pr_deps_falls_back_to_default(self):
        self._bodies = {10: "## Depends on\n\n- #7\n"}
        self.seed(7, "CLOSED")
        self.assertEqual(ready_queue.base_branch_for_issue(10), "master")

    def test_single_open_pr_dep_gives_its_head(self):
        self._bodies = {10: "## Depends on\n\n- #7\n"}
        self.seed(7, "OPEN", labels=("awaiting-merge",))
        ready_queue._pr_index = {7: {"pr": 70, "head": "feature/7-scrape"}}
        self.assertEqual(ready_queue.base_branch_for_issue(10), "feature/7-scrape")

    def test_multi_dep_picks_topmost(self):
        # #9 depends on #8, so #9's branch already contains #8's work.
        self._bodies = {
            10: "## Depends on\n\n- #8\n- #9\n",
            8: "",
            9: "## Depends on\n\n- #8\n",
        }
        self.seed(8, "OPEN", labels=("awaiting-merge",))
        self.seed(9, "OPEN", labels=("awaiting-merge",))
        ready_queue._pr_index = {
            8: {"pr": 80, "head": "feature/8-api"},
            9: {"pr": 90, "head": "feature/9-compare"},
        }
        self.assertEqual(ready_queue.base_branch_for_issue(10), "feature/9-compare")

    def test_native_stack_top_beats_immediate_parent_head(self):
        # #272 depends on #269. #269's PR 281 already has stacked child 283.
        # New work must fork from 283's head, not 281's (that would be a sibling).
        self._bodies = {272: "## Depends on\n\n- #269\n"}
        self.seed(269, "OPEN", labels=("awaiting-merge",))
        ready_queue._pr_index = {269: {"pr": 281, "head": "feature/269-scaffold"}}
        ready_queue._pr_list = [
            {"number": 281, "headRefName": "feature/269-scaffold",
             "baseRefName": "master", "body": "Closes #269", "title": "PR1"},
            {"number": 283, "headRefName": "feature/275-blog",
             "baseRefName": "feature/269-scaffold", "body": "Closes #275", "title": "PR5"},
        ]
        ready_queue._stacks = [{
            "number": 284, "open": True,
            "pull_requests": [
                {"number": 281, "state": "open"},
                {"number": 283, "state": "open"},
            ],
        }]
        self.assertEqual(ready_queue.base_branch_for_issue(272), "feature/275-blog")

    def test_ready_dep_without_pr_is_not_a_base(self):
        # Dep still in the ready queue (no PR yet) — not a base candidate.
        self._bodies = {10: "## Depends on\n\n- #7\n"}
        self.seed(7, "OPEN", labels=("ready",))
        ready_queue._pr_index = {}
        self.assertEqual(ready_queue.base_branch_for_issue(10), "master")


class ComputeQueueOrderTest(unittest.TestCase):
    def setUp(self):
        ready_queue.repo = "o/r"
        ready_queue.state_cache.clear()

    def test_phantom_dep_regression_end_to_end(self):
        """#1205-shaped body (italic none + #1204 mention) must stay pickable."""
        issues = [
            {
                "number": 1205,
                "title": "Cron observability",
                "labels": [{"name": "priority/P1"}],
                "body": (
                    "## Depends on\n\n_None_ — independent of #1204 "
                    "(open-marks fix). Ship either order.\n"
                ),
            },
        ]
        ready_queue.state_cache[1204] = {
            "number": 1204, "state": "OPEN", "labels": [], "title": "marks",
        }
        orig = ready_queue.gh_json

        def fake(args):
            if args[:2] == ["issue", "list"]:
                return issues
            if args[:2] == ["pr", "list"]:
                return []
            raise AssertionError(args)

        ready_queue.gh_json = fake
        try:
            ordered, deferred = ready_queue.compute_queue("ready")
        finally:
            ready_queue.gh_json = orig
        self.assertEqual([c["n"] for c in ordered], [1205])
        self.assertEqual(deferred, [])

    def test_dep_with_open_pr_does_not_defer(self):
        """Dependent of an awaiting-merge issue stays pickable (stack-through)."""
        issues = [
            {
                "number": 120,
                "title": "Nav section",
                "labels": [{"name": "ready"}, {"name": "priority/P1"}],
                "body": "## Depends on\n\n- #118\n",
            },
        ]
        ready_queue.state_cache[118] = {
            "number": 118, "state": "OPEN",
            "labels": [{"name": "awaiting-merge"}], "title": "scrape",
        }
        ready_queue._pr_index = {118: {"pr": 128, "head": "feature/118-scrape"}}
        orig = ready_queue.gh_json

        def fake(args):
            if args[:2] == ["issue", "list"]:
                return issues
            if args[:2] == ["pr", "list"]:
                return []
            raise AssertionError(args)

        ready_queue.gh_json = fake
        try:
            ordered, deferred = ready_queue.compute_queue("ready")
        finally:
            ready_queue.gh_json = orig
            ready_queue._pr_index = None
        self.assertEqual([c["n"] for c in ordered], [120])
        self.assertEqual(deferred, [])
        self.assertEqual(ordered[0]["dep_statuses"], {118: "pr_open"})

    def test_pr_body_mention_does_not_skip_other_issue(self):
        """PR that Closes #275 and mentions #272 must not park #272."""
        issues = [
            {
                "number": 272,
                "title": "SEO helper",
                "labels": [{"name": "ready"}, {"name": "priority/P2"}],
                "body": "## Depends on\n\n- #269\n",
            },
        ]
        ready_queue.state_cache[269] = {
            "number": 269, "state": "OPEN",
            "labels": [{"name": "awaiting-merge"}], "title": "scaffold",
        }
        ready_queue._pr_index = None
        orig = ready_queue.gh_json

        def fake(args):
            if args[:2] == ["issue", "list"]:
                return issues
            if args[:2] == ["pr", "list"]:
                return [{
                    "number": 283,
                    "title": "blog",
                    "headRefName": "feature/275-blog",
                    "body": (
                        "Closes #275\n\nBecause #272 is not on this stack "
                        "layer, this PR adds a minimal head helper.\n"
                    ),
                }]
            raise AssertionError(args)

        ready_queue.gh_json = fake
        try:
            ordered, deferred = ready_queue.compute_queue("ready")
        finally:
            ready_queue.gh_json = orig
            ready_queue._pr_index = None
        self.assertEqual([c["n"] for c in ordered], [272])
        self.assertEqual(deferred, [])

    def test_stack_continuation_beats_unrelated_same_priority(self):
        """Drain an open stack before starting an unrelated P2."""
        issues = [
            {
                "number": 285,
                "title": "Unrelated backend",
                "labels": [{"name": "ready"}, {"name": "priority/P2"}],
                "body": "## Depends on\n\n_None_\n",
            },
            {
                "number": 272,
                "title": "SEO helper",
                "labels": [{"name": "ready"}, {"name": "priority/P2"}],
                "body": "## Depends on\n\n- #269\n",
            },
        ]
        ready_queue.state_cache[269] = {
            "number": 269, "state": "OPEN",
            "labels": [{"name": "awaiting-merge"}], "title": "scaffold",
        }
        ready_queue._pr_index = {269: {"pr": 281, "head": "feature/269-x"}}
        orig = ready_queue.gh_json

        def fake(args):
            if args[:2] == ["issue", "list"]:
                return issues
            if args[:2] == ["pr", "list"]:
                return []
            raise AssertionError(args)

        ready_queue.gh_json = fake
        try:
            ordered, deferred = ready_queue.compute_queue("ready")
        finally:
            ready_queue.gh_json = orig
            ready_queue._pr_index = None
        self.assertEqual([c["n"] for c in ordered], [272, 285])
        self.assertEqual(deferred, [])

    def test_dependent_of_deferred_ready_is_also_deferred(self):
        """#276 must not ship while #274 is ready-but-waiting on #273 in-flight."""
        issues = [
            {
                "number": 274,
                "title": "PR4 packs",
                "labels": [{"name": "ready"}, {"name": "priority/P2"}],
                "body": "## Depends on\n\n- #273\n",
            },
            {
                "number": 276,
                "title": "PR6 chrome",
                "labels": [{"name": "ready"}, {"name": "priority/P2"}],
                "body": "## Depends on\n\n- #274\n",
            },
        ]
        ready_queue.state_cache[273] = {
            "number": 273, "state": "OPEN",
            "labels": [{"name": "agent-working"}], "title": "PR3",
        }
        ready_queue.state_cache[274] = {
            "number": 274, "state": "OPEN",
            "labels": [{"name": "ready"}], "title": "PR4",
        }
        ready_queue._pr_index = {}
        orig = ready_queue.gh_json

        def fake(args):
            if args[:2] == ["issue", "list"]:
                return issues
            if args[:2] == ["pr", "list"]:
                return []
            raise AssertionError(args)

        ready_queue.gh_json = fake
        try:
            ordered, deferred = ready_queue.compute_queue("ready")
        finally:
            ready_queue.gh_json = orig
            ready_queue._pr_index = None
        self.assertEqual(ordered, [])
        deferred_n = {c["n"] for c in deferred}
        self.assertEqual(deferred_n, {274, 276})
        reasons = {c["n"]: c["block_reason"] for c in deferred}
        self.assertIn("273", reasons[274])
        self.assertIn("274(deferred)", reasons[276])


if __name__ == "__main__":
    unittest.main(verbosity=2)
