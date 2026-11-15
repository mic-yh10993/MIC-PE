#Requires -Version 7.0
<#
.SYNOPSIS
    WIM handling: whitelist parsing, mounting, extraction, size assertion.
.DESCRIPTION
    The MICPE build assembles its PE by copying a whitelisted set of files out of
    install.wim. wimlib-imagex does that far faster than DISM, and it understands
    wildcards, so the whitelists stay short. DISM is used only for mounting.
#>

$script:BootWimMaxBytes = 3GB
$script:WimExtractBatchSize = 50

function ConvertTo-WimPathPattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Line
    )

    $text = $Line.Trim()
    if (-not $text) { return $null }
    if ($text.StartsWith(';') -or $text.StartsWith('#')) { return $null }
    if ($text.StartsWith('\')) { $text = $text.Substring(1) }
    $text = $text.TrimEnd()
    if (-not $text) { return $null }
    return $text
}

function Read-Whitelist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    Assert-PathExists -Path $Path -Label 'Whitelist'

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[string]]::new()

    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $pattern = ConvertTo-WimPathPattern -Line $line
        if ($null -eq $pattern) { continue }
        if ($seen.Add($pattern)) { $result.Add($pattern) }
    }

    return $result.ToArray()
}

function Assert-BootWimSize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $WimPath
    )

    Assert-FileSize -Path $WimPath -MaxBytes $script:BootWimMaxBytes -Label 'boot.wim'
}

function Mount-WimImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $WimPath,

        [int] $Index = 1,

        [Parameter(Mandatory = $true)]
        [string] $MountDir
    )

    Assert-PathExists -Path $WimPath -Label 'WIM'

    if (-not (Test-Path -LiteralPath $MountDir)) {
        New-Item -ItemType Directory -Path $MountDir -Force | Out-Null
    }

    Write-SubStep "mounting $WimPath (index $Index) -> $MountDir"
    & dism.exe /English /Mount-Image "/ImageFile:$WimPath" "/Index:$Index" "/MountDir:$MountDir" /Optimize |
        Out-Host
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "dism /Mount-Image failed with exit code $LASTEXITCODE for $WimPath"
}

function Dismount-WimImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir,

        [switch] $Commit
    )

    $args = @('/English', '/Unmount-Image', "/MountDir:$MountDir")
    if ($Commit) { $args += '/Commit' } else { $args += '/Discard' }

    Write-SubStep ("{0} {1}" -f ($(if ($Commit) { 'committing' } else { 'discarding' })), $MountDir)
    & dism.exe @args | Out-Host
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "dism /Unmount-Image failed with exit code $LASTEXITCODE for $MountDir"
}

function Export-WimFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $WimPath,

        [int] $Index = 1,

        [Parameter(Mandatory = $true)]
        [string] $Destination,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Patterns,

        [string] $WimlibPath = 'wimlib-imagex'
    )

    Assert-PathExists -Path $WimPath -Label 'WIM'

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    if ($Patterns.Count -eq 0) {
        Write-Warn 'no extraction patterns supplied'
        return
    }

    $batchIndex = 0
    for ($offset = 0; $offset -lt $Patterns.Count; $offset += $script:WimExtractBatchSize) {
        $batchIndex++
        $end = [Math]::Min($offset + $script:WimExtractBatchSize - 1, $Patterns.Count - 1)
        $batch = $Patterns[$offset..$end]

        Write-SubStep ("extracting batch {0} ({1} pattern(s))" -f $batchIndex, $batch.Count)
        & $WimlibPath extract $WimPath $Index @batch "--dest-dir=$Destination" | Out-Host

        if ($LASTEXITCODE -ne 0) {
            $preview = ($batch | Select-Object -First 3) -join ', '
            throw [System.InvalidOperationException]::new(
                "wimlib-imagex extract failed with exit code $LASTEXITCODE in batch $batchIndex starting with: $preview")
        }
    }
}
