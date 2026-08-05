#!/usr/bin/env bash
# storage-sweep scan — STRICTLY READ-ONLY.
# Measures common dev-tool cache locations and stale project artifacts,
# prints a size report. Deletes nothing, modifies nothing.

set -u

STALE_DAYS="${STALE_DAYS:-60}"
HOME_DIR="$HOME"

hr() { printf '\n=== %s ===\n' "$1"; }

sz() {
  # sz <path> [label] — print human-readable size if the path exists
  local p="$1" label="${2:-$1}"
  if [ -e "$p" ]; then
    local s
    s=$(du -sh "$p" 2>/dev/null | cut -f1)
    printf '%-10s %s\n' "${s:-?}" "$label"
  fi
}

hr "DISK"
df -h / | awk 'NR==1 || /\// {print $1, $2, $3, $4, $5, $9}'

hr "DOCKER (docker system df)"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker system df 2>/dev/null
else
  echo "docker not installed or daemon not running"
fi

hr "PACKAGE CACHES"
if command -v uv >/dev/null 2>&1; then sz "$(uv cache dir 2>/dev/null)" "uv cache"; else sz "$HOME_DIR/.cache/uv" "uv cache"; fi
sz "$HOME_DIR/Library/Caches/pip" "pip cache"
sz "$HOME_DIR/.npm" "npm cache"
if command -v pnpm >/dev/null 2>&1; then sz "$(pnpm store path 2>/dev/null)" "pnpm store"; fi
sz "$HOME_DIR/Library/Caches/Yarn" "yarn cache"
if command -v brew >/dev/null 2>&1; then sz "$(brew --cache 2>/dev/null)" "Homebrew downloads"; fi
sz "$HOME_DIR/.cargo/registry" "cargo registry"
sz "$HOME_DIR/.cargo/git" "cargo git"
sz "$HOME_DIR/go/pkg/mod" "go module cache"
sz "$HOME_DIR/Library/Caches/go-build" "go build cache"
sz "$HOME_DIR/Library/Caches/ms-playwright" "Playwright browsers"
sz "$HOME_DIR/.cache/ms-playwright" "Playwright browsers"
sz "$HOME_DIR/.cache/puppeteer" "Puppeteer browsers"
sz "$HOME_DIR/Library/Caches/com.microsoft.VSCode.ShipIt" "VS Code updater cache"
sz "$HOME_DIR/Library/Caches/typescript" "TypeScript cache"

hr "STALE PROJECT ARTIFACTS (node_modules / .next / target, untouched > ${STALE_DAYS}d)"
find "$HOME_DIR" \
  \( -path "$HOME_DIR/Library" \
     -o -path "$HOME_DIR/.Trash" \
     -o -path "$HOME_DIR/.vscode" \
     -o -path "$HOME_DIR/.cursor" \
     -o -path "$HOME_DIR/.docker" \
     -o -path "$HOME_DIR/.npm" \
     -o -path "$HOME_DIR/.cache" \
     -o -path "$HOME_DIR/.cargo" \
     -o -path "$HOME_DIR/.rustup" \
     -o -path "$HOME_DIR/.local" \
     -o -path "$HOME_DIR/.kimi" \
     -o -path "$HOME_DIR/.kimi-code" \
     -o -path "$HOME_DIR/.grok" \
     -o -path "$HOME_DIR/.claude" \
     -o -path "$HOME_DIR/.codex" \
     -o -path "$HOME_DIR/.nvm" \
     -o -path "$HOME_DIR/.opencode" \
     -o -path "$HOME_DIR/.config" \
     -o -path "$HOME_DIR/go" \
     -o -path "$HOME_DIR/Movies" \
     -o -path "$HOME_DIR/Music" \
     -o -path "$HOME_DIR/Pictures" \
  \) -prune -o \
  \( -type d \( -name node_modules -o -name .next -o -name target \) -mtime +"$STALE_DAYS" -prune -print \) \
  2>/dev/null | while IFS= read -r d; do
    base=$(basename "$d")
    # only treat 'target' as a Rust build dir when a Cargo.toml sits next to it
    if [ "$base" = "target" ] && [ ! -f "$(dirname "$d")/Cargo.toml" ]; then
      continue
    fi
    du -sh "$d" 2>/dev/null
  done | sort -rh

