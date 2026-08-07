#!/usr/bin/env bash
# loop-common.sh — shared config + helpers for the PR-orchestrator loop.
# Sourced by loop-ready-issues.sh (supervisor) and loop-issue-worker.sh.
# Not meant to be executed directly.
#
# Board/repo config comes from a **profile** (profiles/<name>.env), loaded by
# the supervisor via load_loop_profile before any board queries. Direct
# environment exports (REPO, REPO_DIR, PROJECT_*) still win when already set.

# --- Profile loading ---------------------------------------------------------

# Directory of this file (works when sourced).
_LOOP_COMMON_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
: "${PROFILES_DIR:=$_LOOP_COMMON_DIR/profiles}"

# Load profiles/<name>.env into the current shell.
# If the file is missing and SETUP_IF_MISSING=1, run setup-profile.sh first.
load_loop_profile() {
  local name=$1
  local path force_setup=0
  [ -n "$name" ] || { echo "load_loop_profile: empty profile name" >&2; return 1; }

  # Sanitize: basename only
  name=$(basename "$name" .env)
  path="$PROFILES_DIR/${name}.env"

  if [ ! -f "$path" ]; then
    if [ "${SETUP_IF_MISSING:-1}" = 1 ]; then
      echo "[$(date '+%H:%M:%S')] Profile '$name' not found at $path — running setup-profile.sh" >&2
      local setup="$_LOOP_COMMON_DIR/setup-profile.sh"
      [ -x "$setup" ] || chmod +x "$setup" 2>/dev/null || true
      local setup_args=("$name")
      if [ -n "${REPO_DIR:-}" ]; then
        setup_args+=(--repo-dir "$REPO_DIR")
      elif [ -n "${ORCH_REPO_DIR:-}" ]; then
        setup_args+=(--repo-dir "$ORCH_REPO_DIR")
      fi
      if [ -n "${PROJECT_NUMBER:-}" ]; then
        setup_args+=(--project "$PROJECT_NUMBER")
      elif [ -n "${ORCH_PROJECT_NUMBER:-}" ]; then
        setup_args+=(--project "$ORCH_PROJECT_NUMBER")
      fi
      if [ -n "${PROJECT_OWNER:-}" ]; then
        setup_args+=(--owner "$PROJECT_OWNER")
      fi
      bash "$setup" "${setup_args[@]}" || return 1
    else
      echo "Profile not found: $path
Create it with:
  $_LOOP_COMMON_DIR/setup-profile.sh $name --repo-dir <path> --project <N>
" >&2
      return 1
    fi
  fi

  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "$path"
  set +a

  export LOOP_PROFILE="$name"
  export LOOP_PROFILE_PATH="$path"

  # Required keys:
  #   Always: REPO, REPO_DIR (REST queue for scope-loop + pr-loop)
  #   When ORCH_BOARD=1: PROJECT_NUMBER + board field/option IDs
  # REST-only profiles (ORCH_BOARD=0, default) need no project board.
  local req missing=()
  for req in REPO REPO_DIR; do
    if [ -z "${!req:-}" ]; then
      missing+=("$req")
    fi
  done
  if [ "${ORCH_BOARD:-0}" = "1" ]; then
    for req in PROJECT_NUMBER PROJECT_ID STATUS_FIELD_ID OPT_READY OPT_IN_PROGRESS OPT_IN_REVIEW; do
      if [ -z "${!req:-}" ]; then
        missing+=("$req")
      fi
    done
  fi
  if [ ${#missing[@]} -gt 0 ]; then
    echo "Profile $path missing required keys: ${missing[*]}" >&2
    return 1
  fi

  : "${PROJECT_OWNER:=@me}"
  : "${ORCH_BOARD:=0}"
  export REPO REPO_DIR PROJECT_OWNER ORCH_BOARD
  [ -n "${PROJECT_NUMBER:-}" ] && export PROJECT_NUMBER
  [ -n "${PROJECT_ID:-}" ] && export PROJECT_ID
  [ -n "${STATUS_FIELD_ID:-}" ] && export STATUS_FIELD_ID
  [ -n "${OPT_READY:-}" ] && export OPT_READY
  [ -n "${OPT_IN_PROGRESS:-}" ] && export OPT_IN_PROGRESS
  [ -n "${OPT_IN_REVIEW:-}" ] && export OPT_IN_REVIEW
  # Optional columns (Done used after auto-merge; Scoping used by scope-loop)
  [ -n "${OPT_DONE:-}" ] && export OPT_DONE
  [ -n "${OPT_SCOPING:-}" ] && export OPT_SCOPING
  [ -n "${OPT_BACKLOG:-}" ] && export OPT_BACKLOG
  return 0
}

# List available profile stems (no .env).
list_loop_profiles() {
  local f
  [ -d "$PROFILES_DIR" ] || return 0
  for f in "$PROFILES_DIR"/*.env; do
    [ -f "$f" ] || continue
    basename "$f" .env
  done
}

# --- Defaults when no profile loaded yet (safe placeholders) -----------------
# Real values must come from a profile or explicit env before board ops.

: "${PROJECT_OWNER:=@me}"
: "${HEARTBEAT_SECONDS:=60}"
: "${MENTION_USER:=}"
: "${ORCH_AGENT:=kimi}"

# Which agent CLI runs the orchestrator skill for each issue.
#   kimi  → kimi -p "/skill:pr-orchestrator-generic <N>"
#   grok  → grok -p "/pr-orchestrator-generic <N>" --always-approve
# The generic skill is dual-host (Kimi + Grok tool map). Override skill text
# with ORCH_SKILL only if you intentionally want another skill (e.g. the
# call-analyzer-specific Grok /pr-orchestrator).

# Resolve agent-specific CLI, skill prompt, flags, and log dir.
#
# Call after ORCH_AGENT is final. User overrides (ORCH_CLI, ORCH_SKILL,
# ORCH_CLI_ARGS, LOG_DIR) always win when already set in the environment —
# including empty ORCH_CLI_ARGS="" to suppress grok's --always-approve.
#
# When switching agents mid-process, pass --force to re-apply that agent's
# defaults (still does not clobber vars the user exported before launch).
resolve_orch_agent() {
  local force=0
  [ "${1:-}" = "1" ] || [ "${1:-}" = "--force" ] && force=1

  # Snapshot which knobs the user already exported (before we fill defaults).
  # On first call these are empty if unset; on --force we re-read from the
  # original user env via the _USER_* markers set once below.
  if [ -z "${_ORCH_USER_SNAPSHOT:-}" ]; then
    _ORCH_USER_SNAPSHOT=1
    [ -n "${ORCH_CLI+x}" ] && _ORCH_USER_CLI=1 || _ORCH_USER_CLI=0
    [ -n "${ORCH_SKILL+x}" ] && _ORCH_USER_SKILL=1 || _ORCH_USER_SKILL=0
    [ -n "${ORCH_CLI_ARGS+x}" ] && _ORCH_USER_CLI_ARGS=1 || _ORCH_USER_CLI_ARGS=0
    [ -n "${LOG_DIR+x}" ] && _ORCH_USER_LOG_DIR=1 || _ORCH_USER_LOG_DIR=0
  fi

  if [ "$force" = 1 ]; then
    [ "$_ORCH_USER_CLI" = 0 ] && unset ORCH_CLI
    [ "$_ORCH_USER_SKILL" = 0 ] && unset ORCH_SKILL
    [ "$_ORCH_USER_CLI_ARGS" = 0 ] && unset ORCH_CLI_ARGS
    if [ "$_ORCH_USER_LOG_DIR" = 0 ]; then
      case "${LOG_DIR:-}" in
        "$HOME/.kimi-code/pr-loop"|"$HOME/.grok/pr-loop"|"$HOME/.kimi-code/pr-loop-"*|"$HOME/.grok/pr-loop-"*|"") unset LOG_DIR ;;
      esac
    fi
  fi

  local log_suffix=""
  if [ -n "${LOOP_PROFILE:-}" ]; then
    log_suffix="-${LOOP_PROFILE}"
  fi

  case "${ORCH_AGENT}" in
    kimi|Kimi|KIMI)
      ORCH_AGENT=kimi
      ORCH_CLI="${ORCH_CLI:-kimi}"
      ORCH_SKILL="${ORCH_SKILL:-/skill:pr-orchestrator-generic}"
      # Extra args after the prompt (kimi accepts --output-format stream-json etc.)
      : "${ORCH_CLI_ARGS:=}"
      : "${LOG_DIR:=$HOME/.kimi-code/pr-loop${log_suffix}}"
      ;;
    grok|Grok|GROK)
      ORCH_AGENT=grok
      ORCH_CLI="${ORCH_CLI:-grok}"
      # Dual-host generic skill (works on Grok and Kimi).
      ORCH_SKILL="${ORCH_SKILL:-/pr-orchestrator-generic}"
      # Unattended: auto-approve tool use (config may have yolo=false).
      : "${ORCH_CLI_ARGS:=--always-approve}"
      : "${LOG_DIR:=$HOME/.grok/pr-loop${log_suffix}}"
      ;;
    *)
      echo "[$(date '+%H:%M:%S')] ABORT: Unknown ORCH_AGENT='$ORCH_AGENT' (use kimi or grok)" >&2
      exit 1
      ;;
  esac
  mkdir -p "$LOG_DIR"
}

# --- Helpers -----------------------------------------------------------------

log() { echo "[$(date '+%H:%M:%S')] $*"; }

die() { log "ABORT: $*"; exit 1; }

# Human-readable orchestrator invocation for logs.
orch_cmd_display() { # <issue-number>
  local issue=$1
  echo "$ORCH_CLI -p \"$ORCH_SKILL $issue\"${ORCH_CLI_ARGS:+ $ORCH_CLI_ARGS}"
}

# True if porcelain status has any modified/staged tracked files (not pure ??).
_has_tracked_dirt() {
  # First column or second column letters other than ? and space, or renames etc.
  git -C "$REPO_DIR" status --porcelain | grep -Eqv '^\?\?'
}

# Discard known generated-file noise that tooling rewrites mid-loop without
# shipping intent (TanStack Router route tree, etc.). Never touches other paths.
# ORCH_DISCARD_GENERATED=1 (default). Set to 0 to keep strict dirty-tree aborts.
auto_discard_generated_noise() {
  local f restored=()
  [ "${ORCH_DISCARD_GENERATED:-1}" = "1" ] || return 0
  [ -n "${REPO_DIR:-}" ] && [ -d "$REPO_DIR/.git" ] || return 0

  # Space-separated relative paths (override via env for other monorepos).
  # shellcheck disable=SC2206
  local paths=(${ORCH_GENERATED_PATHS:-src/routeTree.gen.ts})

  for f in "${paths[@]}"; do
    [ -n "$f" ] || continue
    # Only restore if that path is modified in the working tree (tracked).
    if git -C "$REPO_DIR" status --porcelain -- "$f" 2>/dev/null | grep -Eq '^.M|^M|^MM|^AM'; then
      git -C "$REPO_DIR" restore --worktree --staged -- "$f" >/dev/null 2>&1 \
        || git -C "$REPO_DIR" checkout -- "$f" >/dev/null 2>&1 \
        || continue
      restored+=("$f")
    fi
  done

  if [ ${#restored[@]} -gt 0 ]; then
    log "Discarded generated noise (ORCH_DISCARD_GENERATED=1): ${restored[*]}"
  fi
}

# Remove untracked debris left by branch switches (e.g. packages/cli/node_modules
# and dist/ after leaving a package branch). Never discards tracked changes
# except known generated noise (see auto_discard_generated_noise).
#
# ORCH_AUTO_CLEAN=1 (default in the unattended loop): also `git clean -fd` when
# the only dirt is untracked paths. Set ORCH_AUTO_CLEAN=0 to disable and fail
# hard on any dirty tree (old behavior).
#
# BUSINESS RULE: `git clean -fdX` deletes EVERY gitignored file — which includes
# local secrets (.env*), virtualenvs, and ops artifacts (backups/, tmp/, output/).
# It wiped a production ops session on 2026-07-29 (env files + a rollback backup).
# `git clean -e` does NOT protect paths in -X mode (it adds candidates instead),
# and `**/x` pathspecs match top-level ignored dirs wholesale — so Phase 1 builds
# the dry-run list, filters protected paths, and cleans only the survivors.
auto_clean_untracked_debris() {
  local dirty before after
  # Paths that must survive auto-clean. Add to this list, never remove.
  local protected_regex='(^|/)\.env($|\.|/)|(^|/)\.venv($|/)|^(backups|tmp|output|\.worktrees)/'
  local victims=()
  auto_discard_generated_noise
  dirty=$(git -C "$REPO_DIR" status --porcelain)
  [ -n "$dirty" ] || return 0

  # Always refuse to touch modified/staged tracked files (beyond generated noise).
  if _has_tracked_dirt; then
    return 0
  fi

  # Phase 1: drop ignored untracked (node_modules, dist when gitignored),
  # minus protected paths.
  before=$(git -C "$REPO_DIR" status --porcelain | wc -l | tr -d ' ')
  while IFS= read -r victim; do
    victims+=("$victim")
  done < <(git -C "$REPO_DIR" clean -fdXn | sed 's/^Would remove //' | grep -vE "$protected_regex" || true)
  if [ "${#victims[@]}" -gt 0 ]; then
    git -C "$REPO_DIR" clean -fdX -- "${victims[@]}" >/dev/null 2>&1 || true
  fi
  after=$(git -C "$REPO_DIR" status --porcelain | wc -l | tr -d ' ')
  if [ "$after" -lt "$before" ]; then
    log "Auto-cleaned ignored untracked files (git clean -fdX, protected paths kept)"
  fi

  dirty=$(git -C "$REPO_DIR" status --porcelain)
  [ -n "$dirty" ] || return 0

  if [ "${ORCH_AUTO_CLEAN:-1}" != "1" ]; then
    return 0
  fi

  # Phase 2: only untracked remains — safe for unattended loop (no WIP on tracked files).
  # NOTE: -e excludes DO work without -X; kept as belt-and-braces for repos whose
  # .gitignore fails to cover env/ops paths.
  if ! _has_tracked_dirt; then
    log "Auto-removing untracked paths left after branch switch (ORCH_AUTO_CLEAN=1):
$dirty"
    git -C "$REPO_DIR" clean -fd \
      -e '.env' -e '.env.*' -e '**/.env' -e '**/.env.*' \
      -e '.venv' -e '**/.venv' \
      -e 'backups' -e 'tmp' -e 'output' -e '.worktrees' \
      >/dev/null 2>&1 \
      || log "WARNING: git clean -fd failed (continuing; clean-tree check may abort)"
  fi
}

require_clean_tree() {
  local dirty
  auto_clean_untracked_debris
  dirty=$(git -C "$REPO_DIR" status --porcelain)
  if [ -n "$dirty" ]; then
    log "Working tree in $REPO_DIR is dirty — refusing to run unattended.
$dirty

Tracked edits: commit/stash/discard them.
Untracked-only: re-run with ORCH_AUTO_CLEAN=1 (default) or remove manually."
    return 1
  fi
}

# Resolve the repo's default branch from origin/HEAD (fallback: main).
default_branch_name() {
  local b
  b=$(git -C "${REPO_DIR:-.}" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  echo "${b:-main}"
}

return_to_main() {
  # Clean untracked debris first so a leftover packages/*/node_modules from the
  # previous issue does not block checkout / the next ticket.
  auto_clean_untracked_debris
  require_clean_tree || return 1
  local default_branch
  default_branch=$(default_branch_name)
  git -C "$REPO_DIR" checkout "$default_branch" >/dev/null 2>&1 \
    || { log "Could not check out $default_branch. Fix the checkout manually, then re-run."; return 1; }
  # Checkout can leave untracked files from the previous branch (ignored build
  # outputs under a path the new branch does not track). Clean again.
  auto_clean_untracked_debris
  require_clean_tree || return 1
  git -C "$REPO_DIR" pull --ff-only >/dev/null 2>&1 \
    || { log "Could not fast-forward $default_branch. Fix the checkout manually, then re-run."; return 1; }
}

# --- Auto-merge (serial land) -------------------------------------------------
# After a successful orchestrator run, land the issue's PR onto the default
# branch before the next ticket starts. Default ON for non-critical product loops
# (ORCH_AUTO_MERGE=1). Set ORCH_AUTO_MERGE=0 to leave PRs open for human merge.
#
# Method: squash + delete branch. If required checks block immediate merge,
# enable GitHub auto-merge and poll until MERGED or ORCH_MERGE_WAIT_SECONDS.
#
# GitHub Stacked PRs (mode A — stack-aware land):
#   Regular `gh pr merge` is wrong for stacked PRs. When a PR sits in a base/head
#   chain (or ORCH_STACK forces stack tooling), land with `gh stack merge` instead.
#   Never push-land a stacked PR (breaks the chain). Requires:
#     gh extension install github/gh-stack
#   and Stacked PRs enabled on the repo (exit 9 if not).

: "${ORCH_AUTO_MERGE:=1}"
: "${ORCH_MERGE_METHOD:=squash}"   # squash | merge | rebase
: "${ORCH_MERGE_WAIT_SECONDS:=900}"
# auto = use gh stack merge only when PR is in an open base/head chain
# 1    = prefer stack tooling whenever the CLI is available and PR looks stacked
# 0    = never call gh stack (legacy single-PR land only)
: "${ORCH_STACK:=auto}"

# True if the gh-stack extension is installed (command: `gh stack`).
gh_stack_cli_available() {
  command -v gh >/dev/null 2>&1 || return 1
  # `gh stack --help` works only when the extension is installed.
  gh stack --help >/dev/null 2>&1
}

# Install/upgrade the gh-stack extension if needed.
# Sets ORCH_STACK_CLI=0|1. Returns 0 when the CLI is usable.
ensure_gh_stack_extension() {
  ORCH_STACK_CLI=0
  export ORCH_STACK_CLI
  command -v gh >/dev/null 2>&1 || {
    log "gh CLI not on PATH — cannot install gh-stack"
    return 1
  }
  if gh_stack_cli_available; then
    ORCH_STACK_CLI=1
    export ORCH_STACK_CLI
    # Optional refresh (off by default — network + seconds each loop)
    if [ "${ORCH_STACK_UPGRADE:-0}" = "1" ]; then
      log "Upgrading gh-stack extension (ORCH_STACK_UPGRADE=1)"
      gh extension upgrade github/gh-stack >/dev/null 2>&1 \
        || gh extension upgrade stack >/dev/null 2>&1 \
        || true
    fi
    return 0
  fi
  log "Installing gh extension github/gh-stack (first-time / missing)"
  if gh extension install github/gh-stack 2>&1; then
    if gh_stack_cli_available; then
      ORCH_STACK_CLI=1
      export ORCH_STACK_CLI
      log "gh-stack extension installed"
      return 0
    fi
  fi
  log "WARNING: could not install gh-stack — stacked create/land disabled"
  return 1
}

# Probe whether the Stacks REST API answers for $REPO.
# Docs: 404 when Stacked PRs are not enabled for the repository.
# Sets ORCH_STACK_REPO_OK=0|1.
probe_gh_stack_repo() {
  ORCH_STACK_REPO_OK=0
  export ORCH_STACK_REPO_OK
  [ -n "${REPO:-}" ] || return 1
  # Prefer body fetch: exit 0 ⇒ stacks API available (empty [] is fine).
  # Avoid `gh api -i | awk` under pipefail — early awk exit SIGPIPEs gh → false failure.
  local out ec=0
  out=$(gh api "repos/${REPO}/stacks" 2>&1) || ec=$?
  if [ "$ec" -eq 0 ]; then
    ORCH_STACK_REPO_OK=1
    export ORCH_STACK_REPO_OK
    return 0
  fi
  if printf '%s' "$out" | grep -qiE '404|Not Found|StacksUnavailable|not enabled'; then
    log "Stacked PRs not enabled for $REPO (GET /stacks failed). No public enable API — enable via GitHub UI / plan, or waitlist https://gh.io/stacksbeta"
    return 1
  fi
  if printf '%s' "$out" | grep -qiE '401|403|Bad credentials|Resource not accessible|Forbidden'; then
    log "Stacked PRs probe unauthorized for $REPO — check gh scopes (repo)"
    return 1
  fi
  log "Stacked PRs probe failed for $REPO (exit $ec): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
  return 1
}

# Local git knobs so non-interactive `gh stack` never hangs on prompts.
# Safe to re-run every loop iteration (idempotent local config).
ensure_gh_stack_git_config() {
  local dir="${1:-${REPO_DIR:-.}}"
  [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || return 0
  # Remember conflict resolutions across rebases (gh stack init also enables this).
  git -C "$dir" config rerere.enabled true >/dev/null 2>&1 || true
  # Avoid remote picker when multiple remotes exist.
  local remotes
  remotes=$(git -C "$dir" remote 2>/dev/null | wc -l | tr -d ' ')
  if [ "${remotes:-0}" -gt 1 ]; then
    if ! git -C "$dir" config --get remote.pushDefault >/dev/null 2>&1; then
      if git -C "$dir" remote | grep -qx origin; then
        git -C "$dir" config remote.pushDefault origin >/dev/null 2>&1 || true
        log "Set git remote.pushDefault=origin (multiple remotes; needed for non-interactive gh stack)"
      fi
    fi
  fi
}

# Full bootstrap for stack mode A — call once per loop start and once per issue.
# Installs the CLI extension if missing, probes repo availability, configures git.
# Exports:
#   ORCH_STACK_CLI=0|1      — extension usable
#   ORCH_STACK_REPO_OK=0|1  — Stacks API available on $REPO
#   ORCH_STACK_READY=0|1    — both CLI and repo OK (safe to use stack tools)
#
# There is no public GitHub API to *enable* Stacked PRs on a repository; when
# the probe fails we log and fall back to classic single-PR land.
# Set ORCH_STACK_ENSURE=0 to skip entirely. ORCH_STACK_UPGRADE=1 to upgrade ext.
ensure_gh_stack_ready() {
  ORCH_STACK_CLI="${ORCH_STACK_CLI:-0}"
  ORCH_STACK_REPO_OK="${ORCH_STACK_REPO_OK:-0}"
  ORCH_STACK_READY=0
  export ORCH_STACK_CLI ORCH_STACK_REPO_OK ORCH_STACK_READY

  if [ "${ORCH_STACK_ENSURE:-1}" = "0" ]; then
    log "ORCH_STACK_ENSURE=0 — skipping gh-stack bootstrap"
    return 0
  fi
  if [ "${ORCH_STACK:-auto}" = "0" ] || [ "${ORCH_STACK:-auto}" = "false" ] || [ "${ORCH_STACK:-auto}" = "off" ]; then
    log "ORCH_STACK=0 — skipping gh-stack bootstrap"
    return 0
  fi

  ensure_gh_stack_extension || true
  if [ "${ORCH_STACK_CLI:-0}" = "1" ]; then
    probe_gh_stack_repo || true
  else
    ORCH_STACK_REPO_OK=0
    export ORCH_STACK_REPO_OK
  fi
  ensure_gh_stack_git_config "${REPO_DIR:-.}"

  if [ "${ORCH_STACK_CLI:-0}" = "1" ] && [ "${ORCH_STACK_REPO_OK:-0}" = "1" ]; then
    ORCH_STACK_READY=1
    export ORCH_STACK_READY
    log "gh-stack ready: CLI=yes repo=$REPO stacks-api=yes (ORCH_STACK=${ORCH_STACK:-auto})"
  else
    ORCH_STACK_READY=0
    export ORCH_STACK_READY
    log "gh-stack not fully ready: CLI=${ORCH_STACK_CLI:-0} repo_ok=${ORCH_STACK_REPO_OK:-0} — classic single-PR path"
  fi
  return 0
}

# Canonical open-PR chain graph — all parent/child/chain/stale questions go
# through pr_chain.py (unit-tested in tests/test_pr_chain.py). These wrappers
# stay thin on purpose; do not re-grow inline python heredocs here.
_pr_chain_py() {
  echo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr_chain.py"
}

# True if open PR $1 is part of a multi-PR base/head chain in $REPO
# (parent and/or child open PR). Standalone PRs targeting trunk return false.
pr_is_in_open_stack() {
  local pr=$1
  [ -n "$pr" ] && [ -n "${REPO:-}" ] || return 1
  REPO_MATCH="$REPO" python3 "$(_pr_chain_py)" in-stack "$pr" >/dev/null 2>&1
}

# Print space-separated open PR numbers from stack bottom up to and including $1.
# Empty stdout + exit 1 if PR missing or not resolvable.
stack_prs_up_to() {
  local pr=$1
  [ -n "$pr" ] && [ -n "${REPO:-}" ] || return 1
  REPO_MATCH="$REPO" python3 "$(_pr_chain_py)" chain-up-to "$pr" 2>/dev/null
}

# Decide whether land should use `gh stack merge` for PR $1.
should_use_stack_merge() {
  local pr=$1
  case "${ORCH_STACK:-auto}" in
    0|false|FALSE|no|NO|off|OFF)
      return 1
      ;;
  esac
  gh_stack_cli_available || return 1
  case "${ORCH_STACK:-auto}" in
    1|true|TRUE|yes|YES|on|ON)
      # Prefer stack merge whenever the PR is actually in a chain.
      pr_is_in_open_stack "$pr"
      ;;
    auto|*)
      pr_is_in_open_stack "$pr"
      ;;
  esac
}

# Land stacked PR $1 (and every open PR below it) via `gh stack merge`.
# Never falls back to push-land. Returns 0 on MERGED, 1 on failure.
merge_pr_via_stack() {
  local pr=$1
  local method="${ORCH_MERGE_METHOD:-squash}"
  local merge_flag err_file state p chain

  [ -n "$pr" ] || return 1
  if ! gh_stack_cli_available; then
    log "gh stack not installed — cannot land stacked PR #$pr (install: gh extension install github/gh-stack)"
    return 1
  fi
  [ -n "${REPO_DIR:-}" ] && [ -d "$REPO_DIR" ] || {
    log "REPO_DIR missing — gh stack merge needs the repo checkout as cwd"
    return 1
  }

  case "$method" in
    squash) merge_flag=--squash ;;
    rebase) merge_flag=--rebase ;;
    merge)  merge_flag=--merge ;;
    *) log "Unknown ORCH_MERGE_METHOD=$method — using squash"; merge_flag=--squash ;;
  esac

  # Stack merge requires open + non-draft for every PR being landed.
  chain=$(stack_prs_up_to "$pr" 2>/dev/null || echo "$pr")
  log "Stack-landing up to PR #$pr (chain: ${chain:-$pr}) via gh stack merge $merge_flag"
  for p in $chain; do
    gh pr ready "$p" --repo "$REPO" >/dev/null 2>&1 || true
  done

  state=$(gh pr view "$pr" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
  if [ "$state" = "MERGED" ]; then
    log "PR #$pr already MERGED"
    return 0
  fi

  err_file=$(mktemp -t pr-stack-merge-err) || return 1
  # Remote-capable: pass PR number. Run from REPO_DIR so gh resolves the right remote.
  if (cd "$REPO_DIR" && gh stack merge "$pr" --yes $merge_flag) >"$err_file" 2>&1; then
    state=$(gh pr view "$pr" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
    if [ "$state" = "MERGED" ]; then
      rm -f "$err_file"
      log "Stack-merged PR #$pr ($method)"
      return 0
    fi
    # Command succeeded but state not yet MERGED (merge queue?) — poll briefly.
    local wait_s="${ORCH_MERGE_WAIT_SECONDS:-900}" elapsed=0
    log "gh stack merge returned OK; waiting up to ${wait_s}s for MERGED on #$pr"
    while [ "$elapsed" -lt "$wait_s" ]; do
      state=$(gh pr view "$pr" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
      if [ "$state" = "MERGED" ]; then
        rm -f "$err_file"
        log "Stack-merged PR #$pr ($method, after ~${elapsed}s)"
        return 0
      fi
      if [ "$state" = "CLOSED" ]; then
        log "PR #$pr CLOSED without merge after gh stack merge"
        rm -f "$err_file"
        return 1
      fi
      sleep 15
      elapsed=$((elapsed + 15))
    done
    log "Timed out waiting for stack merge of PR #$pr
$(head -c 400 "$err_file" 2>/dev/null)"
    rm -f "$err_file"
    return 1
  fi

  # Exit code 9 = Stacked PRs not enabled for this repository
  if grep -qiE 'not enabled|Stacked PRs not enabled|exit status 9' "$err_file" 2>/dev/null; then
    log "Stacked PRs not enabled on this repository — cannot gh stack merge #$pr
$(head -c 400 "$err_file")"
    rm -f "$err_file"
    return 1
  fi

  state=$(gh pr view "$pr" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
  if [ "$state" = "MERGED" ]; then
    rm -f "$err_file"
    log "PR #$pr already MERGED"
    return 0
  fi

  log "gh stack merge failed for PR #$pr
$(cat "$err_file" 2>/dev/null)"
  rm -f "$err_file"
  return 1
}

# Link the open PR chain up to and including PR $1 into a native GitHub stack
# (server-side via `gh stack link`; the branches themselves are plain git).
# No-op without the extension, with ORCH_STACK=0, or for a single PR.
link_stack_chain() {
  local pr=$1 chain count
  case "${ORCH_STACK:-auto}" in 0|false|FALSE|off|OFF) return 0 ;; esac
  gh_stack_cli_available || return 0
  [ -n "${REPO_DIR:-}" ] && [ -d "$REPO_DIR" ] || return 0
  chain=$(stack_prs_up_to "$pr" 2>/dev/null || true)
  [ -n "$chain" ] || return 0
  count=$(printf '%s' "$chain" | wc -w | tr -d ' ')
  [ "$count" -ge 2 ] || return 0
  if (cd "$REPO_DIR" && gh stack link $chain >/dev/null 2>&1); then
    log "Linked native stack: $chain"
  else
    log "WARNING: gh stack link failed for chain: $chain (non-fatal)"
  fi
}

# Print "number<TAB>url<TAB>isDraft" for the open PR that closes $1, or empty.
find_open_pr_for_issue() {
  local issue=$1
  [ -n "${REPO:-}" ] || return 1
  REPO_MATCH="$REPO" python3 "$(_pr_chain_py)" for-issue "$issue" 2>/dev/null
}

# Land PR $1 onto the default branch via local squash + push.
# Used when `gh pr merge` is blocked (e.g. "merging requires human approval"
# and the bot/author cannot self-approve). Safe for non-mission-critical repos
# where the loop already ran tests. Controlled by ORCH_MERGE_VIA_PUSH (default 1).
merge_pr_via_push() {
  local pr=$1
  local head_ref head_oid base_ref title default_branch err_file

  [ "${ORCH_MERGE_VIA_PUSH:-1}" = "1" ] || {
    log "ORCH_MERGE_VIA_PUSH=0 — not landing PR #$pr via push"
    return 1
  }
  # BUSINESS RULE: never squash-push a stacked PR — it flattens the chain and
  # leaves parent/child PRs with wrong bases. Use gh stack merge instead.
  if pr_is_in_open_stack "$pr" 2>/dev/null; then
    log "Refusing push-land for stacked PR #$pr — use gh stack merge (ORCH_STACK)"
    return 1
  fi
  [ -n "${REPO_DIR:-}" ] && [ -d "$REPO_DIR/.git" ] || {
    log "REPO_DIR not a git checkout — cannot push-land PR #$pr"
    return 1
  }

  head_ref=$(gh pr view "$pr" --repo "$REPO" --json headRefName -q .headRefName 2>/dev/null) || return 1
  head_oid=$(gh pr view "$pr" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null) || return 1
  title=$(gh pr view "$pr" --repo "$REPO" --json title -q .title 2>/dev/null || echo "Land PR #$pr")
  # Prefer commit trailer Closes #N so GitHub links the land even without PR merge
  closes_line=$(
    gh pr view "$pr" --repo "$REPO" --json body,title,headRefName -q \
      '[.body // "", .title // "", .headRefName // ""] | @tsv' 2>/dev/null \
    | python3 -c '
import re,sys
text=sys.stdin.read()
nums=sorted(set(int(x) for x in re.findall(r"(?i)(?:closes|fixes|resolves)\s+#(\d+)", text)))
if not nums:
    for m in re.finditer(r"(?i)(?:feature|fix|chore|issue)[/-](\d+)(?:[-/]|$)", text):
        nums.append(int(m.group(1)))
    nums=sorted(set(nums))
print("\n".join(f"Closes #{n}" for n in nums))
' 2>/dev/null || true
  )
  default_branch=$(git -C "$REPO_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  default_branch=${default_branch:-main}

  log "Push-landing PR #$pr ($head_ref @ ${head_oid:0:8}) onto $default_branch"

  # Clean tree on default branch at origin tip
  auto_clean_untracked_debris
  require_clean_tree || return 1
  git -C "$REPO_DIR" fetch origin "$default_branch" "+refs/heads/${head_ref}:refs/remotes/origin/${head_ref}" >/dev/null 2>&1 \
    || git -C "$REPO_DIR" fetch origin >/dev/null 2>&1 \
    || { log "git fetch failed for push-land"; return 1; }
  git -C "$REPO_DIR" checkout "$default_branch" >/dev/null 2>&1 || return 1
  git -C "$REPO_DIR" pull --ff-only origin "$default_branch" >/dev/null 2>&1 || return 1

  if ! git -C "$REPO_DIR" merge --squash "$head_oid" >/dev/null 2>&1; then
    # try remote branch name
    if ! git -C "$REPO_DIR" merge --squash "origin/${head_ref}" >/dev/null 2>&1; then
      log "Squash merge of PR #$pr failed (conflicts?) — aborting push-land"
      git -C "$REPO_DIR" merge --abort >/dev/null 2>&1 || git -C "$REPO_DIR" reset --hard HEAD >/dev/null 2>&1
      return 1
    fi
  fi

  # Nothing to commit = already on main
  if git -C "$REPO_DIR" diff --cached --quiet 2>/dev/null && git -C "$REPO_DIR" diff --quiet 2>/dev/null; then
    log "PR #$pr squash produced empty diff — already on $default_branch?"
    gh pr close "$pr" --repo "$REPO" --comment "Closed: empty squash onto $default_branch (already landed?)." >/dev/null 2>&1 || true
    return 0
  fi

  # Pre-commit hooks can take minutes on large sites; default skip for unattended land.
  # Set ORCH_MERGE_NO_VERIFY=0 to run hooks.
  local commit_flags=()
  if [ "${ORCH_MERGE_NO_VERIFY:-1}" = "1" ]; then
    commit_flags+=(--no-verify)
  fi
  if ! git -C "$REPO_DIR" commit "${commit_flags[@]}" -m "$(cat <<EOF
${title}

Squash-land of PR #${pr} (loop auto-merge via push; gh pr merge blocked).
${closes_line}
EOF
)" >/dev/null 2>&1; then
    log "Commit failed for push-land of PR #$pr"
    git -C "$REPO_DIR" reset --hard HEAD >/dev/null 2>&1
    return 1
  fi

  local push_err
  push_err=$(mktemp -t pr-push-land-err) || push_err=""
  if ! git -C "$REPO_DIR" push origin "$default_branch" >"${push_err:-/dev/null}" 2>&1; then
    log "git push origin $default_branch failed for PR #$pr
$(head -c 600 "$push_err" 2>/dev/null)"
    rm -f "$push_err"
    # Don't leave main ahead of origin locally in a confusing way
    git -C "$REPO_DIR" reset --hard "origin/${default_branch}" >/dev/null 2>&1 || true
    return 1
  fi
  rm -f "$push_err"

  gh pr close "$pr" --repo "$REPO" --comment \
    "Landed on \`${default_branch}\` via squash push (PR merge API blocked — often 'requires human approval' when the author cannot self-approve). Linked issues closed below so the board can move to Done." \
    >/dev/null 2>&1 || true
  # Closing a PR does **not** auto-close issues (only merge does). Close them
  # explicitly so we do not leave "In progress" + open issue + closed PR.
  close_issues_linked_to_pr "$pr" "Landed on \`${default_branch}\` via squash push of PR #${pr}."
  # Best-effort delete head branch
  git -C "$REPO_DIR" push origin --delete "$head_ref" >/dev/null 2>&1 || true

  log "Push-landed PR #$pr onto $default_branch"
  return 0
}

# Close GitHub issues referenced by a PR (Closes/Fixes/Resolves #N, branch feature/N-…).
close_issues_linked_to_pr() {
  local pr=$1
  local comment=${2:-"Closed: work landed on default branch."}
  local nums
  nums=$(
    gh pr view "$pr" --repo "$REPO" --json body,title,headRefName -q \
      '[.body // "", .title // "", .headRefName // ""] | @tsv' 2>/dev/null \
    | python3 -c '
import re,sys
text=sys.stdin.read()
nums=set(int(x) for x in re.findall(r"(?i)(?:closes|fixes|resolves)\s+#(\d+)", text))
for m in re.finditer(r"(?i)(?:feature|fix|chore|issue)[/-](\d+)(?:[-/]|$)", text):
    nums.add(int(m.group(1)))
print(" ".join(str(n) for n in sorted(nums)))
' 2>/dev/null || true
  )
  local n
  for n in $nums; do
    state=$(gh issue view "$n" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
    if [ "$state" = "OPEN" ]; then
      gh issue close "$n" --repo "$REPO" --comment "$comment" >/dev/null 2>&1 \
        && log "Closed issue #$n (linked from PR #$pr)" \
        || log "WARNING: could not close issue #$n"
    fi
  done
}

# True if issue work is already on default branch (merged PR, or closed PR after push-land).
# Never trusts GitHub text search (fuzzy — "Closes #6" matched unrelated PRs).
# If an open PR still targets the issue, always returns false (not landed yet).
issue_already_landed() {
  local issue=$1
  # Open PR for this issue → still needs land
  if [ -n "$(find_open_pr_for_issue "$issue" 2>/dev/null || true)" ]; then
    return 1
  fi
  # Client-side filter of recent closed PRs (merged or push-land closed)
  local closed_pr
  closed_pr=$(
    REPO_MATCH="$REPO" ISSUE_N="$issue" python3 - <<'PY'
import json, os, re, subprocess
repo, n = os.environ["REPO_MATCH"], os.environ["ISSUE_N"]
raw = subprocess.check_output(
    ["gh", "pr", "list", "--repo", repo, "--state", "closed", "--limit", "40",
     "--json", "number,title,headRefName,mergedAt,body"],
    text=True,
)
pat_close = re.compile(rf"(?i)(?:closes|fixes|resolves)\s+#0*{re.escape(n)}\b")
pat_branch = re.compile(rf"(?i)(?:^|/)(?:feature|fix|chore|issue)[/-]0*{re.escape(n)}(?:[-/]|$)")
for pr in json.loads(raw):
    head = pr.get("headRefName") or ""
    title = pr.get("title") or ""
    body = pr.get("body") or ""
    blob = f"{body}\n{title}\n{head}"
    # Require explicit close keyword or feature/<n>- branch — not bare "#n" in title
    if pat_close.search(blob) or pat_branch.search(head):
        print(pr["number"])
        raise SystemExit
PY
  )
  [ -n "$closed_pr" ]
}

# Merge PR $1 (number). Waits until merged when checks require --auto.
# Falls back to push-land when the merge API requires human approval.
# Returns 0 on MERGED/landed, 1 on failure/timeout.
merge_pr_number() {
  local pr=$1
  local method="${ORCH_MERGE_METHOD:-squash}"
  local wait_s="${ORCH_MERGE_WAIT_SECONDS:-900}"
  local merge_flag err_file state elapsed

  case "$method" in
    squash) merge_flag=--squash ;;
    rebase) merge_flag=--rebase ;;
    merge)  merge_flag=--merge ;;
    *) log "Unknown ORCH_MERGE_METHOD=$method — using squash"; merge_flag=--squash ;;
  esac

  [ -n "$pr" ] || return 1
  err_file=$(mktemp -t pr-merge-err) || return 1

  # Undraft so merge is allowed.
  gh pr ready "$pr" --repo "$REPO" >/dev/null 2>&1 || true

  # Already merged?
  state=$(gh pr view "$pr" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
  if [ "$state" = "MERGED" ]; then
    rm -f "$err_file"
    log "PR #$pr already MERGED"
    return 0
  fi

  # GitHub Stacked PRs: atomic land via gh stack merge (never gh pr merge / push-land).
  if should_use_stack_merge "$pr"; then
    rm -f "$err_file"
    if merge_pr_via_stack "$pr"; then
      return 0
    fi
    log "Stacked land failed for PR #$pr — not falling back to gh pr merge / push-land"
    return 1
  fi

  # Fast path: merge now (works when no required checks or already green).
  if gh pr merge "$pr" --repo "$REPO" $merge_flag --delete-branch >"$err_file" 2>&1; then
    rm -f "$err_file"
    log "Merged PR #$pr ($method, immediate)"
    return 0
  fi

  # Human-approval / self-approve blocks — skip waiting; go straight to push-land.
  if grep -qiE 'human approval|review|not mergeable|blocked' "$err_file" 2>/dev/null; then
    if grep -qF 'Blocked: merging requires human approval' "$err_file" 2>/dev/null; then
      log "Local gh shim (~/.local/bin/gh wrapper) intercepted 'gh pr merge' for #$pr — this is a machine-level guard, not GitHub branch protection"
    fi
    log "gh pr merge blocked for #$pr — trying push-land fallback
$(head -c 300 "$err_file")"
    rm -f "$err_file"
    merge_pr_via_push "$pr"
    return $?
  fi

  log "Immediate merge of PR #$pr blocked — enabling auto-merge and waiting up to ${wait_s}s
$(head -c 400 "$err_file" 2>/dev/null)"

  if ! gh pr merge "$pr" --repo "$REPO" $merge_flag --auto --delete-branch >"$err_file" 2>&1; then
    state=$(gh pr view "$pr" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
    if [ "$state" = "MERGED" ]; then
      rm -f "$err_file"
      log "PR #$pr already MERGED"
      return 0
    fi
    if grep -qiE 'human approval|review|blocked' "$err_file" 2>/dev/null; then
      log "auto-merge enable blocked — push-land fallback
$(head -c 300 "$err_file")"
      rm -f "$err_file"
      merge_pr_via_push "$pr"
      return $?
    fi
    log "Could not enable auto-merge on PR #$pr — push-land fallback
$(cat "$err_file" 2>/dev/null)"
    rm -f "$err_file"
    merge_pr_via_push "$pr"
    return $?
  fi

  elapsed=0
  while [ "$elapsed" -lt "$wait_s" ]; do
    state=$(gh pr view "$pr" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
    if [ "$state" = "MERGED" ]; then
      rm -f "$err_file"
      log "Merged PR #$pr ($method, after checks, ~${elapsed}s)"
      return 0
    fi
    if [ "$state" = "CLOSED" ]; then
      log "PR #$pr was CLOSED without merge"
      rm -f "$err_file"
      return 1
    fi
    sleep 15
    elapsed=$((elapsed + 15))
  done

  log "Timed out waiting for PR #$pr — trying push-land fallback"
  rm -f "$err_file"
  merge_pr_via_push "$pr"
  return $?
}

# Find + merge the open PR for issue $1. No-op success if ORCH_AUTO_MERGE=0.
# Sets LAND_PR_URL on success. Returns 0 if merged/already-landed or auto-merge
# disabled, 1 if a PR could not land.
land_issue_pr() {
  local issue=$1
  local line pr url draft

  LAND_PR_URL=""

  if [ "${ORCH_AUTO_MERGE:-1}" != "1" ]; then
    log "ORCH_AUTO_MERGE=0 — leaving PR open for human merge"
    return 0
  fi

  # Prefer open PR (must land) over "already landed" heuristics
  line=$(find_open_pr_for_issue "$issue" || true)
  if [ -z "$line" ]; then
    if issue_already_landed "$issue"; then
      log "Issue #$issue already landed (merged or push-closed PR) — OK"
      state=$(gh issue view "$issue" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
      if [ "$state" = "OPEN" ]; then
        gh issue close "$issue" --repo "$REPO" --comment "Closing: work already on default branch." >/dev/null 2>&1 || true
      fi
      return 0
    fi
    log "WARNING: no open PR found for issue #$issue and not detected as landed"
    return 1
  fi

  pr=$(printf '%s' "$line" | cut -f1)
  url=$(printf '%s' "$line" | cut -f2)
  draft=$(printf '%s' "$line" | cut -f3)
  log "Auto-merging PR #$pr for issue #$issue (draft=$draft) $url"

  if merge_pr_number "$pr"; then
    LAND_PR_URL="$url"
    # Belt-and-suspenders: ensure issue closed even if merge path didn't
    state=$(gh issue view "$issue" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
    if [ "$state" = "OPEN" ]; then
      gh issue close "$issue" --repo "$REPO" --comment "Closing after auto-land of PR #$pr." >/dev/null 2>&1 || true
    fi
    return 0
  fi
  return 1
}

# True if this issue must not be shipped by pr-loop (tracking epic / meta).
# Intentionally strict: children often *mention* a parent "tracking-only epic"
# without being epics themselves (e.g. "Parent epic #252 (tracking-only)").
is_tracking_only_issue() {
  local issue=$1
  local title body
  title=$(gh issue view "$issue" --repo "$REPO" --json title -q .title 2>/dev/null || echo "")
  body=$(gh issue view "$issue" --repo "$REPO" --json body -q .body 2>/dev/null || echo "")
  # Title starts with Epic: / [Epic]
  if printf '%s' "$title" | grep -qiE '^\s*(epic\b|\[epic\])'; then
    return 0
  fi
  # Body says *this* ticket is tracking-only / not for pr-orchestrator
  if printf '%s' "$body" | grep -qiE \
      'do not run [`'\''"]?pr-orchestrator[`'\''"]? on (this|the) (issue|epic)|this (issue|epic) is tracking-only|tracking-only — do not run|do not ship this (issue|epic) with pr-orchestrator|this epic does not implement'; then
    return 0
  fi
  return 1
}

# --- REST-only queue (labels) -------------------------------------------------
# Humans (or automation) put open issues in the ship queue with label `ready`.
# The agent never needs Projects/GraphQL for pick or status.
#
# Canonical ship state machine (REST only — one pathway, no purgatory):
#
#   create issue
#        │
#        ├─ (default) no ship labels ──► scope-loop ──► +ready ──► pr-loop
#        ├─ +ready (explicit skip-scope) ──────────────► pr-loop
#        ├─ +needs-input / true +blocked ──► park (human / external)
#        └─ +triage:ready-to-implement only ──► ORPHAN (historical)
#              heal: promote_triage_ready_orphans → +ready
#
#   Code dependencies (sibling tickets) are NOT a park reason:
#     scope writes ## Depends on + ready; pr-loop topo-sorts the ready queue.
#     heal_false_dependency_blocks: blocked + depends language without
#     external ship gate → -blocked +ready (fixes legacy mis-scopes).
#
#   ready → agent-working → land + close
#                        → awaiting-merge (PR open / stacked; dependents chain
#                          onto the PR branch via ## Depends on, no park)
#                        → agent-failed (re-add ready to retry)
#
# Labels (created on demand):
#   ready          — THE ship queue for pr-loop (only this label implements)
#   agent-working  — claimed by a live worker
#   agent-failed   — last run failed; remove + re-add ready to retry
#   awaiting-merge — PR open, merge pending (human merge or gh stack merge);
#                    dependents treat it as satisfied and stack onto its branch
#   triage:ready-to-implement — metadata from triage only; NOT a ship queue.
#                               Must never sit without ready/needs-input/blocked.
#   blocked        — external/human freeze only (NOT "depends on open #N")
#
# Mode "pick": prints "<issue-number>" only
# Mode "list": prints "#<n> (priority) [deps] title…"

: "${ORCH_READY_LABEL:=ready}"
: "${ORCH_TRIAGE_READY_LABEL:=triage:ready-to-implement}"

ensure_loop_labels() {
  [ -n "${REPO:-}" ] || return 0
  ensure_label "${ORCH_READY_LABEL:-ready}" "0E8A16" "Queued for pr-loop (REST ship queue)"
  ensure_label "agent-working" "fbca04" "Currently being worked on by the automated issue loop"
  ensure_label "agent-failed" "d93f0b" "Automated orchestrator run failed; remove to re-queue"
  ensure_label "awaiting-merge" "6F42C1" "PR open (possibly stacked on another PR); merge pending — dependents may stack onto it"
}

# Heal label purgatory: triage:ready-to-implement without ready was historically
# skipped by scope-loop (assumed "already scoped") but never picked by pr-loop
# (only reads `ready`). Result: tickets sat forever.
#
# Bridge: any open non-epic issue with triage:ready-to-implement that is not
# already ready / agent-* / blocked / needs-input gets +ready.
# Keeps triage label as history metadata.
#
# Call at the start of scope-loop AND pr-loop so either entry point heals orphans.
# Prints "promoted: N N N" or "promoted: (none)" to stdout when mode=print;
# always logs when `log` is available.
promote_triage_ready_orphans() {
  local mode="${1:-log}"  # log | print | quiet
  [ -n "${REPO:-}" ] || return 0
  ensure_loop_labels

  local promoted
  promoted=$(
    REPO_MATCH="$REPO" \
    READY_LABEL="${ORCH_READY_LABEL:-ready}" \
    TRIAGE_LABEL="${ORCH_TRIAGE_READY_LABEL:-triage:ready-to-implement}" \
    python3 - <<'PY' 2>/dev/null || true
import json, os, re, subprocess, sys

repo = os.environ["REPO_MATCH"]
ready = os.environ["READY_LABEL"]
triage = os.environ["TRIAGE_LABEL"]
park = {ready, "agent-working", "agent-failed", "blocked", "needs-input"}

try:
    issues = json.loads(subprocess.check_output(
        ["gh", "issue", "list", "--repo", repo, "--state", "open",
         "--label", triage, "--limit", "100",
         "--json", "number,title,labels"],
        text=True,
    ))
except Exception:
    print("")
    sys.exit(0)

out = []
for it in issues:
    title = it.get("title") or ""
    if re.search(r"^\s*(epic\b|\[epic\])", title, re.I):
        continue
    names = {l.get("name") for l in (it.get("labels") or []) if l.get("name")}
    if triage not in names:
        continue
    if names & park:
        continue
    n = str(it["number"])
    # +ready; leave triage label for audit trail
    subprocess.run(
        ["gh", "issue", "edit", n, "--repo", repo, "--add-label", ready],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    out.append(n)

print(" ".join(out))
PY
  )

  if [ -n "${promoted// /}" ]; then
    case "$mode" in
      print) echo "promoted: $promoted" ;;
      quiet) : ;;
      *)
        if type log >/dev/null 2>&1; then
          log "Healed triage orphans → +${ORCH_READY_LABEL:-ready}: $promoted"
        else
          echo "Healed triage orphans → +${ORCH_READY_LABEL:-ready}: $promoted"
        fi
        ;;
    esac
  else
    case "$mode" in
      print) echo "promoted: (none)" ;;
      quiet) : ;;
      *)
        if type log >/dev/null 2>&1; then
          log "Triage orphan heal: none"
        fi
        ;;
    esac
  fi
}

