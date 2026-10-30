---
name: gh-scope-issue
description: >-
  Deep-groom a rough GitHub issue into a build-ready spec: codebase deep dive
  after the initial brain dump, deletion-first simplification, architecture and
  documentation fit, root-cause (not symptom) fix, the existing helpers to reuse
  and patterns to follow (better ideas become follow-up refactor issues), file matrix, checkable acceptance criteria, and a failure-mode-first test
  contract (tests pin decisions only, size budget, red-first reproduction for
  bugs, E2E-preferred, verifiable artifact, no post-hoc or per-method tests).
  Spec length scales with size. REST labels only
  (scoping → ready). Never implements product code.
  Use for "scope issue #N", "scope all", or scope-loop.
---

# GitHub Issue Scoper

**This is not a first-pass brain dump.** Assume the issue already has *some* intent (human, feature-spec skill, or rough filing). Your job is the **second, stricter pass**:

> Dive the **current codebase and docs**, then rewrite the ticket so an implementer can ship a **simple, pragmatic change that fits existing patterns** — or recommend delete/split/reframe.

**Never implement product code.** Only: issue body, comments, labels, milestone.

| Pass | Skill | Question |
|------|--------|----------|
| 1. Brain dump | human / feature-spec / rough ticket | What do we *want*? |
| 2. **Scope (this)** | `gh-scope-issue` | What should we *actually build*, given the code today? |
| 3. Ship | `pr-orchestrator-generic` | Build exactly that, review, verify, land |

If you only rephrase the original ticket without reading the repo, **you failed**.

**Why the design decisions belong here.** The ship loop runs on a cheaper model. Every decision you leave open (which helper to call, where code lives, what the edge cases are) gets improvised there, and comes back as a review finding or a bug. Loop data: 37% of review findings were re-implementations of a helper that already existed, and the bugs that slipped past review were edge cases nobody listed (unknown values shown as 0, multi-account aggregation, a send that faked success).

## Labels and queue

The label machine, queue rules and dependency doctrine live in [docs/github-loop.md](../../../docs/github-loop.md). Read it; do not restate it. What this skill must get right:

- **Outcome labels:** build-ready → `-scoping +ready`. A human decision is needed (product / budget / legal only, not "I am unsure") → `+needs-input`, no `ready`. A true external freeze → `+blocked` + `## Ship gate (external)`. Delete candidate or epic → never `ready`.
- **Never `blocked` for an open sibling** or "columns not on main yet". Spec is clear → `+ready` with `## Depends on`. pr-loop orders and stacks.
- **`## Depends on` format** (pr-loop parses it): each dep is a bullet starting with `#N`, ship issues only (parent epic goes under `## Parent epic`), no other `#N` in the section. No deps → omit it or write `_None_`.
- **Epic children are one stack:** each child depends on **exactly one** previous child, in ship order. Soft / parallel ordering notes go in Non-goals.
- **No `gh project` edits.** Profile (`pr-orchestrator-generic/profiles/<name>.env`): only `REPO` / `REPO_DIR` matter here.

## Invocation

```
/skill:gh-scope-issue <number>
/skill:gh-scope-issue all          # same queue as scope-loop (open non-epics needing scope)
```

```bash
scope-loop --profile coffee --agent claude     # unattended; cost-routed
```

Skip: titles `Epic:` / `[Epic]`; issues labeled `ready`, `agent-working`, `agent-failed`, `blocked`, `needs-input` or `awaiting-merge`; issues with an open PR that closes them (same matching as pr-loop, `pr-orchestrator-generic/scope_queue.py`). Do **not** require label `scoping`.

## Hard limits