hr "VS CODE DATA"
sz "$HOME_DIR/Library/Application Support/Code/Cache" "Code Cache"
sz "$HOME_DIR/Library/Application Support/Code/CachedData" "Code CachedData"
sz "$HOME_DIR/Library/Application Support/Code/CachedExtensionVSIXs" "Code cached extension installers"
sz "$HOME_DIR/Library/Application Support/Code/logs" "Code logs"
sz "$HOME_DIR/Library/Application Support/Code/Crashpad" "Code crash dumps"
sz "$HOME_DIR/Library/Application Support/Code/User/workspaceStorage" "workspaceStorage (REVIEW ONLY - contains per-project state)"
sz "$HOME_DIR/.vscode/extensions" "installed extensions (REVIEW ONLY)"

hr "AI TOOL LOCAL DATA"
# Grok Build (~/.grok) often dominates disk: sessions/updates.jsonl + worktrees.
# Prune via prune-sessions.sh (dir-level) — not auto-deleted by this scan.
sz "$HOME_DIR/.grok" "Grok Build total (~/.grok)"
sz "$HOME_DIR/.grok/sessions" "  grok sessions (chat history / updates.jsonl)"
sz "$HOME_DIR/.grok/worktrees" "  grok worktrees (subagent isolates)"
sz "$HOME_DIR/.grok/downloads" "  grok downloads (CLI binaries)"
sz "$HOME_DIR/.grok/memtrace" "  grok memtrace"
sz "$HOME_DIR/.kimi" "Kimi Code data (sessions, logs)"
sz "$HOME_DIR/.kimi-code" "Kimi Code data (~/.kimi-code)"
sz "$HOME_DIR/.config/opencode" "opencode config/data"
sz "$HOME_DIR/.local/share/opencode" "opencode local data"
sz "$HOME_DIR/.claude" "Claude Code data"
sz "$HOME_DIR/.codex" "Codex data"

