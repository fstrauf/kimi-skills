---
name: pr-orchestrator
description: Orchestrate the full shipping loop for a GitHub issue — implement, open a draft PR, run thermonuclear review via PR comments, fix findings, run tests, and mark the PR ready for review.
---

# PR Orchestrator

Drive a GitHub issue from assignment through implementation, automated thermonuclear review, test gating, and PR creation. The review handover happens on a GitHub draft PR so every finding and fix is traceable.

## When to use

Use this skill when:
- You have a GitHub issue you want to implement and ship.
- You want the agent to run the implementation → draft PR → thermonuclear review → fix loop → tests → mark ready workflow automatically.

This skill works in both interactive sessions and non-interactive (`kimi -p`) mode. In non-interactive mode the entire workflow runs as one autonomous turn; use background tasks for long-running subagents and tests so the turn can wait for them.

## Invocation

Inside an interactive Kimi session:

```
/skill:pr-orchestrator <issue-number>
```

From the shell (fully automated, single turn):

```bash
kimi -p "/skill:pr-orchestrator <issue-number>" --output-format stream-json
```

Example: `/skill:pr-orchestrator 492`

## Required tools

This skill uses Kimi Code CLI's built-in tools:
- `Bash` for git, GitHub CLI (`gh`), and test commands
- `Agent` for isolated implementation and review-fix subtasks
- `Read` to load the `thermo-nuclear-code-quality-review` baseline from its skill file (subagents have no `Skill` tool — see Phase 4)
- `TodoList` to track progress
- `TaskOutput` to wait for background tasks

## Preconditions

- You are inside a git repository with a remote on GitHub.
- `gh` CLI is authenticated and can read/write issues and PRs.
- The repository has `pnpm test:all` as the canonical pre-ship verification command (adjust if the project uses something else).
- You are willing to let the agent commit, push, open a draft PR, and mark it ready for review.
- For non-interactive runs, long operations (subagents, `pnpm test:all`) should run as background tasks so `kimi -p` can wait for them.

## Non-negotiable limits

These limits override any other instruction in this skill or any invoked skill:

1. **Review loop max 3 iterations.** You must never run a 4th thermonuclear review. If the code still has actionable findings after 3 iterations, stop and report to the user.
2. **No full test/build during review.** `pnpm test:all`, `pnpm build`, and similar full suites run only in the test gate, after the review loop passes.
3. **No force-push or destructive commands.**

## Workflow

### Phase 0 — Lock context

1. Read the skill argument to get the issue number.
2. Call `CreateGoal` with the objective: `Implement GitHub issue #<number>, run the thermonuclear review loop until clean, run pnpm test:all, and mark the PR ready for review`.
3. Run `git branch --show-current` to confirm the current branch.
4. Run `gh issue view <number> --json title,body,labels,number,state,url`.
5. If the issue is closed, stop and report it.
6. If you are on `main` or `master`, create a feature branch named `feature/<issue-number>-<slug>` where `<slug>` is a short kebab-case version of the issue title.
7. Create a `TodoList`:
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
2. Read `AGENTS.md` and any project-specific docs referenced there.
3. Use `Grep` and `Glob` to locate relevant files.
4. If the issue body is ambiguous or contradicts project conventions, make a reasonable interpretation based on `AGENTS.md` and project conventions, then proceed. If you cannot form a reasonable interpretation, abort with a clear error message listing the ambiguity.

### Phase 2 — Implement

1. Spawn a **coder subagent** with a complete brief:
   - Include the issue number, title, and body.
   - Include the relevant file paths you found.
   - Instruct it to follow `AGENTS.md`, make minimal scoped changes, and not to run the full `pnpm test:all` suite.
   - Example prompt: `Implement GitHub issue #N: "<title>". Body: <body>. Relevant files: <paths>. Follow AGENTS.md. Make minimal, correct changes. Run only targeted tests if needed. Do not run pnpm test:all, pnpm build, or any full test/build suite. Return a summary of changes and any open questions.`
   - In non-interactive mode, run the subagent in the background (`run_in_background=true`) and wait for it with `TaskOutput(block=true)`.
2. When the subagent returns, inspect the working tree:
   - `git status --short`
   - `git diff --stat`
   - `git diff --name-only`
