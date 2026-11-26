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

    # Crash-dump capture (round 21): a second disk the blue screen writes
    # its DedicatedDumpFile to, so the host can read the 0x5A bugcheck
    # parameters after QEMU exits. The disk is an NTFS volume (the
    # dedicated file is auto-sized to RAM + 256 MB); it is attached as
    # ide index 0 (primary master, enumerated before the CD-ROM) so
    # WinPE gives it C:.
    [int] $DumpDiskSizeMb = 8192,

    [switch] $NoCrashDumpDisk,

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

        [switch] $ReadResponse,

        # Round 23: wait for the next '(qemu)' prompt instead of
        # returning after the first 2 s read gap. Long monitor commands
        # (dump-guest-memory of 4 GB of RAM) print nothing until they
        # finish, so the default read would return after ~3 s while QEMU
        # is still writing the dump. When this is set, the banner prompt
        # is drained first, the command is sent, and the read loop keeps
        # going until the completion prompt arrives or the deadline
        # passes. The default (0) keeps the old fire-and-forget
        # behaviour for every existing caller.
        [int] $WaitForPromptSec = 0
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    $response = ''
    try {
        $client.Connect('127.0.0.1', [int] $Port)
        $stream = $client.GetStream()
        $writer = [System.IO.StreamWriter]::new($stream)
        $writer.AutoFlush = $true
        if ($WaitForPromptSec -gt 0) {
            # Drain the banner: the monitor prints its greeting plus a
            # '(qemu)' prompt on connect. Wait for that first prompt so
            # the prompt we wait for after the command is the command's
            # own completion prompt, not the banner.
            $null = Read-CleanMonitorUntilPrompt -Stream $stream -TimeoutSec 15
            $writer.WriteLine($Command)
            $response = Read-CleanMonitorUntilPrompt -Stream $stream -TimeoutSec $WaitForPromptSec
        }
        else {
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
    }
    finally {
        $client.Dispose()
    }
    return $response
}

function Read-CleanMonitorUntilPrompt {
    # Reads a QEMU human-monitor stream until the '(qemu)' prompt
    # appears or the deadline passes. Reads raw bytes (not a
    # StreamReader: a read timeout on a StreamReader can leave buffered
    # data behind, and a long command prints nothing for minutes, so
    # every read times out until the prompt finally arrives). Returns
    # the accumulated text (possibly empty when the monitor went away).
    # Pure stream helper; the caller owns the connection. Takes any
    # [System.IO.Stream] (a NetworkStream in production; a MemoryStream
    # in tests) -- only Read() and, when the stream supports it,
    # ReadTimeout are used.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Stream] $Stream,

        [int] $TimeoutSec = 60
    )

    $text = ''
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    if ($Stream.CanTimeout) {
        $Stream.ReadTimeout = 2000
    }
    $buf = [byte[]]::new(4096)
    while ((Get-Date) -lt $deadline) {
        try {
            $n = $Stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $text += [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
            # Match on the accumulated text: the prompt can straddle a
            # TCP segment boundary, so a per-chunk match would miss it.
            if ($text -match '\(qemu\)') { break }
        }
        catch [System.IO.IOException] {
            # Read timeout: nothing arrived yet, keep waiting until the
            # deadline. The monitor prints nothing while a long command
            # runs, so a timeout is the normal case here, not a failure.
        }
    }
    return $text
}

function Invoke-CleanGuestMemoryDump {
    # Round 23: capture a guest-memory dump through the QEMU monitor
    # while the guest is still halted on the blue screen. This is the
    # alternative parameter source for when the guest never wrote a
    # dedicated dump file to the second disk (round 22: the retained
    # .vhd held only a freshly formatted empty NTFS volume).
    #
    # Why plain ELF, not `dump-guest-memory -w` (win-dmp): the -w form
    # needs a vmcoreinfo device on the QEMU side AND the FwCfg driver
    # in the guest, and it fails with "invalid vmcoreinfo note size"
    # when the guest driver is not running yet -- exactly the early
    # boot stage our 0x5A fires in. The plain ELF dump needs no guest
    # cooperation at all: QEMU just snapshots physical memory plus the
    # per-CPU register notes, and the host-side Rizin scan
    # (Invoke-CleanElfBugCheckScan) reads the bugcheck parameters out
    # of it afterwards. Runs only on the Windows runner (QEMU monitor
    # + guest RAM); the caller wraps it so a failure here never fails
    # the verify. Returns $true when the dump file exists, is non-empty
    # and its size stopped growing; $false otherwise. Never throws.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Port,

        [Parameter(Mandatory = $true)]
        [string] $ElfPath,

        # Total time to wait for the monitor command and the file.
        # A 4 GB dump takes a minute or two to write on the runner.
        [int] $WaitSec = 600,

        # The file must hold the same size across this many seconds
        # before it counts as finished (the monitor prompt is the
        # primary signal; this is the belt-and-braces check in case the
        # prompt was missed or the connection dropped mid-dump).
        [int] $StableSec = 10
    )

    try {
        # The monitor parses backslashes as escapes, so the Windows
        # path goes through the same forward-slash conversion as the
        # screendump paths (a bare 'D:\a\...' dies on '\a').
        $monitorPath = ConvertTo-CleanMonitorPath -Path $ElfPath
        Write-Host "dumping guest memory to $ElfPath (monitor: dump-guest-memory)"
        $reply = Invoke-CleanMonitorCommand -Port $Port `
            -Command "dump-guest-memory `"$monitorPath`"" -WaitForPromptSec $WaitSec
        if ($reply) {
            $flat = ($reply -replace "`r`n|`n", ' | ').Trim()
            if ($flat.Length -gt 300) { $flat = $flat.Substring(0, 300) + '...' }
            Write-Host "  guest-memory dump monitor reply: $flat"
        }
        else {
            Write-Host '  guest-memory dump monitor reply was empty (the file poll below decides)'
        }
    }
    catch {
        Write-Host "!!! guest-memory dump monitor command failed: $($_.Exception.Message)"
        return $false
    }
    $deadline = (Get-Date).AddSeconds($WaitSec)
    $lastSize = -1
    $stableSince = $null
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $ElfPath) {
            $size = (Get-Item -LiteralPath $ElfPath).Length
            if ($size -gt 0 -and $size -eq $lastSize) {
                if ($null -eq $stableSince) { $stableSince = Get-Date }
                if (((Get-Date) - $stableSince).TotalSeconds -ge $StableSec) {
                    Write-Host ("guest-memory dump finished: {0:N0} bytes at {1}" -f $size, $ElfPath)
                    return $true
                }
            }
            else {
                $lastSize = $size
                $stableSince = $null
            }
        }
        Start-Sleep -Seconds 5
    }
    Write-Host "!!! guest-memory dump did not finish within ${WaitSec}s (last size ${lastSize})"
    return $false
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

function Find-CleanFreeDriveLetter {
    # First free drive letter from the candidate list, for attaching the
    # crash-dump disk on the runner. Pure (the used letters are passed
    # in) so it is unit-testable without a Windows host.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $UsedLetters
    )

    $usedUpper = @($UsedLetters | ForEach-Object { $_.ToUpperInvariant() })
    foreach ($letter in @('Z', 'Y', 'X', 'W', 'V', 'U', 'T')) {
        if ($usedUpper -notcontains $letter) { return $letter }
    }
    return $null
}

