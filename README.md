# chrysalis

A cross-platform CLI for upgrading and rolling back FileMaker Server installations. Windows is the primary target; macOS and Linux are secondary (Phase 5). Built and maintained by Neo Code Software Limited. chrysalis is pre-v1.0 and not yet recommended for production use.

## Status

- **Current phase:** Phase 1 (Foundation). Wraps up with v0.1.0 once the manual dry-run gate on a real FMS host has been cleared.
- **What works today:** `chrysalis.ps1 -DryRun` parses your config, detects the installed FMS version, runs the seven pre-flight checks, and reports what an upgrade *would* do. Nothing destructive is executed in this phase.
- **What is coming:**
  - Phase 2: upgrade execution (the same workflow, without `-DryRun`).
  - Phase 3: rollback.
  - Phase 4: production hardening (cross-major auto-detection, retries, observability polish).
  - Phase 5: macOS and Linux support.
  - Phase 6: multi-machine orchestration and the v1.0 release.

The live tracker lives in [`TODO.md`](./TODO.md). The full software design doc lives in [`docs/design/`](./docs/design/).

## Quickstart (Phase 1 dry-run)

The Phase 1 path is "drop the folder on the FMS host and inspect the report." Five steps:

1. Clone or download this repo onto the FMS host.
2. Copy `config/config.example.json` to `config.json` at the repo root.
3. Edit `config.json` with your `target_version`, installer URLs and SHA-256s, install root, admin port, and credentials file path.
4. Run the credentials helper to create a DPAPI-encrypted credentials file:

   ```powershell
   .\src\lib\EncryptCreds.ps1
   ```

5. Run the dry-run and read the report:

   ```powershell
   .\chrysalis.ps1 -DryRun
   ```

The dry-run writes a structured log under `.\logs\` and a human-readable summary to the console. If you keep `config.json` somewhere else, pass `-ConfigPath`. If you want logs somewhere other than `.\logs\`, pass `-LogRoot`.

### Exit codes

| Code | Meaning |
| ---- | ------- |
| 0    | Dry-run completed; pre-flight passed. The upgrade would proceed when Phase 2 ships. |
| 1    | Dry-run completed; pre-flight failed. Remediation steps are in the log. |
| 2    | Refused: `-DryRun` was not supplied. Phase 1 only supports dry-run. |
| 3    | Unhandled exception. Stack trace is in the log file (or stderr if the log could not be opened). |

## Requirements

- Windows Server 2016 or later. PowerShell 5.1 ships with the OS.
- A FileMaker Server installation (currently any of the 20.x or 21.x lines; see Decision 5 for the forward-version policy).
- Admin credentials for the FMS host's admin account. chrysalis stores these via DPAPI, so the encrypted blob is bound to the Windows user that created it. See [`docs/runbooks/credentials.md`](./docs/runbooks/credentials.md).
- PowerShell execution policy that allows local scripts. The one-time, per-user setup is:

  ```powershell
  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
  ```

## Configuration

chrysalis is configured by a single `config.json` at the repo root (or wherever you point it with `-ConfigPath`).

- [`config/config.schema.json`](./config/config.schema.json) is the JSON Schema. Every supported field, its type, and its constraints live there.
- [`config/config.example.json`](./config/config.example.json) is a filled-in starting point you can copy and edit.

A couple of details worth knowing up front:

- `target_version` is a semver-ish string of the form `MAJOR.MINOR.PATCH`. It must match a key under `installers`.
- `max_backup_age_hours` defaults to `24`. Pre-flight rejects the run if the most recent native FMS database backup is older than this threshold.

Refer to the schema and the example rather than memorising fields — they stay accurate as chrysalis evolves.

## Project structure

```
chrysalis/
├── chrysalis.ps1            # Entry point (Phase 1 dry-run; Phase 2 upgrade)
├── config/
│   ├── config.schema.json   # JSON Schema for config.json
│   └── config.example.json  # Starting point
├── src/lib/                 # Library scripts
│   ├── Logging.ps1
│   ├── Config.ps1
│   ├── EncryptCreds.ps1
│   ├── VersionDetection.ps1
│   ├── PreFlight.ps1
│   └── sudofmsadmin.ps1
├── tests/                   # Pester 5.x tests
├── docs/
│   ├── design/              # Software design doc
│   ├── decisions/           # ADRs
│   └── runbooks/            # Operational guides
└── PSScriptAnalyzerSettings.psd1
```

## Prior art

The `EncryptCreds` and `sudofmsadmin` patterns are adapted from [`ernestkoe/powershell-fms`](https://github.com/ernestkoe/powershell-fms) (MIT-licensed). chrysalis is a fresh implementation, not a fork; the decision to start greenfield and the credit owed are recorded in [ADR-001](./docs/decisions/ADR-001-greenfield-vs-fork-powershell-fms.md).

## License

MIT. See [`LICENSE`](./LICENSE). Copyright Neo Code Software Limited.

## Contributing

chrysalis is pre-v1.0 and primarily maintained by Neo Code. Issues are welcome. Pull requests are accepted at maintainer discretion. Branch protection enforces CI on every PR — PSScriptAnalyzer and Pester both run on `windows-latest` and must pass before merge.
