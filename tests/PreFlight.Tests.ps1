# PreFlight.Tests.ps1
# Pester 5.x coverage for src/lib/PreFlight.ps1. The seven SDD 6.1 step 2
# checks, the coordinator, the predicate, and the reporter. Mocks the
# heavy/Windows-y dependencies (Get-FmsVersion, Read-ChrysalisCredentials,
# [System.IO.DriveInfo], Get-ChildItem) so the bulk of the suite runs on
# any platform. Filesystem-dependent tests inject paths under $TestDrive.

# Test-IsWindowsHost is kept at file top-level (not inside BeforeAll) as
# documentation of the Pester 5 Discovery-time gotcha that bit PR #3a.
# No Describe in this file is currently Windows-gated because all heavy
# dependencies are mocked, but the pattern is preserved for any future
# Windows-only addition to this test file.
function Test-IsWindowsHost {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

BeforeAll {
    $script:RepoRoot = Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'src/lib/Logging.ps1')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'src/lib/Config.ps1')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'src/lib/EncryptCreds.ps1')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'src/lib/VersionDetection.ps1')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'src/lib/PreFlight.ps1')

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

    function New-TestConfig {
        param(
            [string] $InstallRoot,
            [string] $BackupRoot,
            [string] $CredsFile,
            [string] $TargetVersion = '21.0.3',
            [string[]] $InstallerKeys = @('21.0.3'),
            [int] $MaxBackupAgeHours = 24
        )
        $installersHash = [ordered]@{}
        foreach ($key in $InstallerKeys) {
            $installersHash[$key] = [pscustomobject]@{
                windows = "https://example.invalid/installers/fms_$key.exe"
                macos   = "https://example.invalid/installers/fms_$key.pkg"
                linux   = "https://example.invalid/installers/fms_$key.rpm"
                sha256  = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
            }
        }
        $installers = [pscustomobject] $installersHash
        return [pscustomobject]@{
            target_version       = $TargetVersion
            upgrade_mode         = 'in_place'
            installers           = $installers
            fms                  = [pscustomobject]@{
                install_root_windows = $InstallRoot
                admin_port           = 16001
                creds_file           = $CredsFile
            }
            backup_root          = $BackupRoot
            max_backup_age_hours = $MaxBackupAgeHours
            shutdown_sequence    = @('SERVER')
            startup_sequence     = @('SERVER')
        }
    }
}

Describe 'New-PreFlightResult' {

    It 'returns a PSCustomObject with the expected fields and defaults' {
        $r = New-PreFlightResult -CheckId '2x' -Name 'Demo' -Status 'Pass'
        $r.CheckId     | Should -Be '2x'
        $r.Name        | Should -Be 'Demo'
        $r.Status      | Should -Be 'Pass'
        $r.Detail      | Should -Be ''
        $r.Remediation | Should -Be ''
        $r.Data        | Should -BeNullOrEmpty
    }

    It 'rejects an invalid Status value' {
        { New-PreFlightResult -CheckId '2x' -Name 'Demo' -Status 'Bogus' } |
            Should -Throw
    }

    It 'passes Data through unchanged' {
        $r = New-PreFlightResult -CheckId '2a' -Name 'demo' -Status 'Pass' -Data '21.0.3'
        $r.Data | Should -Be '21.0.3'
    }
}

