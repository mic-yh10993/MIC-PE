#Requires -Version 7.0
<#
.SYNOPSIS
    Resolve a UUP dump build, download its conversion package, and extract the
    install.wim / boot.wim pair from the produced ISO.

.DESCRIPTION
    UUP dump publishes two things the build needs: a "build" identity (uuid) and a
    downloadable package that contains ConvertConfig.ini plus a downloader script.
    The package is generated server-side per architecture and language, so the
    uuid must be resolved first.

    Everything that talks to the network accepts an -Invoke override so the
    functions can be tested without network access.
#>

$script:UupApiBase = 'https://api.uupdump.net'

function Invoke-UupApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Url,

        [scriptblock] $Invoke
    )

    if ($Invoke) {
        return & $Invoke $Url
    }
    return Invoke-RestMethod -Uri $Url -TimeoutSec 120
}

function Get-UupBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Build,

        [ValidateSet('amd64')]
        [string] $Arch = 'amd64',

        [ValidateSet('insider', 'stable')]
        [string] $Channel = 'stable',

        [string] $Lang = 'zh-cn',

        [string] $ApiBase = $script:UupApiBase,

        [scriptblock] $Invoke
    )

    $url = "$ApiBase/listid.php?search=$([uri]::EscapeDataString($Build))"
    $response = Invoke-UupApi -Url $url -Invoke $Invoke

    $builds = $null
    if ($response -is [hashtable]) {
        if ($response.ContainsKey('response') -and $response.response -is [hashtable]) {
            $builds = $response.response['builds']
        }
    }
    elseif ($response.response) {
        $builds = $response.response.builds
    }

    if (-not $builds) {
        throw [System.InvalidOperationException]::new(
            "UUP dump returned no builds for '$Build'. Request URL: $url")
    }

    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($key in @($builds.Keys)) {
        $entry = $builds[$key]

        if ($entry.arch -ne $Arch) { continue }

        $title = [string] $entry.title
        if ($title -notmatch 'Windows 11') { continue }
        if ($Channel -eq 'stable' -and $title -match 'Insider') { continue }
        if ($Channel -eq 'insider' -and $title -notmatch 'Insider') { continue }

        $candidates.Add([pscustomobject]@{
            Uuid  = $entry.uuid
            Build = $entry.build
            Title = $title
        })
    }

    if ($candidates.Count -eq 0) {
        throw [System.InvalidOperationException]::new(
            "No $Arch Windows 11 $Channel build matched '$Build'. Request URL: $url")
    }

    $picked = $candidates | Sort-Object -Property Build -Descending | Select-Object -First 1
    Write-SubStep ("UUP build: {0} ({1})" -f $picked.Build, $picked.Title)
    return $picked
}

function Set-ConvertConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $IniPath,

        [Parameter(Mandatory = $true)]
        [hashtable] $Overrides
    )

    Assert-PathExists -Path $IniPath -Label 'ConvertConfig.ini'

    $lines = Get-Content -LiteralPath $IniPath
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $output = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $lines) {
        if ($line -match '^\s*[#;]' -or $line -notmatch '=') {
            $output.Add($line)
            continue
        }

        $key = ($line -split '=', 2)[0]
        $normalized = $key.Trim()

        if ($Overrides.ContainsKey($normalized)) {
            $output.Add("$normalized=$($Overrides[$normalized])")
            $null = $seen.Add($normalized)
        }
        else {
            $output.Add($line)
        }
    }

    $section = '[Convert]'
    foreach ($key in $Overrides.Keys) {
        if ($seen.Contains($key)) { continue }
        if (-not ($output -contains $section)) {
            $output.Add($section)
        }
        $output.Add("$key=$($Overrides[$key])")
    }

    return ($output -join [Environment]::NewLine)
}

function New-UupDownloadPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uuid,

        [Parameter(Mandatory = $true)]
        [string] $OutDir,

        [string] $Lang = 'zh-cn',

        [string] $Edition = 'professional',

        [string] $ApiBase = $script:UupApiBase
    )

    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }

    $url = "$ApiBase/get.php?id=$Uuid&lang=$Lang&edition=$Edition"
    $zip = Join-Path $OutDir 'uup-package.zip'

    Write-SubStep "downloading UUP package for $Uuid"
    Invoke-WebRequest -Uri $url -OutFile $zip -TimeoutSec 300

    $extractDir = Join-Path $OutDir 'package'
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $extractDir -Force

    $downloader = Join-Path $extractDir 'uup_download_windows.cmd'
    Assert-True -Condition (Test-Path -LiteralPath $downloader) -Message (
        "UUP package did not contain uup_download_windows.cmd. The API may have returned an error page. URL: $url")

    return $extractDir
}

function Get-BaseWims {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $IsoPath,

        [Parameter(Mandatory = $true)]
        [string] $OutDir,

        [string] $SevenZip = '7z'
    )

    Assert-PathExists -Path $IsoPath -Label 'ISO'

    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }

    foreach ($name in 'install.wim', 'boot.wim') {
        Write-SubStep "extracting sources/$name"
        & $SevenZip e $IsoPath "sources/$name" "-o$OutDir" -y | Out-Host
        Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "7z failed to extract sources/$name from $IsoPath"
    }

    $install = Join-Path $OutDir 'install.wim'
    $boot = Join-Path $OutDir 'boot.wim'
    Assert-PathExists -Path $install -Label 'install.wim'
    Assert-PathExists -Path $boot -Label 'boot.wim'

    return [pscustomobject]@{
        InstallWim = $install
        BootWim    = $boot
    }
}
