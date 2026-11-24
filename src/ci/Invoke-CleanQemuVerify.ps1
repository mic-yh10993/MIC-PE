#Requires -Version 7.0
<#
.SYNOPSIS
    QEMU screenshot verification for the MIC-PE clean rebuild.

.DESCRIPTION
    The clean rebuild has no probe.cmd (it is a clean PE, not the m*/wb2
    harness image), so the probe-based verifier (Invoke-QemuVerify.ps1 /
    Test-Stage.ps1) cannot run against it: there is no probe.txt to wait
    for. This script instead boots the ISO, drives the guest through the
    QEMU monitor, and captures screenshots as evidence for a human to
    review:

      shot-01..03  boot progress -> LogonUI (native login, no winpeshl)
      shot-04..05  desktop after pressing Enter at LogonUI (Administrator,
                   blank password, single user tile -> logs straight in)
      shot-06      Start menu after pressing the Windows key (StartAllBack /
                   Start11 must be rendering it)
      shot-07      desktop again after closing the Start menu

    Screenshots are evidence, not a pass/fail signal: the caller uploads
    them as artifacts and the reviewer confirms Explorer is up, the
    taskbar rendered, the desktop icons are present, the LogonUI login
    worked, and StartAllBack/Start11 are in effect. The script exits 0
    when the screenshots were captured; it exits 1 only when QEMU never
    came up or no screenshot was produced at all.

    Login assumption: a single Administrator user with a blank password,
    whose tile is focused by default at LogonUI, so a bare Enter logs in.
    If the LogonUI layout ever needs a click instead, shot-04 will show
    the login screen still up and the reviewer retries interactively.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $IsoPath,

    [Parameter(Mandatory = $true)]
    [string] $OvmfPath,

    [Parameter(Mandatory = $true)]
    [string] $WorkDir,

    [string] $QemuPath = 'qemu-system-x86_64',

    [int] $MemoryMb = 4096,

    [int] $CpuCount = 4,

    [string] $MonitorPort = '4444',

    # Seconds to wait after QEMU start before the first screenshot, then
    # the gap between the boot screenshots. Boot to LogonUI on a hosted
    # runner is typically 60-180 s; the timeline below brackets it.
    [int] $BootWaitSec = 90,

    [int] $BootGapSec = 60,

    # Seconds to wait after pressing Enter at LogonUI before the desktop
    # screenshots, and after the Windows key before the Start menu shot.
    [int] $LoginWaitSec = 45,

    [int] $StartMenuWaitSec = 8
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\build\lib\Common.ps1')

Assert-PathExists -Path $IsoPath -Label 'ISO'
Assert-PathExists -Path $OvmfPath -Label 'OVMF firmware'

if (-not (Test-Path -LiteralPath $WorkDir)) {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
}
$shotDir = Join-Path $WorkDir 'screenshots'
if (-not (Test-Path -LiteralPath $shotDir)) {
    New-Item -ItemType Directory -Path $shotDir -Force | Out-Null
}

function Invoke-CleanMonitorCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Port,

        [Parameter(Mandatory = $true)]
        [string] $Command,

        [int] $ReadDelayMs = 800,

        [switch] $ReadResponse
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    $response = ''
    try {
        $client.Connect('127.0.0.1', [int] $Port)
        $stream = $client.GetStream()
        $writer = [System.IO.StreamWriter]::new($stream)
        $writer.AutoFlush = $true
        $writer.WriteLine($Command)
        Start-Sleep -Milliseconds $ReadDelayMs
        if ($ReadResponse) {
            $stream.ReadTimeout = 2000
            $reader = [System.IO.StreamReader]::new($stream)
            $buffer = [char[]]::new(4096)
            try {
                while ($true) {
                    $read = $reader.Read($buffer, 0, $buffer.Length)
                    if ($read -le 0) { break }
                    $response += [string]::new($buffer, 0, $read)
                }
            }
            catch [System.IO.IOException] {
                # Read timeout: the monitor has said all it will say.
            }
        }
        $writer.WriteLine('')
        Start-Sleep -Milliseconds 300
    }
    finally {
        $client.Dispose()
    }
    return $response
}

