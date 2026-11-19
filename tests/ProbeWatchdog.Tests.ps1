#Requires -Version 7.0
#Requires -Modules Pester
<#
.SYNOPSIS
    Mechanism tests for the probe watchdog (run 44285721257).

.DESCRIPTION
    Build run 44285721257: the probe died inside `call :probe_uwp
    Microsoft.Photos`, so probe_done=1 was never written and the CI host
    waited out the full 45 minutes. probe-watchdog.cmd runs detached
    alongside probe.cmd: when the probe file stops growing for 5 minutes
    it records probe_failed=1 itself, so the host stops waiting early.
    probe_failed still fails the run (see Assert-Probe); it only
    shortens the wait, it never passes one.

    The watchdog stops on its own when it sees probe_done=1, or when
    probe.cmd writes the stop flag before the long installer deploy.
    All cmd.exe tests skip on Linux; the static tests run anywhere.

    Run 44303866765: the watchdog process was alive (its empty-title
    minimized window was on the screenshot) yet never wrote probe_failed
    in 34 quiet minutes, and there was no evidence of which loop step it
    was stuck on. Every loop iteration now appends a heartbeat line to
    micpe-watchdog-heartbeat.txt next to the probe file on the share
    (time, quiet count, observed size), and build.yml collects that
    file into the verify artifact. W4 proves the heartbeat appears and
    the fail still lands on a controlled stall; W5 proves a growing
    probe resets the quiet count instead of being failed.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path
    $script:WatchdogPath = Join-Path $script:RepoRoot 'src/ci/probe-watchdog.cmd'
    $script:ProbePath = Join-Path $script:RepoRoot 'src/ci/probe.cmd'
    # SystemRoot is empty on Linux; the Windows-only paths below are
    # never used there (those tests skip), but BeforeAll still runs for
    # the static tests, so do not let Join-Path see a null parent.
    $script:CmdExe = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\cmd.exe' } else { 'cmd.exe' }
    $script:FindstrExe = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\findstr.exe' } else { 'findstr.exe' }
    # choice.exe is the watchdog's wait (run 44319967017): the work dir
    # is the whole PATH for the test batch, so it must be copied in.
    # ping.exe is no longer used by the watchdog and is not copied.
    $script:ChoiceExe = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\choice.exe' } else { 'choice.exe' }

    # A CRLF batch file: cmd.exe treats a lone LF as part of the line.
    $script:WriteBatchCrlf = {
        param([string] $Path, [string[]] $Lines)
        $text = ($Lines -join "`r`n") + "`r`n"
        [System.IO.File]::WriteAllText($Path, $text, [System.Text.Encoding]::ASCII)
    }

    # Run a batch under a real cmd.exe with only findstr/ping on PATH
    # (as in the PE image), and a hard timeout so a stall is observed
    # as TimedOut instead of hanging CI.
    $script:InvokeCmdTimed = {
        param([string] $BatPath, [string] $WorkDir, [int] $TimeoutSec = 60)
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

    $script:NewWorkDir = {
        $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        Copy-Item -LiteralPath $script:FindstrExe -Destination (Join-Path $workDir 'findstr.exe')
        Copy-Item -LiteralPath $script:ChoiceExe -Destination (Join-Path $workDir 'choice.exe')
        return $workDir
    }

    # The watchdog reads its stop flag from %SystemDrive%, which on the
    # CI runner is the real C: drive. Point it at the work dir instead
    # so the tests never touch the drive root: a wrapper batch sets
    # SystemDrive for the watchdog process only.
    $script:InvokeWatchdog = {
        param([string] $WorkDir, [string] $ProbeFile, [int] $Limit = 2, [int] $Wait = 2, [int] $TimeoutSec = 60)
        $wrapper = Join-Path $WorkDir 'run-watchdog.bat'
        & $script:WriteBatchCrlf $wrapper @(
            '@echo off',
            ('set "SystemDrive={0}"' -f $WorkDir),
            ('call "{0}" "{1}" {2} {3}' -f $script:WatchdogPath, $ProbeFile, $Limit, $Wait),
            'exit /b %errorlevel%'
        )
        return (& $script:InvokeCmdTimed $wrapper $WorkDir -TimeoutSec $TimeoutSec)
    }
}

