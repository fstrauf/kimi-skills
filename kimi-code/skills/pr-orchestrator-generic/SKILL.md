---
name: pr-orchestrator-generic
description: >-
  Orchestrate the full shipping loop for a GitHub issue in any repo — implement
  with a red-first verification artifact, open a draft PR, run parallel
  thermonuclear (structure) and correctness/spec reviews via PR comments, fix
  findings, run the ship gate, and mark the PR ready for review. Works on Kimi
  Code, Grok Build, Ori, and Claude Code. Use for /pr-orchestrator-generic,
  unattended Ready-column loops, or when shipping a scoped issue end-to-end.
when-to-use: >-
  Triggers on "/pr-orchestrator-generic", "/skill:pr-orchestrator-generic",
  "ship issue with generic orchestrator", or the loop-ready-issues.sh runner.
argument-hint: "<issue-number> [<issue-number>...] [--parallel|--serial]"
---

# PR Orchestrator (Generic) — Kimi + Grok + Ori + Claude

Drive a GitHub issue from assignment through implementation, automated review, test gating, and PR creation. The review handover happens on a GitHub draft PR so every finding and fix is traceable.

This is the **repo-agnostic** orchestrator. It assumes only:

- a git repository with a GitHub remote and an authenticated `gh` CLI,
- a **deterministic ship gate** (see Phase 5 — prefer `pnpm run test:gate` or the non-eval subset of `test:all`),
- the `thermo-nuclear-code-quality-review` skill is available as the structure-review baseline.

**Do not run live LLM eval suites in the automated loop** (`test:evals` / `#[ignore]` evals). They are multi-minute, flaky, and not part of CI. Humans can run `pnpm run test:evals` or full `pnpm test:all` before merge if desired.

If a repo needs extra release gates (dev-stack setup, QA scripts, API contract validation, canary checks, real-user integrity), that belongs in a **repo-specific** skill or `AGENTS.md` — do **not** hardcode monorepo paths here. For call-analyzer / Days to Expiry use **`pr-orchestrator`** (dual-host thick overlay: UI gate + real-user QA).

**Labels, queues, Depends-on vs park:** [docs/github-loop.md](../../../docs/github-loop.md) (repo root). Do not invent a second status machine.

## Host detection (do this first)

Detect which agent host you are on, then use **only** that host's tools for the rest of the run.

**First:** `echo "$ORCH_HOST"`. The loop always sets it (`kimi|grok|ori|openrouter|claude`; treat `openrouter` as Ori). When set, it wins. Only sniff tools when it is empty (interactive run):

| Signal | Host |
|--------|------|
| Tools named `run_terminal_command`, `spawn_subagent`, `todo_write`, `get_command_or_subagent_output` exist | **Grok** |
| Tools named `Skill`, `ToolSearch`, `Agent` (with `subagent_type`), `Bash`, and **no** `CreateGoal` / `TodoList` | **Claude** |
| Tools named `Bash`, `Agent`, `TodoList`, `TaskOutput`, `CreateGoal` exist | **Kimi** |
| Tools named `bash`, `spawn_agent`, `wait_agent`, `read`, `write`, `edit`, `grep`, `glob`, `set_goal`, `update_goal` exist | **Ori** |
| Unsure | Prefer the tools you actually have; never invent tool names from the other host |

Write the host name into your working notes (`host: kimi|grok|ori|claude`). **Read [references/hosts.md](references/hosts.md) once** for that host's column: shell, background waits, subagent spawning, Ori result schemas and the OpenRouter adapter policy.

### Claude: never end a turn on a pending wait

A background-completion notification is delivered **only to a top-level interactive session**. When this orchestrator runs as a subagent (launched with the `Agent` tool, which is how parent sessions and pr-loop hand it an issue), nothing wakes it after a background job or background subagent finishes. If it ends its turn with "waiting for the reviewer", "I'll pick up once `test:pr` completes", or anything similar, **the run is dead**, and it stays dead until a human notices. This happened on two consecutive runs on 2026-09-18, both right after spawning a long job, and both times the brief had warned against it explicitly.

Rules for Claude hosts:

- Spawn review, verify, implementer, fixer and triage subagents with `run_in_background: false`. The `Agent` call returns their result in-turn.
- Long shell jobs (`pnpm test:pr`, `pnpm test:all`, the dev stack readiness probe) do go in the background because they exceed the 10-minute foreground cap. Immediately wait on them with `TaskOutput(task_id, block=true, timeout=600000)`, and repeat the call until the task reports completed. A timeout means "still running", so call again in the same turn.
- Before ending any turn, check that every job you started has finished and you've read its result. The only legitimate stopping points are `gh pr ready` succeeding, a `needs-input` exit, or a genuine failure reported on the PR.

**Rules:**

