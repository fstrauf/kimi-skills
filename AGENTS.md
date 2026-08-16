# Repository Guidelines

Personal, cross-repo agent skills (Kimi Code, Grok Build, others). GitHub name is still `kimi-skills`; treat this tree as the **agent-skills** source of truth, not Kimi-only.

## Agent Principles (how to decide)

These override local “clever” defaults.

- **One home per fact.** A label, queue rule, or ship-gate command lives in one file. Skills and product `AGENTS.md` files **link** — they do not copy the table.
- **Simplest thing that fully meets current requirements.** No speculative orchestrator frameworks, extra status labels, or “we might need X later.”
- **Grow in layers.** Ship the smallest end-to-end slice that works. Supervisor first stays bash+Python islands; do not rewrite the fleet to land a one-line fix.
- **Prefer established libraries** only when they cut complexity. `gh` + GitHub issue labels are the queue. Do not add Temporal/LangGraph/Projects v2 for a serial laptop loop.
- **Use what we already depend on first** (bash wrappers on PATH, Python 3 stdlib, `gh`). Check `docs/github-loop.md` and existing `*.py` before adding a package or a second language.
- **Long-term decisions only.** Fix the real shape (fail-open supervisor, one label SSOT). Do not add another heal-heredoc for a single mis-scoped ticket.
- **When touching the loop:** extract toward `pr_chain.py` / `ready_queue.py` / `scope_queue.py`. Do not grow `loop-common.sh`.

## Project Structure

| Path | Role |
|------|------|
| `kimi-code/skills/` | Universal skills (live via `~/.kimi-code/skills` symlink) |
| `agents/skills/` | Shared agent skills (e.g. webbridge) |
| `docs/github-loop.md` | **SSOT** for the GitHub label machine + unattended loop |
| `skills-registry.yaml` | Install-plane contract (canonical path + symlink targets) |
| `scripts/skillctl.py` | `apply` / `verify` / `doctor` |
| `scripts/inventory-skills.py` | Machine-wide skill scan |
| `README.md` | Human map of buckets, harness discovery, consolidation |

New universal skill: `kimi-code/skills/<name>/SKILL.md` + registry entry. Never copy a skill into a product repo.

## Skills vs product repos

| Concern | Lives here | Lives in the product |
|---------|------------|----------------------|
| How to scope / implement / land | Skills + `docs/github-loop.md` | — |
| Which checkout / GitHub repo | `pr-orchestrator-generic/profiles/<name>.env` | — |
| Ship-gate command, ports, safety | — | That product’s `AGENTS.md` |
| Call-analyzer UI + real-user QA | Thick skill `pr-orchestrator` | `docs/d_USER_TESTING_GUIDE.md` |

Read **[docs/github-loop.md](docs/github-loop.md)** before changing labels, queues, or loop scripts.

## Build, Test, Ship Gate

No app build. Python 3 only (stdlib).

```bash
python3 -m pytest kimi-code/skills/pr-orchestrator-generic/tests
python3 scripts/skillctl.py doctor
```

After moving a skill: edit `skills-registry.yaml` → `python3 scripts/skillctl.py apply` → `doctor`. Same day.

Commits: short present-tense (~60 chars). PRs: what changed for agents (label/queue/skill) + why.

## Automation (scope / PR loops)

This repo **owns** the loop. Product repos only declare a profile + ship gate.

Queue is **REST labels only** (not GitHub Projects). Full machine: **[docs/github-loop.md](docs/github-loop.md)**.

```bash
ship-loop --profile coffee --agent grok    # scope then ship
ship-loop --profile coffee --ask           # parked leftovers
scope-loop --profile coffee --agent grok
pr-loop --profile coffee --agent grok
```

| Label | Meaning |
|-------|---------|
| *(none)* | Needs scope |
| `ready` | pr-loop can implement |
| `needs-input` / `blocked` | Owner / external — parked |
| `agent-working` / `agent-failed` | In flight / mechanical fail |
| `awaiting-merge` | PR open; dependents may stack |

Epics (`Epic:` title) are never scoped or shipped. Code dependencies go in `## Depends on`, never in `blocked`.
