# VersionDetection.Tests.ps1
# Pester 5.x coverage for src/lib/VersionDetection.ps1.
#
# Binary VersionInfo tests rely on a real Windows PE file (notepad.exe /
# cmd.exe) because Get-Item.VersionInfo reads the PE version resource.
# A zero-byte file has no version resource. We copy a stock Windows binary
# into $TestDrive and assert detection against its real VersionInfo - this
# is why notepad.exe is referenced here. The binary tests skip on non-
# Windows hosts (DPAPI is unrelated, but PE version resources are a
# Windows construct).
#
# Admin API tests use Pester Mock to stub Invoke-RestMethod and run on
# any platform.
#
# Real WebException unpacking (reflection over the private m_Response
# field, GetResponseStream() body reads, etc.) is exercised manually on
# the test FMS host. Unit tests cover the message-shaping logic via the
# Get-AdminApiErrorDetailInternal seam - constructing a real
# HttpWebResponse with a populated body in-process is impractical
# (private ctors, internal preconditions on the response stream) and the
# private-field reflection path fails the WebResponse type check on PS
# 5.1's strongly-typed SetValue.

# Test-IsWindowsHost lives at file top-level (not inside BeforeAll) because
# Pester 5 evaluates -Skip parameters on Describe blocks at Discovery time,
# which runs BEFORE BeforeAll. A function only defined in BeforeAll is
# unavailable during Discovery and the -Skip expression throws
# CommandNotFoundException.
function Test-IsWindowsHost {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

BeforeAll {
    $script:RepoRoot = Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'src/lib/Logging.ps1')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'src/lib/VersionDetection.ps1')

    function New-TestSecureString {
        param([string] $Plain)
        $ss = New-Object System.Security.SecureString
        foreach ($c in $Plain.ToCharArray()) { $ss.AppendChar($c) }
        $ss.MakeReadOnly()
        return $ss
    }

    function New-TestCredential {
        param(
            [string] $User = 'fmsadmin',
            [string] $Pass = 'unit-test-password'
        )
        return (New-Object System.Management.Automation.PSCredential($User, (New-TestSecureString -Plain $Pass)))
    }

    function New-MinimalConfigObject {
        param(
            [string] $InstallRoot = 'C:\Program Files\FileMaker\FileMaker Server',
            [int] $AdminPort = 16001
        )
        return [pscustomobject]@{
            fms = [pscustomobject]@{
                install_root_windows = $InstallRoot
                admin_port           = $AdminPort
                creds_file           = 'C:\chrysalis\creds.xml'
            }
        }
    }

    function New-FakeFmserverInstall {
        # Copy a real Windows PE binary into $TestDrive in the expected
        # 'Database Server\fmserver.exe' layout so Get-FmsVersionFromBinary
        # can read a real VersionInfo from it. notepad.exe is a small,
        # always-present PE on Windows with a populated version resource.
        param(
            [Parameter(Mandatory = $true)] [string] $InstallRoot
        )
        $databaseServer = Join-Path -Path $InstallRoot -ChildPath 'Database Server'
        New-Item -ItemType Directory -Path $databaseServer -Force | Out-Null
        $targetBinary = Join-Path -Path $databaseServer -ChildPath 'fmserver.exe'
        $source = Join-Path -Path $env:WINDIR -ChildPath 'System32\notepad.exe'
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            # Older / minimal Windows images may not ship notepad.exe at this
            # path. Fall back to cmd.exe which is universally present.
            $source = Join-Path -Path $env:WINDIR -ChildPath 'System32\cmd.exe'
        }
        Copy-Item -LiteralPath $source -Destination $targetBinary -Force
        return $targetBinary
    }

    function Get-ExpectedNormalizedVersion {
        param([string] $BinaryPath)
        $raw = (Get-Item -LiteralPath $BinaryPath).VersionInfo.ProductVersion
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $parts = $raw -split '\.'
        if ($parts.Count -lt 3) { return $null }
        return ($parts[0..2] -join '.')
    }
}

