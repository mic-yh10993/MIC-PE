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
        $expect.Keys | Should -Be @('boot', 'share')
    }

    It 'all maps to the m7 expectations' {
        $fromAll = Get-StageProbeExpect -Stage 'all'
        $fromM7 = Get-StageProbeExpect -Stage 'm7'
        $fromAll.Keys | Should -Be $fromM7.Keys
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