3. If there are no changes, stop and report that the implementation subagent produced no diff.
4. Run any targeted tests the subagent did not run (e.g. `uv run python tests/run_tests.py` for Python changes, or `pnpm test:unit` for frontend changes).
5. If targeted tests fail, spawn a coder subagent to fix them before continuing.
6. Commit the implementation with a message like: `feat: <issue title> (closes #N)`.

### Phase 3 — Open a draft PR

1. Update `TodoList`: mark "Implement" done, "Open draft PR" in-progress.
2. Push the branch: `git push -u origin <branch>`.
3. Create a draft PR with `gh pr create --draft`. Use:
   - Title: the issue title (or a concise version)
   - Body: include `Closes #N`, a brief summary of changes, and a note that an automated thermonuclear review will be run.
4. Capture the PR number from the output (e.g. from `gh pr view --json number` or by parsing the PR URL).
5. Update `TodoList`: mark "Open draft PR" done.

### Phase 4 — Review loop via PR comments (max 3 iterations)

This phase automates the back-and-forth between implementer and reviewer using the draft PR as the communication channel.

**CRITICAL RULES FOR THIS PHASE:**
- The review loop is **strictly limited to 3 iterations total**. This is a hard limit. You must not run a 4th review under any circumstances.
- Do **not** run `pnpm test:all`, `pnpm build`, or any other full test/build suite during the review loop.
- The only work in this phase is review → post findings → fix → push.
- The test gate happens **only after** the review loop passes.

**Review baseline (resolve once, before iteration 1):**

1. Locate the `thermo-nuclear-code-quality-review` skill in your current skill listing and take its absolute `Path:`. Do not hardcode or guess the path — it varies by skill scope and machine.
2. `Read` that file once yourself to confirm it exists and is readable. If it is missing or unreadable, STOP and report to the user. Never run a degraded review without the baseline.
3. Use this resolved path as `<baseline_path>` in every reviewer subagent prompt below. Reviewer subagents have no `Skill` tool, so they load the baseline by reading the file directly — this always gives them the full, current version of the skill.

**Iteration tracking:**
- Maintain an explicit counter starting at `iteration = 1`.
- After each review-fix cycle, increment the counter.
- Before starting any review, check: `if iteration > 3, STOP immediately` and report to the user.

**Loop body:**

```
Set iteration = 1
Create/overwrite file: ~/.kimi-code/tmp/pr-orchestrator-<issue>-review-iter.txt with content "1"

WHILE true:
  1. Read ~/.kimi-code/tmp/pr-orchestrator-<issue>-review-iter.txt to confirm current iteration N.
  2. If N > 3:
       - STOP immediately.
       - Post PR comment: "🛑 Automated review stopped after 3 iterations. Remaining findings require human triage."
       - Report to user.
  3. Update TodoList to "Review loop (iteration N/3)".
  4. Get changed files: git diff --name-only HEAD~1 (or git diff --name-only if uncommitted).
  5. Spawn reviewer subagent (see prompt below) with iteration=N and the resolved <baseline_path>.
  6. Parse response.
  7. If VERDICT == PASS:
       - Post passing PR comment.
       - Break out of loop.
  8. If VERDICT == FAIL:
       - If N == 3:
           * STOP immediately. Do not spawn a fix subagent.
           * Post PR comment with the iteration-3 findings and a note that the loop has reached its limit.
           * Report to user.
       - Post findings as PR comment with marker <!-- thermonuclear-review-iter-N -->.
       - Spawn coder subagent to fix only those findings.
       - Verify fixes pushed.
       - Compare new findings to previous iteration; if same substantive finding repeats, STOP.
       - Increment iteration and write it to ~/.kimi-code/tmp/pr-orchestrator-<issue>-review-iter.txt.
  9. If the response lacks a `BASELINE: loaded` line or a parseable VERDICT, STOP — a review produced without the baseline is invalid.
```

**Reviewer subagent prompt:**

