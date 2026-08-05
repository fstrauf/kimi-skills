---
name: seo-deep-dive
description: >-
  One-shot bootstrap SEO sweep for one PageSeeds project: 6 read-only desks
  (GSC reality, content audit, technical SEO, PostHog funnel, keyword/SERP
  reality, ops loop) → synthesis → epic + subtickets in the customer repo.
  Run once per project to bootstrap the program; weekly-seo +
  seo-program-review maintain afterwards. Throwaway skill — delete after
  the fleet sweep.
when-to-use: >-
  Triggers on "/seo-deep-dive", "SEO deep dive", "SEO bootstrap",
  "first SEO sweep", "bootstrap the SEO program", "do the days-to-expiry
  sweep for this repo", "full SEO investigation for this site".
argument-hint: "[project-name-or-id]"
user-invocable: true
metadata:
  short-description: "Bootstrap SEO sweep: 6 desks → synthesis → ticket backlog"
---

# SEO Deep Dive — bootstrap sweep (one-shot per project)

> Proven 2026-07-30 on days_to_expiry: surfaced 4 root causes → epic #1088
> (9 site tickets) + epic pageseeds-app#300 (8 workflow tickets).
> This skill is the repeatable per-site version. It is **one-shot**: if a
> prior `seo_deep_dive_*.md` exists <90 days old, skip unless the user
> forces a re-run.

You are an SEO operator running a **full diagnostic sweep** for ONE project.
Goal: find the real levers for **impressions → clicks → signups**, then turn
them into a structured ticket backlog. You do **not** implement fixes.

| Layer | Role |
|-------|------|
| Capability | `pageseeds-cli` JSON tools (desk reads only) |
| Behavioral | PostHog MCP (read-only queries) |
| SERP reality | WebSearch on representative queries |
| Output | `.github/automation/seo_deep_dive_<YYYYMMDD_HHMMSS>.md` + epic/subtickets |

## Invocation

```
/seo-deep-dive
/seo-deep-dive coffee
/seo-deep-dive -i expense
```

## Hard rules

- **Read-only on content/product source.** Never edit the customer's webapp,
  MDX, or config. Never edit pageseeds-app source.
- **No mutating CLI** except the two freshness tasks below. Banned:
  `fix-submit`, `write-submit`, `merge-submit`, `create-task` (other types),
  `enqueue`, `select-keywords`, anything that writes content or spawns work.
- Allowed mutations (freshness only): `create-task -t collect_gsc` +
  `execute-task` when the GSC tape is stale (>7d); `collect_posthog` if the
  project uses the engine tape. Nothing else.
