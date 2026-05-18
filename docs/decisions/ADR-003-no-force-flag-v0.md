# ADR-003: No `-Force` flag in v0; narrow `-SkipCheck <name>` reserved for Phase 4+

**Status:** Accepted
**Date:** 2026-05-17
**Related:** SDD §6.1 (Pre-flight), §15 (Risks), §13 (Resolved Decisions), TODO Decision 4

## Context

chrysalis's safety story rests on pre-flight (SDD §6.1 step 2). Seven checks
run before any destructive action:

- 2a. current FMS version detected
- 2b. config has installer entry for current version (rollback safety)
- 2c. config has installer entry for target version
- 2d. admin credentials decrypt
- 2e. license covers target version
- 2f. disk space for installer + backup
- 2g. recent native FMS DB backup exists

Every one of those exists because skipping it has caused, or could cause, a
broken FMS host. A `-Force` flag that bypasses pre-flight is the kind of
flag every CLI accumulates "just in case." It is also the kind of flag
operators reach for on a Friday at 5pm under pressure, and it is the kind
of flag that turns a safe tool into an unsafe one in one keystroke.

Pre-flight is not advisory. It is the guarantee. If a check is wrong, the
right fix is to fix the check, not to add a bypass.

## Decision

v0 ships with no `-Force` flag and no equivalent blanket bypass. Every
pre-flight check must pass for the upgrade or rollback to proceed. If a
check is failing for a legitimate reason, the user must address the
underlying condition (e.g. run `fmsadmin backup`, free disk, re-encrypt
creds) and re-run chrysalis.

Phase 4+ may add a narrow, named escape hatch: `-SkipCheck <name>` that
disables one specific check (e.g. `-SkipCheck disk-space-margin`) only if
that check has proven noisy in production. The flag never accepts "all"
and is never a category bypass. Each named skip must be justified in the
log output ("skipped: disk-space-margin (user-supplied)") so audits can
catch overuse.

## Alternatives Considered

- **Ship `-Force` in v0.** Rejected: undermines the safety guarantee the
  tool is built around. The pressure-moment risk is exactly the moment
  the checks are most valuable.
- **Ship `-Force` but require an additional confirmation prompt.** Rejected:
  on RDP under pressure, prompts get clicked through. The flag's existence
  is the problem, not its UX.
- **Per-check `-SkipCheck <name>` flag in v0.** Rejected for v0: we don't
  yet know which checks will be genuinely noisy in production versus which
  are correctly blocking. Phase 4 (first production use) is when we'll
  learn that. Adding the flag earlier risks shipping skips for checks that
  turn out to be fine.
- **No bypass in v0, named `-SkipCheck` reserved for Phase 4+ (chosen).**
  Keeps v0 safe by construction. Leaves a documented door for narrow,
  evidence-driven escape hatches once we have evidence.

## Consequences

- The tool will sometimes refuse to run when a developer is confident the
  underlying condition is fine. This is the intended behavior. The remedy
  is to fix the condition or fix the check, not to bypass.
- Pre-flight check authors carry a higher bar: each check must produce a
  clear failure message naming the specific remediation. "Refuse with
  clear remediation" only works if the message is actually clear. Misaka
  (coder) writes the messages; Hermione (reviewer) reviews them for
  actionability.
- Future contributors will propose adding `-Force`. This ADR is the
  pre-written answer. If the proposal is genuinely a narrow named skip
  for a specific noisy check, that's the Phase 4+ door — write a new ADR
  amending this one with the specific check name and the production
  evidence justifying it.
- If a check turns out to be wrong (false positive in production), the
  fix is in the check's logic. Clarice (debugger) and Misaka (coder)
  handle that as a bug, not as a UX feature request.

## Notes

Revisit conditions: a specific named check is documented as producing
false positives in production across multiple hosts. At that point write a
follow-up ADR introducing `-SkipCheck <that-specific-name>` with rationale
and evidence. Do not introduce `-SkipCheck` as a generic mechanism without
naming the specific check that justifies it.
