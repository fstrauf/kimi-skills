#!/usr/bin/env bash
#
# ship-loop.sh — walk-away command: scope then ship until both queues drain.
#
# Never aborts because one ticket is stuck. Parks needs-input / agent-failed /
# awaiting-merge and prints leftovers at the end.
#
#   ship-loop --profile coffee --agent grok
#   ship-loop --profile coffee --ask          # print parked questions only
#
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

ASK=0
FORWARD=()
while [ $# -gt 0 ]; do
  case "$1" in
    --ask)
      ASK=1
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: ship-loop --profile NAME [--agent kimi|grok] [--ask] [max-issues]

Runs scope-loop then pr-loop with the same profile. Fail-open: one stuck
ticket never stops the rest. Prints leftovers (needs-input, awaiting-merge,
agent-failed, deferred ready) at the end.

  --ask    Only print leftovers / parked questions. Do not run agents.
EOF
      exit 0
      ;;
    *)
      FORWARD+=("$1")
      shift
      ;;
  esac
done

# shellcheck source=loop-common.sh
source "$SCRIPT_DIR/loop-common.sh"

# Reuse pr-loop arg parsing by requiring --profile in the forwarded args.
LOOP_PROFILE_ARG=""
i=0
while [ $i -lt ${#FORWARD[@]} ]; do
  a="${FORWARD[$i]}"
  case "$a" in
    --list-profiles)
      echo "Profiles in $PROFILES_DIR:"
      list_loop_profiles | sed 's/^/  /'
      exit 0
      ;;
    --profile)
      i=$((i + 1))
      LOOP_PROFILE_ARG="${FORWARD[$i]:-}"
      ;;
    --profile=*)
      LOOP_PROFILE_ARG="${a#--profile=}"
      ;;
  esac
  i=$((i + 1))
done
LOOP_PROFILE_ARG="${LOOP_PROFILE_ARG:-${ORCH_PROFILE:-}}"
if [ -z "$LOOP_PROFILE_ARG" ]; then
  echo "ABORT: --profile NAME is required" >&2
  echo "  ship-loop --list-profiles" >&2
  exit 1
fi

load_loop_profile "$LOOP_PROFILE_ARG" || exit 1

if [ "$ASK" = 1 ]; then
  echo "Parked / waiting for $REPO (profile $LOOP_PROFILE_ARG):"
  report_leftovers
  exit 0
fi

echo "[$(date '+%H:%M:%S')] ship-loop start  profile=$LOOP_PROFILE_ARG  repo=$REPO"
echo "[$(date '+%H:%M:%S')] 1/2 scope-loop"
bash "$SCRIPT_DIR/scope-all.sh" ${FORWARD[@]+"${FORWARD[@]}"}
scope_rc=$?
if [ "$scope_rc" -eq 44 ]; then
  echo "[$(date '+%H:%M:%S')] ship-loop: scope-loop aborted on agent quota — skipping pr-loop (switch agent or top up, then re-run)"
  exit 44
fi

echo "[$(date '+%H:%M:%S')] 2/2 pr-loop"
bash "$SCRIPT_DIR/loop-ready-issues.sh" ${FORWARD[@]+"${FORWARD[@]}"}
pr_rc=$?

echo "[$(date '+%H:%M:%S')] ship-loop finished (scope_exit=$scope_rc pr_exit=$pr_rc)"
report_leftovers
# Agent quota exhaustion (exit 44) is an environment failure, not a leftover —
# propagate it so callers can tell "stopped early" apart from "parked tickets".
if [ "$pr_rc" -eq 44 ]; then
  exit 44
fi
# Fail-open: leftover parked tickets are not a failed run.
exit 0
