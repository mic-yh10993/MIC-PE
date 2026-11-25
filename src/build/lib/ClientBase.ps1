#Requires -Version 5.1
<#
.SYNOPSIS
    Reusable primitives for building a bootable Client (install.wim) image
    from a whitelist/keep-stash discipline instead of blind deletion.

.DESCRIPTION
    The three invariants this module enforces, taken from WIMBuilder2's
    proven build model:

      1. ADD, DON'T DELETE
         WIMBuilder2 starts from an empty directory and extracts only the
         files a component declares (`AddFiles` -> wimlib --files-from-txt).
         A blacklist trim can never be proven safe; a whitelist can.

      2. STASH BEFORE BULK DELETE
         When a whole category must go (fonts, NLS code pages, keyboard
         layouts), the wanted members are *moved* to [KEEP] first, the
         category is wiped, then [KEEP] is restored. This is
         `KEEP_FILES` / `KEEP_DONE` from WIMBuilder2's Slim_Safely.bat.

      3. PROVE THE RESULT BEFORE CAPTURING
         Test-BootCriticalFiles re-checks the boot-critical manifest after
         every trim. A missing entry aborts the build instead of producing
         an image that dies with 0xc00000bb.

.NOTES
    Requires an elevated shell: offline hive edits go through reg.exe.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string] $Message)
    Write-Host ("  -> {0}" -f $Message)
}

function Invoke-RegExe {
    <#
        Runs reg.exe and returns its output. reg.exe writes errors to stderr
        and sets exit codes, so callers must inspect $LASTEXITCODE rather
        than rely on exceptions.
    #>
    param([Parameter(Mandatory)][string[]] $Arguments)

    $out = & reg.exe @Arguments 2>&1 | Out-String
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = $out.Trim()
    }
}

function Mount-OfflineHive {
    <#
        Loads an offline hive under a temporary HKLM key and returns the key
        name. Always pair with Dismount-OfflineHive in a finally block.
    #>
    param(
        [Parameter(Mandatory)][string] $HivePath,
        [string] $Prefix = 'MICPE'
    )

    if (-not (Test-Path -LiteralPath $HivePath)) {
        throw "hive not found: $HivePath"
    }

    $key = '{0}_{1}' -f $Prefix, ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $r = Invoke-RegExe @('load', "HKLM\$key", $HivePath)
    if ($r.ExitCode -ne 0) {
        # A locked hive is the most common failure: another process (or a
        # previous build) still has it mounted.
        throw ("could not load hive {0}: {1}" -f $HivePath, $r.Output)
    }
    return $key
}

function Test-CleanHiveFileReadable {
    <#
    .SYNOPSIS
        True when a file can be opened for reading right now.
    .DESCRIPTION
        A hive file a still-mounted registry key holds is opened by
        the kernel with no sharing, so a read open fails; a free file
        opens. Returns $false only on a lock error (the wrapped
        IOException); any other failure (ACL, a path that is a
        directory) throws, so a real problem is never mistaken for a
        transient lock. A missing file also returns $false -- the
        caller decides whether that is an error.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $stream.Dispose()
        return $true
    }
    catch {
        $ex = $_.Exception
        if ($ex -isnot [System.IO.IOException] -and $ex.InnerException -isnot [System.IO.IOException]) { throw }
        return $false
    }
}

