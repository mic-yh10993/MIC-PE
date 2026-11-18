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
    $script:PingExe = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\ping.exe' } else { 'ping.exe' }

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
        Copy-Item -LiteralPath $script:PingExe -Destination (Join-Path $workDir 'ping.exe')
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
        $tail | Should -Match 'ping -n 2 127\.0\.0\.1' -Because 'each poll step waits about one second'
        $tail | Should -Match 'set /a UWP_WAIT\+=1' -Because 'the poll counts its steps'
        $tail | Should -Match 'if %UWP_WAIT% lss 10 goto :probe_uwp_poll' -Because 'the poll gives up after ten steps instead of hanging'
        $tail | Should -Not -Match 'ping -n 8 127\.0\.0\.1' -Because 'the old fixed 7-second sleep is gone'
    }
}
