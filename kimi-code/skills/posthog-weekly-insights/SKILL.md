---
name: posthog-weekly-insights
description: |
  Weekly analysis of PostHog session recordings, product analytics, and error tracking to surface
  user issues, behavioral patterns, drop-offs, and actionable product conclusions. Produces a
  concise report to the user, and creates GitHub issues only for concrete, reproducible bugs.
triggers:
  - Weekly product review (recommended: Monday morning, covering the previous 7 days)
  - On-demand before product/design planning sessions
  - After a major feature release to observe adoption and friction
---

# PostHog Weekly Insights

## Purpose

Replace dashboard hunting with a structured weekly review. This skill pulls PostHog session
recordings, trends, funnels, and error tracking data, then synthesizes:

- What users actually did last week
- Where they got stuck, dropped off, or encountered errors
- Patterns that suggest product, UX, or instrumentation problems
- Prioritized conclusions and next steps

The output is a narrative report to the user. GitHub issues are created only for concrete,
reproducible bugs — never for vague observations.

## What this skill does

1. Confirms the project's event taxonomy via the data schema.
2. Pulls the previous 7 days of session recordings, prioritizing high-friction signals.
3. Pulls core usage trends and key funnel drop-offs.
4. Pulls PostHog error-tracking issues (if enabled).
5. Synthesizes patterns and writes a structured weekly report.
6. Files GitHub issues for any reproducible bugs found in recordings or error tracking.

## Tools

- PostHog MCP tool: `mcp__posthog__exec`
  - `call read-data-schema {"query": {"kind": "events"}}`
  - `call read-data-schema {"query": {"kind": "event_properties", "event_name": "..."}}`
  - `call query-session-recordings-list`
  - `call query-trends`
  - `call query-funnel`
  - `call query-error-tracking-issues-list` (if error tracking is enabled)
- GitHub CLI: `gh issue create` (only for concrete bugs)

## Configuration

No persistent config file is required. Default scope:

- Time window: previous 7 days (`date_from: "-7d"`)
- Exclude internal/test users: `filter_test_accounts: true`
- Primary focus: webapp behavior, auth flows, portfolio/features flows

If the user wants a different window or a specific funnel, they can state it at invocation.

## Workflow

### 1. Discover events and properties

Always confirm the taxonomy first. Do not guess event names.

```
mcp__posthog__exec: command="call read-data-schema {\"query\":{\"kind\":\"events\"}}"
```

Look for events related to:

- Page views: `$pageview`, `$pageleave`
- Auth: `signed up`, `signed in`, `signed out` (or equivalent)
- Portfolio/features: events around portfolio view, screener usage, trade ingestion
- Errors/exceptions: `$exception` (if error tracking is enabled)

If you need property values for filters:

```
mcp__posthog__exec: command="call read-data-schema {\"query\":{\"kind\":\"event_property_values\",\"event_name\":\"$pageview\",\"property_name\":\"$pathname\"}}"
```

### 2. Pull session recordings

Get recordings with friction signals from the last 7 days, excluding internal users.

**High-friction recordings (console errors):**

```json
{
  "date_from": "-7d",
  "filter_test_accounts": true,
  "properties": [{ "key": "console_error_count", "operator": "gt", "type": "recording", "value": 0 }],
  "order": "console_error_count",
  "limit": 50
}
```

**Long but low-activity recordings (possible confusion):**

```json
{
  "date_from": "-7d",
  "filter_test_accounts": true,
  "properties": [
    { "key": "duration", "operator": "gt", "type": "recording", "value": 120 },
    { "key": "activity_score", "operator": "lt", "type": "recording", "value": 30 }
  ],
  "order": "duration",
  "limit": 30
}
```

**Rage-click sessions (possible broken UI):**

```json
{
  "date_from": "-7d",
  "filter_test_accounts": true,
  "properties": [{ "key": "event", "operator": "exact", "type": "event", "value": "$rageclick" }],
  "order": "start_time",
  "limit": 30
}
```

Deep-link to any notable recording with:

```
https://<posthog_base_url>/replay/<recording_id>
```

### 3. Pull usage trends

Use trends to understand last-week volume vs the prior week.

**Active users and pageviews:**

```json
{
  "kind": "TrendsQuery",
  "series": [
    { "kind": "EventsNode", "event": "$pageview", "math": "dau" },
    { "kind": "EventsNode", "event": "$pageview", "math": "unique_users" }
  ],
  "dateRange": { "date_from": "-14d" },
  "interval": "day",
  "filterTestAccounts": true,
  "compareFilter": { "compare": true }
}
```

