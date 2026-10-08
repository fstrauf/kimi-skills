---
name: storage-sweep
description: >
  Guided macOS dev-machine storage cleanup for heavy coding-tool usage (Grok Build,
  Kimi Code, opencode, VS Code, Docker, Node, Rust, uv/pip, Homebrew). Runs a
  read-only scan of package caches, stale node_modules/.next/target dirs, editor
  caches, AI-tool sessions (especially ~/.grok), and Docker, presents a tiered size
  report, then cleans ONLY the categories the user explicitly confirms — using each
  tool's standard clean command. Use when the user asks to free up disk space, clean
  dev caches, do a storage sweep, clean up ~/.grok, or says their Mac is running
  out of storage.
---

# Storage Sweep — Agent Skill

You run a **guided** storage cleanup on the user's macOS dev machine. The workflow is
always: scan (read-only) → report → user confirms per category → clean only what was
confirmed → show before/after disk usage. You never delete anything on your own
initiative, and you never run the cleanup silently or on a schedule.

## Hard Rules

- **The scan is read-only.** `scan.sh` deletes nothing. Do not add deletions to it.
- **No deletion without explicit per-category confirmation** via AskUserQuestion in
  the current run. Past approvals do not carry over.
- **Only `rm -rf` paths that appeared in the current scan output** and were explicitly
  confirmed. Never glob-delete (no `rm -rf ~/*/node_modules`).
- **Never offered for deletion** (report-only, may only be cleaned if the user asks
  spontaneously and confirms each item): Docker *volumes*, VS Code `workspaceStorage`,
  VS Code installed extensions, Downloads, Trash.
- **AI session data** (Grok / Kimi / Claude / Codex / opencode) is **not** Tier-1
  auto-clean. Offer it only through `prune-sessions.sh` after a dry-run report and
  an explicit age threshold confirmation. Prefer Grok when `~/.grok` is large —
  chat history (`updates.jsonl`) and subagent worktrees are usually the top offenders.
- Prefer each tool's own clean command over manual deletion wherever one exists.
- If a clean command fails, report it and move on — do not retry with more force.

## Step 1 — Scan

Run the read-only scanner (takes 1–5 minutes over the home directory; use a generous
timeout, run in background if needed):

```bash
bash <skill-dir>/scan.sh
```

`STALE_DAYS` defaults to 60; override only if the user asks (`STALE_DAYS=30 bash scan.sh`).

Capture `df -h /` free space **before** any cleanup.

### Session pruning (`prune-sessions.sh`)

Prunes AI-tool session/history data older than `DAYS` (default **14**). Always dry-run
first, show the report, apply only after confirmation:

```bash
DAYS=14 bash <skill-dir>/prune-sessions.sh           # dry run — report only
DAYS=14 bash <skill-dir>/prune-sessions.sh --apply   # delete (confirmed only)
```

**Tool semantics:**

| Tool | Strategy |
|------|----------|
| Kimi / Claude / Codex / opencode | File-level: only files with mtime older than `DAYS` |
| **Grok Build** | **Directory-level**: whole `~/.grok/sessions/<cwd>/<session-id>/` trees when the newest file inside is older than `DAYS`. Skips every ID in `~/.grok/active_sessions.json`. After apply: drops empty cwd groups, removes matching rows from `session_search.sqlite` + `VACUUM`, deletes orphan `relocations/*.lock` |

**Grok dominates disk.** When `~/.grok` is multi-GB, recommend a dedicated Grok pass
with a tighter threshold (3 days is a good default; 1 day is aggressive):

```bash
# Dry run — sessions + worktree GC + old CLI downloads
DAYS=3 GROK_WORKTREE_GC=1 GROK_DOWNLOADS=1 bash <skill-dir>/prune-sessions.sh

# Apply after user confirms the dry-run numbers
DAYS=3 GROK_WORKTREE_GC=1 GROK_DOWNLOADS=1 bash <skill-dir>/prune-sessions.sh --apply
```

