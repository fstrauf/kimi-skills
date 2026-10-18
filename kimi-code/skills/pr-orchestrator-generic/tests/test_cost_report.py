#!/usr/bin/env python3
"""Unit tests for cost_report.py (loop spend visibility)."""

import json
import os
import sys
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import cost_report  # noqa: E402

NOW = datetime.now(timezone.utc).isoformat(timespec="seconds")


def _tmpdir(testcase: unittest.TestCase) -> Path:
    d = tempfile.TemporaryDirectory()
    testcase.addCleanup(d.cleanup)
    return Path(d.name)


def _touch(path: Path, content: str, mtime: float | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    if mtime is not None:
        os.utime(path, (mtime, mtime))


class ClaudeUsageTest(unittest.TestCase):
    def test_sums_cost_by_model(self):
        root = _tmpdir(self)
        slug = root / cost_report._claude_slug("/repo/app")
        _touch(slug / "a.jsonl", "\n".join([
            json.dumps({"type": "cost-state", "sessionId": "s1", "totalCostUSD": 0.5,
                        "modelUsage": {"claude-sonnet-4-5": {"costUSD": 0.5}}}),
            json.dumps({"type": "cost-state", "sessionId": "s1", "totalCostUSD": 1.75,
                        "modelUsage": {"claude-sonnet-4-5": {"costUSD": 0.5},
                                       "claude-opus-4-1": {"costUSD": 1.25}}}),
            json.dumps({"type": "user", "message": {"content": "no cost"}}),
            "not json at all",
        ]) + "\n")
        u = cost_report.claude_usage(0, "/repo/app", projects_root=root)
        self.assertTrue(u["available"])
        self.assertEqual(u["by_model"], {"claude-sonnet-4-5": 0.5, "claude-opus-4-1": 1.25})
        self.assertEqual(u["cost_usd"], 1.75)

    def test_legacy_per_entry_cost_fallback(self):
        root = _tmpdir(self)
        slug = root / cost_report._claude_slug("/repo/app")
        _touch(slug / "a.jsonl", "\n".join([
            json.dumps({"type": "assistant", "message": {"model": "claude-sonnet-4-5"}, "costUSD": 0.5}),
            json.dumps({"type": "assistant", "message": {"model": "claude-sonnet-4-5"}, "costUSD": 0.25}),
        ]) + "\n")
        u = cost_report.claude_usage(0, "/repo/app", projects_root=root)
        self.assertEqual(u["cost_usd"], 0.75)

    def test_mtime_filter(self):
        root = _tmpdir(self)
        slug = root / cost_report._claude_slug("/repo/app")
        old = time.time() - 10_000
        _touch(slug / "old.jsonl", json.dumps({"message": {"model": "m"}, "costUSD": 9.0}) + "\n", mtime=old)
        u = cost_report.claude_usage(time.time() - 100, "/repo/app", projects_root=root)
        self.assertEqual(u["cost_usd"], 0.0)


class KimiUsageTest(unittest.TestCase):
    def test_sums_token_fields(self):
        root = _tmpdir(self)
        _touch(root / "wd_app_abc" / "session_1" / "agents" / "main" / "wire.jsonl", "\n".join([
            json.dumps({"usage": {"inputOther": 277, "output": 470, "inputCacheRead": 98304}}),
            json.dumps({"usage": {"inputOther": 23, "output": 30, "inputCacheCreation": 100}}),
            json.dumps({"something": "else"}),
        ]) + "\n")
        u = cost_report.kimi_usage(0, sessions_root=root)
        self.assertTrue(u["available"])
        self.assertEqual(u["tokens"]["inputOther"], 300)
        self.assertEqual(u["tokens"]["output"], 500)
        self.assertEqual(u["tokens"]["inputCacheRead"], 98304)
        self.assertEqual(u["tokens"]["inputCacheCreation"], 100)

    def test_missing_root_is_zero_not_error(self):
        u = cost_report.kimi_usage(0, sessions_root=Path("/nonexistent/sessions"))
        self.assertTrue(u["available"])
        self.assertEqual(u["tokens"], {})


class CollectUsageTest(unittest.TestCase):
    def test_grok_and_ori_unavailable(self):
        for host in ("grok", "ori", "openrouter"):
            u = cost_report.collect_usage(host, 0)
            self.assertFalse(u["available"])


class UsageLineTest(unittest.TestCase):
    def test_claude_line(self):
        line = cost_report.usage_line({"available": True, "cost_usd": 1.75,
                                       "by_model": {"opus": 1.25, "sonnet": 0.5}})
        self.assertIn("$1.75", line)
        self.assertIn("opus $1.25", line)

    def test_kimi_line(self):
        line = cost_report.usage_line({"available": True, "tokens": {
            "inputOther": 412_000, "output": 38_000, "inputCacheRead": 1_200_000}})
        self.assertIn("412k in", line)
        self.assertIn("38k out", line)

    def test_unavailable_line(self):
        self.assertIn("n/a", cost_report.usage_line({"available": False, "reason": "no store"}))


def _route(issue, profile, role, tier, effort, model, attempt=1, review_iter=0, size="M", host="claude"):
    return {"ts": NOW, "cmd": "route", "host": host, "role": role, "size": size,
            "attempt": attempt, "review_iter": review_iter, "tier": tier, "effort": effort,
            "model": model, "agent": "", "profile": profile, "issue": issue, "cwd": "/repo"}


class BuildReportTest(unittest.TestCase):
    def test_aggregates_routes_and_spend(self):
        entries = [
            _route("1742", "coffee", "implement", "mid", "medium", "sonnet"),
            _route("1742", "coffee", "implement", "mid", "medium", "sonnet"),
            _route("1742", "coffee", "review", "mid", "medium", "sonnet"),
            {"ts": NOW, "cmd": "usage", "host": "claude", "profile": "coffee", "issue": "1742",
             "available": True, "cost_usd": 1.75, "by_model": {"sonnet": 1.75}},
        ]
        out = "\n".join(cost_report.build_report(entries))
        self.assertIn("Issue 1742", out)
        self.assertIn("implement mid/medium ×2", out)
        self.assertIn("$1.75", out)

    def test_detects_escalation(self):
        entries = [
            _route("1742", "coffee", "review", "mid", "medium", "sonnet", review_iter=1),
            _route("1742", "coffee", "review", "strong", "high", "opus", review_iter=3, size="L"),
        ]
        out = "\n".join(cost_report.build_report(entries))
        self.assertIn("⚠ escalated: review", out)
        self.assertIn("ORCH_ROUTE_REVIEW", out)

    def test_issue_filter(self):
        entries = [_route("1", "p", "implement", "cheap", "high", "haiku"),
                   _route("2", "p", "implement", "cheap", "high", "haiku")]
        out = "\n".join(cost_report.build_report(entries, issue="2"))
        self.assertNotIn("Issue 1 ", out)
        self.assertIn("Issue 2", out)

    def test_empty_log(self):
        out = "\n".join(cost_report.build_report([]))
        self.assertIn("No cost-log entries", out)


class LogRoundtripTest(unittest.TestCase):
    def test_append_and_read(self):
        root = _tmpdir(self)
        log = root / "routes.jsonl"
        cost_report.append_log({"ts": NOW, "cmd": "usage", "host": "kimi"}, log)
        cost_report.append_log({"ts": NOW, "cmd": "route", "role": "fix"}, log)
        entries = cost_report.read_log(log)
        self.assertEqual(len(entries), 2)
        self.assertEqual(entries[1]["role"], "fix")

    def test_append_fail_open(self):
        blocker = _tmpdir(self) / "blocker"
        blocker.write_text("not a dir")
        cost_report.append_log({"x": 1}, blocker / "routes.jsonl")  # must not raise


if __name__ == "__main__":
    unittest.main()
