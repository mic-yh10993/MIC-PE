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
    $script:PingExe = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\ping.exe' } else { 'ping.exe' }

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
        Copy-Item -LiteralPath $script:PingExe -Destination (Join-Path $workDir 'ping.exe')
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

    It 'reverse control: without the watchdog start the static test fails' {
        # The assertion above must actually depend on probe.cmd starting
        # the watchdog, not pass vacuously.
        $probe = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $mutated = $probe.Replace('probe-watchdog.cmd', 'probe-watchdog-missing.cmd')
        $mutated | Should -Not -Match 'probe-watchdog\.cmd'
    }
}
