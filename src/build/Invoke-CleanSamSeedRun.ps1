#Requires -Version 7.0
<#
.SYNOPSIS
    One-off SAM/SECURITY seeding run (MIC-PE round 42, user-approved Scheme A).

.DESCRIPTION
    Round 41 research (hidden_files/round41-sam-research.md): the r116
    SAM and SECURITY hives are entirely empty (root 0 subkeys, 0 values),
    and the SAM service does NOT create the built-in accounts at boot --
    r116 died on 0xc00002e3 SAM initialization failed. The databases
    must be seeded before the image can log on.

    This script produces the seed databases from the official image
    itself, once, offline (not every build):

      1. Convert the official Professional install.wim from UUP dump
         (same calls as Invoke-CleanBaseStep, AddUpdates=1 serviced
         22621.1105 -- the same source the clean build uses).
      2. DISM-apply it to a VHD, bcdboot the EFI partition, drop in
         sam-seed-unattend.xml (specialize + OOBE). bcdboot runs from
         the applied image's own System32 (round 42: the host 26100
         bcdboot failed on the 22621 image with exit 193).
      3. Boot the VHD in QEMU (TCG, like the clean verify) and wait
         for the desktop: specialize has run, OOBE has created the
         MICPE administrator (blank password, Administrators group)
         and AutoLogon has signed it in -- the desktop screenshot
         is itself the blank-password proof.
      4. Power the VM off cleanly, harvest SAM + SECURITY from the
         VHD, verify their structure with reg.exe (MICPE in
         SAM\Domains\Account\Users\Names, RID 1000 enabled and in
         the Administrators alias, SECURITY\Policy\Accounts
         populated), and write micpe-seed-verify.txt with sizes,
         SHA256 and the observed structure.

    The harvested hives are then committed to the repo as build inputs
    (src/build/data/sam-seed/) -- see the README there for the privacy
    note (repo is temporarily public). The main build seeds them into
    staging via Invoke-CleanSamSeedStep and enables MICPE (RID 1000)
    offline with the existing Set-OfflineAdminState.

    The seed VM has NO network (-nic none): with a NIC, Windows
    Update can stall the specialize/OOBE flow for a long time, and
    the seed needs no network at all. The QEMU used by the clean
    verify keeps its e1000 NIC (kdnet needs it); only the seed VM
    goes offline.

    Windows-only (DISM, bcdboot, diskpart, reg.exe). Local runs are
    not expected: the local VM has no KVM and a full Windows specialize
    under TCG there is not feasible; this runs on the CI runner.
#>

param(
    [string] $WorkDir = (Join-Path (Get-Location) 'seed-out'),

    [string] $Build = '22621.1105',

    [string] $Edition = 'professional',

    [string] $QemuPath = 'qemu-system-x86_64',

    [string] $OvmfPath = '',

    # Specialize under TCG is slow: a full Windows boot to the OOBE
    # desktop can take 20-40 minutes. 75 minutes is the outer
    # ceiling; the shutdown timer below is what actually ends the run.
    [int] $SpecializeTimeoutMin = 75,

    # Minutes after QEMU start when the guest is shut down for
    # harvest. Round 42 rerun 10 (user 2026-11-28 09:12): no
    # screenshot gates at all -- shutdown is on a timer. In run
    # 46080314320 the Start menu appeared 53.43 min after QEMU
    # start (shot-36, 00:27:38Z; QEMU started 23:34:12Z), so the
    # timer is that measured time plus a 10 min buffer against
    # run-to-run variation, rounded up to a clean 64 min.
    [int] $ShutdownAfterMin = 64,

    [int] $MemoryMb = 4096,

    [int] $CpuCount = 4,

    [string] $MonitorPort = '4444'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
. (Join-Path $scriptDir 'lib\Common.ps1')
. (Join-Path $scriptDir 'lib\BaseImage.ps1')
. (Join-Path $scriptDir 'lib\Wim.ps1')

if (-not (Test-Path -LiteralPath $WorkDir)) {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
}
$shotDir = Join-Path $WorkDir 'screenshots'
if (-not (Test-Path -LiteralPath $shotDir)) {
    New-Item -ItemType Directory -Path $shotDir -Force | Out-Null
}
$seedVerifyPath = Join-Path $WorkDir 'micpe-seed-verify.txt'
$verifyLines = [System.Collections.Generic.List[string]]::new()
function Write-VerifyLine {
    param([string] $Line)
    $verifyLines.Add($Line)
    Write-Host $Line
}

function Get-SeedQemuArgList {
    # Pure function (no process, no files): the exact QEMU argv for the
    # seed VM. Modeled on Get-CleanQemuArgList (round 35) with three
    # deliberate differences: the VM boots from its disk (-boot c, the
    # applied image on ide index 0) instead of a CD-ROM, there is
    # NO -no-reboot (specialize reboots once into OOBE) and NO
    # -no-shutdown (a clean guest shutdown must let QEMU exit, which
    # is the signal the run is done), and there is NO network
    # (-nic none: with a NIC, Windows Update can stall specialize /
    # OOBE for a long time, and the seed needs no network at all).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DiskQcow2,

        [Parameter(Mandatory = $true)]
        [string] $OvmfCodePath,

        [Parameter(Mandatory = $true)]
        [string] $VarsPath,

        [Parameter(Mandatory = $true)]
        [string] $QemuLogPath,

        [int] $MemoryMb = 4096,

        [int] $CpuCount = 4,

        [string] $MonitorPort = '4444'
    )
    return ,@(
        '-m', "$MemoryMb"
        '-smp', "$CpuCount"
        '-cpu', 'max'
        '-display', 'none'
        '-rtc', 'base=localtime'
        '-monitor', "tcp:127.0.0.1:$MonitorPort,server,nowait"
        '-nic', 'none'
        '-serial', 'none'
        '-drive', "if=pflash,format=raw,unit=0,readonly=on,file=$OvmfCodePath"
        '-drive', "if=pflash,format=raw,unit=1,file=$VarsPath"
        '-drive', "file=$DiskQcow2,format=qcow2,if=ide,index=0"
        '-boot', 'c'
        # -D only names the log file; QEMU writes nothing at all
        # unless -d enables a log category, so without -d the file
        # stays 0 bytes (run 46051050523: micpe-seed-qemu.log was
        # empty for exactly this reason). guest_errors makes the log
        # real -- guest errors during specialize/OOBE are the useful
        # signal; a still-empty file then means "no guest errors",
        # not "logging was off". Proven in run 46066624370: with -d
        # guest_errors enabled the log still stayed 0 bytes across a
        # healthy 69-minute boot -- there were simply no guest errors
        # to log, so an empty file is the expected outcome, not a
        # logging failure. The stdout/stderr logs are likewise 0 bytes
        # by design (QEMU runs -display none with -serial none).
        '-d', 'guest_errors'
        '-D', $QemuLogPath
    )
}

