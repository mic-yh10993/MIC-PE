#Requires -Version 7.0
<#
.SYNOPSIS
    Local MICPE build + QEMU verification driver (no GitHub Actions).

.DESCRIPTION
    Wraps src/build/Build-Micpe.ps1 with the local toolchain and source ISO,
    then optionally boots the result under QEMU to verify the native
    Administrator logon. Run from an ELEVATED PowerShell 7 session.

    The build needs administrator rights (dism /Mount-Image) and ~35 GB of
    free space on the workspace volume. Point -Workspace at a large volume.

.EXAMPLE
    # Native-logon image, then verify in QEMU (2 vCPU / 4 GB):
    .\scripts\Invoke-LocalBuild.ps1 -Workspace 'F:\micpe' -NativeLogonExperiment -Verify

.EXAMPLE
    # Rebuild reusing already-extracted base wims (fast):
    .\scripts\Invoke-LocalBuild.ps1 -Workspace 'F:\micpe' -NativeLogonExperiment -SkipDownload -Verify
#>
[CmdletBinding()]
param(
    # Volume root for the build workspace (needs ~35 GB free).
    [Parameter(Mandatory = $true)]
    [string] $Workspace,

    # Source Windows 11 ISO. Defaults to the one in Downloads.
    [string] $SourceIso = 'C:\Users\S-I-M\Downloads\Windows11_Client_x64_zh-cn_26300_9457.iso',

    [ValidateSet('m1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7', 'wb2', 'all')]
    [string] $Stage = 'all',

    # Enable the native Administrator logon path (the phase-1 goal).
    [switch] $NativeLogonExperiment,

    # Reuse base\install.wim / base\boot.wim if both exist (skips 8 GB extraction).
    [switch] $SkipDownload,

    # Boot the built ISO under QEMU and check the probe file.
    [switch] $Verify,

    # QEMU guest resources. 2 vCPU / 4 GB is the tested baseline for UWP in PE.
    [int] $CpuCount = 2,
    [int] $MemoryMb = 4096,

    # Tool locations (relative to the workspace's parent .tmp-ref by default).
    [string] $ToolsBin = 'C:\Users\S-I-M\WorkBuddy\2026-11-21-16-33-41\.tmp-ref\tools\bin',
    [string] $QemuDir  = 'C:\Users\S-I-M\WorkBuddy\2026-11-21-16-33-41\.tmp-ref\qemu',

    # Full transcript of this run. Defaults to a timestamped file under the
    # workspace logs dir so a failed build can always be diagnosed afterwards.
    [string] $LogPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $LogPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $LogPath = Join-Path $Workspace "logs\invoke-localbuild-$stamp.log"
}
$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
Start-Transcript -LiteralPath $LogPath -Force | Out-Null
Write-Host "build transcript: $LogPath"

try {

$repoRoot = Split-Path -Parent $PSScriptRoot

# --- preflight ------------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Elevation required: run this script from an Administrator PowerShell 7 session (dism /Mount-Image needs it).'
}

foreach ($tool in '7z.exe', 'wimlib-imagex.exe', 'oscdimg.exe') {
    $p = Join-Path $ToolsBin $tool
    if (-not (Test-Path -LiteralPath $p)) { throw "Missing tool: $p" }
}
$qemuExe = Join-Path $QemuDir 'qemu-system-x86_64.exe'
if ($Verify -and -not (Test-Path -LiteralPath $qemuExe)) { throw "Missing QEMU: $qemuExe" }
if (-not (Test-Path -LiteralPath $SourceIso)) { throw "Source ISO not found: $SourceIso" }

$wsRoot = [System.IO.Path]::GetFullPath($Workspace)
$driveLetter = [System.IO.Path]::GetPathRoot($wsRoot).Substring(0, 1)
$freeGB = [math]::Round((Get-PSDrive -Name $driveLetter).Free / 1GB, 1)
Write-Host "workspace: $wsRoot  (${driveLetter}:, $freeGB GB free)"
if ($freeGB -lt 35 -and -not $SkipDownload) {
    throw "Need >=35 GB free on ${driveLetter}: for a full build (have $freeGB). Use -SkipDownload if base wims already exist, or pick another volume."
}

