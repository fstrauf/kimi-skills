---
name: pr-orchestrator-generic
description: >-
  Orchestrate the full shipping loop for a GitHub issue in any repo — implement,
  open a draft PR, run thermonuclear review via PR comments, fix findings, run
  pnpm test:all, and mark the PR ready for review. Works on both Kimi Code and
  Grok Build. Use for /pr-orchestrator-generic, unattended Ready-column loops,
  or when shipping a scoped issue end-to-end.
when-to-use: >-
  Triggers on "/pr-orchestrator-generic", "/skill:pr-orchestrator-generic",
  "ship issue with generic orchestrator", or the loop-ready-issues.sh runner.
argument-hint: "<issue-number>"
---

# PR Orchestrator (Generic) — Kimi + Grok

Drive a GitHub issue from assignment through implementation, automated thermonuclear review, test gating, and PR creation. The review handover happens on a GitHub draft PR so every finding and fix is traceable.

This is the **repo-agnostic** orchestrator. It assumes only:

- a git repository with a GitHub remote and an authenticated `gh` CLI,
- a **deterministic ship gate** (see Phase 5 — prefer `pnpm run test:gate` or the non-eval subset of `test:all`),
- the `thermo-nuclear-code-quality-review` skill is available as the review baseline.

**Do not run live LLM eval suites in the automated loop** (`test:evals` / `#[ignore]` evals). They are multi-minute, flaky, and not part of CI. Humans can run `pnpm run test:evals` or full `pnpm test:all` before merge if desired.

If a repo needs extra release gates (dev-stack setup, QA scripts, canary checks, real-user integrity), that belongs in a **repo-specific** skill or `AGENTS.md` — do **not** hardcode monorepo paths here. For call-analyzer / Days to Expiry use **`pr-orchestrator`** (dual-host thick overlay: UI gate + real-user QA).

**Labels, queues, Depends-on vs park:** [docs/github-loop.md](../../../docs/github-loop.md) (repo root). Do not invent a second status machine.

## Host detection (do this first)

Detect which agent host you are on, then use **only** that host's tools for the rest of the run.

| Signal | Host |
|--------|------|
| Tools named `run_terminal_command`, `spawn_subagent`, `todo_write`, `get_command_or_subagent_output` exist | **Grok** |
| Tools named `Bash`, `Agent`, `TodoList`, `TaskOutput`, `CreateGoal` exist | **Kimi** |
| Unsure | Prefer the tools you actually have; never invent tool names from the other host |

Write the host name into your working notes (`host: kimi` or `host: grok`) and stick to the matching column in the tool map below.

## Tool map (use your host's column)

| Purpose | Kimi | Grok |
|---------|------|------|
| Shell (git, gh, short commands) | `Bash` | `run_terminal_command` |
| Long-running shell (`pnpm test:all`, servers) | `Bash` with `run_in_background: true`, `disable_timeout: true` | `run_terminal_command` with `background: true`, large/`0` `timeout` |
| Wait on background work | `TaskOutput(block=true)` / wait on task id | `get_command_or_subagent_output` with `task_ids` + positive `timeout_ms` |
| Stop background work | kill via shell / host stop API if available | `kill_command_or_subagent` |
| Implementation / fix / review subagents | `Agent` (coder/reviewer) | `spawn_subagent` (`subagent_type: "general-purpose"`; prefer `isolation: "worktree"` for implementers) |
| Progress tracking | `TodoList` | `todo_write` |
| Goal / status (optional) | `CreateGoal` | `update_goal` (`message` / `completed` / `blocked_reason`) |
| Read files | `Read` | `read_file` |
| Search code | `Grep`, `Glob` | `grep`, `list_dir` |
| Write small state files | shell redirect / write tools | `write` or shell via `run_terminal_command` |

**Rules:**

1. Never call the other host's tool names.
2. In non-interactive / unattended mode, always run long work (subagents, full test suites) in the background and wait explicitly.
3. Orchestrator coordinates (git, gh, PR comments, scheduling subagents). Prefer subagents for code edits; the orchestrator may still run targeted tests and git/gh directly.

## When to use

- You have a GitHub issue to implement and ship in **any** repo that uses `pnpm test:all` (or documents an equivalent ship gate).
- You want implement → draft PR → thermonuclear review → fix loop → tests → mark ready, automated.
- Interactive or headless (`kimi -p` / `grok -p` / `loop-ready-issues.sh`).

