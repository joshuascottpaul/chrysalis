# Config.ps1
# chrysalis configuration reader and validator. Parses config.json via
# ConvertFrom-Json and enforces the rules captured in config/config.schema.json.
# Implements SDD section 5 (Configuration) and supports the pre-flight 2g
# max_backup_age_hours check (SDD section 6.1).
# PowerShell 5.1 compatible.
# PR #1 scope: Windows config validation only. Cross-platform install_root_*
# validation lands in Phase 5.

function Read-ChrysalisConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "chrysalis: config file not found at '$Path'."
    }

    # Get-Content -Raw returns the whole file as one string; required so
    # ConvertFrom-Json sees a complete JSON document.
    $raw = $null
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch {
        throw "chrysalis: cannot read config file '$Path': $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "chrysalis: config file '$Path' is empty."
    }

    $config = $null
    try {
        $config = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "chrysalis: config file '$Path' is not valid JSON: $($_.Exception.Message)"
    }

    Test-ChrysalisConfig -Config $config

    # Default max_backup_age_hours to 24 if missing, per SDD section 5.
    if (-not (Test-ConfigHasProperty -Object $config -Name 'max_backup_age_hours')) {
        Add-Member -InputObject $config -MemberType NoteProperty -Name 'max_backup_age_hours' -Value 24
    }

    return $config
}

function Test-ConfigHasProperty {
    param(
        [Parameter(Mandatory = $true)]
        $Object,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )
    if ($null -eq $Object) { return $false }
    # PSCustomObject from ConvertFrom-Json exposes properties via PSObject.Properties.
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-ConfigPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        $Object,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )
    if (Test-ConfigHasProperty -Object $Object -Name $Name) {
        return $Object.PSObject.Properties[$Name].Value
    }
    return $null
}

function Test-AllowedProperties {
    param(
        [Parameter(Mandatory = $true)]
        $Object,
        [Parameter(Mandatory = $true)]
        [string[]] $Allowed,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $PathPrefix
    )

    if ($null -eq $Object -or $Object -isnot [pscustomobject]) { return }

    # Mirrors additionalProperties:false in config.schema.json. The parser was
    # silently letting typos like 'max_backup_age_hour' (singular) through,
    # which caused the default to silently win — exactly the foot-gun the
    # schema is designed to prevent.
    $allowedSet = @{}
    foreach ($n in $Allowed) { $allowedSet[$n] = $true }
    $allowedList = ($Allowed -join ', ')

    foreach ($prop in $Object.PSObject.Properties) {
        if (-not $allowedSet.ContainsKey($prop.Name)) {
            if ([string]::IsNullOrEmpty($PathPrefix)) {
                $dotted = $prop.Name
            } else {
                $dotted = "$PathPrefix.$($prop.Name)"
            }
            throw "chrysalis: unknown property '$dotted' in config (allowed: $allowedList)."
        }
    }
}

