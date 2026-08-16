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


if __name__ == "__main__":
    unittest.main()