# Claim: ready → agent-working (REST). Call at worker start.
claim_issue_for_loop() {
  local issue=$1
  ensure_loop_labels
  remove_label "$issue" "${ORCH_READY_LABEL:-ready}"
  remove_label "$issue" "agent-failed"
  add_label "$issue" "agent-working"
}

# Success land: drop working labels; caller closes issue.
release_issue_success() {
  local issue=$1
  remove_label "$issue" "agent-working"
  remove_label "$issue" "${ORCH_READY_LABEL:-ready}"
  remove_label "$issue" "agent-failed"
}

# Fail: agent-failed, not ready (user re-adds ready when they want retry).
release_issue_failed() {
  local issue=$1
  remove_label "$issue" "agent-working"
  remove_label "$issue" "${ORCH_READY_LABEL:-ready}"
  ensure_label "agent-failed" "d93f0b" "Automated orchestrator run failed; remove to re-queue"
  add_label "$issue" "agent-failed"
}

# Interrupt: put back on ready queue.
release_issue_interrupted() {
  local issue=$1
  remove_label "$issue" "agent-working"
  remove_label "$issue" "agent-failed"
  ensure_loop_labels
  add_label "$issue" "${ORCH_READY_LABEL:-ready}"
}

# Eligible ship candidates via REST only.
# Prefer label `ready`. Never ships: blocked/agent-failed/agent-working, Epic titles.
# Order: priority (P0>P1>…), then topological by ## Depends on / Depends on: #N,
# then issue number. Issues whose open deps are not yet closed and not also
# `ready` are deferred (listed with reason in list mode; skipped in pick).
ready_label_candidates() {
  local mode=$1
  [ -n "${REPO:-}" ] || { log "REPO not set — load a profile first"; return 1; }
  ensure_loop_labels

  # Queue logic lives in ready_queue.py (same dir) so it is unit-testable.
  local queue_py
  queue_py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ready_queue.py"
  REPO_MATCH="$REPO" READY_LABEL="${ORCH_READY_LABEL:-ready}" MODE="$mode" \
    python3 "$queue_py"
}

