#Requires -Version 7.0
<#
.SYNOPSIS
    MIC-PE clean rebuild orchestrator (Windows 11 22H2, build 22621.1105
    Professional, rebuilt from the official image against the Ramos reference PE).

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
                  official install.wim (Professional index) into a staging
                  tree (--nullglob: a listed file the official image does
                  not carry is skipped, not fatal).
      2b. catfix  fetch the two 22621.900 catalog files cdrom.sys depends
                  on from the official UUP dump 22621.900 build (KB5020044,
                  user decision 2026-11-25 scheme 2) and inject them into
                  the staging CatRoot; SHA256-verified, and each .cat must
                  contain the cdrom.sys Authenticode hash. The RTM
                  install.wim does not carry them (round 12 root cause),
                  so the whitelist alone can never bring them in.
                  Read back after capture: both files must be in boot.wim
                  with matching SHA256, or the build fails here.
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

    FILE LIST IS FINAL (user decision 2026-11-24 15:00: no hash diff):
    src/build/data/clean-22621.1105-enterprise-files.txt is the reference
    file list minus the deleted third-party apps (Tencent, 360Chrome,
    Thunder, Office2010, PhotoshopCS3, 7-Zip, PENetwork, StartAllBack/
    Start11 program folders, and the third-party Start menu / desktop
    shortcuts). The official install.wim is the source of truth: the
    extract step copies only the listed paths out of it and skips any
    listed path the official image does not carry.

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

    # UUP edition for the download package. The reference PE is Enterprise,
    # but UUP dump does not offer zh-cn Enterprise (user decision
    # 2026-11-24: rebuild from Professional, same build 22621.1105).
    [string] $Edition = 'professional',

    [string] $Workspace,

    [string] $Output,

    [switch] $SkipDownload,

    [string] $SourceIso,

    # File list: one WIM-internal path per line (leading backslash optional,
    # '#' / ';' comment lines and blanks are skipped by Read-Whitelist).
    # Final list (user decision 2026-11-24 15:00: no hash diff against the
    # reference; the official install.wim is the source of truth).
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

# ClientBase loads FIRST on purpose: it defines Write-Step and sets
# StrictMode 2.0, and Common (loaded after) must win both -- the build's
# log format is Common's "==> " and the dispatch runs under Latest.
# Round 15: ClientBase was never loaded, so Enable-WimBootStack and
# Assert-BootCritical were dead code and r90 booted without WimFsf/FBWF.
foreach ($lib in 'ClientBase', 'Common', 'Payload', 'Disk', 'Wim', 'Registry', 'AdminAccount', 'BaseImage', 'Iso') {
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
Write-SubStep ("file list: {0} (final, no hash diff; official image is the source of truth)" -f $fileListPath)

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
    # (Professional index) into the staging tree. --nullglob skips a listed
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

    # Raw state, before any fix: what the install.wim actually left
    # behind (attributes + ACL). Run 45368774235 ran the attrib fix
    # without error and the icsxml copy was still denied, so the log
    # must show the real state instead of assuming the fix worked.
    Show-StagingWriteState -Path $paths.Staging -Label 'staging tree (raw, after extract)'

    # The extracted tree carries the install.wim's read-only attributes;
    # the shell and registry steps write into it (StartAllBack.xml, the
    # hives, unattend.xml), so make it writable now. Run 45359151127
    # failed here: Copy-Item into the extracted icsxml directory was
    # denied while the script-created MICPE directory took the same
    # copy fine.
    Clear-StagingReadOnly -Path $paths.Staging

    # The attribute is not the whole story (run 45368774235): a
    # directory's read-only flag does not block creating files inside
    # it, and the destination file does not exist yet, so the blocker
    # is the ACL -- folders arrive from the install.wim owned by
    # TrustedInstaller. Grant write access to every place the build
    # writes into: the icsxml directory (StartAllBack.xml), the
    # config directory and the hive files themselves (reg load/import
    # and the SAM edit write them in place), and System32 itself
    # (unattend.xml lands there). Same takeown + icacls pattern as
    # Grant-FolderWriteAccess (UwpChain.ps1).
    foreach ($writeTarget in @(
            'Windows\System32\icsxml',
            'Windows\System32\config',
            'Windows\System32\config\SYSTEM',
            'Windows\System32\config\SOFTWARE',
            'Windows\System32\config\DEFAULT',
            'Windows\System32\config\SAM',
            'Windows\System32\config\SECURITY',
            'Windows\System32'
        )) {
        Grant-StagingWriteAccess -Path (Join-Path $paths.Staging $writeTarget)
    }

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

# ---------------------------------------------------------------------------
# Catalog fix (round 13): the two 22621.900 .cat files cdrom.sys depends on
# ---------------------------------------------------------------------------
# Root cause (round 12, verified with objdump + Authenticode hashing):
# cdrom.sys is the only boot-start driver with NO embedded signature (PE
# data directory index 4, certificate table, is 0/0; the other 11 boot
# files all carry ~9.5 KB). Winload verifies it through the system
# catalogs, and its Authenticode hash lives only in these two 22621.900
# catalog files. Both are in the 9,405-path whitelist, but the RTM
# install.wim (22621.1, AddUpdates=0) does not carry them, so the extract
# step silently skips them (--nullglob) and the captured boot.wim has no
# catalog vouching for cdrom.sys -> winload reports 0xc0000428 ("the hash
# for the image cannot be found in the system catalogs", [MS-ERREF]).
#
# Fix (user decision 2026-11-25 10:33, scheme 2): fetch the two files from
# the official UUP dump 22621.900 build (KB5020044, uuid
# 5d5ef944-1ba0-436b-b7d3-571d59a15cbb) and inject them into the staging
# CatRoot. Ramos is comparison only, never a source (the user: many Ramos
# files were tampered with). AddUpdates stays 0; the local machine cannot
# fetch the files (the POST is blocked), so the fetch happens in CI, where
# the base step already does the same get.php POST.

function Find-ByteSequence {
    # Raw byte search: returns $true when $Needle occurs in $Bytes. Used
    # for the .cat check -- catalog files store the Authenticode hash as
    # raw bytes, not text, so a string search would miss it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]] $Bytes,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]] $Needle
    )

    if ($Needle.Count -eq 0) { return $true }
    if ($Bytes.Count -lt $Needle.Count) { return $false }
    $start = 0
    while ($true) {
        $pos = [System.Array]::IndexOf($Bytes, $Needle[0], $start)
        if ($pos -lt 0 -or ($pos + $Needle.Count) -gt $Bytes.Count) { return $false }
        $match = $true
        for ($j = 1; $j -lt $Needle.Count; $j++) {
            if ($Bytes[$pos + $j] -ne $Needle[$j]) { $match = $false; break }
        }
        if ($match) { return $true }
        $start = $pos + 1
    }
}

