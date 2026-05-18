# EncryptCreds.Tests.ps1
# Pester 5.x coverage for src/lib/EncryptCreds.ps1.
#
# DPAPI is Windows-only. These tests skip on non-Windows hosts (see SDD
# section 10 cross-platform note). The CI matrix runs the Windows leg; the
# Linux/macOS leg of the matrix will see these tests as skipped, which is
# the intended outcome.

# Test-IsWindowsHost lives at file top-level (not inside BeforeAll) because
# Pester 5 evaluates -Skip parameters on Describe blocks at Discovery time,
# which runs BEFORE BeforeAll. A function only defined in BeforeAll is
# unavailable during Discovery and the -Skip expression throws
# CommandNotFoundException. PS 5.1 lacks $IsWindows; the Platform check
# works on both PS 5.1 and PS 7+ without needing the automatic variable.
function Test-IsWindowsHost {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

BeforeAll {
    $script:RepoRoot = Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'src/lib/Logging.ps1')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'src/lib/Config.ps1')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'src/lib/EncryptCreds.ps1')

    function New-TestSecureString {
        param([string] $Plain)
        $ss = New-Object System.Security.SecureString
        foreach ($c in $Plain.ToCharArray()) {
            $ss.AppendChar($c)
        }
        $ss.MakeReadOnly()
        return $ss
    }

    function Get-SecureStringPlaintext {
        param([System.Security.SecureString] $Secure)
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
        try {
            return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }

    function New-MinimalConfig {
        param(
            [string] $CredsFile,
            [string] $Path
        )
        $cfg = [ordered]@{
            target_version = '21.0.3'
            upgrade_mode   = 'in_place'
            installers     = [ordered]@{
                '21.0.3' = [ordered]@{
                    windows = 'https://example.invalid/installers/fms_Setup_21.0.3.exe'
                    macos   = 'https://example.invalid/installers/fms_Setup_21.0.3.pkg'
                    linux   = 'https://example.invalid/installers/fms_Setup_21.0.3.rpm'
                    sha256  = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
                }
            }
            fms = [ordered]@{
                install_root_windows = 'C:\Program Files\FileMaker\FileMaker Server'
                admin_port           = 16001
                creds_file           = $CredsFile
            }
            backup_root      = 'C:\FMS_Backups'
            shutdown_sequence = @('SERVER')
            startup_sequence  = @('SERVER')
        }
        ($cfg | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding UTF8
    }
}

Describe 'EncryptCreds - Save-ChrysalisCredentials' -Skip:(-not (Test-IsWindowsHost)) {

    It 'round-trips a username and password through DPAPI' {
        $credsPath = Join-Path -Path $TestDrive -ChildPath 'creds-happy.xml'
        $securePwd = New-TestSecureString -Plain 'p@ssw0rd-Happy-Path!'
        Save-ChrysalisCredentials -Path $credsPath -Username 'fmsadmin' -Password $securePwd

        Test-Path -LiteralPath $credsPath | Should -BeTrue
        $readBack = Import-Clixml -Path $credsPath
        $readBack.UserName | Should -Be 'fmsadmin'
        (Get-SecureStringPlaintext -Secure $readBack.Password) | Should -Be 'p@ssw0rd-Happy-Path!'
    }

    It 'refuses to overwrite an existing creds file without -Force, naming the path' {
        $credsPath = Join-Path -Path $TestDrive -ChildPath 'creds-noforce.xml'
        Set-Content -LiteralPath $credsPath -Value 'placeholder'

        $securePwd = New-TestSecureString -Plain 'secret'
        { Save-ChrysalisCredentials -Path $credsPath -Username 'fmsadmin' -Password $securePwd } |
            Should -Throw -ExpectedMessage "*creds file already exists at '$credsPath'*-Force*"
    }

    It 'overwrites an existing creds file when -Force is passed' {
        $credsPath = Join-Path -Path $TestDrive -ChildPath 'creds-force.xml'
        $first = New-TestSecureString -Plain 'first-password'
        Save-ChrysalisCredentials -Path $credsPath -Username 'fmsadmin' -Password $first

        $second = New-TestSecureString -Plain 'second-password'
        Save-ChrysalisCredentials -Path $credsPath -Username 'fmsadmin2' -Password $second -Force

        $readBack = Import-Clixml -Path $credsPath
        $readBack.UserName | Should -Be 'fmsadmin2'
        (Get-SecureStringPlaintext -Secure $readBack.Password) | Should -Be 'second-password'
    }
}

Describe 'EncryptCreds - Invoke-EncryptCreds end-to-end' -Skip:(-not (Test-IsWindowsHost)) {

    BeforeEach {
        $script:credsPath = Join-Path -Path $TestDrive -ChildPath ('creds-' + [guid]::NewGuid().ToString('N') + '.xml')
        $script:configPath = Join-Path -Path $TestDrive -ChildPath ('config-' + [guid]::NewGuid().ToString('N') + '.json')
        $script:logRoot = Join-Path -Path $TestDrive -ChildPath ('logs-' + [guid]::NewGuid().ToString('N'))
        New-MinimalConfig -CredsFile $script:credsPath -Path $script:configPath
    }

    It 'resolves the creds path from config.json when -Path is omitted' {
        # Mock Read-Host so the test never blocks on interactive input.
        # Pester 5's Mock parameter filter cannot distinguish -AsSecureString
        # easily, so we cover both prompts with one mock that returns the
        # right type based on the bound parameters.
        Mock -CommandName Read-Host -MockWith {
            param($Prompt, [switch]$AsSecureString)
            if ($AsSecureString) {
                return (New-TestSecureString -Plain 'config-resolved-pw')
            }
            return 'fmsadmin'
        }

        Invoke-EncryptCreds -ConfigPath $script:configPath -LogRoot $script:logRoot

        Test-Path -LiteralPath $script:credsPath | Should -BeTrue
        $readBack = Import-Clixml -Path $script:credsPath
        $readBack.UserName | Should -Be 'fmsadmin'
        (Get-SecureStringPlaintext -Secure $readBack.Password) | Should -Be 'config-resolved-pw'
    }

    It 'never writes the password to the chrysalis log file' {
        $sentinel = 'P@ssw0rd-Sentinel-Never-Log-This-x9z'
        Mock -CommandName Read-Host -MockWith {
            param($Prompt, [switch]$AsSecureString)
            if ($AsSecureString) {
                return (New-TestSecureString -Plain $sentinel)
            }
            return 'fmsadmin'
        }

        # Inject a sandboxed log root under $TestDrive so the sentinel scan
        # only ever inspects logs this test produced. No reliance on the
        # working directory, no time-window race against concurrent runs,
        # and no writes to the real ./logs/ directory.
        Invoke-EncryptCreds -Path $script:credsPath -ConfigPath $script:configPath -LogRoot $script:logRoot

        Test-Path -LiteralPath $script:logRoot | Should -BeTrue
        $newLogs = Get-ChildItem -LiteralPath $script:logRoot -Filter 'chrysalis-*.log' -ErrorAction Stop
        $newLogs | Should -Not -BeNullOrEmpty
        foreach ($log in $newLogs) {
            $content = Get-Content -LiteralPath $log.FullName -Raw
            $content | Should -Not -Match ([regex]::Escape($sentinel))
        }
    }

    It 'refuses to overwrite an existing creds file when -Force is omitted, even when path comes from config' {
        Set-Content -LiteralPath $script:credsPath -Value 'placeholder'
        Mock -CommandName Read-Host -MockWith {
            param($Prompt, [switch]$AsSecureString)
            if ($AsSecureString) {
                return (New-TestSecureString -Plain 'irrelevant')
            }
            return 'fmsadmin'
        }

        { Invoke-EncryptCreds -ConfigPath $script:configPath -LogRoot $script:logRoot } |
            Should -Throw -ExpectedMessage "*creds file already exists*-Force*"
    }
}

Describe 'EncryptCreds - Read-ChrysalisCredentialsInternal' -Skip:(-not (Test-IsWindowsHost)) {

    # Read-ChrysalisCredentialsInternal is a script-scoped helper inside
    # EncryptCreds.ps1; it is not a public function. These tests reach it via
    # dot-source scope (Pester's BeforeAll dot-sources EncryptCreds.ps1). The
    # public-facing read path lands in PR #3 pre-flight 2d (SDD section 6.1).

    It 'throws a clear error when the creds file is missing' {
        $missing = Join-Path -Path $TestDrive -ChildPath 'no-such-creds.xml'
        { Read-ChrysalisCredentialsInternal -Path $missing } |
            Should -Throw -ExpectedMessage "*creds file*not found*EncryptCreds.ps1*"
    }

    It 'throws a clear error when the creds file is corrupt' {
        $corrupt = Join-Path -Path $TestDrive -ChildPath 'corrupt-creds.xml'
        Set-Content -LiteralPath $corrupt -Value 'this is not a valid clixml document'
        { Read-ChrysalisCredentialsInternal -Path $corrupt } |
            Should -Throw -ExpectedMessage "*cannot decrypt creds file*"
    }
}