function New-CleanDiskpartScript {
    # diskpart script that creates a VHDX, attaches it, partitions it and
    # quick-formats it NTFS. Pure text builder (diskpart itself only runs
    # on the Windows runner), so it is unit-testable.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $VhdxPath,

        [int] $SizeMb = 8192,

        [Parameter(Mandatory = $true)]
        [string] $Letter
    )

    return @(
        "create vdisk file=`"$VhdxPath`" maximum=$SizeMb type=expandable"
        "select vdisk file=`"$VhdxPath`""
        'attach vdisk'
        'create partition primary'
        'format fs=ntfs quick'
        "assign letter=$Letter"
    ) -join "`n"
}

function New-CleanDiskpartAttachScript {
    # diskpart script that attaches an existing VHD/VHDX and assigns a
    # drive letter to its volume. Round 22 lesson: `assign` works on
    # the VOLUME with focus, not on the disk -- after `attach vdisk`
    # the disk is selected but no volume is, so a bare `assign` fails
    # with "There is no volume selected" and the drive letter never
    # appears (round 21: "crash-dump disk attached but drive Z: never
    # appeared"). `select partition 1` focuses the volume first. The
    # disk was created with exactly one primary partition, so
    # partition 1 is the volume. Pure text builder (diskpart itself
    # only runs on the Windows runner), so it is unit-testable.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DiskPath,

        [Parameter(Mandatory = $true)]
        [string] $Letter
    )

    return @(
        "select vdisk file=`"$DiskPath`""
        'attach vdisk'
        'select partition 1'
        "assign letter=$Letter"
    ) -join "`n"
}

function Get-CleanQemuImgPath {
    # qemu-img sits next to qemu-system-x86_64. The parent is parsed by
    # hand: Split-Path/Join-Path are platform-specific (on the Linux test
    # host Split-Path rewrites a Windows path to forward slashes and
    # Join-Path throws DriveNotFoundException on 'C:'), while this only
    # ever runs on the Windows runner. The separator found is kept.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $QemuPath
    )

    $bs = $QemuPath.LastIndexOf('\')
    $fs = $QemuPath.LastIndexOf('/')
    $idx = [Math]::Max($bs, $fs)
    if ($idx -ge 0) { return ($QemuPath.Substring(0, $idx) + $QemuPath[$idx] + 'qemu-img.exe') }
    return 'qemu-img'
}

function New-CleanCrashDumpDisk {
    # Round 21: build the second disk the blue screen writes its
    # DedicatedDumpFile to. VHDX via diskpart (partition + NTFS quick
    # format, same pattern as the workflow's "Prepare data disks" step),
    # detached, then converted to qcow2 for QEMU. Returns the qcow2 path.
    # Runs only on the Windows runner (diskpart + qemu-img); the caller
    # wraps it so a failure here never fails the verify -- the dump disk
    # is diagnostic, the screenshots are the evidence.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $WorkDir,

        [int] $SizeMb = 8192,

        [Parameter(Mandatory = $true)]
        [string] $QemuImgPath,

        [string] $DiskName = 'micpe-dumpdisk'
    )

    $vhdx = Join-Path $WorkDir "$DiskName.vhdx"
    $qcow2 = Join-Path $WorkDir "$DiskName.qcow2"
    $used = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $letter = Find-CleanFreeDriveLetter -UsedLetters $used
    if (-not $letter) { throw 'no free drive letter for the crash-dump disk (tried Z Y X W V U T)' }
    $diskpartScript = New-CleanDiskpartScript -VhdxPath $vhdx -SizeMb $SizeMb -Letter $letter
    $diskpartScript | diskpart | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "diskpart failed while creating the crash-dump disk $vhdx" }
    try {
        @("select vdisk file=`"$vhdx`"", 'detach vdisk') -join "`n" | diskpart | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "diskpart failed while detaching the crash-dump disk $vhdx" }
    }
    catch {
        @("select vdisk file=`"$vhdx`"", 'detach vdisk') -join "`n" | diskpart | Out-Null
        throw
    }
    & $QemuImgPath convert -f vhdx -O qcow2 $vhdx $qcow2
    if ($LASTEXITCODE -ne 0) { throw "qemu-img convert failed for the crash-dump disk ($vhdx -> $qcow2)" }
    Remove-Item -LiteralPath $vhdx -Force
    return $qcow2
}

function ConvertFrom-CleanRizinBugCheck {
    # Parses `rizin -d dmp://... -c "i~bugcheck"` output, which looks like:
    #   bugcheck=0x0000005a (CRITICAL_SERVICE_FAILED)
    #   bugcheck.arg1=0x0000000000000001
    #   bugcheck.arg2=0xffff...
    #   bugcheck.arg3=0xffff...
    #   bugcheck.arg4=0xffffffffc0000428
    # Pure parser, unit-testable. Returns $null when no bugcheck line is
    # present (not a dump, or Rizin could not read it).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Output
    )

    $code = $null
    $a1 = $null
    $a2 = $null
    $a3 = $null
    $a4 = $null
    foreach ($line in ($Output -split "`r`n|`n")) {
        if ($line -match 'bugcheck=0x([0-9a-fA-F]+)') { $code = $Matches[1].ToLowerInvariant() }
        elseif ($line -match 'bugcheck\.arg1=0x([0-9a-fA-F]+)') { $a1 = $Matches[1].ToLowerInvariant() }
        elseif ($line -match 'bugcheck\.arg2=0x([0-9a-fA-F]+)') { $a2 = $Matches[1].ToLowerInvariant() }
        elseif ($line -match 'bugcheck\.arg3=0x([0-9a-fA-F]+)') { $a3 = $Matches[1].ToLowerInvariant() }
        elseif ($line -match 'bugcheck\.arg4=0x([0-9a-fA-F]+)') { $a4 = $Matches[1].ToLowerInvariant() }
    }
    if ($null -eq $code) { return $null }
    return [pscustomobject]@{
        BugCheckCode = "0x$code"
        Arg1 = if ($null -ne $a1) { "0x$a1" } else { $null }
        Arg2 = if ($null -ne $a2) { "0x$a2" } else { $null }
        Arg3 = if ($null -ne $a3) { "0x$a3" } else { $null }
        Arg4 = if ($null -ne $a4) { "0x$a4" } else { $null }
    }
}

function Get-CleanRizinPath {
    # Downloads the Rizin static Windows build (self-contained, no
    # installer) into the work dir and returns rizin.exe. Cached: a
    # second call in the same run reuses the extracted copy. Only called
    # when a dump file was actually found, so a clean boot pays nothing.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $WorkDir,

        [string] $Version = 'v0.9.1'
    )

    $toolsDir = Join-Path $WorkDir 'tools'
    $rizinDir = Join-Path $toolsDir "rizin-$Version"
    $found = @(Get-ChildItem -LiteralPath $rizinDir -Recurse -Filter 'rizin.exe' -ErrorAction SilentlyContinue)
    if ($found.Count -gt 0) { return $found[0].FullName }
    $zip = Join-Path $toolsDir "rizin-windows-static-$Version.zip"
    if (-not (Test-Path -LiteralPath $zip)) {
        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
        $url = "https://github.com/rizinorg/rizin/releases/download/$Version/rizin-windows-static-$Version.zip"
        Write-Host "downloading Rizin $Version (static Windows build): $url"
        Invoke-WebRequest -Uri $url -OutFile $zip
    }
    if (-not (Test-Path -LiteralPath $zip) -or (Get-Item -LiteralPath $zip).Length -eq 0) {
        throw "Rizin download failed: $zip is missing or empty"
    }
    New-Item -ItemType Directory -Path $rizinDir -Force | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $rizinDir -Force
    $found = @(Get-ChildItem -LiteralPath $rizinDir -Recurse -Filter 'rizin.exe' -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) { throw "Rizin extracted but rizin.exe not found under $rizinDir" }
    return $found[0].FullName
}

