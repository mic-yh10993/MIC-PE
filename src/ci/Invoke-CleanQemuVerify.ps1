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

    # Round 30: path to the built boot.wim, used only to pre-stage
    # ntoskrnl symbols before the KD session (Invoke-CleanSymbolPrestage
    # extracts ntoskrnl.exe from it and fetches its PDB into the local
    # symbol cache). Optional: empty means the pre-stage is skipped
    # with a warning and the session keeps the round 26 SRV* symbol
    # path. The workflow passes $env:BOOT_WIM_PATH (exported by the
    # Build step); local runs without it simply skip the pre-stage.
    [string] $BootWimPath = '',

    [string] $QemuPath = 'qemu-system-x86_64',

    [int] $MemoryMb = 4096,

    [int] $CpuCount = 4,

    [string] $MonitorPort = '4444',

    # Round 26: live kernel-debugger (KD) serial port. The guest's
    # COM1 (kernel debug, serial 115200, enabled on both BCDs since
    # round 16) is wired to a named pipe here so kd.exe can attach
    # live and catch the 0x5A bugcheck the moment it fires; the
    # monitor stays on $MonitorPort (TCP). Round 31: the pipe
    # replaces the round 26 TCP chardev (QEMU -serial
    # tcp:127.0.0.1:50001 + kd com:ipport=50001). Three rounds
    # (28/29/30) of the same shape -- kd.exe connects at the initial
    # breakpoint (uptime 0.014 s) and the transport drops immediately
    # (64->320 retries, no recovery) before the init script prints
    # anything -- point at the QEMU TCP chardev, not at the script
    # or the symbols: the script never ran, so reordering it cannot
    # fix the handshake. A named pipe is the standard VM kernel-debug
    # transport (no TCP stack, no listen backlog, one peer only).
    # The default name is arbitrary; the probe uses 'micpe-kd-probe'.
    [string] $KdPipeName = 'micpe-kd',

    # Round 26: skip the live KD session (escape hatch for a re-run
    # if the debugger misbehaves in CI; the serial output is then
    # discarded and the disk/ELF paths are the only evidence).
    [switch] $NoKdSession,

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

function Format-CleanMonitorStatus {
    # Round 29: turn the three monitor query responses (info status /
    # info registers / info cpus, asked before 'quit') into the
    # report lines for micpe-bugcheck.txt. Pure formatter, no TCP:
    # the caller queries the monitor and hands the raw text here.
    # An empty response means the monitor said nothing; a failed
    # query arrives as a 'query failed: ...' line from the caller.
    # The trailing '(qemu)' prompt and blank lines are dropped.
    # Round 30: 'info vcpus' is an unknown command on this QEMU
    # (both round 29 passes), so the third query is 'info cpus'.
    [CmdletBinding()]
    param(
        [string] $InfoStatus,

        [string] $InfoRegisters,

        [string] $InfoCpus
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($pair in @(
        @{ Query = 'info status'; Response = $InfoStatus },
        @{ Query = 'info registers'; Response = $InfoRegisters },
        @{ Query = 'info cpus'; Response = $InfoCpus }
    )) {
        $lines.Add(('monitor {0}:' -f $pair.Query))
        $text = $pair.Response
        if ($text -and $text.Trim()) {
            foreach ($rl in ($text -split "`r`n|`n")) {
                $trimmed = $rl.Trim()
                if ($trimmed -ne '' -and $trimmed -ne '(qemu)') {
                    $lines.Add(('  {0}' -f $rl.TrimEnd()))
                }
            }
        }
        else {
            $lines.Add('  (no response)')
        }
    }
    return ,$lines.ToArray()
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

function Test-CleanElfCore {
    # Validates an ELF64 core dump header + program headers by parsing
    # them directly (no Rizin): magic, 64-bit class, little-endian,
    # ET_CORE type, and the PT_LOAD segments (count + total mapped
    # bytes). Round 23's scan ran Rizin without checking whether the
    # 4.3 GB ELF was even well-formed; a truncated or unmapped dump
    # would silently yield 0 hits. Only the header + program-header
    # table are read (a few KB), never the whole file, so this is cheap
    # even on a 4 GB dump. Returns @{ Valid; Segments; MappedBytes;
    # Reason }. Never throws: a read failure is itself a finding.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ElfPath
    )

    $result = [pscustomobject]@{ Valid = $false; Segments = 0; MappedBytes = [UInt64]0; Reason = '' }
    try {
        $item = Get-Item -LiteralPath $ElfPath -ErrorAction Stop
        if ($item.Length -lt 64) { $result.Reason = 'file is smaller than an ELF64 header (64 bytes)'; return $result }
        $fs = [System.IO.FileStream]::new($ElfPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $hdr = [byte[]]::new(64)
            if ($fs.Read($hdr, 0, 64) -lt 64) { $result.Reason = 'could not read the ELF64 header'; return $result }
            if ($hdr[0] -ne 0x7F -or $hdr[1] -ne 0x45 -or $hdr[2] -ne 0x4C -or $hdr[3] -ne 0x46) { $result.Reason = 'not an ELF file (bad magic)'; return $result }
            if ($hdr[4] -ne 2) { $result.Reason = 'not a 64-bit ELF (EI_CLASS is not 2)'; return $result }
            if ($hdr[5] -ne 1) { $result.Reason = 'not little-endian (EI_DATA is not 1)'; return $result }
            $eType = [BitConverter]::ToUInt16($hdr, 16)
            if ($eType -ne 4) { $result.Reason = ('e_type is {0}, not ET_CORE (4)' -f $eType); return $result }
            $ePhoff = [BitConverter]::ToUInt64($hdr, 32)
            $ePhentsize = [BitConverter]::ToUInt16($hdr, 54)
            $ePhnum = [BitConverter]::ToUInt16($hdr, 56)
            if ($ePhentsize -ne 56) { $result.Reason = ('unexpected program-header size {0} (expected 56)' -f $ePhentsize); return $result }
            if ($ePhnum -eq 0) { $result.Reason = 'no program headers'; return $result }
            if ($ePhnum -eq 0xFFFF) { $result.Reason = 'extended program-header numbering (PN_XNUM) not supported'; return $result }
            $phdrSize = $ePhnum * 56
            if ($item.Length -lt ($ePhoff + $phdrSize)) { $result.Reason = 'program-header table is truncated'; return $result }
            $null = $fs.Seek([Int64]$ePhoff, [System.IO.SeekOrigin]::Begin)
            $phdrs = [byte[]]::new($phdrSize)
            if ($fs.Read($phdrs, 0, $phdrSize) -lt $phdrSize) { $result.Reason = 'could not read the program-header table'; return $result }
            $segments = 0
            $mapped = [UInt64]0
            for ($i = 0; $i -lt $ePhnum; $i++) {
                $off = $i * 56
                if ([BitConverter]::ToUInt32($phdrs, $off) -eq 1) {
                    $segments++
                    $mapped += [BitConverter]::ToUInt64($phdrs, $off + 32)
                }
            }
            if ($segments -eq 0) { $result.Reason = 'no PT_LOAD segments'; return $result }
            $result.Valid = $true
            $result.Segments = $segments
            $result.MappedBytes = $mapped
            $result.Reason = 'ELF core OK'
            return $result
        }
        finally {
            $fs.Dispose()
        }
    }
    catch {
        $result.Reason = $_.Exception.Message
        return $result
    }
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

        # Round 24: the dump disk's MBR signature (0 = unknown / skip).
        # When set, the scan also looks for those 4 bytes in guest
        # memory: found = the guest read this disk's MBR (enumerated);
        # absent = the guest never got as far as reading the disk.
        [UInt32] $DiskSignature = 0,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]] $Lines
    )

    $result = [pscustomobject]@{ BugCheck = $null; KernBase = $null; Candidates = @(); DiskSignatureHits = $null }
    if (-not (Test-Path -LiteralPath $ElfPath)) {
        $Lines.Add('ELF memory scan skipped: no guest-memory dump file was captured')
        return $result
    }
    $elfSize = (Get-Item -LiteralPath $ElfPath).Length
    $Lines.Add(('ELF memory scan: {0} ({1:N0} bytes)' -f $ElfPath, $elfSize))
    $elfCheck = Test-CleanElfCore -ElfPath $ElfPath
    if ($elfCheck.Valid) {
        $Lines.Add(('ELF core: {0} PT_LOAD segment(s), {1:N0} bytes mapped' -f $elfCheck.Segments, $elfCheck.MappedBytes))
    }
    else {
        $Lines.Add(('ELF core validation failed: {0} (scanning anyway; Rizin may still find hits)' -f $elfCheck.Reason))
    }
    try {
        # --- KDBG: prove the ELF is Windows memory, get the kernel base.
        $kdbgOut = Invoke-CleanRizinFile -RizinPath $RizinPath -FilePath $ElfPath `
            -Commands '/x 4b444247' -WorkDir $WorkDir
        $kdbgHits = @(ConvertFrom-CleanRizinSearchHits -Output $kdbgOut)
        $Lines.Add(('KDBG search: {0} hit(s)' -f $kdbgHits.Count))
        if ($kdbgHits.Count -gt 0) {
            $take = [Math]::Min(20, $kdbgHits.Count)
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

        # --- disk signature: did the guest read this disk's MBR at all?
        # The 4 signature bytes are the disk's own marker (read from
        # the qcow2 MBR at capture time). Found in guest RAM = the
        # kernel read the MBR, so the disk was enumerated and the
        # drive-letter question stays open; absent = the guest never
        # got as far as reading this disk, and the letter is moot --
        # the dump route is dead for a bugcheck this early. One-sided
        # evidence only (an absent signature can also mean the MBR
        # buffer was freed before the dump), so the line says exactly
        # what was and was not found.
        if ($DiskSignature -ne 0) {
            $sigPattern = (([BitConverter]::GetBytes($DiskSignature) | ForEach-Object { '{0:x2}' -f $_ }) -join '')
            $sigOut = Invoke-CleanRizinFile -RizinPath $RizinPath -FilePath $ElfPath `
                -Commands ("/x $sigPattern") -WorkDir $WorkDir
            $sigHits = @(ConvertFrom-CleanRizinSearchHits -Output $sigOut)
            $result.DiskSignatureHits = $sigHits.Count
            $Lines.Add(('disk signature 0x{0:x8}: {1} hit(s) in guest memory' -f $DiskSignature, $sigHits.Count))
            if ($sigHits.Count -gt 0) {
                $Lines.Add('disk signature found in guest memory: the guest read this disk''s MBR (the disk was enumerated)')
            }
            else {
                $Lines.Add('disk signature NOT found in guest memory: the guest never read this disk''s MBR (not enumerated), or the MBR buffer was freed before the dump')
            }
        }

        # --- strict pattern: { code 0x5A, Arg1 1 } then two pointers + NTSTATUS.
        $strictOut = Invoke-CleanRizinFile -RizinPath $RizinPath -FilePath $ElfPath `
            -Commands '/x 5a000000000000000100000000000000' -WorkDir $WorkDir
        $strictHits = @(ConvertFrom-CleanRizinSearchHits -Output $strictOut)
        $Lines.Add(('strict KiBugCheckData search: {0} hit(s)' -f $strictHits.Count))
        $candidates = [System.Collections.Generic.List[pscustomobject]]::new()
        if ($strictHits.Count -gt 0) {
            # Round 24: validate up to 50 (was 20). The reads are one
            # Rizin call either way; the cap only bounded the output.
            $take = [Math]::Min(50, $strictHits.Count)
            $reads = [System.Collections.Generic.List[string]]::new()
            for ($i = 0; $i -lt $take; $i++) {
                foreach ($off in @(0, 8, 16, 24, 32)) {
                    $reads.Add(('pv8 @ 0x{0:x}' -f ($strictHits[$i] + $off)))
                }
            }
            $vals = @(ConvertFrom-CleanRizinValues -Output (Invoke-CleanRizinFile -RizinPath $RizinPath `
                -FilePath $ElfPath -Commands ($reads -join '; ') -WorkDir $WorkDir))
            $strictAccepted = 0
            $strictRejected = 0
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
                    # A valid candidate is always logged, wherever it
                    # sits in the hit list -- it is the result.
                    $strictAccepted++
                    $Lines.Add(('RESULT: BugCheckCode={0} Arg1={1} Arg2={2} Arg3={3} Arg4={4} (from guest memory at 0x{5:x})' -f $cand.Code, $cand.Arg1, $cand.Arg2, $cand.Arg3, $cand.Arg4, $cand.Address))
                }
                else {
                    $strictRejected++
                    if ($i -lt 10) { $Lines.Add(('strict candidate at 0x{0:x} rejected: {1}' -f $cand.Address, $check.Reason)) }
                }
            }
            $Lines.Add(('strict search: examined {0} of {1} hit(s) ({2} accepted, {3} rejected)' -f $take, $strictHits.Count, $strictAccepted, $strictRejected))
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
                # Round 24: validate up to 200 (was 10). Round 23 had
                # 125 loose hits and only the first 10 were ever
                # examined -- a real candidate past position 10 was
                # never seen.
                $take = [Math]::Min(200, $looseHits.Count)
                $reads = [System.Collections.Generic.List[string]]::new()
                for ($i = 0; $i -lt $take; $i++) {
                    foreach ($off in @(0, 8, 16, 24, 32)) {
                        $reads.Add(('pv8 @ 0x{0:x}' -f ($looseHits[$i] + $off)))
                    }
                }
                $vals = @(ConvertFrom-CleanRizinValues -Output (Invoke-CleanRizinFile -RizinPath $RizinPath `
                    -FilePath $ElfPath -Commands ($reads -join '; ') -WorkDir $WorkDir))
                $looseAccepted = 0
                $looseRejected = 0
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
                        # A valid candidate is always logged, wherever
                        # it sits in the hit list -- it is the result.
                        $looseAccepted++
                        $Lines.Add(('RESULT (loose, unconfirmed): BugCheckCode={0} Arg1={1} Arg2={2} Arg3={3} Arg4={4} (from guest memory at 0x{5:x})' -f $cand.Code, $cand.Arg1, $cand.Arg2, $cand.Arg3, $cand.Arg4, $cand.Address))
                    }
                    else {
                        $looseRejected++
                        if ($i -lt 10) { $Lines.Add(('loose candidate at 0x{0:x} rejected: {1}' -f $cand.Address, $check.Reason)) }
                    }
                }
                $Lines.Add(('loose search: examined {0} of {1} hit(s) ({2} accepted, {3} rejected)' -f $take, $looseHits.Count, $looseAccepted, $looseRejected))
            }
        }
        # --- bootlog (round 26): the last driver loaded before the
        # crash. Independent of the parameters above (a cross-check
        # for them): the boot log is the only ordered record of which
        # drivers got as far as loading.
        $null = Invoke-CleanBootlogSearch -RizinPath $RizinPath -ElfPath $ElfPath -WorkDir $WorkDir -Lines $Lines
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

function Invoke-CleanBootlogSearch {
    # Round 26: searches the guest-memory ELF for the boot log
    # (ntbtlog.txt) content. The BCD now sets bootlog Yes (round 26,
    # Set-CleanBcdKernelDebug), so the kernel writes "Loaded driver
    # ..." / "Did not load driver ..." lines to X:\Windows\ntbtlog.txt
    # during boot. The file lives on the WIM RAM disk and vanishes
    # when QEMU exits, but the ELF dump taken while the guest is
    # halted on the blue screen still holds its bytes in RAM -- that
    # is the only way to read it. Two ASCII searches; the highest
    # address hit of either is the last log line written before the
    # crash, read back with `ps` (its first lines are the tail of the
    # boot sequence). Returns @{ Found; LoadedCount; NotLoadedCount;
    # LastLines } (Found = $false when neither pattern hit). Never
    # throws: a missing bootlog is itself a finding (logged, not
    # thrown).
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

    $result = [pscustomobject]@{ Found = $false; LoadedCount = 0; NotLoadedCount = 0; LastLines = @() }
    # ASCII hex: "Loaded driver" / "Did not load driver".
    $loadedHex = '4c6f6164656420647269766572'
    $notLoadedHex = '446964206e6f74206c6f616420647269766572'
    try {
        $loadedOut = Invoke-CleanRizinFile -RizinPath $RizinPath -FilePath $ElfPath -Commands ("/x $loadedHex") -WorkDir $WorkDir
        $loadedHits = @(ConvertFrom-CleanRizinSearchHits -Output $loadedOut)
        $result.LoadedCount = $loadedHits.Count
        $Lines.Add(('bootlog search: "Loaded driver" {0} hit(s) in guest memory' -f $loadedHits.Count))
        $notOut = Invoke-CleanRizinFile -RizinPath $RizinPath -FilePath $ElfPath -Commands ("/x $notLoadedHex") -WorkDir $WorkDir
        $notHits = @(ConvertFrom-CleanRizinSearchHits -Output $notOut)
        $result.NotLoadedCount = $notHits.Count
        $Lines.Add(('bootlog search: "Did not load driver" {0} hit(s) in guest memory' -f $notHits.Count))
        if ($loadedHits.Count -eq 0 -and $notHits.Count -eq 0) {
            $Lines.Add('bootlog NOT found in guest memory: ntbtlog.txt was never written, or its RAM-disk backing is not in this dump (bootlog Yes may not have taken effect, or the log is not in the captured RAM)')
            return $result
        }
        # The highest address of either pattern is the last log line
        # written before the crash. (Do NOT use Measure-Object
        # -Maximum here: it returns a Double, and "{0:x}" formatting
        # a Double throws FormatException.)
        $lastAddr = [UInt64]0
        $lastKind = ''
        foreach ($h in $loadedHits) { if ($h -gt $lastAddr) { $lastAddr = $h; $lastKind = 'Loaded' } }
        foreach ($h in $notHits) { if ($h -gt $lastAddr) { $lastAddr = $h; $lastKind = 'NotLoaded' } }
        # `ps` reads from there until a NUL (the end of the file's
        # last cluster); its first lines are the tail of the boot
        # sequence.
        $psOut = Invoke-CleanRizinFile -RizinPath $RizinPath -FilePath $ElfPath -Commands ("ps @ 0x{0:x}" -f $lastAddr) -WorkDir $WorkDir
        $tail = @(($psOut -split "`r`n|`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | Select-Object -First 15)
        $bootLines = @($tail | Where-Object { $_ -match '^(Loaded driver|Did not load driver)\s' })
        if ($bootLines.Count -gt 0) {
            $result.Found = $true
            $result.LastLines = $bootLines
            $Lines.Add(('bootlog tail (highest hit, 0x{0:x}, {1}): last {2} bootlog line(s) before the crash:' -f $lastAddr, $lastKind, $bootLines.Count))
            foreach ($bl in $bootLines) { $Lines.Add(('  {0}' -f $bl)) }
            $lastLoaded = @($bootLines | Where-Object { $_ -match '^Loaded driver\s' } | Select-Object -Last 1)
            if ($lastLoaded.Count -gt 0) {
                $Lines.Add(('bootlog: last driver loaded before the crash: {0} (the failing driver is likely the next one that never got to log)' -f ($lastLoaded[0] -replace '^Loaded driver\s+', '')))
            }
        }
        else {
            $firstTail = if ($tail.Count -gt 0) { $tail[0] } else { '(empty)' }
            $Lines.Add(('bootlog: highest hit at 0x{0:x} does not read back as bootlog lines (first line: {1}) -- the hit may be the "Loaded driver" format string inside ntoskrnl, not the log buffer' -f $lastAddr, $firstTail))
        }
    }
    catch {
        $Lines.Add(('bootlog search failed: {0}' -f $_.Exception.Message))
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

function Format-CleanVolumeContents {
    # Round 24: formats one line per entry in a directory listing for
    # the crash-dump disk report. Pure function (takes the listing,
    # returns one string). Directories have no .Length property --
    # reading it under Set-StrictMode throws exactly "The property
    # 'Length' cannot be found on this object", which is what killed
    # round 23's capture after a successful attach (a freshly
    # formatted NTFS volume always has "System Volume Information"
    # in its root). Files are shown with their byte size.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.IO.FileSystemInfo[]] $Entries
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Entries) {
        if ($entry.PSIsContainer) {
            $parts.Add(('{0} (directory)' -f $entry.Name))
        }
        else {
            $parts.Add(('{0} ({1:N0} bytes)' -f $entry.Name, $entry.Length))
        }
    }
    return ($parts -join '; ')
}

