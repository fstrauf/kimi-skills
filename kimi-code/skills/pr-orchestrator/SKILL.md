---
name: pr-orchestrator
description: >-
  Orchestrate the full shipping loop for a call-analyzer / Days to Expiry GitHub
  issue — implement, open a draft PR, run thermonuclear review via PR comments,
  fix findings, run pnpm test:all, UI gate (advisory), real-user QA safety check,
  and mark the PR ready for review. Works on both Kimi Code and Grok Build.
  Use when the user wants to ship a call-analyzer issue end-to-end or asks for
  /pr-orchestrator.
when-to-use: >-
  Triggers on "/pr-orchestrator", "/skill:pr-orchestrator", "ship issue",
  "orchestrate PR for issue", or "implement issue and open PR with review loop"
  inside call-analyzer (or when the call-analyzer profile sets ORCH_SKILL=/pr-orchestrator).
argument-hint: "<issue-number>"
---

# PR Orchestrator (call-analyzer) — Kimi + Grok

Drive a GitHub issue from assignment through implementation, automated thermonuclear review, test gating, UI verification (advisory), real-user QA, and PR ready. The review handover happens on a GitHub draft PR so every finding and fix is traceable.

This is the **call-analyzer / Days to Expiry thick overlay**. It assumes the monorepo layout (`webapp/`, `core/`, `api/`, `pnpm test:all`, portfolio QA scripts). For other products use **`pr-orchestrator-generic`**.

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
| Long-running shell (dev stack, `pnpm test:all`) | `Bash` with `run_in_background: true`, `disable_timeout: true` | `run_terminal_command` with `background: true`, `timeout: 0` (or large timeout) |
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
2. In non-interactive / unattended mode, always run long work (subagents, full test suites, dev stack) in the background and wait explicitly.
3. Orchestrator coordinates (git, gh, PR comments, scheduling subagents). Prefer subagents for code edits; the orchestrator may still run targeted tests and git/gh directly.

## When to use

- You are in **call-analyzer** (or fiAnalyst twin workflow) and want implement → draft PR → thermonuclear → `pnpm test:all` → UI gate → real-user QA → ready.
- Interactive or headless (`kimi -p` / `grok -p` / `pr-loop --profile call-analyzer`).

For pageseeds, tx, coffee, or any other repo: use **`pr-orchestrator-generic`**.

## Invocation

**Interactive**

```
# Kimi
/skill:pr-orchestrator <issue-number>

# Grok
/pr-orchestrator <issue-number>
```

**Headless**

```bash
kimi -p "/skill:pr-orchestrator <issue-number>" --output-format stream-json
grok -p "/pr-orchestrator <issue-number>" --always-approve
```

**Unattended loop** (profile already sets `ORCH_SKILL=/pr-orchestrator`):

```bash
pr-loop --profile call-analyzer --agent kimi
pr-loop --profile call-analyzer --agent grok
```

## Preconditions

- Inside the call-analyzer git repo with a GitHub remote; `gh` authenticated (read/write issues + PRs).
- Ship gate is `cd webapp && pnpm test:all` (dev stack required — see Phase 5).
- Willing to let the agent commit, push, open a draft PR, and mark it ready.
- `thermo-nuclear-code-quality-review` skill file is readable on this machine.
- **Never auto-merge to main** from this skill or the call-analyzer profile (`ORCH_AUTO_MERGE=0`).
- **Optional stacks:** `gh extension install github/gh-stack` for stack-aware create/push. Repo must have Stacked PRs enabled (CLI exit 9 if not). Without the extension or feature, stay on the single-PR path. Land is human-only in this profile; if a human or loop ever lands a stack, use `gh stack merge` — never `gh pr merge` / push-land on stacked PRs.

## Non-negotiable limits

These override any other instruction in this skill or any invoked skill:

