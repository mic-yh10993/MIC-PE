#Requires -Version 7.0
<#
.SYNOPSIS
    Boot the built ISO under QEMU and assert the stage's probe expectations.

.DESCRIPTION
    This is the L3 verification tier. It is deliberately separate from the build
    so that a static-only build does not pay the QEMU cost, and so the same script
    can be run locally against an artifact.

    Everything the PE reports arrives through the vvfat share, so a failure is
    reported as a table of key/expected/actual lines rather than a screenshot the
    reader has to interpret.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Iso,

    [Parameter(Mandatory = $true)]
    [ValidateSet('m1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7', 'all')]
    [string] $Stage,

    [string] $WorkDir,

    [int] $TimeoutMin = 45,

    [string] $QemuPath = 'qemu-system-x86_64',

    [switch] $KeepRawScreenshots
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot '..\build\lib\Common.ps1')
. (Join-Path $PSScriptRoot 'Assert-Probe.ps1')
. (Join-Path $PSScriptRoot 'Invoke-QemuVerify.ps1') -ParseOnly

if (-not $WorkDir) {
    $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "micpe-verify-$Stage"
}

$shareDir = Join-Path $WorkDir 'share'
$shotDir = Join-Path $WorkDir 'shots'
$qemuLog = Join-Path $WorkDir 'qemu.log'

foreach ($dir in $WorkDir, $shareDir, $shotDir) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

Write-Step "verifying $Stage"
Write-SubStep "iso: $Iso"
Write-SubStep "share: $shareDir"

$result = Invoke-QemuVerify -Iso $Iso -ShareDir $shareDir -TimeoutMin $TimeoutMin `
    -ScreenshotDir $shotDir -LogPath $qemuLog -QemuPath $QemuPath

if (-not $result.ProbeSeen) {
    Write-Host ''
    Write-Warn 'the PE never wrote a probe file'
    Write-Host "  expected: $($result.ProbePath)"
    if (Test-Path -LiteralPath $qemuLog) {
        Write-Host '  last qemu log lines:'
        Get-Content -LiteralPath $qemuLog -Tail 20 | ForEach-Object { Write-Host "    $_" }
    }
    exit 2
}

$probe = Read-ProbeFile -Path $result.ProbePath
$expected = Get-StageProbeExpect -Stage $Stage

Write-Host ''
Write-Host 'probe received:'
foreach ($key in ($probe.Keys | Sort-Object)) {
    Write-Host ("  {0,-22} {1}" -f $key, $probe[$key])
}

$failures = Assert-ProbeResult -Probe $probe -Expected $expected

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Warn "$($failures.Count) probe assertion(s) failed:"
    foreach ($line in $failures) { Write-Host "  $line" }

    if ($env:GITHUB_STEP_SUMMARY) {
        @(
            "## MICPE $Stage runtime verification: FAILED"
            ''
            '| Check | Result |'
            '| --- | --- |'
            ($failures | ForEach-Object { "| ``$_`` | failed |" })
        ) | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
    }
    exit 1
}

Write-Host ''
Write-Step "all $($expected.Count) probe assertion(s) passed for $Stage"

foreach ($shot in $result.Screenshots) {
    Write-SubStep ("screenshot: {0}" -f (Split-Path -Leaf $shot))
}

if ($env:GITHUB_STEP_SUMMARY) {
    @(
        "## MICPE $Stage runtime verification: PASSED"
        ''
        '| Probe key | Value |'
        '| --- | --- |'
        ($probe.Keys | Sort-Object | ForEach-Object { "| ``$_`` | ``$($probe[$_])`` |" })
    ) | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
}

exit 0
