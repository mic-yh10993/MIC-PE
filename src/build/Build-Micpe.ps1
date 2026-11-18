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

    [string] $Build = '26200',

    [string] $Workspace,

    [string] $Output,

    [switch] $Office,

    [switch] $Chrome,

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
    # provisioning in the field. The media tree ships the full source
    # install.wim (~4.1 GiB) as the install source, so neither flag saves
    # ISO size anyway -- the ISO size is governed by the media, not the
    # base images (M7: the old comment here claimed install.wim was never
    # packaged into our ISO, which the 4.48 GB M1 ISO disproves).
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
    # the EFI boot image, and the folder layout oscdimg packages.
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
    # startnet.cmd (which calls probe.cmd when present) and probe.cmd itself.
    # Mounted with DISM and committed; a failure here discards the mount so
    # a half-injected image never ships.
    Write-Step 'injecting MICPE boot files into boot.wim'
    $startnet = Join-Path $repoRoot 'src\shell\startnet.cmd'
    $probe = Join-Path $repoRoot 'src\ci\probe.cmd'
    Assert-PathExists -Path $startnet -Label 'startnet.cmd'
    Assert-PathExists -Path $probe -Label 'probe.cmd'
    Mount-WimImage -WimPath $mediaBoot -Index 1 -MountDir $paths.Mount
    try {
        $system32 = Join-Path $paths.Mount 'Windows\System32'
        Copy-Item -LiteralPath $startnet -Destination (Join-Path $system32 'startnet.cmd') -Force
        Copy-Item -LiteralPath $probe -Destination (Join-Path $system32 'probe.cmd') -Force
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
        $regFiles = @('40-uwp.reg') |
            ForEach-Object { Join-Path $repoRoot "src/registry/$_" }
        # 40-uwp.reg goes in as SYSTEM: its Appx sideload-policy key gives
        # Administrators only KEY_READ (CI run 44040699722). User decision
        # 2026-11-17 23:43: every registry import happens at CI build time.
        Invoke-RegistryScript -MountDir $paths.Mount -RegFiles $regFiles -SystemRegFiles @('40-uwp.reg')
        Assert-AppxPolicy -MountDir $paths.Mount
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
    $payloadFile = Get-PayloadReleaseAsset -Name 'payload' -StagingDir $staging
    $payloadDir = Join-Path $staging 'payload'
    Expand-Payload -Archive $payloadFile -Destination $payloadDir
    if ($Chrome) {
        $null = Get-PayloadReleaseAsset -Name 'chrome' -StagingDir $payloadDir
    }
    if ($Office) {
        $null = Get-PayloadReleaseAsset -Name 'office' -StagingDir $payloadDir
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
    }
}
else {
    Write-Warn "stage $Stage finished without producing an ISO"
}
