---
name: article-draft
description: >
  Turn a finished interview transcript into a publishable article draft in
  Florian's voice, using a deliberately minimal context: the transcript plus the
  voice profile, nothing else. Use when the user runs /article-draft, says
  "draft from the transcript", "turn the conversation into an article",
  "regenerate the draft", or after an /article-conversation session moves to
  drafting. The interview/idea-finding phase is a different skill:
  /article-conversation.
---

# Article Draft (transcript → draft)

The second half of the article workflow. `/article-conversation` finds the idea
and produces a transcript; **this** skill turns a transcript into a draft.

The split exists because of a measured finding (2026-09, copy-roasting test
series): drafts produced with *minimal* context — transcript + voice profile
only — come out cleaner than drafts written with the full ambient stack (skill
workflow + the old Brand Voice contract + repo instructions). More context
diluted the voice. Brand Voice.md has since been merged into the voice profile
and retired; the profile is the single style authority.

## Context discipline (the whole point)

When drafting, read **exactly two files**:

| File | Role |
|------|------|
| The transcript (`voice_tier: transcript`) | The only source of substance |
| `~/01_code/life/raw_data/articles/voice-profile.md` | The only style authority |

Do **not** read AGENTS.md, other articles, or "similar pieces
for rhythm". The voice profile already encodes everything those were consulted
for, measured from the gold corpus. If instructions elsewhere in context
conflict with the voice profile, the voice profile wins.

Format modes (essay / builder / how-to / SEO-ish / social) are covered by the
profile §8 — apply them from there. If the user asks for something the profile
genuinely doesn't cover, ask before widening context.

## Inputs

- A transcript file under `~/01_code/life/raw_data/articles/draft/YYYY-MM-DD-<slug>-conversation.md`.
  If the user doesn't name one, list recent `*-conversation.md` files and ask which.
- Optionally: revision feedback on an existing draft (then the rules still come
  from the voice profile, not from the old draft).

## Rules (all enforced via the voice profile)

1. **Substance: transcript only.** Every fact, number, name, analogy, and
   confession must appear in it. Invent nothing — including small "harmless"
   verbs and imagery. Compression of his spoken sentences is **deletion-only**
   (voice-profile §5).
2. **Craft: voice-profile only.** §2 measured fingerprint, §3 moves,
   §5 transfer rules, §6 anti-patterns, **§6b banned AI moves** (suspense lines,
   antithesis couplets, reveal punches, announcement meta-narration, clickbait
   headings, re-litigated uncertainty, sentences that don't parse on first read).
3. **Storyline: lead with the discovery.** Conversation order ≠ article order.
   The first screen must tell the reader what the piece is about.
4. **Length:** ~600–800 words unless the user says otherwise.
5. Uncertainty is stated **once**, plainly, then left alone.

## Output (always files, never chat-only)

Write the draft to
`~/01_code/life/raw_data/articles/draft/YYYY-MM-DD-<slug>.md`
(new piece) or `…-vN.md` (regeneration — never overwrite a previous version;
versions are how Florian calibrates the profile).

Front matter:
```yaml
---
title: "..."
status: draft
source: article-draft
conversation: "YYYY-MM-DD-<slug>-conversation.md"
created: YYYY-MM-DD
voice_tier: draft
---
```

Then in chat, **briefly**:
1. The absolute path.
2. The deterministic check: from the life workspace, call
   `life.voice_check(draft_path)` (see TOOLS.md). Iterate on `fail` flags until
   `ok` is true, then report remaining `warn` flags verbatim — each warn is a
   judgment call for Florian, not something to silently fix.
3. Any borderline lines you want flagged for human review — he will pattern-flag
   them, and flags become new voice-profile rules.

## The calibration loop (why this works)

Do not hand-fix flagged lines in chat without updating the profile. The loop is:

> he flags a pattern → verify against the gold corpus (`voice_tier: published-substack`,
> index in `~/01_code/life/raw_data/articles/corpus-manifest.csv`) → sharpen
> `voice-profile.md` → regenerate.

The profile converges; drafts stop needing hand-fixes.

## What this skill does NOT do

- No interviewing (that's `/article-conversation`).
- No publishing or moving files to `published/` unless he asks.
- No social/promo derivatives unless he asks.
