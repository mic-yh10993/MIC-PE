#Requires -Version 7.0
<#
.SYNOPSIS
    Upload a finished MICPE build to its GitHub Release: core files first,
    extras one by one, never letting one bad extra sink the release.

.DESCRIPTION
    The "Upload finished build to Release" step in build.yml calls
    Publish-CleanRelease with the core files (ISO, boot.wim,
    checksums.sha256) and the extras (clean QEMU screenshots as PNGs, plus
    the QEMU serial and debug logs). Core files ride the release creation
    and a failure there still fails the step — without the ISO there is no
    release. Extras are uploaded one by one afterwards; a single bad extra
    only warns and the rest still land.

    Why the split: run 45448778057 built fine, verified fine in QEMU (7/7
    screenshots), and converted all 7 PNGs — then the single combined
    `gh release create` failed with HTTP 400 Bad Content-Length while
    uploading micpe-qemu.log, and the whole release died with it. The r82
    Release and tag never existed; the ISO, boot.wim, checksums, all 7
    PNGs and both logs had no copy anywhere and were lost with the runner.
    The most likely cause is that micpe-qemu.log was empty (QEMU's -D
    debug log writes nothing on a clean run) and GitHub's release-asset
    upload rejects 0-byte files. Empty files are therefore skipped with a
    warning before anything is uploaded, and even a non-empty file that
    fails to upload can no longer take the release down with it.
#>

[CmdletBinding()]
param(
    # Dot-source only (tests): the script only defines functions, so
    # dot-sourcing it is side-effect free with or without this switch.
    [switch] $ParseOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Select-NonEmptyReleaseFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Paths
    )
    # Keep existing, non-empty files; warn and skip the rest. A missing
    # file is a stale path, a 0-byte file is rejected by GitHub's
    # release-asset upload (HTTP 400 Bad Content-Length, run 45448778057):
    # neither may reach the upload list.
    $kept = @()
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Warning ("release upload: skipping missing file '{0}'" -f $path)
            continue
        }
        if ((Get-Item -LiteralPath $path).Length -eq 0) {
            Write-Warning ("release upload: skipping empty file '{0}' (0 bytes; GitHub rejects empty release assets)" -f $path)
            continue
        }
        $kept += $path
    }
    return $kept
}

function Publish-CleanRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Tag,

        [Parameter(Mandatory = $true)]
        [string[]] $CoreFiles,

        [string[]] $ExtraFiles = @(),

        [string] $Title = '',

        [string] $Notes = '',

        [string] $Repository = $env:GITHUB_REPOSITORY,

        # Test seam: a scriptblock that runs `gh` with the given argument
        # array and returns the exit code as an integer. Defaults to the
        # real gh CLI. Tests inject a fake that records calls and
        # simulates success or failure per file.
        #
        # Call the invoker with the array variable bare (`& $GhInvoker
        # $args`), never splatted (`& $GhInvoker @args`): splatting a
        # variable into a [string[]] parameter silently binds only the
        # first element and drops the rest (verified 2026-11-25 — a
        # create call arrived as just @('release')). A literal array
        # (@('release', 'view', ...)) binds whole, but variables do not.
        [scriptblock] $GhInvoker = $null
    )
    if ($null -eq $GhInvoker) {
        $GhInvoker = {
            param([string[]] $GhArgs)
            & gh @GhArgs
            return [int]$LASTEXITCODE
        }
    }

    # Core files ARE the release: a missing or empty one is a hard failure.
    $core = @(Select-NonEmptyReleaseFile -Paths $CoreFiles)
    foreach ($wanted in $CoreFiles) {
        if ($wanted -notin $core) {
            throw "release upload: core file missing or empty: '$wanted'"
        }
    }
    $extras = @(Select-NonEmptyReleaseFile -Paths $ExtraFiles)

    $viewArgs = @('release', 'view', $Tag, '--repo', $Repository)
    $viewExit = & $GhInvoker $viewArgs 2>$null
    if ($viewExit -eq 0) {
        # Re-run of the same workflow run: upload into the existing
        # release instead of failing on the duplicate tag.
        $uploadArgs = @('release', 'upload', $Tag) + $core + @('--repo', $Repository, '--clobber')
        $coreExit = & $GhInvoker $uploadArgs
        if ($coreExit -ne 0) { throw "gh release upload failed for $tag" }
    }
    else {
        $createArgs = @('release', 'create', $Tag) + $core + @('--repo', $Repository)
        if (-not [string]::IsNullOrEmpty($Title)) { $createArgs += @('--title', $Title) }
        if (-not [string]::IsNullOrEmpty($Notes)) { $createArgs += @('--notes', $Notes) }
        $createExit = & $GhInvoker $createArgs
        if ($createExit -ne 0) { throw "gh release upload failed for $tag" }
    }

    # Extras ride one by one: a single bad file (a truncated PNG, a
    # quota hiccup on one asset) only warns and the rest still land.
    # Run 45448778057 lost the ISO, boot.wim and all 7 PNGs because one
    # combined upload failed on micpe-qemu.log.
    foreach ($extra in $extras) {
        $extraArgs = @('release', 'upload', $Tag, $extra, '--repo', $Repository, '--clobber')
        $extraExit = & $GhInvoker $extraArgs
        if ($extraExit -ne 0) {
            Write-Warning ("release upload: failed to upload extra '{0}' to {1}; continuing with the remaining extras" -f $extra, $Tag)
        }
    }
    Write-Host "released $tag"
}
