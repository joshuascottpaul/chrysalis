# EncryptCreds.ps1
# chrysalis DPAPI credential storage. Adapted from ernestkoe/powershell-fms
# (EncryptCreds.ps1, MIT). Greenfield rewrite - patterns reused, code is ours.
# Implements SDD section 10 (Credentials).
# PowerShell 5.1 compatible. Windows-only (DPAPI is a Windows API).
#
# Re-encrypt this credential file when any of the following happens (mirrors
# docs/runbooks/credentials.md - "When you need to re-encrypt"):
#   1. The admin user account on the host changes. DPAPI binds the blob to
#      the encrypting user; a different Windows account cannot decrypt it.
#   2. The host is moved, rebuilt, or restored from a snapshot. DPAPI keys
#      are machine-scoped and do not survive a migration.
#   3. The FMS admin password rotates.
#   4. creds.xml is corrupted or accidentally deleted.
#
# Operator-facing remediation lives in docs/runbooks/credentials.md. Keep
# this header in sync with that runbook.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string] $Path,

    [Parameter(Mandatory = $false)]
    [string] $ConfigPath,

    [Parameter(Mandatory = $false)]
    [switch] $Force,

    [Parameter(Mandatory = $false)]
    [string] $LogRoot
)

$ErrorActionPreference = 'Stop'

# Resolve sibling library paths. $PSScriptRoot is src/lib/; Config.ps1 and
# Logging.ps1 live next to this file. Project root is two levels up.
$script:LibRoot = $PSScriptRoot
$script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $script:LibRoot)

. (Join-Path -Path $script:LibRoot -ChildPath 'Config.ps1')
. (Join-Path -Path $script:LibRoot -ChildPath 'Logging.ps1')

function Resolve-ChrysalisConfigPath {
    param(
        [string] $ExplicitConfigPath,
        [string] $ProjectRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitConfigPath)) {
        return $ExplicitConfigPath
    }
    # Default config location: ./config.json at the repo root. Operators who
    # ship the folder elsewhere can pass -ConfigPath explicitly.
    return (Join-Path -Path $ProjectRoot -ChildPath 'config.json')
}

function Resolve-CredsPath {
    param(
        [string] $ExplicitPath,
        [string] $ConfigPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        return $ExplicitPath
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "chrysalis: no -Path supplied and config file '$ConfigPath' was not found. Pass -Path or -ConfigPath explicitly."
    }
    $cfg = Read-ChrysalisConfig -Path $ConfigPath
    return $cfg.fms.creds_file
}

function Save-ChrysalisCredentials {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Username,

        [Parameter(Mandatory = $true)]
        [System.Security.SecureString] $Password,

        [Parameter(Mandatory = $false)]
        [switch] $Force,

        [Parameter(Mandatory = $false)]
        [pscustomobject] $LogContext
    )

    # Refuse-overwrite gate. Default to safe. See ADR-001 plus the runbook
    # under docs/runbooks/credentials.md ("When you need to re-encrypt").
    if ((Test-Path -LiteralPath $Path) -and -not $Force) {
        $msg = "chrysalis: creds file already exists at '$Path'. Re-run with -Force to overwrite, or delete the file first. See docs/runbooks/credentials.md."
        if ($null -ne $LogContext) {
            Write-Log -Context $LogContext -Severity Error -Message $msg
        }
        throw $msg
    }

    # Ensure the parent directory exists. Fail loud with a remediation hint
    # if we cannot create it - usually a permissions issue on Program Files
    # or a path inside a folder the running user does not own.
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        try {
            $null = New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop
        } catch {
            $msg = "chrysalis: cannot create parent directory '$parent' for creds file: $($_.Exception.Message). Check write permissions, or change fms.creds_file in config.json to a path your user owns."
            if ($null -ne $LogContext) {
                Write-Log -Context $LogContext -Severity Error -Message $msg
            }
            throw $msg
        }
    }

    $cred = New-Object System.Management.Automation.PSCredential($Username, $Password)

    # Export-Clixml on a PSCredential serializes the SecureString via DPAPI,
    # scoping the blob to the current Windows user + machine. That is the
    # DPAPI binding mechanism the SDD section 10 depends on. -Force here is
    # for Export-Clixml's own file-overwrite semantics; the caller-level
    # safety gate above is what enforces our refuse-by-default policy.
    try {
        $cred | Export-Clixml -Path $Path -Force -ErrorAction Stop
    } catch {
        $msg = "chrysalis: failed to write encrypted creds file to '$Path': $($_.Exception.Message). Check that you have write access to the path in fms.creds_file."
        if ($null -ne $LogContext) {
            Write-Log -Context $LogContext -Severity Error -Message $msg
        }
        throw $msg
    }

    # Round-trip verification. Read the file back, compare the decrypted
    # password to the in-memory secure string. Fail loud on mismatch.
    $verify = $null
    try {
        $verify = Import-Clixml -Path $Path -ErrorAction Stop
    } catch {
        $msg = "chrysalis: wrote creds file to '$Path' but could not read it back for round-trip verification: $($_.Exception.Message). The file may be unusable; delete it and try again."
        if ($null -ne $LogContext) {
            Write-Log -Context $LogContext -Severity Error -Message $msg
        }
        throw $msg
    }

    if ($null -eq $verify -or $verify.UserName -ne $Username) {
        $msg = "chrysalis: round-trip verification failed for '$Path' - username mismatch after read-back."
        if ($null -ne $LogContext) {
            Write-Log -Context $LogContext -Severity Error -Message $msg
        }
        throw $msg
    }

    # Plaintext never materializes in managed memory. We compare BSTRs
    # character-by-character via Marshal.ReadInt16 and zero-free the BSTRs
    # in `finally`. PtrToStringBSTR would allocate a managed [String] that
    # lives on the GC heap, is potentially interned, and cannot be zeroed -
    # so we deliberately avoid it. Do not "simplify" by reintroducing it.
    $bstrA = [IntPtr]::Zero
    $bstrB = [IntPtr]::Zero
    try {
        $bstrA = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $bstrB = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($verify.Password)

        # BSTR length-prefix is a 4-byte int stored 4 bytes before the buffer,
        # giving the length in bytes (UTF-16 code units * 2).
        $lenA = [System.Runtime.InteropServices.Marshal]::ReadInt32($bstrA, -4)
        $lenB = [System.Runtime.InteropServices.Marshal]::ReadInt32($bstrB, -4)

        $mismatch = $false
        if ($lenA -ne $lenB) {
            $mismatch = $true
        } else {
            $charCount = [int]($lenA / 2)
            for ($i = 0; $i -lt $charCount; $i++) {
                $a = [System.Runtime.InteropServices.Marshal]::ReadInt16($bstrA, $i * 2)
                $b = [System.Runtime.InteropServices.Marshal]::ReadInt16($bstrB, $i * 2)
                if ($a -ne $b) {
                    $mismatch = $true
                    break
                }
            }
        }

        if ($mismatch) {
            # Do not echo plaintext, lengths, or character offsets - any of
            # those could leak structure of the secret.
            $msg = "chrysalis: round-trip verification failed for '$Path' - decrypted password does not match input."
            if ($null -ne $LogContext) {
                Write-Log -Context $LogContext -Severity Error -Message $msg
            }
            throw $msg
        }
    } finally {
        if ($bstrA -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrA)
        }
        if ($bstrB -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrB)
        }
    }
}