function ConvertTo-CleanMonitorPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    # The QEMU monitor parses backslashes as escapes, so a Windows path
    # dies on '\a' ("unsupported escape code") and the screendump silently
    # produces no file. QEMU on Windows accepts forward slashes.
    return ($Path -replace '\\', '/')
}

function Save-CleanScreenshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Port,

        [Parameter(Mandatory = $true)]
        [string] $ScreenshotDir,

        [Parameter(Mandatory = $true)]
        [int] $ShotIndex,

        [string] $Label = ''
    )

    $ppm = Join-Path $ScreenshotDir ("shot-{0:d2}.ppm" -f $ShotIndex)
    try {
        $null = Invoke-CleanMonitorCommand -Port $Port -Command "screendump `"$(ConvertTo-CleanMonitorPath -Path $ppm)`""
        if (Test-Path -LiteralPath $ppm) {
            $bytes = (Get-Item -LiteralPath $ppm).Length
            Write-Host ("    screenshot {0} ({1}): {2:N0} bytes" -f (Split-Path -Leaf $ppm), $Label, $bytes)
            return $true
        }
        Write-Host "!!! screendump produced no PPM file: $ppm ($Label)"
        return $false
    }
    catch {
        Write-Host "!!! screenshot failed ($Label): $($_.Exception.Message)"
        return $false
    }
}

function Send-CleanKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Port,

        [Parameter(Mandatory = $true)]
        [string] $Key,

        [string] $Label = ''
    )

    try {
        $response = Invoke-CleanMonitorCommand -Port $Port -Command "sendkey $Key" -ReadResponse
        $flat = if ($response) {
            $r = $response -replace "`e\[[0-9;?]*[A-Za-z]", ''
            $r = $r -replace "`e\][^\x07]*`a", ''
            ($r -replace '\s+', ' ').Trim()
        }
        else { '' }
        if ($flat -match 'error|unknown|invalid') {
            Write-Host "!!! sendkey $Key rejected by monitor: $flat"
            return $false
        }
        Write-Host ("    sendkey {0} sent ({1})" -f $Key, $Label)
        return $true
    }
    catch {
        Write-Host "!!! sendkey $Key failed ($Label): $($_.Exception.Message)"
        return $false
    }
}

function Find-CleanOvmfVars {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $CodePath
    )

    $dir = Split-Path -Parent $CodePath
    $candidates = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)vars' -and $_.Name -match '\.fd$' } |
        Sort-Object Name
    if ($candidates.Count -eq 0) {
        throw [System.InvalidOperationException]::new(
            "no OVMF vars template found next to $CodePath (looked for *vars*.fd)")
    }
    return $candidates[0].FullName
}

# --- launch ---------------------------------------------------------------

$varsTemplate = Find-CleanOvmfVars -CodePath $OvmfPath
$varsPath = Join-Path $WorkDir 'OVMF_VARS.fd'
Copy-Item -LiteralPath $varsTemplate -Destination $varsPath -Force

$serialLog = Join-Path $WorkDir 'micpe-serial.log'
$qemuLog = Join-Path $WorkDir 'micpe-qemu.log'

$qemuArgs = @(
    '-m', "$MemoryMb"
    '-smp', "$CpuCount"
    '-cpu', 'max'
    '-display', 'none'
    '-no-reboot'
    '-no-shutdown'
    '-rtc', 'base=localtime'
    '-monitor', "tcp:127.0.0.1:$MonitorPort,server,nowait"
    '-serial', "file:$serialLog"
    '-drive', "if=pflash,format=raw,unit=0,readonly=on,file=$OvmfPath"
    '-drive', "if=pflash,format=raw,unit=1,file=$varsPath"
    '-cdrom', $IsoPath
    '-boot', 'd'
    '-D', $qemuLog
)
$argString = ($qemuArgs | ForEach-Object {
    if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
}) -join ' '

Write-Host "starting QEMU: $QemuPath $argString"
$qemu = Start-Process -FilePath $QemuPath -ArgumentList $argString -PassThru -NoNewWindow
if ($null -eq $qemu) { throw 'failed to start QEMU' }

