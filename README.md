# kimi-skills

Version-controlled home for my Kimi Code / agent skills.

## Layout

| Repo path | Live path (symlink) | Contents |
|---|---|---|
| `kimi-code/skills/` | `~/.kimi-code/skills` | User-scope Kimi Code skills |
| `agents/skills/` | `~/.agents/skills` | Agent skills (e.g. kimi-webbridge) |

## Skills

- `pr-orchestrator` — full shipping loop for a GitHub issue: implement → draft PR → thermonuclear review → test gate → mark ready
- `thermo-nuclear-code-quality-review` — strict maintainability review baseline (used by the orchestrator)
- `feature-spec-to-github-issue` — turn a bug report / feature request into a structured GitHub issue with root-cause analysis
- `gh-scope-issue` — refine a rough GitHub issue from the board's Scoping column into a build-ready spec
- `kimi-webbridge` — browser automation using the user's real browser sessions

## How it works

The live config paths are **symlinks into this repo**, so every skill edit is immediately a git working-tree change — no sync step, no drift. Commit when you want a checkpoint; roll back with `git checkout`.

## Bootstrap on a new machine

```bash
gh repo clone fstrauf/kimi-skills ~/01_code/kimi-skills
ln -s ~/01_code/kimi-skills/kimi-code/skills ~/.kimi-code/skills
ln -s ~/01_code/kimi-skills/agents/skills ~/.agents/skills
```