1. Never call the other host's tool names.
2. In non-interactive / unattended mode, always run long work (subagents, full test suites) in the background and wait explicitly.
3. Orchestrator coordinates (git, gh, PR comments, scheduling subagents). Prefer subagents for code edits; the orchestrator may still run targeted tests and git/gh directly.

## Cost routing (every host)

The cheapest model and lowest effort that does the job. The policy table lives in **one** place, `routing.py` next to this skill (`$ORCH_ROUTING_TOOL`). Do not restate it or pick models by hand.

Before **every** subagent spawn, ask for the route:

```bash
python3 "$ORCH_ROUTING_TOOL" route <role> --host "$ORCH_HOST" --size "${ORCH_SIZE:-M}" \
  --attempt "${ORCH_ATTEMPT:-1}" [--review-iter <N>]
# → tier=mid effort=medium model=sonnet agent=loop-implementer
```

(Interactive run without the loop env: `python3 ~/.kimi-code/skills/pr-orchestrator-generic/routing.py …`, where size comes from `routing.py size` on the issue body.)

| Step | Role |
|------|------|
| Broad code search (Phase 1, finding files for briefs) | `explore` |
| Phase 2 implementer | `implement` |
| Phase 4 structure reviewer (pass `--review-iter N`) | `review` |
| Phase 4 correctness/spec verifier (pass `--review-iter N`) | `verify` |
| Review-finding fixes, targeted-test fixes, ship-gate fixes | `fix` |
| Reading long test / build / CI logs | `triage` |

Rules:

- Use the returned `model` / `agent` exactly (Claude: `Agent(subagent_type=<agent>, model=<model>)`). Empty `model` → your host has no tier routing; spawn as usual and do not pass a model.
- Escalation (the only path to the strongest model, apart from the defaults `routing.py` itself sets) is computed from `--attempt` / `--review-iter`. Never bump a model yourself because a task "feels hard".
- The coordinator stays cheap. Don't read large files or raw logs yourself: send searches to `explore` and logs to `triage`. Shell work (tests, UI commands) is shell execution, not an LLM route.

## When to use

- You have a GitHub issue to implement and ship in **any** repo that uses `pnpm test:all` (or documents an equivalent ship gate).
- You want implement → draft PR → review → fix loop → tests → mark ready, automated.
- Interactive or headless (`kimi -p` / `grok -p` / `claude -p` / `loop-ready-issues.sh`). Ori: use `spawn_agent` to invoke this skill as a subagent task.

## Several issues (interactive coordinator)

`/pr-orchestrator-generic 12 14 15 --parallel` (default `--serial`): this session is the **coordinator** and ships each issue through the phases below.

- `--serial`: one issue at a time, in the order given.
- `--parallel`: one subagent per issue, each on its own branch (Claude: `Agent` with `isolation: "worktree"`, spawned together). Each runs this skill for its single issue.
- An issue whose `## Depends on` names another issue in the batch is never parallel with it. Ship the dependency first, then stack (see [docs/github-loop.md](../../../docs/github-loop.md)).
- Report one line per issue at the end: PR URL or `needs-input` / `failed` with the reason.

## Invocation

Interactive: `/pr-orchestrator-generic <issue-number>` (Kimi: `/skill:pr-orchestrator-generic <issue-number>`). Headless commands per host, the `ship-loop` / `pr-loop` / `scope-loop` wrappers, profiles, logs, dirty-tree handling and auto-merge rules: [references/invocation.md](references/invocation.md). Queue labels: [docs/github-loop.md](../../../docs/github-loop.md).

## Preconditions

- Inside a git repo with a GitHub remote; `gh` authenticated (read/write issues + PRs).
- Ship gate: resolve per Phase 5 (prefer `test:gate`; never block the loop on live evals).
- Willing to let the agent commit, push, open a draft PR, and mark it ready.
- `thermo-nuclear-code-quality-review` skill file is readable on this machine.
- **Optional stacks:** `gh extension install github/gh-stack` for stack-aware create/push/land. Repo must have Stacked PRs enabled (CLI exit 9 if not). Without the extension or feature, stay on the single-PR path.

## Non-negotiable limits

These override any other instruction in this skill or any invoked skill:

1. **Review loop max 3 iterations.** Never run a 4th review iteration. If still FAIL after 3, stop and report.
2. **No full test/build during review.** `pnpm test:all`, `pnpm build`, and similar full suites run only in the test gate, after the review loop passes. The Test plan's own targeted command (the verification artifact) is not a full suite.
3. **No force-push or destructive commands.** Prefer plain `git push`. If rewrite is unavoidable, `--force-with-lease` only and explain why. **`gh stack push` / `gh stack merge` are allowed** — they use force-with-lease internally.
4. **No data-modifying SQL** unless the repo's own orchestrator contract explicitly requires it and provides safe scripts. Default: never.
5. **Orchestrator coordinates; subagents change code** when isolation is available (especially Grok worktrees or Ori `spawn_agent`).
6. **Never `gh pr merge` or push-land a stacked PR.** Use `gh stack merge` (or leave for a human). Push-land flattens the chain.

