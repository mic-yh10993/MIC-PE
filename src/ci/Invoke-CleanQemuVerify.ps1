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

    [int] $StartMenuWaitSec = 8,

    # Dot-source only (tests): define the helpers above without launching
    # QEMU. Same pattern as Invoke-QemuVerify.ps1 -ParseOnly. The three
    # mandatory paths must still be passed (bind-time), but nothing runs.
    [switch] $ParseOnly
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

function Test-CleanScreenshot {
    <#
    .SYNOPSIS
        Classify a QEMU screenshot (PPM) by its dominant screen content.

    .DESCRIPTION
        Round 10 lesson: the verifier counted screenshots (7 of 7 captured)
        and passed, while the guest had died on the Windows Recovery screen
        (cdrom.sys 0xc0000428) -- the boot shots were TianoCore black and
        the desktop shots were all Recovery blue. Counting shots is not a
        pass/fail signal; the screen content is.

        Pure PowerShell / .NET (no OCR, no PIL, no ImageMagick): the
        Windows CI runner has none of those guaranteed, and the PNG
        encoder already proved this approach works there. Reads the PPM
        raster, samples a grid of pixels, and classifies:

          Recovery  >= 50% of sampled pixels are bright blue, and the
                    mean red of those blue pixels is above 16: the
                    Windows Recovery screen, (32,103,178), fills 99%
                    of the frame in round 10. A dark LogonUI background
                    does not trip this: its blue is dark (B < 100)
                    and desaturated.
          BlueScreen >= 50% of sampled pixels are bright blue, and the
                    mean red of those blue pixels is 16 or below: a
                    bugcheck blue screen. The classic BSOD blue is
                    (0,120,215); round 14 rendered it as (0,61,146)
                    in QEMU, mean red ~1. Both have red 0, while the
                    Recovery blue has red 32, so the midpoint 16
                    separates them. Round 14 lesson: the old code lumped
                    both blues into 'Recovery' and the caller blamed
                    0xc0000428 for a BSOD that was really
                    IO1 INITIALIZATION FAILED.
          Boot      >= 80% of sampled pixels are near-black (all channels
                    < 16): the TianoCore firmware screen. Round-10 shot-01
                    is 98% black.
          Other     anything else (LogonUI, desktop, Start menu).

        Returns a [pscustomobject] with Classification, BlueFraction,
        BlackFraction, BlueMeanR/G/B, Sampled and Path. Throws on an
        unreadable or malformed PPM; the caller treats that as unknown,
        not a failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $len = $bytes.Length

    # Parse the P6 header tokens (magic, width, height, maxval), tolerating
    # '#' comments. After the maxval token there is exactly one whitespace
    # byte, then the raster begins.
    $pos = 0
    $tokens = [System.Collections.Generic.List[string]]::new()
    while ($tokens.Count -lt 4 -and $pos -lt $len) {
        while ($pos -lt $len -and ($bytes[$pos] -eq 32 -or $bytes[$pos] -eq 9 -or $bytes[$pos] -eq 10 -or $bytes[$pos] -eq 13)) { $pos++ }
        if ($pos -ge $len) { break }
        if ($bytes[$pos] -eq 35) {
            while ($pos -lt $len -and $bytes[$pos] -ne 10) { $pos++ }
            continue
        }
        $start = $pos
        while ($pos -lt $len -and $bytes[$pos] -ne 32 -and $bytes[$pos] -ne 9 -and $bytes[$pos] -ne 10 -and $bytes[$pos] -ne 13 -and $bytes[$pos] -ne 35) { $pos++ }
        $tokens.Add([System.Text.Encoding]::ASCII.GetString($bytes, $start, $pos - $start))
    }
    if ($tokens.Count -ne 4 -or $tokens[0] -ne 'P6') {
        throw "not a P6 PPM file: '$Path'"
    }
    $width = [int]$tokens[1]
    $height = [int]$tokens[2]
    $maxval = [int]$tokens[3]
    if ($width -le 0 -or $height -le 0 -or $maxval -ne 255) {
        throw "unsupported PPM header in '$Path' ($width x $height, maxval $maxval)"
    }
    if ($pos -lt $len -and ($bytes[$pos] -eq 32 -or $bytes[$pos] -eq 9 -or $bytes[$pos] -eq 10 -or $bytes[$pos] -eq 13)) { $pos++ }
    $rasterStart = $pos
    if (($len - $rasterStart) -lt ($width * $height * 3)) {
        throw "truncated PPM raster in '$Path' (expected $($width * $height * 3) bytes, found $($len - $rasterStart))"
    }

    $stepX = [Math]::Max(1, [int]($width / 40))
    $stepY = [Math]::Max(1, [int]($height / 40))
    $sampled = 0
    $blue = 0
    $black = 0
    $blueSumR = 0
    $blueSumG = 0
    $blueSumB = 0
    for ($y = 0; $y -lt $height; $y += $stepY) {
        for ($x = 0; $x -lt $width; $x += $stepX) {
            $off = $rasterStart + ($y * $width + $x) * 3
            $r = $bytes[$off]
            $g = $bytes[$off + 1]
            $b = $bytes[$off + 2]
            $sampled++
            if ($b -ge 100 -and $b -gt ($r + 40) -and $g -gt ($r + 20)) {
                $blue++
                $blueSumR += $r
                $blueSumG += $g
                $blueSumB += $b
            }
            if ($r -lt 16 -and $g -lt 16 -and $b -lt 16) { $black++ }
        }
    }
    $blueFraction = if ($sampled -gt 0) { $blue / $sampled } else { 0 }
    $blackFraction = if ($sampled -gt 0) { $black / $sampled } else { 0 }
    $blueMeanR = if ($blue -gt 0) { $blueSumR / $blue } else { 0 }
    $blueMeanG = if ($blue -gt 0) { $blueSumG / $blue } else { 0 }
    $blueMeanB = if ($blue -gt 0) { $blueSumB / $blue } else { 0 }
    $classification = 'Other'
    if ($blueFraction -ge 0.5) {
        # Recovery blue (32,103,178) has red 32; both BSOD blues --
        # classic (0,120,215) and round-14 QEMU (0,61,146) -- have red 0.
        # The midpoint 16 separates them; white text / QR pixels are not
        # blue-matched, so they do not move the mean.
        if ($blueMeanR -le 16) { $classification = 'BlueScreen' }
        else { $classification = 'Recovery' }
    }
    elseif ($blackFraction -ge 0.8) { $classification = 'Boot' }

    return [pscustomobject]@{
        Path          = $Path
        Classification = $classification
        BlueFraction  = $blueFraction
        BlackFraction = $blackFraction
        BlueMeanR     = $blueMeanR
        BlueMeanG     = $blueMeanG
        BlueMeanB     = $blueMeanB
        Sampled       = $sampled
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
    # Resolve the OVMF variable-store template that pairs with $CodePath.
    #
    # Run 45416116043 lesson: the old code took the first *vars*.fd file
    # in the directory sorted by name. QEMU ships firmware for every
    # architecture in the same share/ directory, and the aarch64 vars
    # template (edk2-aarch64-vars.fd, 64 MB) sorts before the x86_64 one,
    # so the verifier handed QEMU a 64 MB vars file next to the 3.5 MB
    # code file -- and QEMU refused to start: "combined size of system
    # firmware exceeds 8388608 bytes" (the x86 firmware flash is capped
    # at 8 MiB, see FLASH_SIZE_LIMIT in hw/i386/pc_sysfw.c).
    #
    # The correct pairing is QEMU's own firmware descriptor
    # share/firmware/60-edk2-x86_64.json: edk2-x86_64-code.fd pairs with
    # edk2-i386-vars.fd (540,672 bytes; code + vars = 4 MiB exactly).
    # Same logic as Find-OvmfVars in Invoke-QemuVerify.ps1.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $CodePath
    )

    $dir = Split-Path -Parent $CodePath
    $varsPath = $null
    foreach ($name in @('edk2-i386-vars.fd', 'OVMF_VARS.fd')) {
        $candidate = Join-Path $dir $name
        if (Test-Path -LiteralPath $candidate) {
            $varsPath = $candidate
            break
        }
    }
    if (-not $varsPath) {
        # Last resort: any *vars*.fd in the directory. @() forces an
        # array: a single match comes back as a scalar FileInfo, which
        # has no .Count under Set-StrictMode.
        $candidates = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)vars' -and $_.Name -match '\.fd$' } |
            Sort-Object Name)
        if ($candidates.Count -eq 0) {
            throw [System.InvalidOperationException]::new(
                "no OVMF vars template found next to $CodePath (looked for edk2-i386-vars.fd, OVMF_VARS.fd, then *vars*.fd)")
        }
        $varsPath = $candidates[0].FullName
    }

    # Guard: QEMU caps the combined x86 firmware at 8 MiB. Fail here with
    # both file sizes named, instead of QEMU's bare "combined size of
    # system firmware exceeds 8388608 bytes" ten seconds into the run.
    $codeSize = (Get-Item -LiteralPath $CodePath).Length
    $varsSize = (Get-Item -LiteralPath $varsPath).Length
    $limit = 8 * 1024 * 1024
    Write-Host ("    OVMF vars: {0} ({1:N0} bytes); code {2:N0} bytes; combined {3:N0} bytes (limit {4:N0})" -f (Split-Path -Leaf $varsPath), $varsSize, $codeSize, ($codeSize + $varsSize), $limit)
    if (($codeSize + $varsSize) -gt $limit) {
        # Build the message first: inside ::new(...) the commas would be
        # read as argument separators, so the -f list must not sit bare
        # in the constructor call.
        $detail = ("OVMF code + vars exceed the 8 MiB firmware limit: code {0} ({1:N0} bytes) + vars {2} ({3:N0} bytes) = {4:N0} bytes; " +
            "expected edk2-x86_64-code.fd paired with edk2-i386-vars.fd (4 MiB combined)") -f $CodePath, $codeSize, $varsPath, $varsSize, ($codeSize + $varsSize)
        throw [System.InvalidOperationException]::new($detail)
    }
    return $varsPath
}

