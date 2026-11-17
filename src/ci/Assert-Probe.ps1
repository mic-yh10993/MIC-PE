#Requires -Version 7.0
<#
.SYNOPSIS
    Read and assert the probe results written by the PE itself.

.DESCRIPTION
    The PE writes `key=value` lines into a file on a QEMU vvfat disk. The host
    reads that file straight out of the shared directory, so this side needs no
    serial port, no OCR and no screenshot interpretation for the pass/fail
    decision. Screenshots are kept only as human-facing evidence.
#>

$script:StageProbeExpect = [ordered]@{
    m1 = @{ boot = '1'; share = '1' }
    m2 = @{ boot = '1'; share = '1'; explorer = '1'; shell_ready = '1'; dwm = '1' }
    m3 = @{ boot = '1'; share = '1'; explorer = '1'; shell_ready = '1'; dwm = '1'; network = '*'; ime = '1' }
    m4 = @{ boot = '1'; share = '1'; explorer = '1'; shell_ready = '1'; dwm = '1'; ime = '1'; uwp_appx = '1'; uwp_launch_photos = '1'; uwp_launch_media = '1'; uwp_launch_calculator = '1' }
    m5 = @{ boot = '1'; share = '1'; explorer = '1'; shell_ready = '1'; dwm = '1'; ime = '1'; payload = '1'; brand = '1' }
    m6 = @{ boot = '1'; share = '1'; explorer = '1'; shell_ready = '1'; installer_scan = '1'; installer_deploy = '1' }
    m7 = @{ boot = '1'; share = '1'; explorer = '1'; shell_ready = '1'; dwm = '1'; network = '*'; ime = '1'; uwp_appx = '1'; uwp_launch_photos = '1'; uwp_launch_media = '1'; uwp_launch_calculator = '1'; payload = '1'; brand = '1'; installer_scan = '1'; installer_deploy = '1'; size_wim = '*'; size_iso = '*' }
}

function Get-StageProbeExpect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('m1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7', 'all')]
        [string] $Stage
    )

    if ($Stage -eq 'all') { $Stage = 'm7' }
    return $script:StageProbeExpect[$Stage].Clone()
}

function Read-ProbeFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $result
    }

    foreach ($line in (Get-Content -LiteralPath $Path -Encoding utf8)) {
        $text = $line.Trim()
        if (-not $text) { continue }
        if ($text.StartsWith('#')) { continue }
        if ($text -notmatch '=') { continue }

        $parts = $text -split '=', 2
        $key = $parts[0].Trim()
        if (-not $key) { continue }
        $result[$key] = $parts[1].Trim()
    }

    return $result
}

function Assert-ProbeResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Probe,

        [Parameter(Mandatory = $true)]
        [hashtable] $Expected
    )

    $failures = [System.Collections.Generic.List[string]]::new()

    foreach ($key in ($Expected.Keys | Sort-Object)) {
        $want = [string] $Expected[$key]
        $actual = if ($Probe.ContainsKey($key)) { [string] $Probe[$key] } else { $null }

        if ($want -eq '*') {
            if ([string]::IsNullOrWhiteSpace($actual)) {
                $failures.Add("${key}: expected any non-empty value, got none")
            }
            continue
        }

        if ($null -eq $actual) {
            $failures.Add("${key}: missing (expected '$want')")
            continue
        }

        if ($actual -ne $want) {
            $failures.Add("${key}: expected '$want', got '$actual'")
        }
    }

    # The comma forces array semantics even when there are zero failures, so the
    # caller can always use .Count without a null check.
    return ,($failures.ToArray())
}
