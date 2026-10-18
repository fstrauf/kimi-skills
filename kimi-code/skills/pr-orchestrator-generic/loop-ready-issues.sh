#!/usr/bin/env bash
#
# loop-ready-issues.sh — SUPERVISOR. Sequentially ships GitHub issues from a
# project board's "Ready" column through the pr-orchestrator-generic skill.
#
# Architecture: this file is a thin, stable loop. All per-issue work lives in
# loop-issue-worker.sh, which is COPIED to a temp file and executed fresh at
# every iteration — so edits to the worker or loop-common.sh take effect on
# the NEXT issue of an already-running loop. The supervisor itself re-execs
# from a temp copy at startup, so edits to THIS file mid-run are also safe
# (they take effect on the next run, never corrupt the current one).
#
# Profiles: board + repo config lives in profiles/<name>.env. Pass
#   --profile <name>
# If the file is missing, setup-profile.sh runs automatically (needs
# --repo-dir and optionally --project, or a git checkout + board auto-detect).
#
# Selection: board Status == "Ready", sorted by priority/P0 > P1 > P2 label,
# skipping issues labeled "blocked" or "agent-failed" and issues that already
# have an open PR closing them. Filtered to the profile's REPO only.
#
# Safety model (deliberately strict — this runs unattended in your only
# checkout of the repo):
#   * Tracked edits must be CLEAN. Modified/staged files abort the run
#     (nothing is reset, stashed, or force-checked-out over your work).
#   * Untracked debris (typical: packages/*/node_modules, dist/ left after
#     switching feature branches) is auto-removed when ORCH_AUTO_CLEAN=1
#     (default). Set ORCH_AUTO_CLEAN=0 to keep the old fail-hard behavior.
#   * After each issue the worker returns to the default branch with
#     `git checkout` + clean + `git pull --ff-only`.
#   * Consecutive orchestrator failures are reported, not fatal (fail-open).
#     Each failed ticket is labeled agent-failed; the loop continues.
#
# Interrupts (Ctrl-C): the worker catches INT/TERM, kills the agent process,
# moves the issue back to Ready, and posts an @mention comment. There is no
# agent session to resume — every issue runs as a fresh headless agent turn;
# continuity lives in the git branch, the PR, and the board. Re-running the
# loop simply re-picks the interrupted issue (unless a PR already exists).
#
# Ownership + recovery: the worker labels every issue it starts with
# `agent-working` and removes the label on every exit. An issue left
# "In progress" WITH that label means the previous run died hard (kill -9,
# crash, reboot); the startup sweep re-adopts it — straight to In review if a
# PR exists, back to Ready otherwise. In-progress items WITHOUT the label are
# human-owned and are never touched.
#
# Visibility:
#   * Prints the full eligible queue (in pick order) at startup.
#   * Heartbeat line every HEARTBEAT_SECONDS while a run is in flight.
#   * Full agent stream per issue: tail -f <LOG_DIR>/issue-<N>.log
#   * @mention comments (GitHub mobile push) on ready-for-review, failure,
#     and interruption.
#
# Usage (prefer PATH wrappers in ~/.local/bin):
#   pr-loop --profile txApp --agent grok
#   pr-loop --profile pageseeds-app --agent kimi 3
#   pr-loop --profile my-app --repo-dir ~/code/my-app --project 7 --agent grok
#   pr-loop-setup my-app --repo-dir ~/code/my-app --project 7
#
# Or run this script directly with the same args.
#
# Agent selection (default: kimi, or $ORCH_AGENT if already set):
#   --agent kimi   kimi -p "/skill:pr-orchestrator-generic <N>"
#   --agent grok   grok -p "/pr-orchestrator-generic <N>" --always-approve
#   ORCH_AGENT=grok pr-loop --profile txApp
#
# Logs: ~/.kimi-code/pr-loop-<profile>/ or ~/.grok/pr-loop-<profile>/

set -uo pipefail

