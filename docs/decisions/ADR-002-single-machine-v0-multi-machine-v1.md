# ADR-002: Single-machine FMS in v0; multi-machine deferred to Phase 6 (v1.0)

**Status:** Accepted
**Date:** 2026-05-17
**Related:** SDD §2 (Goals), §14 Phase 6, §13 (Resolved Decisions), TODO Decision 6

## Context

FileMaker Server supports two deployment shapes:

1. **Single-machine.** Database, admin server, WPE, FMDAPI, FMSTB, and any
   workers all on one host. The common case at Neo Code and at Neo Code's
   client base.
2. **Multi-machine.** Database server on one host, one or more worker hosts
   running WPE / FMDAPI / FMSTB separately, coordinated over the network.

Multi-machine upgrade is not "the same flow N times." It introduces:

- **Ordering constraints across hosts.** Workers must drain and shut down
  before the database host begins its shutdown; workers must not come back
  before the database host is fully up and reachable.
- **Separate shutdown and startup sequences per role.** A worker host has no
  `SERVER` service to stop; the database host has no `WPE` shutdown to wait
  on locally if WPE lives elsewhere.
- **Network coordination.** A worker host checking the database host's
  readiness, version, and admin API responsiveness over the network — not
  over localhost.
- **Per-host backup semantics.** What counts as "state" on a worker host
  differs from what counts on the database host (no `Schedules.xml`,
  different cert story, different plugin set).

None of those can be designed and validated without a multi-host test rig.
We have a single test FMS host (per Decision 10) and no multi-host rig
budgeted before Phase 6.

## Decision

v0 (Phases 1–5) supports single-machine FMS hosts only. Multi-machine
support is a v1.0 deliverable, added in Phase 6 before the public release.
The Phase 6 approach is per-host invocation with a documented coordination
sequence — each host runs chrysalis independently, no remote orchestration
(consistent with the SDD §2 non-goal on remote orchestration).

## Alternatives Considered

- **Ship multi-machine in v0.** Rejected: requires a multi-host test rig and
  a per-role workflow design we cannot validate now. Would push Phase 1
  rightward by weeks and risk shipping unverified ordering logic.
- **Detect multi-machine at runtime in v0 and refuse with a clear error.**
  Partially adopted in spirit — pre-flight should be able to recognize a
  multi-host configuration and refuse rather than half-run. Tracked as a
  Phase 1 / Phase 2 implementation detail, not as full support.
- **Defer multi-machine indefinitely.** Rejected: Neo Code has clients on
  multi-machine FMS and the v1.0 release should not ship without it.
  Pinning it to Phase 6 fixes a date.
- **Single-machine v0, multi-machine in Phase 6 (chosen).** Matches our test
  capacity, ships a smaller and safer v0, and binds multi-machine to a
  specific phase with a specific deliverable.

## Consequences

- v0 ships sooner and on a host shape we can actually test.
- Pre-flight gains an obligation: detect multi-host FMS configuration and
  refuse politely with a "v1.0 will support this; for now, run manual upgrade
  steps" message. Misaka (coder) wires this into the pre-flight framework
  in Phase 1 or Phase 2.
- Phase 6 carries real design work, not just polish: per-role workflows,
  cross-host ordering, network-aware smoke tests, per-host backup semantics.
  Ariadne owns documenting these before Misaka implements.
- v1.0 release is gated on multi-machine working end-to-end across at least
  one test deployment with separate database and worker hosts.
- Until Phase 6 starts, this decision will be tempting to revisit every
  time a client asks about multi-machine. Don't. Phase 6 is the answer.

## Notes

Revisit only if: (a) a multi-host test rig becomes available before Phase 4
*and* (b) a paying client materially blocks on multi-machine before v1.0.
Even then, write a new ADR superseding this one — do not silently expand
scope.