function Test-CleanCatHasCdromHash {
    # True when the catalog file contains the cdrom.sys Authenticode hash
    # (both SHA1 and SHA256, as raw bytes). The hashes are pinned: they
    # belong to the RTM cdrom.sys the build always extracts (SHA256
    # 3912fc71...), computed with the section-based Authenticode algorithm
    # (see ~/workspace/micpe-catfix/authenticode_hash.py -- the naive
    # "whole file minus CheckSum" hash is wrong).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $CatPath,

        [string] $Sha1 = '8f19637e8381f4406a72e06276a609bde11ef4e5',

        [string] $Sha256 = '3ca40d030fd515fde7451e685dda10d5c52c20e7898c1b87ea3c86ce329b0d94'
    )

    $bytes = [System.IO.File]::ReadAllBytes($CatPath)
    $sha1Bytes = [System.Convert]::FromHexString($Sha1)
    $sha256Bytes = [System.Convert]::FromHexString($Sha256)
    return ((Find-ByteSequence -Bytes $bytes -Needle $sha1Bytes) -and
        (Find-ByteSequence -Bytes $bytes -Needle $sha256Bytes))
}

function Assert-CleanCatFiles {
    # Filesystem read-back for a directory of .cat files: each expected
    # file must be present exactly once, with the pinned size and SHA256.
    # Hard failure (not the relaxed registry read-back): if the catalogs
    # are not in the image, the whole round is pointless and a 40-minute
    # QEMU run must not be wasted on it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $CatDir,

        [Parameter(Mandatory = $true)]
        [object[]] $ExpectedCats
    )

    foreach ($cat in $ExpectedCats) {
        $found = @(Get-ChildItem -LiteralPath $CatDir -Filter $cat.Name -Recurse -File -ErrorAction SilentlyContinue)
        Assert-True -Condition ($found.Count -eq 1) -Message (
            "catalog read-back: $($cat.Name) not found exactly once under $CatDir (found $($found.Count))")
        $actualSize = (Get-Item -LiteralPath $found[0].FullName).Length
        Assert-True -Condition ($actualSize -eq $cat.Size) -Message (
            "catalog read-back: $($cat.Name) size is $actualSize, expected $($cat.Size)")
        $actualHash = (Get-FileHash -LiteralPath $found[0].FullName -Algorithm SHA256).Hash.ToLower()
        Assert-True -Condition ($actualHash -eq $cat.Sha256.ToLower()) -Message (
            "catalog read-back: $($cat.Name) SHA256 mismatch: expected $($cat.Sha256), got $actualHash")
    }
}

function Find-CleanCatLcuCab {
    # Parse a UUP dump file list (aria2 input format: a URL line followed
    # by indented `out=<filename>` lines, or bare URLs) and return the
    # single KB cumulative-update .cab. Exactly one must match: the list
    # is per build + edition + language, so a second KB5020044 cab would
    # mean the list is not what was asked for -- fail loudly instead of
    # guessing which one holds the catalogs.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $FileListText,

        [string] $Kb = 'KB5020044'
    )

    $pairs = [System.Collections.Generic.List[pscustomobject]]::new()
    $currentUrl = $null
    $currentName = $null
    foreach ($rawLine in ($FileListText -split "`r?`n")) {
        $line = $rawLine.Trim()
        if (-not $line) { continue }
        if ($line -match '^(https?://\S+)') {
            if ($null -ne $currentUrl) {
                $name = $currentName
                if (-not $name) {
                    $name = ($currentUrl -split '/')[-1]
                }
                $pairs.Add([pscustomobject]@{ Url = $currentUrl; FileName = $name })
            }
            $currentUrl = $Matches[1].Trim('"', "'")
            $currentName = $null
            continue
        }
        if ($line -match '^out\s*=\s*(.+?)\s*$' -and $null -ne $currentUrl) {
            $currentName = $Matches[1].Trim('"', "'")
            continue
        }
    }
    if ($null -ne $currentUrl) {
        $name = $currentName
        if (-not $name) {
            $name = ($currentUrl -split '/')[-1]
        }
        $pairs.Add([pscustomobject]@{ Url = $currentUrl; FileName = $name })
    }

    $matches = @($pairs | Where-Object {
            $_.FileName -like '*.cab' -and $_.FileName -like "*$Kb*"
        })
    Assert-True -Condition ($matches.Count -eq 1) -Message (
        "UUP file list: expected exactly one $Kb .cab, found $($matches.Count): $(($matches | ForEach-Object { $_.FileName }) -join ', ')")
    return $matches[0]
}