function ConvertFrom-CleanMbrSignature {
    # Round 24: pure parser for a 512-byte MBR image. Returns the
    # 4-byte disk signature at offset 0x1B8 as a [UInt32], or $null
    # when the image is too short or lacks the 0x55AA boot signature
    # (in which case there is no MBR to trust). The returned value is
    # the bytes as stored, little-endian.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]] $MbrBytes
    )

    if ($MbrBytes.Length -lt 512) { return $null }
    if ($MbrBytes[510] -ne 0x55 -or $MbrBytes[511] -ne 0xAA) { return $null }
    return [BitConverter]::ToUInt32($MbrBytes, 0x1B8)
}

function Get-CleanDiskSignature {
    # Round 24: reads the crash-dump disk's MBR signature from the
    # qcow2 image (qemu-img dd, 512 bytes) and logs it, so the ELF
    # scan can test whether the guest ever read this disk's MBR.
    # Never throws; returns [UInt32] 0 when the signature cannot be
    # determined, and the caller then skips the signature search.
    # Runs at the start of the capture (before the qcow2 is deleted
    # by a successful attach) and uses Invoke-CleanProcessToFile for
    # exact argv passing (round 23: Start-Process -ArgumentList
    # splits on spaces on Linux).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $QemuImgPath,

        [Parameter(Mandatory = $true)]
        [string] $Qcow2Path,

        [Parameter(Mandatory = $true)]
        [string] $WorkDir,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]] $Lines
    )

    $mbrFile = Join-Path $WorkDir 'micpe-dumpdisk-mbr.bin'
    $outFile = Join-Path $WorkDir 'micpe-dumpdisk-mbr.out'
    $errFile = Join-Path $WorkDir 'micpe-dumpdisk-mbr.err'
    try {
        $run = Invoke-CleanProcessToFile -FilePath $QemuImgPath -ArgumentList @(
            'dd', '-f', 'qcow2', '-O', 'raw', ('if={0}' -f $Qcow2Path), ('of={0}' -f $mbrFile), 'bs=512', 'count=1'
        ) -OutFile $outFile -ErrFile $errFile
        if ($run.ExitCode -ne 0) {
            $err = ''
            if (Test-Path -LiteralPath $errFile) { $err = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue) }
            if ($err) { $err = $err.Trim(); if ($err.Length -gt 500) { $err = $err.Substring(0, 500) } }
            $Lines.Add(('disk MBR signature: qemu-img dd failed (exit {0}): {1}' -f $run.ExitCode, $err))
            return [UInt32]0
        }
        if (-not (Test-Path -LiteralPath $mbrFile)) {
            $Lines.Add('disk MBR signature: qemu-img dd reported success but wrote no MBR file')
            return [UInt32]0
        }
        $bytes = [System.IO.File]::ReadAllBytes($mbrFile)
        $sig = ConvertFrom-CleanMbrSignature -MbrBytes $bytes
        if ($null -eq $sig) {
            $Lines.Add('disk MBR signature: no valid MBR (image too short or missing 0x55AA)')
            return [UInt32]0
        }
        $Lines.Add(('disk MBR signature: 0x{0:x8}' -f $sig))
        return $sig
    }
    catch {
        $Lines.Add(('disk MBR signature: could not read the MBR: {0}' -f $_.Exception.Message))
        return [UInt32]0
    }
    finally {
        foreach ($f in @($mbrFile, $outFile, $errFile)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Get-CleanCdbPath {
    # Round 26: locate cdb.exe (the console debugger from the
    # Windows SDK / Debugging Tools for Windows). The windows-2025
    # runner image installs the Windows Desktop Debuggers component
    # (cdb.exe) with the Windows 11 SDK -- actions/runner-images
    # Install-VisualStudio.ps1 enables OptionId.WindowsDesktopDebuggers
    # -- so the standard SDK path is checked first and the PATH
    # second (a manual SDK install). Returns $null (never throws)
    # when cdb is not found: the KD session is best-effort and its
    # absence is a finding in micpe-bugcheck.txt, not a failure.
    [CmdletBinding()]
    param()

    $candidates = @(
        'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe'
        'C:\Program Files\Windows Kits\10\Debuggers\x64\cdb.exe'
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $cmd = Get-Command -Name 'cdb.exe' -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and $cmd.Source) { return $cmd.Source }
    return $null
}

function Write-CleanKdInitScript {
    # Round 27: writes the two-line kd-init.txt the -c "$$>..." token
    # runs at the initial break-in: a deferred breakpoint on
    # KeBugCheckEx that prints the registers and the two
    # UNICODE_STRING arguments, then `g` to continue into the
    # bugcheck. Idempotent: the probe and the real session share it.
    # Round 30: the script now echoes its own progress -- rounds
    # 28-29 left no trace of whether the script ran at all (the log
    # went straight from the kernel banner to the transport retry
    # storm). The markers say exactly where it stopped: START means
    # the -c script began executing; BU ISSUED means the `bu` line
    # ran (and `bl` right after it shows whether the breakpoint
    # resolved to an address or stayed deferred); G ISSUED prints on
    # the NEXT break-in after `g` resumes the target, so its absence
    # with BU ISSUED present means `g` never got through. The
    # markers are plain .echo lines, so ConvertFrom-CleanKdLog can
    # read them without parsing debugger output.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $InitScriptPath
    )
    $initLines = @(
        '.echo *** KD-INIT START ***'
        'bu nt!KeBugCheckEx ".echo *** KEBUGCHECKEX HIT ***; r; du poi(@r8+8); du poi(@r9+8); ? poi(@rsp+0x20); g"'
        'bl'
        '.echo *** KD-INIT BU ISSUED ***'
        'g'
        '.echo *** KD-INIT G ISSUED ***'
    )
    $initLines | Set-Content -LiteralPath $InitScriptPath -Encoding ASCII
}

function Get-CleanKdArgList {
    # Round 27: builds the exact cdb/kd argv for one launch variant.
    # Pure function (no process, no network): the probe and the real
    # session share it, so a variant that survives the probe is
    # launched verbatim against QEMU. Every variant is a single
    # variable change from 'baseline' (the round 26 command line), so
    # the first surviving variant identifies the trigger. Variants:
    # baseline | nosymbols | nologo | inline-c | noc. ('kd' is
    # not an argv variant: it is the same argv with kd.exe as the
    # binary, selected by the caller.) 'noc' drops -c entirely and is
    # probe-only: without -c nothing issues `g`, so the guest would
    # halt at the initial breakpoint. Round 31: the -k connect string
    # is a named pipe ('com:pipe,port=\\.\pipe\micpe-kd'), replacing
    # the round 26 TCP connect string ('com:ipport=50001,
    # port=127.0.0.1') -- three rounds of kd.exe connecting at the
    # initial breakpoint and dropping immediately point at the QEMU
    # TCP chardev. The 'baud' variant is gone with it: a baud rate
    # is meaningless on a pipe.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $KdPipeName,

        [Parameter(Mandatory = $true)]
        [string] $WorkDir,

        [Parameter(Mandatory = $true)]
        [string] $KdLogPath,

        [Parameter(Mandatory = $true)]
        [string] $InitScriptPath,

        [ValidateSet('baseline', 'nosymbols', 'nologo', 'inline-c', 'noc')]
        [string] $Variant = 'baseline'
    )
    $symPath = ('SRV*{0}\kd-symbols*https://msdl.microsoft.com/download/symbols' -f $WorkDir)
    $args = [System.Collections.Generic.List[string]]::new()
    $args.Add('-k')
    $com = ('com:pipe,port=\\.\pipe\{0}' -f $KdPipeName)
    $args.Add($com)
    if ($Variant -ne 'nosymbols') {
        $args.Add('-y')
        $args.Add($symPath)
    }
    if ($Variant -ne 'nologo') {
        $args.Add('-logo')
        $args.Add($KdLogPath)
    }
    if ($Variant -ne 'noc') {
        $args.Add('-c')
        if ($Variant -eq 'inline-c') {
            $args.Add('bu nt!KeBugCheckEx ".echo *** KEBUGCHECKEX HIT ***; r; du poi(@r8+8); du poi(@r9+8); ? poi(@rsp+0x20); g"; g')
        }
        else {
            $args.Add(('$$><{0}' -f $InitScriptPath))
        }
    }
    return $args.ToArray()
}

