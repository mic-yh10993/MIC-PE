#Requires -Version 7.0
<#
.SYNOPSIS
    Payload packages: stage, verify, expand and inject the three payloads.

.DESCRIPTION
    MICPE ships three payload packages, all committed in the repo under
    app/ (user decision 2026-11-17 15:07 — no Release downloads anymore):

        payload  app/payload/micpe-payload.7z        -> Program Files (portable tools)
        chrome   app/chrome/chrome-slim.7z.001/.002  -> Program Files\Google\Chrome
        office   app/office/office2016-slim.7z.001/.002 -> Program Files\Office2016

    Chrome and Office are >100 MB joined, so they are stored as 95 MB
    volumes (GitHub's single-file limit is 100 MB); the build joins the
    volumes and verifies the SHA-256 of the JOINED archive. Every pin
    below is the joined-archive hash, never a single volume's.

    chrome-slim.7z: from the Chrome Enterprise MSI (offline installer),
      Locales pruned to en-US + zh-CN, WidevineCdm (DRM plugin) removed.
    office2016-slim.7z: Office 2016, Access removed (MSACCESS.EXE and
      friends), the vendor's install/uninstall scripts removed.
      Office self-activates per machine, so there is no key to inject.

    The three payload-* Releases (payload-v1, chrome-v1, office-v1) were
    deleted once the app/ versions passed CI; nothing here may download
    them again, and there is exactly one source per package: the app/ tree.

    PECMD.EXE supply (decided M5, design.md §6.5): the runtime is the DSI
    copy (DSI-安装备份-源码/make/PECMD.EXE, SHA-256 pinned in
    docs/payload.md), shipped inside micpe-payload.7z at
    ProgramFiles\MICPE\PECMD.EXE — the path startnet.cmd expects. It is
    third-party freeware: never committed to git, never covered by GPL.
    Do NOT use the GhostCGI copy (GhostCGI/pecmd.exe): it is a different,
    older binary bundled with that tool. The payload build fails loudly
    when PECMD.EXE is missing; a silent skip once let a payload ship
    without it, and the image only fell back to cmd at boot time.

    Chrome/Office integration runs through app/chrome/install.bat and
    app/office/install.bat (user decision 2026-11-17: install.bat runs in
    CI, never inside PE). This file only stages the asset next to the bat
    and invokes it; the .bat holds the component-specific commands
    (7z x for both Chrome and Office).

    // reuse-check: function names, tags and asset names are plan T13
    verbatim. The install/assert split follows the M2/M3/M4 pattern
    (mount -> install -> assert -> commit -> size gate in Build-Micpe.ps1).
#>

# app/ layout: directory per package, joined-archive name, volume names
# (in join order). payload fits in one file, so its single "volume" is
# the archive itself.
$script:AppPackageDir = @{
    payload = 'payload'
    chrome  = 'chrome'
    office  = 'office'
}

$script:AppPackageArchive = @{
    payload = 'micpe-payload.7z'
    chrome  = 'chrome-slim.7z'
    office  = 'office2016-slim.7z'
}

$script:AppPackageVolumes = @{
    payload = @('micpe-payload.7z')
    chrome  = @('chrome-slim.7z.001', 'chrome-slim.7z.002')
    office  = @('office2016-slim.7z.001', 'office2016-slim.7z.002')
}

# SHA-256 pins of the JOINED archives, verified 2026-11-18:
#   micpe-payload.7z      built from the 112-file payload tree + the DSI
#                         PECMD.EXE (see New-PayloadArchive); 28,564,811 B
#   chrome-slim.7z        Chrome 151.0.7922.138, slimmed; 125,367,407 B
#   office2016-slim.7z    Office 2016, Access removed; 167,504,937 B
# A rebuild must reproduce the pin (same 7z version, same file
# timestamps); if it does not, update the pin here in the same commit
# as the re-split.
$script:PayloadHashes = @{
    payload = 'c95737c250d34244a548d12c983f8c73aa479271d4889201429fac5c9960319e'
    chrome  = 'df82dc28b2e0615656dae8b362eab15dd0d8efea7941a78a5e79d0f1a95ca626'
    office  = '8a5ec5d7d8b77303029769f2f9e043b5f6c98e0cdd7cf5d6b56dc8e2ef6301f7'
}

# DSI copy of PECMD.EXE (1,077,760 bytes, 2024-06-06). It travels inside
# micpe-payload.7z, so there is no separate download; the hash is pinned
# here so a future rebuild can prove it is still the same binary.
$script:PecmdHash = '7a3710297473cbb865408d41db362e6014fd3eeaaf819751495e6d928e7adf5e'

function Get-AppPackageArchiveName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if (-not $script:AppPackageArchive.ContainsKey($Name)) {
        throw [System.InvalidOperationException]::new(
            "unknown payload package: $Name (expected payload|chrome|office)")
    }

    return $script:AppPackageArchive[$Name]
}