## Invocation

**Interactive**

```
# Kimi
/skill:pr-orchestrator-generic <issue-number>

# Grok
/pr-orchestrator-generic <issue-number>
```

**Headless (single issue)**

```bash
kimi -p "/skill:pr-orchestrator-generic <issue-number>" --output-format stream-json
grok -p "/pr-orchestrator-generic <issue-number>" --always-approve
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
pr-loop --profile txApp --agent grok 3          # max 3 issues
pr-loop --list-profiles

# First time for a new product (auto-writes profiles/<name>.env if missing):
pr-loop --profile my-app --repo-dir ~/code/my-app --project <N> --agent grok
# or only setup:
pr-loop-setup my-app --repo-dir ~/code/my-app --project <N>
```

Logs: `~/.kimi-code/pr-loop-<profile>/` or `~/.grok/pr-loop-<profile>/` (per profile). Locks are per-profile so two products can loop concurrently.

**Dirty tree between issues:** the loop auto-removes **untracked** debris (e.g. `packages/cli/node_modules` left after leaving a feature branch) when `ORCH_AUTO_CLEAN=1` (default). It never discards **tracked** modifications — those still abort the run. After each issue it returns the checkout to `main` so the next ticket starts clean.

**Unattended loop queue (REST labels, not Projects):**

```bash
gh issue edit N --add-label ready          # you enqueue
pr-loop --profile txApp --agent grok       # agent ships
```

Labels: see [docs/github-loop.md](../../../docs/github-loop.md). `ready` → `agent-working` → land/close · `awaiting-merge` · `needs-input` · `agent-failed`.

**Auto-merge (serial land):** when `ORCH_AUTO_MERGE=1` (default), the **loop worker** lands the PR after orchestrator success, then pulls `main`.

1. If the PR is in an open **GitHub stack** (base/head chain) and `ORCH_STACK` is not `0`: **`gh stack merge <pr> --yes --squash`** (atomic; never push-land stacks).
2. Else try `gh pr merge` (squash).
3. If blocked (*human approval*), **`ORCH_MERGE_VIA_PUSH=1`**: squash onto `main`, push, close issue — **only for non-stacked PRs**.

Set `ORCH_AUTO_MERGE=0` to leave PRs for humans. Stack detection / land helpers live in `loop-common.sh` (`ORCH_STACK=auto|1|0`).

## Preconditions

- Inside a git repo with a GitHub remote; `gh` authenticated (read/write issues + PRs).
- Ship gate: resolve per Phase 5 (prefer `test:gate`; never block the loop on live evals).
- Willing to let the agent commit, push, open a draft PR, and mark it ready.
- `thermo-nuclear-code-quality-review` skill file is readable on this machine.
- **Optional stacks:** `gh extension install github/gh-stack` for stack-aware create/push/land. Repo must have Stacked PRs enabled (CLI exit 9 if not). Without the extension or feature, stay on the single-PR path.

## Non-negotiable limits

These override any other instruction in this skill or any invoked skill:

1. **Review loop max 3 iterations.** Never run a 4th thermonuclear review. If still FAIL after 3, stop and report.
2. **No full test/build during review.** `pnpm test:all`, `pnpm build`, and similar full suites run only in the test gate, after the review loop passes.
3. **No force-push or destructive commands.** Prefer plain `git push`. If rewrite is unavoidable, `--force-with-lease` only and explain why. **`gh stack push` / `gh stack merge` are allowed** — they use force-with-lease internally.
4. **No data-modifying SQL** unless the repo's own orchestrator contract explicitly requires it and provides safe scripts. Default: never.
5. **Orchestrator coordinates; subagents change code** when isolation is available (especially Grok worktrees).
6. **Never `gh pr merge` or push-land a stacked PR.** Use `gh stack merge` (or leave for a human). Push-land flattens the chain.

## GitHub Stacked PRs (mode A — stack-aware)

**Default remains one issue → one ship unit.**

### Ready-queue order (Depends on)

`pr-loop` does **not** ship issues in random open order. `ready_label_candidates` in `loop-common.sh`:

1. Only `ready` (skips `blocked` / `agent-*` / Epics).
2. Parses `## Depends on` / `Depends on: #N` from the issue body.
3. **Topological sort** among ready issues (priority, then **continue an unmerged stack** before unrelated same-P work, then issue number).
4. Defers a ready issue if an open dependency is not closed, not `ready`, and not `awaiting-merge` / open-PR (those stack through).
5. “Does this issue already have a PR?” uses `pr_chain` (`Closes`/`Fixes`/`Resolves #N` or `feature/<N>-`). Never GitHub search `Closes #N in:body` (token-AND false positives).

Scope agents must put **code dependencies in the body**, not in the `blocked` label. See `gh-scope-issue` → *Dependencies vs park labels*.

 Mode A does **not** auto-split work into multi-layer stacks (that is mode B). It makes the orchestrator and pr-loop **safe and correct** when a stack exists or when `ORCH_STACK=1` prefers stack tooling.

### Detect once (Phase 0)

pr-loop **bootstraps stacks every run** (`ensure_gh_stack_ready` in `loop-common.sh`):
installs `github/gh-stack` if missing, probes `GET /repos/{repo}/stacks`, sets local
git knobs (`rerere`, `remote.pushDefault`). Env exported into the agent process:

| Env | Meaning |
|-----|---------|
| `ORCH_STACK` | `auto` (default) \| `1` \| `0` |
| `ORCH_STACK_CLI` | `1` if `gh stack` works |
| `ORCH_STACK_REPO_OK` | `1` if Stacks API answered 2xx for this repo |
| `ORCH_STACK_READY` | `1` only when both CLI + repo probe OK |
| `ORCH_BASE_BRANCH` | Branch this issue must fork from (default branch when unset). pr-loop sets it to a dependency's open-PR head when stacking through an unmerged chain |

### Loop-driven dependency chains (`ORCH_BASE_BRANCH`)

pr-loop ships whole `## Depends on` chains without waiting for human merges:
when a dependency's PR is still open, the loop exports `ORCH_BASE_BRANCH` as
that PR's head — or the **GitHub stack top** if that PR already has stacked
children (never open a sibling against an ancestor). The issue is labeled
`awaiting-merge` after its own PR opens. The agent contract:

1. Fork the feature branch from `origin/$ORCH_BASE_BRANCH` (not from the
   default branch).
2. Open the PR with `--base "$ORCH_BASE_BRANCH"` so GitHub shows only this
   layer's diff.
3. All diff ranges (review, fix verification) use `origin/$ORCH_BASE_BRANCH...HEAD`.
4. **Never merge** such a PR from the agent or loop worker — the human lands
   the whole chain with `gh stack merge <top-pr> --yes --squash` (or merges
   bottom-up), and the next loop run restacks whatever remains.

There is **no public GitHub API to flip “enable Stacked PRs” on a repo**. If the probe
returns 404, log it and stay on the classic path (user must enable via plan / UI / waitlist).

When not launched via pr-loop, probe yourself:

```bash
ORCH_STACK="${ORCH_STACK:-auto}"
STACK_CLI="${ORCH_STACK_CLI:-0}"
if [ "$STACK_CLI" != "1" ] && gh stack --help >/dev/null 2>&1; then
  STACK_CLI=1
fi
if [ "$STACK_CLI" != "1" ] && [ "${ORCH_STACK_ENSURE:-1}" != "0" ]; then
  gh extension install github/gh-stack 2>/dev/null || true
  gh stack --help >/dev/null 2>&1 && STACK_CLI=1
fi
# Prefer ORCH_STACK_READY from the loop when present
STACK_READY="${ORCH_STACK_READY:-$STACK_CLI}"
```

Write `stack_cli` / `stack_ready` into working notes. If `STACK_CLI=0` or `STACK_READY=0`, never call `gh stack *`; use the classic path.

### When to use stack commands

| Situation | Create / open | Iterate (fix+push) | Land (loop only if `ORCH_AUTO_MERGE=1`) |
|-----------|---------------|---------------------|----------------------------------------|
| `STACK_CLI=0` or `ORCH_STACK=0` | `git push` + `gh pr create --draft` | `git push` | `gh pr merge` / push-land |
| Single branch, not in a chain (`ORCH_STACK=auto`) | Classic path (above) | Classic path | Classic path |
| Already on a `gh stack` branch, or open PR base is another PR's head | `gh stack submit --auto` (drafts) | commit → `gh stack push` (rebase first if mid-stack fix: `gh stack rebase` then push) | `gh stack merge <pr> --yes --squash` |
| `ORCH_STACK=1` and `STACK_CLI=1` | Prefer `gh stack init feature/<n>-<slug>` then implement; open with `gh stack submit --auto` | `gh stack push` | stack merge if chained; else classic |

