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

function Dismount-OfflineHive {
    param([Parameter(Mandatory)][string] $Key)
    [void](Invoke-RegExe @('unload', "HKLM\$Key"))
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
        if ($imageKey) { Dismount-OfflineHive -Key $imageKey }
        if ($donorKey) { Dismount-OfflineHive -Key $donorKey }
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
            foreach ($svc in $RequiredService) {
                $path = "HKLM:\$key\ControlSet001\Services\$svc"
                if (-not (Test-Path -LiteralPath $path)) {
                    $serviceProblems += "$svc missing"
                    continue
                }
                $start = (Get-ItemProperty -Path $path -Name Start -ErrorAction SilentlyContinue).Start
                if ($null -eq $start -or $start -ne 0) { $serviceProblems += "$svc Start=$start (expected 0)" }
            }
        }
        finally { Dismount-OfflineHive -Key $key }
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

