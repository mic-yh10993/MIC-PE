#Requires -Version 7.0
<#
.SYNOPSIS
    Boot a MICPE ISO under QEMU, wait for the PE to write its probe file, capture
    screenshots, and return the probe contents.

.DESCRIPTION
    GitHub-hosted runners have no nested virtualisation, so QEMU runs under TCG.
    That is slow but deterministic enough: a 2.3 GB RAM-disk PE reaches the desktop
    in roughly 10-25 minutes.

    Two channels make the result machine-readable:

    * A vvfat drive maps a host directory into the guest as a writable FAT volume.
      The PE writes `micpe-probe.txt` there; the host reads it straight from disk.
    * The QEMU monitor is exposed on TCP so the host can request `screendump` at
      any time. Screenshots are evidence for humans, not the pass/fail signal.

    Boot entry: the ISO is attached as a CD-ROM and the firmware boots it directly,
    which is how a real machine would boot a DVD. The Windows boot sector
    asks "Press any key to boot from CD or DVD..."; the verifier answers it
    with Enter repeatedly until the probe appears (see Send-QemuBootKey),
    because a single early press can land before the prompt is displayed
    and the guest then sits at that prompt forever.
#>

[CmdletBinding()]
param(
    # Not Mandatory: other scripts dot-source this file just for the helper
    # functions, and dot-sourcing a script with mandatory parameters prompts.
    [string] $Iso,

    [string] $ShareDir,

    [int] $TimeoutMin = 45,

    [string] $ScreenshotDir,

    [string] $LogPath,

    [string] $MonitorPort = '4444',

    [int] $MemoryMb = 4096,

    [int] $CpuCount = 4,

    [string] $QemuPath = 'qemu-system-x86_64',

    [string] $FirmwarePath,

    [string[]] $DataDisks,

    [switch] $ParseOnly
)

Set-StrictMode -Version Latest

function Get-QemuArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Iso,

        [Parameter(Mandatory = $true)]
        [string] $ShareDir,

        [string] $MonitorPort = '4444',

        [int] $MemoryMb = 4096,

        [int] $CpuCount = 4,

        [string] $LogPath,

        [string] $FirmwarePath,

        [string[]] $DataDisks
    )

    $args = [System.Collections.Generic.List[string]]::new()
    # Serial log goes next to the -D log when one is set, so the verify
    # artifacts upload can collect it; otherwise it falls back to %TEMP%.
    # (WinPE console output goes to VGA, not serial, so this mostly holds
    # bootloader chatter -- but it is the only guest-side text channel we
    # have, so collect it anyway.)
    $serialLog = if ($LogPath) {
        Join-Path (Split-Path -Parent $LogPath) 'micpe-serial.log'
    }
    else {
        Join-Path ([System.IO.Path]::GetTempPath()) 'micpe-serial.log'
    }

    $args.AddRange([string[]] @(
        '-m', "$MemoryMb"
        '-smp', "$CpuCount"
        '-display', 'none'
        '-no-reboot'
        '-no-shutdown'
        '-rtc', 'base=localtime'
        '-monitor', "tcp:127.0.0.1:$MonitorPort,server,nowait"
        '-serial', "file:$serialLog"
    ))

    if ($FirmwarePath) {
        $args.AddRange([string[]] @('-bios', $FirmwarePath))
    }

    # vvfat: the probe channel. rw so the PE can write results back.
    $args.AddRange([string[]] @(
        '-drive', "file=fat:rw:$ShareDir,format=raw,media=disk,if=ide"
    ))

    foreach ($disk in $DataDisks) {
        $args.AddRange([string[]] @('-drive', "file=$disk,format=qcow2,media=disk,if=ide"))
    }

    $args.AddRange([string[]] @(
        '-cdrom', $Iso
        '-boot', 'd'
    ))

    if ($LogPath) {
        $args.AddRange([string[]] @('-D', $LogPath))
    }

    return $args.ToArray()
}

