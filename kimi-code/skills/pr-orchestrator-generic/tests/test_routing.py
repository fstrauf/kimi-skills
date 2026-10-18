#!/usr/bin/env python3
"""Unit tests for routing.py (cost routing: tier + effort per loop role)."""

import os
import sys
import tempfile
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
        self.assertEqual((r.tier, r.effort, r.model, r.agent), ("cheap", "high", "haiku", "loop-implementer"))
        self.assertEqual(self.r("coordinate").model, "sonnet")

    def test_default_policy_never_uses_strong(self):
        for role in routing.TABLE:
            for size in routing.SIZES:
                self.assertNotEqual(self.r(role, size).tier, "strong", (role, size))

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


class CostLogTest(unittest.TestCase):
    def _run_cli(self, argv, env):
        import json
        from unittest import mock
        with mock.patch.dict(os.environ, env, clear=False):
            self.assertEqual(routing.main(argv), 0)
        with open(env["ORCH_COST_LOG"]) as fh:
            return [json.loads(line) for line in fh]

    def test_route_call_appends_audit_line(self):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        log = os.path.join(d.name, "routes.jsonl")
        lines = self._run_cli(
            ["routing.py", "route", "review", "--host", "claude", "--size", "L", "--attempt", "2", "--review-iter", "1"],
            {"ORCH_COST_LOG": log, "ORCH_PROFILE": "coffee", "ORCH_STATE_ISSUE_N": "1742"})
        self.assertEqual(len(lines), 1)
        e = lines[0]
        self.assertEqual((e["cmd"], e["role"], e["host"]), ("route", "review", "claude"))
        self.assertEqual((e["size"], e["attempt"], e["review_iter"]), ("L", 2, 1))
        self.assertEqual((e["tier"], e["effort"], e["model"]), ("mid", "high", "sonnet"))
        self.assertEqual((e["profile"], e["issue"]), ("coffee", "1742"))

    def test_cli_args_call_also_logs(self):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        log = os.path.join(d.name, "routes.jsonl")
        lines = self._run_cli(
            ["routing.py", "cli-args", "coordinate", "--host", "claude"],
            {"ORCH_COST_LOG": log})
        self.assertEqual(lines[0]["cmd"], "cli-args")
        self.assertEqual(lines[0]["role"], "coordinate")

    def test_unwritable_log_is_fail_open(self):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        blocker = os.path.join(d.name, "blocker")
        with open(blocker, "w") as fh:
            fh.write("not a dir")
        from unittest import mock
        with mock.patch.dict(os.environ, {"ORCH_COST_LOG": os.path.join(blocker, "routes.jsonl")}, clear=False):
            self.assertEqual(routing.main(["routing.py", "route", "review", "--host", "claude"]), 0)  # must not raise

    def test_size_command_does_not_log(self):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        log = os.path.join(d.name, "routes.jsonl")
        body = os.path.join(d.name, "body.md")
        with open(body, "w") as fh:
            fh.write("## Estimate\nSize: S\n")
        from unittest import mock
        with mock.patch.dict(os.environ, {"ORCH_COST_LOG": log}, clear=False):
            self.assertEqual(routing.main(["routing.py", "size", body]), 0)
        self.assertFalse(os.path.exists(log))


if __name__ == "__main__":
    unittest.main()
