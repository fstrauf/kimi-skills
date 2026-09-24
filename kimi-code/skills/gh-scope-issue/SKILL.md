---
name: gh-scope-issue
description: >-
  Deep-groom a rough GitHub issue into a build-ready spec: codebase deep dive
  after the initial brain dump, deletion-first simplification, architecture and
  documentation fit, root-cause (not symptom) fix, file matrix, acceptance
  criteria. REST labels only (scoping → ready). Never implements product code.
  Use for "scope issue #N", "scope all", or scope-loop.
---

# GitHub Issue Scoper

**This is not a first-pass brain dump.** Assume the issue already has *some* intent (human, feature-spec skill, or rough filing). Your job is the **second, stricter pass**:

> Dive the **current codebase and docs**, then rewrite the ticket so an implementer can ship a **simple, pragmatic change that fits existing patterns** — or recommend delete/split/reframe.

**Never implement product code.** Only: issue body, comments, labels, milestone.

---

## Mental model

```text
Rough issue (intent + maybe wrong solution)
        │
        ▼
┌─────────────────────────────────────────┐
│  gh-scope-issue                         │
│  • Verify every premise with file:line  │
│  • Delete half the ask if possible      │
│  • Fit architecture + docs              │
│  • Minimal file matrix + acceptance     │
└─────────────────────────────────────────┘
        │
        ▼
ready → pr-loop implements the contract
```

| Pass | Skill | Question |
|------|--------|----------|
| 1. Brain dump | human / feature-spec / rough ticket | What do we *want*? |
| 2. **Scope (this)** | `gh-scope-issue` | What should we *actually build*, given the code today? |
| 3. Ship | `pr-orchestrator-generic` | Build exactly that, review, land |

If you only rephrase the original ticket without reading the repo, **you failed**.

**Label machine (REST):** [docs/github-loop.md](../../../docs/github-loop.md). This skill sets `ready` / `needs-input` / `blocked` only as that doc defines.

---

## Pipeline (labels, REST — not Projects)

**One ship label only: `ready`.** Everything else is metadata or parking.

```text
create issue (bug/enhancement + priority — NO ship label required)
        │
        ▼
scope-loop  picks open non-epic issues NOT in:
              ready | agent-working | agent-failed | blocked | needs-input
              | awaiting-merge | open Closes #N PR
        │     (also heals triage:ready-to-implement orphans → +ready first)
        ▼
this skill  refines body → -scoping +ready   (unless blocked / needs-input)
        │
        ▼
pr-loop     ready → implement → land → close
```

| Label | Who sets it | Meaning |
|--------|-------------|---------|
| *(none)* | — | Default: **needs scope** until `ready` |
| `scoping` | scope-loop (while in flight) | Visibility only — **not required to enqueue** |
| **`ready`** | This skill / scope-loop / human | **THE** pr-loop ship queue — **spec is build-ready** |
| `needs-input` | This skill | **Human must answer** (product/legal/budget decision). Parked. |
| `blocked` | This skill / human | **External stop only** (vendor, legal hold, explicit ship gate). **Rare.** Parked. |
| `agent-working` / `agent-failed` | pr-loop only | Ship machinery — scope-loop skips |
| `awaiting-merge` | pr-loop (PR open, `ready` stripped) | Merge pending — scope-loop **skips** (do not re-groom) |
| `triage:ready-to-implement` | triage / agents (metadata) | **Not a queue.** If present without `ready`, scope-loop and pr-loop **auto-promote to `ready`**. |

Board columns are for humans only. **Do not** use `gh project item-edit` for queue status.

Profile (`pr-orchestrator-generic/profiles/<name>.env`): `REPO` / `REPO_DIR` only for this skill.

**Legacy:** `ORCH_SCOPE_REQUIRE_LABEL=1 scope-loop …` restores “only label `scoping`”.

---

## Dependencies vs park labels (critical — do not conflate)

**Scoped ≠ mergeable on main right now.** Scope answers: “Is the contract clear enough to implement?”  
Ship order answers: “What lands first?” — that is **pr-loop’s job**, not a reason to withhold `ready`.

| Situation | What to do | Labels |
|-----------|------------|--------|
| Spec is clear; needs columns/API from sibling ticket #N that is open or not on main yet | Document order; **still mark ready** | `+ready` — **never** `blocked` |
| Spec is clear; epic lists ship order 1→2→3 | Same; **one previous child** in Depends-on (epics are one GitHub stack) | all children `+ready` after scope |
| Product/budget/legal question only a human can answer | Park | `+needs-input` (preferred) or `+blocked` with `## Ship gate (external)` |
| True external freeze (vendor outage, legal hold) | Park | `+blocked` + short reason in body |