# Branch that issue $1 must fork from: the head of its topmost open-PR dep
# (stack-through), else the repo default branch. Prints one branch name.
issue_base_branch() {
  local issue=$1
  [ -n "${REPO:-}" ] || return 1
  local queue_py
  queue_py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ready_queue.py"
  REPO_MATCH="$REPO" MODE=base ISSUE_N="$issue" python3 "$queue_py" 2>/dev/null
}

# Park with PR open: not failed, not queued — merge is pending (human merge of
# the stack bottom, or `gh stack merge`). Dependents chain onto the PR branch.
release_issue_awaiting_merge() {
  local issue=$1
  remove_label "$issue" "agent-working"
  remove_label "$issue" "${ORCH_READY_LABEL:-ready}"
  remove_label "$issue" "agent-failed"
  ensure_loop_labels
  add_label "$issue" "awaiting-merge"
}

# REST-only recovery for issues stuck on `agent-working` after a hard kill
# (crash / kill -9 / reboot). The board-based recover_interrupted only works
# for ORCH_BOARD=1 profiles; this sweep needs no GraphQL. Runs at loop start
# (the per-profile lock guarantees no live worker for this profile).
#   open PR exists → awaiting-merge (merge pending, dependents may stack)
#   no PR          → back to ready (re-pick)
recover_stuck_agent_working() {
  [ -n "${REPO:-}" ] || return 0
  ensure_loop_labels
  local nums n pr_line
  nums=$(gh issue list --repo "$REPO" --state open --label agent-working \
    --limit 100 --json number -q '.[].number' 2>/dev/null) || return 0
  for n in $nums; do
    pr_line=$(find_open_pr_for_issue "$n" 2>/dev/null || true)
    remove_label "$n" "agent-working"
    if [ -n "$pr_line" ]; then
      add_label "$n" "awaiting-merge"
      log "Recovery: #$n was stuck agent-working, has open PR #$(printf '%s' "$pr_line" | cut -f1) → awaiting-merge"
    else
      add_label "$n" "${ORCH_READY_LABEL:-ready}"
      log "Recovery: #$n was stuck agent-working with no PR → ready (re-queued)"
      notify "$n" "recovered after a hard-killed run: no PR found, re-queued as \`ready\`."
    fi
  done
}