function Invoke-CleanProcessToFile {
    # Runs a process with an EXACT argv and a timeout, writing its
    # stdout/stderr to files. This exists because Start-Process
    # -ArgumentList splits arguments on spaces on Linux: a Rizin -c
    # command such as '/x 4b444247' arrived as two arguments ('/x' and
    # '4b444247'), so Rizin failed with "Wrong number of arguments
    # passed to /x" and the whole ELF scan returned zero hits (found
    # by the round 23 end-to-end test against a synthetic ELF core).
    # ProcessStartInfo.ArgumentList passes each entry as one argv
    # element on Windows and Linux, with no shell involved. The async
    # readers drain both pipes while the process runs, so a large
    # output cannot deadlock on a full pipe buffer. Returns
    # @{ ExitCode }. Throws only on timeout; the caller decides what
    # a non-zero exit means.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [Parameter(Mandatory = $true)]
        [string[]] $ArgumentList,

        [Parameter(Mandatory = $true)]
        [string] $OutFile,

        [Parameter(Mandatory = $true)]
        [string] $ErrFile,

        [int] $TimeoutSec = 300
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($a in $ArgumentList) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $null = $proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch {}
        throw "process timed out after $TimeoutSec s ($FilePath $($ArgumentList -join ' '))"
    }
    # The process has exited, so the pipes close with it; wait briefly
    # for the async readers to drain before reading the results.
    $null = $outTask.Wait(10000)
    $null = $errTask.Wait(10000)
    $out = if ($outTask.IsCompleted) { $outTask.Result } else { '' }
    $err = if ($errTask.IsCompleted) { $errTask.Result } else { '' }
    [System.IO.File]::WriteAllText($OutFile, $out)
    [System.IO.File]::WriteAllText($ErrFile, $err)
    return [pscustomobject]@{ ExitCode = $proc.ExitCode }
}

function Invoke-CleanRizin {
    # Runs Rizin non-interactively against a crash dump and returns its
    # stdout. Output goes to files (not pipes) so a long listing cannot
    # deadlock on a full pipe buffer; the process is killed at the
    # timeout instead of hanging the step.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RizinPath,

        [Parameter(Mandatory = $true)]
        [string] $DumpFile,

        [Parameter(Mandatory = $true)]
        [string] $Commands,

        [Parameter(Mandatory = $true)]
        [string] $WorkDir,

        [int] $TimeoutSec = 300
    )

    $uri = 'dmp://' + ($DumpFile -replace '\\', '/')
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile = Join-Path $WorkDir "rizin-out-$tag.txt"
    $errFile = Join-Path $WorkDir "rizin-err-$tag.txt"
    $run = Invoke-CleanProcessToFile -FilePath $RizinPath `
        -ArgumentList @('-d', $uri, '-q', '-c', $Commands) `
        -OutFile $outFile -ErrFile $errFile -TimeoutSec $TimeoutSec
    $out = ''
    if (Test-Path -LiteralPath $outFile) { $out = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue }
    if ($run.ExitCode -ne 0) {
        $err = ''
        if (Test-Path -LiteralPath $errFile) { $err = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue }
        Write-Host "!!! Rizin exited $($run.ExitCode) ($Commands): $err"
    }
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    return ($out -as [string])
}

function Invoke-CleanRizinFile {
    # Round 23: runs Rizin non-interactively against a plain file
    # (the QEMU ELF guest-memory dump), not a dmp:// crash dump.
    # Same shape as Invoke-CleanRizin (output to files, killed at the
    # timeout) so a huge search result cannot deadlock on a full pipe
    # buffer. Returns Rizin's stdout as a string (possibly empty).
    # Never throws for a Rizin failure: a non-zero exit is logged and
    # the (possibly partial) output is returned; the caller decides
    # what the output means.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RizinPath,

        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [Parameter(Mandatory = $true)]
        [string] $Commands,

        [Parameter(Mandatory = $true)]
        [string] $WorkDir,

        [int] $TimeoutSec = 600
    )

    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile = Join-Path $WorkDir "rizin-file-out-$tag.txt"
    $errFile = Join-Path $WorkDir "rizin-file-err-$tag.txt"
    $run = Invoke-CleanProcessToFile -FilePath $RizinPath `
        -ArgumentList @('-q', '-c', $Commands, $FilePath) `
        -OutFile $outFile -ErrFile $errFile -TimeoutSec $TimeoutSec
    $out = ''
    if (Test-Path -LiteralPath $outFile) { $out = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue }
    if ($run.ExitCode -ne 0) {
        $err = ''
        if (Test-Path -LiteralPath $errFile) { $err = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue }
        Write-Host "!!! Rizin exited $($run.ExitCode) ($Commands): $err"
    }
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    return ($out -as [string])
}

function ConvertFrom-CleanRizinSearchHits {
    # Parses Rizin `/x <hex>` search output into the hit addresses.
    # Real output (Rizin 0.9.1, verified against a synthetic ELF core):
    #   0x00102010 4 hit.bytes.0
    #   0x00108010 4 hit.bytes.1
    # The line is prefixed by an ANSI erase-line escape when the search
    # runs under -q, so the match is anchored on the address, not on
    # the line start. Pure parser, unit-testable. Returns @() when
    # nothing hit (an empty search prints nothing).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Output
    )

    $hits = @()
    $clean = ($Output -replace "`e\[[0-9;]*[A-Za-z]", '')
    foreach ($line in ($clean -split "`r`n|`n")) {
        $m = [regex]::Match($line, '0x([0-9a-fA-F]+)\s+\d+\s+hit\.')
        if ($m.Success) { $hits += [Convert]::ToUInt64($m.Groups[1].Value, 16) }
    }
    return $hits
}

function ConvertFrom-CleanRizinValues {
    # Parses Rizin `pv8` / `pv4` output into the values, one per line:
    #   0x000000000000005a
    #   0xffffba8f4e9f8c50
    # Pure parser, unit-testable. Lines that are not a bare hex value
    # (warnings, blank lines) are skipped, so the caller can pass a
    # whole multi-command output through and get the values in order.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Output
    )

    $values = @()
    $clean = ($Output -replace "`e\[[0-9;]*[A-Za-z]", '')
    foreach ($line in ($clean -split "`r`n|`n")) {
        $t = $line.Trim()
        if ($t -match '^0x([0-9a-fA-F]+)$') { $values += [Convert]::ToUInt64($Matches[1], 16) }
    }
    return $values
}