### Forbidden (fail the skill)

- Labeling `blocked` because “#110 isn’t merged yet” / “schema columns don’t exist on main yet” / “depends on open sibling”
- Withholding `ready` so the human must re-run scope-loop after every merge
- Using `blocked` as a poor-man’s queue for epic child order

### Required when work is ordered

Always include a machine-parseable section (pr-loop topologically sorts on this):

```markdown
## Parent epic
#268

## Depends on
- #272 — previous layer only (this is stack PR3)
```

Rules for the list:

- Only **ship issues** (other non-epic tickets). Do **not** list parent epics as Depends-on (epics never ship). Put the epic under `## Parent epic`.
- Prefer issue numbers (`#110`), not free text alone.
- Each dep is a **bullet that starts with `#N`**. Optional prose after that number is fine.
- Do **not** put other `#N` in that section (no “open as PR #281”, no “Do not list #268”). Those used to be parsed as extra deps.
- Cutover / “Vue stays until #279” notes belong in Non-goals, not Depends-on.
- If there are **no** code dependencies, omit the section (or write `## Depends on` / `_None_`).
- **Epic children = one GitHub stack (a line).** Each child depends on **exactly one** previous child, in ship order. Soft / “preferred before” / parallel notes go in Non-goals. Two children that both depend only on the same ancestor become sibling PRs; GitHub will stack only one of them. Independent work that can ship in either order is a second stack, or waits for the first to land. See [docs/github-loop.md](../../../docs/github-loop.md).

### External gates only

If something truly must not ship until a human acts outside the repo:

```markdown
## Ship gate (external)
- [ ] Places API budget approved (~$X one-off)
```

Then `+needs-input` or `+blocked` — **not** because of open GitHub issues.

### Mental model

```text
scope-loop  →  every clear child gets +ready (with ## Depends on)
pr-loop     →  topo-sort by Depends on; implement/stack in order; land
human       →  only needs-input / true external blocked
```

---

## Invocation

```
/skill:gh-scope-issue <number>
/skill:gh-scope-issue all          # same queue as scope-loop (open non-epics needing scope)
```

```bash
# No manual label needed — create issues, then:
scope-loop --profile pageseeds-app --agent grok
scope-loop --profile pageseeds --agent grok
scope-loop --profile coffee --agent claude     # cost-routed (see pr-orchestrator-generic/routing.py)
# then:
pr-loop --profile pageseeds-app --agent grok
```

Skip titles matching `Epic:` / `[Epic]` — tracking epics are not ship units.
Skip issues already labeled `ready`, `agent-working`, `agent-failed`, `blocked`, `needs-input`, or `awaiting-merge`.
Skip issues that already have an open PR closing them (`Closes`/`Fixes`/`Resolves #N`, or `feature/<N>-` branch) — same matching as pr-loop.

---

## Hard limits

1. **No product code** — issue metadata only.  
2. **No data-modifying SQL.**  
3. **Never close** without user confirmation (delete-candidates: recommend only).  
4. **Archive original body** in `<details>` at the bottom.  
5. **Every factual claim about code needs `file:line` from this session** — not the ticket’s word, not memory.
6. **Already-scoped = verify-only, never re-cut.** If the issue already carries a completed scope pass (body follows the Phase 6 template incl. `## Five-question filter` + archived original, or a "Scoping pass complete" comment exists): do **not** re-groom. Spot-check premises against *current* code — still true → `+ready` and stop; stale → comment what changed, `+needs-input`, stop. Every cut needs `file:line` proof the item is wrong/stale/duplicated **today**. The deletion quota applies to first-pass brain dumps — never to tickets that already survived an evidence pass, and never to shave "one more item" off a groomed split child.

---

## Data repairs (tickets that fix existing rows)

When the fix must also correct data the bug already wrote (cleanup, backfill, dedupe), the repair is part of the contract, not a post-merge prose checklist:

- **Scope it per the repo's repair convention** (read `AGENTS.md`). In call-analyzer that means a `RepairSpec` in `ops/repairs/<name>.py`; the lifecycle is in `ops/README.md`.
- **Name the invariant as a query:** which rows must not exist after the repair. That query is the spec's `targets`, and "remaining = 0" is the outcome.
- **Acceptance is a machine-checkable command.** In call-analyzer: `uv run python ops/repair.py verify <name>` exits 0.
  - **Never** use a fleet QA exit code, "no FAIL in the QA run", or a step where a human pastes output.
  - Fleet QA carries unrelated known failures. If a QA check is still cited, show with `file:line` that it actually reads the repaired rows (#1917's "no D1 FAIL" criterion could not move at all).
- **Split the work.** The implementer ships the code fix that stops new bad rows, together with the spec. The human `apply` happens after deploy and is not an implementer step.
- **Test plan:** the E2E seeds synthetic rows in a rolled-back transaction and runs plan → apply → verify scoped to those users. The production artifact is the read-only `plan` / `verify` output.

---

## Root-cause-first (non-negotiable)

- **Symptom patch** = guard/null-check/UI workaround while the producer of bad state stays wrong.  
- **Root-cause fix** = change the layer that owns the invariant so the bad state cannot recur.

Name: violated invariant + `file:line` where invalid state is **created**. If you cannot, keep investigating or mark `needs-input` — do not invent a design on an unnamed cause. Do **not** use `blocked` for missing sibling work.

---

## Five-question filter (in order — record in the issue)

1. **Less dumb requirement** — Restate as user problem, not requested solution. Who hurts? What if we wait 3 months? Are premises still true *in the code*?  
2. **Delete** — Close entirely? Already exists? Config/copy only? Kill dead scope. If you delete nothing, explain why. Rule of thumb: if you do not add back ~10% of what you cut, you did not cut enough.  
3. **Simplify** — Only what survives (2). Minimal change; reuse canonical modules/patterns from this repo; one source of truth. **Complexity budget:** list permanent additions (flags, endpoints, columns, branches) with justification. Prefer removing special cases over adding them.  
4. **Accelerate** — Does this shorten a recurring loop? If it lengthens process for no gain, flag it.  
5. **Automate last** — Only if 1–4 leave a repeated manual process worth automating.

---

## Workflow

### Phase 0 — Context

1. Resolve `REPO` / `REPO_DIR` (profile or `gh repo view`).  
2. Load issue: title, body, labels, comments, milestone.  
3. Read repo agent docs (`AGENTS.md`, `AGENT.md`, `Claude.md`, design docs the ticket or AGENT points to).  
4. Todos: Interrogate · Investigate · Delete-pass · Draft · Update issue + labels.

### Phase 1 — Pick (if no number / all mode)

Same queue as `scope-all.sh` (default):

```bash
# Open issues, then filter out:
# - titles Epic: / [Epic]
# - labels: ready, agent-working, agent-failed, blocked, needs-input, awaiting-merge
# - open PR that closes the issue (Closes/Fixes/Resolves #N or feature/N- branch)
# (triage:ready-to-implement is NOT a skip — orphans are healed to +ready by the loop)
# Implementation: pr-orchestrator-generic/scope_queue.py (same as scope-loop)
gh issue list --repo $REPO --state open --limit 100 --json number,title,labels
```

Do **not** require label `scoping`. Process until empty.

### Phase 2 — Interrogate the requirement

1. One-sentence **user problem** (who, when, impact).  
2. List every factual premise in the ticket → **confirmed / wrong / unverifiable** with evidence.  
3. Duplicates / prior art: `gh issue list` / `gh pr list` search.  
4. Verdict: valid+fitting · valid+wrong solution (reframe) · symptom of deeper issue · stale/not real (delete candidate).

### Phase 3 — Codebase deep dive (the core of this skill)

1. **Find where the problem is produced**, not only where it is noticed.  
2. Explore with tools (and 1–2 explore subagents if useful, cost role `explore`: `python3 "${ORCH_ROUTING_TOOL:-$HOME/.kimi-code/skills/pr-orchestrator-generic/routing.py}" route explore --host "$ORCH_HOST"`; on Claude that is `Agent(subagent_type=loop-explorer, model=haiku)`): call paths, existing modules that already do ≥80% of the ask, drift/duplication. Keep raw file reading in the subagents and bring back only `file:line` conclusions.  
3. **Architecture fit:** Which module owns this? Extend it vs new parallel path? Does the fix sit in the right layer?  
4. **Documentation fit:** Primary docs for the area — contradicts / extends / clarifies / untouched? If contract changes, ticket must require doc updates or `NOTE:`/`BUSINESS RULE:` comments. If no docs, say so — do not invent a mandatory doc index for repos that lack one. For an HTTP API change, also identify the product repository's canonical OpenAPI file and validation command; do not require OpenAPI for non-API work.  
5. **Existing coverage:** Prefer reuse over greenfield.  
6. Write symptom-vs-origin explicitly.

### Phase 4 — Delete-before-build

Before designing:

- Deletion candidates  
- Minimal surviving design + complexity budget  
- Explicit **non-goals** (what implementers must not build)  
- Split check: more than one shippable outcome → propose children, do not mega-scope  

### Phase 5 — Priority and milestone

- Priority `P0`–`P3` with one-line rationale (in body; optional `priority/P*` labels).  
- Prefer an existing open milestone; do not create milestones without user approval — propose if needed.

### Phase 6 — Draft the body

Prefer **refine** a good ticket over full rewrite. Always include the core sections below; add the API contract section only when the issue changes an HTTP API:

```markdown
## Problem
## Priority
## Milestone
## Parent epic
#N
## Depends on
- #N — previous ship unit only (omit section or use _None_ if independent)
## Current state / root cause
### Premise verification
### Symptom vs. origin
## Five-question filter
## Proposed change (minimal)
## Architecture fit
## Documentation fit
## API contract
<!-- Include this section only when the issue changes an HTTP API. It supplements, and does not replace, the rest of this specification. -->
- API change: yes/no
- OpenAPI file: `<repo-relative path or not yet established>`
- Validation command: `<documented repo command or not yet established>`
- Contract delta: `<endpoints, parameters, request/response schemas, status codes, and auth changes>`
- Compatibility: additive / breaking / migration required

## File change matrix
## Non-goals
## Acceptance criteria
## QA / verification
## Estimate
Size: S|M|L — <one-line reason>
<!-- Only if true external gate (budget/legal) — otherwise omit -->
## Ship gate (external)
- [ ] …
<details><summary>Original ticket (archived)</summary>
…
</details>
```

`## Estimate` **must** start with a machine-readable `Size:` line. pr-loop reads it to choose model tier and effort (`pr-orchestrator-generic/routing.py`), so size honestly. Over-sizing burns quota; under-sizing only costs an escalated retry.

| Size | When |
|------|------|
| `S` | ≤ 3 files, one module, no schema / API / migration change, obvious pattern to copy |
| `M` | ≤ 10 files, or crosses one boundary (UI↔API, new column, new endpoint) |
| `L` | Cross-module, data migration, `API change: yes` breaking, auth/billing/security-sensitive, or an epic child whose stack deps are still open |

Acceptance must include: fix addresses origin (`file:line`), not only the symptom. When `API change: yes`, acceptance must also require that the OpenAPI document describes the intended boundary and that the product repository's documented contract validation passes.

### Phase 7 — Publish (REST only)

1. `gh issue edit N --body-file …`  
2. Milestone if assigned.  
3. Short comment: premise verdict, origin, deleted scope, estimate.  
4. **Labels:**

| Outcome | Labels |
|---------|--------|
| Build-ready (incl. when siblings must land first) | `-scoping` `+ready`; body has `## Depends on` if ordered |
| Needs **human** input (budget/product/legal **only** — not “I am unsure”) | `-ready` if present; `+needs-input`; **no** `ready` |
| True external freeze only | `+blocked` + `## Ship gate (external)`; **no** `ready` |
| Open sibling / “not on main yet” | **Still `+ready`** — never `blocked` for this |
| Delete candidate | recommend close in comment; **no** `ready` (optional `+needs-input`) |
| Tracking epic | never `ready` (scope-loop should not pick epics) |

5. **No** `gh project` status/priority edits.

`scope-loop` after success: removes `scoping`, adds `ready` **unless** the issue has `blocked` or `needs-input`.

---

## Anti-patterns (fail the skill)

- Rewriting the brain dump without opening the repo  
- Expanding scope (“while we’re here…”)  
- Rubber-stamping a wrong solution because the ticket asked for it  
- Shipping architecture that duplicates an existing module  
- Requiring or inventing an OpenAPI file for work that does not cross an HTTP API boundary  
- Adding `ready` to epics or delete-candidates  
- Implementing the feature “to verify” the scope  
- **`blocked` because a dependency issue is still open or columns are not on main yet** — use `## Depends on` + `ready`  
- Forcing the human to merge one child, re-run scope-loop, then the next  
- Epic children that all depend on the same ancestor (sibling PRs). GitHub stacks are a line — each child depends on the **previous** child only.

---

## Outcomes

| Outcome | Meaning |
|---------|---------|
| **Ready** | Contract is implementable; `ready` set |
| **Needs owner input** | Open questions block; stays `scoping` |
| **Delete candidate** | Evidence to close or shrink drastically |
| **Split recommended** | Children listed; user creates them |

## Report to user

Number, title, URL · outcome · premises confirmed/wrong · origin `file:line` · what was deleted · architecture/doc fit one-liners · estimate · labels · next: `pr-loop` if ready.