Describe 'Get-FmsVersionFromBinary' -Skip:(-not (Test-IsWindowsHost)) {

    It 'returns a normalized three-component version for a real PE binary' {
        # Uses notepad.exe (or cmd.exe) as a stand-in for fmserver.exe. We
        # do NOT assert a fixed version literal because the underlying
        # Windows build varies across CI/dev hosts. We assert (a) the
        # function returns a value that matches ^\d+\.\d+\.\d+$ and (b)
        # it matches what we would compute from VersionInfo ourselves.
        $installRoot = Join-Path -Path $TestDrive -ChildPath 'FMS Real'
        $binary = New-FakeFmserverInstall -InstallRoot $installRoot
        $expected = Get-ExpectedNormalizedVersion -BinaryPath $binary

        $actual = Get-FmsVersionFromBinary -InstallRoot $installRoot
        $actual | Should -Match '^\d+\.\d+\.\d+$'
        if ($null -ne $expected) {
            $actual | Should -Be $expected
        }
    }

    It 'throws naming the resolved path when the binary is missing' {
        $installRoot = Join-Path -Path $TestDrive -ChildPath 'Missing FMS'
        New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
        $expectedPath = Join-Path -Path $installRoot -ChildPath 'Database Server\fmserver.exe'

        { Get-FmsVersionFromBinary -InstallRoot $installRoot } |
            Should -Throw -ExpectedMessage "*fmserver.exe not found at '$expectedPath'*install_root_windows*"
    }

    It 'normalizes a four-component ProductVersion to three components' {
        # Mock Get-Item to return a synthetic VersionInfo with a known
        # ProductVersion. The normalization is what we care about here;
        # using a mock avoids depending on whatever ProductVersion shape
        # the host's notepad happens to ship.
        #
        # We still need the file to exist on disk so the source's
        # Test-Path -PathType Leaf check passes. Set-Content -Value $null
        # writes a zero-byte file without requiring [byte[]] input (which
        # -Encoding Byte demands on PS 5.1).
        $installRoot = Join-Path -Path $TestDrive -ChildPath 'Mocked FMS'
        $databaseServer = Join-Path -Path $installRoot -ChildPath 'Database Server'
        New-Item -ItemType Directory -Path $databaseServer -Force | Out-Null
        $fakeBinary = Join-Path -Path $databaseServer -ChildPath 'fmserver.exe'
        Set-Content -LiteralPath $fakeBinary -Value $null -Force -ErrorAction Stop

        Mock -CommandName Get-Item -ParameterFilter {
            $LiteralPath -eq $fakeBinary
        } -MockWith {
            return [pscustomobject]@{
                VersionInfo = [pscustomobject]@{ ProductVersion = '21.0.3.305' }
            }
        }

        $actual = Get-FmsVersionFromBinary -InstallRoot $installRoot
        $actual | Should -Be '21.0.3'
    }

    It 'throws when ProductVersion is empty' {
        $installRoot = Join-Path -Path $TestDrive -ChildPath 'Empty VI'
        $databaseServer = Join-Path -Path $installRoot -ChildPath 'Database Server'
        New-Item -ItemType Directory -Path $databaseServer -Force | Out-Null
        $fakeBinary = Join-Path -Path $databaseServer -ChildPath 'fmserver.exe'
        Set-Content -LiteralPath $fakeBinary -Value $null -Force -ErrorAction Stop

        Mock -CommandName Get-Item -ParameterFilter {
            $LiteralPath -eq $fakeBinary
        } -MockWith {
            return [pscustomobject]@{
                VersionInfo = [pscustomobject]@{ ProductVersion = '' }
            }
        }

        { Get-FmsVersionFromBinary -InstallRoot $installRoot } |
            Should -Throw -ExpectedMessage "*no ProductVersion*"
    }

    It 'throws when ProductVersion has fewer than three components' {
        $installRoot = Join-Path -Path $TestDrive -ChildPath 'Two Component'
        $databaseServer = Join-Path -Path $installRoot -ChildPath 'Database Server'
        New-Item -ItemType Directory -Path $databaseServer -Force | Out-Null
        $fakeBinary = Join-Path -Path $databaseServer -ChildPath 'fmserver.exe'
        Set-Content -LiteralPath $fakeBinary -Value $null -Force -ErrorAction Stop

        Mock -CommandName Get-Item -ParameterFilter {
            $LiteralPath -eq $fakeBinary
        } -MockWith {
            return [pscustomobject]@{
                VersionInfo = [pscustomobject]@{ ProductVersion = '21.0' }
            }
        }

        { Get-FmsVersionFromBinary -InstallRoot $installRoot } |
            Should -Throw -ExpectedMessage "*fewer than three components*'21.0'*"
    }

    It 'logs an Info line on success when a LogContext is provided' {
        $installRoot = Join-Path -Path $TestDrive -ChildPath 'Logged FMS'
        # Setup side-effect: lays down 'Database Server\fmserver.exe' from a
        # real PE binary so the source's Test-Path and Get-Item.VersionInfo
        # both have something real to read. We don't need the returned path.
        $null = New-FakeFmserverInstall -InstallRoot $installRoot
        $logRoot = Join-Path -Path $TestDrive -ChildPath ('logs-bin-' + [guid]::NewGuid().ToString('N'))
        $ctx = New-LogContext -LogRoot $logRoot -RunId 'binlog'
        try {
            $actual = Get-FmsVersionFromBinary -InstallRoot $installRoot -LogContext $ctx
            $actual | Should -Match '^\d+\.\d+\.\d+$'
        } finally {
            Close-LogContext -Context $ctx
        }
        $content = Get-Content -LiteralPath $ctx.LogPath -Raw
        $content | Should -Match "fmserver.exe at '"
        $content | Should -Match 'normalized to'
    }
}

