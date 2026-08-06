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

    def test_after_keyword_prose(self):
        # Documents regex-3 behavior: "after #N" prose counts as a dep.
        body = "Cash is always missing after #275 strip.\n"
        self.assertEqual(self.parse(body), {275})

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
