#Requires -Version 7.0
#Requires -Modules Pester
<#
.SYNOPSIS
    Guards for the probe.cmd shell section (Build run 44135105700).

.DESCRIPTION
    Run 44135105700 (stage m4, head c498e0b) died with a probe file that
    stopped after three lines (boot=1, share=1, share_drive=C:\) and eight
    missing assertions. The mechanism experiment (Test run 44154459167, on
    a windows-2025 runner under a real cmd.exe) proved, on the genuine
    probe.cmd head and on the exact shell-section construct:

    - A missing tasklist.exe in a `tasklist ... | find ...` pipeline
      silently aborts the batch file. No error is printed (2>nul hides
      the "not recognized" message), the batch just stops, so the probe
      file ends after share_drive and explorer=/dwm=/shell_ready= are
      never written. The run 27 probe file (exactly those three lines)
      was reproduced byte for byte.
    - The screen's "Access is denied." does NOT come from the shell
      section. A failed output open prints it whether 2>nul comes first
      or last, so the run 26 claim (order silences it) is false; the
      line is cosmetic noise from the scan's write test hitting the
      read-only boot ISO (D:).

    The fix is to ship tasklist.exe (plus its en-US/zh-CN MUIs) in
    boot.wim via src/filelists/10-cmdpe.txt. These tests pin the
    dependency so a future filelist cleanup that drops tasklist fails
    loudly in CI instead of silently in QEMU:

    - "dies silently ..." documents what happens without tasklist.
    - "completes ..." proves that with tasklist present the same head
      runs through shell_ready (the discriminating test for the fix).
    - "prints Access is denied ..." pins the corrected redirect fact.

    All three tests need a real cmd.exe, so they skip on Linux.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path
    $script:ProbePath = Join-Path $script:RepoRoot 'src/ci/probe.cmd'
    # $env:SystemRoot does not exist on Linux, and Join-Path throws on a
    # null first argument. The three Windows-only tests skip there, but
    # BeforeAll still runs for the platform-independent cut test below, so
    # keep the Windows paths out of it on Linux. (Latent until the Test 53
    # cut test added the first non-skipped It to this file.)
    if ($IsWindows) {
        $script:CmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $script:FindExe = Join-Path $env:SystemRoot 'System32\find.exe'
        $script:TasklistExe = Join-Path $env:SystemRoot 'System32\tasklist.exe'
    }
    else {
        $script:CmdExe = $null
        $script:FindExe = $null
        $script:TasklistExe = $null
    }

    # Run a batch with only find.exe (+ optionally tasklist.exe) on PATH,
    # so tasklist / ping / reg are all unresolvable, as in the PE image.
    # The batch path itself is absolute, so cmd.exe can still load it.
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

    # A CRLF batch file: cmd.exe treats a lone LF as part of the line.
    $script:WriteBatchCrlf = {
        param([string] $Path, [string[]] $Lines)
        $text = ($Lines -join "`r`n") + "`r`n"
        [System.IO.File]::WriteAllText($Path, $text, [System.Text.Encoding]::ASCII)
    }

    # The genuine probe.cmd scan + shell sections, truncated after the
    # shell_ready if/else (found by content, not line number, so comment
    # edits above it cannot shift the cut), with a marker appended so
    # completion is observable. No shutdown line, no UWP section (must
    # not launch apps on the runner).
    #
    # The cut pattern must be the exact echo of the shell_ready value.
    # Test run 53 (head 211267d): the loose 'shell_ready=' pattern matched
    # the progress marker `echo mark_shell_ready=%TIME: =0%` first (it sits
    # before the shell section), so the head was cut at the marker and the
    # shell section never ran -- the "completes ..." test failed on a
    # missing explorer= key. 'echo shell_ready=[01]' matches only the real
    # if/else line; the marker line has 'mark_' between 'echo ' and
    # 'shell_ready='.
    $script:ShellReadyCutPattern = 'echo shell_ready=[01]'
    $script:BuildProbeHeadBatch = {
        param([string] $Path)
        $probeLines = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
        $end = -1
        for ($i = 0; $i -lt $probeLines.Count; $i++) {
            if ($probeLines[$i] -match $script:ShellReadyCutPattern) { $end = $i; break }
        }
        if ($end -lt 0) { throw 'probe.cmd has no shell_ready line; the head cut is stale' }
        $lines = @($probeLines[0..$end]) + @('echo probe_head_done=1 >> "%PROBE_OUT%"')
        & $script:WriteBatchCrlf $Path $lines
    }
}

