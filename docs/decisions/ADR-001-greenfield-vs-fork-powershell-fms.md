# ADR-001: Greenfield chrysalis, credit `ernestkoe/powershell-fms` for adapted patterns

**Status:** Accepted
**Date:** 2026-05-17
**Related:** SDD §4 (File Layout), §10 (Credentials), §12 (Prior Art), §13 Decision 1, TODO Decision 1

## Context

`ernestkoe/powershell-fms` (MIT) is the most useful piece of public prior art
for FileMaker Server admin scripting in PowerShell. Two patterns in it are
directly relevant to chrysalis:

- `EncryptCreds` — DPAPI-backed credential storage for FMS admin login
- `sudofmsadmin` — elevation wrapper around `fmsadmin`

The repo does not contain an upgrader. It contains adjacent helpers we would
otherwise rebuild from scratch. The question at bootstrap was whether to fork
the repository, vendor it as a submodule, or write chrysalis greenfield and
credit the patterns where adapted.

chrysalis is meant to evolve quickly across Phases 1–6 (PowerShell 5.1 first,
then Bash + python3 on macOS/Linux, then multi-machine). We are also private
until v1.0 (per Decision 8), which makes upstream coordination friction
particularly unattractive during the formative phases.

## Decision

Write chrysalis greenfield. Adapt the two patterns (`EncryptCreds`,
`sudofmsadmin`) into new files under `lib/`. Credit `ernestkoe/powershell-fms`
in two places:

1. README — "Prior art" section naming the upstream repo and its MIT license
2. Per-file header comment on any file whose pattern is adapted from upstream,
   naming the original file and noting MIT attribution

## Alternatives Considered

- **Outright fork of `ernestkoe/powershell-fms`.** Fastest possible start.
  Rejected: drags in surface area (files, conventions, naming) we don't need;
  couples chrysalis's shape to upstream's; makes it harder to evolve toward a
  cross-platform upgrader because the upstream is Windows-only and not
  organized around upgrade/rollback workflows.
- **Vendor as a git submodule.** Keeps upstream pinned, allows pulling fixes.
  Rejected: same surface-area problem as a fork, plus submodule version-pinning
  headaches every time we touch the adapted patterns. Also awkward while
  chrysalis is private and upstream is public.
- **Greenfield with credit (chosen).** Slower start than forking, but we own
  every line, file layout matches the SDD, and we can evolve freely. The
  credit obligation is small and explicit.

## Consequences

- We own all the code. Refactors, renames, and cross-platform changes are
  unilateral; no upstream-merge dance.
- We carry a credit obligation. Every file that adapts an upstream pattern
  needs a header naming the original. Misaka (coder) is responsible for
  adding these on first commit of `EncryptCreds.ps1` and `sudofmsadmin.ps1`;
  Hermione (reviewer) is responsible for catching missing credit in review.
- We forgo any future fixes upstream ships. Acceptable: the patterns are
  small and stable, and FMS admin behavior changes are driven by Claris, not
  by upstream.
- PowerShell 5.1 compatibility is preserved regardless — we write to the
  same target as upstream.

## Notes

If chrysalis ever needs a pattern from upstream we haven't yet adapted, the
same rule applies: rewrite under `lib/`, add the header credit, note it in
the README. Do not partial-fork.