### Create path when using the stack CLI (`ORCH_STACK=1` or already stacked)

```bash
# From default branch, clean tree:
gh stack init "feature/<issue-number>-<slug>"
# ... implement + commit on this branch ...
gh stack submit --auto    # drafts; non-interactive titles
# Capture PR: gh pr view --json number,url
```

Do **not** also run `gh pr create` for the same branch. Body can be updated after submit:

```bash
gh pr edit <pr_number> --body "$(cat <<'EOF'
Closes #<N>

## Summary
...
EOF
)"
```

### Iterate (review fixes / test fixes) on a stack

```bash
# On the branch that owns the finding:
git add -A && git commit -m "fix: …"
# If you edited a lower layer and need descendants updated:
gh stack rebase
gh stack push
```

Plain `git push` mid-stack often leaves upper PRs stale; prefer `gh stack push`.

### Land (humans or pr-loop)

```bash
# Merge everything up to and including this PR (atomic):
gh stack merge <pr_number> --yes --squash
```

pr-loop does this automatically when `ORCH_STACK!=0` and the PR is in an open chain (`loop-common.sh`).

## State and scratch paths

Resolve once at the start (host-neutral):

```bash
scratch_dir="${TMPDIR:-/tmp}/pr-orchestrator-$(id -u)"
mkdir -p "$scratch_dir" && chmod 700 "$scratch_dir"
echo "$scratch_dir"
```

Persist the review iteration counter (survives compaction better than memory alone):

- `iter_file`: `${scratch_dir}/issue-<N>-review-iter.txt`

Prefer absolute paths in later shell calls; do not rely on shell variables surviving across separate tool invocations.

Optional host-specific extras (do not require them):

- Kimi: `~/.kimi-code/tmp/`
- Grok: `~/.grok/plugin-data/pr-orchestrator/`

## Workflow

### Phase 0 — Lock context

1. Read the skill argument for the issue number. If missing, ask once and stop if still missing.
2. Optional goal: set objective  
   `Implement GitHub issue #<number>, run the thermonuclear review loop until clean, run pnpm test:all, and mark the PR ready for review`  
   (Kimi: `CreateGoal` · Grok: `update_goal` with `message`).
3. Shell: `git branch --show-current`.
4. Shell: `gh auth status` (or equivalent). If not authenticated, stop and report.
5. Detect stack CLI + mode (see **GitHub Stacked PRs** above): `STACK_CLI`, `ORCH_STACK`.
6. Shell: `gh issue view <number> --json title,body,labels,number,state,url`.
7. If the issue is closed, stop and report.
8. Resolve the base branch: `BASE="${ORCH_BASE_BRANCH:-<default branch>}"`. When the loop exports `ORCH_BASE_BRANCH`, this issue stacks on an unmerged dependency PR — fork from it, never from the default branch (see *Loop-driven dependency chains*).
9. If on `main` or `master`, create the feature branch:
   - **Stack path** (`ORCH_STACK=1` and `STACK_CLI=1`): `gh stack init "feature/<issue-number>-<slug>"`
   - **Classic path** (default / auto): `git fetch origin "$BASE" && git checkout -b feature/<issue-number>-<slug> "origin/$BASE"`
10. Create todos (Kimi: `TodoList` · Grok: `todo_write`, merge false on first create):
   - Understand issue
   - Implement
   - Open draft PR
   - Review loop
   - Test gate
   - Mark PR ready

### Phase 1 — Understand the issue

1. Read the issue title and body carefully.
2. Read `AGENTS.md` / `Agents.md` and project docs it references.
3. Search the codebase for relevant files (host search tools).
4. If the body is ambiguous, make a reasonable interpretation from `AGENTS.md` and proceed. Park `needs-input` **only** for a product / legal / budget decision a human must make:
   ```bash
   gh issue edit <N> --add-label needs-input --remove-label ready
   gh issue comment <N> --body "needs-input: <the question>"
   ```
   Then **exit 0**. Do not use `blocked`. Do not `agent-failed`. The supervisor will pick the next ticket.
5. Mark "Understand issue" done.

### Phase 2 — Implement

