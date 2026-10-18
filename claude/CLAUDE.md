# Personal workflow (all repos)

Installed as `~/.claude/CLAUDE.md` (symlink, managed by `skills-registry.yaml` in the kimi-skills repo).

## Build flow: scope, then ship

Features are built in two stages over GitHub issues. Labels and queue rules: `~/01_code/kimi-skills/docs/github-loop.md` (single source; do not restate them).

1. **Scope**: `gh-scope-issue` turns a rough issue into a build-ready spec. Run it on **Opus 5.5, medium effort**, ideally via the `loop-scoper` subagent or a session started with `--model opus`. Never implements code.
2. **Ship**: `pr-orchestrator-generic` takes scoped issues to a ready PR. Run it on **Sonnet 5.5, medium effort**. The chat session is the coordinator and spawns the `loop-*` subagents (implementer, reviewer, verifier, fixer, explorer, triage), one issue at a time or in parallel. Usage: `/pr-orchestrator-generic 12 14 --parallel`.

Per-role models for subagents live in `claude/agents/*.md` frontmatter and `routing.py`. Do not pick models by hand. Interactive Opus scoping is a deliberate exception; the unattended loop follows `routing.py`.

Unattended runs: `scope-loop`, `pr-loop`, `ship-loop` (see the repo's AGENTS.md).

## When asked to scope or ship issues

Use the skills above rather than improvising. Product-specific ship gates and ports come from that product's own `AGENTS.md`.