Describe 'Invoke-PreFlightCheck2a' {

    BeforeEach {
        $script:cfg = New-TestConfig -InstallRoot 'X:\fms' -BackupRoot 'Y:\backups' -CredsFile 'X:\creds.xml'
        $script:cred = New-TestCredential
    }

    It 'returns Pass with the detected version in Data when Get-FmsVersion succeeds' {
        Mock -CommandName Get-FmsVersion -MockWith { return '21.0.3' }
        $r = Invoke-PreFlightCheck2a -Config $script:cfg -Credential $script:cred
        $r.Status | Should -Be 'Pass'
        $r.Detail | Should -Match 'Detected version 21.0.3'
        $r.Data   | Should -Be '21.0.3'
    }

    It 'returns Fail with both inner messages joined when AggregateException is thrown' {
        Mock -CommandName Get-FmsVersion -MockWith {
            $inner1 = New-Object System.Exception('binary boom')
            $inner2 = New-Object System.Exception('admin api boom')
            throw (New-Object System.AggregateException('chrysalis: both version-detection paths failed.', @($inner1, $inner2)))
        }
        $r = Invoke-PreFlightCheck2a -Config $script:cfg -Credential $script:cred
        $r.Status      | Should -Be 'Fail'
        $r.Detail      | Should -Match 'Could not detect FMS version'
        $r.Remediation | Should -Match 'binary boom'
        $r.Remediation | Should -Match 'admin api boom'
        $r.Remediation | Should -Match 'install_root_windows'
    }

    It 'returns Fail with the raw message when a non-aggregate exception is thrown (no credential path)' {
        Mock -CommandName Get-FmsVersion -MockWith {
            throw "chrysalis: binary version detection failed and no -Credential was supplied for the Admin API fallback."
        }
        $r = Invoke-PreFlightCheck2a -Config $script:cfg
        $r.Status      | Should -Be 'Fail'
        $r.Detail      | Should -Match 'Could not detect FMS version'
        $r.Remediation | Should -Match 'no -Credential was supplied'
    }
}

