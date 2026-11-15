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
        $script:probe | Should -Match 'SystemSettings'
        $script:probe | Should -Match 'Microsoft\.Photos'
        $script:probe | Should -Match 'Microsoft\.ZuneMusic'
        $script:probe | Should -Match 'uwp_launch_settings'
        $script:probe | Should -Match 'uwp_launch_photos'
        $script:probe | Should -Match 'uwp_launch_media'
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

    It 'writes every key the stage tables assert' {
        . (Join-Path $repoRoot 'src/ci/Assert-Probe.ps1')
        $keys = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($stage in 'm1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7') {
            foreach ($key in (Get-StageProbeExpect -Stage $stage).Keys) { $null = $keys.Add($key) }
        }
        foreach ($key in $keys) {
            if ($key -in @('size_wim', 'size_iso', 'installer_scan', 'installer_deploy')) {
                continue   # written by the build host / installer, not the PE probe
            }
            $script:probe | Should -Match ([regex]::Escape($key)) -Because "probe.cmd must emit $key"
        }
    }
}
