#Requires -Version 7.0
<#
.SYNOPSIS
    Unified entry point for build, test and CI tasks.

.DESCRIPTION
    GitHub Actions defines a separate shell invocation per step, and passing an
    array literal to a -File style invocation is not portable between hosts.
    Wrapping the calls in a script keeps the workflow trivial and the arguments
    explicit.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('syntax', 'test')]
    [string] $Task
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $scriptDir

switch ($Task) {
    'syntax' {
        $paths = @()
        $paths += (Join-Path -Path $repoRoot -ChildPath 'src')
        $paths += (Join-Path -Path $scriptDir -ChildPath '.')
        $paths += (Join-Path -Path $repoRoot -ChildPath 'tests')

        & (Join-Path -Path $scriptDir -ChildPath 'Test-Syntax.ps1') -Path $paths
        exit $LASTEXITCODE
    }

    'test' {
        & (Join-Path -Path $scriptDir -ChildPath 'Invoke-Tests.ps1') -Output Detailed
        exit $LASTEXITCODE
    }
}
