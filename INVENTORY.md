# Skill inventory (this machine)

**Snapshot date:** 2026-07-30 (updated after Phase 2 cleanup same day)  
**Host:** Florian’s macOS  
**Method:** walk known skill roots; a skill = directory containing `SKILL.md`.  
**Note:** Symlinked roots appear twice in “instances” (live path + repo path) when both are scanned — that is one file on disk, not two copies.

### Cleanup applied 2026-07-30

| Action | Result |
|--------|--------|
| Removed `call-analyzer/.kimi/skills/{betterstack-error-triage,email-ops,posthog-weekly-insights}` | Empty dir left; user-scope `~/.kimi-code/skills` supplies them |
| Removed `fiAnalyst/.kimi/skills/{same three}` | Same |
| Removed `~/.grok/skills/gh-ticket-hygiene` | Identical to universal; Grok `paths` still loads kimi tree |
| Removed `kimi-skills/agents/skills/weekly-seo` (454L stale) | Canonical is pageseeds-app `.agents` (957L); `kimi-code/skills/weekly-seo` still symlinks there |
| `pageseeds-app/.github/skills/weekly-seo` | Now symlink → `../../.agents/skills/weekly-seo` |
| Dual-host `pr-orchestrator` written to `kimi-code/skills/pr-orchestrator` | Single source for Kimi + Grok |
| Removed `~/.grok/skills/pr-orchestrator` | No more split-brain fork |
| Cleared `~/.grok/config.toml` `[skills].ignore` for pr-orchestrator | Grok loads skill via `paths = ["~/.kimi-code/skills"]` |

Regenerate live state: `python3 scripts/inventory-skills.py --duplicates-only`

Regenerate rough inventory:

```bash
# From any shell on this machine
python3 - <<'PY'
# (optional) re-run the scan used to build this doc; keep script in repo later as scripts/inventory-skills.py
print("See kimi-skills README / prior agent session for full scanner")
PY
```

---

## Summary

| Metric | Value |
|--------|------:|
| Skill instances found | ~116 |
| Unique skill names | ~62 |
| Roots with skills | 21 |

### Roots scanned

| Root | Symlink target | Role |
|------|----------------|------|
| `~/01_code/kimi-skills/kimi-code/skills` | — | **Canonical universal** |
| `~/.kimi-code/skills` | → kimi-skills `kimi-code/skills` | Kimi user install |
| `~/01_code/kimi-skills/agents/skills` | — | **Canonical agents** |
| `~/.agents/skills` | → kimi-skills `agents/skills` | Agents install |
| `~/.grok/skills` | — | Grok user (mixed: native + copies + one symlink) |
| `~/.grok/bundled/skills` | — | Shipped with Grok (do not edit) |
| `~/.kimi/skills` | — | **Legacy** Kimi tree |
| `~/.claude/skills` | — | Claude leftover |
| `~/.codex/skills` | — | Codex leftover |
| `~/.config/agents/skills` | — | Agents leftover |
| `~/.hermes/skills` | — | Empty curator state only |
| `call-analyzer/.kimi/skills` | — | Product copies of universal |
| `call-analyzer/.github/skills` | — | SEO / PostHog / sentiment (legacy path) |
| `fiAnalyst/.kimi/skills` | — | Product copies of universal |
| `fiAnalyst/.github/skills` | — | Twin of call-analyzer `.github/skills` |
| `pageseeds-app/.agents/skills` | — | Product SEO / video |
| `pageseeds-app/.grok/skills` | mostly → `.agents` | Grok views of product skills |
| `pageseeds-app/.github/skills` | — | Partial / older product skills |
| `nz-coffee-hub/.kimi/skills` | — | Coffee product |
| `nz-coffee-hub/.github/skills` | — | content-fix-apply etc. |
| `tx/.github/skills` | — | Small SEO / distributed-workflows set |

---

## A. Universal (intended home: `kimi-skills/kimi-code/skills`)

