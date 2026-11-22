#Requires -Version 7.0
<#
.SYNOPSIS
    Boot a MICPE native-logon ISO under QEMU and check Administrator logon evidence.

.DESCRIPTION
    Unlike the ordinary probe, the native-logon image never writes probe_done.
    It writes native-logon-probe.txt (and copies it to micpe-probe.txt) from
    logon-admin.cmd, which only Userinit runs inside the authenticated session.
    This harness waits for those keys and screenshots the guest for diagnosis.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Iso,

    [string] $WorkDir = 'E:\micpe\verify-native',

    [string] $QemuPath = 'C:\Users\S-I-M\WorkBuddy\2026-11-21-16-33-41\.tmp-ref\qemu\qemu-system-x86_64.exe',

    [string] $FirmwarePath = 'C:\Users\S-I-M\WorkBuddy\2026-11-21-16-33-41\.tmp-ref\qemu\share\edk2-x86_64-code.fd',

    [string] $FirmwareVarsPath = 'C:\Users\S-I-M\WorkBuddy\2026-11-21-16-33-41\.tmp-ref\qemu\share\edk2-i386-vars.fd',

    [int] $CpuCount = 4,
    [int] $MemoryMb = 6144,
    [int] $TimeoutMin = 15,

    # Headful shows a real QEMU window (useful to SEE the black screen);
    # headless is default so CI can screendump. Both still write guest logs
    # to the vvfat share, which is the primary diagnostic signal.
    [switch] $Headful
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# StrictMode treats an unset $LASTEXITCODE as an error. Native cmdlets in the
# polling loop never set it, so seed it once up front.
$LASTEXITCODE = 0

foreach ($path in @($Iso, $QemuPath, $FirmwarePath, $FirmwareVarsPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing file: $path" }
}
foreach ($dir in @($WorkDir, (Join-Path $WorkDir 'share'), (Join-Path $WorkDir 'shots'))) {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}
$shareDir = Join-Path $WorkDir 'share'
$shotDir = Join-Path $WorkDir 'shots'
$qemuLog = Join-Path $WorkDir 'qemu.log'
$serialLog = Join-Path $WorkDir 'micpe-serial.log'
foreach ($stale in (Get-ChildItem -LiteralPath $shareDir -File -ErrorAction SilentlyContinue)) {
    Remove-Item -LiteralPath $stale.FullName -Force -ErrorAction SilentlyContinue
}

$monitorPort = Get-Random -Minimum 41000 -Maximum 49000
$monitorAddr = "tcp:127.0.0.1:$monitorPort,server,nowait"
# OVMF code/vars are pflash drives, not a legacy PC BIOS ROM. The template
# vars file must be copied per run so UEFI boot state is never persisted.
$varsCopy = Join-Path $WorkDir 'ovmf-vars.fd'
Copy-Item -LiteralPath $FirmwareVarsPath -Destination $varsCopy -Force
$qemuArgs = @(
    '-m', "$MemoryMb", '-smp', "$CpuCount", '-cpu', 'max'
    '-display', $(if ($Headful) { 'gtk' } else { 'none' }), '-no-reboot', '-no-shutdown'
    '-rtc', 'base=localtime'
    '-monitor', $monitorAddr
    '-serial', "file:$serialLog"
    '-drive', "if=pflash,format=raw,unit=0,readonly=on,file=$FirmwarePath"
    '-drive', "if=pflash,format=raw,unit=1,file=$varsCopy"
    '-drive', "file=fat:rw:$shareDir,format=raw,media=disk,if=ide"
    '-cdrom', $Iso, '-boot', 'd'
    '-D', $qemuLog
)
Write-Host "==> QEMU: $QemuPath $($qemuArgs -join ' ')"
$process = Start-Process -FilePath $QemuPath -ArgumentList $qemuArgs -PassThru -NoNewWindow

function Send-Monitor {
    param([string] $Command, [int] $DelayMs = 400)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $client.Connect('127.0.0.1', $monitorPort)
        $writer = [System.IO.StreamWriter]::new($client.GetStream())
        $writer.AutoFlush = $true
        $writer.WriteLine($Command)
        Start-Sleep -Milliseconds $DelayMs
    }
    catch {
        Write-Host "    monitor '$Command' failed: $($_.Exception.Message)"
    }
    finally { $client.Dispose() }
}

