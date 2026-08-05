#!/usr/bin/env bash
# prune-sessions.sh — prune AI-tool session/history data older than N days.
#
# Default is DRY-RUN: reports what would be deleted, deletes nothing.
# Pass --apply to actually delete.
#
#   DAYS=14 ./prune-sessions.sh           # report what a 14-day prune would remove
#   DAYS=3  ./prune-sessions.sh           # tighter (good default for Grok)
#   DAYS=3  ./prune-sessions.sh --apply   # actually remove it
#
# Safety:
# - File-level tools (kimi, opencode, claude, codex): only FILES with mtime older
#   than N days are removed; then empty dirs are cleaned.
# - Grok: whole *session directories* under ~/.grok/sessions/<cwd>/<session-id>/
#   are removed when the newest file inside is older than N days. Active session
#   IDs from ~/.grok/active_sessions.json are always skipped. Config, auth,
#   skills, MCP credentials, and the newest download binary are never touched.
# - Optional Grok extras (same DAYS / --apply):
#     GROK_WORKTREE_GC=1   run `grok worktree gc -f --max-age ${GROK_WT_MAX_AGE:-1h}`
#     GROK_DOWNLOADS=1     keep newest ~/.grok/downloads/binary, remove older

set -u

DAYS="${DAYS:-14}"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

HOME_DIR="$HOME"
GROK_WORKTREE_GC="${GROK_WORKTREE_GC:-0}"
GROK_DOWNLOADS="${GROK_DOWNLOADS:-0}"
GROK_WT_MAX_AGE="${GROK_WT_MAX_AGE:-1h}"

hr() { printf '\n=== %s ===\n' "$1"; }

printf 'Mode: %s   Threshold: %s days\n' \
  "$([ "$APPLY" -eq 1 ] && echo APPLY || echo DRY-RUN)" "$DAYS"
printf 'Grok extras: worktree_gc=%s downloads=%s\n' \
  "$GROK_WORKTREE_GC" "$GROK_DOWNLOADS"

# ---------------------------------------------------------------------------
# File-level roots (legacy / other tools)
# name|session-root pairs.
# ---------------------------------------------------------------------------
FILE_ROOTS="
kimi (legacy CLI)|$HOME_DIR/.kimi/sessions
kimi-code|$HOME_DIR/.kimi-code/sessions
opencode (logs)|$HOME_DIR/.local/share/opencode/log
opencode (snapshots)|$HOME_DIR/.local/share/opencode/snapshot
opencode (tool-output)|$HOME_DIR/.local/share/opencode/tool-output
claude-code|$HOME_DIR/.claude/projects
codex|$HOME_DIR/.codex/sessions
"

hr "FILE-LEVEL SESSION ROOTS"

while IFS='|' read -r name root; do
  [ -z "${name// }" ] && continue
  if [ ! -d "$root" ]; then
    printf '%-28s not present\n' "$name"
    continue
  fi
  # shellcheck disable=SC2016
  matches=$(find "$root" -type f -mtime +"$DAYS" 2>/dev/null || true)
  if [ -z "$matches" ]; then
    size=$(du -sh "$root" 2>/dev/null | cut -f1)
    printf '%-28s %-8s total, nothing older than %sd\n' "$name" "${size:-?}" "$DAYS"
    continue
  fi
  count=$(printf '%s\n' "$matches" | wc -l | tr -d ' ')
  kb=$(printf '%s\n' "$matches" | xargs stat -f '%z' 2>/dev/null \
    | awk '{s+=$1} END {printf "%.0f", s/1024}')
  mb=$(awk -v k="${kb:-0}" 'BEGIN { printf "%.1f", k/1024 }')
  printf '%-28s %s files, %s MB older than %sd\n' "$name" "$count" "$mb" "$DAYS"
  if [ "$APPLY" -eq 1 ]; then
    printf '%s\n' "$matches" | xargs rm -f 2>/dev/null || true
    find "$root" -type d -empty -delete 2>/dev/null || true
    printf '%-28s -> pruned\n' ""
  fi
done <<EOF
$FILE_ROOTS
EOF

# ---------------------------------------------------------------------------
# Grok — directory-level sessions (the big win; updates.jsonl is huge)
# Layout: ~/.grok/sessions/<url-encoded-cwd>/<session-id>/
# ---------------------------------------------------------------------------
hr "GROK SESSIONS (~/.grok/sessions)"

GROK_SESSIONS="$HOME_DIR/.grok/sessions"
if [ ! -d "$GROK_SESSIONS" ]; then
  echo "not present"
