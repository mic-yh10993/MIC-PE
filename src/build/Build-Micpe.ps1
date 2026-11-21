#Requires -Version 7.0
<#
.SYNOPSIS
    MICPE build orchestrator.

.DESCRIPTION
    Runs the requested stage's steps in order. Each step is idempotent enough that
    re-running a stage from scratch is cheap once the cached base image exists.

    Layout under -Workspace:
        base\            install.wim, boot.wim extracted from the source ISO
        media\           the ISO tree that oscdimg will package
        mount\           boot.wim mount point
        mount-install\   install.wim mount point (read-only use)
        out\             MICPE.iso
        logs\            step logs
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('m1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7', 'all')]
    [string] $Stage,

    [string] $Build = '26300',

    [string] $Workspace,

    [string] $Output,

    [switch] $Office,

    [switch] $Chrome,

    # Interactive debug image: when $false, probe.cmd (and the three
    # detached watchers that only ever run from probe.cmd) are left out
    # of boot.wim, so startnet.cmd's `if exist probe.cmd` guard skips
    # the control call and the image lands on an interactive cmd prompt
    # instead of probing and shutting down. PECMD.INI's EXEC probe.cmd
    # fails once, silently; that is harmless. Defaults to $true: every
    # normal build still self-checks.
    [bool] $Probe = $true,

    [switch] $SkipDownload,

    [string] $SourceIso
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$libDir = Join-Path $PSScriptRoot 'lib'

foreach ($lib in 'Common', 'Disk', 'Stages', 'Wim', 'Registry', 'Shell', 'Uwp', 'Payload', 'Brand', 'Installer', 'BaseImage', 'Iso') {
    . (Join-Path $libDir "$lib.ps1")
}

# ---------------------------------------------------------------------------
# Workspace
# ---------------------------------------------------------------------------

if (-not $Workspace) {
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 0 }
    $Workspace = Get-BuildWorkspace -Drives $drives
}

$paths = [pscustomobject]@{
    Root         = $Workspace
    Base         = Join-Path $Workspace 'base'
    Media        = Join-Path $Workspace 'media'
    Mount        = Join-Path $Workspace 'mount'
    MountInstall = Join-Path $Workspace 'mount-install'
    Out          = Join-Path $Workspace 'out'
    Logs         = Join-Path $Workspace 'logs'
    Share        = Join-Path $Workspace 'share'
}

