#Requires -Version 7.0
<#
.SYNOPSIS
    MIC-PE clean rebuild orchestrator (Windows 11 22H2, build 22621.1105
    Enterprise, rebuilt from the official image against the Ramos reference PE).

.DESCRIPTION
    The clean rebuild does NOT patch the UUP boot.wim the way the m* stages
    do. It assembles a fresh PE from the OFFICIAL install.wim:

      1. base     resolve the UUP build, download the conversion package,
                  produce install.wim + boot.wim and the ISO media tree
                  (same lib calls as Build-Micpe.ps1's base step, inlined
                  here on purpose: the existing tests assert on
                  Build-Micpe.ps1's aria2 pre-seed and converter retry
                  text, so the base step is NOT refactored out of that
                  file; this script carries its own copy).
      2. extract  copy ONLY the files in the supplied file list out of the
                  official install.wim (Enterprise index) into a staging
                  tree (--nullglob: a listed file the official image does
                  not carry is skipped, not fatal).
      3. shell    read shell.zip (StartAllBack + Start11, user-supplied,
                  in-repo src/build/data/shell.zip, SHA256-pinned) and lay it
                  out under Windows\System32\MICPE\ (StartAllBack and
                  Start11 in their own subfolders; Start11\Links\ -- the
                  pinned-item shortcuts -- is left out), plus the
                  rewritten System32\icsxml\StartAllBack.xml.
      4. registry mount the staging hives and import the clean .reg patches
                  (10-clean-boot, 20-clean-start11, 30-clean-author,
                  40-clean-startallback) at CI build time -- never inside
                  the running PE -- then enable the built-in Administrator
                  (RID 500) in the staging SAM and write unattend.xml.
      5. capture  capture the staging tree into a fresh boot.wim
                  (wimlib-imagex capture, LZX, --boot, integrity table).
      6. iso      place the new boot.wim in the media tree, drop
                  sources\install.wim (the finished ISO carries only
                  boot.wim, user decision 2026-11-17 15:09), and package
                  MICPE-clean.iso with oscdimg. Sizes are reported as
                  measured; the 3 GB boot.wim cap still applies.

    FILE LIST IS A PLACEHOLDER until the 15:15 official-vs-reference diff
    lands: src/build/data/clean-22621.1105-enterprise-files.txt is the
    reference file list minus the deleted third-party apps (Tencent,
    360Chrome, Thunder, Office2010, PhotoshopCS3, 7-Zip, PENetwork,
    StartAllBack/Start11 program folders, and the third-party Start menu
    / desktop shortcuts). The 15:15 diff replaces it with the verified
    list (official-original vs modified vs reference-added, per file).
    Do NOT dispatch a clean build on the placeholder list as final.

    Layout under -Workspace:
        base\            install.wim, boot.wim extracted from the source ISO
        media\           the ISO tree that oscdimg will package
        staging\         the clean PE file tree (captured into boot.wim)
        out\             MICPE-clean.iso + captured boot.wim
        logs\            step logs
#>