# Grok session breakdown by project (encoded-cwd group) — top 8
if [ -d "$HOME_DIR/.grok/sessions" ]; then
  echo ""
  echo "(grok sessions by project — top 8)"
  # depth-1 dirs are URL-encoded cwd groups; skip sqlite index files
  find "$HOME_DIR/.grok/sessions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
    | while IFS= read -r d; do
        du -sk "$d" 2>/dev/null
      done \
    | sort -rn | head -8 \
    | while read -r kb path; do
        mb=$(awk -v k="$kb" 'BEGIN { if (k>=1048576) printf "%.1fG", k/1048576; else if (k>=1024) printf "%.0fM", k/1024; else printf "%sK", k }')
        # decode %2F → / for readability
        decoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.unquote(sys.argv[1]))" "$(basename "$path")" 2>/dev/null || basename "$path")
        n=$(find "$path" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        printf '%-10s %s sessions  %s\n' "$mb" "$n" "$decoded"
      done
  # age buckets (session dirs only)
  echo ""
  echo "(grok session age buckets)"
  python3 - <<'PY' 2>/dev/null || true
import time
from pathlib import Path
root = Path.home() / ".grok" / "sessions"
now = time.time()
buckets = [("≤1d", 0, 1), ("1–3d", 1, 3), ("3–7d", 3, 7), (">7d", 7, 10_000)]
stats = {label: [0, 0] for label, _, _ in buckets}  # count, bytes
for cwd in root.iterdir():
    if not cwd.is_dir():
        continue
    for sess in cwd.iterdir():
        if not sess.is_dir() or len(sess.name) < 30:
            continue
        try:
            files = [f for f in sess.rglob("*") if f.is_file()]
            if not files:
                continue
            mtime = max(f.stat().st_mtime for f in files)
            size = sum(f.stat().st_size for f in files)
        except Exception:
            continue
        age = (now - mtime) / 86400
        for label, lo, hi in buckets:
            if lo <= age < hi or (label == ">7d" and age >= 7):
                stats[label][0] += 1
                stats[label][1] += size
                break
for label, _, _ in buckets:
    n, b = stats[label]
    print(f"  {label:6}  {n:5} sessions  {b/1e9:6.2f} GB")
PY
fi

hr "XCODE LEFTOVERS"
sz "$HOME_DIR/Library/Developer/Xcode/DerivedData" "DerivedData"
sz "$HOME_DIR/Library/Developer/CoreSimulator" "CoreSimulator"
sz "$HOME_DIR/Library/Developer/Xcode/iOS DeviceSupport" "iOS DeviceSupport"

# --- Git / AI-tool worktrees -------------------------------------------------
# Linked worktrees share objects with the main repo; isolated AI clones often
# do not. Read-only: report path, size, clean/dirty, branch — agent proposes
# removals; never delete from this script.
hr "GIT / AI WORKTREES"

_wt_report_checkout() {
  # _wt_report_checkout <path> [extra-label]
  local d="$1" extra="${2:-}"
  [ -e "$d/.git" ] || return 0
  local size kind branch dirty_n dirty_flag
  size=$(du -sh "$d" 2>/dev/null | cut -f1)
  kind="linked"
  [ -d "$d/.git" ] && kind="full-clone"
  branch=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
  dirty_n=$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  dirty_flag="clean"
  [ "${dirty_n:-0}" -gt 0 ] 2>/dev/null && dirty_flag="dirty:${dirty_n}"
  printf '%-10s %-12s %-10s %s  [%s]%s\n' \
    "${size:-?}" "$kind" "$dirty_flag" "$d" "$branch" "${extra:+ $extra}"
}

# AI-tool isolated worktree roots (full clones or linked trees from subagents)
for root in \
  "$HOME_DIR/.grok/worktrees" \
  "$HOME_DIR/.cursor/worktrees" \
  "$HOME_DIR/.claude/worktrees" \
  "$HOME_DIR/.codex/worktrees" \
  "$HOME_DIR/.kimi-code/worktrees"
do
  if [ -d "$root" ]; then
    sz "$root" "$(basename "$(dirname "$root")")/$(basename "$root") (total)"
    find "$root" -mindepth 1 -maxdepth 2 -type d 2>/dev/null | while IFS= read -r d; do
      _wt_report_checkout "$d"
    done
  fi
done

# Linked worktrees on repos under common code roots (multi-worktree only).
CODE_ROOTS="${CODE_ROOTS:-$HOME_DIR/01_code $HOME_DIR/code $HOME_DIR/src $HOME_DIR/dev $HOME_DIR/Projects $HOME_DIR/projects}"
echo ""
echo "(linked worktrees under CODE_ROOTS; multi-worktree repos only)"
for code_root in $CODE_ROOTS; do
  [ -d "$code_root" ] || continue
  # Primary repos only: .git as a *directory* (skip worktree .git files).
  find "$code_root" -maxdepth 4 -type d -name .git 2>/dev/null | while IFS= read -r gitpath; do
    repo=$(dirname "$gitpath")
    case "$repo" in
      */node_modules/*|*/.venv/*|*/.next/*|*/.tmp/*) continue ;;
    esac
    command -v git >/dev/null 2>&1 || continue
    # Count worktrees; skip single-checkout repos.
    n=$(git -C "$repo" worktree list --porcelain 2>/dev/null | grep -c '^worktree ' || true)
    [ "${n:-0}" -gt 1 ] || continue
    echo "--- $repo ($n worktrees) ---"
    git -C "$repo" worktree list 2>/dev/null | while IFS= read -r wtline; do
      wtpath=$(printf '%s\n' "$wtline" | awk '{print $1}')
      [ -n "$wtpath" ] || continue
      size=$(du -sh "$wtpath" 2>/dev/null | cut -f1)
      dirty_n=$(git -C "$wtpath" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
      dirty_flag="clean"
      [ "${dirty_n:-0}" -gt 0 ] 2>/dev/null && dirty_flag="dirty:${dirty_n}"
      primary=""
      [ "$wtpath" = "$repo" ] && primary=" PRIMARY"
      rest=$(printf '%s\n' "$wtline" | awk '{$1=""; sub(/^ /,""); print}')
      printf '%-10s %-10s %s  %s%s\n' "${size:-?}" "$dirty_flag" "$wtpath" "$rest" "$primary"
    done
  done
done

# Ephemeral checkouts under /tmp (often leftover batch/agent worktrees).
echo ""
echo "(ephemeral checkouts under /tmp — may or may not be registered)"
for p in /tmp /private/tmp; do
  [ -d "$p" ] || continue
  find "$p" -maxdepth 2 \( -type d -name .git -o -type f -name .git \) 2>/dev/null \
    | while IFS= read -r gitpath; do
        _wt_report_checkout "$(dirname "$gitpath")"
      done
done

hr "TOP 10 ~/Library/Caches"
du -sh "$HOME_DIR"/Library/Caches/* 2>/dev/null | sort -rh | head -10

hr "MISC"
sz "$HOME_DIR/Downloads" "Downloads (REVIEW ONLY)"
sz "$HOME_DIR/.Trash" "Trash"

hr "SCAN COMPLETE — nothing was modified"
