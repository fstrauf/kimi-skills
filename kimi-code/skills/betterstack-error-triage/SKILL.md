---
name: betterstack-error-triage
description: |
  Periodically scan BetterStack (errors + incidents), determine whether each issue is already
  tracked in GitHub, collect actionable context, and create a structured GitHub issue for
  anything new. Use for weekly error sweeps, post-deploy monitoring, or on-demand triage.
triggers:
  - Weekly error sweep (recommended: Monday morning)
  - On-demand when a user reports unexpected behavior
  - Post-deploy after shipping changes to api/, core/, or webapp/
---

# BetterStack Error Triage

## Purpose

Turn raw BetterStack errors and incidents into tracked, actionable GitHub issues. This skill
is the bridge between observability and engineering backlog: it finds new problems, deduplicates
them against existing issues, enriches them with context, and files issues that a human can pick
up without re-investigating.

## What this skill does

1. Pulls recent errors and incidents from BetterStack.
2. Scores/prioritizes them by frequency, affected users, and severity.
3. Searches GitHub for existing issues covering the same error pattern or incident.
4. For genuinely new issues, collects stack traces, environment, release, and affected users.
5. Creates a structured GitHub issue with all context and a proposed next step.
6. For already-tracked issues, optionally adds a comment with new occurrence counts or links.

## Tools

- BetterStack MCP tools:
  - `mcp__betterstack__applications` / `mcp__betterstack__application`
  - `mcp__betterstack__errors` / `mcp__betterstack__error`
  - `mcp__betterstack__incidents` / `mcp__betterstack__incident`
  - `mcp__betterstack__source_fields` (to understand log fields)
  - `mcp__betterstack__query` (for custom log/trace searches)
- GitHub CLI: `gh issue create`, `gh issue list`, `gh issue comment`

## Workflow

### 1. Discover applications and sources

```
mcp__betterstack__applications
mcp__betterstack__sources
```

Identify the relevant app/source(s) for this repo. For fiAnalyst the primary apps are usually the
Next.js webapp and the FastAPI backend.

### 2. Pull recent errors

For each application, list unresolved errors from the last 7 days:

```
mcp__betterstack__errors
  application_id: <id>
  start_time: "now-7d"
  state: "unresolved"
  order_by: "last_seen"
```

Also pull active/ongoing incidents if monitors or alerts are configured:

```
mcp__betterstack__incidents
  team_id: <id>
  from: <7 days ago>
  status: ["ongoing", "acknowledged"]
```

### 3. Prioritize

Rank each error by the following heuristics (higher = file first):

| Signal | Weight |
|---|---|
| `exceptions_count` / frequency high | High |
| `users_count` high | High |
| State is `unresolved` or `reoccurred` | High |
| Affects paid/admin users | High |
| Clear stack trace with repo file paths | Medium |
| New in the last 24h | Medium |
| Marked ignored/resolved in BetterStack | Skip unless reoccurred |

For incidents, prioritize anything currently `ongoing` or unacknowledged.

### 4. Deduplicate against GitHub

For each candidate error, build a search query from:

- Error type + message substring (e.g. `TypeError: Cannot read properties of undefined`)
- File path from stack trace
- BetterStack pattern ID if available

Search GitHub:

```bash
gh issue list --repo <owner>/<repo> \
  --search "<error message fragment>" \
  --state all \
  --limit 20 \
  --json number,title,state,labels,updatedAt
```

Also search by BetterStack pattern ID if you have it:

```bash
gh issue list --repo <owner>/<repo> \
  --search "betterstack pattern <pattern>" \
  --state all
```

Decision rules:

- **Exact match** (same pattern ID or same stack frame + same error text): skip creation; add a
  comment with new occurrence count if the last update is older than 24h.
- **Similar but not identical** (same file, different line/message): create a new issue and
  reference the related one.
- **No match**: create a new issue.

### 5. Collect context

For each new error, gather:

- BetterStack error detail:
  ```
  mcp__betterstack__error
    application_id: <id>
    pattern: <pattern>
  ```
- First seen / last seen timestamps
- Affected environments (`environment` property if available)
- Release versions (`release` property if available)
- Sample stack trace (first frame from repo code)
- Affected user count
- Related incident IDs (if any)

If the error has session/user context in logs, run a targeted query:

```
mcp__betterstack__query
  source_id: <id>
  table: <source_table>
  query: SELECT dt, raw FROM {{source}} WHERE dt >= now() - INTERVAL 7 DAY AND ...
```

### 6. Create the GitHub issue

Use `gh issue create` with the following body structure:

```markdown
## Observed Error

**BetterStack pattern:** `<pattern>`
**Application:** <app name>
**First seen:** <ISO timestamp>
**Last seen:** <ISO timestamp>
**Affected users:** <count>
**Environments:** <env>
**Releases:** <release versions>

### Message
```
<error message>
```

### Stack Trace (first repo frame)
```
<stack trace>
```

## Impact

- <who is affected>
- <frequency>
- <any linked incidents>

## Root Cause Hypothesis

<1-2 sentence best guess based on stack trace and recent changes>

## Next Steps

- [ ] Reproduce or confirm code path
- [ ] Determine fix or mitigation
- [ ] Add regression test if applicable

## Links

- BetterStack error: <link if available>
- Related issues: #<num> (if any)
```

Command:

```bash
gh issue create --repo <owner>/<repo> \
  --title "[Error] <concise error summary>" \
  --label "bug,observability" \
  --body-file /tmp/betterstack_issue_<pattern>.md
```

If the `bug` or `observability` labels do not exist, omit `--label` rather than fail.

### 7. Comment on existing issues (optional)

If an error is already tracked and has new occurrences, add a concise comment:

```bash
gh issue comment <number> --repo <owner>/<repo> \
  --body "Still occurring. <new_count> new exceptions since <date>. Last seen: <timestamp>."
```

## Output Format

At the end of the run, produce a short summary for the user:

```
BetterStack Triage Summary — <date>
====================================

Checked: <N> applications, <M> errors, <K> incidents

New issues created:
- #<num> — <title>
- #<num> — <title>

Already tracked (commented/skipped):
- BetterStack pattern <pattern> → #<num>

Top unresolved risks still without tickets:
- <pattern> — <reason>
```

## Guardrails

- **Never create duplicate issues.** Always search GitHub first by pattern ID and message.
- **Do not commit API keys or DSNs** in issue bodies.
- **Respect PII**: do not paste user emails, IP addresses, or account IDs into public issues.
  Use counts and anonymized identifiers.
- **Only file issues you can describe.** If the error is too vague to act on, leave it in the
  summary as "needs more data" rather than create a useless ticket.
- **Avoid noise:** skip single-occurrence errors unless they involve data integrity, auth, or
  payment flows.
- **Link to BetterStack only via pattern ID** if a public deep link is unavailable.

## When NOT to use this skill

- For infrastructure alerts that are already auto-resolved (e.g. transient CPU spikes).
- For errors the team has explicitly chosen to ignore with a documented reason.
- For issues caused by a user's local environment that cannot be reproduced from the trace.