```
Run a thermo-nuclear code quality review on the current branch changes for draft PR #<pr_number>.

This is review iteration <iteration> of 3. On iteration 3, any remaining actionable findings will cause the loop to stop without further fixes. Be decisive: output PASS if previous findings have been addressed and no new structural blockers exist.

Focus on these files: <comma-separated paths>

You do not have a Skill tool — do NOT attempt to invoke /skill:thermo-nuclear-code-quality-review.
Instead, use the Read tool to read this file IN FULL before inspecting the diff; it is the review baseline you must apply rigorously:
<baseline_path>

If you cannot read that file, respond with exactly `BASELINE: MISSING` and nothing else, then stop.

Then inspect the diff and produce a structured verdict.

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

In non-interactive mode, run the reviewer subagent in the background and wait for it with `TaskOutput(block=true)`.

**When VERDICT is FAIL:**

Post the findings:
```
gh pr comment <pr_number> --body "<!-- thermonuclear-review-iter-<iteration> -->
🧪 Automated thermonuclear review findings (iteration <iteration> of 3):

<paste findings>

Please address the above findings and push updates."
```

Then spawn a coder subagent:
```
Address the thermonuclear review findings on draft PR #<pr_number>.

Read the latest review comments with: gh pr view <pr_number> --comments
Focus on comments marked "<!-- thermonuclear-review-iter-<iteration> -->".

Do not change behavior. Make minimal, structural improvements as requested.
Do NOT run pnpm test:all, pnpm build, or any full test/build suite. Only make the requested code changes.
Commit and push your changes. Return a summary of changes.
```

In non-interactive mode, run this subagent in the background and wait for it.

**Hard stop conditions** — stop the loop immediately, post a comment on the PR, and report to the user:
- `iteration` reaches 4 (i.e. 3 review-fix cycles have completed without PASS).
- `VERDICT == FAIL` on iteration 3.
- The same substantive finding appears in two consecutive iterations.
- The reviewer subagent fails to produce a parseable `VERDICT: PASS|FAIL` line.
- The reviewer response lacks the `BASELINE: loaded` line or reports `BASELINE: MISSING` — the review ran without the baseline and is invalid. Verify the `<baseline_path>` resolves before retrying.

Do not proceed to the test gate without a clean review.

### Phase 5 — Test gate

`pnpm test:all` requires the local dev stack (Next.js frontend + Python API) to be running. This phase starts it (if needed) and runs the tests. **Do not tear down the stack here** — Phase 6 (UI gate) needs it; stop only after that phase finishes.

1. Update `TodoList`: mark "Review loop" done, "Test gate" in-progress.
2. **Start the dev stack** (only if not already running):
   - Read the dev-stack ports from `webapp/.env.local` by running:
     ```bash
     grep -E '^(DEV_FRONTEND_PORT|DEV_API_PORT)=' webapp/.env.local
     ```
     Parse the values. Defaults are `DEV_FRONTEND_PORT=3000` and `DEV_API_PORT=3002`.
   - Check whether the stack is already up by curling:
     - `http://localhost:<DEV_FRONTEND_PORT>`
     - `http://localhost:<DEV_API_PORT>`
   - If both respond, skip starting and record `started_dev_stack = false`.
   - Otherwise, record `started_dev_stack = true` and start it from the `webapp/` directory:
     - `Bash` command: `cd webapp && ALLOW_TEST_HELPERS=true pnpm dev:stack`
     - `run_in_background: true`
     - `disable_timeout: true` — the suite runs ~40 min; the default 600s background timeout would kill the stack mid-run.
     - `description: "dev stack for pnpm test:all"`
   - `ALLOW_TEST_HELPERS=true` is mandatory: the e2e suite calls `/api/test-utils/*` routes, which refuse to run without it (checked in the dev server process — an already-running stack must also have been started with the flag; restart it if unsure).
   - Wait for the stack to be ready:
     - Poll both ports until they respond, up to 90 seconds.
     - If they do not become ready, stop the background task, post a failure comment, and abort.
3. **Run the test pipeline**:
   - Always run it as a background `Bash` task: `cd webapp && pnpm test:all`, with `run_in_background: true`, `disable_timeout: true`, and `description: "pnpm test:all"`. (Foreground `Bash` caps at 300s; the suite takes ~40 min.)
   - In non-interactive mode, wait for it with `TaskOutput(block=true)`. In interactive mode, tell the user the suite is running in the background and wait for the completion notification.
4. **Keep the dev stack running** for Phase 6. Record `started_dev_stack` so Phase 6 can stop it after the UI gate if this phase started it.
5. If tests pass, post a comment: `gh pr comment <pr_number> --body "✅ pnpm test:all passed."`
6. If tests fail:
   - Post the failure summary as a PR comment.
   - Spawn a coder subagent to fix the failures.
   - Re-run `pnpm test:all` the same way as step 3 (background task; restart the dev stack per step 2 if needed).
   - Repeat up to 2 more times. If still failing, stop and report the failures to the user.
