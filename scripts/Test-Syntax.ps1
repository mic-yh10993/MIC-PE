#Requires -Version 7.0
<#
.SYNOPSIS
    Parse every PowerShell file in the given paths and fail on syntax errors.

.DESCRIPTION
    Used by CI and locally. Parses files without executing them, so it is safe
    to run against build scripts that would otherwise need a Windows host.

.PARAMETER Path
    Files or directories to scan. Directories are searched recursively for *.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]] $Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-PowerShellFiles {
    param([string[]] $Items)

    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Items) {
        foreach ($part in ($item -split ',')) {
            $trimmed = $part.Trim()
            if (-not $trimmed) { continue }

            if (Test-Path -LiteralPath $trimmed -PathType Container) {
                Get-ChildItem -LiteralPath $trimmed -Recurse -Filter '*.ps1' -File |
                    ForEach-Object { $files.Add($_.FullName) }
            }
            elseif (Test-Path -LiteralPath $trimmed -PathType Leaf) {
                $files.Add((Resolve-Path -LiteralPath $trimmed).Path)
            }
            else {
                Write-Error "Path not found: $trimmed"
            }
        }
    }
    return $files
}

$files = Get-PowerShellFiles -Items $Path
if ($files.Count -eq 0) {
    Write-Host 'No PowerShell files found.'
    exit 0
}

$failures = 0
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file, [ref] $tokens, [ref] $errors) | Out-Null

    if ($errors.Count -gt 0) {
        $failures++
        Write-Host "FAIL $file"
        foreach ($parseError in $errors) {
            $line = $parseError.Extent.StartLineNumber
            $column = $parseError.Extent.StartColumnNumber
            Write-Host ("  {0}:{1} {2}" -f $line, $column, $parseError.Message)
        }
    }
    else {
        Write-Host "OK   $file"
    }
}

Write-Host ''
if ($failures -gt 0) {
    Write-Error "$failures file(s) failed syntax check."
    exit 1
}

Write-Host "All $($files.Count) file(s) passed syntax check."
exit 0
