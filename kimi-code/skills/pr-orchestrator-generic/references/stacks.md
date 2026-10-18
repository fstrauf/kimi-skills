# GitHub Stacked PRs (mode A — stack-aware)

Referenced from `SKILL.md` → *Base branch and stacks*. **Default remains one issue → one ship unit.** Mode A does **not** auto-split work into multi-layer stacks (that is mode B). It makes the orchestrator and pr-loop **safe and correct** when a stack exists or when `ORCH_STACK=1` prefers stack tooling.

## Bootstrap and env

pr-loop **bootstraps stacks every run** (`ensure_gh_stack_ready` in `loop-common.sh`): installs `github/gh-stack` if missing, probes `GET /repos/{repo}/stacks`, sets local git knobs (`rerere`, `remote.pushDefault`). Env exported into the agent process:

| Env | Meaning |
|-----|---------|
| `ORCH_STACK` | `auto` (default) \| `1` \| `0` |
| `ORCH_STACK_CLI` | `1` if `gh stack` works |
| `ORCH_STACK_REPO_OK` | `1` if Stacks API answered 2xx for this repo |
| `ORCH_STACK_READY` | `1` only when both CLI + repo probe OK |
| `ORCH_BASE_BRANCH` | Branch this issue must fork from (default branch when unset). pr-loop sets it to a dependency's open-PR head when stacking through an unmerged chain |

There is **no public GitHub API to flip “enable Stacked PRs” on a repo**. If the probe returns 404, log it and stay on the classic path (user must enable via plan / UI / waitlist).

When not launched via pr-loop, probe yourself:

```bash
ORCH_STACK="${ORCH_STACK:-auto}"
STACK_CLI="${ORCH_STACK_CLI:-0}"
if [ "$STACK_CLI" != "1" ] && gh stack --help >/dev/null 2>&1; then
  STACK_CLI=1
fi
if [ "$STACK_CLI" != "1" ] && [ "${ORCH_STACK_ENSURE:-1}" != "0" ]; then
  gh extension install github/gh-stack 2>/dev/null || true
  gh stack --help >/dev/null 2>&1 && STACK_CLI=1
fi
# Prefer ORCH_STACK_READY from the loop when present
STACK_READY="${ORCH_STACK_READY:-$STACK_CLI}"
```

Write `stack_cli` / `stack_ready` into working notes. If `STACK_CLI=0` or `STACK_READY=0`, never call `gh stack *`; use the classic path.

## When to use stack commands

| Situation | Create / open | Iterate (fix+push) | Land (loop only if `ORCH_AUTO_MERGE=1`) |
|-----------|---------------|---------------------|----------------------------------------|
| `STACK_CLI=0` or `ORCH_STACK=0` | `git push` + `gh pr create --draft` | `git push` | `gh pr merge` / push-land |
| Single branch, not in a chain (`ORCH_STACK=auto`) | Classic path (above) | Classic path | Classic path |
| Already on a `gh stack` branch, or open PR base is another PR's head | `gh stack submit --auto` (drafts) | commit → `gh stack push` (rebase first if mid-stack fix: `gh stack rebase` then push) | `gh stack merge <pr> --yes --squash` |
| `ORCH_STACK=1` and `STACK_CLI=1` | Prefer `gh stack init feature/<n>-<slug>` then implement; open with `gh stack submit --auto` | `gh stack push` | stack merge if chained; else classic |

## Create

```bash
# From default branch, clean tree:
gh stack init "feature/<issue-number>-<slug>"
# ... implement + commit on this branch ...
gh stack submit --auto    # drafts; non-interactive titles
# Capture PR: gh pr view --json number,url
```

Do **not** also run `gh pr create` for the same branch. Set title/body after submit:

```bash
gh pr edit <pr_number> --title "<issue title>" --body "$(cat <<'EOF'
Closes #<N>

## Summary
...
EOF
)"
```

If `gh stack submit` fails with exit 9 (Stacked PRs not enabled) or extension errors, fall back to the classic path and set `STACK_CLI=0` for the rest of the run.

## Iterate (review fixes / test fixes)

```bash
# On the branch that owns the finding:
git add -A && git commit -m "fix: …"
# If you edited a lower layer and need descendants updated:
gh stack rebase
gh stack push
```

Plain `git push` mid-stack often leaves upper PRs stale; prefer `gh stack push`.

## Land (humans or pr-loop)

```bash
# Merge everything up to and including this PR (atomic):
gh stack merge <pr_number> --yes --squash
```

pr-loop does this automatically when `ORCH_STACK!=0` and the PR is in an open chain (`loop-common.sh`).
