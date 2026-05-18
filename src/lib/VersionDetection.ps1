# VersionDetection.ps1
# chrysalis FMS version detection. Two paths: binary VersionInfo (primary)
# and Admin API metadata endpoint (fallback). Returns a semver-ish version
# string or throws with structured remediation.
# Implements SDD section 7 (Version Detection).
# Windows-only in PR #3a; macOS/Linux paths land in Phase 5.
# PowerShell 5.1 compatible.

# Modern FMS Admin API requires TLS 1.2+. PS 5.1 defaults the
# ServicePointManager to SSL 3.0 / TLS 1.0, which today's FMS will refuse.
# Adding 1.2 and 1.3 here is a *negotiation set*, not a downgrade or a
# validation bypass. We never disable certificate validation - that risk is
# specifically called out in TODO.md Phase 1 Risk #3.
try {
    $script:DesiredProtocols = [System.Net.SecurityProtocolType]::Tls12
    # Tls13 is named on .NET Framework 4.8+; the underlying OS must also
    # support it (Windows Server 2019+ / 2022+). If the enum value is absent
    # in older runtimes, the [Enum]::Parse below throws and we fall back to
    # TLS 1.2 only.
    $script:DesiredProtocols = $script:DesiredProtocols -bor [System.Enum]::Parse([System.Net.SecurityProtocolType], 'Tls13')
} catch {
    # Older .NET / older Windows. TLS 1.2 alone is acceptable for FMS hosts
    # that are still on Server 2016.
    $script:DesiredProtocols = [System.Net.SecurityProtocolType]::Tls12
}
[System.Net.ServicePointManager]::SecurityProtocol = `
    [System.Net.ServicePointManager]::SecurityProtocol -bor $script:DesiredProtocols

function Get-FmsVersionFromBinary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $InstallRoot,

        [Parameter(Mandatory = $false)]
        [pscustomobject] $LogContext
    )

    if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
        throw "chrysalis: InstallRoot is empty. Set fms.install_root_windows in config.json."
    }

    # Use Join-Path twice to keep both segments quote-safe for paths with
    # spaces (the typical 'C:\Program Files\FileMaker\FileMaker Server' shape).
    $databaseServer = Join-Path -Path $InstallRoot -ChildPath 'Database Server'
    $binaryPath = Join-Path -Path $databaseServer -ChildPath 'fmserver.exe'

    if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) {
        $msg = "chrysalis: fmserver.exe not found at '$binaryPath'. Verify fms.install_root_windows in config.json."
        if ($null -ne $LogContext) {
            Write-Log -Context $LogContext -Severity Error -Message $msg
        }
        throw $msg
    }

    # (Get-Item ...).VersionInfo reads the PE header version block. On a
    # well-formed FMS binary this yields a four-component string like
    # '21.0.3.305'. Files lacking a version resource return $null or empty.
    $info = $null
    try {
        $info = (Get-Item -LiteralPath $binaryPath -ErrorAction Stop).VersionInfo
    } catch {
        $msg = "chrysalis: failed to read VersionInfo from '$binaryPath': $($_.Exception.Message)."
        if ($null -ne $LogContext) {
            Write-Log -Context $LogContext -Severity Error -Message $msg
        }
        throw $msg
    }

    $productVersion = $null
    if ($null -ne $info) {
        $productVersion = $info.ProductVersion
    }
    if ([string]::IsNullOrWhiteSpace($productVersion)) {
        $msg = "chrysalis: fmserver.exe at '$binaryPath' has no ProductVersion in its VersionInfo. The binary may be corrupt or not an FMS executable."
        if ($null -ne $LogContext) {
            Write-Log -Context $LogContext -Severity Error -Message $msg
        }
        throw $msg
    }

    # Normalize: split on '.' and take the first three components. FMS ships
    # four-component ProductVersion strings (major.minor.patch.build); chrysalis
    # works in three-component semver throughout the config and detection paths.
    $parts = $productVersion -split '\.'
    if ($parts.Count -lt 3) {
        $msg = "chrysalis: fmserver.exe ProductVersion '$productVersion' has fewer than three components; cannot normalize to <major>.<minor>.<patch>."
        if ($null -ne $LogContext) {
            Write-Log -Context $LogContext -Severity Error -Message $msg
        }
        throw $msg
    }
    $normalized = ($parts[0..2] -join '.')
    if ($normalized -notmatch '^\d+\.\d+\.\d+$') {
        $msg = "chrysalis: fmserver.exe ProductVersion '$productVersion' did not normalize to a valid <major>.<minor>.<patch> (got '$normalized')."
        if ($null -ne $LogContext) {
            Write-Log -Context $LogContext -Severity Error -Message $msg
        }
        throw $msg
    }

    if ($null -ne $LogContext) {
        Write-Log -Context $LogContext -Severity Info -Message "fmserver.exe at '$binaryPath' reports version '$productVersion'; normalized to '$normalized'."
    }
    return $normalized
}

function Get-FmsVersionFromAdminApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int] $AdminPort,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential] $Credential,

        [Parameter(Mandatory = $false)]
        [pscustomobject] $LogContext
    )

    if ($AdminPort -lt 1 -or $AdminPort -gt 65535) {
        throw "chrysalis: AdminPort '$AdminPort' is out of range (1-65535). Check fms.admin_port in config.json."
    }
    if ($null -eq $Credential) {
        throw "chrysalis: -Credential is required for the Admin API fallback. Run EncryptCreds.ps1 and pass the decoded PSCredential."
    }

    # Single base URL. chrysalis runs on the FMS host (SDD section 2 non-goal
    # 'Remote orchestration'), so localhost is correct. The bound hostname on
    # the FMS admin cert must match 'localhost' or the operator's cert config
    # is misaligned - that surfaces as a TLS error we handle below.
    $baseUrl = "https://localhost:$AdminPort/fmi/admin/api/v2"
    $loginUrl = "$baseUrl/user/login"
    $metadataUrl = "$baseUrl/server/metadata"
    $logoutUrl = "$baseUrl/user/logout"

    $userName = $Credential.UserName
    if ($null -ne $LogContext) {
        # Username is fine to log. Password and bearer token are not.
        Write-Log -Context $LogContext -Severity Info -Message "Admin API version probe. Url='$metadataUrl' Username='$userName'"
    }

    # Build the login body without keeping plaintext in managed strings any
    # longer than the single HTTP call needs. We surface the password from
    # the SecureString via NetworkCredential, build the JSON body string,
    # immediately overwrite the local variable with $null, and let the
    # request body string drop out of scope as soon as Invoke-RestMethod
    # returns. PowerShell strings are immutable and live on the GC heap; we
    # cannot zero them. The BSTR pattern in EncryptCreds.ps1 is the right
    # tool when we control the lifetime of every comparison byte, but the
    # HTTP request body must be a string for Invoke-RestMethod to serialize.
    # The trade-off is documented and time-bounded.
    $token = $null
    $loginBodyJson = $null
    try {
        $netCred = $Credential.GetNetworkCredential()
        $plainPassword = $netCred.Password
        $loginPayload = @{ username = $userName; password = $plainPassword }
        $loginBodyJson = $loginPayload | ConvertTo-Json -Compress
        $loginPayload = $null
        $plainPassword = $null
        $netCred = $null

        $loginResponse = $null
        try {
            $loginResponse = Invoke-RestMethod -Method Post -Uri $loginUrl `
                -ContentType 'application/json' `
                -Body $loginBodyJson `
                -ErrorAction Stop
        } catch {
            $loginBodyJson = $null
            Convert-AdminApiException -Caught $_ -Url $loginUrl -Phase 'login' -LogContext $LogContext
        } finally {
            # Drop the plaintext-bearing body reference as soon as the call
            # returns, success or failure.
            $loginBodyJson = $null
        }

        $token = Read-AdminApiToken -Response $loginResponse
        if ([string]::IsNullOrWhiteSpace($token)) {
            $msg = "chrysalis: Admin API login at '$loginUrl' returned a response with no token. The server may be in an unexpected state; verify FMS is fully started."
            if ($null -ne $LogContext) {
                Write-Log -Context $LogContext -Severity Error -Message $msg
            }
            throw $msg
        }

        $headers = @{ Authorization = "Bearer $token" }
        $metadataResponse = $null
        try {
            $metadataResponse = Invoke-RestMethod -Method Get -Uri $metadataUrl `
                -Headers $headers `
                -ErrorAction Stop
        } catch {
            Convert-AdminApiException -Caught $_ -Url $metadataUrl -Phase 'metadata' -LogContext $LogContext
        }

        $rawVersion = Read-AdminApiVersion -Response $metadataResponse
        if ([string]::IsNullOrWhiteSpace($rawVersion)) {
            $msg = "chrysalis: Admin API metadata at '$metadataUrl' did not contain a version field. The FMS Admin API contract may have changed; capture the response and update VersionDetection.ps1."
            if ($null -ne $LogContext) {
                Write-Log -Context $LogContext -Severity Error -Message $msg
            }
            throw $msg
        }

        $parts = $rawVersion -split '\.'
        if ($parts.Count -lt 3) {
            $msg = "chrysalis: Admin API metadata reported version '$rawVersion' with fewer than three components; cannot normalize to <major>.<minor>.<patch>."
            if ($null -ne $LogContext) {
                Write-Log -Context $LogContext -Severity Error -Message $msg
            }
            throw $msg
        }
        $normalized = ($parts[0..2] -join '.')
        if ($normalized -notmatch '^\d+\.\d+\.\d+$') {
            $msg = "chrysalis: Admin API metadata version '$rawVersion' did not normalize to a valid <major>.<minor>.<patch> (got '$normalized')."
            if ($null -ne $LogContext) {
                Write-Log -Context $LogContext -Severity Error -Message $msg
            }
            throw $msg
        }

        if ($null -ne $LogContext) {
            Write-Log -Context $LogContext -Severity Info -Message "Admin API at '$metadataUrl' reports version '$rawVersion'; normalized to '$normalized'."
        }
        return $normalized
    } finally {
        # Logout is best-effort. The session token expires on its own; we
        # never let a logout failure mask a successful detection or rethrow
        # over a more meaningful error from the calls above.
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            try {
                $logoutHeaders = @{ Authorization = "Bearer $token" }
                Invoke-RestMethod -Method Post -Uri $logoutUrl -Headers $logoutHeaders -ErrorAction Stop | Out-Null
            } catch {
                if ($null -ne $LogContext) {
                    Write-Log -Context $LogContext -Severity Warn -Message "Admin API logout failed at '$logoutUrl': $($_.Exception.Message). Token will expire on its own."
                }
            }
            $token = $null
        }
    }
}