function Dismount-OfflineHive {
    <#
    .SYNOPSIS
        Unloads an offline hive mounted by Mount-OfflineHive.
    .DESCRIPTION
        The unload is verified, not assumed. reg.exe unload returns a
        non-zero exit code while any handle to the hive is still open,
        and the PowerShell registry provider is known to hold one
        right after enumerating keys (Build-CleanPe.ps1 already
        avoids the provider for the read-back step for exactly this
        reason). The old version ignored the exit code, so a failed
        unload was invisible: the hive stayed mounted, its file
        stayed locked, and the build died much later in the wimlib
        capture with error 47 / 84 (round 18, run 45642177192: the
        guard's SYSTEM unload sits ~10 ms before capture, and the
        file was still locked 20 s into the capture -- consistent
        with "still mounted", not a transient close lag; it was also
        the first round in which capture ran after the guard passed).
        Retry with a GC + sleep between attempts -- the provider
        releases its handles when the runspace cleans up -- and throw
        loudly if the hive never unloads, so the build fails at the
        unload point with a clear message instead of in capture.
        When -HivePath is supplied, the hive file itself is then
        polled for readability, so when Dismount returns the file is
        free for wimlib to read (covers a post-unload close lag too).
        Callers in a finally block: a throw here propagates, which is
        intended -- proceeding with a mounted hive can only fail
        later, with a worse error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Key,
        [string] $HivePath,
        [int] $MaxUnloadAttempts = 10,
        [int] $UnloadRetryDelaySeconds = 1,
        [int] $HiveFreeTimeoutSeconds = 30
    )

    if ($MaxUnloadAttempts -lt 1) { $MaxUnloadAttempts = 1 }
    if ($HiveFreeTimeoutSeconds -lt 0) { $HiveFreeTimeoutSeconds = 0 }

    Write-SubStep "unloading HKLM\$Key"
    $lastOutput = ''
    $lastExit = 1
    for ($attempt = 1; $attempt -le $MaxUnloadAttempts; $attempt++) {
        $r = Invoke-RegExe @('unload', "HKLM\$Key")
        $lastExit = $r.ExitCode
        $lastOutput = $r.Output
        if ($lastExit -eq 0) { break }
        if ($attempt -lt $MaxUnloadAttempts) {
            Write-Warn ("reg unload HKLM\{0} failed (attempt {1}/{2}, exit {3}): {4}; retrying after GC + {5}s" -f $Key, $attempt, $MaxUnloadAttempts, $lastExit, $lastOutput, $UnloadRetryDelaySeconds)
            [GC]::Collect()
            if ($UnloadRetryDelaySeconds -gt 0) { Start-Sleep -Seconds $UnloadRetryDelaySeconds }
        }
    }
    if ($lastExit -ne 0) {
        throw ("could not unload hive HKLM\{0} after {1} attempts (round 18: a hive left mounted locks its file and the later wimlib capture fails with error 47/84): {2}" -f $Key, $MaxUnloadAttempts, $lastOutput)
    }

    if ($HivePath) {
        if (-not (Test-Path -LiteralPath $HivePath)) {
            throw "hive file is gone after unload: $HivePath"
        }
        $deadline = (Get-Date).AddSeconds($HiveFreeTimeoutSeconds)
        while (-not (Test-CleanHiveFileReadable -Path $HivePath)) {
            if ((Get-Date) -ge $deadline) {
                throw ("hive file still locked {0}s after unloading HKLM\{1}: {2}" -f $HiveFreeTimeoutSeconds, $Key, $HivePath)
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Enable-WimBootStack {
    <#
    .SYNOPSIS
        Gives a Client image the driver stack required to run FROM a WIM.

    .DESCRIPTION
        A WIM-booted system needs a filesystem that *is* the WIM and a
        writable overlay on top of it. WinPE ships that stack; a Windows
        install image does not, because it never intends to boot this way.

        Missing it produces exactly:
            Recovery  Your PC/Device needs to be repaired
            A required device isn't connected or can't be accessed
            Error code: 0xc00000bb

        Transplanted services (all Start=0, i.e. boot-start):
            WimFsf   Type=2  Group=FSFilter Compression    DependOn:FltMgr
            FBWF     Type=2  Group=FSFilter System Recovery Tag=5
            FltMgr   Type=2  Group=FSFilter Infrastructure  (already present)
            Ramdisk  Type=1  (demand in WinPE, boot in a full image)

        FBWF's WinPECacheThreshold is the writable-overlay ceiling in MB.
        The reference RAMOS image uses 0x2000 (8 GB); 4 GB fits a 16 GB VM
        that also holds a ~4 GB WIM in RAM.

    .PARAMETER ImageRoot
        Root of the applied image (the directory that holds \Windows).
    .PARAMETER PeDonorWim
        A WinPE boot.wim that contains wimfsf.sys / fbwf.sys and the
        service definitions. The stock install media boot.wim works.
    .PARAMETER OverlayMegabytes
        FBWF overlay ceiling. Default 4096.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ImageRoot,
        [Parameter(Mandatory)][string] $PeDonorWim,
        [int] $PeDonorIndex = 1,
        [int] $OverlayMegabytes = 4096,
        [string] $WimlibPath
    )

    if (-not $WimlibPath) { $WimlibPath = (Get-Command wimlib-imagex.exe -ErrorAction SilentlyContinue).Source }
    if (-not $WimlibPath) { throw 'wimlib-imagex.exe not found; pass -WimlibPath' }

    $imageSystem = Join-Path $ImageRoot 'Windows\System32\config\SYSTEM'
    $imageDrivers = Join-Path $ImageRoot 'Windows\System32\drivers'
    foreach ($p in @($imageSystem, $imageDrivers)) {
        if (-not (Test-Path -LiteralPath $p)) { throw "not an applied image root: $ImageRoot (missing $p)" }
    }

    $donor = Join-Path $env:TEMP ('micpe-wimboot-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $donor -Force | Out-Null

    $donorKey = $null
    $imageKey = $null
    try {
        # --- 1. pull the driver binaries and the donor hive out of the PE ---
        $member = @(
            '/Windows/System32/drivers/wimfsf.sys',
            '/Windows/System32/drivers/fbwf.sys',
            '/Windows/System32/config/SYSTEM'
        )
        & $WimlibPath extract $PeDonorWim $PeDonorIndex --dest-dir="$donor" --no-acls @member 2>&1 |
            Select-Object -Last 1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "wimlib extract failed for donor $PeDonorWim" }

        foreach ($f in 'wimfsf.sys', 'fbwf.sys') {
            $src = Join-Path $donor $f
            if (-not (Test-Path -LiteralPath $src)) { throw "donor PE has no $f (wrong index?)" }
            Copy-Item -LiteralPath $src -Destination (Join-Path $imageDrivers $f) -Force
            Write-Step "$f -> System32\drivers"
        }

        # --- 2. transplant the service definitions ---
        $donorSystem = Join-Path $donor 'SYSTEM'
        if (-not (Test-Path -LiteralPath $donorSystem)) { throw 'donor SYSTEM hive not extracted' }
        $donorKey = Mount-OfflineHive -HivePath $donorSystem -Prefix 'MICPED'
        $imageKey = Mount-OfflineHive -HivePath $imageSystem -Prefix 'MICPEI'

        foreach ($svc in 'WimFsf', 'FBWF') {
            $regFile = Join-Path $donor "$svc.reg"
            $r = Invoke-RegExe @('export', "HKLM\$donorKey\ControlSet001\Services\$svc", $regFile, '/y')
            if ($r.ExitCode -ne 0) { throw "export of $svc failed: $($r.Output)" }

            # reg export writes the source key path; retarget it at the image.
            $text = (Get-Content -LiteralPath $regFile -Raw) -replace [regex]::Escape($donorKey), $imageKey
            $fixed = Join-Path $donor "$svc-fix.reg"
            Set-Content -LiteralPath $fixed -Value $text -Encoding Unicode -NoNewline

            [void](Invoke-RegExe @('delete', "HKLM\$imageKey\ControlSet001\Services\$svc", '/f'))
            $r = Invoke-RegExe @('import', $fixed)
            if ($r.ExitCode -ne 0) { throw "import of $svc failed: $($r.Output)" }
            Write-Step "service $svc transplanted"
        }

        # --- 3. boot-start the devices the loader needs ---
        $svcRoot = "HKLM:\$imageKey\ControlSet001\Services"
        Set-ItemProperty -Path "$svcRoot\Ramdisk" -Name Start -Value 0 -Type DWord
        Set-ItemProperty -Path "$svcRoot\FltMgr" -Name Start -Value 0 -Type DWord
        Set-ItemProperty -Path "$svcRoot\WimFsf" -Name Start -Value 0 -Type DWord
        Set-ItemProperty -Path "$svcRoot\FBWF" -Name Start -Value 0 -Type DWord
        Set-ItemProperty -Path "$svcRoot\FBWF" -Name WinPECacheThreshold -Value $OverlayMegabytes -Type DWord
        Write-Step ("Ramdisk/FltMgr/WimFsf/FBWF Start=0, overlay {0} MB" -f $OverlayMegabytes)

        # --- 4. read back: an unverified registry write is not a fix ---
        foreach ($svc in 'WimFsf', 'FBWF', 'FltMgr', 'Ramdisk') {
            $v = (Get-ItemProperty -Path "$svcRoot\$svc" -Name Start -ErrorAction SilentlyContinue).Start
            if ($null -eq $v -or $v -ne 0) { throw "$svc did not end up boot-start (Start=$v)" }
        }
        Write-Step 'boot stack verified'
    }
    finally {
        if ($imageKey) { Dismount-OfflineHive -Key $imageKey -HivePath $imageSystem }
        if ($donorKey) { Dismount-OfflineHive -Key $donorKey -HivePath $donorSystem }
        Remove-Item -LiteralPath $donor -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- keep-stash ------------------------------------------------------------
# Port of WIMBuilder2's KEEP_FILES / KEEP_DONE (za-Slim\Slim_Safely.bat).
# Category wipes are only safe if the survivors are held aside first.

function Move-ToKeep {
    <#
    .SYNOPSIS
        Parks files aside so a category wipe cannot take them with it.
    .PARAMETER RelativePath
        Directory relative to the image root, e.g. 'Windows\Fonts'.
    .PARAMETER Name
        One or more file names inside that directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ImageRoot,
        [Parameter(Mandatory)][string] $RelativePath,
        [Parameter(Mandatory)][string[]] $Name
    )

    $keepDir = Join-Path (Join-Path $ImageRoot '[KEEP]') $RelativePath
    if (-not (Test-Path -LiteralPath $keepDir)) {
        New-Item -ItemType Directory -Path $keepDir -Force | Out-Null
    }

    foreach ($n in $Name) {
        $src = Join-Path (Join-Path $ImageRoot $RelativePath) $n
        if (Test-Path -LiteralPath $src) {
            Move-Item -LiteralPath $src -Destination (Join-Path $keepDir $n) -Force
        }
    }
}

function Restore-Keep {
    <#
    .SYNOPSIS
        Puts everything parked by Move-ToKeep back, then removes [KEEP].
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ImageRoot)

    $keep = Join-Path $ImageRoot '[KEEP]'
    if (-not (Test-Path -LiteralPath $keep)) { return }

    $count = 0
    Get-ChildItem -LiteralPath $keep -Recurse -File -Force | ForEach-Object {
        $rel = $_.FullName.Substring($keep.Length).TrimStart('\')
        $dst = Join-Path $ImageRoot $rel
        $dstDir = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dstDir)) {
            New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        }
        Move-Item -LiteralPath $_.FullName -Destination $dst -Force
        $count++
    }
    Remove-Item -LiteralPath $keep -Recurse -Force -ErrorAction SilentlyContinue
    Write-Step "$count file(s) restored from [KEEP]"
}

# --- critical-driver file guard (round 16: 0x5A) ---------------------------

function Resolve-CleanDriverImagePath {
    <#
    .SYNOPSIS
        Maps a service ImagePath to a path inside an applied image.
    .DESCRIPTION
        Kernel drivers name their image relative to %SystemRoot% in
        several spellings ('system32\drivers\x.sys',
        '\SystemRoot\system32\drivers\x.sys',
        '%SystemRoot%\System32\drivers\x.sys', a DriverStore path).
        A driver with no ImagePath defaults to
        System32\drivers\<ServiceName>.sys. The remainder is relative
        to the Windows directory under $ImageRoot, and the returned
        path is $ImageRoot\Windows\<remainder>; the file itself may
        not exist -- callers Test-Path the result.
    #>
    [CmdletBinding()]
    param(
        [string] $ImagePath,
        [Parameter(Mandatory)][string] $ServiceName,
        [Parameter(Mandatory)][string] $ImageRoot
    )

    $rel = $ImagePath
    if ([string]::IsNullOrWhiteSpace($rel)) {
        $rel = "System32\drivers\$ServiceName.sys"
    }
    # Strip a %SystemRoot% / \SystemRoot prefix in any spelling, and
    # any NT-path (\??\) or drive-letter prefix; what remains is
    # relative to the Windows directory.
    $rel = $rel -replace '^(?i)(%SystemRoot%|\\SystemRoot|SystemRoot)\\?', ''
    $rel = $rel -replace '^(?i)\\*\?+\\[A-Za-z]:\\', ''
    $rel = $rel -replace '^(?i)[A-Za-z]:\\', ''
    $rel = $rel.TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($rel)) {
        $rel = "System32\drivers\$ServiceName.sys"
    }
    # The image root is the staging root, which holds a Windows\
    # subdir (the fixed manifest in Test-BootCriticalFiles joins
    # 'Windows\...' paths onto it, and production calls this guard
    # with -ImageRoot $paths.Staging). The remainder is relative to
    # that Windows directory, not to the staging root itself.
    # Round 18: the old code joined the remainder straight onto
    # $ImageRoot and looked in staging\System32\... instead of
    # staging\Windows\System32\..., so every driver looked "missing"
    # and Assert-BootCritical refused to capture (run 45628441308:
    # 28 EC=3 + 83 non-critical false positives, including the
    # just-transplanted FBWF/WimFsf/Ramdisk).
    if ($rel -notmatch '^(?i)Windows\\') { $rel = "Windows\$rel" }
    return (Join-Path $ImageRoot $rel)
}

