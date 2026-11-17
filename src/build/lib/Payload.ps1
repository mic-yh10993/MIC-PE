#Requires -Version 7.0
<#
.SYNOPSIS
    Payload packages: download, verify, expand and inject the three payloads.

.DESCRIPTION
    MICPE ships three independently released payloads (one GitHub Release
    each, downloaded only when the matching switch is on):

        payload  micpe-payload.7z            -> Program Files (portable tools)
        chrome   chrome-enterprise-x64.msi   -> Program Files\Google\Chrome
        office   office2016-green.7z         -> Program Files\Office2016

    Every asset is SHA-256 pinned below. The hashes were computed from the
    recovered reference materials (see docs/payload.md) and the download
    fails closed on mismatch: a republished asset must update its pin in
    the same commit, never silently.

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
    (msiexec /a for Chrome, 7z x for Office).

    // reuse-check: function names, tags and asset names are plan T13
    verbatim. The install/assert split follows the M2/M3/M4 pattern
    (mount -> install -> assert -> commit -> size gate in Build-Micpe.ps1).
#>

$script:PayloadReleases = @{
    payload = 'payload-v1'
    chrome  = 'chrome-v1'
    office  = 'office-v1'
}

$script:PayloadAssets = @{
    payload = 'micpe-payload.7z'
    chrome  = 'chrome-enterprise-x64.msi'
    office  = 'office2016-green.7z'
}

# SHA-256 pins, verified 2026-11-17 from the recovered materials:
#   micpe-payload.7z      built from the 112-file payload tree + the DSI
#                         PECMD.EXE (see New-PayloadArchive); 28,564,811 B
#   chrome-enterprise-x64.msi  Google Chrome 151.0.7922.138, 164,831,232 B
#   office2016-green.7z   Office 2016 green, 170,364,185 B
# A rebuild must reproduce the micpe-payload.7z hash (same 7z version,
# same file timestamps — New-PayloadArchive preserves them); if it does
# not, update the pin here in the same commit as the republish.
$script:PayloadHashes = @{
    payload = 'c95737c250d34244a548d12c983f8c73aa479271d4889201429fac5c9960319e'
    chrome  = '0ec77319d917eb232f1b1b52e0f6f6178eacb2d5abff1517f5c17d50a0a2db1a'
    office  = '8bb9a924b72e5d70968121d1ed88df8bea74823e4f8aed1598d766b2a3cb7caf'
}

$script:PayloadRepo = 'mic-yh10993/MIC-PE'

# DSI copy of PECMD.EXE (1,077,760 bytes, 2024-06-06). It travels inside
# micpe-payload.7z, so there is no separate download; the hash is pinned
# here so a future rebuild can prove it is still the same binary.
$script:PecmdHash = '7a3710297473cbb865408d41db362e6014fd3eeaaf819751495e6d928e7adf5e'

function Get-PayloadRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if (-not $script:PayloadReleases.ContainsKey($Name)) {
        throw [System.InvalidOperationException]::new(
            "unknown payload package: $Name (expected payload|chrome|office)")
    }

    return $script:PayloadReleases[$Name]
}

function Get-PayloadAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if (-not $script:PayloadAssets.ContainsKey($Name)) {
        throw [System.InvalidOperationException]::new(
            "unknown payload package: $Name (expected payload|chrome|office)")
    }

    return $script:PayloadAssets[$Name]
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

function Get-PayloadReleaseAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $StagingDir,

        [string] $Repo = $script:PayloadRepo
    )

    $tag = Get-PayloadRelease -Name $Name
    $asset = Get-PayloadAsset -Name $Name
    $expected = Get-PayloadExpectedHash -Name $Name

    if (-not (Test-Path -LiteralPath $StagingDir)) {
        New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
    }

    $gh = Get-Command 'gh' -ErrorAction SilentlyContinue
    if ($null -eq $gh) {
        throw [System.InvalidOperationException]::new(
            "gh CLI is required to download payload release $tag, but it was not found on PATH")
    }

    Write-Step "downloading $asset from release $tag"
    $output = & gh release download $tag --pattern $asset --repo $Repo --dir $StagingDir --clobber 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        $detail = if ($output) { $output.Trim() } else { '(gh printed nothing)' }
        throw [System.InvalidOperationException]::new(
            "failed to download $asset from release $tag ($Repo). " +
            "Publish the payload releases first — see docs/payload.md. gh said: $detail")
    }

    $file = Join-Path $StagingDir $asset
    Assert-PathExists -Path $file -Label "downloaded $asset"
    if (-not (Test-PayloadFileHash -Path $file -ExpectedHash $expected)) {
        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower()
        throw [System.InvalidOperationException]::new(
            "payload asset hash mismatch for $Name ($asset): expected $expected, got $actual. " +
            "Do not ship it: republish the release and update the pin in Payload.ps1 in the same commit.")
    }

    Write-SubStep "$asset downloaded and verified"
    return $file
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
        $msi = Join-Path $PayloadDir 'chrome-enterprise-x64.msi'
        Invoke-ComponentInstall -Component 'chrome' -MountDir $MountDir `
            -RepoRoot $RepoRoot -AssetPath $msi -Runner $ComponentRunner
    }
    if ($Office) {
        if (-not $RepoRoot) {
            throw [System.InvalidOperationException]::new(
                'Install-Payload -Office requires -RepoRoot (the app/office/install.bat location)')
        }
        $archive = Join-Path $PayloadDir 'office2016-green.7z'
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
        # msiexec /a layout is unverified on Windows (no real MSI run yet),
        # so search recursively instead of pinning one subpath.
        $chromeDir = Join-Path $MountDir 'Program Files/Google/Chrome'
        $exe = @()
        if (Test-Path -LiteralPath $chromeDir) {
            $exe = @(Get-ChildItem -LiteralPath $chromeDir -Filter 'chrome.exe' -Recurse -File -ErrorAction SilentlyContinue)
        }
        if ($exe.Count -eq 0) {
            $missing.Add('Program Files/Google/Chrome/**/chrome.exe')
        }
    }

    if ($Office) {
        if (-not (Test-Path -LiteralPath (Join-Path $MountDir 'Program Files/Office2016/Office16/WINWORD.EXE'))) {
            $missing.Add('Program Files/Office2016/Office16/WINWORD.EXE')
        }
    }

    if ($missing.Count -gt 0) {
        throw [System.InvalidOperationException]::new(
            "Payload is incomplete. Missing:`n  " + ($missing -join "`n  "))
    }

    Write-SubStep 'payload artifacts verified'
}
