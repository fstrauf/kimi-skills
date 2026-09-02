#!/usr/bin/env python3
"""Unit tests for agent_health.py quota/rate-limit + stale-log detection.

Run:  python3 tests/test_agent_health.py   (from the skill dir, stdlib only)
"""

import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import agent_health  # noqa: E402

GROK_QUOTA_LOG = """\
I'll scope GitHub issue 377: load the skill, fetch the ticket, verify premises.
You've reached your free Grok Build usage limit for now. Get SuperGrok for much higher limits, or try again later: https://grok.com/supergrok?referrer=grok-build
Error: You've reached your free Grok Build usage limit for now. Get SuperGrok for much higher limits, or try again later: https://grok.com/supergrok?referrer=grok-build
"""

CLEAN_FAILURE_LOG = """\
Running tests...
1 failing test: tests/analytics.spec.ts:42
Error: process exited with code 1
"""


class DetectQuotaErrorTest(unittest.TestCase):
    def test_grok_usage_limit_matches(self):
        hit = agent_health.detect_quota_error(GROK_QUOTA_LOG)
        self.assertIsNotNone(hit)
        self.assertIn("usage limit", hit)

    def test_clean_failure_does_not_match(self):
        self.assertIsNone(agent_health.detect_quota_error(CLEAN_FAILURE_LOG))

    def test_empty_log_does_not_match(self):
        self.assertIsNone(agent_health.detect_quota_error(""))

    def test_each_pattern_matches(self):
        for line in (
            "Error: API quota exceeded for this key",
            "Error: quota exhausted, try again tomorrow",
            "You are out of credits — top up to continue",
            "403: insufficient balance on account",
            "rate limit exceeded for model X",
            "ratelimit reached, backing off",
            "429 Too Many Requests",
            "402 Payment Required",
            "billing error: card declined",
        ):
            with self.subTest(line=line):
                self.assertIsNotNone(agent_health.detect_quota_error(line + "\n"))

    def test_quota_text_outside_tail_does_not_match(self):
        # An issue body quoting quota language deep in a long log must not
        # trip the detector — only the tail is authoritative.
        body = "The GSC API quota exceeded error must be handled gracefully.\n"
        log = body + ("ordinary agent work line\n" * (agent_health.TAIL_LINES + 10))
        self.assertIsNone(agent_health.detect_quota_error(log))

    def test_match_returns_first_matching_tail_line(self):
        log = "noise\ninsufficient quota\nmore noise after\n"
        self.assertEqual(agent_health.detect_quota_error(log), "insufficient quota")


class LogIsStaleTest(unittest.TestCase):
    def _touch(self, path, age_seconds):
        """Set the file's mtime to now - age_seconds."""
        past = time.time() - age_seconds
        os.utime(path, (past, past))

    def test_fresh_log_not_stale(self):
        with tempfile.NamedTemporaryFile() as fh:
            self._touch(fh.name, 60)
            self.assertFalse(agent_health.log_is_stale(fh.name, stale_minutes=15))

    def test_old_log_is_stale(self):
        with tempfile.NamedTemporaryFile() as fh:
            self._touch(fh.name, 20 * 60)
            self.assertTrue(agent_health.log_is_stale(fh.name, stale_minutes=15))

    def test_missing_log_not_stale(self):
        self.assertFalse(agent_health.log_is_stale("/nonexistent/issue-999.log", stale_minutes=15))

    def test_threshold_boundary(self):
        with tempfile.NamedTemporaryFile() as fh:
            self._touch(fh.name, 15 * 60)
            self.assertTrue(agent_health.log_is_stale(fh.name, stale_minutes=15))
            self._touch(fh.name, 15 * 60 - 1)
            self.assertFalse(agent_health.log_is_stale(fh.name, stale_minutes=15))

    def test_explicit_now_used_for_freshness(self):
        # A log written 5 min ago is stale if "now" is 10 min later than the mtime.
        with tempfile.NamedTemporaryFile() as fh:
            self._touch(fh.name, 0)  # mtime = now
            later = time.time() + 20 * 60
            self.assertTrue(agent_health.log_is_stale(fh.name, stale_minutes=15, now=later))

    def test_stale_check_cli_exit_codes(self):
        with tempfile.NamedTemporaryFile() as fh:
            self._touch(fh.name, 20 * 60)
            rc = agent_health.main(["agent_health.py", "stale-check", fh.name, "15"])
            self.assertEqual(rc, 0)
            self._touch(fh.name, 0)
            rc = agent_health.main(["agent_health.py", "stale-check", fh.name, "15"])
            self.assertEqual(rc, 1)

    def test_stale_check_cli_missing_file(self):
        rc = agent_health.main(["agent_health.py", "stale-check", "/nonexistent/issue-1.log", "15"])
        self.assertEqual(rc, 1)

    def test_stale_check_cli_bad_minutes(self):
        with tempfile.NamedTemporaryFile() as fh:
            rc = agent_health.main(["agent_health.py", "stale-check", fh.name, "abc"])
            self.assertEqual(rc, 2)


