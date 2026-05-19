# chrysalis.ps1
# chrysalis entry point. Orchestrates Phase 1 dry-run mode: parse config,
# detect FMS version, run pre-flight checks, report what would happen at
# each step. Upgrade execution lands in Phase 2.
# Supersedes the historical filename 'fms-upgrade.ps1' in SDD section 4.
# (Ariadne to fold this filename into SDD section 4 in a follow-up.)
# PowerShell 5.1 compatible.
#
# Phase 1 supports -DryRun only. Without -DryRun the entry point refuses
# with a clear message naming Phase 2 as the home of upgrade execution.
# Per ADR-003, there is no -Force, no -SkipCheck, no -AllowCrossMajor,
# no -SkipCertificateCheck, and no -Hostname (single-machine v0, ADR-002).
#
# Exit codes:
#   0 - DryRun complete; pre-flight passed.
#   1 - DryRun complete; pre-flight failed (remediation logged).
#   2 - Refused: -DryRun was not supplied. Phase 2 lands upgrade execution.
#   3 - Unhandled exception. Stack trace in the log file.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch] $DryRun,

    [Parameter(Mandatory = $false)]
    [string] $ConfigPath,

    [Parameter(Mandatory = $false)]
    [string] $LogRoot
)

$ErrorActionPreference = 'Stop'

# Capture entry-point parameters before dot-sourcing libs. src/lib/EncryptCreds.ps1
# is both a library AND an operator-facing script: it has its own param() block
# with $Path, $ConfigPath, $Force, $LogRoot. Dot-sourcing it from chrysalis.ps1
# executes that param() block in chrysalis.ps1's script scope, clobbering our
# $ConfigPath and $LogRoot to empty defaults. Stash them under different names
# before dot-sourcing, then use the stashed copies for the rest of the script.
$script:EntryConfigPath = $ConfigPath
$script:EntryLogRoot = $LogRoot
$script:EntryDryRun = [bool]$DryRun

# Resolve library paths relative to this script. $PSScriptRoot is the repo
# root (this file lives at the top level). The lib files live under src/lib/.
$script:ChrysalisRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:ChrysalisRoot)) {
    # $PSScriptRoot can be empty when the script body is executed in an
    # unusual host (e.g. piped from stdin). Fall back to the invocation path.
    $script:ChrysalisRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Path
}
$script:LibRoot = Join-Path -Path $script:ChrysalisRoot -ChildPath 'src/lib'

. (Join-Path -Path $script:LibRoot -ChildPath 'Logging.ps1')
. (Join-Path -Path $script:LibRoot -ChildPath 'Config.ps1')
. (Join-Path -Path $script:LibRoot -ChildPath 'EncryptCreds.ps1')
. (Join-Path -Path $script:LibRoot -ChildPath 'VersionDetection.ps1')
. (Join-Path -Path $script:LibRoot -ChildPath 'PreFlight.ps1')

function Resolve-ChrysalisEntryConfigPath {
    # Resolve the operator-supplied -ConfigPath, or fall back to ./config.json
    # next to this script. We deliberately fail loud with a remediation that
    # names config/config.example.json as the starting template - first-run
    # operators are the most common audience for this error.
    param(
        [string] $Explicit,
        [string] $ScriptRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) {
            throw "chrysalis: config file not found at '$Explicit'. Copy 'config/config.example.json' to this path and edit it for your host."
        }
        return $Explicit
    }

    $default = Join-Path -Path $ScriptRoot -ChildPath 'config.json'
    if (-not (Test-Path -LiteralPath $default -PathType Leaf)) {
        throw "chrysalis: no config file found at '$default'. Copy 'config/config.example.json' to '$default' and edit it for your host, or pass -ConfigPath."
    }
    return $default
}

