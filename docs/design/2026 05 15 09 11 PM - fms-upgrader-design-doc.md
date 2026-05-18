# FileMaker Server Upgrade Tool - Design Doc

**Project:** fms-upgrade (productized as chrysalis)
**Owner:** Josh / Neo Code
**Date:** 2026-05-15
**Status:** Draft v0.4

**2026-05-17:** §13 open questions resolved (see §13). Six additional operational decisions captured in TODO.md and reflected in §2, §5, §6.2, §14 below.
**2026-05-17:** added cross-references to ADR-001/002/003.
**2026-05-17:** specified max_backup_age_hours in config schema (default 24); resolves pre-flight 2g threshold (per Ripley's Phase 1 sequencing call).
**2026-05-17:** §10 — added `sudofmsadmin (elevation wrapper)` subsection describing cross-platform behavior (Windows pass-through, macOS/Linux `sudo fmsadmin`). Resolves PR #2 direction per Ripley.
**2026-05-17:** §5 — documented parser vs. pre-flight separation of concerns for `creds_file` (closes deferred item S6); see ADR-004.
**2026-05-17:** §6.1 step 2e — added Phase 1 scope clarification narrowing the license check to existence + non-zero size; cross-major license-coverage semantics deferred to Phase 4 (§14) per Ripley, gated operationally by Decision 7 (§13). Scope clarification only; not ADR-worthy.

---

## 1. Overview

A command-line tool that automates FileMaker Server (FMS) version upgrades and rollbacks on Windows (primary), macOS, and Linux (secondary). Runnable by Neo Code FileMaker developers via Remote Desktop, with no install dependencies beyond what ships with the target OS.

The tool wraps Claris's existing silent install path with pre-flight checks, state backup, graceful service shutdown, post-upgrade smoke tests, and a deterministic rollback. It does not replace fmsadmin or the Claris installer. It sequences them safely.

---

## 2. Goals

- One command upgrades and rollbacks for FMS hosts
- No runtime installs. PowerShell on Windows, Bash + python3 on macOS/Linux
- Safe by default. Backup before any destructive action. Fail loud if pre-flight checks don't pass
- Auditable. Log every step. Conventional exit codes (0 = success)
- Rollback to any previously-installed version listed in config (within-major in v0; see §6.2)
- Output legible to a developer watching the terminal over RDP
- Single-machine FMS hosts in v0; multi-machine support (separate database + worker hosts) is a v1 deliverable in Phase 6

## Non-Goals

- Remote orchestration (SSH / WinRM in from a control host). Always run locally on the FMS host
- GUI or web UI. CLI only
- Patching FileMaker apps (.fmp12). That's FMUpgradeTool's job, separate concern
- Replacing FMS's own native database backup schedule

---

## 3. Users

**Primary.** Neo Code FileMaker developers, junior to senior. Connect via RDP. Want to drop a folder on the server, edit a config, run it, watch it succeed.

**Secondary.** Neo Code network admins. Capable of Mac and Linux paths, but most upgrades target Windows.

---

## 4. Architecture

### File Layout

```
fms-upgrade/
├── config.json              # Per-upgrade config, Claude-generated or hand-edited
├── fms-upgrade.ps1          # Windows entry point (primary)
├── fms-upgrade.sh           # macOS / Linux entry point
├── lib/
│   ├── EncryptCreds.ps1     # Forked from ernestkoe/powershell-fms
│   ├── ShutdownFMS.ps1
│   ├── StartFMS.ps1
│   ├── BackupState.ps1
│   ├── SmokeTest.ps1
│   └── Rollback.ps1
└── logs/                    # Per-run log files
```

### Runtime Dependencies

- Windows: PowerShell 5.1+ (ships with Windows Server 2016+). No modules required.
- macOS / Linux: Bash 4+ and python3. Both pre-installed on supported versions.

### External Dependencies

- Claris FileMaker Server installer (downloaded per config)
- Existing fmsadmin CLI on the host
- FMS Admin API on the host (used for verification)

---

## 5. Configuration

JSON. PowerShell parses natively with `ConvertFrom-Json`. Bash parses with `python3 -c`.

```json
{
  "target_version": "21.0.3",
  "upgrade_mode": "in_place",
  "installers": {
    "21.0.3": {
      "windows": "https://...",
      "macos": "https://...",
      "linux": "https://...",
      "sha256": "..."
    },
    "21.0.2": { "...": "..." },
    "20.3.2": { "...": "..." }
  },
  "fms": {
    "install_root_windows": "C:\\Program Files\\FileMaker\\FileMaker Server",
    "admin_port": 16001,
    "creds_file": "C:\\fms-upgrade\\creds.xml"
  },
  "backup_root": "C:\\FMS_Backups",
  "max_backup_age_hours": 24,
  "shutdown_sequence": [
    "FMSTB", "FMSE", "XDBC", "WPE", "FMDAPI", "ADMINSERVER", "SERVER"
  ],
  "startup_sequence": [
    "SERVER", "ADMINSERVER", "FMSE", "XDBC", "WPE", "FMDAPI", "FMSTB"
  ]
}
```

The `installers` block lists URLs for the target plus enough historical versions to support rollback to whatever is currently installed. `upgrade_mode` is `in_place` or `uninstall_reinstall`. In-place is fine for minor and patch bumps. Uninstall+reinstall is required for major version jumps where Claris does not support an in-place path.

`max_backup_age_hours` (integer, default 24) is the freshness threshold for the pre-flight 2g native-backup check (§6.1, §8). Sites with sub-daily native backup schedules can lower it; sites with daily backups keep the default. Omitted from `config.json` means 24.

**Versions in scope:** 20.x, 21.x, and forward versions (22.x and beyond) as Claris releases them. 19.x is out of scope (EOL — clients still on 19.x get manual upgrades). The `installers` block is the version registry; adding a new version means a config entry, not a code change.

**Parser scope vs. pre-flight scope.** The config parser performs string-shape validation only (required keys present, types correct, value formats well-formed). It does **not** check filesystem state — in particular, it does not verify that `fms.creds_file` exists on disk. First-run installations legitimately have no `creds.xml` yet (it is produced by `EncryptCreds.ps1`). Filesystem existence and decryptability of `creds_file` are gated by pre-flight check 2d (§6.1) before any destructive action. See [ADR-004](../decisions/ADR-004-config-parser-vs-preflight.md).

---

## 6. Workflows

### 6.1 Upgrade

```
1. Parse config and CLI args
2. Pre-flight
   2a. Detect current installed FMS version (binary VersionInfo, see §7)
   2b. Verify config has installer entry for current version (rollback safety)
   2c. Verify config has installer entry for target version
   2d. Verify admin credentials decrypt
   2e. Verify license covers target version (cross-major check).
       **Phase 1 scope:** the check verifies only that the FMS license file (`.fmcert`) exists at the configured path and is non-zero in size. Parsing the license file and asserting it actually covers the target version (cross-major coverage semantics) is deferred to Phase 4 (§14, "License validation against target version") and is gated operationally in the interim by Decision 7's v0 refusal of cross-major operations (§13, recorded in TODO.md).
   2f. Verify disk space for installer + backup
   2g. Verify recent native FMS DB backup exists. "Recent" is defined by `config.max_backup_age_hours` (integer hours, default 24). A backup older than this threshold fails pre-flight; remediation is documented in §13 Decision 2 (refuse, prompt operator to run `fmsadmin backup`).
3. Backup state to {backup_root}\{timestamp}\ (see §8)
4. Graceful shutdown
   - fmsadmin disconnect client (with user-facing warning message)
   - fmsadmin close
   - Stop services in shutdown_sequence order
5. Download installer if not cached. Verify sha256
6. Run installer
   - in_place: Setup.exe /qb+ (silent with progress bar)
   - uninstall_reinstall: uninstall existing, then Setup.exe with Assisted Install.txt
7. Wait for services to settle
8. Smoke tests (§9)
9. Print summary
   - Pass: success output, log file path, new version
   - Fail: failure output, log file path, rollback instruction
```

> See [ADR-003](../decisions/ADR-003-no-force-flag-v0.md) for why pre-flight failures are not bypassable in v0.

### 6.2 Rollback

Invoked via `-Rollback` flag. Assumes a prior backup exists.

```
1. Read version.txt from most recent backup folder (or specified -BackupId)
2. Verify config has installer entry for that version
3. Graceful shutdown (same sequence as upgrade)
4. Uninstall current FMS
5. Clean install of older version using Setup.exe with stored Assisted Install.txt
6. Restore from backup:
   - Conf\ directory
   - Schedules.xml
   - SSL certificates
   - License file
   - Plugins
   - Registry keys
7. Start services in startup_sequence order
8. Smoke tests
9. Print summary
```

Critical: rollback is **not** "rerun the older installer." FMS does not support downgrade by reinstall. The flow is genuine uninstall + clean install + restore.

**Cross-major rollback is refused in v0.** Within-major only (e.g. 21.0.3 → 21.0.2). Cross-major rollback (e.g. 21.x → 20.x) carries hosted `.fmp12` file-format, `Schedules.xml` schema, and plugin ABI compatibility risk that must be characterized and gated explicitly. An opt-in `-AllowCrossMajor` flag with stronger warnings is a Phase 4+ feature once those risks are documented.

---

## 7. Version Detection

Primary path. Read `ProductVersion` from `fmserver.exe`:

```powershell
(Get-Item "C:\Program Files\FileMaker\FileMaker Server\Database Server\fmserver.exe").VersionInfo.ProductVersion
```

Returns a string like `21.0.3.305`. Works pre and post upgrade. No registry parsing, no XML hunting.

macOS equivalent: read `CFBundleShortVersionString` from the FMS app bundle's Info.plist.

Fallback. Hit the Admin API metadata endpoint:

```
GET https://localhost:16001/fmi/admin/api/v2/server/metadata
```

Returns version in JSON. Useful when the binary path varies or after partial upgrades.

---

## 8. Backup Strategy

Backup target: `{backup_root}\{timestamp}\`

Contents:

1. `Schedules.xml` (FMS scheduled backups configuration)
2. `Conf\` directory (server configuration files)
3. SSL certificates from the FMS cert store
4. License file (`.fmcert`)
5. Custom plugins from `Database Server\Extensions\`
6. Web Publishing settings if customized
7. Registry export of `HKLM:\SOFTWARE\FileMaker` (Windows only)
8. Current `Logs\` directory (forensics if upgrade fails)
9. `version.txt` containing the detected pre-upgrade version
10. Copy of the `Assisted Install.txt` used for this install (needed for rollback's clean install)

We do **not** copy hosted database files (.fmp12). Those are large, change constantly, and are already covered by FMS's native scheduled backup. Pre-flight verifies a recent native backup exists; if not, the tool refuses to run. "Recent" is governed by `config.max_backup_age_hours` (default 24; see §5).

---

## 9. Smoke Tests

Two independent checks. Both must pass for upgrade to report success.

1. **fmsadmin status.** `fmsadmin list files` returns clean exit code and at least one hosted file. Confirms the database server responds to admin commands.
2. **Client port.** TCP port 5003 listening on localhost. Confirms the database server accepts client connections.

Optional third check if `admin_port` is configured:

3. **Admin API metadata.** `GET https://localhost:{admin_port}/fmi/admin/api/v2/server/metadata` returns 200 with the expected version. Confirms admin server up. Independent verification path from fmsadmin CLI.

No hardcoded smoke-test database. Tests are agnostic to what's hosted.

---

## 10. Credentials

Store FMS admin credentials encrypted using Windows DPAPI via the PSCredential pattern from `ernestkoe/powershell-fms`. Credentials are encrypted against the running user account on the FMS host. No plaintext on disk. No env var.

Setup, one-time per host:

```powershell
.\EncryptCreds.ps1
# prompts for username and password, writes encrypted creds.xml
```

Subsequent runs read `creds.xml` automatically. If the running user changes (e.g., different admin account), creds must be re-encrypted.

Cross-platform note. macOS uses Keychain. Linux uses libsecret. Out of scope for v0.

### sudofmsadmin (elevation wrapper)

`sudofmsadmin` is the cross-platform shim that higher-level scripts (shutdown, startup) call instead of invoking `fmsadmin` directly. The contract is identical across platforms; the implementation differs.

- **Windows (`sudofmsadmin.ps1`).** Transparent pass-through. Invokes `fmsadmin` with the supplied arguments and forwards exit code, stdout, and stderr. Elevation on Windows is satisfied by running chrysalis itself as an administrator account — that is an operator concern, handled at the chrysalis entry-point level, not inside the wrapper.
- **macOS / Linux (`sudofmsadmin.sh`, Phase 5).** Wraps `sudo fmsadmin`. Requires the operator to have the corresponding sudoers entry; the README runbook documents the exact sudoers line. The wrapper itself adds no privilege-elevation logic beyond `sudo`.

Rationale: keeping the script name identical across platforms lets the shutdown and startup sequences (§6.1 step 4, §6.2 step 3 / step 7) call `sudofmsadmin` without OS-detecting at the call site. The OS-specific elevation behavior is contained in a single file per platform. The credit obligation for the `sudofmsadmin` pattern itself is handled per [ADR-001](../decisions/ADR-001-greenfield-vs-fork-powershell-fms.md) (greenfield with per-file header crediting `ernestkoe/powershell-fms`).

---

## 11. Distribution

- Public GitHub repo, MIT licensed
- Releases: zip containing scripts + `config.json` template + README
- No installer. Developer drops the folder anywhere on the FMS host and runs from there
- PowerShell execution policy: README documents `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser` or, eventually, code-signed scripts

---

## 12. Prior Art

**ernestkoe/powershell-fms** (MIT). PowerShell scripts for FMS admin. We fork or borrow `EncryptCreds`, `ShutdownFMS`, `StartFMS`, `sudofmsadmin` patterns. No upgrader exists in this repo. We contribute one back.

**dansmith65/FileMaker-LetsEncrypt-Win.** Uses Windows Credential Manager. Alternative credential approach we may adopt later.

**Claris official docs.** Silent install via `Setup.exe` with `/qb+`, `/qn`, `/qn+` switches and `Assisted Install.txt` personalization file. Our tool wraps this, does not replace it.

> See [ADR-001](../decisions/ADR-001-greenfield-vs-fork-powershell-fms.md) for the alternatives considered.

---

## 13. Resolved Decisions (2026-05-17)

1. Fork `ernestkoe/powershell-fms` outright, or write greenfield and credit the patterns? Fork is faster but couples us to their structure.
   **Decision:** Greenfield with credit. Adapt only the patterns we need (`EncryptCreds`, `sudofmsadmin`). Credit `ernestkoe/powershell-fms` in the README and in per-file headers.
2. Should the tool trigger a fresh native FMS DB backup if none is recent, or just refuse to run? Refuse is safer. Trigger is friendlier.
   **Decision:** Refuse. Print remediation (run `fmsadmin backup`, then re-run). Auto-triggering an FMS DB backup contradicts the §2 non-goal of replacing the native backup schedule and risks unbounded runtime during a maintenance window.
3. Notification channel beyond stdout for v1? Slack webhook. Email. Both.
   **Decision:** Slack webhook only for v1. SMTP/email deferred — build later if asked.
4. Should `Assisted Install.txt` be config-driven (license key, install path, port assignments) or shipped per-version as a static file?
   **Decision:** Hybrid. Per-version template skeletons in `lib/templates/`, with values substituted from `config.json` at runtime. License keys never live in the repo. The resolved file is captured in the backup folder (§8 item 10) so rollback's clean install has exactly what was used.

Six additional operational decisions (FMS versions in scope, multi-machine timing, cross-major rollback policy, `-Force` flag, public repo timing, first test target) were resolved the same day and are captured in TODO.md. Their design impact is reflected in §2, §5, §6.2, and §14.

---

## 14. Development Timeline

Estimates assume part-time work, roughly 1-2 days per week from a single developer. Adjust if dedicated. Each phase ends with a working, testable deliverable.

### Phase 1: Foundation (Week 1-2)

**Goal:** Working skeleton with config and pre-flight. No destructive actions yet.

Tasks:

- Repo setup, MIT license, README scaffolding
- Fork or adapt `EncryptCreds.ps1` and `sudofmsadmin.ps1` from `ernestkoe/powershell-fms`
- `config.json` schema and PowerShell parser
- Version detection (binary VersionInfo + Admin API fallback)
- Pre-flight check framework (all checks listed in §6.1 step 2)
- Logging infrastructure with timestamped log files in `./logs/`
- Dry-run mode (executes all checks, performs no changes)

**Deliverable:** `fms-upgrade.ps1 -DryRun` runs end-to-end on a test FMS host and prints exactly what it would do at each step.

### Phase 2: Upgrade Execution (Week 3-4)

**Goal:** Actually upgrade a test FMS instance in-place.

Tasks:

- Backup logic for all artifacts in §8
- Graceful shutdown sequence (FMSTB through SERVER)
- Installer download with HTTP resume support
- SHA256 verification
- `Setup.exe /qb+` silent install execution
- Startup sequence
- Smoke tests (fmsadmin + port 5003)

**Deliverable:** Upgrades a dev FMS host from 21.0.2 to 21.0.3 cleanly. Pass/fail output matches design.

### Phase 3: Rollback (Week 5)

**Goal:** Working rollback path on a test FMS.

Tasks:

- Read pre-upgrade state from backup folder
- Uninstall current FMS
- Clean install of older version with stored `Assisted Install.txt`
- Restore Conf, Schedules.xml, certs, license, plugins, registry
- Rollback smoke tests
- `-Rollback` and `-BackupId` CLI args

**Deliverable:** Rollback from 21.0.3 back to 21.0.2 works end-to-end. Hosted databases remain functional. Schedules and SSL certs survive intact.

### Phase 4: Hardening (Week 6-7)

**Goal:** Ready for first production FMS host.

Tasks:

- Cross-major-version detection, auto-switch to `uninstall_reinstall` mode
- License validation against target version
- Pre-flight HEAD requests to verify installer URLs are live before destructive steps
- Error path testing: download failure, install failure, shutdown timeout, smoke test failure
- Retry logic with sensible defaults
- README + runbook documentation
- Code review with another Neo Code dev

**Deliverable:** Used to upgrade one production FMS host. Low-stakes client first. Rollback path tested in staging environment.

### Phase 5: Cross-Platform (Week 8-9)

**Goal:** macOS and Linux parity.

Tasks:

- `fms-upgrade.sh` entry point
- python3-based JSON parsing
- macOS Keychain credential storage
- Linux libsecret credential storage
- Path abstractions for backup, FMS install location, plist/Info reading
- Smoke test parity across platforms
- Per-platform installer execution (.pkg on macOS, .rpm on Linux)

**Deliverable:** Same flows run on a macOS FMS host and an Ubuntu FMS host with identical CLI semantics.

### Phase 6: Polish, Multi-Machine Support & v1.0 Release (Week 10+)

**Goal:** Quality-of-life improvements, multi-machine FMS support, and public release.

Tasks:

- Multi-machine FMS deployment support (separate database + worker hosts). Per-host invocation with a documented coordination sequence: shut down workers first → upgrade DB host → bring workers back. Each host runs chrysalis independently; no remote orchestration (per §2 non-goal).
- Slack webhook notifications
- Claude for Chrome helper that scrapes the Claris portal for current installer URLs and writes `config.json` automatically
- Optional: code-signed PowerShell scripts to avoid execution policy friction
- Public GitHub release v1.0 (repo flips from private to public; see Distribution §11)
- Announcement on Claris Community + relevant Slack groups

**Deliverable:** v1.0 release with multi-machine support, Slack notifications, and public repo. Blog post or community announcement.

> See [ADR-002](../decisions/ADR-002-single-machine-v0-multi-machine-v1.md) for why multi-machine support is deferred to v1.

### Milestone Summary

| Week | Milestone |
| ---- | --------- |
| 2  | Pre-flight skeleton runs in dry-run mode |
| 4  | First successful test upgrade end-to-end |
| 5  | First successful test rollback end-to-end |
| 7  | First production upgrade (low-stakes client) |
| 9  | Cross-platform parity (macOS + Linux) |
| 10+ | Multi-machine support + Slack notifications + public v1.0 release |

### Resource Notes

- Roughly 10-15 actual developer days across the full timeline
- Test FMS instances required: one Windows Server (any supported FMS version), one macOS host, one Ubuntu host. VM or bare metal both fine.
- Test license keys for at least two FMS major versions to validate cross-major upgrade path
- A throwaway hosted .fmp12 with non-trivial schedules and SSL config to exercise backup/restore meaningfully

### Critical Dependencies

1. Access to Claris portal credentials for fetching installer URLs (Phase 2 onward)
2. A non-production FMS host with hosted DBs and schedules for realistic testing (Phase 1 onward)
3. A second pair of eyes for code review before Phase 4 production rollout
4. Willingness to dogfood internally before public release (Phases 4-5)

---

## 15. Risks

1. **FMS installer changes between versions.** Silent install switches and `Assisted Install.txt` schema have been stable but not contractual. Mitigation: per-version smoke-test runs before rolling out to production hosts.
2. **DPAPI scope.** Credentials encrypted against one user account don't work for another. If the dev who set up creds leaves, someone needs to re-run `EncryptCreds.ps1`. Document this.
3. **Rollback assumes restore-able snapshot.** If backup step fails silently and we don't catch it, rollback is impossible. Mitigation: verify each backup artifact exists and is non-zero after the backup step.
4. **Installer URLs are not publicly accessible.** Claris portal requires login. Config must contain pre-resolved URLs at run time. Stale URLs fail at download step. Mitigation: pre-flight HEAD request to all listed installer URLs before doing anything destructive.
