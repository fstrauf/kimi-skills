# agent-skills (repo: `kimi-skills`)

Version-controlled home for **personal, cross-repo agent skills** used by Kimi Code, Grok Build, Claude Code (loop skills via `~/.claude/skills` install links + `~/.claude/agents`), and other harnesses on this machine.

The GitHub repo is still named `kimi-skills` for history; treat it as the **agent skills** source of truth, not “Kimi-only.”

---

## Mental model (buckets)

| Bucket | Where content lives | Who sees it | Rule |
|--------|---------------------|-------------|------|
| **A. Universal** | This repo `kimi-code/skills/` (or `agents/skills/`) | Every project via user install | **One real file.** Never copy into product repos. |
| **B. Product-local** | That product’s `.agents/skills/` (etc.) | Only when CWD is that repo | Commit with the product. Ports, QA, product secrets. |
| **B2. Product multi-tenant** | Product repo (e.g. `pageseeds/.agents/skills/`) | **Any CWD** via install symlinks | Real file ships with product; catalog + `~/.grok/skills` are **links only**. |
| **C. Harness-native** | `~/.grok/bundled/skills`, pure Grok extras | That harness only | Don’t force into this repo. |

**B2 examples:** `weekly-seo`, `video-clip`, `reddit-engage` — PageSeeds operator skills used from coffee/DTE/expense/… scheduled jobs.

**Drift rule:** if the same skill name exists in more than one place as **real files** (not symlinks), it *will* diverge. Prefer registry-managed symlinks over copies.

---

## Control plane (keep this stable)

The install plane is **declarative**. Do not hand-edit symlinks in `~/.grok/skills` or this catalog when a skill moves — update the registry and re-apply.

| Artifact | Role |
|----------|------|
| [`skills-registry.yaml`](./skills-registry.yaml) | **Source of truth:** bucket, canonical path, install link targets |
| [`scripts/skillctl.py`](./scripts/skillctl.py) | `apply` / `verify` / `doctor` — rewrites + checks the install plane |
| [`scripts/inventory-skills.py`](./scripts/inventory-skills.py) | Broad machine scan; `--check` fails on broken links / multi-real copies |

```bash
cd ~/01_code/kimi-skills

# After cloning this repo or moving a B2 skill:
python3 scripts/skillctl.py apply

# Anytime / before trusting scheduled SEO jobs:
python3 scripts/skillctl.py doctor          # exit 1 on drift
python3 scripts/inventory-skills.py --check # wider scan
```

### How stability is enforced

1. **Registry names the one canonical path** per managed skill.
2. **Install paths are always `SKILL.md` symlinks** to that file (never a second copy).
3. **Root links** `~/.kimi-code/skills` and `~/.agents/skills` must point at this repo (checked by `verify`).
4. **Grok** loads the universal tree via `[skills].paths = ["~/.kimi-code/skills"]` (advisory check in `doctor`).
5. **`verify` / `doctor` exit non-zero** on broken links, wrong targets, leftover stale files, or multiple real `SKILL.md`s for one name.
6. **Moving a skill:** edit `canonical` (and `install` if needed) in `skills-registry.yaml` → `skillctl apply` → commit registry. Same day — no “fix later.”

### New skill checklist

| If… | Then… |
|-----|--------|
| Personal / multi-repo / agent-agnostic | Bucket **A** — create under `kimi-code/skills/<name>/`; add to registry |
| Only meaningful in one product | Bucket **B** — create under that product’s `.agents/skills/`; optional registry note only |
| Product CLI workflow used from many CWDs | Bucket **B2** — create under product; add registry entry with `install:` into this catalog + `~/.grok/skills` → `skillctl apply` |
| Skill moved between repos | Update registry `canonical` → `apply` → `doctor` |

### Optional cadence

- After any skill move or machine restore: `skillctl apply && skillctl doctor`
- Monthly: `inventory-skills.py --check` and skim multi-real output
- SwiftBar / launchd weekly-seo jobs do **not** embed skill paths; they rely on this install plane. If doctor is red, scheduled `/weekly-seo` from non-pageseeds CWDs will fail to load the skill.

