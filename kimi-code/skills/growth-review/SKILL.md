---
name: growth-review
description: |
  Recurring growth review for any repo that has `.github/automation/growth_review.yaml`
  (today: call-analyzer / daystoexpiry.com, nz-coffee-hub / brewedlate.com). Pulls
  north-star deltas (GSC via pageseeds-cli, PostHog, optional read-only DB), runs a free-flow
  "where are we not serving / not converting" desk, grades open hypotheses, decides ≤3 bets,
  files tickets, and appends the entry to the project's GitHub growth ledger issue (body =
  live summary, comments = history). Use when the user runs /growth-review, says
  "growth review", "weekly growth", "revenue check", "how is conversion", "grade the bets",
  "how is the SEO/traffic program going", or the pageseeds operator-runs scheduler fires
  workspace_cmd:growth-review.
metadata:
  short-description: "Recurring growth review + GitHub ledger update (per-project config)"
---

# Growth Review — recurring ledger operator

Every run answers: what moved, did the last bets work, what are the next bets — and writes
that down so the next run never starts from amnesia.

## Phase −1 — load project config (do not rediscover facts)

Read `<cwd>/.github/automation/growth_review.yaml`. If it is missing → STOP and say which
repo lacks it. Everything project-specific comes from this file:

| Key | Meaning |
|---|---|
| `repo` | GitHub `owner/name` for tickets + ledger |
| `pageseeds_project` | pageseeds-cli project id (GSC desk); omit → no GSC desk |
| `ledger_issue` | Issue number — body = live summary, comments = entries |
| `cadence_days` | Intended spacing between entries |
| `posthog` | `project_id`, optional `dashboard_id` (tiles to run first) |
| `definitions_doc` | Canonical metric/funnel definitions — follow, never re-invent |
| `north_stars[]` | `{id, lane, source, note?}` — what the program is graded on |
| `leading_indicators[]` | `{id, lane, source, note?}` — gradeable proxies each run |
| `bottleneck_order[]` | Priority order for picking bets until ledger evidence says otherwise |
| `db` (optional) | `{query_cmd, fallback?, test_account_filter, pulls[]}` — read-only DB desk |
| `small_n_note` | What volume makes a delta noise; how long a window grading needs |
| `related_files` (optional) | Repo files to read for context (e.g. `seo_program.yaml`) |

Metric ids should match the existing definitions (`definitions_doc`, or `seo_program.yaml`
`metrics[]`) — the config lists *which* metrics are graded; it does not redefine them.

## Hard rails

1. **Read-only data.** DB access only through `db.query_cmd` (SELECT-only; never
   data-modifying SQL). The repo's `AGENTS.md` safety rules apply at all times.
2. **Never fabricate numbers.** A source that fails → report "unavailable" and continue;
   missing data is itself a finding.
3. **Small-N honesty.** Apply `small_n_note`. Grade leading indicators each run; judge
   north stars only on windows long enough to mean something. Say when N is too small —
   `unknown` is an honest grade.
4. **One bet per funnel stage / lane per run.** Overlapping changes are ungradeable.
5. **Bottleneck order** from the config, until the ledger's evidence says otherwise.
6. **No code changes.** This skill observes, grades, files tickets, writes the ledger.
   Implementation happens through ticket → scope-loop → pr-loop.
7. **Tickets:** `gh issue create -R <repo>` with `bug` or `enhancement` + `priority/P*`.
   Never `ready` (scope-loop owns that). Each bet ticket contains: hypothesis, **lane**,
   **metric id** (from `north_stars` / `leading_indicators`), expected movement, check date.
   Epics (`Epic:` title) are never scoped/shipped.
8. **PostHog MCP discipline:** info/schema drill-down, `read-data-schema` before querying
   events, `filterTestAccounts: true` on every query.
9. **Don't duplicate weekly-seo.** Page-level SEO tactics (CTR rewrites, refreshes,
   merges, per-page outcome reviews) belong to `/weekly-seo`. This skill reads its output
   and bets at the program level.

## Phases

### Phase 0 — spacing gate