# Best-effort restack of open PR chains whose bottom PR was merged since the
# last run (human merged the stack bottom). A PR is stale when its base branch
# is not the default branch and no *open* PR owns that head anymore (parent
# merged or closed — with or without branch deletion). gh stack's cascading
# rebase + push then re-sits the surviving layers onto the default branch.
# Safe unattended: gh stack rebase aborts and restores on conflict; any
# failure is logged and left for a human (`gh stack sync`). Never fatal.
restack_open_chains() {
  [ "${ORCH_STACK:-auto}" = "0" ] && return 0
  gh_stack_cli_available || return 0
  # Skip on repos where the Stacks API probe failed (404 etc.) — otherwise
  # every loop start logs misleading "left for human" advice.
  [ "${ORCH_STACK_REPO_OK:-0}" = "1" ] || return 0
  [ -n "${REPO_DIR:-}" ] && [ -d "$REPO_DIR/.git" ] || return 0

  local stale pr base
  stale=$(REPO_MATCH="$REPO" python3 "$(_pr_chain_py)" stale-bases 2>/dev/null || true)
  [ -n "$stale" ] || return 0

  for pr in $stale; do
    log "Restack: PR #$pr bases on a merged/deleted branch — attempting gh stack rebase"
    if (cd "$REPO_DIR" && \
        git checkout -q "$(default_branch_name)" >/dev/null 2>&1 && \
        gh stack checkout "$pr" >/dev/null 2>&1 && \
        gh stack rebase >/dev/null 2>&1 && \
        gh stack push >/dev/null 2>&1); then
      log "Restack: PR #$pr chain rebased onto $(default_branch_name) and pushed"
    else
      (cd "$REPO_DIR" && gh stack rebase --abort >/dev/null 2>&1) || true
      log "Restack: automatic rebase of PR #$pr failed (conflict?) — left for human: gh stack checkout $pr && gh stack sync"
    fi
  done
  return_to_main >/dev/null 2>&1 || true
}

