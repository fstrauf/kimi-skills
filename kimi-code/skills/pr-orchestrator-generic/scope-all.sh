#!/usr/bin/env bash
#
# scope-all.sh — SUPERVISOR. Sequentially scopes open, non-epic GitHub issues
# via the gh-scope-issue skill (REST labels only — no Projects GraphQL).
#
# Same profiles as pr-loop:
#   --profile txApp → profiles/txApp.env
#
# Default queue (no manual enqueue):
#   every open issue in REPO that is NOT an Epic and NOT already in the ship
#   pipeline (ready / agent-working / agent-failed / blocked / needs-input /
#   awaiting-merge, or an open Closes #N PR).
#
# Optional legacy mode:
#   ORCH_SCOPE_REQUIRE_LABEL=1  → only issues labeled `scoping` (old behavior)
#
# Label machine:
#   Loop:    run gh-scope-issue → remove scoping if present, add ready
#   pr-loop: picks label ready → topo-sort by ## Depends on → ship
#   blocked: external/human only — NOT "depends on open sibling ticket"
#   Heal:    false dep-blocks → ready at loop start (see loop-common.sh)
#
# Usage:
#   scope-loop --profile pageseeds-app --agent grok
#   scope-loop --profile txApp --agent kimi 3
#   scope-loop --list-profiles
#
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat <<'USAGE'
Usage: scope-all.sh --profile NAME [--agent kimi|grok] [options] [max-issues]

Required:
  --profile NAME      Load profiles/NAME.env (same as pr-loop)

Optional:
  --agent kimi|grok   CLI that runs gh-scope-issue (default: kimi, or $ORCH_AGENT)
  --repo-dir PATH     Checkout path (first-time setup only)
  --project N         Project number (setup only; board not used for queue)
  --owner OWNER       Project owner for setup only
  --list-profiles     Print known profiles and exit
  max-issues          Stop after N issues (0 = no limit)

Queue (REST, default):
  All open non-epic issues that are not already shipped/queued:
    skip: Epic: / [Epic] titles
    skip: labels ready, agent-working, agent-failed, blocked, needs-input, awaiting-merge
    skip: open PR that closes the issue (Closes/Fixes/Resolves #N or feature/N- branch)
  Optional: ORCH_SCOPE_REQUIRE_LABEL=1 → only label `scoping` (legacy)

  After success: -scoping +ready  (unless needs-input / true external blocked)
  Code deps: still +ready (body ## Depends on); pr-loop orders them.

Examples:
  scope-loop --profile pageseeds-app --agent grok
  scope-loop --profile pageseeds --agent grok 2
  ORCH_SCOPE_REQUIRE_LABEL=1 scope-loop --profile txApp --agent kimi
USAGE
}

LOOP_PROFILE_ARG=""
REPO_DIR_FOR_SETUP=""
PROJECT_FOR_SETUP=""
OWNER_FOR_SETUP=""
POSITIONAL=()

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)
      [ $# -ge 2 ] || { echo "ABORT: --profile requires a name" >&2; exit 1; }
      LOOP_PROFILE_ARG="$2"
      shift 2
      ;;
    --profile=*)
      LOOP_PROFILE_ARG="${1#--profile=}"
      shift
      ;;
    --agent)
      [ $# -ge 2 ] || { echo "ABORT: --agent requires kimi|grok" >&2; exit 1; }
      export ORCH_AGENT="$2"
      shift 2
      ;;
    --agent=*)
      export ORCH_AGENT="${1#--agent=}"
      shift
      ;;
    --repo-dir)
      REPO_DIR_FOR_SETUP="${2:?}"
      shift 2
      ;;
    --repo-dir=*)
      REPO_DIR_FOR_SETUP="${1#--repo-dir=}"
      shift
      ;;
    --project)
      PROJECT_FOR_SETUP="${2:?}"
      shift 2
      ;;
    --project=*)
      PROJECT_FOR_SETUP="${1#--project=}"
      shift
      ;;
    --owner)
      OWNER_FOR_SETUP="${2:?}"
      shift 2
      ;;
    --owner=*)
      OWNER_FOR_SETUP="${1#--owner=}"
      shift
      ;;
    --list-profiles)
      # shellcheck source=/dev/null
      source "$SCRIPT_DIR/loop-common.sh"
      echo "Profiles in $PROFILES_DIR:"
      list_loop_profiles | sed 's/^/  /'
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "ABORT: unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

