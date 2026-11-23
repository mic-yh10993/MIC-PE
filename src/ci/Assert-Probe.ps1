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
    # m4 only asserts what an m4 image can actually produce: it boots, the
    # probe reaches the share, the input method preload is set, and the UWP
    # AppX files are present. An m4 image has no PECMD.EXE, so the cmd
    # fallback never starts Explorer; explorer / dwm / shell_ready can
    # never be 1 here, and the UWP apps cannot be launched (launching
    # needs the shell). Those keys are verified at m5 (PECMD arrives with
    # the payload) and m7 (full image). Relaxed in the run 44135105700
    # round; m2/m3 carry the same latent defect (see the eval card §14).
    # Drive letters (user decision 2026-11-17 23:43): the PE system drive
    # is X:, the installed-Windows volume keeps C:. In the CI harness
    # there is no installed-Windows volume, so win_drive=none and
    # drive_fixed=0 are the honest expectations there; a swap on a real
    # machine is verified by the user against docs/test-checklist.md.
    # pe_drive is asserted from m4 on: m1-m3 predate the fix.
    m4 = @{ boot = '1'; share = '1'; ime = '1'; uwp_appx = '1'; pe_drive = 'X'; win_drive = 'none'; drive_fixed = '0' }
    m5 = @{ boot = '1'; share = '1'; explorer = '1'; shell_ready = '1'; dwm = '1'; ime = '1'; payload = '1'; brand = '1'; pe_drive = 'X'; win_drive = 'none'; drive_fixed = '0'; fm_42537950_group0 = '0x1'; fm_42537950_group15 = '0x1'; fm_42537950_group9 = '0x1'; explorer_end = '1' }
    m6 = @{ boot = '1'; share = '1'; explorer = '1'; shell_ready = '1'; installer_scan = '1'; installer_deploy = '1'; pe_drive = 'X'; win_drive = 'none'; drive_fixed = '0' }
    m7 = @{ boot = '1'; share = '1'; explorer = '1'; shell_ready = '1'; dwm = '1'; network = '*'; ime = '1'; uwp_appx = '1'; uwp_launch_photos = '1'; uwp_launch_media = '1'; uwp_launch_calculator = '1'; payload = '1'; brand = '1'; installer_scan = '1'; installer_deploy = '1'; size_wim = '*'; size_iso = '*'; pe_drive = 'X'; win_drive = 'none'; drive_fixed = '0'; fm_42537950_group0 = '0x1'; fm_42537950_group15 = '0x1'; fm_42537950_group9 = '0x1'; explorer_end = '1' }
    # wb2 (the WimBuilder2 UWP chain) is probed by probe-wb2.cmd, not the
    # classic probe.cmd: the wb2 startnet never installs probe.cmd, so the
    # probe runs as a postshell hook (10-probe.cmd) and writes the same
    # micpe-probe.txt format. sab_mapped = StartAllBackLoaderX64.dll is
    # mapped in the explorer process; logonui = LogonUI.exe is present in
    # the image; net_seclogon = the Secondary Logon service is listed by
    # `net start` (round 8: the sc-based `seclogon` key is void — round 7
    # proved `sc query` in this PE returns exit code 0 with zero bytes of
    # stdout for every service, including the RpcSs control group, so the
    # old seclogon assertion measured sc's output, not the service state;
    # `net start` is the trustworthy SCM query path). The probe still
    # writes the sc-based `seclogon` key as a diagnostic (it stays 0 in
    # PE and is not asserted). The probe does NOT shut the guest down:
    # the harness takes the final screenshot first, then quits QEMU.
    #
    # logon_token is deliberately NOT asserted here (round-2 decision,
    # run 62): phase 25 builds the Administrator logon token through
    # seclogon/runas, a workstream of its own with failure modes (runas,
    # the Administrator account, the profile clone) that are independent
    # of whether the desktop/taskbar works. Asserting it would fail every
    # wb2 build for a token-path problem even when the shell is good. The
    # probe still writes logon_token (diagnostic), and the token path is
    # validated separately once seclogon is confirmed RUNNING. logonui
    # stays asserted: LogonUI.exe is in the image (72-logon-ui.txt) and
    # the probe only checks the file exists, so a missing logonui is a
    # real build regression, not a deferred feature.
    #
    # Round 5 adds desktop assertions (wallpaper_file, wallpaper_set,
    # desktop_icons, startmenu_init, taskbar_values): before round 5 the
    # CI had no assertion covering the desktop at all, so a black
    # desktop with no icons and no wallpaper passed silently. All five
    # are build-time properties - the wallpaper file, the Wallpaper
    # registry value, the HideDesktopIcons / StartMenuInit / taskbar
    # values the .reg steps write - so a 0 is a build regression, not
    # a runtime failure. The runtime side (whether Themes actually
    # applies the wallpaper) stays diagnostic (themes_run, themes_after).
    wb2 = @{ boot = '1'; share = '1'; explorer = '1'; shell_ready = '1'; dwm = '1'; sab_mapped = '1'; logonui = '1'; net_seclogon = '1'; wallpaper_file = '1'; wallpaper_set = '1'; desktop_icons = '1'; startmenu_init = '1'; taskbar_values = '1' }
}

function Get-StageProbeExpect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('m1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7', 'wb2', 'all')]
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

function Merge-ProbeFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SharePath,

        [Parameter(Mandatory = $true)]
        [string] $LocalPath
    )

    # Run 48: neither probe file alone holds every key. The share file
    # carries the early share-only keys (explorer, shell_ready, dwm,
    # the service states, the exit codes) that were never dual-written,
    # while the local copy carries the late keys (payload, brand, the
    # end snapshot) a stalled vvfat host view never saw — run 47's
    # share file stopped at 12:43:48 with 55 keys the local copy lacks
    # and 39 keys only the local copy has. The merge is the union:
    # the share file is the base, the local copy overwrites on
    # conflict, because its values are the newest write of each key
    # (the probe echoes every key to both files; the local copy is
    # refreshed by a whole-file copy at every section sync). A missing
    # file contributes nothing — Read-ProbeFile returns empty for it.
    # Read-ProbeFile trims values, so the trailing-space difference
    # between the two files' copies of one line is irrelevant.
    $merged = Read-ProbeFile -Path $SharePath
    $local = Read-ProbeFile -Path $LocalPath
    foreach ($key in $local.Keys) {
        $merged[$key] = $local[$key]
    }

    return $merged
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

    # probe_failed=1 (run 44285721257) is written by the probe watchdog
    # when the probe stalls or dies mid-run. It ends the host wait early
    # (see Test-ProbeComplete) but it never passes a run: a failed probe
    # is a failed run even when every expected key happens to be present.
    if ($Probe.ContainsKey('probe_failed') -and [string] $Probe['probe_failed'] -eq '1') {
        $failures.Add('probe_failed: the probe stalled or died mid-run (see the probe file for the last section reached)')
    }

    # The comma forces array semantics even when there are zero failures, so the
    # caller can always use .Count without a null check.
    return ,($failures.ToArray())
}