7. Mark "Test gate" done.

### Phase 6 — UI verification gate (advisory)

Walk changed frontend UI surfaces with Playwright MCP. **v1 is advisory only** — never block `gh pr ready`, never spawn fix-and-retry for a UI FAIL. Contract: `docs/d_USER_TESTING_GUIDE.md` → "UI verification gate (advisory)".

1. Update `TodoList`: mark "Test gate" done, "UI verification gate (advisory)" in-progress.
2. **Classify the diff** for frontend UI surfaces:
   ```bash
   git diff --name-only origin/main...HEAD 2>/dev/null || git diff --name-only origin/master...HEAD
   ```
   Count as UI surface if any path matches pages/components/app routes under `webapp/src/**` (e.g. `webapp/src/app/**`, `webapp/src/components/**`, feature UI under `webapp/src/components/features/**`). Ignore pure docs, Python/API-only, lockfile-only, tests-only, and non-UI `webapp/` scripts.
   - If none match → `gh pr comment`: `ℹ️ UI gate skipped — no frontend UI changes`. Mark "UI verification gate (advisory)" done, tear down stack if `started_dev_stack` (step 8), proceed to Phase 7.
3. **Build a short checklist** of flows to walk:
   - Prefer the PR body's manual-testing section if present.
   - Else derive 2–6 steps from changed routes/components (e.g. open `/portfolio-view`, open affected dialog).
   - Post the checklist in the gate comment so humans see what was exercised.
4. **Ensure auth storage state** (dev stack must still be up from Phase 5):
   - Path: `webapp/.playwright/e2e-user.json` (gitignored).
   - If missing or a later MCP session returns 401: `cd webapp && pnpm e2e:save-auth` (needs `E2E_TEST_USER_PASSWORD` in `webapp/.env.local`).
   - Playwright MCP is registered with `--isolated` (mandatory — the default persistent profile applies `--storage-state` only to a fresh profile, silently ignoring refreshes), `--storage-state=.../webapp/.playwright/e2e-user.json`, and `--caps=devtools`.
5. **Execute via Playwright MCP**: navigate each checklist step; assert no hard error/blank shell; screenshot each step under `.tmp/ui-gate/<pr-number>/` (create dirs as needed; tmp/gitignored — do not commit).
6. **Report** a PR comment that includes:
   - Explicit label: **advisory**
   - PASS/FAIL per step
   - Artifact paths (screenshot dir)
   - Short trajectory summary (routes visited)
7. **Gate semantics:** FAIL is non-blocking. Do **not** run fix-and-retry. Do **not** withhold `gh pr ready` because of this phase alone.
8. **Stop the dev stack** if we started it (`started_dev_stack` is `true`):
   - Use `TaskStop` on the dev-stack background task.
   - Run a port cleanup command to ensure no stray processes remain:
     ```bash
     kill -9 $(lsof -ti :<DEV_FRONTEND_PORT>) $(lsof -ti :<DEV_API_PORT>) 2>/dev/null || true
     ```
   - Only run the port cleanup if `started_dev_stack` is `true`. If the stack was already running when you checked, do not kill the ports.
9. Mark "UI verification gate (advisory)" done.

### Phase 7 — Real-user QA safety check (conditional)

This is the final automated safety gate before the PR is considered ready. It implements the "Automated PR Orchestrator Contract" in `docs/d_USER_TESTING_GUIDE.md` by running Layer 1 (rule-based), Layer 3 (IBKR cross-reference), and conditional Layer 4/6 checks against real user data. **The gate only applies when the diff can affect the portfolio data pipeline.** On frontend/docs-only PRs, skip the gate explicitly.

**Canonical test users** (hardcoded here; must stay in sync with `docs/d_USER_TESTING_GUIDE.md`):
- `mickywook@gmail.com`
- `smmitche12@gmail.com`
- `f.strauf@gmail.com`

