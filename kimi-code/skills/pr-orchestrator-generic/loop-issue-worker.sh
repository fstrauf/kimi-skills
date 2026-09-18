#!/usr/bin/env bash
#
# loop-issue-worker.sh — handles ONE issue end to end (REST labels + git/PR).
#
# Usage: loop-issue-worker.sh <issue-number> [ignored-board-item-hint]
#
# Queue control (you):
#   gh issue edit N --add-label ready     # enqueue
#   gh issue close N                      # or land path does this
#
# Agent label machine (REST only):
#   ready → agent-working → (land) close issue
#                        → awaiting-merge (PR open/stacked; dependents chain on)
#                        → needs-input (owner question — not a fail)
#                        → agent-failed (mechanical fail; re-add ready to retry)
#                        → ready again on interrupt
#
# Exit: 0 success/skip/park · 1 fail · 42 preflight (worktree + main both unusable) · 44 agent quota exhausted · 130 interrupt
#

set -uo pipefail

ISSUE="${1:?usage: loop-issue-worker.sh <issue-number>}"
# Second arg ignored (legacy project item id)
ITEM_ID_HINT="${2:-}"

COMMON="${LOOP_COMMON:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/loop-common.sh}"
GITHUB_STATE_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/github_state.py"
# shellcheck source=loop-common.sh
source "$COMMON"
if [ -z "${ORCH_CLI:-}" ]; then
  resolve_orch_agent
fi

AGENT_PID=""
WORKER_CWD="$REPO_DIR"
USED_WORKTREE=0

cleanup_issue_workspace() {
  if [ "$USED_WORKTREE" = 1 ]; then
    remove_issue_worktree "$ISSUE"
    USED_WORKTREE=0
  fi
  return_to_main || log "WARNING: main checkout left as-is (tracked edits untouched)"
}

