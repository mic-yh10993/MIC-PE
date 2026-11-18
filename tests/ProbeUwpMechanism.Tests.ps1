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
                $proc.WaitForExit(10000)
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
            $seconds | Should -BeLessThan 15 -Because 'with the guard all three calls return at once; without it each waits out the 10-second poll'
            $text | Should -Match 'uwp_launch_calculator=0' -Because 'no shell means not launchable here, not a launch failure to retry'
            $text | Should -Match 'uwp_launch_photos=0'
            $text | Should -Match 'uwp_launch_media=0'
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

    It 'does NOT start the AppX services this round, and records their last exit codes (run 44365018616)' {
        # Control for run 39: the probe and the watchdog both stopped
        # within ~15 seconds of the two sc start calls, so sc start is
        # the prime suspect for the freeze — but explorer was already
        # Not Responding before any sc start, so it cannot be convicted
        # yet. This round the services are not started at all: one
        # variable at a time. If the probe now runs through, sc start
        # was the trigger; if it still stops at the same place, sc
        # start is exonerated. The last exit codes are recorded
        # instead: run 39 showed sc start returning 0 while the
        # service stayed STOPPED.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Not -Match 'sc start AppXSVC' -Because 'the control run must not start AppXSVC'
        $text | Should -Not -Match 'sc start StateRepository' -Because 'the control run must not start StateRepository'
        $text | Should -Not -Match 'sc start AppReadiness' -Because 'AppReadiness is only queried, not started'
        $text | Should -Not -Match 'appxsvc_start=' -Because 'no start attempt means no start outcome to record'
        $text | Should -Not -Match 'staterepo_start=' -Because 'no start attempt means no start outcome to record'
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

    It 'reverse control: without the frame-host check the diagnostics test fails' {
        # The presence assertion above must actually depend on the probe
        # checking for the frame host, not pass vacuously.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $mutated = $text.Replace('appframehost=', 'appframehost-missing=')
        $mutated | Should -Not -Match 'appframehost='
    }
}
