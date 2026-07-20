#!/usr/bin/env bash
# prune-sessions.sh — prune AI-tool session/history data older than N days.
#
# Default is DRY-RUN: reports what would be deleted, deletes nothing.
# Pass --apply to actually delete.
#
#   DAYS=14 ./prune-sessions.sh           # report what a 14-day prune would remove
#   DAYS=14 ./prune-sessions.sh --apply   # actually remove it
#
# Safety: only FILES older than N days are removed (then emptied dirs are
# cleaned up). Anything touched in the last N days — including sessions that
# are open right now — never matches. Config, credentials, user-history
# indexes, and tool binaries are outside these roots and are never touched.

set -u

DAYS="${DAYS:-14}"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

HOME_DIR="$HOME"

# name|session-root pairs. Add new tools here as needed.
ROOTS="
kimi (legacy CLI)|$HOME_DIR/.kimi/sessions
kimi-code|$HOME_DIR/.kimi-code/sessions
opencode (logs)|$HOME_DIR/.local/share/opencode/log
opencode (snapshots)|$HOME_DIR/.local/share/opencode/snapshot
opencode (tool-output)|$HOME_DIR/.local/share/opencode/tool-output
claude-code|$HOME_DIR/.claude/projects
codex|$HOME_DIR/.codex/sessions
"

total_kb=0

printf 'Mode: %s   Threshold: %s days\n\n' "$([ "$APPLY" -eq 1 ] && echo APPLY || echo DRY-RUN)" "$DAYS"

echo "$ROOTS" | while IFS='|' read -r name root; do
  [ -z "$name" ] && continue
  if [ ! -d "$root" ]; then
    printf '%-24s not present\n' "$name"
    continue
  fi
  matches=$(find "$root" -type f -mtime +"$DAYS" 2>/dev/null)
  if [ -z "$matches" ]; then
    size=$(du -sh "$root" 2>/dev/null | cut -f1)
    printf '%-24s %-8s total, nothing older than %sd\n' "$name" "${size:-?}" "$DAYS"
    continue
  fi
  count=$(printf '%s\n' "$matches" | wc -l | tr -d ' ')
  kb=$(printf '%s\n' "$matches" | xargs stat -f '%z' 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s/1024}')
  printf '%-24s %s files, %.1f MB older than %sd\n' "$name" "$count" "$(echo "$kb" | awk '{print $1/1024}')" "$DAYS"
  if [ "$APPLY" -eq 1 ]; then
    printf '%s\n' "$matches" | xargs rm -f 2>/dev/null
    find "$root" -type d -empty -delete 2>/dev/null
    printf '%-24s -> pruned\n' ""
  fi
done

if [ "$APPLY" -eq 0 ]; then
  echo
  echo "Dry run only. Re-run with --apply to delete the files listed above."
fi
