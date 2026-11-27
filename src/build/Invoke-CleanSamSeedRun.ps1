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
         sam-seed-unattend.xml (specialize + OOBE).
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
    # desktop can take 20-40 minutes. 75 minutes is the ceiling; the
    # loop fails fast on a blue screen instead of burning it.
    [int] $SpecializeTimeoutMin = 75,

    # Seconds to let the desktop settle before powering off
    # (lets specialize finish writing the hives).
    [int] $DesktopSettleSec = 120,

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
        '-D', $QemuLogPath
    )
}

function Test-SeedScreenshotIsDesktop {
    # Pure function: is this screenshot an arrived desktop? The desktop
    # is a bright GUI (low black fraction); the firmware screen,
    # the boot spinner and the specialize progress screens are all
    # mostly black. One 'Other' shot is not enough -- specialize shows
    # GUI progress screens too -- so the caller requires three in a
    # row (90 s apart) before declaring the desktop reached.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Classification,

        [double] $BlackFraction = 1.0
    )
    return ($Classification -eq 'Other') -and ($BlackFraction -lt 0.4)
}

function Invoke-SeedDiskpart {
    # Run a diskpart script, fail loudly on a non-zero exit (same
    # pattern as the build's data-disk preparation).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Script,

        [Parameter(Mandatory = $true)]
        [string] $Label
    )
    $Script | diskpart | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new(
            "diskpart failed while $Label (exit code $LASTEXITCODE)")
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
) -join "`n"

try {
    Write-Step 'applying install.wim to the seed VHD (DISM)'
    & dism.exe /Apply-Image /ImageFile:$installWim /Index:$imageIndex /ApplyDir:V:\ | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new(
            "dism /Apply-Image failed with exit code $LASTEXITCODE")
    }

    Write-Step 'writing the EFI bootloader (bcdboot)'
    & bcdboot.exe V:\Windows /s S: /f UEFI | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new(
            "bcdboot failed with exit code $LASTEXITCODE")
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
    ) -join "`n"
}

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
. (Join-Path $repoRoot 'src\ci\Invoke-CleanQemuVerify.ps1') -IsoPath $installWim -OvmfPath $OvmfPath -WorkDir $WorkDir -ParseOnly

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
Write-Host "starting QEMU: $QemuPath $argString"
$qemu = Start-Process -FilePath $QemuPath -ArgumentList $argString -PassThru -NoNewWindow -RedirectStandardOutput $qemuStdoutLog -RedirectStandardError $qemuStderrLog
if ($null -eq $qemu) { throw 'failed to start QEMU' }

$desktopReached = $false
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

    # Poll screenshots until the desktop is stable: three
    # consecutive desktop-like shots, 90 s apart. Specialize
    # reboots once (specialize -> OOBE -> AutoLogon desktop), so
    # TianoCore may reappear mid-run -- that only resets the streak,
    # it never fails the run. A blue screen at any point fails fast:
    # the specialize itself is broken, and waiting would waste the job.
    $streak = 0
    $shotIndex = 0
    $deadline = (Get-Date).AddMinutes($SpecializeTimeoutMin)
    while ((Get-Date) -lt $deadline) {
        if ($qemu.HasExited) {
            throw "QEMU exited before the desktop appeared (exit $($qemu.ExitCode)); see $qemuLog"
        }
        $shotIndex++
        $took = Save-CleanScreenshot -Port $MonitorPort -ScreenshotDir $shotDir -ShotIndex $shotIndex -Label ("specialize poll {0}" -f $shotIndex)
        if (-not $took) {
            Write-Host ("!!! specialize poll {0}: screenshot failed, retrying" -f $shotIndex)
            $streak = 0
            Start-Sleep -Seconds 60
            continue
        }
        $ppm = Join-Path $shotDir ("shot-{0:d2}.ppm" -f $shotIndex)
        $class = Test-CleanScreenshot -Path $ppm
        Write-Host ("specialize poll {0}: {1} (black {2:P0}, blue {3:P0})" -f $shotIndex, $class.Classification, $class.BlackFraction, $class.BlueFraction)
        if ($class.Classification -eq 'BlueScreen' -or $class.Classification -eq 'Recovery') {
            throw "specialize failed: guest shows $($class.Classification) at shot $shotIndex (see $ppm)"
        }
        if (Test-SeedScreenshotIsDesktop -Classification $class.Classification -BlackFraction $class.BlackFraction) {
            $streak++
            Write-Host ("desktop-like shot {0}/3" -f $streak)
            if ($streak -ge 3) {
                $desktopReached = $true
                $lastShotIndex = $shotIndex
                break
            }
        }
        else {
            $streak = 0
        }
        Start-Sleep -Seconds 90
    }
    if (-not $desktopReached) {
        throw "OOBE desktop not reached within $SpecializeTimeoutMin minutes (last shot $shotIndex); see $shotDir"
    }
    Write-Host ("desktop reached (shot {0}); letting it settle {1} s" -f $lastShotIndex, $DesktopSettleSec)
    Start-Sleep -Seconds $DesktopSettleSec
    $lastShotIndex++
    $null = Save-CleanScreenshot -Port $MonitorPort -ScreenshotDir $shotDir -ShotIndex $lastShotIndex -Label 'desktop final'
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

if (-not $desktopReached) {
    throw 'OOBE desktop was never reached; no hives to harvest'
}

# ---------------------------------------------------------------------------
# 4. Harvest + verify the hives
# ---------------------------------------------------------------------------

Write-Step 'harvesting SAM + SECURITY from the seed VHD'
$samOut = Join-Path $WorkDir 'SAM'
$secOut = Join-Path $WorkDir 'SECURITY'
Invoke-SeedDiskpart -Label 'attaching the seed VHD for harvest' -Script @(
    "select vdisk file=`"$vhdx`""
    'attach vdisk'
    'select partition 2'
    'assign letter=V'
) -join "`n"
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
    Invoke-SeedDiskpart -Label 'detaching the seed VHD after harvest' -Script @(
        "select vdisk file=`"$vhdx`""
        'detach vdisk'
    ) -join "`n"
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
