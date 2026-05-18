# chrysalis TODO

Current phase: 1 (Foundation). See `docs/design/` section 14 for the full timeline.

2026-05-17: PR #1 (Foundation) reviewed and cleared by Hermione; ready to ship. PR #2 (Credentials helpers) is next.
2026-05-17: PR #2 (Credentials helpers) reviewed and cleared by Hermione (second pass); ready to ship. PR #3 (Detection and pre-flight) is next.
2026-05-17: PR #3a (Version Detection) reviewed and cleared by Hermione (second pass); ready to ship. PR #3b (pre-flight framework) is next, gated on first green CI run.
2026-05-17: Josh suggested Admin API-driven discovery (Suggestion 1) and questioned hardcoded test values (Suggestion 2). Ripley filed Suggestion 1 as Phase 4 work; Suggestion 2 closed no-action.
2026-05-17: Decision 8 reversed — repo flipped public to enable branch protection; see Decision 8 update + ADR-005.
2026-05-18: PR #3b (Pre-flight framework, task 8) merged to main via PR https://github.com/joshuascottpaul/chrysallis/pull/1; ready for PR #4 (dry-run + release). Phase 1 task list now needs only PR #4 to ship v0.1.0.

---

## Resolved Decisions (2026-05-17)

All 10 bootstrap questions decided. Phase 1 is unblocked. SDD §13 also updated.

1. **Fork `ernestkoe/powershell-fms` outright, or greenfield with credit?**
   Greenfield. Adapt only the patterns we need (`EncryptCreds`, `sudofmsadmin`). Credit `ernestkoe/powershell-fms` in the README and in per-file headers where patterns are reused.

2. **When no recent native FMS DB backup exists, refuse to run or trigger a fresh backup automatically?**
   Refuse. Print clear remediation: run `fmsadmin backup` (or wait for the next scheduled backup) and re-run chrysalis. Matches SDD §8 and the §2 non-goal of replacing FMS's native backup schedule.

3. **`Assisted Install.txt` - config-driven or static files per-version?**
   Hybrid. Per-version template skeletons in `lib/templates/`, with values (license key, install path, ports) substituted from `config.json` at runtime. License keys never in the repo. The resolved file is captured in the backup folder per SDD §8 item 10 so rollback's clean install has exactly what was used.

4. **Emergency `-Force` flag that skips pre-flight checks - v0, or strict-only?**
   Strict-only in v0. Pre-flight is the safety net; a blanket bypass undermines the whole guarantee. Phase 4+ may add narrow `-SkipCheck <name>` if specific checks prove noisy in production.

5. **FMS versions in scope - just 21.x, or 19.x + 20.x + 21.x?**
   20.x, 21.x, and forward versions (22.x and beyond as Claris releases them). 19.x is out of scope (EOL). The `installers` block in `config.json` is the version registry — new versions are added there, no code change required.

6. **Multi-machine FMS deployments - in scope for v0, or single-machine only?**
   Single-machine in v0. Multi-machine (separate database + worker hosts) is a v1 deliverable — Phase 6 must include this before public v1.0 release.

7. **Cross-major rollback (e.g. 21.x back to 20.x) - allow it, or refuse?**
   Refuse in v0. Within-major only (e.g. 21.0.3 → 21.0.2). Cross-major rollback hits file-format, Schedules.xml, and plugin compatibility issues that need explicit handling. `-AllowCrossMajor` opt-in is a Phase 4+ feature once those risks are documented.

8. **Public GitHub repo from day 1, or private until v1.0?**
   **Decision (reversed 2026-05-17):** ~~Private until v1.0.~~ Public from 2026-05-17. Reversal driven by the need to enable GitHub branch protection on `main` (which requires GitHub Pro or a public repo on personal accounts). Branch protection now enforces: required CI checks (PSScriptAnalyzer + Pester), 1-approval PRs, no force-pushes, no deletions. The "no premature polish" intent of the original decision is unchanged — chrysalis is still pre-v1.0 and is not solicited for community use yet. See ADR-005.