function Test-CleanBugCheckCandidate {
    # Validates one 5-qword candidate read out of guest memory at a
    # /x hit: { BugCheckCode, Arg1, Arg2, Arg3, Arg4 }. The search
    # already fixed the code (and Arg1 for the strict search); this
    # checks the parts the search could not constrain:
    #   Arg2/Arg3 must be canonical kernel addresses (the high half,
    #   0xFFFF800000000000 and up -- user-mode and low addresses are
    #   not UNICODE_STRING pointers in the kernel);
    #   Arg4 must look like an NTSTATUS: the low 32 bits start with
    #   0xC (0xC0000428, 0xC0E90002, ... -- the 64-bit examples are
    #   sign-extended, so the low half is what matters) or it is a
    #   small value. Returns a result object @{ Valid; Reason }.
    # Pure function, unit-testable.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [UInt64] $Code,

        [Parameter(Mandatory = $true)]
        [UInt64] $Arg1,

        [Parameter(Mandatory = $true)]
        [UInt64] $Arg2,

        [Parameter(Mandatory = $true)]
        [UInt64] $Arg3,

        [Parameter(Mandatory = $true)]
        [UInt64] $Arg4
    )

    # NOTE: do NOT write [UInt64]0xFFFF800000000000 -- PowerShell
    # parses that literal as a NEGATIVE Int64 and the cast to UInt64
    # throws OverflowException. Parse the hex text instead.
    $kernelFloor = [Convert]::ToUInt64('ffff800000000000', 16)
    if ($Code -ne 0x5A) { return [pscustomobject]@{ Valid = $false; Reason = 'code is not 0x5A' } }
    if ($Arg1 -gt 0x10000) { return [pscustomobject]@{ Valid = $false; Reason = 'Arg1 is not a small value' } }
    if ($Arg2 -lt $kernelFloor) { return [pscustomobject]@{ Valid = $false; Reason = 'Arg2 is not a canonical kernel address' } }
    if ($Arg3 -lt $kernelFloor) { return [pscustomobject]@{ Valid = $false; Reason = 'Arg3 is not a canonical kernel address' } }
    $low32 = ($Arg4 -band [Convert]::ToUInt64('ffffffff', 16))
    $isNtStatus = ((($low32 -band [Convert]::ToUInt64('f0000000', 16)) -eq [Convert]::ToUInt64('c0000000', 16)) -or ($low32 -lt 0x10000))
    if (-not $isNtStatus) { return [pscustomobject]@{ Valid = $false; Reason = 'Arg4 does not look like an NTSTATUS' } }
    return [pscustomobject]@{ Valid = $true; Reason = 'candidate accepted' }
}

function Test-CleanKdbgCandidate {
    # Validates one KDBG hit: the Size field (at block+0x14, read via
    # pv4 at hit+0x4) must be a plausible _KDDEBUGGER_DATA64 size, and
    # KernBase (at block+0x38, read via pv8 at hit+0x28) must be a
    # canonical kernel address. The hit itself is the OwnerTag 'KDBG'
    # at block+0x10, so the block starts at hit-0x10. Returns
    # @{ Valid; Reason }. Pure function, unit-testable.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [UInt64] $Size,

        [Parameter(Mandatory = $true)]
        [UInt64] $KernBase
    )

    # NOTE: do NOT write [UInt64]0xFFFF800000000000 -- PowerShell
    # parses that literal as a NEGATIVE Int64 and the cast to UInt64
    # throws OverflowException. Parse the hex text instead.
    $kernelFloor = [Convert]::ToUInt64('ffff800000000000', 16)
    if ($Size -lt 0x100 -or $Size -gt 0x1000) { return [pscustomobject]@{ Valid = $false; Reason = 'Size is not a plausible KDBG size' } }
    if ($KernBase -lt $kernelFloor) { return [pscustomobject]@{ Valid = $false; Reason = 'KernBase is not a canonical kernel address' } }
    return [pscustomobject]@{ Valid = $true; Reason = 'KDBG accepted' }
}

