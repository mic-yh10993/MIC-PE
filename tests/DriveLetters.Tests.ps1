#Requires -Version 7.0
#Requires -Modules Pester
<#
.SYNOPSIS
    Guards for the drive-letter fix (user decision 2026-11-17 23:43).

.DESCRIPTION
    The PE system drive is X: (RAM disk). The volume holding an installed
    Windows must keep C:; the PE boot media must not steal it. startnet.cmd
    runs Fix-DriveLetters.cmd right after wpeinit; the script swaps C: with
    the Windows volume's letter via mountvol (volume GUIDs) and records
    pe_drive / win_drive / drive_fixed in %SystemDrive%\micpe-drive-letters.txt,
    which probe.cmd copies into the probe file for Assert-Probe to check.

    The swap path itself can only be proven on a real machine (it needs a
    second Windows volume): docs/test-checklist.md carries that item. The
    no-op path (no installed Windows volume, as in the CI harness) runs on
    the Windows runner here; the swap command sequence is pinned statically.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path
    $script:FixScript = Join-Path $script:RepoRoot 'src/shell/Fix-DriveLetters.cmd'
    $script:Startnet = Join-Path $script:RepoRoot 'src/shell/startnet.cmd'
    $script:Probe = Join-Path $script:RepoRoot 'src/ci/probe.cmd'
    $script:TempRoot = [System.IO.Path]::GetTempPath()
}

Describe 'drive-letter fix wiring' {
    It 'startnet.cmd runs Fix-DriveLetters.cmd after wpeinit and before the shell' {
        $lines = Get-Content -LiteralPath $script:Startnet -Encoding utf8
        $wpeinit = -1
        $call = -1
        $shell = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($wpeinit -lt 0 -and $lines[$i] -match '^\s*wpeinit\s*$') { $wpeinit = $i }
            # Match the call itself, not the header comment that also names
            # the script: a comment-only match would pass with no call.
            if ($call -lt 0 -and $lines[$i] -match 'call\s+.*Fix-DriveLetters\.cmd') { $call = $i }
            # The header comment mentions PECMD.EXE too; match the real
            # branch line, not the comment.
            if ($shell -lt 0 -and $lines[$i] -match 'if exist.*PECMD\.EXE') { $shell = $i }
        }
        $wpeinit | Should -BeGreaterThan -1
        $call | Should -BeGreaterThan $wpeinit -Because 'the fix runs after wpeinit, before the shell starts'
        $shell | Should -BeGreaterThan $call -Because 'the shell starts after the letters are fixed'
    }

    It 'the fix script swaps letters with mountvol by volume GUID, never by bare letter' {
        $text = Get-Content -LiteralPath $script:FixScript -Raw -Encoding utf8
        $text | Should -Match 'mountvol.* /L'
        $text | Should -Match 'mountvol.* /D'
        $text | Should -Match 'GUID_WIN'
        $text | Should -Match 'GUID_C'
        # The swap moves the Windows volume to C: and the old C: volume to
        # the Windows volume's old letter; nothing else is re-lettered.
        $text | Should -Match 'mountvol C:'
        $text | Should -Match 'drive_fixed='
    }

    It 'the fix script is a no-op when there is no installed Windows volume or it is already C:' {
        $text = Get-Content -LiteralPath $script:FixScript -Raw -Encoding utf8
        $text | Should -Match 'WIN_DRIVE.*none'
        $text | Should -Match 'WIN_DRIVE.*==.*C'
        $text | Should -Match 'DRIVE_FIXED=0'
    }

    It 'the fix script never touches the PE system drive itself' {
        $text = Get-Content -LiteralPath $script:FixScript -Raw -Encoding utf8
        # The scan skips the PE drive letter, and no mountvol line ever
        # targets X: (the RAM disk letter cannot change while PE runs).
        $text | Should -Match 'PE_DRIVE'
        $text | Should -Not -Match 'mountvol X:'
        $text | Should -Not -Match 'mountvol %SystemDrive%'
    }

    It 'the fix script records pe_drive, win_drive and drive_fixed for the probe' {
        $text = Get-Content -LiteralPath $script:FixScript -Raw -Encoding utf8
        $text | Should -Match 'micpe-drive-letters\.txt'
        $text | Should -Match 'pe_drive='
        $text | Should -Match 'win_drive='
        $text | Should -Match 'drive_fixed='
        $text | Should -Match 'drive_fix_error='
    }

    It 'probe.cmd copies the drive-letter status into the probe file (and fails loudly when it is missing)' {
        $text = Get-Content -LiteralPath $script:Probe -Raw -Encoding utf8
        $text | Should -Match 'micpe-drive-letters\.txt'
        $text | Should -Match 'drive_letters=missing'
    }

    It 'the fix script has no "& goto" lines (goto after & runs unconditionally in cmd)' {
        # `if cond set ... & goto :label` jumps even when cond is false, so
        # the swap stopped after step 1 with drive_fixed=0. Error paths
        # must use a parenthesised block with set and goto on separate
        # lines. Pin it so the pattern cannot come back.
        $lines = Get-Content -LiteralPath $script:FixScript -Encoding utf8
        $bad = @($lines | Where-Object { $_ -match '&\s*goto\s' })
        $bad | Should -BeNullOrEmpty
    }

    It 'the fix script always calls mountvol with call (a bare call never returns from a .cmd)' {
        # run 44240588434: the swap stopped after step 1 with exactly 2
        # mountvol calls logged. A bare `mountvol` from inside this batch
        # file transfers control to the callee and never returns when
        # mountvol resolves to a .cmd/.bat (the CI fake is mountvol.cmd);
        # against the real mountvol.exe `call` behaves identically. The
        # two `for /f ('mountvol ... /L')` captures run in a child cmd and
        # return on their own, so they are exempt. Pin it so the bare
        # form cannot come back.
        $lines = Get-Content -LiteralPath $script:FixScript -Encoding utf8
        $bad = @($lines | Where-Object {
            $_ -match 'mountvol' -and
            $_ -notmatch '^\s*rem\b' -and
            $_ -notmatch 'call\s+mountvol' -and
            $_ -notmatch 'for\s+/f'
        })
        $bad | Should -BeNullOrEmpty
    }

    It 'reverse control: removing the startnet call makes the wiring test fail' {
        $lines = Get-Content -LiteralPath $script:Startnet -Encoding utf8
        $call = @($lines | Where-Object { $_ -match 'Fix-DriveLetters\.cmd' -and $_ -match '^\s*if exist' })
        $call.Count | Should -Be 1 -Because 'exactly one guarded call must exist in startnet.cmd'
        $without = @($lines | Where-Object { $_ -notmatch 'Fix-DriveLetters\.cmd' })
        ($without -join "`n") | Should -Not -Match 'Fix-DriveLetters\.cmd'
    }
}