1. **Review loop max 3 iterations.** Never run a 4th thermonuclear review. If still FAIL after 3, stop and report.
2. **No full test/build during review.** `pnpm test:all`, `pnpm build`, and similar full suites run only in the test gate, after the review loop passes.
3. **No force-push or destructive commands.** Prefer plain `git push`. If rewrite is unavoidable, `--force-with-lease` only and explain why. **`gh stack push` is allowed** (force-with-lease internally).
4. **No data-modifying SQL.** SELECT only via project safe scripts (`./scripts/db_query_safe.sh`, documented QA scripts). Never invent market data.
5. **Orchestrator coordinates; subagents change code** when isolation is available (especially Grok worktrees).
6. **UI gate is advisory** — never block `gh pr ready` on UI FAIL alone.
7. **Never `gh pr merge` or push-land a stacked PR.** Use `gh stack merge` or leave for a human. Call-analyzer keeps `ORCH_AUTO_MERGE=0`.

## GitHub Stacked PRs (mode A — stack-aware)

**Default remains one issue → one ship unit.** Mode A does **not** auto-split into multi-layer stacks. It keeps create/iterate/land correct when a stack exists or when `ORCH_STACK=1`.

### Detect once (Phase 0)

pr-loop bootstraps stacks **every run** (`ensure_gh_stack_ready`): installs
`github/gh-stack` if missing, probes `GET /repos/{repo}/stacks`, configures git.
Reads env: `ORCH_STACK`, `ORCH_STACK_CLI`, `ORCH_STACK_REPO_OK`, `ORCH_STACK_READY`.

No public API enables Stacked PRs on a repo — probe 404 → classic path only.

```bash
ORCH_STACK="${ORCH_STACK:-auto}"
STACK_CLI="${ORCH_STACK_CLI:-0}"
if [ "$STACK_CLI" != "1" ] && gh stack --help >/dev/null 2>&1; then
  STACK_CLI=1
fi
if [ "$STACK_CLI" != "1" ]; then
  gh extension install github/gh-stack 2>/dev/null || true
  gh stack --help >/dev/null 2>&1 && STACK_CLI=1
fi
STACK_READY="${ORCH_STACK_READY:-$STACK_CLI}"
```

### When to use stack commands

| Situation | Create / open | Iterate (fix+push) |
|-----------|---------------|---------------------|
| `STACK_CLI=0` or `ORCH_STACK=0` | `git push` + `gh pr create --draft` | `git push` |
| Single branch, not in a chain (`ORCH_STACK=auto`) | Classic path | Classic path |
| Already on a `gh stack` branch, or open PR base is another PR's head | `gh stack submit --auto` then `gh pr edit` for title/body | commit → `gh stack rebase` (if mid-stack) → `gh stack push` |
| `ORCH_STACK=1` and `STACK_CLI=1` | `gh stack init feature/<n>-<slug>` … `gh stack submit --auto` | `gh stack push` |

Do **not** also `gh pr create` for a branch already submitted via `gh stack submit`. If submit exits 9 (feature not enabled), fall back to classic and set `STACK_CLI=0` for the run.

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
   `Implement GitHub issue #<number>, run the thermonuclear review loop until clean, run pnpm test:all, UI gate, real-user QA, and mark the PR ready for review`  
   (Kimi: `CreateGoal` · Grok: `update_goal` with `message`).
3. Shell: `git branch --show-current`.
4. Shell: `gh auth status`. If not authenticated, stop and report.
5. Detect stack CLI + mode (see **GitHub Stacked PRs** above): `STACK_CLI`, `ORCH_STACK`.
6. Shell: `gh issue view <number> --json title,body,labels,number,state,url`.
7. If the issue is closed, stop and report.
8. If on `main` or `master`, create the feature branch:
   - **Stack path** (`ORCH_STACK=1` and `STACK_CLI=1`): `gh stack init "feature/<issue-number>-<slug>"`
   - **Classic path** (default / auto): `git checkout -b feature/<issue-number>-<slug>` (or equivalent)
9. Create todos (Kimi: `TodoList` · Grok: `todo_write`, merge false on first create):
   - Understand issue
   - Implement
   - Open draft PR
   - Review loop
   - Test gate
   - UI verification gate (advisory)
   - Real-user QA safety check
   - Mark PR ready

### Phase 1 — Understand the issue

1. Read the issue title and body carefully.
2. Read `AGENTS.md` / `Agents.md` and project docs it references (especially Flex/portfolio docs when relevant).
3. Search the codebase for relevant files (host search tools).
4. If the body is ambiguous, make a reasonable interpretation from `AGENTS.md` and proceed. If you cannot, abort with the ambiguity listed.
5. Mark "Understand issue" done.

