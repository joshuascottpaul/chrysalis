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

Phase 1: Foundation. See `TODO.md` for what's next and what's blocked.
