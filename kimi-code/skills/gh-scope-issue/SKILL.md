---
name: gh-scope-issue
description: Investigate a rough GitHub issue from the project board's "Scoping" column and refine it into a build-ready spec — verified against the current codebase, root-cause gated (symptom vs. origin), deletion-first (SpaceX algorithm), minimal architecture with a complexity budget, file change matrix, acceptance criteria. Use when the user says "scope this issue", "refine issue #N", "work through the scoping tickets", "groom the backlog", or wants a rough idea investigated before implementation.
---

# GitHub Issue Scoper

Turn rough tickets in the **Scoping** column of the GitHub project board into implementation-ready issues that `pr-orchestrator` can pick up and ship. This skill investigates and refines — it never implements.

Pipeline position: **`gh-scope-issue`** (Scoping → Ready) → `pr-orchestrator` (Ready → shipped). For ad-hoc user-reported problems that create *new* issues, `feature-spec-to-github-issue` remains the entry point.

## When to use

- A ticket in the project board's Scoping column needs investigation before anyone can build it.
- The user says "scope issue #N", "refine the scoping tickets", "is this ticket actually worth building?".
- A rough idea must be checked against the current codebase: is the premise still true, does something already solve it, what is the minimal change?

## Invocation

```
/skill:gh-scope-issue            # pick the top ticket from the Scoping column
/skill:gh-scope-issue <number>   # scope a specific issue
```

Non-interactive (single autonomous turn):

```bash
kimi -p "/skill:gh-scope-issue 613" --output-format stream-json
```

Batch (scope every ticket in the Scoping column, one isolated session each):

```bash
bash ~/.kimi-code/scripts/scope-all.sh   # run from the repo root
```

## Required tools

- `Bash` for `gh`, git, and read-only diagnostics
- `Agent` (explore subagents) for isolated codebase investigation
- `TodoList` for progress tracking
- `TaskOutput` to wait for background subagents in non-interactive mode

## Preconditions

- Inside the target git repository with a GitHub remote.
- `gh` authenticated. **Board access needs extra scopes (one-time):** if `gh project item-list 4 --owner @me --limit 1` fails with `missing required scopes [read:project]`, tell the user to run:
  ```bash
  gh auth refresh -s read:project,project
  ```
  Do not block the investigation on board access: if the scopes are unavailable, scope the issue anyway and note in the final report that the card was not moved.
- `AGENTS.md` at the repo root — read it before proposing anything. Its conventions (cost-basis rule, position categories, unified endpoints, API contract discipline, DB safety, golden tests) are hard constraints on every proposal.

## Hard limits

1. **No code changes.** The output is an edited GitHub issue, not a branch. If the ticket turns out to be a trivial fix, say so in the report — still don't fix it.
2. **No data-modifying SQL.** Investigation is SELECT-only, via `./scripts/db_query_safe.sh "SELECT ..."` when a DB check is genuinely needed.
3. **Never close an issue** without explicit user confirmation in the current session. Delete-candidates get a recommendation with evidence, not a close.
4. **Preserve the original ticket text** when rewriting the body (archive it in a collapsed block at the bottom).
5. **Every claim about the code needs evidence** — `file:line` references from actually reading the code in this session, never from memory or from the ticket's say-so.

## The filter: five questions, in order

Adapted from SpaceX's engineering algorithm. Apply all five, in order, and record each answer in the refined issue. Most of the value is in steps 1–2. Two gates sit between the questions: the verdict taxonomy at the end of Phase 2 (is this a valid problem, and is the requested solution the right one?) and the root-cause gate in Phase 3 (is the ticket aimed at the cause, in the layer that owns it?). A ticket that fails a gate gets reframed, not built.