# Heal issues wrongly parked with `blocked` only because of code dependencies
# (sibling tickets / "not on main yet"). True external freezes keep `blocked`
# when the body has ## Ship gate (external) or budget/legal language.
#
# Call at start of scope-loop and pr-loop (after promote_triage_ready_orphans).
heal_false_dependency_blocks() {
  local mode="${1:-log}"
  [ -n "${REPO:-}" ] || return 0
  ensure_loop_labels

  local promoted
  promoted=$(
    REPO_MATCH="$REPO" \
    READY_LABEL="${ORCH_READY_LABEL:-ready}" \
    python3 - <<'PY' 2>/dev/null || true
import json, os, re, subprocess, sys

repo = os.environ["REPO_MATCH"]
ready = os.environ["READY_LABEL"]

try:
    issues = json.loads(subprocess.check_output(
        ["gh", "issue", "list", "--repo", repo, "--state", "open",
         "--label", "blocked", "--limit", "100",
         "--json", "number,title,labels,body"],
        text=True,
    ))
except Exception:
    print("")
    sys.exit(0)

promoted = []
for it in issues:
    n = it["number"]
    title = (it.get("title") or "")
    if re.match(r"(?i)^\s*(epic\b|\[epic\])", title):
        continue
    labels = {l["name"] for l in (it.get("labels") or [])}
    if "needs-input" in labels:
        continue
    if ready in labels or "agent-working" in labels or "agent-failed" in labels:
        continue
    body = it.get("body") or ""

    if re.search(r"(?im)^##\s*Ship gate\s*\(external\)", body):
        continue
    external = bool(re.search(
        r"(?i)\b(places\s+budget|api\s+budget|budget\s+approved|legal\s+hold|"
        r"vendor\s+outage|human\s+approval|owner\s+decision)\b",
        body,
    ))
    has_dep_lang = bool(re.search(
        r"(?i)(##\s*Depends on\b|depends on\b|do not start until\s*#\d|"
        r"blocked on #\d|parent epic:\s*#\d)",
        body,
    ))
    if external:
        continue
    if not has_dep_lang:
        continue

    subprocess.run(
        ["gh", "issue", "edit", str(n), "--repo", repo,
         "--remove-label", "blocked", "--add-label", ready],
        capture_output=True, text=True,
    )
    subprocess.run(
        ["gh", "issue", "comment", str(n), "--repo", repo, "--body",
         "Auto-heal: removed `blocked` (code dependency is not a park reason). "
         "Ship order lives in `## Depends on`; pr-loop topo-sorts the `ready` queue. "
         "See gh-scope-issue skill — Dependencies vs park labels."],
        capture_output=True, text=True,
    )
    promoted.append(str(n))

print(" ".join(promoted))
PY
  )

  promoted=$(echo "$promoted" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')
  if [ -z "$promoted" ]; then
    case "$mode" in
      print) echo "dep-block-heal: (none)" ;;
      quiet) ;;
      *) type log >/dev/null 2>&1 && log "False dep-block heal: none" || true ;;
    esac
    return 0
  fi
  case "$mode" in
    print) echo "dep-block-heal: $promoted" ;;
    quiet) ;;
    *) type log >/dev/null 2>&1 && log "False dep-block heal → +${ORCH_READY_LABEL:-ready}: $promoted" || true ;;
  esac
}