function Get-CleanKdPath {
    # Round 27: kd.exe lives next to cdb.exe in the SDK Debuggers
    # directory. Returns $null when it is not there (the 'kd'
    # probe variant is then skipped, not failed).
    [CmdletBinding()]
    param(
        [string] $CdbPath
    )
    if (-not $CdbPath) { return $null }
    $dir = [System.IO.Path]::GetDirectoryName($CdbPath)
    if (-not $dir) { return $null }
    $kd = [System.IO.Path]::Combine($dir, 'kd.exe')
    if (Test-Path -LiteralPath $kd) { return $kd }
    return $null
}

function Get-CleanDebuggerVersion {
    # Round 27: file version of the debugger binary, for the log.
    # Round 26 never recorded WHICH cdb ran. Returns $null when the
    # file is missing or carries no version resource (never throws).
    [CmdletBinding()]
    param(
        [string] $Path
    )
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        if ($null -ne $info -and $info.FileVersion) { return $info.FileVersion }
    }
    catch {}
    return $null
}

function Get-CleanSymchkPath {
    # Round 30: locates symchk.exe in the same SDK Debuggers
    # directory as cdb.exe (it ships with the debugger package), or
    # $null when cdb.exe is missing or symchk.exe is not next to it.
    # Pure lookup, never throws -- the pre-stage degrades to a
    # warning without it.
    [CmdletBinding()]
    param(
        [string] $CdbPath
    )
    if (-not $CdbPath) { return $null }
    $dir = Split-Path -Parent $CdbPath
    if (-not $dir) { return $null }
    $symchk = Join-Path $dir 'symchk.exe'
    if (Test-Path -LiteralPath $symchk -PathType Leaf) { return $symchk }
    return $null
}

function Get-CleanWimlibPath {
    # Round 30: locates wimlib-imagex (choco install, on PATH in CI)
    # or $null when it is not installed. Never throws.
    [CmdletBinding()]
    param()
    foreach ($name in @('wimlib-imagex.exe', 'wimlib-imagex')) {
        $found = (Get-Command $name -ErrorAction SilentlyContinue).Source
        if ($found) { return $found }
    }
    return $null
}

function Test-CleanSymbolCache {
    # Round 30: $true when the local symbol cache already holds an
    # ntoskrnl.pdb (symchk stores it under a GUID-named subfolder, so
    # the check is recursive). Pure predicate, never throws.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $CacheDir
    )
    if (-not (Test-Path -LiteralPath $CacheDir -PathType Container)) { return $false }
    $pdb = Get-ChildItem -LiteralPath $CacheDir -Filter 'ntoskrnl.pdb' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    return ($null -ne $pdb)
}

function Expand-CleanNtoskrnlFromWim {
    # Round 30: extracts \Windows\System32\ntoskrnl.exe from the
    # built boot.wim into $DestDir via wimlib-imagex and returns the
    # extracted path, or $null when wimlib is missing, the WIM is
    # missing, or the extract fails. Never throws -- the caller logs
    # the reason and continues without pre-staged symbols.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $BootWimPath,

        [Parameter(Mandatory = $true)]
        [string] $WimlibPath,

        [Parameter(Mandatory = $true)]
        [string] $DestDir,

        [int] $TimeoutSec = 60
    )
    if (-not (Test-Path -LiteralPath $BootWimPath -PathType Leaf)) {
        Write-Host ('symbol pre-stage: boot.wim not found at {0}' -f $BootWimPath)
        return $null
    }
    if (-not (Test-Path -LiteralPath $WimlibPath -PathType Leaf)) {
        Write-Host ('symbol pre-stage: wimlib-imagex not found at {0}' -f $WimlibPath)
        return $null
    }
    if (-not (Test-Path -LiteralPath $DestDir -PathType Container)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }
    $outFile = Join-Path $DestDir 'wimlib-extract.out'
    $errFile = Join-Path $DestDir 'wimlib-extract.err'
    try {
        $proc = Invoke-CleanProcessToFile -FilePath $WimlibPath `
            -ArgumentList @('extract', $BootWimPath, '1', '\Windows\System32\ntoskrnl.exe', ('--dest-dir={0}' -f $DestDir)) `
            -OutFile $outFile -ErrFile $errFile -TimeoutSec $TimeoutSec
        if ($proc.ExitCode -ne 0) {
            Write-Host ('symbol pre-stage: wimlib-imagex extract exited {0} (see {1})' -f $proc.ExitCode, $errFile)
            return $null
        }
    }
    catch {
        Write-Host ('symbol pre-stage: wimlib-imagex extract failed: {0}' -f $_.Exception.Message)
        return $null
    }
    $ntoskrnl = Join-Path $DestDir 'ntoskrnl.exe'
    if (Test-Path -LiteralPath $ntoskrnl -PathType Leaf) { return $ntoskrnl }
    Write-Host ('symbol pre-stage: wimlib-imagex exited 0 but no ntoskrnl.exe appeared in {0}' -f $DestDir)
    return $null
}