$deadline = (Get-Date).AddMinutes($TimeoutMin)
$bootKeyUntil = (Get-Date).AddSeconds(150)
$nextBootKey = Get-Date
$nextShot = (Get-Date).AddSeconds(45)
$shotIndex = 0
$probeText = $null
$probePath = $null

try {
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) {
            Write-Warning "QEMU exited early with code $($process.ExitCode)"
            break
        }
        if ((Get-Date) -lt $bootKeyUntil -and (Get-Date) -ge $nextBootKey) {
            Send-Monitor 'sendkey ret' 500
            $nextBootKey = (Get-Date).AddSeconds(25)
        }
        if ((Get-Date) -ge $nextShot) {
            $shotIndex++
            $shot = Join-Path $shotDir ("native-{0:d2}.png" -f $shotIndex)
            Send-Monitor ("screendump " + ($shot -replace '\\', '/') + ' png') 900
            if (Test-Path -LiteralPath $shot) { Write-Host "    screenshot: $shot" }
            $nextShot = (Get-Date).AddSeconds(30)
        }
        foreach ($name in @('native-logon-probe.txt', 'micpe-probe.txt')) {
            $candidate = Join-Path $shareDir $name
            if (-not (Test-Path -LiteralPath $candidate)) { continue }
            $content = Get-Content -LiteralPath $candidate -Raw -ErrorAction SilentlyContinue
            if ($content -match '(?m)^native_logon=1\s*$' -and $content -match '(?m)^logon_admin_script=1\s*$') {
                $probeText = $content
                $probePath = $candidate
                break
            }
        }
        # Diagnostic: surface the first appearance of either log exactly once.
        foreach ($logName in @('native-logon-bootstrap.log', 'native-logon-session.log')) {
            $lp = Join-Path $shareDir $logName
            if ((Test-Path -LiteralPath $lp) -and -not (Get-Variable -Name "seen_$logName" -ErrorAction SilentlyContinue)) {
                Write-Host "---- GUEST LOG: $logName ----"
                Get-Content -LiteralPath $lp -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  | $_" }
                Set-Variable -Name "seen_$logName" -Value $true
            }
        }
        if ($probeText) { break }
        Start-Sleep -Seconds 5
    }
}
finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}

if (-not $probeText) {
    Write-Warning 'native logon probe was not written; dumping everything the guest produced'
    Write-Host "---- SHARE CONTENTS ($shareDir) ----"
    Get-ChildItem -LiteralPath $shareDir -File -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "  FILE $($_.Name)  $($_.Length) bytes"
        Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    | $_" }
    }
    Write-Host "---- SHOTS ----"
    Get-ChildItem -LiteralPath $shotDir -File -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $($_.Name) $($_.Length) bytes" }
    if (Test-Path -LiteralPath $serialLog) { Write-Host '---- SERIAL ----'; Get-Content -LiteralPath $serialLog -Tail 30 }
    if (Test-Path -LiteralPath $qemuLog) { Write-Host '---- QEMU LOG ----'; Get-Content -LiteralPath $qemuLog -Tail 20 }
    exit 2
}

$probe = @{}
foreach ($line in ($probeText -split "`r?`n")) {
    if ($line -match '^\s*([^=#]+?)\s*=\s*(.*?)\s*$') { $probe[$Matches[1]] = $Matches[2] }
}
Write-Host ''
Write-Host "probe received from $probePath"
foreach ($key in ($probe.Keys | Sort-Object)) { Write-Host ("  {0,-22} {1}" -f $key, $probe[$key]) }

$failures = [System.Collections.Generic.List[string]]::new()
foreach ($key in @('native_logon', 'session_non_system', 'logon_admin_script')) {
    if ([string] $probe[$key] -ne '1') { $failures.Add("$key expected 1, got '$($probe[$key])'") }
}
if ([string] $probe['session_sid'] -notmatch '-500\s*$') {
    $failures.Add("session_sid must end in -500 (built-in Administrator), got '$($probe['session_sid'])'")
}
if ($failures.Count -gt 0) {
    Write-Warning "$($failures.Count) native logon assertion(s) failed:"
    $failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host ''
Write-Host '==> native Administrator logon verified in QEMU'
exit 0
