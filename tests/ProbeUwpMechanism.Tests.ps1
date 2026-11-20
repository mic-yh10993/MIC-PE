#Requires -Version 7.0
#Requires -Modules Pester
<#
.SYNOPSIS
    Mechanism experiment for the run 28 probe stall in :probe_uwp.

.DESCRIPTION
    Build run 44161901638 (stage m4, head d12c6a3) passed its 4 relaxed m4
    assertions, but the probe file stopped after uwp_appx=1: uwp_launch_*,
    payload, brand, installer and probe_done were never written, the
    verify loop waited the full 45 minutes for probe_done=1, and the
    screenshots froze on the cmd prompt with no Explorer window. The probe
    died or stalled inside the first `call :probe_uwp CalculatorApp ...`.

    Test run 44178703900 (branch probe-uwp-15, head 78fbfa9) ran this
    experiment on a windows-2025 runner under a real cmd.exe:

    - U1 passed (21.43s): the genuine uwp section completes with
      Explorer running; all three launches 0 (Server has no Calculator),
      probe_uwp_done=1. The batch logic itself does not stall.
    - U1b passed (36.59s) but did NOT reproduce the no-shell condition:
      explorer.exe was still running after Stop-Process plus a 15-second
      wait, Windows restarts the shell automatically, so it re-ran U1
      with a fresh Explorer. Whether `start explorer.exe` blocks with
      no shell present is therefore still unproven directly; the guard
      rests on elimination (the `start` line is the only shell-dependent
      line in the subroutine) plus the design statement in
      Assert-Probe.ps1 that m4 cannot launch UWP apps. Run 29 reaching
      probe_done is the end-to-end proof.
    - U2 passed (21.29s): with the `start` line stubbed out the section
      completes, as expected.
    - U3 FAILED, and that failure is the second bug: the Calculator
      target arrived at the subroutine as
      `...8wekyb3d8bbweApp`, the bang dropped by delayed expansion, so
      the launch could never resolve. The fix switches delayed expansion
      off around the three calls (U3b proves the pattern) and adds an
      Explorer guard at the top of :probe_uwp (U4 proves it skips the
      launch and the probe still completes).

    The fix in src/ci/probe.cmd:
    - :probe_uwp first checks for a running explorer.exe and returns 1
      ("not launchable here") without attempting the launch when there
      is no shell. At m4 the caller then records 0 and the probe runs on
      to probe_done; at m7, with the PECMD shell up, the launch is
      attempted as before.
    - The three `call :probe_uwp` lines sit inside `setlocal
      DisableDelayedExpansion` / `endlocal`, so the bang in the
      AppUserModelId survives into the launch target.

    Build run 44285721257 then hung inside the Photos launch itself:
    the old code slept a fixed 7 seconds and checked once, and Photos
    never appeared, so the probe never returned from the subroutine.
    The fix replaces the blind sleep with a bounded poll (one check a
    second, at most ten) and adds U5: with tasklist stubbed to report
    the app running, all three launches return 1 on the first poll.
    U1 now takes about 40 seconds (three apps times ten polls) and
    still fits the 150-second timeout.

    All cmd.exe tests skip on Linux. The two static tests run anywhere:
    they pin the guard and the DisableDelayedExpansion wrapper in the
    committed probe.cmd so a future edit cannot silently drop them.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path
    $script:ProbePath = Join-Path $script:RepoRoot 'src/ci/probe.cmd'
    # SystemRoot is empty on Linux; the Windows-only paths below are
    # never used there (those tests skip), but BeforeAll still runs for
    # the static tests, so do not let Join-Path see a null parent.
    $script:CmdExe = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\cmd.exe' } else { 'cmd.exe' }
    $script:FindExe = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\find.exe' } else { 'find.exe' }
    $script:TasklistExe = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\tasklist.exe' } else { 'tasklist.exe' }
    # choice.exe is the poll's one-second wait (run 44319967017): the
    # work dir is the whole PATH for the test batch, so it must be
    # copied in like find/tasklist. ping.exe is no longer used by the
    # uwp section and is not copied.
    $script:ChoiceExe = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\choice.exe' } else { 'choice.exe' }

    # A CRLF batch file: cmd.exe treats a lone LF as part of the line.
    $script:WriteBatchCrlf = {
        param([string] $Path, [string[]] $Lines)
        $text = ($Lines -join "`r`n") + "`r`n"
        [System.IO.File]::WriteAllText($Path, $text, [System.Text.Encoding]::ASCII)
    }

    # Run a batch under a real cmd.exe with only find/tasklist/ping on
    # PATH (as in the PE image), and a hard timeout so a stall is
    # observed as TimedOut instead of hanging CI. explorer.exe still
    # resolves: CreateProcess searches the Windows directory before PATH.
    $script:InvokeCmdTimed = {
        param([string] $BatPath, [string] $WorkDir, [int] $TimeoutSec = 150)
        $oldPath = $env:PATH
        $stdoutFile = Join-Path $WorkDir 'cmd-out.txt'
        $stderrFile = Join-Path $WorkDir 'cmd-err.txt'
        try {
            $env:PATH = $WorkDir
            $proc = Start-Process -FilePath $script:CmdExe -ArgumentList '/c', $BatPath `
                -PassThru -NoNewWindow `
                -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
            $exited = $proc.WaitForExit($TimeoutSec * 1000)
            if (-not $exited) {
                try { $proc.Kill($true) } catch { }
                # The return value must be swallowed: a bare
                # WaitForExit leaks its boolean into the scriptblock
                # output, so the caller gets an array instead of the
                # result hashtable and every $result.* access throws
                # PropertyNotFoundException (CI run 44497333624: five
                # timeouts all surfaced as that error, hiding the
                # probe file that says where the batch died).
                $null = $proc.WaitForExit(10000)
            }
            $out = ''
            if (Test-Path -LiteralPath $stdoutFile) {
                $out = Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue
            }
            return @{ TimedOut = (-not $exited); ExitCode = $proc.ExitCode; Output = $out }
        }
        finally {
            $env:PATH = $oldPath
        }
    }

    $script:TestExplorerRunning = {
        return ($null -ne (Get-Process -Name 'explorer' -ErrorAction SilentlyContinue))
    }

    # The genuine probe.cmd uwp section (from `rem --- uwp` to just
    # before `rem --- payload`) plus the :probe_uwp subroutine from the
    # end of the file, with a marker after the three calls so completion
    # is observable. Found by content, not line number, so comment edits
    # above cannot shift the cut. No shutdown line, no payload/brand/
    # installer sections.
    # WARNING (run 46): the start anchor takes the LAST line matching
    # `^rem --- uwp` before payload — a later section header starting
    # with those words (the cross-check header did) silently moves
    # the cut past the guarded launches, so every section test then
    # runs only the tail. Section headers after the uwp header must
    # NOT start with `rem --- uwp`.
    $script:BuildUwpBatch = {
        param([string] $Path, [string] $ProbeOut, [switch] $StubStart)
        $probeLines = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
        $uwpStart = -1; $payloadStart = -1; $subStart = -1
        for ($i = 0; $i -lt $probeLines.Count; $i++) {
            if ($probeLines[$i] -match '^rem --- uwp') { $uwpStart = $i }
            if ($probeLines[$i] -match '^rem --- payload') { $payloadStart = $i; break }
        }
        for ($i = 0; $i -lt $probeLines.Count; $i++) {
            if ($probeLines[$i] -match '^:probe_uwp') { $subStart = $i; break }
        }
        if ($uwpStart -lt 0 -or $payloadStart -lt 0 -or $subStart -lt 0) {
            throw 'probe.cmd uwp cut is stale; the section markers moved'
        }
        $lines = @(
            '@echo off',
            'setlocal EnableDelayedExpansion',
            ('set "PROBE_OUT={0}"' -f $ProbeOut)
        ) + @($probeLines[$uwpStart..($payloadStart - 1)]) + @(
            ('echo probe_uwp_done=1 >> "%PROBE_OUT%"'),
            'exit /b 0'
        ) + @($probeLines[$subStart..($probeLines.Count - 1)])
        if ($StubStart) {
            $lines = @($lines | ForEach-Object {
                if ($_ -match '^\s*start "" explorer\.exe') { 'rem start stubbed for the bisection test' } else { $_ }
            })
        }
        & $script:WriteBatchCrlf $Path $lines
    }

    $script:NewWorkDir = {
        $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        Copy-Item -LiteralPath $script:FindExe -Destination (Join-Path $workDir 'find.exe')
        Copy-Item -LiteralPath $script:TasklistExe -Destination (Join-Path $workDir 'tasklist.exe')
        Copy-Item -LiteralPath $script:ChoiceExe -Destination (Join-Path $workDir 'choice.exe')
        return $workDir
    }
}