function Read-ChrysalisCredentials {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    # Public read path used by pre-flight 2d (SDD section 6.1) and any future
    # consumer. Returns the decrypted PSCredential or throws with operator-
    # actionable remediation. The previous name was
    # Read-ChrysalisCredentialsInternal; the consumer-graduation rename
    # happened in PR #3b when the pre-flight framework landed.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "chrysalis: creds file '$Path' not found. Run EncryptCreds.ps1 to create it. See docs/runbooks/credentials.md."
    }

    try {
        return Import-Clixml -Path $Path -ErrorAction Stop
    } catch {
        throw "chrysalis: cannot decrypt creds file '$Path': $($_.Exception.Message). DPAPI binds the blob to the user who encrypted it and the machine it was encrypted on - if either has changed, re-run EncryptCreds.ps1 -Force as the new user. See docs/runbooks/credentials.md."
    }
}

function Invoke-EncryptCreds {
    [CmdletBinding()]
    param(
        [string] $Path,
        [string] $ConfigPath,
        [switch] $Force,
        [string] $LogRoot
    )

    # Resolve paths up front so logging records exactly what we will operate on.
    $resolvedConfigPath = Resolve-ChrysalisConfigPath -ExplicitConfigPath $ConfigPath -ProjectRoot $script:ProjectRoot
    $resolvedCredsPath = Resolve-CredsPath -ExplicitPath $Path -ConfigPath $resolvedConfigPath

    # Open a log context regardless of whether this is interactive or
    # invoked from a parent script. Audit consistency matters more than
    # avoiding a one-line log file. -LogRoot lets tests inject a sandbox
    # path; absent it, we default to {ProjectRoot}/logs as before.
    if ([string]::IsNullOrWhiteSpace($LogRoot)) {
        $effectiveLogRoot = Join-Path -Path $script:ProjectRoot -ChildPath 'logs'
    } else {
        $effectiveLogRoot = $LogRoot
    }
    $logCtx = New-LogContext -LogRoot $effectiveLogRoot

    try {
        Write-Log -Context $logCtx -Severity Info -Message "EncryptCreds start. CredsPath='$resolvedCredsPath' ConfigPath='$resolvedConfigPath' Force=$([bool]$Force)"

        # do not log secret material - the password and the encrypted blob
        # NEVER touch the log. Read-Host -AsSecureString keeps the plaintext
        # off stdout/stderr and out of the PowerShell history.
        $username = Read-Host -Prompt 'FMS admin username'
        if ([string]::IsNullOrWhiteSpace($username)) {
            throw "chrysalis: username cannot be empty."
        }
        $password = Read-Host -Prompt 'FMS admin password' -AsSecureString
        if ($null -eq $password -or $password.Length -eq 0) {
            throw "chrysalis: password cannot be empty."
        }

        Save-ChrysalisCredentials -Path $resolvedCredsPath -Username $username -Password $password -Force:$Force -LogContext $logCtx

        Write-Log -Context $logCtx -Severity Info -Message "EncryptCreds success. CredsPath='$resolvedCredsPath' Username='$username'"
    } catch {
        # Surface the failure to the log; rethrow so the caller (operator
        # shell or parent script) sees the non-zero exit.
        Write-Log -Context $logCtx -Severity Error -Message "EncryptCreds failed: $($_.Exception.Message)"
        throw
    } finally {
        Close-LogContext -Context $logCtx
    }
}

# Script-mode entry point. When this file is invoked directly (operator runs
# `.\EncryptCreds.ps1`), $MyInvocation.InvocationName is the script path or
# its leaf. When the file is dot-sourced for testing, InvocationName is '.'
# and we skip the auto-invocation so tests can call Invoke-EncryptCreds or
# the helpers directly with mocked Read-Host.
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.InvocationName -ne '') {
    Invoke-EncryptCreds -Path $Path -ConfigPath $ConfigPath -Force:$Force -LogRoot $LogRoot
}