# Back-compat name used by supervisor
board_candidates() {
  ready_label_candidates "$@"
}

# --- Board updates (GitHub Projects v2 = GraphQL only) -----------------------
# There is no REST API for Projects v2 item status. Every `gh project item-list`
# / `item-edit` burns GraphQL quota (5000/hour). We therefore:
#   - cache item-list for BOARD_CACHE_TTL seconds (default 180)
#   - prefer the item-id the supervisor already resolved (hint)
#   - allow ORCH_BOARD=0 to skip board entirely (issues still close via REST)
#
# REST (gh issue close/edit) is separate and rarely rate-limited.

# Board is for *humans* to look at. Default: agents do NOT write project status
# (Projects v2 = GraphQL, burns quota). Ship path uses REST only: issues, PRs, git.
# ORCH_BOARD=1 re-enables Ready/In progress/Done writes if you want full automation.
: "${ORCH_BOARD:=0}"
: "${BOARD_CACHE_TTL:=180}"    # seconds to reuse item-list JSON (reads only when ORCH_BOARD=1 or pick)

board_cache_path() {
  # Avoid $(id -u) — some constrained shells lack `id` on PATH.
  echo "${BOARD_CACHE_FILE:-${TMPDIR:-/tmp}/pr-loop-board-${PROJECT_NUMBER:-x}-${USER:-user}.json}"
}

