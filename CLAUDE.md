# chrysalis - Claude Context

## What This Is

chrysalis is a cross-platform CLI tool for upgrading and rolling back FileMaker Server installations. Windows is the primary target; macOS and Linux are secondary. Built and maintained by Neo Code Software Limited.

Read `docs/design/` before doing any substantive work. The design doc is the source of truth. If the doc and the code disagree, update the doc first (with Ariadne) before changing the code.

## Repo Layout

- `docs/design/` - Software design doc and architecture decisions
- `docs/decisions/` - ADRs (Architecture Decision Records)
- `docs/runbooks/` - Operational guides (added in later phases)
- `src/` - PowerShell and Bash source
- `tests/` - Pester / Bats tests
- `config/` - Config templates
- `.claude/agents/` - Specialized agents for this project
- `logs/` - Run logs (gitignored)

## Agent Cheat Sheet

- Misaka (coder) - writes implementation code
- Hermione (reviewer) - reviews code changes
- Ripley (tech lead) - makes architectural calls
- Ariadne (design) - maintains design docs and ADRs
- Kaylee (tests/CI) - test coverage and pipelines
- Shizuku (docs) - user-facing docs (README, runbooks)
- Clarice (debugger) - root-cause investigation
- Mikasa (simplifier) - removes complexity
- Leia (GitHub ops) - issues, PRs, releases
- Nausicaa (explorer) - codebase navigation and reconnaissance
- Winry (planner) - TODO and sequencing

Invoke an agent by their slug (e.g., the Task tool with `subagent_type: misaka-coder`).

## Conventions

- PowerShell 5.1 compatibility required (Windows Server 2016+ ships with this)
- Bash 4+ and python3 for macOS/Linux scripts. No extra installs.
- Config format: JSON. Parsed natively in PowerShell with ConvertFrom-Json, via `python3 -c` in Bash.
- Credentials: DPAPI on Windows. Never plaintext. Never environment variables.
- Logs go to `./logs/`
- Backups go to `{backup_root}/{timestamp}/`
- "Neo Code" is always two words

## Current Phase

**Phase 1 code is complete and on `main` as of 2026-05-18.** Four PRs shipped (Foundation, Credentials, Version Detection, Pre-flight + Entry Point). 107 Pester tests passing, PSScriptAnalyzer clean, branch protection active. Repo is public at https://github.com/joshuascottpaul/chrysalis.

**The next session must work on task 15 — the only thing between us and `v0.1.0`.** Task 15 is a manual gate: someone runs `.\chrysalis.ps1 -DryRun` on a Windows FMS test host, confirms the dry-run output matches reality, and Leia cuts the `v0.1.0` release. The exact steps live at the top of `TODO.md` under the "RESUME HERE" banner — read those first when starting a new session.

After v0.1.0 ships, Phase 2 (upgrade execution) begins per SDD §14.

## Session resumption protocol

When a new session starts on this repo:
1. Read the "RESUME HERE" banner at the top of `TODO.md`. That's the active task.
2. Check `git log --oneline -5` for any commits since this CLAUDE.md was written.
3. Check `gh pr list` for any open PRs (there should be none — all merged).
4. If Phase 1 is still gating on task 15, the appropriate action is to remind the user about the manual `-DryRun` on the FMS test host, NOT to start new Phase 2 work.