Describe 'Get-FmsVersionFromAdminApi' {

    BeforeEach {
        $script:logRoot = Join-Path -Path $TestDrive -ChildPath ('logs-api-' + [guid]::NewGuid().ToString('N'))
        $script:ctx = New-LogContext -LogRoot $script:logRoot -RunId 'apilog'
        $script:cred = New-TestCredential -User 'fmsadmin' -Pass 'unit-test-pw'
        $script:fakeToken = 'TOKEN-deadbeef-NEVER-LOG-ME'
    }

    AfterEach {
        if ($script:ctx -and -not $script:ctx.Closed) {
            Close-LogContext -Context $script:ctx
        }
    }

    It 'returns the normalized version from a successful login + metadata exchange' {
        Mock -CommandName Invoke-RestMethod -MockWith {
            param($Method, $Uri, $ContentType, $Body, $Headers, $ErrorAction)
            if ($Uri -match 'user/login$') {
                return [pscustomobject]@{
                    response = [pscustomobject]@{ token = $script:fakeToken }
                }
            }
            if ($Uri -match 'server/metadata$') {
                return [pscustomobject]@{
                    response = [pscustomobject]@{ serverVersion = '21.0.3.305' }
                }
            }
            if ($Uri -match 'user/logout$') {
                return [pscustomobject]@{ response = [pscustomobject]@{} }
            }
            throw "unexpected URI in mock: $Uri"
        }

        $actual = Get-FmsVersionFromAdminApi -AdminPort 16001 -Credential $script:cred -LogContext $script:ctx
        $actual | Should -Be '21.0.3'
    }

    It 'never writes the bearer token or the password to the log file' {
        Mock -CommandName Invoke-RestMethod -MockWith {
            param($Method, $Uri, $ContentType, $Body, $Headers, $ErrorAction)
            if ($Uri -match 'user/login$') {
                return [pscustomobject]@{ response = [pscustomobject]@{ token = $script:fakeToken } }
            }
            if ($Uri -match 'server/metadata$') {
                return [pscustomobject]@{ response = [pscustomobject]@{ serverVersion = '21.0.3.305' } }
            }
            return [pscustomobject]@{ response = [pscustomobject]@{} }
        }

        $cred2 = New-TestCredential -User 'fmsadmin' -Pass 'P@ssw0rd-Sentinel-x9z'
        $null = Get-FmsVersionFromAdminApi -AdminPort 16001 -Credential $cred2 -LogContext $script:ctx
        Close-LogContext -Context $script:ctx

        $content = Get-Content -LiteralPath $script:ctx.LogPath -Raw
        $content | Should -Not -Match ([regex]::Escape($script:fakeToken))
        $content | Should -Not -Match 'P@ssw0rd-Sentinel-x9z'
        # Username is fine.
        $content | Should -Match 'fmsadmin'
    }

    It 'throws a TLS-specific error with cert-store remediation when login fails on a TLS handshake' {
        Mock -CommandName Invoke-RestMethod -MockWith {
            $inner = New-Object System.Security.Authentication.AuthenticationException('The remote certificate is invalid according to the validation procedure.')
            throw $inner
        }

        { Get-FmsVersionFromAdminApi -AdminPort 16001 -Credential $script:cred -LogContext $script:ctx } |
            Should -Throw -ExpectedMessage '*TLS handshake failed*cert*'
    }

    It 'shapes a credentials-may-be-wrong message on a 401 (seam test)' {
        # Exercises Get-AdminApiErrorDetailInternal directly. Real
        # WebException unpacking with a populated Response is impractical
        # to construct in-process (see file header). The seam is the
        # contract the unwrapper hands off to; if the unwrapper feeds it
        # Kind='Http' with StatusCode=401, this is the message the operator
        # will see.
        $detail = Get-AdminApiErrorDetailInternal -Kind 'Http' `
            -Url 'https://localhost:16001/fmi/admin/api/v2/user/login' `
            -Phase 'login' `
            -StatusCode 401

        $detail.Message | Should -Match 'credentials may be wrong'
        $detail.Message | Should -Match 'EncryptCreds.ps1'
        $detail.Message | Should -Match 'HTTP 401'
        # Operator-actionable remediation must be present.
        ($detail.Remediations -join "`n") | Should -Match 'EncryptCreds.ps1'
    }

    It 'throws "not reachable" when the connection cannot be established' {
        Mock -CommandName Invoke-RestMethod -MockWith {
            # WebException with no Response = connection-level failure
            $webEx = New-Object System.Net.WebException('Unable to connect to the remote server', $null, [System.Net.WebExceptionStatus]::ConnectFailure, $null)
            throw $webEx
        }

        { Get-FmsVersionFromAdminApi -AdminPort 16001 -Credential $script:cred -LogContext $script:ctx } |
            Should -Throw -ExpectedMessage '*FMS Admin API not reachable*'
    }

    It 'still returns the version when logout throws (logout is best-effort)' {
        Mock -CommandName Invoke-RestMethod -MockWith {
            param($Method, $Uri, $ContentType, $Body, $Headers, $ErrorAction)
            if ($Uri -match 'user/login$') {
                return [pscustomobject]@{ response = [pscustomobject]@{ token = $script:fakeToken } }
            }
            if ($Uri -match 'server/metadata$') {
                return [pscustomobject]@{ response = [pscustomobject]@{ serverVersion = '21.0.3.305' } }
            }
            if ($Uri -match 'user/logout$') {
                throw 'logout boom'
            }
        }

        $actual = Get-FmsVersionFromAdminApi -AdminPort 16001 -Credential $script:cred -LogContext $script:ctx
        $actual | Should -Be '21.0.3'

        Close-LogContext -Context $script:ctx
        $content = Get-Content -LiteralPath $script:ctx.LogPath -Raw
        $content | Should -Match 'Admin API logout failed'
        $content | Should -Match '\[WARN\]'
    }

    It 'rejects an out-of-range AdminPort before any network call' {
        Mock -CommandName Invoke-RestMethod -MockWith { throw 'should not be called' }
        { Get-FmsVersionFromAdminApi -AdminPort 0 -Credential $script:cred -LogContext $script:ctx } |
            Should -Throw -ExpectedMessage '*out of range*'
        { Get-FmsVersionFromAdminApi -AdminPort 70000 -Credential $script:cred -LogContext $script:ctx } |
            Should -Throw -ExpectedMessage '*out of range*'
    }

    It 'throws when the metadata response has no version field' {
        Mock -CommandName Invoke-RestMethod -MockWith {
            param($Method, $Uri, $ContentType, $Body, $Headers, $ErrorAction)
            if ($Uri -match 'user/login$') {
                return [pscustomobject]@{ response = [pscustomobject]@{ token = $script:fakeToken } }
            }
            if ($Uri -match 'server/metadata$') {
                return [pscustomobject]@{ response = [pscustomobject]@{ unrelated = 'no version here' } }
            }
            return [pscustomobject]@{ response = [pscustomobject]@{} }
        }

        { Get-FmsVersionFromAdminApi -AdminPort 16001 -Credential $script:cred -LogContext $script:ctx } |
            Should -Throw -ExpectedMessage '*did not contain a version field*'
    }

    It 'scrubs Bearer-token patterns from server error-body snippets (seam test)' {
        # Threat model: an FMS error response body could in principle echo
        # the Authorization header back to us. The sentinel token must not
        # appear in the shaped message, and the redaction marker must be
        # visible. Exercises Get-AdminApiErrorDetailInternal directly with
        # a synthetic JSON body - real WebException construction with a
        # populated Response body is impractical in-process (see file
        # header).
        $sentinel = $script:fakeToken
        $bodyText = '{"messages":[{"code":"500","message":"Token Bearer ' + $sentinel + ' invalid"}]}'

        $detail = Get-AdminApiErrorDetailInternal -Kind 'Http' `
            -Url 'https://localhost:16001/fmi/admin/api/v2/server/metadata' `
            -Phase 'metadata' `
            -StatusCode 500 `
            -BodyText $bodyText

        $detail.Message | Should -Not -Match ([regex]::Escape($sentinel))
        $detail.Message | Should -Match 'Bearer \[REDACTED\]'
        $detail.Message | Should -Match 'HTTP 500'
    }

    It 'throws when login succeeds but the response carries no token' {
        # Source lines ~180-186: empty/missing token in an otherwise-200
        # login response. The function must reject this rather than fall
        # through and present a blank Authorization header upstream.
        Mock -CommandName Invoke-RestMethod -MockWith {
            param($Method, $Uri, $ContentType, $Body, $Headers, $ErrorAction)
            if ($Uri -match 'user/login$') {
                return [pscustomobject]@{ response = [pscustomobject]@{} }
            }
            if ($Uri -match 'server/metadata$') {
                throw 'metadata should never be called when login has no token'
            }
            return [pscustomobject]@{ response = [pscustomobject]@{} }
        }

        { Get-FmsVersionFromAdminApi -AdminPort 16001 -Credential $script:cred -LogContext $script:ctx } |
            Should -Throw -ExpectedMessage '*returned a response with no token*'

        Close-LogContext -Context $script:ctx
        $content = Get-Content -LiteralPath $script:ctx.LogPath -Raw
        # There is no token in this scenario, but assert the well-known
        # success-path sentinel isn't somehow present, and username is fine.
        $content | Should -Not -Match ([regex]::Escape($script:fakeToken))
        $content | Should -Match 'fmsadmin'
    }
}

