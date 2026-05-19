# Logging.ps1
# chrysalis logging module. Creates timestamped log files under ./logs/ and
# emits structured lines to file plus the appropriate console stream.
# Implements SDD section 14 Phase 1 logging infrastructure; consumed by the
# pre-flight framework and dry-run mode.
# PowerShell 5.1 compatible.

function New-LogContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string] $LogRoot,

        [Parameter(Mandatory = $false)]
        [string] $RunId
    )

    if ([string]::IsNullOrWhiteSpace($LogRoot)) {
        # Default: ./logs relative to the current working directory. The caller
        # is expected to set $PWD to the repo root, or pass -LogRoot explicitly.
        $LogRoot = Join-Path -Path (Get-Location).Path -ChildPath 'logs'
    }

    if ([string]::IsNullOrWhiteSpace($RunId)) {
        # Short random suffix. Eight hex chars from a GUID; collision-resistant
        # enough for human-scale concurrent runs on a single host.
        $RunId = ([guid]::NewGuid().ToString('N')).Substring(0, 8)
    }

    # Create the log root if missing. Fail loud if we cannot.
    if (-not (Test-Path -LiteralPath $LogRoot)) {
        try {
            $null = New-Item -ItemType Directory -Path $LogRoot -Force -ErrorAction Stop
        } catch {
            throw "chrysalis: cannot create log root '$LogRoot': $($_.Exception.Message)"
        }
    }

    # Sanity check: New-Item -ItemType Directory against a path that already
    # exists as a FILE on Windows does NOT throw — it returns silently. Without
    # this guard, downstream file open at $LogPath fails with a confusing
    # "Could not find a part of the path" instead of a clear log-root error.
    # Also defense-in-depth if New-Item ever returns without producing a real
    # directory.
    if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) {
        throw "chrysalis: cannot create log root '$LogRoot': path exists but is not a directory."
    }

    $startTime = Get-Date
    $stamp = $startTime.ToString('yyyyMMdd-HHmmss')
    $fileName = "chrysalis-$stamp-$RunId.log"
    $logPath = Join-Path -Path $LogRoot -ChildPath $fileName

    # Open the file for append with UTF8 (no BOM is fine; PS 5.1 StreamWriter
    # defaults to UTF8 with BOM unless we pass an explicit encoding). Use an
    # explicit UTF8Encoding($false) so the file is BOM-less for tail/grep
    # friendliness on Windows.
    $writer = $null
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false)
        # TODO (Phase 4 hardening, per Hermione PR #1 review S1): switch to
        # FileMode::CreateNew with an IOException-specific catch so a colliding
        # RunId fails loudly instead of appending. Deferred because the
        # collision is vanishingly rare (8 hex chars + second-resolution stamp)
        # and CreateNew would break legitimate re-runs of the same RunId.
        $stream = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $writer = New-Object System.IO.StreamWriter($stream, $encoding)
        $writer.NewLine = "`r`n"
        $writer.AutoFlush = $true
    } catch {
        if ($writer) { try { $writer.Dispose() } catch { } }
        throw "chrysalis: cannot open log file '$logPath' for writing: $($_.Exception.Message)"
    }

    $context = [pscustomobject]@{
        LogRoot   = $LogRoot
        LogPath   = $logPath
        RunId     = $RunId
        StartTime = $startTime
        Writer    = $writer
        Closed    = $false
    }

    # Deliberately do NOT emit a "Session start" line here. The entry-point
    # banner (chrysalis.ps1) already records RunId / LogPath as its first lines,
    # and the spec requires the banner to be the literal first line of the log
    # file. Close-LogContext still writes a Session-end line with elapsed
    # seconds, which is the surviving session-boundary marker.
    return $context
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Info', 'Warn', 'Error', 'Remediation')]
        [string] $Severity,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Message
    )

    Write-LogInternal -Context $Context -Severity $Severity -Message $Message
}

function Write-LogInternal {
    param(
        [pscustomobject] $Context,
        [string] $Severity,
        [string] $Message
    )

    if ($null -eq $Context) {
        throw 'chrysalis: Write-Log requires a non-null -Context.'
    }
    if ($Context.Closed) {
        throw 'chrysalis: log context is already closed.'
    }

    # ISO 8601 with milliseconds, local timezone offset. e.g. 2026-05-17T18:42:13.482-07:00
    $timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
    $severityTag = $Severity.ToUpperInvariant()
    $line = "$timestamp [$severityTag] $Message"

    try {
        $Context.Writer.WriteLine($line)
    } catch {
        # If the file write fails after the context was created we want this
        # to surface immediately rather than be silently swallowed.
        throw "chrysalis: failed to write to log '$($Context.LogPath)': $($_.Exception.Message)"
    }

    switch ($Severity) {
        'Info' {
            Write-Host $line
        }
        'Warn' {
            # Write-Warning goes to the warning stream (#3), which surfaces on
            # stderr in most hosts. Keep the structured line readable.
            Write-Warning $line
        }
        'Error' {
            # Prominent stderr line. We deliberately avoid `throw` here so the
            # caller can keep running and decide whether to abort.
            [Console]::Error.WriteLine($line)
        }
        'Remediation' {
            # Remediation is post-failure guidance — actionable next steps.
            # Render on stderr with a clear prefix so it stands out from regular
            # errors in a terminal scroll.
            [Console]::Error.WriteLine("REMEDIATION: $line")
        }
    }
}

function Close-LogContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context
    )

    if ($null -eq $Context) {
        return
    }
    if ($Context.Closed) {
        return
    }

    $elapsed = ((Get-Date) - $Context.StartTime).TotalSeconds
    # Format with three decimal places. PS 5.1's [string]::Format with the
    # invariant culture avoids locale-specific decimal separators.
    $elapsedText = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:F3}', $elapsed)
    $endMessage = "Session end. Elapsed=${elapsedText}s"

    try {
        Write-LogInternal -Context $Context -Severity 'Info' -Message $endMessage
    } catch {
        # Even if the final write fails, we still need to close the handle.
        [Console]::Error.WriteLine("chrysalis: failed to write session-end line: $($_.Exception.Message)")
    }

    try {
        $Context.Writer.Flush()
    } catch { }
    try {
        $Context.Writer.Dispose()
    } catch { }

    $Context.Closed = $true
}
