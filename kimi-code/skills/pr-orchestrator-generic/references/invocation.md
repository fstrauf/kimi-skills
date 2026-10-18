# Invocation and the unattended loop

Referenced from `SKILL.md` → *Invocation*. Human-facing usage; a running orchestrator doesn't need it.

## Interactive and headless

**Interactive**

```
# Kimi
/skill:pr-orchestrator-generic <issue-number>

# Grok / Claude Code
/pr-orchestrator-generic <issue-number>

# Ori
Use `task` or `spawn_agent` with prompt containing this skill's instructions.
```

**Headless (single issue)**

```bash
kimi -p "/skill:pr-orchestrator-generic <issue-number>" --output-format stream-json
grok -p "/pr-orchestrator-generic <issue-number>" --always-approve
claude -p "/pr-orchestrator-generic <issue-number>" --model sonnet --settings '{"effortLevel":"low"}' \
  --permission-mode bypassPermissions --output-format stream-json --verbose
# Ori: invoke via `spawn_agent` with prompt containing this skill.
```

**Walk-away (scope then ship):**

```bash
ship-loop --profile coffee --agent grok
ship-loop --profile coffee --ask          # print parked leftovers
```

**Unattended Ready-column loop** (`pr-loop` on PATH, or `loop-ready-issues.sh` next to this skill):

Board + repo config comes from a **profile** (`profiles/<name>.env`). `--profile` is required.

Installed wrappers (via `~/.local/bin`, already on PATH):

| Command | Points at |
|---------|-----------|
| `ship-loop` | `ship-loop.sh` (scope then ship) |
| `pr-loop` | `loop-ready-issues.sh` |
| `scope-loop` | `scope-all.sh` |
| `pr-loop-setup` | `setup-profile.sh` |

```bash
pr-loop --profile txApp --agent grok
pr-loop --profile pageseeds-app --agent kimi
pr-loop --profile any --agent ori
pr-loop --profile coffee --agent claude        # cost-routed (see routing.py)
pr-loop --profile txApp --agent grok 3          # max 3 issues
pr-loop --list-profiles

# First time for a new product (auto-writes profiles/<name>.env if missing):
pr-loop --profile my-app --repo-dir ~/code/my-app --project <N> --agent grok
# or only setup:
pr-loop-setup my-app --repo-dir ~/code/my-app --project <N>
```

Logs: `~/.kimi-code/pr-loop-<profile>/`, `~/.grok/pr-loop-<profile>/`, `~/.ori/pr-loop-<profile>/`, or `~/.claude/pr-loop-<profile>/` (per profile). Locks are per-profile so two products can loop concurrently.

**Dirty tree between issues:** the loop auto-removes **untracked** debris (e.g. `packages/cli/node_modules` left after leaving a feature branch) when `ORCH_AUTO_CLEAN=1` (default). It never discards **tracked** modifications — those still abort the run. After each issue it returns the checkout to `main` so the next ticket starts clean.

**Queue:** REST labels, not Projects — see [docs/github-loop.md](../../../../docs/github-loop.md). Enqueue by hand with `gh issue edit N --add-label ready`.

**Auto-merge (serial land):** when `ORCH_AUTO_MERGE=1` (default), the **loop worker** lands the PR after orchestrator success, then pulls `main`.

1. If the PR is in an open **GitHub stack** (base/head chain) and `ORCH_STACK` is not `0`: **`gh stack merge <pr> --yes --squash`** (atomic; never push-land stacks).
2. Else try `gh pr merge` (squash).
3. If blocked (*human approval*), **`ORCH_MERGE_VIA_PUSH=1`**: squash onto `main`, push, close issue — **only for non-stacked PRs**.

Set `ORCH_AUTO_MERGE=0` to leave PRs for humans. Stack detection / land helpers live in `loop-common.sh` (`ORCH_STACK=auto|1|0`).