| Env flag | Effect |
|----------|--------|
| `GROK_WORKTREE_GC=1` | Runs `grok worktree gc` with `--max-age` (default `1h`, override `GROK_WT_MAX_AGE`). Dry-run uses `--dry-run`; apply uses `-f`. Skips worktrees still owned by live processes. |
| `GROK_DOWNLOADS=1` | Keeps the **newest** binary under `~/.grok/downloads/`, removes older versions (~100–130 MB each). |
| `GROK_WT_MAX_AGE` | Duration for worktree GC (e.g. `30m`, `1h`, `1d`). Default `1h`. |

**Never touch** under `~/.grok`: `auth.json`, `config.toml`, `mcp_credentials.json`,
`skills/`, `bundled/`, `docs/`, the active session dirs, or the newest download binary.

If the user only wants Grok cleaned (no full sweep), skip `scan.sh` package-cache
sections and go straight to the Grok dry-run above, then confirm.

## Step 2 — Report

Present a compact tiered summary, largest first, grouped as:

- **Tier 1 — Safe (tool-managed caches, fully regenerable):** Docker build cache,
  uv, pip, npm, pnpm, yarn, Homebrew downloads, cargo registry, go caches,
  Playwright/Puppeteer browsers; **Grok old downloads** (keep newest binary only).
- **Tier 2 — Safe, costs a rebuild:** stale `node_modules` / `.next` / `target` dirs
  (list each with size and age); **unused git / AI worktrees** (see below);
  **Grok worktree GC** via `grok worktree gc`.
- **Tier 3 — Review + age threshold:** AI session data (especially Grok
  `~/.grok/sessions`), Docker volumes, workspaceStorage, extensions, Downloads,
  Trash. For sessions, always show the `prune-sessions.sh` dry-run before offering
  apply. State sizes; require explicit threshold (e.g. “sessions older than 3 days”).

The scan's **UNCATALOGUED CACHES** section lists any `~/.*`, `~/.cache/*` or
`~/Library/Caches/*` entry over 100 MB that is not in the hand-picked lists. Surface
those as Tier 3 candidates and ask; do not assume they are regenerable.

Note anything unusual (e.g. a single directory dominating the disk — often
`~/.grok/sessions` for heavy Grok users).

### Worktrees (from `GIT / AI WORKTREES` scan section)

Linked worktrees — including Claude Code's `<repo>/.claude/worktrees/*` in **every**
repo under `CODE_ROOTS` — are classified by `worktree_gc.py` (also run inside
`scan.sh`). **Use its verdict; never judge a worktree by size or `clean` alone** —
an in-flight PR branch is clean too.

| Verdict | Meaning | Offer for removal? |
|---------|---------|--------------------|
| `SAFE` | clean, idle, fully merged (ancestor of default branch, or PR merged/closed), or a stale registration whose directory is gone | Yes, after confirmation |
| `REVIEW` | clean + idle + pushed, but unmerged with no PR record | Only with a separate explicit yes per path |
| `KEEP` | primary, locked, dirty, rebase/merge in progress, open PR, commits on no remote, live process cwd, or any activity (commit / git metadata / Claude session transcript) within `IDLE_DAYS` (default 2) | Never. Report the reason |

If `gh` is unavailable, every unmerged branch is `KEEP` (fail closed).

```bash
python3 <skill-dir>/worktree_gc.py                      # report only
IDLE_DAYS=1 python3 <skill-dir>/worktree_gc.py          # shorter idle window
python3 <skill-dir>/worktree_gc.py --apply PATH...      # removes only paths still SAFE
python3 <skill-dir>/worktree_gc.py --apply PATH... --include-review
```

`--apply` re-classifies at delete time (so a worktree that became active since the
scan is refused), runs `git worktree remove` + `prune`, then `git branch -d` (which
refuses unmerged branches). Orphan dirs in `.claude/worktrees` that git does not know
about are report-only; inspect before any `rm -rf`.

Most disk in `KEEP` worktrees is a per-worktree `node_modules`/`.next`. That cannot be
reclaimed while the work is active; say so rather than loosening the rules.