9. **Notifications for v1 - Slack, email, both, or stdout only?**
   Slack webhook only. SMTP/email deferred — build later if a client asks. The SDD plan to ship both in Phase 6 is narrowed to Slack only.

10. **First test target - dedicated Neo Code test FMS host, or piggyback on a client dev/staging?**
    Dedicated Neo Code test FMS host. Low-stakes client dev/staging is reserved for Phase 4's first production upgrade. Matches the SDD's existing Resource Notes.

---

## Phase 1 Tasks

Sequence per Ripley's call 2026-05-17. See ADR-001/002/003 for the bootstrap decisions.

Phase 1 deliverable per SDD §14: `fms-upgrade.ps1 -DryRun` runs end-to-end on a test FMS host and prints exactly what it would do at each step.

**Execution order (Resequenced 2026-05-17):** `1 → (9, 12 in parallel) → 4 → 5 → (2, 3 in parallel) → 6 → 7 → 8 → 10 → 13 → 14 → 15`

**Note on testing:** Task 11 (standalone "Pester tests for the above") is dissolved. Pester coverage lands *with each piece* as part of definition-of-done. Kaylee reviews every PR for coverage rather than writing tests in a closing sweep.

### PR #1: Foundation (tasks 1, 9, 4, 5 + CI scaffolding from 12) — SHIPPED 2026-05-17

No FMS interaction in PR #1 — reviewable without a test host.

- [x] **1.** Repo scaffold, MIT license filled in, README placeholder (@shizuku-docs)
- [x] **9.** Logging infrastructure — timestamped log files in `./logs/`; structured remediation messages; consumed by pre-flight + dry-run (@misaka-coder)
- [x] **4.** config.json schema and template — **blocked on Ariadne landing `max_backup_age_hours` (default 24) for pre-flight check 2g**; likely resolved by the time this is picked up, but confirm before starting (@misaka-coder, @ariadne-design for schema doc)
- [x] **5.** PowerShell config parser with validation (@misaka-coder)
- [x] **12a.** GitHub Actions workflow skeleton: lint + Pester runner wiring (Track B, parallel with Track A as soon as scaffold lands) (@kaylee-tests, @leia-github)
- [x] Pester scaffolding alongside the above so each task lands with its own tests (@kaylee-tests)

### PR #2+: Credentials helpers (tasks 2, 3 in parallel) — SHIPPED 2026-05-17

Depend on scaffold + logging interface only. Feed pre-flight check 2d (creds decrypt).

- [x] **2.** EncryptCreds.ps1 — greenfield, patterns adapted from ernestkoe/powershell-fms with credit (per Decision 1). **Document DPAPI re-encrypt step in this PR** (SDD §15 risk 2) (@misaka-coder)
- [x] **3.** sudofmsadmin.ps1 — greenfield, patterns adapted from ernestkoe/powershell-fms with credit (per Decision 1) (@misaka-coder)

### PR #3a: Version Detection (tasks 6, 7) — SHIPPED 2026-05-17

- [x] **6.** Version detection: binary VersionInfo path (@misaka-coder)
- [x] **7.** Version detection: Admin API fallback path — honor system cert store, log clear error on TLS failure, **NO `-SkipCertificateCheck`** (@misaka-coder)

### PR #3b: Pre-flight framework (task 8) — SHIPPED 2026-05-18

- [x] **8.** Pre-flight check framework — all 7 checks from SDD §6.1 step 2 (check 2g uses `max_backup_age_hours`, check 2d uses creds from task 2, check 2e Phase 1 scope: cert exists + non-zero per SDD §6.1 2e update) (@misaka-coder)

### PR #4: Dry-run + release (tasks 10, 13, 14, 15) — NEXT

- [ ] **10.** Dry-run mode flag and reporting (logging consumer) (@misaka-coder)
- [ ] **13.** Code review pass (@hermione-reviewer)
- [ ] **14.** README update reflecting Phase 1 capabilities (@shizuku-docs)
- [ ] **15.** Cut tag v0.1.0 once dry-run mode works on a test host (@leia-github)

---

## Phase 1 Risks

Tracked per Ripley's call 2026-05-17. Misaka and Hermione: check this list when picking up work.