function Invoke-CleanElfBugCheckScan {
    # Round 23: reads the 0x5A bugcheck parameters out of a QEMU ELF
    # guest-memory dump with Rizin, without needing the guest to have
    # written a dump file at all. Two searches, both verified against
    # a synthetic ELF core with Rizin 0.9.1:
    #   KDBG:  /x 4b444247 ('KDBG' OwnerTag) -> KernBase at hit+0x28
    #          (block+0x38) and Size at hit+0x4 (block+0x14). A valid
    #          KDBG proves the ELF really is Windows memory and gives
    #          the kernel base as evidence; it is not a gate.
    #   strict: /x 5a000000000000000100000000000000 (the 16-byte
    #          prefix { code 0x5A, Arg1 1 }) -> 5 qwords at each hit,
    #          validated by Test-CleanBugCheckCandidate.
    #   loose (only when strict found nothing):
    #          /x 5a00000000000000 (the code alone) -> first hits,
    #          validated the same way; labelled unconfirmed because
    #          Arg1 was not constrained to 1.
    # The Rizin /x output is parsed by ConvertFrom-CleanRizinSearchHits
    # and the qwords by ConvertFrom-CleanRizinValues; the reads for all
    # hits go in ONE Rizin call each (a fresh Rizin on a 4 GB dump
    # costs seconds per start). Appends every finding to $Lines and
    # returns @{ BugCheck; KernBase; Candidates }. Never throws: a
    # scan failure is itself a finding (logged, not thrown).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RizinPath,

        [Parameter(Mandatory = $true)]
        [string] $ElfPath,

        [Parameter(Mandatory = $true)]
        [string] $WorkDir,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]] $Lines
    )

    $result = [pscustomobject]@{ BugCheck = $null; KernBase = $null; Candidates = @() }
    if (-not (Test-Path -LiteralPath $ElfPath)) {
        $Lines.Add('ELF memory scan skipped: no guest-memory dump file was captured')
        return $result
    }
    $elfSize = (Get-Item -LiteralPath $ElfPath).Length
    $Lines.Add(('ELF memory scan: {0} ({1:N0} bytes)' -f $ElfPath, $elfSize))
    try {
        # --- KDBG: prove the ELF is Windows memory, get the kernel base.
        $kdbgOut = Invoke-CleanRizinFile -RizinPath $RizinPath -FilePath $ElfPath `
            -Commands '/x 4b444247' -WorkDir $WorkDir
        $kdbgHits = @(ConvertFrom-CleanRizinSearchHits -Output $kdbgOut)
        $Lines.Add(('KDBG search: {0} hit(s)' -f $kdbgHits.Count))
        if ($kdbgHits.Count -gt 0) {
            $take = [Math]::Min(10, $kdbgHits.Count)
            $reads = [System.Collections.Generic.List[string]]::new()
            for ($i = 0; $i -lt $take; $i++) {
                $hit = $kdbgHits[$i]
                $reads.Add(('pv4 @ 0x{0:x}' -f ($hit + 4)))
                $reads.Add(('pv8 @ 0x{0:x}' -f ($hit + 0x28)))
            }
            $vals = @(ConvertFrom-CleanRizinValues -Output (Invoke-CleanRizinFile -RizinPath $RizinPath `
                -FilePath $ElfPath -Commands ($reads -join '; ') -WorkDir $WorkDir))
            for ($i = 0; $i -lt $take; $i++) {
                if ((2 * $i + 1) -ge $vals.Count) { break }
                $check = Test-CleanKdbgCandidate -Size $vals[2 * $i] -KernBase $vals[2 * $i + 1]
                if ($check.Valid) {
                    $result.KernBase = $vals[2 * $i + 1]
                    $Lines.Add(('KDBG accepted at 0x{0:x}: Size=0x{1:x} KernBase=0x{2:x}' -f $kdbgHits[$i], $vals[2 * $i], $vals[2 * $i + 1]))
                    break
                }
                else {
                    $Lines.Add(('KDBG hit at 0x{0:x} rejected: {1}' -f $kdbgHits[$i], $check.Reason))
                }
            }
            if ($null -eq $result.KernBase) { $Lines.Add('KDBG: no hit validated (KernBase unknown)') }
        }

        # --- strict pattern: { code 0x5A, Arg1 1 } then two pointers + NTSTATUS.
        $strictOut = Invoke-CleanRizinFile -RizinPath $RizinPath -FilePath $ElfPath `
            -Commands '/x 5a000000000000000100000000000000' -WorkDir $WorkDir
        $strictHits = @(ConvertFrom-CleanRizinSearchHits -Output $strictOut)
        $Lines.Add(('strict KiBugCheckData search: {0} hit(s)' -f $strictHits.Count))
        $candidates = [System.Collections.Generic.List[pscustomobject]]::new()
        if ($strictHits.Count -gt 0) {
            $take = [Math]::Min(20, $strictHits.Count)
            $reads = [System.Collections.Generic.List[string]]::new()
            for ($i = 0; $i -lt $take; $i++) {
                foreach ($off in @(0, 8, 16, 24, 32)) {
                    $reads.Add(('pv8 @ 0x{0:x}' -f ($strictHits[$i] + $off)))
                }
            }
            $vals = @(ConvertFrom-CleanRizinValues -Output (Invoke-CleanRizinFile -RizinPath $RizinPath `
                -FilePath $ElfPath -Commands ($reads -join '; ') -WorkDir $WorkDir))
            for ($i = 0; $i -lt $take; $i++) {
                if ((5 * $i + 4) -ge $vals.Count) { break }
                $check = Test-CleanBugCheckCandidate -Code $vals[5 * $i] -Arg1 $vals[5 * $i + 1] `
                    -Arg2 $vals[5 * $i + 2] -Arg3 $vals[5 * $i + 3] -Arg4 $vals[5 * $i + 4]
                $cand = [pscustomobject]@{
                    Address = $strictHits[$i]
                    Code    = ('0x{0:x}' -f $vals[5 * $i])
                    Arg1    = ('0x{0:x}' -f $vals[5 * $i + 1])
                    Arg2    = ('0x{0:x}' -f $vals[5 * $i + 2])
                    Arg3    = ('0x{0:x}' -f $vals[5 * $i + 3])
                    Arg4    = ('0x{0:x}' -f $vals[5 * $i + 4])
                    Valid   = $check.Valid
                    Reason  = $check.Reason
                    Strict  = $true
                }
                $candidates.Add($cand)
                if ($check.Valid) {
                    $Lines.Add(('RESULT: BugCheckCode={0} Arg1={1} Arg2={2} Arg3={3} Arg4={4} (from guest memory at 0x{5:x})' -f $cand.Code, $cand.Arg1, $cand.Arg2, $cand.Arg3, $cand.Arg4, $cand.Address))
                }
                else {
                    $Lines.Add(('strict candidate at 0x{0:x} rejected: {1}' -f $cand.Address, $check.Reason))
                }
            }
        }
        $confirmed = @($candidates | Where-Object { $_.Valid })
        if ($confirmed.Count -eq 0) {
            # --- loose pattern: the code alone. Arg1 was not
            # constrained, so anything found here is unconfirmed
            # (a stale stack copy would carry the same values, which
            # is corroboration rather than a false positive, but the
            # label stays honest).
            $looseOut = Invoke-CleanRizinFile -RizinPath $RizinPath -FilePath $ElfPath `
                -Commands '/x 5a00000000000000' -WorkDir $WorkDir
            $looseHits = @(ConvertFrom-CleanRizinSearchHits -Output $looseOut)
            $Lines.Add(('loose KiBugCheckData search: {0} hit(s)' -f $looseHits.Count))
            if ($looseHits.Count -gt 0) {
                $take = [Math]::Min(10, $looseHits.Count)
                $reads = [System.Collections.Generic.List[string]]::new()
                for ($i = 0; $i -lt $take; $i++) {
                    foreach ($off in @(0, 8, 16, 24, 32)) {
                        $reads.Add(('pv8 @ 0x{0:x}' -f ($looseHits[$i] + $off)))
                    }
                }
                $vals = @(ConvertFrom-CleanRizinValues -Output (Invoke-CleanRizinFile -RizinPath $RizinPath `
                    -FilePath $ElfPath -Commands ($reads -join '; ') -WorkDir $WorkDir))
                for ($i = 0; $i -lt $take; $i++) {
                    if ((5 * $i + 4) -ge $vals.Count) { break }
                    $check = Test-CleanBugCheckCandidate -Code $vals[5 * $i] -Arg1 $vals[5 * $i + 1] `
                        -Arg2 $vals[5 * $i + 2] -Arg3 $vals[5 * $i + 3] -Arg4 $vals[5 * $i + 4]
                    $cand = [pscustomobject]@{
                        Address = $looseHits[$i]
                        Code    = ('0x{0:x}' -f $vals[5 * $i])
                        Arg1    = ('0x{0:x}' -f $vals[5 * $i + 1])
                        Arg2    = ('0x{0:x}' -f $vals[5 * $i + 2])
                        Arg3    = ('0x{0:x}' -f $vals[5 * $i + 3])
                        Arg4    = ('0x{0:x}' -f $vals[5 * $i + 4])
                        Valid   = $check.Valid
                        Reason  = $check.Reason
                        Strict  = $false
                    }
                    $candidates.Add($cand)
                    if ($check.Valid) {
                        $Lines.Add(('RESULT (loose, unconfirmed): BugCheckCode={0} Arg1={1} Arg2={2} Arg3={3} Arg4={4} (from guest memory at 0x{5:x})' -f $cand.Code, $cand.Arg1, $cand.Arg2, $cand.Arg3, $cand.Arg4, $cand.Address))
                    }
                    else {
                        $Lines.Add(('loose candidate at 0x{0:x} rejected: {1}' -f $cand.Address, $check.Reason))
                    }
                }
            }
        }
        $result.Candidates = $candidates.ToArray()
        $confirmed = @($candidates | Where-Object { $_.Valid })
        if ($confirmed.Count -gt 0) {
            $first = $confirmed[0]
            $result.BugCheck = [pscustomobject]@{
                BugCheckCode = $first.Code
                Arg1 = $first.Arg1
                Arg2 = $first.Arg2
                Arg3 = $first.Arg3
                Arg4 = $first.Arg4
            }
        }
        else {
            $Lines.Add('ELF memory scan: no KiBugCheckData candidate validated (no bugcheck parameters in guest memory)')
        }
    }
    catch {
        $Lines.Add(('ELF memory scan failed: {0}' -f $_.Exception.Message))
    }
    return $result
}

function Add-CleanVolumeList {
    # Appends the volumes visible on the runner to $Lines, so a failed
    # attach says WHAT the runner sees instead of only what it did not
    # see. Round 22 lesson: the round 22 code only listed volumes on
    # the poll-timeout path, so the diskpart-error path (the one round
    # 22 actually hit) wrote no volume listing at all, even though the
    # RESULT line claimed "the diskpart output and volume listing
    # above are the evidence". Every failure path in
    # Invoke-CleanDiskAttach calls this now. Never throws: a listing
    # failure is itself a line.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]] $Lines
    )

    try {
        $vols = @(Get-Volume -ErrorAction Stop | ForEach-Object { '{0}: {1} {2} ({3:N0} bytes)' -f $_.DriveLetter, $_.FileSystemLabel, $_.FileSystem, $_.Size })
        $Lines.Add(('volumes on the runner: {0}' -f ($vols -join '; ')))
    }
    catch {
        $Lines.Add(('attach: could not list volumes: {0}' -f $_.Exception.Message))
    }
}