foreach ($key in 'Root', 'Base', 'Media', 'Out', 'Logs', 'Share') {
    $path = $paths.$key
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

$isoPath = if ($Output) { $Output } else { Join-Path $paths.Out 'MICPE.iso' }

$steps = Get-StageSteps -Stage $Stage
Write-Step "MICPE stage $Stage"
Write-SubStep ("workspace: {0}" -f $paths.Root)
Write-SubStep ("steps: {0}" -f ($steps -join ' -> '))

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

function Invoke-BaseStep {
    $baseDir = $paths.Base
    $installWim = Join-Path $baseDir 'install.wim'
    $bootWim = Join-Path $baseDir 'boot.wim'

    if ($SkipDownload -and (Test-Path -LiteralPath $installWim) -and (Test-Path -LiteralPath $bootWim)) {
        Write-SubStep 'base images already present, skipping download'
        return
    }

    if ($SourceIso) {
        Assert-PathExists -Path $SourceIso -Label 'Source ISO'
        Write-Step 'extracting base images from the supplied ISO'
        $null = Get-BaseWims -IsoPath $SourceIso -OutDir $baseDir
        return
    }

    Write-Step "resolving Windows 11 build $Build from UUP dump"
    $uup = Get-UupBuild -Build $Build -Arch 'amd64' -Channel 'stable'

    Write-Step 'downloading UUP conversion package'
    $packageDir = New-UupDownloadPackage -Uuid $uup.Uuid -OutDir $baseDir -Lang 'zh-cn' -Edition 'professional'

    $iniPath = Join-Path $packageDir 'ConvertConfig.ini'
    # SkipApps MUST stay 0: the UWP apps we copy into the PE (Photos,
    # Media Player, Calculator) live inside install.wim, and skipping them
    # would leave nothing to extract.
    # ResetBase stays 0 because component-baseline resets have broken UWP
    # provisioning in the field. Neither flag saves ISO size: the ISO size
    # is governed by the media, not the base images, and the iso step drops
    # the media's install.wim anyway (user decision 2026-11-17 15:09).
    $config = Set-ConvertConfig -IniPath $iniPath -Overrides @{
        AddUpdates = '0'
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
        # Fetch it ourselves: the bundled get_aria2.ps1 relies on Get-FileHash and
        # fails when the runner's powershell resolves to a shell without it.
        Invoke-WebRequest -Uri 'https://uupdump.net/misc/aria2c.exe' -OutFile $aria2 -TimeoutSec 300
        $actual = (Get-FileHash -LiteralPath $aria2 -Algorithm SHA256).Hash.ToLower()
        Assert-True -Condition ($actual -eq $ariaExpectHash) -Message (
            "aria2c.exe hash mismatch: expected $ariaExpectHash, got $actual")
        Write-SubStep 'aria2c.exe downloaded and verified'
    }
    else {
        Write-SubStep 'aria2c.exe already verified'
    }

    # The bundled files\get_aria2.ps1 calls Get-FileHash, which is not
    # available in the PowerShell session the converter's .cmd spawns
    # (observed: CommandNotFoundException -> "aria2c.exe appears to be
    # tampered with" -> uup_download_windows.cmd exit 1). Replace it with
    # our .NET-only verifier; aria2c.exe itself was already verified above.
    $null = Repair-UupAria2Script -PackageDir $packageDir

    Write-Step 'converting UUP files into an ISO (this takes 40-90 minutes)'
    # The converter fetches files from UUP dump itself (aria2), so it can hit
    # the same transient 504 as the API calls: run 43985086793 died on exactly
    # that, after every UUP file was already downloaded. Retry it the same way;
    # aria2 resumes from its control files, so a re-run is cheap.
    $null = Invoke-NetworkWithRetry -Action {
        Push-Location $packageDir
        try {
            $downloader = Join-Path $packageDir 'uup_download_windows.cmd'
            # The downloader ends with `pause`, which blocks an unattended run.
            # Feed it newlines on stdin so it drains and exits.
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
    $null = Get-BaseWims -IsoPath $producedIso.FullName -OutDir $baseDir

    # The media tree comes from the same ISO: it supplies the boot sectors,
    # the EFI boot image, and the folder layout oscdimg packages. The full
    # install.wim stays in the media tree until the iso step drops it
    # (Remove-InstallWimFromMedia, user decision 2026-11-17 15:09).
    Write-Step 'laying out the media tree'
    if (Test-Path -LiteralPath $paths.Media) {
        Remove-Item -LiteralPath $paths.Media -Recurse -Force
    }
    & 7z x $producedIso.FullName "-o$($paths.Media)" -y | Out-Host
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message 'failed to extract the source ISO into the media tree'
}

function Invoke-ReseedStep {
    Write-Step 'replacing the media boot.wim with the working copy'
    $mediaBoot = Join-Path $paths.Media 'sources/boot.wim'
    $baseBoot = Join-Path $paths.Base 'boot.wim'
    Assert-PathExists -Path $baseBoot -Label 'boot.wim'

    if (-not (Test-Path -LiteralPath $mediaBoot)) {
        Write-Warn "media did not contain sources/boot.wim, placing the working copy"
    }

    Copy-Item -LiteralPath $baseBoot -Destination $mediaBoot -Force

    # Inject the MICPE boot files so the image can self-check: the repo's
    # startnet.cmd (which calls probe.cmd when present), probe.cmd itself,
    # probe-watchdog.cmd, the detached watcher that fails a stalled
    # probe early (run 44285721257), probe-sync.cmd, the detached
    # watcher that echoes the probe's local mirror to the serial log so
    # the host can tell a wedged share from a frozen guest
    # (run 44386689307), and probe-mirror.cmd, the detached watcher
    # that copies the local mirror to the second vvfat volume now that
    # the serial channel is dead (run 44428428849).
    # Mounted with DISM and committed; a failure here discards the mount so
    # a half-injected image never ships.
    Write-Step 'injecting MICPE boot files into boot.wim'
    $startnet = Join-Path $repoRoot 'src\shell\startnet.cmd'
    $probeFile = Join-Path $repoRoot 'src\ci\probe.cmd'
    $watchdog = Join-Path $repoRoot 'src\ci\probe-watchdog.cmd'
    $sync = Join-Path $repoRoot 'src\ci\probe-sync.cmd'
    $mirror = Join-Path $repoRoot 'src\ci\probe-mirror.cmd'
    Assert-PathExists -Path $startnet -Label 'startnet.cmd'
    Assert-PathExists -Path $probeFile -Label 'probe.cmd'
    Assert-PathExists -Path $watchdog -Label 'probe-watchdog.cmd'
    Assert-PathExists -Path $sync -Label 'probe-sync.cmd'
    Assert-PathExists -Path $mirror -Label 'probe-mirror.cmd'
    Mount-WimImage -WimPath $mediaBoot -Index 1 -MountDir $paths.Mount
    try {
        $system32 = Join-Path $paths.Mount 'Windows\System32'
        Copy-Item -LiteralPath $startnet -Destination (Join-Path $system32 'startnet.cmd') -Force
        if ($Probe) {
            Copy-Item -LiteralPath $probeFile -Destination (Join-Path $system32 'probe.cmd') -Force
            Copy-Item -LiteralPath $watchdog -Destination (Join-Path $system32 'probe-watchdog.cmd') -Force
            Copy-Item -LiteralPath $sync -Destination (Join-Path $system32 'probe-sync.cmd') -Force
            Copy-Item -LiteralPath $mirror -Destination (Join-Path $system32 'probe-mirror.cmd') -Force
        }
        else {
            # probe=false: interactive debug image. probe.cmd stays out
            # of the image, so startnet.cmd skips the control call and
            # ends on an interactive cmd prompt; the three watchers are
            # only ever started from probe.cmd, so they stay out too.
            Write-SubStep 'probe disabled: leaving probe.cmd and its watchers out of the image (interactive debug build)'
        }
    }
    catch {
        Dismount-WimImage -MountDir $paths.Mount
        throw
    }
    Dismount-WimImage -MountDir $paths.Mount -Commit

    Assert-BootWimSize -WimPath $mediaBoot
}

function Invoke-ExplorerStep {
    Write-Step 'installing the Explorer shell'
    $mediaBoot = Join-Path $paths.Media 'sources/boot.wim'
    $installWim = Join-Path $paths.Base 'install.wim'
    Assert-PathExists -Path $mediaBoot -Label 'boot.wim'
    Assert-PathExists -Path $installWim -Label 'install.wim'

    Mount-WimImage -WimPath $mediaBoot -Index 1 -MountDir $paths.Mount
    try {
        Install-ExplorerShell -MountDir $paths.Mount -InstallWim $installWim -RepoRoot $repoRoot
        # 10 before 20 on purpose: 20-explorer.reg overrides the Winlogon
        # Shell pointer that 10-pe-base.reg sets (PECMD is launched from
        # startnet.cmd; Explorer is the desktop shell).
        $regFiles = @('10-pe-base.reg', '20-explorer.reg') |
            ForEach-Object { Join-Path $repoRoot "src/registry/$_" }
        Invoke-RegistryScript -MountDir $paths.Mount -RegFiles $regFiles
        Set-BootShell -MountDir $paths.Mount -RepoRoot $repoRoot
        Assert-ExplorerPresent -MountDir $paths.Mount
    }
    catch {
        Dismount-WimImage -MountDir $paths.Mount
        throw
    }
    Dismount-WimImage -MountDir $paths.Mount -Commit

    Assert-BootWimSize -WimPath $mediaBoot
}

function Invoke-RuntimesStep {
    Write-Step 'installing the WOW64 runtimes'
    $mediaBoot = Join-Path $paths.Media 'sources/boot.wim'
    $installWim = Join-Path $paths.Base 'install.wim'
    Assert-PathExists -Path $mediaBoot -Label 'boot.wim'
    Assert-PathExists -Path $installWim -Label 'install.wim'

    Mount-WimImage -WimPath $mediaBoot -Index 1 -MountDir $paths.Mount
    try {
        Install-Runtimes -MountDir $paths.Mount -InstallWim $installWim -RepoRoot $repoRoot
    }
    catch {
        Dismount-WimImage -MountDir $paths.Mount
        throw
    }
    Dismount-WimImage -MountDir $paths.Mount -Commit

    Assert-BootWimSize -WimPath $mediaBoot
}

function Invoke-ComponentsStep {
    Write-Step 'installing DWM, components and the input method'
    $mediaBoot = Join-Path $paths.Media 'sources/boot.wim'
    $installWim = Join-Path $paths.Base 'install.wim'
    Assert-PathExists -Path $mediaBoot -Label 'boot.wim'
    Assert-PathExists -Path $installWim -Label 'install.wim'

    Mount-WimImage -WimPath $mediaBoot -Index 1 -MountDir $paths.Mount
    try {
        Install-Components -MountDir $paths.Mount -InstallWim $installWim -RepoRoot $repoRoot
        Install-Ime -MountDir $paths.Mount -InstallWim $installWim -RepoRoot $repoRoot
        $regFiles = @('30-components.reg') |
            ForEach-Object { Join-Path $repoRoot "src/registry/$_" }
        Invoke-RegistryScript -MountDir $paths.Mount -RegFiles $regFiles
        Assert-ImeRegistered -MountDir $paths.Mount
    }
    catch {
        Dismount-WimImage -MountDir $paths.Mount
        throw
    }
    Dismount-WimImage -MountDir $paths.Mount -Commit

    Assert-BootWimSize -WimPath $mediaBoot
}

function Invoke-UwpStep {
    Write-Step 'installing the UWP stack and provisioned apps'
    $mediaBoot = Join-Path $paths.Media 'sources/boot.wim'
    $installWim = Join-Path $paths.Base 'install.wim'
    Assert-PathExists -Path $mediaBoot -Label 'boot.wim'
    Assert-PathExists -Path $installWim -Label 'install.wim'

    Mount-WimImage -WimPath $mediaBoot -Index 1 -MountDir $paths.Mount
    try {
        Install-AppxFramework -MountDir $paths.Mount -InstallWim $installWim -RepoRoot $repoRoot
        Install-UwpApps -MountDir $paths.Mount -InstallWim $installWim -RepoRoot $repoRoot `
            -PackageNames (Get-UwpDefaults)
        Install-FrameHost -MountDir $paths.Mount -InstallWim $installWim -RepoRoot $repoRoot
        $regFiles = @('40-uwp.reg', '60-werdumps.reg', '70-feature-42537950.reg', '80-etc-42537950.reg') |
            ForEach-Object { Join-Path $repoRoot "src/registry/$_" }
        # 40-uwp.reg goes in as SYSTEM: its Appx sideload-policy key gives
        # Administrators only KEY_READ (CI run 44040699722). User decision
        # 2026-11-17 23:43: every registry import happens at CI build time.
        # 60-werdumps.reg rides the SYSTEM import too (run 51): it makes
        # WerFault write explorer's minidump to X:\CrashDumps when it
        # crashes, so the probe can copy the dump to the share and locate
        # the run 48 BEX64 offset 0x1181ea's call stack. Run 50: its key
        # path was HKLM\SOFTWARE, which a plain reg.exe import writes
        # into the RUNNER's live hive — the image never got it (dump_*
        # all 0 in run 49). It now addresses PE-SOFT (the mounted
        # SOFTWARE hive) — and run 50 proved the plain admin path does
        # not land the key even with the right address
        # (wer_localdumps_folder=missing while both SYSTEM imports
        # landed): the "admin-writable" assumption was never verified
        # against the key's DACL, so SYSTEM is used rather than
        # risking another silent miss.
        # 70-feature-42537950.reg rides the privileged write, not the
        # SYSTEM import: run 51 proved even SYSTEM cannot write the
        # FeatureManagement group keys (Overrides\0, \15, \9 give SYSTEM
        # only KEY_READ, 0x00020019 — no SET_VALUE, no CREATE_SUB_KEY;
        # eval card §37.4). The privileged writer enables
        # SeBackup/SeRestorePrivilege and opens the keys with
        # REG_OPTION_BACKUP_RESTORE, which skips the DACL without
        # changing it; the write still happens at CI build time while
        # the hive is mounted. Run 51: the override is written grouped
        # (Overrides\0, \15 and \9) — the flat entry run 50 wrote was
        # ignored by the loader (§36.5.1).
        # 80-etc-42537950.reg rides the privileged write too (run 58):
        # it writes feature 42537950 = 1 (Disabled) into the active
        # EnterpriseTempControls config 2208259724, the temp layer
        # ntdll reads directly. That key also gives SYSTEM only
        # KEY_READ, so the writer's DACL save/write/restore flow runs
        # for it (save the stock DACL, transient SYSTEM-only DACL,
        # write, restore and verify by SDDL comparison); the shipped image
        # keeps the stock DACL. The 70-feature values and groups are
        # untouched.
        Invoke-RegistryScript -MountDir $paths.Mount -RegFiles $regFiles -SystemRegFiles @('40-uwp.reg', '60-werdumps.reg') -PrivilegedRegFiles @('70-feature-42537950.reg', '80-etc-42537950.reg')
        Assert-AppxPolicy -MountDir $paths.Mount
        Assert-WerLocalDumps -MountDir $paths.Mount
        Register-ProvisionedAppx -MountDir $paths.Mount -PackageNames (Get-UwpDefaults)
        Assert-UwpReady -MountDir $paths.Mount
    }
    catch {
        Dismount-WimImage -MountDir $paths.Mount
        throw
    }
    Dismount-WimImage -MountDir $paths.Mount -Commit

    Assert-BootWimSize -WimPath $mediaBoot
}

function Invoke-PayloadStep {
    Write-Step 'installing the payload packages'
    $mediaBoot = Join-Path $paths.Media 'sources/boot.wim'
    Assert-PathExists -Path $mediaBoot -Label 'boot.wim'

    $staging = Join-Path $paths.Logs 'payload'
    # One source per package: the app/ tree in this repo. No Release
    # downloads (user decision 2026-11-17 15:07). The chrome/office
    # archives are staged into the payload dir next to the expanded
    # payload, where Install-Payload expects them.
    $payloadFile = Get-AppPackageArchive -Name 'payload' -RepoRoot $repoRoot -StagingDir $staging
    $payloadDir = Join-Path $staging 'payload'
    Expand-Payload -Archive $payloadFile -Destination $payloadDir
    if ($Chrome) {
        $null = Get-AppPackageArchive -Name 'chrome' -RepoRoot $repoRoot -StagingDir $payloadDir
    }
    if ($Office) {
        $null = Get-AppPackageArchive -Name 'office' -RepoRoot $repoRoot -StagingDir $payloadDir
    }

    Mount-WimImage -WimPath $mediaBoot -Index 1 -MountDir $paths.Mount
    try {
        Install-Payload -MountDir $paths.Mount -PayloadDir $payloadDir `
            -Chrome:$Chrome -Office:$Office -RepoRoot $repoRoot
        Assert-PayloadInstalled -MountDir $paths.Mount -Chrome:$Chrome -Office:$Office
    }
    catch {
        Dismount-WimImage -MountDir $paths.Mount
        throw
    }
    Dismount-WimImage -MountDir $paths.Mount -Commit

    Assert-BootWimSize -WimPath $mediaBoot
}

function Invoke-BrandStep {
    Write-Step 'applying OEM branding'
    $mediaBoot = Join-Path $paths.Media 'sources/boot.wim'
    Assert-PathExists -Path $mediaBoot -Label 'boot.wim'

    Mount-WimImage -WimPath $mediaBoot -Index 1 -MountDir $paths.Mount
    try {
        Set-Brand -MountDir $paths.Mount -RepoRoot $repoRoot
        Assert-BrandApplied -MountDir $paths.Mount
    }
    catch {
        Dismount-WimImage -MountDir $paths.Mount
        throw
    }
    Dismount-WimImage -MountDir $paths.Mount -Commit

    Assert-BootWimSize -WimPath $mediaBoot
}

function Invoke-InstallerStep {
    Write-Step 'installing the MICPE installer'
    $mediaBoot = Join-Path $paths.Media 'sources/boot.wim'
    Assert-PathExists -Path $mediaBoot -Label 'boot.wim'
    Mount-WimImage -WimPath $mediaBoot -Index 1 -MountDir $paths.Mount
    try {
        Install-Installer -MountDir $paths.Mount -RepoRoot $repoRoot
        Assert-InstallerInstalled -MountDir $paths.Mount
    }
    catch {
        Dismount-WimImage -MountDir $paths.Mount
        throw
    }
    Dismount-WimImage -MountDir $paths.Mount -Commit
    Assert-BootWimSize -WimPath $mediaBoot
}

function Invoke-IsoStep {
    $bootWim = Join-Path $paths.Media 'sources/boot.wim'
    Assert-PathExists -Path $bootWim -Label 'boot.wim'

    # run 44062469206 diagnosis: the UUP media's boot.wim boots image 2
    # (Windows Setup) by default, while every build step customises image 1
    # (Windows PE) and the probe lives only there. Point the boot image at
    # 1 here, after the last mount/commit and before packaging, or winload
    # starts Setup and the probe can never run.
    Write-Step 'setting boot.wim boot image to 1 (Windows PE)'
    Set-WimBootIndex -WimPath $bootWim -Index 1
    $bootIndex = Get-WimBootIndex -WimPath $bootWim
    Assert-True -Condition ($bootIndex -eq 1) -Message "boot.wim boot index is $bootIndex, expected 1 (Windows PE)"

    $wimBytes = (Get-Item -LiteralPath $bootWim).Length

    # M7 volume governance (plan Task 18 Step 3): decide the degrade before
    # packaging. The per-step Assert-BootWimSize is the first line of
    # defence; this names the next component to drop if the image ever
    # grows past the 3 GB cap, and fails the build with the instruction
    # instead of shipping an oversized image. No automatic re-run: the
    # operator turns the switch off and runs again.
    $enabled = [System.Collections.Generic.List[string]]::new()
    if ($Office) { $enabled.Add('office') }
    if ($Chrome) { $enabled.Add('chrome') }
    if ($steps -contains 'uwp') { $enabled.Add('photos'); $enabled.Add('mediaplayer') }
    $decision = Invoke-Degrade -CurrentWimBytes $wimBytes -Enabled $enabled.ToArray()
    if ($decision.TooBig) {
        $drop = $decision.NextToDrop
        $size = Format-ByteSize -Bytes $wimBytes
        if ($drop -in 'office', 'chrome') {
            throw [System.InvalidOperationException]::new(
                "boot.wim 已超 3 GB 上限（当前 $size）：请关掉 -$drop 后重新构建（按已批降级顺序，下一个应砍：$drop）。")
        }
        if ($drop) {
            throw [System.InvalidOperationException]::new(
                "boot.wim 已超 3 GB 上限（当前 $size），且 Office/Chrome 均已关闭：下一个应砍的是 $drop，它没有构建开关，需从代码里去掉后重新构建。")
        }
        throw [System.InvalidOperationException]::new(
            "boot.wim 已超 3 GB 上限（当前 $size），且已批降级顺序里已无可砍项：映像需要人工瘦身，不是开关能解决的。")
    }
    $next = if ($enabled.Count -gt 0) { $enabled[0] } else { '无' }
    Write-SubStep ("boot.wim {0}，未超 3 GB 上限（若以后超限，按顺序先砍：{1}）" -f (Format-ByteSize -Bytes $wimBytes), $next)

    Write-Step 'packaging MICPE.iso'
    # Minimal media (user decision 2026-11-17 15:09): the ISO carries only
    # boot.wim. The UUP media tree still has the full install.wim; drop it
    # here, after the last step that needs it. The installer finds the
    # user's own install.wim on another volume (install.mic protocol).
    Remove-InstallWimFromMedia -MediaDir $paths.Media
    New-MicpeIso -MediaDir $paths.Media -OutIso $isoPath -OscdimgPath (Get-OscdimgPath)

    $isoBytes = (Get-Item -LiteralPath $isoPath).Length

    Write-Step 'size report'
    Write-SubStep ("boot.wim = {0}" -f (Format-ByteSize -Bytes $wimBytes))
    Write-SubStep ("MICPE.iso = {0}" -f (Format-ByteSize -Bytes $isoBytes))

    return [pscustomobject]@{
        IsoPath   = $isoPath
        IsoBytes  = $isoBytes
        BootWim   = $bootWim
        WimBytes  = $wimBytes
    }
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

$result = $null
foreach ($step in $steps) {
    switch ($step) {
        'base'      { Invoke-BaseStep }
        'reseed'    { Invoke-ReseedStep }
        'explorer'  { Invoke-ExplorerStep }
        'runtimes'  { Invoke-RuntimesStep }
        'components' { Invoke-ComponentsStep }
        'uwp'       { Invoke-UwpStep }
        'payload'   { Invoke-PayloadStep }
        'brand'     { Invoke-BrandStep }
        'installer' { Invoke-InstallerStep }
        'iso'       { $result = Invoke-IsoStep }
        default {
            Write-Warn "step '$step' is not implemented yet (planned for a later stage)"
        }
    }
}

if ($result) {
    Write-Step 'done'
    Write-SubStep ("ISO: {0}" -f $result.IsoPath)
    Write-SubStep ("SHA256: {0}" -f (Get-FileHash -LiteralPath $result.IsoPath -Algorithm SHA256).Hash)

    if ($env:GITHUB_STEP_SUMMARY) {
        @(
            "## MICPE $Stage build"
            ''
            '| Item | Value |'
            '| --- | --- |'
            "| Stage | ``$Stage`` |"
            "| Build | ``$Build`` |"
            "| boot.wim | $(Format-ByteSize -Bytes $result.WimBytes) |"
            "| ISO | $(Format-ByteSize -Bytes $result.IsoBytes) |"
            "| SHA256 | ``$((Get-FileHash -LiteralPath $result.IsoPath -Algorithm SHA256).Hash)`` |"
        ) | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
    }

    # Export the artifact paths for later steps. This must not live inside
    # the summary block above: on a runner without GITHUB_STEP_SUMMARY the
    # four variables would silently never be written, and the verify step
    # would then fail with an empty -Iso. Guarded on GITHUB_ENV itself so
    # local runs (where the variable is unset) keep working.
    if ($env:GITHUB_ENV) {
        "ISO_PATH=$($result.IsoPath)" | Add-Content -LiteralPath $env:GITHUB_ENV
        "BOOT_WIM_PATH=$($result.BootWim)" | Add-Content -LiteralPath $env:GITHUB_ENV
        "WIM_BYTES=$($result.WimBytes)" | Add-Content -LiteralPath $env:GITHUB_ENV
        "ISO_BYTES=$($result.IsoBytes)" | Add-Content -LiteralPath $env:GITHUB_ENV
        # The base install.wim is the install source for the deploy smoke
        # test's data disks (build.yml): the finished ISO no longer carries
        # one (user decision 2026-11-17 15:09), so the workflow cannot
        # extract it from the ISO anymore.
        "INSTALL_WIM_PATH=$(Join-Path $paths.Base 'install.wim')" | Add-Content -LiteralPath $env:GITHUB_ENV
    }
}
else {
    Write-Warn "stage $Stage finished without producing an ISO"
}
