# PreFlight.ps1
# chrysalis pre-flight check framework. Runs the seven SDD section 6.1 step 2
# checks (2a-2g) and returns a structured result list. Designed to fail
# loud, collect every failure, and surface remediation text. Pre-flight is
# strict by ADR-003 (no -Force, no -SkipCheck in v0).
# Implements SDD section 6.1 step 2.
# Windows-only in PR #3b; cross-platform paths land in Phase 5.
# PowerShell 5.1 compatible.

# This file expects its sibling libraries (Config.ps1, Logging.ps1,
# EncryptCreds.ps1, VersionDetection.ps1) to be dot-sourced by the caller so
# the framework can reach Read-ChrysalisCredentials, Get-FmsVersion, and
# Write-Log without re-dot-sourcing them here. Tests follow the same pattern.

function New-PreFlightResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [string] $CheckId,
        [Parameter(Mandatory = $true)]  [string] $Name,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Pass', 'Fail', 'Skip')]
        [string] $Status,
        [Parameter(Mandatory = $false)] [string] $Detail = '',
        [Parameter(Mandatory = $false)] [string] $Remediation = '',
        [Parameter(Mandatory = $false)] $Data = $null
    )

    return [pscustomobject]@{
        CheckId     = $CheckId
        Name        = $Name
        Status      = $Status
        Detail      = $Detail
        Remediation = $Remediation
        Data        = $Data
    }
}

# ---------------------------------------------------------------------------
# Script-scoped check implementations. One per SDD 6.1 step 2 sub-check.
# Each returns a single result object built via New-PreFlightResult. The
# coordinator wraps each call in try/catch so an unexpected exception
# becomes a Fail rather than aborting the run.
# ---------------------------------------------------------------------------