# --- Self-copy guard (must run before SCRIPT_DIR is used) ---------------------
# Re-exec from a temp copy so that editing THIS file mid-run cannot corrupt
# bash's lazy byte-offset reads (crash signature: stray one-char command +
# "syntax error near unexpected token" right after the queue drains). The
# worker already gets this treatment per iteration; now the supervisor does
# too. LOOP_SELF_DIR preserves the real script dir for sibling files
# (worker, loop-common.sh, profiles/) after the re-exec.
if [ -z "${LOOP_SELF_COPY:-}" ]; then
  LOOP_SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  export LOOP_SELF_DIR
  LOOP_SELF_COPY=$(mktemp -t pr-loop-self) || { echo "mktemp failed" >&2; exit 1; }
  cp "${BASH_SOURCE[0]}" "$LOOP_SELF_COPY" || { echo "self-copy failed" >&2; exit 1; }
  export LOOP_SELF_COPY
  exec bash "$LOOP_SELF_COPY" "$@"
fi
trap 'rm -f "$LOOP_SELF_COPY"' EXIT

SCRIPT_DIR=${LOOP_SELF_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}

# --- Args (parse before sourcing so ORCH_AGENT is final) -----------------------

usage() {
  cat <<'EOF'
Usage: loop-ready-issues.sh --profile NAME [--agent kimi|grok|ori|openrouter|claude] [options] [max-issues]

Required:
  --profile NAME      Load profiles/NAME.env (auto-setup if missing)

Optional:
  --agent kimi|grok|ori|openrouter|claude Which CLI/wrapper runs the orchestrator (default: kimi, or $ORCH_AGENT)
  --repo-dir PATH     Checkout path (passed to setup-profile if creating; overrides REPO_DIR after load if set before source… use for first-time setup)
  --project N         Project board number (first-time setup only)
  --owner OWNER       Project owner (default @me; first-time setup)
  --list-profiles     Print known profiles and exit
  max-issues          Stop after N issues (0 = no limit, default 0)

Environment:
  ORCH_AGENT          kimi | grok | ori | openrouter | claude (same as --agent)
  ORCH_MAX_TIER       cheap | mid | strong — cost-routing ceiling (routing.py; claude only)
  ORCH_ROUTE_<ROLE>   tier:effort pin for one role, e.g. ORCH_ROUTE_REVIEW=mid:high
  ORCH_SKILL          Skill prompt prefix (default depends on agent)
  ORCH_CLI            Override CLI binary name
  ORCH_CLI_ARGS       Extra CLI args (grok default: --always-approve; Ori is empty)
  ORCH_MODEL          Optional OpenRouter model hint passed to an Ori wrapper
  LOG_DIR             Per-issue log directory
  REPO_DIR            Working tree (also set by profile)
  MENTION_USER        GitHub login for @mentions (default: gh api user)
  SETUP_IF_MISSING    1 (default) = run setup-profile when profile file missing
  ORCH_AUTO_CLEAN     1 (default) = remove untracked debris between issues;
                      never discards modifications to tracked files
  ORCH_AUTO_MERGE     1 (default) = land each green PR before the next issue
                      (serial land). 0 = leave PRs open for human merge
  ORCH_MERGE_METHOD   squash (default) | merge | rebase  (for gh pr merge /
                      gh stack merge)
  ORCH_MERGE_WAIT_SECONDS  max wait when checks block merge (default 900)
  ORCH_MERGE_VIA_PUSH 1 (default) = if gh pr merge is blocked (e.g. "requires
                      human approval" / cannot self-approve), squash onto main
                      and push, then close the PR. Never used for stacked PRs.
  ORCH_MERGE_NO_VERIFY 1 (default) = --no-verify on push-land commits
  ORCH_STACK          auto (default) | 1 | 0
                      auto = land with `gh stack merge` when the PR is in an
                      open base/head chain; 1 = same preference when CLI present;
                      0 = never use gh stack (legacy single-PR land only).
  ORCH_STACK_ENSURE   1 (default) = each loop start installs gh-stack if missing,
                      probes GET /repos/{repo}/stacks, configures git for
                      non-interactive stack use. 0 = skip bootstrap.
  ORCH_STACK_UPGRADE  0 (default) = do not upgrade the extension every run;
                      1 = `gh extension upgrade` when already installed.
  ORCH_STACK_AUTOLAND 0 (default) = stacked/approval-blocked PRs stay open as
                      `awaiting-merge` for a human (or `gh stack merge`).
                      1 = worker lands stack-linked chains itself via
                      `gh stack merge --yes` when `gh pr merge` is blocked
                      (e.g. by a local gh shim). Bypasses human-merge guards —
                      opt in consciously.
  (Board writes removed. REST labels are the queue — see docs/github-loop.md.)

Examples:
  ./loop-ready-issues.sh --profile txApp --agent grok
  ./loop-ready-issues.sh --profile pageseeds-app --agent kimi 2
  ./loop-ready-issues.sh --profile new-app --repo-dir ~/code/new-app --project <N> --agent grok
EOF
}

POSITIONAL=()
LOOP_PROFILE_ARG=""
REPO_DIR_FOR_SETUP=""
PROJECT_FOR_SETUP=""
OWNER_FOR_SETUP=""

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
      [ $# -ge 2 ] || { echo "ABORT: --agent requires kimi, grok, ori, or openrouter" >&2; exit 1; }
      ORCH_AGENT="$2"
      shift 2
      ;;
    --agent=*)
      ORCH_AGENT="${1#--agent=}"
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
      # shellcheck source=loop-common.sh
      source "$SCRIPT_DIR/loop-common.sh"
      echo "Profiles in $PROFILES_DIR:"
      _profiles=$(list_loop_profiles || true)
      if [ -n "$_profiles" ]; then
        printf '%s\n' "$_profiles" | sed 's/^/  /'
      else
        echo "  (none — run ./setup-profile.sh <name> --repo-dir … --project N)"
      fi
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      POSITIONAL+=("$@")
      break
      ;;
    -*)
      echo "ABORT: unknown option: $1 (try --help)" >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