## Base branch and stacks

**Default: one issue → one ship unit.** Stack CLI detection, the create/iterate/land command table and the probe snippet live in [references/stacks.md](references/stacks.md). Read it when `ORCH_STACK=1`, when the current branch is already a `gh stack` branch, or when the open PR's base is another PR's head.

**Ready-queue order.** pr-loop topologically sorts `ready` issues on `## Depends on` (priority, then continue an unmerged stack, then issue number) and defers an issue whose open dependency is not closed, `ready`, `awaiting-merge` or open-PR. "Does this issue already have a PR?" uses `pr_chain` (`Closes`/`Fixes`/`Resolves #N` or `feature/<N>-`), never GitHub search. Scope agents put **code dependencies in the body**, not in `blocked`.

**Loop-driven dependency chains (`ORCH_BASE_BRANCH`).** When a dependency's PR is still open, the loop exports `ORCH_BASE_BRANCH` as that PR's head — or the **GitHub stack top** if that PR already has stacked children (never open a sibling against an ancestor). The issue is labeled `awaiting-merge` after its own PR opens. The agent contract:

1. Fork the feature branch from `origin/$ORCH_BASE_BRANCH` (not from the default branch).
2. Open the PR with `--base "$ORCH_BASE_BRANCH"` so GitHub shows only this layer's diff.
3. All diff ranges (review, fix verification) use `origin/$ORCH_BASE_BRANCH...HEAD`.
4. **Never merge** such a PR from the agent or loop worker — the human lands the whole chain with `gh stack merge <top-pr> --yes --squash` (or merges bottom-up), and the next loop run restacks whatever remains.

## State and scratch paths

Resolve once at the start (host-neutral):

```bash
scratch_dir="${TMPDIR:-/tmp}/pr-orchestrator-$(id -u)"
mkdir -p "$scratch_dir" && chmod 700 "$scratch_dir"
echo "$scratch_dir"
```

