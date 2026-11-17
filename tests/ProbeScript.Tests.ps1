BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
}

Describe 'probe.cmd' {
    BeforeAll {
        $script:probe = Get-Content -LiteralPath (Join-Path $repoRoot 'src/ci/probe.cmd') -Raw
    }

    It 'writes boot and share first so the host can always tell the PE ran' {
        $script:probe | Should -Match 'echo boot=1'
        $script:probe | Should -Match 'echo share=%SHARE%'
    }

    It 'checks each shell artifact the M2 stage asserts' {
        $script:probe | Should -Match 'explorer=0'
        $script:probe | Should -Match 'explorer=1'
        $script:probe | Should -Match 'dwm='
        $script:probe | Should -Match 'shell_ready='
    }

    It 'records the ime preload value in the exact key the assert expects' {
        $script:probe | Should -Match 'echo ime='
        $script:probe | Should -Match '0804'
    }

    It 'probes each UWP app under its expected process name' {
        $script:probe | Should -Match 'CalculatorApp'
        $script:probe | Should -Match 'Microsoft\.Photos'
        $script:probe | Should -Match 'Microsoft\.ZuneMusic'
        $script:probe | Should -Match 'uwp_launch_calculator'
        $script:probe | Should -Match 'uwp_launch_photos'
        $script:probe | Should -Match 'uwp_launch_media'
    }

    It 'does not probe the Settings app (not provisioned, user decision 2026-11-16)' {
        $script:probe | Should -Not -Match 'SystemSettings'
        $script:probe | Should -Not -Match 'uwp_launch_settings'
        $script:probe | Should -Not -Match 'immersivecontrolpanel'
    }

    It 'verifies the payload paths with the 7-zip lowercase directory' {
        $script:probe | Should -Match 'Program Files\\7-zip\\7z\.exe'
    }

    It 'verifies the brand values the owner asked for' {
        $script:probe | Should -Match 'OEMInformation'
        $script:probe | Should -Match 'space\.bilibili\.com/1978487514'
        $script:probe | Should -Match 'oemlogo\.bmp'
    }

    It 'shuts down after probing so the job does not wait for the timeout' {
        $script:probe | Should -Match 'shutdown'
    }

    It 'redirects both branches of every probe if/else into the probe file' {
        # A redirect after the closing paren only covers the else branch, so a
        # 0 value (and the network line) would leak to the console instead of
        # the probe file. Every branch must carry its own redirect.
        $script:probe | Should -Not -Match 'else \(echo [^)]*\) >>'
        $script:probe | Should -Match 'echo explorer=0 >> "%PROBE_OUT%"'
        $script:probe | Should -Match 'echo network=pending >> "%PROBE_OUT%"'
    }

    It 'runs the installer discovery in cli mode and fails loudly when it is missing' {
        $script:probe | Should -Match 'MICPE-Setup\.wcs.*-cli -discoveronly'
        $script:probe | Should -Match 'MICPE_PROBE_FILE=%PROBE_OUT%'
        $script:probe | Should -Match 'echo installer_scan=0 >> "%PROBE_OUT%"'
    }

    It 'deploys the found source to the largest free volume when data disks are attached' {
        # plan Task 17 Step 6: the deploy step reads the installer_path the
        # discovery wrote, picks the biggest free volume that is not the
        # source, the PE or the probe share, and runs -cli -deploy.
        $script:probe | Should -Match 'installer_path='
        $script:probe | Should -Match '-cli -deploy'
        $script:probe | Should -Match 'installer_boot=1'
        $script:probe | Should -Match 'EFI\\Microsoft\\Boot\\BCD'
    }

    It 'skips the deploy when no source was found or no target exists' {
        $script:probe | Should -Match 'if not defined DEPLOY_SRC goto :skip_deploy'
        $script:probe | Should -Match 'if not defined DEPLOY_TARGET goto :skip_deploy'
        $script:probe | Should -Match ':skip_deploy'
    }

    It 'writes every key the stage tables assert' {
        . (Join-Path $repoRoot 'src/ci/Assert-Probe.ps1')
        $keys = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($stage in 'm1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7') {
            foreach ($key in (Get-StageProbeExpect -Stage $stage).Keys) { $null = $keys.Add($key) }
        }
        foreach ($key in $keys) {
            if ($key -in @('size_wim', 'size_iso')) {
                continue   # written by the build host, not the PE probe
            }
            if ($key -eq 'installer_deploy') {
                # Written by the .wcs (-cli -deploy) that probe.cmd invokes,
                # not by a literal echo in probe.cmd itself.
                $script:probe | Should -Match '-cli -deploy' -Because 'probe.cmd must trigger the deploy that writes installer_deploy'
                continue
            }
            $script:probe | Should -Match ([regex]::Escape($key)) -Because "probe.cmd must emit $key"
        }
    }
}
