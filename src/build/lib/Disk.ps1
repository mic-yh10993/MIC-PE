#Requires -Version 7.0
<#
.SYNOPSIS
    Runner disk housekeeping: remove preinstalled bloat and pick the largest drive.

.DESCRIPTION
    GitHub's windows-2025 image ships several multi-gigabyte SDKs the MICPE build
    never uses. Removing them frees room for the UUP download, the mounted images
    and the ISO. Drive selection is separated into a pure function so it can be
    tested without touching real disks.
#>

$script:RunnerBloatPaths = @(
    'C:\Android'
    'C:\SeleniumWebDrivers'
    'C:\R'
    'C:\Program Files\MongoDB'
    'C:\Program Files\PostgreSQL'
    'C:\Program Files (x86)\Microsoft SDKs\Azure'
)

function Remove-RunnerBloat {
    [CmdletBinding()]
    param(
        [string[]] $Paths,
        [string] $LocalAppData = $env:LOCALAPPDATA
    )

    if (-not $PSBoundParameters.ContainsKey('Paths')) {
        $candidates = @($script:RunnerBloatPaths)
        if ($LocalAppData) {
            $candidates += @(
                (Join-Path $LocalAppData 'pip\cache')
                (Join-Path $LocalAppData 'NuGet')
            )
        }
        $Paths = $candidates
    }

    $removed = 0
    foreach ($path in $Paths) {
        if (-not $path) { continue }
        if (Test-Path -LiteralPath $path) {
            Write-SubStep "removing $path"
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $path)) {
                $removed++
            }
        }
    }

    Write-SubStep "removed $removed path(s)"
    return $removed
}

function Get-BuildDrive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Drives
    )

    $usable = @($Drives | Where-Object { $null -ne $_ -and $_.Free -gt 0 })
    if ($usable.Count -eq 0) {
        throw [System.InvalidOperationException]::new('No filesystem drive with free space was found.')
    }

    return ($usable | Sort-Object -Property Free -Descending | Select-Object -First 1)
}

function Get-BuildWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Drives
    )

    $drive = Get-BuildDrive -Drives $Drives
    $root = $drive.Root
    if (-not $root.EndsWith([System.IO.Path]::DirectorySeparatorChar) -and
        -not $root.EndsWith('/') -and
        -not $root.EndsWith('\')) {
        $root = $root + [System.IO.Path]::DirectorySeparatorChar
    }

    $workspace = Join-Path $root 'micpe'
    if (-not (Test-Path -LiteralPath $workspace)) {
        New-Item -ItemType Directory -Path $workspace -Force | Out-Null
    }

    Write-SubStep "build workspace: $workspace"
    return $workspace
}