Persist across compaction (prefer absolute paths; shell variables don't survive separate tool calls):

- `iter_file`: `${scratch_dir}/issue-<N>-review-iter.txt` — review iteration counter
- `head_file`: `${scratch_dir}/issue-<N>-reviewed-head.txt` — HEAD SHA the last review iteration saw
- `spec_file`: `${scratch_dir}/issue-<N>-spec.md` — the spec sections reviewers get (Phase 1)
- `artifact_file`: `${scratch_dir}/issue-<N>-artifact.md` — the verification artifact (Phase 2)

## Workflow

### Durable state and resume contract

The supervisor may invoke this skill again against an existing PR. Do not create a second branch or PR when `ORCH_RESUME_PR` is set; reuse `ORCH_RESUME_HEAD` and continue from `ORCH_RESUME_PHASE`.

The supervisor provides `ORCH_STATE_TOOL`, `ORCH_STATE_ISSUE_N`, and (when resuming an existing PR) `ORCH_STATE_PR_N`. State markers are **required, not optional**: pr-loop's completion gate treats a run as done only when the PR carries a `phase=ready status=ok` marker — a missing marker means the work is re-queued as failed even if the PR is perfect. On a fresh run there is no `ORCH_STATE_PR_N` yet: markers go to the issue until the draft PR exists, then `export ORCH_STATE_PR_N=<n>` so every later marker attaches to the PR.

At every phase boundary append a state marker:

```bash
state_target="${ORCH_STATE_PR_N:-$ORCH_STATE_ISSUE_N}"
state_kind="${ORCH_STATE_PR_N:+pr}"
state_kind="${state_kind:-issue}"
REPO_MATCH="${REPO_MATCH:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}" \
  python3 "$ORCH_STATE_TOOL" "append-$state_kind" "$state_target" \
  phase=<phase> status=<ok|failed|blocked|needs_input> attempt=<attempt> next=<phase> pr="${ORCH_STATE_PR_N:-0}"
```

Required semantics:

- `status=failed` or `status=blocked` preserves the next resume phase and exits nonzero unless this is an explicit `needs-input` decision.
- `status=needs_input` is the only non-error zero-exit park.
- The final successful phase MUST append `phase=ready status=ok next=ready` after every required gate passes and after `gh pr ready` succeeds.
- Never claim success, mark an issue `awaiting-merge`, or leave a draft PR as if complete without that final marker. A draft PR with no final marker is resumable work.
- If `ORCH_STATE_TOOL` is missing or fails to run, do NOT skip markers. Post the marker line yourself with `gh pr comment <n> --body` (or `gh issue comment` before a PR exists), preserving the exact `<!-- ship-loop-state phase=... status=... attempt=... next=... pr=... -->` format — the reader only scans comment bodies for that line.

### Phase 0 — Lock context

1. Read the skill argument for the issue number. If missing, ask once and stop if still missing.
2. Optional goal (see references/hosts.md): `Implement GitHub issue #<number>, pass review and verification, pass the ship gate, and mark the PR ready for review`.
3. Shell: `git branch --show-current`.
4. Shell: `gh auth status` (or equivalent). If not authenticated, stop and report.
5. Detect stack CLI + mode (see *Base branch and stacks*): `STACK_CLI`, `ORCH_STACK`.
6. Shell: `gh issue view <number> --json title,body,labels,number,state,url`.
7. If the issue is closed, stop and report.
8. Resolve the base branch: `BASE="${ORCH_BASE_BRANCH:-<default branch>}"`. When the loop exports `ORCH_BASE_BRANCH`, this issue stacks on an unmerged dependency PR — fork from it, never from the default branch.
9. If on `main` or `master`, create the feature branch:
   - **Stack path** (`ORCH_STACK=1` and `STACK_CLI=1`): `gh stack init "feature/<issue-number>-<slug>"`
   - **Classic path** (default / auto): `git fetch origin "$BASE" && git checkout -b feature/<issue-number>-<slug> "origin/$BASE"`
10. Create todos: Understand issue · Implement + verify · React control scan · Open draft PR · Review loop · Test gate · Mark PR ready.

### Phase 1 — Understand the issue

1. Read the issue title and body carefully.
2. Read `AGENTS.md` / `Agents.md` and project docs it references.
3. Search the codebase for relevant files (host search tools; for broad sweeps use a role `explore` subagent).
4. **Write `spec_file`:** copy these issue sections verbatim, whichever exist — `## Problem`, `## Reuse`, `## Proposed change (minimal)`, `## Implementation sketch`, `## Non-goals`, `## File change matrix`, `## Test plan`, `## Acceptance criteria`, `## API contract`. Older issues without a scope pass: copy the whole body. Every implementer, reviewer and verifier brief includes this file.
5. If the body is ambiguous, make a reasonable interpretation from `AGENTS.md` and proceed. If the issue contains `## API contract` with `API change: yes`, treat its OpenAPI file and contract delta as part of the implementation scope; this supplements the rest of the issue and does not replace normal acceptance criteria. Park `needs-input` **only** for a product / legal / budget decision a human must make:
   ```bash
   gh issue edit <N> --add-label needs-input --remove-label ready
   gh issue comment <N> --body "needs-input: <the question>"
   ```
   Then **exit 0**. Do not use `blocked`. Do not `agent-failed`. The supervisor will pick the next ticket.
6. Mark "Understand issue" done.

### Phase 2 — Implement and verify

1. Spawn an **implementer subagent** (role `implement`, see *Cost routing*; per-host spawn notes in references/hosts.md) with a complete brief:
    - Issue number, title, and `spec_file`
    - Relevant file paths
    - Follow `AGENTS.md`; minimal scoped changes. Call the helpers listed in `## Reuse`; do not re-implement what they own. Follow `## Implementation sketch` when present.
    - If the issue declares `API change: yes`, update the named OpenAPI file and implementation together; preserve the declared compatibility behavior
    - **Red first for bugs:** run the Test plan's reproduction on the base branch and confirm it fails *before* changing code. If it passes on the base branch, the reproduction is wrong: fix the reproduction (or report `needs-input` if the bug can't be reproduced) before touching product code.
    - **Visual / layout bugs:** the reproduction is browser-level (Playwright or the repo's equivalent) and saves a screenshot or trace. jsdom or unit tests are not proof of a layout fix.
    - Tests: implement exactly the scoped issue's `## Test plan` / `## QA / verification` contract — nothing more. **Do not add unit tests beyond what the scope agreed**, and add none at all when the contract names none. Targeted runs only; **do not** run `pnpm test:all` / full build
    - Return: summary of changes, changed files, commit SHAs, open questions, and the **verification artifact**: the exact command(s), the red result on the base branch (bugs), the green result on the branch, and any artifact path (output file, screenshot, trace, response snapshot)
2. Inspect:
   - `git status --short`
   - `git log --oneline -5` and/or `git diff --stat "origin/$BASE...HEAD"`
3. If there are no changes, stop and report that the implementer produced no diff.
4. Run any targeted tests the subagent skipped (commands from `AGENTS.md`).
5. If those fail, spawn a fix subagent (role `fix`; hand long failure output to role `triage` first) before continuing.
6. **Verification artifact gate.** If the Test plan names a command or E2E and the implementer returned no green run of it (or no red run for a bug ticket), spawn a fix subagent once to produce it. Then write `artifact_file`: command(s), red result, green result, artifact paths. If it is still missing, write `artifact: missing — <reason>` and continue; the verifier FAILs it in Phase 4.
7. Ensure a commit exists, e.g. `feat: <issue title> (closes #N)`.
8. Mark "Implement + verify" done.

### Phase 2.5 — React control scan

Cheap, **fail-open**, after implement and before the draft PR. Not a review iteration. Do not run a full-project score. Do not `agent-failed` if a scanner is missing, flaky, or the repo is not React.

1. Mark "React control scan" in progress.
2. Resolve skill files (same probe pattern as the thermonuclear baseline). First readable path wins for each name:

```bash
for name in react-doctor shadscan; do
  for p in \
    "$HOME/.kimi-code/skills/$name/SKILL.md" \
    "$HOME/.grok/skills/$name/SKILL.md" \
    "$HOME/.agents/skills/$name/SKILL.md" \
    "$HOME/.ori/skills/$name/SKILL.md" \
    "$HOME/.claude/skills/$name/SKILL.md"; do
    if [ -f "$p" ]; then echo "$name $p"; break; fi
  done
done
```

3. Read each readable file. Missing skill → skip that scanner, note it.
4. Follow **Orchestrator control step** in `react-doctor`, then in `shadscan`. Flags, JSON fields, and must-fix rules live in those files — do not copy them here.
5. If either scanner edited files, commit (`fix: react-doctor / shadscan on #<N>`) before opening the PR.
6. Record a one-line result for the later PR comment (`clean` / `N errors remaining` / `skipped: <reason>` per scanner).
7. Mark "React control scan" done.

### Phase 3 — Open a draft PR

1. Mark "Open draft PR" in progress.
2. **Stack path** (active `gh stack` / `ORCH_STACK=1` with CLI): `gh stack submit --auto`, then `gh pr edit` title/body — see references/stacks.md → *Create*. Same body as the classic path below.
3. **Classic path** (default):

```bash
git push -u origin <branch>
# ORCH_BASE_BRANCH is always set by loop-issue-worker.sh — stacked on an
# unmerged dep PR, a profile's opt-in ORCH_BASE_BRANCH_DEFAULT (e.g. a
# product that integrates on `dev` instead of the repo's real default
# branch), or the repo's actual default branch as the final fallback.
gh pr create --draft \
  ${ORCH_BASE_BRANCH:+--base "$ORCH_BASE_BRANCH"} \
  --title "<issue title>" \
  --body "$(cat <<'EOF'
Closes #<N>

## Summary
<brief summary of changes>

## Deviations from the spec
<files or behavior outside ## File change matrix / ## Proposed change, each with the reason — or "None">

## Automated gates
React control scan (react-doctor + shadscan) already ran on the branch.
Structure review and correctness/spec verification run on this draft PR, followed by the ship gate.
EOF
)"
```

4. Capture PR number/url: `gh pr view --json number,url`.
5. Post the verification artifact (from `artifact_file`):
   ```bash
   gh pr comment <pr_number> --body "<!-- verification-artifact -->
   🔬 Verification artifact
   - Command: \`<command>\`
   - Base branch (red): <result or n/a for non-bugs>
   - This branch (green): <result>
   - Artifact: <path / snapshot / screenshot / trace>"
   ```
6. If Phase 2.5 produced a scanner result, comment it (`ℹ️ React control scan: react-doctor {result} · shadscan {result}`).
7. Mark "Open draft PR" done.

### Phase 4 — Review loop via PR comments (max 3 iterations)

Each iteration runs **two reviewers in parallel**, each with its own verdict. Never merge or rerank their findings: a PASS on one axis must not hide a FAIL on the other.

| Reviewer | Role / Claude agent | Judges |
|----------|---------------------|--------|
| Structure | `review` / `loop-reviewer` | Maintainability per the thermonuclear baseline: abstractions, duplication, layering, file size, test inflation |
| Verifier | `verify` / `loop-verifier` | Correctness first (producers traced, edge classes answered, each bug with a breaking input), then every acceptance criterion, scope vs file matrix, artifact |

**CRITICAL:**

- Strictly **3** review iterations max. Never a 4th.
- No `pnpm test:all` / full build in this phase.
- Only: review + verify → post findings → fix → push.
- Test gate only after both PASS (or hard stop).

**Review baseline (once, before iteration 1):**

1. Resolve the absolute path to `thermo-nuclear-code-quality-review` `SKILL.md`. Use the first readable candidate:

```bash
for p in \
  "$HOME/.kimi-code/skills/thermo-nuclear-code-quality-review/SKILL.md" \
  "$HOME/.grok/skills/thermo-nuclear-code-quality-review/SKILL.md" \
  "$HOME/.grok/bundled/skills/thermo-nuclear-code-quality-review/SKILL.md" \
  "$HOME/.agents/skills/thermo-nuclear-code-quality-review/SKILL.md" \
  "$HOME/.ori/skills/thermo-nuclear-code-quality-review/SKILL.md" \
  "$HOME/.claude/skills/thermo-nuclear-code-quality-review/SKILL.md"; do
  if [ -f "$p" ]; then echo "$p"; break; fi
done
```

   Also acceptable: take the path from your host's skill listing if it exposes one. Do not hardcode a single machine path without probing.

2. Read that file yourself to confirm it is readable. If missing/unreadable, STOP. Never run a degraded review without the baseline.
3. Use that path as `<baseline_path>` in every structure-reviewer prompt. Reviewer subagents have **no** Skill tool — they must read the baseline file.

**Iteration tracking:**

```bash
echo 1 > "<iter_file>"
```

**Loop body:**

```
WHILE true:
  1. Read <iter_file> → N
  2. If N > 3:
       - STOP
       - gh pr comment: "🛑 Automated review stopped after 3 iterations. Remaining findings require human triage."
       - Report to user / optional blocked goal
  3. Mark todo "Review loop (iteration N/3)"
  4. Changed files (base = `ORCH_BASE_BRANCH` when set — never diff a stacked
     branch against the default branch, that shows the whole chain):
       git diff --name-only "origin/${ORCH_BASE_BRANCH:-main}...HEAD" 2>/dev/null \
         || git diff --name-only origin/master...HEAD \
         || git diff --name-only HEAD~1
     Iteration ≥ 2: also the fix range `<SHA in head_file>..HEAD`.
  5. Write `git rev-parse HEAD` to <head_file>.
  6. Spawn BOTH in parallel and wait for both (Claude: two Agent calls in one message):
       - structure reviewer (role `review`, `--review-iter N`; prompt below)
       - verifier (role `verify`, `--review-iter N`; prompt below)
  7. Parse the reviewer's BASELINE + VERDICT and the verifier's VERDICT.
  8. If both PASS:
       - Post passing PR comment (both verdicts)
       - Break
  9. If either FAILs:
       - If N == 3: STOP, post findings, do not spawn fix, report
       - Else: post findings with marker <!-- thermonuclear-review-iter-N -->, under
         separate `### Spec`, `### Correctness`, `### Structure` headings (verbatim)
       - Spawn a fixer (role `fix`) for only those findings; commit + push
       - If the same substantive finding repeats across consecutive iterations, STOP
       - N = N+1; write N to <iter_file>
 10. Missing `BASELINE: loaded`, or an unparseable VERDICT from either → STOP (invalid review)
```

**Structure reviewer prompt:**

```
Run a thermo-nuclear code quality review on the current branch changes for draft PR #<pr_number>.

This is review iteration <iteration> of 3. On iteration 3, any remaining actionable findings will cause the loop to stop without further fixes. Be decisive: output PASS if previous findings have been addressed and no new structural blockers exist.

Focus on these files: <comma-separated paths>
<Iteration ≥ 2 only:> Fix range since your last review: <prev_head>..HEAD. Previous findings (confirm each is resolved): <paste the previous Structure findings>

Issue spec (from issue #<issue_number>, verbatim): <contents of spec_file>
Use `## Reuse` to judge duplication: re-implementing a listed helper is a finding.
Apply baseline §8 against the spec's `## Test plan` (or, when it has none: a new unit test FAILs unless the PR body justifies it per product AGENTS.md → Tests (a)/(b)/(c)): FAIL unit tests the test plan does not name, and mock-wiring/tautology tests; golden fixtures, E2E specs and edits to existing tests are exempt.
Correctness and spec compliance are judged by a separate verifier. Do not report them.

You do not have a Skill tool — do NOT attempt to invoke /thermo-nuclear-code-quality-review or /skill:thermo-nuclear-code-quality-review.
Instead, use your host's read-file tool to read this file IN FULL before inspecting the diff; it is the review baseline you must apply rigorously:
<baseline_path>

If you cannot read that file, respond with exactly `BASELINE: MISSING` and nothing else, then stop.

Then inspect the diff (prefer `origin/$ORCH_BASE_BRANCH...HEAD` when `ORCH_BASE_BRANCH` is set, else origin/main...HEAD or origin/master...HEAD) and produce a structured verdict.

Your response must use this exact format:

BASELINE: loaded (<baseline_path>)

VERDICT: PASS|FAIL

FINDINGS:
1. [Only if FAIL] <file path>: <specific, actionable issue>. Suggested fix: <concrete change>.
2. ...

NOTES:
- Optional non-blocking observations.

Be decisive. If previous findings have been addressed and no new structural blockers exist, output PASS. Do not introduce new low-severity findings in later iterations.
Do not explain your reasoning outside these sections.
```

**Verifier prompt:**

```
Verify draft PR #<pr_number> for issue #<issue_number>: does it do what the spec says, and is it correct?

This is verification iteration <iteration> of 3.
Diff range: origin/<base>...HEAD. Changed files: <comma-separated paths>
<Iteration ≥ 2 only:> Fix range since your last pass: <prev_head>..HEAD. Previous Spec/Correctness findings (confirm each is resolved): <paste them>

Issue spec (verbatim): <contents of spec_file>
Verification artifact (verbatim): <contents of artifact_file>
PR body "Deviations from the spec": <paste>

Correctness first. Trace every value the new code consumes to its producer (across services and languages in this repo) and state what it returns for no data, partial data, several entities and failure; types are not evidence. Existing behavior the diff newly relies on is in scope. Do not judge style or structure; another reviewer owns that.

Your response must use this exact format:

CORRECTNESS: PASS|FAIL
- Producers traced: <call → producer file:line → what it returns for empty / partial / multi-entity / failure>
- Edge classes: unknown-as-0 <ok|finding|n/a> · zero denominators <…> · multi-entity <…> · failure reported as success <…> · partial/transient failure commits or sends <…> · dry run writes <…> · timezones <…> · empty rows <…>
1. [Only if FAIL] <file:line>: <bug>. Breaking input: <concrete input or state>. Wrong result: <what the user sees>. Suggested fix: <concrete change>.

SPEC: PASS|FAIL
- "<acceptance criterion, quoted>": met|partial|missing — <file:line evidence>
- Scope: ok | <files/modules outside the matrix, or built non-goals, or re-implemented Reuse helpers, without a justified deviation>
- Artifact: ok | missing | red — <detail>

VERDICT: PASS|FAIL

FAIL when there is any correctness finding (including should-fix-before-users problems), any criterion is partial or missing, the artifact is missing or red, or scope creep is unjustified. Each correctness finding needs a concrete breaking input. Do not introduce new low-severity findings in later iterations.
```

**When either verdict is FAIL** (and N < 3):

```bash
gh pr comment <pr_number> --body "<!-- thermonuclear-review-iter-<iteration> -->
🧪 Automated review findings (iteration <iteration> of 3):

### Spec
<verifier SPEC block, or 'PASS'>

### Correctness
<verifier CORRECTNESS findings, or 'PASS'>

### Structure
<reviewer FINDINGS, or 'PASS'>

Please address the above findings and push updates."
```

Then spawn the fixer (role `fix`):

```
Address the review findings on draft PR #<pr_number>.

Read the latest review comments with: gh pr view <pr_number> --comments
Focus on the comment marked "<!-- thermonuclear-review-iter-<iteration> -->".

Spec and Correctness findings: change behavior exactly as each finding requires, and rerun the verification artifact command so it stays green (update the PR's verification-artifact comment if its result changed).
Structure findings: do not change behavior; make minimal structural improvements as requested.
Do not add unit tests beyond the issue's `## Test plan`.
Do NOT run pnpm test:all, pnpm build, or any full test/build suite.
Commit and push your changes.
If this branch is part of a GitHub stack (gh stack), push with: gh stack push
(and gh stack rebase first if you edited a lower layer). Otherwise: git push.
Return, per finding: fixed / not fixed (reason).
```

**Hard stop** (comment on PR + report to user):

- Would exceed 3 iterations
- Either verdict FAIL on iteration 3
- Same substantive finding in two consecutive iterations
- Unparseable `VERDICT` from either reviewer
- Missing `BASELINE: loaded` or `BASELINE: MISSING`
- A review subagent cannot be spawned (no subagent tool on this host, spawn error, or it never returns a result)

No review subagent means no review: never review the diff yourself or skip the loop. Append `phase=review status=failed next=review`, exit nonzero, and never reach `gh pr ready`. The draft PR stays resumable.

Do not enter the test gate without both PASS.

Mark "Review loop" done on PASS.

### Phase 5 — Test gate

1. Mark "Test gate" in progress.
2. Check `AGENTS.md` for prerequisites (services, env, seed data). Run documented setup first; teardown after if documented.
3. If the issue declares `API change: yes`, resolve the named contract validation command from `AGENTS.md` or the product docs. Run it as part of this gate, or report that the repository has no documented API contract check; do not invent a new validation framework in the generic orchestrator.
4. **Resolve the ship-gate command** (first match wins):

   ```bash
   # 1) Explicit automated gate
   if package.json has scripts["test:gate"] → pnpm run test:gate

   # 2) AGENTS.md / project docs name a non-eval gate for CI/automation → use that

   # 3) pageseeds-style test:all that includes live evals — run the deterministic subset only:
   pnpm run test:rust \
     && pnpm run lint \
     && pnpm exec tsc -b \
     && pnpm test \
     && pnpm run check:ipc \
     && pnpm run check:task-store \
     && ./scripts/check-bindings.sh \
     && pnpm run build
   # Skip: pnpm run test:evals  (live LLM; flaky; multi-minute; not in GitHub CI)

   # 4) Fallback
   pnpm test:all   # only if the above scripts do not exist
   ```

   If the issue declares `API change: yes`, append the repository's documented API contract validation command when it is not already included in the resolved gate. The OpenAPI check is additive; it does not replace lint, typecheck, tests, build, or the repository's other acceptance checks.

   **Hard rule:** do **not** invoke `pnpm run test:evals` or `cargo test … -- --ignored` live-eval filters in this phase unless the user explicitly set `ORCH_RUN_EVALS=1` in the environment.

5. **Run the resolved command** as a **background** shell task (full suites exceed foreground timeouts). Wait until completion **within the same turn**, using the host's blocking wait (Claude: `TaskOutput(block=true, timeout=600000)`, repeated until completed). Never end the turn with the gate still running.
6. If pass: `gh pr comment <pr_number> --body "✅ Ship gate passed: \`<exact command>\`."`
7. If fail:

   - Classify: product failure vs flake (eval timeout, network, corrupted cargo index).
   - Product: post summary, spawn fix subagent, re-run gate once more (**max 2 total attempts**).
   - Flake only (rare with evals skipped): re-run gate once with no code change; if still fail, stop and report.
8. Mark "Test gate" done.

**Why the deterministic subset:** on PageSeeds, `pnpm test:all` = rust + **live LLM evals** + lint + tsc + vitest + checks + full vite build. Live evals alone often take 10–30+ minutes and flake, forcing full-suite retries. CI only runs ~4 minutes of rust + lint/typecheck; the loop should track that, not paid LLM regression suites.

### Phase 6 — Mark PR ready for review

1. Mark "Mark PR ready" in progress.
2. `gh pr ready <pr_number>`.
3. Final comment:

```
This PR is ready for review.
- 🔬 Verification artifact: `<command>` red → green (see verification-artifact comment)
- ℹ️ React control scan: react-doctor {result} · shadscan {result}
- ✅ Structure review + correctness/spec verification passed (<N> iteration(s))
- ✅ Ship gate green (`<exact command>` — live LLM evals not run in the automated loop)
```

4. Report PR URL to the user.
5. Mark all todos done. Optional: complete the goal and clean up worktrees you created (references/hosts.md).

## Safety rules

- Do not force-push without lease; prefer no force-push at all. `gh stack push` is fine (lease internally).
- Do not run destructive database or file commands.
- Never `gh pr merge` or squash-push-land a stacked PR — use `gh stack merge` or hand off to a human.
- If the issue needs a human decision (product/legal/budget only), `+needs-input` and exit 0. Do not abort the fleet.
- If the review loop or test gate gets stuck, stop and report current state rather than looping forever.
- Respect project-specific test commands from `AGENTS.md`.
- Prefer worktree-isolated implementers when the host supports them so the main workspace stays clean (Ori supports `spawn_agent` for isolation).

## Output expectations

At the end of a successful run, report:

- Issue number and title
- Branch name
- PR URL
- Verification artifact (command, red → green)
- Number of review iterations and both final verdicts
- Test result (`pnpm test:all` or project equivalent)
- Host used (`kimi`, `grok`, `ori` or `claude`)
- Note that the PR is ready for review
- Reminder: manual QA is still required before approving

## Relationship to other skills

| Skill | Role |
|-------|------|
| `pr-orchestrator` | **Call-analyzer thick overlay** (dual-host): same loop + `pnpm test:all`/dev stack + UI gate + real-user QA. Use only in call-analyzer; profile `ORCH_SKILL=/pr-orchestrator`. |
| `gh-scope-issue` | Writes the spec sections (`## Reuse`, `## Test plan`, `## Acceptance criteria`, …) this skill copies into `spec_file` |
| `react-doctor` | Phase 2.5 React health scan. Policy + flags live in that skill’s *Orchestrator control step*. |
| `shadscan` | Phase 2.5 shadcn/ui scan when official shadcn is present. Same pattern. |
| `thermo-nuclear-code-quality-review` | Structure-review baseline, read by reviewer subagents |
| `ship-loop` (PATH) | Walk-away: scope then ship; `--ask` prints leftovers |
| `pr-loop` (PATH) / `loop-ready-issues.sh` | Unattended Ready-column runner; **`--profile NAME`** + `--agent kimi\|grok\|ori\|claude` |
| `pr-loop-setup` (PATH) / `setup-profile.sh` | Create/refresh `profiles/<name>.env` |
| `profiles/*.env` | Per-product board/repo config **shared with scope-loop** (txApp, pageseeds-app, …) |
| `scope-loop` (PATH) / `scope-all.sh` | Unattended Scoping-column runner; same `--profile NAME` as pr-loop |
| `pr-babysit` (Grok) | Post-ready CI/review babysitter; already understands Graphite + `gh stack` |
| `docs/github-loop.md` | **SSOT** for REST labels, handover, supervisor rules |
