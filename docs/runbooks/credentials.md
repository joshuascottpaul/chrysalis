# Credentials Runbook

**Status:** Stub. Fuller examples and real terminal output land in Phase 4 (Hardening), once the first production upgrade gives us a real operator's confusion to learn from.

## What this is

chrysalis needs to call `fmsadmin` with the FMS admin username and password to stop services, run smoke tests, and roll back. It never stores that password in plaintext. Instead, it encrypts the credentials using Windows DPAPI and writes them to `creds.xml` at the path you set in `config.json` under `fms.creds_file`. DPAPI scopes that encrypted blob to a single user account on a single machine, which means the file is only decryptable by the same Windows user logged in to the same host that wrote it. That is a deliberate constraint (see SDD §10 for the full design and §15 risk 2 for why we accepted the operational cost).

The practical consequence: any time the user, the host, or the password changes, you need to re-encrypt.

## First-time setup

Log in to the FMS host via RDP as the user who will run chrysalis upgrades. From the chrysalis folder, run:

```powershell
.\EncryptCreds.ps1
```

The script prompts for the FMS admin username and the FMS admin password. It writes the encrypted blob to the path configured in `config.json` at `fms.creds_file`. Do this once per host, per user.

Confirm the file landed where you expected:

```powershell
Test-Path (Get-Content .\config.json | ConvertFrom-Json).fms.creds_file
```

You should see `True`.

## When you need to re-encrypt

DPAPI is strict about who can read what it wrote. Re-encrypt whenever any of the following happen:

- The admin user account on the host changes. A different person is logging in to run upgrades.
- The host is moved or rebuilt. DPAPI keys are machine-scoped; they do not survive a migration.
- The FMS admin password rotates.
- `creds.xml` becomes corrupted or is accidentally deleted.

## How to re-encrypt

Log in as the user who will run chrysalis going forward. From the chrysalis folder:

```powershell
.\EncryptCreds.ps1 -Force
```

`-Force` overwrites the existing `creds.xml` after prompting for the new username and password. If you prefer to be cautious, rename the existing file first (e.g. `creds.xml.bak`) and run the script without `-Force`.

Then confirm chrysalis can decrypt the new file by running a dry-run upgrade:

```powershell
.\chrysalis.ps1 -DryRun
```

A clean dry-run means the credentials are good. A decrypt error means something is still wrong — see Troubleshooting below.

## Troubleshooting

**`creds.xml not found`**
The file does not exist at the path configured in `config.json`. Run `.\EncryptCreds.ps1` to create it. If the file exists but the script does not see it, check the `fms.creds_file` path in `config.json` matches where you expect.

**`Cannot decrypt creds.xml`**
DPAPI refused to unwrap the blob. The two common causes are: you are logged in as a different Windows user than the one who originally encrypted it, or the host has changed (rebuild, migration, restored backup). Log in as the original user if you can, otherwise re-encrypt with `.\EncryptCreds.ps1 -Force`.

**`Access denied writing creds.xml`**
The current user cannot write to the path in `config.json` at `fms.creds_file`. Either change the path to a location the user owns (a folder under the user profile is a safe default), or grant write permission to the existing path.

## What chrysalis never logs

For the avoidance of doubt: chrysalis never writes the password or the encrypted blob to its log files. Log entries record the path to `creds.xml`, the FMS admin username, and the success or failure of the decrypt and `fmsadmin` calls. If you ever see a password fragment in a log, that is a bug — file it.
