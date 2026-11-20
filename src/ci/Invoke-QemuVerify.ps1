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
    which is how a real machine would boot a DVD. The BIOS path's boot sector
    asks "Press any key to boot from CD or DVD..."; the verifier answers it
    with Enter every 3 seconds, at most 4 times (see Send-QemuBootKey),
    because the prompt times out after about 10 seconds. The UEFI path
    has no prompt at all, because the build packs efisys_noprompt.bin as
    the EFI El Torito image -- the prompting efisys.bin's cdboot.efi times
    out after about 3 seconds, which no harness key can reach in time
    (run 44046530462: "BdsDxe: failed to start Boot0001 ... : Time out").
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

    # Second vvfat volume for the local-mirror control (run 44428428849):
    # the serial channel is dead, so the local mirror file needs a
    # retrieval path that does not depend on the suspect share. The
    # probe's detached probe-mirror.cmd copies the local file here
    # every few seconds; the host reads it straight from this
    # directory after QEMU exits. Empty means no mirror drive (the
    # probe runs on without it, mirror=0).
    [string] $MirrorDir,

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

        # Writable NVRAM store for the pflash boot below. When present
        # together with FirmwarePath, the firmware is booted from pflash
        # drives instead of -bios.
        [string] $FirmwareVarsPath,

        [string[]] $DataDisks,

        [string] $MirrorDir
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
        # '-cpu max': the default qemu64 CPU lacks instructions the 25H2
        # kernel needs, so the guest triple-faults about a minute after the
        # WIM is read (local TCG repro, run 44062469206) and the verify can
        # never pass. -cpu max gives the guest the host's full feature set.
        '-cpu', 'max'
        '-display', 'none'
        '-no-reboot'
        '-no-shutdown'
        '-rtc', 'base=localtime'
        '-monitor', "tcp:127.0.0.1:$MonitorPort,server,nowait"
        '-serial', "file:$serialLog"
    ))

    if ($FirmwarePath -and $FirmwareVarsPath) {
        # Split OVMF images are pflash images, not a BIOS ROM: run 43989280052
        # proved -bios rejects the 3,653,632-byte code file ("could not load
        # PC BIOS"). The code drive is read-only; the vars drive is the
        # writable NVRAM store (a per-run copy of the template).
        $args.AddRange([string[]] @(
            '-drive', "if=pflash,format=raw,unit=0,readonly=on,file=$FirmwarePath"
            '-drive', "if=pflash,format=raw,unit=1,file=$FirmwareVarsPath"
        ))
    }
    elseif ($FirmwarePath) {
        $args.AddRange([string[]] @('-bios', $FirmwarePath))
    }

    # vvfat: the probe channel. rw so the PE can write results back.
    $args.AddRange([string[]] @(
        '-drive', "file=fat:rw:$ShareDir,format=raw,media=disk,if=ide"
    ))

    # Mirror drive (run 44428428849): a second vvfat volume for the
    # local-mirror control, attached right after the share so it
    # letters after it (D: when the share is C:). The probe finds it
    # by the micpe-mirror.txt sentinel, not by letter. A second
    # independent vvfat instance: if the share volume wedges but the
    # guest lives, the mirror copy keeps growing; if both stop, the
    # guest itself froze (or both volumes wedged at once — the
    # residual ambiguity, see eval card §29).
    if ($MirrorDir) {
        $args.AddRange([string[]] @(
            '-drive', "file=fat:rw:$MirrorDir,format=raw,media=disk,if=ide"
        ))
    }

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

function ConvertTo-NativeArgumentString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    # Start-Process -ArgumentList joins an array with bare spaces, so a value
    # with a space is split into two arguments by the native parser: run
    # 43989280052 passed '-bios C:\Program Files\qemu\share\...' and QEMU
    # read it as '-bios C:\Program' + 'Files\qemu\...', then died with
    # "Could not open 'Files\qemu\share\edk2-x86_64-code.fd'". Quote any
    # argument that contains whitespace so it survives as one token.
    ($Arguments | ForEach-Object {
        if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
    }) -join ' '
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