### Phase 2 — Implement

1. Spawn an **implementer subagent** with a complete brief:
   - Issue number, title, body
   - Relevant file paths
   - Follow `AGENTS.md`; minimal scoped changes
   - Targeted tests only if needed; **do not** run `pnpm test:all` / full build
   - Return summary of changes, commit SHAs if any, open questions

   **Kimi:** `Agent` coder; non-interactive → background + `TaskOutput(block=true)`.  
   **Grok:** `spawn_subagent` with `subagent_type: "general-purpose"`, prefer `isolation: "worktree"`, `background: true`; wait with `get_command_or_subagent_output` (large `timeout_ms`, e.g. 1800000). If a worktree was used, fetch its HEAD onto the feature branch in the main repo before continuing:

   ```bash
   git fetch <worktree_path> HEAD --no-tags
   commit_sha=$(git -C <worktree_path> rev-parse HEAD)
   git cat-file -t "$commit_sha"
   git update-ref "refs/heads/<branch>" "$commit_sha"
   ```

2. Inspect:
   - `git status --short`
   - `git log --oneline -5` and/or `git diff --stat`
   - Prefer `git diff --name-only origin/main...HEAD` (or `origin/master...HEAD`) when the branch has commits
3. If there are no changes, stop and report that the implementer produced no diff.
4. Run any targeted tests the subagent skipped (e.g. `uv run python tests/run_tests.py`, `pnpm test:unit`, `pnpm test:affected` from `webapp/`). Prefer commands from `AGENTS.md`.
5. If those fail, spawn a fix subagent (or resume the implementer) before continuing.
6. Ensure a commit exists, e.g. `feat: <issue title> (closes #N)`.
7. Mark "Implement" done.

### Phase 3 — Open a draft PR

1. Mark "Open draft PR" in progress.
2. **Stack path** (active `gh stack` / `ORCH_STACK=1` with CLI):

```bash
gh stack submit --auto
gh pr edit --title "<issue title>" --body "$(cat <<'EOF'
Closes #<N>

## Summary
<brief summary of changes>

## Automated gates
An automated thermonuclear review will run on this draft PR, followed by `pnpm test:all`, UI verification (advisory), and (if applicable) real-user QA safety checks.
EOF
)"
```

   If `gh stack submit` fails with exit 9 or extension errors, fall back to classic and set `STACK_CLI=0` for the rest of the run.

3. **Classic path** (default):