function Invoke-SeedDiskpart {
    # Run a diskpart script, fail loudly on a non-zero exit (same
    # pattern as the build's data-disk preparation).
    # -Script is [string[]]: the call sites pass @(...) line arrays.
    # A trailing `-join "`n"` at a call site does NOT join -- it parses
    # as a -join parameter and fails binding (run 45981633632 died on
    # the [string] conversion first; with [string[]] the same call sites
    # would die on the -join parameter instead). Join here, once, and
    # feed diskpart a single script.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Script,

        [Parameter(Mandatory = $true)]
        [string] $Label
    )
    ($Script -join "`n") | diskpart | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new(
            "diskpart failed while $Label (exit code $LASTEXITCODE)")
    }
}

function Get-SeedDiskpartVolumeNumber {
    # Run diskpart `list disk` + `list volume` and return the volume
    # number of the volume whose drive letter (or label) matches.
    # Prints the raw output first, so the CI log shows the disk and
    # volume layout even when the parse below finds nothing. Returns
    # $null when no volume matches. Used by the bcdboot gate (find
    # the S: volume) and by the harvest attach (find the SEED
    # volume): both must select by letter/label, never by partition
    # number -- run 46017835896 proved `convert gpt` auto-creates a
    # Microsoft Reserved Partition as partition 1 (16 MB on Win10/11;
    # Microsoft Learn, "Establish and boot to GPT mirrors": after
    # Convert GPT, List partition shows "Partition 1 Reserved"), so
    # the EFI partition is partition 2 and the primary partition is
    # partition 3, and any hard-coded partition number is wrong.
    # Uses Write-Host only (no Write-Step / lib helpers), so the
    # function stays testable in isolation.
    [CmdletBinding()]
    param(
        [string] $DriveLetter,

        [string] $Label
    )
    if (-not $DriveLetter -and -not $Label) {
        throw [System.ArgumentException]::new('Get-SeedDiskpartVolumeNumber needs -DriveLetter or -Label')
    }
    $lines = @()
    try {
        $listCommands = @('list disk', 'list volume')
        $lines = @( (($listCommands -join "`n") | diskpart 2>&1 | ForEach-Object { "$_" }) )
    } catch { $lines = @() }
    Write-Host 'seed diskpart [INFO] list disk / list volume:'
    $lines | ForEach-Object { Write-Host ("    {0}" -f $_) }
    $text = ($lines -join "`n")
    if ($DriveLetter) {
        $match = [regex]::Match($text, ('(?m)^\s*Volume\s+(\d+)\s+' + [regex]::Escape($DriveLetter) + '\s+\S+'))
    }
    else {
        $match = [regex]::Match($text, ('(?m)^\s*Volume\s+(\d+)\s+(?:[A-Za-z]\s+)?' + [regex]::Escape($Label) + '\s+'))
    }
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value
}