1. **No product code** — issue metadata only, plus follow-up refactor issues (*Follow existing patterns*).
2. **No data-modifying SQL.**
3. **Never close** without user confirmation (delete-candidates: recommend only).
4. **Archive the original body** in `<details>` at the bottom.
5. **Every factual claim about code needs `file:line` from this session** — not the ticket’s word, not memory.
6. **Already-scoped = verify-only, never re-cut.** If the issue already carries a completed scope pass (body follows the template incl. `## Five-question filter` + archived original, or a "Scoping pass complete" comment exists): do **not** re-groom. Spot-check premises against *current* code — still true → `+ready` and stop; stale → comment what changed, `+needs-input`, stop. Every cut needs `file:line` proof the item is wrong/stale/duplicated **today**. The deletion quota applies to first-pass brain dumps — never to tickets that already survived an evidence pass, and never to shave "one more item" off a groomed split child.

## Root-cause-first (non-negotiable)

- **Symptom patch** = guard/null-check/UI workaround while the producer of bad state stays wrong.
- **Root-cause fix** = change the layer that owns the invariant so the bad state cannot recur.

Name: violated invariant + `file:line` where invalid state is **created**. If you cannot, keep investigating or mark `needs-input` — do not invent a design on an unnamed cause. Do **not** use `blocked` for missing sibling work.

## Follow existing patterns (non-negotiable)

Main usually already has a way to do this kind of change: how a route is added, how errors surface, how data is fetched, where config lives, how a job is scheduled. The spec follows it. Two ways of doing the same thing on main is worse than one mediocre way.

