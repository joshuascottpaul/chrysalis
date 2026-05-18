# sudofmsadmin.Tests.ps1
# Pester 5.x coverage for src/lib/sudofmsadmin.ps1.
#
# Elevation behavior is exercised manually on the test FMS host per SDD §14
# Phase 1 deliverable. CI covers arg parsing, fmsadmin resolution, and
# exit-code propagation only.

BeforeAll {
    $script:RepoRoot = Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'src/lib/Logging.ps1')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'src/lib/Config.ps1')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'src/lib/sudofmsadmin.ps1')

    function New-MinimalConfigForSudo {
        param(
            [string] $InstallRoot,
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
                install_root_windows = $InstallRoot
                admin_port           = 16001
                creds_file           = (Join-Path -Path $TestDrive -ChildPath 'creds.xml')
            }
            backup_root      = 'C:\FMS_Backups'
            shutdown_sequence = @('SERVER')
            startup_sequence  = @('SERVER')
        }
        ($cfg | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding UTF8
    }

    function New-StubFmsadmin {
        param([string] $Path)
        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        # Contents do not matter - Resolve-FmsadminPath only checks Test-Path.
        Set-Content -LiteralPath $Path -Value '<stub fmsadmin executable for tests>'
    }
}

Describe 'Resolve-FmsadminPath' {

    It "prefers {install_root}\Database Server\fmsadmin.exe when present" {
        $installRoot = Join-Path -Path $TestDrive -ChildPath 'FileMaker Server'
        $expected = Join-Path -Path $installRoot -ChildPath 'Database Server\fmsadmin.exe'
        New-StubFmsadmin -Path $expected

        $configPath = Join-Path -Path $TestDrive -ChildPath 'config-dbserver.json'
        New-MinimalConfigForSudo -InstallRoot $installRoot -Path $configPath

        $resolved = Resolve-FmsadminPath -ConfigPath $configPath
        $resolved | Should -Be $expected
    }

    It 'falls back to {install_root}\fmsadmin.exe when Database Server variant is missing' {
        $installRoot = Join-Path -Path $TestDrive -ChildPath 'FileMaker Server Flat'
        $expected = Join-Path -Path $installRoot -ChildPath 'fmsadmin.exe'
        New-StubFmsadmin -Path $expected

        $configPath = Join-Path -Path $TestDrive -ChildPath 'config-flat.json'
        New-MinimalConfigForSudo -InstallRoot $installRoot -Path $configPath

        $resolved = Resolve-FmsadminPath -ConfigPath $configPath
        $resolved | Should -Be $expected
    }

    It 'falls back to PATH when no config-derived path exists' {
        $installRoot = Join-Path -Path $TestDrive -ChildPath 'NoFmsHere'
        New-Item -ItemType Directory -Path $installRoot -Force | Out-Null

        $configPath = Join-Path -Path $TestDrive -ChildPath 'config-nopath.json'
        New-MinimalConfigForSudo -InstallRoot $installRoot -Path $configPath

        # Stub Get-Command so PATH resolution returns a known value without
        # depending on whether the runner happens to have fmsadmin installed.
        $pathStub = Join-Path -Path $TestDrive -ChildPath 'PATH-fmsadmin.exe'
        New-StubFmsadmin -Path $pathStub
        Mock -CommandName Get-Command -MockWith {
            return [pscustomobject]@{ Source = $pathStub }
        } -ParameterFilter { $Name -eq 'fmsadmin' }

        $resolved = Resolve-FmsadminPath -ConfigPath $configPath
        $resolved | Should -Be $pathStub
    }

    It 'returns $null when neither config-derived path nor PATH locate fmsadmin' {
        $installRoot = Join-Path -Path $TestDrive -ChildPath 'NothingHere'
        New-Item -ItemType Directory -Path $installRoot -Force | Out-Null

        $configPath = Join-Path -Path $TestDrive -ChildPath 'config-none.json'
        New-MinimalConfigForSudo -InstallRoot $installRoot -Path $configPath

        Mock -CommandName Get-Command -MockWith { return $null } -ParameterFilter { $Name -eq 'fmsadmin' }

        $resolved = Resolve-FmsadminPath -ConfigPath $configPath
        $resolved | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-SudoFmsadmin - resolution failure' {

    It 'returns exit code 2 when fmsadmin cannot be located' {
        $installRoot = Join-Path -Path $TestDrive -ChildPath 'Empty'
        New-Item -ItemType Directory -Path $installRoot -Force | Out-Null

        $configPath = Join-Path -Path $TestDrive -ChildPath 'config-empty.json'
        New-MinimalConfigForSudo -InstallRoot $installRoot -Path $configPath

        Mock -CommandName Get-Command -MockWith { return $null } -ParameterFilter { $Name -eq 'fmsadmin' }

        # Inject a sandboxed log root so this test never writes to the real
        # ./logs/ directory.
        $logRoot = Join-Path -Path $TestDrive -ChildPath ('logs-' + [guid]::NewGuid().ToString('N'))
        $exit = Invoke-SudoFmsadmin -ConfigPath $configPath -Arguments @('list', 'files') -LogRoot $logRoot
        $exit | Should -Be 2
    }
}

Describe 'Invoke-SudoFmsadmin - invocation' {

    BeforeEach {
        $script:installRoot = Join-Path -Path $TestDrive -ChildPath ('FMS-' + [guid]::NewGuid().ToString('N'))
        $script:fmsadminPath = Join-Path -Path $script:installRoot -ChildPath 'Database Server\fmsadmin.exe'
        New-StubFmsadmin -Path $script:fmsadminPath

        $script:configPath = Join-Path -Path $TestDrive -ChildPath ('cfg-' + [guid]::NewGuid().ToString('N') + '.json')
        New-MinimalConfigForSudo -InstallRoot $script:installRoot -Path $script:configPath

        # Sandbox the log directory under $TestDrive so these tests never write
        # to the real ./logs/.
        $script:logRoot = Join-Path -Path $TestDrive -ChildPath ('logs-' + [guid]::NewGuid().ToString('N'))
    }

    It 'propagates the non-zero exit code returned by fmsadmin' {
        Mock -CommandName Invoke-Fmsadmin -MockWith { return 7 }

        $exit = Invoke-SudoFmsadmin -ConfigPath $script:configPath -Arguments @('list', 'files') -LogRoot $script:logRoot
        $exit | Should -Be 7
    }

    It 'propagates a zero exit code on success' {
        Mock -CommandName Invoke-Fmsadmin -MockWith { return 0 }

        $exit = Invoke-SudoFmsadmin -ConfigPath $script:configPath -Arguments @('status') -LogRoot $script:logRoot
        $exit | Should -Be 0
    }

    It 'passes the args array through verbatim to Invoke-Fmsadmin' {
        $script:capturedArgs = $null
        $script:capturedPath = $null
        Mock -CommandName Invoke-Fmsadmin -MockWith {
            param($FmsadminPath, $Arguments)
            $script:capturedPath = $FmsadminPath
            $script:capturedArgs = $Arguments
            return 0
        }

        $expectedArgs = @('disconnect', 'client', '-y', '-m', 'Upgrade in progress')
        $null = Invoke-SudoFmsadmin -ConfigPath $script:configPath -Arguments $expectedArgs -LogRoot $script:logRoot

        $script:capturedPath | Should -Be $script:fmsadminPath
        # Compare element-by-element to avoid PS 5.1 quirks around array equality.
        $script:capturedArgs.Count | Should -Be $expectedArgs.Count
        for ($i = 0; $i -lt $expectedArgs.Count; $i++) {
            $script:capturedArgs[$i] | Should -Be $expectedArgs[$i]
        }
    }
}
