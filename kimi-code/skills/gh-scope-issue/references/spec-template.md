# Spec body templates

Referenced from `SKILL.md` → *Phase 6*. Pick the form by the size you estimate. pr-orchestrator copies `## Reuse`, `## Proposed change (minimal)`, `## Implementation sketch`, `## Non-goals`, `## File change matrix`, `## Test plan` and `## Acceptance criteria` verbatim into the implementer, reviewer and verifier briefs. Keep those heading names exact.

## Short form — `Size: S`

Soft cap ~3k characters. A 30-line change does not need a 10k-character spec.

```markdown
## Problem
## Depends on
- #N — previous ship unit only (omit section if independent)
## Root cause
<violated invariant + file:line where the bad state is created; premises: confirmed / wrong, one line each>
## Five-question filter
1. Requirement: … 2. Delete: … 3. Simplify: … 4. Accelerate: … 5. Automate: …   (one line each)
## Reuse
- `path:line` — <helper/module> owns <what>; call it, don't re-implement
## Proposed change (minimal)
## File change matrix
## Test plan
## Acceptance criteria
- [ ] <criterion> — checked by: <command / E2E step / observable artifact>
## Estimate
Size: S — <one-line reason>
<details><summary>Original ticket (archived)</summary>
…
</details>
```

## Full form — `Size: M` / `Size: L`

Add the API contract section only when the issue changes an HTTP API.

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
## Reuse
- `path:line` — <helper/module/pattern> owns <what>; the implementer must call or extend it
## Proposed change (minimal)
## Implementation sketch
<!-- Key signatures and data shapes, and which file/layer each lives in.
     No full code: a sketch longer than the change has written the code. -->
## Architecture fit
## Documentation fit
## API contract
<!-- Only when the issue changes an HTTP API. Supplements, does not replace, the rest. -->
- API change: yes/no
- OpenAPI file: `<repo-relative path or not yet established>`
- Validation command: `<documented repo command or not yet established>`
- Contract delta: `<endpoints, parameters, request/response schemas, status codes, and auth changes>`
- Compatibility: additive / breaking / migration required
## File change matrix
## Test plan
<!-- Failure modes first (incl. the edge-class checklist in SKILL.md). They feed
     the design and the verifier; they are not the test list. Then only the
     scenarios that earn a test, each tagged (a) red-first repro, (b) pinned
     decision (state it in one sentence) or (c) blast radius, within the size
     budget (S ≤ 2, M ≤ 4, L ≤ 6; a decision table counts as one). Each runs on
     the real path and ends in a verifiable, repeatable artifact. Visual/layout
     bugs: browser-level check + screenshot/trace. Fake-backed tests are
     isolation tests, not E2E, and come out of the same budget. -->
## Non-goals
## Acceptance criteria
- [ ] <criterion> — checked by: <command / E2E step / observable artifact>
## QA / verification
## Estimate
Size: M|L — <one-line reason>
<!-- Only if true external gate (budget/legal) — otherwise omit -->
## Ship gate (external)
- [ ] …
<details><summary>Original ticket (archived)</summary>
…
</details>
```

## Estimate sizes

`## Estimate` **must** start with a machine-readable `Size:` line. pr-loop reads it to route models and effort (`pr-orchestrator-generic/routing.py`), including whether the correctness verifier runs on the strong tier, so size honestly.

| Size | When |
|------|------|
| `S` | ≤ 3 files, one module, no schema / API / migration change, obvious pattern to copy |
| `M` | ≤ 10 files, or crosses one boundary (UI↔API, new column, new endpoint) |
| `L` | Cross-module, data migration, `API change: yes` breaking, auth/billing/security-sensitive, or an epic child whose stack deps are still open |

Money, billing, email-sending and multi-account aggregation logic is never `S`, even when the diff is small: those are where loop-passed PRs shipped correctness bugs.
