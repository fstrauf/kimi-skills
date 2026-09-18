---
name: pr-batch-review
description: >-
  Sweep every open pull request in a repo, verify each one against a strict
  red-flag checklist, and report which ones are safe to approve or merge. Review
  is read-only by default: merging is a separate optional step that requires
  explicit user approval. After an approved merge batch, verify master with the
  real local gate (cargo/Rust tests + site tests + build), because repo CI is
  often site-only (Vercel + GitGuardian) and never compiles Rust. Use when
  "detail" (or any bot) opened a pile of bug-fix PRs, the user asks which PRs
  can be auto-approved, or asks to batch-review open pull requests.
when-to-use: >-
  Triggers on "/pr-batch-review", "review the open pull requests", "detail
  opened a ton of pull requests", "which pull requests can be automatically
  approved", "analyze and verify open PRs", or an explicit request to merge
  the reviewed PRs.
argument-hint: "[repo]"
user-invocable: true
metadata:
  short-description: "Batch-verify open PRs and recommend clean ones; merge only with explicit approval"
---

# PR Batch Review — triage → verify → report → optional merge → local gate

Sweeps the **open** pull requests of a repo (typically many auto-generated bug-fix PRs from a tool like Detail), verifies them, and reports which ones are safe. It does **not** approve or merge by default. Merging is always an optional follow-up requiring explicit user approval.

Companion skills (do not overlap):
- **`pr-orchestrator-generic`** — ship ONE scoped issue end-to-end (implement → PR → thermonuclear review → ready).
- **`gh-scope-issue` / `gh-ticket-hygiene`** — issues, not PRs.
- **`thermo-nuclear-code-quality-review`** — deep maintainability review of one change.

## Hard rules

1. **CI is not the gate here.** Repo CI is typically site-only (Vercel + GitGuardian security scan) and never runs cargo. The real verification is the **local repo gate** after merges (see Phase 4).
2. **Read-only by default.** Do not approve, merge, rebase, push, or modify PR branches during the review/report phase.
3. **Integration preflight is separate from GitHub merging.** After review, combine all recommended PR heads in a temporary local worktree and run the repo's full gate against the combined result. Do not push this branch or create a public integration PR.
4. **Merging is optional and requires explicit user approval after the review report and integration result.** A general request to analyze, verify, or recommend PRs is not permission to merge them.
5. **No red flags → RECOMMEND. Any red flag → FLAG**, and flagged PRs are never included in the integration or merged — they go in the report for a human.
6. If the user explicitly authorizes merging, merge sequentially, re-checking `mergeable_state` right before each merge (GitHub recomputes lazily; a snapshot says nothing).
7. Read every diff hunk of every PR you're responsible for — including the merged result after conflict resolution.

## Host detection

Detect which agent host you are on, then use only that host's tool names.

| Tool shape | Host |
|-----------|------|
| `bash`, `spawn_agent`/`task`, `read`, `write`, `edit`, `grep`, `glob` | **Ori / opencode** |
| `Bash`, `Agent`, `TodoList`, `TaskOutput`, `CreateGoal` | **Kimi** |
| `run_terminal_command`, `spawn_subagent`, `todo_write` | **Grok** |
| Unsure | Use the tools you actually have; never invent names from another host |

## Phase 0 — Inventory (who, how big, mergeable)

```bash
# Table: number → +add/-del, changedFiles, mergeable/mergeStateStatus, head branch
gh pr list --state open --limit 200 \
  --json number,title,additions,deletions,changedFiles,mergeable,mergeStateStatus,headRefName,baseRefName \
  --jq '.[] | "\(.number)\t+\(.additions)/-\(.deletions)\t\(.changedFiles) files\t\(.mergeable)/\(.mergeStateStatus)\t\(.headRefName)"' | sort -n

# Checks rollup (same CI for the whole set is a signal the repo gate is elsewhere)
gh pr list --state open --limit 200 --json number,statusCheckRollup --jq '.[] | .number as $n | .statusCheckRollup[] | "\($n)\t\(.context // .name)\t\(.state // .status)"' | sort -u

# Files touched by each PR (to segment into non-overlapping batches)
gh pr list --state open --limit 200 --json number,files --jq '.[] | "== PR #\(.number) ==", (.files[] | "  \(.path)")'
```

Also:

- **All PRs must be based on `master`** (or whatever the default branch is). Anything based elsewhere is a FLAG.
- Confirm repo **merge methods**: `gh repo view --json mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed`.
- Read the repo's `AGENTS.md` ship gates up front — the repo gate is authoritative for Phase 4.