[CmdletBinding()]
param(
    # UUP build to resolve. The reference PE is 22621.1105.
    [string] $Build = '22621.1105',

    # UUP edition for the download package. The reference PE is Enterprise.
    [string] $Edition = 'enterprise',

    [string] $Workspace,

    [string] $Output,

    [switch] $SkipDownload,

    [string] $SourceIso,

    # File list: one WIM-internal path per line (leading backslash optional,
    # '#' / ';' comment lines and blanks are skipped by Read-Whitelist).
    # Defaults to the placeholder clean list; replaced after the 15:15 diff.
    [string] $FileList,

    # Pinned SHA256 of shell.zip (in-repo src/build/data/shell.zip).
    [string] $ShellSha256 = '8f94801470e20b94129d0b7e294d1c6b413b060dcf6b70f8e9409cee3a94b0bd',

    # shell.zip to use instead of the in-repo copy (local runs / tests).
    # Default: src/build/data/shell.zip (the repo is private, so the file
    # lives in git directly instead of a Release asset).
    [string] $ShellZipPath,

    # Directory holding the clean .reg patches (default src/build/reg).
    [string] $RegDir,

    [string] $WimlibPath = 'wimlib-imagex'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$libDir = Join-Path $PSScriptRoot 'lib'

foreach ($lib in 'Common', 'Disk', 'Wim', 'Registry', 'AdminAccount', 'BaseImage', 'Iso') {
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
    Root    = $Workspace
    Base    = Join-Path $Workspace 'base'
    Media   = Join-Path $Workspace 'media'
    Staging = Join-Path $Workspace 'staging'
    Out     = Join-Path $Workspace 'out'
    Logs    = Join-Path $Workspace 'logs'
}

foreach ($key in 'Root', 'Base', 'Out', 'Logs') {
    $path = $paths.$key
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

$isoPath = if ($Output) { $Output } else { Join-Path $paths.Out 'MICPE-clean.iso' }
$fileListPath = if ($FileList) { $FileList } else {
    Join-Path $PSScriptRoot 'data\clean-22621.1105-enterprise-files.txt'
}
$regDirPath = if ($RegDir) { $RegDir } else { Join-Path $PSScriptRoot 'reg' }

Write-Step "MICPE clean rebuild $Build ($Edition)"
Write-SubStep ("workspace: {0}" -f $paths.Root)
Write-SubStep ("file list: {0}" -f $fileListPath)
Write-Warn 'file list is a PLACEHOLDER until the 15:15 official-vs-reference diff lands (see the list header)'

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

function Invoke-CleanBaseStep {
    # Resolve the UUP build, download the conversion package, produce
    # install.wim + boot.wim and the ISO media tree. This is the same
    # sequence as Build-Micpe.ps1's Invoke-BaseStep, inlined here on
    # purpose (see the script header: the base step is not refactored out
    # of Build-Micpe.ps1 because the tests assert on its text).
    $baseDir = $paths.Base
    $installWim = Join-Path $baseDir 'install.wim'
    $bootWim = Join-Path $baseDir 'boot.wim'

    if ($SkipDownload -and (Test-Path -LiteralPath $installWim) -and (Test-Path -LiteralPath $bootWim)) {
        Write-SubStep 'base images already present, skipping download'
        return [pscustomobject]@{ InstallWim = $installWim; BootWim = $bootWim }
    }

    if ($SourceIso) {
        Assert-PathExists -Path $SourceIso -Label 'Source ISO'
        Write-Step 'extracting base images from the supplied ISO'
        $null = Get-BaseWims -IsoPath $SourceIso -OutDir $baseDir
        return [pscustomobject]@{ InstallWim = $installWim; BootWim = $bootWim }
    }

    Write-Step "resolving Windows 11 build $Build from UUP dump"
    $uup = Get-UupBuild -Build $Build -Arch 'amd64' -Channel 'stable'

    Write-Step 'downloading UUP conversion package'
    $packageDir = New-UupDownloadPackage -Uuid $uup.Uuid -OutDir $baseDir -Lang 'zh-cn' -Edition $Edition

    $iniPath = Join-Path $packageDir 'ConvertConfig.ini'
    # SkipApps MUST stay 0: the files we copy into the PE live inside
    # install.wim, and skipping them would leave nothing to extract.
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
    # available in the PowerShell session the converter's .cmd spawns.
    # Replace it with our .NET-only verifier; aria2c.exe itself was already
    # verified above.
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

    return [pscustomobject]@{ InstallWim = $installWim; BootWim = $bootWim }
}

function Invoke-CleanExtractStep {
    # Copy ONLY the files in the file list out of the official install.wim
    # (Enterprise index) into the staging tree. --nullglob skips a listed
    # file the official image does not carry; the critical files below are
    # asserted explicitly so a silent skip of something essential fails
    # the build here instead of at first boot.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $InstallWim
    )

    $index = Get-WimImageIndexByEdition -WimPath $InstallWim -Edition $Edition -WimlibPath $WimlibPath
    Write-Step ("official install.wim: edition '{0}' is image index {1}" -f $Edition, $index)

    $patterns = Read-Whitelist -Path $fileListPath
    Write-SubStep ("file list: {0} paths" -f $patterns.Count)

    if (Test-Path -LiteralPath $paths.Staging) {
        Remove-Item -LiteralPath $paths.Staging -Recurse -Force
    }
    Export-WimFiles -WimPath $InstallWim -Index $index -Destination $paths.Staging -Patterns $patterns -WimlibPath $WimlibPath

    # Critical files: without these the image cannot boot, log on, or show
    # a shell. (winload.exe is the boot loader, explorer.exe the shell,
    # the config hives carry the registry the next step patches.)
    foreach ($required in @(
            'Windows\System32\winload.exe',
            'Windows\explorer.exe',
            'Windows\System32\config\SYSTEM',
            'Windows\System32\config\SOFTWARE',
            'Windows\System32\config\DEFAULT',
            'Windows\System32\config\SAM',
            'Windows\System32\config\SECURITY'
        )) {
        Assert-PathExists -Path (Join-Path $paths.Staging $required) -Label "staged $required"
    }

    return [pscustomobject]@{
        Staging    = $paths.Staging
        ImageIndex = $index
        FileCount  = $patterns.Count
    }
}

function Get-CleanShellZip {
    # Resolve shell.zip: the in-repo copy (src/build/data/shell.zip) is
    # the default -- the repo is private, so the file lives in git
    # directly instead of a Release asset. -ShellZipPath overrides it
    # (local runs / tests). The pinned SHA256 is always verified.
    $zipPath = if ($ShellZipPath) { $ShellZipPath } else {
        Join-Path $repoRoot 'src/build/data/shell.zip'
    }
    Assert-PathExists -Path $zipPath -Label 'shell.zip (in-repo)'

    $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLower()
    Assert-True -Condition ($actual -eq $ShellSha256.ToLower()) -Message (
        "shell.zip SHA256 mismatch: expected $ShellSha256, got $actual")
    Write-SubStep 'shell.zip verified against the pinned SHA256'
    return $zipPath
}

function Invoke-CleanShellStep {
    # Lay StartAllBack + Start11 out under Windows\System32\MICPE\.
    # Start11\Links\ (the pinned-item shortcuts) is left out on purpose:
    # the user asked for the Start menu pinned items to be cleaned, and
    # 20-clean-start11.reg resets Start11's pinned-item creation flags so
    # it rebuilds its default set from the clean system's apps.
    $zipPath = Get-CleanShellZip

    $extractDir = Join-Path $paths.Logs 'shell'
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force
    }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

    $micpeDir = Join-Path $paths.Staging 'Windows\System32\MICPE'
    if (-not (Test-Path -LiteralPath $micpeDir)) {
        New-Item -ItemType Directory -Path $micpeDir -Force | Out-Null
    }

    $sabSrc = Join-Path $extractDir 'shell\StartAllBack'
    $s11Src = Join-Path $extractDir 'shell\Start11'
    Assert-PathExists -Path $sabSrc -Label 'shell.zip StartAllBack'
    Assert-PathExists -Path $s11Src -Label 'shell.zip Start11'

    Copy-Item -LiteralPath $sabSrc -Destination (Join-Path $micpeDir 'StartAllBack') -Recurse -Force
    Copy-Item -LiteralPath $s11Src -Destination (Join-Path $micpeDir 'Start11') -Recurse -Force

    # Drop the pinned-item shortcuts Start11 ships (Links\ holds the
    # Start menu pinned .lnk files for the deleted third-party apps).
    $linksDir = Join-Path $micpeDir 'Start11\Links'
    if (Test-Path -LiteralPath $linksDir) {
        Remove-Item -LiteralPath $linksDir -Recurse -Force
        Write-SubStep 'removed Start11\Links (pinned-item shortcuts for the deleted apps)'
    }

    # The rewritten Control Panel tasks file: its commands already point
    # at the MICPE location (src/build/data/StartAllBack.xml). The other
    # icsxml files (cmnicfg, ipcfg, ...) are Microsoft files and come
    # from the official image via the file list.
    $icsxmlDir = Join-Path $paths.Staging 'Windows\System32\icsxml'
    if (-not (Test-Path -LiteralPath $icsxmlDir)) {
        New-Item -ItemType Directory -Path $icsxmlDir -Force | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $repoRoot 'src\build\data\StartAllBack.xml') `
        -Destination (Join-Path $icsxmlDir 'StartAllBack.xml') -Force

    foreach ($required in @(
            'Windows\System32\MICPE\StartAllBack\StartAllBackX64.dll',
            'Windows\System32\MICPE\StartAllBack\StartAllBackLoaderX64.dll',
            'Windows\System32\MICPE\StartAllBack\StartAllBackCfg.exe',
            'Windows\System32\MICPE\Start11\Start11.exe',
            'Windows\System32\MICPE\Start11\Start11Config.exe',
            'Windows\System32\MICPE\Start11\Start11_64.dll',
            'Windows\System32\icsxml\StartAllBack.xml'
        )) {
        Assert-PathExists -Path (Join-Path $paths.Staging $required) -Label "staged $required"
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath $linksDir)) -Message (
        'Start11\Links survived the shell step; the pinned-item shortcuts must not ship')
}

function Invoke-CleanRegistryStep {
    # Mount the staging hives and import the clean .reg patches at CI
    # build time (user decision 2026-11-17 23:43: never inside the PE),
    # then enable Administrator in the staging SAM and write unattend.xml.
    # Invoke-RegistryScript mounts from $MountDir\Windows\System32\config,
    # which is exactly the staging layout, so it works on a plain
    # directory tree -- no DISM mount is needed for this step.
    $regFiles = @('10-clean-boot.reg', '20-clean-start11.reg', '30-clean-author.reg', '40-clean-startallback.reg') |
        ForEach-Object { Join-Path $regDirPath $_ }
    foreach ($regFile in $regFiles) {
        Assert-PathExists -Path $regFile -Label "registry patch $(Split-Path -Leaf $regFile)"
    }

    Write-Step 'importing the clean registry patches into the staging hives'
    Invoke-RegistryScript -MountDir $paths.Staging -RegFiles $regFiles

    Write-Step 'enabling built-in Administrator in the staging SAM'
    $samPath = Join-Path $paths.Staging 'Windows\System32\config\SAM'
    $admin = Set-OfflineAdminState -SamPath $samPath
    if (-not $admin.Found) {
        # The official install.wim SAM carries the Administrator record,
        # so an empty hive here means the extract lost it -- fail loudly
        # instead of shipping an image nobody can log into.
        throw [System.InvalidOperationException]::new(
            'the staging SAM has no Administrator record; the file-list extract lost it')
    }

    # The reference's unattend.xml (windowsPE pass only: ComputerName
    # WINXPE, no network, no firewall). The official install.wim does
    # not ship one at this path, so it is written from the repo copy.
    Copy-Item -LiteralPath (Join-Path $repoRoot 'src\build\data\unattend.xml') `
        -Destination (Join-Path $paths.Staging 'Windows\System32\unattend.xml') -Force
    Assert-PathExists -Path (Join-Path $paths.Staging 'Windows\System32\unattend.xml') -Label 'staged unattend.xml'
}

