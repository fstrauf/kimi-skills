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

# Stack-through: resolve which branch this issue builds on. When a dependency
# has an open (unmerged) PR, this is that PR's head branch — the agent forks
# from it and opens the PR against it, so the loop never waits on a merge.
ORCH_BASE_BRANCH=$(issue_base_branch "$ISSUE" 2>/dev/null || true)
ORCH_BASE_BRANCH=${ORCH_BASE_BRANCH:-$(default_branch_name)}
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
# shellcheck disable=SC2086
(cd "$WORKER_CWD" && \
  ORCH_RUN_EVALS="$ORCH_RUN_EVALS" SKIP_EVALS="$SKIP_EVALS" \
  ORCH_STACK="$ORCH_STACK" \
  ORCH_STACK_CLI="$ORCH_STACK_CLI" \
  ORCH_STACK_REPO_OK="$ORCH_STACK_REPO_OK" \
  ORCH_STACK_READY="$ORCH_STACK_READY" \
  ORCH_BASE_BRANCH="$ORCH_BASE_BRANCH" \
  "$ORCH_CLI" -p "$ORCH_SKILL $ISSUE" $ORCH_CLI_ARGS) \
  > "$LOG_DIR/issue-$ISSUE.log" 2>&1 &
AGENT_PID=$!
while kill -0 "$AGENT_PID" 2>/dev/null; do
  sleep "$HEARTBEAT_SECONDS"
  kill -0 "$AGENT_PID" 2>/dev/null || break
  elapsed=$(( (SECONDS - start) / 60 ))
  size=$(stat -f%z "$LOG_DIR/issue-$ISSUE.log" 2>/dev/null || echo 0)
  last=$(grep -v '^[[:space:]]*$' "$LOG_DIR/issue-$ISSUE.log" 2>/dev/null | tail -1 | cut -c1-100)
  log "Issue #$ISSUE running ${elapsed}m — log ${size} bytes${last:+ | last: $last}"
done
wait "$AGENT_PID"
rc=$?
AGENT_PID=""

# --- Result ------------------------------------------------------------------

if issue_has_label "$ISSUE" "needs-input"; then
  log "Issue #$ISSUE: agent parked as needs-input — not a mechanical fail"
  park_needs_input
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

# Stacked layer: the PR targets another PR's branch, not the default branch.
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

# Optional: leave PR open for human merge
if [ "${ORCH_AUTO_MERGE:-1}" != "1" ]; then
  release_issue_awaiting_merge "$ISSUE"
  # Keep issue open; awaiting-merge so dependents can stack onto the PR branch
  notify "$ISSUE" "orchestrator green (ORCH_AUTO_MERGE=0).${pr_url:+ PR: $pr_url} Labeled \`awaiting-merge\` — merge the PR to close."
  cleanup_issue_workspace
  exit 0
fi

if land_issue_pr "$ISSUE"; then
  finish_landed "$ISSUE" "$LAND_PR_URL" "Closed after successful auto-land to default branch (pr-loop)." "Done — landed on $DEFAULT_BR."
fi

# Land failed on a default-branch PR — optional stack autoland escape hatch.
if [ "${ORCH_STACK_AUTOLAND:-0}" = "1" ] && [ -n "$pr_n" ] && gh_stack_cli_available; then
  link_stack_chain "$pr_n"
  log "ORCH_STACK_AUTOLAND=1 — land failed, trying gh stack merge for PR #$pr_n"
  if merge_pr_via_stack "$pr_n"; then
    finish_landed "$ISSUE" "$pr_url" "Closed after stack autoland of PR #$pr_n." "Done — stack-landed via gh stack merge."
  fi
fi

# Land failed
if [ -n "$pr_n" ]; then
  # PR exists but not landed — park as awaiting-merge so dependents stack on
  # it instead of deferring forever.
  release_issue_awaiting_merge "$ISSUE"
  notify "$ISSUE" "orchestrator green but land failed — PR open for you.${pr_url:+ $pr_url} Labeled \`awaiting-merge\`; dependents will stack onto its branch."
  log "Land failed for #$ISSUE but open PR exists — parked as awaiting-merge"
  cleanup_issue_workspace
  exit 0
fi

log "Issue #$ISSUE: exit 0 but no PR and not on main — ship failure"
release_issue_failed "$ISSUE"
notify "$ISSUE" "orchestrator exited 0 but no PR / not on main. Labeled \`agent-failed\`."
cleanup_issue_workspace
exit 1