1. Update `TodoList`: mark "UI verification gate (advisory)" done, "Real-user QA safety check" in-progress.
2. **Classify the diff.** List changed files:
   ```bash
   git diff --name-only origin/main...HEAD 2>/dev/null || git diff --name-only origin/master...HEAD
   ```
   Categorize each file into at most one of these buckets (a single PR may match several buckets):
   - `pipeline_any` — `core/portfolio/**`, `core/services/ibkr_flex/**`, `core/services/scanner/**`, `core/services/brokers/snaptrade_processor.py`, `core/db/portfolio_persistence.py`, `core/db/portfolio_exclusions.py`, `core/db/snaptrade_sync_jobs.py`, `core/qa/**`, `api/portfolio_*.py`, `api/v1/portfolio*.py`, `api/v1/test_set.py`, `api/v1/import_flex.py`, `api/v1/snaptrade_admin.py`, `api/routers/portfolio.py`, `api/routers/snaptrade.py`, `api/routers/ibkr_flex.py`, `api/services/portfolio_*.py`, `api/services/position_detail_service.py`, `api/services/trade_service.py`, `api/jobs/portfolio*.py`, `api/jobs/flex_import_job.py`, `api/validation/cross_reference.py`, `ops/resync_*.py`, `tests/golden/`, `scripts/qa_*.py`, `core/testing/**`
   - `ingestion` — `core/services/ibkr_flex/**`, `core/services/brokers/snaptrade_processor.py`, `api/routers/snaptrade.py`, `api/v1/snaptrade_admin.py`, `core/db/snaptrade_sync_jobs.py`, `ops/resync_*.py`
   - `calculation` — `core/portfolio/calculations.py`, `core/portfolio/analytics.py`, `core/portfolio/position_builder.py`, `core/portfolio/cost_basis.py`, `core/portfolio/spread_*.py`, `core/portfolio/lifecycle_matching.py`, `core/portfolio/view.py`, `core/portfolio/nav.py`, `core/portfolio/snapshot_accounting.py`
   - `display_meaning` — `webapp/src/components/features/portfolio/**`, `core/portfolio/expiring_positions.py`, `core/services/scanner/classification.py`
   - `snaptrade` — `core/services/brokers/snaptrade_processor.py`, `api/routers/snaptrade.py`, `api/v1/snaptrade_admin.py`, `core/db/snaptrade_sync_jobs.py`
   - `frontend_only` — `webapp/**` outside portfolio features, `docs/**`, `chrome_extension_wxt/**`
   If no file matches `pipeline_any`, `ingestion`, `calculation`, `display_meaning`, or `snaptrade`, skip the gate. Post a PR comment: `ℹ️ Real-user QA skipped — no pipeline-affecting files changed (frontend/docs only).` Mark "Real-user QA safety check" done and proceed to Phase 8.
3. **Extract the QA user email from the original GitHub issue.** Search the issue title and body for an email address (e.g. `user@example.com` or a `QA user: <email>` line — the scoping workflow adds one for pipeline tickets).
4. If no email is found, STOP and report: "Pipeline-affecting changes but no QA user email found in issue #<number>. Add a line `QA user: <email>` to the issue body and re-run." Do not mark the PR ready.
5. Ensure required environment variables are available:
   - `DATABASE_URL`: if not set, load from `api/.env`:
     ```bash
     export DATABASE_URL=$(grep DATABASE_URL api/.env | cut -d'"' -f2)
     ```
   - `BETTER_AUTH_SECRET`: required for re-sync and prod-to-local diff. If not set, load from `api/.env`:
     ```bash
     export BETTER_AUTH_SECRET=$(grep BETTER_AUTH_SECRET api/.env | cut -d'"' -f2)
     ```
     If still missing, STOP and report.
   - **Production-secret note:** For `scripts/compare_prod_local.py` calls against `https://api.daystoexpiry.com`, the `BETTER_AUTH_SECRET` must be the *production* secret. `api/.env` and `api/.env.local` usually contain local/dev secrets, which cause the admin export endpoint to return 401. Ensure the production secret is present in the environment before running this conditional check.
6. **Run the base Layer 1 + Layer 3 gates on active real users.** These are the checks documented in `docs/d_QA_DATA_QUALITY.md` Layer 6:
   ```bash
   uv run python scripts/qa_pipeline_integrity.py --real-users --ci
   uv run python scripts/qa_ibkr_crossref.py --real-users --ci
   ```