function Invoke-MonitorCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Port,

        [Parameter(Mandatory = $true)]
        [string] $Command,

        [int] $ReadDelayMs = 800,

        # Read the monitor's reply back (greeting + command output + prompt)
        # instead of fire-and-forget: a rejected command (bad key name,
        # unknown command) is otherwise invisible, and run 43951915833
        # showed sendkey doing nothing for 45 minutes without a trace.
        # Off by default: screendump judges success by the file it makes.
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

function ConvertTo-MonitorPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    # The QEMU monitor parses backslashes as escapes, so a Windows path like
    # D:\a\... dies on '\a' ("unsupported escape code") and the screendump
    # silently produces no file. QEMU on Windows accepts forward slashes.
    return ($Path -replace '\\', '/')
}

function Send-QemuBootKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Port
    )

    # The Windows ISO boot sector waits on "Press any key to boot from CD or
    # DVD..." and, with no other boot device attached, just sits there: run
    # 43912243734 produced 5 identical screenshots of that prompt over 45
    # minutes, and the PE never started. Answer it with Enter so the PE
    # actually boots. The monitor's reply is read back and logged: run
    # 43951915833 sent the key every 31s for the whole run and the guest
    # still never moved, with no trace of why -- a rejected sendkey must
    # show up in the log instead of vanishing.
    try {
        $response = Invoke-MonitorCommand -Port $Port -Command 'sendkey ret' -ReadResponse
        $flat = if ($response) { ($response -replace '\s+', ' ').Trim() } else { '' }
        if ($flat -match 'error|unknown|invalid') {
            Write-Host "!!! boot key rejected by monitor: $flat"
        }
        elseif ($flat) {
            Write-Host "    boot key sent (sendkey ret) -- monitor: $flat"
        }
        else {
            Write-Host '    boot key sent (sendkey ret)'
        }
    }
    catch {
        Write-Host "!!! boot key failed: $($_.Exception.Message)"
    }
}

function Find-OvmfCode {
    [CmdletBinding()]
    param(
        [string] $QemuPath = 'qemu-system-x86_64'
    )

    # The Windows ISO's EFI bootloader starts bootmgr directly, with no
    # "Press any key" prompt at all -- so when OVMF is available the
    # verifier prefers UEFI boot and the whole sendkey problem disappears.
    # The choco QEMU layout on the runner is not pinned down, so check the
    # usual spots and fall back to a shallow search under the QEMU dir.
    $dirs = [System.Collections.Generic.List[string]]::new()
    $qemuExe = $null
    if ($QemuPath -and (Test-Path -LiteralPath $QemuPath -ErrorAction SilentlyContinue)) {
        $qemuExe = (Resolve-Path -LiteralPath $QemuPath).Path
    }
    else {
        $qemuExe = (Get-Command $QemuPath -ErrorAction SilentlyContinue).Source
    }
    if ($qemuExe) { $dirs.Add((Split-Path -Parent $qemuExe)) }
    # Windows-only install locations: joining a 'C:' drive path on Linux
    # throws (there is no C: drive), so only add them on Windows. The
    # function must return $null -- not throw -- when OVMF is absent, or
    # the Linux Test workflow breaks.
    if ($IsWindows) {
        $dirs.Add('C:\Program Files\qemu')
        $dirs.Add('C:\Program Files (x86)\qemu')
    }

    foreach ($dir in $dirs) {
        foreach ($sub in @('', 'share', 'share\qemu')) {
            $candidate = Join-Path (Join-Path $dir $sub) 'OVMF_CODE.fd'
            if ($null -ne $candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
        }
    }
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $found = Get-ChildItem -LiteralPath $dir -Recurse -Depth 2 -Filter 'OVMF_CODE*.fd' `
            -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Save-QemuScreenshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Port,

        [Parameter(Mandatory = $true)]
        [string] $ScreenshotDir,

        [Parameter(Mandatory = $true)]
        [int] $ShotIndex
    )

    $ppm = Join-Path $ScreenshotDir ("shot-{0:d2}.ppm" -f $ShotIndex)
    try {
        # QEMU's screendump writes P6 PPM data whatever the file suffix is,
        # so the evidence file is named .ppm and kept: it is both the
        # machine-readable ratio input and the human-readable evidence the
        # upload step collects. (The previous .png copy was PPM bytes under
        # a PNG name, which strict viewers refuse to open.)
        Invoke-MonitorCommand -Port $Port -Command "screendump `"$(ConvertTo-MonitorPath -Path $ppm)`""
        if (Test-Path -LiteralPath $ppm) {
            $ratio = Measure-PpmNonBlackRatio -PpmPath $ppm
            $ratio | Set-Content -LiteralPath ($ppm -replace '\.ppm$', '.ratio.txt')
            Write-Host ("    screenshot {0}: {1:P1} non-black" -f (Split-Path -Leaf $ppm), $ratio)
        }
        else {
            Write-Host "!!! screendump produced no PPM file: $ppm"
        }
    }
    catch {
        Write-Host "!!! screenshot failed: $($_.Exception.Message)"
    }
}