MAX_ISSUES="${POSITIONAL[0]:-0}"
: "${ORCH_AGENT:=kimi}"
: "${ORCH_SCOPING_LABEL:=scoping}"
: "${ORCH_READY_LABEL:=ready}"
# Default: pick all open non-epic work that isn't already in the ship pipeline.
# Set to 1 to restore "only label scoping" enqueue.
: "${ORCH_SCOPE_REQUIRE_LABEL:=0}"

if [ -z "$LOOP_PROFILE_ARG" ]; then
  echo "ABORT: --profile NAME is required (same profiles as pr-loop)." >&2
  echo "  scope-loop --list-profiles" >&2
  exit 1
fi

if [ -n "$REPO_DIR_FOR_SETUP" ]; then
  export REPO_DIR="$REPO_DIR_FOR_SETUP"
  export ORCH_REPO_DIR="$REPO_DIR_FOR_SETUP"
fi
if [ -n "$PROJECT_FOR_SETUP" ]; then
  export PROJECT_NUMBER="$PROJECT_FOR_SETUP"
  export ORCH_PROJECT_NUMBER="$PROJECT_FOR_SETUP"
fi
if [ -n "$OWNER_FOR_SETUP" ]; then
  export PROJECT_OWNER="$OWNER_FOR_SETUP"
fi

# shellcheck source=/dev/null
source "$SCRIPT_DIR/loop-common.sh"
load_loop_profile "$LOOP_PROFILE_ARG" || exit 1

export ORCH_SCOPING_LABEL ORCH_READY_LABEL ORCH_SCOPE_REQUIRE_LABEL
export REPO REPO_DIR

# Ensure labels (REST)
gh label create "${ORCH_SCOPING_LABEL}" --repo "$REPO" --color "5319E7" \
  --description "Needs gh-scope-issue (REST scope queue)" --force >/dev/null 2>&1 || true
gh label create "${ORCH_READY_LABEL}" --repo "$REPO" --color "0E8A16" \
  --description "Queued for pr-loop" --force >/dev/null 2>&1 || true
gh label create "needs-input" --repo "$REPO" --color "D93F0B" \
  --description "Scope blocked on owner decision; not ready for pr-loop" --force >/dev/null 2>&1 || true

RUN_ID=$(date +%Y%m%d-%H%M%S)
if [ "${ORCH_AGENT}" = "grok" ]; then
  LOG_ROOT="${HOME}/.grok/scope-loop-${LOOP_PROFILE}"
else
  LOG_ROOT="${HOME}/.kimi-code/scope-loop-${LOOP_PROFILE}"
fi
LOGDIR="$LOG_ROOT/$RUN_ID"
mkdir -p "$LOGDIR"
SUMMARY="$LOGDIR/summary.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$SUMMARY"; }

# Heal triage:ready-to-implement orphans → +ready (see loop-common.sh).
# Must run before the scope snapshot so healed issues are not re-scoped.
promote_triage_ready_orphans log
# Heal false "blocked on open sibling" parks → +ready (code deps ≠ park).
heal_false_dependency_blocks log

# Snapshot open issues that need scoping (REST). See scope_queue.py.
# Default: every open non-epic issue not already in ship/failed/parked pipeline.
# Legacy: ORCH_SCOPE_REQUIRE_LABEL=1 → only label scoping.
ISSUES=$(
  REPO_MATCH="$REPO" \
  SCOPING_LABEL="$ORCH_SCOPING_LABEL" \
  READY_LABEL="$ORCH_READY_LABEL" \
  REQUIRE_LABEL="$ORCH_SCOPE_REQUIRE_LABEL" \
  python3 "$SCRIPT_DIR/scope_queue.py" 2>"$LOGDIR/issue-list.err" || true
)

if [ -z "${ISSUES// /}" ]; then
  if [ "$ORCH_SCOPE_REQUIRE_LABEL" = "1" ]; then
    log "No open issues with label \`$ORCH_SCOPING_LABEL\` for $REPO — nothing to do."
    log "Enqueue (legacy): gh issue edit N --repo $REPO --add-label $ORCH_SCOPING_LABEL"
  else
    log "No open non-epic issues needing scope for $REPO — nothing to do."
    log "Queue skips: Epic titles, labels \`$ORCH_READY_LABEL\` / agent-working / agent-failed / blocked / needs-input / awaiting-merge, open Closes #N PR."
    log "Note: triage:ready-to-implement orphans were healed to \`$ORCH_READY_LABEL\` above (if any) — run pr-loop to ship."
  fi
  exit 0