else
  # Collect candidates via Python for correct mtime / size / safety.
  # Protects every session_id in ~/.grok/active_sessions.json.
  # Prints TSV: session_id \t path \t size_bytes \t age_days
  REPORT=$(DAYS="$DAYS" python3 - <<'PY'
import os, time, json
from pathlib import Path

days = int(os.environ.get("DAYS", "14"))
cutoff = time.time() - days * 86400
root = Path.home() / ".grok" / "sessions"
active = set()
try:
    p = Path.home() / ".grok" / "active_sessions.json"
    if p.exists():
        for s in json.loads(p.read_text()):
            if isinstance(s, dict) and s.get("session_id"):
                active.add(s["session_id"])
except Exception:
    pass

rows = []
total_keep = 0
keep_count = 0
for cwd_dir in sorted(root.iterdir()):
    if not cwd_dir.is_dir():
        continue
    # skip index / non-session dirs
    if cwd_dir.name.startswith("."):
        continue
    for sess in cwd_dir.iterdir():
        if not sess.is_dir():
            continue
        sid = sess.name
        # session ids are UUIDv7-ish; skip obvious non-session dirs
        if len(sid) < 30:
            continue
        try:
            files = [f for f in sess.rglob("*") if f.is_file()]
            if files:
                mtime = max(f.stat().st_mtime for f in files)
                size = sum(f.stat().st_size for f in files)
            else:
                mtime = sess.stat().st_mtime
                size = 0
        except Exception:
            continue
        if sid in active:
            keep_count += 1
            total_keep += size
            continue
        if mtime > cutoff:
            keep_count += 1
            total_keep += size
            continue
        age_d = (time.time() - mtime) / 86400
        rows.append((sid, str(sess), size, age_d))

rows.sort(key=lambda r: -r[2])
total_del = sum(r[2] for r in rows)
print(f"META\t{len(rows)}\t{total_del}\t{keep_count}\t{total_keep}")
for sid, path, size, age in rows:
    print(f"{sid}\t{path}\t{size}\t{age:.1f}")
PY
)

  meta=$(printf '%s\n' "$REPORT" | head -1)
  # META \t n_del \t bytes_del \t n_keep \t bytes_keep
  n_del=$(printf '%s\n' "$meta" | cut -f2)
  bytes_del=$(printf '%s\n' "$meta" | cut -f3)
  n_keep=$(printf '%s\n' "$meta" | cut -f4)
  bytes_keep=$(printf '%s\n' "$meta" | cut -f5)
  gb_del=$(awk -v b="${bytes_del:-0}" 'BEGIN { printf "%.2f", b/1e9 }')
  gb_keep=$(awk -v b="${bytes_keep:-0}" 'BEGIN { printf "%.2f", b/1e9 }')

  total_now=$(du -sh "$GROK_SESSIONS" 2>/dev/null | cut -f1)
  printf 'Current size: %s\n' "${total_now:-?}"
  printf 'Would delete: %s sessions (%.2f GB) older than %sd\n' \
    "${n_del:-0}" "${gb_del:-0}" "$DAYS"
  printf 'Would keep:   %s sessions (%.2f GB) — recent or active\n' \
    "${n_keep:-0}" "${gb_keep:-0}"

  # Show top 10 candidates by size
  printf '%s\n' "$REPORT" | awk -F'\t' 'NR>1 && NR<=11 {
    gb=$3/1e9; printf "  %6.2f GB  age=%.0fd  %s\n", gb, $4, $1
  }'
  if [ "${n_del:-0}" -gt 10 ] 2>/dev/null; then
    printf '  … and %s more\n' "$((n_del - 10))"
  fi

  if [ "$APPLY" -eq 1 ] && [ "${n_del:-0}" -gt 0 ] 2>/dev/null; then
    printf '%s\n' "$REPORT" | awk -F'\t' 'NR>1 {print $2}' | while IFS= read -r path; do
      [ -n "$path" ] || continue
      [ -d "$path" ] || continue
      rm -rf "$path"
    done

    # Empty cwd group dirs
    find "$GROK_SESSIONS" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true

    # Search index: drop deleted session_ids, then VACUUM
    IDS_FILE=$(mktemp)
    printf '%s\n' "$REPORT" | awk -F'\t' 'NR>1 {print $1}' > "$IDS_FILE"
    python3 - <<PY
import sqlite3
from pathlib import Path
idx = Path.home() / ".grok" / "sessions" / "session_search.sqlite"
ids_path = Path("$IDS_FILE")
ids = [l.strip() for l in ids_path.read_text().splitlines() if l.strip()]
if not idx.exists() or not ids:
    raise SystemExit(0)
conn = sqlite3.connect(str(idx))
cur = conn.cursor()
removed = 0
for i in range(0, len(ids), 200):
    chunk = ids[i:i+200]
    ph = ",".join("?" * len(chunk))
    cur.execute(f"DELETE FROM session_docs WHERE session_id IN ({ph})", chunk)
    removed += cur.rowcount if cur.rowcount and cur.rowcount > 0 else 0
