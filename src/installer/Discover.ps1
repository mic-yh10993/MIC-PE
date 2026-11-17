#Requires -Version 7.0
<#
.SYNOPSIS
    install.mic source discovery for the MICPE installer (M6, Task 15).

.DESCRIPTION
    Pure functions: given a list of volume roots, find install images using
    the install.mic protocol (design §5.4.1). A volume whose root carries
    install.mic IS the install source volume; without a marker the scan falls
    back to sources\install.wim, install.wim, sources\install.esd and *.esd.
    A marker volume whose image is missing is reported as a broken entry
    (Review Focus #1) instead of being silently skipped, and a root that
    throws is warned about and skipped instead of failing the whole scan
    (Review Focus #5).

    # reuse-check: no DSI content is used here. The protocol comes from
    docs/design.md §5.4.1 and the function shapes from docs/plan.md Task 15;
    the try/catch-per-root and sort rules are implemented from that spec.
#>

$script:MinImageBytes = 512MB

function Read-InstallMic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $lines = [System.IO.File]::ReadAllLines($Path)
    }
    catch {
        Write-Warn "cannot read install.mic at $Path : $($_.Exception.Message)"
        return $null
    }

    if ($lines.Count -eq 0) {
        return $null
    }

    # ReadAllLines already strips a UTF-8 BOM; TrimStart covers a stray
    # BOM character in an ANSI file as well.
    $first = $lines[0].TrimStart([char]0xFEFF).Trim()
    if (-not $first) {
        return $null
    }
    return $first
}

function Test-InstallImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $ext = [System.IO.Path]::GetExtension($Path)
    if ($ext -notin '.wim', '.esd') {
        return $false
    }

    return (Get-Item -LiteralPath $Path).Length -gt $script:MinImageBytes
}

function Find-InstallSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Roots = @()
    )

    $found = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($root in $Roots) {
        try {
            if (-not $root -or -not (Test-Path -LiteralPath $root)) {
                Write-Warn "install source root not accessible: $root"
                continue
            }

            $marker = Join-Path $root 'install.mic'
            if (Test-Path -LiteralPath $marker -PathType Leaf) {
                $display = Read-InstallMic -Path $marker
                $image = Join-Path $root 'sources/install.wim'
                if (Test-InstallImage -Path $image) {
                    $found.Add([pscustomobject]@{
                        Root        = $root
                        ImagePath   = $image
                        DisplayName = $display
                        HasMarker   = $true
                        Broken      = $false
                    })
                }
                else {
                    # Review Focus #1: a marker without its image is a
                    # broken entry, never a silent skip.
                    $found.Add([pscustomobject]@{
                        Root        = $root
                        ImagePath   = $null
                        DisplayName = $display
                        HasMarker   = $true
                        Broken      = $true
                    })
                }
                continue
            }

            # No marker: degrade per design §5.4.1 rule 3, in priority order.
            $hit = $null
            foreach ($candidate in @(
                (Join-Path $root 'sources/install.wim'),
                (Join-Path $root 'install.wim'),
                (Join-Path $root 'sources/install.esd')
            )) {
                if (Test-InstallImage -Path $candidate) {
                    $hit = $candidate
                    break
                }
            }
            if ($null -eq $hit) {
                $esd = Get-ChildItem -LiteralPath $root -Filter '*.esd' -File `
                    -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
                if ($null -ne $esd -and (Test-InstallImage -Path $esd.FullName)) {
                    $hit = $esd.FullName
                }
            }

            if ($null -ne $hit) {
                # No marker means no display name; the image file name is
                # the deterministic stand-in the UI shows.
                $found.Add([pscustomobject]@{
                    Root        = $root
                    ImagePath   = $hit
                    DisplayName = [System.IO.Path]::GetFileNameWithoutExtension($hit)
                    HasMarker   = $false
                    Broken      = $false
                })
            }
        }
        catch {
            # Review Focus #5: one bad root must not fail the whole scan.
            Write-Warn "install source scan failed for root ${root}: $($_.Exception.Message)"
            continue
        }
    }

    $sorted = @($found | Sort-Object -Property `
        @{ Expression = { $_.HasMarker }; Descending = $true },
        @{ Expression = { $null -ne $_.ImagePath -and $_.ImagePath -match 'sources' }; Descending = $true },
        @{ Expression = { $_.Root } })
    # Comma forces array semantics: without it an empty result unwraps to
    # $null and `.Count` throws under StrictMode (same trap Test-Syntax.ps1
    # documents for its file list).
    return ,$sorted
}