7. **Run targeted checks for the issue QA user + canonical test users.** Use `--blast-radius` so Tier 1 users are also covered:
   ```bash
   uv run python scripts/qa_pipeline_integrity.py \
     --email <extracted-email>,mickywook@gmail.com,smmitche12@gmail.com,f.strauf@gmail.com \
     --blast-radius --ci
   uv run python scripts/qa_ibkr_crossref.py \
     --email <extracted-email>,mickywook@gmail.com,smmitche12@gmail.com,f.strauf@gmail.com \
     --blast-radius --ci
   ```
8. **Interpret base-gate results** based on `docs/d_USER_TESTING_GUIDE.md`:
   - `ALL_CLEAR`: all checks passed. Continue.
   - `OK_WITH_WARNINGS`: only WARNs, no FAILs. Continue, but post the warning summary to the PR as a non-blocking note.
   - `INVESTIGATE`: at least one FAIL. STOP. Do not mark the PR ready. Post the failures to the PR and report to the user.
   Common expected WARNs (B6, B7, B9, D4) may appear in `OK_WITH_WARNINGS`. Do not treat these as blockers unless they are new or extreme. If any check exits non-zero, treat it as `INVESTIGATE` and stop.
9. **Run conditional checks based on change type.** Only run the checks that match the diff classification. Any non-zero exit or unexpected diff is treated as `INVESTIGATE` unless the PR explicitly notes the change is intentional and a golden snapshot is updated.

   **If `ingestion` is matched:**
   - Dry-run re-sync for the QA user:
     ```bash
     uv run python ops/resync_user.py --email <extracted-email> --dry-run
     ```
   - If dry-run succeeds, run the live re-sync:
     ```bash
     uv run python ops/resync_user.py --email <extracted-email>
     ```
   - If `snaptrade` is also matched, run the SnapTrade sync curl from `docs/d_USER_TESTING_GUIDE.md` for the QA user.
   - Re-run the targeted Layer 1 + Layer 3 checks for the QA user:
     ```bash
     uv run python scripts/qa_pipeline_integrity.py --email <extracted-email> --ci
     uv run python scripts/qa_ibkr_crossref.py --email <extracted-email> --ci
     ```
   - If `snaptrade` is matched, run the SnapTrade source-isolation query from `docs/d_USER_TESTING_GUIDE.md`.

   **If `calculation` is matched:**
   - Determine the local API port from `webapp/.env.local`:
     ```bash
     DEV_API_PORT=$(grep -E '^DEV_API_PORT=' webapp/.env.local | cut -d'=' -f2)
     DEV_API_PORT=${DEV_API_PORT:-3002}
     ```
   - Ensure the local Python API is running on that port. Phase 6 may have stopped the stack if Phase 5 started it — restart the API if needed. Check health:
     ```bash
     if ! curl -s "http://localhost:${DEV_API_PORT}/health" > /dev/null 2>&1; then
       PYTHONPATH=. uv run uvicorn api.main:app --host 127.0.0.1 --port "${DEV_API_PORT}" &
       API_PID=$!
       # Wait up to 60 seconds for the API to be ready
       for i in {1..30}; do
         if curl -s "http://localhost:${DEV_API_PORT}/health" > /dev/null 2>&1; then
           break
         fi
         sleep 2
       done
     fi
     ```
     Record whether the API was started in this step so it can be stopped afterwards.
   - Resolve user IDs for the QA user and canonical test users:
     ```bash
     user_id_for() {
       uv run python - "$1" <<'PY'
     import sys
     from core.db import get_db
     email = sys.argv[1]
     with get_db() as conn:
         rows = conn.run("SELECT id FROM options.users WHERE email = :email", email=email)
         print(rows[0][0] if rows else "")
     PY
     }
     QA_USER_ID=$(user_id_for <extracted-email>)
     USER_MICKY=$(user_id_for mickywook@gmail.com)
     USER_STEVE=$(user_id_for smmitche12@gmail.com)
     USER_FLORIAN=$(user_id_for f.strauf@gmail.com)
     ```
   - Run prod-to-local diff for each resolved user (skip any whose user ID could not be resolved):
     ```bash
     for uid in "$QA_USER_ID" "$USER_MICKY" "$USER_STEVE" "$USER_FLORIAN"; do
       [ -n "$uid" ] || continue
       uv run python scripts/compare_prod_local.py \
         --prod-url https://api.daystoexpiry.com \
         --local-url "http://localhost:${DEV_API_PORT}" \
         --user-id "$uid" \
         --source ibkr_flex \
         --today $(date +%Y-%m-%d) \
         --out "tmp/prod-local-diff-${uid}.md"
     done
     ```
   - If the API was started in this step, stop it:
     ```bash
     if [ -n "$API_PID" ]; then
       kill "$API_PID" 2>/dev/null || true
     fi
     ```
   - If differences are detected and the PR notes they are intentional, update the relevant golden snapshot for the QA user:
     ```bash
     uv run python scripts/run_prod_test_set.py \
       --prod-url https://api.daystoexpiry.com \
       --user-id "$QA_USER_ID" \
       --source ibkr_flex \
       --today $(date +%Y-%m-%d) \
       --save-test-set tests/golden_snapshots/portfolio_pipeline/<descriptive-name>.json
     ```
     Commit the updated snapshot.

   **If `snaptrade` is matched (and `ingestion` was not):**
   - Run the SnapTrade sync curl from `docs/d_USER_TESTING_GUIDE.md` for the QA user.
   - Run the SnapTrade source-isolation query from `docs/d_USER_TESTING_GUIDE.md`.
   - Run targeted Layer 1 + Layer 3 checks for the QA user.

   **If `display_meaning` is matched:**
   - Do not attempt full automation. STOP after base gates and post a PR comment with the exact fixture-based comparison commands from `docs/d_USER_TESTING_GUIDE.md`:
     ```bash
     cd webapp
     pnpm tsx src/scripts/debug/compare-expiring-positions.ts export-fixture \
       --user-id <USER_ID> --source ibkr_flex --out ../tests/fixtures/portfolio/<feature>-<user>.fixture.json
     # Repeat for 2-3 diverse users, then emit from main and the feature branch, and diff.
     ```
   - Do not mark the PR ready until the user confirms the manual comparison is complete.
