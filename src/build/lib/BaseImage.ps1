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

# SHA256 of the aria2c.exe we trust, pinned in three places that must agree:
# the pre-seed in Build-Micpe.ps1, the default of src/build/uup/get_aria2.ps1,
# and this constant. The tests assert all three match.
$script:Aria2ExpectedHash = 'b9cd71b275af11b63c33457b0f43f2f2675937070c563e195f223efd7fa4c74b'

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

    # Both hashtable (tests) and PSCustomObject (Invoke-RestMethod) shapes occur.
    $body = if ($response -is [System.Collections.IDictionary]) { $response['response'] } else { $response.response }
    $builds = if ($body) {
        if ($body -is [System.Collections.IDictionary]) { $body['builds'] } else { $body.builds }
    } else { $null }

    if (-not $builds) {
        throw [System.InvalidOperationException]::new(
            "UUP dump returned no builds for '$Build'. Request URL: $url")
    }

    # Invoke-RestMethod turns the JSON object into a PSCustomObject, while the
    # test fixtures use hashtables. Normalize both to a list of entries.
    $entries = if ($builds -is [System.Collections.IDictionary]) {
        foreach ($key in @($builds.Keys)) { $builds[$key] }
    }
    else {
        foreach ($property in $builds.PSObject.Properties) { $property.Value }
    }

    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $entries) {
        if ($null -eq $entry) { continue }
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

    # Compare numerically: "26200.10066" must outrank "26200.9974", which string
    # ordering would get backwards.
    $picked = $candidates |
        Sort-Object -Property @{ Expression = { [version] ($_.Build -replace '[^0-9.]', '') } } -Descending |
        Select-Object -First 1
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

    # The ini is sectioned ([convert-UUP], [Store_Apps], ...) and pads keys before
    # the '='. Keys are matched across the whole file; a key that does not exist
    # yet is inserted into the first section so it is never appended after the
    # last stanza where the converter would ignore it.
    $lines = Get-Content -LiteralPath $IniPath
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $output = [System.Collections.Generic.List[string]]::new()
    $firstSectionIndex = -1
    $pending = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $lines) {
        if ($line -match '^\s*[#;]') {
            $output.Add($line)
            continue
        }

        if ($line -match '^\s*\[[^\]]+\]\s*$') {
            if ($pending.Count -gt 0) {
                foreach ($item in $pending) { $output.Add($item) }
                $pending.Clear()
            }
            $output.Add($line)
            if ($firstSectionIndex -lt 0) { $firstSectionIndex = $output.Count - 1 }
            continue
        }

        if ($line -notmatch '=') {
            $output.Add($line)
            continue
        }

        $key = ($line -split '=', 2)[0].Trim()
        if ($Overrides.ContainsKey($key)) {
            $output.Add(("{0,-12}= {1}" -f $key, $Overrides[$key]))
            $null = $seen.Add($key)
        }
        else {
            $output.Add($line)
        }
    }

    $missing = @($Overrides.Keys | Where-Object { -not $seen.Contains($_) } | Sort-Object)
    if ($missing.Count -gt 0) {
        Assert-True -Condition ($firstSectionIndex -ge 0) -Message (
            "ConvertConfig.ini has no section header, cannot insert: $($missing -join ', ')")
        $insertion = @($missing | ForEach-Object { "{0,-12}= {1}" -f $_, $Overrides[$_] })
        $output.InsertRange($firstSectionIndex + 1, [string[]] $insertion)
        Write-Warn ("added unknown ConvertConfig keys: {0}" -f ($missing -join ', '))
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

        [string] $WebBase = 'https://uupdump.net',

        [switch] $IncludeUpdates
    )

    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }

    # The download package is produced by the web front end, not the JSON API.
    # POST + a form body selects the "download and convert" flavour, which
    # yields uup_download_windows.cmd plus ConvertConfig.ini.
    $query = "id=$Uuid&pack=$([uri]::EscapeDataString($Lang))&edition=$([uri]::EscapeDataString($Edition))"
    # autodl=2 is the "download and convert" flavour: it ships
    # uup_download_windows.cmd together with ConvertConfig.ini.
    # autodl=1 only produces the bare file list, autodl=3 asks for a virtual
    # edition and rejects plain professional.
    $body = @{
        autodl  = '2'
        cleanup = '1'
    }
    if ($IncludeUpdates) { $body['updates'] = '1' }

    $url = "$WebBase/get.php?$query"
    $zip = Join-Path $OutDir 'uup-package.zip'

    Write-SubStep "downloading UUP conversion package for $Uuid ($Lang, $Edition)"
    Invoke-WebRequest -Uri $url -Method Post -Body $body -OutFile $zip -TimeoutSec 600
    Assert-PathExists -Path $zip -Label 'UUP package archive'

    $extractDir = Join-Path $OutDir 'package'
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $extractDir -Force
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue

    $downloader = Join-Path $extractDir 'uup_download_windows.cmd'
    $config = Join-Path $extractDir 'ConvertConfig.ini'
    Assert-True -Condition (Test-Path -LiteralPath $downloader) -Message (
        "UUP package did not contain uup_download_windows.cmd. URL: $url")
    Assert-True -Condition (Test-Path -LiteralPath $config) -Message (
        "UUP package did not contain ConvertConfig.ini. URL: $url")

    return $extractDir
}

function Repair-UupAria2Script {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $PackageDir,

        [string] $ReplacementScript
    )

    # The bundled files\get_aria2.ps1 calls Get-FileHash, which is not available
    # in the PowerShell session the converter's .cmd spawns. Replace it with our
    # .NET-only verifier (same contract: pinned hash, same download URL, same
    # "tampered with" failure) before the downloader runs.
    if (-not $ReplacementScript) {
        $ReplacementScript = Join-Path $PSScriptRoot '..\uup\get_aria2.ps1'
    }

    $target = Join-Path $PackageDir 'files\get_aria2.ps1'
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Warn 'UUP package has no files\get_aria2.ps1; nothing to patch'
        return $false
    }

    Assert-PathExists -Path $ReplacementScript -Label 'aria2 verifier replacement'
    Copy-Item -LiteralPath $ReplacementScript -Destination $target -Force

    $content = Get-Content -LiteralPath $target -Raw
    Assert-True -Condition (-not (Test-ScriptInvokesCommand -Path $target -CommandName 'Get-FileHash')) -Message (
        'patched get_aria2.ps1 still calls Get-FileHash')
    Assert-True -Condition ($content -match [regex]::Escape($script:Aria2ExpectedHash)) -Message (
        'patched get_aria2.ps1 does not contain the pinned aria2c hash')

    Write-SubStep 'patched files\get_aria2.ps1 to verify aria2c without Get-FileHash'
    return $true
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
