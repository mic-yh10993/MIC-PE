#Requires -Version 7.0
<#
.SYNOPSIS
    Run Pester tests.

.PARAMETER Path
    Test files or directories. Defaults to the tests directory next to the repository root.

.PARAMETER Output
    Pester output verbosity.
#>
[CmdletBinding()]
param(
    [string[]] $Path,
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string] $Output = 'Detailed'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Path) {
    $Path = Join-Path $repoRoot 'tests'
}

Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Output.Verbosity = $Output
$config.Run.Exit = $false
$config.Run.PassThru = $true

$result = Invoke-Pester -Configuration $config

if ($result.FailedCount -gt 0) {
    Write-Host ''
    Write-Host ("FAILED: {0} passed, {1} failed, {2} skipped" -f $result.PassedCount, $result.FailedCount, $result.SkippedCount)
    exit 1
}

Write-Host ''
Write-Host ("PASSED: {0} passed, {1} skipped" -f $result.PassedCount, $result.SkippedCount)
exit 0
