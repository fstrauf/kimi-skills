#!/usr/bin/env python3
"""Unit tests for labels.py heal rules + leftover formatting.

Run:  python3 tests/test_labels.py   (from the skill dir, stdlib only)
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import labels  # noqa: E402


def issue(n, title="Do the thing", label_list=(), body=""):
    return {
        "number": n,
        "title": title,
        "labels": [{"name": x} for x in label_list],
        "body": body,
    }


class PromoteTriageTest(unittest.TestCase):
    def test_orphan_promoted(self):
        self.assertTrue(labels.should_promote_triage(
            issue(1, label_list=("triage:ready-to-implement", "bug"))
        ))

    def test_already_ready_skipped(self):
        self.assertFalse(labels.should_promote_triage(
            issue(1, label_list=("triage:ready-to-implement", "ready"))
        ))

    def test_parked_skipped(self):
        self.assertFalse(labels.should_promote_triage(
            issue(1, label_list=("triage:ready-to-implement", "needs-input"))
        ))
        self.assertFalse(labels.should_promote_triage(
            issue(1, label_list=("triage:ready-to-implement", "blocked"))
        ))

    def test_epic_skipped(self):
        self.assertFalse(labels.should_promote_triage(
            issue(1, title="Epic: tracking", label_list=("triage:ready-to-implement",))
        ))


class HealDepBlockTest(unittest.TestCase):
    def test_sibling_dep_healed(self):
        body = "## Depends on\n- #110 — schema first\n"
        self.assertTrue(labels.should_heal_dep_block(
            issue(2, label_list=("blocked",), body=body)
        ))

    def test_external_gate_kept(self):
        body = "## Ship gate (external)\n- [ ] budget approved\n## Depends on\n- #110\n"
        self.assertFalse(labels.should_heal_dep_block(
            issue(2, label_list=("blocked",), body=body)
        ))

    def test_legal_language_kept(self):
        self.assertFalse(labels.should_heal_dep_block(
            issue(2, label_list=("blocked",), body="legal hold until counsel replies")
        ))

    def test_no_dep_language_kept(self):
        self.assertFalse(labels.should_heal_dep_block(
            issue(2, label_list=("blocked",), body="waiting on vendor")
        ))

    def test_needs_input_not_healed(self):
        self.assertFalse(labels.should_heal_dep_block(
            issue(2, label_list=("blocked", "needs-input"), body="## Depends on\n- #1\n")
        ))


class LeftoversFormatTest(unittest.TestCase):
    def test_empty(self):
        text = labels.format_leftovers({k: [] for k in (
            "needs-input", "blocked", "agent-failed", "agent-working",
            "awaiting-merge", "ready",
        )})
        self.assertIn("none", text)

    def test_awaiting_merge_prints_land_hint(self):
        text = labels.format_leftovers({
            "needs-input": [],
            "blocked": [],
            "agent-failed": [],
            "agent-working": [],
            "awaiting-merge": ["#12 stack layer"],
            "ready": [],
        })
        self.assertIn("awaiting-merge", text)
        self.assertIn("gh stack merge", text)
        self.assertIn("not Done", text)


class HealUnlabeledScopedTest(unittest.TestCase):
    scoped_body = (
        "## Proposed Scope\n\nDo the thing.\n\n"
        "## Depends on\n- #110 — schema first\n\n"
        "## Acceptance Criteria\n\n- [ ] done\n"
    )

    def test_scoped_orphan_healed(self):
        self.assertTrue(labels.should_heal_unlabeled_scoped(
            issue(3, label_list=("enhancement", "priority/P1"), body=self.scoped_body)
        ))

    def test_raw_idea_skipped(self):
        # Never scoped — no scoped sections — stays with scope-loop.
        self.assertFalse(labels.should_heal_unlabeled_scoped(
            issue(3, label_list=("enhancement",), body="Would be nice to have …")
        ))

    def test_every_queue_or_park_label_skipped(self):
        for park in (
            "ready", "agent-working", "agent-failed", "needs-input",
            "blocked", "awaiting-merge", "scoping", "tracking",
            "no-ai", "no-agent",
        ):
            self.assertFalse(
                labels.should_heal_unlabeled_scoped(
                    issue(3, label_list=("enhancement", park), body=self.scoped_body)
                ),
                park,
            )

    def test_epic_skipped(self):
        self.assertFalse(labels.should_heal_unlabeled_scoped(
            issue(3, title="[EPIC] thing", label_list=("enhancement",), body=self.scoped_body)
        ))

    def test_dep_section_alone_is_scoped(self):
        body = "## Depends on\n- #110\n"
        self.assertTrue(labels.should_heal_unlabeled_scoped(
            issue(3, label_list=("bug",), body=body)
        ))


class StripClosedAwaitingTest(unittest.TestCase):
    def test_strips_label(self):
        calls = []

        def fake_edit(repo, n, *args):
            calls.append((n, args))

        orig = labels._gh_edit
        orig_json = labels._gh_json
        labels._gh_edit = fake_edit
        labels._gh_json = lambda *a: [{"number": 7}, {"number": 8}]
        try:
            self.assertEqual(labels.strip_closed_awaiting("o/r"), ["7", "8"])
        finally:
            labels._gh_edit = orig
            labels._gh_json = orig_json
        self.assertEqual(calls, [(7, ("--remove-label", "awaiting-merge")),
                                 (8, ("--remove-label", "awaiting-merge"))])

    def test_dry_run_does_not_edit(self):
        calls = []

        def fake_edit(repo, n, *args):
            calls.append((n, args))

        orig = labels._gh_edit
        orig_json = labels._gh_json
        labels._gh_edit = fake_edit
        labels._gh_json = lambda *a: [{"number": 7}]
        try:
            self.assertEqual(labels.strip_closed_awaiting("o/r", apply=False), ["7"])
        finally:
            labels._gh_edit = orig
            labels._gh_json = orig_json
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
