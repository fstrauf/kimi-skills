#!/usr/bin/env bash
#
# setup-profile.sh — create or refresh a **shared** loop profile for one GitHub repo.
#
# Profiles are used by both:
#   pr-loop   / loop-ready-issues.sh  → Ready column → implement/ship
#   scope-loop / scope-all.sh         → Scoping column → gh-scope-issue
#
# Discovers: REPO (from git remote / gh), project board IDs, Status field +
# Scoping / Ready / In progress / In review option IDs, and optional Priority/Size.
# Writes profiles/<name>.env
#
# Usage:
#   ./setup-profile.sh <profile-name> [--repo-dir PATH] [--project N] [--owner @me|USER] [--force]
#
# Examples:
#   ./setup-profile.sh txApp --repo-dir ~/01_code/tx/txApp --project 6
#   ./setup-profile.sh pageseeds-app --repo-dir ~/01_code/pageseeds-app --project 5
#   ./setup-profile.sh my-app --repo-dir .     # auto-pick board that already has this repo's issues
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROFILES_DIR="$SCRIPT_DIR/profiles"

usage() {
  cat <<'EOF'
Usage: setup-profile.sh <profile-name> [options]

  --repo-dir PATH   Git checkout (default: $PWD if a git root, else fail)
  --project N       GitHub project number under --owner (default: auto-detect)
  --owner OWNER     Project owner (default: @me)
  --force           Overwrite existing profiles/<name>.env
  -h, --help        This help

Profile name is the file stem: profiles/<name>.env
EOF
}

log() { echo "[setup-profile] $*"; }
die() { echo "[setup-profile] ERROR: $*" >&2; exit 1; }

PROFILE_NAME=""
REPO_DIR_ARG=""
PROJECT_NUMBER_ARG=""
PROJECT_OWNER="@me"
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-dir)
      REPO_DIR_ARG="${2:?}"
      shift 2
      ;;
    --repo-dir=*)
      REPO_DIR_ARG="${1#--repo-dir=}"
      shift
      ;;
    --project)
      PROJECT_NUMBER_ARG="${2:?}"
      shift 2
      ;;
    --project=*)
      PROJECT_NUMBER_ARG="${1#--project=}"
      shift
      ;;
    --owner)
      PROJECT_OWNER="${2:?}"
      shift 2
      ;;
    --owner=*)
      PROJECT_OWNER="${1#--owner=}"
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [ -z "$PROFILE_NAME" ]; then
        PROFILE_NAME="$1"
      else
        die "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[ -n "$PROFILE_NAME" ] || { usage; exit 1; }
case "$PROFILE_NAME" in
  */*|*..*|*\\*) die "invalid profile name: $PROFILE_NAME" ;;
esac

PROFILE_PATH="$PROFILES_DIR/${PROFILE_NAME}.env"
if [ -f "$PROFILE_PATH" ] && [ "$FORCE" != 1 ]; then
  die "profile already exists: $PROFILE_PATH (use --force to overwrite)"
fi

# --- Resolve REPO_DIR --------------------------------------------------------

if [ -n "$REPO_DIR_ARG" ]; then
  REPO_DIR=$(cd "$REPO_DIR_ARG" && pwd) || die "repo-dir not found: $REPO_DIR_ARG"
else
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    REPO_DIR=$(git rev-parse --show-toplevel)
  else
    die "not inside a git repo — pass --repo-dir PATH"
  fi
fi

[ -d "$REPO_DIR/.git" ] || [ -f "$REPO_DIR/.git" ] || die "not a git checkout: $REPO_DIR"

command -v gh >/dev/null || die "gh CLI not on PATH"
gh auth status >/dev/null 2>&1 || die "gh not authenticated"

# --- Resolve REPO (owner/name) -----------------------------------------------

REPO=$(
  git -C "$REPO_DIR" remote get-url origin 2>/dev/null \
    | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##'
)
# Prefer gh (handles SSH/HTTPS and renames)
if gh_repo=$(gh -R "$REPO_DIR" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null); then
  REPO="$gh_repo"
elif [ -z "$REPO" ]; then
  die "could not resolve GitHub repo from $REPO_DIR"
fi

REPO_SLUG="${REPO##*/}"
log "REPO=$REPO"
log "REPO_DIR=$REPO_DIR"