1. **Pre-flight 2g threshold unspecified** — `max_backup_age_hours` (default 24) being added to config schema by Ariadne in parallel. Precondition for task 4.
2. **DPAPI scope (SDD §15 risk 2)** — DPAPI-encrypted creds are bound to user + machine. The EncryptCreds PR (task 2) must document the re-encrypt step for credential migration.
3. **Admin API TLS handling (task 7)** — honor the system cert store, log a clear error on TLS failure, and do **not** ship `-SkipCertificateCheck`. A bypass flag undermines the safety guarantee.

---

## Deferred Follow-ups (Phase 1 review)

Items Hermione flagged during PR #1 review. Not blocking PR #2.

- [ ] **S1 — Logging file collision hardening:** switch `FileMode::Append` to `FileMode::CreateNew` and catch `IOException` specifically with a remediation message. Ref: `src/lib/Logging.ps1` near the existing TODO comment. (@misaka-coder, earliest Phase 4)
- [x] **[RESOLVED 2026-05-17] S6 — Validate `creds_file` path at config-read time:** ~~pre-flight 2d already verifies decrypt, but an earlier path check gives a better error. Needs a Ripley call on whether the parser may assume the file exists when read.~~ Ripley chose option (b): parser does **not** stat `creds_file`. Reason: `EncryptCreds.ps1` produces `creds.xml`, so first-run legitimately has no file yet; shape-validation belongs in the parser, filesystem state belongs in pre-flight 2d (SDD §6.1 step 2d). See ADR-004 and SDD §5 parser-scope note. (@ripley-tech-lead decided, @misaka-coder no-op)
- [ ] **`upgrade_mode` default behavior:** parser currently leaves absent values absent; Phase 4 auto-detection will decide the default. (@ariadne-design SDD update + @ripley-tech-lead decision, earliest Phase 4)
- [ ] **Type-vs-fractional parser error split:** current "must be a JSON integer (got 'X' …)" wording is misleading when `X` is a string. Split into two messages. Ref: `src/lib/Config.ps1` `admin_port` and `max_backup_age_hours` integer-type errors. (@misaka-coder, low priority)
- [ ] **Validation order note (unknown-property-first):** parser flags unknown properties before missing-required-fields — intentional, but warrants a one-liner in SDD §5 or `Test-AllowedProperties` doc. (@ariadne-design)

### From PR #2 review (Hermione, second pass, 2026-05-17)

- [ ] **S2 — Empty password remediation hint:** after "password cannot be empty.", append "Re-run EncryptCreds.ps1 and enter a non-empty password at the prompt." Ref: `src/lib/EncryptCreds.ps1` empty-password check. (@misaka-coder, low priority)
- [ ] **S3 — Log the verified username, not the prompt input:** have `Save-ChrysalisCredentials` log `$verify.UserName` on success rather than the prompt-time `$username`. Defense in depth for "logs match disk." Ref: `src/lib/EncryptCreds.ps1` success log line. (@misaka-coder, low priority)
- [ ] **S4 — Test the null-Source defensive branch in `Resolve-FmsadminPath`:** add a one-liner test where the `Get-Command fmsadmin` mock returns `Source = $null`. Ref: `tests/sudofmsadmin.Tests.ps1`. (@misaka-coder or @kaylee-tests, low priority)
- [ ] **S5 — Assert fmsadmin-not-found logs the Error + Remediation lines:** current test asserts exit code only. Extend to verify the log content (uses the `-LogRoot` injection pattern from B1). Ref: `tests/sudofmsadmin.Tests.ps1`. (@misaka-coder, low priority)
- [ ] **S6 — `Invoke-Fmsadmin` exit-code propagation manual test:** mock-based test masks the real `$LASTEXITCODE` behaviour. Add a manual-test note in the test file header explicitly calling out exit-code propagation. Ref: `tests/sudofmsadmin.Tests.ps1` header. (@kaylee-tests, earliest Phase 1 manual test on the FMS test host)
- [ ] **S7 — Tighten auto-invocation guard:** `$MyInvocation.InvocationName -ne '.'` fires for `&`-style invocations too. Either tighten to `$MyInvocation.CommandOrigin -eq 'Runspace'` (PS 5.1 supports it), or update the comment to acknowledge "any non-dot-source invocation runs the body." Ref: `src/lib/EncryptCreds.ps1`, `src/lib/sudofmsadmin.ps1` auto-invocation guards. (@misaka-coder, low priority)
- [ ] **N4 — `Get-Content -Raw` in runbook:** `docs/runbooks/credentials.md` line ~24 calls `Get-Content ... | ConvertFrom-Json` without `-Raw`. Works in 5.1 (line-array gets joined), but inconsistent with `Config.ps1` style. Optional fix. (@shizuku-docs)
- [ ] **N5 — Runbook references `.\chrysalis.ps1 -DryRun` before that entry point exists:** flag in the runbook with "(coming in v0.1.0)" or generalize until PR #4 lands the entry point. (@shizuku-docs)