function Invoke-CleanSymbolPrestage {
    # Round 30: warms the local symbol cache with the ntoskrnl PDB
    # BEFORE the KD session starts, so the `bu nt!KeBugCheckEx`
    # breakpoint resolves from disk instead of stalling on a live
    # msdl download. Evidence: the round 29 micpe-kd.log ends with
    # 'DBGHELP: Timeout to store: ...\kd-symbols*https://msdl...'
    # and the transport dropped right after the connection, before
    # the init script printed anything. The real session keeps its
    # round 26 SRV* symbol path unchanged (same argv, same cache
    # directory) -- a warm cache simply means the download never
    # happens. Steps: (1) skip when already cached; (2) extract
    # ntoskrnl.exe from boot.wim; (3) symchk /v it against the SRV*
    # store; (4) verify the PDB landed in the cache. Best-effort:
    # any step may fail and the run continues with the round 29
    # behaviour; the summary file (micpe-symbol-prestage.txt) always
    # records the outcome so the check round can see whether the
    # cache was warm. Returns @{ Success; Reason; PdbPath; CacheDir;
    # SummaryPath }. Never throws.
    [CmdletBinding()]
    param(
        [string] $BootWimPath,

        [Parameter(Mandatory = $true)]
        [string] $WorkDir,

        [string] $SymchkPath,

        [string] $WimlibPath,

        [int] $TimeoutSec = 120
    )
    $cacheDir = Join-Path $WorkDir 'kd-symbols'
    $summaryPath = Join-Path $WorkDir 'micpe-symbol-prestage.txt'
    $finish = {
        param($success, $reason, $pdbPath, $details)
        $summary = [System.Collections.Generic.List[string]]::new()
        $summary.Add('symbol pre-stage (round 30: ntoskrnl.pdb into the local KD symbol cache)')
        $summary.Add(('outcome: {0}' -f $(if ($success) { 'cached' } else { 'not cached' })))
        $summary.Add(('reason: {0}' -f $reason))
        $summary.Add(('cache: {0}' -f $cacheDir))
        $summary.Add(('ntoskrnl.pdb: {0}' -f $(if ($pdbPath) { $pdbPath } else { 'none' })))
        # Round 31: the symchk diagnostics (command line, exit
        # code, input size, output tails). Round 30 reported only
        # 'exited 0 but no PDB' with no evidence of what symchk
        # actually did; the next check round needs these lines to
        # tell a wrong path from a wrong cache directory from a
        # silent no-op. Only the symchk branches pass $details.
        if ($null -ne $details -and $details.Count -gt 0) {
            $summary.Add('--- symchk diagnostics (round 31) ---')
            foreach ($d in $details) { $summary.Add($d) }
        }
        $summary | Set-Content -LiteralPath $summaryPath -Encoding ASCII
        return [pscustomobject]@{
            Success = $success; Reason = $reason; PdbPath = $pdbPath
            CacheDir = $cacheDir; SummaryPath = $summaryPath
        }
    }
    try {
        if (Test-CleanSymbolCache -CacheDir $cacheDir) {
            $pdb = Get-ChildItem -LiteralPath $cacheDir -Filter 'ntoskrnl.pdb' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
            $pdbPath = if ($pdb) { $pdb.FullName } else { $null }
            return (& $finish $true 'ntoskrnl.pdb already in the local cache (no download needed)' $pdbPath)
        }
        if (-not $BootWimPath -or -not (Test-Path -LiteralPath $BootWimPath -PathType Leaf)) {
            return (& $finish $false 'no boot.wim path (pre-stage skipped; the session keeps the SRV* symbol path)' $null)
        }
        $symchk = $SymchkPath
        if (-not $symchk) {
            $cdb = Get-CleanCdbPath
            $symchk = Get-CleanSymchkPath -CdbPath $cdb
        }
        if (-not $symchk) {
            return (& $finish $false 'symchk.exe not found (no Windows SDK Debuggers next to cdb.exe)' $null)
        }
        $wimlib = $WimlibPath
        if (-not $wimlib) { $wimlib = Get-CleanWimlibPath }
        if (-not $wimlib) {
            return (& $finish $false 'wimlib-imagex not found (cannot extract ntoskrnl.exe from boot.wim)' $null)
        }
        $extractDir = Join-Path $WorkDir 'kd-symbol-prestage'
        $ntoskrnl = Expand-CleanNtoskrnlFromWim -BootWimPath $BootWimPath -WimlibPath $wimlib -DestDir $extractDir -TimeoutSec 60
        if (-not $ntoskrnl) {
            return (& $finish $false 'could not extract ntoskrnl.exe from boot.wim (see wimlib-extract.err in kd-symbol-prestage)' $null)
        }
        # Round 31: the extracted file's size, for the diagnostics
        # below (a 0-byte or truncated extract explains a symchk
        # that exits 0 without producing a PDB).
        $ntoskrnlBytes = (Get-Item -LiteralPath $ntoskrnl -ErrorAction SilentlyContinue).Length
        $symPath = ('SRV*{0}*https://msdl.microsoft.com/download/symbols' -f $cacheDir)
        $outFile = Join-Path $WorkDir 'micpe-symbol-prestage-symchk.out'
        $errFile = Join-Path $WorkDir 'micpe-symbol-prestage-symchk.err'
        $proc = $null
        try {
            $proc = Invoke-CleanProcessToFile -FilePath $symchk `
                -ArgumentList @('/v', $ntoskrnl, '/s', $symPath) `
                -OutFile $outFile -ErrFile $errFile -TimeoutSec $TimeoutSec
        }
        catch {
            return (& $finish $false ('symchk failed to run (timeout {0} s or launch error: {1})' -f $TimeoutSec, $_.Exception.Message) $null)
        }
        # Round 31: record what symchk actually did before judging
        # the result. The summary file is the only evidence the
        # check round gets (the .out/.err files are not uploaded),
        # so the command line, exit code, input size and both
        # output tails go here.
        $symchkDetails = [System.Collections.Generic.List[string]]::new()
        $symchkDetails.Add(('symchk command: {0} /v {1} /s {2}' -f $symchk, $ntoskrnl, $symPath))
        $symchkDetails.Add(('symchk exit code: {0}' -f $proc.ExitCode))
        $symchkDetails.Add(('ntoskrnl.exe bytes: {0}' -f $(if ($null -ne $ntoskrnlBytes) { $ntoskrnlBytes } else { 'unknown' })))
        $outTail = @()
        if (Test-Path -LiteralPath $outFile) { $outTail = @(Get-Content -LiteralPath $outFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 30) }
        $symchkDetails.Add(('symchk stdout (last {0} non-empty lines):' -f $outTail.Count))
        if ($outTail.Count -gt 0) { foreach ($t in $outTail) { $symchkDetails.Add(('  {0}' -f $t)) } } else { $symchkDetails.Add('  (empty)') }
        $errTail = @()
        if (Test-Path -LiteralPath $errFile) { $errTail = @(Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 30) }
        $symchkDetails.Add(('symchk stderr (last {0} non-empty lines):' -f $errTail.Count))
        if ($errTail.Count -gt 0) { foreach ($t in $errTail) { $symchkDetails.Add(('  {0}' -f $t)) } } else { $symchkDetails.Add('  (empty)') }
        if ($proc.ExitCode -ne 0) {
            return (& $finish $false ('symchk exited {0} (see micpe-symbol-prestage-symchk.err)' -f $proc.ExitCode) $null $symchkDetails)
        }
        if (Test-CleanSymbolCache -CacheDir $cacheDir) {
            $pdb = Get-ChildItem -LiteralPath $cacheDir -Filter 'ntoskrnl.pdb' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
            $pdbPath = if ($pdb) { $pdb.FullName } else { $null }
            return (& $finish $true 'symchk fetched ntoskrnl.pdb into the local cache (the KD session will not download it live)' $pdbPath $symchkDetails)
        }
        return (& $finish $false 'symchk exited 0 but no ntoskrnl.pdb appeared in the cache' $null $symchkDetails)
    }
    catch {
        try { return (& $finish $false ('pre-stage aborted: {0}' -f $_.Exception.Message) $null) } catch {}
        return [pscustomobject]@{
            Success = $false; Reason = ('pre-stage aborted: {0}' -f $_.Exception.Message); PdbPath = $null
            CacheDir = $cacheDir; SummaryPath = $summaryPath
        }
    }
    finally {
        # The extracted ntoskrnl.exe is a scratch copy; the cache
        # holds the PDB. Best-effort cleanup, never throws.
        try {
            $extractDir = Join-Path $WorkDir 'kd-symbol-prestage'
            if (Test-Path -LiteralPath $extractDir -PathType Container) {
                Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        catch {}
    }
}

function Test-CleanKdPipe {
    # Round 31: does a named pipe \\.\pipe\$PipeName exist? The
    # pipe is QEMU's serial chardev (-serial pipe:) and the debugger
    # connects to it, so this is the round 27 TCP pre-check's
    # replacement: it proves (or disproves) that QEMU's serial
    # endpoint is up when kd.exe starts. It only ENUMERATES the pipe
    # directory -- it never opens or connects to the pipe, because a
    # named pipe accepts exactly one client and a probe connection
    # here would steal the debugger's only slot. Returns $false on
    # a missing pipe or any error (including a non-Windows host,
    # where \\.\pipe\ does not exist). Never throws.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $PipeName
    )
    try {
        $files = [System.IO.Directory]::GetFiles('\\.\pipe\')
        return ($files -contains ('\\.\pipe\' + $PipeName))
    }
    catch { return $false }
}

function Save-CleanKdConsoleOutput {
    # Round 27: drains the ReadToEndAsync tasks a background cdb
    # session leaves on its Process object (KdOutTask/KdErrTask note
    # properties, attached by Start-CleanKdSession) and writes them
    # to the console files. Never throws and never waits long: a task
    # that does not complete within the bound is skipped (the -logo
    # transcript is the primary evidence; the console files are the
    # backstop for a session that died before the log file was opened).
    [CmdletBinding()]
    param(
        $Process,

        [string] $OutFile,

        [string] $ErrFile,

        [int] $WaitSec = 10
    )
    if ($null -eq $Process) { return }
    $outTask = $null
    $errTask = $null
    $outProp = $Process.PSObject.Properties['KdOutTask']
    if ($null -ne $outProp) { $outTask = $outProp.Value }
    $errProp = $Process.PSObject.Properties['KdErrTask']
    if ($null -ne $errProp) { $errTask = $errProp.Value }
    if ($null -ne $outTask -and $OutFile) {
        try {
            if ($outTask.Wait([timespan]::FromSeconds($WaitSec)) -and $outTask.IsCompleted -and -not $outTask.IsFaulted -and -not $outTask.IsCanceled) {
                [System.IO.File]::WriteAllText($OutFile, ($outTask.Result -as [string]))
            }
        }
        catch {}
    }
    if ($null -ne $errTask -and $ErrFile) {
        try {
            if ($errTask.Wait([timespan]::FromSeconds($WaitSec)) -and $errTask.IsCompleted -and -not $errTask.IsFaulted -and -not $errTask.IsCanceled) {
                [System.IO.File]::WriteAllText($ErrFile, ($errTask.Result -as [string]))
            }
        }
        catch {}
    }
}

function Start-CleanKdSession {
    # Round 26: start cdb.exe as a background process attached to
    # the guest's KD serial port (QEMU -serial pipe:\\.\pipe\...,
    # round 31: a named pipe instead of the round 26 TCP chardev),
    # with a log file and a script file that sets a
    # deferred breakpoint on KeBugCheckEx and continues. Returns the
    # Process object, or $null when cdb is missing or could not start
    # (best-effort: the caller logs the reason and continues without
    # live KD). The caller kills the process in the finally block
    # (it exits on its own when QEMU quits and the pipe disconnects,
    # but never rely on that).
    #
    # Round 31 note on the script order (why `bu` still comes
    # before `g`, not the round 30 fallback (b) "g first, breakpoint
    # after"): the fallback was written for a session that stalls
    # INSIDE the script, but rounds 28/29/30 prove the script never
    # runs at all -- the START echo is absent from micpe-kd.log,
    # micpe-kd-console.out and the full run log in all three rounds,
    # and kd.exe goes straight from the kernel banner into the retry
    # storm. Reordering lines the debugger never reaches cannot fix
    # the handshake; the pipe is the one variable that can. And a
    # g-first script would be strictly worse once the handshake
    # works: `g` pauses the script until the next break-in, so `bu`
    # would only be set at the bugcheck break itself -- too late --
    # and the Arg2/Arg3 `du` strings (the whole point of the round)
    # would be lost. The old order (bu, bl, g) is kept verbatim.
    #
    # The debugger commands live in $InitScriptPath (a file, not a
    # -c string): -c "$$><path>" is a single quote-free token, so no
    # quoting layer can mangle the breakpoint's command list. The
    # argv is built with ProcessStartInfo.ArgumentList, so each
    # element is exactly one argument on any host (round 23 lesson:
    # Start-Process -ArgumentList splits arguments on spaces on
    # Linux). The init script itself:
    #   .echo *** KD-INIT START ***
    #   bu nt!KeBugCheckEx ".echo *** KEBUGCHECKEX HIT ***; r; du poi(@r8+8); du poi(@r9+8); ? poi(@rsp+0x20); g"
    #   bl
    #   .echo *** KD-INIT BU ISSUED ***
    #   g
    #   .echo *** KD-INIT G ISSUED ***
    # `bu` (not `bp`) is a deferred breakpoint: at the initial
    # break-in the symbols may not be ready yet, and `bu` resolves
    # via the export table (KeBugCheckEx is exported by ntoskrnl)
    # and stays pending until it can bind. `r` prints the registers
    # (rcx = bugcheck code, rdx = Arg1, r8 = Arg2, r9 = Arg3); the
    # two `du` print the UNICODE_STRING contents Arg2/Arg3 point at
    # (service registry path, driver image path); `?` prints the
    # Arg4 NTSTATUS from the stack; the trailing `g` continues into
    # the bugcheck, where cdb breaks again and logs the bugcheck
    # banner. No `!analyze -v` (needs interactive work at the
    # bugcheck break; a later round can add it). The bp commands use
    # only `r`/`du`/`?`/`.echo`, none of which needs PDBs -- but
    # round 29 showed the assumption "a slow symbol download can
    # only delay `g`" is wrong in practice: the log went straight
    # from the kernel banner to the transport retry storm with no
    # script output at all, so the download stall (DBGHELP timeout
    # on the SRV* store) coincides with the transport dropping.
    # Round 30 therefore pre-stages the ntoskrnl PDB into the
    # local cache before the session (Invoke-CleanSymbolPrestage)
    # and the script echoes its own progress, so the log now shows
    # exactly where the session stopped.
    #
    # Round 27: the argv comes from Get-CleanKdArgList (shared with
    # the probe, so a variant that survives the probe is launched
    # verbatim here); -DebuggerPath/-Variant select it (defaults
    # keep the round 26 behaviour). stdout/stderr are redirected and
    # drained asynchronously (the Invoke-CleanProcessToFile pattern):
    # round 26 inherited the console and the failing cdb printed
    # nothing anywhere, so the exit code was the only evidence. The
    # drain tasks ride on the returned Process object (KdOutTask /
    # KdErrTask) and are written to the console files by the caller
    # (finally block) or here on immediate exit.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $KdPipeName,

        [Parameter(Mandatory = $true)]
        [string] $WorkDir,

        [Parameter(Mandatory = $true)]
        [string] $KdLogPath,

        [Parameter(Mandatory = $true)]
        [string] $InitScriptPath,

        [string] $DebuggerPath,

        [ValidateSet('baseline', 'nosymbols', 'nologo', 'inline-c', 'noc')]
        [string] $Variant = 'baseline',

        [string] $ConsoleOutPath,

        [string] $ConsoleErrPath,

        [int] $StartupWaitSec = 5
    )

    $debugger = $DebuggerPath
    if (-not $debugger) { $debugger = Get-CleanCdbPath }
    if ($null -eq $debugger) {
        Write-Host 'live KD session skipped: cdb.exe not found (no Windows SDK Debuggers on this host); continuing without live KD'
        return $null
    }
    $version = Get-CleanDebuggerVersion -Path $debugger
    $verText = if ($version) { $version } else { 'unknown' }
    Write-Host ('live KD session: debugger {0} (version {1}), variant {2}' -f $debugger, $verText, $Variant)
    if ($Variant -eq 'noc') {
        Write-Host 'live KD session refused: the noc variant is probe-only (without -c nothing issues `g`, so the guest would halt at the initial breakpoint)'
        return $null
    }
    Write-CleanKdInitScript -InitScriptPath $InitScriptPath
    $argv = Get-CleanKdArgList -KdPipeName $KdPipeName -WorkDir $WorkDir -KdLogPath $KdLogPath -InitScriptPath $InitScriptPath -Variant $Variant
    Write-Host ('live KD session argv: {0} {1}' -f $debugger, ($argv -join ' '))
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $debugger
    foreach ($a in $argv) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        $null = $proc.Start()
    }
    catch {
        Write-Host "live KD session failed to start $debugger ($($_.Exception.Message))"
        return $null
    }
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $proc | Add-Member -NotePropertyName 'KdOutTask' -NotePropertyValue $outTask -Force
    $proc | Add-Member -NotePropertyName 'KdErrTask' -NotePropertyValue $errTask -Force
    # Round 29: remember which debugger binary this session runs, so
    # the bugcheck report names it -- the round 28 report still said
    # "round 26, cdb.exe" while the session actually ran kd.exe.
    $proc | Add-Member -NotePropertyName 'KdDebuggerName' -NotePropertyValue ([System.IO.Path]::GetFileName($debugger)) -Force
    # Give the debugger a moment to connect or fail fast on bad
    # arguments; a process that already exited here never attached
    # to anything.
    Start-Sleep -Seconds $StartupWaitSec
    if ($proc.HasExited) {
        Save-CleanKdConsoleOutput -Process $proc -OutFile $ConsoleOutPath -ErrFile $ConsoleErrPath
        $consoleHint = ''
        if ($ConsoleOutPath -or $ConsoleErrPath) {
            $consoleHint = ('; console output in {0} / {1}' -f $ConsoleOutPath, $ConsoleErrPath)
        }
        Write-Host ('live KD session: {0} exited immediately (exit {1}){2}' -f [System.IO.Path]::GetFileName($debugger), $proc.ExitCode, $consoleHint)
        return $null
    }
    Write-Host ('live KD session started: {0} (pid {1}) attached to pipe \\.\pipe\{2}, log {3}' -f [System.IO.Path]::GetFileName($debugger), $proc.Id, $KdPipeName, $KdLogPath)
    return $proc
}

function Invoke-CleanKdProbeAttempt {
    # Round 27: one probe variant against the fake KD peer. Starts
    # an async wait for the debugger's connect, runs the debugger
    # with the exact argv via Invoke-CleanProcessToFile (stdout/
    # stderr to files, killed at the timeout), and reports whether
    # it was still alive at the end of the observation window. A
    # timeout means ALIVE (the process had to be killed); a return
    # means it exited, with the exit code and the console files as
    # evidence. Never throws for a debugger failure; only a broken
    # pipe setup returns a failed attempt.
    # Round 31: the fake peer is a named pipe server
    # (\\.\pipe\$PipeName), not a TCP listener. Each attempt creates
    # its OWN server on the same name and disposes it in the finally
    # block: a NamedPipeServerStream accepts exactly one connection
    # per WaitForConnectionAsync call and cannot be re-armed, so
    # reusing one server across attempts would throw. A connected
    # peer is disconnected before disposal so the next attempt's
    # server can bind the same name. The probe's finally block
    # observes every AcceptTask (the connect task) when it stops.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DebuggerPath,

        [Parameter(Mandatory = $true)]
        [string[]] $ArgumentList,

        [Parameter(Mandatory = $true)]
        [string] $PipeName,

        [Parameter(Mandatory = $true)]
        [string] $WorkDir,

        [Parameter(Mandatory = $true)]
        [string] $Label,

        [int] $ObserveSeconds = 10
    )
    $outFile = Join-Path $WorkDir ('micpe-kd-probe-{0}.out' -f $Label)
    $errFile = Join-Path $WorkDir ('micpe-kd-probe-{0}.err' -f $Label)
    $connectTask = $null
    $alive = $false
    $exitCode = $null
    $errorText = ''
    $pipe = $null
    try {
        $pipe = [System.IO.Pipes.NamedPipeServerStream]::new($PipeName, [System.IO.Pipes.PipeDirection]::InOut, 1, [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous)
        $connectTask = $pipe.WaitForConnectionAsync()
    }
    catch {
        $errorText = ('cannot create a pipe server named \\.\pipe\{0}: {1}' -f $PipeName, $_.Exception.Message)
        return [pscustomobject]@{
            Label = $Label; Alive = $false; ExitCode = $null
            OutFile = $outFile; ErrFile = $errFile; Error = $errorText
            AcceptTask = $null
        }
    }
    try {
        $run = Invoke-CleanProcessToFile -FilePath $DebuggerPath `
            -ArgumentList $ArgumentList -OutFile $outFile -ErrFile $errFile `
            -TimeoutSec $ObserveSeconds
        $exitCode = $run.ExitCode
    }
    catch {
        if ($_.Exception.Message -match 'timed out') { $alive = $true }
        else { $errorText = $_.Exception.Message }
    }
    finally {
        # Disconnect a connected peer (the debugger did connect)
        # before disposing, so the next attempt can create a fresh
        # server on the same name; a still-pending wait is dropped
        # with the server.
        try { if ($pipe.IsConnected) { $pipe.Disconnect() } } catch {}
        try { $pipe.Dispose() } catch {}
    }
    return [pscustomobject]@{
        Label = $Label; Alive = $alive; ExitCode = $exitCode
        OutFile = $outFile; ErrFile = $errFile; Error = $errorText
        AcceptTask = $connectTask
    }
}

function Invoke-CleanKdProbe {
    # Round 27: pre-flight probe (see round27-design.md). Runs the
    # cdb variants against a fake pipe server (a silent peer: the
    # debugger must sit waiting for the target's initial breakpoint)
    # and returns the first variant that stays alive, or a result
    # with Variant $null when none does. Writes micpe-kd-probe.txt
    # (per-variant outcomes) and micpe-kd-probe-<variant>.out/.err
    # (each attempt's console). Returns $null when cdb is missing or
    # the pipe server cannot be created (probe inconclusive: the caller falls
    # back to the round 26 behaviour). Never throws for a debugger
    # failure; only a broken pipe setup returns $null.
    # Round 31: the fake peer is a named pipe server, not a TCP
    # listener -- the real session now connects to a pipe, so the
    # probe must present the same kind of peer. The server is
    # created fresh per attempt (see Invoke-CleanKdProbeAttempt);
    # the one-shot creation here only proves the pipe name is
    # usable on this host before the variants run.
    # Round 28: the returned Variant is the ARGV variant for the
    # real session, never a probe label. The variants table splits
    # Label from Variant on purpose -- 'kd' wins with the baseline
    # argv and kd.exe as the binary -- and round 27 returned the
    # label instead, which Start-CleanKdSession's Variant
    # ValidateSet correctly rejected ('kd' is a binary choice, not
    # an argv shape). Label carries the winning probe label for the
    # summary and the call-site log only.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $WorkDir,

        [Parameter(Mandatory = $true)]
        [string] $KdLogPath,

        [Parameter(Mandatory = $true)]
        [string] $InitScriptPath,

        [string] $ProbePipeName = 'micpe-kd-probe',

        [int] $ObserveSeconds = 10,

        [string] $CdbPath
    )
    $cdb = $CdbPath
    if (-not $cdb) { $cdb = Get-CleanCdbPath }
    if ($null -eq $cdb) {
        Write-Host 'KD probe skipped: cdb.exe not found (no Windows SDK Debuggers on this host); continuing without live KD'
        return $null
    }
    $version = Get-CleanDebuggerVersion -Path $cdb
    $verText = if ($version) { $version } else { 'unknown' }
    Write-Host ('KD probe: debugger {0} (version {1}), fake pipe server on \\.\pipe\{2}' -f $cdb, $verText, $ProbePipeName)
    Write-CleanKdInitScript -InitScriptPath $InitScriptPath
    # Round 31: prove the pipe name is creatable on this host
    # before the variants run (a name the host cannot create makes
    # the probe inconclusive, exactly like the round 27 listener
    # that could not start). The server is disposed immediately;
    # each attempt creates its own.
    try {
        $testPipe = [System.IO.Pipes.NamedPipeServerStream]::new($ProbePipeName, [System.IO.Pipes.PipeDirection]::InOut, 1, [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous)
        $testPipe.Dispose()
    }
    catch {
        Write-Host ('KD probe inconclusive: cannot create a pipe server named \\.\pipe\{0} ({1})' -f $ProbePipeName, $_.Exception.Message)
        return $null
    }
    $attempts = @()
    $winner = $null
    $winnerLabel = $null
    $winnerDebugger = $null
    try {
        $kdExe = Get-CleanKdPath -CdbPath $cdb
        $variants = @(
            @{ Label = 'baseline'; Debugger = $cdb; Variant = 'baseline' }
            @{ Label = 'kd'; Debugger = $kdExe; Variant = 'baseline' }
            @{ Label = 'nosymbols'; Debugger = $cdb; Variant = 'nosymbols' }
            @{ Label = 'nologo'; Debugger = $cdb; Variant = 'nologo' }
            @{ Label = 'inline-c'; Debugger = $cdb; Variant = 'inline-c' }
            @{ Label = 'noc'; Debugger = $cdb; Variant = 'noc' }
        )
        foreach ($v in $variants) {
            if ($null -eq $v.Debugger) {
                Write-Host ('KD probe: variant {0} skipped (debugger binary not found)' -f $v.Label)
                continue
            }
            $probeLog = Join-Path $WorkDir ('micpe-kd-probe-{0}.log' -f $v.Label)
            $argv = Get-CleanKdArgList -KdPipeName $ProbePipeName -WorkDir $WorkDir -KdLogPath $probeLog -InitScriptPath $InitScriptPath -Variant $v.Variant
            $attempt = Invoke-CleanKdProbeAttempt -DebuggerPath $v.Debugger -ArgumentList $argv -PipeName $ProbePipeName -WorkDir $WorkDir -Label $v.Label -ObserveSeconds $ObserveSeconds
            $attempts += $attempt
            if ($attempt.Alive) {
                if ($v.Label -eq 'noc') {
                    Write-Host 'KD probe: only the no--c variant stays alive -- the -c token is the trigger (probe-only, never used for the real session)'
                }
                else {
                    # Round 28: keep the ARGV variant, not the probe
                    # label. 'kd' wins with the baseline argv and
                    # kd.exe as the binary; handing the label 'kd'
                    # to Start-CleanKdSession was the round 27
                    # failure (its Variant ValidateSet rightly
                    # rejects a binary label as an argv shape).
                    $winner = $v.Variant
                    $winnerLabel = $v.Label
                    $winnerDebugger = $v.Debugger
                    Write-Host ('KD probe: variant {0} stays alive ({1} s); using it for the real session' -f $v.Label, $ObserveSeconds)
                }
                break
            }
            $outTail = @()
            $errTail = @()
            if (Test-Path -LiteralPath $attempt.OutFile) { $outTail = @(Get-Content -LiteralPath $attempt.OutFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 5) }
            if (Test-Path -LiteralPath $attempt.ErrFile) { $errTail = @(Get-Content -LiteralPath $attempt.ErrFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 5) }
            $detail = ''
            if ($attempt.Error) { $detail = ('launch error: {0}' -f $attempt.Error) }
            elseif ($null -ne $attempt.ExitCode) { $detail = ('exit {0}' -f $attempt.ExitCode) }
            $consoleBits = @()
            if ($outTail.Count -gt 0) { $consoleBits += ('stdout: {0}' -f ($outTail -join ' | ')) }
            if ($errTail.Count -gt 0) { $consoleBits += ('stderr: {0}' -f ($errTail -join ' | ')) }
            if ($consoleBits.Count -eq 0) { $consoleBits += 'no console output at all' }
            Write-Host ('KD probe: variant {0} failed ({1}); {2}' -f $v.Label, $detail, ($consoleBits -join '; '))
        }
    }
    finally {
        # Round 31: no shared listener to stop -- each attempt
        # creates and disposes its own pipe server. Only the connect
        # tasks are observed here (a disposed server's pending wait
        # faults, which the try/catch swallows).
        foreach ($a in $attempts) {
            if ($null -ne $a.AcceptTask) {
                try { $null = $a.AcceptTask.Wait(1000) } catch {}
            }
        }
    }
    $summaryPath = Join-Path $WorkDir 'micpe-kd-probe.txt'
    $summary = [System.Collections.Generic.List[string]]::new()
    $summary.Add('KD launch probe (round 27, fake pipe server -- the debugger must sit waiting for the target initial breakpoint)')
    $summary.Add(('debugger: {0} (version {1})' -f $cdb, $verText))
    $summary.Add(('fake pipe server: \\.\pipe\{0}; observation window: {1} s per variant' -f $ProbePipeName, $ObserveSeconds))
    foreach ($a in $attempts) {
        if ($a.Alive) { $summary.Add(('variant {0}: ALIVE at {1} s (still running when killed)' -f $a.Label, $ObserveSeconds)) }
        elseif ($a.Error) { $summary.Add(('variant {0}: FAILED to launch ({1})' -f $a.Label, $a.Error)) }
        else { $summary.Add(('variant {0}: EXITED fast (exit {1}); console: {2} / {3}' -f $a.Label, $a.ExitCode, $a.OutFile, $a.ErrFile)) }
    }
    if ($winner) { $summary.Add(('result: variant {0} ({1}) selected for the real session' -f $winnerLabel, $winnerDebugger)) }
    elseif (@($attempts | Where-Object { $_.Alive }).Count -gt 0) { $summary.Add('result: only the no--c variant stays alive -- the -c token is the trigger; the real KD session is disabled this run') }
    else { $summary.Add('result: no variant stays alive; the real KD session is disabled this run') }
    $summary | Set-Content -LiteralPath $summaryPath -Encoding ASCII
    Write-Host ('KD probe summary: {0}' -f $summaryPath)
    return [pscustomobject]@{
        Variant = $winner; Label = $winnerLabel; DebuggerPath = $winnerDebugger
        Attempts = $attempts; SummaryPath = $summaryPath
    }
}

function ConvertFrom-CleanKdLog {
    # Round 26: parses a cdb -logo session transcript for the 0x5A
    # bugcheck. The transcript holds (a) the bugcheck banner the
    # kernel prints when the debugger breaks in on KeBugCheckEx, and
    # (b) the two `du` lines from the `bu nt!KeBugCheckEx` breakpoint
    # (the UNICODE_STRING contents: service registry path and driver
    # image path). The register dump and the `?` output (Arg4 from
    # the stack) are in the log for manual cross-check but are not
    # parsed -- the banner is authoritative (it comes from the
    # kernel). Pure parser, unit-testable. Returns
    # @{ BugCheck; Arg2String; Arg3String; Connected; BrokeIn;
    # InitStarted; InitBuIssued; InitGIssued; Reason } -- BugCheck is
    # $null when the log has no bugcheck banner (KD never connected,
    # never broke in, or the guest never bugchecked); Reason then
    # says which, from the log's own lines, so the caller reports the
    # failure instead of inventing parameters. The banner is
    # authoritative (it comes from the kernel); the registers are
    # corroboration only. The `?` output (Arg4 from the stack) is in
    # the log for manual cross-check.
    # Round 30: also reads the init script's .echo progress markers
    # (KD-INIT START / BU ISSUED / G ISSUED) into InitStarted /
    # InitBuIssued / InitGIssued, so the caller can tell whether the
    # -c script ran at all and whether `g` got through. Logs from
    # before round 30 have no markers, so all three stay $false and
    # the Reason falls back to the round 26 wording.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Content
    )

    $result = [pscustomobject]@{
        BugCheck = $null
        Arg2String = $null
        Arg3String = $null
        Connected = $false
        BrokeIn = $false
        InitStarted = $false
        InitBuIssued = $false
        InitGIssued = $false
        Reason = 'KD log is empty (cdb produced no output)'
    }
    if ([string]::IsNullOrWhiteSpace($Content)) { return $result }
    $lines = ($Content -split "`r`n|`n")
    if ($Content -match 'Connected to Windows') { $result.Connected = $true }
    $markerIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        # The .echo output line itself (*** KEBUGCHECKEX HIT ***), not
        # the `kd> bu ...` command echo, which contains the same text
        # inside its quotes.
        if ($lines[$i] -match '^\s*\*\*\* KEBUGCHECKEX HIT \*\*\*\s*$') { $markerIdx = $i; break }
    }
    # Round 30 init-script progress markers (see
    # Write-CleanKdInitScript). The .echo output lines are exact
    # lines of their own, so the anchored match cannot hit the
    # command echo inside the `bu` line.
    foreach ($l in $lines) {
        if ($l -match '^\s*\*\*\* KD-INIT START \*\*\*\s*$') { $result.InitStarted = $true }
        if ($l -match '^\s*\*\*\* KD-INIT BU ISSUED \*\*\*\s*$') { $result.InitBuIssued = $true }
        if ($l -match '^\s*\*\*\* KD-INIT G ISSUED \*\*\*\s*$') { $result.InitGIssued = $true }
    }
    $result.BrokeIn = ($markerIdx -ge 0)
    # Bugcheck banner (cdb prints it when it breaks in on the bugcheck):
    #   *** Fatal System Error: 0x0000005a
    #         (0x0000000000000001,0xffff...,0xffff...,0xffffffffc0000428)
    for ($i = 0; $i -lt ($lines.Count - 1); $i++) {
        $m = [regex]::Match($lines[$i], 'Fatal System Error:\s*0x([0-9a-fA-F]+)')
        if (-not $m.Success) { continue }
        $a = [regex]::Match($lines[$i + 1], '\(\s*0x([0-9a-fA-F]+)\s*,\s*0x([0-9a-fA-F]+)\s*,\s*0x([0-9a-fA-F]+)\s*,\s*0x([0-9a-fA-F]+)\s*\)')
        if ($a.Success) {
            $result.BugCheck = [pscustomobject]@{
                BugCheckCode = ('0x{0}' -f $m.Groups[1].Value.ToLowerInvariant())
                Arg1 = ('0x{0}' -f $a.Groups[1].Value.ToLowerInvariant())
                Arg2 = ('0x{0}' -f $a.Groups[2].Value.ToLowerInvariant())
                Arg3 = ('0x{0}' -f $a.Groups[3].Value.ToLowerInvariant())
                Arg4 = ('0x{0}' -f $a.Groups[4].Value.ToLowerInvariant())
            }
            $result.Reason = 'bugcheck banner found in the live KD log'
            break
        }
    }
    if ($markerIdx -ge 0) {
        # Path-like lines after the marker are the two `du` outputs
        # (first = Arg2's string, second = Arg3's): a bare string
        # with no whitespace, starting with a backslash. The `r`
        # output lines contain '=' and the `?` output starts with
        # 'Evaluate expression:', so neither can match.
        $paths = [System.Collections.Generic.List[string]]::new()
        for ($i = $markerIdx; $i -lt $lines.Count; $i++) {
            $t = $lines[$i].Trim()
            if ($t -match '^\\[^\s]{7,}$') { $paths.Add($t) }
        }
        if ($paths.Count -ge 1) { $result.Arg2String = $paths[0] }
        if ($paths.Count -ge 2) { $result.Arg3String = $paths[1] }
        if ($null -eq $result.BugCheck) {
            $result.Reason = 'the KeBugCheckEx breakpoint fired, but no bugcheck banner followed (cdb was killed before the banner, or the breakpoint fired on a different path)'
        }
    }
    elseif ($null -eq $result.BugCheck) {
        if (-not $result.Connected) {
            if ($Content -match 'Waiting to reconnect|Waiting for reconnect|could not connect|Connection refused') {
                $result.Reason = 'KD never connected to the guest (cdb could not reach the QEMU serial TCP port)'
            }
            else {
                $result.Reason = 'KD never connected to the guest (no "Connected to Windows" in the log)'
            }
        }
        else {
            if ($result.InitStarted) {
                # The round 30 init script echoes its own progress,
                # so the log itself says where the session stopped:
                # START with no G ISSUED means the transport dropped
                # while the script ran and `g` never got through.
                if ($result.InitGIssued) {
                    $result.Reason = 'KD connected and the init script ran (g issued), but the KeBugCheckEx breakpoint never fired (the guest never bugchecked, or the breakpoint did not resolve)'
                }
                else {
                    $result.Reason = 'KD connected and the init script started, but g was never issued (the transport dropped while the script ran)'
                }
            }
            else {
                $result.Reason = 'KD connected, but the KeBugCheckEx breakpoint never fired (the guest never bugchecked, or the breakpoint did not resolve)'
            }
        }
    }
    return $result
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
    # Round 24: the round 23 capture died AFTER a successful attach
    # with "The property 'Length' cannot be found on this object" --
    # the volume-contents line read .Length on "System Volume
    # Information", which is a directory (DirectoryInfo has no
    # .Length; StrictMode turns the read into a throw). The listing
    # is now Format-CleanVolumeContents (directories shown as such),
    # and Add-CleanVolumeList runs on every attach success plus in
    # the catch -- rounds 22-23 only wired it into the three attach
    # failure paths, so the promised Get-Volume diagnosis never
    # appeared in micpe-bugcheck.txt. The disk's MBR signature is
    # read at the start of the capture and searched for in the ELF:
    # found = the guest read this disk's MBR (enumerated); absent =
    # the guest never got that far, and the drive-letter question is
    # moot for a bugcheck this early. The ELF scan also validates
    # the core dump's program headers first and validates up to
    # 200 loose hits (round 23 examined only 10 of 125).
    [CmdletBinding()]
    param(
        [string] $Qcow2Path,

        [Parameter(Mandatory = $true)]
        [string] $QemuImgPath,

        [Parameter(Mandatory = $true)]
        [string] $WorkDir,

        [string] $RizinVersion = 'v0.9.1',

        [string] $ElfPath,

        # Round 26: the live KD session log (cdb.exe -logo). Parsed
        # first, before the disk path: it is the most direct evidence
        # (the kernel's own bugcheck banner), and when it yields a
        # BugCheck the ELF scan is skipped like a good disk dump.
        [string] $KdLogPath,

        # Round 27: the pre-flight probe summary (micpe-kd-probe.txt)
        # and the real session's console files. They are the evidence
        # when cdb died before the -logo file was opened (round 26:
        # no log, no output, only the exit code).
        [string] $KdProbePath,

        [string] $KdConsoleOutPath,

        [string] $KdConsoleErrPath,

        # Round 29: the debugger binary the live session ran
        # ('kd.exe' / 'cdb.exe'; empty when no session ran) and the
        # QEMU monitor status queried before 'quit'. Both ride the
        # report so the round 28 freeze has a second witness.
        [string] $KdDebuggerName,

        [AllowEmptyCollection()]
        [string[]] $MonitorStatus,

        # Round 30: the symbol pre-stage summary
        # (micpe-symbol-prestage.txt) -- whether ntoskrnl.pdb was
        # already in the local cache when the KD session started.
        # Empty when the pre-stage was skipped (no-KD control pass).
        [string] $SymbolPrestagePath
    )

    $reportPath = Join-Path $WorkDir 'micpe-bugcheck.txt'
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('MICPE crash-dump capture (round 21: 0x5A bugcheck parameters)')
    if ($Qcow2Path) { $lines.Add(('QEMU dump disk: {0}' -f $Qcow2Path)) }
    # Round 24: the drive letter the dump is expected on. This is the
    # DESIGN expectation, not an observation -- the disk is
    # if=ide,index=0 (the first fixed disk; the CD-ROM is the second
    # drive) and WinPE's own RAM disk is X:, so the first fixed disk
    # should be C: in the guest and DedicatedDumpFile (C:\...) should
    # land on it. The volume listing and the MBR-signature search
    # below are the observation that tests this expectation; if they
    # say otherwise, this line is the claim being falsified.
    $lines.Add('expected drive letter: C: (dump disk is if=ide,index=0, the first fixed disk; WinPE''s own RAM disk is X: -- design expectation, not an observation)')
    # Round 29: the QEMU monitor status queried before 'quit' (info
    # status / info registers / info vcpus) -- the second witness for
    # the round 28 firmware freeze, next to the screenshots. Present
    # even when there is no KD log and no dump disk.
    if ($MonitorStatus -and $MonitorStatus.Count -gt 0) {
        $lines.Add('--- QEMU monitor status (queried before quit) ---')
        foreach ($ml in $MonitorStatus) { $lines.Add($ml) }
    }
    # Round 30: the symbol pre-stage outcome (was ntoskrnl.pdb
    # already in the local cache when the KD session started?). The
    # summary file is written by Invoke-CleanSymbolPrestage even when
    # the pre-stage failed, so a missing file here means the
    # pre-stage never ran (control pass, or an older script).
    if ($SymbolPrestagePath -and (Test-Path -LiteralPath $SymbolPrestagePath)) {
        $preContent = Get-Content -LiteralPath $SymbolPrestagePath -Raw -ErrorAction SilentlyContinue
        if ($preContent) {
            $lines.Add('--- symbol pre-stage (round 30, ntoskrnl.pdb) ---')
            foreach ($pl in ($preContent -split "`r`n|`n")) {
                if ($pl.Trim() -ne '') { $lines.Add(('  {0}' -f $pl)) }
            }
        }
    }
    $result = [pscustomobject]@{ DumpFound = $false; BugCheck = $null; ReportPath = $reportPath; DiskPath = $null }
    # Round 26: parse the live KD log first (before the disk path,
    # and outside the try so it runs even when there is no dump disk
    # to read back -- the early return below still runs the finally,
    # which writes these lines). The caller kills cdb before calling
    # this function, so the log is complete.
    if ($KdLogPath) {
        if (Test-Path -LiteralPath $KdLogPath) {
            $kdContent = Get-Content -LiteralPath $KdLogPath -Raw -ErrorAction SilentlyContinue
            $kdParsed = ConvertFrom-CleanKdLog -Content ($kdContent -as [string])
            $kdHeader = if ($KdDebuggerName) { ('--- live KD session ({0}) ---' -f $KdDebuggerName) } else { '--- live KD session ---' }
            $lines.Add($kdHeader)
            if ($null -ne $kdParsed.BugCheck) {
                $lines.Add(('RESULT (live KD): BugCheckCode={0} Arg1={1} Arg2={2} Arg3={3} Arg4={4}' -f $kdParsed.BugCheck.BugCheckCode, $kdParsed.BugCheck.Arg1, $kdParsed.BugCheck.Arg2, $kdParsed.BugCheck.Arg3, $kdParsed.BugCheck.Arg4))
                $result.BugCheck = $kdParsed.BugCheck
                $result.DumpFound = $true
                if ($kdParsed.Arg2String) { $lines.Add(('Arg2 (service registry path, live KD): {0}' -f $kdParsed.Arg2String)) }
                if ($kdParsed.Arg3String) { $lines.Add(('Arg3 (driver image path, live KD): {0}' -f $kdParsed.Arg3String)) }
            }
            else {
                $lines.Add(('live KD produced no bugcheck parameters: {0}' -f $kdParsed.Reason))
                # Note: '-or' on strings returns a Boolean in
                # PowerShell, so the fallback needs an explicit if --
                # ($KdDebuggerName -or 'the debugger') would print
                # 'True' here.
                $kdNameText = if ($KdDebuggerName) { $KdDebuggerName } else { 'the debugger' }
                if ($kdParsed.Connected) { $lines.Add(('live KD: {0} did connect to the guest' -f $kdNameText)) }
                if ($kdParsed.BrokeIn) { $lines.Add('live KD: the KeBugCheckEx breakpoint did fire') }
                # Round 30: the init script's own progress markers.
                # Only when at least one marker is present -- logs
                # from before round 30 have none, and reporting
                # 'started=False' for them would be wrong (the old
                # script had no markers to print).
                if ($kdParsed.InitStarted -or $kdParsed.InitBuIssued -or $kdParsed.InitGIssued) {
                    $lines.Add(('live KD init script: started={0}, bu-issued={1}, g-issued={2}' -f $kdParsed.InitStarted, $kdParsed.InitBuIssued, $kdParsed.InitGIssued))
                }
                $tail = @(($kdContent -split "`r`n|`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 20)
                if ($tail.Count -gt 0) {
                    $lines.Add('live KD log tail (last 20 non-empty lines; the full log is micpe-kd.log in the Release):')
                    foreach ($tl in $tail) { $lines.Add(('  {0}' -f $tl)) }
                }
            }
        }
        else {
            $lines.Add(('live KD session: no log file at {0} (cdb never started, or -NoKdSession)' -f $KdLogPath))
        }
    }
    # Round 27: the pre-flight probe summary and the real session's
    # console files. These are the evidence when cdb died before the
    # -logo file was opened (round 26: no log, no output, only the
    # exit code). Appended only when the -logo parse yielded no
    # parameters (a working session's banner already says it all).
    if ($null -eq $result.BugCheck) {
        if ($KdProbePath -and (Test-Path -LiteralPath $KdProbePath)) {
            $probeContent = Get-Content -LiteralPath $KdProbePath -Raw -ErrorAction SilentlyContinue
            if ($probeContent) {
                $lines.Add('--- KD launch probe (round 27, fake pipe server) ---')
                foreach ($pl in ($probeContent -split "`r`n|`n")) {
                    if ($pl.Trim() -ne '') { $lines.Add(('  {0}' -f $pl)) }
                }
            }
        }
        foreach ($consoleFile in @($KdConsoleOutPath, $KdConsoleErrPath)) {
            if ($consoleFile -and (Test-Path -LiteralPath $consoleFile)) {
                $consoleContent = Get-Content -LiteralPath $consoleFile -Raw -ErrorAction SilentlyContinue
                $consoleTail = @(($consoleContent -split "`r`n|`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 20)
                if ($consoleTail.Count -gt 0) {
                    $lines.Add(('KD console tail ({0}, last 20 non-empty lines; the full file is in the Release):' -f [System.IO.Path]::GetFileName($consoleFile)))
                    foreach ($cl in $consoleTail) { $lines.Add(('  {0}' -f $cl)) }
                }
            }
        }
    }
    $vhdx = Join-Path $WorkDir 'micpe-dumpdisk-read.vhdx'
    $vhd = Join-Path $WorkDir 'micpe-dumpdisk-read.vhd'
    $attachedLetter = $null
    $diskFile = $null
    $volumesListed = $false
    $diskSignature = [UInt32]0
    try {
        if (-not $Qcow2Path -or -not (Test-Path -LiteralPath $Qcow2Path)) {
            # No dump disk to read back (creation failed, or the caller
            # only has a guest-memory ELF). Skip the disk path; the
            # return still runs the finally below, which scans the ELF
            # (if any) and writes the report.
            $lines.Add('no qcow2 dump disk to read back (creation failed or no disk); skipping the disk path')
            return $result
        }
        # Round 24: read the disk's MBR signature now -- the qcow2
        # is deleted once an image attaches, and the signature is
        # needed by the ELF scan to test whether the guest ever read
        # this disk's MBR.
        $sig = Get-CleanDiskSignature -QemuImgPath $QemuImgPath -Qcow2Path $Qcow2Path -WorkDir $WorkDir -Lines $lines
        if ($null -ne $sig -and $sig -ne 0) { $diskSignature = $sig }
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
        # Round 24: the volume listing now runs on every attach
        # success, not only on attach failure -- rounds 22-23
        # promised it in the report and it never appeared, because
        # Add-CleanVolumeList was only wired into the three attach
        # failure paths.
        Add-CleanVolumeList -Lines $lines
        $volumesListed = $true
        Remove-Item -LiteralPath $Qcow2Path -Force -ErrorAction SilentlyContinue
        $dumpFile = "${attachedLetter}:\dedicateddumpfile.sys"
        $lines.Add(('attached as {0}: ; dump file path {1}' -f $attachedLetter, $dumpFile))
        # Round 24: Format-CleanVolumeContents lists directories
        # without touching .Length (round 23 died here: a fresh
        # NTFS root always contains "System Volume Information",
        # and DirectoryInfo has no .Length -- under StrictMode the
        # read throws before the volume-contents line is written).
        $volEntries = @(Get-ChildItem -LiteralPath "${attachedLetter}:\" -Force -ErrorAction SilentlyContinue)
        $lines.Add(('volume contents: {0}' -f (Format-CleanVolumeContents -Entries $volEntries)))
        if (-not (Test-Path -LiteralPath $dumpFile)) {
            $lines.Add('RESULT: NO DUMP FILE -- the blue screen did not write a dedicated dump file to the second disk.')
            $lines.Add('This is expected when the system booted cleanly (no bugcheck, nothing to write). It is a problem only when the screenshots show a blue screen; then the causes are: (1) the crash-dump stack was not initialised yet when the 0x5A fired at IopLoadDriver time; (2) the second disk was not C: in WinPE, so DedicatedDumpFile pointed at the wrong letter; (3) the disk was not enumerated in time. The disk was attached and readable, so the file really is absent.')
            $lines.Add('Next step if the screenshots show a blue screen and this repeats: read micpe-kd.log (live KD session) and micpe-kd-probe.txt (round 27 pre-flight probe) -- if the probe found no working argv, its console files say why cdb would not start. Re-checking the drive letter with a WinPE command-line probe is the remaining fallback.')
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
        # Round 24: if the attach succeeded but the read-back died
        # (round 23: the .Length error), the volume listing still
        # belongs in the report -- it is the drive-letter evidence.
        if (-not $volumesListed) { Add-CleanVolumeList -Lines $lines }
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
                $elfScan = Invoke-CleanElfBugCheckScan -RizinPath $rizin -ElfPath $ElfPath -WorkDir $WorkDir -DiskSignature $diskSignature -Lines $lines
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

# Round 26: the serial port now goes to cdb over TCP (see -serial
# below), so there is no micpe-serial.log any more; the KD session
# log (micpe-kd.log) is the replacement, uploaded by the workflow.
$kdLog = Join-Path $WorkDir 'micpe-kd.log'
$kdInit = Join-Path $WorkDir 'kd-init.txt'
# Round 27: the real session's stdout/stderr (drained by the finally
# block) and the pre-flight probe summary. All three ride the
# artifact + Release uploads with micpe-kd.log.
$kdConsoleOut = Join-Path $WorkDir 'micpe-kd-console.out'
$kdConsoleErr = Join-Path $WorkDir 'micpe-kd-console.err'
$kdProbeSummary = Join-Path $WorkDir 'micpe-kd-probe.txt'
$script:kdProbeResult = $null
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
    # Round 26: the guest COM1 (kernel debug) goes to a TCP server
    # for the live KD session instead of a file; without a debugger
    # the output is discarded (the old micpe-serial.log is gone --
    # see micpe-kd.log). `server,nowait` means QEMU never blocks
    # waiting for cdb to connect.
    '-serial', "pipe:\\.\pipe\$KdPipeName"
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

# Round 30: symbol pre-stage -- warm the local KD symbol cache
# with the ntoskrnl PDB BEFORE the probe and the real session run,
# so `bu nt!KeBugCheckEx` resolves from disk instead of stalling on
# a live msdl download. Evidence: the round 29 micpe-kd.log ends
# with 'DBGHELP: Timeout to store: ...\kd-symbols*https://msdl...'
# and the transport dropped right after the connection. Best-effort
# only: a failed pre-stage only warns, and the session keeps the
# round 26 SRV* symbol path (the argv is unchanged either way).
# The summary (micpe-symbol-prestage.txt) rides micpe-bugcheck.txt
# via -SymbolPrestagePath on the capture call below.
$symbolPrestageSummary = Join-Path $WorkDir 'micpe-symbol-prestage.txt'
$script:symbolPrestageResult = $null
if (-not $NoKdSession) {
    try {
        $script:symbolPrestageResult = Invoke-CleanSymbolPrestage -BootWimPath $BootWimPath -WorkDir $WorkDir -TimeoutSec 120
        if ($null -ne $script:symbolPrestageResult) {
            Write-Host ('symbol pre-stage: {0}' -f $script:symbolPrestageResult.Reason)
        }
    }
    catch {
        Write-Host "!!! symbol pre-stage failed (diagnostic only, continuing with the SRV* symbol path): $($_.Exception.Message)"
        $script:symbolPrestageResult = $null
    }
}

# Round 27: pre-flight KD probe -- reproduce the round 26 cdb launch
# against a fake pipe server BEFORE QEMU starts, so a failing argv
# is diagnosed without touching the guest. Runs only when the KD
# session is enabled; never throws, never changes the verdict. The
# result decides which argv (if any) the real session uses below.
if (-not $NoKdSession) {
    try {
        $script:kdProbeResult = Invoke-CleanKdProbe -WorkDir $WorkDir -KdLogPath $kdLog -InitScriptPath $kdInit
        if ($null -ne $script:kdProbeResult -and $null -ne $script:kdProbeResult.Variant) {
            # Round 28: log the probe label ('kd') so this line
            # matches micpe-kd-probe.txt; Variant is the argv shape
            # ('baseline' for the kd winner) and goes to the session.
            $probeLabel = $script:kdProbeResult.Label
            if ($null -eq $probeLabel) { $probeLabel = $script:kdProbeResult.Variant }
            Write-Host ('KD probe: using variant {0} ({1}) for the real session' -f $probeLabel, $script:kdProbeResult.DebuggerPath)
        }
        elseif ($null -ne $script:kdProbeResult) {
            Write-Host 'KD probe: no variant stays alive; the real KD session is disabled this run (see micpe-kd-probe.txt)'
        }
    }
    catch {
        Write-Host "!!! KD probe failed (diagnostic only, continuing with the round 26 baseline): $($_.Exception.Message)"
        $script:kdProbeResult = $null
    }
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
$script:kdProc = $null
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

    # Round 26: attach the live KD session now, while the guest is
    # still early in boot -- the kernel re-sends its initial
    # breakpoint only for a while (round 24: 26 retries, then silence),
    # so the debugger must be attached from the start. Best-effort
    # only: a KD failure is logged, never throws, never changes the
    # run's verdict.
    # Round 27: the argv comes from the pre-flight probe (a variant
    # that survived it is launched verbatim); when the probe ran and
    # every variant failed, the real session is not launched with a
    # known-bad argv. When the probe was inconclusive (no cdb, or the
    # fake pipe server could not be created), fall back to the round 26
    # baseline -- the new console redirect captures any failure.
    if (-not $NoKdSession) {
        try {
            if ($null -ne $script:kdProbeResult -and $null -eq $script:kdProbeResult.Variant) {
                Write-Host '!!! live KD session not started: the probe found no working argv (see micpe-kd-probe.txt); continuing without live KD (disk/ELF paths remain)'
                $script:kdProc = $null
            }
            else {
                $probeVariant = 'baseline'
                $probeDebugger = $null
                if ($null -ne $script:kdProbeResult) {
                    $probeVariant = $script:kdProbeResult.Variant
                    $probeDebugger = $script:kdProbeResult.DebuggerPath
                }
                # Round 27: confirm the QEMU serial endpoint is up
                # before launching the debugger (round 26 never
                # proved it was). A negative answer only warns: the
                # debugger retries the connect, and the console
                # files will show what happens. Round 31: the check
                # enumerates the pipe directory only -- it never
                # opens the pipe (one client only; a probe
                # connection would steal the debugger's slot).
                $kdPipePresent = Test-CleanKdPipe -PipeName $KdPipeName
                Write-Host ('KD named pipe \\.\pipe\{0} present: {1}' -f $KdPipeName, $kdPipePresent)
                if (-not $kdPipePresent) { Write-Host '!!! KD named pipe is not present yet; starting the debugger anyway (it retries the connect)' }
                $script:kdProc = Start-CleanKdSession -KdPipeName $KdPipeName -WorkDir $WorkDir -KdLogPath $kdLog -InitScriptPath $kdInit -DebuggerPath $probeDebugger -Variant $probeVariant -ConsoleOutPath $kdConsoleOut -ConsoleErrPath $kdConsoleErr
                if ($null -eq $script:kdProc) { Write-Host '!!! live KD session not started; continuing without live KD (disk/ELF paths remain)' }
            }
        }
        catch {
            Write-Host "!!! live KD session failed to start (diagnostic only): $($_.Exception.Message)"
            $script:kdProc = $null
        }
    }
    else {
        Write-Host 'live KD session disabled (-NoKdSession); the serial output is discarded'
    }

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
    # Round 29: ask the monitor what state the guest is in BEFORE
    # anything kills QEMU -- the round 28 freeze needs a second
    # witness besides the screenshots: is the guest paused (held at
    # the initial breakpoint by the debugger), running (spinning
    # somewhere with no display output), or triple-faulted (dead)?
    # Best-effort only; a dead monitor never changes the verdict.
    # The text lands in micpe-bugcheck.txt via -MonitorStatus on
    # the capture call below, and is also printed to the step log.
    $monitorStatusLines = @()
    try {
        $monitorResponses = @{}
        # Round 30: info vcpus is an unknown command on this QEMU
        # (both round 29 passes said so); info cpus is the one that
        # answers.
        foreach ($monitorQuery in @('info status', 'info registers', 'info cpus')) {
            try {
                # WaitForPromptSec (not -ReadResponse): the banner is
                # drained first and the read runs until the command's
                # own completion prompt, so a long 'info registers'
                # output arrives whole instead of truncated at a
                # 2 s read gap.
                $monitorResponses[$monitorQuery] = Invoke-CleanMonitorCommand -Port $MonitorPort -Command $monitorQuery -WaitForPromptSec 10
            }
            catch {
                $monitorResponses[$monitorQuery] = ('query failed: {0}' -f $_.Exception.Message)
            }
        }
        $monitorStatusLines = Format-CleanMonitorStatus -InfoStatus $monitorResponses['info status'] -InfoRegisters $monitorResponses['info registers'] -InfoCpus $monitorResponses['info cpus']
        Write-Host ($monitorStatusLines -join "`n")
    }
    catch {
        Write-Host ("!!! monitor status query failed (diagnostic only): {0}" -f $_.Exception.Message)
        $monitorStatusLines = @()
    }
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
    # Round 26: stop the live KD session now that QEMU has exited, so
    # the -logo file is flushed before the capture parses it. cdb
    # normally exits on its own when the TCP connection drops; the
    # kill is the backstop (same shape as the QEMU kill above).
    if ($script:kdProc -and -not $script:kdProc.HasExited) {
        $script:kdProc.WaitForExit(10000)
        if (-not $script:kdProc.HasExited) {
            try { $script:kdProc.Kill() } catch {}
        }
    }
    # Round 27: drain the KD session's stdout/stderr into the console
    # files now that cdb has exited (or been killed): the pipes are
    # closed, so the drain tasks complete with the full transcript.
    # Must run before Dispose().
    if ($script:kdProc) {
        Save-CleanKdConsoleOutput -Process $script:kdProc -OutFile $kdConsoleOut -ErrFile $kdConsoleErr
    }
    if ($script:kdProc) { try { $script:kdProc.Dispose() } catch {} }
    # Round 21: crash-dump capture. Runs even when the screen gate threw
    # (a blue screen is exactly when the dump matters); never changes the
    # run's verdict -- a capture failure is logged, not thrown.
    # Round 23: run it when there is a dump disk to read back OR a
    # guest-memory ELF to scan (the ELF scan lives inside the capture,
    # so the ELF-only case still gets parsed).
    # Round 26: also run it when a KD log exists -- the log is parsed
    # even when the disk and the ELF are both gone.
    # Round 27: also run it when the probe summary exists -- the
    # probe outcomes belong in the report even when the real session
    # never started.
    if (($dumpDiskQcow2 -and (Test-Path -LiteralPath $dumpDiskQcow2)) -or
        ($script:guestMemoryElf -and (Test-Path -LiteralPath $script:guestMemoryElf)) -or
        (Test-Path -LiteralPath $kdLog) -or
        (Test-Path -LiteralPath $kdProbeSummary)) {
        # Round 29: name the debugger binary the session ran (empty
        # when no session ran -- the control pass, or cdb missing).
        $kdDebuggerName = ''
        if ($script:kdProc -and $script:kdProc.PSObject.Properties['KdDebuggerName']) {
            $kdDebuggerName = [string]$script:kdProc.KdDebuggerName
        }
        try {
            $script:crashDumpResult = Invoke-CleanCrashDumpCapture -Qcow2Path $dumpDiskQcow2 -QemuImgPath $qemuImgPath -WorkDir $WorkDir -ElfPath $script:guestMemoryElf -KdLogPath $kdLog -KdProbePath $kdProbeSummary -KdConsoleOutPath $kdConsoleOut -KdConsoleErrPath $kdConsoleErr -KdDebuggerName $kdDebuggerName -MonitorStatus @($monitorStatusLines) -SymbolPrestagePath $symbolPrestageSummary
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