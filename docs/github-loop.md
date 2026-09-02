# GitHub ship loop

Single source of truth for how issues move from “rough ticket” to landed PR across every product profile. Skills and product `AGENTS.md` files **link here**. Do not copy this table into a fourth place.

Runtime today: `scope-loop` / `pr-loop` (bash) + Python queue modules + LLM skills. The *contract* below is what any agent must honor; implementation is allowed to move under it.

## Pipeline

```text
create issue          (bug/enhancement + priority — no ship label required)
        │
        ▼
scope-loop            open non-epic, not already in the ship/park pipeline
        │             skill: gh-scope-issue
        │             success → +ready   (unless needs-input / true blocked)
        ▼
pr-loop               label ready, topo-sorted by ## Depends on
        │             skill: pr-orchestrator-generic
        │             (call-analyzer profile: pr-orchestrator)
        │
        ├─ land + close
        ├─ awaiting-merge   (PR open / stacked; dependents stack onto the branch)
        └─ agent-failed     (mechanical fail — re-add ready to retry)

hygiene               needs-input / dupes / healed  (gh-ticket-hygiene)
```

Board columns are for humans. Agents must not `gh project item-edit`. `ORCH_BOARD=0` is the default.

## Labels

One ship label: **`ready`**. Everything else is metadata or a park.

| Label | Who sets it | Meaning | Next |
|-------|-------------|---------|------|
| *(none)* | — | Needs a scope pass | `scope-loop` |
| `scoping` | scope-loop (in flight) | Visibility only — **not** required to enqueue | — |
| **`ready`** | scope skill / human / heal | Spec is build-ready; **the** pr-loop queue | `pr-loop` |
| `needs-input` | scope or implementer | Human must answer (product / legal / budget) | park |
| `blocked` | scope / human | **External** stop only (vendor, legal hold). Rare. | park |
| `agent-working` | pr-loop worker | Claimed by a live run | land / park / fail |
| `agent-failed` | pr-loop worker | Mechanical failure (crash, tests, review FAIL×3) | human: `-agent-failed +ready` |
| `awaiting-merge` | pr-loop worker | PR open; merge pending | stack through / human `gh stack merge` |
| `triage:ready-to-implement` | triage | Metadata only. Loop heals orphans → `+ready` | — |

Skip titles `Epic:` / `[Epic]`. Epics are never scoped or shipped.

### Forbidden

- `blocked` because “#N is not merged yet” / “columns are not on main yet”
- Withholding `ready` so a human must re-run scope after every merge
- `needs-input` because the agent is merely unsure — make a reasonable call from the product `AGENTS.md`, or ask only when a human *decision* is required
- Adding `ready` to an epic or a delete-candidate
- Driving status via GitHub Projects

## Dependencies vs park

**Scoped ≠ mergeable on main right now.** Scope answers “is the contract clear?” Ship order is pr-loop’s job.

| Situation | Labels | Body |
|-----------|--------|------|
| Spec clear; needs sibling #N first | **`+ready`** | `## Depends on` with a `#N` bullet |
| Product / budget / legal question | `+needs-input` (no `ready`) | question in the body |
| True external freeze | `+blocked` + `## Ship gate (external)` | checkbox the human owns |

```markdown
## Depends on
- #110 — geo columns on roasters (land or stack under this first)
```

Rules:

- Only ship issues (not parent epics).
- Each dep is a **bullet that starts with `#N`**. Do not put other `#N` in that section (no “open as PR #281”).
- No deps → omit the section or write `_None_`.
- pr-loop topologically sorts `ready` issues. An open dep with an open PR or `awaiting-merge` is **satisfied** (stack-through): the dependent forks from that PR’s head via `ORCH_BASE_BRANCH`.
- **Epics ship as one GitHub stack** (a line, not a bush). See below.

## Epics are one stack

GitHub stacked PRs are a **single chain**: bottom PR targets the default branch; each next PR targets the head of the one below it. Siblings that share a parent are not a stack.

| Rule | Who |
|------|-----|
| Epic title (`Epic:` / `[Epic]`) is never `ready` | scope-loop |
| Each child lists **one** previous child in `## Depends on` (not the epic, not “269 and 272 and 273”) | gh-scope-issue |
| Soft / parallel notes go in Non-goals, not Depends-on | gh-scope-issue |
| Next child forks from the **current stack top**, never from an ancestor that already has a stacked child | pr-loop (`ORCH_BASE_BRANCH`) |
| `gh stack link` only **appends** to that stack. A sibling PR is logged and left unlinked — do not fake a stack | pr-loop |
| Independent work that can ship in either order is a **second stack** (or waits for the first to land) | scope |

```markdown
## Parent epic
#268

## Depends on
- #272 — previous layer (route manifest). This is stack PR3.
```

Do **not**:

```markdown
## Depends on
- #269 — scaffold
- #272 — also this
- #273 — preferred chrome
```

That DAG opens two PRs against #269 and GitHub will only stack one of them.

## Commands

Profiles live in `kimi-code/skills/pr-orchestrator-generic/profiles/<name>.env` (`REPO`, `REPO_DIR`, merge flags). Same profile for scope and ship.

```bash
ship-loop --profile coffee --agent grok   # scope then ship (walk-away)
scope-loop --profile coffee --agent grok  # scope only
pr-loop --profile coffee --agent grok     # ship only
ship-loop --profile coffee --ask          # print parked leftovers
pr-loop --list-profiles

# enqueue by hand (skip scope)
gh issue edit N --repo OWNER/REPO --add-label ready

# retry a mechanical fail
gh issue edit N --repo OWNER/REPO --remove-label agent-failed --add-label ready
```

| Wrapper | Script | Queue |
|---------|--------|-------|
| `ship-loop` | `ship-loop.sh` | scope then ship; prints leftovers |
| `scope-loop` | `scope-all.sh` + `scope_queue.py` | open non-epics not in ship/park pipeline |
| `pr-loop` | `loop-ready-issues.sh` + worker | `ready`, topo-sorted |
| `pr-loop-setup` | `setup-profile.sh` | write `profiles/<name>.env` |

Logs: `~/.kimi-code/pr-loop-<profile>/` or `~/.grok/pr-loop-<profile>/`. Locks are per-profile. Each issue runs in `$REPO_DIR/.worktrees/issue-N` so a dirty main checkout cannot abort the fleet.

## Who does what

| Actor | May | Must not |
|-------|-----|----------|
| **gh-scope-issue** | Rewrite issue body, `+ready` / `+needs-input` / `+blocked` | Product code, close without ask, `blocked` for sibling deps |
| **pr-orchestrator-generic** | Implement, draft PR, review×3, ship gate, `gh pr ready` | Merge stacked PRs, invent a park label, run live evals |
| **pr-orchestrator** | Same + call-analyzer UI/QA | Leak those gates into generic |
| **pr-loop worker** | `ready`→`agent-working`→close / `awaiting-merge` / `agent-failed` | Re-scope, touch human-owned in-progress (no `agent-working`) |
| **gh-ticket-hygiene** | Propose closes / clear stale `needs-input` | Add `ready`, touch `agent-*`, close without confirm |
| **Product `AGENTS.md`** | Ship-gate command, ports, safety | A second label machine |

## Supervisor rules (current vs intended)

| Rule | Behavior |
|------|----------|
| One stuck ticket | Park it (`needs-input` / `agent-failed` / `awaiting-merge`). Loop continues. |
| Ambiguity | `+needs-input`, exit 0, next ticket. Not `agent-failed`. |
| Empty pickable, deferred remain | Print deferred + blocking `#N`. That is not Done. |
| `needs-input` drain | `ship-loop --ask` lists parked questions. Answer on the issue, then `-needs-input +ready`. |
| Scope then ship | `ship-loop --profile NAME` |
| Land blocked (shim / husky / stack) | `awaiting-merge`; leftovers print `gh stack merge <top-pr> --yes --squash` |
| Dirty main checkout | Issue runs in a worktree. Tracked edits on main are left untouched. |
| Agent quota / rate-limit exhausted | Abort the whole run (exit 44), print switch-agent guidance. Current issue goes back to `ready` (pr-loop) / keeps `scoping` (scope-loop) — never `agent-failed`. Signatures: `agent_health.py`. |
| Agent wedged on exit (log frozen) | The CLI is expected to exit when its run finishes. A live process with a log untouched for `ORCH_AGENT_STALE_MINUTES` (default 15) **and an idle process tree** is a wedged agent (child servers holding its output pipes). The worker kills the whole process tree and judges the run by work product: an open PR → completed run (normal result flow); no PR → `agent-failed`. A frozen log with a CPU-burning tree is a long silent phase (delegated subagent, cold build) — the worker heartbeats into the log and keeps waiting, never kills. Detectors: `agent_health.py stale-check` + `tree-busy`. |

Mechanical `agent-failed` only: process crash, ship-gate red after retries, review FAIL after 3. Not “I had a question.”

## Agent handover (any repo)

When you touch a product checkout:

1. Read that repo’s `AGENTS.md` (ship gate, safety).
2. Honor the labels in the table above. If you cannot implement, **`needs-input` + comment**, do not leave the issue unlabeled and do not `blocked` a sibling.
3. If you implement: `Closes #N` on the PR; branch `feature/<N>-<slug>`.
4. If `ORCH_BASE_BRANCH` is set, fork and open the PR against that branch — never flatten a stack onto the default branch.
5. Do not `gh pr merge` / push-land a stacked PR.

When you touch **this** repo (the loop itself): read [AGENTS.md](../AGENTS.md), keep queue logic in the Python modules, add tests under `pr-orchestrator-generic/tests/`.