### From PR #3a review (Hermione, second pass, 2026-05-17)

- [ ] **S2 — Coordinator `admin_port` pre-check:** `Get-FmsVersion` casts `[int] $Config.fms.admin_port` without verifying presence. Parser already guards, but a one-line guard here would give a clearer error to programmatic callers. Ref: `src/lib/VersionDetection.ps1` `Get-FmsVersion`. (@misaka-coder, low priority)
- [ ] **S3 — Misleading "script-scoped" comment:** file header implies private helpers but PowerShell `.ps1` dot-source exports every top-level function. Fix the comment (or promote to `.psm1` + `Export-ModuleMember` — overkill). Ref: `src/lib/VersionDetection.ps1` file header. (@misaka-coder, low priority)
- [x] **S5 — Preemptive PSSA worry on `Convert-AdminApiException`:** Hermione confirmed `Convert-` is approved and won't flag. Logged as "no action needed" in case the flagged-anyway note in Misaka's report leads someone to rename without checking. (closed — no action)
- [ ] **S7 — PE-VersionInfo test should `Set-ItResult -Skipped` on stripped images:** rather than silently passing the regex check when ProductVersion is empty. Ref: `tests/VersionDetection.Tests.ps1` happy-path binary test. (@kaylee-tests, low priority)
- [ ] **N1 — Capitalization mismatch in 401 test expectation:** source has `"Credentials"`, test matches `*credentials*`. `-like` is case-insensitive in PowerShell so it passes, but matching case helps grep. Ref: `src/lib/VersionDetection.ps1` 401 throw + `tests/VersionDetection.Tests.ps1` assertion. (@misaka-coder, lowest priority)
- [ ] **N2 — `ServicePointManager.SecurityProtocol` is a global mutation at file-load:** harmless today but document the side-effect explicitly in the file header. Ref: `src/lib/VersionDetection.ps1` top of file. (@misaka-coder, low priority)
- [ ] **N3 — `StreamReader` not disposed on exception in `Convert-AdminApiException`:** wrap in try/finally. Minor handle leak. Ref: `src/lib/VersionDetection.ps1` body-extraction block. (@misaka-coder, low priority)
- [ ] **N4 — `[GC]::Collect()` for residual plaintext password:** documented in code; honest comment names the residual risk. File as Phase 4 hardening only if a security audit asks. (@misaka-coder, conditional, earliest Phase 4)
- [ ] **N6 — Verbose candidate accumulator in `Read-AdminApiVersion`:** works as written, minor simplification possible with early-return foreach. (@mikasa-simplifier, lowest priority — when she's looking for a cut)
- [ ] **N7 — Optional vs. mandatory `-LogContext`:** every `Write-Log` is `$null`-guarded; cleaner if `-LogContext` were mandatory once Phase 1 entry points exist. Ref: `src/lib/VersionDetection.ps1` all `Write-Log` call sites. (@misaka-coder, earliest PR #4 once entry points land)
- [x] **Josh-suggestion-2 — Hardcoded test versions/paths (2026-05-17)**: Closed no-action. Ripley reviewed every fixture: pattern-based assertions and example-config regression guards are correct as-is. A `$script:TestVersion` constant would not save maintenance. Rationale captured in Ripley's PR #3b kickoff thread.

### From PR #3b review (Hermione, 2026-05-18)

Hermione's blocking and should-fix items (S1 2d Test-Path pre-check, S2 GiB labeling, N3 sort multi-file Detail, N5 path in 2d Pass Detail) were all addressed in PR #3b's review-fix commit and are closed. Only the four nits Misaka punted on are filed below.

- [ ] **N2 — `Get-PreFlightDriveRoot` non-Windows fallback wording:** returns the full input path when no drive letter is exposed, producing odd Detail strings like "install root drive '/var/lib/fms'". Phase 5 concern only. Ref: `src/lib/PreFlight.ps1` `Get-PreFlightDriveRoot`. (@misaka-coder, earliest Phase 5)
- [ ] **N4 — `New-PreFlightCheckException` defined after first use:** PowerShell resolves at call time so it works, but top-to-bottom readers hit the calls before the definitions. Reorder for readability. Ref: `src/lib/PreFlight.ps1` lines ~461 and ~479. (@misaka-coder or @mikasa-simplifier, lowest priority)
- [ ] **N6 — 2g remediation should quote the full `fmsadmin backup` invocation:** currently just says "Run 'fmsadmin backup'". Quote the actual recommended invocation with `-y -d <path> -t <name>` so the operator can copy-paste. Ref: `src/lib/PreFlight.ps1` 2g Fail Remediation. (@shizuku-docs, low priority)
- [ ] **N7 — 2c's "file a bug" Remediation should name the bug tracker:** add `https://github.com/joshuascottpaul/chrysallis/issues` to the remediation text. Ref: `src/lib/PreFlight.ps1` 2c Remediation. (@misaka-coder, low priority)

---

## Phase 4 Tasks (filed 2026-05-17)

Filed but not next — Phase 1 PR #3b is still the active work. Do not promote until Phase 1 ships.

### Admin API discovery (replaces config-driven values where FMS can be queried)

Ripley's call 2026-05-17: API value wins for "host state" (backup folder, admin port reachable, install root, configured schedules). Config wins for "operator intent" (target_version, installer URLs, sequences, max_backup_age_hours). Disagreement on host state is a pre-flight failure with remediation — no silent reconciliation, no `--update-config` auto-rewrite in v0. Multiple-backup case: auto-pick newest backup that satisfies max_backup_age_hours; override via `--backup <id>`; abort (not prompt) if zero qualify.

- [ ] **P4-API-1.** Reconnaissance: walk the SoliantMike FM-Admin-API-Tool repo (https://github.com/SoliantMike/FM-Admin-API-Tool) and Claris docs (https://help.claris.com/en/admin-api-guide/content/index.html). Produce a table of (config key chrysalis reads today, candidate Admin API endpoint, FMS version that introduced it, response shape). Deliverable: a short doc under `docs/design/` or `docs/decisions/` ready for Ariadne's Phase 4 design pass. (@nausicaa-explorer)
- [ ] **P4-API-2.** ADR-XXX: conflict policy (API vs config) + backup-selection algorithm (auto-pick-newest + `--backup <id>` override). Gated on P4-API-1. (@ariadne-design)
- [ ] **P4-API-3.** Implementation: extend `src/lib/VersionDetection.ps1` (or a new `src/lib/AdminApiDiscovery.ps1`) with discovery endpoints; wire pre-flight checks to use API values where ADR-XXX dictates; document operator-visible behavior changes in the runbook. Gated on P4-API-1 and P4-API-2. (@misaka-coder)

---

## Later Phases

See SDD §14 for Phases 2-6:

- Phase 2: Upgrade execution
- Phase 3: Rollback
- Phase 4: Hardening + first production use (low-stakes client) + Admin API discovery (see Phase 4 Tasks block above).
- Phase 5: Cross-platform (macOS + Linux)
- Phase 6: Polish, multi-machine support (v1 deliverable per Decision 6), Slack notifications (per Decision 9), public v1.0 release (per Decision 8)
