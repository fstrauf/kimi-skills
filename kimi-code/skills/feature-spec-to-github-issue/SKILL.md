---
name: feature-spec-to-github-issue
description: Transform a bug report, UX inconsistency, or feature request into a structured GitHub issue with root cause analysis, proposed architecture, file change matrix, and acceptance criteria. Use when the user reports a bug, points out inconsistent behavior, asks "why does X happen?", or requests a feature that requires codebase investigation and architectural design before implementation. Also use when the user explicitly asks to create a spec, feature specification, or GitHub issue.
---

# Feature Spec to GitHub Issue

Transform a problem description into a production-ready GitHub issue.

## Workflow

### 1. Investigate root cause

- Search the codebase for relevant code paths
- Run diagnostic queries (DB, API, logs) if needed
- Identify the exact mechanism causing the reported behavior
- Distinguish between "our bug" and "external limitation" (e.g., provider API behavior)

### 2. Check for existing patterns

Before proposing a fix:
- Search for similar logic elsewhere in the codebase
- Look for existing fallback, enrichment, or computation patterns
- Check if a canonical implementation already exists
- If multiple code paths do similar things, note the drift

### 3. Design unified architecture

If the fix involves computation, enrichment, or transformation:
- Propose a single source of truth (module/function) that all paths call
- Avoid ad-hoc helpers in endpoint files or components
- Prefer extracting reusable logic over inlining
- Reference the pattern in `references/architecture-principles.md`

### 4. Draft the GitHub issue

Use this structure:

```markdown
## Problem Statement
[What the user sees and why it's wrong/confusing]

## Root Cause
[Technical explanation with code references]

## Proposed Architecture
[New module, refactored paths, data flow]

## Files to Create/Modify
| File | Action | Description |
|---|---|---|

## Open Questions
[Product/technical decisions that need owner input]

## Acceptance Criteria
- [ ] ...
```

### 5. Create the issue

Use `gh issue create` with:
- `--title`: Concise, descriptive
- `--label`: See **Label pathway** below (critical — wrong labels strand tickets)
- `--body`: The full structured markdown

If labels don't exist, omit `--label` rather than fail.

### Label pathway (call-analyzer / pr-loop / scope-loop)

Ship machinery is **REST labels only**. The **only** implement queue is `ready`.

```text
create issue
  ├─ default: bug|enhancement + priority/P*   → scope-loop → +ready → pr-loop
  ├─ open questions remain: +needs-input       → park (no ready)
  └─ explicit "skip scope, ship now": +ready   → pr-loop directly
```

| Do | Don't |
|----|--------|
| `bug` / `enhancement` + `priority/P0`–`P3` | Use **only** `triage:ready-to-implement` (orphans the ticket) |
| Leave ship labels empty so **scope-loop** picks it up | Confuse `triage:ready-to-implement` with `ready` |
| Add `ready` only when the body is truly build-ready **and** you intend to skip scope | Add `ready` on epics / tracking issues |
| Add `needs-input` when owner decisions block | Dual-label `ready` + `needs-input` |

**`triage:ready-to-implement` is metadata, not a queue.** If you set it, also set `ready` (or leave both off and let scope-loop run). Loops auto-heal orphans → `ready`, but do not rely on that as the happy path.

Example create (default path — will enter scope-loop):

```bash
gh issue create --title "…" \
  --label "bug,priority/P1" \
  --body "…"
# do NOT add triage:ready-to-implement or ready unless intentional
```

## Principles

- **DRY**: If the codebase already has a function that does 80% of what's needed, refactor and reuse it rather than duplicating
- **Self-documenting flags**: When computing synthetic/fallback data, add a metadata flag (e.g., `_synthetic_greeks: True`) so consumers can distinguish computed from live
- **No provider pollution**: Keep provider classes thin API wrappers; enrichment happens at the consumer layer
- **Testability**: New modules should be pure functions with no side effects
- **Data repairs are part of the spec**: if the bug already wrote bad rows, specify the repair as an invariant query plus the repo's repair convention from `AGENTS.md`. In call-analyzer that is a `RepairSpec` in `ops/repairs/`, and "done" means `ops/repair.py verify <name>` exits 0. Never make "run QA, no FAIL" or a prose dry-run/apply checklist the acceptance criterion.

## When NOT to use this skill

- For one-line bug fixes (no architectural change needed)
- For documentation-only changes
- For tasks where the user explicitly says "just fix it quickly"