export ORCH_AGENT="${ORCH_AGENT:-kimi}"

# shellcheck source=loop-common.sh
source "$SCRIPT_DIR/loop-common.sh"

# Require --profile (or ORCH_PROFILE env)
LOOP_PROFILE_ARG="${LOOP_PROFILE_ARG:-${ORCH_PROFILE:-}}"
if [ -z "$LOOP_PROFILE_ARG" ]; then
  echo "ABORT: --profile NAME is required (which repo/board to drain).

Known profiles:"
  list_loop_profiles | sed 's/^/  /' || true
  echo "
Examples:
  $0 --profile txApp --agent grok
  $0 --profile pageseeds-app --agent kimi
"
  exit 1
fi

# Pass setup hints into load_loop_profile / setup-profile
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

load_loop_profile "$LOOP_PROFILE_ARG" || die "Failed to load profile '$LOOP_PROFILE_ARG'"

resolve_orch_agent

MAX_ISSUES="${1:-0}"                                # 0 = no limit
# Optional 2nd positional still accepts repo-dir override after profile load
if [ $# -ge 2 ]; then
  REPO_DIR="$2"
  export REPO_DIR
fi

# Per-profile lock so pageseeds + txApp loops can coexist (not same profile)
LOCK_DIR="$HOME/.kimi-code/pr-loop.${LOOP_PROFILE}.lock"
WORKER_SRC="$SCRIPT_DIR/loop-issue-worker.sh"
# Fail-open: never abort the run because N tickets failed.
CONSECUTIVE_FAILURE_LIMIT="${ORCH_MAX_FAILURES:-0}"

export REPO_DIR LOG_DIR HEARTBEAT_SECONDS MENTION_USER
export ORCH_AGENT ORCH_CLI ORCH_SKILL ORCH_CLI_ARGS ORCH_MODEL
export LOOP_COMMON="$SCRIPT_DIR/loop-common.sh"
export REPO PROJECT_NUMBER PROJECT_OWNER PROJECT_ID
export STATUS_FIELD_ID OPT_READY OPT_IN_PROGRESS OPT_IN_REVIEW
[ -n "${OPT_DONE:-}" ] && export OPT_DONE
[ -n "${OPT_SCOPING:-}" ] && export OPT_SCOPING
[ -n "${OPT_BACKLOG:-}" ] && export OPT_BACKLOG
export LOOP_PROFILE LOOP_PROFILE_PATH
# Stack bootstrap knobs (worker re-runs ensure_gh_stack_ready per issue)
export ORCH_STACK ORCH_STACK_ENSURE ORCH_STACK_UPGRADE ORCH_STACK_AUTOLAND
export ORCH_STACK_CLI ORCH_STACK_REPO_OK ORCH_STACK_READY

# --- Preflight ----------------------------------------------------------------

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    die "Another loop instance is running for profile '$LOOP_PROFILE' (pid $old_pid, lock: $LOCK_DIR)."
  fi
  # Stale lock: the previous process died without cleanup (kill -9, reboot).
  log "Removing stale lock (previous pid ${old_pid:-unknown} is not alive)"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || die "Could not acquire lock: $LOCK_DIR"
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$REPO_DIR" || die "Repo dir not found: $REPO_DIR"
command -v "$ORCH_CLI" >/dev/null || die "$ORCH_CLI CLI not on PATH (ORCH_AGENT=$ORCH_AGENT)"
gh auth status >/dev/null 2>&1 || die "gh CLI not authenticated"
[ -f "$WORKER_SRC" ] || die "Worker not found: $WORKER_SRC"
mention_user || die "Could not determine your GitHub login — set MENTION_USER explicitly."
if ! return_to_main; then
  log "WARNING: main checkout dirty — issues run in worktrees; tracked edits on main are left untouched"
fi
ensure_loop_labels
# Stack mode A bootstrap: install gh-stack if missing, probe repo Stacks API,
# configure local git so non-interactive stack commands don't hang.
ensure_gh_stack_ready
export ORCH_STACK_CLI ORCH_STACK_REPO_OK ORCH_STACK_READY ORCH_STACK

# Persist the full run transcript (queue, pick decisions, exit reason) to a
# per-run summary log. Previously master output was stdout-only, so there was
# no way to tell after the fact why a loop stopped (empty queue, preflight
# die, interrupt). scope-all.sh already tees its summary; mirror that here.
RUN_ID=$(date +%Y%m%d-%H%M%S)
SUMMARY_LOG="$LOG_DIR/summary-$RUN_ID.log"
exec > >(tee -a "$SUMMARY_LOG") 2>&1

log "Profile: $LOOP_PROFILE ($LOOP_PROFILE_PATH)"
log "Repo:    $REPO  |  checkout $REPO_DIR"
# Heal triage:ready-to-implement orphans → +ready before listing the queue.
# Historical bug: triage label alone was neither scoped nor shipped.
promote_triage_ready_orphans log
heal_false_dependency_blocks log
heal_unlabeled_scoped_orphans log
strip_closed_stale_labels log
# REST-only recovery: issues stuck on agent-working after a hard kill get
# re-queued (no PR) or parked as awaiting-merge (open PR).
recover_stuck_agent_working
# Restack open PR chains whose bottom PR was human-merged since the last run.
restack_open_chains

log "Queue:   REST label \`${ORCH_READY_LABEL:-ready}\` (not the project board)"
log "Ship:    ready → agent-working → land + close issue | awaiting-merge (stacked) | fail → agent-failed"
log "Stack:   ensure=${ORCH_STACK_ENSURE:-1} mode=${ORCH_STACK:-auto} cli=${ORCH_STACK_CLI:-0} repo_ok=${ORCH_STACK_REPO_OK:-0} ready=${ORCH_STACK_READY:-0}"
log "You:     gh issue edit N --add-label ready   # enqueue"
log "         gh issue edit N --remove-label agent-failed --add-label ready  # retry"
log "         (triage:ready-to-implement alone is auto-healed to ready on loop start)"
log "         (scoped issues that lost every ship/park label are auto-healed to ready on loop start)"
log "Skips:   Epic: titles, agent-failed/blocked/agent-working, open Closes #N PR"
log "Agent:   $ORCH_AGENT ($ORCH_CLI -p \"$ORCH_SKILL <N>\"${ORCH_CLI_ARGS:+ $ORCH_CLI_ARGS})"
log "Logs:    $LOG_DIR"
log "Eligible queue (label=${ORCH_READY_LABEL:-ready}):"
if queue=$(ready_label_candidates list) && [ -n "$queue" ]; then
  echo "$queue" | sed 's/^/    /'
else
  log "    (empty — add label \`ready\` to open issues you want shipped)"
fi

# --- Main loop -----------------------------------------------------------------

completed=0
consecutive_failures=0

while true; do
  if [ "$MAX_ISSUES" -gt 0 ] && [ "$completed" -ge "$MAX_ISSUES" ]; then
    log "Reached max-issues limit ($MAX_ISSUES). Done."
    break
  fi

  if ! pick=$(ready_label_candidates pick); then
    die "Failed to list issues with label ready (REST). Check 'gh auth status' and network."
  fi
  if [ -z "$pick" ]; then
    queue=$(ready_label_candidates list || true)
    if printf '%s' "$queue" | grep -q DEFERRED; then
      log "Ready queue has deferred issues (deps not shippable yet) — not Done:"
      echo "$queue" | sed 's/^/    /'
    else
      log "No open issues with label \`${ORCH_READY_LABEL:-ready}\`."
    fi
    break
  fi
  issue=$pick

  log "=== Issue #$issue — starting orchestrator ($ORCH_AGENT) ==="
  log "    Live stream: tail -f $LOG_DIR/issue-$issue.log"

  # Live-swap: run a per-iteration copy of the worker, so edits to
  # loop-issue-worker.sh / loop-common.sh apply to the NEXT issue.
  worker_copy=$(mktemp -t pr-loop-worker) || die "mktemp failed"
  cp "$WORKER_SRC" "$worker_copy"
  bash "$worker_copy" "$issue"
  rc=$?
  rm -f "$worker_copy"

  if [ "$rc" -eq 130 ] || [ "$rc" -eq 143 ]; then
    log "Interrupted — exiting. Issue #$issue has label ready restored."
    exit "$rc"
  elif [ "$rc" -eq 44 ]; then
    # Worker already restored ready + printed guidance. Stop the fleet:
    # every remaining ticket would die on the same exhausted quota.
    log "Agent quota exhausted — run aborted early. Issue #$issue re-queued as \`${ORCH_READY_LABEL:-ready}\`."
    exit 44
  elif [ "$rc" -eq 42 ]; then
    # Legacy preflight. Worktrees should make this rare — park and continue.
    log "Worker preflight failed for #$issue — continuing (fail-open)."
    consecutive_failures=$((consecutive_failures + 1))
  elif [ "$rc" -eq 0 ]; then
    consecutive_failures=0
    completed=$((completed + 1))
  else
    consecutive_failures=$((consecutive_failures + 1))
    if [ "$CONSECUTIVE_FAILURE_LIMIT" -gt 0 ] && [ "$consecutive_failures" -ge "$CONSECUTIVE_FAILURE_LIMIT" ]; then
      log "NOTE: $consecutive_failures consecutive failures (ORCH_MAX_FAILURES=$CONSECUTIVE_FAILURE_LIMIT) — continuing anyway (fail-open)."
    fi
  fi
done

return_to_main || log "WARNING: could not return main to a clean default branch (your tracked edits are intact)."
log "Loop finished. $completed issue(s) processed (closed if landed)."
report_leftovers | while IFS= read -r line; do log "$line"; done