Other worktree sources the scan still lists: AI-tool isolates (`~/.grok/worktrees`,
`~/.cursor/worktrees`, `~/.codex/worktrees`, `~/.kimi-code/worktrees`; often full
clones) and ephemeral `/tmp` checkouts. Only offer those that are clean and idle.

**Grok worktrees:** prefer the official CLI over raw `rm -rf`:

```bash
grok worktree list
grok worktree gc --dry-run --max-age 1h
grok worktree gc -f --max-age 1h          # after confirm
# or via prune-sessions: GROK_WORKTREE_GC=1
```

Raw `rm -rf` of a path under `~/.grok/worktrees` is only for confirmed orphans that
`gc` will not touch (and only the exact path from the scan).

## Step 3 — Confirm

Ask which categories to clean (multi-select), one question for Tier 1 categories,
one for Tier 2 items (including individual worktree paths when present).

For **Grok / AI sessions**, ask a dedicated question with age options, e.g.:

- Sessions older than **3 days** (recommended for Grok)
- Sessions older than **1 day** (aggressive)
- Sessions older than **7 days** (conservative)
- Skip session pruning

Include optional checkboxes for `GROK_WORKTREE_GC` and `GROK_DOWNLOADS` when
`~/.grok` is present.

Docker volume pruning, if the user raises it, requires its own separate explicit
confirmation with a data-loss warning.

## Step 4 — Clean (only confirmed categories)

Standard clean commands per category:

| Category | Command |
|---|---|
| Docker images/containers/build cache | `docker system prune -af` |
| Docker volumes (separate confirm!) | `docker volume prune` |
| uv | `uv cache prune` |
| pip | `pip cache purge` |
| npm | `npm cache clean --force` |
| pnpm | `pnpm store prune` |
| yarn | `yarn cache clean` |
| Homebrew | `brew cleanup --prune=all && brew autoremove` |
| cargo registry | `cargo cache -a` if `cargo-cache` is installed; otherwise `rm -rf` the exact `~/.cargo/registry/cache` and `~/.cargo/registry/src` paths from the scan (both regenerate) |
| NuGet / cargo-xwin / codex-runtimes / node-gyp / unused rustup toolchains | `dotnet nuget locals all --clear`; `rm -rf` the exact scan path for the others; `rustup toolchain uninstall <name>` |
| go | `go clean -cache -modcache` |
| Stale `node_modules`/`.next`/`target` | `rm -rf` the exact confirmed paths from the scan |
| VS Code caches | `rm -rf` the confirmed `Cache` / `CachedData` / `CachedExtensionVSIXs` / `logs` / `Crashpad` dirs only |
| Linked git worktree (SAFE/REVIEW only) | `python3 <skill-dir>/worktree_gc.py --apply <exact path>` (add `--include-review` for REVIEW). Never hand-roll `git worktree remove --force`. |
| AI-tool full-clone worktree | Prefer `grok worktree gc -f` for Grok; otherwise `rm -rf` the exact confirmed path under `~/.grok/worktrees` (etc.) from the scan — these are not registered with the main repo. |
| **Grok sessions (+ optional worktrees/downloads)** | `DAYS=<N> GROK_WORKTREE_GC=1 GROK_DOWNLOADS=1 bash <skill-dir>/prune-sessions.sh --apply` after dry-run confirmation |
| Other AI sessions only | `DAYS=<N> bash <skill-dir>/prune-sessions.sh --apply` |

Skip any tool that isn't installed.

## Step 5 — Report result

Show `df -h /` before/after (capture the before value in step 1), total space freed,
and any failures. For Grok, also show:

```bash
du -sh ~/.grok ~/.grok/sessions ~/.grok/worktrees ~/.grok/downloads 2>/dev/null
```

Remind the user they can re-run the sweep any time, and that recurring automation
(launchd) is available on request but not set up by default.

### Suggested recurring Grok hygiene (optional, only if user asks)

```bash
# Monthly: keep ~3 days of Grok history + GC stale worktrees + old binaries
DAYS=3 GROK_WORKTREE_GC=1 GROK_DOWNLOADS=1 \
  bash <skill-dir>/prune-sessions.sh --apply
```

Do **not** install launchd jobs unless the user explicitly requests automation.
