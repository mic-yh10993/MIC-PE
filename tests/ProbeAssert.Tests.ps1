BeforeAll {
    . "$PSScriptRoot/../src/ci/Assert-Probe.ps1"
    $script:TempRoot = [System.IO.Path]::GetTempPath()
}

Describe 'Read-ProbeFile' {
    It 'parses key=value and ignores comments and blanks' {
        $f = New-TemporaryFile
        Set-Content -LiteralPath $f -Value @('# header', 'boot=1', '', 'explorer=1', 'ime=1')
        $probe = Read-ProbeFile -Path $f
        $probe.Keys.Count | Should -Be 3
        $probe['explorer'] | Should -Be '1'
    }

    It 'lets the last duplicate win' {
        $f = New-TemporaryFile
        Set-Content -LiteralPath $f -Value @('uwp_launch=0', 'uwp_launch=1')
        (Read-ProbeFile -Path $f)['uwp_launch'] | Should -Be '1'
    }

    It 'keeps values containing equals signs' {
        $f = New-TemporaryFile
        Set-Content -LiteralPath $f -Value @('installer_name=MICPE=v1')
        (Read-ProbeFile -Path $f)['installer_name'] | Should -Be 'MICPE=v1'
    }

    It 'returns an empty table for a missing file' {
        (Read-ProbeFile -Path (Join-Path $script:TempRoot 'micpe-absent-probe.txt')).Count | Should -Be 0
    }

    It 'tolerates CRLF and stray whitespace' {
        $f = New-TemporaryFile
        Set-Content -LiteralPath $f -Value "  boot = 1  `r`n"
        (Read-ProbeFile -Path $f)['boot'] | Should -Be '1'
    }
}

Describe 'Assert-ProbeResult' {
    It 'returns every failing key with expected and actual' {
        $probe = @{ explorer = '1'; ime = '0'; dwm = '' }
        $bad = Assert-ProbeResult -Probe $probe -Expected @{ explorer = '1'; ime = '1'; dwm = '*'; network = '*' }
        $bad.Count | Should -Be 3
        ($bad -join "`n") | Should -Match 'ime'
        ($bad -join "`n") | Should -Match 'dwm'
        ($bad -join "`n") | Should -Match 'network'
    }

    It 'passes when everything matches' {
        (Assert-ProbeResult -Probe @{ a = '1'; b = 'x' } -Expected @{ a = '1'; b = '*' }).Count | Should -Be 0
    }

    It 'reports a missing key distinctly from a wrong value' {
        $bad = Assert-ProbeResult -Probe @{ a = '2' } -Expected @{ a = '1'; b = '1' }
        ($bad -join "`n") | Should -Match "a: expected '1', got '2'"
        ($bad -join "`n") | Should -Match "b: missing"
    }
}

Describe 'Get-StageProbeExpect' {
    It 'm1 only requires boot and share' {
        $expect = Get-StageProbeExpect -Stage 'm1'
        @($expect.Keys | Sort-Object) | Should -Be @('boot', 'share')
        $expect.Count | Should -Be 2
    }

    It 'm4 only requires what an m4 image can produce (no shell yet)' {
        # run 44135105700: an m4 image has no PECMD.EXE, so the cmd
        # fallback never starts Explorer; explorer / dwm / shell_ready
        # and the uwp_launch_* keys can never be 1 there. They are
        # verified at m5 (PECMD arrives with the payload) and m7.
        # Drive letters are asserted from m4 on (user decision
        # 2026-11-17 23:43); in the CI harness there is no installed
        # Windows volume, so win_drive=none and drive_fixed=0.
        $expect = Get-StageProbeExpect -Stage 'm4'
        @($expect.Keys | Sort-Object) | Should -Be @('boot', 'drive_fixed', 'ime', 'pe_drive', 'share', 'uwp_appx', 'win_drive')
        $expect.Count | Should -Be 7
    }

    It 'm5, m6 and m7 carry the drive-letter keys too' {
        foreach ($stage in 'm5', 'm6', 'm7') {
            $expect = Get-StageProbeExpect -Stage $stage
            $expect['pe_drive'] | Should -Be 'X'
            $expect['win_drive'] | Should -Be 'none'
            $expect['drive_fixed'] | Should -Be '0'
        }
    }

    It 'all maps to the m7 expectations' {
        $fromAll = Get-StageProbeExpect -Stage 'all'
        $fromM7 = Get-StageProbeExpect -Stage 'm7'
        @($fromAll.Keys | Sort-Object) | Should -Be @($fromM7.Keys | Sort-Object)
        foreach ($key in $fromM7.Keys) { $fromAll[$key] | Should -Be $fromM7[$key] }
    }

    It 'm7 is a superset of every earlier stage' {
        $m7 = Get-StageProbeExpect -Stage 'm7'
        foreach ($stage in 'm1', 'm2', 'm3', 'm4', 'm5', 'm6') {
            foreach ($key in (Get-StageProbeExpect -Stage $stage).Keys) {
                $m7.ContainsKey($key) | Should -BeTrue -Because "m7 must cover $stage key $key"
            }
        }
    }

    It 'returns a copy so callers cannot mutate the table' {
        $expect = Get-StageProbeExpect -Stage 'm1'
        $expect['boot'] = 'tampered'
        (Get-StageProbeExpect -Stage 'm1')['boot'] | Should -Be '1'
    }
}