# Put local tools first on PATH: the build calls wimlib-imagex / 7z by bare name.
$env:Path = "$ToolsBin;$QemuDir;$env:Path"

# --- media tree -----------------------------------------------------------
# Build-Micpe.ps1's Invoke-BaseStep lays out media\ only on the UUP download
# path. With a local SourceIso (and -SkipDownload) it returns early, so the
# reseed step fails on a missing media\sources\boot.wim. Prepare it here.
$mediaDir = Join-Path $wsRoot 'media'
$mediaBoot = Join-Path $mediaDir 'sources/boot.wim'
if (-not (Test-Path -LiteralPath $mediaBoot)) {
    $sevenZip = Join-Path $ToolsBin '7z.exe'
    Write-Host "`n=== MEDIA TREE (extracting the source ISO -> $mediaDir) ==="
    if (Test-Path -LiteralPath $mediaDir) {
        # Clear contents but keep the directory itself (avoids ACL/in-use issues
        # on a pre-created workspace dir).
        Get-ChildItem -LiteralPath $mediaDir -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    & $sevenZip x $SourceIso "-o$mediaDir" -y | Select-Object -Last 8
    if ($LASTEXITCODE -ne 0) { throw "7z failed to extract the media tree (exit $LASTEXITCODE)" }
    if (-not (Test-Path -LiteralPath $mediaBoot)) { throw "media tree extraction did not produce $mediaBoot" }
}
else {
    Write-Host "`nmedia tree already present, skipping ISO extraction"
}

# --- build ----------------------------------------------------------------
$buildArgs = @{
    Stage        = $Stage
    Workspace    = $wsRoot
    SourceIso    = $SourceIso
    SkipDownload = [bool] $SkipDownload
}
if ($NativeLogonExperiment) { $buildArgs.NativeLogonExperiment = $true }

$buildScript = Join-Path $repoRoot 'src/build/Build-Micpe.ps1'
Write-Host "`n=== BUILD (stage=$Stage, nativeLogon=$([bool]$NativeLogonExperiment)) ==="
& $buildScript @buildArgs
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) { throw "Build failed with exit code $LASTEXITCODE" }

$iso = Join-Path $wsRoot 'out\MICPE.iso'
if (-not (Test-Path -LiteralPath $iso)) {
    # Build-Micpe.ps1 may export a custom -Output; fall back to scanning out\.
    $iso = (Get-ChildItem -LiteralPath (Join-Path $wsRoot 'out') -Filter '*.iso' -File |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
if (-not $iso -or -not (Test-Path -LiteralPath $iso)) { throw 'Build produced no ISO.' }
Write-Host "`nISO ready: $iso"

# --- verify ---------------------------------------------------------------
if ($Verify) {
    $ovmf = Join-Path $QemuDir 'share\edk2-x86_64-code.fd'
    $vars = Join-Path $QemuDir 'share\edk2-i386-vars.fd'
    foreach ($f in $ovmf, $vars) {
        if (-not (Test-Path -LiteralPath $f)) { throw "Missing firmware: $f" }
    }
    $workDir = Join-Path $wsRoot 'verify-out'
    $verifyScript = Join-Path $repoRoot 'src/ci/Test-Stage.ps1'
    Write-Host "`n=== QEMU VERIFY (cpu=$CpuCount, mem=${MemoryMb}MB, stage=$Stage) ==="
    & $verifyScript -Iso $iso -Stage $Stage -WorkDir $workDir `
        -QemuPath $qemuExe -Firmware 'uefi' -FirmwarePath $ovmf `
        -CpuCount $CpuCount -MemoryMb $MemoryMb -TimeoutMin 45
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) { throw "QEMU verification failed with exit code $LASTEXITCODE" }
    Write-Host "`nVerify artifacts: $workDir"
}

Write-Host "`nDONE. ISO: $iso"

}
finally {
    Stop-Transcript | Out-Null
    Write-Host "build transcript saved: $LogPath"
}