function Read-AdminApiToken {
    param($Response)

    if ($null -eq $Response) { return $null }
    # FMS Admin API v2 returns the token under response.token in the documented
    # shape: { "response": { "token": "..." }, "messages": [ ... ] }. Be
    # tolerant of small shape variations: a top-level 'token' field or a
    # 'data.token' field have shown up in older builds. Probe both.
    if ($null -ne $Response.PSObject.Properties['response']) {
        $inner = $Response.response
        if ($null -ne $inner -and $null -ne $inner.PSObject.Properties['token']) {
            return [string] $inner.token
        }
    }
    if ($null -ne $Response.PSObject.Properties['token']) {
        return [string] $Response.token
    }
    if ($null -ne $Response.PSObject.Properties['data']) {
        $data = $Response.data
        if ($null -ne $data -and $null -ne $data.PSObject.Properties['token']) {
            return [string] $data.token
        }
    }
    return $null
}

function Read-AdminApiVersion {
    param($Response)

    if ($null -eq $Response) { return $null }
    # Documented v2 metadata shape: response.serverVersion (or response.version
    # on some builds). Probe both, plus the top-level fields, before giving up.
    $candidates = @()
    if ($null -ne $Response.PSObject.Properties['response']) {
        $inner = $Response.response
        if ($null -ne $inner) {
            foreach ($name in @('serverVersion', 'version', 'productVersion')) {
                if ($null -ne $inner.PSObject.Properties[$name]) {
                    $candidates += [string] $inner.PSObject.Properties[$name].Value
                }
            }
        }
    }
    foreach ($name in @('serverVersion', 'version', 'productVersion')) {
        if ($null -ne $Response.PSObject.Properties[$name]) {
            $candidates += [string] $Response.PSObject.Properties[$name].Value
        }
    }
    foreach ($c in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($c)) { return $c }
    }
    return $null
}

