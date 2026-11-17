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

    The :probe_uwp subroutine does, in order: a tasklist|find check
    (proven safe by the run 44135105700 round), `start "" explorer.exe
    "<shell: target>"`, a 7-second ping settle, a second tasklist|find,
    and `exit /b %errorlevel%`. Only the `start explorer.exe` line can
    block: in the m4 image there is no PECMD.EXE, no Explorer shell is
    running, and the Assert-Probe.ps1 m4 comment already states that UWP
    apps cannot be launched at m4 (launching needs the shell).

    These tests run the genuine uwp section (cut from probe.cmd by
    content, never by line number) under a real cmd.exe on a
    windows-2025 runner, with a hard timeout so a stall is observed,
    not fatal:

    - U1 runs it with Explorer as the runner left it (control: the
      shell-exists path) and records whether explorer.exe was running.
    - U1b kills explorer.exe first (the PE condition: no shell) and
      runs the same genuine code.
    - U2 stubs out the `start explorer.exe` line: if U1/U1b stall and
      U2 completes, the launch attempt itself is the culprit and the
      surrounding batch logic (tasklist pipes, the `!` in the target,
      exit /b) is exonerated.
    - U3 proves the `shell:AppsFolder\...!App` target survives the
      `call` with delayed expansion intact.

    All four tests need a real cmd.exe, so they skip on Linux. U1b
    stops explorer.exe on the ephemeral runner VM only; the runner
    agent is a service and does not depend on it, and the test
    restarts Explorer afterwards when it was running before.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path
    $script:ProbePath = Join-Path $script:RepoRoot 'src/ci/probe.cmd'
    $script:CmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $script:FindExe = Join-Path $env:SystemRoot 'System32\find.exe'
    $script:TasklistExe = Join-Path $env:SystemRoot 'System32\tasklist.exe'
    $script:PingExe = Join-Path $env:SystemRoot 'System32\ping.exe'

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

    It 'U3: the shell target with ! survives the call intact' -Skip:(-not $IsWindows) {
        # The Calculator target contains `!App`; with delayed expansion
        # on, a mangled argument would break the launch before `start`
        # is even reached. Prove the subroutine receives it verbatim.
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
            $text | Should -Match 'Microsoft.WindowsCalculator_8wekyb3d8bbwe!App'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
