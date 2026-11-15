#Requires -Version 7.0
<#
.SYNOPSIS
    Shared helpers for the MICPE build: logging, assertions, temp directories.

.DESCRIPTION
    Every build library dot-sources this file. Functions here must stay free of
    external dependencies so they can run on any PowerShell 7 host.
#>

Set-StrictMode -Version Latest

function Write-Step {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Message
    )

    Write-Host "==> $Message"
}

function Write-SubStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Message
    )

    Write-Host "    - $Message"
}

function Write-Warn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Message
    )

    Write-Host "!!! $Message" -ForegroundColor Yellow
}

function Assert-True {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool] $Condition,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if (-not $Condition) {
        throw [System.InvalidOperationException]::new($Message)
    }
}

function Assert-PathExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [string] $Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        $what = if ($Label) { $Label } else { 'Path' }
        throw [System.InvalidOperationException]::new("${what} not found: $Path")
    }
}

function Format-ByteSize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [long] $Bytes
    )

    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Assert-FileSize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [long] $MaxBytes,

        [Parameter(Mandatory = $true)]
        [string] $Label
    )

    Assert-PathExists -Path $Path -Label $Label

    $actual = (Get-Item -LiteralPath $Path).Length
    if ($actual -gt $MaxBytes) {
        throw [System.InvalidOperationException]::new(
            ("{0} is {1}, exceeding the {2} limit (by {3})" -f
                $Label,
                (Format-ByteSize -Bytes $actual),
                (Format-ByteSize -Bytes $MaxBytes),
                (Format-ByteSize -Bytes ($actual - $MaxBytes))))
    }

    Write-SubStep ("{0} = {1} (limit {2})" -f $Label, (Format-ByteSize -Bytes $actual), (Format-ByteSize -Bytes $MaxBytes))
}

function Get-MicpeTempDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root
    )

    $dir = Join-Path $Root 'micpe-tmp'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}
