# sudofmsadmin.ps1
# chrysalis fmsadmin invoker. Adapted from ernestkoe/powershell-fms
# (sudofmsadmin.ps1, MIT). On Windows this is a transparent pass-through;
# the macOS/Linux Bash sibling (Phase 5) wraps `sudo fmsadmin`.
# Implements SDD section 10 (Credentials, sudofmsadmin elevation wrapper).
# PowerShell 5.1 compatible. Windows path in PR #2.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string] $ConfigPath,

    [Parameter(Mandatory = $false)]
    [string] $LogRoot,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Arguments
)

$ErrorActionPreference = 'Stop'

$script:LibRoot = $PSScriptRoot
$script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $script:LibRoot)

. (Join-Path -Path $script:LibRoot -ChildPath 'Config.ps1')
. (Join-Path -Path $script:LibRoot -ChildPath 'Logging.ps1')

function Resolve-SudoFmsConfigPath {
    param(
        [string] $ExplicitConfigPath,
        [string] $ProjectRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitConfigPath)) {
        return $ExplicitConfigPath
    }
    return (Join-Path -Path $ProjectRoot -ChildPath 'config.json')
}

function Resolve-FmsadminPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string] $ConfigPath
    )

    # Order of resolution (per Misaka's spec, SDD section 7 informs the
    # conventional install layout):
    #   1. {install_root}\Database Server\fmsadmin.exe
    #   2. {install_root}\fmsadmin.exe
    #   3. Get-Command fmsadmin on PATH
    # Each step is skipped if its prerequisite is missing (no config, etc.).
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        try {
            $cfg = Read-ChrysalisConfig -Path $ConfigPath
            $installRoot = $cfg.fms.install_root_windows
            if (-not [string]::IsNullOrWhiteSpace($installRoot)) {
                $candidate = Join-Path -Path $installRoot -ChildPath 'Database Server\fmsadmin.exe'
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    return $candidate
                }
                $candidate = Join-Path -Path $installRoot -ChildPath 'fmsadmin.exe'
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    return $candidate
                }
            }
        } catch {
            # Config read failures here are non-fatal; we will still try PATH.
            # The caller's log captures the upstream config parse error.
        }
    }

    $onPath = Get-Command -Name 'fmsadmin' -ErrorAction SilentlyContinue
    if ($null -ne $onPath -and -not [string]::IsNullOrWhiteSpace($onPath.Source)) {
        return $onPath.Source
    }

    return $null
}

function Invoke-Fmsadmin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $FmsadminPath,

        [Parameter(Mandatory = $false)]
        [string[]] $Arguments
    )

    # Wrapper around the actual external invocation. Isolated for tests:
    # Pester Mock can replace this with a fake that sets $script:LASTEXITCODE
    # and returns canned output without spawning fmsadmin.exe.
    if ($null -eq $Arguments) {
        & $FmsadminPath
    } else {
        & $FmsadminPath @Arguments
    }
    return $LASTEXITCODE
}

function Invoke-SudoFmsadmin {
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [string[]] $Arguments,
        [string] $LogRoot
    )

    $resolvedConfigPath = Resolve-SudoFmsConfigPath -ExplicitConfigPath $ConfigPath -ProjectRoot $script:ProjectRoot

    # -LogRoot lets tests inject a sandbox path; absent it, default to
    # {ProjectRoot}/logs.
    if ([string]::IsNullOrWhiteSpace($LogRoot)) {
        $effectiveLogRoot = Join-Path -Path $script:ProjectRoot -ChildPath 'logs'
    } else {
        $effectiveLogRoot = $LogRoot
    }
    $logCtx = New-LogContext -LogRoot $effectiveLogRoot

    try {
        $fmsadminPath = Resolve-FmsadminPath -ConfigPath $resolvedConfigPath

        if ([string]::IsNullOrWhiteSpace($fmsadminPath)) {
            Write-Log -Context $logCtx -Severity Error -Message "sudofmsadmin: could not locate fmsadmin. Checked '{install_root}\Database Server\fmsadmin.exe', '{install_root}\fmsadmin.exe', and PATH."
            Write-Log -Context $logCtx -Severity Remediation -Message "Verify fms.install_root_windows in config.json points at the FileMaker Server install root, or ensure fmsadmin is on PATH."
            return 2
        }

        # Arguments are logged verbatim. fmsadmin's CLI does not accept the
        # password as a positional argument and chrysalis never passes
        # secrets through this wrapper (creds come from creds.xml via the
        # higher-level helpers). If you are adding a new caller and you find
        # yourself wanting to push a password through here, stop and revisit
        # SDD section 10 - this wrapper is not the right surface.
        $argDisplay = if ($null -eq $Arguments -or $Arguments.Count -eq 0) { '<none>' } else { ($Arguments -join ' ') }
        Write-Log -Context $logCtx -Severity Info -Message "sudofmsadmin invoke. FmsadminPath='$fmsadminPath' Args=$argDisplay"

        $exit = Invoke-Fmsadmin -FmsadminPath $fmsadminPath -Arguments $Arguments
        if ($null -eq $exit) {
            # Defensive: a mock that forgets to set $LASTEXITCODE should not
            # be reported as success. Treat null as a chrysalis-side error
            # distinct from fmsadmin's own non-zero codes.
            Write-Log -Context $logCtx -Severity Error -Message "sudofmsadmin: fmsadmin invocation returned no exit code."
            return 1
        }

        Write-Log -Context $logCtx -Severity Info -Message "sudofmsadmin complete. ExitCode=$exit"
        return [int] $exit
    } finally {
        Close-LogContext -Context $logCtx
    }
}

# Script-mode entry point. Dot-source-safe: tests load this file via `.` and
# call Invoke-SudoFmsadmin / Resolve-FmsadminPath directly.
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.InvocationName -ne '') {
    $exitCode = Invoke-SudoFmsadmin -ConfigPath $ConfigPath -Arguments $Arguments -LogRoot $LogRoot
    exit $exitCode
}
