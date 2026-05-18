# chrysalis TODO

Current phase: 1 (Foundation). See `docs/design/` section 14 for the full timeline.

2026-05-17: PR #1 (Foundation) reviewed and cleared by Hermione; ready to ship. PR #2 (Credentials helpers) is next.
2026-05-17: PR #2 (Credentials helpers) reviewed and cleared by Hermione (second pass); ready to ship. PR #3 (Detection and pre-flight) is next.
2026-05-17: PR #3a (Version Detection) reviewed and cleared by Hermione (second pass); ready to ship. PR #3b (pre-flight framework) is next, gated on first green CI run.

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
   Private until v1.0. Matches SDD §14 Phase 6 ("Public GitHub release v1.0"). Reduces premature-polish pressure during Phases 1–3 and keeps early bugs internal.

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

### PR #3b: Pre-flight framework (task 8) — gated on first green CI run

- [ ] **8.** Pre-flight check framework — all 7 checks from SDD §6.1 step 2 (check 2g uses `max_backup_age_hours`, check 2d uses creds from task 2, check 2e Phase 1 scope: cert exists + non-zero per SDD §6.1 2e update) (@misaka-coder)

### PR #4: Dry-run + release (tasks 10, 13, 14, 15)

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

---

## Later Phases

See SDD §14 for Phases 2-6:

- Phase 2: Upgrade execution
- Phase 3: Rollback
- Phase 4: Hardening + first production use (low-stakes client)
- Phase 5: Cross-platform (macOS + Linux)
- Phase 6: Polish, multi-machine support (v1 deliverable per Decision 6), Slack notifications (per Decision 9), public v1.0 release (per Decision 8)