# --- launch ---------------------------------------------------------------

if (-not $ParseOnly) {

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

    # Screen-content gate (round 10 lesson): counting screenshots is not
    # a pass/fail signal -- round 10 captured 7 of 7 while the guest had
    # died on the Windows Recovery screen. Classify each shot by its
    # dominant content; a blue failure screen (Recovery or BSOD) anywhere
    # in the run means the system never booted, so the step fails and
    # says which kind it was instead of pressing Enter / Win into a dead
    # guest and calling it a pass. Round 14 lesson: do not default the
    # blame to 0xc0000428 -- the blue screen there was a bugcheck
    # (IO1 INITIALIZATION FAILED), not Recovery.
    $classifications = @()
    Get-ChildItem -LiteralPath $shotDir -File -Filter 'shot-*.ppm' |
        Sort-Object Name |
        ForEach-Object {
            try {
                $c = Test-CleanScreenshot -Path $_.FullName
                $classifications += $c
                Write-Host ("  shot content: {0}: {1} (blue {2:P0}, black {3:P0}, blue mean RGB {4:N0}/{5:N0}/{6:N0}, {7} sampled)" -f $_.Name, $c.Classification, $c.BlueFraction, $c.BlackFraction, $c.BlueMeanR, $c.BlueMeanG, $c.BlueMeanB, $c.Sampled)
            }
            catch {
                Write-Host ("!!! could not classify {0}: {1} (treated as unknown, not a failure)" -f $_.Name, $_.Exception.Message)
            }
        }
    $blueFailureShots = @($classifications | Where-Object { $_.Classification -eq 'Recovery' -or $_.Classification -eq 'BlueScreen' })
    if ($blueFailureShots.Count -gt 0) {
        $names = ($blueFailureShots | ForEach-Object { Split-Path -Leaf $_.Path }) -join ', '
        $kinds = [System.Collections.Generic.List[string]]::new()
        $recoveryCount = @($blueFailureShots | Where-Object { $_.Classification -eq 'Recovery' }).Count
        if ($recoveryCount -gt 0) { $kinds.Add(("{0} show(s) the Windows Recovery screen" -f $recoveryCount)) }
        $bsodCount = @($blueFailureShots | Where-Object { $_.Classification -eq 'BlueScreen' }).Count
        if ($bsodCount -gt 0) { $kinds.Add(("{0} show(s) a bugcheck blue screen (BSOD)" -f $bsodCount)) }
        throw ("QEMU screen check failed: {0} -- the system never reached LogonUI/desktop: {1}" -f ($kinds -join '; '), $names)
    }
    if ($classifications.Count -gt 0 -and @($classifications | Where-Object { $_.Classification -ne 'Boot' }).Count -eq 0) {
        throw 'QEMU screen check failed: every screenshot is a black screen (boot stalled at firmware / no display output); the system never reached LogonUI'
    }
    $logonShot = @($classifications | Where-Object { (Split-Path -Leaf $_.Path) -eq 'shot-03.ppm' })
    if ($logonShot.Count -gt 0 -and $logonShot[0].Classification -eq 'Boot') {
        Write-Host '!!! shot-03 is still a black screen at LogonUI time (slow boot?); the later shots decide'
    }
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

}