fi

case "$ORCH_AGENT" in
  kimi)
    run_scope() {
      local n=$1
      kimi -p "/skill:gh-scope-issue $n" --output-format text
    }
    ;;
  grok)
    run_scope() {
      local n=$1
      grok -p "/gh-scope-issue $n" --always-approve
    }
    ;;
  *)
    echo "ABORT: unknown ORCH_AGENT=$ORCH_AGENT (use kimi|grok)" >&2
    exit 1
    ;;
esac

# After successful scope: hand off to pr-loop unless needs-input / true external blocked.
promote_scoped_to_ready() {
  local n=$1
  local labels
  labels=$(gh issue view "$n" --repo "$REPO" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null || echo "")

  gh issue edit "$n" --repo "$REPO" --remove-label "$ORCH_SCOPING_LABEL" >/dev/null 2>&1 || true

  if printf '%s' "$labels" | grep -Eq '(^|,)(blocked|needs-input)(,|$)'; then
    log "    labels: -$ORCH_SCOPING_LABEL (kept out of ready — needs-input/external blocked) (#$n)"
    log "    note: code deps must use ## Depends on + ready, not blocked (see gh-scope-issue)"
    return 0
  fi

  gh issue edit "$n" --repo "$REPO" --add-label "$ORCH_READY_LABEL" >/dev/null 2>&1 \
    && log "    labels: -$ORCH_SCOPING_LABEL +$ORCH_READY_LABEL (#$n)" \
    || log "    WARNING: could not add label $ORCH_READY_LABEL on #$n"
}

log "Scope loop start  profile=$LOOP_PROFILE  repo=$REPO  agent=$ORCH_AGENT"
if [ "$ORCH_SCOPE_REQUIRE_LABEL" = "1" ]; then
  log "Queue:   REST label \`$ORCH_SCOPING_LABEL\` only (ORCH_SCOPE_REQUIRE_LABEL=1)"
else
  log "Queue:   all open non-epic issues not already ready/agent-*/blocked/needs-input/awaiting-merge or an open Closes #N PR"
fi
log "After:   -$ORCH_SCOPING_LABEL +$ORCH_READY_LABEL (unless needs-input/external blocked)"
log "Issues:  $ISSUES"
log "Logs:    $LOGDIR"

ok=0; fail=0; skip=0; done_count=0
for N in $ISSUES; do
  if [ "$MAX_ISSUES" -gt 0 ] 2>/dev/null && [ "$done_count" -ge "$MAX_ISSUES" ]; then
    log "Reached max-issues=$MAX_ISSUES — stopping."
    break
  fi
  state=$(gh issue view "$N" --repo "$REPO" --json state -q .state 2>/dev/null || echo "UNKNOWN")
  if [ "$state" = "CLOSED" ]; then
    log "--- issue #$N: skipped (closed) ---"
    skip=$((skip + 1))
    continue
  fi
  title=$(gh issue view "$N" --repo "$REPO" --json title -q .title 2>/dev/null || echo "")
  if printf '%s' "$title" | grep -qiE '^\s*(epic\b|\[epic\])'; then
    log "--- issue #$N: skipped (Epic title) ---"
    skip=$((skip + 1))
    continue
  fi

  # Optional visibility while in flight (not required for queue selection)
  gh issue edit "$N" --repo "$REPO" --add-label "$ORCH_SCOPING_LABEL" >/dev/null 2>&1 || true

  log "--- issue #$N: starting ---"
  start=$(date +%s)
  if run_scope "$N" >"$LOGDIR/issue-$N.log" 2>&1; then
    dur=$(( $(date +%s) - start ))
    promote_scoped_to_ready "$N"
    log "--- issue #$N: DONE (${dur}s) ---"
    ok=$((ok + 1))
  else
    rc=$?
    dur=$(( $(date +%s) - start ))
    log "--- issue #$N: FAILED (exit $rc, ${dur}s) — see issue-$N.log ---"
    # Leave scoping label if we added it so a retry is visible; do not add ready
    fail=$((fail + 1))
  fi
  done_count=$((done_count + 1))
done

log "=== Loop complete: $ok succeeded, $fail failed, $skip skipped ==="
log "Next: pr-loop --profile $LOOP_PROFILE --agent $ORCH_AGENT   (or ship-loop to do both)"
report_leftovers | while IFS= read -r line; do log "$line"; done
# Fail-open: a scoped needs-input is success-park, not a failed run.
exit 0