Describe 'Invoke-PreFlightCheck2b' {

    BeforeEach {
        $script:cfg = New-TestConfig -InstallRoot 'X:\fms' -BackupRoot 'Y:\backups' -CredsFile 'X:\creds.xml' `
            -TargetVersion '21.0.4' -InstallerKeys @('21.0.3', '21.0.4')
    }

    It 'returns Skip when CurrentVersion is missing (2a failed)' {
        $r = Invoke-PreFlightCheck2b -Config $script:cfg -CurrentVersion ''
        $r.Status | Should -Be 'Skip'
        $r.Detail | Should -Match 'Skipped because 2a failed'
    }

    It 'returns Pass when the installers map has the current version' {
        $r = Invoke-PreFlightCheck2b -Config $script:cfg -CurrentVersion '21.0.3'
        $r.Status | Should -Be 'Pass'
        $r.Detail | Should -Match "Current version '21\.0\.3' has installer entry"
    }

    It 'returns Fail with rollback remediation when current version is missing from installers' {
        $r = Invoke-PreFlightCheck2b -Config $script:cfg -CurrentVersion '20.3.1'
        $r.Status      | Should -Be 'Fail'
        $r.Detail      | Should -Match "No installer entry for current version '20\.3\.1'"
        $r.Remediation | Should -Match "installers\.20\.3\.1"
        $r.Remediation | Should -Match 'rollback'
    }
}

Describe 'Invoke-PreFlightCheck2c' {

    It 'returns Pass when installers contains target_version' {
        $cfg = New-TestConfig -InstallRoot 'X:\fms' -BackupRoot 'Y:\backups' -CredsFile 'X:\creds.xml' `
            -TargetVersion '21.0.3' -InstallerKeys @('21.0.3')
        $r = Invoke-PreFlightCheck2c -Config $cfg
        $r.Status | Should -Be 'Pass'
        $r.Detail | Should -Match "Target version '21\.0\.3' has installer entry"
    }

    It 'returns Fail with a file-a-bug remediation when target_version is unmapped' {
        # The parser would normally catch this. We synthesize the mismatch
        # directly to confirm the pre-flight fallback message is correct.
        $cfg = New-TestConfig -InstallRoot 'X:\fms' -BackupRoot 'Y:\backups' -CredsFile 'X:\creds.xml' `
            -TargetVersion '21.0.4' -InstallerKeys @('21.0.4')
        # Strip the target_version's installer entry to simulate the impossible.
        $cfg.installers = [pscustomobject]@{}
        $r = Invoke-PreFlightCheck2c -Config $cfg
        $r.Status      | Should -Be 'Fail'
        $r.Detail      | Should -Match "target_version '21\.0\.4' has no matching installers entry"
        $r.Remediation | Should -Match 'file a bug'
    }
}

Describe 'Invoke-PreFlightCheck2d' {

    BeforeEach {
        # Real on-disk creds file under $TestDrive so the new Test-Path
        # pre-check in Invoke-PreFlightCheck2d sees the file as present.
        # The "file not found" test points at a sibling path that does NOT
        # exist; it must not rely on Read-ChrysalisCredentials throwing.
        $script:credsFile = Join-Path -Path $TestDrive -ChildPath ('creds-' + [guid]::NewGuid().ToString('N') + '.xml')
        Set-Content -LiteralPath $script:credsFile -Value '<creds/>' -Force
        $script:missingCredsFile = Join-Path -Path $TestDrive -ChildPath ('missing-creds-' + [guid]::NewGuid().ToString('N') + '.xml')
        $script:cfg = New-TestConfig -InstallRoot 'X:\fms' -BackupRoot 'Y:\backups' -CredsFile $script:credsFile
    }

    It 'returns Pass with the username (and never the password) when decrypt succeeds' {
        Mock -CommandName Read-ChrysalisCredentials -MockWith {
            return (New-TestCredential -User 'fmsadmin' -Pass 'SENTINEL-SECRET')
        }
        $r = Invoke-PreFlightCheck2d -Config $script:cfg
        $r.Status | Should -Be 'Pass'
        $r.Detail | Should -Match "Admin credentials decrypted from '"
        $r.Detail | Should -Match "\(user 'fmsadmin'\)"
        # The Pass Detail now includes the creds file path. Assert it.
        $escapedPath = [regex]::Escape($script:credsFile)
        $r.Detail | Should -Match $escapedPath
        # Belt-and-braces: assert the sentinel password is NOT in the result.
        $r.Detail      | Should -Not -Match 'SENTINEL-SECRET'
        $r.Remediation | Should -Not -Match 'SENTINEL-SECRET'
    }

    It 'returns Fail with file-not-found remediation when creds file is missing' {
        # No Read-ChrysalisCredentials mock: the Test-Path pre-check
        # short-circuits before the function is ever called.
        $cfg = New-TestConfig -InstallRoot 'X:\fms' -BackupRoot 'Y:\backups' -CredsFile $script:missingCredsFile
        $r = Invoke-PreFlightCheck2d -Config $cfg
        $r.Status      | Should -Be 'Fail'
        $escapedMissing = [regex]::Escape($script:missingCredsFile)
        $r.Detail      | Should -Match ("Admin credentials file not found at '" + $escapedMissing + "'")
        $r.Remediation | Should -Match 'EncryptCreds\.ps1'
        $r.Remediation | Should -Match 'credentials\.md'
    }

    It 'returns Fail with decrypt remediation when DPAPI decrypt fails' {
        Mock -CommandName Read-ChrysalisCredentials -MockWith {
            throw "chrysalis: cannot decrypt creds file: bad data."
        }
        $r = Invoke-PreFlightCheck2d -Config $script:cfg
        $r.Status      | Should -Be 'Fail'
        $escapedPath = [regex]::Escape($script:credsFile)
        $r.Detail      | Should -Match ("Cannot decrypt credentials at '" + $escapedPath + "'")
        $r.Remediation | Should -Match 'DPAPI'
        $r.Remediation | Should -Match 'EncryptCreds\.ps1'
    }
}

Describe 'Invoke-PreFlightCheck2f' {

    BeforeEach {
        $script:installRoot = Join-Path -Path $TestDrive -ChildPath 'preflight2f-install'
        $script:backupRoot  = Join-Path -Path $TestDrive -ChildPath 'preflight2f-backup'
        New-Item -ItemType Directory -Path $script:installRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $script:backupRoot -Force | Out-Null
        $script:cfg = New-TestConfig -InstallRoot $script:installRoot -BackupRoot $script:backupRoot -CredsFile 'X:\creds.xml'
    }

    It 'returns Pass when both drives have at least 5 GiB free' {
        # Mock the helpers exposed by PreFlight.ps1 to keep the assertion
        # platform-agnostic. Real-disk reads are exercised manually.
        Mock -CommandName Get-PreFlightDriveFreeGb -MockWith { return 100 }
        Mock -CommandName Get-PreFlightDriveRoot -MockWith {
            param($Path)
            return ([System.IO.Path]::GetPathRoot($Path)).TrimEnd('\','/')
        }
        $r = Invoke-PreFlightCheck2f -Config $script:cfg
        $r.Status | Should -Be 'Pass'
        $r.Detail | Should -Match 'has 100 GiB free'
    }

    It 'returns Fail naming the install root drive when it is below threshold' {
        Mock -CommandName Get-PreFlightDriveFreeGb -MockWith {
            param($Path)
            if ($Path -eq $script:installRoot) { return 1 }
            return 50
        }
        Mock -CommandName Get-PreFlightDriveRoot -MockWith { return 'X:' } -ParameterFilter { $Path -eq $script:installRoot }
        Mock -CommandName Get-PreFlightDriveRoot -MockWith { return 'Y:' } -ParameterFilter { $Path -eq $script:backupRoot }
        $r = Invoke-PreFlightCheck2f -Config $script:cfg
        $r.Status      | Should -Be 'Fail'
        $r.Detail      | Should -Match "install root drive 'X:'"
        $r.Detail      | Should -Match '1 GiB free'
        $r.Remediation | Should -Match '5 GiB'
    }

    It 'returns Fail naming the backup root drive when it is below threshold' {
        Mock -CommandName Get-PreFlightDriveFreeGb -MockWith {
            param($Path)
            if ($Path -eq $script:backupRoot) { return 2 }
            return 50
        }
        Mock -CommandName Get-PreFlightDriveRoot -MockWith { return 'X:' } -ParameterFilter { $Path -eq $script:installRoot }
        Mock -CommandName Get-PreFlightDriveRoot -MockWith { return 'Y:' } -ParameterFilter { $Path -eq $script:backupRoot }
        $r = Invoke-PreFlightCheck2f -Config $script:cfg
        $r.Status | Should -Be 'Fail'
        $r.Detail | Should -Match "backup root drive 'Y:'"
        $r.Detail | Should -Match '2 GiB free'
    }

    It 'returns Fail when the free-space lookup itself throws' {
        Mock -CommandName Get-PreFlightDriveFreeGb -MockWith { throw 'lookup boom' }
        Mock -CommandName Get-PreFlightDriveRoot -MockWith { return 'X:' }
        $r = Invoke-PreFlightCheck2f -Config $script:cfg
        $r.Status      | Should -Be 'Fail'
        $r.Detail      | Should -Match 'Could not read free space'
        $r.Remediation | Should -Match 'config\.json'
    }
}

Describe 'Invoke-PreFlightCheck2e' {

    BeforeEach {
        $script:installRoot = Join-Path -Path $TestDrive -ChildPath ('preflight2e-' + [guid]::NewGuid().ToString('N'))
        $script:databaseServer = Join-Path -Path $script:installRoot -ChildPath 'Database Server'
        New-Item -ItemType Directory -Path $script:databaseServer -Force | Out-Null
        $script:cfg = New-TestConfig -InstallRoot $script:installRoot `
            -BackupRoot (Join-Path -Path $TestDrive -ChildPath 'unused-backup') `
            -CredsFile 'X:\creds.xml'
    }

    It 'returns Skip when install root is unreachable per 2a' {
        $r = Invoke-PreFlightCheck2e -Config $script:cfg -InstallRootReachable $false
        $r.Status | Should -Be 'Skip'
        $r.Detail | Should -Match '2a'
    }

    It 'returns Fail when Database Server directory does not exist' {
        $cfg = New-TestConfig -InstallRoot (Join-Path -Path $TestDrive -ChildPath 'no-such-root') `
            -BackupRoot (Join-Path -Path $TestDrive -ChildPath 'unused-backup') `
            -CredsFile 'X:\creds.xml'
        $r = Invoke-PreFlightCheck2e -Config $cfg -InstallRootReachable $true
        $r.Status      | Should -Be 'Fail'
        $r.Detail      | Should -Match 'No \.fmcert license file found'
        $r.Remediation | Should -Match 'FMS admin console'
    }

    It 'returns Fail with zero-found message when no .fmcert is present' {
        $r = Invoke-PreFlightCheck2e -Config $script:cfg -InstallRootReachable $true
        $r.Status      | Should -Be 'Fail'
        $r.Detail      | Should -Match 'No \.fmcert license file found'
    }

    It 'returns Fail with zero-byte message when the .fmcert is empty' {
        $emptyLicense = Join-Path -Path $script:databaseServer -ChildPath 'License.fmcert'
        Set-Content -LiteralPath $emptyLicense -Value $null -Force
        $r = Invoke-PreFlightCheck2e -Config $script:cfg -InstallRootReachable $true
        $r.Status      | Should -Be 'Fail'
        $r.Detail      | Should -Match 'zero bytes'
        $r.Remediation | Should -Match 'empty'
    }

    It 'returns Fail with a multiple-files message when more than one .fmcert is found' {
        $a = Join-Path -Path $script:databaseServer -ChildPath 'Old.fmcert'
        $b = Join-Path -Path $script:databaseServer -ChildPath 'New.fmcert'
        Set-Content -LiteralPath $a -Value 'old license content'
        Set-Content -LiteralPath $b -Value 'new license content'
        $r = Invoke-PreFlightCheck2e -Config $script:cfg -InstallRootReachable $true
        $r.Status      | Should -Be 'Fail'
        $r.Detail      | Should -Match 'Found 2 license files'
        $r.Remediation | Should -Match 'stale ones'
    }

    It 'returns Pass with file size when exactly one non-zero .fmcert is found' {
        $license = Join-Path -Path $script:databaseServer -ChildPath 'License.fmcert'
        Set-Content -LiteralPath $license -Value 'fake license content'
        $r = Invoke-PreFlightCheck2e -Config $script:cfg -InstallRootReachable $true
        $r.Status | Should -Be 'Pass'
        $r.Detail | Should -Match 'License\.fmcert'
        $r.Detail | Should -Match 'bytes'
        $r.Data   | Should -Match 'License\.fmcert'
    }
}

Describe 'Invoke-PreFlightCheck2g' {

    BeforeEach {
        $script:backupRoot = Join-Path -Path $TestDrive -ChildPath ('preflight2g-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:backupRoot -Force | Out-Null
        $script:cfg = New-TestConfig -InstallRoot 'X:\fms' -BackupRoot $script:backupRoot -CredsFile 'X:\creds.xml' `
            -MaxBackupAgeHours 24
    }

    It 'returns Fail when backup_root does not exist' {
        $cfg = New-TestConfig -InstallRoot 'X:\fms' -BackupRoot (Join-Path -Path $TestDrive -ChildPath 'no-such-backup') `
            -CredsFile 'X:\creds.xml'
        $r = Invoke-PreFlightCheck2g -Config $cfg
        $r.Status      | Should -Be 'Fail'
        $r.Detail      | Should -Match 'does not exist'
        $r.Remediation | Should -Match 'backup_root'
    }

    It 'returns Fail when no .fmp12 files exist in backup_root' {
        $r = Invoke-PreFlightCheck2g -Config $script:cfg
        $r.Status      | Should -Be 'Fail'
        $r.Detail      | Should -Match 'No FMS database backup newer than 24h'
        $r.Remediation | Should -Match 'fmsadmin backup'
    }

    It 'returns Fail when all .fmp12 files are older than max_backup_age_hours' {
        $stale = Join-Path -Path $script:backupRoot -ChildPath 'old-backup.fmp12'
        Set-Content -LiteralPath $stale -Value 'stale db'
        (Get-Item -LiteralPath $stale).LastWriteTime = (Get-Date).AddHours(-48)
        $r = Invoke-PreFlightCheck2g -Config $script:cfg
        $r.Status | Should -Be 'Fail'
        $r.Detail | Should -Match 'No FMS database backup newer than 24h'
    }

    It 'returns Pass when at least one recent .fmp12 exists' {
        $fresh = Join-Path -Path $script:backupRoot -ChildPath 'fresh.fmp12'
        Set-Content -LiteralPath $fresh -Value 'fresh db'
        # Default LastWriteTime is "now", so it is well within 24h.
        $r = Invoke-PreFlightCheck2g -Config $script:cfg
        $r.Status | Should -Be 'Pass'
        $r.Detail | Should -Match 'Found 1 recent backup file'
        $r.Detail | Should -Match 'newest is'
    }

    It 'finds .fmp12 files in immediate subdirectories of backup_root' {
        $sub = Join-Path -Path $script:backupRoot -ChildPath 'daily'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        $nested = Join-Path -Path $sub -ChildPath 'sub-fresh.fmp12'
        Set-Content -LiteralPath $nested -Value 'nested db'
        $r = Invoke-PreFlightCheck2g -Config $script:cfg
        $r.Status | Should -Be 'Pass'
        $r.Detail | Should -Match 'recent backup file'
    }
}

Describe 'Invoke-PreFlight (coordinator)' {

    BeforeEach {
        $script:installRoot = Join-Path -Path $TestDrive -ChildPath ('coord-install-' + [guid]::NewGuid().ToString('N'))
        $script:backupRoot  = Join-Path -Path $TestDrive -ChildPath ('coord-backup-'  + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path -Path $script:installRoot -ChildPath 'Database Server') -Force | Out-Null
        New-Item -ItemType Directory -Path $script:backupRoot -Force | Out-Null

        $license = Join-Path -Path (Join-Path -Path $script:installRoot -ChildPath 'Database Server') -ChildPath 'License.fmcert'
        Set-Content -LiteralPath $license -Value 'fake license'
        $fresh = Join-Path -Path $script:backupRoot -ChildPath 'fresh.fmp12'
        Set-Content -LiteralPath $fresh -Value 'fresh db'

        # Real on-disk creds file so 2d's Test-Path pre-check passes.
        $script:credsFile = Join-Path -Path $TestDrive -ChildPath ('coord-creds-' + [guid]::NewGuid().ToString('N') + '.xml')
        Set-Content -LiteralPath $script:credsFile -Value '<creds/>' -Force

        $script:cfg = New-TestConfig -InstallRoot $script:installRoot -BackupRoot $script:backupRoot `
            -CredsFile $script:credsFile -TargetVersion '21.0.4' -InstallerKeys @('21.0.3', '21.0.4')
        $script:cred = New-TestCredential

        Mock -CommandName Get-FmsVersion -MockWith { return '21.0.3' }
        Mock -CommandName Read-ChrysalisCredentials -MockWith {
            return (New-TestCredential -User 'fmsadmin' -Pass 'unused')
        }
        Mock -CommandName Get-PreFlightDriveFreeGb -MockWith { return 100 }
        Mock -CommandName Get-PreFlightDriveRoot -MockWith { return 'T:' }
    }

    It 'returns seven results, all Pass on a healthy mocked system' {
        $results = Invoke-PreFlight -Config $script:cfg -Credential $script:cred
        $results.Count | Should -Be 7
        ($results | Where-Object { $_.Status -eq 'Fail' }).Count | Should -Be 0
        ($results | Where-Object { $_.Status -eq 'Pass' }).Count | Should -Be 7
    }

    It 'emits results in the Ripley order 2a, 2b, 2c, 2d, 2f, 2e, 2g' {
        $results = Invoke-PreFlight -Config $script:cfg -Credential $script:cred
        $ids = $results | ForEach-Object { $_.CheckId }
        ($ids -join ',') | Should -Be '2a,2b,2c,2d,2f,2e,2g'
    }

    It 'marks 2b and 2e as Skip when 2a fails, but still runs the other independent checks' {
        Mock -CommandName Get-FmsVersion -MockWith {
            $inner1 = New-Object System.Exception('binary boom')
            $inner2 = New-Object System.Exception('admin api boom')
            throw (New-Object System.AggregateException('both paths failed', @($inner1, $inner2)))
        }
        $results = Invoke-PreFlight -Config $script:cfg -Credential $script:cred
        $r2a = $results | Where-Object { $_.CheckId -eq '2a' } | Select-Object -First 1
        $r2b = $results | Where-Object { $_.CheckId -eq '2b' } | Select-Object -First 1
        $r2c = $results | Where-Object { $_.CheckId -eq '2c' } | Select-Object -First 1
        $r2d = $results | Where-Object { $_.CheckId -eq '2d' } | Select-Object -First 1
        $r2e = $results | Where-Object { $_.CheckId -eq '2e' } | Select-Object -First 1
        $r2f = $results | Where-Object { $_.CheckId -eq '2f' } | Select-Object -First 1
        $r2g = $results | Where-Object { $_.CheckId -eq '2g' } | Select-Object -First 1

        $r2a.Status | Should -Be 'Fail'
        $r2b.Status | Should -Be 'Skip'
        $r2c.Status | Should -Be 'Pass'
        $r2d.Status | Should -Be 'Pass'
        $r2e.Status | Should -Be 'Skip'
        $r2f.Status | Should -Be 'Pass'
        $r2g.Status | Should -Be 'Pass'
    }

    It 'turns an unexpected exception from a check into a Fail result without aborting later checks' {
        Mock -CommandName Invoke-PreFlightCheck2d -MockWith { throw 'unexpected 2d boom' }
        $results = Invoke-PreFlight -Config $script:cfg -Credential $script:cred
        $r2d = $results | Where-Object { $_.CheckId -eq '2d' } | Select-Object -First 1
        $r2d.Status      | Should -Be 'Fail'
        $r2d.Detail      | Should -Match "Unexpected error during pre-flight check '2d'"
        $r2d.Remediation | Should -Match 'unexpected 2d boom'
        # Later checks (2f, 2e, 2g) still ran and produced Pass results.
        ($results | Where-Object { $_.CheckId -in @('2f','2e','2g') -and $_.Status -eq 'Pass' }).Count | Should -Be 3
    }

    It 'turns a null return from a check into a Fail result' {
        Mock -CommandName Invoke-PreFlightCheck2c -MockWith { return $null }
        $results = Invoke-PreFlight -Config $script:cfg -Credential $script:cred
        $r2c = $results | Where-Object { $_.CheckId -eq '2c' } | Select-Object -First 1
        $r2c.Status      | Should -Be 'Fail'
        $r2c.Detail      | Should -Match "Check '2c' returned no result"
        $r2c.Remediation | Should -Match 'File a bug'
    }
}