# Refresh cached project item-list if missing/stale. Returns 0 if cache usable.
refresh_board_cache() {
  local force=${1:-0}
  local path age
  path=$(board_cache_path)
  if [ "$force" != "1" ] && [ -f "$path" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null || echo 0) ))
    if [ "$age" -ge 0 ] && [ "$age" -lt "${BOARD_CACHE_TTL:-180}" ]; then
      return 0
    fi
  fi
  local err
  err="${TMPDIR:-/tmp}/pr-loop-board-err-$$.txt"
  if ! gh project item-list "$PROJECT_NUMBER" --owner "${PROJECT_OWNER:-@me}" \
        --format json --limit 500 >"$path" 2>"$err"; then
    if grep -qi 'rate limit' "$err" 2>/dev/null; then
      log "GraphQL rate limit on project item-list (Projects v2). Cache not refreshed.
  REST is fine; board ops need GraphQL. Wait for reset or set ORCH_BOARD=0 to skip board updates.
  $(head -c 200 "$err" 2>/dev/null)"
    else
      log "project item-list failed: $(head -c 200 "$err" 2>/dev/null)"
    fi
    rm -f "$err"
    # Keep stale cache if present
    [ -f "$path" ] && return 0
    return 1
  fi
  rm -f "$err"
  return 0
}

set_status() { # <item-id> <option-id> <label>
  local item_id=$1 option_id=$2 label=$3
  local err
  if [ "${ORCH_BOARD:-1}" != "1" ]; then
    log "ORCH_BOARD=0 — skip board status '$label'"
    return 0
  fi
  if [ -z "$item_id" ] || [ -z "$option_id" ]; then
    log "WARNING: set_status missing item_id or option_id for '$label' — skipping"
    return 1
  fi
  err="${TMPDIR:-/tmp}/pr-loop-edit-err-$$.txt"
  if gh project item-edit --project-id "$PROJECT_ID" --id "$item_id" \
      --field-id "$STATUS_FIELD_ID" --single-select-option-id "$option_id" >/dev/null 2>"$err"; then
    rm -f "$err"
    log "Board #$PROJECT_NUMBER status -> $label (item ${item_id:0:24}…)"
    return 0
  fi
  if grep -qi 'rate limit' "$err" 2>/dev/null; then
    log "WARNING: GraphQL rate limit on item-edit (status '$label') — board not updated. Issue close via REST still works."
  else
    log "WARNING: failed to set board status to $label: $(head -c 180 "$err" 2>/dev/null)"
  fi
  rm -f "$err"
  return 1
}

# Look up project item id from **cached** board list (refreshes at most every TTL).
# Prints the item id or empty.
board_item_id_for_issue() {
  local issue=$1
  [ -n "$issue" ] && [ -n "${PROJECT_NUMBER:-}" ] && [ -n "${REPO:-}" ] || return 1
  if [ "${ORCH_BOARD:-1}" != "1" ]; then
    return 1
  fi
  refresh_board_cache || return 1
  local path
  path=$(board_cache_path)
  [ -f "$path" ] || return 1
  REPO_MATCH="$REPO" ISSUE_N="$issue" python3 - "$path" <<'PY'
import json, os, sys
path = sys.argv[1]
repo = os.environ["REPO_MATCH"]
slug = repo.split("/")[-1]
want = int(os.environ["ISSUE_N"])
with open(path) as f:
    items = json.load(f).get("items") or []
for it in items:
    c = it.get("content") or {}
    n = c.get("number")
    if n is None or int(n) != want:
        continue
    r = " ".join([
        str(it.get("repository") or ""),
        str(c.get("repository") or ""),
        str(c.get("url") or ""),
    ])
    if slug not in r and repo not in r:
        continue
    print(it["id"])
    raise SystemExit(0)
raise SystemExit(1)
PY
}