1. Spawn an **implementer subagent** with a complete brief:
   - Issue number, title, body
   - Relevant file paths
   - Follow `AGENTS.md`; minimal scoped changes
   - Targeted tests only if needed; **do not** run `pnpm test:all` / full build
   - Return summary of changes, commit SHAs if any, open questions

   **Kimi:** `Agent` coder; non-interactive → background + `TaskOutput(block=true)`.  
   **Grok:** `spawn_subagent` with `subagent_type: "general-purpose"`, prefer `isolation: "worktree"`, `background: true`; wait with `get_command_or_subagent_output` (large `timeout_ms`, e.g. 1800000). If a worktree was used, fetch its HEAD onto the feature branch in the main repo before continuing (same idea as execute-plan worktree protocol).

2. Inspect:
   - `git status --short`
   - `git log --oneline -5` and/or `git diff --stat`
   - Prefer `git diff --name-only origin/main...HEAD` (or `origin/master...HEAD`) when the branch has commits
3. If there are no changes, stop and report that the implementer produced no diff.
4. Run any targeted tests the subagent skipped (commands from `AGENTS.md`).
5. If those fail, spawn a fix subagent (or resume the implementer) before continuing.
6. Ensure a commit exists, e.g. `feat: <issue title> (closes #N)`.
7. Mark "Implement" done.

### Phase 3 — Open a draft PR

1. Mark "Open draft PR" in progress.
2. **Stack path** (active `gh stack` / `ORCH_STACK=1` with CLI — see table above):

```bash
gh stack submit --auto
# drafts by default with --auto; set title/body on the PR for this branch:
gh pr edit --title "<issue title>" --body "$(cat <<'EOF'
Closes #<N>

## Summary
<brief summary of changes>

## Automated gates
An automated thermonuclear review will run on this draft PR, followed by `pnpm test:all`.
EOF
)"
```

   If `gh stack submit` fails with exit 9 (Stacked PRs not enabled) or extension errors, fall back to the classic path and set `STACK_CLI=0` for the rest of the run.

3. **Classic path** (default):

```bash
git push -u origin <branch>
# When ORCH_BASE_BRANCH is set (stacked on an unmerged dep PR), target it:
#   gh pr create --draft --base "$ORCH_BASE_BRANCH" ...
gh pr create --draft \
  ${ORCH_BASE_BRANCH:+--base "$ORCH_BASE_BRANCH"} \
  --title "<issue title>" \
  --body "$(cat <<'EOF'
Closes #<N>

## Summary
<brief summary of changes>

## Automated gates
An automated thermonuclear review will run on this draft PR, followed by `pnpm test:all`.
EOF
)"
```

4. Capture PR number/url: `gh pr view --json number,url`.
5. Mark "Open draft PR" done.

### Phase 4 — Review loop via PR comments (max 3 iterations)

**CRITICAL:**

- Strictly **3** review iterations max. Never a 4th.
- No `pnpm test:all` / full build in this phase.
- Only: review → post findings → fix → push.
- Test gate only after PASS (or hard stop).

**Review baseline (once, before iteration 1):**

1. Resolve absolute path to `thermo-nuclear-code-quality-review` `SKILL.md`. Probe in order; use first readable:

```bash
for p in \
  "$HOME/.kimi-code/skills/thermo-nuclear-code-quality-review/SKILL.md" \
  "$HOME/.grok/skills/thermo-nuclear-code-quality-review/SKILL.md" \
  "$HOME/.grok/bundled/skills/thermo-nuclear-code-quality-review/SKILL.md" \
  "$HOME/.agents/skills/thermo-nuclear-code-quality-review/SKILL.md"; do
  if [ -f "$p" ]; then echo "$p"; break; fi
done
```

   Also acceptable: take the path from your host's skill listing if it exposes one. Do not hardcode a single machine path without probing.

2. Read that file yourself to confirm it is readable. If missing/unreadable, STOP. Never run a degraded review without the baseline.
3. Use that path as `<baseline_path>` in every reviewer subagent prompt. Reviewer subagents have **no** Skill tool — they must `Read` / `read_file` the baseline file.

**Iteration tracking:**

```bash
echo 1 > "<iter_file>"
```

**Loop body:**

