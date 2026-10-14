#!/usr/bin/env python3
"""Unit tests for routing.py (cost routing: tier + effort per loop role)."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import routing  # noqa: E402


class RouteTest(unittest.TestCase):
    def r(self, role, attempt=1, host="claude", **env):
        return routing.route(role, host, attempt, env=env)

    def test_table_lookup(self):
        r = self.r("implement")
        self.assertEqual((r.tier, r.effort, r.model, r.agent), ("mid", "medium", "sonnet", "loop-implementer"))
        self.assertEqual(self.r("coordinate").model, "sonnet")

    def test_only_scope_uses_strong_by_default(self):
        for role in routing.TABLE:
            self.assertEqual(self.r(role).model == "opus", role == "scope", role)

    def test_haiku_only_for_triage(self):
        for role in routing.TABLE:
            self.assertEqual(self.r(role).model == "haiku", role == "triage", role)

    def test_attempt_two_steps_effort_up_once(self):
        r = self.r("fix", attempt=2)
        self.assertEqual((r.tier, r.effort), ("mid", "high"))

    def test_attempt_three_reaches_strong(self):
        self.assertEqual(self.r("implement", attempt=3).model, "opus")
        self.assertEqual(self.r("review", attempt=3).model, "opus")

    def test_non_escalating_roles_stay_put(self):
        self.assertEqual(self.r("triage", attempt=5).tier, "cheap")

    def test_max_tier_ceiling(self):
        self.assertEqual(self.r("implement", attempt=3, ORCH_MAX_TIER="mid").model, "sonnet")

    def test_role_override_pins_route(self):
        r = self.r("implement", attempt=3, ORCH_ROUTE_IMPLEMENT="cheap:low")
        self.assertEqual((r.tier, r.effort), ("cheap", "low"))

    def test_invalid_override_falls_back(self):
        r = self.r("implement", ORCH_ROUTE_IMPLEMENT="huge")
        self.assertEqual((r.tier, r.effort), ("mid", "medium"))

    def test_unknown_role_raises(self):
        with self.assertRaises(ValueError):
            self.r("dance")


class HostTest(unittest.TestCase):
    def test_single_model_hosts_are_noop(self):
        for host in ("kimi", "grok", "ori", "openrouter", ""):
            r = routing.route("implement", host, env={})
            self.assertEqual((r.model, r.agent), ("", ""))
            self.assertEqual(routing.cli_args(r, host), [])

    def test_claude_cli_args(self):
        r = routing.route("coordinate", "claude", env={})
        self.assertEqual(routing.cli_args(r, "claude"), ["--model", "sonnet", "--settings", '{"effortLevel":"low"}'])


if __name__ == "__main__":
    unittest.main()
