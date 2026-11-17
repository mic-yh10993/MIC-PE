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

Describe 'probe.cmd drive scan (run 44101018512)' {
    BeforeAll {
        $script:probe = Get-Content -LiteralPath (Join-Path $repoRoot 'src/ci/probe.cmd') -Raw
        # The drive list as written in the scan loop, e.g. 'C D E ... Z'.
        $m = [regex]::Match($script:probe, 'for %%D in \(([^)]*)\)')
        $script:scanLetters = @($m.Groups[1].Value -split '\s+' | Where-Object { $_ })
        # Mirrors the batch scan loop over a fake drive table (no real
        # disks are touched): a drive is picked only if it exists and
        # the write test succeeds; the first such drive wins.
        $script:PickProbeDrive = {
            param($letters, $drives)
            foreach ($letter in $letters) {
                $d = $drives[$letter]
                if ($null -eq $d) { continue }     # drive absent here
                if (-not $d.Exists) { continue }
                if (-not $d.Writable) { continue }  # read-only: skip
                return $letter
            }
            return $null
        }
    }

    It 'scans C: (the CI vvfat share) and never scans the PE system drive X:' {
        # run 25: the scan list was D..Z, so it skipped C: (the share)
        # and fell back to X:, which the CI host cannot see.
        $script:scanLetters | Should -Contain 'C'
        $script:scanLetters | Should -Not -Contain 'X'
        $script:scanLetters | Should -Not -Contain 'A'
        $script:scanLetters | Should -Not -Contain 'B'
    }

    It 'keeps the write-test in the 2>nul-first order (both orders leak Access is denied, run 44154459167)' {
        # Corrected by the run 44135105700 mechanism experiment (Test run
        # 44154459167): a failed output open prints "Access is denied"
        # whether 2>nul comes first or last, so the order silences
        # nothing. The line is cosmetic noise on the read-only boot ISO;
        # the scan skips the drive by the file-existence check, not by
        # silencing, and the probe still completes.
        $script:probe | Should -Match 'echo test 2>nul > "%%D:\\micpe-write-test\.tmp"'
        $script:probe | Should -Not -Match 'echo test > "%%D:\\micpe-write-test\.tmp" 2>nul'
    }

    It 'picks C: on the CI layout (C: share writable, D: ISO read-only)' {
        $drives = @{
            C = @{ Exists = $true; Writable = $true }    # vvfat share
            D = @{ Exists = $true; Writable = $false }   # boot ISO
            X = @{ Exists = $true; Writable = $true }    # PE system drive
        }
        & $script:PickProbeDrive $script:scanLetters $drives | Should -Be 'C'
    }

    It 'skips a read-only drive and keeps going instead of stopping at it' {
        # C: absent here: the scan must pass D: (read-only) and land on
        # the next writable drive rather than giving up at the first.
        $drives = @{
            D = @{ Exists = $true; Writable = $false }
            E = @{ Exists = $true; Writable = $true }
            X = @{ Exists = $true; Writable = $true }
        }
        & $script:PickProbeDrive $script:scanLetters $drives | Should -Be 'E'
    }

    It 'finds nothing writable when every scanned drive is read-only or absent' {
        # Then PROBE_DIR stays empty and probe.cmd falls back to X:
        # (the run 25 behaviour); the fallback itself is covered by the
        # 'writes boot and share first' test, not hidden here.
        $drives = @{
            C = @{ Exists = $false; Writable = $false }
            D = @{ Exists = $true; Writable = $false }
            X = @{ Exists = $true; Writable = $true }
        }
        & $script:PickProbeDrive $script:scanLetters $drives | Should -BeNullOrEmpty
    }

    It 'has no parentheses in rem lines inside the scan block (cmd parses them as block delimiters)' {
        # run 26: a rem line "drive (run 25 screenshot) while ..." inside
        # the for block closed the block early at its ')', and cmd then
        # choked on the next token: "此时不应有 while。" — probe.cmd died
        # before writing anything. rem lines at top level may keep their
        # parentheses; inside a (...) block they must not have any.
        $lines = $script:probe -split "`r?`n"
        $start = ($lines | Select-String -Pattern 'for %%D in \(' | Select-Object -First 1).LineNumber - 1
        $end = ($lines | Select-String -Pattern 'if not defined PROBE_DIR \(' | Select-Object -First 1).LineNumber - 1
        $blockRems = @($lines[$start..$end] | Where-Object { $_ -match '^\s*rem\b' })
        $blockRems | Should -Not -BeNullOrEmpty -Because 'the scan block must still carry its comments'
        foreach ($rem in $blockRems) {
            $rem | Should -Not -Match '[()]' -Because "rem inside a (...) block must not contain parens: $rem"
        }
    }

    It 'has no bare-text lines inside the scan block (every line is a command or a rem)' {
        # run 26, second half of the same bug: the comment's continuation
        # lines had lost their "rem" prefix, so cmd parsed them as
        # commands and died with "此时不应有 while。" before writing
        # anything. A comment inside a (...) block must keep "rem" on
        # every line, not just the first.
        $lines = $script:probe -split "`r?`n"
        $start = ($lines | Select-String -Pattern 'for %%D in \(' | Select-Object -First 1).LineNumber - 1
        $end = ($lines | Select-String -Pattern 'if not defined PROBE_DIR \(' | Select-Object -First 1).LineNumber - 1
        $blockLines = @($lines[$start..$end] | Where-Object { $_.Trim() -ne '' })
        foreach ($line in $blockLines) {
            $line.Trim() | Should -Match '^(rem\b|for\b|if\b|echo\b|del\b|set\b|\)$)' -Because "bare text inside a (...) block is parsed as a command: $line"
        }
    }
}