function Test-ChrysalisConfig {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    if ($null -eq $Config) {
        throw "chrysalis: config root is null."
    }
    if ($Config -isnot [pscustomobject]) {
        throw "chrysalis: config root must be a JSON object."
    }

    $allowedRoot = @(
        'target_version',
        'upgrade_mode',
        'installers',
        'fms',
        'backup_root',
        'max_backup_age_hours',
        'shutdown_sequence',
        'startup_sequence'
    )
    Test-AllowedProperties -Object $Config -Allowed $allowedRoot -PathPrefix ''

    $requiredTop = @('target_version', 'installers', 'fms', 'backup_root', 'shutdown_sequence', 'startup_sequence')
    foreach ($name in $requiredTop) {
        if (-not (Test-ConfigHasProperty -Object $Config -Name $name)) {
            throw "chrysalis: required field '$name' is missing from config."
        }
    }

    # target_version: semver-ish.
    $targetVersion = $Config.target_version
    if (-not ($targetVersion -is [string]) -or [string]::IsNullOrWhiteSpace($targetVersion)) {
        throw "chrysalis: target_version must be a non-empty string (got '$targetVersion')."
    }
    if ($targetVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "chrysalis: target_version must match '<major>.<minor>.<patch>' (got '$targetVersion')."
    }

    # upgrade_mode (optional). If absent, leave it absent — SDD section 5 is
    # silent on the default and Phase 4 will introduce auto-detection
    # (uninstall_reinstall for cross-major bumps). Picking a default here would
    # pre-commit that design decision before Ariadne and Ripley have signed off.
    if (Test-ConfigHasProperty -Object $Config -Name 'upgrade_mode') {
        $upgradeMode = $Config.upgrade_mode
        if ($upgradeMode -ne 'in_place' -and $upgradeMode -ne 'uninstall_reinstall') {
            throw "chrysalis: upgrade_mode must be 'in_place' or 'uninstall_reinstall' (got '$upgradeMode')."
        }
    }

    # installers: object with at least one entry, including target_version.
    $installers = $Config.installers
    if ($null -eq $installers -or $installers -isnot [pscustomobject]) {
        throw "chrysalis: installers must be a JSON object keyed by version string."
    }
    $installerNames = @($installers.PSObject.Properties | ForEach-Object { $_.Name })
    if ($installerNames.Count -eq 0) {
        throw "chrysalis: installers must contain at least one version entry."
    }
    if (-not (Test-ConfigHasProperty -Object $installers -Name $targetVersion)) {
        throw "chrysalis: installers has no entry for target_version '$targetVersion'."
    }

    foreach ($prop in $installers.PSObject.Properties) {
        Test-InstallerEntry -VersionKey $prop.Name -Entry $prop.Value
    }

    # fms block.
    $fms = $Config.fms
    if ($null -eq $fms -or $fms -isnot [pscustomobject]) {
        throw "chrysalis: fms must be a JSON object."
    }
    $allowedFms = @(
        'install_root_windows',
        'install_root_macos',
        'install_root_linux',
        'admin_port',
        'creds_file'
    )
    Test-AllowedProperties -Object $fms -Allowed $allowedFms -PathPrefix 'fms'
    foreach ($name in @('install_root_windows', 'admin_port', 'creds_file')) {
        if (-not (Test-ConfigHasProperty -Object $fms -Name $name)) {
            throw "chrysalis: required field 'fms.$name' is missing from config."
        }
    }
    $installRoot = $fms.install_root_windows
    if (-not ($installRoot -is [string]) -or [string]::IsNullOrWhiteSpace($installRoot)) {
        throw "chrysalis: fms.install_root_windows must be a non-empty string (got '$installRoot')."
    }
    # Note: creds_file is validated as a string only. Existence is NOT checked
    # here by design. EncryptCreds.ps1 creates the file on first run, so a
    # parser-level Test-Path would break first-run setup. The pre-flight 2d
    # decrypt check (SDD section 6.1) is the existence-and-decrypt gate.
    # See ADR-004 for the parser-vs-preflight separation-of-concerns rule.
    $credsFile = $fms.creds_file
    if (-not ($credsFile -is [string]) -or [string]::IsNullOrWhiteSpace($credsFile)) {
        throw "chrysalis: fms.creds_file must be a non-empty string (got '$credsFile')."
    }

    $adminPort = $fms.admin_port
    if (-not (Test-IsInteger -Value $adminPort)) {
        throw "chrysalis: fms.admin_port must be a JSON integer (got '$adminPort' - number literals with a decimal point are not accepted)."
    }
    $adminPortInt = [int] $adminPort
    if ($adminPortInt -lt 1) {
        throw "chrysalis: fms.admin_port must be an integer between 1 and 65535 (got '$adminPort' - below lower bound)."
    }
    if ($adminPortInt -gt 65535) {
        throw "chrysalis: fms.admin_port must be an integer between 1 and 65535 (got '$adminPort' - above upper bound)."
    }

    # backup_root.
    $backupRoot = $Config.backup_root
    if (-not ($backupRoot -is [string]) -or [string]::IsNullOrWhiteSpace($backupRoot)) {
        throw "chrysalis: backup_root must be a non-empty string (got '$backupRoot')."
    }

    # max_backup_age_hours (optional, default 24, integer >= 1).
    if (Test-ConfigHasProperty -Object $Config -Name 'max_backup_age_hours') {
        $maxAge = $Config.max_backup_age_hours
        if (-not (Test-IsInteger -Value $maxAge)) {
            throw "chrysalis: max_backup_age_hours must be a JSON integer >= 1 (got '$maxAge' - number literals with a decimal point are not accepted)."
        }
        $maxAgeInt = [int] $maxAge
        if ($maxAgeInt -lt 1) {
            throw "chrysalis: max_backup_age_hours must be an integer >= 1 (got '$maxAge')."
        }
    }

    # shutdown_sequence and startup_sequence: non-empty arrays of non-empty strings.
    Test-StringArrayField -FieldPath 'shutdown_sequence' -Value $Config.shutdown_sequence
    Test-StringArrayField -FieldPath 'startup_sequence' -Value $Config.startup_sequence
}