10. Post a summary PR comment listing which conditional checks ran and their results. If any conditional check produced a diff or failure, attach the report file (e.g. `tmp/prod-local-diff-<email>.md`) to the comment or paste the summary.
11. Mark "Real-user QA safety check" done.

### Phase 8 — Mark PR ready for review

1. Update `TodoList`: mark "Mark PR ready" in-progress.
2. Run `gh pr ready <pr_number>`.
3. Post a final comment summarizing all gates — use the QA block matching how Phase 7 ended:
   ```
   This PR is ready for review.
   - ✅ Thermonuclear review passed
   - ✅ pnpm test:all green
   - ℹ️ UI verification gate (advisory): <pass | fail (non-blocking) | skipped — no frontend UI changes>
   - ✅ Real-user QA safety check passed
     - Layer 1 (rule-based pipeline integrity) on active real users
     - Layer 3 (IBKR cross-reference) on active real users
     - Targeted checks for <extracted-email> + canonical test users
     - Conditional checks run: <re-sync / prod-to-local diff / SnapTrade / display-meaning manual gate / none>
   ```
   If Phase 7 was skipped, replace the QA block with: `- ⏭️ Real-user QA skipped (no pipeline-affecting changes)`
4. Report the PR URL to the user.
5. Mark all todos done.

## Safety rules

- Do not force-push (`git push --force`).
- Do not run destructive database or file commands.
- If the issue is ambiguous and you cannot form a reasonable interpretation, abort with a clear error.
- If the review loop or test gate gets stuck, stop and report the current state rather than looping forever.
- Respect project-specific test commands; use the one from `AGENTS.md` if it differs from `pnpm test:all`.

## Output expectations

At the end of a successful run, report:
- Issue number and title
- Branch name
- Draft PR URL
- Number of review iterations and final verdict
- Test result (`pnpm test:all`)
- UI verification gate (advisory): pass / fail (non-blocking) / skipped + artifact paths if any
- Real-user QA safety check result:
  - User email extracted from the issue
  - Base gates (Layer 1 + Layer 3) result
  - Conditional checks run (re-sync / prod-to-local diff / SnapTrade / display-meaning manual gate / none)
  - Or `skipped` with the reason when the diff had no pipeline-affecting files
- Note that the PR is now ready for review
- Reminder: manual app testing is still required before approving the PR (fixture-based comparison is required for display-meaning changes)
