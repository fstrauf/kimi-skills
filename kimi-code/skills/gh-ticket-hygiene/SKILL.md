---
name: gh-ticket-hygiene
description: >
  Repo ticket hygiene pass: scan open GitHub issues for already-healed,
  duplicate, terminal trackers, and stale needs-input; skip pr-loop
  (ready/agent-*) and pure unscoping inventory owned by scope-loop; propose
  closes and label fixes; never close without confirmation. Use when the user
  runs /gh-ticket-hygiene, /ticket-hygiene, "ticket hygiene", "clean up
  issues", "hygiene pass", or asks to triage open tickets for duplicates and
  stale work.
---

# GitHub Ticket Hygiene

**Third pass in the issue pipeline** — not scoping, not shipping.

```text
scope-loop (gh-scope-issue)  →  refine unscoping → ready
pr-loop    (pr-orchestrator) →  ready → implement → land
hygiene    (this skill)      →  close noise: healed / dupe / terminal trackers / stale needs-input
```

| Pass | Skill | Question |
|------|--------|----------|
| Scope | `gh-scope-issue` | What should we *build*? |
| Ship | `pr-orchestrator` / generic | Build and land it |
| **Hygiene (this)** | `gh-ticket-hygiene` | What should we *stop tracking*? |

**Never implement product code.** Issue metadata + comments only. Optional: open a small follow-up ticket when a tracker closes with deferred work (only if user asks).

---

## Mental model

You are the **janitor for the issue board**, not a builder.

Typical wins (from real sessions):
- One-user canary already green after re-sync → **close as healed**
- Tracker whose children all shipped → **close; record deferrals**
- Original bug ticket superseded by fuller build ticket → **close as duplicate**
- `needs-input` whose answer landed in a later comment / PR → **clear label or close**
- Close condition in body already met (PR merged, AC checked) → **close**

Typical non-work:
- Labeled `ready` / `agent-working` / `agent-failed` → **skip** (pr-loop owns)
- Open, not scoped, not `needs-input`, no close/dupe/healed signal → **skip** (scope-loop owns)
- Tracking epics with open children → **report only**, do not close

---

## Invocation

```
/gh-ticket-hygiene
/gh-ticket-hygiene call-analyzer
/gh-ticket-hygiene --repo fstrauf/call-analyzer
/ticket-hygiene --limit 40
```

Resolve repo:
1. Explicit `--repo owner/name` or profile name (`call-analyzer`, `pageseeds`, …)
2. Else `pr-orchestrator-generic` profile if user named one
3. Else `gh repo view --json nameWithOwner` from cwd

Optional flags (user intent, not necessarily CLI):
- **Report only** (default) — classify + propose; **no closes**
- **Apply approved** — after user confirms a batch, execute closes/label edits
- **Focus** — only `needs-input`, or only numbers the user listed

---

## Hard limits

1. **No product code**, no SQL mutations, no PR merges.
2. **Never close** an issue without explicit user confirmation for that issue or an approved batch list.
3. **Never add `ready`** — that is scope-loop / human enqueue only.
4. **Never remove `agent-working` / `agent-failed`** — pr-loop owns those.
5. **Never re-scope** full issue bodies (that is `gh-scope-issue`). Hygiene may leave a short comment + label tweak.
6. Prefer **one close comment** that records evidence (QA green date, superseding issue, merged PR).

---

## Pipeline labels (REST only — same as other skills)

| Label | Hygiene behavior |
|--------|------------------|
| `ready` | **Skip** — in ship queue |
| `agent-working` / `agent-failed` | **Skip** — pr-loop machinery |
| `scoping` | **Skip** unless also `needs-input` or body says delete/dupe/healed |
| `needs-input` | **Primary queue** — re-verify if still blocked |
| `blocked` | Re-check blocker; if gone, comment + propose `-blocked` (or keep needs-input) |
| `duplicate` | If still open with clear target → propose close |
| Epic title (`Epic:` / `[Epic]`) | **Report only** unless all children closed and user wants epic close |

Board/Projects: **do not** drive status via `gh project` unless the user explicitly asks.

---

## Who is in the hygiene queue?

**INCLUDE** open issues that match any of:

1. Label `needs-input` or `blocked` or `duplicate`
2. Title/body markers: `tracker:`, `delete candidate`, `already green`, `already healed`, `duplicate of #`, `superseded by #`, `close this`, `close when`, `disposition`
3. Body **close condition** / acceptance checkboxes mostly done, remaining items are “owner close”
4. Explicit comment from scope pass: “recommend close”, “delete candidate”, “duplicate of #N”
5. Parent trackers whose **ship children are all closed** (verify with `gh issue view` on children)
6. User-listed issue numbers

**EXCLUDE** (default):

1. Labels: `ready`, `agent-working`, `agent-failed`
2. Pure unscoping inventory: open, no `needs-input`/`blocked`/`duplicate`, no hygiene markers above, title not tracker/epic complete → leave for scope-loop
3. Issues updated by pr-loop in the last few minutes with `agent-working` (already excluded by label)

Cap: process up to **40** candidates per pass (or user `--limit`). If more, prioritize: `needs-input` → P0/P1 → oldest `needs-input` → trackers.

---

## Workflow

### Phase 0 — Context

1. Resolve `REPO` (and optional local checkout for premise checks).
2. Snapshot open issues:

```bash
gh issue list --repo "$REPO" --state open --limit 100 \
  --json number,title,labels,updatedAt,createdAt,author,milestone
```

3. Filter to hygiene candidates (INCLUDE/EXCLUDE above).
4. Todos: Inventory · Classify · Verify hot ones · Report · (Apply if approved).

### Phase 1 — Inventory table

Build a table for the user:

| # | Title | Labels | Bucket | Proposed action | Confidence |
|---|-------|--------|--------|-----------------|------------|

**Buckets:**

| Bucket | Meaning |
|--------|---------|
| `HEALED` | Premises false now; canary green / data fixed / no residual work |
| `DUPLICATE` | 100% covered by another open or closed ship ticket |
| `TRACKER_DONE` | Children shipped/declined/deferred-with-link; close condition met |
| `STALE_NEEDS_INPUT` | `needs-input` but decision already made or no longer needed |
| `STILL_BLOCKED` | Real open question or external blocker remains |
| `ACTIVE_SHIP` | Has open PR / agent-working (should have been skipped; note if mislabeled) |
| `LEAVE_FOR_SCOPE` | Unscoped real work — not hygiene |
| `LEAVE_FOR_PR_LOOP` | `ready` / in flight |
| `NEEDS_USER` | Ambiguous — ask, do not invent |

### Phase 2 — Verify (only for close/label proposals)

For each `HEALED` / `DUPLICATE` / `TRACKER_DONE` / `STALE_NEEDS_INPUT` candidate:

1. Read full issue: `gh issue view N --json title,body,labels,comments,state`
2. Check linked PRs: `gh pr list --search "N" --state all`
3. If body claims “already green” / QA — **re-verify when cheap**:
   - Prefer evidence already in comments with dates
   - Optional live check only if repo has a one-command canary and user environment allows (e.g. `qa_pipeline_integrity.py --email … --ci`) — never mutate DB
4. For duplicates: open the superseding issue; confirm AC covers this ticket’s scope
5. For trackers: verify each child number’s `state` (CLOSED/OPEN)
6. Record **one-line evidence** per proposal (PR number, child list, QA date, comment quote)

Do **not** deep-dive the whole codebase like `gh-scope-issue` unless verification requires it.

### Phase 3 — Report to user (mandatory gate)

Present:

1. **Summary counts** by bucket  
2. **Proposed closes** (numbered list with one-line reason + evidence)  
3. **Proposed label fixes** (e.g. remove `needs-input` if still open for real work)  
4. **Still blocked / needs your call** (questions only)  
5. **Skipped** counts: ready / agent-* / leave-for-scope  

Ask explicitly:

```text
Approve closes for: #A, #B, #C?
Any to keep open? Any to inspect deeper?
```

Do **not** close until the user answers.

### Phase 4 — Apply (only after approval)

For each approved close:

```bash
gh issue close N --repo "$REPO" --comment "$(cat <<'EOF'
…evidence-based close reason…
EOF
)"
```

Close comment templates:

**Healed**
```markdown
Closing as already healed — no residual work.

**Evidence:** … (QA date / 0 violations / repair dry-run empty / re-sync date)

No product code or ops `--execute` needed. If this regresses, open a **new** issue rather than reusing this historical ticket.
```

**Duplicate**
```markdown
Closing as **duplicate of #M**.

Full build/tracking contract lives there. No unique residual on this ticket — do not implement against #N.
```

**Tracker done**
```markdown
Closing tracker — disposition terminal for ship work.

**Shipped:** #… / PR …
**Declined:** …
**Deferred:** … (blocked on #…; open a new ticket when unblocked — do not reopen this tracker as a ship unit)
```

Label-only fixes (if approved):

```bash
gh issue edit N --repo "$REPO" --remove-label needs-input
# optional: gh issue edit N --add-label duplicate
```

Never add `ready` from this skill.

### Phase 5 — Optional follow-ups

Only if user asks:
- File deferred child (“remove bare-legacy fallback, blocked on #988”)
- Comment on superseding issue “hygiene closed #N as dupe”

---

## Classification heuristics (fast)

### HEALED
- Body/comments: “already green”, “delete candidate”, “0 FAIL”, “nothing to do”
- Acceptance checkboxes for technical work are `[x]`; only “owner closes” remains
- Linked repair/ops plan obsolete because re-sync or merge fixed data

### DUPLICATE
- Comment: “superseded by #M”, “implement under #M”, “duplicate of #M”
- Same root cause + same fix path as an open `ready` / `agent-working` / open PR issue
- Original find ticket vs fuller residual ticket (prefer single tracker = the fuller one)

### TRACKER_DONE
- Title starts with `tracker:` or body is disposition table
- All ship children CLOSED; declined rows recorded; deferred rows either have a follow-up issue or are explicitly “record on this tracker”
- Close condition paragraph satisfied

### STALE_NEEDS_INPUT
- Labeled `needs-input` but latest scope comment says “recommend close” / “not for pr-loop”
- Question answered in a later human comment
- Waiting only on “please close when convenient”

### STILL_BLOCKED
- Real missing product decision, missing credentials, or open parent ops ticket with no evidence of completion
- Keep open; optionally refresh comment with “still blocked on X as of YYYY-MM-DD”

### NEEDS_USER
- Two plausible superseding tickets
- Healed claim is old and no cheap re-verify
- Epic with mixed open/closed children and unclear epic policy

---

## Anti-patterns (fail the skill)

- Closing without user confirmation  
- Implementing a fix “while cleaning”  
- Adding `ready` so pr-loop picks junk  
- Re-scoping every open issue (that is scope-loop)  
- Touching `agent-working` issues  
- Closing epics that still have open children without asking  
- Running fleet-wide ops `--execute` as “hygiene”  
- Filing drive-by product PRs  

---

## Report format (final message)

```markdown
## Ticket hygiene — {repo} ({date})

### Counts
- Candidates examined: N
- Propose close: N (healed / dupe / tracker)
- Still blocked / needs you: N
- Skipped (pr-loop / scope-loop): N

### Propose close
| # | Bucket | Why | Evidence |
|---|--------|-----|----------|

### Needs your call
| # | Question |
|---|----------|

### Skipped (sample)
…

**Next:** reply with issue numbers to close, or “close all proposed”.
```

After apply: list closed URLs + any label edits.

---

## Relationship to other skills

| If you need… | Use |
|--------------|-----|
| Rewrite body into build contract | `gh-scope-issue` |
| Implement + PR | `pr-orchestrator` / `pr-orchestrator-generic` |
| Close noise / dupes / healed / trackers | **this skill** |
| File a new bug from a report | `feature-spec-to-github-issue` |

Profiles: same `REPO` as `pr-orchestrator-generic/profiles/<name>.env` when the user names a profile.

---

## Smoke checklist (skill is working)

1. On a repo with mixed open issues, inventory includes `needs-input` and excludes `ready`.  
2. At least one proposal cites evidence (PR #, child states, or comment).  
3. No `gh issue close` runs before user approval.  
4. After “close all proposed”, close comments are non-empty and point at superseding work or heal evidence.