- **Always pass `-i <project_id>` (or `-p`) to project-scoped CLI calls.**
  cwd/env resolution can silently pick the WRONG project (verified: an
  unscoped `list-tasks` returned another project's tasks).
- PostHog: MCP query/read tools only. No insight/dashboard creation.
- Secrets via EnvResolver resolution only; never print or embed keys.
- Everything you claim needs evidence: numbers, file:line, or command output.
  Small-n caveats are mandatory where n is small.

## Preflight (desk 0)

1. `pageseeds-cli list-projects` → resolve the project (id, repo path,
   GSC property). Work from the customer repo root afterwards.
2. Config presence: `.github/automation/project.yaml`,
   `.github/automation/seo_program.yaml`. **Missing seo_program.yaml is
   expected for fresh projects** — the sweep bootstraps it (see Output).
3. Freshness: `pageseeds-cli site-overview -i <id>` → `freshness.stale`?
   If yes, run the collect_gsc task (allowed) and re-read.
4. State files: `gsc_collection.json`, `articles.json`, `link_scan.json`,
   `keyword_coverage.json`, `gsc_metrics_synced_at` in `.github/automation/`.
   Note which exist and their ages. `generated_at` is now producer-stamped,
   but still sanity-check ages.
5. Existing artifacts: prior `weekly_seo_*.md`, `seo_program_review_*.md`,
   prior `seo_deep_dive_*.md` (skip rule above).

## The 6 desks

Run desks 1–6 as **parallel read-only subagents if your runtime supports
them** (AgentSwarm: one agent per desk); otherwise sequentially. Each desk
returns a dense evidence report; you synthesize.

### Desk 1 — GSC reality (is it actually flatlining?)

Commands: `site-overview`, `gsc-performance -l 25`, `gsc-movers -l 100`,
`gsc-queries -i <id> -l 500` (all `-i <id>`); local `gsc_page_daily` via CLI
desk reads; `ctr_query_metrics` through `article -S <slug>` / `gsc-queries -u <url>`.

Produce:
- Site totals per window (7d/28d/90d): impressions, clicks, CTR, position —
  and the **trend**. Impression drops alone ≠ flatlining: check whether
  clicks/CTR rose while informational impressions were pruned (the DTE
  pattern: clicks 3×, impressions −45%).
- Top 30 queries by impressions AND by clicks; top 30 pages likewise.
- Striking distance (pos 4–20, meaningful impressions).
- High-impression / low-CTR cohort (the cheapest click lever).
- Noise audit: quoted-phrase zero-click queries (bot noise), brand-name
  collisions (e.g. "daily expiring options" junk on Days to Expiry),
  `site:` queries. Exclude from demand math.
- Click share by cluster: map top-50 queries/pages to `project.yaml`
  clusters (primary/tools/commercial vs legacy/drift). Verify any claimed
  shares in seo_program.yaml — definitions get inflated.

### Desk 2 — Content audit

Content dir (find it: `articles.json` / repo layout; e.g. `webapp/content/blog/`)
+ catalog + `link_scan.json` + `gsc_collection.json` (index coverage).

Produce:
- Topical map per post: slug, title, date, ~word count, cluster, CTA
  presence (in-body product links, CTA components), internal links out.
- Cluster distribution + publish cadence over time (content-farm bursts?).
- **Cannibal families**: multiple posts per intent. Cross-ref index status —
  Google's not-indexed verdicts map to duplication families.
- Not-indexed share from `gsc_collection.json` (Crawled/Discovered—not indexed).
- Stale signals: titles with old years, mistitled posts (title ≠ slug intent),
  stale data sections.
- CTA coverage: share of posts with contextual in-body CTA vs footer-only.
- State integrity: run the sync/validate desk read if available
  (`sync_and_validate` reports duplicate_prefix / export_lag since #315/#316).
- Spot-read 5–8 representative posts (top earner, newest, a tools post):
  quality vs what ranks for that query.

### Desk 3 — Technical SEO & on-page funnel

Repo (the webapp) + live site (FetchURL: `/`, a tool page, `/pricing`,
2–3 blog posts, `/sitemap.xml`, `/robots.txt`).

Produce:
- Route inventory: which marketing/tool/commercial routes exist, are
  indexable, and have real content vs thin placeholders. Compare against the
  product_paths the program assumes.
- Blog template anatomy: title/H1 handling, meta, canonical, JSON-LD types,
  CTA placement, related-posts module (auto or hand-written?).
- Sitemap/robots contradictions: URLs in sitemap that 301; routes missing
  from sitemap; `public/robots.txt` overriding app routers; static files
  shadowing app routes.
- Metadata issues: duplicate/empty titles, brand suffix duplication
  (DTE had `| Brand | Brand` on 8 commercial pages), frozen lastmod.
- Draft status handling: are "draft" posts actually live? (DTE: the blog
  loader had no status filter — 21 "drafts" were indexed.)
- **Deploy state**: `git log` recent content commits vs latest automation
  reports vs live HTML. Report any shipped-but-undeployed or
  reported-but-not-committed gaps.

### Desk 4 — PostHog funnel

MCP only. Project id from `project.yaml` (`posthog_project_id`).

Produce:
- Confirm events BEFORE querying (`read-data-schema`): signup_started /
  signup_completed / activation events exist? Since when? **Young-event
  caveat** — if signup_started is 12 days old, historical baseline claims
  are unverifiable; say so.
- **Always filter `$host`** (and document the filter): dev/localhost/staging
  and OTHER PRODUCTS contaminate shared projects (DTE's project also
  carried expensesorted hosts).
- Weekly trend 90d: site users, blog users, signup_started, signup_completed.
  Note analytics blackouts.
- Conversion by entry-path group: blog vs tools vs commercial vs home.
  Where does the funnel actually break?
- Top converting paths (which pages precede signups); CTA-click landscape
  per post if `cta_clicked` exists (high-traffic zero-CTA-click posts are
  prime harvest targets).
- Activation if measurable (signup → key action ≤7d), incl. failure modes
  (DTE: SnapTrade import ~75% failure — product-side, not SEO).
- Small-n discipline: rates from n<30 are directional; label them.

### Desk 5 — Keyword strategy & SERP reality

Inputs: `project.yaml` (primary/problem/audience/do_not_expand + clusters),
`ctr_query_metrics` via `gsc-queries`, WebSearch ~10 representative queries
(mix of primary, high-impression, and tool/commercial terms).

Produce:
- Per-keyword verdict: real demand (GSC impressions), who ranks, winnable
  for this site's size?, intent match to the product.
- **Positioning-vs-demand test**: are "primary" keywords actually searched?
  (DTE: all 10 primaries = ~10 impressions/90d total — positioning copy, not
  demand. Mode A attract was structurally starved.)
- Demand pools ranked: tools/calculators, competitor/switcher, workflow
  terms, listicles/school, brand. Where does this site's realistic fuel
  come from?
- do_not_expand assessment: right calls? Anything excluded that converts?
- 10–15 concrete opportunities ranked by demand × intent × winnability ×
  product fit (incl. "X alternative", calculators, workflow terms).
- Anti-targets: what NOT to build (zero-demand vanity keywords).
- Video/YouTube note: which SERPs show video carousels with no incumbent
  (procedural/product-fit content only — don't fight big channels on
  school terms).

### Desk 6 — Ops loop & history

Inputs: prior `weekly_seo_*.md` / `seo_program_review_*.md` (if any),
`pageseeds-cli list-tasks -i <id>` (task store), `git log` cadence.

Produce:
- Timeline of past runs: date → mode → measures → outcomes. **Does any run
  ever measure a previous measure?** (DTE: loop was entirely future-tense,
  0/20 outcome reviews executed.)
- Task store health: stale/failed/duplicate tasks (esp. duplicate
  `content_outcome_review` pairs — dedupe is not retroactive), never-run
  types.
- Deploy cadence: are content commits landing near run times?
- Plumbing: redirects committed or gitignored? publish path workarounds?
  State files stale?
- Note: the pageseeds workflow machinery itself was hardened 2026-07
  (epic #300: measurement gate, run-spacing, uncovered demand, decay
  inventory, prune pipeline, outcome loop, PostHog tape). Do NOT re-litigate
  workflow mechanics — report only THIS project's loop health. If you find
  a genuinely new workflow gap, route it to a pageseeds-app ticket, not the
  customer repo.

## Synthesis

Combine the desks into the four-root-cause frame (adapt to evidence — do
not force the pattern):

1. **Demand reality** — is the strategy aimed at searched queries?
2. **CTR/mix** — how much impression volume sits at broken CTR? What's the
   click share of money classes vs drift?
3. **Inventory quality** — cannibalization, index rejection, technical debt.
4. **Funnel** — where does entry → CTA → signup → activation actually break?

Then the ranked lever list (max ~9), each with: expected impact on
impressions → clicks → signups, evidence pointer, rough effort. Cheap
certainty beats speculative volume: CTR on existing mega-pages, index
fixes, consolidation, missing tool routes usually outrank new content.

## Output

1. **Report**: `.github/automation/seo_deep_dive_<YYYYMMDD_HHMMSS>.md` —
   desk summaries, synthesis, ranked levers, and a proposed
   `seo_program.yaml` (or updates) reflecting demand reality: mode,
   primary_backlog from REAL demand pools, harvest queue from the CTR/CTA
   findings, tools queue from missing/misaligned routes. Do not write
   program changes into the YAML yourself unless the user asked — the
   report proposes; `/seo-program-review` or the user ratifies.
2. **Tickets** (default: create them; skip only if the user says report-only):
   - ONE epic in the **customer repo**: "SEO bootstrap: <site> deep dive
     <date>" — root causes, key data, task list of subtickets.
   - One subticket per lever. Body template: `Part of #<epic>` →
     `## Problem Statement` → `## Evidence / Root Cause` (dense numbers +
     file paths) → `## Proposed Approach` → `## Files / Areas` →
     `## Open Questions` → `## Acceptance Criteria` (checkboxes).
   - Labels: `enhancement` + `priority/P2` (+ `priority/P1` for the top
     time-sensitive item) + `scoping` if the repo has it. **Never** `ready`,
     `triage:ready-to-implement`, or `agent-working` — these go to the
     scope queue, not the ship queue.
   - Link subtickets as native sub-issues:
     `gh api repos/<owner>/<repo>/issues/<epic>/sub_issues -F sub_issue_id=<id>`
     (id via `gh api repos/<owner>/<repo>/issues/<n> --jq .id`; `-F`, not
     `-f` — string ids get 422). Fallback: epic task list + `Part of #` lines.
   - **Routing rule:** site/content/config gaps → customer repo tickets;
     workflow/CLI/machinery gaps → fstrauf/pageseeds-app tickets. Machinery
     was just hardened (epic #300) — only file genuinely new gaps there.
3. **Final message**: 5-line summary — the one-sentence diagnosis, top 3
   levers, epic URL, what happens next (weekly-seo cadence + first
   measurement gate).

## Pitfalls (all burned once — do not relearn)

- Unscoped CLI calls resolve the wrong project — always `-i`/`-p`.
- PostHog without `$host` filter = other products + dev hosts in your funnel.
- "Flatlining" from impressions alone is usually wrong — check clicks/CTR.
- Baselines quoted from young events (<30d old) are fiction — say so.
- n<30 conversion rates are directional — label them.
- Reports ≠ reality: verify deploy state against git log and live HTML.
- Draft-status frontmatter may not gate anything — check the loader.
- Sitemap can list 301'd URLs; robots.txt can shadow app routers.
- GSC has a ~14-day lag for verdicts on recent ships — date your evidence.
- Bot noise (quoted zero-click queries) inflates demand math — filter it.
- `keyword_coverage.json` / `links_to_add.json` can be stale garbage even
  with fresh timestamps — cross-check against live desk reads.

## After the sweep (handoff)

- Steady state is NOT this skill: `/weekly-seo` (weekly, now with
  measurement gate + run-spacing) and `/seo-program-review` (monthly)
  maintain the program. `/weekly-seo-status` for cross-project freshness.
- The first weekly run after a sweep should be measure-only if the spacing
  gate blocks mode work (<5d since last mode run).
- This skill is throwaway: once every active project has a bootstrap epic,
  delete it.
