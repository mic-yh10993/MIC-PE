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

    It 'fails the run when probe_failed=1 even if every expected key matches' {
        # Run 44285721257: the watchdog writes probe_failed=1 when the
        # probe stalls or dies mid-run. It ends the host wait early, but
        # it never passes a run.
        $probe = @{ explorer = '1'; ime = '1'; probe_failed = '1' }
        $bad = Assert-ProbeResult -Probe $probe -Expected @{ explorer = '1'; ime = '1' }
        $bad.Count | Should -Be 1
        ($bad -join "`n") | Should -Match 'probe_failed'
    }

    It 'ignores probe_failed=0' {
        $probe = @{ explorer = '1'; probe_failed = '0' }
        (Assert-ProbeResult -Probe $probe -Expected @{ explorer = '1' }).Count | Should -Be 0
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

    It 'm5 and m7 assert the grouped feature override is off and explorer survives to the end (run 50, run 51)' {
        # Run 50: the CI build imports an override forcing
        # DisableWin10Taskbar (42537950) off; the stage asserts the
        # probe read it back as 0x0, and asserts explorer is still
        # alive at probe end (the old explorer=1 is set while it is
        # still starting, so it cannot prove the fix worked). Run 51:
        # the flat entry run 50 wrote was ignored by the loader, so
        # the override is written grouped and the stage asserts the
        # three group keys instead of the flat one.
        foreach ($stage in 'm5', 'm7') {
            $expect = Get-StageProbeExpect -Stage $stage
            $expect['fm_42537950_group0'] | Should -Be '0x0'
            $expect['fm_42537950_group15'] | Should -Be '0x0'
            $expect['fm_42537950_group9'] | Should -Be '0x0'
            $expect.Keys | Should -Not -Contain 'fm_42537950_state'
            $expect['explorer_end'] | Should -Be '1'
        }
        (Get-StageProbeExpect -Stage 'm5').Count | Should -Be 15 -Because 'm5 had 11 assertions before run 50, 13 in run 50, and the flat key is replaced by three group keys in run 51'
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

Describe 'Merge-ProbeFiles' {
    It 'returns the union of the share file and the local copy (run 48)' {
        # Run 47, counted from the two artifact files: the share file
        # held 55 keys the local copy lacks (the early share-only keys
        # and the poll markers), the local copy held 39 keys only it
        # has (payload, brand, the end snapshot). Neither file alone
        # judges a run; the merge holds both.
        $share = New-TemporaryFile
        $local = New-TemporaryFile
        Set-Content -LiteralPath $share -Value @('boot=1', 'explorer=1', 'shell_ready=1', 'appxsvc=0')
        Set-Content -LiteralPath $local -Value @('boot=1', 'payload=1', 'brand=1')
        $merged = Merge-ProbeFiles -SharePath $share -LocalPath $local
        $merged['explorer'] | Should -Be '1' -Because 'a share-only key survives the merge'
        $merged['shell_ready'] | Should -Be '1'
        $merged['payload'] | Should -Be '1' -Because 'a local-only key survives the merge'
        $merged['brand'] | Should -Be '1'
        $merged['boot'] | Should -Be '1'
        $merged['appxsvc'] | Should -Be '0'
    }

    It 'lets the local copy win on conflict (it holds the newest write)' {
        # The probe echoes every key to both files; the local copy is
        # refreshed by a whole-file copy at every section sync, so its
        # value of a twice-written key (the per-app markers) is the
        # newest one.
        $share = New-TemporaryFile
        $local = New-TemporaryFile
        Set-Content -LiteralPath $share -Value @('mark_xcheck_enter=12:43:25.81', 'explorer=1')
        Set-Content -LiteralPath $local -Value @('mark_xcheck_enter=12:44:16.34', 'explorer=1')
        $merged = Merge-ProbeFiles -SharePath $share -LocalPath $local
        $merged['mark_xcheck_enter'] | Should -Be '12:44:16.34'
    }

    It 'tolerates a missing file on either side' {
        $share = New-TemporaryFile
        Set-Content -LiteralPath $share -Value @('boot=1', 'explorer=1')
        $missing = Join-Path $script:TempRoot 'micpe-absent-probe.txt'
        $merged = Merge-ProbeFiles -SharePath $share -LocalPath $missing
        $merged['explorer'] | Should -Be '1'
        $merged = Merge-ProbeFiles -SharePath $missing -LocalPath $share
        $merged['explorer'] | Should -Be '1'
        (Merge-ProbeFiles -SharePath $missing -LocalPath $missing).Count | Should -Be 0
    }

    It 'trims the trailing-space difference between the two copies' {
        # The two files' copies of one line differ by a trailing space
        # (run 47: share values end in one space, local values in
        # two) — the merged value must be the bare value either way.
        $share = New-TemporaryFile
        $local = New-TemporaryFile
        Set-Content -LiteralPath $share -Value @('payload=1 ')
        Set-Content -LiteralPath $local -Value @('payload=1  ')
        $merged = Merge-ProbeFiles -SharePath $share -LocalPath $local
        $merged['payload'] | Should -Be '1'
    }
}
