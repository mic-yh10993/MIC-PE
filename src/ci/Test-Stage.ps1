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
    [ValidateSet('m1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7', 'wb2', 'all')]
    [string] $Stage,

    [string] $WorkDir,

    [int] $TimeoutMin = 45,

    [string] $QemuPath = 'qemu-system-x86_64',

    # Guest resources. Defaults match Invoke-QemuVerify so CI behaviour is
    # unchanged; local runs can pass 2 vCPU / 4096 MB for UWP-in-PE.
    [int] $MemoryMb = 4096,
    [int] $CpuCount = 4,

    [ValidateSet('auto', 'uefi', 'bios')]
    [string] $Firmware = 'auto',

    # Passed through to the verifier when set (e.g. by the workflow's
    # "Ensure OVMF firmware" step); empty means "let the verifier find
    # it". Same dot-source trap as $Firmware: the helper declares this
    # name too, so it is saved and restored around the dot-source below.
    [string] $FirmwarePath,

    # Extra qcow2 disks for the installer deploy smoke test (plan Task 17
    # Step 6): the workflow's "Prepare data disks" step creates them and
    # passes them here; empty means a plain boot-only run. Same dot-source
    # trap: Invoke-QemuVerify.ps1 declares $DataDisks too.
    [string[]] $DataDisks,

    # Second vvfat volume for the local-mirror control (run 44428428849).
    # Empty means "derive it from WorkDir" (verify-out\mirror), so the
    # workflow needs no change. Same dot-source trap as $DataDisks:
    # Invoke-QemuVerify.ps1 declares $MirrorDir too.
    [string] $MirrorDir,

    [switch] $KeepRawScreenshots
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot '..\build\lib\Common.ps1')
. (Join-Path $PSScriptRoot 'Assert-Probe.ps1')

# Dot-sourcing a script binds its param block in this scope, and
# Invoke-QemuVerify.ps1 declares $Iso/$TimeoutMin/$QemuPath too: the bare
# dot-source below silently reset them to their defaults, so $Iso came back
# empty and the Invoke-QemuVerify call died on parameter binding (runs
# 43884981629 and 43891758991 both failed exactly this way). Save the three
# colliding parameters first and restore them right after.
$dotSourceParams = @{ Iso = $Iso; TimeoutMin = $TimeoutMin; QemuPath = $QemuPath; MemoryMb = $MemoryMb; CpuCount = $CpuCount; Firmware = $Firmware; FirmwarePath = $FirmwarePath; DataDisks = $DataDisks; MirrorDir = $MirrorDir }
. (Join-Path $PSScriptRoot 'Invoke-QemuVerify.ps1') -ParseOnly
$Iso = $dotSourceParams.Iso
$TimeoutMin = $dotSourceParams.TimeoutMin
$QemuPath = $dotSourceParams.QemuPath
$MemoryMb = $dotSourceParams.MemoryMb
$CpuCount = $dotSourceParams.CpuCount
$Firmware = $dotSourceParams.Firmware
$FirmwarePath = $dotSourceParams.FirmwarePath
$DataDisks = $dotSourceParams.DataDisks
$MirrorDir = $dotSourceParams.MirrorDir

if (-not $WorkDir) {
    $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "micpe-verify-$Stage"
}

$shareDir = Join-Path $WorkDir 'share'
$shotDir = Join-Path $WorkDir 'shots'
$qemuLog = Join-Path $WorkDir 'qemu.log'
$mirrorDir = if ($MirrorDir) { $MirrorDir } else { Join-Path $WorkDir 'mirror' }

foreach ($dir in $WorkDir, $shareDir, $shotDir, $mirrorDir) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

Write-Step "verifying $Stage"
Write-SubStep "iso: $Iso"
Write-SubStep "share: $shareDir"
Write-SubStep "mirror: $mirrorDir"

$result = Invoke-QemuVerify -Iso $Iso -ShareDir $shareDir -TimeoutMin $TimeoutMin `
    -ScreenshotDir $shotDir -LogPath $qemuLog -QemuPath $QemuPath -MemoryMb $MemoryMb `
    -CpuCount $CpuCount -Firmware $Firmware -FirmwarePath $FirmwarePath `
    -DataDisks $DataDisks -MirrorDir $mirrorDir

# A leaked monitor reply can turn $result into an Object[] instead of the
# single result object (run 44046530462 threw "The property 'ProbeSeen'
# cannot be found on this object" here under Set-StrictMode). Guard first:
# anything that is not the result object is a clean probe timeout, not a
# crash -- exit 2 with the same "never wrote a probe file" message.
# Run 48: either probe file counts — the share file alone went missing
# in run 47 while the local copy held the whole run, so a run with
# only the local copy is still a run worth judging, not a timeout.
if ($null -eq $result -or $result -isnot [pscustomobject] -or (-not $result.ProbeSeen -and -not $result.LocalProbeSeen)) {
    Write-Host ''
    Write-Warn 'the PE never wrote a probe file'
    # .ProbePath is only safe on the result object itself: on an Object[]
    # (leaked monitor replies) even this read throws under StrictMode.
    if ($result -is [pscustomobject]) {
        Write-Host "  expected: $($result.ProbePath)"
    }
    if (Test-Path -LiteralPath $qemuLog) {
        Write-Host '  last qemu log lines:'
        Get-Content -LiteralPath $qemuLog -Tail 20 | ForEach-Object { Write-Host "    $_" }
    }
    exit 2
}

$probe = Merge-ProbeFiles -SharePath $result.ProbePath -LocalPath $result.ProbeLocalPath
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