---

## Layout in this repo

| Repo path | Live install path | Contents |
|-----------|-------------------|----------|
| `kimi-code/skills/` | `~/.kimi-code/skills` → **symlink** | Universal skills (**A**) + **B2 catalog links** |
| `agents/skills/` | `~/.agents/skills` → **symlink** | Shared agent skills (e.g. browser bridge) |
| `skills-registry.yaml` | — | Machine install contract |

Edits to **A** skill bodies under those directories **are** the live skills. **B2** bodies live in the product repo; only the symlink lives here.

### How harnesses find these skills today

| Harness | Discovery |
|---------|-----------|
| **Kimi Code** | `~/.kimi-code/skills` (symlink) + `<repo>/.kimi/skills`. `merge_all_available_skills = true` in `~/.kimi-code/config.toml`. |
| **Grok Build** | `~/.grok/skills`, repo `.agents`/`.grok`/…, **plus** `[skills].paths = ["~/.kimi-code/skills"]` in `~/.grok/config.toml`. Bundled under `~/.grok/bundled/skills`. |
| **Other** | Claude/Codex/etc. often look under `~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills` — wire to the same roots or leave unused. |

Grok does **not** scan `.github/skills/` by default. Those trees are legacy / product SEO tooling unless a harness is explicitly taught to load them.

---

**Loop contract (labels, queues, handover):** [`docs/github-loop.md`](./docs/github-loop.md). Agents working in this repo: [`AGENTS.md`](./AGENTS.md).

## How to dice the PR orchestrator (multi-repo + multi-agent)

You maintain many product repos and want the **same shipping loop** everywhere, on **Kimi and Grok** (and later other agents). Dice it in three layers — do **not** fork the whole loop per repo or per agent.

```text
┌─────────────────────────────────────────────────────────────┐
│  Layer 1 — Universal loop skill (this repo)                 │
│  pr-orchestrator-generic                                    │
│  • host detection (Kimi vs Grok tool map)                    │
│  • implement → draft PR → review + verify ×3 → ship gate    │
│  • mark ready                                               │
│  • no product paths, no real-user QA, no monorepo secrets   │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│  Layer 2 — Loop profile (profiles/<product>.env)            │
│  • REPO / REPO_DIR / labels / board / auto-merge flags      │
│  • ORCH_SKILL= which skill the unattended loop invokes      │
│  Shared by pr-loop + scope-loop                             │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│  Layer 3 — Repo contract (lives IN the product repo)        │
│  AGENTS.md + ship docs                                      │
│  • ship gate command (test:all / test:gate / …)             │
│  • safety rules, ports, env files                           │
│  Optional thick overlay skill ONLY when generic is not enough│
│  e.g. pr-orchestrator (call-analyzer): UI gate + real-user QA│
└─────────────────────────────────────────────────────────────┘
```

### What goes where

| Concern | Put it here | Why |
|---------|-------------|-----|
| Review max 3, draft PR, thermonuclear baseline, dual host tools | **`pr-orchestrator-generic`** | Same on every repo/agent |
| Unattended Ready-column runner, multi-product | **`profiles/*.env` + `pr-loop`** | Board/path only — not skill prose |
| “How do we verify before ship?” | **Product `AGENTS.md`** | Generic already reads this for ship-gate resolution |
| Dev-stack ports, Playwright UI gate, real-user QA scripts, blast-radius emails | **Call-analyzer thick skill** (`pr-orchestrator`) *or* docs the skill loads | Product-specific; would poison the generic skill |
| Coffee / pageseeds / tx quirks | Thin profile + `AGENTS.md`; thick skill only if gates are large | Avoid a skill per product by default |

### Recommended usage