function Assert-CleanRegistry {
    # Read back the values the clean patches must have landed, through the
    # mounted staging hives (reg.exe query, never the PowerShell provider:
    # the provider holds an open handle and a later reg unload fails).
    # Run 55 lesson: an import that exits 0 can still have missed, so the
    # read-back happens here, at the registry step, not three steps later.
    $configDir = Join-Path $paths.Staging 'Windows\System32\config'
    $loaded = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($hive in (Get-PeHiveMap)) {
            $file = Join-Path $configDir $hive.File
            if (-not (Test-Path -LiteralPath $file)) {
                Write-Warn "hive not present, skipping read-back: $file"
                continue
            }
            Mount-RegistryHive -HiveFile $file -KeyName $hive.Key
            $loaded.Add($hive.Key)
        }

        $setup = Get-RegistryKeyValues -KeyName 'PE-SYS' -SubKey 'Setup'
        Assert-True -Condition ($null -ne $setup) -Message 'read-back: PE-SYS\Setup is missing'
        Assert-True -Condition ($setup['SetupType'] -eq '0x2') -Message "read-back: SetupType is '$($setup['SetupType'])', expected 0x2"
        Assert-True -Condition ($setup['CmdLine'] -eq 'LogonUI') -Message "read-back: CmdLine is '$($setup['CmdLine'])', expected LogonUI"
        Assert-True -Condition ($setup['SystemSetupInProgress'] -eq '0x0') -Message "read-back: SystemSetupInProgress is '$($setup['SystemSetupInProgress'])', expected 0x0"

        $winlogon = Get-RegistryKeyValues -KeyName 'PE-SOFT' -SubKey 'Microsoft\Windows NT\CurrentVersion\Winlogon'
        Assert-True -Condition ($null -ne $winlogon) -Message 'read-back: PE-SOFT Winlogon is missing'
        Assert-True -Condition ($winlogon['Shell'] -eq 'explorer.exe') -Message "read-back: Winlogon Shell is '$($winlogon['Shell'])', expected explorer.exe"
        Assert-True -Condition ($winlogon['AutoRestartShell'] -eq '0x1') -Message "read-back: AutoRestartShell is '$($winlogon['AutoRestartShell'])', expected 0x1"

        $currentVersion = Get-RegistryKeyValues -KeyName 'PE-SOFT' -SubKey 'Microsoft\Windows NT\CurrentVersion'
        Assert-True -Condition ($currentVersion['RegisteredOwner'] -eq 'SYSTEM-Intel-MIC') -Message "read-back: RegisteredOwner is '$($currentVersion['RegisteredOwner'])', expected SYSTEM-Intel-MIC"
        Assert-True -Condition ($currentVersion['SystemRoot'] -eq 'X:\Windows') -Message "read-back: SystemRoot is '$($currentVersion['SystemRoot'])', expected X:\Windows"

        $loader = Get-RegistryKeyValues -KeyName 'PE-SOFT' -SubKey 'Classes\CLSID\{117E3954-5034-453A-A18B-7B79493646E6}\InprocServer32'
        Assert-True -Condition ($null -ne $loader) -Message 'read-back: StartAllBack loader CLSID is missing'
        Assert-True -Condition ($loader['(Default)'] -match 'MICPE\\StartAllBackLoaderX64\.dll') -Message "read-back: loader CLSID points at '$($loader['(Default)'])', expected the MICPE path"

        $startIsBack = Get-RegistryKeyValues -KeyName 'PE-DEF' -SubKey 'Software\StartIsBack'
        Assert-True -Condition ($null -ne $startIsBack) -Message 'read-back: PE-DEF Software\StartIsBack is missing'
        Assert-True -Condition ($startIsBack['Disabled'] -eq '0x0') -Message "read-back: StartIsBack Disabled is '$($startIsBack['Disabled'])', expected 0x0"

        $start8 = Get-RegistryKeyValues -KeyName 'PE-DEF' -SubKey 'Software\Stardock\Start8\Start8.ini\Start8'
        Assert-True -Condition ($null -ne $start8) -Message 'read-back: PE-DEF Start11 Start8.ini\Start8 is missing'
        Assert-True -Condition ($start8['Image'] -match 'MICPE\\Start11\\StartButtons\\default\.png') -Message "read-back: Start11 Image is '$($start8['Image'])', expected the MICPE path"

        Write-SubStep 'registry read-back: boot chain, author, StartAllBack loader, Start11 image all landed'
    }
    finally {
        for ($index = $loaded.Count - 1; $index -ge 0; $index--) {
            try {
                Dismount-RegistryHive -KeyName $loaded[$index]
            }
            catch {
                Write-Warn $_.Exception.Message
            }
        }
    }
}

