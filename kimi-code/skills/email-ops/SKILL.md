---
name: email-ops
description: >
  Read and search Florian's email on this machine via the himalaya CLI (IMAP).
  Covers listing/filtering envelopes, reading bodies, and the daystoexpiry.com client-bug
  triage flow: find report emails, classify, dedup against GitHub, file issues in
  fstrauf/call-analyzer, and mark processed mail with Gmail labels.
  Use whenever the user asks to check, list, search, or triage email — e.g. "check my email",
  "any new mail", "search mail for …", client-bug triage of daystoexpiry.com mail, or an
  on-demand support-mail sweep.
---

# Email Ops (himalaya)

## Purpose

Generic, agent-friendly email access on this machine. Backed by `himalaya` v1.2 (IMAP against
`imap.gmail.com`, account `f.strauf@gmail.com`). **Read-only except triage labels** (see State
model): no SMTP/send backend is configured, and all reads use `--preview` so unread state is never
touched.

## Setup (already done — reference for repair)

- Config: `~/Library/Application Support/himalaya/config.toml`
- Password: macOS Keychain item, retrieved via
  `security find-generic-password -s himalaya-gmail -a f.strauf@gmail.com -w`
  (same Gmail app password the `consult` project uses; regenerate at myaccount.google.com/apppasswords)
- If auth fails: verify the keychain item exists; recreate with
  `security add-generic-password -U -a f.strauf@gmail.com -s himalaya-gmail -w "<app-password>"`

## Command reference

JSON goes to **stdout**; log/WARN lines go to **stderr** — never merge them (`2>/dev/null`, not `2>&1`)
when parsing output.

```bash
# List folders
himalaya folder list

# List/search envelopes (JSON). Query language: from|to|subject|body <pattern>,
# after|before|date <yyyy-mm-dd>, flag <flag>, combined with and/or/not; "order by date desc".
himalaya envelope list -f "[Google Mail]/All Mail" -s 50 -o json \
  to daystoexpiry.com and after 2026-07-10 order by date desc 2>/dev/null

# Read a message body (ALWAYS --preview; never mark Seen)
himalaya message read <ID> -f "[Google Mail]/All Mail" --preview --no-headers 2>/dev/null

# Apply a triage label (= IMAP copy into the label folder; the ONLY permitted write)
# NOTE: TARGET folder is a positional arg (there is no -t flag)
himalaya message copy "agent-triaged" <ID> -f "[Google Mail]/All Mail"
himalaya message copy "agent-triaged/bug-filed" <ID> -f "[Google Mail]/All Mail"

# List already-triaged envelopes (for exclusion)
himalaya envelope list -f "agent-triaged" -s 100 -o json 2>/dev/null
```

Rules:

1. **Never** run `message write/send/reply`, `flag add/remove`, `message delete/move`,
   or `folder purge/create`. The single allowed write is `message copy` into an
   `agent-triaged*` label folder.
2. Envelope IDs are **per-folder IMAP UIDs** — the same message has different IDs in INBOX vs
   All Mail. Always read/label from the same folder you searched.
3. Prefer `[Google Mail]/All Mail` for searches (covers inbound + sent); INBOX only for
   "what's new right now".
4. Use `-o json` for listings; pipe message bodies as plain text.
5. `-s <n>` caps page size; keep listings ≤ 50 envelopes.

## State model: what has been processed

Processed-state lives **on the messages as Gmail labels**, not in a local file:

- `agent-triaged` — applied to EVERY email a triage run has scanned (bug or not). This folder is
  the exclusion set: anything in it is skipped by future runs.
- `agent-triaged/bug-filed` — ADDITIONALLY applied when a GitHub issue was created, so the user
  can see in Gmail which mails became tickets. (Not part of the exclusion set — the parent label
  already covers exclusion.)

A small local file keeps what labels cannot store — the message→issue mapping and the last-run
timestamp: `~/.local/state/email-triage/processed.json`
`{ "last_run": "<date>", "issues": { "<from>|<date>|<subject>": "<issue-url>" } }`.
If the file is lost, triage still works (labels prevent reprocessing); only the URL mapping is gone.

## Workflow: daystoexpiry.com client-bug triage

Mail to `@daystoexpiry.com` (e.g. `florian@`, `contact@`) is delivered to this Gmail account.
Target repo for tickets: **fstrauf/call-analyzer**.

1. **Fetch candidates** — search All Mail:
   `to daystoexpiry.com and after <date> order by date desc`
   (`<date>` = `last_run` from processed.json, default 7 days back).
2. **Subtract processed** — list folder `agent-triaged`; drop candidates whose
   `from|date|subject` tuple appears there.
3. **Pre-filter** — skip obvious non-bugs by sender/subject (invoices, newsletters, legal notices,
   Discord/verify signups, Resend/SnapTrade ops mail).
4. **Read + classify** — `--preview` read each remaining candidate; classify bug report vs. other.
   Extract: summary, error signature (exact error text/stack), reproduction hints, environment clues.
5. **Dedup vs GitHub** — `gh search issues "<error signature>" -R fstrauf/call-analyzer --state open`.
6. **File the ticket** — for each confirmed, non-duplicate bug, invoke the
   **`feature-spec-to-github-issue` skill** with the email content as the bug report input;
   the issue lands in `fstrauf/call-analyzer`. Add label `client-reported` when the skill/gh call
   supports it; otherwise `gh issue edit <n> -R fstrauf/call-analyzer --add-label client-reported`.
7. **Label everything scanned** — `message copy` every email processed in this run into
   `agent-triaged`; additionally copy the ones that produced an issue into `agent-triaged/bug-filed`.
   If a label folder is missing, create it once with `himalaya folder create "<name>"`.
8. **Update state + digest** — write processed.json, then report: scanned N emails, M bug reports,
   K new issues (URLs), J skipped as duplicates/noise.

Issue creation is outward-facing: in an **interactive session** show the drafted issue and get the
user's go-ahead before invoking the create skill. Applying the `agent-triaged*` labels is part of
every approved triage run and needs no separate confirmation.