| Repo | Interactive / loop skill | Notes |
|------|--------------------------|--------|
| **call-analyzer** (critical) | `/pr-orchestrator` (thick, dual-host) | Profile sets `ORCH_SKILL=/pr-orchestrator`, `ORCH_AUTO_MERGE=0`. Single file in this repo; Grok loads it via `[skills].paths`. |
| **pageseeds-app, tx, coffee, others** | `/pr-orchestrator-generic` | Profile points at generic; ship gate from `AGENTS.md` / `test:gate`. |
| **New product** | Start with **generic only** | Add profile via `pr-loop-setup`. Promote a thick skill only if you grow extra gates that cannot live in docs. |

### What we are *not* doing

- **Not** “instruction path only in the repo, no skill” for the full loop — the loop is long, multi-agent, and unattended; a skill is the right package.
- **Not** hardcoding call-analyzer QA into generic — that breaks other products and bloats every run.
- **Not** maintaining separate Kimi vs Grok forks of the same product skill — both hosts share one file with a tool map.

### Orchestrator status

- [x] Dual-host `pr-orchestrator` (call-analyzer thick) in `kimi-code/skills/`
- [x] Removed `~/.grok/skills/pr-orchestrator` fork
- [x] Cleared Grok `[skills].ignore` for pr-orchestrator
- [ ] Optional rename later: `pr-orchestrator` = core, `pr-orchestrator-call-analyzer` = thick (only if names confuse)
- [x] `ORCH_SKILL` in profiles remains the unattended switch

---

## Skills in this repo (canonical list)

### `kimi-code/skills/` (universal)

| Skill | Purpose |
|-------|---------|
| `pr-orchestrator-generic` | **Default multi-repo loop.** Dual-host (Kimi + Grok). Profiles + `pr-loop` for unattended. |
| `pr-orchestrator` | **Call-analyzer thick overlay** (dual-host): UI gate, real-user QA, monorepo `pnpm test:all` + dev stack. |
| `thermo-nuclear-code-quality-review` | Strict maintainability review baseline used by orchestrators. |
| `feature-spec-to-github-issue` | Bug/UX/feature → structured GitHub issue with root-cause analysis. |
| `gh-scope-issue` | Second-pass issue scoping: codebase dive → build-ready spec; labels scoping → ready. |
| `gh-ticket-hygiene` | Board hygiene: close healed/duplicate/terminal trackers; label fixes. |
| `betterstack-error-triage` | BetterStack errors/incidents → GitHub issues when new. |
| `posthog-weekly-insights` | Weekly PostHog session + analytics pass; issues only for concrete bugs. (Includes call-analyzer measurement-contract notes — keep honest or split overlay later.) |
| `email-ops` | Himalaya IMAP email read/search + daystoexpiry client-bug triage. |
| `storage-sweep` | Guided macOS dev storage cleanup + session pruner scripts. |
| `weekly-seo` | **Symlink** → `pageseeds-app/.agents/skills/weekly-seo` (product-owned). |

Also present (cleanup candidates): `*.skill` zip packages next to some skills — legacy packaging, not needed for day-to-day discovery.

### `agents/skills/`

| Skill | Purpose |
|-------|---------|
| `kimi-webbridge` | Control the user’s real browser sessions. |

---

## Bootstrap on a new machine

```bash
gh repo clone fstrauf/kimi-skills ~/01_code/kimi-skills

# Kimi user skills
ln -sfn ~/01_code/kimi-skills/kimi-code/skills ~/.kimi-code/skills

# Shared agents skills
ln -sfn ~/01_code/kimi-skills/agents/skills ~/.agents/skills
```

### Grok bridge (already set on this machine)

In `~/.grok/config.toml`:

```toml
[skills]
paths = ["~/.kimi-code/skills"]
# Temporary until pr-orchestrator is unified:
# ignore = ["~/.kimi-code/skills/pr-orchestrator"]
```

Prefer **Grok `paths`** (or a single shared tree) over maintaining a second full copy under `~/.grok/skills`.

Optional install script (when added): `./scripts/install-symlinks.sh`.

---

## Machine-wide inventory

A full scan of skill roots on this Mac (as of **2026-07-30**) is in **[INVENTORY.md](./INVENTORY.md)**.