| Skill | Lines | Locations (content) | Status |
|-------|------:|---------------------|--------|
| `betterstack-error-triage` | 254 | canonical + kimi symlink + **identical** copies in call-analyzer & fiAnalyst `.kimi` | Deduplicate: drop project copies |
| `email-ops` | 111 | same pattern | Deduplicate: drop project copies |
| `feature-spec-to-github-issue` | 80 | canonical + kimi symlink + **legacy** `~/.kimi/skills` | Drop legacy |
| `gh-scope-issue` | 243 | canonical + kimi symlink only | Clean |
| `gh-ticket-hygiene` | 338 | canonical + kimi symlink + **identical** `~/.grok/skills` | Drop Grok copy; use paths |
| `posthog-weekly-insights` | 383 global / **343** project | canonical ahead of call-analyzer & fiAnalyst | **Drift** — promote or split overlay |
| `pr-orchestrator` | 516 Kimi / **512** Grok | canonical vs `~/.grok/skills` **differ** (tool maps) | **Split brain** — merge or dual-name |
| `pr-orchestrator-generic` | 464 | canonical + kimi symlink only | Clean |
| `storage-sweep` | 129 | canonical + kimi symlink only | Clean |
| `thermo-nuclear-code-quality-review` | 192 | canonical + kimi symlink + legacy `~/.kimi` | Drop legacy |
| `weekly-seo` (via symlink) | 957 | `kimi-code/skills/weekly-seo` → pageseeds-app `.agents` | OK install; product-owned content |

**Legacy packages (`.skill` zips):**  
`feature-spec-to-github-issue.skill`, `thermo-nuclear-code-quality-review.skill` under kimi-skills and `~/.kimi` — cleanup candidates.

---

## B. Product-specific

### pageseeds-app

| Skill | Lines | Path notes |
|-------|------:|------------|
| `weekly-seo` | 957 | **Canonical product** `.agents/skills/weekly-seo`; also linked from kimi-skills + `~/.grok/skills` |
| `weekly-seo` (stale) | 454 | `kimi-skills/agents/skills/weekly-seo` and `pageseeds-app/.github/skills/weekly-seo` |
| `weekly-seo-status` | 313 | `.agents` + `.grok` symlink |
| `video-clip` | 601 | `.agents` + `.grok` symlink |
| `centralized-logic-check` | 73 | `.agents` (+ `.skill` package) |
| `feature-spec-generation` | 55 | `.github/skills` |
| `indexing-distinctiveness` | 38 | `.github/skills` |
| `pageseeds-investigation` | 97 | `.github/skills` |

Related Grok-only but product-facing: `~/.grok/skills/reddit-engage` (PageSeeds CLI engagement pass).

### call-analyzer / fiAnalyst (`.kimi` — universal copies)

| Skill | call-analyzer | fiAnalyst | vs global |
|-------|---------------|-----------|-----------|
| `betterstack-error-triage` | 254 | 254 | identical |
| `email-ops` | 111 | 111 | identical |
| `posthog-weekly-insights` | 343 | 343 | **behind** global 383 |

### call-analyzer / fiAnalyst (`.github/skills` — mostly twins)

Identical pairs unless noted:

- `distributed-workflows` (115)
- `market-sentiment` (96)
- `posthog-product-insights` (292)
- `posthog-single-site` (192)
- `sentiment-admin` (75)
- `seo-clustering-linking` (186)
- `seo-content-cleanup` (67)
- `seo-content-creation` (144)
- `seo-indexing-diagnostics` (127)
- `seo-indexing-remediation` (147)
- `seo-keyword-research` (222)
- `seo-local-setup` (51) — also differs on `tx` (53)
- `seo-ops-management` (62)
- `seo-publishing-deployment` (77)
- `seo-status-dashboard` (70)
- `seo-sync-validation` (56)
- `portfolio-qa-agentic.md` (flat md, not a skill dir)

**Visibility:** not loaded by Grok default discovery.