- **Find the precedent.** For each kind of thing the change adds (endpoint, component, query, job, migration, CLI command…), find the closest existing example and record it under `## Reuse` as a **Follow** entry: `path:line` plus what to copy (layering, error handling, naming, file location).
- **Follow it unless the new way is significantly better.** Significant means a concrete, nameable gain: a bug class removed, real duplication deleted, a measured cost. Taste, novelty and "more modern" don't count.
- **Even when it is better, this ticket follows the existing pattern.** File the better approach as a follow-up refactor issue ([docs/github-loop.md → Follow-up issues](../../../docs/github-loop.md#follow-up-issues-pattern-refactors)) and list it under `## Non-goals` (`Refactor of <pattern>: #N`).
- **Exception: the pattern is the root cause.** When the bug lives in the pattern itself, fixing it is the ticket. Say so under Root cause and list every call site in the file matrix, or file the call sites you leave out as a follow-up.
- **Two competing patterns:** name the canonical one (documented in `AGENTS.md`, then most used, then most recent) and say why.
- Precedent this skill forbids elsewhere (per-method tests, *Test contract* §8) is never a pattern to follow.

## Test contract (non-negotiable)

Scoping decides **what must be proven**, not just what must be built. Every scoped issue carries a test contract.

**What tests are for here.** The same pipeline writes the spec, the code and the tests, so a green suite only means "nothing we thought of broke". It doesn't show the feature is right. That job belongs to the independent verifier and human review. Tests have one job: **pin decisions** a later agent can't read from the code and might "fix". (KineX #945: 13 scoped scenarios and 765 integration tests were green, and a human reviewer still found two real gaps in minutes. Neither gap was on the failure-mode list.)

1. **Failure modes first.** Before designing the fix, list every way the change could fail — bad input, boundary values, concurrency, partial failure, rollback, regression in the adjacent path. Always walk this edge-class checklist and keep the ones that apply:
   - an unknown or missing value rendered as 0 / "$0" / "0.0%"
   - zero or empty denominators and start values
   - aggregation across several entities (accounts, connections, users)
   - some members of a set missing or invalid while the rest proceed silently (partly mapped, partly priced, partly sent)
   - an external call that fails but reports success; a missing key or config that silently fakes success
   - partial or transient failure that still commits state, marks work done, or sends
   - a dry run or read path that writes
   - timezone and naive-datetime mixing
   - empty lists and no rows

   The failure-mode list feeds the design, `## Reuse` and the verifier. **It is not the test list.** Most failure modes are handled by the design and checked by the verifier. They don't each get a test.
2. **Then design.** The change is the minimal thing that survives the failure-mode + delete passes.
3. **Red first for bugs.** The first Test plan scenario reproduces the bug and **fails on today's main**, with its exact command. A fix whose test never went red proves nothing. (txApp shipped the same UI fix four times because nothing reproduced the bug first.)
4. **A scenario earns a test only if it:**
   - **(a) reproduces the bug** red-first, or
   - **(b) pins a product decision** a later agent could undo without noticing ("no areas → 409", "polygon beats blocks", "landscape → 422"). Write the decision as one sentence next to the scenario, or
   - **(c) guards a high-blast-radius failure:** money, data loss or corruption, a send to users, auth and permissions.

   Request shapes, field mapping, empty states and "renders the list" are the verifier's job, not tests. Tag each scenario `(a)`, `(b)` or `(c)`.
5. **Budget by size.** New test scenarios, not counting the red-first reproduction: `S` ≤ 2 · `M` ≤ 4 · `L` ≤ 6. A decision table (one parameterised test over decision → expected outcome) counts as one scenario. Going over the budget needs one line per extra scenario saying why the verifier can't check it instead.
6. **E2E-first.** Preferred verification is an end-to-end test that exercises the real path (HTTP calls, UI flow, CLI invocation — whatever the user actually touches). **Visual or layout bugs need a browser-level check** (Playwright or the repo's equivalent) that saves a screenshot or trace; jsdom and unit tests can't see layout. When a layer has no real-path harness (e.g. no browser E2E for a web client), say so. A test driven by fakes, stubs or a recording HTTP handler is an isolation test, not E2E, whatever framework runs it. It counts against the same budget and still needs (a)/(b)/(c). For that layer, prefer a manual QA artifact (a screenshot) to one fake-backed test per failure mode.
7. **Verifiable artifact.** Every E2E test ends by producing a repeatable, checkable artifact: a command output, a file, a DB row, an API response snapshot, a screenshot — something a reviewer can re-run and compare. "Tests pass" is not the artifact.
8. **No post-hoc or per-method tests.** Never write tests after the code; they only mirror what it does. Never plan one test per method, endpoint verb or field. Repo precedent (an existing `*ServiceTests` that does this) is not a reason to copy the pattern.

If the repo has a documented test convention or ship gate (`AGENTS.md`, test tiers), the plan must fit it — the contract is E2E-first *within* the repo's own gate, not instead of it. Fitting the gate means the scenarios run inside it. It doesn't mean copying the repo's existing test volume.

## Data repairs (tickets that fix existing rows)

When the fix must also correct data the bug already wrote (cleanup, backfill, dedupe), the repair is part of the contract, not a post-merge prose checklist:

- **Scope it per the repo's repair convention** (read `AGENTS.md`). In call-analyzer that means a `RepairSpec` in `ops/repairs/<name>.py`; the lifecycle is in `ops/README.md`.
- **Name the invariant as a query:** which rows must not exist after the repair. That query is the spec's `targets`, and "remaining = 0" is the outcome.
- **Acceptance is a machine-checkable command.** In call-analyzer: `uv run python ops/repair.py verify <name>` exits 0. **Never** use a fleet QA exit code, "no FAIL in the QA run", or a step where a human pastes output. If a QA check is still cited, show with `file:line` that it actually reads the repaired rows.
- **Split the work.** The implementer ships the code fix that stops new bad rows, together with the spec. The human `apply` happens after deploy and is not an implementer step.
- **Test plan:** the E2E seeds synthetic rows in a rolled-back transaction and runs plan → apply → verify scoped to those users. The production artifact is the read-only `plan` / `verify` output.

## Five-question filter (in order — record in the issue)

1. **Less dumb requirement** — Restate as user problem, not requested solution. Who hurts? What if we wait 3 months? Are premises still true *in the code*?
2. **Delete** — Close entirely? Already exists? Config/copy only? Kill dead scope. If you delete nothing, explain why. Rule of thumb: if you do not add back ~10% of what you cut, you did not cut enough.
3. **Simplify** — Only what survives (2). Minimal change; reuse canonical modules/patterns from this repo; one source of truth. **Complexity budget:** list permanent additions (flags, endpoints, columns, branches) with justification. Prefer removing special cases over adding them.
4. **Accelerate** — Does this shorten a recurring loop? If it lengthens process for no gain, flag it.
5. **Automate last** — Only if 1–4 leave a repeated manual process worth automating.

For `Size: S`, one line per question is enough.

## Workflow

### Phase 0 — Context

1. Resolve `REPO` / `REPO_DIR` (profile or `gh repo view`).
2. Load issue: title, body, labels, comments, milestone.
3. Read repo agent docs (`AGENTS.md`, `AGENT.md`, `Claude.md`, design docs the ticket or AGENT points to).
4. Todos: Interrogate · Investigate · Delete-pass · Draft · Update issue + labels.

### Phase 1 — Pick (if no number / all mode)

Same queue as `scope-all.sh` (`pr-orchestrator-generic/scope_queue.py`): open issues minus the skips in *Invocation*. `triage:ready-to-implement` is **not** a skip — orphans are healed to `+ready` by the loop. Process until empty.

### Phase 2 — Interrogate the requirement

1. One-sentence **user problem** (who, when, impact).
2. List every factual premise in the ticket → **confirmed / wrong / unverifiable** with evidence.
3. Duplicates / prior art: `gh issue list` / `gh pr list` search.
4. Verdict: valid+fitting · valid+wrong solution (reframe) · symptom of deeper issue · stale/not real (delete candidate).

### Phase 3 — Codebase deep dive (the core of this skill)

1. **Find where the problem is produced**, not only where it is noticed.
2. Explore with tools (and 1–2 explore subagents if useful, cost role `explore`: `python3 "${ORCH_ROUTING_TOOL:-$HOME/.kimi-code/skills/pr-orchestrator-generic/routing.py}" route explore --host "$ORCH_HOST"`; on Claude that is `Agent(subagent_type=loop-explorer)` with the routed model): call paths, existing modules that already do ≥80% of the ask, drift/duplication. Keep raw file reading in the subagents and bring back only `file:line` conclusions.
3. **Reuse inventory:** every existing helper, module or type the change should call or extend (**Call**), with `file:line` and what it owns, and the closest existing example of each kind of thing the change adds (**Follow**, per *Follow existing patterns*). This becomes `## Reuse`. If two near-duplicates exist, name the canonical one. **Sibling rules:** when the change re-derives something an existing path already computes (a filter, an extent, a validation, an as-of-date rule), name that path and list the rules the new one must match. For example: "the renderer only keeps orchards effective on the print date (`file:line`)", or "the orchard extent throws on unmapped blocks (`file:line`)". Both #945 gaps were sibling rules the new path dropped.
4. **Architecture fit:** Which module owns this? Extend it vs new parallel path? Does the fix sit in the right layer?
5. **Documentation fit:** Primary docs for the area — contradicts / extends / clarifies / untouched? If contract changes, ticket must require doc updates or `NOTE:`/`BUSINESS RULE:` comments. If no docs, say so — do not invent a mandatory doc index for repos that lack one. For an HTTP API change, also identify the product repository's canonical OpenAPI file and validation command; do not require OpenAPI for non-API work.
6. Write symptom-vs-origin explicitly.

### Phase 4 — Delete-before-build

Before designing:

- Deletion candidates
- **Failure modes first** — enumerate per the Test contract, including the edge-class checklist; this seeds the design, `## Reuse` sibling rules and `## Test plan`'s failure list. Only (a)/(b)/(c) scenarios become tests
- Minimal surviving design + complexity budget
- Explicit **non-goals** (what implementers must not build)
- Split check: more than one shippable outcome → propose children, do not mega-scope

### Phase 5 — Priority, milestone, size

- Priority `P0`–`P3` with one-line rationale (in body; optional `priority/P*` labels).
- Prefer an existing open milestone; do not create milestones without user approval — propose if needed.
- Size `S|M|L` per [references/spec-template.md](references/spec-template.md) → *Estimate sizes*. Size picks the template form, and pr-loop routes models on it.

### Phase 6 — Draft the body

Use [references/spec-template.md](references/spec-template.md): the **short form for `Size: S`** (soft cap ~3k characters), the **full form for M/L**. Prefer refining a good ticket over a full rewrite. Keep the section headings exact; pr-orchestrator copies them into its briefs.

Required in every form:

- **`## Reuse`** — from the Phase 3 inventory: **Call** entries (`path:line` + what it owns) and **Follow** entries (`path:line` + what to copy). Write `_None — greenfield_` only when you searched and nothing fits, and say what you searched.
- **`## Implementation sketch`** (M/L) — key signatures and data shapes and which file/layer each goes in. No full code: a sketch longer than the change has written the code.
- **`## Test plan`** — per the Test contract: failure modes, then only the scenarios that earn a test, each tagged (a)/(b)/(c) and within the size budget; red-first reproduction for bugs, browser check for visual bugs, artifact.
- **`## Acceptance criteria`** — each criterion names how it's checked (command, E2E step, or observable artifact). The verifier quotes them one by one. Acceptance must include: the fix addresses the origin (`file:line`), not only the symptom; the test plan's artifact is reproducible by re-running the documented command(s); unit tests written after the implementation are **not** the proof. When `API change: yes`, also: the OpenAPI document describes the boundary and the repo's contract validation passes.
- **`## File change matrix`** — the verifier flags files outside it. List every file you expect; an implementer who needs more must justify it in the PR.

### Phase 7 — Publish (REST only)

1. `gh issue edit N --body-file …`
2. Milestone if assigned.
3. Follow-up refactor issues per [docs/github-loop.md → Follow-up issues](../../../docs/github-loop.md#follow-up-issues-pattern-refactors) (dedupe first); put their numbers under `## Non-goals`.
4. Short comment: premise verdict, origin, deleted scope, follow-ups filed, estimate.
5. Labels per *Labels and queue* above. `scope-loop` after success removes `scoping` and adds `ready` **unless** the issue has `blocked` or `needs-input`.

## Anti-patterns (fail the skill)

- Rewriting the brain dump without opening the repo
- Expanding scope (“while we’re here…”)
- Rubber-stamping a wrong solution because the ticket asked for it
- Shipping architecture that duplicates an existing module, or omitting `## Reuse` so the implementer re-invents one
- A spec that adds a second way of doing something main already does, without a significant named gain; or one that switches pattern inside the ticket instead of filing a follow-up
- A full-form 10k-character spec for an `S` change
- A bug ticket whose first test can't go red on today's main; a visual bug "proven" by jsdom
- Acceptance criteria with no named check
- Requiring or inventing an OpenAPI file for work that does not cross an HTTP API boundary
- Adding `ready` to epics or delete-candidates
- Implementing the feature “to verify” the scope
- Scoping an issue without a `## Test plan`
- Accepting post-hoc unit tests as proof of correctness
- A Test plan with one scenario per failure mode, or over the size budget without a per-scenario reason
- Fake-backed component or service tests presented as E2E; one test per method copied from repo precedent
- **`blocked` because a dependency issue is still open or columns are not on main yet** — use `## Depends on` + `ready`
- Epic children that all depend on the same ancestor (sibling PRs)

## Outcomes

| Outcome | Meaning |
|---------|---------|
| **Ready** | Contract is implementable; `ready` set |
| **Needs owner input** | Open questions block; `needs-input` set |
| **Delete candidate** | Evidence to close or shrink drastically |
| **Split recommended** | Children listed; user creates them |

## Report to user

Number, title, URL · outcome · premises confirmed/wrong · origin `file:line` · reuse list (Call / Follow) · follow-up issues filed · what was deleted · architecture/doc fit one-liners · estimate · labels · next: `pr-loop` if ready.