function Get-AdminApiErrorDetailInternal {
    # Pure message-shaping seam. Given pre-extracted error details (kind,
    # status code, response body, network status, raw message), produces the
    # chrysalis-shaped error text and optional remediation lines. No I/O, no
    # reflection, no exception unwrapping - that's all in
    # Convert-AdminApiException above this seam. Existing for testability:
    # real System.Net.WebException construction with a populated Response is
    # impractical in a unit test (the private-field reflection path is
    # statically typed and brittle). Real WebException unpacking is exercised
    # manually on the test FMS host; unit tests cover this seam directly.
    #
    # $Kind is one of: 'Auth' | 'Http' | 'Network' | 'Unknown'.
    # Returns a hashtable with: Message (string), Remediations (string[]).
    param(
        [Parameter(Mandatory = $true)] [string] $Kind,
        [Parameter(Mandatory = $true)] [string] $Url,
        [Parameter(Mandatory = $true)] [string] $Phase,
        [Parameter(Mandatory = $false)] [int]    $StatusCode = 0,
        [Parameter(Mandatory = $false)] [string] $BodyText,
        [Parameter(Mandatory = $false)] [string] $NetworkStatus,
        [Parameter(Mandatory = $false)] [string] $RawMessage
    )

    $remediations = @()
    $bodySnippet = $null
    if (-not [string]::IsNullOrWhiteSpace($BodyText)) {
        $bodySnippet = $BodyText
        try {
            $parsed = $BodyText | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $parsed -and $null -ne $parsed.PSObject.Properties['messages']) {
                $msgs = @($parsed.messages)
                if ($msgs.Count -gt 0 -and $null -ne $msgs[0].PSObject.Properties['message']) {
                    $bodySnippet = [string] $msgs[0].message
                }
            }
        } catch {
            # body isn't JSON; fall through with the raw snippet
        }
        # Belt-and-braces: a server-side error message could in principle
        # echo the Authorization header. Strip any 'Bearer <token>' pattern
        # before it makes its way into the log.
        $bodySnippet = $bodySnippet -replace 'Bearer\s+\S+', 'Bearer [REDACTED]'
        if ($bodySnippet.Length -gt 200) {
            $bodySnippet = $bodySnippet.Substring(0, 200) + '...'
        }
    }

    switch ($Kind) {
        'Auth' {
            $msg = "chrysalis: TLS handshake failed contacting Admin API at '$Url': $RawMessage. The FMS admin certificate is not trusted by the system cert store. Fix the FMS admin cert configuration (install the issuing CA into the Windows trust store, or rotate the FMS admin cert) - chrysalis deliberately does not provide a -SkipCertificateCheck bypass."
            $remediations += "Trust the FMS admin cert: import the issuing certificate authority into LocalMachine\Root, or replace the FMS admin cert with one chained to a CA already in the system trust store."
            return @{ Message = $msg; Remediations = $remediations }
        }
        'Http' {
            if ($StatusCode -eq 401 -or $StatusCode -eq 403) {
                $msg = "chrysalis: Admin API rejected credentials at '$Url' (HTTP $StatusCode). Credentials may be wrong or the FMS admin password may have rotated; re-run EncryptCreds.ps1 with the current password. See docs/runbooks/credentials.md."
                $remediations += "Re-run EncryptCreds.ps1 -Force as the user that runs chrysalis. See docs/runbooks/credentials.md ('When you need to re-encrypt')."
                return @{ Message = $msg; Remediations = $remediations }
            }
            $snippetText = if ([string]::IsNullOrWhiteSpace($bodySnippet)) { '' } else { " ServerMessage='$bodySnippet'" }
            $msg = "chrysalis: Admin API call to '$Url' failed during $Phase with HTTP $StatusCode.$snippetText"
            return @{ Message = $msg; Remediations = $remediations }
        }
        'Network' {
            $msg = "chrysalis: FMS Admin API not reachable at '$Url' during $Phase ($NetworkStatus). Is the FileMaker Server service running and listening on the configured admin_port?"
            $remediations += "Check service state: Get-Service 'FileMaker Server'. Verify admin_port in config.json matches the port FMS is listening on."
            return @{ Message = $msg; Remediations = $remediations }
        }
        default {
            $msg = "chrysalis: Admin API call to '$Url' failed during ${Phase}: $RawMessage"
            return @{ Message = $msg; Remediations = $remediations }
        }
    }
}