function Invoke-CleanCaptureStep {
    # Capture the staging tree into a fresh boot.wim. The capture is a
    # single-image WIM; the boot index is re-asserted to 1 afterwards
    # (same belt-and-braces as the m* iso step).
    $bootWim = Join-Path $paths.Out 'boot.wim'
    $null = New-WimCapture -SourceDir $paths.Staging -WimPath $bootWim -Name 'MICPE' -WimlibPath $WimlibPath

    Set-WimBootIndex -WimPath $bootWim -Index 1 -WimlibPath $WimlibPath
    $bootIndex = Get-WimBootIndex -WimPath $bootWim -WimlibPath $WimlibPath
    Assert-True -Condition ($bootIndex -eq 1) -Message "captured boot.wim boot index is $bootIndex, expected 1 (Windows PE)"

    Assert-BootWimSize -WimPath $bootWim
    return $bootWim
}

function Invoke-CleanIsoStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $BootWim
    )

    $mediaBoot = Join-Path $paths.Media 'sources/boot.wim'
    Assert-PathExists -Path $BootWim -Label 'captured boot.wim'
    $mediaSources = Split-Path -Parent $mediaBoot
    if (-not (Test-Path -LiteralPath $mediaSources)) {
        New-Item -ItemType Directory -Path $mediaSources -Force | Out-Null
    }
    Copy-Item -LiteralPath $BootWim -Destination $mediaBoot -Force

    $wimBytes = (Get-Item -LiteralPath $mediaBoot).Length
    Assert-BootWimSize -WimPath $mediaBoot

    # The captured WIM is already single-image with boot index 1; re-assert
    # after the copy so a stale media boot.wim can never slip through.
    Set-WimBootIndex -WimPath $mediaBoot -Index 1 -WimlibPath $WimlibPath
    $bootIndex = Get-WimBootIndex -WimPath $mediaBoot -WimlibPath $WimlibPath
    Assert-True -Condition ($bootIndex -eq 1) -Message "media boot.wim boot index is $bootIndex, expected 1 (Windows PE)"

    Write-Step 'packaging MICPE-clean.iso'
    # Minimal media (user decision 2026-11-17 15:09): the ISO carries only
    # boot.wim. The UUP media tree still has the full install.wim; drop it
    # here, after the last step that needs it. The installer finds the
    # user's own install.wim on another volume (install.mic protocol).
    Remove-InstallWimFromMedia -MediaDir $paths.Media
    New-MicpeIso -MediaDir $paths.Media -OutIso $isoPath -OscdimgPath (Get-OscdimgPath)

    $isoBytes = (Get-Item -LiteralPath $isoPath).Length

    Write-Step 'size report'
    Write-SubStep ("boot.wim = {0}" -f (Format-ByteSize -Bytes $wimBytes))
    Write-SubStep ("MICPE-clean.iso = {0}" -f (Format-ByteSize -Bytes $isoBytes))

    return [pscustomobject]@{
        IsoPath  = $isoPath
        IsoBytes = $isoBytes
        BootWim  = $mediaBoot
        WimBytes = $wimBytes
    }
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