1. **Make the requirement less dumb.** Restate the ticket as the underlying user problem, not the requested solution. Who actually needs this? What breaks if nothing happens for 3 months? Are the ticket's assumptions about the code still true — verify each one by reading the code. If the premise is wrong or stale, the scoping outcome is *reframe* (or *delete*), not *build*.
2. **Delete the part or process step.** Can this be closed outright? Does existing code already do it (search first)? Would a config change, a copy change, or deleting dead code solve it? If the final proposal removes nothing, explain why nothing could be removed. Rule of thumb: "if you're not adding back 10% of what you deleted, you didn't delete enough."
3. **Simplify / optimize — only what survives step 2.** The most common senior-engineer error is optimizing a thing that shouldn't exist. Design the minimal change: reuse the canonical module (check `AGENTS.md` for mandated ones — e.g. `core/portfolio/cost_basis.py`, `core.portfolio.categories`, `@/lib/api-types.generated.ts`), one source of truth, no new abstraction for a single call site. **Complexity budget:** list everything the surviving scope adds permanently — flags, config keys, endpoints, schema columns, special-case branches. Each must justify its lifetime maintenance cost; prefer removing a special case over adding one. If the budget is long relative to the problem's value, the scope is still too big.
4. **Accelerate cycle time.** For process/workflow tickets: does the proposal shorten the loop (fewer steps, faster checks, less manual QA)? If the ticket makes a recurring loop *longer*, flag it.
5. **Automate — last.** Only if steps 1–4 leave a repeated manual process worth automating. Automating a dumb process just makes dumb faster.

## Workflow

### Phase 0 — Lock context

1. Call `CreateGoal` with objective: `Scope GitHub issue #<N> (or the top Scoping ticket) into a build-ready spec: verify the premise against the codebase, apply the five-question filter, rewrite the issue body, and move the project card out of Scoping`.
2. `gh repo view --json nameWithOwner -q .nameWithOwner` → record `<repo>`.
3. Board discovery (best-effort, skip gracefully on scope errors):
   ```bash
   gh project view 4 --owner @me --format json        # → project id (PVT_...)
   gh project field-list 4 --owner @me --format json  # → Status field id + option ids
   gh project item-list 4 --owner @me --format json --limit 200
   ```
   From the field list, capture the `Status` field id and the option ids for `Scoping` and the target column — prefer `Ready`, else `Todo`. Never move a card to `In Progress`; that transition belongs to `pr-orchestrator`.
4. Create a `TodoList`: Pick ticket · Interrogate requirement · Investigate codebase · Delete-before-build pass · Draft refined issue · Update issue + move card.

### Phase 1 — Pick the ticket

**Issue number passed:**
- `gh issue view <N> --json number,title,body,labels,state,url,comments`
- If the issue is closed, stop and report.
- Find its project item in the item-list (`content.number == N`, `content.repository == <repo>`); record the item id. If it's not on the board, proceed anyway and note it.

**No number passed:**
- Filter board items to the Scoping column **and** `content.repository == <repo>` — the board is user-level and may hold other repos' issues. Match the status name case-insensitively: boards name it `Scoping` or `scoping`.
- Present the top 3 in board order (top of column first) with title + one-line gist, and ask the user which to scope. In non-interactive mode, take the first one.
- If the Scoping column is empty for this repo, report that and stop.

### Phase 2 — Interrogate the requirement (question 1)

1. Restate the ticket in one sentence as a user problem: who hurts, when, how badly.
2. List every factual premise the ticket makes about the code ("there is no way to add contracts today", "the sync overwrites snapshots"). Verify each premise with `Grep`/`Read`. Mark each: **confirmed** (with `file:line`), **wrong** (with evidence), or **unverifiable**.
3. Check for duplicates and prior art:
   ```bash
   gh issue list --search "<keywords>" --state all --limit 10
   gh pr list --search "<keywords>" --state all --limit 10
   ```
4. Decide the verdict — exactly one of:
   - **Valid problem, fitting solution** → continue to Phase 3.
   - **Valid problem, wrong solution** → reframe around the problem, not the requested fix; continue.
   - **Symptom of a deeper issue** → flag it now; the root-cause gate in Phase 3 decides whether scope redirects to the cause (possibly a different ticket).
   - **Stale premise / not a real problem** → delete candidate: recommend closing, with evidence (recommendation only, per hard limit 3).
   Separately: if a duplicate exists, link the canonical issue and recommend closing this one.