function Get-CleanRegistryValue {
    <#
    .SYNOPSIS
        Reads one registry value without tripping StrictMode.
    .DESCRIPTION
        Get-ItemProperty only exposes the values that exist as
        properties on the returned object; under Set-StrictMode
        -Version 2.0 (or Latest) reading a missing value as
        $props.<Name> throws "The property '<Name>' cannot be found
        on this object". The r91 SYSTEM hive has 43 service keys
        with no Start value at all (.NET CLR Data, Winsock, ...),
        and that exact throw killed the round 16 build in
        Test-BootCriticalFiles before it checked a single driver.
        Reading through PSObject.Properties returns $null for a
        missing value instead of throwing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Properties,
        [Parameter(Mandatory)][string] $Name
    )
    $prop = $Properties.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

# --- guard reads through reg.exe, never the provider (round 20) -----------
# Round 19 (run 45656051010) proved the PowerShell registry provider is
# what breaks the guard's own hive unload: after Test-BootCriticalFiles
# enumerated 679 services with Get-ChildItem + Get-ItemProperty, `reg
# unload` of the verify hive failed 10/10 times with Access is denied,
# while the 10 other unloads in the same session (all reg.exe-only
# hives) succeeded. The provider holds an open handle on the hive and
# GC + retry cannot release it -- the read-back step already avoids the
# provider for exactly this reason (Build-CleanPe.ps1, CI run
# 44001157082). So the guard reads the whole Services tree with one
# `reg.exe query /s` call: the parent pwsh process never opens the
# hive, so nothing in-session can hold it open and the later unload
# succeeds on the first attempt.