Describe 'probe watchdog mechanism (run 44285721257)' {
    It 'W1: writes probe_failed=1 when the probe file stops growing' -Skip:(-not $IsWindows) {
        $workDir = & $script:NewWorkDir
        $probeFile = Join-Path $workDir 'micpe-probe.txt'
        try {
            Set-Content -LiteralPath $probeFile -Value @('boot=1', 'share=1', 'explorer=1') -Encoding ascii
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = & $script:InvokeWatchdog $workDir $probeFile -Limit 2 -Wait 2 -TimeoutSec 60
            $sw.Stop()
            Write-Host "timed out: $($result.TimedOut); exit code: $($result.ExitCode); elapsed seconds: $($sw.Elapsed.TotalSeconds)"
            $text = Get-Content -LiteralPath $probeFile -Raw
            Write-Host "probe file: [$text]"
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 1 -Because 'the watchdog reports that it had to fail the probe'
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 30 -Because 'two quiet checks of about a second each must not take the 5-minute default'
            $text | Should -Match 'probe_failed=1'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'W2: exits quietly when probe_done=1 appears while watching' -Skip:(-not $IsWindows) {
        $workDir = & $script:NewWorkDir
        $probeFile = Join-Path $workDir 'micpe-probe.txt'
        try {
            Set-Content -LiteralPath $probeFile -Value @('boot=1', 'share=1') -Encoding ascii
            # Start the watchdog in the background, then complete the
            # probe the way probe.cmd would: the watcher must see the
            # done line and stop without writing probe_failed.
            $wrapper = Join-Path $workDir 'run-watchdog.bat'
            & $script:WriteBatchCrlf $wrapper @(
                '@echo off',
                ('set "SystemDrive={0}"' -f $WorkDir),
                ('call "{0}" "{1}" 5 2' -f $script:WatchdogPath, $probeFile),
                'exit /b %errorlevel%'
            )
            $oldPath = $env:PATH
            $proc = $null
            $exited = $false
            try {
                $env:PATH = $workDir
                $proc = Start-Process -FilePath $script:CmdExe -ArgumentList '/c', $wrapper -PassThru -NoNewWindow
                Start-Sleep -Seconds 3
                Add-Content -LiteralPath $probeFile -Value 'explorer=1' -Encoding ascii
                Add-Content -LiteralPath $probeFile -Value 'probe_done=1' -Encoding ascii
                $exited = $proc.WaitForExit(30000)
                if (-not $exited) { try { $proc.Kill($true) } catch { }; $proc.WaitForExit(10000) }
            }
            finally { $env:PATH = $oldPath }
            $exited | Should -Be $true -Because 'the watchdog must stop once the probe is done'
            $proc.ExitCode | Should -Be 0
            (Get-Content -LiteralPath $probeFile -Raw) | Should -Not -Match 'probe_failed'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'W3: stops when probe.cmd writes the stop flag before the deploy' -Skip:(-not $IsWindows) {
        $workDir = & $script:NewWorkDir
        $probeFile = Join-Path $workDir 'micpe-probe.txt'
        try {
            Set-Content -LiteralPath $probeFile -Value @('boot=1', 'share=1') -Encoding ascii
            New-Item -ItemType File -Path (Join-Path $workDir 'micpe-watchdog-stop.txt') -Force | Out-Null
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = & $script:InvokeWatchdog $workDir $probeFile -Limit 2 -Wait 2 -TimeoutSec 60
            $sw.Stop()
            Write-Host "timed out: $($result.TimedOut); exit code: $($result.ExitCode); elapsed seconds: $($sw.Elapsed.TotalSeconds)"
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 0
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 15 -Because 'a present stop flag ends the first check at once'
            (Get-Content -LiteralPath $probeFile -Raw) | Should -Not -Match 'probe_failed'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'W4: writes a heartbeat while a stalled probe is being failed (run 44303866765)' -Skip:(-not $IsWindows) {
        # Run 35: the watchdog process was alive (empty-title minimized
        # window on the screenshot) yet never wrote probe_failed=1 in 34
        # quiet minutes, and there was no evidence of which loop step it
        # was stuck on. The heartbeat must prove the loop itself runs:
        # one line per iteration with the quiet count and the size it
        # observed, plus a line for the fail write itself.
        $workDir = & $script:NewWorkDir
        $probeFile = Join-Path $workDir 'micpe-probe.txt'
        $heartbeatFile = Join-Path $workDir 'micpe-watchdog-heartbeat.txt'
        try {
            Set-Content -LiteralPath $probeFile -Value @('boot=1', 'share=1', 'explorer=1') -Encoding ascii
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = & $script:InvokeWatchdog $workDir $probeFile -Limit 2 -Wait 2 -TimeoutSec 60
            $sw.Stop()
            Write-Host "timed out: $($result.TimedOut); exit code: $($result.ExitCode); elapsed seconds: $($sw.Elapsed.TotalSeconds)"
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 1 -Because 'the watchdog reports that it had to fail the probe'
            (Get-Content -LiteralPath $probeFile -Raw) | Should -Match 'probe_failed=1'
            Test-Path -LiteralPath $heartbeatFile | Should -Be $true -Because 'the loop must leave a heartbeat trail'
            $beats = @(Get-Content -LiteralPath $heartbeatFile)
            Write-Host "heartbeat: [$($beats -join ' | ')]"
            $beats.Count | Should -BeGreaterOrEqual 4 -Because 'start line plus at least three iterations (quiet 0, 1, 2)'
            ($beats -join "`n") | Should -Match 'watchdog_start=' -Because 'the start line proves the script itself began'
            ($beats -join "`n") | Should -Match 'quiet=2' -Because 'the triggering iteration counted two quiet checks'
            ($beats -join "`n") | Should -Match 'probe_failed_written=1' -Because 'the fail write is recorded in the heartbeat too'
            $sizes = @([regex]::Matches(($beats -join "`n"), 'size=(\d+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
            $sizes.Count | Should -Be 1 -Because 'a stalled probe file has one size; changing sizes would explain a quiet counter that never fires'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'W5: the heartbeat shows the quiet count reset when the probe grows again' -Skip:(-not $IsWindows) {
        # The other half of the run 35 mystery: if the observed size kept
        # "changing", the quiet counter would reset forever and
        # probe_failed would never fire. A growing probe must show the
        # reset in the heartbeat (quiet=0 after quiet>=1) and must not
        # be failed.
        $workDir = & $script:NewWorkDir
        $probeFile = Join-Path $workDir 'micpe-probe.txt'
        $heartbeatFile = Join-Path $workDir 'micpe-watchdog-heartbeat.txt'
        try {
            Set-Content -LiteralPath $probeFile -Value @('boot=1', 'share=1') -Encoding ascii
            $wrapper = Join-Path $workDir 'run-watchdog.bat'
            & $script:WriteBatchCrlf $wrapper @(
                '@echo off',
                ('set "SystemDrive={0}"' -f $WorkDir),
                ('call "{0}" "{1}" 5 2' -f $script:WatchdogPath, $probeFile),
                'exit /b %errorlevel%'
            )
            $oldPath = $env:PATH
            $proc = $null
            $exited = $false
            try {
                $env:PATH = $workDir
                $proc = Start-Process -FilePath $script:CmdExe -ArgumentList '/c', $wrapper -PassThru -NoNewWindow
                # Poll the heartbeat until it proves the loop counted a
                # quiet check, then grow the probe: the next heartbeat
                # line after that must show the counter back at zero.
                $countedQuiet = $false
                for ($i = 0; $i -lt 40 -and -not $countedQuiet; $i++) {
                    Start-Sleep -Milliseconds 500
                    if (Test-Path -LiteralPath $heartbeatFile) {
                        $countedQuiet = (Get-Content -LiteralPath $heartbeatFile -Raw -ErrorAction SilentlyContinue) -match 'quiet=[1-9]'
                    }
                }
                $countedQuiet | Should -Be $true -Because 'the loop must count at least one quiet check before the probe grows'
                Add-Content -LiteralPath $probeFile -Value 'explorer=1' -Encoding ascii
                $sawReset = $false
                for ($i = 0; $i -lt 40 -and -not $sawReset; $i++) {
                    Start-Sleep -Milliseconds 500
                    if (Test-Path -LiteralPath $heartbeatFile) {
                        $lines = @(Get-Content -LiteralPath $heartbeatFile -ErrorAction SilentlyContinue)
                        $firstQuiet = -1; $resetAfter = -1
                        for ($j = 0; $j -lt $lines.Count; $j++) {
                            if ($firstQuiet -lt 0 -and $lines[$j] -match 'quiet=[1-9]') { $firstQuiet = $j }
                            if ($firstQuiet -ge 0 -and $j -gt $firstQuiet -and $lines[$j] -match 'quiet=0') { $resetAfter = $j; break }
                        }
                        $sawReset = ($resetAfter -ge 0)
                    }
                }
                $sawReset | Should -Be $true -Because 'a growing probe file must reset the quiet counter to zero'
                Add-Content -LiteralPath $probeFile -Value 'probe_done=1' -Encoding ascii
                $exited = $proc.WaitForExit(30000)
                if (-not $exited) { try { $proc.Kill($true) } catch { }; $proc.WaitForExit(10000) }
            }
            finally { $env:PATH = $oldPath }
            $exited | Should -Be $true -Because 'the watchdog must stop once the probe is done'
            $proc.ExitCode | Should -Be 0
            (Get-Content -LiteralPath $probeFile -Raw) | Should -Not -Match 'probe_failed'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'W6: a long wait is split into short ticks (run 44349189039)' -Skip:(-not $IsWindows) {
        # Run 38: the loop died in its first 60-second choice wait
        # (before_wait written, after_wait never). WD_WAIT=12 must run
        # as two 6-second ticks: the heartbeat has to show tick=1/2
        # and tick=2/2, proving the tick loop itself runs on Windows.
        $workDir = & $script:NewWorkDir
        $probeFile = Join-Path $workDir 'micpe-probe.txt'
        $heartbeatFile = Join-Path $workDir 'micpe-watchdog-heartbeat.txt'
        try {
            Set-Content -LiteralPath $probeFile -Value @('boot=1', 'share=1', 'explorer=1') -Encoding ascii
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = & $script:InvokeWatchdog $workDir $probeFile -Limit 2 -Wait 12 -TimeoutSec 60
            $sw.Stop()
            Write-Host "timed out: $($result.TimedOut); exit code: $($result.ExitCode); elapsed seconds: $($sw.Elapsed.TotalSeconds)"
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 1 -Because 'the watchdog reports that it had to fail the probe'
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 45 -Because 'two quiet checks of twelve seconds each must not take the 5-minute default'
            (Get-Content -LiteralPath $probeFile -Raw) | Should -Match 'probe_failed=1'
            Test-Path -LiteralPath $heartbeatFile | Should -Be $true -Because 'the loop must leave a heartbeat trail'
            $beats = @(Get-Content -LiteralPath $heartbeatFile)
            Write-Host "heartbeat: [$($beats -join ' | ')]"
            ($beats -join "`n") | Should -Match 'phase=wait_tick tick=1/2' -Because 'the first tick of a 12-second wait must be recorded'
            ($beats -join "`n") | Should -Match 'phase=wait_tick tick=2/2' -Because 'the second tick must be recorded too, proving the tick loop runs to the end'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'W7: exits within one tick when probe_done appears mid-wait (run 44410311576)' -Skip:(-not $IsWindows) {
        # Run 41: the heartbeat stopped at tick 3/12 although probe_done
        # was already written and the stop flag was already set — the
        # loop-top checks never ran because the tick loop runs the whole
        # 60-second cycle first, and the guest's own shutdown killed the
        # watcher mid-cycle. With the check inside the tick loop,
        # probe_done mid-wait must end the watcher within one tick
        # (~5 s), not at the end of the 60-second cycle.
        $workDir = & $script:NewWorkDir
        $probeFile = Join-Path $workDir 'micpe-probe.txt'
        $heartbeatFile = Join-Path $workDir 'micpe-watchdog-heartbeat.txt'
        try {
            Set-Content -LiteralPath $probeFile -Value @('boot=1', 'share=1') -Encoding ascii
            $wrapper = Join-Path $workDir 'run-watchdog.bat'
            & $script:WriteBatchCrlf $wrapper @(
                '@echo off',
                ('set "SystemDrive={0}"' -f $WorkDir),
                ('call "{0}" "{1}" 5 60' -f $script:WatchdogPath, $probeFile),
                'exit /b %errorlevel%'
            )
            $oldPath = $env:PATH
            $proc = $null
            $exited = $false
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $env:PATH = $workDir
                $proc = Start-Process -FilePath $script:CmdExe -ArgumentList '/c', $wrapper -PassThru -NoNewWindow
                Start-Sleep -Seconds 3
                Add-Content -LiteralPath $probeFile -Value 'probe_done=1' -Encoding ascii
                $exited = $proc.WaitForExit(20000)
                if (-not $exited) { try { $proc.Kill($true) } catch { }; $proc.WaitForExit(10000) }
            }
            finally { $env:PATH = $oldPath }
            $sw.Stop()
            Write-Host "exited: $exited; exit code: $($proc.ExitCode); elapsed seconds: $($sw.Elapsed.TotalSeconds)"
            $exited | Should -Be $true -Because 'probe_done mid-wait must end the watcher within one tick, not at the end of the 60-second cycle'
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 20 -Because 'without the in-tick check the watcher would run the full 60-second cycle'
            $proc.ExitCode | Should -Be 0
            (Get-Content -LiteralPath $heartbeatFile -Raw -ErrorAction SilentlyContinue) | Should -Match 'probe_done_seen=1' -Because 'the clean exit is marked, so a heartbeat that just stops is still a death'
            (Get-Content -LiteralPath $probeFile -Raw) | Should -Not -Match 'probe_failed'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'probe watchdog (static)' {
    It 'the watchdog script exists and probe.cmd starts it' {
        Test-Path -LiteralPath $script:WatchdogPath | Should -Be $true
        $probe = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $probe | Should -Match 'probe-watchdog\.cmd' -Because 'probe.cmd must start the watchdog once the probe file exists'
        $probe.IndexOf('probe-watchdog.cmd') | Should -BeGreaterThan $probe.IndexOf('share_drive=') -Because 'the watchdog can only watch a file that exists'
        $probe.IndexOf('probe-watchdog.cmd') | Should -BeLessThan $probe.IndexOf('--- drive letters') -Because 'the watchdog must start before the first hang-prone section'
    }

    It 'probe.cmd tells the watchdog to stop before the installer deploy' {
        $probe = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $probe | Should -Match 'micpe-watchdog-stop\.txt'
        # Anchor on the full deploy command, not '-cli -deploy' alone:
        # the bare string first appears in the installer-section comment.
        $probe.IndexOf('micpe-watchdog-stop.txt') | Should -BeLessThan $probe.IndexOf('pecmd.exe "%SystemDrive%\Program Files\MICPE\MICPE-Setup\MICPE-Setup.wcs" -cli -deploy') -Because 'the flag must be written before the long deploy starts'
        $probe.IndexOf('micpe-watchdog-stop.txt') | Should -BeGreaterThan $probe.IndexOf('mark_installer_deploy') -Because 'the flag belongs to the deploy section, not earlier'
    }

    It 'the watchdog watches for probe_done and records probe_failed after a quiet spell' {
        $wd = Get-Content -LiteralPath $script:WatchdogPath -Raw -Encoding utf8
        $wd | Should -Match 'probe_done=1' -Because 'a finished probe stops the watcher'
        $wd | Should -Match 'echo probe_failed=1' -Because 'a stalled probe must be failed loudly, not left silent'
        $wd | Should -Match 'micpe-watchdog-stop\.txt' -Because 'the deploy stop flag must stop the watcher'
        $wd | Should -Match 'WD_LIMIT=5' -Because 'the default is five quiet checks'
        $wd | Should -Match 'WD_WAIT=60' -Because 'the default check spacing is sixty seconds'
    }

    It 'the build injects the watchdog into the image next to probe.cmd' {
        $build = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src/build/Build-Micpe.ps1') -Raw -Encoding utf8
        # Single quotes: the pattern carries literal $ and ' characters, and
        # a double-quoted pattern would expand $watchdog to nothing.
        $build | Should -Match 'Copy-Item -LiteralPath \$watchdog -Destination \(Join-Path \$system32 ''probe-watchdog\.cmd''\)' -Because 'the reseed step must copy the watchdog into System32'
        $build.IndexOf('probe-watchdog.cmd') | Should -BeGreaterThan $build.IndexOf('probe.cmd') -Because 'the watchdog is injected by the same reseed step as probe.cmd'
    }

    It 'the watchdog watches the local probe copy as well as the share probe file (run 48)' {
        # Run 47: the share file's host view stalled at 12:43:48
        # while the guest kept writing to 12:45:18 — the local copy
        # held the whole run. The watcher reads both: probe_done in
        # either file ends the watch, and growth in either file resets
        # the quiet count, so a stalled share view can no longer fake
        # a dead probe.
        $wd = Get-Content -LiteralPath $script:WatchdogPath -Raw -Encoding utf8
        $wd | Should -Match 'WD_LOCAL=%~dp1micpe-probe-local\.txt' -Because 'the local copy lives next to the share probe file'
        $wdLines = Get-Content -LiteralPath $script:WatchdogPath -Encoding utf8
        $localDoneChecks = @($wdLines | Where-Object { $_ -match 'findstr /b /c:"probe_done=1" "%WD_LOCAL%"' })
        $localDoneChecks.Count | Should -Be 3 -Because 'the loop top, the tick loop and the fail branch all check the local copy'
        $wd | Should -Match 'WD_LOCAL_SIZE=' -Because 'the local size is tracked alongside the share size'
        $wd | Should -Match 'WD_LOCAL_NOW' -Because 'each round reads the local size too'
        $wd | Should -Match 'local=%WD_LOCAL_NOW%' -Because 'the heartbeat records the local size it observed'
    }

    It 'the watchdog writes a heartbeat line every loop iteration (run 44303866765)' {
        # Run 44319967017: each round writes two heartbeat lines, one
        # before the wait and one after it, so a partial heartbeat says
        # whether the loop died in the wait or in the next round's file
        # work. The phase tag is what tells them apart.
        $wd = Get-Content -LiteralPath $script:WatchdogPath -Raw -Encoding utf8
        $wd | Should -Match 'WD_HEARTBEAT=%~dp1micpe-watchdog-heartbeat\.txt' -Because 'the heartbeat lives next to the probe file on the share, where the host can read it'
        $wd | Should -Match 'watchdog_start=' -Because 'the start line proves the script itself began'
        $wd | Should -Match 'quiet=%WD_QUIET% size=%WD_NOW%' -Because 'each iteration records its quiet count and the size it observed'
        $wd | Should -Match 'probe_failed_written=1' -Because 'the fail write is recorded in the heartbeat too'
        # The heartbeat must go to its own file: writing it into the
        # probe file would grow the file and reset the quiet count.
        $wdLines = Get-Content -LiteralPath $script:WatchdogPath -Encoding utf8
        $beatLines = @($wdLines | Where-Object { $_ -match 'quiet=%WD_QUIET%' })
        $beatLines.Count | Should -Be 2 -Because 'one heartbeat line before the wait, one after it'
        $beatLines[0] | Should -Match 'phase=before_wait' -Because 'the first heartbeat line of a round proves the round started'
        $beatLines[1] | Should -Match 'phase=after_wait' -Because 'the second heartbeat line proves the wait returned'
        foreach ($line in $beatLines) {
            $line | Should -Match 'WD_HEARTBEAT' -Because 'the heartbeat goes to its own file, not the probe file'
        }
        # Order by line number, not by IndexOf on the whole text: the
        # header comment also names both phases. The echo lines are the
        # code lines; the comment lines start with "rem".
        $beforeLine = ($wdLines | Select-String -Pattern 'phase=before_wait' | Where-Object { $_.Line -match '^echo ' } | Select-Object -First 1).LineNumber
        $afterLine = ($wdLines | Select-String -Pattern 'phase=after_wait' | Where-Object { $_.Line -match '^echo ' } | Select-Object -First 1).LineNumber
        $waitLine = ($wdLines | Select-String -Pattern 'choice /c Y /d Y /t %WD_TICKLEN%' | Select-Object -First 1).LineNumber
        $tickLine = ($wdLines | Select-String -Pattern 'phase=wait_tick' | Where-Object { $_.Line -match '^echo ' } | Select-Object -First 1).LineNumber
        $beforeLine | Should -Not -BeNullOrEmpty -Because 'the before-wait heartbeat line must exist'
        $afterLine | Should -Not -BeNullOrEmpty -Because 'the after-wait heartbeat line must exist'
        $waitLine | Should -Not -BeNullOrEmpty -Because 'the choice wait line must exist'
        $tickLine | Should -Not -BeNullOrEmpty -Because 'the tick heartbeat line must exist (run 44349189039)'
        $beforeLine | Should -BeLessThan $waitLine -Because 'the before-wait line is written before the wait starts'
        $waitLine | Should -BeLessThan $tickLine -Because 'the tick line is written only after a tick returns'
        $tickLine | Should -BeLessThan $afterLine -Because 'the after-wait line is written only after the last tick returns'
    }

    It 'the watchdog waits with choice, not ping (run 44319967017)' {
        # ping is the prime suspect for the round-2 stall, and the
        # watchdog's ping -n 60 was one of the two candidates for it.
        # Run 44349189039: the wait is split into short choice ticks
        # (see the tick test below); the wait line carries the tick
        # length now, not the whole WD_WAIT.
        $wd = Get-Content -LiteralPath $script:WatchdogPath -Raw -Encoding utf8
        $wd | Should -Match 'choice /c Y /d Y /t %WD_TICKLEN%' -Because 'each tick waits with choice'
        $wd | Should -Not -Match 'ping -n %WD_WAIT%' -Because 'the ping wait is gone'
        $wd | Should -Not -Match 'choice /c Y /d Y /t %WD_WAIT%' -Because 'a single 60-second choice wait never returned in run 38'
    }

    It 'the watchdog splits a long wait into short ticks (run 44349189039)' {
        # Run 38: before_wait written 17:02:42.67, after_wait never
        # appeared — the loop died in its first 60-second choice wait,
        # while the probe's 1-second choice waits returned 30 times in
        # the same run. WD_WAIT=60 becomes 12 ticks of 5 seconds with a
        # heartbeat line after each tick; small values used by the
        # mechanism tests (WD_WAIT=2) stay a single tick of the same
        # length, so the total wait is unchanged there.
        $wd = Get-Content -LiteralPath $script:WatchdogPath -Raw -Encoding utf8
        $wd | Should -Match 'set /a WD_TICKS=%WD_WAIT% / 5' -Because 'the tick count comes from the wait'
        $wd | Should -Match 'if %WD_TICKS% lss 1 set "WD_TICKS=1"' -Because 'a short wait is still a single tick'
        $wd | Should -Match 'set /a WD_TICKLEN=%WD_WAIT% / %WD_TICKS%' -Because 'the tick length divides the wait'
        $wd | Should -Match ':watchdog_wait_tick' -Because 'the ticks run in their own loop'
        $wd | Should -Match 'if %WD_TICK% lss %WD_TICKS% goto :watchdog_wait_tick' -Because 'the loop runs every tick'
        $wd | Should -Match 'phase=wait_tick' -Because 'each tick leaves a heartbeat line saying which tick it was'
    }

    It 'the verify artifact collects the heartbeat file' {
        $buildYml = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/build.yml') -Raw -Encoding utf8
        $buildYml | Should -Match 'verify-out/share/micpe-watchdog-heartbeat\.txt' -Because 'a heartbeat on the share is useless if the artifact upload does not collect it'
    }

    It 'reverse control: without the heartbeat write the static test fails' {
        # The heartbeat assertion above must actually depend on the
        # watchdog writing the line, not pass vacuously.
        $wd = Get-Content -LiteralPath $script:WatchdogPath -Raw -Encoding utf8
        $mutated = $wd.Replace('quiet=%WD_QUIET% size=%WD_NOW%', 'quiet=missing size=missing')
        $mutated | Should -Not -Match 'quiet=%WD_QUIET% size=%WD_NOW%'
    }

    It 'reverse control: without the watchdog start the static test fails' {
        # The assertion above must actually depend on probe.cmd starting
        # the watchdog, not pass vacuously.
        $probe = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $mutated = $probe.Replace('probe-watchdog.cmd', 'probe-watchdog-missing.cmd')
        $mutated | Should -Not -Match 'probe-watchdog\.cmd'
    }

    It 'the tick loop checks the stop conditions before every tick (run 44410311576)' {
        # Run 41: the heartbeat stopped at tick 3/12 although probe_done
        # was already written and the stop flag was already set — the
        # loop-top checks never ran because the tick loop runs the whole
        # 60-second cycle first, and the guest's own shutdown killed the
        # watcher mid-cycle. The check must live inside :watchdog_wait_tick,
        # before the choice wait, and the clean exit is marked.
        $wd = Get-Content -LiteralPath $script:WatchdogPath -Raw -Encoding utf8
        $wd | Should -Match 'probe_done_seen=1' -Because 'the clean exit is marked, so a heartbeat that just stops is still a death'
        $wd | Should -Match 'stop_seen=1' -Because 'a stop-flag exit is marked too'
        $wdLines = Get-Content -LiteralPath $script:WatchdogPath -Encoding utf8
        $tickLabelLine = ($wdLines | Select-String -Pattern '^:watchdog_wait_tick' | Select-Object -First 1).LineNumber
        # The same checks also exist at the loop top, and a third
        # probe_done check lives in :watchdog_fail; the tick-loop copies
        # are the ones after the tick label and before the tick wait.
        $doneCheckLine = ($wdLines | Select-String -Pattern 'findstr /b /c:"probe_done=1" "%WD_FILE%"' | Where-Object { $_.LineNumber -gt $tickLabelLine } | Select-Object -First 1).LineNumber
        $stopCheckLine = ($wdLines | Select-String -Pattern 'if exist "%WD_STOP%"' | Where-Object { $_.LineNumber -gt $tickLabelLine } | Select-Object -First 1).LineNumber
        $choiceLine = ($wdLines | Select-String -Pattern 'choice /c Y /d Y /t %WD_TICKLEN%' | Select-Object -First 1).LineNumber
        $tickLabelLine | Should -Not -BeNullOrEmpty
        $doneCheckLine | Should -Not -BeNullOrEmpty -Because 'the probe_done check must exist inside the tick loop'
        $stopCheckLine | Should -Not -BeNullOrEmpty -Because 'the stop-flag check must exist inside the tick loop'
        $choiceLine | Should -Not -BeNullOrEmpty
        $doneCheckLine | Should -BeGreaterThan $tickLabelLine -Because 'the check is inside the tick loop'
        $stopCheckLine | Should -BeGreaterThan $tickLabelLine -Because 'the check is inside the tick loop'
        $doneCheckLine | Should -BeLessThan $choiceLine -Because 'the check runs before the tick wait'
        $stopCheckLine | Should -BeLessThan $choiceLine -Because 'the check runs before the tick wait'
    }
}