function Invoke-CleanDiskAttach {
    # Attaches a VHD/VHDX on the runner and waits for its drive
    # letter. Returns a pscustomobject @{ Letter = <letter>;
    # DiskPath = <path> } or $null. Never throws: every failure mode
    # writes its diagnostics into $Lines (diskpart output, the
    # volumes visible on the runner) so micpe-bugcheck.txt says WHY
    # the disk did not come back, instead of one bare "never
    # appeared" line (round 21). A failed attach detaches the disk
    # again so a retry starts clean. Runs only on the Windows runner
    # (diskpart + Get-Volume); the caller wraps it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DiskPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]] $Lines,

        [int] $WaitSec = 30
    )

    $usedBefore = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name.ToUpperInvariant() })
    $letter = Find-CleanFreeDriveLetter -UsedLetters $usedBefore
    if (-not $letter) {
        $Lines.Add('attach: no free drive letter to attach the crash-dump disk (tried Z Y X W V U T)')
        Add-CleanVolumeList -Lines $Lines
        return $null
    }
    $script = New-CleanDiskpartAttachScript -DiskPath $DiskPath -Letter $letter
    $diskpartOut = ''
    try {
        $diskpartOut = ($script | diskpart | Out-String)
    }
    catch {
        $Lines.Add(('attach: diskpart did not run: {0}' -f $_.Exception.Message))
        return $null
    }
    $flatOut = ($diskpartOut -replace "`r`n|`n", ' | ').Trim()
    $Lines.Add(('attach diskpart output: {0}' -f $flatOut))
    if ($LASTEXITCODE -ne 0) {
        $Lines.Add(('attach: diskpart exited {0}' -f $LASTEXITCODE))
    }
    if ($diskpartOut -match 'DiskPart has encountered an error|There is no volume selected|The system cannot find the file|The specified disk is not found|Virtual Disk Service error') {
        $Lines.Add('attach: diskpart reported an error (see output above); detaching and giving up on this image')
        Add-CleanVolumeList -Lines $Lines
        try { @("select vdisk file=`"$DiskPath`"", 'detach vdisk') -join "`n" | diskpart | Out-Null } catch {}
        return $null
    }
    for ($i = 0; $i -lt $WaitSec; $i++) {
        if (Test-Path -LiteralPath "${letter}:\") {
            return [pscustomobject]@{ Letter = $letter; DiskPath = $DiskPath }
        }
        # Windows may have automounted the volume under a different
        # letter (assign raced it, or assign failed but the volume
        # still came up). Any letter that was not there before the
        # attach is this disk; take it rather than failing.
        $usedNow = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name.ToUpperInvariant() })
        $newLetters = @($usedNow | Where-Object { $usedBefore -notcontains $_ })
        if ($newLetters.Count -gt 0) {
            $Lines.Add(('attach: drive {0}: never appeared, but a new letter {1}: showed up after the attach; using it' -f $letter, $newLetters[0]))
            return [pscustomobject]@{ Letter = $newLetters[0]; DiskPath = $DiskPath }
        }
        Start-Sleep -Seconds 1
    }
    $Lines.Add(('attach: drive {0}: never appeared within {1} s' -f $letter, $WaitSec))
    Add-CleanVolumeList -Lines $Lines
    try { @("select vdisk file=`"$DiskPath`"", 'detach vdisk') -join "`n" | diskpart | Out-Null } catch {}
    return $null
}

function ConvertTo-CleanDeSparseDisk {
    # Round 23: converts the qcow2 dump disk back to a VHD/VHDX and
    # materializes the result with a plain copy. qemu-img writes the
    # converted file with the NTFS sparse attribute set, and diskpart
    # refuses to attach a sparse virtual disk ("Virtual hard disk
    # files must be uncompressed and unencrypted and must not be
    # sparse" -- round 22, on BOTH the VHDX and the VHD fallback).
    # A plain Copy-Item loses the sparse attribute (verified: Microsoft
    # Q&A, "if you simply copy the file to another name the copy of
    # the file will lose the sparse attribute"; and `fsutil sparse
    # setflag <file> 0` on an already-sparse file may corrupt it, so
    # the copy -- not setflag -- is the fix). The fsutil queryflag
    # output is logged as proof the copy is not sparse; the attach
    # result is still the ground truth. Returns the materialized path.
    # Throws on convert/copy failure (the caller turns it into a
    # RESULT line). The conversion itself is echoed into $Lines: the
    # round 22 log had no qemu-img convert lines at all, so the next
    # check could not see whether the conversion even ran.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $QemuImgPath,

        [Parameter(Mandatory = $true)]
        [string] $Qcow2Path,

        [Parameter(Mandatory = $true)]
        [string] $Format,

        [Parameter(Mandatory = $true)]
        [string] $OutPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]] $Lines
    )

    $tmpPath = $OutPath + '.convert'
    $Lines.Add(('convert: qemu-img convert -f qcow2 -O {0} {1} {2}' -f $Format, $Qcow2Path, $tmpPath))
    & $QemuImgPath convert -f qcow2 -O $Format $Qcow2Path $tmpPath
    if ($LASTEXITCODE -ne 0) { throw "qemu-img convert back to $Format failed ($Qcow2Path -> $tmpPath)" }
    Copy-Item -LiteralPath $tmpPath -Destination $OutPath -Force
    Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
    try {
        $flag = (& fsutil sparse queryflag $OutPath 2>&1 | Out-String).Trim()
        $Lines.Add(('de-sparse: copied to {0}; fsutil sparse queryflag: {1}' -f $OutPath, $flag))
    }
    catch {
        $Lines.Add(('de-sparse: copied to {0}; fsutil sparse queryflag did not run: {1}' -f $OutPath, $_.Exception.Message))
    }
    return $OutPath
}

