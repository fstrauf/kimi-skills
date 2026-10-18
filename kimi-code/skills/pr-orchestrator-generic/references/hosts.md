# Host tool map and per-host notes

Referenced from `SKILL.md` → *Host detection*. Use only the column of the host you detected.

## Tool map

| Purpose | Kimi | Grok | Ori | Claude |
|---------|------|------|-----|--------|
| Shell (git, gh, short commands) | `Bash` | `run_terminal_command` | `bash` | `Bash` |
| Long-running shell (`pnpm test:all`, servers) | `Bash` with `run_in_background: true`, `disable_timeout: true` | `run_terminal_command` with `background: true`, large/`0` `timeout` | Prefer `spawn_agent` + `wait_agent`; use `bash` with `timeoutMs` ≥ 3600000 only when no background agent is needed | `Bash` with `run_in_background: true` (max `timeout` 600000 for foreground), then wait **in the same turn** per the next row |
| Wait on background work | `TaskOutput(block=true)` / wait on task id | `get_command_or_subagent_output` with `task_ids` + positive `timeout_ms` | `wait_agent` | `TaskOutput(task_id, block=true, timeout=600000)` in a loop **within the same turn** until the task reports completed. **Never** end the turn expecting a completion notification (SKILL.md → *Claude: never end a turn on a pending wait*) |
| Stop background work | kill via shell / host stop API if available | `kill_command_or_subagent` | `stop_agent` | `TaskStop` |
| Implementation / fix / review / verify subagents | `Agent` (coder/reviewer) | `spawn_subagent` (`subagent_type: "general-purpose"`; prefer `isolation: "worktree"` for implementers) | `task` with `result_schema` for structured short work; `spawn_agent` + `wait_agent` for long work or progress monitoring | `Agent` with `subagent_type` = routed `agent` (`loop-implementer`, `loop-reviewer`, `loop-verifier`, `loop-fixer`, `loop-explorer`, `loop-triage`) and `model` = routed `model`, spawned with **`run_in_background: false`** so the call blocks and returns the result in-turn |
| Progress tracking | `TodoList` | `todo_write` | `update_goal` / inline comments | `TodoWrite` (or task tools) |
| Goal / status (optional) | `CreateGoal` | `update_goal` (`message` / `completed` / `blocked_reason`) | `set_goal` / `update_goal` | — (state markers only) |
| Read files | `Read` | `read_file` | `read` | `Read` |
| Search code | `Grep`, `Glob` | `grep`, `list_dir` | `grep`, `glob` | `Grep`, `Glob` (broad sweeps → `loop-explorer`) |
| Write small state files | shell redirect / write tools | `write` or shell via `run_terminal_command` | `write` or `edit` or shell via `bash` | `Write` or shell redirect |

## Spawning subagents per host

- **Kimi:** `Agent` coder; non-interactive → background + `TaskOutput(block=true)`.
- **Grok:** `spawn_subagent` with `subagent_type: "general-purpose"`, prefer `isolation: "worktree"`, `background: true`. Wait with `get_command_or_subagent_output` (large `timeout_ms`, e.g. 1800000). If a worktree was used, fetch its HEAD onto the feature branch in the main repo before continuing.
- **Ori:** prefer `task` with a `result_schema` when the work is short and bounded. Use `spawn_agent` with a detailed brief for long work or when progress monitoring is useful; wait with `wait_agent`. Pass `model` only as a routing hint when explicitly configured; otherwise keep OpenRouter Auto.
- **Claude:** `Agent` with `subagent_type` / `model` from the route, **`run_in_background: false`**. Two subagents that run in parallel (Phase 4 reviewer + verifier) go as two `Agent` calls in the same message.

Ori result schemas:

| Role | `result_schema` |
|------|-----------------|
| implement | `{ "status": "ok\|needs-input\|failed", "summary": "...", "changed_files": [], "commits": [], "tests": [], "artifact": { "command": "...", "red": "...", "green": "...", "path": "..." } }` |
| review | `{ "baseline": "loaded\|missing", "verdict": "PASS\|FAIL", "findings": [{ "path": "...", "issue": "...", "suggested_fix": "..." }], "notes": [] }` |
| verify | `{ "spec": "PASS\|FAIL", "criteria": [{ "quote": "...", "status": "met\|partial\|missing", "evidence": "..." }], "scope": [], "correctness": "PASS\|FAIL", "findings": [{ "path": "...", "bug": "...", "breaking_input": "...", "suggested_fix": "..." }], "verdict": "PASS\|FAIL" }` |

The textual formats in SKILL.md stay the interchange format for Kimi, Grok, Claude and shell adapters.

## Ori and OpenRouter execution policy

Ori does not expose its in-process `task`/`spawn_agent` API to a shell child. The unattended shell loop therefore invokes an adapter through `ORCH_CLI`; `ORCH_AGENT=ori` supplies the conventional `ori` default, while installations using an OpenRouter adapter should set `ORCH_CLI` explicitly. The adapter must accept `-p <prompt>`, run in the supplied working directory, preserve the exit code, and forward `ORCH_MODEL` when set.

`routing.py` returns tiers here too. Map `tier` onto the adapter's economical / mid / strongest route when it supports one.

`ORCH_MODEL` is an optional hint, not a provider-specific CLI flag. This keeps OpenRouter Auto routing as the default and lets a local adapter map roles/models without coupling this skill to one API. Never silently retry a failed model route as another ticket; report quota failures and let the supervisor switch agents.

For in-process Ori orchestration, prefer `task` with a `result_schema` for implementer/reviewer/verifier results. Use `spawn_agent` for long-running test gates and dev servers, then `wait_agent`; do not occupy the coordinator with a multi-hour foreground `bash` call.

## Host-specific scratch extras (optional)

- Kimi: `~/.kimi-code/tmp/`
- Grok: `~/.grok/plugin-data/pr-orchestrator/`
- Ori: no default; use `scratch_dir` from SKILL.md.

## Goal / worktree cleanup

- Optional goal at Phase 0 — Kimi: `CreateGoal` · Grok: `update_goal` with `message` · Ori: `set_goal`.
- Complete it at Phase 6 — Kimi goal done · Grok `update_goal` with `completed: true` · Ori `update_goal` with `completed: true`.
- Worktrees you created: clean them up when the host supports it (e.g. `grok worktree rm --force <path>`).