$base = Invoke-CleanBaseStep
$extract = Invoke-CleanExtractStep -InstallWim $base.InstallWim
Write-SubStep ("staged {0} file-list paths from install.wim index {1}" -f $extract.FileCount, $extract.ImageIndex)
Invoke-CleanShellStep
Invoke-CleanRegistryStep
Assert-CleanRegistry
$capturedBootWim = Invoke-CleanCaptureStep
$result = Invoke-CleanIsoStep -BootWim $capturedBootWim

Write-Step 'done'
Write-SubStep ("ISO: {0}" -f $result.IsoPath)
Write-SubStep ("SHA256: {0}" -f (Get-FileHash -LiteralPath $result.IsoPath -Algorithm SHA256).Hash)

if ($env:GITHUB_STEP_SUMMARY) {
    @(
        "## MICPE clean rebuild $Build ($Edition)"
        ''
        '| Item | Value |'
        '| --- | --- |'
        "| Build | ``$Build`` |"
        "| Edition | ``$Edition`` |"
        "| File list | ``$fileListPath`` (placeholder until the 15:15 diff) |"
        "| Shell | ``src/build/data/shell.zip`` (SHA256-pinned) |"
        "| boot.wim | $(Format-ByteSize -Bytes $result.WimBytes) |"
        "| ISO | $(Format-ByteSize -Bytes $result.IsoBytes) |"
        "| SHA256 | ``$((Get-FileHash -LiteralPath $result.IsoPath -Algorithm SHA256).Hash)`` |"
    ) | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
}

# Export the artifact paths for later steps (QEMU verify, Release upload).
# Guarded on GITHUB_ENV itself so local runs keep working.
if ($env:GITHUB_ENV) {
    "ISO_PATH=$($result.IsoPath)" | Add-Content -LiteralPath $env:GITHUB_ENV
    "BOOT_WIM_PATH=$($result.BootWim)" | Add-Content -LiteralPath $env:GITHUB_ENV
    "WIM_BYTES=$($result.WimBytes)" | Add-Content -LiteralPath $env:GITHUB_ENV
    "ISO_BYTES=$($result.IsoBytes)" | Add-Content -LiteralPath $env:GITHUB_ENV
    # The base install.wim is the install source for the deploy smoke
    # test's data disks (build.yml): the finished ISO no longer carries
    # one (user decision 2026-11-17 15:09), so the workflow cannot
    # extract it from the ISO anymore.
    "INSTALL_WIM_PATH=$($base.InstallWim)" | Add-Content -LiteralPath $env:GITHUB_ENV
}
