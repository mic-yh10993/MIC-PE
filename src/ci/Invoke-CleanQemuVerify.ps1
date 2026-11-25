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
    $proc = Start-Process -FilePath $RizinPath -ArgumentList @('-d', $uri, '-q', '-c', $Commands) `
        -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch {}
        throw "Rizin timed out after $TimeoutSec s ($Commands)"
    }
    $out = ''
    if (Test-Path -LiteralPath $outFile) { $out = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue }
    if ($proc.ExitCode -ne 0) {
        $err = ''
        if (Test-Path -LiteralPath $errFile) { $err = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue }
        Write-Host "!!! Rizin exited $($proc.ExitCode) ($Commands): $err"
    }
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    return ($out -as [string])
}

function Invoke-CleanCrashDumpCapture {
    # Round 21: after QEMU exits, convert the dump disk back to VHDX,
    # attach it, and read the dedicated dump file the blue screen was
    # supposed to write. Never throws: a missing dump file is itself the
    # finding (dump stack not ready at IopLoadDriver, or the wrong drive
    # letter), and it is written to micpe-bugcheck.txt either way. The
    # caller runs this in the finally block so it runs even when the
    # screen gate threw (a blue screen is exactly when the dump matters).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Qcow2Path,

        [Parameter(Mandatory = $true)]
        [string] $QemuImgPath,

        [Parameter(Mandatory = $true)]
        [string] $WorkDir,

        [string] $RizinVersion = 'v0.9.1'
    )

    $reportPath = Join-Path $WorkDir 'micpe-bugcheck.txt'
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('MICPE crash-dump capture (round 21: 0x5A bugcheck parameters)')
    $lines.Add(('QEMU dump disk: {0}' -f $Qcow2Path))
    $result = [pscustomobject]@{ DumpFound = $false; BugCheck = $null; ReportPath = $reportPath }
    $vhdx = Join-Path $WorkDir 'micpe-dumpdisk-read.vhdx'
    $attachedLetter = $null
    try {
        # Windows cannot attach qcow2, so convert back to VHDX first.
        & $QemuImgPath convert -f qcow2 -O vhdx $Qcow2Path $vhdx
        if ($LASTEXITCODE -ne 0) { throw "qemu-img convert back to VHDX failed ($Qcow2Path -> $vhdx)" }
        Remove-Item -LiteralPath $Qcow2Path -Force -ErrorAction SilentlyContinue
        $used = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        $letter = Find-CleanFreeDriveLetter -UsedLetters $used
        if (-not $letter) { throw 'no free drive letter to attach the crash-dump disk (tried Z Y X W V U T)' }
        $attachedLetter = $letter
        @("select vdisk file=`"$vhdx`"", 'attach vdisk', "assign letter=$letter") -join "`n" | diskpart | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "diskpart failed while attaching the crash-dump disk $vhdx" }
        Start-Sleep -Seconds 3
        if (-not (Test-Path -LiteralPath "${letter}:\")) { throw "crash-dump disk attached but drive ${letter}: never appeared" }
        $dumpFile = "${letter}:\dedicateddumpfile.sys"
        $lines.Add(('attached as {0}: ; dump file path {1}' -f $letter, $dumpFile))
        $volFiles = @(Get-ChildItem -LiteralPath "${letter}:\" -Force -ErrorAction SilentlyContinue |
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
        if ($attachedLetter) {
            @("select vdisk file=`"$vhdx`"", 'detach vdisk') -join "`n" | diskpart | Out-Null
        }
        if (Test-Path -LiteralPath $vhdx) { Remove-Item -LiteralPath $vhdx -Force -ErrorAction SilentlyContinue }
        $lines | Set-Content -LiteralPath $reportPath -Encoding UTF8
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
    # Round 21: crash-dump capture. Runs even when the screen gate threw
    # (a blue screen is exactly when the dump matters); never changes the
    # run's verdict -- a capture failure is logged, not thrown.
    if ($dumpDiskQcow2 -and (Test-Path -LiteralPath $dumpDiskQcow2)) {
        try {
            $script:crashDumpResult = Invoke-CleanCrashDumpCapture -Qcow2Path $dumpDiskQcow2 -QemuImgPath $qemuImgPath -WorkDir $WorkDir
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