function Get-CleanCatFixFileList {
    # Resolve the 22621.900 build and download its bare file list as
    # plain text (get.php aria2=2 -- the aria2 input file: URL lines
    # followed by indented `out=<filename>` lines). That is the list
    # the LCU cab URL comes from.
    #
    # Do NOT use autodl=1 here: round 13 proved it returns a
    # downloader-script ZIP (uup_download_windows.cmd etc.) with no file
    # list in it, so the matcher found 0 cabs and the whole round died
    # before QEMU. aria2=2 is the endpoint that returns the list itself
    # (verified 2026-11-25: GET returns 324 lines, exactly one
    # Windows11.0-KB5020044-x64.cab).
    [CmdletBinding()]
    param(
        [string] $Build = '22621.900',

        [string] $Lang = 'zh-cn',

        [string] $Edition = 'professional',

        [Parameter(Mandatory = $true)]
        [string] $WorkDir,

        [string] $WebBase = 'https://uupdump.net',

        [scriptblock] $UupInvoke
    )

    $uup = Get-UupBuild -Build $Build -Arch 'amd64' -Channel 'stable' -Invoke $UupInvoke
    Write-SubStep ("UUP catalog build: {0} ({1})" -f $uup.Build, $uup.Title)

    if (-not (Test-Path -LiteralPath $WorkDir)) {
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    }
    $query = "id=$($uup.Uuid)&pack=$([uri]::EscapeDataString($Lang))&edition=$([uri]::EscapeDataString($Edition))&aria2=2"
    $url = "$WebBase/get.php?$query"
    $listDir = Join-Path $WorkDir 'filelist'
    if (Test-Path -LiteralPath $listDir) {
        Remove-Item -LiteralPath $listDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $listDir -Force | Out-Null
    $listFile = Join-Path $listDir 'uup-filelist.txt'
    Write-SubStep "downloading UUP file list for $($uup.Uuid) ($Lang, $Edition)"
    Invoke-NetworkWithRetry -Action {
        Invoke-WebRequest -Uri $url -OutFile $listFile -TimeoutSec 600
    } -Label "UUP file list $url"
    Assert-PathExists -Path $listFile -Label 'UUP file list'
    # The endpoint must have returned the aria2 list, not an error page
    # or a script ZIP: fail loudly here instead of letting the matcher
    # report a misleading "found 0 cabs" downstream.
    $listText = Get-Content -LiteralPath $listFile -Raw
    $preview = if ($listText) { $listText.Substring(0, [Math]::Min(200, $listText.Length)) } else { '<empty>' }
    Assert-True -Condition ($listText -match '(?m)^\s*out\s*=') -Message (
        "UUP file list from $url is not an aria2 list (no 'out=' lines; first 200 chars: $preview)")
    return $listDir
}

function Invoke-CleanCatFixStep {
    # Fetch the two 22621.900 catalog files from the official UUP dump
    # build and inject them into the staging CatRoot. Runs after extract
    # (the staging tree is writable by then) and before capture.
    # -FileListZipPath / -CabPath are test seams: when given, the network
    # fetch / download is skipped and the supplied files are used.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StagingDir,

        [Parameter(Mandatory = $true)]
        [string] $WorkDir,

        [string] $CatBuild = '22621.900',

        [string] $CatKb = 'KB5020044',

        [string] $CatRootRel = 'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}',

        [string] $SevenZipPath = '7z',

        [string] $Lang = 'zh-cn',

        [string] $Edition = 'professional',

        [scriptblock] $UupInvoke,

        [string] $FileListZipPath,

        [string] $CabPath,

        [object[]] $ExpectedCats = @(
            [pscustomobject]@{
                Name   = 'Microsoft-Windows-Client-Desktop-Required-Package0110~31bf3856ad364e35~amd64~~10.0.22621.900.cat'
                Size   = 205062
                Sha256 = 'e09905c4319b6194def5c9b33f53688234ef1fd80cc5a568c486e8843143dd8d'
            },
            [pscustomobject]@{
                Name   = 'Microsoft-Windows-Common-Drivers-merged-Package~31bf3856ad364e35~amd64~~10.0.22621.900.cat'
                Size   = 137452
                Sha256 = '0a614b442f4c3a85c3f5a4615f748c5b94b2f3f401802e46f7bb2101adc03f62'
            }
        ),

        [string] $CdromSha1 = '8f19637e8381f4406a72e06276a609bde11ef4e5',

        [string] $CdromSha256 = '3ca40d030fd515fde7451e685dda10d5c52c20e7898c1b87ea3c86ce329b0d94'
    )

    Write-Step 'fetching the two 22621.900 catalog files for cdrom.sys (round 13 root cause)'

    # 1. File list (aria2=2) -> the single KB5020044 LCU cab URL.
    if ($FileListZipPath) {
        $fileListDir = Join-Path $WorkDir 'filelist'
        if (Test-Path -LiteralPath $fileListDir) {
            Remove-Item -LiteralPath $fileListDir -Recurse -Force
        }
        Expand-Archive -LiteralPath $FileListZipPath -DestinationPath $fileListDir -Force
    }
    else {
        $fileListDir = Get-CleanCatFixFileList -Build $CatBuild -Lang $Lang -Edition $Edition -WorkDir $WorkDir -UupInvoke $UupInvoke
    }
    $listFiles = @(Get-ChildItem -LiteralPath $fileListDir -Filter '*.txt' -Recurse -File -ErrorAction SilentlyContinue)
    if ($listFiles.Count -eq 0) {
        $listFiles = @(Get-ChildItem -LiteralPath $fileListDir -Filter '*.cmd' -Recurse -File -ErrorAction SilentlyContinue)
    }
    Assert-True -Condition ($listFiles.Count -gt 0) -Message (
        "UUP file list contained no .txt/.cmd file under $fileListDir (contents: $((Get-ChildItem -LiteralPath $fileListDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', '))")
    $listText = ($listFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    $lcu = Find-CleanCatLcuCab -FileListText $listText -Kb $CatKb
    Write-SubStep ("LCU cab: {0}" -f $lcu.FileName)

    # 2. Download only that cab (the whole conversion package is GBs;
    # the catalogs live in this one cab).
    $downloadedCab = $false
    if (-not $CabPath) {
        if (-not (Test-Path -LiteralPath $WorkDir)) {
            New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
        }
        $CabPath = Join-Path $WorkDir $lcu.FileName
        Invoke-NetworkWithRetry -Action {
            Invoke-WebRequest -Uri $lcu.Url -OutFile $CabPath -TimeoutSec 1800
        } -Label "LCU cab download $($lcu.FileName)"
        $downloadedCab = $true
    }
    Assert-PathExists -Path $CabPath -Label "LCU cab $($lcu.FileName)"

    # 3. Extract just the two catalog files (wildcards, recursive: the
    # cab stores them under component paths, not at the root).
    $extractDir = Join-Path $WorkDir 'lcu'
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    $wildcards = @($ExpectedCats | ForEach-Object { "*$($_.Name)" })
    # Do NOT initialise $LASTEXITCODE here: a plain assignment creates a
    # function-local that shadows the real value (a native 7z exit code,
    # or the fake's $global:LASTEXITCODE, would never reach the check
    # below). The BCD experiment proved the no-init pattern; a fresh
    # session starts with $LASTEXITCODE 0 and both 7z and the fake always
    # set it.
    $null = & $SevenZipPath x $CabPath ("-o{0}" -f $extractDir) -y -r @wildcards 2>&1
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message (
        "7z failed to extract the catalog files from $($lcu.FileName) (exit $LASTEXITCODE)")

    # 4. Verify each catalog (size + SHA256 + cdrom.sys hash inside),
    # then inject it into the staging CatRoot.
    $catRootDir = Join-Path $StagingDir $CatRootRel
    if (-not (Test-Path -LiteralPath $catRootDir)) {
        New-Item -ItemType Directory -Path $catRootDir -Force | Out-Null
    }
    $injected = [System.Collections.Generic.List[string]]::new()
    foreach ($cat in $ExpectedCats) {
        $found = @(Get-ChildItem -LiteralPath $extractDir -Filter $cat.Name -Recurse -File -ErrorAction SilentlyContinue)
        Assert-True -Condition ($found.Count -eq 1) -Message (
            "LCU cab $($lcu.FileName) did not contain exactly one $($cat.Name) (found $($found.Count))")
        $catPath = $found[0].FullName
        $actualSize = (Get-Item -LiteralPath $catPath).Length
        Assert-True -Condition ($actualSize -eq $cat.Size) -Message (
            "$($cat.Name) size is $actualSize, expected $($cat.Size)")
        $actualHash = (Get-FileHash -LiteralPath $catPath -Algorithm SHA256).Hash.ToLower()
        Assert-True -Condition ($actualHash -eq $cat.Sha256.ToLower()) -Message (
            "$($cat.Name) SHA256 mismatch: expected $($cat.Sha256), got $actualHash")
        $hasHash = Test-CleanCatHasCdromHash -CatPath $catPath -Sha1 $CdromSha1 -Sha256 $CdromSha256
        Assert-True -Condition $hasHash -Message (
            "$($cat.Name) does not contain the cdrom.sys Authenticode hash -- wrong catalog file")
        Copy-Item -LiteralPath $catPath -Destination (Join-Path $catRootDir $cat.Name) -Force
        Assert-PathExists -Path (Join-Path $catRootDir $cat.Name) -Label "staged $($cat.Name)"
        $injected.Add($cat.Name)
        Write-SubStep ("injected {0} ({1} bytes, SHA256 verified, cdrom.sys hash present)" -f $cat.Name, $actualSize)
    }

    # 5. Drop the big temp files (the cab is hundreds of MB, the expanded
    # tree GBs); the injected copies live in staging now. A test-supplied
    # cab is the caller's file, never deleted.
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($downloadedCab) {
        Remove-Item -LiteralPath $CabPath -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        ExpectedCats = $ExpectedCats
        CatRootRel   = $CatRootRel
        Injected     = @($injected.ToArray())
    }
}

function Assert-CleanCatFilesInBootWim {
    # Read-back after capture: the two catalogs must be in boot.wim with
    # matching SHA256. Hard failure -- this is the whole point of the
    # round, and a silent miss would waste the QEMU run.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $BootWim,

        [Parameter(Mandatory = $true)]
        [object[]] $ExpectedCats,

        [string] $CatRootRel = 'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}',

        [string] $WorkDir,

        [string] $WimlibPath = 'wimlib-imagex'
    )

    $extractDir = if ($WorkDir) { $WorkDir } else { Join-Path (Split-Path -Parent $BootWim) 'catfix-readback' }
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force
    }
    $patterns = @($ExpectedCats | ForEach-Object { "$CatRootRel\$($_.Name)" })
    Export-WimFiles -WimPath $BootWim -Index 1 -Destination $extractDir -Patterns $patterns -WimlibPath $WimlibPath
    Assert-CleanCatFiles -CatDir $extractDir -ExpectedCats $ExpectedCats
    Write-SubStep 'catalog read-back: both 22621.900 .cat files are in boot.wim with matching SHA256'
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