function ConvertTo-CleanRegDword {
    <#
    .SYNOPSIS
        Converts a REG_DWORD string ('0x3') to [int]; $null when missing.
    .DESCRIPTION
        reg.exe prints DWORDs as hex strings. An unparseable value
        returns $null instead of throwing, so one odd row cannot kill
        the guard -- the caller treats $null Start as "skip" (driver
        check) or "Start= (expected 0)" (required-service check).
    #>
    [CmdletBinding()]
    param([AllowNull()][string] $Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $trimmed = $Raw.Trim()
    try {
        if ($trimmed -match '^0x([0-9a-fA-F]+)$') { return [Convert]::ToInt32($Matches[1], 16) }
        return [int]$trimmed
    }
    catch { return $null }
}

function ConvertFrom-CleanServicesRegQuery {
    <#
    .SYNOPSIS
        Parses `reg.exe query <Services key> /s` output into service rows.
    .DESCRIPTION
        Pure text parsing, no registry access: unit-testable on Linux.
        `reg.exe query /s` prints one block per key -- the queried key
        itself first, then every subkey recursively -- each block headed
        by its full path, followed by `    Name    REG_TYPE    data`
        rows and a blank line. Only direct children of the Services key
        are services; deeper blocks (Parameters, Enum, Linkage, ...) are
        ignored. REG_MULTI_SZ continuation lines carry no REG_ token, so
        they never match a value row. A missing value is $null (43 of
        the 679 r91 service keys have no Start at all -- round 17).
        The value-row regex mirrors Registry.ps1's
        ConvertFrom-RegQueryOutput, so the two parsers agree on what a
        row looks like. Returns objects with Name, Start, ErrorControl,
        Type and ImagePath -- the same shape Test-CleanCriticalDriverFiles
        takes.
        [AllowEmptyString] on $Lines is load-bearing: reg.exe output
        is full of blank lines between blocks, and a mandatory
        [string[]] parameter refuses an array containing an empty
        string ("Cannot bind argument ... because it is an empty
        string") unless the attribute is present.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Lines,
        [Parameter(Mandatory)][string] $ServicesPath
    )

    $blocks = @()
    $block = $null
    foreach ($line in $Lines) {
        if ($line -match '^HKEY_LOCAL_MACHINE\\') {
            $block = [pscustomobject]@{ Path = $line.Trim(); Values = @{} }
            $blocks += $block
            continue
        }
        if ($null -eq $block) { continue }
        if ($line -match '^\s+(.+?)\s{2,}REG_[A-Z_]+\s+(.*\S)\s*$') {
            $block.Values[$Matches[1]] = $Matches[2].Trim()
        }
        elseif ($line -match '^\s+(.+?)\s{2,}REG_[A-Z_]+\s*$') {
            $block.Values[$Matches[1]] = ''
        }
        # Blank lines and REG_MULTI_SZ continuation lines carry no REG_
        # token, so they never match a value row: ignored.
    }

    $services = @()
    $prefix = "$ServicesPath\"
    foreach ($block in $blocks) {
        if (-not $block.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $rest = $block.Path.Substring($prefix.Length)
        if ($rest.Length -eq 0 -or $rest.Contains('\')) { continue }
        $services += [pscustomobject]@{
            Name         = $rest
            Start        = ConvertTo-CleanRegDword -Raw $block.Values['Start']
            ErrorControl = ConvertTo-CleanRegDword -Raw $block.Values['ErrorControl']
            Type         = ConvertTo-CleanRegDword -Raw $block.Values['Type']
            ImagePath    = $block.Values['ImagePath']
        }
    }
    return $services
}

function Get-CleanServicesViaRegQuery {
    <#
    .SYNOPSIS
        Reads every service under a mounted SYSTEM hive's Services key
        through reg.exe, never through the PowerShell provider.
    .DESCRIPTION
        One `reg.exe query /s` call returns every service; the parent
        pwsh process never opens the hive, so nothing in-session can
        hold it open and the later `reg unload` succeeds. Returns @()
        when the Services key is absent (same as the old Test-Path
        guard around the provider enumeration).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Key)

    # reg.exe accepts the short root (HKLM) in the query, but prints
    # the long root (HKEY_LOCAL_MACHINE) in every output header -- the
    # parser matches block paths against the long form, so the two
    # paths must not be confused (passing the short form to the parser
    # matches nothing and the guard sees zero services).
    $queryPath = "HKLM\$Key\ControlSet001\Services"
    $servicesPath = "HKEY_LOCAL_MACHINE\$Key\ControlSet001\Services"
    $r = Invoke-RegExe @('query', $queryPath, '/s')
    if ($r.ExitCode -ne 0) { return @() }
    $lines = @($r.Output -split "`r?`n")
    return (ConvertFrom-CleanServicesRegQuery -Lines $lines -ServicesPath $servicesPath)
}

function Test-CleanCriticalDriverFiles {
    <#
    .SYNOPSIS
        Checks every boot/system driver in $Services for its file.
    .DESCRIPTION
        Round 16 root cause: FileCrypt was Start=1 + ErrorControl=3
        with its file missing from the image, and the fixed
        boot-critical manifest never listed it, so the build sailed
        through capture and only died in QEMU with
        CRITICAL_SERVICE_FAILED (0x5A). The kernel bugchecks 0x5A when
        a driver with ErrorControl=3 fails to load during IoInitSystem's
        driver-load phase, so any Start=0/1, Type=1/2, ErrorControl=3
        service whose driver file is missing is a guaranteed 0x5A.
        Non-critical (ErrorControl < 3) missing drivers only fail their
        load and log it; they are reported separately and never fail
        this check. $Services is a list of objects with Name, Start,
        ErrorControl, Type and ImagePath (ImagePath may be empty).
        Returns CriticalMissing and NonCriticalMissing (service names).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ImageRoot,
        [AllowEmptyCollection()][object[]] $Services = @()
    )

    $criticalMissing = @()
    $nonCriticalMissing = @()
    foreach ($svc in $Services) {
        if ($null -eq $svc.Start -or ($svc.Start -ne 0 -and $svc.Start -ne 1)) { continue }
        if ($null -eq $svc.Type -or ($svc.Type -ne 1 -and $svc.Type -ne 2)) { continue }
        $driverPath = Resolve-CleanDriverImagePath -ImagePath $svc.ImagePath -ServiceName $svc.Name -ImageRoot $ImageRoot
        if (Test-Path -LiteralPath $driverPath) { continue }
        $ec = $svc.ErrorControl
        if ($null -eq $ec) { $ec = 1 }
        if ($ec -eq 3) { $criticalMissing += $svc.Name }
        else { $nonCriticalMissing += $svc.Name }
    }
    return [pscustomobject]@{
        CriticalMissing    = $criticalMissing
        NonCriticalMissing = $nonCriticalMissing
    }
}

# --- pre-capture proof -----------------------------------------------------

function Test-BootCriticalFiles {
    <#
    .SYNOPSIS
        Verifies the boot-critical manifest before an image is captured.

    .DESCRIPTION
        Every entry here is load-bearing for the path
        bootmgr -> winload -> ntoskrnl -> smss -> winlogon -> LogonUI.
        A trim that removes one of them produces a boot failure whose
        error code points at the wrong thing (0xc00000bb was a *driver
        stack* problem, not a missing file, which is exactly why this list
        is checked as files AND services).

        Returns an object with Missing (files) and ServiceProblems.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ImageRoot,
        [string[]] $RequiredService = @('WimFsf', 'FBWF', 'FltMgr', 'Ramdisk')
    )

    $files = @(
        'Windows\System32\ntoskrnl.exe',
        'Windows\System32\hal.dll',
        'Windows\System32\ci.dll',
        'Windows\System32\smss.exe',
        'Windows\System32\csrss.exe',
        'Windows\System32\wininit.exe',
        'Windows\System32\services.exe',
        'Windows\System32\lsass.exe',
        'Windows\System32\svchost.exe',
        'Windows\System32\winlogon.exe',
        'Windows\System32\LogonUI.exe',
        'Windows\System32\userinit.exe',
        'Windows\explorer.exe',
        'Windows\System32\dwm.exe',
        'Windows\System32\drivers\wimfsf.sys',
        'Windows\System32\drivers\fbwf.sys',
        'Windows\System32\drivers\fltmgr.sys',
        'Windows\System32\drivers\ramdisk.sys',
        'Windows\System32\drivers\ntfs.sys',
        'Windows\System32\drivers\partmgr.sys',
        'Windows\System32\drivers\volmgr.sys',
        'Windows\System32\drivers\volmgrx.sys',
        'Windows\System32\drivers\mountmgr.sys',
        'Windows\System32\drivers\classpnp.sys',
        'Windows\System32\drivers\storport.sys',
        'Windows\System32\config\SYSTEM',
        'Windows\System32\config\SOFTWARE',
        'Windows\System32\config\SAM',
        'Windows\System32\config\SECURITY',
        'Windows\System32\config\DEFAULT'
    )

    $missing = @()
    foreach ($rel in $files) {
        if (-not (Test-Path -LiteralPath (Join-Path $ImageRoot $rel))) { $missing += $rel }
    }

    $serviceProblems = @()
    $systemHive = Join-Path $ImageRoot 'Windows\System32\config\SYSTEM'
    if (Test-Path -LiteralPath $systemHive) {
        $key = Mount-OfflineHive -HivePath $systemHive -Prefix 'MICPEV'
        try {
            # Round 20: read the whole Services tree through reg.exe,
            # never through the PowerShell provider. The provider kept
            # an open handle on the hive after the guard enumerated
            # 679 services through it, and the guard's own `reg unload`
            # then failed 10/10 times with Access is denied (round 19,
            # run 45656051010) -- while the 10 other unloads in the
            # same session (all reg.exe-only hives) succeeded. The
            # read-back step already avoids the provider for exactly
            # this reason (Build-CleanPe.ps1, CI run 44001157082). One
            # query serves both the required-services check and the
            # critical-driver enumeration, and the parent pwsh process
            # never opens the hive, so nothing in-session can hold it
            # open.
            $services = Get-CleanServicesViaRegQuery -Key $key

            foreach ($svc in $RequiredService) {
                $row = @($services | Where-Object { $_.Name -eq $svc })
                if ($row.Count -eq 0) {
                    $serviceProblems += "$svc missing"
                    continue
                }
                $start = $row[0].Start
                if ($null -eq $start -or $start -ne 0) { $serviceProblems += "$svc Start=$start (expected 0)" }
            }

            # Round 16 guard: the fixed manifest above cannot catch a
            # critical driver the whitelist silently drops (FileCrypt was
            # Start=1 + ErrorControl=3 with no file in the image, and the
            # build only died in QEMU with 0x5A). $services above is the
            # full enumeration; fail on any boot/system driver whose
            # file is missing.
            $driverCheck = Test-CleanCriticalDriverFiles -ImageRoot $ImageRoot -Services $services
            foreach ($name in $driverCheck.CriticalMissing) {
                $serviceProblems += "$name is a critical boot/system driver (ErrorControl=3) but its file is missing from the image"
            }
            if ($driverCheck.NonCriticalMissing.Count -gt 0) {
                Write-Warn ("non-critical boot/system drivers with missing files (failed load only, no 0x5A): {0}" -f ($driverCheck.NonCriticalMissing -join ', '))
            }
        }
        finally { Dismount-OfflineHive -Key $key -HivePath $systemHive }
    }

    [pscustomobject]@{
        Missing          = $missing
        ServiceProblems  = $serviceProblems
        IsBootable       = ($missing.Count -eq 0 -and $serviceProblems.Count -eq 0)
    }
}

function Assert-BootCritical {
    <#
    .SYNOPSIS
        Throws when Test-BootCriticalFiles finds a hole. Call it right
        before wimlib capture.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ImageRoot)

    $r = Test-BootCriticalFiles -ImageRoot $ImageRoot
    if ($r.IsBootable) {
        Write-Step 'boot-critical manifest OK'
        return $r
    }
    $lines = @()
    if ($r.Missing.Count) { $lines += ('missing files: ' + ($r.Missing -join ', ')) }
    if ($r.ServiceProblems.Count) { $lines += ('service problems: ' + ($r.ServiceProblems -join ', ')) }
    throw ("image is not bootable, refusing to capture. {0}" -f ($lines -join '; '))
}

