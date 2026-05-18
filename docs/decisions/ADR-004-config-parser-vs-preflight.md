# ADR-004: Config parser validates shape only; filesystem state belongs in pre-flight

**Status:** Accepted
**Date:** 2026-05-17
**Related:** SDD §5 (Configuration), §6.1 step 2d (Pre-flight credentials check), §10 (Credentials), TODO Deferred Follow-up S6

## Context

During PR #1 review, Hermione flagged S6: should the config parser
(`src/lib/Config.ps1`) verify that `fms.creds_file` actually exists on disk
at config-read time? An earlier path check would produce a friendlier error
than waiting until pre-flight check 2d (which currently does the existence
and decrypt validation immediately before destructive action).

Two paths were open:

- **(a)** Have the parser stat `creds_file` during parse and fail loudly if
  it does not exist. Friendlier error timing.
- **(b)** Keep the parser purely shape-validating (string present, looks
  like a path). Leave existence and decryptability to pre-flight 2d.

The wrinkle: `EncryptCreds.ps1` is the script that produces `creds.xml`.
On a freshly-set-up host, the operator's first chrysalis-related action
is to edit `config.json` (which now references a `creds_file` path) and
then run `EncryptCreds.ps1` to create the file at that path. If the
parser stats the file at read time, every legitimate first-run flow that
parses config before encrypting creds would fail spuriously.

The deeper question is about separation of concerns. The parser's job is
"is this config syntactically well-formed?" The pre-flight's job is "is
the world in a state where it is safe to proceed?" `creds_file` existing
on disk is a property of the world, not of the config text.

## Decision

The config parser validates string shape only. It checks that
`fms.creds_file` is present, is a string, and is non-empty. It does not
stat the path. Existence and decryptability of `creds_file` are gated by
pre-flight check 2d (SDD §6.1 step 2d), which runs before any destructive
action.

This rule generalizes: any field whose value names a filesystem entity
(installer paths, backup roots, cert directories) is shape-validated by
the parser and existence-validated by pre-flight. The parser never touches
the filesystem.

## Alternatives Considered

- **(a) Parser stats `creds_file` at read time.** Friendlier error in
  steady state. Rejected: breaks the legitimate first-run flow where
  config is authored before `EncryptCreds.ps1` has produced `creds.xml`.
  Workarounds (e.g., "only stat if the operator passes `--strict`") add
  a flag to paper over a separation-of-concerns problem.
- **(b) Parser does shape only; pre-flight does state (chosen).** Clean
  separation. Parser can run in any context (including bootstrapping a
  fresh host) without ordering constraints on external setup steps.
  Pre-flight is already the gate before destructive action, so failure
  there is at the right time.
- **Hybrid: parser warns but does not fail if missing.** Rejected: a
  warning in this position is noise — either the operator is mid-bootstrap
  (warning is wrong) or the operator is mid-run (pre-flight will fail
  loudly in a moment anyway). Warning twice is worse than failing once.

## Consequences

- **Parser stays cheap and testable.** No filesystem access in
  `src/lib/Config.ps1`. Unit tests for the parser do not need temp-file
  fixtures or mock filesystems.
- **Pre-flight remains the single authoritative state gate.** If a future
  contributor proposes adding filesystem checks to the parser, point them
  at this ADR; the answer is that those checks belong in pre-flight.
- **Error timing is one step later than the friendliest possible.** An
  operator with a typo in `creds_file` learns about it at pre-flight 2d,
  not at config parse. Acceptable: pre-flight 2d's failure message names
  the resolved path explicitly, so the typo is still obvious in the
  output.
- **The rule generalizes.** When pre-flight checks for installer URLs
  (Phase 4, see SDD §15 risk 4) land, they follow the same pattern:
  parser validates URL shape; pre-flight does the HEAD request. No
  filesystem or network access in the parser layer.

## Notes

Resolves TODO Deferred Follow-up S6 (Phase 1 review). The S6 line in
`TODO.md` is marked resolved and points back here. Misaka (coder) and
Hermione (reviewer) own the rule going forward: parser stays pure;
filesystem and network checks live in pre-flight.
