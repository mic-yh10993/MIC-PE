<#
.SYNOPSIS
    Drop-in replacement for the UUP conversion package's files\get_aria2.ps1.

.DESCRIPTION
    The bundled script verifies files\aria2c.exe with Get-FileHash. That cmdlet
    is not available in the PowerShell session the converter's
    uup_download_windows.cmd spawns (observed 2026-11-15: CommandNotFoundException
    at get_aria2.ps1:38, then "aria2c.exe appears to be tampered with" and the
    downloader exits 1), even though our own pre-seed step already downloaded
    and verified the same binary.

    This replacement keeps the exact same contract -- verify the pinned SHA256,
    download from the same URL when the binary is missing or mismatched, fail
    with the same "tampered with" message -- but computes the hash with .NET
    only, so it works in every PowerShell from 2.0 on, in powershell.exe and
    in pwsh. It deliberately avoids Get-FileHash, Invoke-WebRequest and any
    other cmdlet that might be missing from the spawning session.

    Parameters exist only so tests can point the script at scratch files; the
    converter invokes it with no arguments and the defaults below apply.
#>

param(
    [string] $ExpectedHash = 'b9cd71b275af11b63c33457b0f43f2f2675937070c563e195f223efd7fa4c74b',

    [string] $DownloadUrl = 'https://uupdump.net/misc/aria2c.exe',

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $RemainingArgs
)

$ErrorActionPreference = 'Stop'

function Get-Sha256Hex {
    param([string] $Path)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $bytes = $sha.ComputeHash($stream)
        }
        finally {
            $stream.Close()
        }
    }
    finally {
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLower()
}

$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$candidates = @()
if ($scriptDir) {
    $candidates += (Join-Path $scriptDir 'aria2c.exe')
}
$candidates += (Join-Path (Get-Location) 'files\aria2c.exe')
$candidates += (Join-Path (Get-Location) 'aria2c.exe')

$aria2 = $null
foreach ($candidate in $candidates) {
    if (Test-Path -Path $candidate) {
        $aria2 = $candidate
        break
    }
}

Write-Host 'Verifying aria2c.exe...'
if ($aria2 -and (Get-Sha256Hex -Path $aria2) -eq $ExpectedHash.ToLower()) {
    exit 0
}

Write-Host 'Downloading aria2c.exe...'
$target = $candidates[0]
$targetDir = Split-Path -Parent $target
if ($targetDir -and -not (Test-Path -Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}

try {
    $client = New-Object System.Net.WebClient
    try {
        $client.DownloadFile($DownloadUrl, $target)
    }
    finally {
        $client.Dispose()
    }
}
catch {
    Write-Error ("failed to download aria2c.exe from ${DownloadUrl}: $($_.Exception.Message)")
    exit 1
}

if ((Get-Sha256Hex -Path $target) -eq $ExpectedHash.ToLower()) {
    exit 0
}

Write-Error 'aria2c.exe appears to be tampered with'
exit 1
