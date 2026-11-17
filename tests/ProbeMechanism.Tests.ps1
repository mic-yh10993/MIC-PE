#Requires -Version 7.0
<#
.SYNOPSIS
    Mechanism experiment for run 44135105700 (run 27): the probe file stopped
    after share_drive, at the shell section's first tasklist pipeline.

    The probe died between `share_drive=` and `explorer=`; the only statement
    there is `tasklist ... | find ...`, and tasklist.exe is absent from the
    whole boot.wim. Two hypotheses need a real cmd.exe to settle, because
    static reading cannot tell them apart:

      H1  A missing tasklist in a pipeline kills the batch (then the fix is
          to extract tasklist.exe into boot.wim).
      H2  `echo test 2>nul > file` does NOT silence a failed output open
          (then the run 27 screenshot's single "Access is denied" line came
          from the D: write test during the scan, and the death needs another
          explanation).

    These tests run cmd.exe with a restricted PATH (a temp dir holding only
    find.exe), so tasklist is genuinely unresolvable exactly as in the PE.
    Windows-only: they skip on Linux, where no cmd.exe exists.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:CmdExe = if ($IsWindows) { Join-Path $env:SystemRoot 'System32\cmd.exe' } else { 'cmd.exe' }

    # Fresh temp dir holding only find.exe: under a PATH of just this dir,
    # cmd resolves find but not tasklist, ping, reg or anything else from
    # System32 -- the same lookup failure the PE hits.
    $script:NewMechWorkDir = {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('micpe-probe-mech-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\find.exe') -Destination $dir
        return $dir
    }

    # Run a batch file under the restricted PATH and return cmd's output.
    $script:InvokeRestrictedCmd = {
        param([string] $BatPath, [string] $WorkDir)
        $oldPath = $env:PATH
        try {
            $env:PATH = $WorkDir
            $out = & $script:CmdExe /c $BatPath 2>&1 | Out-String
            return $out
        }
        finally {
            $env:PATH = $oldPath
        }
    }

    $script:WriteBatchCrlf = {
        param([string] $Path, [string[]] $Lines)
        [System.IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
    }
}

Describe 'probe.cmd shell section under a missing tasklist (run 44135105700)' {
    It 'survives the exact shell-section construct when tasklist is not on PATH' -Skip:(-not $IsWindows) {
        # Lines 51-52 of src/ci/probe.cmd, copied verbatim, plus a trailing
        # marker: if the marker is missing, the batch died at the pipeline.
        $workDir = & $script:NewMechWorkDir
        try {
            $marker = Join-Path $workDir 'marker.txt'
            $bat = Join-Path $workDir 'survive.bat'
            & $script:WriteBatchCrlf $bat @(
                '@echo off',
                ('set "PROBE_OUT={0}"' -f $marker),
                '> "%PROBE_OUT%" echo boot=1',
                'tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul',
                'if errorlevel 1 (echo explorer=0 >> "%PROBE_OUT%") else (echo explorer=1 >> "%PROBE_OUT%")',
                'echo after=1 >> "%PROBE_OUT%"'
            )
            $out = & $script:InvokeRestrictedCmd $bat $workDir
            Write-Host "cmd output: [$out]"
            $text = Get-Content -LiteralPath $marker -Raw
            $text | Should -Match 'boot=1'
            $text | Should -Match 'explorer=0' -Because 'find saw no tasklist output, so the 0 branch must run'
            $text | Should -Match 'after=1' -Because 'the batch must continue past the missing-tasklist pipeline'
        }
        finally {
            if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
        }
    }

    It 'runs the real probe.cmd scan + shell sections to shell_ready with tasklist missing' -Skip:(-not $IsWindows) {
        # The genuine head of probe.cmd (lines 1-61: scan, boot/share writes,
        # shell section) plus a trailing marker. No installer/uwp sections:
        # they would launch apps on the runner. No shutdown line either:
        # the head has none, and the tail must never run here.
        $workDir = & $script:NewMechWorkDir
        try {
            $probe = Get-Content -LiteralPath (Join-Path $repoRoot 'src/ci/probe.cmd')
            $head = @($probe[0..60]) + @('echo probe_head_done=1 >> "%PROBE_OUT%"')
            $bat = Join-Path $workDir 'probe-head.bat'
            & $script:WriteBatchCrlf $bat $head
            $out = & $script:InvokeRestrictedCmd $bat $workDir
            Write-Host "cmd output: [$out]"
            # The scan picks C: on the runner (writable), as it picks C: in CI.
            $probeOut = 'C:\micpe-probe.txt'
            Test-Path -LiteralPath $probeOut | Should -BeTrue -Because 'the scan must find the writable C: drive'
            $text = Get-Content -LiteralPath $probeOut -Raw
            $text | Should -Match 'boot=1'
            $text | Should -Match 'share_drive=C:\\'
            $text | Should -Match 'explorer=0'
            $text | Should -Match 'dwm=0'
            $text | Should -Match 'shell_ready=0'
            $text | Should -Match 'probe_head_done=1' -Because 'the head must run to the end, not die at tasklist'
        }
        finally {
            if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
            if (Test-Path -LiteralPath 'C:\micpe-probe.txt') { Remove-Item -LiteralPath 'C:\micpe-probe.txt' -Force }
            if (Test-Path -LiteralPath 'C:\micpe-write-test.tmp') { Remove-Item -LiteralPath 'C:\micpe-write-test.tmp' -Force }
        }
    }

    It 'silences a failed output open only when 2>nul precedes the redirect' -Skip:(-not $IsWindows) {
        # Redirecting to a directory always fails with "Access is denied",
        # whatever the account: the open itself is the thing being tested.
        $dir = 'C:\Windows'
        $new = & $script:CmdExe /c "echo test 2>nul > `"$dir`"" 2>&1 | Out-String
        $old = & $script:CmdExe /c "echo test > `"$dir`" 2>nul" 2>&1 | Out-String
        Write-Host "new-order (2>nul first) output: [$new]"
        Write-Host "old-order (> first) output: [$old]"
        $new | Should -Not -Match 'Access is denied' -Because '2>nul must precede the redirect to silence a failed open (run 26 claim)'
        $old | Should -Match 'Access is denied' -Because 'the old order is the control: it must still leak'
    }
}