function Write-PlannedUpgradeSteps {
    # Dry-run reporter for the SDD section 6.1 upgrade workflow. Every line is
    # Info-level; nothing here mutates state. The "Would back up..." timestamp
    # is computed at log time so re-runs reflect the moment the operator
    # actually invoked chrysalis. None of these lines invoke fmsadmin, the
    # installer, or the service controller - that's Phase 2.
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $Config,
        [Parameter(Mandatory = $true)] [pscustomobject] $LogContext
    )

    Write-Log -Context $LogContext -Severity Info -Message 'Planned upgrade steps (dry-run: nothing below is executed):'

    # Step 3: backup. Use [System.IO.Path]::Combine, NOT Join-Path, because
    # Join-Path probes the drive root via the PSDrive provider and throws on
    # a non-existent drive (e.g. running on macOS dev with a Windows-pathed
    # config: `Join-Path 'C:\Backups' '20260518-180000'` errors with "Cannot
    # find drive C"). The path here is purely for the log message; we never
    # touch the filesystem with it in dry-run.
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $backupRoot = $Config.backup_root
    $wouldBeBackupPath = [System.IO.Path]::Combine($backupRoot, $stamp)
    Write-Log -Context $LogContext -Severity Info -Message "Would back up state to '$wouldBeBackupPath' (SDD section 8 artifacts)."

    # Step 4: shutdown sequence
    $shutdownSeq = @($Config.shutdown_sequence) -join ', '
    Write-Log -Context $LogContext -Severity Info -Message "Would gracefully shut down FMS in order: $shutdownSeq"

    # Step 5: download installer + verify SHA-256
    $targetVersion = $Config.target_version
    $installerEntry = $null
    if ($null -ne $Config.installers -and $null -ne $Config.installers.PSObject.Properties[$targetVersion]) {
        $installerEntry = $Config.installers.$targetVersion
    }
    if ($null -ne $installerEntry) {
        # Installer URLs and hashes are config-supplied (the operator already
        # has them in their config.json). Logging them is safe.
        $windowsUrl = $installerEntry.windows
        $sha = $installerEntry.sha256
        Write-Log -Context $LogContext -Severity Info -Message "Would download installer for target version $targetVersion from '$windowsUrl'."
        Write-Log -Context $LogContext -Severity Info -Message "Would verify SHA-256 against '$sha'."
    } else {
        Write-Log -Context $LogContext -Severity Warn -Message "Would download installer for target version $targetVersion (no installer entry in config; pre-flight 2c would have caught this)."
    }

    # Step 6: run installer
    if (Test-ConfigHasProperty -Object $Config -Name 'upgrade_mode') {
        $mode = $Config.upgrade_mode
        Write-Log -Context $LogContext -Severity Info -Message "Would run installer in '$mode' mode."
    } else {
        Write-Log -Context $LogContext -Severity Info -Message "Would run installer in 'in_place' mode (config did not specify upgrade_mode; Phase 4 will auto-detect for cross-major bumps)."
    }

    # Step 7: startup sequence
    $startupSeq = @($Config.startup_sequence) -join ', '
    Write-Log -Context $LogContext -Severity Info -Message "Would start services in order: $startupSeq"

    # Step 8: smoke tests
    Write-Log -Context $LogContext -Severity Info -Message 'Would run smoke tests: fmsadmin list files, TCP port 5003, Admin API metadata.'

    # Step 9: summary
    Write-Log -Context $LogContext -Severity Info -Message 'Would print success or failure summary based on smoke test outcome.'
}