function Invoke-PreFlightCheck2a {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [pscustomobject] $Config,
        [Parameter(Mandatory = $false)] [System.Management.Automation.PSCredential] $Credential,
        [Parameter(Mandatory = $false)] [pscustomobject] $LogContext
    )

    $name = 'Detect current installed FMS version'
    try {
        $version = Get-FmsVersion -Config $Config -Credential $Credential -LogContext $LogContext
        return (New-PreFlightResult -CheckId '2a' -Name $name -Status 'Pass' `
            -Detail "Detected version $version" -Data $version)
    } catch [System.AggregateException] {
        $agg = $_.Exception
        $innerMessages = @()
        if ($null -ne $agg.InnerExceptions) {
            foreach ($inner in $agg.InnerExceptions) {
                if ($null -ne $inner -and -not [string]::IsNullOrWhiteSpace($inner.Message)) {
                    $innerMessages += $inner.Message
                }
            }
        }
        $joined = ($innerMessages -join '; ')
        $remediation = "$joined; verify fms.install_root_windows in config.json, ensure FMS is installed, or check Admin API reachability."
        return (New-PreFlightResult -CheckId '2a' -Name $name -Status 'Fail' `
            -Detail 'Could not detect FMS version' -Remediation $remediation)
    } catch {
        # Non-aggregate failure (e.g. binary path failed and no credential was
        # supplied for the fallback). Surface the raw message; the operator
        # still needs to read it.
        $remediation = "$($_.Exception.Message); verify fms.install_root_windows in config.json, ensure FMS is installed, or check Admin API reachability."
        return (New-PreFlightResult -CheckId '2a' -Name $name -Status 'Fail' `
            -Detail 'Could not detect FMS version' -Remediation $remediation)
    }
}

function Invoke-PreFlightCheck2b {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [pscustomobject] $Config,
        [Parameter(Mandatory = $false)] [string] $CurrentVersion
    )

    $name = 'Config has installer entry for current version'
    if ([string]::IsNullOrWhiteSpace($CurrentVersion)) {
        return (New-PreFlightResult -CheckId '2b' -Name $name -Status 'Skip' `
            -Detail 'Skipped because 2a failed.')
    }

    $installers = $Config.installers
    $hasEntry = $false
    if ($null -ne $installers -and $null -ne $installers.PSObject.Properties[$CurrentVersion]) {
        $hasEntry = $true
    }

    if ($hasEntry) {
        return (New-PreFlightResult -CheckId '2b' -Name $name -Status 'Pass' `
            -Detail "Current version '$CurrentVersion' has installer entry.")
    }

    return (New-PreFlightResult -CheckId '2b' -Name $name -Status 'Fail' `
        -Detail "No installer entry for current version '$CurrentVersion'." `
        -Remediation "Add an 'installers.$CurrentVersion' block to config.json so rollback is possible from this version, or use a config with the current version's installer URLs.")
}

function Invoke-PreFlightCheck2c {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $Config
    )

    $name = 'Config has installer entry for target version'
    $targetVersion = $Config.target_version
    $installers = $Config.installers
    $hasEntry = $false
    if ($null -ne $installers -and -not [string]::IsNullOrWhiteSpace($targetVersion) `
        -and $null -ne $installers.PSObject.Properties[$targetVersion]) {
        $hasEntry = $true
    }

    if ($hasEntry) {
        return (New-PreFlightResult -CheckId '2c' -Name $name -Status 'Pass' `
            -Detail "Target version '$targetVersion' has installer entry.")
    }

    # The config parser already enforces this; if we reach a Fail here, that
    # is a real bug. Remediation reflects that.
    return (New-PreFlightResult -CheckId '2c' -Name $name -Status 'Fail' `
        -Detail "target_version '$targetVersion' has no matching installers entry." `
        -Remediation "Edit config.json so installers.$targetVersion exists; or change target_version. The parser should have caught this earlier - file a bug.")
}

function Invoke-PreFlightCheck2d {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $Config
    )

    $name = 'Verify admin credentials decrypt'
    $credsPath = $Config.fms.creds_file

    # Pre-check existence so the file-missing branch never depends on
    # substring-matching Read-ChrysalisCredentials's thrown message. The
    # try/catch below then only has to handle decrypt failures.
    if (-not (Test-Path -LiteralPath $credsPath -PathType Leaf)) {
        return (New-PreFlightResult -CheckId '2d' -Name $name -Status 'Fail' `
            -Detail "Admin credentials file not found at '$credsPath'." `
            -Remediation 'Run .\EncryptCreds.ps1 to create the credentials file. See docs/runbooks/credentials.md.')
    }

    try {
        $cred = Read-ChrysalisCredentials -Path $credsPath
        # Pull only the username for the Detail line. Never store or log the
        # SecureString password.
        $userName = $cred.UserName
        return (New-PreFlightResult -CheckId '2d' -Name $name -Status 'Pass' `
            -Detail "Admin credentials decrypted from '$credsPath' (user '$userName').")
    } catch {
        return (New-PreFlightResult -CheckId '2d' -Name $name -Status 'Fail' `
            -Detail "Cannot decrypt credentials at '$credsPath'." `
            -Remediation 'Credentials are DPAPI-bound to the user + machine that encrypted them. Re-run .\EncryptCreds.ps1 -Force as the current user, or log in as the encrypting user. See docs/runbooks/credentials.md.')
    }
}

function Get-PreFlightDriveFreeGb {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Path
    )

    # Returns free space in GiB (as a double) for the volume hosting $Path.
    # PowerShell's 1GB literal is 1073741824 bytes (1024^3) = 1 GiB; the
    # function name keeps "Gb" for backward-compat with existing mocks.
    # Uses [System.IO.DriveInfo] because it accepts a path-like root and
    # avoids the PSDrive providers/non-FS edge cases. Caller catches errors.
    $drive = New-Object System.IO.DriveInfo($Path)
    return [math]::Round(($drive.AvailableFreeSpace / 1GB), 2)
}

function Get-PreFlightDriveRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Path
    )

    # Returns the drive root segment for human-facing messages ("C:\" -> "C:").
    # Falls back to the path itself if the OS doesn't expose a drive letter.
    $root = [System.IO.Path]::GetPathRoot($Path)
    if ([string]::IsNullOrWhiteSpace($root)) { return $Path }
    # Trim trailing slash for readability: 'C:\' -> 'C:'.
    return $root.TrimEnd('\','/')
}