function Get-AppPackageVolumePaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $RepoRoot
    )

    if (-not $script:AppPackageDir.ContainsKey($Name)) {
        throw [System.InvalidOperationException]::new(
            "unknown payload package: $Name (expected payload|chrome|office)")
    }

    $dir = Join-Path (Join-Path $RepoRoot 'app') $script:AppPackageDir[$Name]
    # The unary comma keeps a single-volume package an array: without it
    # PowerShell unwraps the one element to a bare string, and callers
    # reading .Count / [0] break.
    return , @($script:AppPackageVolumes[$Name] | ForEach-Object { Join-Path $dir $_ })
}

function Join-AppPackageVolumes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Volumes,

        [Parameter(Mandatory = $true)]
        [string] $OutFile
    )

    # Byte-exact concatenation, in order, via streams (no whole-file
    # buffering: the joined archives are 125-167 MB). Works on Windows
    # and Linux alike, so the unit tests can run it locally.
    $out = [System.IO.File]::Create($OutFile)
    try {
        foreach ($volume in $Volumes) {
            Assert-PathExists -Path $volume -Label 'package volume'
            $in = [System.IO.File]::OpenRead($volume)
            try { $in.CopyTo($out) } finally { $in.Dispose() }
        }
    }
    finally { $out.Dispose() }
}

function Get-AppPackageArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $RepoRoot,

        [Parameter(Mandatory = $true)]
        [string] $StagingDir
    )

    $archive = Get-AppPackageArchiveName -Name $Name
    $expected = Get-PayloadExpectedHash -Name $Name
    $volumes = Get-AppPackageVolumePaths -Name $Name -RepoRoot $RepoRoot

    if (-not (Test-Path -LiteralPath $StagingDir)) {
        New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
    }

    $file = Join-Path $StagingDir $archive
    if ($volumes.Count -eq 1 -and $volumes[0] -eq (Join-Path (Join-Path (Join-Path $RepoRoot 'app') $script:AppPackageDir[$Name]) $archive)) {
        # Single-volume package: the committed file IS the archive.
        Copy-Item -LiteralPath $volumes[0] -Destination $file -Force
    }
    else {
        Write-Step "joining $($volumes.Count) volumes for $archive"
        Join-AppPackageVolumes -Volumes $volumes -OutFile $file
    }

    Assert-PathExists -Path $file -Label "staged $archive"
    if (-not (Test-PayloadFileHash -Path $file -ExpectedHash $expected)) {
        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower()
        throw [System.InvalidOperationException]::new(
            "payload archive hash mismatch for $Name ($archive): expected $expected, got $actual. " +
            "Do not ship it: re-split the archive and update the pin in Payload.ps1 in the same commit.")
    }

    Write-SubStep "$archive staged and verified"
    return $file
}

function Get-PayloadExpectedHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if (-not $script:PayloadHashes.ContainsKey($Name)) {
        throw [System.InvalidOperationException]::new(
            "unknown payload package: $Name (expected payload|chrome|office)")
    }

    return $script:PayloadHashes[$Name]
}

function Test-PayloadFileHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $ExpectedHash
    )

    Assert-PathExists -Path $Path -Label 'payload asset'
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
    return ($actual -eq $ExpectedHash.ToLower())
}