conn.commit()
conn.execute("VACUUM")
conn.close()
print(f"  search index: removed {removed} rows + VACUUM")
PY
    rm -f "$IDS_FILE"

    # Orphan relocations locks (0-byte clutter)
    reloc="$HOME_DIR/.grok/relocations"
    if [ -d "$reloc" ]; then
      removed_locks=0
      for lock in "$reloc"/*.lock; do
        [ -e "$lock" ] || continue
        sid=$(basename "$lock" .lock)
        # still exists as a session dir?
        if ! find "$GROK_SESSIONS" -mindepth 2 -maxdepth 2 -type d -name "$sid" 2>/dev/null | grep -q .; then
          rm -f "$lock"
          removed_locks=$((removed_locks + 1))
        fi
      done
      printf '  relocation locks removed: %s\n' "$removed_locks"
    fi

    after=$(du -sh "$GROK_SESSIONS" 2>/dev/null | cut -f1)
    printf 'Grok sessions after: %s\n' "${after:-?}"
  fi
fi

# ---------------------------------------------------------------------------
# Grok worktree GC (official CLI; safe — skips alive processes)
# ---------------------------------------------------------------------------
if [ "$GROK_WORKTREE_GC" = "1" ]; then
  hr "GROK WORKTREE GC (max-age=$GROK_WT_MAX_AGE)"
  if command -v grok >/dev/null 2>&1; then
    before_wt=$(du -sh "$HOME_DIR/.grok/worktrees" 2>/dev/null | cut -f1)
    printf 'worktrees before: %s\n' "${before_wt:-absent}"
    if [ "$APPLY" -eq 1 ]; then
      grok worktree gc -f --max-age "$GROK_WT_MAX_AGE" 2>&1 || true
      after_wt=$(du -sh "$HOME_DIR/.grok/worktrees" 2>/dev/null | cut -f1)
      printf 'worktrees after:  %s\n' "${after_wt:-absent}"
    else
      grok worktree gc --dry-run --max-age "$GROK_WT_MAX_AGE" 2>&1 || true
      echo "(dry-run only; re-run with --apply to remove)"
    fi
  else
    echo "grok CLI not on PATH — skip"
  fi
fi

# ---------------------------------------------------------------------------
# Grok downloads — keep newest binary only
# ---------------------------------------------------------------------------
if [ "$GROK_DOWNLOADS" = "1" ]; then
  hr "GROK DOWNLOADS (~/.grok/downloads)"
  dl="$HOME_DIR/.grok/downloads"
  if [ ! -d "$dl" ]; then
    echo "not present"
  else
    # list files by mtime newest first
    mapfile_tmp=$(mktemp)
    # macOS: use find + stat + sort
    find "$dl" -type f -maxdepth 1 2>/dev/null \
      | while IFS= read -r f; do
          m=$(stat -f '%m' "$f" 2>/dev/null || echo 0)
          s=$(stat -f '%z' "$f" 2>/dev/null || echo 0)
          printf '%s\t%s\t%s\n' "$m" "$s" "$f"
        done \
      | sort -t$'\t' -k1,1nr > "$mapfile_tmp"

    nfiles=$(wc -l < "$mapfile_tmp" | tr -d ' ')
    if [ "${nfiles:-0}" -le 1 ]; then
      size=$(du -sh "$dl" 2>/dev/null | cut -f1)
      printf 'only %s binary present (%s) — nothing to prune\n' "${nfiles:-0}" "${size:-?}"
    else
      newest=$(head -1 "$mapfile_tmp" | cut -f3)
      printf 'keep newest: %s\n' "$(basename "$newest")"
      old_bytes=0
      while IFS=$'\t' read -r _m sz path; do
        [ "$path" = "$newest" ] && continue
        mb=$(awk -v s="$sz" 'BEGIN { printf "%.0f", s/1024/1024 }')
        printf '  remove: %s (%s MB)\n' "$(basename "$path")" "$mb"
        old_bytes=$((old_bytes + sz))
        if [ "$APPLY" -eq 1 ]; then
          rm -f "$path"
        fi
      done < <(tail -n +2 "$mapfile_tmp")
      gb=$(awk -v b="$old_bytes" 'BEGIN { printf "%.2f", b/1e9 }')
      printf 'old downloads: %.2f GB %s\n' "$gb" \
        "$([ "$APPLY" -eq 1 ] && echo removed || echo reclaimable)"
    fi
    rm -f "$mapfile_tmp"
  fi
fi

hr "DONE"
if [ "$APPLY" -eq 0 ]; then
  echo "Dry run only. Re-run with --apply to delete."
  echo "Recommended Grok full pass:"
  echo "  DAYS=3 GROK_WORKTREE_GC=1 GROK_DOWNLOADS=1 $0 --apply"
fi
