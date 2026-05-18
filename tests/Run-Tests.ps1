# Run-Tests.ps1
# Local Pester 5.x runner. Mirrors what .github/workflows/ci.yml does so a dev
# can run `pwsh -File tests/Run-Tests.ps1` (or PS 5.1 on Windows) and get the
# same behavior as CI without the artifact upload step.

[CmdletBinding()]
param(
    [string] $Path = (Join-Path -Path $PSScriptRoot -ChildPath '.')
)

$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.0.0 -Force

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.Exit = $true
$config.TestResult.Enabled = $true
$config.TestResult.OutputFormat = 'NUnitXml'
$config.TestResult.OutputPath = Join-Path -Path $PSScriptRoot -ChildPath '..\test-results\pester.xml'
$config.Output.Verbosity = 'Detailed'

$resultsDir = Split-Path -Parent $config.TestResult.OutputPath
if (-not (Test-Path -LiteralPath $resultsDir)) {
    New-Item -ItemType Directory -Path $resultsDir | Out-Null
}

Invoke-Pester -Configuration $config
