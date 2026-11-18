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
            @{ Mark = 'mark_uwp_appx'; Work = 'AppXDeploymentClient.dll' }
            @{ Mark = 'mark_uwp_launch_calculator'; Work = 'call :probe_uwp CalculatorApp' }
            @{ Mark = 'mark_uwp_launch_photos'; Work = 'call :probe_uwp Microsoft.Photos' }
            @{ Mark = 'mark_uwp_launch_media'; Work = 'call :probe_uwp Microsoft.ZuneMusic' }
            @{ Mark = 'mark_payload'; Work = 'set "PAYLOAD=1"' }
            @{ Mark = 'mark_brand'; Work = 'set "BRAND=1"' }
            @{ Mark = 'mark_installer'; Work = 'MICPE_PROBE_FILE=%PROBE_OUT%' }
            @{ Mark = 'mark_installer_deploy'; Work = 'set "DEPLOY_SRC="' }
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
        $markerLines = @($script:probeLines | Where-Object { $_ -match 'echo mark_' })
        $markerLines.Count | Should -Be $script:markers.Count
        foreach ($line in $markerLines) {
            $line | Should -Match '^echo mark_' -Because "marker must be a top-level line, not block content: $line"
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