function Invoke-CleanCrashDumpCapture {
    # Round 22: after QEMU exits, convert the dump disk back to VHDX,
    # attach it, and read the dedicated dump file the blue screen was
    # supposed to write. Never throws: a missing dump file is itself the
    # finding (dump stack not ready at IopLoadDriver, or the wrong drive
    # letter), and it is written to micpe-bugcheck.txt either way. The
    # caller runs this in the finally block so it runs even when the
    # screen gate threw (a blue screen is exactly when the dump matters).
    # Round 22 fix: the round 21 read-back failed with "drive Z: never
    # appeared" because the diskpart attach script ran `assign` with no
    # volume selected (attach selects the disk, not a volume) and
    # discarded diskpart's output, so the failure was invisible; the
    # converted VHDX was then deleted, destroying the evidence. The
    # attach now selects partition 1 first, captures diskpart's output,
    # polls for the letter, falls back to VHD (vpc) if the VHDX will
    # not attach, and preserves the converted disk file for upload
    # instead of deleting it.
    # Round 23: the round 22 attach never ran -- diskpart failed at
    # `attach vdisk` on both formats ("must be uncompressed and
    # unencrypted and must not be sparse": qemu-img's output is
    # sparse), so the select-partition fix was never tested. The
    # conversion now materializes the file with a plain copy
    # (ConvertTo-CleanDeSparseDisk) and the .vhdx is no longer deleted
    # on the VHD fallback (round 22 deleted it, so the artifact and
    # the Release only ever got the .vhd). A guest-memory ELF dump
    # (Invoke-CleanGuestMemoryDump, taken while the guest is halted on
    # the blue screen) can be passed in as -ElfPath: when the disk
    # produced no parameters, the ELF is scanned with Rizin
    # (Invoke-CleanElfBugCheckScan) as the alternative source. The
    # ELF is deleted after the scan -- 4 GB cannot leave the runner
    # (Release caps assets at ~1.9 GB).
    [CmdletBinding()]
    param(
        [string] $Qcow2Path,

        [Parameter(Mandatory = $true)]
        [string] $QemuImgPath,

        [Parameter(Mandatory = $true)]
        [string] $WorkDir,

        [string] $RizinVersion = 'v0.9.1',

        [string] $ElfPath
    )

    $reportPath = Join-Path $WorkDir 'micpe-bugcheck.txt'
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('MICPE crash-dump capture (round 21: 0x5A bugcheck parameters)')
    if ($Qcow2Path) { $lines.Add(('QEMU dump disk: {0}' -f $Qcow2Path)) }
    $result = [pscustomobject]@{ DumpFound = $false; BugCheck = $null; ReportPath = $reportPath; DiskPath = $null }
    $vhdx = Join-Path $WorkDir 'micpe-dumpdisk-read.vhdx'
    $vhd = Join-Path $WorkDir 'micpe-dumpdisk-read.vhd'
    $attachedLetter = $null
    $diskFile = $null
    try {
        if (-not $Qcow2Path -or -not (Test-Path -LiteralPath $Qcow2Path)) {
            # No dump disk to read back (creation failed, or the caller
            # only has a guest-memory ELF). Skip the disk path; the
            # return still runs the finally below, which scans the ELF
            # (if any) and writes the report.
            $lines.Add('no qcow2 dump disk to read back (creation failed or no disk); skipping the disk path')
            return $result
        }
        # Windows cannot attach qcow2, so convert back first. VHDX is
        # the format the disk was created in; VHD (vpc) is the fallback
        # if the qemu-img VHDX will not attach (known qemu-img VHDX
        # quirks). The qcow2 is deleted only once a converted image
        # has attached -- it is the only source for the fallback.
        # Round 23: the conversion is de-sparsed with a plain copy
        # (ConvertTo-CleanDeSparseDisk); round 22's attach failed on
        # both formats because qemu-img's output is sparse, so the
        # select-partition fix was never tested.
        $null = ConvertTo-CleanDeSparseDisk -QemuImgPath $QemuImgPath -Qcow2Path $Qcow2Path `
            -Format 'vhdx' -OutPath $vhdx -Lines $lines
        $attached = Invoke-CleanDiskAttach -DiskPath $vhdx -Lines $lines
        if ($null -eq $attached) {
            $lines.Add('VHDX attach failed; retrying as VHD (vpc)...')
            $null = ConvertTo-CleanDeSparseDisk -QemuImgPath $QemuImgPath -Qcow2Path $Qcow2Path `
                -Format 'vpc' -OutPath $vhd -Lines $lines
            $attached = Invoke-CleanDiskAttach -DiskPath $vhd -Lines $lines
        }
        if ($null -eq $attached) { throw 'crash-dump disk could not be attached (VHDX and VHD both failed; the diskpart output and volume listing above are the evidence)' }
        $attachedLetter = $attached.Letter
        $diskFile = $attached.DiskPath
        $result.DiskPath = $diskFile
        Remove-Item -LiteralPath $Qcow2Path -Force -ErrorAction SilentlyContinue
        $dumpFile = "${attachedLetter}:\dedicateddumpfile.sys"
        $lines.Add(('attached as {0}: ; dump file path {1}' -f $attachedLetter, $dumpFile))
        $volFiles = @(Get-ChildItem -LiteralPath "${attachedLetter}:\" -Force -ErrorAction SilentlyContinue |
            ForEach-Object { '{0} ({1:N0} bytes)' -f $_.Name, $_.Length })
        $lines.Add(('volume contents: {0}' -f ($volFiles -join '; ')))
        if (-not (Test-Path -LiteralPath $dumpFile)) {
            $lines.Add('RESULT: NO DUMP FILE -- the blue screen did not write a dedicated dump file to the second disk.')
            $lines.Add('This is expected when the system booted cleanly (no bugcheck, nothing to write). It is a problem only when the screenshots show a blue screen; then the causes are: (1) the crash-dump stack was not initialised yet when the 0x5A fired at IopLoadDriver time; (2) the second disk was not C: in WinPE, so DedicatedDumpFile pointed at the wrong letter; (3) the disk was not enumerated in time. The disk was attached and readable, so the file really is absent.')
            $lines.Add('Next step if the screenshots show a blue screen and this repeats: switch to the Rizin winkd KD session (backup plan) or re-check the drive letter with a WinPE command-line probe.')
        }
        else {
            $size = (Get-Item -LiteralPath $dumpFile).Length
            $lines.Add(('RESULT: dump file present: {0:N0} bytes' -f $size))
            $rizin = Get-CleanRizinPath -WorkDir $WorkDir -Version $RizinVersion
            $out = Invoke-CleanRizin -RizinPath $rizin -DumpFile $dumpFile -Commands 'i~bugcheck' -WorkDir $WorkDir
            $lines.Add('--- Rizin i~bugcheck (raw) ---')
            $lines.Add($out)
            $parsed = ConvertFrom-CleanRizinBugCheck -Output $out
            if ($null -eq $parsed) {
                $lines.Add('RESULT: Rizin could not read a bugcheck from the dump (not a crash dump, or the bitmap header could not be parsed). The raw output above is the evidence; try opening the file in WinDbg on a Windows host.')
            }
            else {
                $lines.Add(('RESULT: BugCheckCode={0} Arg1={1} Arg2={2} Arg3={3} Arg4={4}' -f $parsed.BugCheckCode, $parsed.Arg1, $parsed.Arg2, $parsed.Arg3, $parsed.Arg4))
                $result.BugCheck = $parsed
                # Best-effort UNICODE_STRING resolution for Arg2/Arg3 (the
                # pointers alone name nothing; the strings are the service
                # registry path and the driver image path). UNICODE_STRING64
                # is Length u16 @+0, MaximumLength u16 @+2, Buffer u64 @+8.
                foreach ($pair in @(
                    @{ Name = 'Arg2 (service registry path)'; Ptr = $parsed.Arg2 },
                    @{ Name = 'Arg3 (driver image path)'; Ptr = $parsed.Arg3 }
                )) {
                    if (-not $pair.Ptr) { $lines.Add(("{0}: no pointer captured" -f $pair.Name)); continue }
                    try {
                        $ptrVal = [Convert]::ToUInt64(($pair.Ptr -replace '^0x', ''), 16)
                        $bufOut = Invoke-CleanRizin -RizinPath $rizin -DumpFile $dumpFile -Commands ("pv @ 0x{0:x}" -f ($ptrVal + 8)) -WorkDir $WorkDir
                        $m = [regex]::Match($bufOut, '0x[0-9a-fA-F]+')
                        if (-not $m.Success) { $lines.Add(("{0}: could not read Buffer pointer (Rizin said: {1})" -f $pair.Name, $bufOut.Trim())); continue }
                        $strOut = Invoke-CleanRizin -RizinPath $rizin -DumpFile $dumpFile -Commands ("psw @ $($m.Value)") -WorkDir $WorkDir
                        $lines.Add(("{0}: {1} -> {2}" -f $pair.Name, $pair.Ptr, $strOut.Trim()))
                    }
                    catch {
                        $lines.Add(("{0}: resolution failed (best-effort only): {1}" -f $pair.Name, $_.Exception.Message))
                    }
                }
            }
            $result.DumpFound = $true
        }
    }
    catch {
        $lines.Add(('RESULT: capture failed: {0}' -f $_.Exception.Message))
    }
    finally {
        if ($attachedLetter -and $diskFile) {
            @("select vdisk file=`"$diskFile`"", 'detach vdisk') -join "`n" | diskpart | Out-Null
        }
        # Round 23: the guest-memory ELF dump is the alternative
        # source when the disk produced no parameters (round 22: the
        # retained .vhd held only a freshly formatted empty NTFS
        # volume -- the guest never wrote a dump). This runs even when
        # the disk attach failed above, because the ELF does not depend
        # on the disk at all; and it runs only when the disk path did
        # not already produce a BugCheck, so a good disk dump is never
        # re-done from memory.
        if ($null -eq $result.BugCheck -and $ElfPath -and (Test-Path -LiteralPath $ElfPath)) {
            try {
                $lines.Add('disk path produced no bugcheck parameters; scanning the guest-memory ELF dump')
                $rizin = Get-CleanRizinPath -WorkDir $WorkDir -Version $RizinVersion
                $elfScan = Invoke-CleanElfBugCheckScan -RizinPath $rizin -ElfPath $ElfPath -WorkDir $WorkDir -Lines $lines
                if ($null -ne $elfScan.BugCheck) {
                    $result.BugCheck = $elfScan.BugCheck
                    $result.DumpFound = $true
                }
            }
            catch {
                $lines.Add(('ELF memory scan failed: {0}' -f $_.Exception.Message))
            }
        }
        # The qcow2 is the intermediate: delete it. The converted disk
        # file (VHDX or VHD) is PRESERVED for upload (artifact +
        # Release) so the dump survives the runner even if Rizin could
        # not parse it here; the workflow deletes nothing.
        if ($Qcow2Path) { Remove-Item -LiteralPath $Qcow2Path -Force -ErrorAction SilentlyContinue }
        foreach ($candidate in @($vhdx, $vhd)) {
            if (Test-Path -LiteralPath $candidate) {
                $lines.Add(('preserved disk file for upload: {0} ({1:N0} bytes)' -f $candidate, (Get-Item -LiteralPath $candidate).Length))
            }
        }
        $lines | Set-Content -LiteralPath $reportPath -Encoding UTF8
        # Round 23: the ELF dump (4 GB) cannot leave the runner
        # (Release caps assets at ~1.9 GB), so delete it after the
        # scan; the parsed parameters are in the report above.
        if ($ElfPath -and (Test-Path -LiteralPath $ElfPath)) {
            Remove-Item -LiteralPath $ElfPath -Force -ErrorAction SilentlyContinue
            Write-Host "guest-memory ELF dump deleted after scan: $ElfPath"
        }
    }
    Write-Host ($lines -join "`n")
    return $result
}