function Invoke-PreFlightCheck2f {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $Config
    )

    $name = 'Disk space for installer and backup'
    # Threshold is intentionally conservative for v0. Make this configurable
    # in Phase 4 if real-world ops complain. Real-world FMS installers are
    # ~1-2 GiB; backups vary widely. 5 GiB is generous; tight enough to catch
    # a near-full disk. (PowerShell's 1GB literal is 1024^3 = 1 GiB.)
    $minFreeGb = 5

    $installRoot = $Config.fms.install_root_windows
    $backupRoot  = $Config.backup_root

    $installDrive = Get-PreFlightDriveRoot -Path $installRoot
    $backupDrive  = Get-PreFlightDriveRoot -Path $backupRoot

    $installFreeGb = $null
    $backupFreeGb  = $null
    $errors = @()

    try {
        $installFreeGb = Get-PreFlightDriveFreeGb -Path $installRoot
    } catch {
        $errors += "Could not read free space for install root drive '$installDrive': $($_.Exception.Message)"
    }
    try {
        $backupFreeGb = Get-PreFlightDriveFreeGb -Path $backupRoot
    } catch {
        $errors += "Could not read free space for backup root drive '$backupDrive': $($_.Exception.Message)"
    }

    if ($errors.Count -gt 0) {
        return (New-PreFlightResult -CheckId '2f' -Name $name -Status 'Fail' `
            -Detail ($errors -join ' ') `
            -Remediation "Free up space on the named drive(s), or change install_root_windows / backup_root in config.json to a drive with at least ${minFreeGb} GiB free.")
    }

    $failingDrives = @()
    if ($installFreeGb -lt $minFreeGb) {
        $failingDrives += "install root drive '$installDrive' has $installFreeGb GiB free (need $minFreeGb GiB)"
    }
    if ($backupFreeGb -lt $minFreeGb) {
        $failingDrives += "backup root drive '$backupDrive' has $backupFreeGb GiB free (need $minFreeGb GiB)"
    }

    if ($failingDrives.Count -gt 0) {
        return (New-PreFlightResult -CheckId '2f' -Name $name -Status 'Fail' `
            -Detail ($failingDrives -join '; ') `
            -Remediation "Free up space on the named drive(s), or change install_root_windows / backup_root in config.json to a drive with at least ${minFreeGb} GiB free.")
    }

    return (New-PreFlightResult -CheckId '2f' -Name $name -Status 'Pass' `
        -Detail "Install root drive '$installDrive' has $installFreeGb GiB free; backup root drive '$backupDrive' has $backupFreeGb GiB free.")
}

function Invoke-PreFlightCheck2e {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $Config,
        [Parameter(Mandatory = $false)] [bool] $InstallRootReachable = $true
    )

    $name = 'License file exists (Phase 1 scope)'
    # Phase 1 scope per SDD 6.1 step 2e: verify the .fmcert file exists and is
    # non-zero. Cross-major license parsing is Phase 4. Search one level deep
    # under {install_root}\Database Server\ for *.fmcert.
    if (-not $InstallRootReachable) {
        return (New-PreFlightResult -CheckId '2e' -Name $name -Status 'Skip' `
            -Detail 'Skipped because install root is unreachable (see 2a).')
    }

    $installRoot = $Config.fms.install_root_windows
    $databaseServer = Join-Path -Path $installRoot -ChildPath 'Database Server'

    if (-not (Test-Path -LiteralPath $databaseServer -PathType Container)) {
        return (New-PreFlightResult -CheckId '2e' -Name $name -Status 'Fail' `
            -Detail "No .fmcert license file found under '$databaseServer'." `
            -Remediation 'Verify FMS is installed and licensed. Run FMS admin console to re-apply the license file, then re-run chrysalis.')
    }

    # Recursive within Database Server. The runbook narrative said "one level
    # deep is enough — don't walk arbitrarily deep"; the .fmcert is typically
    # in a CStore or licensing subfolder. -Recurse is fine: Database Server
    # is a bounded tree the FMS installer owns.
    $found = @()
    try {
        $found = @(Get-ChildItem -LiteralPath $databaseServer -Filter '*.fmcert' -File -Recurse -ErrorAction Stop)
    } catch {
        return (New-PreFlightResult -CheckId '2e' -Name $name -Status 'Fail' `
            -Detail "Could not scan '$databaseServer' for .fmcert files: $($_.Exception.Message)." `
            -Remediation 'Verify FMS is installed and licensed. Run FMS admin console to re-apply the license file, then re-run chrysalis.')
    }

    if ($found.Count -eq 0) {
        return (New-PreFlightResult -CheckId '2e' -Name $name -Status 'Fail' `
            -Detail "No .fmcert license file found under '$databaseServer'." `
            -Remediation 'Verify FMS is installed and licensed. Run FMS admin console to re-apply the license file, then re-run chrysalis.')
    }

    if ($found.Count -gt 1) {
        # Sort by FullName so re-runs produce a deterministic list ordering
        # in the operator-facing Detail string (filesystem enumeration order
        # is not guaranteed).
        $list = ($found | Sort-Object -Property FullName | ForEach-Object { $_.FullName }) -join ', '
        return (New-PreFlightResult -CheckId '2e' -Name $name -Status 'Fail' `
            -Detail "Found $($found.Count) license files under '$databaseServer': $list." `
            -Remediation 'Multiple license files is unusual. Verify which is current via FMS admin console and remove stale ones.')
    }

    $licenseFile = $found[0]
    if ($licenseFile.Length -le 0) {
        return (New-PreFlightResult -CheckId '2e' -Name $name -Status 'Fail' `
            -Detail "License file '$($licenseFile.FullName)' exists but is zero bytes." `
            -Remediation 'The license file is empty, which means it was not written correctly. Re-apply the license via FMS admin console.')
    }

    return (New-PreFlightResult -CheckId '2e' -Name $name -Status 'Pass' `
        -Detail "License file '$($licenseFile.FullName)' exists ($($licenseFile.Length) bytes)." `
        -Data $licenseFile.FullName)
}