function Convert-AdminApiException {
    # Translates a low-level network/HTTP exception into a chrysalis-shaped
    # throw with operator-actionable remediation. Always throws; never returns.
    # Real exception-unwrapping lives here; the message-shaping lives in
    # Get-AdminApiErrorDetailInternal so it can be unit-tested without
    # constructing a real WebException with a populated Response.
    param(
        [Parameter(Mandatory = $true)] $Caught,
        [Parameter(Mandatory = $true)] [string] $Url,
        [Parameter(Mandatory = $true)] [string] $Phase,
        [Parameter(Mandatory = $false)] [pscustomobject] $LogContext
    )

    $ex = $Caught.Exception

    # Walk the exception chain to find the meaningful inner type. PowerShell
    # 5.1's Invoke-RestMethod wraps the underlying exception in a
    # System.Net.WebException, which itself may wrap a TLS auth exception.
    $authException = $null
    $webException = $null
    $cursor = $ex
    while ($null -ne $cursor) {
        if ($cursor -is [System.Security.Authentication.AuthenticationException]) {
            $authException = $cursor
        }
        if ($cursor -is [System.Net.WebException] -and $null -eq $webException) {
            $webException = $cursor
        }
        $cursor = $cursor.InnerException
    }

    $detail = $null

    if ($null -ne $authException) {
        $detail = Get-AdminApiErrorDetailInternal -Kind 'Auth' -Url $Url -Phase $Phase -RawMessage $authException.Message
    } elseif ($null -ne $webException) {
        $response = $webException.Response
        if ($null -ne $response) {
            $statusCode = 0
            try {
                $statusCode = [int] $response.StatusCode
            } catch { }
            $bodyText = $null
            try {
                $stream = $response.GetResponseStream()
                if ($null -ne $stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $bodyText = $reader.ReadToEnd()
                    $reader.Dispose()
                }
            } catch {
                # Body read failed; that's fine, we still have the status code.
            }
            $detail = Get-AdminApiErrorDetailInternal -Kind 'Http' -Url $Url -Phase $Phase -StatusCode $statusCode -BodyText $bodyText
        } else {
            # No response object: connection-level failure (refused, reset, DNS,
            # service not running).
            $detail = Get-AdminApiErrorDetailInternal -Kind 'Network' -Url $Url -Phase $Phase -NetworkStatus ([string] $webException.Status)
        }
    } else {
        # Catch-all. Preserve the original message; the operator can chase the
        # stack trace from the log.
        $detail = Get-AdminApiErrorDetailInternal -Kind 'Unknown' -Url $Url -Phase $Phase -RawMessage $ex.Message
    }

    if ($null -ne $LogContext) {
        Write-Log -Context $LogContext -Severity Error -Message $detail.Message
        foreach ($r in $detail.Remediations) {
            Write-Log -Context $LogContext -Severity Remediation -Message $r
        }
    }
    throw $detail.Message
}

