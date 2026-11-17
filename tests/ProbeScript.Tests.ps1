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

    It 'writes every key the stage tables assert' {
        . (Join-Path $repoRoot 'src/ci/Assert-Probe.ps1')
        $keys = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($stage in 'm1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7') {
            foreach ($key in (Get-StageProbeExpect -Stage $stage).Keys) { $null = $keys.Add($key) }
        }
        foreach ($key in $keys) {
            if ($key -in @('size_wim', 'size_iso', 'installer_deploy')) {
                continue   # written by the build host / M7 QEMU harness, not the PE probe
            }
            $script:probe | Should -Match ([regex]::Escape($key)) -Because "probe.cmd must emit $key"
        }
    }
}