function Invoke-ChrysalisDryRun {
    # Function form of the dry-run orchestration. Returns an integer exit
    # code (0/1/3); the script-mode entry calls `exit` on the result. Tests
    # call this function directly with mocked dependencies so they can
    # assert on the return value without spawning a child process.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)] [string] $ConfigPath,
        [Parameter(Mandatory = $false)] [string] $LogRoot,
        [Parameter(Mandatory = $false)] [string] $ScriptRoot
    )

    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
        $ScriptRoot = $script:ChrysalisRoot
    }

    $logCtx = $null
    $exitCode = 0
    try {
        # Resolve the config path before opening the log: a missing config is
        # the most likely first-run error, and we want it to surface directly
        # without producing a misleading "session start" log line.
        $resolvedConfigPath = Resolve-ChrysalisEntryConfigPath -Explicit $ConfigPath -ScriptRoot $ScriptRoot

        if ([string]::IsNullOrWhiteSpace($LogRoot)) {
            $effectiveLogRoot = Join-Path -Path $ScriptRoot -ChildPath 'logs'
        } else {
            $effectiveLogRoot = $LogRoot
        }
        $logCtx = New-LogContext -LogRoot $effectiveLogRoot

        # Dry-run banner.
        Write-Log -Context $logCtx -Severity Info -Message 'chrysalis DryRun starting.'
        Write-Log -Context $logCtx -Severity Info -Message "Config: $resolvedConfigPath"
        Write-Log -Context $logCtx -Severity Info -Message "Log: $($logCtx.LogPath)"
        Write-Log -Context $logCtx -Severity Info -Message 'Phase 1 deliverable: this run reports what would happen; no destructive operations are performed.'

        # Parse config.
        $config = Read-ChrysalisConfig -Path $resolvedConfigPath
        $targetVersionMsg = "Target version: $($config.target_version)"
        if (Test-ConfigHasProperty -Object $config -Name 'upgrade_mode') {
            $targetVersionMsg += " (upgrade_mode: $($config.upgrade_mode))"
        } else {
            $targetVersionMsg += " (upgrade_mode: unspecified; defaults to in_place at runtime)"
        }
        Write-Log -Context $logCtx -Severity Info -Message $targetVersionMsg

        # Read credentials. On failure we log the error + remediation and
        # continue; pre-flight 2d will surface the underlying cause as a
        # structured Fail.
        $credential = $null
        try {
            $credential = Read-ChrysalisCredentials -Path $config.fms.creds_file
            # Only the username goes to the log. The PSCredential itself
            # stays in memory; the SecureString is not stringified.
            Write-Log -Context $logCtx -Severity Info -Message "Loaded admin credentials for user '$($credential.UserName)'."
        } catch {
            Write-Log -Context $logCtx -Severity Warn -Message "Could not read admin credentials: $($_.Exception.Message)"
            Write-Log -Context $logCtx -Severity Remediation -Message 'Run .\src\lib\EncryptCreds.ps1 to create the credentials file. Pre-flight 2d will report the same condition below. See docs/runbooks/credentials.md.'
        }

        # Run pre-flight. Invoke-PreFlight wraps each individual check in
        # try/catch internally, so a misbehaving check becomes a Fail rather
        # than aborting the entire dry-run.
        $results = Invoke-PreFlight -Config $config -Credential $credential -LogContext $logCtx

        # Write the structured report. Write-PreFlightReport handles the
        # severity-tagged per-check status, the remediation lines, and the
        # summary line - we do not duplicate that formatting here.
        Write-PreFlightReport -Results $results -LogContext $logCtx

        # Report what would happen next. None of the lines below execute
        # anything.
        Write-PlannedUpgradeSteps -Config $config -LogContext $logCtx

        # Final summary + exit code.
        if (Test-PreFlightPassed -Results $results) {
            Write-Log -Context $logCtx -Severity Info -Message 'chrysalis DryRun complete: pre-flight passed. The upgrade would proceed when -DryRun is removed (Phase 2).'
            $exitCode = 0
        } else {
            Write-Log -Context $logCtx -Severity Error -Message 'chrysalis DryRun complete: pre-flight FAILED. Remediation steps above. Address them and re-run.'
            $exitCode = 1
        }
    } catch {
        # Anything that escapes here is an unhandled exception - usually a
        # missing config file before the log was opened, or an unexpected
        # exception from a dependency. Write to the log if we have one;
        # otherwise write to stderr.
        $errMsg = "chrysalis: unhandled exception: $($_.Exception.Message)"
        $stackTrace = $_.ScriptStackTrace
        if ($null -ne $logCtx -and -not $logCtx.Closed) {
            try {
                Write-Log -Context $logCtx -Severity Error -Message $errMsg
                if (-not [string]::IsNullOrWhiteSpace($stackTrace)) {
                    Write-Log -Context $logCtx -Severity Error -Message "Stack: $stackTrace"
                }
            } catch {
                # Logging itself broke. Fall through to stderr.
            }
        }
        [Console]::Error.WriteLine($errMsg)
        $exitCode = 3
    } finally {
        if ($null -ne $logCtx -and -not $logCtx.Closed) {
            try { Close-LogContext -Context $logCtx } catch { }
        }
    }

    return $exitCode
}

# Script-mode entry point. When this file is invoked directly,
# $MyInvocation.InvocationName is the script path or its leaf. When the file
# is dot-sourced for testing, InvocationName is '.' and we skip the
# auto-invocation so tests can call Invoke-ChrysalisDryRun directly with
# mocked dependencies. Same pattern as src/lib/EncryptCreds.ps1.
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.InvocationName -ne '') {
    # Strict-only gate. Refuse any invocation that does not pass -DryRun. The
    # check lives inside the auto-invocation guard so dot-source-and-call from
    # tests does not trip it. See ADR-003: safety beats convenience in v0.
    # Caveat (Hermione PR #4 N2, deferred for a dedicated turn): the dot-source
    # statements above run BEFORE this gate, so non-DryRun invocations still
    # execute lib top-level code. The libs are inert (functions + EncryptCreds'
    # own param block, all non-destructive). A future refactor should move
    # this gate ahead of dot-sourcing if any lib gains destructive top-level
    # side effects.
    if (-not $script:EntryDryRun) {
        $refusal = "chrysalis: Phase 1 only supports -DryRun mode. Pass -DryRun to inspect what would happen. Upgrade execution (without -DryRun) lands in Phase 2."
        [Console]::Error.WriteLine($refusal)
        exit 2
    }

    $code = Invoke-ChrysalisDryRun -ConfigPath $script:EntryConfigPath -LogRoot $script:EntryLogRoot -ScriptRoot $script:ChrysalisRoot
    exit $code
}
