BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'src/ci/Assert-Probe.ps1')
}

Describe 'probe.cmd progress markers (run 44181949882)' {
    BeforeAll {
        $script:probeText = Get-Content -LiteralPath (Join-Path $repoRoot 'src/ci/probe.cmd') -Raw
        $script:probeLines = $script:probeText -split "`r?`n"
        # Each marker must sit at the start of its section, before the
        # first work line of that section. Run 29 stopped after dwm=1
        # (5 lines) and the evidence could not tell "died" from "slow":
        # the next partial probe must say where it stopped and how long
        # each section took.
        $script:markers = @(
            @{ Mark = 'mark_shell_ready'; Work = 'tasklist /fi "imagename eq explorer.exe"' }
            # Settle markers (run 44249181100): runs 31/32 stopped between
            # mark_shell_ready and shell_ready. ping_after doubles as the
            # "before" of the second tasklist (its line is identical to the
            # first, so no work string can pin it); both after-markers pair
            # with the shell_ready echo, the first work line after them.
            @{ Mark = 'mark_shell_ping_before'; Work = 'ping -n 16 127.0.0.1' }
            @{ Mark = 'mark_shell_ping_after'; Work = 'echo shell_ready=' }
            @{ Mark = 'mark_shell_check_after'; Work = 'echo shell_ready=' }
            @{ Mark = 'mark_network'; Work = 'set "IPV4="' }
            @{ Mark = 'mark_ime'; Work = 'reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Keyboard Layout\Preload"' }
            # Diagnostics markers (run 44349189039): the UWP activation
            # chain is diagnosed before the launches, so a partial probe
            # says which check it died in.
            @{ Mark = 'mark_uwp_diag'; Work = 'set "TASKLIST_OUT=' }
            @{ Mark = 'mark_folder_window'; Work = 'start "" explorer.exe "%SystemDrive%\"' }
            @{ Mark = 'mark_uwp_svc'; Work = 'call :probe_svc AppXSVC appxsvc' }
            # Control markers (run 44365018616): the services are no
            # longer started — the freeze followed the two sc start
            # calls, so this round only records their last exit codes.
            # Each AppxAllUserStore query is bracketed so a partial
            # probe says whether it died inside the query or in the
            # append write after it.
            @{ Mark = 'mark_uwp_svc_exitcode'; Work = 'sc queryex AppXSVC' }
            @{ Mark = 'mark_appxstore_calc_query'; Work = 'find /i "Microsoft.WindowsCalculator"' }
            @{ Mark = 'mark_appxstore_calc_after'; Work = 'echo appxstore_calc=' }
            @{ Mark = 'mark_appxstore_photos_query'; Work = 'find /i "Microsoft.Windows.Photos"' }
            @{ Mark = 'mark_appxstore_photos_after'; Work = 'echo appxstore_photos=' }
            @{ Mark = 'mark_appxstore_media_query'; Work = 'find /i "Microsoft.ZuneMusic"' }
            @{ Mark = 'mark_appxstore_media_after'; Work = 'echo appxstore_media=' }
            @{ Mark = 'mark_uwp_appx'; Work = 'AppXDeploymentClient.dll' }
            @{ Mark = 'mark_uwp_launch_calculator'; Work = 'call :probe_uwp CalculatorApp' }
            @{ Mark = 'mark_uwp_launch_photos'; Work = 'call :probe_uwp Microsoft.Lightbox' }
            @{ Mark = 'mark_uwp_launch_media'; Work = 'call :probe_uwp Microsoft.Media.Player' }
            # Subroutine markers (run 44303866765): the probe died inside
            # the Media call, so :probe_uwp brackets its own launch. The
            # enter marker sits before the guard; start_before/start_after
            # bracket the `start` line itself; the caller's
            # uwp_launch_<app> line is the poll-finished witness.
            @{ Mark = 'mark_uwp_enter'; Work = 'set "UWP_PROC=%~1"' }
            @{ Mark = 'mark_uwp_start_before'; Work = 'start "" explorer.exe "%UWP_TARGET%"' }
            @{ Mark = 'mark_uwp_start_after'; Work = 'set "UWP_WAIT=0"' }
            # Cross-check markers (run 46): the guarded launches all
            # failed at the explorer guard in run 45, so the cross-check
            # retries each app without the guard, through a plain
            # ShellExecute. The enter/start markers bracket the
            # :probe_xcheck launch the same way :probe_uwp brackets its.
            @{ Mark = 'mark_xcheck'; Work = 'echo xcheck_explorer_before=' }
            @{ Mark = 'mark_xcheck_launch_calculator'; Work = 'call :probe_xcheck CalculatorApp' }
            @{ Mark = 'mark_xcheck_launch_photos'; Work = 'call :probe_xcheck Microsoft.Lightbox' }
            @{ Mark = 'mark_xcheck_launch_media'; Work = 'call :probe_xcheck Microsoft.Media.Player' }
            @{ Mark = 'mark_xcheck_enter'; Work = 'set "XCHECK_PROC=%~1"' }
            @{ Mark = 'mark_xcheck_start_before'; Work = 'start "" "%XCHECK_TARGET%"' }
            @{ Mark = 'mark_xcheck_start_after'; Work = 'set "XCHECK_WAIT=0"' }
            @{ Mark = 'mark_payload'; Work = 'set "PAYLOAD=1"' }
            @{ Mark = 'mark_brand'; Work = 'set "BRAND=1"' }
            @{ Mark = 'mark_installer'; Work = 'MICPE_PROBE_FILE=%PROBE_OUT%' }
            # Run 44386689307: the probe stopped after brand=1 and never
            # wrote mark_installer, so the scan call is bracketed with a
            # before/after pair the same way the reg queries are. The
            # deploy pair brackets the .wcs deploy call the same way.
            # The deploy-before anchor is the full stop-flag echo line:
            # the bare filename also appears in the watchdog comment at
            # the top of probe.cmd, which would put the anchor before
            # the marker.
            @{ Mark = 'mark_installer_before'; Work = 'MICPE_PROBE_FILE=%PROBE_OUT%' }
            @{ Mark = 'mark_installer_after'; Work = 'set "DEPLOY_SRC="' }
            @{ Mark = 'mark_installer_deploy'; Work = 'set "DEPLOY_SRC="' }
            @{ Mark = 'mark_installer_deploy_before'; Work = 'echo stop > "%SystemDrive%\micpe-watchdog-stop.txt"' }
            @{ Mark = 'mark_installer_deploy_after'; Work = 'echo probe_done=1' }
        )
    }

    It 'writes a mark_SECTION=%TIME% line at the start of every probe section' {
        foreach ($m in $script:markers) {
            $line = 'echo ' + $m.Mark + '=%TIME: =0% >> "%PROBE_OUT%"'
            $script:probeText | Should -Match ([regex]::Escape($line)) -Because "probe.cmd must mark the start of $($m.Mark)"
        }
    }

    It 'writes each marker before the section work it marks' {
        foreach ($m in $script:markers) {
            $markLine = ($script:probeLines | Select-String -Pattern ([regex]::Escape('echo ' + $m.Mark + '=')) | Select-Object -First 1).LineNumber
            $workLine = ($script:probeLines | Select-String -Pattern ([regex]::Escape($m.Work)) | Select-Object -First 1).LineNumber
            $markLine | Should -Not -BeNullOrEmpty -Because "marker $($m.Mark) must exist"
            $workLine | Should -Not -BeNullOrEmpty -Because "work line $($m.Work) must exist"
            $markLine | Should -BeLessThan $workLine -Because "$($m.Mark) must come before $($m.Work)"
        }
    }

    It 'writes marker lines at column 0, outside (...) blocks, so %TIME% is read when the line runs' {
        # %TIME% inside a (...) block expands once, when the block is
        # parsed, so every marker in the block would carry the same
        # frozen time. probe.cmd top-level commands start at column 0;
        # block contents are indented.
        # Run 44319967017: the per-round poll markers (mark_uwp_poll_)
        # are dynamic (process name and round number sit in the key),
        # so they cannot be pinned as fixed lines in the list above
        # and are left out of the count; they are pinned by pattern in
        # ProbeUwpMechanism.Tests.ps1 instead. They are column-0 lines
        # too, so they are checked the same way right below. Run 46
        # adds the cross-check poll markers (mark_xcheck_poll_): same
        # rule, same treatment. Run 47 adds the WER snapshot marker
        # (mark_wer_): one parameterized line inside the subroutine,
        # same rule, same treatment.
        $markerLines = @($script:probeLines | Where-Object { $_ -match 'echo mark_' -and $_ -notmatch 'mark_uwp_poll_' -and $_ -notmatch 'mark_xcheck_poll_' -and $_ -notmatch 'mark_wer_' })
        $markerLines.Count | Should -Be $script:markers.Count
        foreach ($line in $markerLines) {
            $line | Should -Match '^echo mark_' -Because "marker must be a top-level line, not block content: $line"
        }
        $pollLines = @($script:probeLines | Where-Object { $_ -match 'echo mark_uwp_poll_' })
        $pollLines.Count | Should -BeGreaterThan 0 -Because 'the poll loop must write per-round markers'
        foreach ($line in $pollLines) {
            $line | Should -Match '^echo mark_uwp_poll_' -Because "poll marker must be a top-level line, not block content: $line"
        }
        $xcheckPollLines = @($script:probeLines | Where-Object { $_ -match 'echo mark_xcheck_poll_' })
        $xcheckPollLines.Count | Should -Be 3 -Because 'one marker per poll step: wait_before, wait_after, check_after'
        foreach ($line in $xcheckPollLines) {
            $line | Should -Match '^echo mark_xcheck_poll_' -Because "poll marker must be a top-level line, not block content: $line"
        }
    }

    It 'markers are parsed by Read-ProbeFile and ignored by the stage assertions' {
        # A full m4 probe with markers, as the PE would write it.
        $f = New-TemporaryFile
        Set-Content -LiteralPath $f -Value @(
            'boot=1'
            'share=1'
            'share_drive=C:\'
            'pe_drive=X'
            'win_drive=none'
            'drive_fixed=0'
            'explorer=0'
            'dwm=1'
            'mark_shell_ready=06:12:34.56'
            'shell_ready=0'
            'mark_network=06:13:01.02'
            'network=pending'
            'mark_ime=06:13:05.11'
            'ime=1'
            'mark_uwp_appx=06:13:09.44'
            'uwp_appx=1'
            'probe_done=1'
        )
        $probe = Read-ProbeFile -Path $f
        $probe['mark_shell_ready'] | Should -Be '06:12:34.56'
        $probe['mark_ime'] | Should -Be '06:13:05.11'
        (Assert-ProbeResult -Probe $probe -Expected (Get-StageProbeExpect -Stage 'm4')).Count | Should -Be 0
    }

    It 'a marked probe missing ime still fails on ime (markers cannot mask a failure)' {
        # The run 29 partial probe with markers added: markers present,
        # ime never written, so the m4 verdict must still fail on ime.
        $f = New-TemporaryFile
        Set-Content -LiteralPath $f -Value @(
            'boot=1'
            'share=1'
            'pe_drive=X'
            'win_drive=none'
            'drive_fixed=0'
            'mark_shell_ready=06:12:34.56'
            'shell_ready=0'
            'mark_network=06:13:01.02'
            'network=pending'
            'mark_ime=06:13:05.11'
            'mark_uwp_appx=06:13:09.44'
            'uwp_appx=1'
            'probe_done=1'
        )
        $probe = Read-ProbeFile -Path $f
        $failures = Assert-ProbeResult -Probe $probe -Expected (Get-StageProbeExpect -Stage 'm4')
        $failures.Count | Should -Be 1
        $failures[0] | Should -Match 'ime: missing'
    }

    It 'reverse control: removing a marker line makes the marker test fail' {
        # The marker-presence assertion above must actually depend on the
        # marker being in probe.cmd, not pass vacuously.
        $mutated = $script:probeText.Replace('echo mark_ime=%TIME: =0% >> "%PROBE_OUT%"', '')
        $mutated | Should -Not -Match ([regex]::Escape('echo mark_ime=%TIME: =0% >> "%PROBE_OUT%"'))
    }

    It 'reverse control: a marked probe with a wrong ime value still fails' {
        $f = New-TemporaryFile
        Set-Content -LiteralPath $f -Value @(
            'boot=1'
            'share=1'
            'mark_ime=06:13:05.11'
            'ime=0'
            'mark_uwp_appx=06:13:09.44'
            'uwp_appx=1'
            'probe_done=1'
        )
        $probe = Read-ProbeFile -Path $f
        $failures = Assert-ProbeResult -Probe $probe -Expected (Get-StageProbeExpect -Stage 'm4')
        $failures.Count | Should -BeGreaterThan 0
        ($failures -join "`n") | Should -Match 'ime'
    }
}