function Get-FmsVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Config,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential] $Credential,

        [Parameter(Mandatory = $false)]
        [pscustomobject] $LogContext
    )

    if ($null -eq $Config -or $null -eq $Config.fms) {
        throw "chrysalis: Get-FmsVersion requires a parsed config object with an 'fms' block."
    }

    $installRoot = $Config.fms.install_root_windows
    $binaryError = $null
    $binaryException = $null
    try {
        return (Get-FmsVersionFromBinary -InstallRoot $installRoot -LogContext $LogContext)
    } catch {
        # Capture both the message (for the operator-facing aggregate string)
        # and the exception object (so PR #3b's pre-flight consumer can
        # type-switch on the inner exception rather than string-sniffing the
        # message).
        $binaryException = $_.Exception
        $binaryError = $_.Exception.Message
        if ($null -ne $LogContext) {
            Write-Log -Context $LogContext -Severity Warn -Message "Binary version detection failed; falling back to Admin API. BinaryError='$binaryError'"
        }
    }

    if ($null -eq $Credential) {
        $msg = "chrysalis: binary version detection failed and no -Credential was supplied for the Admin API fallback. Pass the PSCredential from Read-ChrysalisCredentials. BinaryError='$binaryError'"
        if ($null -ne $LogContext) {
            Write-Log -Context $LogContext -Severity Error -Message $msg
        }
        throw $msg
    }

    $adminPort = [int] $Config.fms.admin_port
    try {
        return (Get-FmsVersionFromAdminApi -AdminPort $adminPort -Credential $Credential -LogContext $LogContext)
    } catch {
        $apiException = $_.Exception
        $apiError = $_.Exception.Message
        $msg = "chrysalis: both version-detection paths failed. BinaryError='$binaryError' AdminApiError='$apiError'"
        if ($null -ne $LogContext) {
            Write-Log -Context $LogContext -Severity Error -Message $msg
        }
        # Wrap both inner exceptions in an AggregateException so callers can
        # type-switch (e.g. PR #3b's pre-flight) instead of parsing $msg.
        # AggregateException.Message already includes the wrapped messages,
        # so existing substring-based assertions continue to pass.
        $aggregate = New-Object System.AggregateException($msg, @($binaryException, $apiException))
        throw $aggregate
    }
}