function Test-InstallerEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $VersionKey,
        [Parameter(Mandatory = $true)]
        $Entry
    )

    if ($VersionKey -notmatch '^\d+\.\d+\.\d+$') {
        throw "chrysalis: installers key '$VersionKey' must match '<major>.<minor>.<patch>'."
    }
    if ($null -eq $Entry -or $Entry -isnot [pscustomobject]) {
        throw "chrysalis: installers.$VersionKey must be a JSON object."
    }

    Test-AllowedProperties -Object $Entry -Allowed @('windows', 'macos', 'linux', 'sha256') -PathPrefix "installers.$VersionKey"

    foreach ($name in @('windows', 'macos', 'linux', 'sha256')) {
        if (-not (Test-ConfigHasProperty -Object $Entry -Name $name)) {
            throw "chrysalis: required field 'installers.$VersionKey.$name' is missing from config."
        }
    }

    foreach ($platform in @('windows', 'macos', 'linux')) {
        $url = $Entry.PSObject.Properties[$platform].Value
        if (-not ($url -is [string]) -or [string]::IsNullOrWhiteSpace($url)) {
            throw "chrysalis: installers.$VersionKey.$platform must be a non-empty string (got '$url')."
        }
    }

    $sha = $Entry.sha256
    if (-not ($sha -is [string]) -or $sha -notmatch '^[0-9a-fA-F]{64}$') {
        throw "chrysalis: installers.$VersionKey.sha256 must be 64 hex characters (got '$sha')."
    }
}

function Test-StringArrayField {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FieldPath,
        [Parameter(Mandatory = $false)]
        $Value
    )

    # ConvertFrom-Json on an empty JSON array '[]' returns $null in PS 5.1, so
    # treat null as "empty array" rather than "wrong type" for this field.
    if ($null -eq $Value) {
        throw "chrysalis: $FieldPath must contain at least one entry."
    }

    # PS 5.1's pipeline unwraps single-element collections, so a one-entry JSON
    # array may surface as a bare string rather than [object[]]. Force-wrap so
    # downstream indexing works regardless.
    $items = @($Value)
    if ($items.Count -lt 1) {
        throw "chrysalis: $FieldPath must contain at least one entry."
    }
    for ($i = 0; $i -lt $items.Count; $i++) {
        $item = $items[$i]
        if (-not ($item -is [string]) -or [string]::IsNullOrWhiteSpace($item)) {
            throw "chrysalis: $FieldPath[$i] must be a non-empty string (got '$item')."
        }
    }
}

function Test-IsInteger {
    param([Parameter(Mandatory = $false)] $Value)

    if ($null -eq $Value) { return $false }
    # ConvertFrom-Json maps JSON integers to [int] or [long], and any number
    # literal containing '.' or scientific notation to [double] (or [decimal]/
    # [single] in edge cases). We deliberately reject the floating-point types
    # outright — even when the value is integral (e.g. 16001.0) — because the
    # schema is stricter than PS's permissive numeric coercions and we want
    # the parser to surface authoring smells like a stray decimal point.
    if ($Value -is [int] -or $Value -is [long]) { return $true }
    return $false
}