function Invoke-CleanWimBootStep {
    # Transplant the WIM boot stack (WimFsf + FBWF) from the stock install
    # media boot.wim into staging (round 15: IO1 INITIALIZATION FAILED).
    # The clean rebuild copies only whitelist files out of install.wim,
    # and install.wim never WIM-boots, so it carries neither wimfsf.sys /
    # fbwf.sys nor the WimFsf / FBWF service definitions -- the whitelist
    # lists them, but the copy step silently skips them with a warning
    # (round 14 log: 4x "No matches for path pattern"). Without the stack
    # the kernel cannot mount its own boot volume and bugchecks 0x69.
    # Enable-WimBootStack (ClientBase.ps1) does the transplant from the
    # stock boot.wim and verifies Start=0 by read-back; it throws when
    # the donor lacks the drivers. fbwflib.dll / fbwf.sys.mui are NOT
    # transplanted here: the driver does not import the user-mode library
    # and the .mui is only localized strings -- if round 15 still 0x69s,
    # add them next. Runs after the registry step (its hive edits must
    # land first) and before capture.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StagingDir,

        [Parameter(Mandatory = $true)]
        [string] $PeDonorWim,

        [int] $OverlayMegabytes = 4096,

        [string] $WimlibPath = 'wimlib-imagex'
    )

    Write-Step 'transplanting the WIM boot stack (WimFsf + FBWF) from the stock boot.wim'
    Enable-WimBootStack -ImageRoot $StagingDir -PeDonorWim $PeDonorWim -OverlayMegabytes $OverlayMegabytes -WimlibPath $WimlibPath
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
    # State right before the copy that run 45368774235 denied: attrib +
    # icacls + a write probe, so the next run's log shows whether the
    # grant above actually took, instead of assuming it did.
    Show-StagingWriteState -Path $icsxmlDir -Label 'icsxml (before StartAllBack.xml copy)' -ShowContents
    Copy-Item -LiteralPath (Join-Path $repoRoot 'src\build\data\StartAllBack.xml') `
        -Destination (Join-Path $icsxmlDir 'StartAllBack.xml') -Force

    foreach ($required in @(
            'Windows\System32\MICPE\StartAllBack\StartAllBackX64.dll',
            'Windows\System32\MICPE\StartAllBack\StartAllBackLoaderX64.dll',
            'Windows\System32\MICPE\StartAllBack\StartAllBackCfg.exe',
            'Windows\System32\MICPE\Start11\Start11.exe',
            'Windows\System32\MICPE\Start11\Start11Config.exe',
            'Windows\System32\MICPE\Start11\Start11_64.exe',
            'Windows\System32\icsxml\StartAllBack.xml'
        )) {
        Assert-PathExists -Path (Join-Path $paths.Staging $required) -Label "staged $required"
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath $linksDir)) -Message (
        'Start11\Links survived the shell step; the pinned-item shortcuts must not ship')
}

function Get-CleanAppDirs {
    # Discover the app directories under app/ that take part in the clean
    # build. A directory is an app when it carries install.bat (the CI
    # integration script) AND at least one .reg file at its top level (the
    # registry that app needs). No software name is hardcoded here: the
    # build scans the directories, so a new app joins by adding a folder
    # with install.bat + .reg and registering its archive in Payload.ps1.
    # Excluded by construction:
    #   _template  -- name starts with '_'; a template, not an app.
    #   payload    -- no install.bat (expanded by Expand-Payload instead).
    #   start11 / startallback -- laid out by the shell step (shell.zip),
    #     not the app step; their .reg files (if any) live in a reg/
    #     subdirectory, not at the top level.
    $appRoot = Join-Path $repoRoot 'app'
    if (-not (Test-Path -LiteralPath $appRoot)) { return @() }
    $dirs = Get-ChildItem -LiteralPath $appRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '_*' } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'install.bat') } |
        Where-Object { @(Get-ChildItem -LiteralPath $_.FullName -Filter '*.reg' -File -ErrorAction SilentlyContinue).Count -gt 0 } |
        Sort-Object Name
    return @($dirs | ForEach-Object { $_.FullName })
}

function Invoke-CleanAppStep {
    # For every discovered app directory, in name order: join its split
    # volumes (Payload.ps1: byte-exact join + SHA256 of the JOINED archive),
    # run its install.bat against the staging tree, and collect its .reg
    # files for the registry step. The .reg files are NOT imported here:
    # the registry step mounts the staging hives once and imports the
    # clean patches and the app patches together. Returns the collected
    # .reg paths and the installed app names.
    $appDirs = Get-CleanAppDirs
    if ($appDirs.Count -eq 0) {
        Write-SubStep 'no app directories discovered under app/'
        return [pscustomobject]@{ RegFiles = @(); Names = @() }
    }

    $appStaging = Join-Path $paths.Logs 'apps'
    if (-not (Test-Path -LiteralPath $appStaging)) {
        New-Item -ItemType Directory -Path $appStaging -Force | Out-Null
    }

    $appRegFiles = [System.Collections.Generic.List[string]]::new()
    $appNames = [System.Collections.Generic.List[string]]::new()
    foreach ($appDir in $appDirs) {
        $name = Split-Path -Leaf $appDir
        Write-Step "installing app: $name"
        # Join + verify the archive. Throws when the package is not
        # registered in Payload.ps1 -- register it there first (archive
        # name, volumes, joined SHA256); a silent skip would ship an
        # image missing the app.
        $archive = Get-AppPackageArchive -Name $name -RepoRoot $repoRoot -StagingDir $appStaging
        # Run the component install.bat against the staging tree
        # (vendor layout: Office -> Program Files\Office2016, Chrome ->
        # Program Files\Google\Chrome\Application; never MICPE).
        Invoke-ComponentInstall -Component $name -MountDir $paths.Staging -RepoRoot $repoRoot -AssetPath $archive
        # Collect this app's .reg files (top level, sorted by name).
        $regs = @(Get-ChildItem -LiteralPath $appDir -Filter '*.reg' -File | Sort-Object Name | ForEach-Object { $_.FullName })
        foreach ($reg in $regs) { $appRegFiles.Add($reg) }
        $appNames.Add($name)
        Write-SubStep ("app {0}: installed, {1} .reg file(s) collected" -f $name, $regs.Count)
    }
    return [pscustomobject]@{ RegFiles = @($appRegFiles.ToArray()); Names = @($appNames.ToArray()) }
}

function Invoke-CleanRegistryStep {
    # Mount the staging hives and import the clean .reg patches at CI
    # build time (user decision 2026-11-17 23:43: never inside the PE),
    # then enable Administrator in the staging SAM and write unattend.xml.
    # Invoke-RegistryScript mounts from $MountDir\Windows\System32\config,
    # which is exactly the staging layout, so it works on a plain
    # directory tree -- no DISM mount is needed for this step.
    [CmdletBinding()]
    param(
        # .reg files collected from the discovered app directories
        # (Invoke-CleanAppStep). Imported together with the clean patches
        # in one mount session, after them.
        [string[]] $AppRegFiles = @()
    )

    $regFiles = @('10-clean-boot.reg', '20-clean-start11.reg', '30-clean-author.reg', '40-clean-startallback.reg') |
        ForEach-Object { Join-Path $regDirPath $_ }
    foreach ($regFile in $regFiles) {
        Assert-PathExists -Path $regFile -Label "registry patch $(Split-Path -Leaf $regFile)"
    }
    $allRegFiles = @($regFiles) + @($AppRegFiles)
    foreach ($regFile in $allRegFiles) {
        Assert-PathExists -Path $regFile -Label "registry patch $(Split-Path -Leaf $regFile)"
    }

    Write-Step 'importing the clean registry patches into the staging hives'
    Invoke-RegistryScript -MountDir $paths.Staging -RegFiles $allRegFiles

    Write-Step 'enabling built-in Administrator in the staging SAM'
    $samPath = Join-Path $paths.Staging 'Windows\System32\config\SAM'
    $admin = Set-OfflineAdminState -SamPath $samPath
    if (-not $admin.Found) {
        # MEASURED (2026-11-24, run 45390017855): the official install.wim
        # SAM is an EMPTY hive by design -- 8,192 bytes, valid regf, no
        # subkeys, no Administrator record. Verified against the exact UUP
        # source (professional_zh-cn.esd, image 3 "Windows 11 专业版",
        # SHA1-verified): its \Windows\System32\config\SAM is the same
        # 8 KB empty hive, and the sibling hives show the same pattern
        # (SOFTWARE 66 MB and SYSTEM 8.9 MB populated, SECURITY/BBI 8 KB
        # minimal). The extraction is faithful (wimlib extract of the
        # reference PE SAM is byte-identical), and no build step touches
        # SAM between extraction and here, so an empty hive is expected,
        # not a lost extract. The SAM service creates the built-in accounts
        # (including Administrator RID 500) when it starts -- the reference
        # PE proves it: it boots to LogonUI with a working Administrator
        # even though the image it was built from had an empty SAM, and
        # 10-clean-boot.reg already lifts the blank-password restriction.
        # Skip the offline enable and let the boot-time SAM service do it.
        Write-Warn 'staging SAM is an empty hive (no Administrator record): expected for an install.wim source; the SAM service creates the built-in accounts at boot, so the offline enable step is skipped'
    }

    # The reference's unattend.xml (windowsPE pass only: ComputerName
    # WINXPE, no network, no firewall). The official install.wim does
    # not ship one at this path, so it is written from the repo copy.
    Copy-Item -LiteralPath (Join-Path $repoRoot 'src\build\data\unattend.xml') `
        -Destination (Join-Path $paths.Staging 'Windows\System32\unattend.xml') -Force
    Assert-PathExists -Path (Join-Path $paths.Staging 'Windows\System32\unattend.xml') -Label 'staged unattend.xml'
}

