#Requires -Version 7.0
<#
.SYNOPSIS
    Build step tables for each MICPE milestone.

.DESCRIPTION
    Kept apart from the orchestrator so the ordering can be unit tested without
    executing any build step. Each stage name maps to the ordered set of steps
    that must run to produce that stage's ISO.
#>

$script:AllSteps = @(
    'base'
    'reseed'
    'explorer'
    'runtimes'
    'components'
    'uwp'
    'payload'
    'brand'
    'installer'
    'iso'
)

$script:StageSteps = @{
    m1 = @('base', 'reseed', 'iso')
    m2 = @('base', 'reseed', 'explorer', 'iso')
    m3 = @('base', 'reseed', 'explorer', 'runtimes', 'components', 'iso')
    m4 = @('base', 'reseed', 'explorer', 'runtimes', 'components', 'uwp', 'iso')
    m5 = @('base', 'reseed', 'explorer', 'runtimes', 'components', 'uwp', 'payload', 'brand', 'iso')
    m6 = @('base', 'reseed', 'explorer', 'runtimes', 'components', 'uwp', 'payload', 'brand', 'installer', 'iso')
    m7 = $script:AllSteps
}

function Get-StageSteps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('m1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7', 'all')]
        [string] $Stage
    )

    if ($Stage -eq 'all') {
        return @($script:AllSteps)
    }

    if (-not $script:StageSteps.ContainsKey($Stage)) {
        throw [System.InvalidOperationException]::new("Unknown stage: $Stage")
    }

    return @($script:StageSteps[$Stage])
}

function Get-AllSteps {
    [CmdletBinding()]
    param()

    return @($script:AllSteps)
}

$script:DegradeOrder = @('office', 'chrome', 'photos', 'mediaplayer')

function Get-DegradeOrder {
    [CmdletBinding()]
    param()

    return @($script:DegradeOrder)
}

function Invoke-Degrade {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [long] $CurrentWimBytes,

        [AllowEmptyCollection()]
        [string[]] $Enabled = @(),

        [long] $CapBytes = 3GB
    )

    if ($CurrentWimBytes -le $CapBytes) {
        return [pscustomobject]@{ TooBig = $false; NextToDrop = $null }
    }

    foreach ($candidate in $script:DegradeOrder) {
        if ($Enabled -contains $candidate) {
            return [pscustomobject]@{ TooBig = $true; NextToDrop = $candidate }
        }
    }

    return [pscustomobject]@{ TooBig = $true; NextToDrop = $null }
}
