#Requires -Version 7.0
<#
.SYNOPSIS
    Installer step for the MICPE build (M6): copy the installer into the image.

.DESCRIPTION
    Copies src/installer/* into Program Files\MICPE\MICPE-Setup\ inside the
    mounted boot.wim: the WCS wizard, its .ini, the lang strings, and the
    PowerShell discovery/deploy functions the wizard calls for its space
    check (CheckTarget dot-sources Deploy.ps1 when PowerShell exists in PE).

    # reuse-check: the mount -> install -> assert -> commit -> size-gate
    # shape is copied from Invoke-BrandStep; the copy-then-assert split
    # copies Invoke-PayloadStep / Assert-PayloadInstalled.
#>

function Install-Installer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir,

        [Parameter(Mandatory = $true)]
        [string] $RepoRoot
    )

    Assert-PathExists -Path $MountDir -Label 'boot.wim mount'
    $source = Join-Path $RepoRoot 'src/installer'
    Assert-PathExists -Path $source -Label 'installer sources'

    # The destination must exist as a directory before the copy (M5 lesson:
    # Copy-Item onto a missing path turns the first file hit into the
    # destination itself).
    $dest = Join-Path $MountDir 'Program Files/MICPE/MICPE-Setup'
    if (-not (Test-Path -LiteralPath $dest)) {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
    }

    foreach ($rel in 'MICPE-Setup.wcs', 'MICPE-Setup.ini', 'Deploy.ps1', 'Discover.ps1') {
        $file = Join-Path $source $rel
        Assert-PathExists -Path $file -Label "installer file $rel"
        Copy-Item -LiteralPath $file -Destination $dest -Force
    }

    $langDest = Join-Path $dest 'lang'
    if (-not (Test-Path -LiteralPath $langDest)) {
        New-Item -ItemType Directory -Path $langDest -Force | Out-Null
    }
    $langFile = Join-Path $source 'lang/zh-CN.txt'
    Assert-PathExists -Path $langFile -Label 'installer lang file'
    Copy-Item -LiteralPath $langFile -Destination $langDest -Force

    Write-SubStep 'installer files installed'
}

function Assert-InstallerInstalled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir
    )

    # This is the assert M5 deliberately left out: Payload.ps1 notes that
    # MICPE-Setup.wcs did not exist anywhere in the recovered materials,
    # so asserting it there could never pass. Now that M6 authors it,
    # the installer step asserts it here.
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($rel in 'Program Files/MICPE/MICPE-Setup/MICPE-Setup.wcs',
                    'Program Files/MICPE/MICPE-Setup/MICPE-Setup.ini',
                    'Program Files/MICPE/MICPE-Setup/Deploy.ps1',
                    'Program Files/MICPE/MICPE-Setup/Discover.ps1',
                    'Program Files/MICPE/MICPE-Setup/lang/zh-CN.txt') {
        if (-not (Test-Path -LiteralPath (Join-Path $MountDir $rel))) {
            $missing.Add($rel)
        }
    }

    if ($missing.Count -gt 0) {
        throw [System.InvalidOperationException]::new(
            ("installer files missing from the image: {0}" -f ($missing -join ', ')))
    }

    Write-SubStep 'installer files present'
}
