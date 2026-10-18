#!/usr/bin/env python3
"""routing.py — cost routing: which model tier + effort each loop step gets.

One home for the policy. Skills and shell wrappers ask this module; they do
not pick models by hand.

Policy: Opus for scoping and for the correctness/spec verifier on M/L issues,
Sonnet (medium) for implement/review/fix and S-size verify, Haiku only for log
triage. Opus is otherwise reachable only through escalation of a failing run:

  - resume attempt 2          → implement/fix/review go up one step
                                (cheap→mid, effort +1; mid stays mid)
  - resume attempt ≥3, or an L issue whose review is on iteration 3
                              → strong tier for that role only
  - ORCH_MAX_TIER=cheap|mid|strong caps every route (default strong)
  - ORCH_ROUTE_<ROLE>=tier:effort pins one role (no escalation applied)

Size comes from the scoped issue body (`## Estimate` → `Size: S|M|L`, written
by gh-scope-issue). Missing / unparseable size → M.

Hosts: claude maps tiers to models. kimi / grok / ori / openrouter run one
model per session, so routing is a no-op there (empty model, no CLI args) and
the loop behaves exactly as before.

CLI:
  routing.py size <issue-body-file|->
      print S|M|L
  routing.py route <role> [--host H] [--size S|M|L] [--attempt N] [--review-iter N]
      print `tier=mid effort=low model=sonnet agent=loop-implementer`
      (model/agent empty on hosts without tier routing)
  routing.py cli-args <role> [same flags]
      print top-level session CLI flags for the host (empty for no-op hosts)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass

TIERS = ("cheap", "mid", "strong")
EFFORTS = ("low", "medium", "high")
SIZES = ("S", "M", "L")
DEFAULT_SIZE = "M"

# role → (tier, effort), same for every size. Opus only for scoping (and escalation);
# Sonnet everywhere else; Haiku only to summarize logs.
_POLICY: dict[str, tuple[str, str]] = {
    "coordinate": ("mid", "low"),
    "scope": ("strong", "medium"),
    "explore": ("mid", "low"),
    "implement": ("mid", "medium"),
    "review": ("mid", "medium"),
    "fix": ("mid", "medium"),
    "triage": ("cheap", "low"),
}
TABLE: dict[str, dict[str, tuple[str, str]]] = {role: {size: row for size in SIZES} for role, row in _POLICY.items()}
# The correctness/spec verifier is the one size-aware role: loop-passed M/L PRs
# still shipped correctness bugs that only an Opus review caught.
TABLE["verify"] = {"S": ("mid", "medium"), "M": ("strong", "medium"), "L": ("strong", "medium")}

ESCALATING_ROLES = frozenset({"implement", "fix", "review", "verify"})

HOST_MODELS: dict[str, dict[str, str]] = {
    "claude": {"cheap": "haiku", "mid": "sonnet", "strong": "opus"},
}

# Claude subagent definitions (claude/agents/*.md) per role.
HOST_AGENTS: dict[str, dict[str, str]] = {
    "claude": {
        "explore": "loop-explorer",
        "implement": "loop-implementer",
        "review": "loop-reviewer",
        "verify": "loop-verifier",
        "fix": "loop-fixer",
        "triage": "loop-triage",
    },
}

_SIZE_RE = re.compile(r"^\s*[-*]?\s*\**size\**\s*[:=]\s*\**\s*([SML])\b", re.IGNORECASE | re.MULTILINE)


@dataclass(frozen=True)
class Route:
    tier: str
    effort: str
    model: str
    agent: str

    def line(self) -> str:
        return f"tier={self.tier} effort={self.effort} model={self.model} agent={self.agent}"


def parse_size(body: str) -> str:
    """Size from the `## Estimate` section; falls back to any `Size:` line, then M."""
    estimate = re.search(r"^##\s*Estimate\s*$(.*?)(?=^##\s|\Z)", body, re.MULTILINE | re.DOTALL)
    for text in ([estimate.group(1)] if estimate else []) + [body]:
        match = _SIZE_RE.search(text)
        if match:
            return match.group(1).upper()
    return DEFAULT_SIZE


def _step(values: tuple[str, ...], value: str, by: int) -> str:
    return values[min(values.index(value) + by, len(values) - 1)]


def _parse_override(raw: str) -> tuple[str, str] | None:
    tier, _, effort = raw.strip().partition(":")
    if tier in TIERS and effort in EFFORTS:
        return tier, effort
    return None


def route(
    role: str,
    host: str = "",
    size: str = DEFAULT_SIZE,
    attempt: int = 1,
    review_iter: int = 0,
    env: dict[str, str] | None = None,
) -> Route:
    if role not in TABLE:
        raise ValueError(f"unknown role {role!r} (known: {', '.join(TABLE)})")
    env = os.environ if env is None else env
    size = size.upper() if size and size.upper() in SIZES else DEFAULT_SIZE
    tier, effort = TABLE[role][size]

    override = _parse_override(env.get(f"ORCH_ROUTE_{role.upper()}", ""))
    if override:
        tier, effort = override
    elif role in ESCALATING_ROLES:
        if attempt >= 3 or (size == "L" and review_iter >= 3):
            tier, effort = "strong", _step(EFFORTS, effort, 1)
        elif attempt == 2:
            tier, effort = _step(TIERS, tier, 1) if tier == "cheap" else tier, _step(EFFORTS, effort, 1)

    ceiling = env.get("ORCH_MAX_TIER", "strong")
    if ceiling in TIERS and TIERS.index(tier) > TIERS.index(ceiling):
        tier = ceiling

    host = (host or "").lower()
    model = HOST_MODELS.get(host, {}).get(tier, "")
    agent = HOST_AGENTS.get(host, {}).get(role, "")
    return Route(tier, effort, model, agent)


def cli_args(r: Route, host: str) -> list[str]:
    """Top-level session flags. Effort goes through --settings (works on every CLI version)."""
    if (host or "").lower() != "claude" or not r.model:
        return []
    settings = json.dumps({"effortLevel": r.effort}, separators=(",", ":"))
    return ["--model", r.model, "--settings", settings]


def _read_body(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    with open(path, errors="replace") as fh:
        return fh.read()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="routing.py", description="Loop cost routing")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_size = sub.add_parser("size")
    p_size.add_argument("body_file")
    for name in ("route", "cli-args"):
        p = sub.add_parser(name)
        p.add_argument("role")
        p.add_argument("--host", default=os.environ.get("ORCH_HOST", ""))
        p.add_argument("--size", default=os.environ.get("ORCH_SIZE", DEFAULT_SIZE))
        p.add_argument("--attempt", type=int, default=1)
        p.add_argument("--review-iter", type=int, default=0)
    args = parser.parse_args(argv[1:])

    if args.cmd == "size":
        try:
            print(parse_size(_read_body(args.body_file)))
        except OSError:
            print(DEFAULT_SIZE)
        return 0

    try:
        r = route(args.role, args.host, args.size, args.attempt, args.review_iter)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    if args.cmd == "route":
        print(r.line())
    else:
        print(" ".join(cli_args(r, args.host)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