function Assert-ReadBack {
    # Registry read-back check, relaxed to a warning by user decision
    # (2026-11-24 23:18, reply to the round 5 failure report): the clean
    # rebuild is in early debugging, so a read-back mismatch must not fail
    # the build -- it is logged loudly and the build continues to the ISO
    # and the QEMU screenshot verification, which is the real evidence.
    # Only the read-back section uses this; the extract / copy / registry
    # import / SAM steps keep their hard Assert-True failures.
    # To tighten again, make this throw (or swap the calls back to
    # Assert-True): replace the Write-Warn below with a throw of
    # [System.InvalidOperationException].
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool] $Condition,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if (-not $Condition) {
        $script:readBackFailures++
        Write-Warn "read-back FAILED (warning only, build continues): $Message"
    }
}

function Assert-CleanRegistry {
    # Read back the values the clean patches must have landed, through the
    # mounted staging hives (reg.exe query, never the PowerShell provider:
    # the provider holds an open handle and a later reg unload fails).
    # Run 55 lesson: an import that exits 0 can still have missed, so the
    # read-back happens here, at the registry step, not three steps later.
    [CmdletBinding()]
    param(
        # App names installed by Invoke-CleanAppStep. Only the apps that
        # were actually installed are read back here.
        [string[]] $AppNames = @()
    )

    $configDir = Join-Path $paths.Staging 'Windows\System32\config'
    $script:readBackFailures = 0
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
        Assert-ReadBack -Condition ($null -ne $setup) -Message 'read-back: PE-SYS\Setup is missing'
        Assert-ReadBack -Condition ($setup['SetupType'] -eq '0x2') -Message "read-back: SetupType is '$($setup['SetupType'])', expected 0x2"
        Assert-ReadBack -Condition ($setup['CmdLine'] -eq 'LogonUI') -Message "read-back: CmdLine is '$($setup['CmdLine'])', expected LogonUI"
        Assert-ReadBack -Condition ($setup['SystemSetupInProgress'] -eq '0x0') -Message "read-back: SystemSetupInProgress is '$($setup['SystemSetupInProgress'])', expected 0x0"

        # Boot-start drivers (round 10 root cause): cdrom and exfat must be
        # Start=0 like the Ramos reference PE; the official install.wim
        # ships cdrom at Start=1 and exfat at Start=3, and round 10 died
        # in winload on cdrom.sys 0xc0000428.
        $cdrom = Get-RegistryKeyValues -KeyName 'PE-SYS' -SubKey 'ControlSet001\Services\cdrom'
        Assert-ReadBack -Condition ($null -ne $cdrom) -Message 'read-back: PE-SYS\ControlSet001\Services\cdrom is missing'
        Assert-ReadBack -Condition ($cdrom['Start'] -eq '0x0') -Message "read-back: cdrom Start is '$($cdrom['Start'])', expected 0x0"
        $exfat = Get-RegistryKeyValues -KeyName 'PE-SYS' -SubKey 'ControlSet001\Services\exfat'
        Assert-ReadBack -Condition ($null -ne $exfat) -Message 'read-back: PE-SYS\ControlSet001\Services\exfat is missing'
        Assert-ReadBack -Condition ($exfat['Start'] -eq '0x0') -Message "read-back: exfat Start is '$($exfat['Start'])', expected 0x0"

        # Missing boot drivers (round 11 root cause): the official
        # install.wim SYSTEM hive lists 9 Start=0 drivers whose .sys files
        # are not in the captured boot.wim; the Ramos reference PE has none
        # of these 9 services at all. Two are ErrorControl=3 (critical):
        # iorate and rdyboost. WdBoot is the Early-Launch (ELAM) driver.
        # Disable all 9 so winload never tries to load a boot driver that
        # is not in the image.
        foreach ($name in @('WdBoot', 'WdFilter', 'MsSecFlt', 'SgrmAgent', 'IntelPMT', 'intelpep', 'cnghwassist', 'iorate', 'rdyboost')) {
            $svc = Get-RegistryKeyValues -KeyName 'PE-SYS' -SubKey "ControlSet001\Services\$name"
            Assert-ReadBack -Condition ($null -ne $svc) -Message "read-back: PE-SYS\ControlSet001\Services\$name is missing"
            Assert-ReadBack -Condition ($svc['Start'] -eq '0x4') -Message "read-back: $name Start is '$($svc['Start'])', expected 0x4"
        }

        $winlogon = Get-RegistryKeyValues -KeyName 'PE-SOFT' -SubKey 'Microsoft\Windows NT\CurrentVersion\Winlogon'
        Assert-ReadBack -Condition ($null -ne $winlogon) -Message 'read-back: PE-SOFT Winlogon is missing'
        Assert-ReadBack -Condition ($winlogon['Shell'] -eq 'explorer.exe') -Message "read-back: Winlogon Shell is '$($winlogon['Shell'])', expected explorer.exe"
        Assert-ReadBack -Condition ($winlogon['AutoRestartShell'] -eq '0x1') -Message "read-back: AutoRestartShell is '$($winlogon['AutoRestartShell'])', expected 0x1"

        $currentVersion = Get-RegistryKeyValues -KeyName 'PE-SOFT' -SubKey 'Microsoft\Windows NT\CurrentVersion'
        Assert-ReadBack -Condition ($currentVersion['RegisteredOwner'] -eq 'SYSTEM-Intel-MIC') -Message "read-back: RegisteredOwner is '$($currentVersion['RegisteredOwner'])', expected SYSTEM-Intel-MIC"
        Assert-ReadBack -Condition ($currentVersion['SystemRoot'] -eq 'X:\Windows') -Message "read-back: SystemRoot is '$($currentVersion['SystemRoot'])', expected X:\Windows"

        $loader = Get-RegistryKeyValues -KeyName 'PE-SOFT' -SubKey 'Classes\CLSID\{117E3954-5034-453A-A18B-7B79493646E6}\InprocServer32'
        Assert-ReadBack -Condition ($null -ne $loader) -Message 'read-back: StartAllBack loader CLSID is missing'
        Assert-ReadBack -Condition ($loader['(Default)'] -match 'MICPE\\StartAllBack\\StartAllBackLoaderX64\.dll') -Message "read-back: loader CLSID points at '$($loader['(Default)'])', expected the MICPE path"

        $startIsBack = Get-RegistryKeyValues -KeyName 'PE-DEF' -SubKey 'Software\StartIsBack'
        Assert-ReadBack -Condition ($null -ne $startIsBack) -Message 'read-back: PE-DEF Software\StartIsBack is missing'
        Assert-ReadBack -Condition ($startIsBack['Disabled'] -eq '0x0') -Message "read-back: StartIsBack Disabled is '$($startIsBack['Disabled'])', expected 0x0"

        $start8 = Get-RegistryKeyValues -KeyName 'PE-DEF' -SubKey 'Software\Stardock\Start8\Start8.ini\Start8'
        Assert-ReadBack -Condition ($null -ne $start8) -Message 'read-back: PE-DEF Start11 Start8.ini\Start8 is missing'
        Assert-ReadBack -Condition ($start8['Image'] -match 'MICPE\\Start11\\StartButtons\\default\.png') -Message "read-back: Start11 Image is '$($start8['Image'])', expected the MICPE path"

        # App registry (only the apps Invoke-CleanAppStep installed): the
        # App Paths entry proves the app .reg landed; the file-association
        # entry proves the ProgID wiring landed.
        foreach ($appName in $AppNames) {
            if ($appName -eq 'chrome') {
                $chromePaths = Get-RegistryKeyValues -KeyName 'PE-SOFT' -SubKey 'Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
                Assert-ReadBack -Condition ($null -ne $chromePaths) -Message 'read-back: PE-SOFT App Paths\chrome.exe is missing'
                Assert-ReadBack -Condition ($chromePaths['(Default)'] -eq 'X:\Program Files\Google\Chrome\Application\chrome.exe') -Message "read-back: chrome.exe App Paths is '$($chromePaths['(Default)'])', expected the Chrome Application path"
                $chromeHtml = Get-RegistryKeyValues -KeyName 'PE-SOFT' -SubKey 'Classes\ChromeHTML'
                Assert-ReadBack -Condition ($null -ne $chromeHtml) -Message 'read-back: PE-SOFT Classes\ChromeHTML is missing'
                Assert-ReadBack -Condition ($chromeHtml['(Default)'] -eq 'Chrome HTML Document') -Message "read-back: ChromeHTML is '$($chromeHtml['(Default)'])', expected 'Chrome HTML Document'"
                $htmlAssoc = Get-RegistryKeyValues -KeyName 'PE-SOFT' -SubKey 'Classes\.html'
                Assert-ReadBack -Condition ($null -ne $htmlAssoc) -Message 'read-back: PE-SOFT Classes\.html is missing'
                Assert-ReadBack -Condition ($htmlAssoc['(Default)'] -eq 'ChromeHTML') -Message "read-back: .html is '$($htmlAssoc['(Default)'])', expected ChromeHTML"
            }
            elseif ($appName -eq 'office') {
                $wordPaths = Get-RegistryKeyValues -KeyName 'PE-SOFT' -SubKey 'Microsoft\Windows\CurrentVersion\App Paths\WINWORD.EXE'
                Assert-ReadBack -Condition ($null -ne $wordPaths) -Message 'read-back: PE-SOFT App Paths\WINWORD.EXE is missing'
                Assert-ReadBack -Condition ($wordPaths['(Default)'] -eq 'X:\Program Files\Office2016\Office16\WINWORD.EXE') -Message "read-back: WINWORD.EXE App Paths is '$($wordPaths['(Default)'])', expected the Office2016 path"
                $docxAssoc = Get-RegistryKeyValues -KeyName 'PE-SOFT' -SubKey 'Classes\.docx'
                Assert-ReadBack -Condition ($null -ne $docxAssoc) -Message 'read-back: PE-SOFT Classes\.docx is missing'
                Assert-ReadBack -Condition ($docxAssoc['(Default)'] -eq 'Word.Document.12') -Message "read-back: .docx is '$($docxAssoc['(Default)'])', expected Word.Document.12"
            }
            else {
                Write-Warn "read-back: no registry assertions defined for app '$appName'; its .reg import was verified by reg.exe exit code only"
            }
        }

        if ($script:readBackFailures -gt 0) {
            Write-Warn "registry read-back: $($script:readBackFailures) check(s) failed (warnings only, build continues to QEMU); review the !!! lines above"
        }
        else {
            Write-SubStep 'registry read-back: boot chain, author, StartAllBack loader, Start11 image all landed'
        }
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
$catFix = Invoke-CleanCatFixStep -StagingDir $paths.Staging -WorkDir (Join-Path $paths.Logs 'catfix')
Invoke-CleanShellStep
$apps = Invoke-CleanAppStep
Invoke-CleanRegistryStep -AppRegFiles $apps.RegFiles
Assert-CleanRegistry -AppNames $apps.Names
Invoke-CleanWimBootStep -StagingDir $paths.Staging -PeDonorWim $base.BootWim -WimlibPath $WimlibPath
Assert-BootCritical -ImageRoot $paths.Staging
$capturedBootWim = Invoke-CleanCaptureStep
Assert-CleanCatFilesInBootWim -BootWim $capturedBootWim -ExpectedCats $catFix.ExpectedCats -WimlibPath $WimlibPath
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
        "| File list | ``$fileListPath`` (final, no hash diff) |"
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
