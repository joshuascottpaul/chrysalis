# chrysalis - Claude Context

## What This Is

chrysalis is a cross-platform CLI tool for upgrading and rolling back FileMaker Server installations. Windows is the primary target; macOS and Linux are secondary. Built and maintained by Neo Code Software Limited.

Read `docs/design/` before doing any substantive work. The design doc is the source of truth. If the doc and the code disagree, update the doc first (with Ariadne) before changing the code.

## Repo Layout

- `chrysalis.ps1` - Phase 1 entry point at repo root (`-DryRun` only in Phase 1; upgrade path lands in Phase 2)
- `docs/design/` - Software design doc (currently `2026 05 15 09 11 PM - fms-upgrader-design-doc.md`, Draft v0.5)
- `docs/decisions/` - ADRs (ADR-001 through ADR-005 — see ADR index below)
- `docs/runbooks/` - Operational guides (`credentials.md` exists from PR #2; more land in later phases)
- `src/lib/` - PowerShell library scripts (Logging, Config, EncryptCreds, sudofmsadmin, VersionDetection, PreFlight)
- `tests/` - Pester 5.x tests (matched per source file) + `tests/fixtures/` (config fixtures)
- `config/` - Config schema (`config.schema.json`) and example (`config.example.json`)
- `.github/workflows/ci.yml` - CI on `windows-latest`: PSScriptAnalyzer + Pester
- `PSScriptAnalyzerSettings.psd1` - PSSA config at repo root; excludes 5 rules that conflict with intentional choices (Write-Host for CLI, empty catches for best-effort cleanup, plural-noun cmdlets that act on collections, BOM-less UTF-8). PSSA scans `src/` only — `tests/` is excluded because Pester mock idioms produce too many false positives.
- `.claude/agents/` - Specialized agents for this project
- `logs/` - Run logs (gitignored)

## Repo Visibility and Branch Protection

- **Public repo** at https://github.com/joshuascottpaul/chrysalis (flipped from private on 2026-05-17 to enable branch protection; see ADR-005 for the reversal of original Decision 8). The "no premature polish" intent stays — chrysalis is still pre-v1.0.
- **Branch protection on `main`**: required status checks (PSScriptAnalyzer + Pester, strict), 1 approval per PR, no force-push, no deletions. `enforce_admins=false` so admins can bypass for emergency.
- **Workflow**: all changes land via PR on a feature branch (`feat/<name>`). Direct push to `main` is blocked except by admin bypass. Self-approval is blocked by GitHub; merges use `gh pr merge --squash --admin --delete-branch` until a second reviewer joins.

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

## ADR Index

Read these before making decisions that touch their territory.

- **ADR-001** — Greenfield over forking `ernestkoe/powershell-fms`. Adapted patterns carry a per-file credit header.
- **ADR-002** — Single-machine v0; multi-machine support is a v1 deliverable in Phase 6.
- **ADR-003** — No `-Force` flag in v0. Pre-flight is the safety net; a blanket bypass undermines the guarantee. (No `-SkipCheck`, `-AllowCrossMajor`, `-SkipCertificateCheck` either.)
- **ADR-004** — Parser-vs-pre-flight separation of concerns. The config parser validates string shape; filesystem state (existence, reachability) belongs in pre-flight (SDD §6.1 step 2).
- **ADR-005** — Decision 8 reversed: repo public from 2026-05-17 to enable branch protection. Premature-polish risk transferred to discipline.

## Conventions

- PowerShell 5.1 compatibility required (Windows Server 2016+ ships with this)
- Bash 4+ and python3 for macOS/Linux scripts. No extra installs.
- Config format: JSON. Parsed natively in PowerShell with ConvertFrom-Json, via `python3 -c` in Bash.
- Credentials: DPAPI on Windows. Never plaintext. Never environment variables.
- Logs go to `./logs/`
- Backups go to `{backup_root}/{timestamp}/`
- "Neo Code" is always two words
- No emoji in code, comments, or docs unless the user explicitly asks.

## Phase 1 lessons learned (from CI triage)

These bit us once on `windows-latest` CI. Future authors should not repeat them.

- **Pester 5 `-Skip` on a `Describe` is evaluated during Discovery, before `BeforeAll` runs.** Any helper used in a `-Skip` expression (e.g., `Test-IsWindowsHost`) must be defined at file top-level, not inside `BeforeAll`. We hit this on PR #3a; the fix added the helper above the first `Describe`.
- **`Set-Content -Encoding Byte` requires `[byte[]]`, not a string.** For tests that need to gate on `Get-Item.VersionInfo` (PE-header reads), `Mock Get-Item -ParameterFilter { $LiteralPath -eq $fakeBinary } -MockWith { ... }` is the right pattern; fake-PE creation via `Set-Content -Encoding Byte` is not.
- **`WebException.Response` is strongly typed as `System.Net.WebResponse`.** Reflecting a `PSCustomObject` into `m_Response` fails type-check on PS 5.1. When you need to test exception-handling paths, refactor the production code to expose a testable seam (see `Get-AdminApiErrorDetailInternal` in `src/lib/VersionDetection.ps1`) rather than fight reflection.
- **PowerShell's `1GB` literal is `1073741824` (binary, 1 GiB), not 1,000,000,000.** Label numbers as GiB if you compute via `/1GB`. The pre-flight disk-space check (2f) uses GiB throughout.
- **`*-Service` cmdlets are Windows-only.** Cross-platform Pester runs need a shim layer (`if (-not (Get-Command Stop-Service -ErrorAction SilentlyContinue)) { function global:Stop-Service { ... } }`) so `Mock` has a target on macOS/Linux pwsh.
- **Pester `Mock -ParameterFilter` does not populate `$PSBoundParameters`.** Filters bind positional args directly to `$Path` / `$LiteralPath`. Inspect those, not `$PSBoundParameters.ContainsKey(...)`.
- **Tests must never write to the real `./logs/`.** Every test that opens a `LogContext` must inject `-LogRoot` under `$TestDrive`. PR #2 review B1 was a real bug caused by missing this.
- **PSScriptAnalyzer's `PSUseBOMForUnicodeEncodedFile` rule fires on em-dashes.** We write BOM-less UTF-8 deliberately for tail/grep friendliness; the rule is in the excluded list.
- **`gh repo create` and branch-protection API on private personal repos need GitHub Pro.** Public repos on free accounts get full branch protection. ADR-005 captures the trade.

## Session Discipline

- The agent system is the right tool for parallelizable work. Dispatch in parallel when tasks are independent (Ariadne docs + Misaka code + Shizuku runbook). Sequence when there's a real dependency.
- Don't commit on behalf of the user without explicit ask. Don't push to `main` directly except via admin bypass and only for trivial docs/TODO follow-ups that already passed CI on a prior PR. Code changes always go through PR.
- Before any non-trivial change: cross-check the SDD + the relevant ADR + `TODO.md`. The doc tree is the contract.

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