function New-PayloadArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $PayloadTreeDir,

        [Parameter(Mandatory = $true)]
        [string] $PecmdExe,

        [Parameter(Mandatory = $true)]
        [string] $OutArchive
    )

    Assert-PathExists -Path $PayloadTreeDir -Label 'payload tree directory'
    # Fail loudly, never silently skip: a payload without PECMD.EXE only
    # shows up at boot time, when the image falls back to cmd.
    Assert-PathExists -Path $PecmdExe -Label 'PECMD.EXE (DSI copy)'

    $staging = Join-Path ([System.IO.Path]::GetTempPath()) "micpe-payload-$(Get-Random)"
    try {
        $programFiles = Join-Path $staging 'ProgramFiles'
        Copy-Item -LiteralPath $PayloadTreeDir -Destination $programFiles -Recurse -Force
        Assert-PathExists -Path (Join-Path $programFiles '7-zip/7z.exe') -Label 'payload tree 7-zip/7z.exe'

        $micpeDir = Join-Path $programFiles 'MICPE'
        if (-not (Test-Path -LiteralPath $micpeDir)) {
            New-Item -ItemType Directory -Path $micpeDir -Force | Out-Null
        }
        $pecmdDest = Join-Path $micpeDir 'PECMD.EXE'
        Copy-Item -LiteralPath $PecmdExe -Destination $pecmdDest -Force

        # Preserve timestamps so a rebuild reproduces the pinned hash:
        # Copy-Item resets them, and 7z stores them in the archive.
        $sourceRoot = (Get-Item -LiteralPath $PayloadTreeDir).FullName
        foreach ($entry in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force)) {
            $relative = $entry.FullName.Substring($sourceRoot.Length).TrimStart(
                [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            $dest = Join-Path $programFiles $relative
            if (Test-Path -LiteralPath $dest) {
                (Get-Item -LiteralPath $dest).LastWriteTime = $entry.LastWriteTime
            }
        }
        (Get-Item -LiteralPath $programFiles).LastWriteTime = (Get-Item -LiteralPath $sourceRoot).LastWriteTime
        (Get-Item -LiteralPath $pecmdDest).LastWriteTime = (Get-Item -LiteralPath $PecmdExe).LastWriteTime

        Write-Step "building $OutArchive"
        Push-Location $staging
        try {
            $null = & 7z a -mx=5 $OutArchive ProgramFiles 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw [System.InvalidOperationException]::new(
                    "7z failed with exit code $LASTEXITCODE while building $OutArchive")
            }
        }
        finally {
            Pop-Location
        }

        Assert-PathExists -Path $OutArchive -Label 'built micpe-payload.7z'
        $hash = (Get-FileHash -LiteralPath $OutArchive -Algorithm SHA256).Hash.ToLower()
        Write-SubStep "micpe-payload.7z built, SHA256 $hash"
        return [pscustomobject]@{ Path = $OutArchive; Sha256 = $hash }
    }
    finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Expand-Payload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Archive,

        [Parameter(Mandatory = $true)]
        [string] $Destination
    )

    Assert-PathExists -Path $Archive -Label 'payload archive'
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    $null = & 7z x $Archive "-o$Destination" -y 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new(
            "7z failed with exit code $LASTEXITCODE while expanding $Archive")
    }

    $missing = @()
    foreach ($rel in 'ProgramFiles/7-zip/7z.exe', 'ProgramFiles/MICPE/PENetwork/PENetwork.exe') {
        if (-not (Test-Path -LiteralPath (Join-Path $Destination $rel))) { $missing += $rel }
    }
    if ($missing.Count -gt 0) {
        throw [System.InvalidOperationException]::new(
            "expanded payload is incomplete. Missing:`n  " + ($missing -join "`n  "))
    }

    Write-SubStep 'payload archive expanded and verified'
}

function Get-ComponentInstallBatPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Component,

        [Parameter(Mandatory = $true)]
        [string] $RepoRoot
    )

    if ($Component -notin 'chrome', 'office') {
        throw [System.InvalidOperationException]::new(
            "unknown component: $Component (expected chrome|office)")
    }

    return (Join-Path $RepoRoot "app/$Component/install.bat")
}