Describe 'Get-FmsVersion (coordinator)' {

    BeforeEach {
        $script:logRoot = Join-Path -Path $TestDrive -ChildPath ('logs-coord-' + [guid]::NewGuid().ToString('N'))
        $script:ctx = New-LogContext -LogRoot $script:logRoot -RunId 'coord'
        $script:cred = New-TestCredential
        $script:cfg = New-MinimalConfigObject -InstallRoot (Join-Path -Path $TestDrive -ChildPath 'coord-install') -AdminPort 16001
    }

    AfterEach {
        if ($script:ctx -and -not $script:ctx.Closed) {
            Close-LogContext -Context $script:ctx
        }
    }

    It 'returns the binary version and skips the Admin API path when binary succeeds' {
        Mock -CommandName Get-FmsVersionFromBinary -MockWith { return '21.0.3' }
        Mock -CommandName Get-FmsVersionFromAdminApi -MockWith {
            throw 'should never be called when binary succeeds'
        }

        $actual = Get-FmsVersion -Config $script:cfg -Credential $script:cred -LogContext $script:ctx
        $actual | Should -Be '21.0.3'
        Should -Invoke -CommandName Get-FmsVersionFromAdminApi -Times 0
    }

    It 'falls back to the Admin API when the binary path fails and logs a Warn' {
        Mock -CommandName Get-FmsVersionFromBinary -MockWith { throw 'fmserver.exe not found' }
        Mock -CommandName Get-FmsVersionFromAdminApi -MockWith { return '21.0.4' }

        $actual = Get-FmsVersion -Config $script:cfg -Credential $script:cred -LogContext $script:ctx
        $actual | Should -Be '21.0.4'

        Close-LogContext -Context $script:ctx
        $content = Get-Content -LiteralPath $script:ctx.LogPath -Raw
        $content | Should -Match '\[WARN\].*falling back to Admin API'
    }

    It 'throws an aggregate error referencing both inner failures when both paths fail' {
        Mock -CommandName Get-FmsVersionFromBinary -MockWith { throw 'fmserver.exe nowhere' }
        Mock -CommandName Get-FmsVersionFromAdminApi -MockWith { throw 'admin api dead' }

        { Get-FmsVersion -Config $script:cfg -Credential $script:cred -LogContext $script:ctx } |
            Should -Throw -ExpectedMessage "*both version-detection paths failed*fmserver.exe nowhere*admin api dead*"

        # Lock the contract for PR #3b's pre-flight consumer: the thrown
        # error must be a real AggregateException carrying both inner
        # exceptions, not a flat string.
        $thrown = $null
        try {
            Get-FmsVersion -Config $script:cfg -Credential $script:cred -LogContext $script:ctx
        } catch {
            $thrown = $_.Exception
        }
        $thrown | Should -Not -BeNullOrEmpty
        $thrown -is [System.AggregateException] | Should -BeTrue
        $thrown.InnerExceptions.Count | Should -Be 2
    }

    It 'throws cleanly without calling the Admin API when -Credential is not supplied and binary fails' {
        Mock -CommandName Get-FmsVersionFromBinary -MockWith { throw 'fmserver.exe missing' }
        Mock -CommandName Get-FmsVersionFromAdminApi -MockWith {
            throw 'should not be called when no credential is supplied'
        }

        { Get-FmsVersion -Config $script:cfg -LogContext $script:ctx } |
            Should -Throw -ExpectedMessage "*no -Credential was supplied*"
        Should -Invoke -CommandName Get-FmsVersionFromAdminApi -Times 0
    }
}