Describe 'probe.cmd uwp section stall (run 44161901638)' {
    It 'U1: completes the genuine uwp section with Explorer as the runner left it' -Skip:(-not $IsWindows) {
        $workDir = & $script:NewWorkDir
        $probeOut = Join-Path $workDir 'micpe-probe.txt'
        $bat = Join-Path $workDir 'probe-uwp.bat'
        try {
            $explorerBefore = & $script:TestExplorerRunning
            Write-Host "explorer running before: $explorerBefore"
            & $script:BuildUwpBatch $bat $probeOut
            $result = & $script:InvokeCmdTimed $bat $workDir
            Write-Host "cmd output: [$($result.Output)]"
            Write-Host "timed out: $($result.TimedOut); exit code: $($result.ExitCode)"
            $text = if (Test-Path -LiteralPath $probeOut) { Get-Content -LiteralPath $probeOut -Raw } else { '' }
            Write-Host "probe file: [$text]"
            Write-Host "explorer running after: $(& $script:TestExplorerRunning)"
            $result.TimedOut | Should -Be $false -Because 'a stall must surface as a timeout, not a hang of CI'
            $text | Should -Match 'uwp_launch_calculator=[01]'
            $text | Should -Match 'probe_uwp_done=1'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'U1b: completes the genuine uwp section with no Explorer running (the PE condition)' -Skip:(-not $IsWindows) {
        $workDir = & $script:NewWorkDir
        $probeOut = Join-Path $workDir 'micpe-probe.txt'
        $bat = Join-Path $workDir 'probe-uwp.bat'
        $explorerWasRunning = & $script:TestExplorerRunning
        try {
            if ($explorerWasRunning) {
                Stop-Process -Name 'explorer' -Force -ErrorAction SilentlyContinue
                for ($i = 0; $i -lt 15 -and (& $script:TestExplorerRunning); $i++) {
                    Start-Sleep -Seconds 1
                }
            }
            Write-Host "explorer running before: $(& $script:TestExplorerRunning) (was running: $explorerWasRunning)"
            & $script:BuildUwpBatch $bat $probeOut
            $result = & $script:InvokeCmdTimed $bat $workDir
            Write-Host "cmd output: [$($result.Output)]"
            Write-Host "timed out: $($result.TimedOut); exit code: $($result.ExitCode)"
            $text = if (Test-Path -LiteralPath $probeOut) { Get-Content -LiteralPath $probeOut -Raw } else { '' }
            Write-Host "probe file: [$text]"
            Write-Host "explorer running after: $(& $script:TestExplorerRunning)"
            $result.TimedOut | Should -Be $false -Because 'a stall must surface as a timeout, not a hang of CI'
            $text | Should -Match 'uwp_launch_calculator=[01]'
            $text | Should -Match 'probe_uwp_done=1'
        }
        finally {
            if ($explorerWasRunning -and -not (& $script:TestExplorerRunning)) {
                Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ErrorAction SilentlyContinue | Out-Null
            }
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'U2: completes the uwp section when the explorer launch is stubbed out' -Skip:(-not $IsWindows) {
        # Bisection control: if U1/U1b stall and this completes, the
        # `start explorer.exe` line (or the real Explorer behind it) is
        # the culprit, and the surrounding batch logic is exonerated.
        $workDir = & $script:NewWorkDir
        $probeOut = Join-Path $workDir 'micpe-probe.txt'
        $bat = Join-Path $workDir 'probe-uwp.bat'
        try {
            & $script:BuildUwpBatch $bat $probeOut -StubStart
            $result = & $script:InvokeCmdTimed $bat $workDir
            Write-Host "cmd output: [$($result.Output)]"
            Write-Host "timed out: $($result.TimedOut); exit code: $($result.ExitCode)"
            $text = if (Test-Path -LiteralPath $probeOut) { Get-Content -LiteralPath $probeOut -Raw } else { '' }
            Write-Host "probe file: [$text]"
            $result.TimedOut | Should -Be $false
            $text | Should -Match 'uwp_launch_calculator=0' -Because 'with the launch stubbed out no app can be running'
            $text | Should -Match 'probe_uwp_done=1'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'U3a: documents that delayed expansion strips the bang from the target' -Skip:(-not $IsWindows) {
        # Test run 44178703900: with delayed expansion on, the Calculator
        # target arrived at the subroutine with the bang dropped
        # (`...8wekyb3d8bbweApp`), so the launch could never resolve.
        # This pins why probe.cmd switches delayed expansion off around
        # the three launch calls; it asserts cmd behaviour, not our code.
        $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        $target = Join-Path $workDir 'target.txt'
        $bat = Join-Path $workDir 'bang.bat'
        try {
            $lines = @(
                '@echo off',
                'setlocal EnableDelayedExpansion',
                'call :show "shell:AppsFolder\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"',
                'exit /b 0',
                ':show',
                ('echo %~1 > "{0}"' -f $target),
                'exit /b 0'
            )
            & $script:WriteBatchCrlf $bat $lines
            $result = & $script:InvokeCmdTimed $bat $workDir -TimeoutSec 60
            Write-Host "cmd output: [$($result.Output)]"
            $result.TimedOut | Should -Be $false
            $text = Get-Content -LiteralPath $target -Raw
            Write-Host "target received: [$text]"
            $text | Should -Match 'Microsoft.WindowsCalculator_8wekyb3d8bbweApp'
            $text | Should -Not -Match '!'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'U3b: the fixed call pattern preserves the bang in the target' -Skip:(-not $IsWindows) {
        # The same call as U3a, but with delayed expansion switched off
        # around it, exactly as probe.cmd now does. The subroutine must
        # receive the AppUserModelId verbatim.
        $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        $target = Join-Path $workDir 'target.txt'
        $bat = Join-Path $workDir 'bang.bat'
        try {
            $lines = @(
                '@echo off',
                'setlocal EnableDelayedExpansion',
                'setlocal DisableDelayedExpansion',
                'call :show "shell:AppsFolder\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"',
                'endlocal',
                'exit /b 0',
                ':show',
                ('echo %~1 > "{0}"' -f $target),
                'exit /b 0'
            )
            & $script:WriteBatchCrlf $bat $lines
            $result = & $script:InvokeCmdTimed $bat $workDir -TimeoutSec 60
            Write-Host "cmd output: [$($result.Output)]"
            $result.TimedOut | Should -Be $false
            $text = Get-Content -LiteralPath $target -Raw
            Write-Host "target received: [$text]"
            $text | Should -Match 'Microsoft.WindowsCalculator_8wekyb3d8bbwe!App'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'U4: the Explorer guard skips the launch and the probe still completes' -Skip:(-not $IsWindows) {
        # The discriminating test for the guard: tasklist is stubbed to
        # report no processes, so the guard must see "no Explorer" and
        # return 1 at once. Without the guard the three calls would each
        # wait out the 7-second ping, 21 seconds minimum (U1/U2 took
        # 21.29-21.43s), so the 15-second bound separates the two.
        $workDir = & $script:NewWorkDir
        Remove-Item -LiteralPath (Join-Path $workDir 'tasklist.exe') -Force
        & $script:WriteBatchCrlf (Join-Path $workDir 'tasklist.bat') @('@echo off', 'exit /b 0')
        $probeOut = Join-Path $workDir 'micpe-probe.txt'
        $bat = Join-Path $workDir 'probe-uwp.bat'
        try {
            & $script:BuildUwpBatch $bat $probeOut
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = & $script:InvokeCmdTimed $bat $workDir -TimeoutSec 60
            $sw.Stop()
            $seconds = $sw.Elapsed.TotalSeconds
            Write-Host "cmd output: [$($result.Output)]"
            Write-Host "timed out: $($result.TimedOut); exit code: $($result.ExitCode); elapsed seconds: $seconds"
            $text = if (Test-Path -LiteralPath $probeOut) { Get-Content -LiteralPath $probeOut -Raw } else { '' }
            Write-Host "probe file: [$text]"
            $result.TimedOut | Should -Be $false
            # Run 46: the guard still skips the three guarded launches
            # at once, but the cross-check runs anyway (it has no
            # guard) and its bounded poll is 10 rounds x 1 s x 3 apps,
            # so the section takes ~30 s even though the guard is
            # instant. The <15 s bound died with the cross-check.
            $seconds | Should -BeLessThan 55 -Because 'guard instant plus the cross-check bounded poll'
            $text | Should -Match 'uwp_launch_calculator=0' -Because 'no shell means not launchable here, not a launch failure to retry'
            $text | Should -Match 'uwp_launch_photos=0'
            $text | Should -Match 'uwp_launch_media=0'
            $text | Should -Match 'xcheck_launch_calculator=0' -Because 'the cross-check still attempts all three without the guard'
            $text | Should -Match 'xcheck_launch_photos=0'
            $text | Should -Match 'xcheck_launch_media=0'
            $text | Should -Match 'probe_uwp_done=1'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'U5: returns 1 at once when the app is already running (run 44285721257)' -Skip:(-not $IsWindows) {
        # The poll's fast path: tasklist is stubbed to report every
        # queried image as running (it echoes its own arguments, so the
        # filter string itself matches the find), so each call must
        # return 1 on the first poll instead of waiting out ten steps.
        $workDir = & $script:NewWorkDir
        Remove-Item -LiteralPath (Join-Path $workDir 'tasklist.exe') -Force
        & $script:WriteBatchCrlf (Join-Path $workDir 'tasklist.bat') @('@echo off', 'echo %*')
        $probeOut = Join-Path $workDir 'micpe-probe.txt'
        $bat = Join-Path $workDir 'probe-uwp.bat'
        try {
            & $script:BuildUwpBatch $bat $probeOut
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = & $script:InvokeCmdTimed $bat $workDir -TimeoutSec 60
            $sw.Stop()
            $seconds = $sw.Elapsed.TotalSeconds
            Write-Host "cmd output: [$($result.Output)]"
            Write-Host "timed out: $($result.TimedOut); exit code: $($result.ExitCode); elapsed seconds: $seconds"
            $text = if (Test-Path -LiteralPath $probeOut) { Get-Content -LiteralPath $probeOut -Raw } else { '' }
            Write-Host "probe file: [$text]"
            $result.TimedOut | Should -Be $false
            $seconds | Should -BeLessThan 30 -Because 'a running app is found on the first poll; without the poll it would wait out the full window'
            $text | Should -Match 'uwp_launch_calculator=1'
            $text | Should -Match 'uwp_launch_photos=1'
            $text | Should -Match 'uwp_launch_media=1'
            $text | Should -Match 'probe_uwp_done=1'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'probe.cmd uwp guard and bang fix (static)' {
    It 'refuses to launch when Explorer is not running' {
        $probe = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
        $sub = -1; $start = -1
        for ($i = 0; $i -lt $probe.Count; $i++) {
            if ($probe[$i] -match '^:probe_uwp') { $sub = $i }
            if ($sub -ge 0 -and $probe[$i] -match '^\s*start "" explorer\.exe') { $start = $i; break }
        }
        $sub | Should -BeGreaterThan -1 -Because 'probe.cmd must still carry the :probe_uwp subroutine'
        $start | Should -BeGreaterThan $sub -Because 'the subroutine must still launch through explorer.exe'
        $head = $probe[$sub..($start - 1)] -join "`n"
        $head | Should -Match 'tasklist' -Because 'the guard checks the process list for a running Explorer'
        $head | Should -Match 'explorer\.exe' -Because 'the guard looks for Explorer specifically'
        $head | Should -Match 'exit /b 1' -Because 'the guard returns "not launchable" without attempting the launch'
    }

    It 'switches delayed expansion off around the uwp launch calls' {
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $calls = @([regex]::Matches($text, 'call :probe_uwp'))
        $calls.Count | Should -Be 3 -Because 'the probe launches exactly three UWP apps'
        $off = $text.IndexOf('setlocal DisableDelayedExpansion')
        $off | Should -BeGreaterThan -1 -Because 'the calls must run with delayed expansion off, or the bang is stripped (U3a)'
        $off | Should -BeLessThan $calls[0].Index -Because 'the switch-off must come before the first call'
        $on = $text.IndexOf('endlocal', $calls[0].Index)
        $on | Should -BeGreaterThan $calls[2].Index -Because 'delayed expansion must stay off until after the last call'
    }

    It 'waits on a bounded poll, never a blind sleep (run 44285721257)' {
        $probe = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
        $sub = -1
        for ($i = 0; $i -lt $probe.Count; $i++) {
            if ($probe[$i] -match '^:probe_uwp') { $sub = $i; break }
        }
        $sub | Should -BeGreaterThan -1 -Because 'probe.cmd must still carry the :probe_uwp subroutine'
        $tail = $probe[$sub..($probe.Count - 1)] -join "`n"
        $tail | Should -Match ':probe_uwp_poll' -Because 'the launch wait is a poll loop'
        # Run 44319967017: the one-second wait is choice, not ping.
        # ping is the prime suspect for the Media poll stall, and the
        # shell section's ping -n 16 sits outside this subroutine, so
        # the tail must not contain a poll ping at all.
        $tail | Should -Match 'choice /c Y /d Y /t 1' -Because 'each poll step waits about one second'
        $tail | Should -Not -Match 'ping -n 2 127\.0\.0\.1' -Because 'the poll wait is choice now, not ping'
        $tail | Should -Match 'set /a UWP_WAIT\+=1' -Because 'the poll counts its steps'
        $tail | Should -Match 'if %UWP_WAIT% lss 10 goto :probe_uwp_poll' -Because 'the poll gives up after ten steps instead of hanging'
        $tail | Should -Not -Match 'ping -n 8 127\.0\.0\.1' -Because 'the old fixed 7-second sleep is gone'
    }

    It 'marks every poll round, so a partial probe names the step it died in (run 44319967017)' {
        # The run 36 probe stopped inside the Media poll's first round
        # and the loop has three steps (wait, tasklist, find). Each
        # round writes wait_before / wait_after / check_after markers
        # whose key carries the process name and round number: a death
        # in the wait leaves wait_before as the last line, a death in
        # tasklist/find leaves wait_after, and a death after the check
        # leaves check_after.
        $probe = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
        $sub = -1
        for ($i = 0; $i -lt $probe.Count; $i++) {
            if ($probe[$i] -match '^:probe_uwp') { $sub = $i; break }
        }
        $sub | Should -BeGreaterThan -1 -Because 'probe.cmd must still carry the :probe_uwp subroutine'
        $tail = $probe[$sub..($probe.Count - 1)] -join "`n"
        $tail | Should -Match 'mark_uwp_poll_%UWP_PROC%_r%UWP_WAIT%_wait_before=%TIME: =0%' -Because 'each round marks the wait start'
        $tail | Should -Match 'mark_uwp_poll_%UWP_PROC%_r%UWP_WAIT%_wait_after=%TIME: =0%' -Because 'each round marks the wait end'
        $tail | Should -Match 'mark_uwp_poll_%UWP_PROC%_r%UWP_WAIT%_check_after=%TIME: =0%' -Because 'each round marks the check end'
        $pollLines = @($probe | Where-Object { $_ -match 'echo mark_uwp_poll_' })
        $pollLines.Count | Should -Be 3 -Because 'one marker per poll step: wait_before, wait_after, check_after'
        foreach ($line in $pollLines) {
            $line | Should -Match '^echo mark_uwp_poll_' -Because "a poll marker must be a top-level line, not block content: $line"
        }
    }

    It 'polls the verified process image names (run 44319967017)' {
        # The names were read off the provisioned packages'
        # AppxManifest.xml in the run 27 boot.wim (same 25H2 install.wim
        # source as CI): CalculatorApp.exe, Microsoft.Lightbox.exe (the
        # new Photos app), Microsoft.Media.Player.exe. The old names
        # Microsoft.Photos.exe and Microsoft.ZuneMusic.exe do not exist
        # in the image, so the old poll could never see those apps even
        # if they launched.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'call :probe_uwp CalculatorApp "shell:AppsFolder\\Microsoft\.WindowsCalculator_8wekyb3d8bbwe!App"' -Because 'Calculator runs as CalculatorApp.exe'
        $text | Should -Match 'call :probe_uwp Microsoft\.Lightbox "shell:AppsFolder\\Microsoft\.Windows\.Photos_8wekyb3d8bbwe!App"' -Because 'the new Photos app runs as Microsoft.Lightbox.exe'
        $text | Should -Match 'call :probe_uwp Microsoft\.Media\.Player "shell:AppsFolder\\Microsoft\.ZuneMusic_8wekyb3d8bbwe!Microsoft\.ZuneMusic"' -Because 'Media Player runs as Microsoft.Media.Player.exe'
        $text | Should -Not -Match 'call :probe_uwp Microsoft\.Photos ' -Because 'Microsoft.Photos.exe does not exist in the image'
        $text | Should -Not -Match 'call :probe_uwp Microsoft\.ZuneMusic ' -Because 'Microsoft.ZuneMusic.exe does not exist in the image'
    }

    It 'diagnoses the UWP activation chain before launching (run 44349189039)' {
        # Run 38: the three apps never appeared in tasklist although the
        # start lines returned at once. Before the launches, the probe
        # now records which link of the chain is broken: service states,
        # the StateRepository database, the SYSTEM profile Packages
        # directory, EnableLUA, and the AppxAllUserStore entries.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $diag = $text.IndexOf('mark_uwp_diag')
        $diag | Should -BeGreaterThan -1 -Because 'the diagnostics section must be marked'
        $diag | Should -BeGreaterThan $text.IndexOf('mark_ime') -Because 'the diagnostics run after the input-method check'
        $diag | Should -BeLessThan $text.IndexOf('mark_uwp_appx') -Because 'the diagnostics run before the UWP launches'
        $text | Should -Match 'call :probe_svc AppXSVC appxsvc' -Because 'the AppX deployment service state is recorded'
        $text | Should -Match 'call :probe_svc StateRepository staterepo' -Because 'the StateRepository service state is recorded'
        $text | Should -Match 'call :probe_svc AppReadiness appreadiness' -Because 'the AppReadiness service state is recorded'
        $text | Should -Match 'StateRepository-Machine\.srd' -Because 'the generated StateRepository database is checked, not assumed'
        $text | Should -Match 'config\\systemprofile\\AppData\\Local\\Packages' -Because 'the SYSTEM profile Packages directory is checked'
        $text | Should -Match 'EnableLUA' -Because 'UWP activation needs UAC infrastructure; EnableLUA says whether it exists'
        $text | Should -Match 'AppxAllUserStore' -Because 'the per-app registration entries are checked'
        $text | Should -Match 'appxstore_calc=' -Because 'the Calculator registration is recorded'
        $text | Should -Match 'appxstore_photos=' -Because 'the Photos registration is recorded'
        $text | Should -Match 'appxstore_media=' -Because 'the Media Player registration is recorded'
        $text | Should -Match 'micpe-tasklist\.txt' -Because 'the full tasklist dump is written next to the probe file'
        $text | Should -Match 'tasklist /v' -Because 'only the verbose dump shows window titles'
    }

    It 'records the frame host files and host registrations, and re-checks services after the launches (run 45)' {
        # Run 45: the frame host chain is extracted into the image, so the
        # probe records whether the files are in the running image (not
        # just whether the processes run — that is appframehost= and
        # friends above), whether the SOFTWARE hive swap carried the two
        # SystemApps hosts' InboxApplications entries, and whether the
        # launches started the deployment services on demand.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'framehost_files=' -Because 'the frame host binaries and SystemApps hosts are recorded'
        $text | Should -Match 'framehost_dlls=' -Because 'the service DLLs are recorded'
        $text | Should -Match 'ApplicationFrameHost\.exe' -Because 'the frame host file check names the binary'
        $text | Should -Match 'Windows\.StateRepository\.dll' -Because 'the StateRepository service DLL is checked (on-disk name Windows.StateRepository.dll)'
        $text | Should -Match 'AppReadiness\.dll' -Because 'the AppReadiness ServiceDll is checked'
        $text | Should -Match 'ShellExperienceHost_cw5n1h2txyewy' -Because 'the shell host directory name is checked'
        $text | Should -Match 'appxstore_shellexperiencehost=' -Because 'the shell host registration is recorded'
        $text | Should -Match 'appxstore_startmenuexperiencehost=' -Because 'the Start menu host registration is recorded'
        $text | Should -Match 'call :probe_svc AppXSVC appxsvc_after' -Because 'the AppXSVC state after the launches is recorded'
        $text | Should -Match 'call :probe_svc StateRepository staterepo_after' -Because 'the StateRepository state after the launches is recorded'
        $text | Should -Match 'call :probe_svc AppReadiness appreadiness_after' -Because 'the AppReadiness state after the launches is recorded'
        $text.IndexOf('framehost_files=') | Should -BeGreaterThan $text.IndexOf('mark_uwp_appx') -Because 'the file checks run in the UWP section'
        $text.IndexOf('call :probe_svc AppXSVC appxsvc_after') | Should -BeGreaterThan $text.IndexOf('call :probe_explorer_cpu media') -Because 'the after-states are re-checked after the Media launch'
        $text.IndexOf('call :probe_svc AppXSVC appxsvc_after') | Should -BeLessThan $text.IndexOf('mark_payload') -Because 'the after-states are re-checked before the payload section'
    }

    It 'records the frame-host and shell-host presence the desktop depends on (run 44349189039)' {
        # ApplicationFrameHost.exe displays every UWP app window, and
        # ShellExperienceHost / StartMenuExperienceHost host the modern
        # shell UI. None of them is in any filelist, so the probe must
        # check at runtime instead of assuming they exist.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'appframehost=' -Because 'the UWP window host presence is recorded'
        $text | Should -Match 'shellexperiencehost=' -Because 'the shell experience host presence is recorded'
        $text | Should -Match 'startmenuexperiencehost=' -Because 'the Start menu host presence is recorded'
        $text | Should -Match 'runtimebroker=' -Because 'the activation broker presence is recorded'
        $text | Should -Match 'ApplicationFrameHost\.exe' -Because 'the check looks for the frame host by image name'
        $text | Should -Match 'ShellExperienceHost\.exe' -Because 'the check looks for the shell host by image name'
        $text | Should -Match 'StartMenuExperienceHost\.exe' -Because 'the check looks for the Start menu host by image name'
    }

    It 'starts the AppX services only after probe_done, and records their last exit codes (run 39 control lifted in run 51)' {
        # Run 51 lifts the run 39 control: the probe and the watchdog
        # both stopped within ~15 seconds of the two sc start calls, so
        # the start attempt stayed out of the probe through run 50.
        # Run 50 proved RpcSs is the only thing holding StateRepository
        # back, so run 51 starts the services — but only after
        # probe_done is already in the LOCAL file (§34.7), where a
        # wedge costs a delayed shutdown, not a lost conclusion. The
        # start calls run detached through :probe_sc_start. The last
        # exit codes are still recorded before the first launch, as
        # before: run 39 showed sc start returning 0 while the service
        # stayed STOPPED.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text.IndexOf('call :probe_sc_start AppXSVC appxsvc') | Should -BeGreaterThan $text.IndexOf('echo probe_done=1') -Because 'AppXSVC is started only after probe_done'
        $text.IndexOf('call :probe_sc_start StateRepository staterepo') | Should -BeGreaterThan $text.IndexOf('echo probe_done=1') -Because 'StateRepository is started only after probe_done'
        $text | Should -Not -Match 'sc start AppReadiness' -Because 'AppReadiness is only queried, not started'
        $text | Should -Not -Match 'appxsvc_start=' -Because 'the start outcome is recorded under appxsvc_after_start, not appxsvc_start'
        $text | Should -Not -Match 'staterepo_start=' -Because 'the start outcome is recorded under staterepo_after_start, not staterepo_start'
        $text | Should -Match 'sc queryex AppXSVC' -Because 'the stopped service exit code is read, not assumed'
        $text | Should -Match 'sc queryex StateRepository' -Because 'the stopped service exit code is read, not assumed'
        $text | Should -Match 'WIN32_EXIT_CODE' -Because 'queryex reports the service last exit code under that name'
        $text | Should -Match 'appxsvc_exitcode=' -Because 'the AppXSVC last exit code is recorded'
        $text | Should -Match 'staterepo_exitcode=' -Because 'the StateRepository last exit code is recorded'
        $text.IndexOf('sc queryex AppXSVC') | Should -BeLessThan $text.IndexOf('call :probe_uwp CalculatorApp') -Because 'the exit codes are recorded before the first launch'
        $text.IndexOf('sc queryex AppXSVC') | Should -BeGreaterThan $text.IndexOf('call :probe_svc AppXSVC appxsvc') -Because 'the before-state is recorded before the exit-code query'
    }

    It 'brackets each AppxAllUserStore query with before/after markers (run 44365018616)' {
        # Run 39 stopped after appxstore_photos=1, in the third
        # identical reg query or in the append write after it — the
        # two look the same in the probe file. The _query marker is
        # written before the query runs, the _after marker right after
        # it returns, so the next partial probe says which it was.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        foreach ($app in @('calc', 'photos', 'media')) {
            $text | Should -Match "mark_appxstore_${app}_query=" -Because "the $app query start is marked"
            $text | Should -Match "mark_appxstore_${app}_after=" -Because "the $app query return is marked"
        }
        $text.IndexOf('mark_appxstore_calc_query') | Should -BeLessThan $text.IndexOf('find /i "Microsoft.WindowsCalculator"') -Because 'the calc query marker precedes its query'
        $text.IndexOf('mark_appxstore_calc_after') | Should -BeLessThan $text.IndexOf('appxstore_calc=1') -Because 'the calc after-marker precedes its result echo'
        $text.IndexOf('mark_appxstore_photos_query') | Should -BeLessThan $text.IndexOf('find /i "Microsoft.Windows.Photos"') -Because 'the photos query marker precedes its query'
        $text.IndexOf('mark_appxstore_photos_after') | Should -BeLessThan $text.IndexOf('appxstore_photos=1') -Because 'the photos after-marker precedes its result echo'
        $text.IndexOf('mark_appxstore_media_query') | Should -BeLessThan $text.IndexOf('find /i "Microsoft.ZuneMusic"') -Because 'the media query marker precedes its query'
        $text.IndexOf('mark_appxstore_media_after') | Should -BeLessThan $text.IndexOf('appxstore_media=1') -Because 'the media after-marker precedes its result echo'
        # The after-marker must not clobber the query errorlevel: the
        # result echo reads a captured variable, not errorlevel.
        $text | Should -Match 'APPXSTORE_CALC=%ERRORLEVEL%' -Because 'the calc query outcome is captured before the after-marker echo'
        $text | Should -Match 'APPXSTORE_PHOTOS=%ERRORLEVEL%' -Because 'the photos query outcome is captured before the after-marker echo'
        $text | Should -Match 'APPXSTORE_MEDIA=%ERRORLEVEL%' -Because 'the media query outcome is captured before the after-marker echo'
    }

    It 'dumps the modules loaded by the hung explorer (run 44365018616)' {
        # Explorer is alive but Not Responding with no window; the
        # module list says what it has loaded. It goes into the same
        # tasklist file the build already collects.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'tasklist /m /fi "imagename eq explorer.exe"' -Because 'the module dump is scoped to explorer'
        $text | Should -Match 'tasklist /m explorer.exe' -Because 'the dump is labelled in the tasklist file'
        $text.IndexOf('tasklist /m') | Should -BeGreaterThan $text.IndexOf('folder_window_test=1') -Because 'the module dump runs after the folder-window test'
        $text.IndexOf('tasklist /m') | Should -BeLessThan $text.IndexOf('mark_uwp_appx') -Because 'the module dump runs in the diagnostics section, before the launches'
    }

    It 'the folder-window test says whether explorer can create any window (run 44349189039)' {
        # Explorer is alive but no desktop, taskbar or folder window ever
        # appears. Opening one folder window and dumping tasklist again
        # separates "explorer cannot create any window" from "explorer
        # cannot create the shell".
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'start "" explorer\.exe "%SystemDrive%\\"' -Because 'the test opens a folder window through explorer'
        $text | Should -Match 'folder_window_test=1' -Because 'the test records that it ran'
        # Count code lines only: the section header comment also names
        # tasklist /v, so a raw-text match would count it as a dump.
        $probeLines = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
        $dumps = @($probeLines | Where-Object { $_ -match '^tasklist /v' })
        $dumps.Count | Should -Be 3 -Because 'one dump before the test, one after it, and one at probe end (run 44386689307)'
        $text.IndexOf('folder_window_test=1') | Should -BeLessThan $text.IndexOf('mark_uwp_appx') -Because 'the test runs in the diagnostics section, before the launches'
    }

    It 'the launch guard records whether explorer was alive and which PID it was (run 44410311576)' {
        # Run 41: explorer was Not Responding in the first two snapshots
        # and gone by the end snapshot — it hung and then died inside the
        # run (alive at the Photos guard 22:50:16, gone at the Media
        # guard 22:50:46). The guard key says which launch found it
        # missing, and the PID says whether a later launch sees the same
        # process or a restarted one. ctfmon/ChsIME/WmiPrvSE were already
        # in the FIRST snapshot in run 41, so their late appearance is
        # not evidence about the death.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'echo explorer_guard=0 >> "%PROBE_LOCAL%"' -Because 'a launch that finds explorer missing is recorded'
        $text | Should -Match 'echo explorer_guard=1 >> "%PROBE_LOCAL%"' -Because 'a launch that finds it alive is recorded too'
        $text | Should -Match 'explorer_pid=%EXPLORER_PID%' -Because 'the PID is recorded for each launch'
        $probeLines = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
        $guardLine = ($probeLines | Select-String -Pattern 'explorer_guard=1' | Where-Object { $_.Line -match '^echo ' } | Select-Object -First 1).LineNumber
        # The subroutine's start takes the target from %UWP_TARGET%; the
        # folder-window test's start takes "%SystemDrive%\" and is a
        # different line, before the subroutine.
        $startLine = ($probeLines | Select-String -Pattern 'start "" explorer\.exe "%UWP_TARGET%"' | Select-Object -First 1).LineNumber
        $guardLine | Should -Not -BeNullOrEmpty
        $startLine | Should -Not -BeNullOrEmpty
        $guardLine | Should -BeLessThan $startLine -Because 'the guard must run before the launch it guards'
        # The guard lives in :probe_uwp: the first start after the
        # subroutine label is the one it guards, and the static test
        # above already pins the label-to-first-start order.
        $text | Should -Match 'explorer_after_calculator=1 >> "%PROBE_LOCAL%"' -Because 'the caller checks survival after each launch'
        $text | Should -Match 'explorer_after_photos=0 >> "%PROBE_LOCAL%"'
        $text | Should -Match 'explorer_after_media=1 >> "%PROBE_LOCAL%"'
        # The after-checks sit between the launches, splitting the death
        # window to a single launch instead of one launch later.
        $text.IndexOf('explorer_after_calculator=') | Should -BeLessThan $text.IndexOf('mark_uwp_launch_photos') -Because 'the Calculator after-check runs before the Photos launch'
        $text.IndexOf('explorer_after_photos=') | Should -BeLessThan $text.IndexOf('mark_uwp_launch_media') -Because 'the Photos after-check runs before the Media launch'
        $text.IndexOf('explorer_after_media=') | Should -BeLessThan $text.IndexOf('mark_payload') -Because 'the Media after-check runs before the payload section'
    }

    It 'the end snapshot records WerFault and dwm presence (run 44410311576)' {
        # Run 41: explorer died inside the run with no crash handler in
        # any snapshot. The end keys say whether a crash was ever
        # reported (WerFault) and whether the compositor outlived the
        # shell (dwm). Absence of WerFault in all three snapshots is
        # itself evidence: a silent exit, not a reported crash.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'echo werfault_end=0 >> "%PROBE_LOCAL%"' -Because 'the no-crash case is recorded'
        $text | Should -Match 'echo werfault_end=1 >> "%PROBE_OUT%"' -Because 'a reported crash is recorded too'
        $text | Should -Match 'echo dwm_end=1 >> "%PROBE_LOCAL%"' -Because 'the compositor outliving the shell is recorded'
        $text.IndexOf('werfault_end=') | Should -BeGreaterThan $text.IndexOf('--- tasklist at probe end ---') -Because 'the end keys run after the end snapshot'
        $text.IndexOf('dwm_end=') | Should -BeLessThan $text.IndexOf('echo probe_done=1') -Because 'the end keys run before probe_done'
    }

    It 'records explorer CPU time at each liveness check (run 44428428849)' {
        # Run 42: explorer's CPU time was already frozen at 0:00:13 in
        # the first tasklist snapshot, so the snapshots alone cannot say
        # when it stopped working — at startup, or later. The CPU time
        # at each liveness check gives the freeze profile.
        # Run 44441708839: the parse itself was broken — /nh is only
        # valid with /fo table or csv, so with /fo list tasklist failed
        # and every key came back missing. The exact line below pins
        # the fix: no /nh, the list form's CPU-time line read with
        # tokens=3. The preuwp call brackets the network/ime/diagnostics
        # gap between the shell call and the first snapshot.
        # Run 44459251306: the match is on "CPU" alone, not "CPU Time" —
        # the zh-CN image prints "CPU 时间", so "CPU Time" never matched
        # there and every key came back missing again. "CPU" is the first
        # token of that line in both languages, and no other list-form
        # line contains it, so tokens=3 still yields the time.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'tasklist /v /fo list /fi "imagename eq explorer\.exe" 2\^>nul \^\| find /i "CPU"' -Because 'the list form prints one CPU-time line per process, the match must be on "CPU" alone for zh-CN (run 44459251306), and /nh must not be there (run 44441708839)'
        $text | Should -Match 'echo explorer_cpu_%~1=%EXPLORER_CPU%' -Because 'the time is recorded under the segment key'
        $text | Should -Match 'echo explorer_cpu_%~1=missing' -Because 'a missing process is recorded, not skipped'
        $text | Should -Match 'call :probe_explorer_cpu shell' -Because 'the shell check records the first CPU time'
        $text | Should -Match 'call :probe_explorer_cpu preuwp' -Because 'the pre-UWP check brackets the network/ime/diagnostics gap'
        $text | Should -Match 'call :probe_explorer_cpu calculator'
        $text | Should -Match 'call :probe_explorer_cpu photos'
        $text | Should -Match 'call :probe_explorer_cpu media'
        $text | Should -Match 'call :probe_explorer_cpu end'
        # The shell call sits before the shell_ready echo, so the head
        # mechanism test covers it; the after-check calls sit between
        # the launches.
        $text.IndexOf('call :probe_explorer_cpu shell') | Should -BeLessThan $text.IndexOf('echo shell_ready=1')
        $text.IndexOf('call :probe_explorer_cpu shell') | Should -BeLessThan $text.IndexOf('call :probe_explorer_cpu preuwp')
        $text.IndexOf('call :probe_explorer_cpu preuwp') | Should -BeLessThan $text.IndexOf('--- tasklist before UWP section ---') -Because 'the pre-UWP check runs right before the first snapshot'
        $text.IndexOf('call :probe_explorer_cpu calculator') | Should -BeLessThan $text.IndexOf('mark_uwp_launch_photos')
        $text.IndexOf('call :probe_explorer_cpu media') | Should -BeLessThan $text.IndexOf('mark_payload')
    }

    It 'reverse control: with /nh back in the CPU-time line the exact-line test fails' {
        # The exact-line assertion above must actually depend on the
        # /nh absence, not pass vacuously.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $mutated = $text.Replace('tasklist /v /fo list /fi "imagename eq explorer.exe" 2^>nul', 'tasklist /v /fo list /fi "imagename eq explorer.exe" /nh 2>nul')
        $mutated | Should -Not -Match 'tasklist /v /fo list /fi "imagename eq explorer\.exe" 2\^>nul \^\| find /i "CPU"'
    }

    It 'checks explorer liveness mid-poll to split the death window (run 44428428849)' {
        # In both death rounds explorer died ~25-30 s after a start
        # explorer.exe call — the same window as the ten-round poll, so
        # the after-check cannot tell whether the start killed it. A
        # mid-poll check at round 5 splits the window in half.
        $probe = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
        $sub = -1
        for ($i = 0; $i -lt $probe.Count; $i++) {
            if ($probe[$i] -match '^:probe_uwp') { $sub = $i; break }
        }
        $sub | Should -BeGreaterThan -1 -Because 'probe.cmd must still carry the :probe_uwp subroutine'
        $tail = $probe[$sub..($probe.Count - 1)] -join "`n"
        $tail | Should -Match 'if %UWP_WAIT%==5' -Because 'the check runs once, in the middle of the ten-round poll'
        $tail | Should -Match 'echo explorer_midpoll_%UWP_PROC%=0 >> "%PROBE_LOCAL%"' -Because 'a mid-poll death is recorded'
        $tail | Should -Match 'echo explorer_midpoll_%UWP_PROC%=1 >> "%PROBE_OUT%"' -Because 'mid-poll survival is recorded too'
    }

    It 'the end snapshot checks the WER queues for an explorer entry (run 44428428849)' {
        # Explorer exits silently (no WerFault in any snapshot), so a
        # crash report would only exist if WerFault failed to launch at
        # all. The queue check is pure file existence, so it cannot
        # stall the probe one line before probe_done. No event-log
        # query: a silent exit writes no Event 1000/1001.
        # Run 44441708839: wer_explorer=1 alone cannot say whether the
        # entry is this run's death or an old one, so each matching
        # entry's name and last-write time are copied too — the name
        # carries the faulting binary and the report kind, the time is
        # compared against the death window.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'Microsoft\\Windows\\WER\\ReportQueue' -Because 'a crash report would queue here even if WerFault never ran'
        $text | Should -Match 'Microsoft\\Windows\\WER\\ReportArchive'
        $text | Should -Match 'echo wer_explorer=%WER_EXPLORER%' -Because 'the queue check result is recorded'
        $text | Should -Match 'echo wer_explorer_name=%%N' -Because 'each matching queue entry name is copied'
        $text | Should -Match 'echo wer_explorer_time=%%~tT' -Because 'each matching queue entry last-write time is copied too'
        $text | Should -Match 'echo wer_explorer_archive_name=%%N' -Because 'the archive entries are copied the same way'
        $text | Should -Match 'echo wer_explorer_archive_time=%%~tT'
        $text.IndexOf('wer_explorer=') | Should -BeGreaterThan $text.IndexOf('dwm_end=') -Because 'the WER check runs after the end keys'
        $text.IndexOf('wer_explorer=') | Should -BeLessThan $text.IndexOf('echo probe_done=1') -Because 'the WER check runs before probe_done'
    }

    It 'checks explorer liveness mid-diagnosis to split the death window (run 46)' {
        # Run 45: explorer died during the diagnostics — last alive
        # evidence the second tasklist snapshot, first dead evidence the
        # Calculator guard — so the death window spans the whole
        # appxstore/host-query stretch. One liveness check (plus a CPU
        # sample) mid-diagnosis splits that window at the queries.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'explorer_mid_diag=' -Because 'the mid-diagnosis liveness check is recorded'
        $text | Should -Match 'call :probe_explorer_cpu diag' -Because 'the mid-diagnosis CPU sample brackets the queries'
        $text.IndexOf('explorer_mid_diag=') | Should -BeGreaterThan $text.IndexOf('appxstore_startmenuexperiencehost=') -Because 'the check runs after the host queries'
        $text.IndexOf('explorer_mid_diag=') | Should -BeLessThan $text.IndexOf('mark_uwp_appx') -Because 'the check runs before the UWP launches'
    }

    It 'dumps tasklist /svc so a busy svchost can be identified (run 46)' {
        # Run 45: svchost PID 1072 burned ~1:45 of CPU in the UWP
        # section. tasklist /v shows the CPU time but not the hosted
        # services; the /svc dump names them.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'tasklist /svc' -Because 'the service dump names the hosted services per process'
        $text | Should -Match 'svc_dump=1' -Because 'the dump is recorded'
        $text.IndexOf('tasklist /svc') | Should -BeGreaterThan $text.IndexOf('tasklist_dump=1') -Because 'the dump goes into the tasklist file'
    }

    It 'dumps the mirror volume root and counts its files (run 46)' {
        # Run 44/45: mirror=0 with drives=CDX — the volume is visible
        # but the sentinel is not. The root listing says whether the
        # volume is empty (vvfat delivered nothing) or holds files
        # under a different name.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        # The echo prefix matters: a bare 'mirror_root_files=' also
        # matches the `set "MIRROR_ROOT_FILES="` assignment (-Match
        # is case-insensitive), so without it this test would pass
        # even with the echo deleted (reverse control, run 46).
        $text | Should -Match 'echo mirror_root_files=' -Because 'the file count on the mirror volume is recorded'
        $text | Should -Match 'mirror_root_drive=' -Because 'which drive was listed is recorded'
        $text | Should -Match 'dir "%MIRROR_ROOT%"' -Because 'the root listing is dumped into the tasklist file'
        $text | Should -Match 'if defined MIRROR_DIR set "MIRROR_ROOT=%MIRROR_DIR%"' -Because 'the sentinel-found drive is preferred'
        $text | Should -Match 'if not defined MIRROR_ROOT if exist "D:\\" set "MIRROR_ROOT=D:\\"' -Because 'D: is the fallback on the CI layout'
    }

    It 'copies each explorer WER Report.wer into the tasklist file (run 46)' {
        # The queue name/time only says "an explorer crash happened at
        # 06:35". The faulting module, exception code and offset live in
        # the Report.wer text file inside each entry; the probe copies
        # them into the already-collected tasklist file.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'Report\.wer' -Because 'the report text is copied, not just the entry name'
        $text | Should -Match 'wer_reports=' -Because 'how many reports were found is recorded'
        $text | Should -Match 'ReportQueue\\\*explorer\*' -Because 'only explorer entries are copied from the queue'
        $text | Should -Match 'ReportArchive\\\*explorer\*' -Because 'only explorer entries are copied from the archive'
        $text.IndexOf('wer_reports=') | Should -BeGreaterThan $text.IndexOf('wer_explorer=') -Because 'the report dump runs with the WER check'
        $text.IndexOf('wer_reports=') | Should -BeLessThan $text.IndexOf('echo probe_done=1') -Because 'the report dump runs before probe_done'
    }

    It 'records event-log existence and copies the logs for host-side parsing, without querying wevtutil (run 46)' {
        # A silent exit writes no Event 1000/1001, but the log files
        # themselves say whether the event-log service ran at all in
        # this PE. wevtutil against a stopped log service is a stall
        # risk one line before probe_done, so it is never queried.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'evtx_system=' -Because 'the System log existence is recorded'
        $text | Should -Match 'evtx_system_size=' -Because 'the System log size is recorded'
        $text | Should -Match 'evtx_system_copy=' -Because 'whether the copy landed is recorded'
        $text | Should -Match 'evtx_app=' -Because 'the Application log existence is recorded'
        $text | Should -Match 'micpe-system\.evtx' -Because 'the System log is copied to the share for host-side parsing'
        $text | Should -Match 'micpe-application\.evtx' -Because 'the Application log is copied too'
        # wevtutil appears only in rem comments (the decision not to
        # query it is documented there); no command line may invoke it.
        $probeLines = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
        $wevtLines = @($probeLines | Where-Object { $_ -match 'wevtutil' })
        $wevtLines.Count | Should -BeGreaterThan 0 -Because 'the no-wevtutil decision is documented in the probe'
        foreach ($line in $wevtLines) {
            $line.Trim() | Should -Match '^rem' -Because "wevtutil must only appear in a comment, never as a command: $line"
        }
        $text.IndexOf('evtx_system=') | Should -BeGreaterThan $text.IndexOf('wer_explorer=') -Because 'the log check runs with the WER check'
        $text.IndexOf('evtx_system=') | Should -BeLessThan $text.IndexOf('echo probe_done=1') -Because 'the log check runs before probe_done'
    }

    It 'records whether any crash dump was written (run 46)' {
        # Runs 41-45: werfault_end=0 every time, so these are expected
        # 0 — the check is the evidence, not the expectation.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'dump_minidump=' -Because 'a minidump would be the breakpoint evidence'
        $text | Should -Match 'dump_crashdumps=' -Because 'the SYSTEM CrashDumps directory is checked'
        $text | Should -Match 'dump_memory=' -Because 'a full MEMORY.dmp is checked'
        $text | Should -Match 'Minidump\\\*\.dmp' -Because 'the minidump check is a wildcard existence check'
        $text.IndexOf('dump_minidump=') | Should -BeGreaterThan $text.IndexOf('wer_explorer=') -Because 'the dump checks run with the WER check'
        $text.IndexOf('dump_minidump=') | Should -BeLessThan $text.IndexOf('echo probe_done=1') -Because 'the dump checks run before probe_done'
    }

    It 'cross-checks UWP launches without the explorer guard (run 46)' {
        # Run 45's three uwp_launch_*=0 are NOT a cross-validation:
        # all three failed at the explorer guard, before any real
        # launch attempt. The cross-check retries each app through a
        # launch path that does not go through the explorer.exe
        # process, so a 0 here means the activation itself failed.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text.Contains('call :probe_xcheck CalculatorApp "shell:AppsFolder\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"') | Should -Be $true -Because 'Calculator is retried without the guard'
        $text.Contains('call :probe_xcheck Microsoft.Lightbox "shell:AppsFolder\Microsoft.Windows.Photos_8wekyb3d8bbwe!App"') | Should -Be $true -Because 'Photos is retried without the guard'
        $text.Contains('call :probe_xcheck Microsoft.Media.Player "shell:AppsFolder\Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic"') | Should -Be $true -Because 'Media Player is retried without the guard'
        # The explorer/frame-host truth checks must use the System32
        # tasklist by full path (C1/C1b): a bare tasklist is shadowed
        # by the harness copy on the runner, whose /fi is rejected,
        # so a bare check would always read 0 and X1's =1 assertions
        # would be false. The polls stay bare on purpose: they are
        # stubbed by the harness (U4/U5) and identical to the
        # guarded poll's shape.
        $text.Contains('%SystemRoot%\System32\tasklist.exe" /fi "imagename eq explorer.exe"') | Should -Be $true -Because 'the cross-check explorer checks must see the real shell'
        $text.Contains('%SystemRoot%\System32\tasklist.exe" /fi "imagename eq ApplicationFrameHost.exe"') | Should -Be $true -Because 'the frame-host check must see the real host'
        $text | Should -Match 'xcheck_launch_calculator=' -Because 'the cross-check result is recorded per app'
        $text | Should -Match 'xcheck_launch_photos='
        $text | Should -Match 'xcheck_launch_media='
        $text | Should -Match 'xcheck_explorer_before=' -Because 'the shell state at cross-check entry is recorded'
        $text | Should -Match 'xcheck_explorer_after=' -Because 'whether the shell survived the retries is recorded'
        $text | Should -Match 'xcheck_framehost_after=' -Because 'whether the frame host spawned is recorded'
        $text.IndexOf('mark_xcheck=') | Should -BeGreaterThan $text.IndexOf('call :probe_svc AppXSVC appxsvc_after') -Because 'the cross-check runs after the service re-checks'
        $text.IndexOf('mark_xcheck=') | Should -BeLessThan $text.IndexOf('mark_payload') -Because 'the cross-check runs before the payload section'
        # The three calls run inside their own DisableDelayedExpansion
        # block (the bang must survive, U3), separate from the guarded
        # launches' block.
        $xcheckCalls = @([regex]::Matches($text, 'call :probe_xcheck'))
        $xcheckCalls.Count | Should -Be 3 -Because 'the probe cross-checks exactly three UWP apps'
        $off = $text.IndexOf('setlocal DisableDelayedExpansion', $text.IndexOf('mark_xcheck='))
        $off | Should -BeGreaterThan -1 -Because 'the cross-check calls must run with delayed expansion off'
        $off | Should -BeLessThan $xcheckCalls[0].Index -Because 'the switch-off must come before the first cross-check call'
        $on = $text.IndexOf('endlocal', $xcheckCalls[0].Index)
        $on | Should -BeGreaterThan $xcheckCalls[2].Index -Because 'delayed expansion must stay off until after the last cross-check call'
    }

    It 'no section header after the uwp header steals the slice anchor (run 46)' {
        # BuildUwpBatch takes the LAST line matching `^rem --- uwp`
        # before payload as the slice start. The run-46 cross-check
        # header read `rem --- uwp cross-check`, so the slice started
        # at the cross-check and every section test ran only the tail
        # (CI run 44497333624: U1/U1b/U2/U4/X1 all timed out, U5 saw
        # a probe file with no uwp_launch_* keys at all). The last
        # such header before payload must be the section header itself.
        $lines = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
        $payloadIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^rem --- payload') { $payloadIdx = $i; break }
        }
        $payloadIdx | Should -BeGreaterThan 0 -Because 'the payload header must exist'
        $uwpHeaders = @($lines[0..($payloadIdx - 1)] | Where-Object { $_ -match '^rem --- uwp' })
        $uwpHeaders.Count | Should -BeGreaterThan 0 -Because 'the uwp header must exist'
        $uwpHeaders[-1] | Should -Match '^rem --- uwp -+ *$' -Because 'the last uwp header before payload is the section start, not a later sub-header'
    }

    It 'the cross-check launch does not go through explorer.exe (run 46)' {
        # The whole point of the cross-check is a launch path that
        # does not need a running shell. :probe_xcheck must contain
        # no explorer guard and no explorer.exe in its start line.
        # The start is detached (outer start launches a child cmd
        # that runs the ShellExecute): a bare start blocks the probe
        # indefinitely when the app cannot activate (CI run
        # 44502105340 X1: 300 s with no start_after), so the child
        # cmd absorbs the block and the probe keeps polling.
        $probe = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
        $sub = -1; $start = -1
        for ($i = 0; $i -lt $probe.Count; $i++) {
            if ($probe[$i] -match '^:probe_xcheck') { $sub = $i }
            if ($sub -ge 0 -and $probe[$i] -match '^\s*start ""') { $start = $i; break }
        }
        $sub | Should -BeGreaterThan -1 -Because 'probe.cmd must carry the :probe_xcheck subroutine'
        $start | Should -BeGreaterThan $sub -Because 'the subroutine must launch the app'
        $probe[$start] | Should -Match 'start "" cmd /c start "" "%XCHECK_TARGET%"' -Because 'the launch is detached: the outer start returns at once, the child cmd runs the ShellExecute'
        $probe[$start] | Should -Not -Match 'explorer\.exe' -Because 'the launch must not go through the explorer.exe process'
        $head = $probe[$sub..($start - 1)] -join "`n"
        $head | Should -Not -Match 'explorer_guard=0' -Because 'there is no explorer guard in the cross-check'
        $tail = $probe[$sub..($probe.Count - 1)] -join "`n"
        $tail | Should -Match ':probe_xcheck_poll' -Because 'the cross-check wait is a poll loop'
        $tail | Should -Match 'choice /c Y /d Y /t 1' -Because 'each poll step waits about one second'
        $tail | Should -Match 'if %XCHECK_WAIT% lss 10 goto :probe_xcheck_poll' -Because 'the poll gives up after ten steps instead of hanging'
    }

    It 'the cross-check poll marks every round (run 46)' {
        $probe = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
        $sub = -1
        for ($i = 0; $i -lt $probe.Count; $i++) {
            if ($probe[$i] -match '^:probe_xcheck') { $sub = $i; break }
        }
        $sub | Should -BeGreaterThan -1 -Because 'probe.cmd must carry the :probe_xcheck subroutine'
        $tail = $probe[$sub..($probe.Count - 1)] -join "`n"
        $tail | Should -Match 'mark_xcheck_poll_%XCHECK_PROC%_r%XCHECK_WAIT%_wait_before=%TIME: =0%' -Because 'each round marks the wait start'
        $tail | Should -Match 'mark_xcheck_poll_%XCHECK_PROC%_r%XCHECK_WAIT%_wait_after=%TIME: =0%' -Because 'each round marks the wait end'
        $tail | Should -Match 'mark_xcheck_poll_%XCHECK_PROC%_r%XCHECK_WAIT%_check_after=%TIME: =0%' -Because 'each round marks the check end'
        $pollLines = @($probe | Where-Object { $_ -match 'echo mark_xcheck_poll_' })
        $pollLines.Count | Should -Be 3 -Because 'one marker per poll step: wait_before, wait_after, check_after'
    }

    It 'W1: the WER capture copies an explorer entry name and time, and skips other entries (run 44441708839)' -Skip:(-not $IsWindows) {
        # The verbatim capture snippet from probe.cmd, run against a
        # fake WER tree (ProgramData redirected to the work dir, so the
        # real WER queues are never touched). The queue holds one
        # explorer-named entry and one notepad entry; the archive holds
        # one explorer-named entry. Only the explorer entries may be
        # copied, each with its last-write time.
        $workDir = & $script:NewWorkDir
        $werRoot = Join-Path $workDir 'ProgramData'
        $queue = Join-Path $werRoot 'Microsoft\Windows\WER\ReportQueue'
        $archive = Join-Path $werRoot 'Microsoft\Windows\WER\ReportArchive'
        New-Item -ItemType Directory -Path (Join-Path $queue 'AppCrash_explorer.exe_9f2a1c') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $queue 'AppCrash_notepad.exe_9f2a1c') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $archive 'AppHang_explorer.exe_7b3e9d') -Force | Out-Null
        $outFile = Join-Path $workDir 'wer-out.txt'
        $bat = Join-Path $workDir 'wer-capture.bat'
        try {
            & $script:WriteBatchCrlf $bat @(
                '@echo off',
                ('set "ProgramData={0}"' -f $werRoot),
                ('set "PROBE_OUT={0}"' -f $outFile),
                ('set "PROBE_LOCAL={0}"' -f $outFile),
                'set "WER_EXPLORER=0"',
                'if exist "%ProgramData%\Microsoft\Windows\WER\ReportQueue" (',
                '    dir /b "%ProgramData%\Microsoft\Windows\WER\ReportQueue" 2>nul | find /i "explorer" >nul',
                '    if not errorlevel 1 set "WER_EXPLORER=1"',
                '    for /f "delims=" %%N in (''dir /b "%ProgramData%\Microsoft\Windows\WER\ReportQueue" 2^>nul ^| find /i "explorer"'') do (',
                '        echo wer_explorer_name=%%N >> "%PROBE_LOCAL%" & echo wer_explorer_name=%%N >> "%PROBE_OUT%"',
                '        for %%T in ("%ProgramData%\Microsoft\Windows\WER\ReportQueue\%%N") do echo wer_explorer_time=%%~tT >> "%PROBE_LOCAL%" & echo wer_explorer_time=%%~tT >> "%PROBE_OUT%"',
                '    )',
                ')',
                'if exist "%ProgramData%\Microsoft\Windows\WER\ReportArchive" (',
                '    dir /b "%ProgramData%\Microsoft\Windows\WER\ReportArchive" 2>nul | find /i "explorer" >nul',
                '    if not errorlevel 1 set "WER_EXPLORER=1"',
                '    for /f "delims=" %%N in (''dir /b "%ProgramData%\Microsoft\Windows\WER\ReportArchive" 2^>nul ^| find /i "explorer"'') do (',
                '        echo wer_explorer_archive_name=%%N >> "%PROBE_LOCAL%" & echo wer_explorer_archive_name=%%N >> "%PROBE_OUT%"',
                '        for %%T in ("%ProgramData%\Microsoft\Windows\WER\ReportArchive\%%N") do echo wer_explorer_archive_time=%%~tT >> "%PROBE_LOCAL%" & echo wer_explorer_archive_time=%%~tT >> "%PROBE_OUT%"',
                '    )',
                ')',
                'echo wer_explorer=%WER_EXPLORER% >> "%PROBE_LOCAL%" & echo wer_explorer=%WER_EXPLORER% >> "%PROBE_OUT%"'
            )
            $result = & $script:InvokeCmdTimed $bat $workDir
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 0
            $text = Get-Content -LiteralPath $outFile -Raw
            Write-Host "wer capture: [$text]"
            $text | Should -Match 'wer_explorer=1' -Because 'an explorer entry exists in the queue'
            $text | Should -Match 'wer_explorer_name=AppCrash_explorer\.exe_9f2a1c' -Because 'the queue entry name is copied'
            $text | Should -Match 'wer_explorer_time=[0-9]' -Because 'the queue entry last-write time is copied too'
            $text | Should -Match 'wer_explorer_archive_name=AppHang_explorer\.exe_7b3e9d' -Because 'the archive entry name is copied the same way'
            $text | Should -Match 'wer_explorer_archive_time=[0-9]'
            $text | Should -Not -Match 'notepad' -Because 'a non-explorer entry must not be copied'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'W2: the WER capture writes nothing when no explorer entry exists (run 44441708839)' -Skip:(-not $IsWindows) {
        # Same verbatim snippet, empty WER tree: the result must be an
        # honest 0 with no fabricated name or time lines.
        $workDir = & $script:NewWorkDir
        $werRoot = Join-Path $workDir 'ProgramData'
        $queue = Join-Path $werRoot 'Microsoft\Windows\WER\ReportQueue'
        New-Item -ItemType Directory -Path $queue -Force | Out-Null
        $outFile = Join-Path $workDir 'wer-out.txt'
        $bat = Join-Path $workDir 'wer-capture.bat'
        try {
            & $script:WriteBatchCrlf $bat @(
                '@echo off',
                ('set "ProgramData={0}"' -f $werRoot),
                ('set "PROBE_OUT={0}"' -f $outFile),
                ('set "PROBE_LOCAL={0}"' -f $outFile),
                'set "WER_EXPLORER=0"',
                'if exist "%ProgramData%\Microsoft\Windows\WER\ReportQueue" (',
                '    dir /b "%ProgramData%\Microsoft\Windows\WER\ReportQueue" 2>nul | find /i "explorer" >nul',
                '    if not errorlevel 1 set "WER_EXPLORER=1"',
                '    for /f "delims=" %%N in (''dir /b "%ProgramData%\Microsoft\Windows\WER\ReportQueue" 2^>nul ^| find /i "explorer"'') do (',
                '        echo wer_explorer_name=%%N >> "%PROBE_LOCAL%" & echo wer_explorer_name=%%N >> "%PROBE_OUT%"',
                '        for %%T in ("%ProgramData%\Microsoft\Windows\WER\ReportQueue\%%N") do echo wer_explorer_time=%%~tT >> "%PROBE_LOCAL%" & echo wer_explorer_time=%%~tT >> "%PROBE_OUT%"',
                '    )',
                ')',
                'if exist "%ProgramData%\Microsoft\Windows\WER\ReportArchive" (',
                '    dir /b "%ProgramData%\Microsoft\Windows\WER\ReportArchive" 2>nul | find /i "explorer" >nul',
                '    if not errorlevel 1 set "WER_EXPLORER=1"',
                '    for /f "delims=" %%N in (''dir /b "%ProgramData%\Microsoft\Windows\WER\ReportArchive" 2^>nul ^| find /i "explorer"'') do (',
                '        echo wer_explorer_archive_name=%%N >> "%PROBE_LOCAL%" & echo wer_explorer_archive_name=%%N >> "%PROBE_OUT%"',
                '        for %%T in ("%ProgramData%\Microsoft\Windows\WER\ReportArchive\%%N") do echo wer_explorer_archive_time=%%~tT >> "%PROBE_LOCAL%" & echo wer_explorer_archive_time=%%~tT >> "%PROBE_OUT%"',
                '    )',
                ')',
                'echo wer_explorer=%WER_EXPLORER% >> "%PROBE_LOCAL%" & echo wer_explorer=%WER_EXPLORER% >> "%PROBE_OUT%"'
            )
            $result = & $script:InvokeCmdTimed $bat $workDir
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 0
            $text = Get-Content -LiteralPath $outFile -Raw
            Write-Host "wer capture empty: [$text]"
            $text | Should -Match 'wer_explorer=0'
            $text | Should -Not -Match 'wer_explorer_name='
            $text | Should -Not -Match 'wer_explorer_time='
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'X1: the cross-check section completes with Explorer running and records honest 0s (run 46)' -Skip:(-not $IsWindows) {
        # The genuine uwp section (guarded launches + cross-check) run
        # on the runner: Explorer is running, the three UWP apps are
        # absent on Server, so every launch is an honest 0 — but the
        # section must complete, the cross-check must attempt all three
        # apps without the guard, and the frame host must stay 0.
        # The cross-check start is detached (a child cmd absorbs the
        # block), so the section completes in ~35 s even though the
        # apps are absent on Server; a bare start would block here
        # for 300 s with no start_after (CI run 44502105340 X1).
        $workDir = & $script:NewWorkDir
        $probeOut = Join-Path $workDir 'micpe-probe.txt'
        $bat = Join-Path $workDir 'probe-uwp.bat'
        try {
            & $script:BuildUwpBatch $bat $probeOut
            $result = & $script:InvokeCmdTimed $bat $workDir
            $text = if (Test-Path -LiteralPath $probeOut) { Get-Content -LiteralPath $probeOut -Raw } else { '' }
            Write-Host "probe file: [$text]"
            $result.TimedOut | Should -Be $false -Because 'a stall must surface as a timeout, not a hang of CI'
            $text | Should -Match 'xcheck_explorer_before=1' -Because 'Explorer is running on the runner'
            $text | Should -Match 'xcheck_launch_calculator=0' -Because 'Calculator is absent on Server, so the cross-check honestly reports 0'
            $text | Should -Match 'xcheck_launch_photos=0'
            $text | Should -Match 'xcheck_launch_media=0'
            $text | Should -Match 'xcheck_explorer_after=1' -Because 'the retries must not kill the running shell'
            $text | Should -Match 'xcheck_framehost_after=0' -Because 'no UWP app launched, so no frame host spawned'
            $text | Should -Match 'probe_uwp_done=1'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'W3: the WER Report.wer dump copies explorer reports and counts them (run 46)' -Skip:(-not $IsWindows) {
        # The verbatim dump snippet from probe.cmd, run against a fake
        # WER tree (ProgramData redirected to the work dir, so the real
        # WER queues are never touched). The queue holds one explorer
        # entry with a Report.wer and one notepad entry with a Report.wer;
        # the archive holds one explorer entry with a Report.wer. Only
        # the explorer reports may be copied, each with its entry header,
        # and wer_reports must count exactly those two.
        $workDir = & $script:NewWorkDir
        $werRoot = Join-Path $workDir 'ProgramData'
        $queue = Join-Path $werRoot 'Microsoft\Windows\WER\ReportQueue'
        $archive = Join-Path $werRoot 'Microsoft\Windows\WER\ReportArchive'
        $qDir = Join-Path $queue 'AppCrash_explorer.exe_9f2a1c'
        $nDir = Join-Path $queue 'AppCrash_notepad.exe_9f2a1c'
        $aDir = Join-Path $archive 'AppCrash_explorer.exe_7b3e9d'
        New-Item -ItemType Directory -Path $qDir -Force | Out-Null
        New-Item -ItemType Directory -Path $nDir -Force | Out-Null
        New-Item -ItemType Directory -Path $aDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $qDir 'Report.wer') -Value @('Version=1', 'Sig[4].Name=Fault Module Name', 'Sig[4].Value=EXPLORERFRAME.DLL', 'Sig[7].Name=Exception Code', 'Sig[7].Value=c0000005') -Encoding ascii
        Set-Content -LiteralPath (Join-Path $nDir 'Report.wer') -Value @('Version=1', 'Sig[4].Value=NOTEPAD.EXE') -Encoding ascii
        Set-Content -LiteralPath (Join-Path $aDir 'Report.wer') -Value @('Version=1', 'Sig[4].Name=Fault Module Name', 'Sig[4].Value=SHELL32.DLL') -Encoding ascii
        $outFile = Join-Path $workDir 'wer-out.txt'
        $taskFile = Join-Path $workDir 'micpe-tasklist.txt'
        $bat = Join-Path $workDir 'wer-dump.bat'
        try {
            & $script:WriteBatchCrlf $bat @(
                '@echo off',
                ('set "ProgramData={0}"' -f $werRoot),
                ('set "PROBE_OUT={0}"' -f $outFile),
                ('set "PROBE_LOCAL={0}"' -f $outFile),
                ('set "TASKLIST_OUT={0}"' -f $taskFile),
                'set "WER_REPORTS=0"',
                'for /d %%D in ("%ProgramData%\Microsoft\Windows\WER\ReportQueue\*explorer*") do (',
                '    if exist "%%D\Report.wer" (',
                '        echo --- WER ReportQueue %%~nxD --- >> "%TASKLIST_OUT%"',
                '        type "%%D\Report.wer" >> "%TASKLIST_OUT%" 2>nul',
                '        set /a WER_REPORTS+=1',
                '    )',
                ')',
                'for /d %%D in ("%ProgramData%\Microsoft\Windows\WER\ReportArchive\*explorer*") do (',
                '    if exist "%%D\Report.wer" (',
                '        echo --- WER ReportArchive %%~nxD --- >> "%TASKLIST_OUT%"',
                '        type "%%D\Report.wer" >> "%TASKLIST_OUT%" 2>nul',
                '        set /a WER_REPORTS+=1',
                '    )',
                ')',
                'echo wer_reports=%WER_REPORTS% >> "%PROBE_LOCAL%" & echo wer_reports=%WER_REPORTS% >> "%PROBE_OUT%"'
            )
            $result = & $script:InvokeCmdTimed $bat $workDir
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 0
            $text = Get-Content -LiteralPath $outFile -Raw
            $task = if (Test-Path -LiteralPath $taskFile) { Get-Content -LiteralPath $taskFile -Raw } else { '' }
            Write-Host "wer dump probe: [$text]"
            Write-Host "wer dump tasklist: [$task]"
            $text | Should -Match 'wer_reports=2' -Because 'one queue report plus one archive report'
            $task | Should -Match 'WER ReportQueue AppCrash_explorer\.exe_9f2a1c' -Because 'the queue report is headed with its entry name'
            $task | Should -Match 'EXPLORERFRAME\.DLL' -Because 'the queue Report.wer text is copied'
            $task | Should -Match 'c0000005' -Because 'the exception code line is copied too'
            $task | Should -Match 'WER ReportArchive AppCrash_explorer\.exe_7b3e9d' -Because 'the archive report is headed the same way'
            $task | Should -Match 'SHELL32\.DLL' -Because 'the archive Report.wer text is copied'
            $task | Should -Not -Match 'NOTEPAD\.EXE' -Because 'a non-explorer entry must not be copied'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'M1: the mirror root count counts the files on the volume (run 46)' -Skip:(-not $IsWindows) {
        # The verbatim mirror-root snippet from probe.cmd, run against
        # a temp directory holding exactly three files: the count must
        # be 3, the drive must be recorded, and the listing must land
        # in the tasklist file. A second run with an empty directory
        # must report 0, not missing.
        $workDir = & $script:NewWorkDir
        $mirrorDir = Join-Path $workDir 'mirror'
        New-Item -ItemType Directory -Path $mirrorDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $mirrorDir 'micpe-mirror.txt') -Value 'sentinel' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $mirrorDir 'a.txt') -Value 'a' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $mirrorDir 'b.txt') -Value 'b' -Encoding ascii
        $outFile = Join-Path $workDir 'mirror-out.txt'
        $taskFile = Join-Path $workDir 'micpe-tasklist.txt'
        $bat = Join-Path $workDir 'mirror-count.bat'
        $snippet = @(
            '@echo off',
            'setlocal EnableDelayedExpansion',
            ('set "MIRROR_DIR={0}"' -f $mirrorDir),
            ('set "PROBE_OUT={0}"' -f $outFile),
            ('set "TASKLIST_OUT={0}"' -f $taskFile),
            'set "MIRROR_ROOT="',
            'if defined MIRROR_DIR set "MIRROR_ROOT=%MIRROR_DIR%"',
            'if not defined MIRROR_ROOT if exist "D:\" set "MIRROR_ROOT=D:\"',
            'if defined MIRROR_ROOT (',
            '    echo --- dir %MIRROR_ROOT% --- >> "%TASKLIST_OUT%"',
            '    dir "%MIRROR_ROOT%" >> "%TASKLIST_OUT%" 2>nul',
            '    set "MIRROR_ROOT_FILES="',
            '    for /f %%F in (''dir /b "%MIRROR_ROOT%" 2^>nul ^| find /c /v ""'') do set "MIRROR_ROOT_FILES=%%F"',
            '    if defined MIRROR_ROOT_FILES (echo mirror_root_files=!MIRROR_ROOT_FILES: =! >> "%PROBE_OUT%") else (echo mirror_root_files=missing >> "%PROBE_OUT%")',
            '    echo mirror_root_drive=%MIRROR_ROOT% >> "%PROBE_OUT%"',
            ') else (',
            '    echo mirror_root_files=missing >> "%PROBE_OUT%"',
            ')'
        )
        try {
            & $script:WriteBatchCrlf $bat $snippet
            $result = & $script:InvokeCmdTimed $bat $workDir
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 0
            $text = Get-Content -LiteralPath $outFile -Raw
            $task = if (Test-Path -LiteralPath $taskFile) { Get-Content -LiteralPath $taskFile -Raw } else { '' }
            Write-Host "mirror count probe: [$text]"
            $text | Should -Match 'mirror_root_files=3' -Because 'the temp mirror holds exactly three files'
            $text | Should -Match 'mirror_root_drive=' -Because 'the listed drive is recorded'
            $task | Should -Match 'micpe-mirror\.txt' -Because 'the root listing is dumped into the tasklist file'
            # Empty directory: 0, not missing.
            Remove-Item -LiteralPath (Join-Path $mirrorDir 'micpe-mirror.txt') -Force
            Remove-Item -LiteralPath (Join-Path $mirrorDir 'a.txt') -Force
            Remove-Item -LiteralPath (Join-Path $mirrorDir 'b.txt') -Force
            Remove-Item -LiteralPath $outFile -Force
            Remove-Item -LiteralPath $taskFile -Force
            $result = & $script:InvokeCmdTimed $bat $workDir
            $result.TimedOut | Should -Be $false
            $text = Get-Content -LiteralPath $outFile -Raw
            $text | Should -Match 'mirror_root_files=0' -Because 'an empty volume reports 0 files, not missing'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reverse control: without the frame-host check the diagnostics test fails' {
        # The presence assertion above must actually depend on the probe
        # checking for the frame host, not pass vacuously.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $mutated = $text.Replace('appframehost=', 'appframehost-missing=')
        $mutated | Should -Not -Match 'appframehost='
    }
}

Describe 'explorer CPU time (run 44428428849)' {
    It 'C1: the CPU-time parse extracts a time from tasklist /v /fo list' -Skip:(-not $IsWindows) {
        # The table form cannot be parsed — its memory column holds
        # "31,048 K", whose comma breaks token counting — so the probe
        # reads the list form's CPU-time line ("CPU Time:  0:00:13" in
        # en-US, "CPU 时间:  0:00:13" in zh-CN) with tokens=3. The match
        # is on "CPU" alone: run 44459251306 proved "CPU Time" never
        # matches on the zh-CN image. "CPU" is the first token of that
        # line in both languages, and no other list-form line contains
        # it, so the same snippet parses both.
        # Run 44441708839: the old snippet carried /nh, which is only
        # valid with /fo table or csv — with /fo list tasklist fails,
        # the error is swallowed by 2>nul, and every key came back
        # missing. The old C1 passed anyway: it accepted "a time or an
        # explicit missing", so the missing branch hid the broken
        # snippet. Strict now — with one deliberate deviation: the
        # filter is cmd.exe, not explorer.exe. The runner's tests run
        # in session 0, where no explorer.exe is visible (Test run
        # 44449769368 proved it: the head test's explorer=0 and dwm=0),
        # so an explorer.exe filter could never yield a time there.
        # cmd.exe is the test batch's own process, guaranteed visible,
        # so a real time here proves the pipeline itself works — list
        # form, tokens=3, no /nh. One deviation from probe.cmd: the
        # batch calls tasklist by its System32 full path, not bare.
        # The work-dir COPY of tasklist.exe rejects /fi ("The search
        # filter cannot be recognized.", exit 1) although it is
        # byte-identical to the original (C1diag, run 44457204773) —
        # a bare call here would resolve to that copy via PATH and
        # yield missing for the wrong reason. In PE the probe's bare
        # call resolves to the image's real System32 tasklist, which
        # accepts /fi, so the full path here is the faithful
        # simulation. The path is deliberately UNQUOTED: it has no
        # spaces, and a leading quote makes cmd /c strip the first
        # and last quote of the for /f command (run 44458215755 —
        # the quoted form yielded missing even with the working
        # original). The exact line in probe.cmd (with the
        # explorer.exe filter) is pinned by the static exact-line test
        # above; C1b below proves /nh breaks the same pipeline.
        $workDir = & $script:NewWorkDir
        $outFile = Join-Path $workDir 'cpu-out.txt'
        $bat = Join-Path $workDir 'cpu-parse.bat'
        try {
            & $script:WriteBatchCrlf $bat @(
                '@echo off',
                'set "EXPLORER_CPU="',
                ('for /f "tokens=3" %%C in (''{0} /v /fo list /fi "imagename eq cmd.exe" 2^>nul ^| find /i "CPU"'') do set "EXPLORER_CPU=%%C"' -f $script:TasklistExe),
                ('if defined EXPLORER_CPU (echo explorer_cpu=%EXPLORER_CPU% >> "{0}") else (echo explorer_cpu=missing >> "{0}")' -f $outFile)
            )
            $result = & $script:InvokeCmdTimed $bat $workDir
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 0
            $text = Get-Content -LiteralPath $outFile -Raw
            Write-Host "cpu parse: [$text]"
            $text | Should -Match 'explorer_cpu=[0-9]+:[0-9]{2}:[0-9]{2}' -Because 'cmd.exe runs in the test session, so the parse must yield a real time — missing would mean the snippet is broken (run 44441708839)'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'the work-dir tasklist copy rejects /fi; the System32 original accepts it (run 44457204773)' -Skip:(-not $IsWindows) {
        # Harness trap, proven by C1diag v3-v6: NewWorkDir copies
        # tasklist.exe out of System32 so the restricted PATH can
        # resolve it, but the copy rejects /fi ("The search filter
        # cannot be recognized.", exit 1) although it is
        # byte-identical to the original (SHA256 proven in v3) and
        # works with no args (841 lines). The original accepts /fi
        # and finds pwsh.exe; the copy fails the same filter. Any
        # test that needs /fi must call the System32 original by
        # full path (C1/C1b do); a bare call resolves to the copy
        # and yields missing for the wrong reason. If this test ever
        # turns green the other way round (the copy accepts /fi),
        # the harness limitation is gone — re-check C1/C1b, which
        # can then go back to a bare call.
        $workDir = & $script:NewWorkDir
        try {
            $copy = Join-Path $workDir 'tasklist.exe'
            $oFi = & $script:TasklistExe /fi "imagename eq pwsh.exe" 2>&1 | Out-String
            Write-Host "orig /fi pwsh exit $($LASTEXITCODE) [$oFi]"
            $cFi = & $copy /fi "imagename eq pwsh.exe" 2>&1 | Out-String
            Write-Host "copy /fi pwsh exit $($LASTEXITCODE) [$cFi]"
            $oV = & $script:TasklistExe /v /fo list /fi "imagename eq pwsh.exe" 2>&1 | Out-String
            Write-Host "orig /v /fo list /fi pwsh exit $($LASTEXITCODE) [$oV]"
            $cV = & $copy /v /fo list /fi "imagename eq pwsh.exe" 2>&1 | Out-String
            Write-Host "copy /v /fo list /fi pwsh exit $($LASTEXITCODE) [$cV]"
            ($oFi -match 'pwsh.exe') | Should -Be $true -Because 'the control cell must find pwsh.exe'
            ($oV -match 'CPU Time:') | Should -Be $true -Because 'the original must show a CPU Time line in list form'
            ($cFi -match 'The search filter cannot be recognized') | Should -Be $true -Because 'the copy must reject /fi'
            ($cV -match 'pwsh.exe') | Should -Be $false -Because 'the copy must not find anything with /v /fo list /fi'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'C1b: the same snippet WITH /nh yields missing on real cmd.exe (run 44441708839)' -Skip:(-not $IsWindows) {
        # Reverse control for C1: the exact pre-fix snippet, /nh and
        # all, must produce missing on the same runner where C1
        # produces a time. Same cmd.exe filter as C1 — cmd.exe is
        # running, so missing here can only mean /nh broke tasklist,
        # not that the process is absent. (An explorer.exe filter
        # would prove nothing on this runner: Test run 44449769368
        # showed explorer is invisible in session 0, so missing
        # would be the answer either way.) Same System32 full path
        # as C1: the work-dir copy rejects /fi (run 44457204773),
        # so a bare call would yield missing for the wrong reason
        # and this reverse control would prove nothing.
        $workDir = & $script:NewWorkDir
        $outFile = Join-Path $workDir 'cpu-out.txt'
        $bat = Join-Path $workDir 'cpu-parse-broken.bat'
        try {
            & $script:WriteBatchCrlf $bat @(
                '@echo off',
                'set "EXPLORER_CPU="',
                ('for /f "tokens=3" %%C in (''{0} /v /fo list /fi "imagename eq cmd.exe" /nh 2^>nul ^| find /i "CPU"'') do set "EXPLORER_CPU=%%C"' -f $script:TasklistExe),
                ('if defined EXPLORER_CPU (echo explorer_cpu=%EXPLORER_CPU% >> "{0}") else (echo explorer_cpu=missing >> "{0}")' -f $outFile)
            )
            $result = & $script:InvokeCmdTimed $bat $workDir
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 0
            $text = Get-Content -LiteralPath $outFile -Raw
            Write-Host "cpu parse with /nh: [$text]"
            $text | Should -Match 'explorer_cpu=missing' -Because '/nh is invalid with /fo list, so tasklist fails and nothing parses'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'probe.cmd wedge and activation diagnostics (run 47)' {
    BeforeAll {
        # Extract one subroutine from probe.cmd by content (label to the
        # next label), so the mechanism tests run the real code, not a
        # hand copy that can drift silently.
        $script:ExtractProbeSub = {
            param([string] $Label, [string] $StopLabel)
            $lines = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
            $start = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match "^$Label") { $start = $i; break }
            }
            if ($start -lt 0) { throw "subroutine $Label not found in probe.cmd" }
            $end = $lines.Count - 1
            for ($i = $start + 1; $i -lt $lines.Count; $i++) {
                if ($StopLabel -and ($lines[$i] -match "^$StopLabel")) { $end = $i - 1; break }
            }
            return ,@($lines[$start..$end])
        }
    }

    It 'takes a WER/evtx snapshot in the diagnostics, after the launches, and after the cross-check' {
        # Run 46: the WER/evtx/dump capture lived in the end snapshot,
        # so the guest wedging in the Media poll took all of it — the
        # breakpoint evidence stayed blank. Three mid-run snapshots now
        # bound the evidence to the section that produced it.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $calls = @([regex]::Matches($text, 'call :probe_wer_snapshot'))
        $calls.Count | Should -Be 3 -Because 'exactly three mid-run snapshots: diag, uwp, xcheck'
        $text.IndexOf('call :probe_wer_snapshot diag') | Should -BeGreaterThan $text.IndexOf('call :probe_explorer_cpu diag') -Because 'the diag snapshot comes after the mid-diagnosis liveness check'
        $text.IndexOf('call :probe_wer_snapshot diag') | Should -BeLessThan $text.IndexOf('rem --- uwp ---') -Because 'the diag snapshot is taken before the launches'
        $text.IndexOf('call :probe_wer_snapshot uwp') | Should -BeGreaterThan $text.IndexOf('call :probe_svc AppReadiness appreadiness_after') -Because 'the uwp snapshot comes after the launches and the re-check'
        $text.IndexOf('call :probe_wer_snapshot uwp') | Should -BeLessThan $text.IndexOf('rem --- cross-check') -Because 'the uwp snapshot is taken before the cross-check'
        $text.IndexOf('call :probe_wer_snapshot xcheck') | Should -BeGreaterThan $text.IndexOf('xcheck_framehost_after=') -Because 'the xcheck snapshot comes after the cross-check'
        $text.IndexOf('call :probe_wer_snapshot xcheck') | Should -BeLessThan $text.IndexOf('rem --- payload') -Because 'the xcheck snapshot is taken before the payload section'
    }

    It 'the WER snapshot subroutine records suffixed keys and suffixed evtx copies' {
        $snap = & $script:ExtractProbeSub ':probe_wer_snapshot' ':probe_poll_check'
        $body = $snap -join "`n"
        $body | Should -Match 'mark_wer_%~1=' -Because 'each snapshot marks its section with its suffix'
        $body | Should -Match 'wer_%~1_explorer=' -Because 'each snapshot names its explorer WER state with its suffix'
        $body | Should -Match 'wer_%~1_reports=' -Because 'each snapshot counts the copied reports with its suffix'
        $body | Should -Match 'wer_%~1_explorer_name=' -Because 'the report name is recorded with its suffix'
        $body | Should -Match 'wer_%~1_explorer_time=' -Because 'the report time is recorded with its suffix'
        $body | Should -Match 'evtx_%~1_system=' -Because 'each snapshot records its System log state with its suffix'
        $body | Should -Match 'micpe-system-%~1\.evtx' -Because 'each snapshot copies the System log under a suffixed name'
        $body | Should -Match 'micpe-application-%~1\.evtx' -Because 'each snapshot copies the Application log under a suffixed name'
        $body | Should -Match 'dump_%~1_minidump=' -Because 'each snapshot records its minidump state with its suffix'
        $body | Should -Match 'Report\.wer' -Because 'each snapshot types the explorer Report.wer into the tasklist file'
    }

    It 'checks the poll through a detached tasklist, never a direct pipe' {
        # Run 46 died between a poll round's wait_after and check_after
        # — the only step in between is the tasklist|find pipeline, so
        # a hung tasklist enumeration kills the probe outright. The
        # poll now runs tasklist detached in a child cmd and waits on
        # its output file with a bounded spin plus two one-second
        # ticks; a timeout is recorded and the poll continues.
        $probe = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
        $helper = & $script:ExtractProbeSub ':probe_poll_check' ':probe_sync_local'
        $helperBody = $helper -join "`n"
        $helperBody | Should -Match 'start "" /min cmd /c tasklist' -Because 'tasklist runs detached in a child cmd'
        $helperBody | Should -Match 'echo DONE' -Because 'the child appends a DONE sentinel after tasklist exits'
        $helperBody | Should -Match '%%~zF gtr 0' -Because 'the parent waits for the file to be non-empty, not merely to exist (the redirection creates it at once)'
        $helperBody | Should -Match 'tasklist_timeout_%~1=1' -Because 'a hung enumeration is recorded, not swallowed'
        $helperBody | Should -Match 'taskkill /f /im tasklist\.exe' -Because 'the helper tries to kill the hung tasklist before returning'
        $helperBody | Should -Match 'exit /b 0' -Because 'the helper returns 0 when the process is listed'
        $helperBody | Should -Match 'exit /b 1' -Because 'the helper returns 1 when the process is absent or the check times out'
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        @([regex]::Matches($text, 'call :probe_poll_check %UWP_PROC%')).Count | Should -Be 2 -Because 'the uwp pre-check and the uwp poll both go through the helper'
        @([regex]::Matches($text, 'call :probe_poll_check %XCHECK_PROC%')).Count | Should -Be 2 -Because 'the xcheck pre-check and the xcheck poll both go through the helper'
        @([regex]::Matches($text, 'call :probe_poll_check explorer')).Count | Should -Be 2 -Because 'both mid-poll liveness checks go through the helper'
        # Neither poll loop may call tasklist directly any more: take
        # each loop from its label to its final exit and require no
        # line starting with tasklist.
        foreach ($label in @(':probe_uwp_poll', ':probe_xcheck_poll')) {
            $start = -1
            for ($i = 0; $i -lt $probe.Count; $i++) {
                if ($probe[$i] -match "^$label") { $start = $i; break }
            }
            $start | Should -BeGreaterThan -1 -Because "probe.cmd must still carry $label"
            $end = $start
            for ($i = $start + 1; $i -lt $probe.Count; $i++) {
                if ($probe[$i] -match '^exit /b 1') { $end = $i; break }
            }
            $section = $probe[$start..$end] -join "`n"
            $section | Should -Not -Match '(?m)^tasklist /fi' -Because "$label must not call tasklist directly"
        }
    }

    It 'adds no new tasklist /v snapshot lines' {
        # The three full snapshots (diagnosis, folder-window test, end)
        # are pinned by the stage table; the helper uses tasklist /fi
        # only, and the new diagnostics add sc/mountvol dumps, not
        # tasklist /v lines.
        $probe = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
        ($probe | Where-Object { $_ -match '^tasklist /v' }).Count | Should -Be 3
    }

    It 'dual-writes the launch and verdict keys to the local probe file' {
        # Run 46: a 724-byte NUL hole in the share probe file ate the
        # Calculator launch result. The local file never goes through
        # the share, so the keys a verdict depends on are written to
        # both files.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        foreach ($key in @('uwp_launch_calculator', 'uwp_launch_photos', 'uwp_launch_media',
                'xcheck_launch_calculator', 'xcheck_launch_photos', 'xcheck_launch_media')) {
            $text.Contains("echo $key=1 >> `"%PROBE_LOCAL%`" & echo $key=1 >> `"%PROBE_OUT%`"") | Should -Be $true -Because "$key must be written to the local file as well as the share file"
        }
        $text.Contains('echo payload=%PAYLOAD% >> "%PROBE_LOCAL%" & echo payload=%PAYLOAD% >> "%PROBE_OUT%"') | Should -Be $true -Because 'payload must survive a NUL hole in the share file'
        $text.Contains('echo brand=%BRAND% >> "%PROBE_LOCAL%" & echo brand=%BRAND% >> "%PROBE_OUT%"') | Should -Be $true -Because 'brand must survive a NUL hole in the share file'
    }

    It 'diagnoses the UWP activation chain in the uwp section opening' {
        # Run 46: the package is in the store (appxstore_media=1) but
        # the shell namespace cannot resolve its AUMID — Media died
        # with a "Windows cannot find the file" dialog. These checks
        # say which link of the activation chain is broken, before
        # the launches. They sit after mark_uwp_appx, not in the
        # diagnostics above: the activation_files line names
        # AppXDeploymentClient.dll, and a marker test pins
        # mark_uwp_appx before the first occurrence of that name.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $appx = $text.IndexOf('mark_uwp_appx=')
        $launch = $text.IndexOf('call :probe_uwp CalculatorApp')
        $appx | Should -BeGreaterThan -1
        $launch | Should -BeGreaterThan $appx
        foreach ($key in @('appsfolder_clsid=', 'aumid_calc=', 'aumid_photos=', 'aumid_media=', 'activation_files=', 'mountvol_dump=')) {
            $pos = $text.IndexOf($key)
            $pos | Should -BeGreaterThan $appx -Because "$key is a uwp-section check, after the appx marker"
            $pos | Should -BeLessThan $launch -Because "$key is recorded before the launches"
        }
        # Pin the =1 branch, dual-written — a key name alone is not
        # enough: the 0 branch carries the same name, so a mutation
        # that deletes the 1 branch would otherwise pass unnoticed.
        foreach ($key in @('appsfolder_clsid', 'aumid_calc', 'aumid_photos', 'aumid_media', 'activation_files', 'mountvol_dump')) {
            $text.Contains("echo $key=1 >> `"%PROBE_LOCAL%`" & echo $key=1 >> `"%PROBE_OUT%`"") | Should -Be $true -Because "$key must record 1 to the local file as well as the share file"
        }
        $text | Should -Match 'reg query "HKLM\\SOFTWARE\\Classes\\CLSID\\\{4234d49b-0245-4df3-b780-3893943456e1\}' -Because 'the shell:AppsFolder class registration is checked'
        $text | Should -Match 'Microsoft\.WindowsCalculator_8wekyb3d8bbwe!App' -Because 'the Calculator AUMID is looked up in AppxAllUserStore'
        $text | Should -Match 'Microsoft\.ZuneMusic_8wekyb3d8bbwe!Microsoft\.ZuneMusic' -Because 'the Media AUMID is looked up in AppxAllUserStore'
        $text | Should -Match 'twinapi\.appcore\.dll' -Because 'the activation DLLs are checked'
        $text | Should -Match 'sc qc AppXSVC' -Because 'the deployment services config is dumped'
        $text | Should -Match 'sc qc StateRepository'
        $text | Should -Match 'sc qc AppReadiness'
        $text | Should -Match '(?m)^mountvol' -Because 'the volume table is dumped (the mirror volume question)'
    }

    It 'never pipes a bang-carrying pattern through find' {
        # CI run 44519361912: the batch died on the piped AUMID
        # reg-query line with exit 255 and no stderr — the pipe
        # child parses the bang with delayed expansion on, and the
        # unterminated !...! swallows the rest of the batch. The
        # AUMID lookups dump the store to a file and search the file
        # instead; pin that shape here so the pipe never comes back.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Not -Match '\| find /i "[^"]*!' -Because 'a piped find must never carry a bang in its pattern'
        $text | Should -Match 'micpe-aumid\.tmp' -Because 'the AUMID lookups search a dumped file instead of a pipe'
    }

    It 'copies the local probe file to the share at the end of every section' {
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $calls = @([regex]::Matches($text, 'call :probe_sync_local'))
        $calls.Count | Should -Be 5 -Because 'diag, uwp, xcheck, brand, and the sc start experiment each sync the local file; the end also fires a detached copy (run 48)'
        $text.IndexOf('call :probe_sync_local', $text.IndexOf('call :probe_wer_snapshot diag')) | Should -BeGreaterThan $text.IndexOf('call :probe_wer_snapshot diag') -Because 'the diag section syncs after its snapshot'
        $text.IndexOf('call :probe_sync_local', $text.IndexOf('call :probe_wer_snapshot uwp')) | Should -BeGreaterThan $text.IndexOf('call :probe_wer_snapshot uwp') -Because 'the uwp section syncs after its snapshot'
        $text.IndexOf('call :probe_sync_local', $text.IndexOf('call :probe_wer_snapshot xcheck')) | Should -BeGreaterThan $text.IndexOf('call :probe_wer_snapshot xcheck') -Because 'the xcheck section syncs after its snapshot'
        $text.IndexOf('call :probe_sync_local', $text.IndexOf('echo brand=')) | Should -BeGreaterThan $text.IndexOf('echo brand=') -Because 'the brand section syncs after the brand verdict'
        $text.IndexOf('call :probe_sync_local', $text.IndexOf('call :probe_sc_start AppXSVC appxsvc')) | Should -BeGreaterThan $text.IndexOf('call :probe_sc_start AppXSVC appxsvc') -Because 'the experiment syncs after the last start call, so the experiment keys reach the share copy too'
        $text.IndexOf('start "" /min cmd /c copy /y "%PROBE_LOCAL%"', $text.IndexOf('echo dump_memory=')) | Should -BeGreaterThan $text.IndexOf('echo dump_memory=') -Because 'the end copy happens after the end snapshot'
        $text.IndexOf('start "" /min cmd /c copy /y "%PROBE_LOCAL%"') | Should -BeGreaterThan $text.IndexOf('echo probe_done=1') -Because 'the end copy is fired after probe_done is written to the local file'
        $sync = & $script:ExtractProbeSub ':probe_sync_local' ''
        ($sync -join "`n") | Should -Match 'copy /y "%PROBE_LOCAL%" "%PROBE_DIR%micpe-probe-local\.txt"' -Because 'the sync copies the local file onto the share'
    }

    It 'the poll-check pin fails when the uwp poll goes back to a direct tasklist (reverse control)' {
        # Proves the static pin above would catch the regression: put
        # the direct call back into the poll and the "no direct
        # tasklist" assertion must fire.
        $probe = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
        $start = -1
        for ($i = 0; $i -lt $probe.Count; $i++) {
            if ($probe[$i] -match '^:probe_uwp_poll') { $start = $i; break }
        }
        $start | Should -BeGreaterThan -1
        $end = $start
        for ($i = $start + 1; $i -lt $probe.Count; $i++) {
            if ($probe[$i] -match '^exit /b 1') { $end = $i; break }
        }
        $section = $probe[$start..$end] -join "`n"
        $mutated = $section -replace 'call :probe_poll_check %UWP_PROC%', 'tasklist /fi "imagename eq %UWP_PROC%.exe" /nh 2>nul | find /i "%UWP_PROC%.exe" >nul'
        $mutated | Should -Match '(?m)^tasklist /fi' -Because 'the mutation must actually restore the direct call'
        $section | Should -Not -Match '(?m)^tasklist /fi' -Because 'the real poll must not call tasklist directly'
    }

    It 'P1: the poll helper returns 0 fast when the process is listed' -Skip:(-not $IsWindows) {
        $workDir = & $script:NewWorkDir
        Remove-Item -LiteralPath (Join-Path $workDir 'tasklist.exe') -Force
        & $script:WriteBatchCrlf (Join-Path $workDir 'tasklist.bat') @('@echo off', 'echo %*')
        $outFile = Join-Path $workDir 'poll-out.txt'
        $bat = Join-Path $workDir 'poll-check.bat'
        $helper = & $script:ExtractProbeSub ':probe_poll_check' ':probe_sync_local'
        try {
            & $script:WriteBatchCrlf $bat (@(
                '@echo off',
                ('set "SystemDrive={0}"' -f $workDir),
                ('set "PROBE_OUT={0}"' -f $outFile),
                ('set "PROBE_LOCAL={0}"' -f $outFile),
                'call :probe_poll_check CalculatorApp',
                'echo poll_rc=%ERRORLEVEL% >> "%PROBE_OUT%"',
                'exit /b 0'
            ) + $helper)
            $result = & $script:InvokeCmdTimed $bat $workDir -TimeoutSec 60
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 0
            $text = Get-Content -LiteralPath $outFile -Raw
            Write-Host "poll found: [$text]"
            $text | Should -Match 'poll_rc=0' -Because 'the stub lists the process, so the helper returns 0'
            $text | Should -Not -Match 'tasklist_timeout_' -Because 'a fast answer must not be recorded as a timeout'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'P2: the poll helper returns 1 with no timeout when the process is absent' -Skip:(-not $IsWindows) {
        $workDir = & $script:NewWorkDir
        Remove-Item -LiteralPath (Join-Path $workDir 'tasklist.exe') -Force
        & $script:WriteBatchCrlf (Join-Path $workDir 'tasklist.bat') @('@echo off', 'exit /b 0')
        $outFile = Join-Path $workDir 'poll-out.txt'
        $bat = Join-Path $workDir 'poll-check.bat'
        $helper = & $script:ExtractProbeSub ':probe_poll_check' ':probe_sync_local'
        try {
            & $script:WriteBatchCrlf $bat (@(
                '@echo off',
                ('set "SystemDrive={0}"' -f $workDir),
                ('set "PROBE_OUT={0}"' -f $outFile),
                ('set "PROBE_LOCAL={0}"' -f $outFile),
                'call :probe_poll_check CalculatorApp',
                'echo poll_rc=%ERRORLEVEL% >> "%PROBE_OUT%"',
                'exit /b 0'
            ) + $helper)
            $result = & $script:InvokeCmdTimed $bat $workDir -TimeoutSec 60
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 0
            $text = Get-Content -LiteralPath $outFile -Raw
            Write-Host "poll absent: [$text]"
            $text | Should -Match 'poll_rc=1' -Because 'an empty listing means the process is absent'
            $text | Should -Not -Match 'tasklist_timeout_' -Because 'an empty answer is not a timeout'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'P3: the poll helper times out, records tasklist_timeout, and returns 1 when tasklist never answers' -Skip:(-not $IsWindows) {
        # The run-46 wedge: the child tasklist never writes its file,
        # so the parent must give up after a bounded wait and let the
        # poll continue instead of dying with the probe. The blocking
        # stub lingers in the background after the batch exits (its
        # choice runs 30 s); the work-dir cleanup tolerates that.
        $workDir = & $script:NewWorkDir
        Remove-Item -LiteralPath (Join-Path $workDir 'tasklist.exe') -Force
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\taskkill.exe') -Destination (Join-Path $workDir 'taskkill.exe')
        & $script:WriteBatchCrlf (Join-Path $workDir 'tasklist.bat') @('@echo off', 'choice /c Y /d Y /t 30 >nul')
        $outFile = Join-Path $workDir 'poll-out.txt'
        $bat = Join-Path $workDir 'poll-check.bat'
        $helper = & $script:ExtractProbeSub ':probe_poll_check' ':probe_sync_local'
        try {
            & $script:WriteBatchCrlf $bat (@(
                '@echo off',
                ('set "SystemDrive={0}"' -f $workDir),
                ('set "PROBE_OUT={0}"' -f $outFile),
                ('set "PROBE_LOCAL={0}"' -f $outFile),
                'call :probe_poll_check CalculatorApp',
                'echo poll_rc=%ERRORLEVEL% >> "%PROBE_OUT%"',
                'exit /b 0'
            ) + $helper)
            $result = & $script:InvokeCmdTimed $bat $workDir -TimeoutSec 60
            $result.TimedOut | Should -Be $false -Because 'a hung tasklist must not hang the probe'
            $result.ExitCode | Should -Be 0
            $text = Get-Content -LiteralPath $outFile -Raw
            Write-Host "poll timeout: [$text]"
            $text | Should -Match 'poll_rc=1' -Because 'no answer means not found'
            $text | Should -Match 'tasklist_timeout_CalculatorApp=1' -Because 'the timeout is recorded for the host to see'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'W4: the WER snapshot subroutine records a suffixed snapshot from a fake tree' -Skip:(-not $IsWindows) {
        $workDir = & $script:NewWorkDir
        $werRoot = Join-Path $workDir 'ProgramData'
        $queue = Join-Path $werRoot 'Microsoft\Windows\WER\ReportQueue'
        $archive = Join-Path $werRoot 'Microsoft\Windows\WER\ReportArchive'
        $queueEntry = Join-Path $queue 'AppCrash_explorer.exe_9f2a1c'
        New-Item -ItemType Directory -Path $queueEntry -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $archive 'AppHang_explorer.exe_7b3e9d') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $queueEntry 'Report.wer'), "Fault Module: test.dll`r`n", [System.Text.Encoding]::ASCII)
        $fakeWin = Join-Path $workDir 'Windows'
        $logs = Join-Path $fakeWin 'System32\winevt\Logs'
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $logs 'System.evtx'), 'fake-system-evtx', [System.Text.Encoding]::ASCII)
        [System.IO.File]::WriteAllText((Join-Path $logs 'Application.evtx'), 'fake-app-evtx', [System.Text.Encoding]::ASCII)
        $shareDir = Join-Path $workDir 'share'
        New-Item -ItemType Directory -Path $shareDir -Force | Out-Null
        $outFile = Join-Path $workDir 'wer-out.txt'
        $tasklistFile = Join-Path $workDir 'tasklist.txt'
        $bat = Join-Path $workDir 'wer-snapshot.bat'
        $snap = & $script:ExtractProbeSub ':probe_wer_snapshot' ':probe_poll_check'
        try {
            & $script:WriteBatchCrlf $bat (@(
                '@echo off',
                ('set "ProgramData={0}"' -f $werRoot),
                ('set "SystemRoot={0}"' -f $fakeWin),
                ('set "PROBE_DIR={0}\"' -f $shareDir),
                ('set "PROBE_OUT={0}"' -f $outFile),
                ('set "PROBE_LOCAL={0}"' -f $outFile),
                ('set "TASKLIST_OUT={0}"' -f $tasklistFile),
                'call :probe_wer_snapshot diag',
                'exit /b 0'
            ) + $snap)
            $result = & $script:InvokeCmdTimed $bat $workDir -TimeoutSec 60
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 0
            $text = Get-Content -LiteralPath $outFile -Raw
            Write-Host "wer snapshot: [$text]"
            $text | Should -Match 'mark_wer_diag=' -Because 'the snapshot marks its section'
            $text | Should -Match 'wer_diag_explorer=1' -Because 'an explorer entry exists in the queue'
            $text | Should -Match 'wer_diag_explorer_name=AppCrash_explorer\.exe_9f2a1c' -Because 'the queue entry name is copied with the suffix'
            $text | Should -Match 'wer_diag_explorer_time=[0-9]' -Because 'the queue entry time is copied with the suffix'
            $text | Should -Match 'wer_diag_reports=1' -Because 'one report was copied'
            $text | Should -Match 'wer_diag_explorer_archive_name=AppHang_explorer\.exe_7b3e9d' -Because 'the archive entry name is copied too'
            $text | Should -Match 'evtx_diag_system=1' -Because 'the fake System log exists'
            $text | Should -Match 'evtx_diag_system_size=[0-9]' -Because 'the System log size is recorded'
            $text | Should -Match 'evtx_diag_system_copy=1' -Because 'the System log copy landed on the share'
            $text | Should -Match 'evtx_diag_app_copy=1' -Because 'the Application log copy landed on the share'
            $text | Should -Match 'dump_diag_minidump=0' -Because 'no minidump exists in the fake tree'
            $text | Should -Match 'dump_diag_memory=0' -Because 'no full memory dump exists in the fake tree'
            (Test-Path -LiteralPath (Join-Path $shareDir 'micpe-system-diag.evtx')) | Should -Be $true -Because 'the suffixed System log copy must be on the share'
            (Test-Path -LiteralPath (Join-Path $shareDir 'micpe-application-diag.evtx')) | Should -Be $true -Because 'the suffixed Application log copy must be on the share'
            $tasklist = Get-Content -LiteralPath $tasklistFile -Raw
            $tasklist | Should -Match 'Fault Module: test\.dll' -Because 'the explorer Report.wer is typed into the tasklist file'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'probe.cmd run 48 harness liveness and activation diagnostics (run 48)' {
    BeforeAll {
        # Same subroutine extractor as the run 47 Describe: extract by
        # content (label to the next label), so the tests run against
        # the real code, not a hand copy that can drift silently.
        $script:ExtractProbeSub48 = {
            param([string] $Label, [string] $StopLabel)
            $lines = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
            $start = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match "^$Label") { $start = $i; break }
            }
            if ($start -lt 0) { throw "subroutine $Label not found in probe.cmd" }
            $end = $lines.Count - 1
            for ($i = $start + 1; $i -lt $lines.Count; $i++) {
                if ($StopLabel -and ($lines[$i] -match "^$StopLabel")) { $end = $i - 1; break }
            }
            return ,@($lines[$start..$end])
        }
    }

    It 'copies each WER Report.wer straight to the share in the mid-run snapshot' {
        # Run 47: the WER report NAME and time reached the host, but
        # the Report.wer CONTENT never did — the share view stopped at
        # 12:41, before the end snapshot typed it into the tasklist
        # file, so the faulting module is still blank. A fresh
        # create+write+close copy is the channel that survived run 47
        # (the local probe copy landed complete at every section
        # sync); the tasklist transcription is not a reliable channel.
        $snap = & $script:ExtractProbeSub48 ':probe_wer_snapshot' ':probe_poll_check'
        $body = $snap -join "`n"
        $body | Should -Match 'micpe-wer-explorer-%~1\.wer' -Because 'the queue report is copied under a suffixed name'
        $body | Should -Match 'wer_%~1_wer_copy=' -Because 'the queue copy landing is recorded with its suffix'
        $body | Should -Match 'micpe-wer-explorer-%~1-archive\.wer' -Because 'the archive report is copied under its own suffixed name'
        $body | Should -Match 'wer_%~1_archive_wer_copy=' -Because 'the archive copy landing is recorded with its suffix'
        $body | Should -Match 'copy /y "%%D\\Report\.wer" "%PROBE_DIR%micpe-wer-explorer-%~1\.wer"' -Because 'the copy is a whole-file copy, not an append into the live probe file'
    }

    It 'copies the end-snapshot WER report straight to the share too' {
        # The end snapshot keeps its unsuffixed keys; the copy lands
        # under the unsuffixed name so build.yml can upload it with
        # one glob.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'copy /y "%%D\\Report\.wer" "%PROBE_DIR%micpe-wer-explorer\.wer"' -Because 'the end snapshot copies its report the same way'
        $text | Should -Match 'wer_wer_copy=' -Because 'the end copy landing is recorded'
        $text.IndexOf('wer_wer_copy=') | Should -BeGreaterThan $text.IndexOf('wer_reports=') -Because 'the copy key is written after the report count'
        $text.IndexOf('wer_wer_copy=') | Should -BeLessThan $text.IndexOf('rem Run 46 (explorer breakpoint): a silent exit writes no Event') -Because 'the copy key belongs to the WER block, not the evtx block'
    }

    It 'diagnoses the deployment services start config without starting them' {
        # Run 48: AppXSVC/StateRepository/AppReadiness sit STOPPED
        # with Start=0x3 (manual) and nothing ever starts them — the
        # launches need them running, so the probe records WHY they
        # never run: the Start type, the ServiceDll the SCM would
        # load, whether that file exists, and the account. Reads only.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        foreach ($svc in @('AppXSVC', 'StateRepository', 'AppReadiness')) {
            $text | Should -Match "call :probe_svc_reg $svc" -Because "the $svc start config is recorded in the activation block"
        }
        $text.IndexOf('call :probe_svc_reg AppXSVC') | Should -BeGreaterThan $text.IndexOf('sc qc AppReadiness') -Because 'the reg reads come after the raw qc dumps'
        $text.IndexOf('call :probe_svc_reg AppReadiness') | Should -BeLessThan $text.IndexOf('echo --- mountvol ---') -Because 'the reg reads come before the volume dump'
        $reg = & $script:ExtractProbeSub48 ':probe_svc_reg' $null
        $regBody = $reg -join "`n"
        $regBody | Should -Match 'sc qc %1' -Because 'the Start type and the account come from sc qc'
        $regBody | Should -Match 'START_TYPE' -Because 'the Start type is parsed from the qc output'
        $regBody | Should -Match 'SERVICE_START_NAME' -Because 'the account is parsed from the qc output'
        $regBody | Should -Match 'ServiceDll' -Because 'the ServiceDll comes from the service Parameters key'
        $regBody | Should -Match 'svc_%2_start=' -Because 'the Start type is recorded under the service prefix'
        $regBody | Should -Match 'svc_%2_dll=' -Because 'the ServiceDll literal is recorded under the service prefix'
        $regBody | Should -Match 'svc_%2_dll_exists=' -Because 'the ServiceDll file existence is recorded under the service prefix'
        $regBody | Should -Match 'svc_%2_obj=' -Because 'the account is recorded under the service prefix'
        $regBody | Should -Match 'exit /b 0' -Because 'the subroutine returns cleanly'
    }

    It 'starts the AppX services only after probe_done (run 39 control lifted in run 51)' {
        # The run 39 control: the probe and the watchdog both stopped
        # within ~15 seconds of two sc start calls, so sc start is the
        # prime suspect for a guest-wide wedge — and a detached sc.exe
        # would not protect against the service start itself wedging
        # the guest. Runs 41/44/45/47 proved the probe runs through
        # WITHOUT starting them, so the start attempt is a separate
        # experiment (after probe_done, where a wedge costs nothing).
        # Run 51 runs that experiment: the start calls live after
        # probe_done and go through the detached :probe_sc_start
        # helper, so a wedge can only delay the shutdown.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text.IndexOf('call :probe_sc_start AppXSVC appxsvc') | Should -BeGreaterThan $text.IndexOf('echo probe_done=1') -Because 'AppXSVC is started only after probe_done'
        $text.IndexOf('call :probe_sc_start StateRepository staterepo') | Should -BeGreaterThan $text.IndexOf('echo probe_done=1') -Because 'StateRepository is started only after probe_done'
        $text | Should -Not -Match 'sc start AppReadiness' -Because 'AppReadiness is only queried, not started'
        $text | Should -Not -Match 'appxsvc_start=' -Because 'the start outcome is recorded under appxsvc_after_start, not appxsvc_start'
        $text | Should -Not -Match 'staterepo_start=' -Because 'the start outcome is recorded under staterepo_after_start, not staterepo_start'
    }

    It 'counts the AUMID dump lines and checks the deployment server DLL' {
        # Run 47: aumid_*=0 with appxstore_*=1 — the package keys
        # exist, the !App subkeys do not resolve. The dump line count
        # says whether the enumeration itself was empty; the
        # AppXDeploymentServer.dll check closes the last gap in the
        # activation-files list (the client DLL alone is not the
        # whole activation path).
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'aumid_lines=' -Because 'the dump size is recorded'
        $text.IndexOf('aumid_lines=') | Should -BeLessThan $text.IndexOf('del "%SystemDrive%\micpe-aumid.tmp"') -Because 'the count is taken before the dump is deleted'
        $text | Should -Match 'activation_appxdeployserver=' -Because 'the deployment server DLL is recorded'
        $text.IndexOf('activation_appxdeployserver=') | Should -BeGreaterThan $text.IndexOf('activation_files=1') -Because 'the server check sits with the activation file checks'
        $text.IndexOf('activation_appxdeployserver=') | Should -BeLessThan $text.IndexOf('call :probe_uwp CalculatorApp') -Because 'the server check runs before the launches'
    }

    It 'dual-writes the service exit codes and adds the AppReadiness one' {
        # Run 47 proved a share-only key can go missing when the host
        # view stalls; the exit codes are verdict keys for the
        # activation chain, so they are dual-written now. AppReadiness
        # never had its exit code recorded before.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'echo appxsvc_exitcode=%APPXSVC_EXIT% >> "%PROBE_LOCAL%"' -Because 'the AppXSVC exit code survives a stalled share view'
        $text | Should -Match 'echo staterepo_exitcode=%STATEREPO_EXIT% >> "%PROBE_LOCAL%"' -Because 'the StateRepository exit code survives a stalled share view'
        $text | Should -Match 'sc queryex AppReadiness' -Because 'the AppReadiness exit code is read too'
        $text | Should -Match 'echo appready_exitcode=%APPREADY_EXIT% >> "%PROBE_LOCAL%"' -Because 'the AppReadiness exit code is dual-written like the others'
        $text.IndexOf('appready_exitcode=') | Should -BeGreaterThan $text.IndexOf('staterepo_exitcode=') -Because 'the AppReadiness read follows the StateRepository read'
    }
}

Describe 'probe.cmd run 49 BEX64 breakpoint control and minidump capture (run 49)' {
    BeforeAll {
        # Same subroutine extractor as the run 47/48 Describes: extract
        # by content (label to the next label), so the tests run
        # against the real code, not a hand copy that can drift.
        $script:ExtractProbeSub49 = {
            param([string] $Label, [string] $StopLabel)
            $lines = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
            $start = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match "^$Label") { $start = $i; break }
            }
            if ($start -lt 0) { throw "subroutine $Label not found in probe.cmd" }
            $end = $lines.Count - 1
            for ($i = $start + 1; $i -lt $lines.Count; $i++) {
                if ($StopLabel -and ($lines[$i] -match "^$StopLabel")) { $end = $i - 1; break }
            }
            return ,@($lines[$start..$end])
        }
    }

    It 'skips the folder-window creation this round (BEX64 breakpoint control)' {
        # Run 48 died at 14:27, one minute after the folder-window test
        # at 14:26:39, inside the same diag/uwp-opening window — the
        # creation itself is the prime suspect for the c0000409
        # failfast (CTray::Init, tray.cpp:595). If explorer still dies
        # in the same window without it, the trigger is shell
        # self-init; if it lives past diag, the trigger is the
        # creation. The flag defaults to 0 (skipped); set it to 1 to
        # restore the test. The tasklist snapshots stay: they say what
        # explorer loaded (or that it is already gone).
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'set "FOLDER_WINDOW_TEST=0"' -Because 'the control is off by default this round'
        $text | Should -Match 'if "%FOLDER_WINDOW_TEST%"=="1"' -Because 'the creation is conditional on the flag'
        $text | Should -Match 'echo folder_window_test=0' -Because 'the skipped run records 0, not 1'
        $text | Should -Match 'echo folder_window_skipped=1 >> "%PROBE_LOCAL%"' -Because 'the skip is dual-written like the other verdict keys'
        $text | Should -Match 'echo folder_window_skipped=1 >> "%PROBE_OUT%"' -Because 'the skip is recorded on the share file too'
        $flag = $text.IndexOf('set "FOLDER_WINDOW_TEST=0"')
        $flag | Should -BeGreaterThan -1
        $text.IndexOf('if "%FOLDER_WINDOW_TEST%"=="1"') | Should -BeGreaterThan $flag -Because 'the flag is set before it is read'
        $text.IndexOf('start "" explorer.exe "%SystemDrive%\"') | Should -BeGreaterThan $text.IndexOf('if "%FOLDER_WINDOW_TEST%"=="1"') -Because 'the creation sits inside the flag branch'
        $text.IndexOf('folder_window_test=1') | Should -BeGreaterThan $text.IndexOf('if "%FOLDER_WINDOW_TEST%"=="1"') -Because 'the 1 verdict is written only inside the flag branch'
        $text.IndexOf('folder_window_test=1') | Should -BeLessThan $text.IndexOf('mark_uwp_appx') -Because 'the test still runs in the diagnostics section, before the launches'
    }

    It 'reads the deployment services Start value straight from the registry' {
        # Run 48: sc queryex and sc qc print NOTHING in this PE, so
        # svc_*_start stayed missing — a probe limitation, not a
        # service fact. The Start DWORD is read from the service key
        # itself, with the same for /f tokens=3 shape run 42/43
        # already proved for Serial/Serenum. The sc qc reads stay:
        # on a fuller image they may print again, and the two sources
        # cross-check each other.
        $reg = & $script:ExtractProbeSub49 ':probe_svc_reg' $null
        $regBody = $reg -join "`n"
        $regBody | Should -Match 'reg query "HKLM\\SYSTEM\\CurrentControlSet\\Services\\%1" /v Start' -Because 'the Start value comes from the service key'
        $regBody | Should -Match 'svc_%2_regstart=' -Because 'the registry Start value is recorded under the service prefix'
        $regBody | Should -Match 'sc qc %1' -Because 'the sc qc reads stay for the cross-check'
        $regBody | Should -Match 'svc_%2_start=' -Because 'the sc qc Start type is still recorded too'
        $regBody | Should -Match 'SVC_REG_START_REG=missing' -Because 'a missing key leaves missing, like the other fields'
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        foreach ($svc in @('AppXSVC', 'StateRepository', 'AppReadiness')) {
            $text | Should -Match "call :probe_svc_reg $svc" -Because "the $svc Start value is read in the activation block"
        }
    }

    It 'copies every minidump to the share at each snapshot and at the end' {
        # Report.wer alone cannot locate the 0x1181ea call stack — only
        # a minidump can. WER LocalDumps (60-werdumps.reg, CI-time
        # import) writes explorer's dump to X:\CrashDumps; the queue
        # entry itself may also hold a .dmp/.hdmp. Each snapshot copies
        # what exists right then, so a wedge in a later section cannot
        # take the dump with it.
        $dump = & $script:ExtractProbeSub49 ':probe_dump_copy' ':probe_poll_check'
        $dumpBody = $dump -join "`n"
        $dumpBody | Should -Match 'micpe-minidump-%~1-' -Because 'the copy name carries the section suffix'
        $dumpBody | Should -Match 'WER\\ReportQueue' -Because 'the queue dumps are copied'
        $dumpBody | Should -Match '"%%D\\\*\.dmp"' -Because 'the queue .dmp files are copied'
        $dumpBody | Should -Match '"%%D\\\*\.hdmp"' -Because 'the queue .hdmp files are copied too'
        $dumpBody | Should -Match 'CrashDumps\\\*\.dmp' -Because 'the LocalDumps folder is copied'
        $dumpBody | Should -Match 'systemprofile\\AppData\\Local\\CrashDumps' -Because 'the system-profile dumps are copied'
        $dumpBody | Should -Match 'dump_%~1_wer_dmp=' -Because 'the queue dump presence is recorded with its suffix'
        $dumpBody | Should -Match 'dump_%~1_wer_dmp_copy=' -Because 'the queue copy landing is recorded with its suffix'
        $dumpBody | Should -Match 'dump_%~1_localdumps=' -Because 'the LocalDumps presence is recorded with its suffix'
        $dumpBody | Should -Match 'dump_%~1_localdumps_copy=' -Because 'the LocalDumps copy landing is recorded with its suffix'
        $dumpBody | Should -Match 'dump_%~1_profile=' -Because 'the system-profile dump presence is recorded with its suffix'
        $dumpBody | Should -Match 'dump_%~1_profile_copy=' -Because 'the system-profile copy landing is recorded with its suffix'
        $dumpBody | Should -Match 'copy /y "%%F" "%PROBE_DIR%micpe-minidump-%~1-%%~nxF"' -Because 'the copy is a whole-file copy under the crashing PID name'
        $dumpBody | Should -Match 'exit /b 0' -Because 'the subroutine returns cleanly'
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $calls = @([regex]::Matches($text, 'call :probe_dump_copy'))
        $calls.Count | Should -Be 2 -Because 'one call site inside :probe_wer_snapshot (runs at diag, uwp, xcheck) plus one at the end snapshot'
        $text | Should -Match 'call :probe_dump_copy end' -Because 'the end snapshot copies the dumps too'
        $snap = & $script:ExtractProbeSub49 ':probe_wer_snapshot' ':probe_poll_check'
        ($snap -join "`n") | Should -Match 'call :probe_dump_copy %~1' -Because 'each mid-run snapshot copies the dumps before returning'
    }

    It 're-scans the mirror late, at the end of the run' {
        # Run 48: mirror=0 was NOT a scan miss — the scan already
        # covered A: — the volume simply had not enumerated when the
        # probe started. The end-of-run re-scan catches a
        # late-enumerating volume; the mountvol dump goes into the
        # tasklist file for a human cross-check.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'mirror_late=' -Because 'the late mirror verdict is recorded'
        $text | Should -Match 'mirror_drive_late=' -Because 'the late mirror drive is recorded when one is found'
        $text | Should -Match 'drives_late=' -Because 'the late drive list is recorded'
        $text | Should -Match 'mountvol_end=1' -Because 'the end mountvol dump is recorded'
        $text | Should -Match '--- mountvol \(end\) ---' -Because 'the end mountvol dump is labelled in the tasklist file'
        $text | Should -Match 'for %%D in \(A B C D E F G H I J K L M N O P Q R S T U V W Y Z\)' -Because 'the late mirror scan covers A: (the run 47 miss)'
        $text.IndexOf('mirror_late=') | Should -BeGreaterThan $text.IndexOf('echo dump_memory=') -Because 'the late scan runs in the end snapshot'
        $text.IndexOf('mirror_late=') | Should -BeLessThan $text.IndexOf('echo probe_done=1') -Because 'the late scan runs before probe_done'
        $text.IndexOf('mountvol_end=1') | Should -BeGreaterThan $text.IndexOf('mirror_late=') -Because 'the mountvol dump follows the late scan'
    }

    It 'starts the AppX services only after probe_done (run 39 control lifted in run 51)' {
        # The run 39 control: the probe and the watchdog both stopped
        # within ~15 seconds of two sc start calls. The start attempt
        # is a separate experiment (after probe_done, where a wedge
        # costs nothing) — run 51 runs it, through the detached
        # :probe_sc_start helper.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text.IndexOf('call :probe_sc_start AppXSVC appxsvc') | Should -BeGreaterThan $text.IndexOf('echo probe_done=1') -Because 'AppXSVC is started only after probe_done'
        $text.IndexOf('call :probe_sc_start StateRepository staterepo') | Should -BeGreaterThan $text.IndexOf('echo probe_done=1') -Because 'StateRepository is started only after probe_done'
        $text | Should -Not -Match 'sc start AppReadiness' -Because 'AppReadiness is only queried, not started'
        $text | Should -Not -Match 'appxsvc_start=' -Because 'the start outcome is recorded under appxsvc_after_start, not appxsvc_start'
        $text | Should -Not -Match 'staterepo_start=' -Because 'the start outcome is recorded under staterepo_after_start, not staterepo_start'
    }
}

Describe 'probe.cmd run 50 feature 42537950 override read-back and explorer_end (run 50)' {
    It 'reads the feature 42537950 override back at runtime, flat and in the three groups' {
        # Run 50: the image's offline SYSTEM hive holds 330 Overrides
        # and none is 42537950, so the feature runs at its built-in
        # default (enabled) and CTray::Init failfasts. The CI build now
        # imports an override forcing it off; the probe reads it back
        # read-only so the stage can say whether the import landed.
        # The group checks say whether the feature also sits in a group
        # override (it does not in the image). Same for /f tokens=3
        # shape :probe_svc_reg already proved for service Start values.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'reg query "HKLM\\SYSTEM\\CurrentControlSet\\Control\\FeatureManagement\\Overrides\\42537950" /v EnabledState' -Because 'the flat override is read back'
        $text | Should -Match 'reg query "HKLM\\SYSTEM\\CurrentControlSet\\Control\\FeatureManagement\\Overrides\\0\\42537950" /v EnabledState' -Because 'group 0 is checked too'
        $text | Should -Match 'reg query "HKLM\\SYSTEM\\CurrentControlSet\\Control\\FeatureManagement\\Overrides\\15\\42537950" /v EnabledState' -Because 'group 15 is checked too'
        $text | Should -Match 'reg query "HKLM\\SYSTEM\\CurrentControlSet\\Control\\FeatureManagement\\Overrides\\9\\42537950" /v EnabledState' -Because 'group 9 is checked too'
        $text | Should -Match 'echo fm_42537950_state=%FM_STATE% >> "%PROBE_LOCAL%"' -Because 'the state is dual-written like the other verdict keys'
        $text | Should -Match 'echo fm_42537950_state=%FM_STATE% >> "%PROBE_OUT%"' -Because 'the state is recorded on the share file too'
        $text | Should -Match 'echo fm_42537950_group0=%FM_G0%' -Because 'the group 0 check is recorded'
        $text | Should -Match 'echo fm_42537950_group15=%FM_G15%' -Because 'the group 15 check is recorded'
        $text | Should -Match 'echo fm_42537950_group9=%FM_G9%' -Because 'the group 9 check is recorded'
        $text | Should -Match 'set "FM_STATE=missing"' -Because 'a missing key leaves missing, like the other fields'
        $text.IndexOf('echo fm_42537950_state=') | Should -BeGreaterThan $text.IndexOf('mark_uwp_svc') -Because 'the read-back runs in the diagnostics section'
        $text.IndexOf('echo fm_42537950_state=') | Should -BeLessThan $text.IndexOf('mark_uwp_launch_calculator') -Because 'the read-back runs before the UWP launches'
    }

    It 'reads the boot control set selection, the ControlSet001 override, the temp-control config and the raw options back (run 54)' {
        # Run 54 read-path close-out (eval card §40.1): the evaluation
        # goes through the OS feature-staging API on CurrentControlSet,
        # so the probe also reads HKLM\SYSTEM\Select (which control set
        # is Current), the same override under ControlSet001 directly,
        # the active EnterpriseTempControls config, and the raw
        # EnabledStateOptions — read-only, no new mark_ marker.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'reg query "HKLM\\SYSTEM\\Select" /v Current' -Because 'Current says which control set CurrentControlSet is'
        $text | Should -Match 'reg query "HKLM\\SYSTEM\\Select" /v Default' -Because 'Default is part of the boot selection'
        $text | Should -Match 'reg query "HKLM\\SYSTEM\\Select" /v Failed' -Because 'Failed is part of the boot selection'
        $text | Should -Match 'reg query "HKLM\\SYSTEM\\Select" /v LastKnownGood' -Because 'LastKnownGood is part of the boot selection'
        $text | Should -Match 'reg query "HKLM\\SYSTEM\\ControlSet001\\Control\\FeatureManagement\\Overrides\\0\\42537950" /v EnabledState' -Because 'ControlSet001 is read back directly'
        $text | Should -Match 'reg query "HKLM\\SYSTEM\\CurrentControlSet\\Control\\FeatureManagement\\EnterpriseTempControls\\Active" /v ActiveConfig' -Because 'the active temp-control config is read back'
        $text | Should -Match 'reg query "HKLM\\SYSTEM\\CurrentControlSet\\Control\\FeatureManagement\\Overrides\\0\\42537950" /v EnabledStateOptions' -Because 'the raw options value is read back'
        $text | Should -Match 'echo fm_select_current=%FM_SEL_CURRENT%' -Because 'the Current value is recorded'
        $text | Should -Match 'echo fm_select_lastknowngood=%FM_SEL_LKG%' -Because 'the LastKnownGood value is recorded'
        $text | Should -Match 'echo fm_42537950_cs001_group0=%FM_CS001_G0%' -Because 'the ControlSet001 read-back is recorded'
        $text | Should -Match 'echo fm_etc_activeconfig=%FM_ETC_ACTIVE%' -Because 'the active config is recorded'
        $text | Should -Match 'echo fm_42537950_group0_options=%FM_G0_OPT%' -Because 'the raw options value is recorded'
        # Run 56 (eval card §42): ntdll reads EnterpriseTempControls
        # directly (its .rdata holds the Active path but no Overrides
        # path — the Overrides are consumed by the kernel), so the
        # probe also reads the feature's entry in the active temp
        # config (expect missing: the stock active config is empty)
        # and FconPresent. Both are read-only diagnostics.
        $text | Should -Match 'reg query "HKLM\\SYSTEM\\CurrentControlSet\\Control\\FeatureManagement\\EnterpriseTempControls\\2208259724" /v 42537950' -Because 'the feature entry in the active temp config is read back'
        $text | Should -Match 'reg query "HKLM\\SYSTEM\\CurrentControlSet\\Control\\FeatureManagement" /v FconPresent' -Because 'FconPresent is read back'
        $text | Should -Match 'echo fm_etc_feature=%FM_ETC_FEATURE%' -Because 'the temp-config read-back is recorded'
        $text | Should -Match 'echo fm_fconpresent=%FM_FCON%' -Because 'FconPresent is recorded'
        $text.IndexOf('echo fm_etc_feature=') | Should -BeGreaterThan $text.IndexOf('echo fm_42537950_group0_options=') -Because 'the temp-config diagnostics follow the group read-backs'
        $text.IndexOf('echo fm_fconpresent=') | Should -BeLessThan $text.IndexOf('echo wer_localdumps_folder=') -Because 'the diagnostics run before the WER section'
        $text.IndexOf('echo fm_select_current=') | Should -BeGreaterThan $text.IndexOf('echo fm_42537950_group9=') -Because 'the diagnostics follow the group read-backs'
        $text.IndexOf('echo fm_42537950_group0_options=') | Should -BeLessThan $text.IndexOf('echo wer_localdumps_folder=') -Because 'the diagnostics run before the WER section'
    }

    It 'writes the sc start experiment completion marker before the fifth sync (run 54)' {
        # Run 53: the host ended the verification the moment it saw
        # probe_done, killing QEMU before the experiment finished, so
        # no scstart_* or aumid_after_* key ever came back. The
        # experiment now writes scstart_done=1 when it finishes; the
        # host waits for it (bounded) before ending the run. The
        # marker goes to the local file only, like the other
        # experiment keys, and the fifth sync carries it to the share.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'echo scstart_done=1 >> \"%PROBE_LOCAL%\"' -Because 'the experiment writes its own completion marker'
        $text.IndexOf('echo scstart_done=1') | Should -BeGreaterThan $text.IndexOf('echo probe_done=1') -Because 'the experiment runs after probe_done'
        $text.IndexOf('echo scstart_done=1') | Should -BeGreaterThan $text.IndexOf('aumid_after_lines=') -Because 'the marker is written after the AUMID re-dump'
        $text.IndexOf('echo scstart_done=1') | Should -BeLessThan $text.LastIndexOf('call :probe_sync_local') -Because 'the fifth sync carries the marker to the share'
    }

    It 'reads the WER LocalDumps key, the RpcSs state and the appmodel group back (run 50 diagnostics)' {
        # Run 50 correction: 60-werdumps.reg addressed HKLM\SOFTWARE,
        # which a plain reg.exe import writes into the runner's live
        # hive — run 49's image never got the LocalDumps key. The file
        # now addresses PE-SOFT; the probe reads the key back to prove
        # it landed. StateRepository's only dependency is RpcSs and its
        # appmodel svchost group is defined in the image, so the probe
        # records RpcSs's own state and the group definition in the
        # running image. Reads only in this section — the sc start
        # experiment runs after probe_done (eval card §34.7, run 51).
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'reg query "HKLM\\SOFTWARE\\Microsoft\\Windows\\Windows Error Reporting\\LocalDumps\\explorer\.exe" /v DumpFolder' -Because 'the LocalDumps key is read back from the running image'
        $text | Should -Match 'echo wer_localdumps_folder=%WER_DUMPS%' -Because 'the LocalDumps read-back is recorded'
        $text | Should -Match 'call :probe_svc RpcSs rpcss' -Because 'RpcSs state is recorded (StateRepository depends only on it)'
        $text | Should -Match 'reg query "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Svchost" /v appmodel' -Because 'the appmodel group definition is checked in the running image'
        $text | Should -Match 'echo svchost_appmodel=' -Because 'the appmodel group presence is recorded'
        $text.IndexOf('call :probe_sc_start RpcSs rpcss') | Should -BeGreaterThan $text.IndexOf('echo probe_done=1') -Because 'RpcSs is started only after probe_done, never in the diagnostics section'
        $text | Should -Not -Match 'reg add' -Because 'the diagnostics are read-only'
        $text | Should -Not -Match 'reg import' -Because 'the diagnostics are read-only'
    }

    It 'records explorer alive at probe end (explorer_end)' {
        # Run 50: the old explorer=1 is set while explorer is still
        # starting, so it cannot prove the feature fix worked. The end
        # snapshot now records whether explorer is still alive, with
        # the same tasklist /fi shape as werfault_end/dwm_end, and the
        # m5 stage asserts explorer_end=1.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'echo explorer_end=1 >> "%PROBE_LOCAL%"' -Because 'the alive verdict is dual-written'
        $text | Should -Match 'echo explorer_end=1 >> "%PROBE_OUT%"' -Because 'the alive verdict is recorded on the share file too'
        $text | Should -Match 'echo explorer_end=0 >> "%PROBE_LOCAL%"' -Because 'the dead verdict is dual-written too'
        $text.IndexOf('echo explorer_end=') | Should -BeGreaterThan $text.IndexOf('echo dwm_end=') -Because 'explorer_end follows dwm_end in the end snapshot'
        $text.IndexOf('echo explorer_end=') | Should -BeLessThan $text.IndexOf('echo probe_done=1') -Because 'explorer_end is written before probe_done'
    }
}

Describe 'probe.cmd run 51 grouped feature override and service start experiment (run 51)' {
    It 'starts the services detached with a bounded wait and records the after-states' {
        # Run 51: RpcSs is StateRepository's only dependency and it is
        # STOPPED in PE (run 50). The experiment starts RpcSs, then
        # StateRepository, then AppXSVC — but only after probe_done is
        # already in the LOCAL file (§34.7), where a wedge costs a
        # delayed shutdown, not a lost conclusion. Each start runs
        # detached through :probe_sc_start (run 39: two start calls
        # stalled probe + watchdog within ~15s), and the after-state
        # is read back with :probe_svc right after each start.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'call :probe_sc_start RpcSs rpcss' -Because 'RpcSs is started through the helper'
        $text | Should -Match 'call :probe_sc_start StateRepository staterepo' -Because 'StateRepository is started through the helper'
        $text | Should -Match 'call :probe_sc_start AppXSVC appxsvc' -Because 'AppXSVC is started through the helper'
        $text | Should -Match 'call :probe_svc RpcSs rpcss_after_start' -Because 'the RpcSs state after the start is recorded'
        $text | Should -Match 'call :probe_svc StateRepository staterepo_after_rpcss' -Because 'whether StateRepository followed RpcSs is recorded'
        $text | Should -Match 'call :probe_svc StateRepository staterepo_after_start' -Because 'the StateRepository state after its own start is recorded'
        $text | Should -Match 'call :probe_svc AppXSVC appxsvc_after_start' -Because 'the AppXSVC state after the start is recorded'
        $text.IndexOf('call :probe_sc_start RpcSs rpcss') | Should -BeLessThan $text.IndexOf('call :probe_sc_start StateRepository staterepo') -Because 'RpcSs is started before StateRepository'
        $text.IndexOf('call :probe_sc_start StateRepository staterepo') | Should -BeLessThan $text.IndexOf('call :probe_sc_start AppXSVC appxsvc') -Because 'StateRepository is started before AppXSVC'
        $text.IndexOf('call :probe_svc RpcSs rpcss_after_start') | Should -BeGreaterThan $text.IndexOf('call :probe_sc_start RpcSs rpcss') -Because 'the after-state is read after the start call'
    }

    It 'runs each start detached with a bounded wait and a DONE sentinel (:probe_sc_start)' {
        # The parent never blocks on the start command: the child runs
        # detached, writes its output to a temp file plus DONE, and the
        # parent waits for DONE with a bounded spin and 15 one-second
        # ticks, then taskkills a hung start. Same shape as the
        # :probe_poll_check detachment (run 47).
        # Run 56: the spin was 20000 bare iterations with no time bound
        # and no progress key — on a slow PE the spin alone could
        # outrun the host's 120-second wait, so no scstart_* key ever
        # came back (run 55, twice). The spin is now a short fast path
        # (200 iterations, then the timed wait takes over), and the
        # experiment writes a started key before the child is launched.
        $helper = & $script:ExtractProbeSub ':probe_sc_start' ':probe_poll_check'
        ($helper -join "`n") | Should -Match 'start "" /min cmd /c sc start %~1' -Because 'the start runs in a detached child cmd'
        ($helper -join "`n") | Should -Match 'echo DONE' -Because 'the child writes a DONE sentinel'
        ($helper -join "`n") | Should -Match 'find /i "DONE"' -Because 'the parent waits for the sentinel, not merely a non-empty file'
        ($helper -join "`n") | Should -Match 'if %SC_WAIT% geq 15 goto sc_start_timeout' -Because 'the wait is bounded at 15 seconds'
        ($helper -join "`n") | Should -Match 'taskkill /f /im sc\.exe' -Because 'a hung start is taskkilled'
        ($helper -join "`n") | Should -Match 'echo scstart_%~2_done=1' -Because 'a finished start is recorded'
        ($helper -join "`n") | Should -Match 'echo scstart_%~2_timeout=1' -Because 'a timed-out start is recorded'
        ($helper -join "`n") | Should -Match 'echo scstart_%~2_started=1' -Because 'the experiment writes a progress key before the child is launched'
        ($helper -join "`n") | Should -Match 'if %SC_SPIN% lss 200 goto sc_start_spin' -Because 'the spin is a short fast path, not an unbounded loop'
        ($helper -join "`n") | Should -Not -Match 'if %SC_SPIN% lss 20000' -Because 'the 20000-iteration spin is gone'
        ($helper -join "`n").IndexOf('echo scstart_%~2_started=1') | Should -BeLessThan ($helper -join "`n").IndexOf('start "" /min cmd /c sc start') -Because 'the started key is written before the child is launched'
    }

    It 're-dumps the AUMID store after the starts and syncs the local file once more' {
        # If StateRepository came up, the !App subkeys may resolve now
        # — the cross-check dump runs again with _after keys. Dump to
        # a file and search the file (never a pipe: CI run 44519361912).
        # The experiment keys are written after the detached end copy
        # fired, so the local file is synced once more (fifth sync).
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'micpe-aumid-after\.tmp' -Because 'the re-dump uses its own temp file'
        $text | Should -Match 'echo aumid_after_calc=' -Because 'the Calculator AUMID is re-checked'
        $text | Should -Match 'echo aumid_after_photos=' -Because 'the Photos AUMID is re-checked'
        $text | Should -Match 'echo aumid_after_media=' -Because 'the Media AUMID is re-checked'
        $text | Should -Match 'echo aumid_after_lines=' -Because 'the re-dump line count is recorded'
        $text.IndexOf('echo aumid_after_calc=') | Should -BeGreaterThan $text.IndexOf('call :probe_sc_start AppXSVC appxsvc') -Because 'the re-dump runs after the starts'
        $text.IndexOf('call :probe_sync_local', $text.IndexOf('echo aumid_after_lines=')) | Should -BeGreaterThan $text.IndexOf('echo aumid_after_lines=') -Because 'the fifth sync follows the re-dump'
    }
}