on_interrupt() {
  trap '' INT TERM
  log "Interrupted during issue #$ISSUE — restoring ready label"
  [ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null
  release_issue_interrupted "$ISSUE"
  cleanup_issue_workspace
  notify "$ISSUE" "orchestrator interrupted. Label \`ready\` restored — re-run the loop to pick it up."
  exit 130
}
trap on_interrupt INT TERM

# Single success epilogue for every land path: drop loop labels, close the
# issue, notify, restore the checkout. Always exits 0.
finish_landed() { # <issue> <pr-url> <close-comment> <notify-message>
  local issue=$1 url=$2 comment=$3 msg=$4
  release_issue_success "$issue"
  local istate
  istate=$(gh issue view "$issue" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
  if [ "$istate" = "OPEN" ]; then
    gh issue close "$issue" --repo "$REPO" --comment "$comment" >/dev/null 2>&1 \
      && log "Closed issue #$issue" \
      || log "WARNING: could not close issue #$issue"
  fi
  notify "$issue" "$msg${url:+ $url}"
  cleanup_issue_workspace
  exit 0
}

park_needs_input() {
  release_issue_parked_needs_input "$ISSUE"
  notify "$ISSUE" "parked as \`needs-input\` (owner decision). Loop continues with the next ticket."
  cleanup_issue_workspace
  exit 0
}

log "Worker start issue=#$ISSUE repo=$REPO (REST labels; worktrees on)"

# Prefer a worktree so dirty main cannot kill this ticket (or the fleet).
if ! return_to_main; then
  log "Main checkout dirty — will run this issue in a worktree (fail-open)"
fi

# Re-check stack tooling every issue (install if missing, re-probe API, git knobs).
# Cheap when already installed; first run on a machine installs github/gh-stack.
ensure_gh_stack_ready
export ORCH_STACK_CLI ORCH_STACK_REPO_OK ORCH_STACK_READY ORCH_STACK

# --- Skip tracking epics -------------------------------------------------------
if is_tracking_only_issue "$ISSUE"; then
  log "SKIP #$ISSUE — tracking-only / Epic"
  release_issue_success "$ISSUE"   # clear ready so we don't re-pick
  remove_label "$ISSUE" "${ORCH_READY_LABEL:-ready}"
  notify "$ISSUE" "skipped: tracking epic (implement children; do not put \`ready\` on epics)."
  exit 0
fi

claim_issue_for_loop "$ISSUE"
log "Claimed #$ISSUE (labels: -ready +agent-working)"

# --- Resume detection ---------------------------------------------------------
# If the issue already has an open PR that was NOT completed (no final
# `phase=ready status=ok` marker), this is a RESUMED run: reuse that PR and its
# branch, and continue from the phase recorded in the state comment instead of
# starting over. The build worktree logic below already checks out the pushed
# feature/<issue>-loop branch, so the agent keeps all prior work.
RESUME_PHASE=""
RESUME_ATTEMPT=""
RESUME_PR=""
RESUME_HEAD=""
resume_line=$(find_open_pr_for_issue "$ISSUE" || true)
if [ -n "$resume_line" ]; then
  RESUME_PR=$(printf '%s' "$resume_line" | cut -f1)
  RESUME_HEAD=$(gh pr view "$RESUME_PR" --repo "$REPO" --json headRefName -q .headRefName 2>/dev/null || echo "")
  resume_state=$(REPO_MATCH="$REPO" python3 "$GITHUB_STATE_PY" read-pr "$RESUME_PR" 2>/dev/null || true)
  if [ -n "$resume_state" ]; then
    state_phase=$(printf '%s' "$resume_state" | sed -n 's/.*phase=\([a-z_0-9]*\).*/\1/p')
    state_status=$(printf '%s' "$resume_state" | sed -n 's/.*status=\([a-z_0-9]*\).*/\1/p')
    state_attempt=$(printf '%s' "$resume_state" | sed -n 's/.*attempt=\([0-9]*\).*/\1/p')
    # Only resume when the previous run did NOT reach a final ready state.
    if [ "$state_phase" != "ready" ] || [ "$state_status" != "ok" ]; then
      RESUME_PHASE="${state_phase:-implement}"
      RESUME_ATTEMPT="${state_attempt:-1}"
      log "RESUME #$ISSUE: phase='$RESUME_PHASE' attempt='$RESUME_ATTEMPT' PR #$RESUME_PR head='$RESUME_HEAD'"
    fi
  else
    # PR exists but has no state record — fresh-start this PR (agent will
    # re-implement on the existing branch, so prior commits are retained).
    log "PR #$RESUME_PR exists without a state record — will restage on feature/$ISSUE-loop"
  fi
fi
export RESUME_PHASE RESUME_ATTEMPT RESUME_PR RESUME_HEAD

# Cost routing (routing.py): size from the scoped body, attempt = failed runs + 1.
# No-op for single-model hosts (empty args). Subagent routes are asked by the skill.
ROUTING_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/routing.py"
ORCH_HOST="${ORCH_HOST:-$ORCH_AGENT}"
ORCH_SIZE=$(gh issue view "$ISSUE" --repo "$REPO" --json body -q .body 2>/dev/null \
  | python3 "$ROUTING_PY" size - 2>/dev/null || echo M)
ORCH_ATTEMPT=$(( ${RESUME_ATTEMPT:-0} + 1 ))
route_args=$(python3 "$ROUTING_PY" cli-args coordinate --host "$ORCH_HOST" \
  --size "$ORCH_SIZE" --attempt "$ORCH_ATTEMPT" 2>/dev/null || true)
ORCH_CLI_ARGS="${ORCH_CLI_ARGS:-}${route_args:+ $route_args}"
export ORCH_HOST ORCH_SIZE ORCH_ATTEMPT ORCH_ROUTING_TOOL="$ROUTING_PY"
log "Routing #$ISSUE: host=$ORCH_HOST size=$ORCH_SIZE attempt=$ORCH_ATTEMPT${route_args:+ ($route_args)}"

# Stack-through: resolve which branch this issue builds on. When a dependency
# has an open (unmerged) PR, this is that PR's head branch — the agent forks
# from it and opens the PR against it, so the loop never waits on a merge.
# ORCH_BASE_BRANCH_DEFAULT is an opt-in per-profile override (e.g. a product
# that integrates PRs on a `dev` branch instead of the repo's real GitHub
# default branch) — unset for every profile that doesn't set it, so this is a
# no-op everywhere except where a profile.env explicitly opts in.
ORCH_BASE_BRANCH=$(issue_base_branch "$ISSUE" 2>/dev/null || true)
ORCH_BASE_BRANCH=${ORCH_BASE_BRANCH:-${ORCH_BASE_BRANCH_DEFAULT:-$(default_branch_name)}}
export ORCH_BASE_BRANCH
log "Base branch for #$ISSUE: $ORCH_BASE_BRANCH"

if wt=$(ensure_issue_worktree "$ISSUE"); then
  WORKER_CWD="$wt"
  USED_WORKTREE=1
  log "Worktree: $WORKER_CWD"
else
  WORKER_CWD="$REPO_DIR"
  if ! require_clean_tree; then
    log "Cannot create worktree and main is dirty — #$ISSUE agent-failed; loop continues"
    release_issue_failed "$ISSUE"
    notify "$ISSUE" "could not create a worktree and the main checkout has tracked edits. Fix the tree, then \`-agent-failed +ready\`."
    cleanup_issue_workspace
    exit 0
  fi
  log "Worktree unavailable — running in main checkout $WORKER_CWD"
fi

# --- Run the orchestrator ----------------------------------------------------

cmd_display=$(orch_cmd_display "$ISSUE")
log "Running: $cmd_display"
start=$SECONDS
export ORCH_RUN_EVALS="${ORCH_RUN_EVALS:-0}"
export SKIP_EVALS="${SKIP_EVALS:-1}"
# Stack readiness for the agent (Phase 0 of orchestrator reads these).
export ORCH_STACK="${ORCH_STACK:-auto}"
export ORCH_STACK_CLI="${ORCH_STACK_CLI:-0}"
export ORCH_STACK_REPO_OK="${ORCH_STACK_REPO_OK:-0}"
export ORCH_STACK_READY="${ORCH_STACK_READY:-0}"
# Resume context for the orchestrator (Phase 1 of orchestrator reads these).
export ORCH_RESUME_PR="$RESUME_PR"
export ORCH_RESUME_HEAD="$RESUME_HEAD"
export ORCH_RESUME_PHASE="$RESUME_PHASE"
export ORCH_RESUME_ATTEMPT="$RESUME_ATTEMPT"
export ORCH_STATE_TOOL="$GITHUB_STATE_PY"
# shellcheck disable=SC2086
(cd "$WORKER_CWD" && \
  ORCH_RUN_EVALS="$ORCH_RUN_EVALS" SKIP_EVALS="$SKIP_EVALS" \
  ORCH_STACK="$ORCH_STACK" \
  ORCH_STACK_CLI="$ORCH_STACK_CLI" \
  ORCH_STACK_REPO_OK="$ORCH_STACK_REPO_OK" \
  ORCH_STACK_READY="$ORCH_STACK_READY" \
  ORCH_BASE_BRANCH="$ORCH_BASE_BRANCH" \
  ORCH_RESUME_PR="$ORCH_RESUME_PR" \
  ORCH_RESUME_HEAD="$ORCH_RESUME_HEAD" \
  ORCH_RESUME_PHASE="$ORCH_RESUME_PHASE" \
  ORCH_RESUME_ATTEMPT="$ORCH_RESUME_ATTEMPT" \
  ORCH_STATE_TOOL="$ORCH_STATE_TOOL" \
  ORCH_HOST="$ORCH_HOST" ORCH_SIZE="$ORCH_SIZE" ORCH_ATTEMPT="$ORCH_ATTEMPT" \
  ORCH_ROUTING_TOOL="$ORCH_ROUTING_TOOL" \
  "$ORCH_CLI" -p "$ORCH_SKILL $ISSUE" $ORCH_CLI_ARGS) \
  > "$LOG_DIR/issue-$ISSUE.log" 2>&1 &
AGENT_PID=$!
STALE_KILLED=0
while kill -0 "$AGENT_PID" 2>/dev/null; do
  sleep "$HEARTBEAT_SECONDS"
  kill -0 "$AGENT_PID" 2>/dev/null || break
  elapsed=$(( (SECONDS - start) / 60 ))
  size=$(stat -f%z "$LOG_DIR/issue-$ISSUE.log" 2>/dev/null || echo 0)
  last=$(grep -v '^[[:space:]]*$' "$LOG_DIR/issue-$ISSUE.log" 2>/dev/null | tail -1 | cut -c1-100)
  log "Issue #$ISSUE running ${elapsed}m — log ${size} bytes${last:+ | last: $last}"
  # Stale-agent watchdog: the CLI is expected to exit when its run finishes.
  # A live process with a log frozen for ORCH_AGENT_STALE_MINUTES means it
  # wedged on exit (child servers hold its output pipes) — but only when the
  # tree is also idle. A frozen log with a CPU-burning tree is a long silent
  # phase (delegated subagent, cold build): not a wedge, never kill it.
  if agent_log_is_stale "$LOG_DIR/issue-$ISSUE.log"; then
    if agent_tree_is_busy "$AGENT_PID" "$LOG_DIR/issue-$ISSUE.cputime"; then
      # Heartbeat into the agent log: informs live-stream watchers and resets
      # the mtime staleness clock for the next window.
      echo "[loop] log quiet ${ORCH_AGENT_STALE_MINUTES:-15}m+ but agent tree is busy (build/subagent) — continuing" \
        >> "$LOG_DIR/issue-$ISSUE.log"
      log "Issue #$ISSUE: log stale but agent tree busy — not killing"
    else
      log "Issue #$ISSUE: agent log frozen ${ORCH_AGENT_STALE_MINUTES:-15}+ min and tree idle — killing wedged agent tree"
      STALE_KILLED=1
      kill_process_tree "$AGENT_PID"
      break
    fi
  fi
done
wait "$AGENT_PID"
rc=$?
AGENT_PID=""

# --- Result ------------------------------------------------------------------

# An agent that parked explicitly on a question wins over the stale heuristics.
if issue_has_label "$ISSUE" "needs-input"; then
  log "Issue #$ISSUE: agent parked as needs-input — not a mechanical fail"
  park_needs_input
fi

# A stale-killed agent (finished answering, CLI never exited) must be judged by
# what it produced, not by the kill's exit code. If it opened a PR, the run
# effectively completed — hand off to the normal result flow. If it produced no
# PR, it was a genuine hang: mechanical failure.
if [ "$STALE_KILLED" = 1 ]; then
  stale_line=$(find_open_pr_for_issue "$ISSUE" || true)
  if [ -n "$stale_line" ]; then
    stale_pr=$(printf '%s' "$stale_line" | cut -f1)
    log "Issue #$ISSUE: stale-killed agent left open PR #$stale_pr — treating as completed run"
    rc=0
  else
    log "Issue #$ISSUE: stale-killed agent left no PR — genuine hang, mechanical failure"
    rc=1
  fi
fi

if [ "$rc" -ne 0 ]; then
  # Agent backend dead (quota / rate limit)? Not a ticket failure: restore the
  # ready label and abort the whole run — remaining tickets would fail the same.
  if agent_log_hit_quota "$LOG_DIR/issue-$ISSUE.log"; then
    log "Issue #$ISSUE: agent '$ORCH_AGENT' quota/rate-limit exhausted — aborting run (not a ticket failure)"
    release_issue_interrupted "$ISSUE"
    notify "$ISSUE" "agent \`$ORCH_AGENT\` ran out of quota mid-run — not a ticket failure. Re-queued as \`ready\` and the loop aborted. Switch agent or top up quota, then re-run."
    print_quota_abort_guidance "$ISSUE" "$LOG_DIR/issue-$ISSUE.log"
    cleanup_issue_workspace
    exit 44
  fi
  log "Issue #$ISSUE: orchestrator FAILED (exit $rc) — see $LOG_DIR/issue-$ISSUE.log"
  release_issue_failed "$ISSUE"
  notify "$ISSUE" "orchestrator failed (exit $rc). Labeled \`agent-failed\`; remove it and add \`ready\` to re-queue."
  cleanup_issue_workspace
  exit 1
fi

log "Issue #$ISSUE: orchestrator finished OK (exit 0)"
DEFAULT_BR=$(default_branch_name)
open_line=$(find_open_pr_for_issue "$ISSUE" || true)
pr_n=""; pr_url=""; pr_base=""
if [ -n "$open_line" ]; then
  pr_n=$(printf '%s' "$open_line" | cut -f1)
  pr_url=$(printf '%s' "$open_line" | cut -f2)
  pr_base=$(gh pr view "$pr_n" --repo "$REPO" --json baseRefName -q .baseRefName 2>/dev/null || echo "")
fi

# --- Completion gate ----------------------------------------------------------
# Exiting 0 is NOT enough. The orchestrator's terminal step must have written a
# `phase=ready status=ok` state marker ON the PR, and the PR must be non-draft.
# Anything else (draft PR, or no completion marker) is an incomplete run:
# resumable agent-failed, never awaiting-merge. This closes the 2026-09-14
# regression where review hard-stops and skipped gates were labeled
# awaiting-merge and the loop moved on.
if [ -z "$pr_n" ]; then
  # rc=0 with no PR is not "green": parking awaiting-merge would tell
  # dependents a branch exists to stack on when none does.
  log "Issue #$ISSUE: orchestrator exited 0 but produced no PR — ship failure"
  release_issue_failed "$ISSUE"
  notify "$ISSUE" "orchestrator exited 0 but produced no PR. Labeled \`agent-failed\`; remove it and add \`ready\` to re-queue."
  cleanup_issue_workspace
  exit 1
fi

if ! REPO_MATCH="$REPO" python3 "$GITHUB_STATE_PY" verify "$pr_n" phase=ready status=ok; then
  log "Issue #$ISSUE: PR #$pr_n lacks the phase=ready status=ok completion marker — ship flow incomplete"
  # Increment the persistent attempt counter (deterministic; the queue caps on
  # it). Reads the latest marker, writes attempt+1 onto the PR.
  prev_attempt=$(REPO_MATCH="$REPO" python3 "$GITHUB_STATE_PY" read-pr "$pr_n" 2>/dev/null \
    | sed -n 's/.*attempt=\([0-9]*\).*/\1/p')
  next_attempt=$(( ${prev_attempt:-0} + 1 ))
  REPO_MATCH="$REPO" python3 "$GITHUB_STATE_PY" append-pr "$pr_n" \
    phase=failed status=failed attempt="$next_attempt" next="${RESUME_PHASE:-implement}" pr="$pr_n" \
    >/dev/null 2>&1 || true
  release_issue_failed "$ISSUE"
  # Resumable: re-queue automatically so the next run picks up the existing
  # draft PR and continues from the recorded phase (attempt-capped in the queue).
  add_label "$ISSUE" "${ORCH_READY_LABEL:-ready}"
  notify "$ISSUE" "orchestrator exited 0 but PR #$pr_n has no completion marker (phase=ready status=ok). Attempt $next_attempt/${ORCH_RESUME_MAX_ATTEMPTS:-3}. Re-queued as \`ready\` — the next loop run resumes PR #$pr_n from the recorded state instead of restarting."
  cleanup_issue_workspace
  exit 1
fi

pr_draft=$(gh pr view "$pr_n" --repo "$REPO" --json isDraft -q .isDraft 2>/dev/null || echo "true")
if [ "$pr_draft" = "true" ]; then
  log "Issue #$ISSUE: PR #$pr_n is marked ready in state but still DRAFT onGitHub — ship flow incomplete"
  release_issue_failed "$ISSUE"
  notify "$ISSUE" "orchestrator marked PR #$pr_n ready in state but the PR is still open as a DRAFT. Labeled \`agent-failed\`; re-queue with \`-agent-failed +ready\` to resume."
  cleanup_issue_workspace
  exit 1
fi

log "Issue #$ISSUE: orchestrator finished OK and marked PR #$pr_n ready"

# Safety: the issue was meant to stack on ORCH_BASE_BRANCH but the agent opened
# the PR against the default branch. Merging it would silently land every
# unmerged layer underneath — retarget, and if that fails, park. Never land
# such a PR from the loop.
if [ -n "$pr_n" ] && [ "$ORCH_BASE_BRANCH" != "$DEFAULT_BR" ] && [ "$pr_base" = "$DEFAULT_BR" ]; then
  log "PR #$pr_n targets $DEFAULT_BR but issue stacks on $ORCH_BASE_BRANCH — retargeting"
  if gh pr edit "$pr_n" --repo "$REPO" --base "$ORCH_BASE_BRANCH" >/dev/null 2>&1; then
    pr_base="$ORCH_BASE_BRANCH"
  else
    log "WARNING: could not retarget PR #$pr_n to $ORCH_BASE_BRANCH — parking, no land attempted"
    release_issue_awaiting_merge "$ISSUE"
    notify "$ISSUE" "orchestrator green, but the PR targets \`$DEFAULT_BR\` while this issue stacks on \`$ORCH_BASE_BRANCH\`, and retargeting failed: $pr_url. Parked as \`awaiting-merge\`; retarget with \`gh pr edit $pr_n --base $ORCH_BASE_BRANCH\`."
    cleanup_issue_workspace
    exit 0
  fi
fi

# Stacked layer: the PR targets another PR branch, not the default branch.
# Merging from the loop would flatten the chain — park as awaiting-merge and
# let the loop move on to issues that stack on top of this one.
if [ -n "$pr_n" ] && [ -n "$pr_base" ] && [ "$pr_base" != "$DEFAULT_BR" ]; then
  link_stack_chain "$pr_n"
  if [ "${ORCH_STACK_AUTOLAND:-0}" = "1" ]; then
    log "ORCH_STACK_AUTOLAND=1 — attempting gh stack merge up to PR #$pr_n"
    if merge_pr_via_stack "$pr_n"; then
      finish_landed "$ISSUE" "$pr_url" "Closed after stack autoland of PR #$pr_n." "Done — stack-landed via gh stack merge."
    fi
    log "Stack autoland failed for PR #$pr_n — parking as awaiting-merge"
  fi
  release_issue_awaiting_merge "$ISSUE"
  log "Issue #$ISSUE stacked on '$pr_base' (PR #$pr_n) — awaiting-merge; loop continues"
  notify "$ISSUE" "orchestrator green — PR stacked on \`$pr_base\`: $pr_url. Labeled \`awaiting-merge\`. Land the chain with \`gh stack merge $pr_n --yes --squash\` (or merge bottom-up); dependents keep building on it meanwhile."
  cleanup_issue_workspace
  exit 0
fi

# Unstacked default-branch PR. Auto-merge when enabled, else await the human.
if [ "${ORCH_AUTO_MERGE:-1}" != "1" ]; then
  release_issue_awaiting_merge "$ISSUE"
  notify "$ISSUE" "orchestrator green (ORCH_AUTO_MERGE=0).${pr_url:+ PR: $pr_url} Labeled \`awaiting-merge\` — merge the PR to close."
  cleanup_issue_workspace
  exit 0
fi

if land_issue_pr "$ISSUE"; then
  finish_landed "$ISSUE" "$LAND_PR_URL" "Closed after successful auto-land to default branch (pr-loop)." "Done — landed on $DEFAULT_BR."
fi

# Land failed on a default-branch PR — optional stack autoland escape hatch.
if [ "${ORCH_STACK_AUTOLAND:-0}" = "1" ] && gh_stack_cli_available; then
  link_stack_chain "$pr_n"
  log "ORCH_STACK_AUTOLAND=1 — land failed, trying gh stack merge for PR #$pr_n"
  if merge_pr_via_stack "$pr_n"; then
    finish_landed "$ISSUE" "$pr_url" "Closed after stack autoland of PR #$pr_n." "Done — stack-landed via gh stack merge."
  fi
fi

# Land failed with a ready PR — park for human merge so dependents can stack.
release_issue_awaiting_merge "$ISSUE"
notify "$ISSUE" "orchestrator green but land failed — PR open for you.${pr_url:+ $pr_url} Labeled \`awaiting-merge\`; dependents will stack onto its branch."
log "Land failed for #$ISSUE but open READY PR exists — parked as awaiting-merge"
cleanup_issue_workspace
exit 0