### Phase 3 — Investigate the codebase

1. Read `AGENTS.md`. For any touched subsystem, follow its doc routing (`AI_DOCS_INDEX.md`; e.g. read `docs/d_FLEX_TRADE_RULES.md` before proposing changes to `core/services/` or `core/portfolio/`).
2. **Documentation fit checkpoint.** For every code area the ticket touches, look up its primary doc in `docs/AI_DOCS_INDEX.md`. Record each primary doc and answer:
   - Does this change alter a documented assumption, row shape, invariant, or external-API mapping?
   - If yes, the ticket must include updating the primary doc or adding `BUSINESS RULE:` / `NOTE:` comments that link to it.
   - If no primary doc exists for a touched area, the ticket should add one to `AI_DOCS_INDEX.md` (and create the doc if the area is non-trivial).
   - If the change is purely mechanical and touches no documented contract, note "no doc impact."
3. Spawn one or two **explore subagents** with precise questions — one question per agent, e.g.:
   - "Find every code path that lets a user add an option contract to the compare view. For each: `file:line`, trigger, required data."
   - "How does SnapTrade sync currently merge fetched positions into the persisted snapshot? Report the merge function, where partial/degraded fetch responses are detected (if anywhere), and `file:line` for each."
   In non-interactive mode run them in the background and wait with `TaskOutput(block=true)`.
3. If a data check is needed (e.g. "does the bug actually occur in prod data?"), use `./scripts/db_query_safe.sh "SELECT ..."` — SELECT only.
4. **Root-cause gate — symptom or cause?** Name the invariant that is violated and the place where the invalid state is *created* (`file:line`) — usually not where it *surfaces*. The fix location defaults to the origin, not the crash site: a guard or null-check where things blow up while the producer of the bad state stays untouched is a symptom patch, and the ticket gets reframed around the cause. If you cannot name the invariant, keep digging or mark it unverifiable — do not design around an unnamed cause.
5. Produce, in writing:
   - **Current state / root cause** with `file:line` evidence, including the symptom-vs-origin distinction from the gate.
   - **Existing coverage**: code that already does ≥80% of the ask.
   - **Drift**: multiple code paths doing similar things (candidates for unification, per `AGENTS.md` unified-endpoints rule).
   - **Architecture fit**: which canonical module owns this concern per `AGENTS.md`, and whether the natural fix extends it or adds a parallel path (parallel paths need explicit justification). Challenge the ticket's implied placement: the fix should land in the layer that owns the violated invariant — a UI patch for a data-layer bug is a reframe, not a build. If the natural fix lands outside the canonical owner, that is a smell: either the ticket is mis-scoped or the architecture has drifted; say which.

### Phase 4 — Delete-before-build pass (questions 2–5)

Write down, before designing anything:

1. **Deletion candidates** — dead code this ticket should remove instead of extend; config/copy changes that would make the ticket evaporate; existing features that already solve it. If none exist, state why.
2. **Simplification** — the minimal architecture: modules reused, single source of truth, what is deliberately *not* built (these become Non-Goals), plus the complexity budget from question 3: every permanent addition (flag, config key, endpoint, column, branch) listed with its justification.
3. **Acceleration** — for process tickets: loop before/after.
4. **Automation** — anything worth automating only after 1–3, or explicitly "nothing to automate".
5. **Split check** — if the surviving scope contains more than one independently shippable outcome, propose child issues in the report (do not create them without user confirmation).

### Phase 5 — Draft the refined issue body

**If the ticket is already well-scoped** (structured body, verified claims, acceptance criteria) and your verification confirms it: refine rather than rewrite — add the premise-verification table, the five-question filter, resolve any open questions with explicit recommendations, and archive the original body. Don't churn a good ticket for format's sake.

Write the body to `~/.kimi-code/tmp/scoped-issue-<N>.md` (create the dir if needed), using this structure:

```markdown
## Problem
[Verified user problem: who, when, impact. One paragraph.]

## Current state / root cause
[How the code behaves today, with file:line evidence. Which of the original ticket's premises were confirmed / wrong.]
**Symptom vs. origin:** [where the problem surfaces vs. the file:line where the invalid state is created; the violated invariant. The fix targets the origin.]

## Five-question filter
1. **Requirement**: [restatement; verdict — valid + fitting solution / valid + wrong solution / symptom of a deeper issue / not a real problem]
2. **Delete**: [what was removed from scope, or why nothing could be]
3. **Simplify**: [why this is the minimal change; complexity budget — permanent additions (flags, config, endpoints, columns, branches) and their justification]
4. **Accelerate**: [cycle-time effect, or n/a]
5. **Automate**: [automation, or "nothing to automate"]

## Proposed change (minimal)
[Bullets: architecture in the fewest moving parts; reuse of existing modules; data flow.]

## Architecture fit
[Canonical module per AGENTS.md that owns this; why this extends it rather than adding a parallel path; why the fix belongs in this layer — the one that owns the violated invariant.]

## Documentation fit
[Primary docs for touched code areas from `docs/AI_DOCS_INDEX.md`; what doc updates or `BUSINESS RULE:` / `NOTE:` comments are required; whether a new primary doc is needed. Explicitly state "no doc impact" if the change touches no documented contract.]

## File change matrix
| File | Action | Why |
|---|---|---|

## Non-goals
[Explicitly out of scope — the deletions from question 2.]

## Acceptance criteria
- [ ] ...

## QA / verification
[How to verify the fix end-to-end. For portfolio/pipeline tickets, include a line `QA user: <email>` with the affected real user — pr-orchestrator's real-user QA gate reads it from the issue body.]

## Estimate
[S / M / L + one-line reasoning]

<details><summary>Original ticket (archived)</summary>

[Verbatim original body]

</details>
```

### Phase 6 — Update the issue and move the card

1. `gh issue edit <N> --body-file ~/.kimi-code/tmp/scoped-issue-<N>.md`
2. Post a short investigation comment:
   ```bash
   gh issue comment <N> --body "🔍 Scoped: premise <confirmed/reframed>. Removed from scope: <X>. Estimate: <S/M/L>. Card → <Ready|Todo>. See rewritten body for evidence and the five-question filter."
   ```
3. Move the card (skip with a note if board scopes are missing, the item wasn't found, or the card is already in the target column):
   ```bash
   gh project item-edit --project-id <PVT_id> --id <PVTI_item_id> \
     --field-id <Status_field_id> --single-select-option-id <Ready_option_id>
   ```
   If the board has a `Size` field (check the field list from Phase 0), also set it from the estimate — same command with the Size field id and the matching option id.
4. **Delete-candidate outcome:** do *not* move the card to Ready and do *not* close the issue. Post the evidence as a comment recommending closure (or a smaller replacement ticket) and leave the card in Scoping for the user to decide.
5. Mark todos done.

## Outcomes

Every run ends in exactly one of:

- **Ready** — premise verified, scope minimized, body rewritten, card moved to Ready/Todo.
- **Needs owner input** — open questions block scoping; they're listed in the issue's Open Questions and in the report.
- **Delete candidate** — evidence says close or shrink drastically; recommendation posted, card left in Scoping.
- **Split recommended** — proposed child issues listed in the report; user decides.

## Output expectations

Report at the end:
- Issue number, title, URL, and outcome (one of the four above)
- Premise verdicts: what was confirmed, what was wrong (with `file:line`); whether the fix targets the root cause (origin) or a symptom
- Documentation fit: primary docs for touched areas from `docs/AI_DOCS_INDEX.md`, required doc updates or comments, or "no doc impact"
- What was deleted from scope (question 2) — or why nothing could be
- Estimate and the canonical module the fix should live in
- Card status (moved to X / not moved + reason)
- Open questions for the owner, if any
- Suggested next step: `/skill:pr-orchestrator <N>` when the outcome is Ready
