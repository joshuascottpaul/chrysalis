# Chrysalis.Tests.ps1
# Pester 5.x coverage for the chrysalis.ps1 entry point.
#
# Strategy: most tests dot-source chrysalis.ps1 (which itself dot-sources the
# lib files) and exercise Invoke-ChrysalisDryRun directly with mocked
# dependencies. The strict-only refusal gate is a script-body guard that
# calls `exit 2`, so that one test spawns a child PowerShell process to
# capture the real exit code.
#
# All log output is routed to $TestDrive via -LogRoot; no test writes to the
# real ./logs/ directory.

# Test-IsWindowsHost is kept at file top-level (not inside BeforeAll) as
# documentation of the Pester 5 Discovery-time gotcha that bit PR #3a.
# No Describe in this file is currently Windows-gated because all
# Windows-specific dependencies (DPAPI, PE VersionInfo, real Admin API) are
# mocked, but the pattern is preserved for any future Windows-only addition.
function Test-IsWindowsHost {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

BeforeAll {
    $script:RepoRoot = Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')
    $script:EntryScript = Join-Path -Path $script:RepoRoot -ChildPath 'chrysalis.ps1'

    # Dot-source the entry point. Because $MyInvocation.InvocationName is '.'
    # under dot-sourcing, the auto-invocation guard at the bottom of
    # chrysalis.ps1 does not fire. The lib files are dot-sourced as a side
    # effect of dot-sourcing chrysalis.ps1, so Read-ChrysalisConfig,
    # Invoke-PreFlight, etc. are available for direct mocking.
    . $script:EntryScript

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

    function New-EntryTestConfig {
        # Produce a parsed config object shaped like Read-ChrysalisConfig's
        # output. Tests mock Read-ChrysalisConfig to return this object, so
        # the on-disk JSON content does not have to be byte-accurate - only
        # the existence of the file matters (Resolve-ChrysalisEntryConfigPath
        # checks Test-Path before reading).
        param(
            [string] $InstallRoot = 'C:\Program Files\FileMaker\FileMaker Server',
            [string] $BackupRoot = 'C:\FMS_Backups',
            [string] $CredsFile = 'C:\chrysalis\creds.xml',
            [string] $TargetVersion = '21.0.3',
            [string[]] $InstallerKeys = @('21.0.3'),
            [string] $UpgradeMode = 'in_place'
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
        $obj = [pscustomobject]@{
            target_version       = $TargetVersion
            installers           = [pscustomobject] $installersHash
            fms                  = [pscustomobject]@{
                install_root_windows = $InstallRoot
                admin_port           = 16001
                creds_file           = $CredsFile
            }
            backup_root          = $BackupRoot
            max_backup_age_hours = 24
            shutdown_sequence    = @('FMSTB', 'FMSE', 'SERVER')
            startup_sequence     = @('SERVER', 'FMSE', 'FMSTB')
        }
        if (-not [string]::IsNullOrWhiteSpace($UpgradeMode)) {
            Add-Member -InputObject $obj -MemberType NoteProperty -Name 'upgrade_mode' -Value $UpgradeMode
        }
        return $obj
    }

    function New-EntryConfigFile {
        # Materializes a placeholder config file on disk. The body does not
        # have to be valid JSON because Read-ChrysalisConfig is mocked in
        # every test; only Resolve-ChrysalisEntryConfigPath's Test-Path check
        # sees this file.
        param([string] $Path)
        Set-Content -LiteralPath $Path -Value '{"placeholder": true}' -Force
        return $Path
    }

    function New-PassResult {
        param([string] $Id, [string] $Name)
        return [pscustomobject]@{
            CheckId     = $Id
            Name        = $Name
            Status      = 'Pass'
            Detail      = "$Id passed"
            Remediation = ''
            Data        = $null
        }
    }

    function New-FailResult {
        param([string] $Id, [string] $Name, [string] $Detail, [string] $Remediation)
        return [pscustomobject]@{
            CheckId     = $Id
            Name        = $Name
            Status      = 'Fail'
            Detail      = $Detail
            Remediation = $Remediation
            Data        = $null
        }
    }
}

Describe 'chrysalis.ps1 strict-only entry gate' {

    It 'refuses without -DryRun and exits with code 2' {
        # Spawn a child pwsh so the script-body `exit 2` produces a real
        # process exit code we can capture. Dot-sourcing into the test
        # process would skip the auto-invocation guard.
        $stderrFile = Join-Path -Path $TestDrive -ChildPath ('refuse-stderr-' + [guid]::NewGuid().ToString('N') + '.txt')
        $stdoutFile = Join-Path -Path $TestDrive -ChildPath ('refuse-stdout-' + [guid]::NewGuid().ToString('N') + '.txt')

        # Pick the same PowerShell host that's running this test so PS 5.1
        # (powershell.exe) and PS 7+ (pwsh) both work. -WindowStyle Hidden is
        # omitted because it errors on non-Windows; the process is short and
        # invisible enough without it.
        $psHost = (Get-Process -Id $PID).Path
        $proc = Start-Process -FilePath $psHost `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $script:EntryScript) `
            -RedirectStandardError $stderrFile `
            -RedirectStandardOutput $stdoutFile `
            -PassThru -Wait

        $proc.ExitCode | Should -Be 2
        $stderr = Get-Content -LiteralPath $stderrFile -Raw
        $stderr | Should -Match 'Phase 1 only supports -DryRun mode'
        $stderr | Should -Match 'Phase 2'
    }
}

Describe 'Resolve-ChrysalisEntryConfigPath' {

    It 'returns the explicit path when it exists' {
        $cfgPath = Join-Path -Path $TestDrive -ChildPath 'explicit.json'
        New-EntryConfigFile -Path $cfgPath | Out-Null
        $actual = Resolve-ChrysalisEntryConfigPath -Explicit $cfgPath -ScriptRoot $TestDrive
        $actual | Should -Be $cfgPath
    }

    It 'throws naming config/config.example.json when -ConfigPath points at a missing file' {
        $missing = Join-Path -Path $TestDrive -ChildPath 'does-not-exist.json'
        { Resolve-ChrysalisEntryConfigPath -Explicit $missing -ScriptRoot $TestDrive } |
            Should -Throw -ExpectedMessage "*config file not found at '$missing'*config/config.example.json*"
    }

    It 'falls back to ./config.json when -Explicit is empty' {
        $scriptRoot = Join-Path -Path $TestDrive -ChildPath ('fallback-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $scriptRoot -Force | Out-Null
        $defaultPath = Join-Path -Path $scriptRoot -ChildPath 'config.json'
        New-EntryConfigFile -Path $defaultPath | Out-Null
        $actual = Resolve-ChrysalisEntryConfigPath -Explicit '' -ScriptRoot $scriptRoot
        $actual | Should -Be $defaultPath
    }

    It 'throws naming config/config.example.json when the default config.json is missing' {
        $scriptRoot = Join-Path -Path $TestDrive -ChildPath ('fallback-missing-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $scriptRoot -Force | Out-Null
        { Resolve-ChrysalisEntryConfigPath -Explicit '' -ScriptRoot $scriptRoot } |
            Should -Throw -ExpectedMessage '*no config file found*config/config.example.json*'
    }
}

Describe 'Invoke-ChrysalisDryRun happy path' {

    BeforeEach {
        $script:scriptRoot = Join-Path -Path $TestDrive -ChildPath ('happy-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:scriptRoot -Force | Out-Null
        $script:cfgPath = Join-Path -Path $script:scriptRoot -ChildPath 'config.json'
        New-EntryConfigFile -Path $script:cfgPath | Out-Null
        $script:logRoot = Join-Path -Path $TestDrive -ChildPath ('logs-happy-' + [guid]::NewGuid().ToString('N'))
        $script:testConfig = New-EntryTestConfig
    }

    It 'returns 0, logs the banner and planned steps, and reports pre-flight passed' {
        Mock -CommandName Read-ChrysalisConfig -MockWith { return $script:testConfig }
        Mock -CommandName Read-ChrysalisCredentials -MockWith {
            return (New-TestCredential -User 'fmsadmin' -Pass 'unit-test-pw')
        }
        Mock -CommandName Invoke-PreFlight -MockWith {
            return @(
                (New-PassResult -Id '2a' -Name 'Detect current installed FMS version'),
                (New-PassResult -Id '2b' -Name 'Config has installer entry for current version'),
                (New-PassResult -Id '2c' -Name 'Config has installer entry for target version'),
                (New-PassResult -Id '2d' -Name 'Verify admin credentials decrypt'),
                (New-PassResult -Id '2f' -Name 'Disk space for installer and backup'),
                (New-PassResult -Id '2e' -Name 'License file exists (Phase 1 scope)'),
                (New-PassResult -Id '2g' -Name 'Recent native FMS DB backup exists')
            )
        }

        $code = Invoke-ChrysalisDryRun -ConfigPath $script:cfgPath -LogRoot $script:logRoot -ScriptRoot $script:scriptRoot
        $code | Should -Be 0

        # Find the produced log file. New-LogContext stamps the name with the
        # start time and a random RunId; we only need the single .log file
        # under $script:logRoot.
        $logFile = (Get-ChildItem -LiteralPath $script:logRoot -Filter 'chrysalis-*.log' -File | Select-Object -First 1).FullName
        $logFile | Should -Not -BeNullOrEmpty
        $content = Get-Content -LiteralPath $logFile -Raw

        # Banner present.
        $content | Should -Match 'chrysalis DryRun starting'
        $content | Should -Match 'Phase 1 deliverable'
        $content | Should -Match 'no destructive operations are performed'

        # Config + creds reported.
        $content | Should -Match "Target version: 21.0.3"
        $content | Should -Match "Loaded admin credentials for user 'fmsadmin'"

        # Planned upgrade steps name the shutdown sequence and target version.
        $content | Should -Match 'Planned upgrade steps'
        $content | Should -Match 'FMSTB, FMSE, SERVER'
        $content | Should -Match 'target version 21.0.3'
        $content | Should -Match "in 'in_place' mode"
        $content | Should -Match 'SERVER, FMSE, FMSTB'
        $content | Should -Match 'fmsadmin list files'

        # Final summary names "pre-flight passed".
        $content | Should -Match 'DryRun complete: pre-flight passed'
        $content | Should -Match 'Phase 2'
    }

    It 'does not invoke any destructive operation in the happy path' {
        Mock -CommandName Read-ChrysalisConfig -MockWith { return $script:testConfig }
        Mock -CommandName Read-ChrysalisCredentials -MockWith {
            return (New-TestCredential -User 'fmsadmin' -Pass 'unit-test-pw')
        }
        Mock -CommandName Invoke-PreFlight -MockWith {
            return @((New-PassResult -Id '2a' -Name 'Detect current installed FMS version'))
        }
        # Phase 2 functions do not exist yet. We define throwing stubs here
        # so that if a future refactor accidentally wires Phase 2 work into
        # the dry-run path, the test surfaces it loudly. The Should -Invoke
        # assertions verify they were never called.
        function global:Invoke-Backup { throw 'destructive Invoke-Backup must not run in dry-run' }
        function global:Stop-FmsService { throw 'destructive Stop-FmsService must not run in dry-run' }
        function global:Invoke-FmsInstaller { throw 'destructive Invoke-FmsInstaller must not run in dry-run' }
        Mock -CommandName Invoke-Backup -MockWith { throw 'should not be called' }
        Mock -CommandName Stop-FmsService -MockWith { throw 'should not be called' }
        Mock -CommandName Invoke-FmsInstaller -MockWith { throw 'should not be called' }

        try {
            $code = Invoke-ChrysalisDryRun -ConfigPath $script:cfgPath -LogRoot $script:logRoot -ScriptRoot $script:scriptRoot
            $code | Should -Be 0

            Should -Invoke -CommandName Invoke-Backup -Times 0
            Should -Invoke -CommandName Stop-FmsService -Times 0
            Should -Invoke -CommandName Invoke-FmsInstaller -Times 0
        } finally {
            Remove-Item Function:\Invoke-Backup -ErrorAction SilentlyContinue
            Remove-Item Function:\Stop-FmsService -ErrorAction SilentlyContinue
            Remove-Item Function:\Invoke-FmsInstaller -ErrorAction SilentlyContinue
        }
    }

    It 'never writes the credential password to the log file (sentinel containment)' {
        $sentinel = 'P@ssw0rd-Chrysalis-Sentinel-q7z'
        Mock -CommandName Read-ChrysalisConfig -MockWith { return $script:testConfig }
        Mock -CommandName Read-ChrysalisCredentials -MockWith {
            return (New-TestCredential -User 'fmsadmin' -Pass $sentinel)
        }
        Mock -CommandName Invoke-PreFlight -MockWith {
            return @((New-PassResult -Id '2a' -Name 'Detect current installed FMS version'))
        }

        $code = Invoke-ChrysalisDryRun -ConfigPath $script:cfgPath -LogRoot $script:logRoot -ScriptRoot $script:scriptRoot
        $code | Should -Be 0

        $logFile = (Get-ChildItem -LiteralPath $script:logRoot -Filter 'chrysalis-*.log' -File | Select-Object -First 1).FullName
        $content = Get-Content -LiteralPath $logFile -Raw
        $content | Should -Not -Match ([regex]::Escape($sentinel))
        # Username is fine to log; assert it as a positive control.
        $content | Should -Match 'fmsadmin'
    }
}

Describe 'Invoke-ChrysalisDryRun pre-flight failure path' {

    BeforeEach {
        $script:scriptRoot = Join-Path -Path $TestDrive -ChildPath ('fail-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:scriptRoot -Force | Out-Null
        $script:cfgPath = Join-Path -Path $script:scriptRoot -ChildPath 'config.json'
        New-EntryConfigFile -Path $script:cfgPath | Out-Null
        $script:logRoot = Join-Path -Path $TestDrive -ChildPath ('logs-fail-' + [guid]::NewGuid().ToString('N'))
        $script:testConfig = New-EntryTestConfig
    }

    It 'returns 1 and logs the failing remediation when pre-flight reports a Fail' {
        Mock -CommandName Read-ChrysalisConfig -MockWith { return $script:testConfig }
        Mock -CommandName Read-ChrysalisCredentials -MockWith {
            return (New-TestCredential -User 'fmsadmin' -Pass 'unit-test-pw')
        }
        $failRemediation = 'Run fmsadmin backup, then re-run chrysalis (SENTINEL-REMEDIATION).'
        Mock -CommandName Invoke-PreFlight -MockWith {
            return @(
                (New-PassResult -Id '2a' -Name 'Detect current installed FMS version'),
                (New-FailResult -Id '2g' -Name 'Recent native FMS DB backup exists' `
                    -Detail "No FMS database backup newer than 24h found under 'X:\backups'." `
                    -Remediation $failRemediation)
            )
        }

        $code = Invoke-ChrysalisDryRun -ConfigPath $script:cfgPath -LogRoot $script:logRoot -ScriptRoot $script:scriptRoot
        $code | Should -Be 1

        $logFile = (Get-ChildItem -LiteralPath $script:logRoot -Filter 'chrysalis-*.log' -File | Select-Object -First 1).FullName
        $content = Get-Content -LiteralPath $logFile -Raw

        # Remediation text from the failing check is in the log.
        $content | Should -Match 'SENTINEL-REMEDIATION'

        # Final summary names "pre-flight FAILED".
        $content | Should -Match 'DryRun complete: pre-flight FAILED'
        $content | Should -Match 'Address them and re-run'
    }
}

Describe 'Invoke-ChrysalisDryRun unhandled exception path' {

    BeforeEach {
        $script:scriptRoot = Join-Path -Path $TestDrive -ChildPath ('exc-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:scriptRoot -Force | Out-Null
        $script:cfgPath = Join-Path -Path $script:scriptRoot -ChildPath 'config.json'
        New-EntryConfigFile -Path $script:cfgPath | Out-Null
        $script:logRoot = Join-Path -Path $TestDrive -ChildPath ('logs-exc-' + [guid]::NewGuid().ToString('N'))
    }

    It 'returns 3 when Read-ChrysalisConfig throws unexpectedly' {
        Mock -CommandName Read-ChrysalisConfig -MockWith {
            throw 'chrysalis: synthetic config parse failure for the unhandled-exception test.'
        }
        $code = Invoke-ChrysalisDryRun -ConfigPath $script:cfgPath -LogRoot $script:logRoot -ScriptRoot $script:scriptRoot
        $code | Should -Be 3

        $logFile = (Get-ChildItem -LiteralPath $script:logRoot -Filter 'chrysalis-*.log' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($null -ne $logFile) {
            $content = Get-Content -LiteralPath $logFile.FullName -Raw
            $content | Should -Match 'unhandled exception'
        }
    }

    It 'returns 3 when the resolved config file is missing (resolution itself throws)' {
        $missing = Join-Path -Path $script:scriptRoot -ChildPath 'absent.json'
        # Note: no Read-ChrysalisConfig mock; Resolve-ChrysalisEntryConfigPath
        # throws before we reach it. The catch block converts the throw into
        # exit code 3.
        $code = Invoke-ChrysalisDryRun -ConfigPath $missing -LogRoot $script:logRoot -ScriptRoot $script:scriptRoot
        $code | Should -Be 3
    }
}