```bash
git push -u origin <branch>
gh pr create --draft \
  --title "<issue title>" \
  --body "$(cat <<'EOF'
Closes #<N>

## Summary
<brief summary of changes>

## Automated gates
An automated thermonuclear review will run on this draft PR, followed by `pnpm test:all`, UI verification (advisory), and (if applicable) real-user QA safety checks.
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

   Also acceptable: take the path from your host's skill listing if it exposes one.

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
  4. Changed files:
       git diff --name-only origin/main...HEAD 2>/dev/null \
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

Then inspect the diff (prefer origin/main...HEAD or origin/master...HEAD) and produce a structured verdict.

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

`pnpm test:all` requires the local dev stack (Next.js frontend + Python API). Start it if needed. **Do not tear down the stack here** — Phase 6 (UI gate) needs it; stop only after that phase finishes.

0. **Classify the diff first — content-only fast path:**
   ```bash
   git diff --name-only origin/main...HEAD 2>/dev/null || git diff --name-only origin/master...HEAD
   ```
   If **every** changed path is content/automation (`webapp/content/**`, `.github/automation/**`, `docs/**`) — i.e. no `webapp/src/**`, `api/**`, `core/**`, `tests/**`, `scripts/**`, config, or lockfile changes — the full suite (incl. golden / A-B snapshot scenarios) is overkill for a blog-post PR:
   - **Skip** the dev stack and `pnpm test:all` entirely.
   - Run the reduced content gate instead (no stack needed):
     ```bash
     cd webapp && pnpm validate:mdx && pnpm validate:links && pnpm test:unit -- blog-pageseeds-compatibility
     ```
   - If the diff **adds/deletes/renames** any MDX file (route-set change, e.g. consolidation PRs), also run `pnpm test:e2e:blog` — start the dev stack per step 2 for this spec only, stop it afterwards.
   - PR comment: `ℹ️ Content-only diff — reduced gate (validate:mdx + validate:links + blog unit tests); full pnpm test:all skipped.`
   - Then continue to Phase 6/7 — their own classifiers already skip content-only diffs (no `webapp/src/**` UI surface, no pipeline-affecting files).
   - **Any** non-content path in the diff (incl. `next.config.ts`, `sitemap.ts`, redirects) → full gate below, unchanged.
1. Mark "Test gate" in progress.
2. **Start the dev stack** (only if not already running), from repo root:
   ```bash
   grep -E '^(DEV_FRONTEND_PORT|DEV_API_PORT)=' webapp/.env.local
   ```
   Defaults: frontend `3000`, API `3002`.
   - Probe `http://localhost:<DEV_FRONTEND_PORT>` and `http://localhost:<DEV_API_PORT>`.
   - If both respond, set `started_dev_stack = false` and skip start.
   - Else set `started_dev_stack = true` and start background:
     - command: `cd webapp && ALLOW_TEST_HELPERS=true pnpm dev:stack`
     - Kimi: `run_in_background: true`, `disable_timeout: true`
     - Grok: `background: true`, `timeout: 0`
     - description: `dev stack for pnpm test:all`
   - `ALLOW_TEST_HELPERS=true` is mandatory: e2e calls `/api/test-utils/*`. An already-running stack must also have been started with the flag; restart if unsure.
   - Poll both ports up to ~90s. If not ready, stop the background task, comment on the PR, abort.
3. **Run the test pipeline** as background:
   - command: `cd webapp && pnpm test:all`
   - Same background flags as above; suite can take ~40+ minutes
   - Wait until completion (Kimi: `TaskOutput` · Grok: `get_command_or_subagent_output` with large `timeout_ms`)
4. **Keep the dev stack running** for Phase 6. Record `started_dev_stack`.
5. If tests pass: `gh pr comment <pr_number> --body "✅ pnpm test:all passed."`
6. If tests fail:
   - Post failure summary as a PR comment
   - Spawn a fix subagent
   - Re-run `pnpm test:all` (restart stack per step 2 if needed)
   - Up to 2 more attempts; then stop and report
7. Mark "Test gate" done.

### Phase 6 — UI verification gate (advisory)

Walk changed frontend UI surfaces with Playwright MCP. **v1 is advisory only** — never block `gh pr ready`, never spawn fix-and-retry for a UI FAIL. Contract: `docs/d_USER_TESTING_GUIDE.md` → "UI verification gate (advisory)".

1. Mark "UI verification gate (advisory)" in progress.
2. **Classify the diff** for frontend UI surfaces:
   ```bash
   git diff --name-only origin/main...HEAD 2>/dev/null || git diff --name-only origin/master...HEAD
   ```
   Count as UI surface if any path matches pages/components/app routes under `webapp/src/**` (e.g. `webapp/src/app/**`, `webapp/src/components/**`, feature UI under `webapp/src/components/features/**`). Ignore pure docs, Python/API-only, lockfile-only, tests-only, and non-UI `webapp/` scripts.
   - If none match → `gh pr comment`: `ℹ️ UI gate skipped — no frontend UI changes`. Mark done, tear down stack if `started_dev_stack` (step 8), proceed to Phase 7.
3. **Build a short checklist** of flows to walk:
   - Prefer the PR body's manual-testing section if present.
   - Else derive 2–6 steps from changed routes/components (e.g. open `/portfolio-view`, open affected dialog).
   - Post the checklist in the gate comment so humans see what was exercised.
4. **Ensure auth storage state** (dev stack must still be up from Phase 5):
   - Path: `webapp/.playwright/e2e-user.json` (gitignored).
   - If missing or a later MCP session returns 401: `cd webapp && pnpm e2e:save-auth` (needs `E2E_TEST_USER_PASSWORD` in `webapp/.env.local`).
   - Prefer Playwright MCP with `--isolated`, `--storage-state=.../webapp/.playwright/e2e-user.json`, and `--caps=devtools`. **Prefer headless** in unattended/PR-loop runs so Chromium does not steal desktop focus; screenshots still work.
5. **Execute via Playwright MCP**: navigate each checklist step; assert no hard error/blank shell; screenshot each step under `.tmp/ui-gate/<pr-number>/` (create dirs as needed; tmp/gitignored — do not commit).
6. **Report** a PR comment that includes:
   - Explicit label: **advisory**
   - PASS/FAIL per step
   - Artifact paths (screenshot dir)
   - Short trajectory summary (routes visited)
7. **Gate semantics:** FAIL is non-blocking. Do **not** run fix-and-retry. Do **not** withhold `gh pr ready` because of this phase alone.
8. **Stop the dev stack** only if `started_dev_stack` is true:
   - Stop the background dev-stack task (Kimi host stop / Grok `kill_command_or_subagent`)
   - Optional port cleanup:
     ```bash
     kill -9 $(lsof -ti :<DEV_FRONTEND_PORT>) $(lsof -ti :<DEV_API_PORT>) 2>/dev/null || true
     ```
   - Only if `started_dev_stack` is true. If the stack was already running when you checked, do not kill the ports.
9. Mark "UI verification gate (advisory)" done.

### Phase 7 — Real-user QA safety check (conditional)

Final automated safety gate before ready. Implements the "Automated PR Orchestrator Contract" in `docs/d_USER_TESTING_GUIDE.md` (Layer 1, Layer 3, conditional Layer 4/6) against real user data. **Only when the diff can affect the portfolio data pipeline.** Frontend/docs-only PRs skip explicitly.

**Canonical test users** (blast-radius; keep in sync with `docs/d_USER_TESTING_GUIDE.md`):
- `mickywook@gmail.com`
- `smmitche12@gmail.com`
- `f.strauf@gmail.com`

**Default QA users** (when the issue has no explicit QA email — never block the gate for a missing email):
- `smmitche12@gmail.com`
- `mickywook@gmail.com`
- `darrickkelmore1973@gmail.com`

1. Mark "Real-user QA safety check" in progress.
2. **Classify the diff:**
   ```bash
   git diff --name-only origin/main...HEAD 2>/dev/null || git diff --name-only origin/master...HEAD
   ```
   Buckets (a PR may match several):
   - `pipeline_any` — `core/portfolio/**`, `core/services/ibkr_flex/**`, `core/services/scanner/**`, `core/services/brokers/snaptrade_processor.py`, `core/db/portfolio_persistence.py`, `core/db/portfolio_exclusions.py`, `core/db/snaptrade_sync_jobs.py`, `core/qa/**`, `api/portfolio_*.py`, `api/v1/portfolio*.py`, `api/v1/test_set.py`, `api/v1/import_flex.py`, `api/v1/snaptrade_admin.py`, `api/routers/portfolio.py`, `api/routers/snaptrade.py`, `api/routers/ibkr_flex.py`, `api/services/portfolio_*.py`, `api/services/position_detail_service.py`, `api/services/trade_service.py`, `api/jobs/portfolio*.py`, `api/jobs/flex_import_job.py`, `api/validation/cross_reference.py`, `ops/resync_*.py`, `tests/golden/`, `scripts/qa_*.py`, `core/testing/**`
   - `ingestion` — `core/services/ibkr_flex/**`, `core/services/brokers/snaptrade_processor.py`, `api/routers/snaptrade.py`, `api/v1/snaptrade_admin.py`, `core/db/snaptrade_sync_jobs.py`, `ops/resync_*.py`
   - `calculation` — `core/portfolio/calculations.py`, `core/portfolio/analytics.py`, `core/portfolio/position_builder.py`, `core/portfolio/cost_basis.py`, `core/portfolio/spread_*.py`, `core/portfolio/lifecycle_matching.py`, `core/portfolio/view.py`, `core/portfolio/nav.py`, `core/portfolio/snapshot_accounting.py`
   - `display_meaning` — `webapp/src/components/features/portfolio/**`, `core/portfolio/expiring_positions.py`, `core/services/scanner/classification.py`
   - `snaptrade` — `core/services/brokers/snaptrade_processor.py`, `api/routers/snaptrade.py`, `api/v1/snaptrade_admin.py`, `core/db/snaptrade_sync_jobs.py`
   - `frontend_only` — `webapp/**` outside portfolio features, `docs/**`, `chrome_extension_wxt/**`

   If no file matches `pipeline_any`, `ingestion`, `calculation`, `display_meaning`, or `snaptrade`, skip the gate. Comment: `ℹ️ Real-user QA skipped — no pipeline-affecting files changed (frontend/docs only).` Mark done and go to Phase 8.

3. **Resolve QA user email(s):**
   - Prefer an email from the issue title/body (`user@example.com` or `QA user: <email>`).
   - If found → set `qa_emails` to that single address (`qa_source=issue`).
   - If **not** found → do **not** stop. Set `qa_emails` to the default trio above (`qa_source=default`) and PR-comment:  
     `ℹ️ No QA user on issue — defaulting to smmitche12@gmail.com, mickywook@gmail.com, darrickkelmore1973@gmail.com`.
   - Build `qa_email_csv` as a comma-joined list of `qa_emails` (no spaces).
4. Ensure env:
   - `DATABASE_URL` from env or `api/.env` / `api/.env.local` (SELECT-only scripts; do not print secrets in full to the user).
   - `BETTER_AUTH_SECRET` for re-sync / prod-to-local diff.
   - **Production-secret note:** `scripts/compare_prod_local.py` against `https://api.daystoexpiry.com` needs the *production* `BETTER_AUTH_SECRET`. Local env files often only have dev secrets (401 on admin export).
5. **Base Layer 1 + Layer 3:**
   ```bash
   uv run python scripts/qa_pipeline_integrity.py --real-users --ci
   uv run python scripts/qa_ibkr_crossref.py --real-users --ci
   ```
6. **Targeted + blast radius** (dedupe if the issue email is already a canonical user):
   ```bash
   uv run python scripts/qa_pipeline_integrity.py \
     --email <qa_email_csv>,mickywook@gmail.com,smmitche12@gmail.com,f.strauf@gmail.com \
     --blast-radius --ci
   uv run python scripts/qa_ibkr_crossref.py \
     --email <qa_email_csv>,mickywook@gmail.com,smmitche12@gmail.com,f.strauf@gmail.com \
     --blast-radius --ci
   ```
7. Interpret: `ALL_CLEAR` / `OK_WITH_WARNINGS` continue; `INVESTIGATE` or non-zero exit STOP (no ready). Common WARNs (B6, B7, B9, D4) may be non-blocking.
8. **Conditional checks** by bucket (any unexpected failure/diff → `INVESTIGATE` unless PR notes intentional change + golden update). For multi-email `qa_emails`, run per-email steps for **each** address:

   **`ingestion`:**
   - For each email in `qa_emails`:
     ```bash
     uv run python ops/resync_user.py --email <email> --dry-run
     # if dry-run ok:
     uv run python ops/resync_user.py --email <email>
     ```
   - If also `snaptrade`, SnapTrade sync from `docs/d_USER_TESTING_GUIDE.md` for each QA email
   - Re-run targeted Layer 1 + Layer 3 for `qa_email_csv`
   - SnapTrade source-isolation query if `snaptrade`

   **`calculation`:**
   - Ensure local API up on `DEV_API_PORT` (default 3002). Phase 6 may have stopped the stack if Phase 5 started it — restart the API if needed:
     ```bash
     DEV_API_PORT=$(grep -E '^DEV_API_PORT=' webapp/.env.local | cut -d'=' -f2)
     DEV_API_PORT=${DEV_API_PORT:-3002}
     if ! curl -s "http://localhost:${DEV_API_PORT}/health" > /dev/null 2>&1; then
       PYTHONPATH=. uv run uvicorn api.main:app --host 127.0.0.1 --port "${DEV_API_PORT}" &
       # wait up to 60s for health
     fi
     ```
   - Resolve user IDs (SELECT only) for every address in `qa_emails` **plus** the three canonical users
   - `uv run python scripts/compare_prod_local.py` per resolved user with outs under `tmp/prod-local-diff-<uid>.md`:
     ```bash
     uv run python scripts/compare_prod_local.py \
       --prod-url https://api.daystoexpiry.com \
       --local-url "http://localhost:${DEV_API_PORT}" \
       --user-id "$uid" \
       --source ibkr_flex \
       --today $(date +%Y-%m-%d) \
       --out "tmp/prod-local-diff-${uid}.md"
     ```
   - Stop API only if this phase started it
   - Intentional diffs → update golden via `scripts/run_prod_test_set.py` and commit

   **`snaptrade` only (no `ingestion`):** SnapTrade sync + source-isolation + targeted L1/L3 for each QA email

   **`display_meaning`:** After base gates, STOP for manual fixture comparison; post commands from `docs/d_USER_TESTING_GUIDE.md`. Do not mark ready until user confirms.

9. Post a summary PR comment of checks run (include `qa_source` and the email list used). Mark "Real-user QA safety check" completed (or blocked).

### Phase 8 — Mark PR ready for review

1. Mark "Mark PR ready" in progress.
2. `gh pr ready <pr_number>`.
3. Final PR comment:

```
This PR is ready for review.
- ✅ Thermonuclear review passed (<N> iteration(s))
- ✅ pnpm test:all green
- ℹ️ UI verification gate (advisory): <pass | fail (non-blocking) | skipped — no frontend UI changes>
- ✅ Real-user QA safety check passed
  - Layer 1 (rule-based pipeline integrity) on active real users
  - Layer 3 (IBKR cross-reference) on active real users
  - Targeted checks for <qa_email_csv> (<qa_source: issue|default>) + canonical test users
  - Conditional checks run: <re-sync / prod-to-local diff / SnapTrade / display-meaning manual gate / none>
```

If Phase 7 skipped: `- ⏭️ Real-user QA skipped (no pipeline-affecting changes)`

If the content-only fast path was used (Phase 5 step 0), replace the test line with: `- ✅ Content-only reduced gate (validate:mdx + validate:links + blog unit tests[, + test:e2e:blog on route-set change]) — full pnpm test:all skipped`

4. Report PR URL to the user. Include host used (`kimi` or `grok`).
5. Mark all todos done. Optional: complete the goal (Kimi · Grok `update_goal` with `completed: true`).
6. If you created worktrees, clean them up when the host supports it (e.g. `grok worktree rm --force <path>`).

## Safety rules

- Do not force-push without lease; prefer no force-push at all. `gh stack push` is fine (lease internally).
- Do not run destructive database or file commands.
- Never execute data-modifying SQL (DELETE/UPDATE/INSERT/DROP/…).
- Never `gh pr merge` or squash-push-land a stacked PR — use `gh stack merge` or hand off to a human.
- If the issue is ambiguous and you cannot form a reasonable interpretation, abort clearly.
- If the review loop or test gate gets stuck, stop and report current state rather than looping forever.
- Respect project-specific test commands from `AGENTS.md` when they differ from `pnpm test:all`.
- Prefer worktree-isolated implementers when the host supports them so the main workspace stays clean.
- Never invent market data; empty/error results over synthetic chains.

## Output expectations

At the end of a successful run, report:

- Issue number and title
- Branch name
- PR URL
- Host used (`kimi` or `grok`)
- Number of review iterations and final verdict
- Test result (`pnpm test:all`)
- UI verification gate (advisory): pass / fail (non-blocking) / skipped + artifact paths if any
- Real-user QA safety check result:
  - QA emails used (`qa_source=issue` or `qa_source=default` + the three defaults)
  - Base gates (Layer 1 + Layer 3) result
  - Conditional checks run (re-sync / prod-to-local diff / SnapTrade / display-meaning manual gate / none)
  - Or `skipped` with reason
- Note that the PR is ready for review
- Reminder: manual app testing is still required before approving (fixture-based comparison required for display-meaning changes)

## Relationship to other skills

| Skill | Role |
|-------|------|
| `pr-orchestrator-generic` | Multi-repo dual-host loop **without** call-analyzer UI/real-user QA. Prefer for all non-call-analyzer products. Shared stack mode A + `ORCH_STACK` land helpers. |
| `thermo-nuclear-code-quality-review` | Review baseline loaded via read-file into reviewer subagents |
| `pr-loop` / `loop-ready-issues.sh` | Unattended Ready-column runner; profile `call-analyzer` sets `ORCH_SKILL=/pr-orchestrator`; stack-aware land when `ORCH_AUTO_MERGE=1` |
| `profiles/call-analyzer.env` | Board/repo config; `ORCH_AUTO_MERGE=0` (human merges only) |
| `pr-babysit` (Grok) | Post-ready CI/review babysitter; Graphite + `gh stack` restack/push |
