#!/usr/bin/env python3
"""Unit tests for routing.py (cost routing: tier + effort per loop role)."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import routing  # noqa: E402

SCOPED_BODY = """\
## Problem
Size: L is mentioned here but is not the estimate.

## Estimate
Size: S — two files, no schema change.

## Ship gate (external)
"""


class ParseSizeTest(unittest.TestCase):
    def test_estimate_section_wins(self):
        self.assertEqual(routing.parse_size(SCOPED_BODY), "S")

    def test_bold_bullet_form(self):
        self.assertEqual(routing.parse_size("## Estimate\n- **Size:** l\n"), "L")

    def test_missing_defaults_to_m(self):
        self.assertEqual(routing.parse_size("## Estimate\n~2h\n"), "M")
        self.assertEqual(routing.parse_size(""), "M")


class RouteTest(unittest.TestCase):
    def r(self, role, size="M", attempt=1, review_iter=0, host="claude", **env):
        return routing.route(role, host, size, attempt, review_iter, env=env)

    def test_table_lookup(self):
        r = self.r("implement", "S")
        self.assertEqual((r.tier, r.effort, r.model, r.agent), ("mid", "medium", "sonnet", "loop-implementer"))
        self.assertEqual(self.r("coordinate").model, "sonnet")

    def test_only_scope_uses_strong_by_default(self):
        for role in routing.TABLE:
            for size in routing.SIZES:
                expected = "strong" if role == "scope" else None
                if expected:
                    self.assertEqual(self.r(role, size).model, "opus", (role, size))
                else:
                    self.assertNotEqual(self.r(role, size).tier, "strong", (role, size))

    def test_haiku_only_for_triage(self):
        for role in routing.TABLE:
            self.assertEqual(self.r(role).model == "haiku", role == "triage", role)

    def test_attempt_two_steps_up_once(self):
        r = self.r("fix", "S", attempt=2)
        self.assertEqual((r.tier, r.effort), ("mid", "high"))
        r = self.r("review", "M", attempt=2)
        self.assertEqual((r.tier, r.effort), ("mid", "high"))

    def test_attempt_three_or_late_l_review_reaches_strong(self):
        self.assertEqual(self.r("implement", "S", attempt=3).model, "opus")
        self.assertEqual(self.r("review", "L", review_iter=3).model, "opus")
        self.assertEqual(self.r("review", "M", review_iter=3).model, "sonnet")

    def test_non_escalating_roles_stay_put(self):
        self.assertEqual(self.r("triage", attempt=5).tier, "cheap")

    def test_max_tier_ceiling(self):
        self.assertEqual(self.r("implement", attempt=3, ORCH_MAX_TIER="mid").model, "sonnet")

    def test_role_override_pins_route(self):
        r = self.r("implement", attempt=3, ORCH_ROUTE_IMPLEMENT="cheap:low")
        self.assertEqual((r.tier, r.effort), ("cheap", "low"))

    def test_invalid_override_and_size_fall_back(self):
        r = self.r("implement", "XL", ORCH_ROUTE_IMPLEMENT="huge")
        self.assertEqual((r.tier, r.effort), ("mid", "medium"))

    def test_unknown_role_raises(self):
        with self.assertRaises(ValueError):
            self.r("dance")


class HostTest(unittest.TestCase):
    def test_single_model_hosts_are_noop(self):
        for host in ("kimi", "grok", "ori", "openrouter", ""):
            r = routing.route("implement", host, "L", env={})
            self.assertEqual((r.model, r.agent), ("", ""))
            self.assertEqual(routing.cli_args(r, host), [])

    def test_claude_cli_args(self):
        r = routing.route("coordinate", "claude", "M", env={})
        self.assertEqual(routing.cli_args(r, "claude"), ["--model", "sonnet", "--settings", '{"effortLevel":"low"}'])


if __name__ == "__main__":
    unittest.main()
