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

**Labels and handover:** [docs/github-loop.md](../../../docs/github-loop.md).

## Phases 0–4 — follow generic

Read **this file in full first**, then read sibling `../pr-orchestrator-generic/SKILL.md` in full and execute its Phases 0–4 (host map, implement, draft PR, thermonuclear ×3, stack rules).

Call-analyzer extras on top of generic:

- **Never auto-merge** (`ORCH_AUTO_MERGE=0` on this profile). Land is human / `gh stack merge`.
- **No data-modifying SQL.** SELECT only via project safe scripts. Never invent market data.
- **UI gate is advisory** — never block `gh pr ready` on UI FAIL alone.
- Todos must also include: UI verification gate (advisory) · Real-user QA safety check.
- Ambiguity: `+needs-input` and exit 0 (same as generic). Do not abort the fleet.

Invocation: `/pr-orchestrator <N>` or `pr-loop --profile call-analyzer --agent grok`.

After generic Phase 4 PASS, continue here. Do **not** enter Phase 5 without a clean review PASS.

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
- If the issue needs a human decision (product/legal/budget only), `+needs-input` and exit 0.
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
| `ship-loop` / `pr-loop` | Unattended runners; profile `call-analyzer` sets `ORCH_SKILL=/pr-orchestrator` |
| `profiles/call-analyzer.env` | Board/repo config; `ORCH_AUTO_MERGE=0` (human merges only) |
| `pr-babysit` (Grok) | Post-ready CI/review babysitter; Graphite + `gh stack` restack/push |
| `docs/github-loop.md` | **SSOT** for REST labels and supervisor handover |