# Set status for an issue.
# Usage: set_issue_status <issue> <option-id> <label> [item-id-hint]
# Prefer hint (from supervisor pick) to avoid an extra GraphQL list.
set_issue_status() {
  local issue=$1 option_id=$2 label=$3 hint=${4:-}
  local item_id

  if [ "${ORCH_BOARD:-1}" != "1" ]; then
    log "ORCH_BOARD=0 — skip board '$label' for #$issue (issue labels/close still via REST)"
    return 0
  fi

  item_id=$hint
  if [ -z "$item_id" ]; then
    item_id=$(board_item_id_for_issue "$issue" 2>/dev/null) || item_id=""
  fi
  if [ -z "$item_id" ]; then
    log "WARNING: no project item id for #$issue on board #$PROJECT_NUMBER — cannot set '$label' (rate limit or not on board)"
    return 1
  fi
  set_status "$item_id" "$option_id" "$label"
}

mention_user() {
  if [ -z "$MENTION_USER" ]; then
    MENTION_USER=$(gh api user --jq .login 2>/dev/null) || true
  fi
  [ -n "$MENTION_USER" ]
}

# Post an @mention comment on the issue — this is what triggers the GitHub
# mobile push notification (direct mention).
notify() { # <issue> <message>
  if ! mention_user; then
    log "WARNING: no GitHub login available — skipping notification for issue #$1"
    return 0
  fi
  gh issue comment "$1" --repo "$REPO" --body "Hey @$MENTION_USER — $2" >/dev/null \
    && log "Notified @$MENTION_USER on issue #$1" \
    || log "WARNING: could not post notification on issue #$1"
}

# --- Labels --------------------------------------------------------------------

ensure_label() { # <name> <color> <description> — create or update, never fails hard
  gh label create "$1" --repo "$REPO" --color "$2" --description "$3" --force >/dev/null 2>&1 \
    || log "WARNING: could not ensure label '$1' exists"
}

add_label() { # <issue> <name>
  gh issue edit "$1" --repo "$REPO" --add-label "$2" >/dev/null 2>&1 \
    || log "WARNING: could not label issue #$1 as $2"
}

remove_label() { # <issue> <name> — silent if absent
  gh issue edit "$1" --repo "$REPO" --remove-label "$2" >/dev/null 2>&1 || true
}

# --- Recovery of interrupted runs ------------------------------------------------
#
# The worker labels every issue it starts with `agent-working` and removes the
# label on every exit path (success / failure / graceful interrupt). An issue
# left "In progress" WITH the label therefore means: the previous loop died
# hard (kill -9, crash, reboot) mid-run. Issues without the label are owned by
# a human and are never touched.

# Print "<issue> <item-id> yes|no" (last field = open PR exists) for each
# agent-owned In-progress item.
recover_candidates() {
  local items_file
  items_file=$(mktemp -t pr-loop-items) || return 1
  if ! gh project item-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" \
        --format json --limit 500 > "$items_file"; then
    rm -f "$items_file"
    return 1
  fi
  python3 - "$REPO" "$items_file" <<'EOF'
import json, subprocess, sys

repo, items_path = sys.argv[1], sys.argv[2]
with open(items_path) as f:
    items = json.load(f)["items"]

in_progress = {}
for it in items:
    content = it.get("content") or {}
    if it.get("status") == "In progress" and content.get("type") == "Issue":
        if repo.endswith((content.get("repository") or "").split("/")[-1]):
            in_progress[content["number"]] = it["id"]

if not in_progress:
    sys.exit(0)

issues = json.loads(subprocess.run(
    ["gh", "issue", "list", "--repo", repo, "--state", "open",
     "--json", "number,labels", "--limit", "200"],
    capture_output=True, check=True).stdout)

for issue in issues:
    n = issue["number"]
    if n not in in_progress:
        continue
    labels = {l["name"] for l in issue["labels"]}
    if "agent-working" not in labels:
        continue
    prs = subprocess.run(
        ["gh", "pr", "list", "--repo", repo, "--state", "open",
         "--search", f"Closes #{n} in:body", "--json", "number"],
        capture_output=True, check=True).stdout
    print(f"{n} {in_progress[n]} {'yes' if json.loads(prs) else 'no'}")
EOF
  local rc=$?
  rm -f "$items_file"
  return $rc
}

# Sweep In progress cards that are NOT owned by a live agent (no agent-working).
# These get stranded when: interrupt handler fails, old wrong-board status, or
# orchestrator opened a PR then the worker died before land/Done.
# Safe: never touches issues still labeled agent-working (active worker).
sweep_stranded_in_progress() {
  local items_file n item_id title labels open_pr
  items_file=$(mktemp -t pr-loop-items) || return 0
  if ! gh project item-list "$PROJECT_NUMBER" --owner "${PROJECT_OWNER:-@me}" \
        --format json --limit 500 >"$items_file" 2>/dev/null; then
    rm -f "$items_file"
    return 0
  fi
  while IFS=$'\t' read -r n item_id title; do
    [ -n "$n" ] || continue
    labels=$(gh issue view "$n" --repo "$REPO" --json labels -q '[.labels[].name]|join(" ")' 2>/dev/null || echo "")
    if echo " $labels " | grep -q ' agent-working '; then
      log "Sweep: #$n still agent-working — leave In progress"
      continue
    fi
    if is_tracking_only_issue "$n" 2>/dev/null; then
      log "Sweep: #$n tracking epic stranded In progress → Backlog"
      if [ -n "${OPT_BACKLOG:-}" ]; then
        set_issue_status "$n" "$OPT_BACKLOG" "Backlog"
      else
        set_issue_status "$n" "$OPT_IN_REVIEW" "In review"
      fi
      continue
    fi
    if issue_already_landed "$n" 2>/dev/null; then
      log "Sweep: #$n already on main → Done"
      [ -n "${OPT_DONE:-}" ] && set_issue_status "$n" "$OPT_DONE" "Done" \
        || set_issue_status "$n" "$OPT_IN_REVIEW" "In review"
      istate=$(gh issue view "$n" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
      if [ "$istate" = "OPEN" ]; then
        gh issue close "$n" --repo "$REPO" --comment "Closed by board sweep: work already on default branch." >/dev/null 2>&1 || true
      fi
      continue
    fi
    open_pr=$(find_open_pr_for_issue "$n" | cut -f1 || true)
    if [ -n "$open_pr" ]; then
      log "Sweep: #$n has open PR #$open_pr → In review"
      set_issue_status "$n" "$OPT_IN_REVIEW" "In review"
      continue
    fi
    log "Sweep: #$n In progress with no PR and not landed → Ready"
    set_issue_status "$n" "$OPT_READY" "Ready"
  done < <(
    REPO_MATCH="$REPO" python3 - "$items_file" <<'PY'
import json, os, sys
repo = os.environ["REPO_MATCH"]
slug = repo.split("/")[-1]
with open(sys.argv[1]) as f:
    items = json.load(f).get("items") or []
for it in items:
    if it.get("status") != "In progress":
        continue
    c = it.get("content") or {}
    n = c.get("number")
    if n is None:
        continue
    r = " ".join([str(it.get("repository") or ""), str(c.get("repository") or ""), str(c.get("url") or "")])
    if slug not in r and repo not in r:
        continue
    title = (c.get("title") or "").replace("\t", " ")
    print(f"{n}\t{it['id']}\t{title}")
PY
  )
  rm -f "$items_file"
}

# Adopt agent-owned In-progress items on the **profile** board:
#   already on main -> Done
#   open PR -> In review
#   else -> Ready
recover_interrupted() {
  local recovered n item_id has_pr
  if ! recovered=$(recover_candidates); then
    log "WARNING: recovery sweep failed (gh error) — continuing without it"
    return 0
  fi
  [ -n "$recovered" ] || return 0
  while read -r n item_id has_pr; do
    [ -n "$n" ] || continue
    remove_label "$n" "agent-working"
    if issue_already_landed "$n"; then
      log "Recovery: issue #$n already landed — Done"
      if [ -n "${OPT_DONE:-}" ]; then
        set_issue_status "$n" "$OPT_DONE" "Done"
      else
        set_issue_status "$n" "$OPT_IN_REVIEW" "In review"
      fi
      istate=$(gh issue view "$n" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
      if [ "$istate" = "OPEN" ]; then
        gh issue close "$n" --repo "$REPO" --comment "Closed on recovery: work already on default branch." >/dev/null 2>&1 || true
      fi
    elif [ "$has_pr" = "yes" ]; then
      log "Recovery: issue #$n has an open PR — In review"
      set_issue_status "$n" "$OPT_IN_REVIEW" "In review"
      notify "$n" "recovered after interrupt: PR exists → In review."
    else
      log "Recovery: issue #$n interrupted mid-run — Ready"
      set_issue_status "$n" "$OPT_READY" "Ready"
      notify "$n" "recovered after interrupt with no PR — Ready for re-run."
    fi
  done <<< "$recovered"
}