PS_TABLE = """\
  100     1   00:00:05
  200   100   00:01:10
  300   200   00:00:20
  400     1   00:00:07
  500   400   00:00:03
"""


class ParsePsTableTest(unittest.TestCase):
    def test_parses_pid_ppid_time(self):
        table = agent_health.parse_ps_table(PS_TABLE)
        self.assertEqual(table[100], (1, 5))
        self.assertEqual(table[200], (100, 70))
        self.assertEqual(table[300], (200, 20))

    def test_parses_all_time_shapes(self):
        self.assertEqual(agent_health._parse_ps_time("01:02"), 62)
        self.assertEqual(agent_health._parse_ps_time("1:02:03"), 3723)
        self.assertEqual(agent_health._parse_ps_time("2-03:04:05"), 183845)
        # macOS prints hundredths: MM:SS.hs
        self.assertEqual(agent_health._parse_ps_time("18:45.42"), 1125)
        self.assertEqual(agent_health._parse_ps_time("1:02:03.99"), 3723)

    def test_skips_malformed_lines(self):
        table = agent_health.parse_ps_table("PID PPID TIME\nnot-a-row\n  1 0 00:00:01\n")
        self.assertEqual(table, {1: (0, 1)})


class TreeCpuSecondsTest(unittest.TestCase):
    def test_sums_root_and_descendants_only(self):
        table = agent_health.parse_ps_table(PS_TABLE)
        # 100 + 200 + 300; the 400/500 subtree is unrelated.
        self.assertEqual(agent_health.tree_cpu_seconds(table, 100), 95)

    def test_subtree_root(self):
        table = agent_health.parse_ps_table(PS_TABLE)
        self.assertEqual(agent_health.tree_cpu_seconds(table, 400), 10)

    def test_missing_root_returns_none(self):
        table = agent_health.parse_ps_table(PS_TABLE)
        self.assertIsNone(agent_health.tree_cpu_seconds(table, 999))


class TreeIsBusyTest(unittest.TestCase):
    def test_first_sample_counts_as_busy_and_writes_baseline(self):
        with tempfile.TemporaryDirectory() as td:
            state = os.path.join(td, "cpu")
            self.assertTrue(agent_health.tree_is_busy(state, 100.0))
            with open(state) as fh:
                self.assertEqual(float(fh.read()), 100.0)

    def test_flat_second_sample_is_idle(self):
        with tempfile.TemporaryDirectory() as td:
            state = os.path.join(td, "cpu")
            agent_health.tree_is_busy(state, 100.0)
            self.assertFalse(agent_health.tree_is_busy(state, 100.0))

    def test_increased_sample_is_busy(self):
        with tempfile.TemporaryDirectory() as td:
            state = os.path.join(td, "cpu")
            agent_health.tree_is_busy(state, 100.0)
            self.assertTrue(agent_health.tree_is_busy(state, 130.5))

    def test_corrupt_state_counts_as_first_sample(self):
        with tempfile.TemporaryDirectory() as td:
            state = os.path.join(td, "cpu")
            with open(state, "w") as fh:
                fh.write("garbage")
            self.assertTrue(agent_health.tree_is_busy(state, 100.0))

    def test_tree_busy_cli_live_process(self):
        # Feed synthetic ps tables through the real CLI path: pid's CPU grows
        # between samples → busy; flat → idle. No wall-clock dependence.
        with tempfile.TemporaryDirectory() as td:
            state = os.path.join(td, "cpu")
            pid = str(os.getpid())
            samples = iter([f"  {pid}     1   00:00:05\n", f"  {pid}     1   00:00:07\n"])

            class _Result:
                def __init__(self, out):
                    self.stdout = out

            def fake_run(*args, **kwargs):
                return _Result(next(samples))

            original = agent_health.subprocess.run
            agent_health.subprocess.run = fake_run
            try:
                rc = agent_health.main(["agent_health.py", "tree-busy", pid, state])
                self.assertEqual(rc, 0)  # first sample: baseline
                rc = agent_health.main(["agent_health.py", "tree-busy", pid, state])
                self.assertEqual(rc, 0)  # CPU grew: busy
            finally:
                agent_health.subprocess.run = original

    def test_tree_busy_cli_gone_process(self):
        with tempfile.TemporaryDirectory() as td:
            state = os.path.join(td, "cpu")
            rc = agent_health.main(["agent_health.py", "tree-busy", "99999999", state])
            self.assertEqual(rc, 1)


if __name__ == "__main__":
    unittest.main()