Describe 'probe.cmd shell section under a missing tasklist (run 44135105700)' {
    It 'cuts the probe head after the real shell_ready line, not the mark_shell_ready marker (Test run 53)' {
        # Pure string logic: runs on Linux too, so the Test 53 regression is
        # caught locally instead of only on the Windows runner. The old
        # 'shell_ready=' pattern matched the marker line first; prove the
        # new pattern picks the real if/else line and the head still carries
        # the tasklist pipelines the shell section needs.
        $probeLines = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
        $marker = -1
        $cut = -1
        for ($i = 0; $i -lt $probeLines.Count; $i++) {
            if ($marker -lt 0 -and $probeLines[$i] -match 'mark_shell_ready=') { $marker = $i }
            if ($cut -lt 0 -and $probeLines[$i] -match $script:ShellReadyCutPattern) { $cut = $i }
        }
        $marker | Should -BeGreaterThan -1 -Because 'the progress marker must exist for this test to mean anything'
        $cut | Should -BeGreaterThan $marker -Because 'the cut must be after the marker, not on it'
        $probeLines[$cut] | Should -Match 'echo shell_ready=[01]'
        ($probeLines[0..$cut] -join "`n") | Should -Match 'tasklist'
        # And the old pattern really was the bug: it stops at the marker.
        $oldCut = -1
        for ($i = 0; $i -lt $probeLines.Count; $i++) {
            if ($probeLines[$i] -match 'shell_ready=') { $oldCut = $i; break }
        }
        $oldCut | Should -Be $marker
    }

    It 'dies silently at the first tasklist pipeline when tasklist is not on PATH' -Skip:(-not $IsWindows) {
        # The exact shell-section construct, probe.cmd lines 51-52.
        $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        Copy-Item -LiteralPath $script:FindExe -Destination (Join-Path $workDir 'find.exe')
        $marker = Join-Path $workDir 'marker.txt'
        $bat = Join-Path $workDir 'shell-section.bat'
        try {
            $lines = @(
                '@echo off',
                ('> "{0}" echo boot=1' -f $marker),
                'tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul',
                'if errorlevel 1 (echo explorer=0 >> "{0}") else (echo explorer=1 >> "{0}")' -f $marker,
                ('echo after=1 >> "{0}"' -f $marker)
            )
            & $script:WriteBatchCrlf $bat $lines
            $out = & $script:InvokeRestrictedCmd $bat $workDir
            Write-Host "cmd output: [$out]"
            $text = Get-Content -LiteralPath $marker -Raw
            $text | Should -Match 'boot=1'
            # The batch never reaches the if/else: explorer= is unwritten.
            $text | Should -Not -Match 'explorer=0' -Because 'find saw no tasklist output, so the 0 branch must run -- unless the batch died first'
            $text | Should -Not -Match 'after=1' -Because 'the marker after the pipeline must not run if the batch died at the pipeline'
            # And the death is silent: 2>nul hides the "not recognized" error.
            $out | Should -Not -Match 'not recognized'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'completes the real probe.cmd scan + shell sections when tasklist is on PATH' -Skip:(-not $IsWindows) {
        # The discriminating test for the fix: the same genuine head that
        # died in run 44135105700 must run through shell_ready once
        # tasklist.exe is available (as it will be after 10-cmdpe.txt
        # carries it). Values are 0-or-1: the runner may itself run
        # explorer.exe, so only the keys' presence is asserted.
        # ping.exe is on PATH too: the PE image has PING.EXE, and the
        # head's settle line needs it (a missing ping fails silently
        # but is not the PE behaviour).
        $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        Copy-Item -LiteralPath $script:FindExe -Destination (Join-Path $workDir 'find.exe')
        Copy-Item -LiteralPath $script:TasklistExe -Destination (Join-Path $workDir 'tasklist.exe')
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\ping.exe') -Destination (Join-Path $workDir 'ping.exe')
        $bat = Join-Path $workDir 'probe-head.bat'
        try {
            & $script:BuildProbeHeadBatch $bat
            $out = & $script:InvokeRestrictedCmd $bat $workDir
            Write-Host "cmd output: [$out]"
            # The scan picks the first writable drive on the runner (C:).
            $text = Get-Content -LiteralPath 'C:\micpe-probe.txt' -Raw
            $text | Should -Match 'boot=1'
            $text | Should -Match 'share=1'
            $text | Should -Match 'share_drive=C:\\'
            $text | Should -Match 'com1=1' -Because 'the runner has a COM1 port, so the open test must succeed'
            $text | Should -Match 'serialcomm=1' -Because 'the runner has COM1, so the /v form of the enumeration must read it (run 44410311576)'
            $text | Should -Match 'explorer=[01]'
            $text | Should -Match 'dwm=[01]'
            $text | Should -Match 'shell_ready=[01]'
            $text | Should -Match 'probe_head_done=1'
        }
        finally {
            Remove-Item -LiteralPath 'C:\micpe-probe.txt' -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'prints Access is denied for a failed output open in either redirect order' -Skip:(-not $IsWindows) {
        # Corrects the run 26 claim: 2>nul first does NOT silence a failed
        # open. Both orders print it, so the run 27 screen line is
        # cosmetic noise from the scan write test on the read-only D:.
        # The target is the SystemRoot directory itself (no trailing
        # backslash, so the quoting cannot be misread as an escaped quote).
        $dir = $env:SystemRoot
        $new = & $script:CmdExe /c "echo test 2>nul > `"$dir`"" 2>&1 | Out-String
        $old = & $script:CmdExe /c "echo test > `"$dir`" 2>nul" 2>&1 | Out-String
        Write-Host "new-order (2>nul first) output: [$new]"
        Write-Host "old-order (> first) output: [$old]"
        $new | Should -Match 'Access is denied'
        $old | Should -Match 'Access is denied'
    }
}