function Read-Ppm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $PpmPath
    )

    # QEMU writes binary P6 PPM: "P6\n<w> <h>\n255\n" then RGB triples.
    $bytes = [System.IO.File]::ReadAllBytes($PpmPath)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0x50 -or $bytes[1] -ne 0x36) {
        throw [System.InvalidOperationException]::new("Not a binary PPM file: $PpmPath")
    }

    $headerEnd = 0
    $newlines = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0x0A) {
            $newlines++
            if ($newlines -eq 3) { $headerEnd = $i + 1; break }
        }
    }
    if ($headerEnd -eq 0) {
        throw [System.InvalidOperationException]::new("Malformed PPM header: $PpmPath")
    }

    $header = [System.Text.Encoding]::ASCII.GetString($bytes, 0, $headerEnd)
    $dimensions = ($header -split "`n")[1] -split '\s+'
    $width = [int] $dimensions[0]
    $height = [int] $dimensions[1]

    return [pscustomobject]@{
        Width  = $width
        Height = $height
        Pixels = $bytes[$headerEnd..($bytes.Length - 1)]
    }
}

function Measure-PpmNonBlackRatio {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $PpmPath,

        [int] $Threshold = 24,

        [int] $Step = 8
    )

    $image = Read-Ppm -PpmPath $PpmPath
    $pixels = $image.Pixels
    $lit = 0
    $total = 0

    for ($y = 0; $y -lt $image.Height; $y += $Step) {
        for ($x = 0; $x -lt $image.Width; $x += $Step) {
            $offset = (($y * $image.Width) + $x) * 3
            if ($offset + 2 -ge $pixels.Length) { continue }
            $total++
            if ($pixels[$offset] -gt $Threshold -or
                $pixels[$offset + 1] -gt $Threshold -or
                $pixels[$offset + 2] -gt $Threshold) {
                $lit++
            }
        }
    }

    if ($total -eq 0) { return 0 }
    return [double] $lit / $total
}

function Measure-NonBlackRatio {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $PngPath,

        [int] $Threshold = 24,

        [int] $Step = 8
    )

    # Kept for callers that only have a PNG. Requires System.Drawing, which is
    # present on Windows but not on Linux, so tests use Measure-PpmNonBlackRatio.
    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::FromFile($PngPath)
    try {
        $lit = 0
        $total = 0
        for ($y = 0; $y -lt $bitmap.Height; $y += $Step) {
            for ($x = 0; $x -lt $bitmap.Width; $x += $Step) {
                $pixel = $bitmap.GetPixel($x, $y)
                $total++
                if ($pixel.R -gt $Threshold -or $pixel.G -gt $Threshold -or $pixel.B -gt $Threshold) {
                    $lit++
                }
            }
        }
        if ($total -eq 0) { return 0 }
        return [double] $lit / $total
    }
    finally {
        $bitmap.Dispose()
    }
}