- `gh issue view <ledger_issue> -R <repo> --json body,comments`.
- If the newest entry comment is **younger than `cadence_days − 2` days** → STOP and say so
  (idempotent re-run guard). Override only when the user explicitly says "force" /
  "override"; log the override in the entry.

### Phase 1 — data pull (deltas)

Run one desk per source present in the config; skip the rest.

1. **GSC desk** (`pageseeds_project` set): `pageseeds-cli gsc-performance`, `gsc-movers`,
   `gsc-queries`, `ctr-outcomes`, `site-overview` for the project (`--help` for flags;
   28d vs previous 28d). Pull the rows behind every gsc-sourced metric id.
2. **PostHog desk:** if `posthog.dashboard_id` → run its tiles first
   (`dashboard-insights-run`); re-run uncomputed tiles via trends/funnels/paths using the
   definitions in `definitions_doc`. Pull every posthog-sourced metric id.
3. **DB desk** (`db` set): run `db.pulls[]` through `db.query_cmd`, always applying
   `db.test_account_filter`. If `query_cmd` fails, use `db.fallback`.
4. **Existing loop state:** read `.github/automation/weekly_outcome_latest.json` (if
   present) and `related_files` (e.g. `seo_program.yaml` items with `status: measuring`) so
   you build on weekly-seo's verdicts instead of re-measuring them.
5. Compare to the baseline in the issue body and to the last entry. Produce a compact
   delta table: `metric id · lane · baseline · last entry · now`.

### Phase 1b — free-flow desk (bet candidates, not a report dump)

Answer each with evidence (numbers + URLs/queries), ≤5 bullets each. Skip a question whose
source desk is absent.

1. **Demand we don't serve:** high-impression queries with no matching page, or page-1
   positions with ~0 clicks.
2. **Rank but no click:** CTR far below what the position implies, at program level
   (patterns across a cluster), not single-page title tweaks.
3. **Land but no next step:** PostHog paths from landing groups to the lane's conversion
   event (signup, outbound click, checkout…); bounce and pages/session by landing group.

Findings become candidates for Phase 3. Anything page-tactical → note it for weekly-seo.

### Phase 2 — grade hypotheses

- For every open bet in the body's "Hypotheses in flight" table: check its ticket state
  (`gh issue view <n> -R <repo>`), whether it deployed (`git log --all --grep="#<n>"`), and
  grade the named metric id against Phase 1 data: `hit` / `miss` / `unknown`.
- Check date not reached → `pending` (still record the current reading).
- New evidence beats optimism. A `miss` gets a "what next" note (iterate, revert, or park).

### Phase 3 — next bets (≤3)

- Pick from `bottleneck_order`, using open grades, Phase 1b candidates, existing P1/P2
  tickets (`gh issue list -R <repo>`), and fresh anomalies.
- Each bet: hypothesis, lane, metric id, expected movement, check date, ticket (new or
  existing). Prefer fewer, sharper bets.

### Phase 4 — ledger write

1. **Comment** on the ledger issue: `### Entry #N — <date>` with delta table, Phase 1b
   top findings (≤5 lines), graded bets, new bets, and a 2–3 line "learning" paragraph.
   This is the history.
2. **Update the issue body** (`gh issue edit <ledger_issue> -R <repo> --body-file …`):
   refresh *Current summary* — last run / next run due (`+cadence_days`), the hypotheses
   table (verdicts + new bets), latest numbers vs baseline. Keep the baseline table and
   "How the ledger works" intact. The body must stay readable without the comments.

### Phase 5 — report

End with a compact summary: deltas that matter, verdicts, next bets with ticket links, and
anything needing a human decision.

## Relationship to other skills

- `/weekly-seo` — tactical page-level SEO loop with its own per-page outcome reviews.
  Input to this skill; never duplicated by it.
- `/seo-program-review` — monthly `seo_program.yaml` rebalance; reads this ledger's body.
- `/posthog-weekly-insights` — product-behaviour deep dive; its output is bet input.
- Scheduler: `pageseeds-cli operator-runs enable -i <project> --skill
  workspace_cmd:growth-review --every <cadence_days>d --cmd "… -p '/growth-review'"`, run
  from the product repo so the config resolves. Interactive: "run the growth review".