# --- launch ---------------------------------------------------------------

if (-not $ParseOnly) {

$varsTemplate = Find-CleanOvmfVars -CodePath $OvmfPath
$varsPath = Join-Path $WorkDir 'OVMF_VARS.fd'
Copy-Item -LiteralPath $varsTemplate -Destination $varsPath -Force

$serialLog = Join-Path $WorkDir 'micpe-serial.log'
$qemuLog = Join-Path $WorkDir 'micpe-qemu.log'

# Round 21: the crash-dump disk. Diagnostic only: a failure here must
# not fail the verify (the screenshots are the evidence), so it is
# wrapped and the run continues without the disk.
$qemuImgPath = Get-CleanQemuImgPath -QemuPath $QemuPath
$dumpDiskQcow2 = $null
if (-not $NoCrashDumpDisk) {
    try {
        $dumpDiskQcow2 = New-CleanCrashDumpDisk -WorkDir $WorkDir -SizeMb $DumpDiskSizeMb -QemuImgPath $qemuImgPath
        Write-Host "crash-dump disk ready: $dumpDiskQcow2 (DedicatedDumpFile target C:)"
    }
    catch {
        Write-Host "!!! crash-dump disk could not be created (diagnostic only, QEMU verify continues without it): $($_.Exception.Message)"
        $dumpDiskQcow2 = $null
    }
}

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
if ($dumpDiskQcow2) {
    # ide index 0 (primary master): enumerated before the CD-ROM
    # (secondary master), so WinPE gives this fixed disk C:.
    $qemuArgs += @('-drive', "file=$dumpDiskQcow2,format=qcow2,if=ide,index=0")
}
$argString = ($qemuArgs | ForEach-Object {
    if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
}) -join ' '

Write-Host "starting QEMU: $QemuPath $argString"
$qemu = Start-Process -FilePath $QemuPath -ArgumentList $argString -PassThru -NoNewWindow
if ($null -eq $qemu) { throw 'failed to start QEMU' }

$shotsTaken = 0
$shotIndex = 0
$script:crashDumpResult = $null
$script:blueScreenSeen = $false
$script:guestMemoryElf = $null
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
    # Round 23: remember whether the guest died on a bugcheck blue
    # screen, so the finally block below can snapshot guest RAM
    # (Invoke-CleanGuestMemoryDump) before quitting QEMU. Set here,
    # before the gate throws -- the finally block is the only place
    # that can still reach the monitor.
    $script:blueScreenSeen = (@($blueFailureShots | Where-Object { $_.Classification -eq 'BlueScreen' }).Count -gt 0)
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
    # Round 23: while the guest is still halted on the blue screen,
    # snapshot its RAM through the monitor. The ELF dump is the
    # alternative parameter source when the guest never wrote a
    # dedicated dump file (round 22: the retained .vhd held only a
    # freshly formatted empty NTFS volume). It must happen BEFORE
    # 'quit': once QEMU exits the memory is gone. Best-effort only;
    # a failure here never changes the run's verdict.
    if ($script:blueScreenSeen) {
        try {
            $elfPath = Join-Path $WorkDir 'guest-memory.elf'
            if (Invoke-CleanGuestMemoryDump -Port $MonitorPort -ElfPath $elfPath) {
                $script:guestMemoryElf = $elfPath
            }
        }
        catch {
            Write-Host "!!! guest-memory dump failed (diagnostic only): $($_.Exception.Message)"
        }
    }
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
    # Round 21: crash-dump capture. Runs even when the screen gate threw
    # (a blue screen is exactly when the dump matters); never changes the
    # run's verdict -- a capture failure is logged, not thrown.
    # Round 23: run it when there is a dump disk to read back OR a
    # guest-memory ELF to scan (the ELF scan lives inside the capture,
    # so the ELF-only case still gets parsed).
    if (($dumpDiskQcow2 -and (Test-Path -LiteralPath $dumpDiskQcow2)) -or
        ($script:guestMemoryElf -and (Test-Path -LiteralPath $script:guestMemoryElf))) {
        try {
            $script:crashDumpResult = Invoke-CleanCrashDumpCapture -Qcow2Path $dumpDiskQcow2 -QemuImgPath $qemuImgPath -WorkDir $WorkDir -ElfPath $script:guestMemoryElf
        }
        catch {
            Write-Host "!!! crash-dump capture failed (diagnostic only, run verdict unchanged): $($_.Exception.Message)"
        }
    }
}

return [pscustomobject]@{
    ScreenshotDir = $shotDir
    ShotsTaken    = $shotsTaken
    ShotsExpected = $shotIndex
    BugCheck      = $script:crashDumpResult
}

}