```
Set iteration = N from <iter_file> (start at 1)

WHILE true:
  1. Read <iter_file> → N
  2. If N > 3:
       - STOP
       - gh pr comment: "🛑 Automated review stopped after 3 iterations. Remaining findings require human triage."
       - Report to user / optional blocked goal
  3. Mark todo "Review loop (iteration N/3)"
  4. Changed files (base = `ORCH_BASE_BRANCH` when set — never diff a stacked
     branch against the default branch, that shows the whole chain):
       git diff --name-only "origin/${ORCH_BASE_BRANCH:-main}...HEAD" 2>/dev/null \
         || git diff --name-only origin/master...HEAD \
         || git diff --name-only HEAD~1
  5. Spawn reviewer subagent (prompt below), background, wait for completion
  6. Parse BASELINE + VERDICT
  7. If VERDICT == PASS:
       - Post passing PR comment
       - Break
  8. If VERDICT == FAIL:
       - If N == 3: STOP, post findings, do not spawn fix, report
       - Else: post findings with marker <!-- thermonuclear-review-iter-N -->
       - Spawn/resume implementer to fix only those findings; commit + push
       - If same substantive finding repeats across consecutive iterations, STOP
       - N = N+1; write N to <iter_file>
  9. Missing BASELINE: loaded or unparseable VERDICT → STOP (invalid review)
```

**Reviewer subagent prompt:**

```
Run a thermo-nuclear code quality review on the current branch changes for draft PR #<pr_number>.

This is review iteration <iteration> of 3. On iteration 3, any remaining actionable findings will cause the loop to stop without further fixes. Be decisive: output PASS if previous findings have been addressed and no new structural blockers exist.

Focus on these files: <comma-separated paths>

You do not have a Skill tool — do NOT attempt to invoke /thermo-nuclear-code-quality-review or /skill:thermo-nuclear-code-quality-review.
Instead, use your host's read-file tool to read this file IN FULL before inspecting the diff; it is the review baseline you must apply rigorously:
<baseline_path>

If you cannot read that file, respond with exactly `BASELINE: MISSING` and nothing else, then stop.

Then inspect the diff (prefer `origin/$ORCH_BASE_BRANCH...HEAD` when `ORCH_BASE_BRANCH` is set, else origin/main...HEAD or origin/master...HEAD) and produce a structured verdict.

Your response must use this exact format:

BASELINE: loaded (<baseline_path>)

VERDICT: PASS|FAIL

FINDINGS:
1. [Only if FAIL] <file path>: <specific, actionable issue>. Suggested fix: <concrete change>.
2. ...

NOTES:
- Optional non-blocking observations.

Be decisive. If previous findings have been addressed and no new structural blockers exist, output PASS. Do not introduce new low-severity findings in later iterations.
Do not explain your reasoning outside these sections.
```

**When VERDICT is FAIL** (and N < 3):

```bash
gh pr comment <pr_number> --body "<!-- thermonuclear-review-iter-<iteration> -->
🧪 Automated thermonuclear review findings (iteration <iteration> of 3):

<paste findings>

Please address the above findings and push updates."
```

Then spawn/resume implementer:

```
Address the thermonuclear review findings on draft PR #<pr_number>.

Read the latest review comments with: gh pr view <pr_number> --comments
Focus on comments marked "<!-- thermonuclear-review-iter-<iteration> -->".

Do not change behavior. Make minimal, structural improvements as requested.
Do NOT run pnpm test:all, pnpm build, or any full test/build suite. Only make the requested code changes.
Commit and push your changes.
If this branch is part of a GitHub stack (gh stack), push with: gh stack push
(and gh stack rebase first if you edited a lower layer). Otherwise: git push.
Return a summary of changes.
```

**Hard stop** (comment on PR + report to user):

- Would exceed 3 iterations
- `VERDICT == FAIL` on iteration 3
- Same substantive finding in two consecutive iterations
- Unparseable `VERDICT`
- Missing `BASELINE: loaded` or `BASELINE: MISSING`

Do not enter the test gate without a clean PASS.

Mark "Review loop" done on PASS.

### Phase 5 — Test gate