function Invoke-ComponentInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Component,

        [Parameter(Mandatory = $true)]
        [string] $MountDir,

        [Parameter(Mandatory = $true)]
        [string] $RepoRoot,

        [Parameter(Mandatory = $true)]
        [string] $AssetPath,

        [scriptblock] $Runner = $null
    )

    if ($Component -notin 'chrome', 'office') {
        throw [System.InvalidOperationException]::new(
            "unknown component: $Component (expected chrome|office)")
    }
    Assert-PathExists -Path $AssetPath -Label "$Component asset"
    Assert-PathExists -Path $MountDir -Label 'boot.wim mount'
    $bat = Get-ComponentInstallBatPath -Component $Component -RepoRoot $RepoRoot
    Assert-PathExists -Path $bat -Label 'component install.bat'

    # The bat runs outside the build process and cannot take the asset
    # path: by convention it reads its own files from its own folder, so
    # the asset is staged next to it first. *.msi/*.7z are git-ignored,
    # so this staging never pollutes the repo.
    if ($null -eq $Runner -and -not $IsWindows) {
        throw [System.InvalidOperationException]::new(
            "component install.bat requires Windows (cmd.exe); cannot run $bat on this host")
    }
    $componentDir = Split-Path -Parent $bat
    Copy-Item -LiteralPath $AssetPath -Destination $componentDir -Force
    Write-SubStep "$Component asset staged next to install.bat"

    if ($null -ne $Runner) {
        # Test seam only: the runner throws on failure.
        & $Runner $bat $MountDir $RepoRoot
        return
    }

    $output = & cmd.exe /c "`"$bat`" `"$MountDir`" `"$RepoRoot`"" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        $detail = if ($output) { $output.Trim() } else { '(install.bat printed nothing)' }
        throw [System.InvalidOperationException]::new(
            "install.bat failed with exit code $LASTEXITCODE for $Component : $detail")
    }

    Write-SubStep "$Component installed"
}

function Install-Payload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir,

        [Parameter(Mandatory = $true)]
        [string] $PayloadDir,

        [switch] $Chrome,

        [switch] $Office,

        [string] $RepoRoot = '',

        [scriptblock] $ComponentRunner = $null
    )

    Assert-PathExists -Path $MountDir -Label 'boot.wim mount'
    Assert-PathExists -Path $PayloadDir -Label 'payload staging'
    $source = Join-Path $PayloadDir 'ProgramFiles'
    Assert-PathExists -Path $source -Label 'expanded payload ProgramFiles'

    $dest = Join-Path $MountDir 'Program Files'
    # The destination must exist as a directory before the copy: when it
    # does not, Copy-Item copies the first wildcard hit onto the path
    # itself, and a file hit turns the destination into a file — the next
    # directory hit then fails with "Container cannot be copied onto
    # existing leaf item".
    if (-not (Test-Path -LiteralPath $dest)) {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
    }
    Copy-Item -Path (Join-Path $source '*') -Destination $dest -Recurse -Force
    Write-SubStep 'payload ProgramFiles copied'

    # Chrome/Office extraction lives in the component install.bat files
    # (user decision 2026-11-17: install.bat runs in CI, never inside PE);
    # this function only stages the asset and invokes the bat.
    if ($Chrome) {
        if (-not $RepoRoot) {
            throw [System.InvalidOperationException]::new(
                'Install-Payload -Chrome requires -RepoRoot (the app/chrome/install.bat location)')
        }
        $archive = Join-Path $PayloadDir 'chrome-slim.7z'
        Invoke-ComponentInstall -Component 'chrome' -MountDir $MountDir `
            -RepoRoot $RepoRoot -AssetPath $archive -Runner $ComponentRunner
    }
    if ($Office) {
        if (-not $RepoRoot) {
            throw [System.InvalidOperationException]::new(
                'Install-Payload -Office requires -RepoRoot (the app/office/install.bat location)')
        }
        $archive = Join-Path $PayloadDir 'office2016-slim.7z'
        Invoke-ComponentInstall -Component 'office' -MountDir $MountDir `
            -RepoRoot $RepoRoot -AssetPath $archive -Runner $ComponentRunner
    }
}