function Format-MonitorReply {
    [CmdletBinding()]
    param(
        [string] $Reply,

        [int] $MaxLength = 200
    )

    # The monitor's readline echoes the command back with ANSI colour and
    # cursor escapes, and repeats the (qemu) prompt per line: run
    # 43965120455 logged several hundred characters of escape soup per
    # keypress. Strip the escapes, collapse the whitespace, and cap the
    # length so the build log stays readable. The raw reply is still
    # returned by Invoke-MonitorCommand for callers that need it.
    if (-not $Reply) { return '' }
    $flat = $Reply -replace "`e\[[0-9;?]*[A-Za-z]", ''
    $flat = $flat -replace "`e\][^\x07]*`a", ''
    $flat = ($flat -replace '\s+', ' ').Trim()
    if ($flat.Length -gt $MaxLength) {
        $flat = $flat.Substring(0, $MaxLength) + '...'
    }
    return $flat
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
        $flat = Format-MonitorReply -Reply $response
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

function Save-QemuBlockInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Port
    )

    # Run 47 (mirror): the harness attaches a second vvfat volume for
    # the mirror, yet the guest enumerates only C/D/X and the mirror
    # probe key reads 0 — the probe is reporting truthfully, so the gap
    # is between QEMU and the guest. Ask the monitor which block devices
    # QEMU actually attached (info block lists the ide0-hd0/ide0-hd1/
    # ide1-cd0 devices with their tray state), so the next round can
    # tell a QEMU-side attach failure from a guest-side enumeration
    # failure. Never fails the run: the monitor may be gone by the time
    # this runs, and a missing reply is itself evidence.
    try {
        $response = Invoke-MonitorCommand -Port $Port -Command 'info block' -ReadResponse
        $flat = Format-MonitorReply -Reply $response -MaxLength 2000
        if ($flat) {
            Write-Host "    qemu block devices: $flat"
        }
        else {
            Write-Host '    qemu block devices: (no reply)'
        }
    }
    catch {
        Write-Host "    qemu block devices query failed: $($_.Exception.Message)"
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
    #
    # Two names are tried, in order: QEMU renamed its bundled UEFI
    # firmware from OVMF_CODE.fd to edk2-x86_64-code.fd in 9.0, and the
    # runner's QEMU 11.1.0 ships only the new name (verified against the
    # official 11.1.0 installer, SHA-512 matched: it contains
    # share/edk2-x86_64-code.fd and no OVMF_CODE.fd). The secure-code
    # variant is deliberately NOT matched: it only runs on q35 with SMM,
    # and the verifier uses the default i440fx machine.
    $searchNames = @('OVMF_CODE.fd', 'edk2-x86_64-code.fd')
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

    foreach ($name in $searchNames) {
        foreach ($dir in $dirs) {
            foreach ($sub in @('', 'share', 'share\qemu')) {
                $candidate = Join-Path (Join-Path $dir $sub) $name
                if ($null -ne $candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
            }
        }
    }
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($name in $searchNames) {
            $found = Get-ChildItem -LiteralPath $dir -Recurse -Depth 2 -Filter $name `
                -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { return $found.FullName }
        }
    }
    return $null
}

function Find-OvmfVars {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $CodePath
    )

    # The x86_64 firmware's NVRAM template is the i386 vars file: QEMU's own
    # firmware descriptor share/firmware/60-edk2-x86_64.json pairs
    # edk2-x86_64-code.fd with edk2-i386-vars.fd (540,672 bytes; code +
    # vars = 4 MiB exactly). The vars file is the writable NVRAM store, so
    # the verifier copies it per run -- it must never be passed to QEMU
    # in place under the install directory.
    $dir = Split-Path -Parent $CodePath
    foreach ($name in @('edk2-i386-vars.fd', 'OVMF_VARS.fd')) {
        $candidate = Join-Path $dir $name
        if (Test-Path -LiteralPath $candidate) { return $candidate }
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
        # Discard the monitor reply: Invoke-MonitorCommand returns its
        # response string, and a bare call here leaks it into this
        # function's output stream. That leaked string ended up inside
        # Invoke-QemuVerify's return value alongside the result object,
        # and Test-Stage.ps1 then read .ProbeSeen off an Object[] and
        # threw "The property 'ProbeSeen' cannot be found on this object"
        # (run 44046530462). Send-QemuBootKey is safe: it assigns the
        # return value to $response.
        $null = Invoke-MonitorCommand -Port $Port -Command "screendump `"$(ConvertTo-MonitorPath -Path $ppm)`""
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

function Test-ProbeComplete {
    [CmdletBinding()]
    param(
        [string] $Content
    )

    # The probe is complete only when probe.cmd has written its last line.
    # probe.cmd writes boot=1 FIRST and then spends minutes on the shell,
    # UWP, payload, brand and installer checks: breaking on boot=1 (what
    # the loop used to do) returns a partial probe and every later
    # assertion fails on keys that were simply not written yet.
    # probe_failed=1 (run 44285721257) is also a terminal line: the
    # watchdog writes it when the probe stalls or dies mid-run, so the
    # host stops waiting early. It ends the wait only; the verdict is
    # still a failure, see Assert-ProbeResult.
    if (-not $Content) { return $false }
    if ($Content -match '(?m)^probe_failed=1\s*$') { return $true }
    return ($Content -match '(?m)^probe_done=1\s*$')
}

function Test-ScStartComplete {
    [CmdletBinding()]
    param(
        [string] $Content
    )

    # Run 54: the sc start experiment runs after probe_done (run 51)
    # and writes scstart_done=1 to the probe local file when it
    # finishes; the fifth sync carries it to the share. The host
    # waits for it (bounded, see Test-ProbeWaitDone) so the
    # experiment results come back instead of being cut off with
    # QEMU (run 53: no scstart_* or aumid_after_* key ever came back).
    if (-not $Content) { return $false }
    return ($Content -match '(?m)^scstart_done=1\s*$')
}

function Test-ProbeWaitDone {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $ShareContent,

        [AllowNull()]
        [object] $LocalContent,

        [AllowNull()]
        [Nullable[datetime]] $ProbeDoneAt,

        [int] $ScStartWaitSec = 120
    )

    # Run 54: probe_done ends the main probe, but the sc start
    # experiment runs after it and needs up to ~45 seconds more
    # (three bounded sc starts plus the AUMID re-dump). Returns
    # $true when the host may end the wait: probe_failed (the
    # watchdog says the probe died — never wait for an experiment
    # that cannot run), scstart_done seen in either file, or the
    # bounded wait after probe_done has elapsed (the experiment
    # did not finish in time; proceeding with what came back is
    # itself a signal, not a silent loss). $ProbeDoneAt is $null
    # until probe_done is first seen, so this never ends the wait
    # before the main probe is done.
    if ($null -eq $ProbeDoneAt) { return $false }
    $share = if ($ShareContent -is [string]) { $ShareContent } else { '' }
    $local = if ($LocalContent -is [string]) { $LocalContent } else { '' }
    $combined = "$share`n$local"
    if ($combined -match '(?m)^probe_failed=1\s*$') { return $true }
    if ($combined -match '(?m)^scstart_done=1\s*$') { return $true }
    return ((Get-Date) - $ProbeDoneAt).TotalSeconds -ge $ScStartWaitSec
}

function Test-ScreenshotFrozen {
    [CmdletBinding()]
    param(
        [string] $PreviousHash,
        [string] $CurrentHash,
        [int] $PreviousProbeLength,
        [int] $CurrentProbeLength,
        [bool] $ProbeExists,
        [string] $ProbeContent,

        # Run 48: the watchdog heartbeat is a second liveness signal.
        # Run 47 proved the share probe file's host view can stall while
        # the guest keeps writing (host saw 7794 bytes, guest wrote
        # 11184), so "probe did not grow" alone is not proof the guest
        # is wedged — the watchdog was still ticking the whole time
        # (quiet=0, last line 12:45:18). A growing heartbeat vetoes the
        # frozen verdict the same way a growing probe does. The three
        # parameters are optional: when no heartbeat file exists yet
        # (the watchdog starts mid-run) the old behaviour stands.
        [int] $PreviousHeartbeatLength = -1,
        [int] $CurrentHeartbeatLength = -1,
        [bool] $HeartbeatExists = $false
    )

    # The guest is frozen only when three things are true at once:
    # two consecutive screenshots are byte-identical, the probe file
    # exists but has not grown since the last screenshot, and the
    # probe is not in the long installer deploy (mark_installer_deploy
    # means a deploy may legitimately take a long time with a static
    # screen and a quiet probe). Any one of them alone is not enough:
    # a healthy PE shows a static screen for minutes at a time (the
    # probe's waits are silent), and a slow probe can be quiet between
    # sections. Run 44386689307 wasted 45 of 72 minutes waiting out a
    # freeze this would have caught at the second screenshot.
    if (-not $ProbeExists) { return $false }
    if (-not $PreviousHash -or -not $CurrentHash) { return $false }
    if ($PreviousHash -ne $CurrentHash) { return $false }
    if ($CurrentProbeLength -ne $PreviousProbeLength) { return $false }
    if ($HeartbeatExists -and $CurrentHeartbeatLength -ne $PreviousHeartbeatLength) { return $false }
    if ($ProbeContent -match '(?m)^mark_installer_deploy=') { return $false }
    if (Test-ProbeComplete -Content $ProbeContent) { return $false }
    return $true
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

        [string] $MirrorDir,

        [string] $ProbeFileName = 'micpe-probe.txt',

        # Which firmware to boot: auto prefers UEFI (OVMF) when it is
        # installed, because the build packs efisys_noprompt.bin as the EFI
        # El Torito image, so the UEFI path has no "Press any key" prompt
        # at all; uefi requires OVMF and fails fast when it is missing;
        # bios forces SeaBIOS + sendkey.
        [ValidateSet('auto', 'uefi', 'bios')]
        [string] $Firmware = 'auto',

        # Seconds after QEMU starts before answering the "Press any key to
        # boot from CD or DVD..." prompt, the interval between presses,
        # and how many times to press in total. User decision 2026-11-17:
        # the prompt times out after about 10 seconds, so press every 3
        # seconds, 4 times -- instead of the old every-30-seconds-forever
        # rhythm (runs 43951915833/43965120455 sent dozens of keys over
        # 45 minutes and the guest still never moved). An Enter landing
        # in the PE's cmd prompt is just an empty line. This only matters
        # for the BIOS fallback; the UEFI path has no prompt (the build
        # packs efisys_noprompt.bin), so no key is needed there.
        [int] $BootKeyDelaySec = 15,

        [int] $BootKeyIntervalSec = 3,

        [int] $BootKeyMaxSends = 4
    )

    if (-not (Test-Path -LiteralPath $Iso)) {
        throw [System.InvalidOperationException]::new("ISO not found: $Iso")
    }
    if (-not (Test-Path -LiteralPath $ShareDir)) {
        New-Item -ItemType Directory -Path $ShareDir -Force | Out-Null
    }
    if ($MirrorDir) {
        if (-not (Test-Path -LiteralPath $MirrorDir)) {
            New-Item -ItemType Directory -Path $MirrorDir -Force | Out-Null
        }
        # Sentinel: the probe finds the mirror drive by this file, not
        # by letter, so a letter shift cannot misidentify it.
        Set-Content -LiteralPath (Join-Path $MirrorDir 'micpe-mirror.txt') -Value 'MICPE mirror drive' -Encoding ascii
    }
    if ($ScreenshotDir -and -not (Test-Path -LiteralPath $ScreenshotDir)) {
        New-Item -ItemType Directory -Path $ScreenshotDir -Force | Out-Null
    }

    $probePath = Join-Path $ShareDir $ProbeFileName
    if (Test-Path -LiteralPath $probePath) {
        Remove-Item -LiteralPath $probePath -Force
    }

    # Run 48: the probe's local copy and the watchdog heartbeat live in
    # the same share directory. A stale copy from a previous run in
    # this directory would fake completion, so both are removed here
    # alongside the probe file itself.
    $probeLocalPath = Join-Path $ShareDir 'micpe-probe-local.txt'
    $heartbeatPath = Join-Path $ShareDir 'micpe-watchdog-heartbeat.txt'
    foreach ($stale in @($probeLocalPath, $heartbeatPath)) {
        if (Test-Path -LiteralPath $stale) {
            Remove-Item -LiteralPath $stale -Force
        }
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

    # pflash boot needs a writable NVRAM store next to the read-only code
    # image. The vars template lives next to the code file (Find-OvmfVars);
    # copy it per run into the work dir instead of letting QEMU write into
    # the install directory. Without a vars drive the split OVMF image
    # cannot boot at all -- -bios already proved that in run 43989280052.
    $FirmwareVarsPath = $null
    if ($FirmwarePath -and $Firmware -ne 'bios') {
        $varsTemplate = Find-OvmfVars -CodePath $FirmwarePath
        if ($varsTemplate) {
            $FirmwareVarsPath = Join-Path (Split-Path -Parent $ShareDir) 'edk2-x86_64-vars.fd'
            Copy-Item -LiteralPath $varsTemplate -Destination $FirmwareVarsPath -Force
            Write-Host "    firmware vars: $FirmwareVarsPath"
        }
        elseif ($Firmware -eq 'uefi') {
            throw [System.InvalidOperationException]::new("Firmware=uefi but no OVMF vars template (edk2-i386-vars.fd) was found next to $FirmwarePath")
        }
        else {
            Write-Host '    firmware: no OVMF vars template, falling back to SeaBIOS'
            $FirmwarePath = $null
        }
    }

    $qemuArgs = Get-QemuArgs -Iso $Iso -ShareDir $ShareDir -MonitorPort $MonitorPort `
        -MemoryMb $MemoryMb -CpuCount $CpuCount -LogPath $LogPath `
        -FirmwarePath $FirmwarePath -FirmwareVarsPath $FirmwareVarsPath -DataDisks $DataDisks `
        -MirrorDir $MirrorDir

    Write-Host "==> starting qemu (timeout ${TimeoutMin}m)"
    $qemuArgString = ConvertTo-NativeArgumentString -Arguments $qemuArgs
    Write-Host "    $QemuPath $qemuArgString"

    $process = Start-Process -FilePath $QemuPath -ArgumentList $qemuArgString -PassThru -NoNewWindow
    # Run 47 (mirror): log what QEMU actually attached, once, right
    # after start — before the guest has any chance to enumerate.
    Save-QemuBlockInfo -Port $MonitorPort
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    $shotIndex = 0
    $prevShotHash = $null
    $prevProbeLength = -1
    $prevHeartbeatLength = -1
    $nextShotAt = (Get-Date).AddMinutes(10)
    $bootKeyAt = (Get-Date).AddSeconds($BootKeyDelaySec)
    $bootKeysSent = 0
    $probe = @{}
    $probeLocal = $null
    # Run 54: set when probe_done is first seen; the host then waits
    # up to $ScStartWaitSec more for the sc start experiment
    # (scstart_done=1) before ending the run, see Test-ProbeWaitDone.
    $probeDoneAt = $null

    try {
        while ((Get-Date) -lt $deadline) {
            if ($process.HasExited) {
                Write-Host "!!! qemu exited early with code $($process.ExitCode)"
                break
            }

            # Answer the "Press any key to boot from CD or DVD..." prompt:
            # every 3 seconds, at most 4 times (user decision 2026-11-17:
            # the prompt times out after about 10 seconds). A single early
            # press can land before the prompt is even displayed
            # (run 43939552552), so the burst is short and early rather
            # than one press.
            if ((Get-Date) -ge $bootKeyAt -and $bootKeysSent -lt $BootKeyMaxSends `
                    -and -not (Test-Path -LiteralPath $probePath)) {
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
                if (Test-ProbeComplete -Content $probe) {
                    # Run 54: probe_done is not the end any more — the
                    # sc start experiment runs after it. Record when it
                    # was first seen and end the wait only when the
                    # experiment is done, failed, or out of time.
                    if ($null -eq $probeDoneAt) { $probeDoneAt = Get-Date }
                    if (Test-ProbeWaitDone -ShareContent $probe -LocalContent $probeLocal -ProbeDoneAt $probeDoneAt) {
                        Start-Sleep -Seconds 5
                        break
                    }
                }
            }

            # Run 48: the local copy is the second completion signal.
            # Run 47's share file stopped at 12:43:48 while the guest
            # kept writing to 12:45:18 — the local copy held payload=1
            # and brand=1, and probe_done lands there first now.
            if (Test-Path -LiteralPath $probeLocalPath) {
                $probeLocal = Get-Content -LiteralPath $probeLocalPath -Raw -ErrorAction SilentlyContinue
                if (Test-ProbeComplete -Content $probeLocal) {
                    # Run 54: same second-marker wait as the share
                    # file above — the experiment marker lands in the
                    # local copy (fifth sync), not the share probe.
                    if ($null -eq $probeDoneAt) { $probeDoneAt = Get-Date }
                    if (Test-ProbeWaitDone -ShareContent $probe -LocalContent $probeLocal -ProbeDoneAt $probeDoneAt) {
                        Start-Sleep -Seconds 5
                        break
                    }
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

                # Freeze detection (run 44386689307): the guest froze
                # with the screen and the probe both silent, and the
                # harness still waited out the full 45 minutes. Two
                # consecutive byte-identical screenshots plus a probe
                # file that has not grown since the last shot is a
                # frozen guest — fail early instead of waiting.
                # $probe is a hashtable until the first read, so only
                # a string counts as probe text here.
                # Run 48: the growth check reads the longer of the
                # share probe and the local copy (run 47: the share
                # view stalled while the guest kept writing), and a
                # growing watchdog heartbeat vetoes the verdict — a
                # ticking watchdog means the guest is alive even when
                # both probe views look still.
                $shotPath = Join-Path $ScreenshotDir ("shot-{0:d2}.ppm" -f $shotIndex)
                if (Test-Path -LiteralPath $shotPath) {
                    $probeText = if ($probe -is [string]) { $probe } else { '' }
                    $probeLength = if ($probe -is [string]) { $probe.Length } else { 0 }
                    if ($probeLocal -is [string] -and $probeLocal.Length -gt $probeLength) {
                        $probeText = $probeLocal
                        $probeLength = $probeLocal.Length
                    }
                    $heartbeatExists = Test-Path -LiteralPath $heartbeatPath
                    $heartbeatLength = if ($heartbeatExists) { (Get-Item -LiteralPath $heartbeatPath).Length } else { -1 }
                    $shotHash = (Get-FileHash -LiteralPath $shotPath -Algorithm MD5).Hash
                    if (Test-ScreenshotFrozen -PreviousHash $prevShotHash -CurrentHash $shotHash `
                            -PreviousProbeLength $prevProbeLength -CurrentProbeLength $probeLength `
                            -ProbeExists (Test-Path -LiteralPath $probePath) -ProbeContent $probeText `
                            -PreviousHeartbeatLength $prevHeartbeatLength -CurrentHeartbeatLength $heartbeatLength `
                            -HeartbeatExists $heartbeatExists) {
                        Write-Host '!!! screenshot frozen and probe silent: the guest appears wedged, failing early instead of waiting out the timeout'
                        break
                    }
                    $prevShotHash = $shotHash
                    $prevProbeLength = $probeLength
                    $prevHeartbeatLength = $heartbeatLength
                }
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
                # Discard the reply: a bare call leaks the response string
                # into Invoke-QemuVerify's return value (same trap as
                # Save-QemuScreenshot above; run 44046530462).
                $null = Invoke-MonitorCommand -Port $MonitorPort -Command 'quit' -ReadDelayMs 200
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

    # Run 48: the local copy is read after QEMU exits, same as the
    # share probe — a clean guest shutdown flushes the vvfat share,
    # so this is the freshest copy the host will ever see. Test-Stage
    # merges the two (see Merge-ProbeFiles): neither file alone holds
    # every key — the share file has the early share-only keys, the
    # local copy has the late keys a stalled host view never saw.
    $localContent = if (Test-Path -LiteralPath $probeLocalPath) {
        Get-Content -LiteralPath $probeLocalPath -Raw
    }
    else { $null }

    return [pscustomobject]@{
        ProbePath   = $probePath
        ProbeText   = $content
        ProbeSeen   = ($null -ne $content)
        ProbeLocalPath = $probeLocalPath
        ProbeLocalText = $localContent
        LocalProbeSeen = ($null -ne $localContent)
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

    # A leaked monitor reply (or any other stray pipeline output) can turn
    # $result into an Object[] instead of the single result object; read
    # .ProbeSeen only when the result is actually the object we expect,
    # otherwise report a clean probe timeout (run 44046530462).
    if ($null -ne $result -and $result -is [pscustomobject] -and $result.ProbeSeen) {
        Write-Host '==> probe received:'
        Write-Host $result.ProbeText
    }
    else {
        Write-Host '!!! no probe file was written by the PE'
        exit 2
    }
}
