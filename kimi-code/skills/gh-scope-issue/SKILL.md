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

---

## Pipeline (labels, REST — not Projects)

**One ship label only: `ready`.** Everything else is metadata or parking.

```text
create issue (bug/enhancement + priority — NO ship label required)
        │
        ▼
scope-loop  picks open non-epic issues NOT in:
              ready | agent-working | agent-failed | blocked | needs-input
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
| **`ready`** | This skill / scope-loop / human | **THE** pr-loop ship queue |
| `needs-input` / `blocked` | This skill | Parked — **not** ready |
| `agent-working` / `agent-failed` | pr-loop only | Ship machinery — scope-loop skips |
| `triage:ready-to-implement` | triage / agents (metadata) | **Not a queue.** If present without `ready`, scope-loop and pr-loop **auto-promote to `ready`** so tickets never sit in purgatory. Prefer setting `ready` directly when build-ready. |

Board columns are for humans only. **Do not** use `gh project item-edit` for queue status.

Profile (`pr-orchestrator-generic/profiles/<name>.env`): `REPO` / `REPO_DIR` only for this skill.

**Legacy:** `ORCH_SCOPE_REQUIRE_LABEL=1 scope-loop …` restores “only label `scoping`”.

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
# then:
pr-loop --profile pageseeds-app --agent grok
```

Skip titles matching `Epic:` / `[Epic]` — tracking epics are not ship units.
Skip issues already labeled `ready`, `agent-working`, `agent-failed`, `blocked`, or `needs-input`.

---

## Hard limits

1. **No product code** — issue metadata only.  
2. **No data-modifying SQL.**  
3. **Never close** without user confirmation (delete-candidates: recommend only).  
4. **Archive original body** in `<details>` at the bottom.  
5. **Every factual claim about code needs `file:line` from this session** — not the ticket’s word, not memory.
6. **Already-scoped = verify-only, never re-cut.** If the issue already carries a completed scope pass (body follows the Phase 6 template incl. `## Five-question filter` + archived original, or a "Scoping pass complete" comment exists): do **not** re-groom. Spot-check premises against *current* code — still true → `+ready` and stop; stale → comment what changed, `+needs-input`, stop. Every cut needs `file:line` proof the item is wrong/stale/duplicated **today**. The deletion quota applies to first-pass brain dumps — never to tickets that already survived an evidence pass, and never to shave "one more item" off a groomed split child.

---

## Root-cause-first (non-negotiable)

- **Symptom patch** = guard/null-check/UI workaround while the producer of bad state stays wrong.  
- **Root-cause fix** = change the layer that owns the invariant so the bad state cannot recur.

Name: violated invariant + `file:line` where invalid state is **created**. If you cannot, keep investigating or mark blocked — do not invent a design on an unnamed cause.

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
# - labels: ready, agent-working, agent-failed, blocked, needs-input
# (triage:ready-to-implement is NOT a skip — orphans are healed to +ready by the loop)
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
2. Explore with tools (and 1–2 explore subagents if useful): call paths, existing modules that already do ≥80% of the ask, drift/duplication.  
3. **Architecture fit:** Which module owns this? Extend it vs new parallel path? Does the fix sit in the right layer?  
4. **Documentation fit:** Primary docs for the area — contradicts / extends / clarifies / untouched? If contract changes, ticket must require doc updates or `NOTE:`/`BUSINESS RULE:` comments. If no docs, say so — do not invent a mandatory doc index for repos that lack one.  
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

Prefer **refine** a good ticket over full rewrite. Always include:

```markdown
## Problem
## Priority
## Milestone
## Current state / root cause
### Premise verification
### Symptom vs. origin
## Five-question filter
## Proposed change (minimal)
## Architecture fit
## Documentation fit
## File change matrix
## Non-goals
## Acceptance criteria
## QA / verification
## Estimate
<details><summary>Original ticket (archived)</summary>
…
</details>
```

Acceptance must include: fix addresses origin (`file:line`), not only the symptom.

### Phase 7 — Publish (REST only)

1. `gh issue edit N --body-file …`  
2. Milestone if assigned.  
3. Short comment: premise verdict, origin, deleted scope, estimate.  
4. **Labels:**

| Outcome | Labels |
|---------|--------|
| Build-ready | `-scoping` `+ready` |
| Needs owner input / blocked | `-ready` if present; `+needs-input` or `+blocked`; **no** `ready` |
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
- Adding `ready` to epics or delete-candidates  
- Implementing the feature “to verify” the scope  

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
