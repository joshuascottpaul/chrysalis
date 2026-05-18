# Config.Tests.ps1
# Pester 5.x coverage for src/lib/Config.ps1.

BeforeAll {
    $script:RepoRoot = Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'src/lib/Config.ps1')

    $script:FixtureDir = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures'
    $script:ExamplePath = Join-Path -Path $script:RepoRoot -ChildPath 'config/config.example.json'
}

Describe 'Read-ChrysalisConfig - happy path' {

    It 'parses config/config.example.json into a PSCustomObject' {
        $cfg = Read-ChrysalisConfig -Path $script:ExamplePath
        $cfg | Should -Not -BeNullOrEmpty
        $cfg.target_version | Should -Be '21.0.3'
        $cfg.fms.admin_port | Should -Be 16001
        $cfg.backup_root | Should -Be 'C:\FMS_Backups'
        $cfg.installers.PSObject.Properties.Name | Should -Contain '21.0.3'
        $cfg.installers.PSObject.Properties.Name | Should -Contain '21.0.2'
        $cfg.shutdown_sequence.Count | Should -BeGreaterThan 0
        $cfg.startup_sequence.Count | Should -BeGreaterThan 0
    }

    It 'preserves target_version and installer sha256 from config.example.json (regression guard)' {
        $cfg = Read-ChrysalisConfig -Path $script:ExamplePath
        # Pinned values from config/config.example.json. If either drifts and
        # this test still passes, the parser is silently dropping data.
        $cfg.target_version | Should -Be '21.0.3'
        $cfg.installers.'21.0.3'.sha256 | Should -Be '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
        $cfg.upgrade_mode | Should -Be 'in_place'
    }

    It 'parses the good fixture cleanly' {
        $cfg = Read-ChrysalisConfig -Path (Join-Path -Path $script:FixtureDir -ChildPath 'good.json')
        $cfg.max_backup_age_hours | Should -Be 24
    }

    It 'defaults max_backup_age_hours to 24 when omitted' {
        $cfg = Read-ChrysalisConfig -Path (Join-Path -Path $script:FixtureDir -ChildPath 'max-backup-age-omitted.json')
        $cfg.max_backup_age_hours | Should -Be 24
    }
}

Describe 'Read-ChrysalisConfig - failure modes' {

    It 'errors when a required top-level field is missing' {
        $path = Join-Path -Path $script:FixtureDir -ChildPath 'missing-target-version.json'
        { Read-ChrysalisConfig -Path $path } | Should -Throw -ExpectedMessage "*required field 'target_version'*"
    }

    It 'errors when admin_port is a string instead of an integer' {
        $path = Join-Path -Path $script:FixtureDir -ChildPath 'admin-port-string.json'
        { Read-ChrysalisConfig -Path $path } | Should -Throw -ExpectedMessage "*fms.admin_port must be a JSON integer*"
    }

    # Lower-bound case (admin_port = 0). Pairs with admin-port-too-high.json
    # so the parser's two bound branches are covered independently — see
    # Hermione PR #1 review B1.
    It 'errors when admin_port is below the lower bound' {
        $path = Join-Path -Path $script:FixtureDir -ChildPath 'admin-port-out-of-range.json'
        { Read-ChrysalisConfig -Path $path } | Should -Throw -ExpectedMessage "*fms.admin_port must be an integer between 1 and 65535 (got '0' - below lower bound)*"
    }

    It 'errors when admin_port is above the upper bound' {
        $path = Join-Path -Path $script:FixtureDir -ChildPath 'admin-port-too-high.json'
        { Read-ChrysalisConfig -Path $path } | Should -Throw -ExpectedMessage "*fms.admin_port must be an integer between 1 and 65535 (got '70000' - above upper bound)*"
    }

    It 'errors when admin_port is an integral-valued JSON double (16001.0)' {
        $path = Join-Path -Path $script:FixtureDir -ChildPath 'admin-port-fractional.json'
        { Read-ChrysalisConfig -Path $path } | Should -Throw -ExpectedMessage "*fms.admin_port must be a JSON integer*number literals with a decimal point are not accepted*"
    }

    It 'errors on an unknown root-level property (typo of max_backup_age_hours)' {
        $path = Join-Path -Path $script:FixtureDir -ChildPath 'unknown-root-property.json'
        { Read-ChrysalisConfig -Path $path } | Should -Throw -ExpectedMessage "*unknown property 'max_backup_age_hour' in config*"
    }

    It 'errors on an unknown property inside an installers entry' {
        $path = Join-Path -Path $script:FixtureDir -ChildPath 'unknown-installer-property.json'
        { Read-ChrysalisConfig -Path $path } | Should -Throw -ExpectedMessage "*unknown property 'installers.21.0.3.windowss' in config*"
    }

    It 'errors on an unknown property inside the fms block' {
        $path = Join-Path -Path $script:FixtureDir -ChildPath 'unknown-fms-property.json'
        { Read-ChrysalisConfig -Path $path } | Should -Throw -ExpectedMessage "*unknown property 'fms.admin_porte' in config*"
    }

    It "errors when upgrade_mode is neither 'in_place' nor 'uninstall_reinstall'" {
        $path = Join-Path -Path $script:FixtureDir -ChildPath 'bad-upgrade-mode.json'
        { Read-ChrysalisConfig -Path $path } | Should -Throw -ExpectedMessage "*upgrade_mode must be 'in_place' or 'uninstall_reinstall' (got 'in-place')*"
    }

    It 'errors when target_version has no matching installers entry' {
        $path = Join-Path -Path $script:FixtureDir -ChildPath 'no-installer-for-target.json'
        { Read-ChrysalisConfig -Path $path } | Should -Throw -ExpectedMessage "*installers has no entry for target_version '21.0.3'*"
    }

    It 'errors when sha256 is malformed' {
        $path = Join-Path -Path $script:FixtureDir -ChildPath 'bad-sha256.json'
        { Read-ChrysalisConfig -Path $path } | Should -Throw -ExpectedMessage "*installers.21.0.3.sha256 must be 64 hex characters*"
    }

    It 'errors when target_version does not match major.minor.patch' {
        $path = Join-Path -Path $script:FixtureDir -ChildPath 'bad-target-version-format.json'
        { Read-ChrysalisConfig -Path $path } | Should -Throw -ExpectedMessage "*target_version must match*"
    }

    It 'errors when max_backup_age_hours is below 1' {
        $path = Join-Path -Path $script:FixtureDir -ChildPath 'max-backup-age-zero.json'
        { Read-ChrysalisConfig -Path $path } | Should -Throw -ExpectedMessage "*max_backup_age_hours must be an integer >= 1*"
    }

    It 'errors when shutdown_sequence is an empty array' {
        $path = Join-Path -Path $script:FixtureDir -ChildPath 'empty-shutdown-sequence.json'
        { Read-ChrysalisConfig -Path $path } | Should -Throw -ExpectedMessage "*shutdown_sequence must contain at least one entry*"
    }

    It 'errors when the config file does not exist' {
        $bogus = Join-Path -Path $TestDrive -ChildPath 'does-not-exist.json'
        { Read-ChrysalisConfig -Path $bogus } | Should -Throw -ExpectedMessage "*config file not found*"
    }

    It 'errors when the config file is not valid JSON' {
        $bad = Join-Path -Path $TestDrive -ChildPath 'malformed.json'
        Set-Content -LiteralPath $bad -Value '{ this is not json'
        { Read-ChrysalisConfig -Path $bad } | Should -Throw -ExpectedMessage "*is not valid JSON*"
    }
}