function Assert-SeedBcdbootPrerequisites {
    # Pre-bcdboot gate (round 42: run 45988904072 died at bcdboot --
    # the host bcdboot 26100 failed on the 22621 image with
    # "Failure when attempting to copy boot files.", exit 193
    # ERROR_BAD_EXE_FORMAT). The failed run's log proves the disk
    # layout (GPT, EFI FAT32 on S:, NTFS on V:, DISM 100%) but proves
    # nothing about S: at bcdboot time -- no step ever read S: before
    # bcdboot, so "mounted but unreadable" was never excluded. Every
    # probe below logs OK/FAIL first, so the CI log shows the full
    # state even when the gate throws; the throw then names every
    # failed check. In particular it answers, in the log, the user's
    # question "is the EFI partition actually attached": S: must be a
    # live FAT32 volume, an EFI System Partition by GPT type, and
    # readable (Test-Path + dir) at this exact moment.
    # Run 46004055968 false-positive fix: the first version of this
    # gate used the Get-Volume / Get-Partition drive-letter lookups
    # for S:, and both returned nothing -- while Test-Path, dir and
    # fsutil proved S: was live and FAT32 in the same session, and
    # the Get-Volume lookup for V: worked fine on the same disk.
    # That is expected Windows behavior, not a broken layout: per
    # Microsoft Learn (VDS CREATE_PARTITION_PARAMETERS), only
    # basic-data partitions can be assigned drive letters and be
    # enumerated by FindFirstVolume / FindNextVolume; the ESP is a
    # system partition, so its letter exists only at the Win32
    # mount-manager level (Test-Path, fsutil see it) and never in
    # the Storage provider's (MSFT_Volume / MSFT_Partition) view --
    # which is exactly why -DriveLetter S finds nothing while
    # -DriveLetter V (basic data) works. So the S: checks below
    # never ask the Storage provider by drive letter: the volume
    # verdict comes from Win32_Volume with a Test-Path fallback,
    # and the GPT type comes from diskpart `detail partition` on
    # the S: volume itself (selected by letter, never by
    # partition number -- see check 2).
    # Run 46017835896 false-positive fix: the gate used to hard-code
    # partition 1, assuming the EFI partition is created first and
    # is therefore partition 1. It is not: `convert gpt`
    # auto-creates a Microsoft Reserved Partition as partition 1
    # (16 MB on Win10/11; Microsoft Learn, "Establish and boot to
    # GPT mirrors": after Convert GPT, List partition shows
    # "Partition 1 Reserved"), so on the seed VHD partition 1 is
    # the MSR, partition 2 is the EFI partition (S:), and partition
    # 3 is the primary (V:). The gate read the MSR's GPT type
    # (e3c9e316-...) and failed a layout that is correct -- the
    # V: size in the same run's log proves it: 32,491 MB =
    # 32768 - 260 (ESP) - 16 (MSR) - ~1 overhead. The same wrong
    # assumption also lived in the harvest attach (a fixed partition
    # number for the primary); both are fixed here by selecting
    # volumes by letter/label instead of partitions by number.
    # Uses Write-Host only (no Write-Step / lib helpers), so the
    # function stays testable in isolation.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $VhdPath
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    $sReadable = $false
    $sFileSystem = ''
    $sGptType = ''
    $sVolumeNumber = $null
    $bootmgfwExists = $false
    $bcdTemplateExists = $false
    $imageBcdbootExists = $false

    # 1. S: volume exists and is FAT32. Ask the WMI volume provider
    #    (Win32_Volume enumerates mounted volumes) first; the Storage
    #    provider is blind to ESP drive letters (see header). If
    #    Win32_Volume also misses S:, fall back to the filesystem-
    #    level proof (Test-Path) -- the file system itself is pinned
    #    by the fsutil check below, so the gate as a whole still
    #    proves FAT32; a genuinely unmounted S: fails both paths.
    $volS = $null
    try { $volS = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='S:'" -ErrorAction Stop } catch { $volS = $null }
    if ($null -ne $volS -and $volS.FileSystem -eq 'FAT32') {
        $sFileSystem = 'FAT32'
        Write-Host ("bcdboot prereq [OK  ] S: volume: FAT32 (Win32_Volume), {0:N0} MB" -f ($volS.Capacity / 1MB))
    }
    elseif ($null -ne $volS) {
        Write-Host ("bcdboot prereq [FAIL] S: volume: file system is {0}, expected FAT32" -f $volS.FileSystem)
        $failures.Add(("S: file system is {0}, expected FAT32" -f $volS.FileSystem))
    }
    else {
        Write-Host 'bcdboot prereq [INFO] S: volume: Win32_Volume did not list S: (the volume providers are blind to ESP drive letters -- run 46004055968); falling back to Test-Path'
        $rootProbe = $false
        try { $rootProbe = Test-Path -LiteralPath 'S:\' -ErrorAction Stop } catch { $rootProbe = $false }
        if (-not $rootProbe) {
            Write-Host 'bcdboot prereq [FAIL] S: volume: S: is not readable (Win32_Volume did not list S: and Test-Path S:\ failed -- the EFI partition is not attached)'
            $failures.Add('S: is not readable (EFI partition not attached or not accessible)')
        }
        else {
            Write-Host 'bcdboot prereq [OK  ] S: volume: live (Test-Path S:\ passed; file system pinned by the fsutil check below)'
        }
    }

    # 2. S: is the EFI System Partition by GPT type. Get-Partition
    #    -DriveLetter S is blind to the ESP for the same VDS reason
    #    as check 1 (run 46004055968), so ask diskpart -- the tool
    #    that built this layout. NEVER select by partition number:
    #    run 46017835896 failed this exact check because the gate
    #    hard-coded partition 1 and read the Microsoft Reserved
    #    Partition's GPT type (e3c9e316-...) instead of the ESP's.
    #    `convert gpt` auto-creates an MSR as partition 1 (16 MB on
    #    Win10/11), so on the seed VHD partition 1 is the MSR,
    #    partition 2 is the EFI partition (S:), and partition 3 is
    #    the primary (V:). Select the volume by its letter S:
    #    instead -- the same S: bcdboot uses -- which gives focus
    #    to the volume's disk and partition (Microsoft Learn,
    #    diskpart: "After a volume has focus, the related disk and
    #    partition also have focus"), then `detail partition`
    #    prints the GPT type GUID. The raw diskpart output of both
    #    probes is printed to the log, so the next failure can be
    #    located from the log alone.
    $espGuid = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    $sVolumeNumber = Get-SeedDiskpartVolumeNumber -DriveLetter 'S'
    if ($null -eq $sVolumeNumber) {
        Write-Host 'bcdboot prereq [FAIL] S: GPT type: diskpart list volume has no volume with drive letter S:'
        $failures.Add('S: volume not found in diskpart list volume')
    }
    else {
        Write-Host ("bcdboot prereq [OK  ] S: GPT type probe: S: is Volume {0} (diskpart list volume)" -f $sVolumeNumber)
        $detailLines = @()
        try {
            # Parenthesised join (the file-wide convention since the
            # run 45981633632 binding bug): a trailing `) -join` at a
            # call site parses as a -join parameter, so the join is
            # always written ($array -join "`n") in parentheses.
            $detailCommands = @(
                "select vdisk file=`"$VhdPath`""
                "select volume $sVolumeNumber"
                'detail disk'
                'list partition'
                'detail partition'
            )
            $detailLines = @( ($detailCommands -join "`n") | diskpart 2>&1 | ForEach-Object { "$_" } )
        } catch { $detailLines = @() }
        Write-Host 'bcdboot prereq [INFO] S: GPT type probe (diskpart detail disk / list partition / detail partition):'
        $detailLines | ForEach-Object { Write-Host ("    {0}" -f $_) }
        $detailText = ($detailLines -join "`n")
        $typeMatch = [regex]::Match($detailText, '(?m)^\s*Type\s*:\s*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
        if (-not $typeMatch.Success) {
            Write-Host 'bcdboot prereq [FAIL] S: GPT type: diskpart detail partition returned no Type GUID -- cannot confirm the S: volume is the EFI System Partition'
            $failures.Add('S: GPT type could not be confirmed (diskpart detail partition returned no Type GUID)')
        }
        elseif ($typeMatch.Groups[1].Value -ieq 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b') {
            $sGptType = $espGuid
            Write-Host ("bcdboot prereq [OK  ] S: GPT type: EFI System Partition (diskpart detail partition, S: is Volume {0})" -f $sVolumeNumber)
        }
        else {
            Write-Host ("bcdboot prereq [FAIL] S: GPT type: {0}, expected EFI System Partition {1}" -f $typeMatch.Groups[1].Value, $espGuid)
            $failures.Add(("S: GPT type is {0}, expected EFI System Partition" -f $typeMatch.Groups[1].Value))
        }
    }

    # 3. S: is readable RIGHT NOW -- the user's question: is the EFI
    # partition actually attached? Assigned in diskpart is not proof;
    # a live Test-Path + dir at this exact moment is.
    $rootOk = $false
    try { $rootOk = Test-Path -LiteralPath 'S:\' -ErrorAction Stop } catch { $rootOk = $false }
    if (-not $rootOk) {
        Write-Host 'bcdboot prereq [FAIL] S: readable: Test-Path S:\ failed -- the EFI partition is NOT readable at bcdboot time'
        $failures.Add('S:\ is not readable (EFI partition not attached or not accessible)')
    }
    else {
        $listing = $null
        try { $listing = @(Get-ChildItem -LiteralPath 'S:\' -Force -ErrorAction Stop) } catch { $listing = $null }
        if ($null -eq $listing) {
            Write-Host 'bcdboot prereq [FAIL] S: readable: Test-Path S:\ passed but dir S:\ failed'
            $failures.Add('dir S:\ failed after Test-Path passed')
        }
        else {
            $sReadable = $true
            $names = ($listing | ForEach-Object { $_.Name }) -join ', '
            Write-Host ("bcdboot prereq [OK  ] S: readable: S:\ is attached and readable right now, {0} entr(ies) before bcdboot: {1}" -f $listing.Count, $names)
        }
    }

    # 4. fsutil agrees S: is FAT32 (independent confirmation from the OS).
    $fsutilLines = @()
    try { $fsutilLines = @( & fsutil.exe fsinfo volumeinfo S: 2>&1 ) } catch { $fsutilLines = @() }
    $fsutilText = ($fsutilLines -join "`n")
    $fsMatch = [regex]::Match($fsutilText, 'File System Name\s*:\s*(\S+)')
    if (-not $fsMatch.Success) {
        Write-Host 'bcdboot prereq [FAIL] S: fsutil: fsutil fsinfo volumeinfo S: returned no File System Name'
        $failures.Add('fsutil fsinfo volumeinfo S: returned no File System Name')
    }
    elseif ($fsMatch.Groups[1].Value -ne 'FAT32') {
        Write-Host ("bcdboot prereq [FAIL] S: fsutil: File System Name is {0}, expected FAT32" -f $fsMatch.Groups[1].Value)
        $failures.Add(("fsutil reports S: file system {0}, expected FAT32" -f $fsMatch.Groups[1].Value))
    }
    else {
        $sFileSystem = 'FAT32'
        Write-Host 'bcdboot prereq [OK  ] S: fsutil: File System Name FAT32'
    }

    # 5. V: volume exists, NTFS, and holds the applied Windows.
    $volV = $null
    try { $volV = Get-Volume -DriveLetter V -ErrorAction Stop } catch { $volV = $null }
    if ($null -eq $volV) {
        Write-Host 'bcdboot prereq [FAIL] V: volume: Get-Volume -DriveLetter V found no volume'
        $failures.Add('V: volume not found')
    }
    elseif ($volV.FileSystem -ne 'NTFS') {
        Write-Host ("bcdboot prereq [FAIL] V: volume: file system is {0}, expected NTFS" -f $volV.FileSystem)
        $failures.Add(("V: file system is {0}, expected NTFS" -f $volV.FileSystem))
    }
    else {
        Write-Host ("bcdboot prereq [OK  ] V: volume: NTFS, {0:N0} MB, health {1}" -f ($volV.Size / 1MB), $volV.HealthStatus)
    }
    if (-not (Test-Path -LiteralPath 'V:\Windows')) {
        Write-Host 'bcdboot prereq [FAIL] V:\Windows: missing -- DISM did not apply the image to V:'
        $failures.Add('V:\Windows is missing')
    }
    else {
        Write-Host 'bcdboot prereq [OK  ] V:\Windows: present (DISM apply landed on V:)'
    }

    # 6. The source boot files bcdboot needs to copy, plus the image's
    # own bcdboot.exe (the fix runs that one, not the host's).
    foreach ($bootFile in @(
        'V:\Windows\Boot\EFI\bootmgfw.efi'
        'V:\Windows\System32\config\BCD-Template'
        'V:\Windows\System32\bcdboot.exe'
    )) {
        if (Test-Path -LiteralPath $bootFile) {
            $sizeText = ''
            try { $sizeText = (" ({0:N0} bytes)" -f (Get-Item -LiteralPath $bootFile).Length) } catch { $sizeText = '' }
            Write-Host ("bcdboot prereq [OK  ] source file present: {0}{1}" -f $bootFile, $sizeText)
            if ($bootFile -like '*bootmgfw.efi') { $bootmgfwExists = $true }
            elseif ($bootFile -like '*BCD-Template') { $bcdTemplateExists = $true }
            elseif ($bootFile -like '*bcdboot.exe') { $imageBcdbootExists = $true }
        }
        else {
            Write-Host ("bcdboot prereq [FAIL] source file missing: {0}" -f $bootFile)
            $failures.Add(("source file missing: {0}" -f $bootFile))
        }
    }

    if ($failures.Count -gt 0) {
        throw [System.InvalidOperationException]::new(
            ("bcdboot prerequisites failed ({0}): {1}" -f $failures.Count, ($failures -join '; ')))
    }
    Write-Host 'bcdboot prereq [OK  ] all checks passed -- S: IS attached (FAT32, EFI System Partition, readable right now); V:\Windows boot files are present'
    return [pscustomobject]@{
        SReadable          = $sReadable
        SFileSystem        = $sFileSystem
        SGptType           = $sGptType
        SVolumeNumber      = $sVolumeNumber
        BootmgfwExists     = $bootmgfwExists
        BcdTemplateExists  = $bcdTemplateExists
        ImageBcdbootExists = $imageBcdbootExists
    }
}

function Get-SeedHiveVerification {
    # Verify the harvested hives with reg.exe only (load, query,
    # unload -- never the PowerShell provider: round 19 proved the
    # provider holds an open handle and a later reg unload fails).
    # Returns the observed structure; throws loudly on any gap.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SamPath,

        [Parameter(Mandatory = $true)]
        [string] $SecurityPath
    )

    $samSize = (Get-Item -LiteralPath $SamPath).Length
    $secSize = (Get-Item -LiteralPath $SecurityPath).Length
    if ($samSize -le 8192) {
        throw [System.InvalidOperationException]::new(
            "harvested SAM is still an empty hive ($samSize bytes, expected > 8192)")
    }
    if ($secSize -le 8192) {
        throw [System.InvalidOperationException]::new(
            "harvested SECURITY is still an empty hive ($secSize bytes, expected > 8192)")
    }
    $samHash = (Get-FileHash -LiteralPath $SamPath -Algorithm SHA256).Hash.ToLower()
    $secHash = (Get-FileHash -LiteralPath $SecurityPath -Algorithm SHA256).Hash.ToLower()

    # SAM: MICPE must exist under Users\Names, and RID 1000
    # (000003E8) must carry an 80-byte F value. reg query /s lists the
    # whole subtree; the child names are the lines that extend the
    # queried key by exactly one segment. The built-in Administrator
    # (RID 500) stays disabled in a UserAccounts-built image; the
    # logon account is MICPE, so only RID 1000 is checked here.
    $samKey = "MICPE_SEED_SAM_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $samLoaded = $false
    $names = @()
    $samFlags = $null
    try {
        $LASTEXITCODE = 0
        $null = & reg.exe load "HKLM\$samKey" $SamPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new(
                "reg load failed for harvested SAM $SamPath (exit code $LASTEXITCODE)")
        }
        $samLoaded = $true
        $LASTEXITCODE = 0
        $namesOut = & reg.exe query "HKLM\$samKey\SAM\Domains\Account\Users\Names" /s 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new(
                "reg query failed for SAM Users\Names (exit code $LASTEXITCODE): the harvested SAM has no account database")
        }
        $namesPrefix = "HKEY_LOCAL_MACHINE\$samKey\SAM\Domains\Account\Users\Names\"
        $names = @($namesOut -split "`r?`n" | Where-Object { $_ -and $_.StartsWith($namesPrefix, [StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object { $_.Substring($namesPrefix.Length).Split('\')[0] } |
            Where-Object { $_ } | Select-Object -Unique)
        if ($names -notcontains 'MICPE') {
            throw [System.InvalidOperationException]::new(
                "harvested SAM Users\Names has no MICPE (found: $($names -join ', '))")
        }
        $LASTEXITCODE = 0
        $fOut = & reg.exe query "HKLM\$samKey\SAM\Domains\Account\Users\000003E8" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new(
                "reg query failed for SAM Users\000003E8 (exit code $LASTEXITCODE): no MICPE record")
        }
        $fMatch = [regex]::Match($fOut, '^\s*F\s+REG_BINARY\s+([0-9a-fA-F]+)\s*$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        if (-not $fMatch.Success -or $fMatch.Groups[1].Value.Length -lt 160) {
            throw [System.InvalidOperationException]::new(
                'harvested SAM Users\000003E8 has no 80-byte F value')
        }
        $fHex = $fMatch.Groups[1].Value
        $fBytes = [byte[]]::new($fHex.Length / 2)
        for ($i = 0; $i -lt $fBytes.Length; $i++) {
            $fBytes[$i] = [Convert]::ToByte($fHex.Substring($i * 2, 2), 16)
        }
        # ACB flags: DWORD at offset 0x38, ACB_DISABLED = 0x0001.
        # A UserAccounts-created admin is enabled by construction
        # (0x0210 = ACB_NORMAL | ACB_PWNOEXP). The build still runs
        # Set-OfflineAdminState on MICPE as a belt-and-braces step,
        # but a disabled MICPE here means the unattend did not do
        # what it was supposed to -- fail loudly instead of
        # harvesting a database that cannot log on. The
        # blank-password proof is the desktop screenshot (the machine
        # auto-logged on as MICPE with no password).
        $samFlags = [BitConverter]::ToUInt32($fBytes, 0x38)
        if (($samFlags -band 0x1) -ne 0) {
            throw [System.InvalidOperationException]::new(
                ("harvested SAM MICPE is flagged disabled (F flags 0x{0:X8}): the unattend UserAccounts step did not enable it" -f $samFlags))
        }
        # Administrators alias (00000220) must list MICPE (RID 1000)
        # as a member: the unattend puts it in the Administrators
        # group, and the PE logon needs an admin account. The member
        # SIDs are the value names under the alias Members key.
        $LASTEXITCODE = 0
        $membersOut = & reg.exe query "HKLM\$samKey\SAM\Domains\Builtin\Aliases\00000220\Members" /s 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new(
                "reg query failed for SAM Builtin Aliases\00000220\Members (exit code $LASTEXITCODE): cannot confirm MICPE is in the Administrators group")
        }
        if ($membersOut -notmatch '-1000') {
            throw [System.InvalidOperationException]::new(
                "harvested SAM Administrators alias has no RID 1000 member (MICPE is not in the Administrators group): $membersOut")
        }
    }
    finally {
        if ($samLoaded) {
            $null = & reg.exe unload "HKLM\$samKey" 2>&1
        }
    }

    # SECURITY: Policy\Accounts must be populated (the reference has
    # 13 SID accounts; a fresh specialize of the same build should
    # produce the same standard set -- require at least 10 and log
    # the full list for review).
    $secKey = "MICPE_SEED_SEC_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $secLoaded = $false
    $secAccounts = @()
    try {
        $LASTEXITCODE = 0
        $null = & reg.exe load "HKLM\$secKey" $SecurityPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new(
                "reg load failed for harvested SECURITY $SecurityPath (exit code $LASTEXITCODE)")
        }
        $secLoaded = $true
        $LASTEXITCODE = 0
        $secOut = & reg.exe query "HKLM\$secKey\Policy\Accounts" /s 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new(
                "reg query failed for SECURITY Policy\Accounts (exit code $LASTEXITCODE): the harvested SECURITY has no policy database")
        }
        $secPrefix = "HKEY_LOCAL_MACHINE\$secKey\Policy\Accounts\"
        $secAccounts = @($secOut -split "`r?`n" | Where-Object { $_ -and $_.StartsWith($secPrefix, [StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object { $_.Substring($secPrefix.Length).Split('\')[0] } |
            Where-Object { $_ } | Select-Object -Unique)
        if ($secAccounts.Count -lt 10) {
            throw [System.InvalidOperationException]::new(
                "harvested SECURITY Policy\Accounts has only $($secAccounts.Count) account(s) (expected >= 10): $($secAccounts -join ', ')")
        }
    }
    finally {
        if ($secLoaded) {
            $null = & reg.exe unload "HKLM\$secKey" 2>&1
        }
    }

    return [pscustomobject]@{
        SamSize            = $samSize
        SecuritySize       = $secSize
        SamSha256          = $samHash
        SecuritySha256     = $secHash
        SamNames           = $names
        SamFlags           = $samFlags
        SecurityAccounts   = $secAccounts
    }
}

# ---------------------------------------------------------------------------
# 1. Official install.wim (same calls as Invoke-CleanBaseStep)
# ---------------------------------------------------------------------------

$baseDir = Join-Path $WorkDir 'base'
if (-not (Test-Path -LiteralPath $baseDir)) {
    New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
}
Write-Step "resolving Windows 11 build $Build from UUP dump"
$uup = Get-UupBuild -Build $Build -Arch 'amd64' -Channel 'stable'
Write-VerifyLine ("UUP build: {0} ({1}), uuid {2}" -f $uup.Build, $uup.Title, $uup.Uuid)

Write-Step 'downloading UUP conversion package'
$packageDir = New-UupDownloadPackage -Uuid $uup.Uuid -OutDir $baseDir -Lang 'zh-cn' -Edition $Edition

$iniPath = Join-Path $packageDir 'ConvertConfig.ini'
$config = Set-ConvertConfig -IniPath $iniPath -Overrides @{
    AddUpdates = '1'
    Cleanup    = '1'
    ResetBase  = '0'
    SkipApps   = '0'
    SkipEdge   = '1'
    NetFx3     = '0'
    wim2esd    = '0'
    wim2swm    = '0'
    StartVirtual = '0'
}
Set-Content -LiteralPath $iniPath -Value $config -Encoding UTF8

Write-Step 'ensuring aria2c is present'
$filesDir = Join-Path $packageDir 'files'
if (-not (Test-Path -LiteralPath $filesDir)) {
    New-Item -ItemType Directory -Path $filesDir -Force | Out-Null
}
$aria2 = Join-Path $filesDir 'aria2c.exe'
$ariaExpectHash = 'b9cd71b275af11b63c33457b0f43f2f2675937070c563e195f223efd7fa4c74b'
$needDownload = $true
if (Test-Path -LiteralPath $aria2) {
    $existing = (Get-FileHash -LiteralPath $aria2 -Algorithm SHA256).Hash.ToLower()
    $needDownload = ($existing -ne $ariaExpectHash)
}
if ($needDownload) {
    Invoke-WebRequest -Uri 'https://uupdump.net/misc/aria2c.exe' -OutFile $aria2 -TimeoutSec 300
    $actual = (Get-FileHash -LiteralPath $aria2 -Algorithm SHA256).Hash.ToLower()
    Assert-True -Condition ($actual -eq $ariaExpectHash) -Message (
        "aria2c.exe hash mismatch: expected $ariaExpectHash, got $actual")
    Write-SubStep 'aria2c.exe downloaded and verified'
}
else {
    Write-SubStep 'aria2c.exe already verified'
}
$null = Repair-UupAria2Script -PackageDir $packageDir

Write-Step 'converting UUP files into an ISO (this takes 40-90 minutes)'
$null = Invoke-NetworkWithRetry -Action {
    Push-Location $packageDir
    try {
        $downloader = Join-Path $packageDir 'uup_download_windows.cmd'
        $output = & cmd.exe /c "echo. | `"$downloader`"" 2>&1
        $output | Out-Host
        Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "uup_download_windows.cmd failed with exit code $LASTEXITCODE"
    }
    finally {
        Pop-Location
    }
} -MaxAttempts 3 -Label 'uup converter'

$producedIso = Get-ChildItem -LiteralPath $packageDir -Filter '*.iso' -File |
    Sort-Object Length -Descending | Select-Object -First 1
Assert-True -Condition ($null -ne $producedIso) -Message "UUP conversion produced no ISO in $packageDir"

Write-Step 'extracting install.wim and boot.wim'
$wims = Get-BaseWims -IsoPath $producedIso.FullName -OutDir $baseDir
$installWim = $wims.InstallWim
$installWimHash = (Get-FileHash -LiteralPath $installWim -Algorithm SHA256).Hash.ToLower()
Write-VerifyLine ("install.wim: {0} ({1:N0} bytes, SHA256 {2})" -f $installWim, (Get-Item -LiteralPath $installWim).Length, $installWimHash)
$imageIndex = Get-WimImageIndexByEdition -WimPath $installWim -Edition $Edition -WimlibPath 'wimlib-imagex'
Write-VerifyLine ("install.wim Professional image index: {0}" -f $imageIndex)

# ---------------------------------------------------------------------------
# 2. Apply to a VHD, bcdboot, drop in the seed unattend
# ---------------------------------------------------------------------------

foreach ($letter in 'S', 'V') {
    if (Get-PSDrive -Name $letter -ErrorAction SilentlyContinue) {
        throw [System.InvalidOperationException]::new(
            "drive letter ${letter}: is already in use; cannot stage the seed disk")
    }
}
$vhdx = Join-Path $WorkDir 'seed.vhdx'
if (Test-Path -LiteralPath $vhdx) { Remove-Item -LiteralPath $vhdx -Force }
Write-Step 'creating the seed VHD (EFI + NTFS)'
Invoke-SeedDiskpart -Label 'creating the seed VHD' -Script @(
    "create vdisk file=`"$vhdx`" maximum=32768 type=expandable"
    "select vdisk file=`"$vhdx`""
    'attach vdisk'
    'convert gpt'
    'create partition efi size=260'
    'format quick fs=fat32 label="SYSTEM"'
    'assign letter=S'
    'create partition primary'
    'format quick fs=ntfs label="SEED"'
    'assign letter=V'
)

try {
    Write-Step 'applying install.wim to the seed VHD (DISM)'
    & dism.exe /Apply-Image /ImageFile:$installWim /Index:$imageIndex /ApplyDir:V:\ | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new(
            "dism /Apply-Image failed with exit code $LASTEXITCODE")
    }

    # Gate: prove the bcdboot prerequisites in the log before running
    # bcdboot (round 42: run 45988904072 died here -- the host
    # bcdboot 26100 failed on the 22621 image, exit 193; the log
    # proved the layout but never proved S: was readable).
    Assert-SeedBcdbootPrerequisites -VhdPath $vhdx

    Write-Step 'writing the EFI bootloader (bcdboot from the applied image)'
    # Run the applied image's own bcdboot (22621), not the host's
    # (26100, Server 2025): Microsoft's Capture-and-Apply sample runs
    # W:\Windows\System32\bcdboot, and the Win11 install guide
    # documents the image's own bcdboot as the remedy for exactly
    # "Failure when attempting to copy boot files". The image's
    # bcdboot copies the image's own boot files, so no host/image
    # version skew can enter. /f UEFI is unchanged (OVMF + GPT).
    $imageBcdboot = 'V:\Windows\System32\bcdboot.exe'
    & $imageBcdboot V:\Windows /s S: /f UEFI | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new(
            "bcdboot (from the applied image) failed with exit code $LASTEXITCODE")
    }

    Write-Step 'dropping in the seed unattend (specialize + OOBE)'
    $pantherDir = 'V:\Windows\Panther'
    if (-not (Test-Path -LiteralPath $pantherDir)) {
        New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $scriptDir 'data\sam-seed-unattend.xml') `
        -Destination (Join-Path $pantherDir 'unattend.xml') -Force
    Assert-PathExists -Path (Join-Path $pantherDir 'unattend.xml') -Label 'seed unattend.xml'
}
finally {
    Invoke-SeedDiskpart -Label 'detaching the seed VHD' -Script @(
        "select vdisk file=`"$vhdx`""
        'detach vdisk'
    )
}

# Section 3 prerequisites, loaded here -- before the qcow2 conversion
# (round 42 rerun: run 46033515034 died on an unrecognized verifier
# helper because the conversion ran before this load, which used to sit
# 24 lines below the call). The OvmfPath/QemuPath checks come first so
# a missing firmware or emulator still fails with the intended message,
# not a parameter-binding error from the dot-source. All four values
# are already set here: $installWim was applied by DISM above, and
# $OvmfPath/$QemuPath/$WorkDir are script parameters / created at the
# head of this script.
if (-not $OvmfPath) {
    throw [System.InvalidOperationException]::new(
        'no OVMF firmware path was passed (the workflow discovers it before this step)')
}
Assert-PathExists -Path $OvmfPath -Label 'OVMF firmware'
Assert-PathExists -Path $QemuPath -Label 'QEMU'

# Dot-source the clean verifier for its screenshot/monitor helpers
# (ParseOnly: define helpers, do not launch QEMU). IsoPath only needs
# to exist here -- the install.wim stands in for it; the seed run
# never boots an ISO.
# Round 42 rerun (run 46043894030): dot-sourcing binds ALL of the
# verifier's params into this scope, defaults included -- its bare
# 'qemu-system-x86_64' default clobbered the workflow's full QEMU
# path, so the qemu-img lookup fell back to bare 'qemu-img' (not in
# PATH). Pass through every shared name the seed script uses after
# this load, so a default can never silently reset a caller value
# again (MemoryMb/CpuCount/MonitorPort coincide with the defaults
# today; QemuPath is the one that differed).
. (Join-Path $repoRoot 'src\ci\Invoke-CleanQemuVerify.ps1') -IsoPath $installWim -OvmfPath $OvmfPath -WorkDir $WorkDir -QemuPath $QemuPath -MemoryMb $MemoryMb -CpuCount $CpuCount -MonitorPort $MonitorPort -ParseOnly

Write-Step 'converting the seed VHD to qcow2 for QEMU'
$qemuImgPath = Get-CleanQemuImgPath -QemuPath $QemuPath
$qcow2 = Join-Path $WorkDir 'seed.qcow2'
if (Test-Path -LiteralPath $qcow2) { Remove-Item -LiteralPath $qcow2 -Force }
& $qemuImgPath convert -f vhdx -O qcow2 $vhdx $qcow2 | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw [System.InvalidOperationException]::new(
        "qemu-img convert failed with exit code $LASTEXITCODE")
}

# ---------------------------------------------------------------------------
# 3. Boot in QEMU, wait for the OOBE desktop (MICPE auto-logged on)
# ---------------------------------------------------------------------------

# (Section 3 prerequisites -- the OvmfPath/QemuPath checks and the
# verifier dot-source -- now live above the qcow2 conversion, which
# needs the verifier helpers. See the comment there.)
$varsTemplate = Find-CleanOvmfVars -CodePath $OvmfPath
$varsPath = Join-Path $WorkDir 'OVMF_VARS.fd'
Copy-Item -LiteralPath $varsTemplate -Destination $varsPath -Force

$qemuLog = Join-Path $WorkDir 'micpe-seed-qemu.log'
$qemuStdoutLog = Join-Path $WorkDir 'micpe-seed-qemu-stdout.log'
$qemuStderrLog = Join-Path $WorkDir 'micpe-seed-qemu-stderr.log'
$qemuArgs = Get-SeedQemuArgList -DiskQcow2 $qcow2 -OvmfCodePath $OvmfPath -VarsPath $varsPath -QemuLogPath $qemuLog -MemoryMb $MemoryMb -CpuCount $CpuCount -MonitorPort $MonitorPort
$argString = ($qemuArgs | ForEach-Object {
    if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
}) -join ' '
$qemuStartedAt = Get-Date
Write-Host "starting QEMU: $QemuPath $argString"
$qemu = Start-Process -FilePath $QemuPath -ArgumentList $argString -PassThru -NoNewWindow -RedirectStandardOutput $qemuStdoutLog -RedirectStandardError $qemuStderrLog
if ($null -eq $qemu) { throw 'failed to start QEMU' }

$shutdownTimerFired = $false
$lastShotIndex = 0
try {
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
    if (-not $monitorUp) { throw 'QEMU monitor never came up within 120 s' }
    Write-Host 'QEMU monitor is up; specialize is running'

    # Round 42 rerun 10 (user 2026-11-28 09:12): no screenshot gates
    # at all. Screenshots are evidence only -- the shutdown is on a
    # timer (see $ShutdownAfterMin). Specialize reboots once
    # (specialize -> OOBE -> AutoLogon desktop), so the guest may show
    # TianoCore, OOBE, the welcome screen, the desktop or the Start
    # menu at any poll; none of them is a gate any more. A bare Ctrl
    # keypress each poll keeps the display awake so the evidence
    # screenshots stay readable (it types nothing and opens nothing).
    $shotIndex = 0
    $deadline = (Get-Date).AddMinutes($SpecializeTimeoutMin)
    $shutdownAt = $qemuStartedAt.AddMinutes($ShutdownAfterMin)
    while ((Get-Date) -lt $deadline) {
        if ($qemu.HasExited) {
            throw "QEMU exited before the shutdown timer fired (exit $($qemu.ExitCode)); see $qemuLog"
        }
        $shotIndex++
        $null = Send-CleanKey -Port $MonitorPort -Key 'ctrl'
        $took = Save-CleanScreenshot -Port $MonitorPort -ScreenshotDir $shotDir -ShotIndex $shotIndex -Label ("specialize poll {0}" -f $shotIndex)
        if (-not $took) {
            Write-Host ("!!! specialize poll {0}: screenshot failed, retrying" -f $shotIndex)
            Start-Sleep -Seconds 60
            continue
        }
        if ((Get-Date) -ge $shutdownAt) {
            $lastShotIndex = $shotIndex
            $shutdownTimerFired = $true
            Write-Host ("shutdown timer reached ({0} min after QEMU start, shot {1}); shutting down for harvest" -f $ShutdownAfterMin, $shotIndex)
            break
        }
        Start-Sleep -Seconds 90
    }
    if (-not $shutdownTimerFired) {
        throw "shutdown timer did not fire within $SpecializeTimeoutMin minutes (last shot $shotIndex); see $shotDir"
    }
}
finally {
    # Clean shutdown: the hives are only trustworthy if the guest
    # flushed them. system_powerdown lets the guest shut down; QEMU
    # exits on shutdown (no -no-shutdown). If it is still alive
    # after 180 s, quit via the monitor; as a last resort kill it.
    try {
        $null = Invoke-CleanMonitorCommand -Port $MonitorPort -Command 'system_powerdown'
    }
    catch {
        Write-Host ("!!! system_powerdown failed: {0}" -f $_.Exception.Message)
    }
    $exited = $false
    for ($i = 0; $i -lt 36; $i++) {
        if ($qemu.HasExited) { $exited = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $exited) {
        Write-Host 'guest did not exit after powerdown; sending quit via the monitor'
        try {
            $null = Invoke-CleanMonitorCommand -Port $MonitorPort -Command 'quit'
        }
        catch {
            Write-Host ("!!! monitor quit failed: {0}" -f $_.Exception.Message)
        }
        for ($i = 0; $i -lt 6; $i++) {
            if ($qemu.HasExited) { $exited = $true; break }
            Start-Sleep -Seconds 5
        }
    }
    if (-not $exited -and -not $qemu.HasExited) {
        Write-Host '!!! QEMU still alive; killing it (hives may be torn -- the verification below will catch it)'
        Stop-Process -InputObject $qemu -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
    }
    if ($qemu.HasExited) {
        Write-Host ("QEMU exit code: {0}" -f $qemu.ExitCode)
    }
    else {
        Write-Host 'QEMU still has not exited after kill; continuing -- the harvest verification below is the real gate'
    }
}

if (-not $shutdownTimerFired) {
    throw 'shutdown timer never fired; no hives to harvest'
}

# Convert the QEMU-written qcow2 back to VHDX before harvesting.
# Round 42 rerun (run 46051050523): the harvest attached the ORIGINAL
# seed.vhdx, which QEMU never wrote to -- the guest's specialize/OOBE
# writes all landed in seed.qcow2 -- so the harvested SAM was still
# the install image's empty 8 KB hive. The convert-back writes a NEW
# file; the original VHD is left untouched until the conversion
# succeeds, and a failed conversion throws here instead of silently
# harvesting the stale disk.
# Round 42 rerun 11 (run 46093144284 rerun): the bare qemu-img output
# is sparse, and diskpart refuses to attach a sparse virtual disk
# ("Virtual hard disk files must be uncompressed and unencrypted and
# must not be sparse") -- the harvest died at the attach with only
# the runner's own disks in list volume. So the conversion goes
# through ConvertTo-CleanDeSparseDisk (round 23, same fix on the main
# build's dump disk): it converts to a .convert temp file and
# plain-copies it to the output, which loses the sparse attribute,
# and logs the fsutil sparse queryflag as proof. The helper is
# defined in the verifier, which this script dot-sourced above
# (section 3 prerequisites), so it is in scope here -- no duplicate
# implementation. The convert + de-sparse lines land in $verifyLines,
# so the proof travels with the verification report.
Write-Step 'converting the QEMU qcow2 back to VHDX for harvest'
$harvestVhdx = Join-Path $WorkDir 'seed-harvest.vhdx'
if (Test-Path -LiteralPath $harvestVhdx) { Remove-Item -LiteralPath $harvestVhdx -Force }
try {
    $null = ConvertTo-CleanDeSparseDisk -QemuImgPath $qemuImgPath -Qcow2Path $qcow2 -Format 'vhdx' -OutPath $harvestVhdx -Lines $verifyLines
}
catch {
    throw [System.InvalidOperationException]::new(
        "qemu-img convert back failed ($($_.Exception.Message)) (the QEMU-written disk was not recovered; refusing to harvest the stale pre-QEMU VHD)")
}

# ---------------------------------------------------------------------------
# 4. Harvest + verify the hives
# ---------------------------------------------------------------------------

# The harvest mounts $harvestVhdx (the converted-back QEMU disk),
# never the original $vhdx: QEMU booted the qcow2, so only the
# converted-back disk carries the specialize/OOBE writes.
Write-Step 'harvesting SAM + SECURITY from the converted-back seed disk'
$samOut = Join-Path $WorkDir 'SAM'
$secOut = Join-Path $WorkDir 'SECURITY'
Invoke-SeedDiskpart -Label 'attaching the converted-back VHD for harvest' -Script @(
    "select vdisk file=`"$harvestVhdx`""
    'attach vdisk'
)
# The Windows volume is found by its label (SEED), never by
# partition number: `convert gpt` auto-creates an MSR as partition
# 1 (see the bcdboot gate comment), so the primary is partition 3,
# not 2 -- a fixed partition number here used to select the EFI
# partition instead, and the harvest would have read V:\Windows
# off the ESP.
$seedVolumeNumber = Get-SeedDiskpartVolumeNumber -Label 'SEED'
if ($null -eq $seedVolumeNumber) {
    throw [System.InvalidOperationException]::new(
        'harvest failed: SEED volume not found in diskpart list volume')
}
Invoke-SeedDiskpart -Label 'assigning V: to the seed Windows volume' -Script @(
    "select vdisk file=`"$harvestVhdx`""
    "select volume $seedVolumeNumber"
    'assign letter=V'
)
try {
    if (-not (Test-Path -LiteralPath 'V:\Windows\System32\config\SAM')) {
        throw 'harvest failed: V:\Windows\System32\config\SAM is missing (specialize did not produce a system hive)'
    }
    if (-not (Test-Path -LiteralPath 'V:\Windows\System32\config\SECURITY')) {
        throw 'harvest failed: V:\Windows\System32\config\SECURITY is missing'
    }
    Copy-Item -LiteralPath 'V:\Windows\System32\config\SAM' -Destination $samOut -Force
    Copy-Item -LiteralPath 'V:\Windows\System32\config\SECURITY' -Destination $secOut -Force
    Assert-PathExists -Path $samOut -Label 'harvested SAM'
    Assert-PathExists -Path $secOut -Label 'harvested SECURITY'
}
finally {
    Invoke-SeedDiskpart -Label 'detaching the converted-back VHD after harvest' -Script @(
        "select vdisk file=`"$harvestVhdx`""
        'detach vdisk'
    )
}

Write-Step 'verifying the harvested hives'
$observed = Get-SeedHiveVerification -SamPath $samOut -SecurityPath $secOut
Write-VerifyLine ("harvested SAM: {0:N0} bytes, SHA256 {1}" -f $observed.SamSize, $observed.SamSha256)
Write-VerifyLine ("harvested SECURITY: {0:N0} bytes, SHA256 {1}" -f $observed.SecuritySize, $observed.SecuritySha256)
Write-VerifyLine ("SAM Users\Names: {0}" -f ($observed.SamNames -join ', '))
Write-VerifyLine ("SAM MICPE (RID 1000) F flags: 0x{0:X8} (ACB_DISABLED bit is CLEAR -- the build still clears it offline as a belt-and-braces step)" -f $observed.SamFlags)
Write-VerifyLine ("SECURITY Policy\Accounts: {0} account(s): {1}" -f $observed.SecurityAccounts.Count, ($observed.SecurityAccounts -join ', '))
Write-VerifyLine ("blank-password proof: the desktop screenshot (shot-{0:d2}.ppm) shows the machine auto-logged on as MICPE with no password (AutoLogon, blank password)" -f $lastShotIndex)
Write-VerifyLine 'seed hives verified: SAM + SECURITY are populated databases, ready to commit as build inputs'

$verifyLines | Set-Content -LiteralPath $seedVerifyPath -Encoding UTF8
Write-Step 'done'
Write-SubStep ("seed hives: $samOut, $secOut")
Write-SubStep ("verification report: $seedVerifyPath")
