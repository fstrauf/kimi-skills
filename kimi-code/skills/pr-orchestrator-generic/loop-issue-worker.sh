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
# Agent label machine (REST only — no Projects/GraphQL):
#   ready → agent-working → (land) close issue
#                        → agent-failed (no ready; re-add ready to retry)
#                        → ready again on interrupt
#
# Exit: 0 success/skip · 1 fail · 42 preflight · 130 interrupt
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

on_interrupt() {
  trap '' INT TERM
  log "Interrupted during issue #$ISSUE — restoring ready label"
  [ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null
  release_issue_interrupted "$ISSUE"
  notify "$ISSUE" "orchestrator interrupted. Label \`ready\` restored — re-run the loop to pick it up."
  exit 130
}
trap on_interrupt INT TERM

log "Worker start issue=#$ISSUE repo=$REPO (REST labels only; ORCH_BOARD=${ORCH_BOARD:-0})"

return_to_main || exit 42

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
(cd "$REPO_DIR" && \
  ORCH_RUN_EVALS="$ORCH_RUN_EVALS" SKIP_EVALS="$SKIP_EVALS" \
  ORCH_STACK="$ORCH_STACK" \
  ORCH_STACK_CLI="$ORCH_STACK_CLI" \
  ORCH_STACK_REPO_OK="$ORCH_STACK_REPO_OK" \
  ORCH_STACK_READY="$ORCH_STACK_READY" \
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

if [ "$rc" -ne 0 ]; then
  log "Issue #$ISSUE: orchestrator FAILED (exit $rc) — see $LOG_DIR/issue-$ISSUE.log"
  release_issue_failed "$ISSUE"
  notify "$ISSUE" "orchestrator failed (exit $rc). Labeled \`agent-failed\`; remove it and add \`ready\` to re-queue."
  return_to_main || log "WARNING: could not return to clean main after failure"
  exit 1
fi

log "Issue #$ISSUE: orchestrator finished OK (exit 0)"

# Optional: leave PR open for human merge
if [ "${ORCH_AUTO_MERGE:-1}" != "1" ]; then
  release_issue_success "$ISSUE"
  # Keep issue open; remove ready so not re-picked until user re-queues or closes
  pr_url=$(find_open_pr_for_issue "$ISSUE" | cut -f2 || true)
  notify "$ISSUE" "orchestrator green (ORCH_AUTO_MERGE=0).${pr_url:+ PR: $pr_url} Add \`ready\` only if you want the loop to try again."
  return_to_main || true
  exit 0
fi

if land_issue_pr "$ISSUE"; then
  release_issue_success "$ISSUE"
  istate=$(gh issue view "$ISSUE" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
  if [ "$istate" = "OPEN" ]; then
    gh issue close "$ISSUE" --repo "$REPO" --comment "Closed after successful auto-land to default branch (pr-loop)." >/dev/null 2>&1 \
      && log "Closed issue #$ISSUE" \
      || log "WARNING: could not close issue #$ISSUE"
  fi
  notify "$ISSUE" "Done — landed on main.${LAND_PR_URL:+ $LAND_PR_URL}"
  return_to_main || log "WARNING: could not return to clean main after success"
  exit 0
fi

# Land failed
open_line=$(find_open_pr_for_issue "$ISSUE" || true)
if [ -n "$open_line" ]; then
  pr_url=$(printf '%s' "$open_line" | cut -f2)
  # PR exists but not landed — leave open, no ready, no agent-failed (human merge)
  remove_label "$ISSUE" "agent-working"
  remove_label "$ISSUE" "${ORCH_READY_LABEL:-ready}"
  notify "$ISSUE" "orchestrator green but land failed — PR open for you.${pr_url:+ $pr_url}"
  log "Land failed for #$ISSUE but open PR exists — left open without ready"
  return_to_main || true
  exit 0
fi

log "Issue #$ISSUE: exit 0 but no PR and not on main — ship failure"
release_issue_failed "$ISSUE"
notify "$ISSUE" "orchestrator exited 0 but no PR / not on main. Labeled \`agent-failed\`."
return_to_main || true
exit 1