Describe 'Test-PreFlightPassed' {

    It 'returns $true when every result is Pass' {
        $results = @(
            (New-PreFlightResult -CheckId '2a' -Name 'a' -Status 'Pass'),
            (New-PreFlightResult -CheckId '2b' -Name 'b' -Status 'Pass')
        )
        Test-PreFlightPassed -Results $results | Should -BeTrue
    }

    It 'returns $true when results contain Pass and Skip but no Fail' {
        $results = @(
            (New-PreFlightResult -CheckId '2a' -Name 'a' -Status 'Pass'),
            (New-PreFlightResult -CheckId '2b' -Name 'b' -Status 'Skip')
        )
        Test-PreFlightPassed -Results $results | Should -BeTrue
    }

    It 'returns $false when any result is Fail' {
        $results = @(
            (New-PreFlightResult -CheckId '2a' -Name 'a' -Status 'Pass'),
            (New-PreFlightResult -CheckId '2b' -Name 'b' -Status 'Fail' -Remediation 'fix it')
        )
        Test-PreFlightPassed -Results $results | Should -BeFalse
    }
}

Describe 'Write-PreFlightReport' {

    BeforeEach {
        $script:logRoot = Join-Path -Path $TestDrive -ChildPath ('preflight-log-' + [guid]::NewGuid().ToString('N'))
        $script:ctx = New-LogContext -LogRoot $script:logRoot -RunId 'pflog'
    }

    AfterEach {
        if ($script:ctx -and -not $script:ctx.Closed) {
            Close-LogContext -Context $script:ctx
        }
    }

    It 'logs an Info line per Pass, a Warn line per Skip, and an Error + Remediation per Fail' {
        $results = @(
            (New-PreFlightResult -CheckId '2a' -Name 'Detect version'   -Status 'Pass' -Detail 'Detected 21.0.3'),
            (New-PreFlightResult -CheckId '2b' -Name 'Current installer' -Status 'Skip' -Detail 'Skipped because 2a failed.'),
            (New-PreFlightResult -CheckId '2d' -Name 'Decrypt creds'    -Status 'Fail' -Detail 'Cannot decrypt creds' -Remediation 'Re-run EncryptCreds.ps1.')
        )
        Write-PreFlightReport -Results $results -LogContext $script:ctx
        Close-LogContext -Context $script:ctx

        $content = Get-Content -LiteralPath $script:ctx.LogPath -Raw
        $content | Should -Match '\[INFO\].*2a Pass Detect version.*Detected 21\.0\.3'
        $content | Should -Match '\[WARN\].*2b Skip Current installer.*Skipped because 2a failed'
        $content | Should -Match '\[ERROR\].*2d Fail Decrypt creds.*Cannot decrypt creds'
        $content | Should -Match '\[REMEDIATION\].*Re-run EncryptCreds\.ps1'
    }

    It 'writes a summary line with total/passed/skipped/failed counts' {
        $results = @(
            (New-PreFlightResult -CheckId '2a' -Name 'a' -Status 'Pass'),
            (New-PreFlightResult -CheckId '2b' -Name 'b' -Status 'Pass'),
            (New-PreFlightResult -CheckId '2c' -Name 'c' -Status 'Skip'),
            (New-PreFlightResult -CheckId '2d' -Name 'd' -Status 'Fail' -Remediation 'fix'),
            (New-PreFlightResult -CheckId '2e' -Name 'e' -Status 'Fail' -Remediation 'fix'),
            (New-PreFlightResult -CheckId '2f' -Name 'f' -Status 'Pass'),
            (New-PreFlightResult -CheckId '2g' -Name 'g' -Status 'Pass')
        )
        Write-PreFlightReport -Results $results -LogContext $script:ctx
        Close-LogContext -Context $script:ctx

        $content = Get-Content -LiteralPath $script:ctx.LogPath -Raw
        $content | Should -Match 'Pre-flight summary: total=7 passed=4 skipped=1 failed=2\.'
        $content | Should -Match 'Pre-flight failed 2 of 7 checks'
    }

    It 'omits the final remediation line when no checks failed' {
        $results = @(
            (New-PreFlightResult -CheckId '2a' -Name 'a' -Status 'Pass'),
            (New-PreFlightResult -CheckId '2b' -Name 'b' -Status 'Skip')
        )
        Write-PreFlightReport -Results $results -LogContext $script:ctx
        Close-LogContext -Context $script:ctx

        $content = Get-Content -LiteralPath $script:ctx.LogPath -Raw
        $content | Should -Not -Match 'Pre-flight failed'
    }
}