$shotsTaken = 0
$shotIndex = 0
try {
    # Wait for the monitor to accept connections.
    $monitorUp = $false
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        if ($qemu.HasExited) {
            throw "QEMU exited early (exit $($qemu.ExitCode)); see $qemuLog"
        }
        try {
            $null = Invoke-CleanMonitorCommand -Port $MonitorPort -Command 'info status' -ReadResponse
            $monitorUp = $true
            break
        }
        catch {
            Start-Sleep -Seconds 5
        }
    }
    if (-not $monitorUp) {
        throw 'QEMU monitor never came up within 120 s'
    }
    Write-Host 'QEMU monitor is up; booting'

    # Boot progress -> LogonUI.
    Start-Sleep -Seconds $BootWaitSec
    $shotIndex++
    if (Save-CleanScreenshot -Port $MonitorPort -ScreenshotDir $shotDir -ShotIndex $shotIndex -Label 'boot') { $shotsTaken++ }
    Start-Sleep -Seconds $BootGapSec
    $shotIndex++
    if (Save-CleanScreenshot -Port $MonitorPort -ScreenshotDir $shotDir -ShotIndex $shotIndex -Label 'boot/LogonUI') { $shotsTaken++ }
    Start-Sleep -Seconds $BootGapSec
    $shotIndex++
    if (Save-CleanScreenshot -Port $MonitorPort -ScreenshotDir $shotDir -ShotIndex $shotIndex -Label 'LogonUI expected') { $shotsTaken++ }

    # Log in as Administrator (blank password, single user tile).
    $null = Send-CleanKey -Port $MonitorPort -Key 'ret' -Label 'Enter at LogonUI (log in as Administrator)'
    Start-Sleep -Seconds $LoginWaitSec
    $shotIndex++
    if (Save-CleanScreenshot -Port $MonitorPort -ScreenshotDir $shotDir -ShotIndex $shotIndex -Label 'desktop after login') { $shotsTaken++ }
    Start-Sleep -Seconds 30
    $shotIndex++
    if (Save-CleanScreenshot -Port $MonitorPort -ScreenshotDir $shotDir -ShotIndex $shotIndex -Label 'desktop settled') { $shotsTaken++ }

    # Open the Start menu (StartAllBack / Start11 must be rendering it).
    $null = Send-CleanKey -Port $MonitorPort -Key 'meta_l' -Label 'Windows key (open Start menu)'
    Start-Sleep -Seconds $StartMenuWaitSec
    $shotIndex++
    if (Save-CleanScreenshot -Port $MonitorPort -ScreenshotDir $shotDir -ShotIndex $shotIndex -Label 'Start menu') { $shotsTaken++ }
    $null = Send-CleanKey -Port $MonitorPort -Key 'esc' -Label 'Escape (close Start menu)'
    Start-Sleep -Seconds 5
    $shotIndex++
    if (Save-CleanScreenshot -Port $MonitorPort -ScreenshotDir $shotDir -ShotIndex $shotIndex -Label 'desktop after Start menu') { $shotsTaken++ }

    Write-Host ("clean QEMU verify: {0} of {1} screenshots captured in {2}" -f $shotsTaken, $shotIndex, $shotDir)
    if ($shotsTaken -eq 0) {
        throw 'no screenshots were captured; QEMU produced no display output'
    }

    # Shot list for the step summary / artifact upload.
    Get-ChildItem -LiteralPath $shotDir -File -Filter 'shot-*.ppm' |
        Sort-Object Name |
        ForEach-Object { Write-Host ("  shot: {0} ({1:N0} bytes)" -f $_.Name, $_.Length) }
}
finally {
    try {
        $null = Invoke-CleanMonitorCommand -Port $MonitorPort -Command 'quit'
    }
    catch {
        # Monitor already gone (QEMU exited); nothing to quit.
    }
    if (-not $qemu.HasExited) {
        $qemu.WaitForExit(15000)
        if (-not $qemu.HasExited) {
            $qemu.Kill()
        }
    }
}

return [pscustomobject]@{
    ScreenshotDir = $shotDir
    ShotsTaken    = $shotsTaken
    ShotsExpected = $shotIndex
}
