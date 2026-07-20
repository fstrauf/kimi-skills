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

hr "AI TOOL LOCAL DATA (REVIEW ONLY)"
sz "$HOME_DIR/.kimi" "Kimi Code data (sessions, logs)"
sz "$HOME_DIR/.config/opencode" "opencode config/data"
sz "$HOME_DIR/.local/share/opencode" "opencode local data"

hr "XCODE LEFTOVERS"
sz "$HOME_DIR/Library/Developer/Xcode/DerivedData" "DerivedData"
sz "$HOME_DIR/Library/Developer/CoreSimulator" "CoreSimulator"
sz "$HOME_DIR/Library/Developer/Xcode/iOS DeviceSupport" "iOS DeviceSupport"

hr "TOP 10 ~/Library/Caches"
du -sh "$HOME_DIR"/Library/Caches/* 2>/dev/null | sort -rh | head -10

hr "MISC"
sz "$HOME_DIR/Downloads" "Downloads (REVIEW ONLY)"
sz "$HOME_DIR/.Trash" "Trash"

hr "SCAN COMPLETE — nothing was modified"