Headline numbers:

| Metric | Count |
|--------|------:|
| Skill instances (directories with `SKILL.md`) | ~116 |
| Unique skill names | ~62 |
| Roots scanned | ~21 |

That includes: this repo, `~/.grok/skills`, Grok bundled skills, product-repo trees (`.kimi` / `.agents` / `.grok` / `.github`), and legacy `~/.kimi`, `~/.claude`, `~/.codex` leftovers.

---

## Consolidation plan

Work top-down. Do not mass-delete product `.github/skills` until you confirm nothing still invokes them.

### Phase 0 — Agree ownership (no file moves)

| Skill | Recommended bucket | Canonical path |
|-------|-------------------|----------------|
| `pr-orchestrator-generic`, `gh-scope-issue`, `gh-ticket-hygiene`, `feature-spec-to-github-issue`, `thermo-nuclear-code-quality-review`, `storage-sweep` | **A Universal** | `kimi-skills/kimi-code/skills/…` |
| `betterstack-error-triage`, `email-ops` | **A Universal** (identical project copies today) | same |
| `posthog-weekly-insights` | **A Universal** base; product funnel rules either in global (if shared) or thin **B** overlay | global is *ahead* of project copies |
| `pr-orchestrator` | **A Universal** with dual tool-map, *or* keep Kimi + Grok forks explicitly documented | resolve Phase 1 |
| `weekly-seo`, `weekly-seo-status`, `weekly-seo-continue`, `seo-program-review`, `video-clip`, `reddit-engage` | **B2** PageSeeds multi-tenant | `pageseeds/.agents/skills` (+ registry install links) |
| `coffee-data`, `pr-orchestrator-coffee` | **B Product** | `nz-coffee-hub` |
| SEO / sentiment / distributed-workflows under `.github/skills` | **B Product** or archive | call-analyzer / fiAnalyst / tx (often duplicated) |
| `help`, `imagine`, `create-skill`, `check-work`, Grok bundled set | **C Harness** | leave under `~/.grok` / bundled |

### Phase 1 — Fix split brain (high value)

1. **`pr-orchestrator`**
   - Today: Kimi copy in this repo (516 lines, Kimi tools: `Bash`/`Agent`/…).
   - Grok copy at `~/.grok/skills/pr-orchestrator` (512 lines, Grok tools: `run_terminal_command`/`spawn_subagent`/…).
   - Grok config **ignores** the kimi path so Grok never runs the Kimi file.
   - Options (pick one):
     - **(Preferred)** Merge into one skill with a short “Tool map: Grok vs Kimi” section (generic orchestrator already aims at dual harness).
     - Or rename: `pr-orchestrator` (Kimi) + `pr-orchestrator-grok`, and drop the ignore hack.
     - Or deprecate both in favor of `pr-orchestrator-generic` only.

2. **`weekly-seo` family (B2)**
   - Canonical: `pageseeds/.agents/skills/weekly-seo` (and continue/status/program-review).
   - Install: managed by `skills-registry.yaml` → `skillctl apply` (catalog + `~/.grok/skills` links).
   - Do **not** point at `pageseeds-app` (skills removed; repo is docs/CLI install only).

3. **`gh-ticket-hygiene`**
   - Content is identical between `~/.grok/skills` and this repo.
   - Action: remove Grok copy; rely on `paths = ["~/.kimi-code/skills"]`.

### Phase 2 — Remove redundant project copies

These product-repo copies match (or lag) universal skills and create false “only works in this repo” / stale-version bugs:

| Location | Skills | Action |
|----------|--------|--------|
| `call-analyzer/.kimi/skills/` | `betterstack-error-triage`, `email-ops` (identical), `posthog-weekly-insights` (**40 lines behind** global) | Delete after confirming Kimi user skills load in that repo (`merge_all_available_skills`). Refresh or delete posthog copy deliberately. |
| `fiAnalyst/.kimi/skills/` | same three | same |