## Phase 1 — Triage: the red-flag checklist

Use this verbatim both when reviewing yourself and when you instruct subagents:

1. Secrets / API keys / tokens / machine paths committed **or logged**.
2. **Non-additive SQLite migration edits** — migrations on the DB (e.g. `db/mod.rs` `MIGRATION_VN`) are **additive only**: new appended version blocks, never edits to old ones.
3. Business logic added to the thin CLI crate (CLI stays parse → call core → print).
4. New production `unwrap()` / `panic!()` / `expect!` (test-only is fine).
5. Breaking the **public install / CLI contract surface** (installer, `--version`/JSON output shape, license-verify path).
6. **Scope creep** — PR title says one fix, diff touches unrelated subsystems.
7. **Test gutting** — removing/changing existing assertions without replacement.
8. Regex / parser / formatter changes that obviously break valid inputs (hand-written regexes are the norm here — judge for obvious breakage only).
9. **Task lifecycle violations** (if the repo has a spawner contract): tasks created outside `TaskSpawner`, or lifecycle policy re-encoded outside `task_definitions`.
10. Any touch of **Stripe / checkout / license mint** = FLAG regardless (review personally).

### Own vs delegate

- **OWNED (you read the diff of each, full attention)** — anything touching the **website** (`src/`), **Stripe / checkout / success**, **DB migrations**, **CLI contract**, **license**.
- **DELEGATE** — domain Rust/lib fixes, the bulk. Parallel subagents, batches of ~5–7 PRs each (chunk by file overlap so reviewers don't step on non-overlapping areas).

### Subagent prompt template (delegate)

Give each reviewer: the repo checkout, the exact PR numbers, the checklist above (numbered), and:

> Review these PRs read-only (never modify anything, never run cargo). For each:
> 1. `gh pr view <n> --json number,title,body` and `gh pr diff <n>`.
> 2. Check every hunk against the numbered red-flag list. Reason about compile-ability by hand (no cargo in this review). Confirm cross-file consistency (signatures, re-exports, call sites) by reading the current tree where a change references other modules.
> 3. Verdict: **APPROVE** or **FLAG** + 1–3 sentence rationale naming the specific concern, if any.
> Return a compact table: `PR | verdict | rationale`.

## Phase 2 — Decide and report

- **RECOMMEND** = no red flags found by you or the reviewer. This is a recommendation, not an approval action.
- **FLAG** = any red flag → leave unapproved and unmerged, note exactly why in the report. Do **not** fix the PR's content — just surface it (the human decides).
- End the review with a compact table. Then run the local integration preflight on the recommended PRs (Phase 3) before asking whether the user wants to proceed with any separate remote actions:
  1. approve the recommended PRs;
  2. merge the approved PRs (only after an explicit merge approval);
  3. do both.
- Never infer merge permission from a request to analyze, verify, recommend, or approve. Merging requires a distinct explicit user instruction.

## Phase 3 — Local integration preflight (default, no remote write)

After Phase 2 identifies the recommended PRs, combine those PR heads locally in a temporary worktree and run the full repository gate. This is the validation the user wants: it tests the **combined change**, not each PR in isolation.

This phase:

- includes only `RECOMMEND` PRs;
- uses a temporary branch/worktree based on the current remote default branch;
- merges PR heads in ascending order, preserving each PR's changes;
- resolves conflicts locally and records which files needed resolution;
- never pushes the integration branch, updates PR branches, approves PRs, merges GitHub PRs, or creates a public PR;
- reports `INTEGRATION GREEN` or `INTEGRATION FAILED` with the failing command and PR context.

```bash
DEFAULT_BRANCH=master
INTEGRATION_DIR="$(mktemp -d)"
# Fetch each recommended PR head without changing any PR or remote branch.
for n in <recommended-pr-numbers-ascending>; do
  git fetch origin "pull/$n/head:refs/remotes/origin/pr-$n"
done

git fetch origin "$DEFAULT_BRANCH"
git worktree add "$INTEGRATION_DIR" "origin/$DEFAULT_BRANCH"
cd "$INTEGRATION_DIR"
git switch -c "pr-batch-integration-$(date +%Y%m%d-%H%M%S)"

# Merge every recommended PR head in ascending order; inspect and resolve conflicts.
for n in <recommended-pr-numbers-ascending>; do
  git merge --no-commit --no-ff "refs/remotes/origin/pr-$n"
  # On conflicts: resolve, git add, then git commit --no-edit.
  # If no conflicts: git commit --no-edit.
done

# Read AGENTS.md and run the repo's complete gate.
# For this monorepo:
pnpm run test:cli
pnpm test
pnpm build
```

Use a separate temp worktree for the integration so the user's checkout remains untouched. Clean it up after collecting the result. If the integration fails, do not proceed to remote approval or merging unless the user explicitly asks to merge despite the failure.

## Phase 3-B — Optional approve and merge (only after explicit user approval)

Do not enter this phase during a review-only or integration-only run. Once the user explicitly authorizes merging, confirm the exact scope (all recommended PRs or a selected subset) and whether the integration gate must be green (default: yes), then proceed in ascending order. Works when everything is on `master`.

```bash
# Optional approval action, only if the user authorized approval
gh pr review "$n" --approve

# Merge action, only after explicit user authorization to merge.
# Use REST rather than `gh pr merge` when repo approval rules block the latter.
gh api -X PUT "repos/{owner}/{repo}/pulls/$n/merge" -f merge_method=squash \
  --jq .merged   # true = merged
```

Handling the stragglers:

- `mergeable_state == "dirty"` → `gh pr update-branch "$n" --rebase`, wait ~10s, retry the merge. If still dirty → resolve locally (Phase 3.1), then merge.
- `mergeable_state == "UNKNOWN"` → wait for GitHub's background compute (sleep ~10s), retry. The REST call may 405 the first time.
- Many "conflicts" in a batch of auto-generated PRs are **additive test collisions** — the resolved diff keeps both sides' code. When possible verify via the original PR bodies that the two sides are orthogonal.

### Phase 3-C — manual conflict resolution in a temp worktree

```bash
git fetch origin pull/$n/head:pr$n-detail
git worktree add /tmp/ps-pr$n pr$n-detail
cd /tmp/ps-pr$n
git fetch origin master
git checkout -B pr$n-merge origin/master
git merge --no-commit pr$n-detail          # → conflict fire
# resolve: keep both sides unless one is superseded by master, then
git add -A && git commit --no-edit --no-verify
LOCAL=$(git ls-remote origin "refs/pull/$n/head" ... )  # expected old SHA
git push origin pr$n-merge:refs/heads/<bot-branch> --force-with-lease=<expected-old-sha>
# then merge via the REST call above.
```

- Cleanup the worktree + branch when done (`git worktree remove`, `git worktree prune`, `git branch -D`).
- **Do not re-verify the merged result halfway** — Phase 4 catches everything at once.

## Phase 4 — Verify master locally (the real gate)

**Review-only run:** do not claim merged-result verification; report that no merge was performed. You may run the repo's tests against the current clean master only if useful.

**After the user explicitly authorizes and all approved merges are done** (including any fixes you committed):

```bash
git checkout master && git pull --ff-only origin master
```

Run the repo gate — read the root `AGENTS.md` "Ship gates" table; for this monorepo:
`pnpm run test:cli` (cargo core + cli + `check:task-store` + `check:cli-contract`) and `pnpm test` (site) and `pnpm build`.

If you broke something during merge resolution:

- Fix it locally, `git add`, `git commit` a small fix commit on master, push.
- **Never amend** the PR-branch pushes, **never reopen happy PRs**.

Heads-up:

- The pre-commit hook may trip on pre-existing issues (e.g. *content slug drift* in `content/` — 28 entries) that have nothing to do with your merges. Confirm with `git stash` then `node scripts/validate-slugs.js`; if it fails on clean master too, it's not yours → commit with `--no-verify` intentionally and note it in the report.
- Reddit-reply tests can hit **live credentials** on an operator machine — if a test asserting env misses PATH, isolate `HOME` so `~/.config/automation/secrets.env` can't inject real creds (pattern in `oauth.rs`).

## Phase 5 — Report

Review-only report:

| PR | title | recommendation | rationale |
|---|---|---|---|
| #192 | … | RECOMMEND | – |
| #207 | … | FLAG | reason |

Include the integration result (`INTEGRATION GREEN` or `INTEGRATION FAILED`) and the full-gate commands/results. Then explicitly ask whether the user wants to approve and/or merge the recommended PRs. State clearly that **nothing was merged remotely**; the integration branch was temporary and local.

After an explicitly authorized merge run, include the merged PRs, any conflict resolutions, the local gate (`pnpm run test:cli / test / build — all green`), and any pre-existing noise (such as slug drift).

Success criteria for review-only: every open PR has a recommendation or flag, no write action was taken, and the user is offered the optional merge step. Success criteria for a merge run: authorized PRs merged on `master`, local gate green, flagged PRs listed with concrete reasons.