# --- Resolve project number --------------------------------------------------

pick_project_number() {
  local n title count
  # Prefer projects that already list issues from this repo.
  while IFS=$'\t' read -r n title; do
    [ -n "$n" ] || continue
    count=$(
      gh project item-list "$n" --owner "$PROJECT_OWNER" --format json --limit 200 2>/dev/null \
        | REPO_MATCH="$REPO" python3 -c '
import json,sys,os
repo=os.environ["REPO_MATCH"]
slug=repo.split("/")[-1]
try:
    items=json.load(sys.stdin).get("items") or []
except Exception:
    print(0); raise SystemExit
n=0
for it in items:
    c=it.get("content") or {}
    if c.get("type")!="Issue": continue
    r=(it.get("repository") or "")+" "+(c.get("repository") or "")
    if slug in r or repo in r: n+=1
print(n)
' 2>/dev/null || echo 0
    )
    if [ "${count:-0}" -gt 0 ]; then
      log "auto-detected project #$n ($title) — $count issue(s) for $REPO"
      echo "$n"
      return 0
    fi
  done < <(gh project list --owner "$PROJECT_OWNER" --format json --limit 50 \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
for p in d.get("projects") or []:
    print(f"{p[\"number\"]}\t{p.get(\"title\",\"\")}")' 2>/dev/null)

  return 1
}

if [ -n "$PROJECT_NUMBER_ARG" ]; then
  PROJECT_NUMBER="$PROJECT_NUMBER_ARG"
else
  if ! PROJECT_NUMBER=$(pick_project_number); then
    die "could not auto-detect a project board with issues for $REPO.
List boards: gh project list --owner $PROJECT_OWNER
Re-run with: ./setup-profile.sh $PROFILE_NAME --repo-dir $REPO_DIR --project <N>"
  fi
fi

log "PROJECT_NUMBER=$PROJECT_NUMBER OWNER=$PROJECT_OWNER"

# --- Project + Status field IDs ----------------------------------------------

PROJECT_ID=$(gh project view "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json --jq .id) \
  || die "project view failed for #$PROJECT_NUMBER"

FIELDS_JSON=$(gh project field-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json) \
  || die "field-list failed for project #$PROJECT_NUMBER"

eval "$(
  python3 -c "
import json,sys,shlex
data=json.loads(sys.argv[1])
status=None
priority=None
size=None
for f in data.get('fields') or []:
    name=f.get('name')
    if name=='Status' and f.get('options') is not None:
        status=f
    elif name=='Priority' and f.get('options') is not None:
        priority=f
    elif name=='Size' and f.get('options') is not None:
        size=f
if not status:
    print('echo \"[setup-profile] ERROR: no Status single-select field on board\" >&2; exit 1')
    raise SystemExit(0)
print(f'STATUS_FIELD_ID={shlex.quote(status[\"id\"])}')
# Case-insensitive option match
want={
    'scoping':'OPT_SCOPING',
    'ready':'OPT_READY',
    'in progress':'OPT_IN_PROGRESS',
    'in review':'OPT_IN_REVIEW',
    'done':'OPT_DONE',
    'backlog':'OPT_BACKLOG',
}
found={}
for o in status.get('options') or []:
    key=o['name'].strip().lower()
    if key in want and want[key] not in found:
        found[want[key]]=o['id']
# fallback aliases used on some boards
aliases={
    'todo':'OPT_READY',
    'in-progress':'OPT_IN_PROGRESS',
    'in_progress':'OPT_IN_PROGRESS',
    'review':'OPT_IN_REVIEW',
}
for o in status.get('options') or []:
    key=o['name'].strip().lower().replace('_',' ')
    key2=o['name'].strip().lower()
    for a,var in list(want.items())+list(aliases.items()):
        if (key==a or key2==a) and var not in found:
            found[var]=o['id']
# Ready path requires ship columns; Scoping is optional (scope-loop)
missing=[v for v in ('OPT_READY','OPT_IN_PROGRESS','OPT_IN_REVIEW') if v not in found]
if missing:
    opts=', '.join(o['name'] for o in (status.get('options') or []))
    print(f'echo \"[setup-profile] ERROR: missing Status options {missing}; have: {opts}\" >&2; exit 1')
    raise SystemExit(0)
for k,v in found.items():
    print(f'{k}={shlex.quote(v)}')
if 'OPT_SCOPING' not in found:
    print('OPT_SCOPING=')
# Optional Priority / Size (used by gh-scope-issue when moving cards)
if priority:
    print(f'PRIORITY_FIELD_ID={shlex.quote(priority[\"id\"])}')
    for o in priority.get('options') or []:
        n=o['name'].strip().upper()
        if n in ('P0','P1','P2','P3'):
            print(f'OPT_{n}={shlex.quote(o[\"id\"])}')
if size:
    print(f'SIZE_FIELD_ID={shlex.quote(size[\"id\"])}')
    for o in size.get('options') or []:
        n=o['name'].strip().upper()
        if n in ('XS','S','M','L','XL'):
            print(f'OPT_{n}={shlex.quote(o[\"id\"])}')
" "$FIELDS_JSON"
)" || die "could not parse Status field options"

# --- Write profile -----------------------------------------------------------

mkdir -p "$PROFILES_DIR"
{
  cat <<EOF
# Shared loop profile: $PROFILE_NAME
# Used by: pr-loop (Ready) + scope-loop (Scoping)
# Generated by setup-profile.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Regenerate: ./setup-profile.sh $PROFILE_NAME --repo-dir $REPO_DIR --project $PROJECT_NUMBER --force

REPO=$REPO
REPO_DIR=$REPO_DIR
PROJECT_NUMBER=$PROJECT_NUMBER
PROJECT_OWNER=$PROJECT_OWNER
PROJECT_ID=$PROJECT_ID
STATUS_FIELD_ID=$STATUS_FIELD_ID
EOF
  # Optional scoping column (empty if board has no Scoping status)
  if [ -n "${OPT_SCOPING:-}" ]; then
    echo "OPT_SCOPING=$OPT_SCOPING"
  fi
  cat <<EOF
OPT_READY=$OPT_READY
OPT_IN_PROGRESS=$OPT_IN_PROGRESS
OPT_IN_REVIEW=$OPT_IN_REVIEW
EOF
  if [ -n "${OPT_DONE:-}" ]; then
    echo "OPT_DONE=$OPT_DONE"
  fi
  if [ -n "${OPT_BACKLOG:-}" ]; then
    echo "OPT_BACKLOG=$OPT_BACKLOG"
  fi
  # Optional priority/size — only emit if setup captured them
  for k in PRIORITY_FIELD_ID OPT_P0 OPT_P1 OPT_P2 OPT_P3 SIZE_FIELD_ID OPT_XS OPT_S OPT_M OPT_L OPT_XL; do
    if [ -n "${!k:-}" ]; then
      echo "$k=${!k}"
    fi
  done
} > "$PROFILE_PATH"

log "wrote $PROFILE_PATH"
if [ -z "${OPT_SCOPING:-}" ]; then
  log "note: board has no Scoping status — scope-loop cannot run until you add a 'scoping' column"
fi
echo
echo "Use with:"
echo "  pr-loop --profile $PROFILE_NAME --agent grok          # Ready → ship"
echo "  scope-loop --profile $PROFILE_NAME --agent grok       # Scoping → Ready"
echo "  ./loop-ready-issues.sh --profile $PROFILE_NAME --agent kimi 1"
