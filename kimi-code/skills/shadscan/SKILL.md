---
name: shadscan
description: >-
  Deterministic shadcn/ui audit of the current React repo via @shadscan/cli.
  Scores UI fundamentals (accessibility, forms, theme, states, polish) 0–100
  with file-level evidence. Use when the user runs /shadscan, asks to scan
  shadcn, audit shadcn UI, raise the shadscan score, check shadcn
  accessibility or production polish, or run a UI fundamentals scan.
  React + official shadcn only — refuse Vue / shadcn-vue.
when-to-use: >-
  Triggers on "/shadscan", "shadscan", "scan shadcn", "audit shadcn",
  "shadcn UI audit", "raise the shadscan score", "shadcn accessibility scan",
  "UI fundamentals scan".
argument-hint: "[path] [--fix] [--category name] [--check-ui url]"
user-invocable: true
metadata:
  short-description: "Scan this React shadcn repo with @shadscan/cli"
---

# shadscan

Local, read-only audit of **this** repo via `@shadscan/cli`. One repo per
run. Do not upload source. Do not install a project dependency.

Tool: [TheOrcDev/shadscan](https://github.com/TheOrcDev/shadscan) — 62
static rules, score 0–100. Does not start the app, edit files, or call an
AI model.

## Hard rails

| # | Rule |
|---|------|
| 1 | **Local CLI only.** `npx --yes @shadscan/cli`. Never the hosted API, never a source tarball, never `SHADSCAN_API_KEY`. |
| 2 | **React + official shadcn only.** Vue / `shadcn-vue` / no React → stop. Do not invent a Vue audit. |
| 3 | **Default is report-only.** Edit only when the user said `fix` / `raise the score` / `implement`, or when this is an [orchestrator control step](#orchestrator-control-step). |
| 4 | **Do not `--apply`.** You are the agent. Parse `--json`; do not launch Claude/Codex/Grok via the CLI. |
| 5 | **Ignore kitchen-sink gates** in `acceptanceCriteria`. Shadscan lists every `package.json` script. Use the repo's documented ship gate (or `lint` + `typecheck`) after real edits. |
| 6 | **Never edit only to silence an advisory.** Low-confidence / `verify` items need rendered or manual evidence. |
| 7 | **Do not add product chrome blindly.** Command menu, theme hotkey, toasts, and SEO files are `decide` — implement only when they fit this product. |

## Gate (before any scan)

1. Resolve target: user path, else cwd. If cwd is a monorepo root, look one
   level down for the app (`webapp/`, `apps/web/`, `apps/desktop/`).
2. Read `package.json` + `components.json` if present.

| Signal | Action |
|--------|--------|
| `vue` / `shadcn-vue` / schema `https://shadcn-vue.com/schema.json` | **Refuse** — see [Unsupported](#unsupported) |
| `react` + `components.json` with `ui.shadcn.com` schema | Scan that package |
| `react` without `components.json` | Scan anyway; foundation will fail `shadcn-config-present` |
| No React | **Refuse** |
| Multiple workspace packages | `--list-projects` first; scan one app (`--project <path>`) unless the user asked for the pooled root score |

```bash
npx --yes @shadscan/cli --list-projects --no-interactive --no-roast <path>
```

## Scan

First `npx` can take ~60–90s. Always:

```bash
npx --yes @shadscan/cli --json --no-interactive --no-roast <path>
```

Optional:

```bash
# One category: foundation | interaction | states | accessibility | forms | production-polish
npx --yes @shadscan/cli --json --no-interactive --no-roast --category accessibility <path>

# One workspace package
npx --yes @shadscan/cli --json --no-interactive --no-roast --project webapp <path>

# Rendered overflow (app must already be running; not part of the 0–100 score)
npx --yes @shadscan/cli --check-ui http://localhost:3000 --json --no-interactive --no-roast
```

`--check-ui` only when the user asked or a local/preview URL is already up.
Do not start the app for it.

On `UNSUPPORTED_PROJECT` / “does not declare React”: treat as [Unsupported](#unsupported).

## Read the JSON

Trust these fields; do not invent findings.

| Field | Use |
|-------|-----|
| `score` / `grade` / `maxScore` | Headline |
| `framework.adapter` | `next-app-router`, `vite-react`, … |
| `shadcn.configPath` / `shadcn.style` | Config evidence |
| `rulesetVersion` | Quote when comparing before/after |
| `agentHandoff.actionables[]` | Work list |
| `findings[]` | Full rule results (`pass` / `fail` / `advisory` / `not-applicable`) |

Each actionable:

| Field | Meaning |
|-------|---------|
| `disposition` | `fix` = defect · `decide` = product choice · `verify` = needs a browser |
| `findingId` | Stable rule id |
| `scoreImpact` | Points on the table |
| `confidence` | `high` / `medium` / `low` |
| `evidence[].filePath` + `line` | Inspect before treating as real |
| `suggestedFix` | Starting point, not a mandate |

`not-applicable` is not a miss. Do not implement unused surfaces (no
questionnaires → skip `questionnaire-item-composition`).

## Modes

### Report (default)

Inspect cited files enough to drop false positives. Then report. Do not
edit.

### Fix (only if asked)

1. Confirm each `fix` against the cited file.
2. Implement **high-confidence `fix`** items first (labels, alt, dialog
   titles, button `type`, semantic controls). Smallest change that satisfies
   the rule in this codebase’s existing patterns.
3. `decide` items: implement only when the product is an app that should
   have that surface (dashboard/admin → theme + command menu often yes;
   marketing/content site → usually waive). State the waiver.
4. `verify` / advisories: do not code. Optionally `--check-ui` if a URL is
   running.
5. Rescan with the **same** command + ruleset. Compare `findingId`s and
   score.
6. Run the repo’s real ship gate for the files you touched — not the
   script dump in the handoff.

Do not add shadcn components the product does not need just to pass
`command-menu-present` or `toast-provider-present`.

## Orchestrator control step

Used by `pr-orchestrator-generic` after implement (after `react-doctor`).
Fail-open. Never `agent-failed` because this scanner is missing or the
repo is not official shadcn.

1. Official shadcn only (`components.json` with `ui.shadcn.com` schema).
   Missing / Vue / no React → report `skipped: no official shadcn` and
   stop this skill.
2. Scan the app package (same [Gate](#gate-before-any-scan) resolution):

   ```bash
   npx --yes @shadscan/cli --json --no-interactive --no-roast --project <app> <path>
   ```

3. `UNSUPPORTED_PROJECT` / CLI error → skip with reason; do not block.
4. Must-fix this pass: high-confidence `disposition: fix` items whose
   evidence file is in this branch’s diff. One implementer pass, then
   one rescan with the same command.
5. `decide` / `verify` / advisories: note for the PR comment. Do not
   add command menus, theme hotkeys, toasts, or SEO files. Do not fail
   the ship.

Scan flags and JSON fields live in this file only. The orchestrator
must not copy them.

## Unsupported

Use this shape and stop:

```text
shadscan cannot audit this repo. It only scans React + official shadcn
(Next, Vite React, React Router, TanStack Start, …).

This tree looks like {Vue / shadcn-vue / no React} ({evidence: schema or
dependency}). No scan, no invented Vue checklist.
```

## Report to the user

```markdown
## shadscan — {packageName} ({adapter})

**Score:** {n}/100 ({grade}) · ruleset {rulesetVersion}
**Config:** {components.json path or missing}

### Categories
{fail counts by category, or “clean”}

### Fixes (high-confidence defects)
| Rule | Evidence | Impact |
|…|

### Decisions (implement or waive)
| Rule | Fits this product? | Note |
|…|

### Advisories (do not code blindly)
- …

### Not applicable
- {one line if useful}

### Next
- Report-only: “say **fix** to implement confirmed Fixes”
- After a fix pass: before → after score + remaining `findingId`s
```

Do not paste the raw JSON. Do not paste `--prompt` output.

## Relationship

| Skill | Role |
|-------|------|
| `react-doctor` | React correctness / hooks / a11y / perf. Run first; this skill is shadcn chrome only. |
| `pr-orchestrator-generic` | Calls this skill’s [orchestrator control step](#orchestrator-control-step) after implement. |

## Optional MCP (not required)

Only if the user wants a persistent server:

```bash
npx -y @shadscan/cli mcp <repo-root>
```

Tools: `scan`, `list_projects`, `explain_rule`. Every call re-scans. Prefer
the CLI from this skill; do not reconfigure Grok MCP mid-run.
