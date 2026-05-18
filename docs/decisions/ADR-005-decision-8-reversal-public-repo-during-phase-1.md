# ADR-005: Reverse Decision 8 — flip chrysalis repo public during Phase 1 to enable branch protection

**Status:** Accepted
**Date:** 2026-05-17
**Related:** TODO.md Decision 8, SDD §11 (Distribution), SDD §14 Phase 6

## Context

TODO Decision 8 (resolved 2026-05-17, earlier the same day) set the repo to
private until v1.0. Rationale at the time: match SDD §14 Phase 6 ("Public
GitHub release v1.0"), reduce premature-polish pressure during Phases 1–3,
and keep early bugs internal.

Later on 2026-05-17 we hit a branch-protection gate during Phase 1. GitHub
does not allow branch protection rules on private repositories owned by a
personal account without a GitHub Pro subscription. Branch protection on a
free personal-account private repo is not configurable through the UI or
API.

The team valued branch protection — required CI status checks
(PSScriptAnalyzer + Pester), 1-approval PRs, no force-pushes, no deletions
— higher than the privacy benefit of Decision 8 at this stage. Phase 1
has accumulated three PRs (PR #1 Foundation, PR #2 Credentials helpers,
PR #3a Version Detection) that landed without CI-gated PR review at the
ref-protection level, and PR #3b is queued. Waiting until v1.0 for
guardrails meant Phase 1 through Phase 5 would continue accumulating
unreviewed-by-CI direct pushes — exactly the failure mode branch
protection exists to prevent.

No license keys, DPAPI material, or client identifiers are or have ever
been in the repo (see `.gitignore` and SDD §10). The "make public" action
is a metadata flip with no secret-exposure consequences.

## Decision

Flip the chrysalis GitHub repo public on 2026-05-17. Enable branch
protection on `main` with:

- Required status checks: PSScriptAnalyzer, Pester
- Strict mode: branches must be up-to-date with `main` before merge
- 1-approval PRs required
- No force-pushes
- No deletions
- `enforce_admins = false` (admin bypass available for emergency)

Decision 8 in TODO.md is marked reversed (struck-through original,
followed by the reversed decision and reasoning). The "no premature
polish during Phases 1–3" intent of Decision 8 is retained as a
discipline note — chrysalis is still pre-v1.0 and is not soliciting
community use yet.

## Alternatives Considered

- **Upgrade to GitHub Pro ($4/month per user).** Pays a recurring
  per-developer fee for a feature that is free on a public repo. Rejected:
  the cost is not the friction, the principle is — we would be paying to
  keep visible the same work that is fine to make visible.
- **Move repo to a free GitHub org (orgs get branch protection on private
  repos at the free Team tier).** Rejected: creating a `neocode-software`
  org for one project is premature org-scaffolding. We do not have a
  second project lined up that would share the org.
- **Defer branch protection until v1.0 per Decision 8.** Rejected: three
  PRs of accumulated code without ref-level CI gating is already too much
  exposure to direct-push mistakes. Waiting through Phases 1-5 makes that
  worse, not better. The original Decision 8 framing did not anticipate
  the ref-protection gating cost.
- **Flip public, accept Decision 8 reversal (chosen).** Branch protection
  active immediately. Repo contents are inspectable by the public. No
  secret-exposure issue per the `.gitignore` and §10 audit. The
  premature-polish-pressure risk transfers to the developers; we mitigate
  by discipline rather than by repo visibility.

## Consequences

- **chrysalis source is publicly readable from 2026-05-17 onward.** Issues,
  code, commits, and the Phase 1 design churn are visible. No license
  keys or DPAPI material are or have ever been in the repo (see
  `.gitignore` and SDD §10).
- **Branch protection is active.** All future changes land via PR with
  green CI. Direct push to `main` is no longer permitted except via
  admin bypass (which is reserved for emergency only).
- **Premature-polish pressure risk from Decision 8 transfers to developer
  discipline.** We may feel pressure to clean up Phase 1's in-progress
  shape because the world can see it. Mitigation: keep working, ship
  Phase 1 deliverable, ignore the audience until v1.0.
- **v1.0 ceremony becomes "announcement and community-readiness," not
  "public reveal."** Soft change. The engineering plan in SDD §14 is
  unaffected. The Phase 6 line in §14 has been updated to reflect this.
- **Operational obligation.** Future ADRs and SDD updates that touch
  Decision 8 must reference this ADR. The TODO Decision 8 entry is
  preserved with strikethrough and pointer here.

## Notes

The repo can be flipped back to private at any time without losing the
branch protection rules themselves (private + branch protection on
personal accounts requires Pro, but the flip-back operation is
single-command and the rule definitions persist). We will not flip back
unless a real security incident or a compliance need arises. Revisit
condition: if any client engagement requires private code for the
chrysalis repo specifically (not the client's data), we re-evaluate
under the cost-of-Pro vs. cost-of-org framing in Alternatives.