function Assert-PayloadInstalled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir,

        [switch] $Chrome,

        [switch] $Office
    )

    $missing = [System.Collections.Generic.List[string]]::new()

    # The four items probe.cmd checks for payload=1, plus PECMD.EXE,
    # which M5 supplies and startnet.cmd depends on.
    #
    # NOT asserted here: Program Files\MICPE\MICPE-Setup\MICPE-Setup.wcs.
    # The plan interface lists it, but no .wcs file exists anywhere in the
    # recovered materials — MICPE-Setup is the user's own installer, authored
    # in M6 — and probe.cmd does not check it either. M6 asserts it when
    # the installer exists; asserting it here could never pass.
    foreach ($rel in 'Program Files/7-zip/7z.exe',
                    'Program Files/MICPE/PENetwork/PENetwork.exe',
                    'Program Files/MICPE/PECMD.EXE',
                    'Program Files/DiskGenius.exe',
                    'Program Files/WinNTSetup/unattend/Win10_x64.xml') {
        if (-not (Test-Path -LiteralPath (Join-Path $MountDir $rel))) {
            $missing.Add($rel)
        }
    }

    if ($Chrome) {
        # Chrome is a 7z extract now (no msiexec), and the version dir
        # under Application varies by release, so search recursively
        # instead of pinning one subpath.
        $chromeDir = Join-Path $MountDir 'Program Files/Google/Chrome'
        $exe = @()
        if (Test-Path -LiteralPath $chromeDir) {
            $exe = @(Get-ChildItem -LiteralPath $chromeDir -Filter 'chrome.exe' -Recurse -File -ErrorAction SilentlyContinue)
        }
        if ($exe.Count -eq 0) {
            $missing.Add('Program Files/Google/Chrome/**/chrome.exe')
        }
        # Slimming assertions (packaging round): the archive must already
        # be slimmed — pruning happens at package time, not here.
        if (Test-Path -LiteralPath $chromeDir) {
            $widevine = @(Get-ChildItem -LiteralPath $chromeDir -Directory -Recurse -Filter 'WidevineCdm' -ErrorAction SilentlyContinue)
            if ($widevine.Count -gt 0) {
                $missing.Add('Chrome not slimmed: WidevineCdm present')
            }
            $localeDirs = @(Get-ChildItem -LiteralPath $chromeDir -Directory -Recurse -Filter 'Locales' -ErrorAction SilentlyContinue)
            foreach ($localeDir in $localeDirs) {
                $extra = @(Get-ChildItem -LiteralPath $localeDir.FullName -Filter '*.pak' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notmatch '^(en-US|zh-CN)' })
                if ($extra.Count -gt 0) {
                    $missing.Add("Chrome not slimmed: extra locale $($extra[0].Name)")
                }
            }
        }
    }

    if ($Office) {
        if (-not (Test-Path -LiteralPath (Join-Path $MountDir 'Program Files/Office2016/Office16/WINWORD.EXE'))) {
            $missing.Add('Program Files/Office2016/Office16/WINWORD.EXE')
        }
        # Slimming assertions (packaging round): Access and the vendor's
        # install/uninstall scripts must be gone.
        $officeDir = Join-Path $MountDir 'Program Files/Office2016'
        if (Test-Path -LiteralPath (Join-Path $officeDir 'Office16/MSACCESS.EXE')) {
            $missing.Add('Office not slimmed: MSACCESS.EXE present')
        }
        foreach ($vendorScript in '!)inst.cmd', '-)unist.cmd') {
            if (Test-Path -LiteralPath (Join-Path $officeDir $vendorScript)) {
                $missing.Add("Office not slimmed: vendor script $vendorScript present")
            }
        }
    }

    if ($missing.Count -gt 0) {
        throw [System.InvalidOperationException]::new(
            "Payload is incomplete. Missing:`n  " + ($missing -join "`n  "))
    }

    Write-SubStep 'payload artifacts verified'
}