### nz-coffee-hub

| Skill | Lines | Location |
|-------|------:|----------|
| `coffee-data` | 150 | `.kimi/skills` |
| `pr-orchestrator-coffee` | 235 | `.kimi/skills` |
| `content-fix-apply` | 90 | `.github/skills` |

### tx

| Skill | Lines | Notes |
|-------|------:|-------|
| `distributed-workflows` | 88 | differs from call-analyzer 115 |
| `seo-local-setup` | 53 | differs slightly from call-analyzer 51 |

---

## C. Harness-native (Grok)

### User `~/.grok/skills`

| Skill | Lines | Notes |
|-------|------:|-------|
| `check-work` | 287 | Grok verification flow |
| `code-review` | 192 | Matches bundled |
| `create-skill` | 81 | Slightly differs from bundled (83) |
| `gh-ticket-hygiene` | 338 | Identical to universal — **redundant** |
| `help` | 51 | Grok docs helper |
| `imagine` | 131 | Matches bundled |
| `pr-orchestrator` | 512 | **Grok fork** of ship loop |
| `reddit-engage` | 384 | PageSeeds Reddit pass (could move to product or universal) |
| `weekly-seo` | 957 | Symlink → pageseeds-app |

### Bundled `~/.grok/bundled/skills` (shipped; leave alone)

`build-with-ai`, `code-review`, `create-skill`, `create-workflow`, `design`, `docx`, `execute-plan`, `game-*`, `imagine`, `implement`, `pdf`, `pptx`, `pr-babysit`, `resume-claude`, `resume-codex`, `resume-cursor`, `review`, `shared`, …

---

## Leftover / multi-install noise

### `kimi-webbridge` (5 installs, same content)

| Path |
|------|
| `kimi-skills/agents/skills/kimi-webbridge` (**canonical**) |
| `~/.agents/skills` (symlink to above) |
| `~/.claude/skills/kimi-webbridge` (copy) |
| `~/.codex/skills/kimi-webbridge` (copy) |
| `~/.config/agents/skills/kimi-webbridge` (copy) |

### Legacy `~/.kimi/skills`

- `feature-spec-to-github-issue` (+ `.skill`)
- `thermo-nuclear-code-quality-review` (+ `.skill`)
- `gh-pick-and-start-issue` (orphan; not in kimi-skills)

### Name collisions with content mismatch (action required)

| Skill | Problem |
|-------|---------|
| `pr-orchestrator` | Kimi vs Grok tool-map forks |
| `posthog-weekly-insights` | Global 383 vs project 343 |
| `weekly-seo` | 957 product vs 454 stale agents/.github |
| `seo-local-setup` / `distributed-workflows` | call-analyzer vs tx drift |

---

## Install wiring currently in effect

```text
kimi-skills/kimi-code/skills  <──symlink──  ~/.kimi-code/skills
        │
        └── Grok [skills].paths ──► also visible in Grok
              (except pr-orchestrator ignored)

kimi-skills/agents/skills  <──symlink──  ~/.agents/skills

~/.grok/skills/weekly-seo  ──symlink──► pageseeds-app/.agents/skills/weekly-seo
kimi-skills/.../weekly-seo ──symlink──► same pageseeds-app file
```

---

## Consolidation checklist (copy into issues/todos)

See [README.md](./README.md#consolidation-plan) for phases. Short list:

- [ ] Unify or dual-name `pr-orchestrator`
- [ ] Delete stale 454-line `weekly-seo` copies
- [ ] Drop redundant `~/.grok/skills/gh-ticket-hygiene`
- [ ] Drop call-analyzer/fiAnalyst `.kimi` copies of identical universals
- [ ] Fix `posthog-weekly-insights` drift
- [ ] Retire `~/.kimi/skills` and duplicate webbridge copies
- [ ] Decide fate of `.github/skills` SEO matrix
- [ ] Optional: `scripts/install-symlinks.sh` + `scripts/inventory-skills.py`