function Invoke-QemuVerify {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Iso,

        [Parameter(Mandatory = $true)]
        [string] $ShareDir,

        [int] $TimeoutMin = 45,

        [string] $ScreenshotDir,

        [string] $LogPath,

        [string] $MonitorPort = '4444',

        [int] $MemoryMb = 4096,

        [int] $CpuCount = 4,

        [string] $QemuPath = 'qemu-system-x86_64',

        [string] $FirmwarePath,

        [string[]] $DataDisks,

        [string] $ProbeFileName = 'micpe-probe.txt',

        # Which firmware to boot: auto prefers UEFI (OVMF) when it is
        # installed, because the Windows ISO's EFI bootloader skips the
        # "Press any key" prompt entirely; uefi requires OVMF and fails
        # fast when it is missing; bios forces SeaBIOS + sendkey.
        [ValidateSet('auto', 'uefi', 'bios')]
        [string] $Firmware = 'auto',

        # Seconds after QEMU starts before answering the "Press any key to
        # boot from CD or DVD..." prompt, and the interval for repeating it.
        # SeaBIOS under TCG is slow: run 43939552552 sent the key at +21s
        # and +32s, but the prompt only appeared later, so both presses
        # were lost and the guest sat at the prompt for 45 minutes. The
        # key is therefore sent repeatedly until the probe appears; an
        # Enter landing in the PE's cmd prompt is just an empty line.
        [int] $BootKeyDelaySec = 15,

        [int] $BootKeyIntervalSec = 30
    )

    if (-not (Test-Path -LiteralPath $Iso)) {
        throw [System.InvalidOperationException]::new("ISO not found: $Iso")
    }
    if (-not (Test-Path -LiteralPath $ShareDir)) {
        New-Item -ItemType Directory -Path $ShareDir -Force | Out-Null
    }
    if ($ScreenshotDir -and -not (Test-Path -LiteralPath $ScreenshotDir)) {
        New-Item -ItemType Directory -Path $ScreenshotDir -Force | Out-Null
    }

    $probePath = Join-Path $ShareDir $ProbeFileName
    if (Test-Path -LiteralPath $probePath) {
        Remove-Item -LiteralPath $probePath -Force
    }

    if (-not $FirmwarePath) {
        switch ($Firmware) {
            'bios' {
                Write-Host '    firmware: SeaBIOS (forced)'
            }
            'uefi' {
                $FirmwarePath = Find-OvmfCode -QemuPath $QemuPath
                if (-not $FirmwarePath) {
                    throw [System.InvalidOperationException]::new('Firmware=uefi but no OVMF_CODE.fd was found near the QEMU install')
                }
                Write-Host "    firmware: OVMF (UEFI) $FirmwarePath"
            }
            default {
                $FirmwarePath = Find-OvmfCode -QemuPath $QemuPath
                if ($FirmwarePath) {
                    Write-Host "    firmware: OVMF (UEFI) $FirmwarePath"
                }
                else {
                    Write-Host '    firmware: SeaBIOS (no OVMF found, falling back to sendkey)'
                }
            }
        }
    }

    $qemuArgs = Get-QemuArgs -Iso $Iso -ShareDir $ShareDir -MonitorPort $MonitorPort `
        -MemoryMb $MemoryMb -CpuCount $CpuCount -LogPath $LogPath `
        -FirmwarePath $FirmwarePath -DataDisks $DataDisks

    Write-Host "==> starting qemu (timeout ${TimeoutMin}m)"
    Write-Host "    $QemuPath $($qemuArgs -join ' ')"

    $process = Start-Process -FilePath $QemuPath -ArgumentList $qemuArgs -PassThru -NoNewWindow
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    $shotIndex = 0
    $nextShotAt = (Get-Date).AddMinutes(10)
    $bootKeyAt = (Get-Date).AddSeconds($BootKeyDelaySec)
    $bootKeysSent = 0
    $probe = @{}

    try {
        while ((Get-Date) -lt $deadline) {
            if ($process.HasExited) {
                Write-Host "!!! qemu exited early with code $($process.ExitCode)"
                break
            }

            # Answer the "Press any key to boot from CD or DVD..." prompt,
            # repeatedly until the probe appears: a single early press can
            # land before the prompt is even displayed (run 43939552552).
            if ((Get-Date) -ge $bootKeyAt -and -not (Test-Path -LiteralPath $probePath)) {
                Send-QemuBootKey -Port $MonitorPort
                $bootKeysSent++
                $bootKeyAt = (Get-Date).AddSeconds($BootKeyIntervalSec)
                if ($bootKeysSent -eq 1) {
                    # Bring the next screenshot forward so there is early
                    # evidence of whether the PE started booting.
                    $earlyShotAt = (Get-Date).AddSeconds(45)
                    if ($earlyShotAt -lt $nextShotAt) { $nextShotAt = $earlyShotAt }
                }
            }

            if (Test-Path -LiteralPath $probePath) {
                Start-Sleep -Seconds 3
                $probe = Get-Content -LiteralPath $probePath -Raw -ErrorAction SilentlyContinue
                if ($probe -and $probe -match 'boot=1') {
                    Start-Sleep -Seconds 5
                    break
                }
            }

            # Periodic screenshots: run 43896578569 waited the full 45
            # minutes with no probe and no picture of what the guest was
            # doing. A shot every 10 minutes shows whether it is stuck at
            # boot, at a prompt, or somewhere else entirely.
            if ($ScreenshotDir -and (Get-Date) -ge $nextShotAt) {
                $shotIndex++
                Save-QemuScreenshot -Port $MonitorPort -ScreenshotDir $ScreenshotDir -ShotIndex $shotIndex
                $nextShotAt = (Get-Date).AddMinutes(10)
            }

            Start-Sleep -Seconds 10
        }

        if ($ScreenshotDir) {
            $shotIndex++
            Save-QemuScreenshot -Port $MonitorPort -ScreenshotDir $ScreenshotDir -ShotIndex $shotIndex
        }
    }
    finally {
        if (-not $process.HasExited) {
            try {
                Invoke-MonitorCommand -Port $MonitorPort -Command 'quit' -ReadDelayMs 200
                Start-Sleep -Seconds 3
            }
            catch { }
            if (-not $process.HasExited) {
                $process.Kill($true)
            }
        }
    }

    $content = if (Test-Path -LiteralPath $probePath) {
        Get-Content -LiteralPath $probePath -Raw
    }
    else { $null }

    return [pscustomobject]@{
        ProbePath   = $probePath
        ProbeText   = $content
        ProbeSeen   = ($null -ne $content)
        Screenshots = if ($ScreenshotDir) { @(Get-ChildItem -LiteralPath $ScreenshotDir -Filter '*.ppm' -File) } else { @() }
        QemuLog     = $LogPath
    }
}

if (-not $ParseOnly) {
    if (-not $Iso) { throw [System.InvalidOperationException]::new('-Iso is required') }
    if (-not $ShareDir) { throw [System.InvalidOperationException]::new('-ShareDir is required') }

    $result = Invoke-QemuVerify -Iso $Iso -ShareDir $ShareDir -TimeoutMin $TimeoutMin `
        -ScreenshotDir $ScreenshotDir -LogPath $LogPath -MonitorPort $MonitorPort `
        -MemoryMb $MemoryMb -CpuCount $CpuCount -QemuPath $QemuPath `
        -FirmwarePath $FirmwarePath -DataDisks $DataDisks

    if ($result.ProbeSeen) {
        Write-Host '==> probe received:'
        Write-Host $result.ProbeText
    }
    else {
        Write-Host '!!! no probe file was written by the PE'
        exit 2
    }
}