**Top pages by pathname:**

```json
{
  "kind": "TrendsQuery",
  "series": [{ "kind": "EventsNode", "event": "$pageview", "math": "total" }],
  "dateRange": { "date_from": "-7d" },
  "interval": "day",
  "breakdownFilter": { "breakdowns": [{ "property": "$pathname", "type": "event" }] },
  "filterTestAccounts": true
}
```

### 4. Pull key funnels

Identify the biggest drop-off. Common funnels for this product:

- Sign-up → first portfolio link / first data import
- Portfolio view → feature usage (screener, options chain, etc.)
- Any onboarding step with known steps

Example funnel command:

```json
{
  "kind": "FunnelsQuery",
  "series": [
    { "kind": "EventsNode", "event": "$pageview", "properties": [{ "key": "$pathname", "type": "event", "value": "/app", "operator": "icontains" }] },
    { "kind": "EventsNode", "event": "feature used" }
  ],
  "dateRange": { "date_from": "-7d" },
  "funnelsFilter": { "funnelVizType": "steps" },
  "filterTestAccounts": true
}
```

Use event names discovered in step 1. Do not invent events.

### 5. Pull PostHog error tracking (if enabled)

```
mcp__posthog__exec: command="call query-error-tracking-issues-list {}"
```

If error tracking is not enabled or returns nothing, note that in the report and rely on
session `console_error_count` instead.

### 6. Synthesize the weekly report

Produce a structured markdown report with these sections:

```markdown
# PostHog Weekly Report — <start_date> to <end_date>

## Executive Summary

- Total unique users: <N> (vs prior week <+/-X%)
- Total sessions: <N>
- Recordings with console errors: <N>
- Top drop-off funnel: <funnel> at <step> (<X>% lost)
- New error-tracking issues: <N>

## User Activity Highlights

### Volume
- DAU trend: <brief description>
- Top pages: <list top 5 with % of total>
- Notable changes WoW: <what moved>

### Engagement Patterns
- Average session duration / activity score trend
- Most-used features (from events discovered in step 1)
- Return vs new-user mix if available

## Friction & Issues Found

### From session recordings
| Recording | Signal | Page | Hypothesis | Link |
|---|---|---|---|---|
| `<id>` | console error / rage click / long inactive | `/app/...` | <one-line guess> | [replay](https://.../replay/<id>) |

### From funnels
| Funnel | Worst step | Drop-off | Hypothesis |
|---|---|---|---|
| sign-up → first import | Step 2 | 45% | form too long / unclear CTA |

### From error tracking
| Issue | Count | Affected users | First seen |
|---|---|---|---|
| `<issue name>` | <N> | <N> | <date> |

## Conclusions & Recommendations

1. <conclusion tied to a specific metric or recording>
2. <conclusion>
3. <conclusion>

## Action Items

- [ ] <specific task> — owner surface / priority
- [ ] <specific task>

## Bugs Filed

- #<num> — <title> (only for reproducible bugs)
```

### 7. File GitHub issues for concrete bugs only

Create an issue only when:

- A session recording shows a reproducible UI bug (e.g. button does nothing, infinite spinner,
  crash after a clear sequence), **and**
- You can describe the reproduction path, or
- A PostHog error-tracking issue maps to a clear stack trace in repo code.

Use the same structured body as the `betterstack-error-triage` skill, but prefix the title with
`[UX]` or `[Analytics]` if it's not a backend bug.

Do **not** file issues for:

- Generic drop-offs without a hypothesis
- One-off user confusion
- Missing instrumentation (note as recommendation instead)

## Guardrails

- **Schema first:** never query an event name taken from the prompt. Confirm via
  `read-data-schema`.
- **No PII in reports:** use counts and anonymized session IDs; never paste emails, names, or
  account details.
- **Correlation, not causation:** frame conclusions as "suggests" or "coincides with" unless a
  recording proves the causal chain.
- **Do not over-interpret one session:** a single confused user is an anecdote; look for 3+
  similar sessions before calling it a pattern.
- **Use 7-day windows by default.** Avoid daily noise unless asked.
- **Link recordings correctly:** `{posthog_base_url}/replay/{id}`, never
  `/replay/home?sessionRecordingId={id}`.

## When NOT to use this skill

- For real-time incident response (use `betterstack-error-triage` instead).
- For SEO or marketing analytics (use the existing `posthog-product-insights` or
  `posthog-single-site` skill).
- When the user only wants a single metric pulled — use `mcp__posthog__exec` directly.