function Invoke-PreFlightCheck2g {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $Config
    )

    $name = 'Recent native FMS DB backup exists'
    $backupRoot = $Config.backup_root
    # Parser defaults max_backup_age_hours to 24 if absent.
    $maxAgeHours = [int] $Config.max_backup_age_hours

    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) {
        return (New-PreFlightResult -CheckId '2g' -Name $name -Status 'Fail' `
            -Detail "Backup root '$backupRoot' does not exist." `
            -Remediation 'Create the directory, or fix backup_root in config.json.')
    }

    # v0 heuristic: scan {backup_root} and its immediate subdirectories for
    # any .fmp12 file whose LastWriteTime is within max_backup_age_hours.
    # Phase 4 may tighten this against FMS's actual backup schedule (the
    # Admin API exposes scheduled backup configuration - see TODO Phase 4
    # Admin API discovery work).
    $cutoff = (Get-Date).AddHours(-$maxAgeHours)
    $candidates = @()
    try {
        # -Depth 1: scan backup_root itself plus immediate subdirectories.
        # -Filter on Get-ChildItem is the cheapest of the .fmp12 selectors.
        $candidates = @(Get-ChildItem -LiteralPath $backupRoot -Filter '*.fmp12' -File -Recurse -Depth 1 -ErrorAction Stop)
    } catch {
        return (New-PreFlightResult -CheckId '2g' -Name $name -Status 'Fail' `
            -Detail "Could not scan '$backupRoot': $($_.Exception.Message)." `
            -Remediation 'Verify backup_root is readable, or fix backup_root in config.json.')
    }

    $recent = @($candidates | Where-Object { $_.LastWriteTime -ge $cutoff })
    if ($recent.Count -eq 0) {
        return (New-PreFlightResult -CheckId '2g' -Name $name -Status 'Fail' `
            -Detail "No FMS database backup newer than ${maxAgeHours}h found under '$backupRoot'." `
            -Remediation "Run 'fmsadmin backup' to create a fresh backup, then re-run chrysalis. (Decision 2: chrysalis refuses to trigger backups automatically.)")
    }

    $newest = ($recent | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1)
    $hoursAgo = [math]::Round(((Get-Date) - $newest.LastWriteTime).TotalHours, 1)
    return (New-PreFlightResult -CheckId '2g' -Name $name -Status 'Pass' `
        -Detail "Found $($recent.Count) recent backup file(s) under '$backupRoot'; newest is ${hoursAgo}h ago.")
}

# ---------------------------------------------------------------------------
# Public coordinator, predicate, and reporter.
# ---------------------------------------------------------------------------

function Invoke-PreFlight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [pscustomobject] $Config,
        [Parameter(Mandatory = $false)] [System.Management.Automation.PSCredential] $Credential,
        [Parameter(Mandatory = $false)] [pscustomobject] $LogContext
    )

    # Run order per Ripley: 2a -> 2b -> 2c -> 2d -> 2f -> 2e -> 2g.
    # Cheapest-local-first surfaces dumb-config errors before disk hits.
    # 2a feeds 2b and 2e. 2g is the most expensive (filesystem walk of
    # backup root). Each check is wrapped in try/catch so an unexpected
    # exception becomes a Fail result; other checks still run.
    $results = New-Object System.Collections.Generic.List[object]

    # 2a
    $r2a = $null
    try {
        $r2a = Invoke-PreFlightCheck2a -Config $Config -Credential $Credential -LogContext $LogContext
    } catch {
        $r2a = New-PreFlightCheckException -CheckId '2a' -Name 'Detect current installed FMS version' -Exception $_.Exception
    }
    if ($null -eq $r2a) { $r2a = New-PreFlightCheckNullResult -CheckId '2a' -Name 'Detect current installed FMS version' }
    $results.Add($r2a) | Out-Null

    # 2b - depends on 2a's Data
    $currentVersion = $null
    if ($r2a.Status -eq 'Pass') {
        $currentVersion = [string] $r2a.Data
    }
    $r2b = $null
    try {
        $r2b = Invoke-PreFlightCheck2b -Config $Config -CurrentVersion $currentVersion
    } catch {
        $r2b = New-PreFlightCheckException -CheckId '2b' -Name 'Config has installer entry for current version' -Exception $_.Exception
    }
    if ($null -eq $r2b) { $r2b = New-PreFlightCheckNullResult -CheckId '2b' -Name 'Config has installer entry for current version' }
    $results.Add($r2b) | Out-Null

    # 2c
    $r2c = $null
    try {
        $r2c = Invoke-PreFlightCheck2c -Config $Config
    } catch {
        $r2c = New-PreFlightCheckException -CheckId '2c' -Name 'Config has installer entry for target version' -Exception $_.Exception
    }
    if ($null -eq $r2c) { $r2c = New-PreFlightCheckNullResult -CheckId '2c' -Name 'Config has installer entry for target version' }
    $results.Add($r2c) | Out-Null

    # 2d
    $r2d = $null
    try {
        $r2d = Invoke-PreFlightCheck2d -Config $Config
    } catch {
        $r2d = New-PreFlightCheckException -CheckId '2d' -Name 'Verify admin credentials decrypt' -Exception $_.Exception
    }
    if ($null -eq $r2d) { $r2d = New-PreFlightCheckNullResult -CheckId '2d' -Name 'Verify admin credentials decrypt' }
    $results.Add($r2d) | Out-Null

    # 2f
    $r2f = $null
    try {
        $r2f = Invoke-PreFlightCheck2f -Config $Config
    } catch {
        $r2f = New-PreFlightCheckException -CheckId '2f' -Name 'Disk space for installer and backup' -Exception $_.Exception
    }
    if ($null -eq $r2f) { $r2f = New-PreFlightCheckNullResult -CheckId '2f' -Name 'Disk space for installer and backup' }
    $results.Add($r2f) | Out-Null

    # 2e - depends on install root being reachable, which 2a effectively
    # detects (binary path failure is the primary symptom of an unreachable
    # install root). If 2a failed, mark 2e Skip via -InstallRootReachable.
    $installRootReachable = ($r2a.Status -eq 'Pass')
    $r2e = $null
    try {
        $r2e = Invoke-PreFlightCheck2e -Config $Config -InstallRootReachable $installRootReachable
    } catch {
        $r2e = New-PreFlightCheckException -CheckId '2e' -Name 'License file exists (Phase 1 scope)' -Exception $_.Exception
    }
    if ($null -eq $r2e) { $r2e = New-PreFlightCheckNullResult -CheckId '2e' -Name 'License file exists (Phase 1 scope)' }
    $results.Add($r2e) | Out-Null

    # 2g
    $r2g = $null
    try {
        $r2g = Invoke-PreFlightCheck2g -Config $Config
    } catch {
        $r2g = New-PreFlightCheckException -CheckId '2g' -Name 'Recent native FMS DB backup exists' -Exception $_.Exception
    }
    if ($null -eq $r2g) { $r2g = New-PreFlightCheckNullResult -CheckId '2g' -Name 'Recent native FMS DB backup exists' }
    $results.Add($r2g) | Out-Null

    return $results.ToArray()
}

function New-PreFlightCheckException {
    # Helper for the coordinator: turn an unexpected exception (i.e. the check
    # function itself blew up rather than returning a Fail result) into a
    # Fail result. Detail is the one-line summary; Remediation is the
    # actionable text - even a raw exception message is "actionable" because
    # the operator has to read it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $CheckId,
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] $Exception
    )
    $msg = if ($null -ne $Exception) { $Exception.Message } else { '<no exception message>' }
    return (New-PreFlightResult -CheckId $CheckId -Name $Name -Status 'Fail' `
        -Detail "Unexpected error during pre-flight check '$CheckId'." `
        -Remediation $msg)
}

function New-PreFlightCheckNullResult {
    # Defensive: a check function that returns $null is a bug. Emit a Fail
    # rather than letting a null sneak into the aggregate.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $CheckId,
        [Parameter(Mandatory = $true)] [string] $Name
    )
    return (New-PreFlightResult -CheckId $CheckId -Name $Name -Status 'Fail' `
        -Detail "Check '$CheckId' returned no result." `
        -Remediation "Internal error: pre-flight check '$CheckId' produced no result object. File a bug.")
}

function Test-PreFlightPassed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]] $Results
    )

    # Pass and Skip both count as "passed" for this predicate. Skip is
    # reserved for "not applicable in this phase" and is never produced
    # in a normal Phase 1 run on a healthy system - see SDD 6.1 step 2e.
    foreach ($r in $Results) {
        if ($r.Status -eq 'Fail') { return $false }
    }
    return $true
}

function Write-PreFlightReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]] $Results,
        [Parameter(Mandatory = $true)] [pscustomobject] $LogContext
    )

    Write-Log -Context $LogContext -Severity Info -Message 'Pre-flight report:'

    $passed  = 0
    $skipped = 0
    $failed  = 0
    foreach ($r in $Results) {
        $line = "$($r.CheckId) $($r.Status) $($r.Name) - $($r.Detail)"
        switch ($r.Status) {
            'Pass' {
                $passed++
                Write-Log -Context $LogContext -Severity Info -Message $line
            }
            'Skip' {
                $skipped++
                Write-Log -Context $LogContext -Severity Warn -Message $line
            }
            'Fail' {
                $failed++
                Write-Log -Context $LogContext -Severity Error -Message $line
                if (-not [string]::IsNullOrWhiteSpace($r.Remediation)) {
                    Write-Log -Context $LogContext -Severity Remediation -Message $r.Remediation
                }
            }
        }
    }

    $total = $Results.Count
    Write-Log -Context $LogContext -Severity Info -Message "Pre-flight summary: total=$total passed=$passed skipped=$skipped failed=$failed."

    if ($failed -gt 0) {
        Write-Log -Context $LogContext -Severity Remediation -Message "Pre-flight failed $failed of $total checks. Remediation steps above. Address them and re-run."
    }
}