1. Mark "Test gate" in progress.
2. Check `AGENTS.md` for prerequisites (services, env, seed data). Run documented setup first; teardown after if documented.
3. **Resolve the ship-gate command** (first match wins):

   ```bash
   # 1) Explicit automated gate
   if package.json has scripts["test:gate"] → pnpm run test:gate

   # 2) AGENTS.md / project docs name a non-eval gate for CI/automation → use that

   # 3) pageseeds-style test:all that includes live evals — run the deterministic subset only:
   pnpm run test:rust \
     && pnpm run lint \
     && pnpm exec tsc -b \
     && pnpm test \
     && pnpm run check:ipc \
     && pnpm run check:task-store \
     && ./scripts/check-bindings.sh \
     && pnpm run build
   # Skip: pnpm run test:evals  (live LLM; flaky; multi-minute; not in GitHub CI)

   # 4) Fallback
   pnpm test:all   # only if the above scripts do not exist
   ```

   **Hard rule:** do **not** invoke `pnpm run test:evals` or `cargo test … -- --ignored` live-eval filters in this phase unless the user explicitly set `ORCH_RUN_EVALS=1` in the environment.

4. **Run the resolved command** as a **background** shell task (full suites exceed foreground timeouts). Wait until completion.
5. If pass: `gh pr comment <pr_number> --body "✅ Ship gate passed: \`<exact command>\`."`
6. If fail:
   - Classify: product failure vs flake (eval timeout, network, corrupted cargo index).
   - Product: post summary, spawn fix subagent, re-run gate once more (**max 2 total attempts**).
   - Flake only (rare with evals skipped): re-run gate once with no code change; if still fail, stop and report.
7. Mark "Test gate" done.

**Why this is faster:** On PageSeeds, `pnpm test:all` = rust + **live LLM evals** + lint + tsc + vitest + checks + full vite build. Live evals alone often take 10–30+ minutes and flake (wrong LLM categories), forcing full-suite retries. CI only runs ~4 minutes of rust + lint/typecheck; the loop should track that, not paid LLM regression suites.

### Phase 6 — Mark PR ready for review

1. Mark "Mark PR ready" in progress.
2. `gh pr ready <pr_number>`.
3. Final comment:

```
This PR is ready for review.
- ✅ Thermonuclear review passed (<N> iteration(s))
- ✅ Ship gate green (`<exact command>` — live LLM evals not run in the automated loop)
```

4. Report PR URL to the user.
5. Mark all todos done. Optional: complete the goal (Kimi goal done · Grok `update_goal` with `completed: true`).
6. If you created worktrees, clean them up when the host supports it (e.g. `grok worktree rm --force <path>`).

## Safety rules

- Do not force-push without lease; prefer no force-push at all. `gh stack push` is fine (lease internally).
- Do not run destructive database or file commands.
- Never `gh pr merge` or squash-push-land a stacked PR — use `gh stack merge` or hand off to a human.
- If the issue needs a human decision (product/legal/budget only), `+needs-input` and exit 0. Do not abort the fleet.
- If the review loop or test gate gets stuck, stop and report current state rather than looping forever.
- Respect project-specific test commands from `AGENTS.md`.
- Prefer worktree-isolated implementers when the host supports them so the main workspace stays clean.

## Output expectations

At the end of a successful run, report:

- Issue number and title
- Branch name
- PR URL
- Number of review iterations and final verdict
- Test result (`pnpm test:all` or project equivalent)
- Host used (`kimi` or `grok`)
- Note that the PR is ready for review
- Reminder: manual QA is still required before approving

## Relationship to other skills

| Skill | Role |
|-------|------|
| `pr-orchestrator` | **Call-analyzer thick overlay** (dual-host): same loop + `pnpm test:all`/dev stack + UI gate + real-user QA. Use only in call-analyzer; profile `ORCH_SKILL=/pr-orchestrator`. |
| `thermo-nuclear-code-quality-review` | Review baseline loaded via read-file into reviewer subagents |
| `ship-loop` (PATH) | Walk-away: scope then ship; `--ask` prints leftovers |
| `pr-loop` (PATH) / `loop-ready-issues.sh` | Unattended Ready-column runner; **`--profile NAME`** + `--agent kimi\|grok` |
| `pr-loop-setup` (PATH) / `setup-profile.sh` | Create/refresh `profiles/<name>.env` |
| `profiles/*.env` | Per-product board/repo config **shared with scope-loop** (txApp, pageseeds-app, …) |
| `scope-loop` (PATH) / `scope-all.sh` | Unattended Scoping-column runner; same `--profile NAME` as pr-loop |
| `pr-babysit` (Grok) | Post-ready CI/review babysitter; already understands Graphite + `gh stack` |
| `docs/github-loop.md` | **SSOT** for REST labels, handover, supervisor rules |
