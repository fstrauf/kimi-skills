#!/usr/bin/env python3
"""Unit tests for agent_health.py quota/rate-limit detection.

Run:  python3 tests/test_agent_health.py   (from the skill dir, stdlib only)
"""

import sys
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


if __name__ == "__main__":
    unittest.main()
