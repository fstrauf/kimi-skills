---
name: react-doctor
description: >-
  Deterministic React health scan of the current repo via the react-doctor CLI.
  Scores correctness, performance, security, accessibility, and maintainability
  0–100 with file-level diagnostics. Use when the user runs /react-doctor, asks
  to scan React, audit React, raise the React Doctor score, check React a11y /
  hooks / effects, or run a React health scan. React / Preact / React Native
  only — refuse Vue / Svelte / no React.
when-to-use: >-
  Triggers on "/react-doctor", "react doctor", "scan React", "audit React",
  "React health scan", "raise the React Doctor score", "React accessibility
  scan", "React performance scan".
argument-hint: "[path] [--fix] [--scope full|changed|files] [--category name] [--project name]"
user-invocable: true
metadata:
  short-description: "Scan this React repo with react-doctor"
---

# react-doctor

Local audit of **this** repo via the `react-doctor` CLI. One repo per run.
Do not install a project dependency. Do not run `react-doctor install` or
`react-doctor ci` unless the user asked.

Tool: [react.doctor](https://www.react.doctor/) — curated lint + complexity /
JSX-duplication + optional Socket.dev supply-chain. Score 0–100. Does not
start the app or call an AI model to invent findings.

Official CLI / JSON / rule prompts are the source of truth. This skill is
the operator policy. Do not copy the 800-rule index in here.

## Hard rails

| # | Rule |
|---|------|
| 1 | **Local CLI only.** `npx -y react-doctor@<version>` (or a project-local binary). Never `react-doctor install` (writes a third-party skill). Never upload a source tarball. |
| 2 | **React / Preact / React Native only.** Vue / Svelte / no React runtime → stop. Do not invent a Vue checklist. |
| 3 | **Default is report-only.** Edit only when the user said `fix` / `raise the score` / `implement`, or when this is an [orchestrator control step](#orchestrator-control-step). |
| 4 | **You are the agent.** Parse `--json`. Do not launch Claude/Codex/Grok via the CLI. |
| 5 | **Require JSON `schemaVersion === 3` and `ok === true`.** Other schema → stop and report the version. Do not invent fields. |
| 6 | **Never suppress a correctness rule just to clear the report.** Narrow inline disables only with evidence. |
| 7 | **Performance is a hypothesis** unless the rule proves a correctness bug. Design-tagged / creative-direction rules stay off unless the user asked. |
| 8 | **Do not treat an empty diagnostic list as clean** when React was undetected, coverage is incomplete, or the requested project is missing. |

## Gate (before any scan)

1. Resolve target: user path, else cwd. If cwd is a monorepo root, look one
   level down for the app (`webapp/`, `apps/web/`, `apps/desktop/`).
2. Read `package.json` (and workspace children if needed).

| Signal | Action |
|--------|--------|
| `react` / `react-native` / `preact` / `expo` | Scan that package |
| `vue` / `svelte` / `solid-js` and no React runtime | **Refuse** — see [Unsupported](#unsupported) |
| No React runtime | **Refuse** |
| Multiple workspace packages | Scan the package being edited (`--project <name-or-path>`). User asked for everything → `--project "*"` |

Prefer a project-local binary when `package.json` already depends on
`react-doctor`. Otherwise pin once:

```bash
npx -y react-doctor@latest --version
```

Record that version. Reuse the same command for `why`, `rules explain`, and
every rescan. First `npx` can take ~60–90s.

## Scan

Always JSON, non-interactive, non-blocking exit (parse the file even if the
process is nonzero):

```bash
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/react-doctor.XXXXXX")"
npx -y "react-doctor@${REACT_DOCTOR_VERSION}" \
  --json --yes --blocking none \
  ${SCOPE_ARGS} ${PROJECT_ARGS} \
  > "$RUN_DIR/report.json"
```

### Scope (pick one)

| Intent | Flags |
|--------|--------|
| Whole project / “what’s the score?” | `--scope full` |
| Issues this branch introduced (default on a feature branch) | `--scope changed --include-untracked --base origin/${BASE:-main}` |
| Dirty working tree / uncommitted | `--scope files --base HEAD --include-untracked` |
| Orchestrator control step | see [below](#orchestrator-control-step) |

`--scope changed` is the default when cwd is a feature branch with a merge
base. Honor an explicit user scope.

Optional:

```bash
# One or more categories: Security | Bugs | Performance | Accessibility | Maintainability
--category Security --category Bugs

# One workspace package (name or path)
--project webapp

# Skip Socket.dev (offline / unattended)
--no-supply-chain

# Skip score API + share URL + crash reporting
--no-score
```

Do not start the app. Do not write `doctor.config.*` unless the user asked
to configure rules.

On `ok !== true` or unreadable JSON: report the error payload and stop.
`reactDetected: false` (or equivalent “no React runtime”) is
[Unsupported](#unsupported), not a clean scan.

## Read the JSON

Trust these fields; do not invent findings. Read `projects[].diagnostics`,
not only a flattened top-level array.

| Field | Use |
|-------|-----|
| `schemaVersion` | Must be `3` |
| `ok` | Must be `true` to treat the report as usable |
| `summary.score` | Headline (never recompute) |
| scanner / CLI version | Quote when comparing before/after |
| `projects[].diagnostics[]` | Work list |
| coverage / skip reasons | Incomplete vs clean |

Each diagnostic (names vary slightly; use what the report actually has):

| Field | Meaning |
|-------|---------|
| rule key (`react-doctor/…`) | Stable id |
| `severity` | `error` before `warning` |
| `category` | Security · Bugs · Performance · Accessibility · Maintainability |
| path + line | Inspect before treating as real |
| `id` / `fixGroupId` | Dedupe one root-cause fix |
| message / help | Starting point, not a mandate |

Group by `fixGroupId` so one fix is not applied N times.

When a rule is unclear:

```bash
npx -y "react-doctor@${REACT_DOCTOR_VERSION}" why <file>:<line>
npx -y "react-doctor@${REACT_DOCTOR_VERSION}" rules explain <plugin>/<rule>
```

Or fetch the official prompt once per unique rule (do not paste
repository-wide copy prompts into a file):

`https://www.react.doctor/prompts/rules/<plugin>/<rule>.md`

Use `## Validation prompt` for applicability and `## Fix prompt` for the
edit. HTTP 404 → local `rules explain` only.

Read `.react-doctor/false-positives.md` when present. A suppression counts
only when every documented predicate is observed in the cited file.

## Modes

### Report (default)

Inspect cited files enough to drop false positives. Then report. Do not
edit.

### Fix (only if asked, or orchestrator control step)

1. Confirm each diagnostic against the cited file.
2. Implement **error** diagnostics first, in this order: Security → Bugs →
   Accessibility → other errors. Smallest change that satisfies the rule in
   this codebase’s existing patterns.
3. Warnings: only when the user asked, or they are the same root cause as
   an error you are already fixing.
4. Skip unless the user explicitly asked:
   - design-tagged / creative-direction rules
   - Performance findings that are not proven correctness bugs
   - React Native fixes that need native deps, Pods, Gradle, or an
     architecture migration
   - Manifest / lockfile edits, except when the canonical fix is a
     dependency change
5. Do not add `startTransition` as a debounce, do not strip memoization
   just because the compiler is on, and do not suppress hydration warnings
   as a flicker fix.
6. Rescan with the **same** executable, version, scope, project, and
   categories. A finding is fixed only when it disappears and no new
   error appeared in an unfiltered rescan of the same files.
7. Run the repo’s real ship gate for the files you touched.

## Orchestrator control step

Used by `pr-orchestrator-generic` (and the call-analyzer overlay) after
implement, before the draft PR. Fail-open: never `agent-failed` because
this scanner is missing, flaky, or the repo is not React.

1. Detect React (`react` / `react-native` / `preact` / `expo` in the app
   `package.json`). None → report `skipped: no React` and stop this skill.
2. Scan **introduced** issues only:

   ```bash
   npx -y "react-doctor@${REACT_DOCTOR_VERSION}" \
     --json --yes --blocking none \
     --scope changed --include-untracked \
     --base "origin/${ORCH_BASE_BRANCH:-main}" \
     --no-supply-chain \
     ${PROJECT_ARGS} \
     > "$RUN_DIR/report.json"
   ```

3. Schema / `ok` / coverage failure → report skip reason; do not block.
4. Must-fix this pass: **new `error`** diagnostics in Security, Bugs, or
   Accessibility on files this branch touched. One implementer pass, then
   one rescan with the same command.
5. Remaining errors / warnings: note them for the PR comment. Do not open
   a second review loop. Do not fail the ship.
6. Then run **shadscan** only if official shadcn is present — follow
   `shadscan` → *Orchestrator control step*. Do not copy shadscan flags here.

## Unsupported

Use this shape and stop:

```text
react-doctor cannot audit this repo. It scans React, Preact, React Native,
Next, Vite React, Expo, TanStack Start, …

This tree looks like {Vue / Svelte / no React} ({evidence: dependency}).
No scan, no invented checklist.
```

## Report to the user

```markdown
## react-doctor — {package or project} ({framework / React version})

**Score:** {summary.score}/100 · scanner {version} · schema {schemaVersion}
**Scope:** {full | changed | files} · base {ref or n/a}
**Coverage:** {complete | incomplete + reason}

### By category
{error/warning counts per category, or “clean”}

### Errors (fix these)
| Rule | File:line | Category | Note |
|…|

### Warnings
| Rule | File:line | Note |
|…|

### Rejected / waived
- {false positive or evidenced waiver}

### Next
- Report-only: “say **fix** to implement confirmed Errors”
- After a fix pass: before → after score + remaining rule keys
```

Do not paste the raw JSON.

## Relationship

| Skill | Role |
|-------|------|
| `shadscan` | shadcn/ui fundamentals (a11y chrome, forms, theme). Pair after this scan when official shadcn is present. |
| `pr-orchestrator-generic` | Calls this skill’s [orchestrator control step](#orchestrator-control-step) after implement. |
| `thermo-nuclear-code-quality-review` | Abstraction / file-size review. Different gate. |
