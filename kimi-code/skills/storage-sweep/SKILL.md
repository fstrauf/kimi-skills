---
name: storage-sweep
description: >
  Guided macOS dev-machine storage cleanup for heavy coding-tool usage (Kimi Code,
  opencode, VS Code, Docker, Node, Rust, uv/pip, Homebrew). Runs a read-only scan of
  package caches, stale node_modules/.next/target dirs, editor caches, and Docker,
  presents a tiered size report, then cleans ONLY the categories the user explicitly
  confirms — using each tool's standard clean command. Use when the user asks to free
  up disk space, clean dev caches, do a storage sweep, or says their Mac is running
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
  VS Code installed extensions, Kimi Code / opencode session data, Downloads, Trash.
- Prefer each tool's own clean command over manual deletion wherever one exists.
- If a clean command fails, report it and move on — do not retry with more force.

## Step 1 — Scan

Run the read-only scanner (takes 1–5 minutes over the home directory; use a generous
timeout, run in background if needed):

```bash
bash <skill-dir>/scan.sh
```

`STALE_DAYS` defaults to 60; override only if the user asks (`STALE_DAYS=30 bash scan.sh`).

### Session pruning

`<skill-dir>/prune-sessions.sh` prunes AI-tool session/history data (Kimi legacy
`~/.kimi`, Kimi Code `~/.kimi-code`, opencode logs/snapshots/tool-output, Claude Code,
Codex) older than `DAYS` (default 14). It only removes files older than the threshold,
so sessions open right now are never touched, and config/credentials are outside its
roots. **Always run it dry first and show the user, apply only after confirmation:**

```bash
DAYS=14 bash <skill-dir>/prune-sessions.sh           # dry run — report only
DAYS=14 bash <skill-dir>/prune-sessions.sh --apply   # delete (confirmed only)
```

## Step 2 — Report

Present a compact tiered summary, largest first, grouped as:

- **Tier 1 — Safe (tool-managed caches, fully regenerable):** Docker build cache,
  uv, pip, npm, pnpm, yarn, Homebrew downloads, cargo registry, go caches,
  Playwright/Puppeteer browsers.
- **Tier 2 — Safe, costs a rebuild:** stale `node_modules` / `.next` / `target` dirs
  (list each with size and age).
- **Tier 3 — Review only:** Docker volumes, workspaceStorage, extensions, AI tool
  session data, Downloads, Trash. State sizes; do not offer to clean.

Note anything unusual (e.g. a single directory dominating the disk).

## Step 3 — Confirm

Ask which categories to clean (multi-select), one question for Tier 1 categories,
one for Tier 2 items. Docker volume pruning, if the user raises it, requires its own
separate explicit confirmation with a data-loss warning.

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
| cargo registry | `cargo cache -a` if `cargo-cache` is installed; otherwise skip and say so |
| go | `go clean -cache -modcache` |
| Stale `node_modules`/`.next`/`target` | `rm -rf` the exact confirmed paths from the scan |
| VS Code caches | `rm -rf` the confirmed `Cache` / `CachedData` / `CachedExtensionVSIXs` / `logs` / `Crashpad` dirs only |

Skip any tool that isn't installed.

## Step 5 — Report result

Show `df -h /` before/after (capture the before value in step 1), total space freed,
and any failures. Remind the user they can re-run the sweep any time, and that
recurring automation (launchd) is available on request but not set up by default.