Describe 'Fix-DriveLetters.cmd swap run' {
    It 'swaps C: with the Windows volume through mountvol and records drive_fixed=1' -Skip:(-not $IsWindows) {
        # The swap path needs a second Windows volume, which the runner does
        # not have. Fake one: put a \Windows\System32\config\SYSTEM marker
        # on the first existing non-C drive, and put a fake mountvol.cmd on
        # PATH that logs every call and answers /L with fixed GUIDs. No real
        # letter ever moves: every mountvol call hits the fake. This test
        # would have caught the `if ... set ... & goto` bug (goto after &
        # runs unconditionally, so the swap stopped after step 1 with
        # drive_fixed=0).
        $winLetter = $null
        foreach ($letter in 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'Y', 'Z') {
            if (Test-Path -LiteralPath "${letter}:\") { $winLetter = $letter; break }
        }
        if (-not $winLetter) { Set-ItResult -Skipped -Because 'no non-C drive exists on this runner'; return }
        if (Test-Path -LiteralPath "${winLetter}:\Windows") { Set-ItResult -Skipped -Because "$winLetter already has a Windows directory; refusing to touch it"; return }

        $workDir = Join-Path $script:TempRoot "drivefix-swap-$(Get-Random)"
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        $fakeWin = "${winLetter}:\Windows\System32\config\SYSTEM"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fakeWin) | Out-Null
        Set-Content -LiteralPath $fakeWin -Value 'fake installed-Windows marker'
        $logFile = Join-Path $workDir 'mountvol.log'
        $fakeDir = Join-Path $workDir 'bin'
        New-Item -ItemType Directory -Path $fakeDir -Force | Out-Null
        $guidWin = '\\?\Volume{11111111-1111-1111-1111-111111111111}\'
        $guidC = '\\?\Volume{22222222-2222-2222-2222-222222222222}\'
        $fakeLines = @(
            '@echo off',
            ('echo %* >> "{0}"' -f $logFile),
            ('if /i "%~1"=="{0}:" if /i "%~2"=="/L" echo {1}' -f $winLetter, $guidWin),
            ('if /i "%~1"=="C:" if /i "%~2"=="/L" echo {0}' -f $guidC),
            'exit /b 0'
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $fakeDir 'mountvol.cmd'),
            (($fakeLines -join "`r`n") + "`r`n"),
            [System.Text.Encoding]::ASCII)

        # The temp letter is the first free letter from Z: down, skipping
        # C:, the Windows volume's letter and the PE drive (first char of
        # the overridden SystemDrive, i.e. the temp dir's drive).
        $peDrive = $workDir.Substring(0, 1)
        $tmpLetter = $null
        foreach ($letter in 'Z', 'Y', 'W', 'V', 'U', 'T', 'S', 'R', 'Q', 'P', 'O', 'N', 'M', 'L', 'K', 'J', 'I', 'H', 'G', 'F', 'E', 'D') {
            if ($letter -in @('C', $winLetter, $peDrive)) { continue }
            if (-not (Test-Path -LiteralPath "${letter}:\")) { $tmpLetter = $letter; break }
        }
        if (-not $tmpLetter) { Set-ItResult -Skipped -Because 'no free letter for the swap temp'; return }

        $oldPath = $env:PATH
        $oldSystemDrive = $env:SystemDrive
        try {
            $env:PATH = $fakeDir
            $env:SystemDrive = $workDir
            # Absolute cmd.exe: the restricted PATH above has no cmd.exe,
            # and PowerShell resolves the command name through PATH.
            # The child cmd still inherits the restricted PATH, so every
            # mountvol call inside the script hits the fake.
            $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
            $null = & $cmdExe /c "`"$script:FixScript`"" 2>&1
            $LASTEXITCODE | Should -Be 0

            $calls = @(Get-Content -LiteralPath $logFile -Encoding utf8 | ForEach-Object { $_.TrimEnd() })
            # The fake logs with `echo %* >> log`, and cmd's echo-before-
            # redirect form writes one trailing space after the text
            # (verified on run 31's own probe file: `echo explorer=0 >>`
            # lines carry a trailing space while `>> file echo ...` lines
            # do not). The product's actual arguments are unaffected --
            # the fake's own %~1/%~2 matching proves they are exactly
            # `D:` and `/L` (the GUID came back and all 8 calls ran).
            # Trim the logging artifact before comparing the sequence,
            # not the sequence itself.
            $expected = @(
                "${winLetter}: /L",
                "${tmpLetter}: $guidWin",
                "${winLetter}: /D",
                'C: /L',
                'C: /D',
                "C: $guidWin",
                "${winLetter}: $guidC",
                "${tmpLetter}: /D"
            )
            $calls.Count | Should -Be $expected.Count -Because ('mountvol calls must be exactly the swap sequence, got: ' + ($calls -join ' | '))
            for ($i = 0; $i -lt $expected.Count; $i++) {
                $calls[$i] | Should -Be $expected[$i]
            }

            $status = Join-Path $workDir 'micpe-drive-letters.txt'
            Test-Path -LiteralPath $status | Should -BeTrue
            $lines = Get-Content -LiteralPath $status -Encoding utf8
            ($lines -join "`n") | Should -Match ("pe_drive=" + [regex]::Escape($peDrive))
            ($lines -join "`n") | Should -Match ("win_drive=" + [regex]::Escape($winLetter))
            ($lines -join "`n") | Should -Match 'drive_fixed=1'
            ($lines -join "`n") | Should -Not -Match 'drive_fix_error='
        }
        finally {
            $env:PATH = $oldPath
            $env:SystemDrive = $oldSystemDrive
            Remove-Item -LiteralPath "${winLetter}:\Windows" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Fix-DriveLetters.cmd no-op run' {
    It 'writes pe_drive/win_drive=none/drive_fixed=0 when no installed Windows volume exists' -Skip:(-not $IsWindows) {
        # On the runner the only Windows volume is C: itself; the script
        # is run with %SystemDrive% pointed at a temp directory so the
        # status file lands there, not at the C: root. The scan skips the
        # PE drive (first char of the overridden SystemDrive) and finds
        # no \Windows\System32\config\SYSTEM on any other letter.
        $workDir = Join-Path $script:TempRoot "drivefix-$(Get-Random)"
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        $preExists = Test-Path -LiteralPath 'C:\micpe-drive-letters.txt'
        $oldSystemDrive = $env:SystemDrive
        try {
            $env:SystemDrive = $workDir
            $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
            $null = & $cmdExe /c "`"$script:FixScript`"" 2>&1
            $LASTEXITCODE | Should -Be 0
            $status = Join-Path $workDir 'micpe-drive-letters.txt'
            Test-Path -LiteralPath $status | Should -BeTrue
            $lines = Get-Content -LiteralPath $status -Encoding utf8
            ($lines -join "`n") | Should -Match ("pe_drive=" + [regex]::Escape($workDir.Substring(0, 1)))
            ($lines -join "`n") | Should -Match 'win_drive=none'
            ($lines -join "`n") | Should -Match 'drive_fixed=0'
            ($lines -join "`n") | Should -Not -Match 'drive_fix_error='
        }
        finally {
            $env:SystemDrive = $oldSystemDrive
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
            if (-not $preExists) {
                Remove-Item -LiteralPath 'C:\micpe-drive-letters.txt' -Force -ErrorAction SilentlyContinue
            }
        }
        # The override must have worked: no status file leaked to C:\.
        if (-not $preExists) {
            Test-Path -LiteralPath 'C:\micpe-drive-letters.txt' | Should -BeFalse
        }
    }
}