If a product needs call-analyzer-specific PostHog dashboard IDs, keep a **thin** project skill (e.g. `posthog-call-analyzer`) that points at `MEASUREMENT_CONTRACT.md`, and leave the weekly workflow universal.

### Phase 3 — Retire legacy trees

| Path | Action |
|------|--------|
| `~/.kimi/skills/` | Old Kimi home; duplicates `feature-spec…`, thermo-nuclear; has orphan `gh-pick-and-start-issue`. Archive or delete after confirming Kimi Code only uses `~/.kimi-code`. |
| `~/.claude/skills`, `~/.codex/skills`, `~/.config/agents/skills` | Extra `kimi-webbridge` copies; replace with symlinks to `~/.agents/skills/kimi-webbridge` or delete if unused. |
| `*.skill` zip files next to live skills | Delete if unused by any installer. |
| `~/.grok/skills/{code-review,create-skill,imagine}` | Match bundled; safe to drop user copies if bundled always loads. |
| `~/.grok/skills/weekly-seo*` | Symlink to `pageseeds/.agents/...` via `skillctl apply` (not pageseeds-app). |

### Phase 4 — `.github/skills` decision

`call-analyzer` and `fiAnalyst` each carry ~15 SEO/PostHog/sentiment skills under `.github/skills` (mostly **identical twins**). `tx` and `pageseeds-app` have smaller sets.

These are **not** on Grok’s default scan path. Options:

- **Keep** if Claude/Codex/older automation still loads `.github/skills` for SEO ops — but dedupe fiAnalyst ↔ call-analyzer (submodule, shared package, or “SEO lives only in call-analyzer”).
- **Migrate** active ones into `.agents/skills` in the repo that owns the product.
- **Archive** (e.g. `skills.deprecated` like `automation/`) if replaced by pageseeds-cli / universal skills (`weekly-seo`, `reddit-engage`).

### Phase 5 — Hygiene going forward

1. **New universal skill** → `kimi-code/skills/<name>/` + registry entry; never `cp` into product repos.
2. **New B2 skill** → product `.agents/skills` + registry `install` list → `skillctl apply`.
3. **New product-local skill** → only that product’s `.agents/skills`; no global install unless it becomes B2.
4. **Moved skill** → edit registry `canonical` the same day → `apply` → `doctor`.
5. Avoid `ignore = [...]` in Grok config except as a short-lived migration aid.
6. Prefer `skillctl doctor` over hand-maintained `INVENTORY.md` snapshots.

### Progress

```text
[x] Document three-bucket model + B2 multi-tenant
[x] skills-registry.yaml + scripts/skillctl.py (apply / verify / doctor)
[x] inventory-skills.py --check (broken links + multi-real)
[x] Fix weekly-seo* / seo-program-review install links → pageseeds (not pageseeds-app)
[x] Dedup reddit-engage to pageseeds canonical + install links
[x] Dual-host call-analyzer pr-orchestrator; drop Grok fork + ignore hack
[ ] Clean ~/.kimi/skills + leftover kimi-webbridge installs elsewhere
[ ] Triage .github/skills SEO set (keep one home / archive)
[ ] Optional: launchd/timer for weekly skillctl doctor notification
```

---

## Related config on this machine

| File | Role |
|------|------|
| `~/.kimi-code/config.toml` | `merge_all_available_skills = true` |
| `~/.grok/config.toml` | `[skills] paths`, `ignore` |
| `~/.grok/docs/user-guide/08-skills.md` | Grok skill discovery rules |

---

## Why a skill might be “missing” in a repo

1. It only exists under another harness’s user dir (`~/.grok/skills` vs `~/.kimi-code/skills`).
2. It only exists as a **project** skill in a different product repo.
3. It lives under `.github/skills`, which Grok does not scan by default.
4. Name collision + `ignore` / priority hides the version you expect.
5. Stale project copy exists but is outdated — feels “broken,” not “missing.”

Use the three-bucket table first; then check [INVENTORY.md](./INVENTORY.md) for every path that name appears on.
