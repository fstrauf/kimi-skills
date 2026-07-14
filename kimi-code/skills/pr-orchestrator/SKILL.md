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

`pnpm test:all` requires the local dev stack (Next.js frontend + Python API) to be running. This phase starts it, runs the tests, and then stops it.

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
4. **Stop the dev stack** if we started it:
   - Use `TaskStop` on the dev-stack background task.
   - Run a port cleanup command to ensure no stray processes remain:
     ```bash
     kill -9 $(lsof -ti :<DEV_FRONTEND_PORT>) $(lsof -ti :<DEV_API_PORT>) 2>/dev/null || true
     ```
   - Only run the port cleanup if `started_dev_stack` is `true`. If the stack was already running when you checked, do not kill the ports.
5. If tests pass, post a comment: `gh pr comment <pr_number> --body "✅ pnpm test:all passed."`
6. If tests fail:
   - Post the failure summary as a PR comment.
   - Spawn a coder subagent to fix the failures.
   - Re-run `pnpm test:all` the same way as step 3 (background task; restart the dev stack per step 2 if needed).
   - Repeat up to 2 more times. If still failing, stop and report the failures to the user.
7. Mark "Test gate" done.

### Phase 6 — Real-user QA safety check (conditional)

This is the final automated safety gate before the PR is considered ready. It runs the rule-based pipeline integrity checks from `docs/d_USER_TESTING_GUIDE.md` against real user data. **The gate only applies when the diff can affect the portfolio data pipeline.** On frontend/docs-only PRs, stopping with "no QA email found" is noise — skip the gate explicitly instead.

1. Update `TodoList`: mark "Test gate" done, "Real-user QA safety check" in-progress.
2. **Classify the diff.** List changed files and check whether any can affect the portfolio data pipeline:
   ```bash
   git diff --name-only origin/main...HEAD 2>/dev/null || git diff --name-only origin/master...HEAD
   ```
   Pipeline-affecting paths: `core/`, `api/`, `ops/`, `tests/golden/`, `scripts/qa_pipeline_integrity.py`. Everything else (webapp UI, docs, chrome extension) is not. When in doubt, treat as pipeline-affecting.
3. **If no pipeline-affecting files changed:** skip the gate. Post a PR comment: `ℹ️ Real-user QA skipped — no pipeline-affecting files changed (frontend/docs only).` Mark "Real-user QA safety check" done and proceed to Phase 7.
4. **If pipeline-affecting files changed, extract the QA user email from the original GitHub issue.** Search the issue title and body for an email address (e.g. `user@example.com` or a `QA user: <email>` line — the scoping workflow adds one for pipeline tickets).
5. If no email is found, STOP and report: "Pipeline-affecting changes but no QA user email found in issue #<number>. Add a line `QA user: <email>` to the issue body and re-run." Do not mark the PR ready.
6. Ensure `DATABASE_URL` is available. If it is not set in the environment, load it from `api/.env`:
   ```bash
   export DATABASE_URL=$(grep DATABASE_URL api/.env | cut -d'"' -f2)
   ```
7. Run the pipeline integrity checks for Tier 1 (key) users:
   ```bash
   uv run python scripts/qa_pipeline_integrity.py --tier 1 --business-logic-only --ci
   ```
8. Run the pipeline integrity check for the user specified in the issue:
   ```bash
   uv run python scripts/qa_pipeline_integrity.py --email <extracted-email> --business-logic-only --ci
   ```
9. **Interpret the results** based on `docs/d_USER_TESTING_GUIDE.md`:
   - `ALL_CLEAR`: all checks passed. Continue.
   - `OK_WITH_WARNINGS`: only WARNs, no FAILs. Continue, but post the warnings to the PR as a non-blocking note.
   - `INVESTIGATE`: at least one FAIL. STOP. Do not mark the PR ready. Post the failures to the PR and report to the user.
10. Common expected WARNs (B6, B7, B9, D4) may appear in `OK_WITH_WARNINGS`. Do not treat these as blockers unless they are new or extreme.
11. If any check exits non-zero, treat it as `INVESTIGATE` and stop.
12. Mark "Real-user QA safety check" done.

### Phase 7 — Mark PR ready for review

1. Update `TodoList`: mark "Mark PR ready" in-progress.
2. Run `gh pr ready <pr_number>`.
3. Post a final comment summarizing all gates — use the QA line matching how Phase 6 ended:
   ```
   This PR is ready for review.
   - ✅ Thermonuclear review passed
   - ✅ pnpm test:all green
   - ✅ Real-user QA safety check passed (Tier 1 + <extracted-email>)
   ```
   If Phase 6 was skipped, replace the last line with: `- ⏭️ Real-user QA skipped (no pipeline-affecting changes)`
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
- Real-user QA safety check result (including the user email extracted from the issue) — or `skipped` with the reason when the diff had no pipeline-affecting files
- Note that the PR is now ready for review
- Reminder: manual app testing is still required before approving the PR
