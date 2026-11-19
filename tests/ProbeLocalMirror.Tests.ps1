#Requires -Version 7.0
#Requires -Modules Pester
<#
.SYNOPSIS
    Mechanism and static tests for the probe local mirror (run 44386689307).

.DESCRIPTION
    Build run 44386689307: the probe stopped after brand=1 and never
    wrote installer_scan or probe_done, and the harness waited out the
    full 45 minutes. The freeze is guest-level and intermittent, and
    its timing drifts (run 39: ~30-40 s after shell_ready; run 40:
    ~2.2 min after), so the remaining distinction is local disk vs
    share: probe.cmd now writes every section marker to a local mirror
    file on %SystemDrive% FIRST and to the share second, and a detached
    probe-sync.cmd echoes the local file's last line to the serial log
    every few seconds. The host reads the serial log without the share:
    serial markers keep coming while the share probe stops growing ->
    the guest is alive and the share is wedged (vvfat); serial markers
    stop too -> the guest itself froze.

    The same round also brackets the installer scan and deploy calls
    with before/after markers (the run 40 probe cannot say whether it
    died entering the installer section or inside the .wcs call),
    dumps the raw sc queryex output into the tasklist file (both
    WIN32_EXIT_CODE parses came back missing), and takes a second
    tasklist snapshot at probe end (explorer was already Not
    Responding before the UWP diagnostics, with a complete module
    list, so the end dump says whether it ever built a window).

    All cmd.exe tests skip on Linux; the static tests run anywhere.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path
    $script:SyncPath = Join-Path $script:RepoRoot 'src/ci/probe-sync.cmd'
    $script:MirrorPath = Join-Path $script:RepoRoot 'src/ci/probe-mirror.cmd'
    $script:ProbePath = Join-Path $script:RepoRoot 'src/ci/probe.cmd'
    $script:BuildPath = Join-Path $script:RepoRoot 'src/build/Build-Micpe.ps1'
    $script:WorkflowPath = Join-Path $script:RepoRoot '.github/workflows/build.yml'
    # SystemRoot is empty on Linux; the Windows-only paths below are
    # never used there (those tests skip), but BeforeAll still runs for
    # the static tests, so do not let Join-Path see a null parent.
    $script:CmdExe = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\cmd.exe' } else { 'cmd.exe' }
    $script:FindstrExe = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\findstr.exe' } else { 'findstr.exe' }
    # choice.exe is the sync's wait (run 44319967017): the work dir is
    # the whole PATH for the test batch, so it must be copied in.
    $script:ChoiceExe = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\choice.exe' } else { 'choice.exe' }

    # A CRLF batch file: cmd.exe treats a lone LF as part of the line.
    $script:WriteBatchCrlf = {
        param([string] $Path, [string[]] $Lines)
        $text = ($Lines -join "`r`n") + "`r`n"
        [System.IO.File]::WriteAllText($Path, $text, [System.Text.Encoding]::ASCII)
    }

    # Run a batch under a real cmd.exe with only findstr/choice on PATH
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

    # The sync reads its stop flag from %SystemDrive%, which on the CI
    # runner is the real C: drive. Point it at the work dir instead so
    # the tests never touch the drive root: a wrapper batch sets
    # SystemDrive for the sync process only. Interval 1 keeps the
    # tests fast: one 1-second tick per report.
    $script:InvokeSync = {
        param([string] $WorkDir, [string] $LocalFile, [string] $SerialFile, [int] $TimeoutSec = 60)
        $wrapper = Join-Path $WorkDir 'run-sync.bat'
        & $script:WriteBatchCrlf $wrapper @(
            '@echo off',
            ('set "SystemDrive={0}"' -f $WorkDir),
            ('call "{0}" "{1}" 1 "{2}"' -f $script:SyncPath, $LocalFile, $SerialFile),
            'exit /b %errorlevel%'
        )
        return (& $script:InvokeCmdTimed $wrapper $WorkDir -TimeoutSec $TimeoutSec)
    }

    # Start the sync in the background the way probe.cmd does, so the
    # test can grow the local file while it watches.
    $script:StartSync = {
        param([string] $WorkDir, [string] $LocalFile, [string] $SerialFile)
        $wrapper = Join-Path $WorkDir 'run-sync.bat'
        & $script:WriteBatchCrlf $wrapper @(
            '@echo off',
            ('set "SystemDrive={0}"' -f $WorkDir),
            ('call "{0}" "{1}" 1 "{2}"' -f $script:SyncPath, $LocalFile, $SerialFile),
            'exit /b %errorlevel%'
        )
        $oldPath = $env:PATH
        try {
            $env:PATH = $WorkDir
            return Start-Process -FilePath $script:CmdExe -ArgumentList '/c', $wrapper -PassThru -NoNewWindow
        }
        finally { $env:PATH = $oldPath }
    }

    # The mirror companion takes the local file and the mirror dir
    # (trailing backslash, as the probe passes %MIRROR_DIR%). Same
    # SystemDrive wrapper as the sync so the stop-flag check reads the
    # work dir, never the drive root.
    $script:InvokeMirror = {
        param([string] $WorkDir, [string] $LocalFile, [string] $MirrorDir, [int] $TimeoutSec = 60)
        $wrapper = Join-Path $WorkDir 'run-mirror.bat'
        & $script:WriteBatchCrlf $wrapper @(
            '@echo off',
            ('set "SystemDrive={0}"' -f $WorkDir),
            ('call "{0}" "{1}" "{2}\"' -f $script:MirrorPath, $LocalFile, $MirrorDir),
            'exit /b %errorlevel%'
        )
        return (& $script:InvokeCmdTimed $wrapper $WorkDir -TimeoutSec $TimeoutSec)
    }

    $script:StartMirror = {
        param([string] $WorkDir, [string] $LocalFile, [string] $MirrorDir)
        $wrapper = Join-Path $WorkDir 'run-mirror.bat'
        & $script:WriteBatchCrlf $wrapper @(
            '@echo off',
            ('set "SystemDrive={0}"' -f $WorkDir),
            ('call "{0}" "{1}" "{2}\"' -f $script:MirrorPath, $LocalFile, $MirrorDir),
            'exit /b %errorlevel%'
        )
        $oldPath = $env:PATH
        try {
            $env:PATH = $WorkDir
            return Start-Process -FilePath $script:CmdExe -ArgumentList '/c', $wrapper -PassThru -NoNewWindow
        }
        finally { $env:PATH = $oldPath }
    }
}

Describe 'probe sync mechanism (run 44386689307)' {
    It 'S1: echoes the local file last line to the serial log and follows it when the file grows' -Skip:(-not $IsWindows) {
        $workDir = & $script:NewWorkDir
        $localFile = Join-Path $workDir 'micpe-probe-local.txt'
        $serialFile = Join-Path $workDir 'serial.log'
        try {
            Set-Content -LiteralPath $localFile -Value @('boot=1', 'share=1') -Encoding ascii
            $proc = & $script:StartSync $workDir $localFile $serialFile
            try {
                Start-Sleep -Seconds 3
                $serial = Get-Content -LiteralPath $serialFile -Raw -ErrorAction SilentlyContinue
                Write-Host "serial after 3s: [$serial]"
                $serial | Should -Match 'sync_start=' -Because 'the sync announces itself first'
                $serial | Should -Match 'last=share=1' -Because 'the first report carries the local file last line'
                Add-Content -LiteralPath $localFile -Value 'explorer=1' -Encoding ascii
                Start-Sleep -Seconds 3
                $serial = Get-Content -LiteralPath $serialFile -Raw -ErrorAction SilentlyContinue
                Write-Host "serial after grow: [$serial]"
                $serial | Should -Match 'last=explorer=1' -Because 'the next report follows the grown file'
                Add-Content -LiteralPath $localFile -Value 'probe_done=1' -Encoding ascii
                $exited = $proc.WaitForExit(30000)
                if (-not $exited) { try { $proc.Kill($true) } catch { }; $proc.WaitForExit(10000) }
                $exited | Should -Be $true -Because 'the sync must stop once the probe is done'
                $proc.ExitCode | Should -Be 0
            }
            finally {
                if (-not $proc.HasExited) { try { $proc.Kill($true) } catch { } }
            }
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'S2: exits quietly when probe_done=1 is already there' -Skip:(-not $IsWindows) {
        $workDir = & $script:NewWorkDir
        $localFile = Join-Path $workDir 'micpe-probe-local.txt'
        $serialFile = Join-Path $workDir 'serial.log'
        try {
            Set-Content -LiteralPath $localFile -Value @('boot=1', 'probe_done=1') -Encoding ascii
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = & $script:InvokeSync $workDir $localFile $serialFile -TimeoutSec 60
            $sw.Stop()
            Write-Host "timed out: $($result.TimedOut); exit code: $($result.ExitCode); elapsed seconds: $($sw.Elapsed.TotalSeconds)"
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 0
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 15 -Because 'a finished probe ends the first check at once'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'S3: stops when probe.cmd writes the stop flag before the deploy' -Skip:(-not $IsWindows) {
        $workDir = & $script:NewWorkDir
        $localFile = Join-Path $workDir 'micpe-probe-local.txt'
        $serialFile = Join-Path $workDir 'serial.log'
        try {
            Set-Content -LiteralPath $localFile -Value @('boot=1', 'share=1') -Encoding ascii
            New-Item -ItemType File -Path (Join-Path $workDir 'micpe-watchdog-stop.txt') -Force | Out-Null
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = & $script:InvokeSync $workDir $localFile $serialFile -TimeoutSec 60
            $sw.Stop()
            Write-Host "timed out: $($result.TimedOut); exit code: $($result.ExitCode); elapsed seconds: $($sw.Elapsed.TotalSeconds)"
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 0
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 15 -Because 'a present stop flag ends the first check at once'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'S4: the COM1 open test distinguishes a writable device from a missing one (run 44410311576)' -Skip:(-not $IsWindows) {
        # Run 41: probe-sync.cmd wrote zero sync lines although it lived
        # until the stop flag, so the channel itself is the suspect.
        # probe.cmd tests it with `copy /y nul COM1` and records
        # com1=1/0 from copy's errorlevel, and separately writes
        # `echo sync_test > COM1` as the end-to-end proof in the serial
        # log. The redirect's errorlevel must NOT be used: a failed `>`
        # redirect leaves errorlevel UNCHANGED — it reports the previous
        # command's errorlevel, not its own outcome. CI run 44425584830
        # showed it staying 0 after a failing redirect (previous command
        # had succeeded); run 44426492643 showed it staying 1 (previous
        # command, a failing copy, had set it). Either way the redirect
        # can never report com1. This test proves the copy legs on real
        # cmd.exe (copy to a writable target succeeds, copy to an
        # unopenable target fails with errorlevel 1, copy to NUL proves
        # copy-to-a-device works in principle) and pins the trap in both
        # directions. The runner's own COM1 is diagnostic only, not
        # asserted: it is enumerated (serialcomm=1) but may be reserved
        # by the Azure serial console, so its open can fail there while
        # the probe's copy logic is still sound — the true-side value of
        # com1 is verified in PE by the Build, not on the runner.
        # `> COM99` is not a missing-device sentinel either (CI run
        # 44423069424: cmd creates a plain file named COM99; only
        # COM1-COM9 are reserved device names).
        $workDir = & $script:NewWorkDir
        $outFile = Join-Path $workDir 'com1-test.txt'
        $srcFile = Join-Path $workDir 'serial-src.log'
        $copyFile = Join-Path $workDir 'copy-target.log'
        $missingFile = Join-Path $workDir 'no-such-dir\device.log'
        $bat = Join-Path $workDir 'com1-test.bat'
        try {
            & $script:WriteBatchCrlf $bat @(
                '@echo off',
                ('echo sync_test > "{0}" 2>nul' -f $srcFile),
                ('copy /y "{0}" NUL >nul 2>&1' -f $srcFile),
                ('if errorlevel 1 (echo copy_nul=0 >> "{0}") else (echo copy_nul=1 >> "{0}")' -f $outFile),
                ('copy /y "{0}" COM1 >nul 2>&1' -f $srcFile),
                ('if errorlevel 1 (echo copy_com1=0 >> "{0}") else (echo copy_com1=1 >> "{0}")' -f $outFile),
                ('copy /y nul COM1 >nul 2>&1'),
                ('if errorlevel 1 (echo copy_nul_com1=0 >> "{0}") else (echo copy_nul_com1=1 >> "{0}")' -f $outFile),
                ('copy /y nul "{0}" >nul 2>&1' -f $copyFile),
                ('if errorlevel 1 (echo copy_ok=0 >> "{0}") else (echo copy_ok=1 >> "{0}")' -f $outFile),
                ('copy /y nul "{0}" >nul 2>&1' -f $missingFile),
                ('if errorlevel 1 (echo copy_missing=0 >> "{0}") else (echo copy_missing=1 >> "{0}")' -f $outFile),
                ('copy /y nul "{0}" >nul 2>&1' -f $missingFile),
                ('echo sync_test > "{0}" 2>nul' -f $missingFile),
                ('if errorlevel 1 (echo trap_after_fail=1 >> "{0}") else (echo trap_after_fail=0 >> "{0}")' -f $outFile),
                ('copy /y nul "{0}" >nul 2>&1' -f $copyFile),
                ('echo sync_test > "{0}" 2>nul' -f $missingFile),
                ('if errorlevel 1 (echo trap_after_ok=1 >> "{0}") else (echo trap_after_ok=0 >> "{0}")' -f $outFile)
            )
            $result = & $script:InvokeCmdTimed $bat $workDir -TimeoutSec 60
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 0
            $text = Get-Content -LiteralPath $outFile -Raw
            Write-Host "com1 test: [$text]"
            $text | Should -Match 'copy_nul=1' -Because 'copy to a device works in principle'
            $text | Should -Match 'copy_ok=1' -Because 'copy to a writable target succeeds'
            $text | Should -Match 'copy_missing=0' -Because 'copy to a target that cannot be opened fails with errorlevel 1'
            $text | Should -Match 'trap_after_fail=1' -Because 'a failed redirect leaves a set errorlevel alone'
            $text | Should -Match 'trap_after_ok=0' -Because 'a failed redirect leaves a clear errorlevel alone — the trap the probe must not rely on'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'probe mirror mechanism (run 44428428849)' {
    It 'M1: copies the local file to the mirror dir and follows it when the file grows, then stops on probe_done' -Skip:(-not $IsWindows) {
        # The serial channel is dead (run 42), so the local mirror file
        # needs a retrieval path that does not depend on the suspect
        # share: the mirror companion copies the whole local file to a
        # second vvfat volume every 5 seconds. The copy is the whole
        # file, not just the last line, so the host gets every marker.
        $workDir = & $script:NewWorkDir
        $localFile = Join-Path $workDir 'micpe-probe-local.txt'
        $mirrorDir = Join-Path $workDir 'mirror'
        New-Item -ItemType Directory -Path $mirrorDir -Force | Out-Null
        $mirrorFile = Join-Path $mirrorDir 'micpe-probe-local.txt'
        try {
            Set-Content -LiteralPath $localFile -Value @('boot=1', 'share=1') -Encoding ascii
            $proc = & $script:StartMirror $workDir $localFile $mirrorDir
            try {
                Start-Sleep -Seconds 3
                $mirror = Get-Content -LiteralPath $mirrorFile -Raw -ErrorAction SilentlyContinue
                Write-Host "mirror after 3s: [$mirror]"
                $mirror | Should -Match 'share=1' -Because 'the first copy carries the local file as it stands'
                Add-Content -LiteralPath $localFile -Value 'explorer=1' -Encoding ascii
                Start-Sleep -Seconds 6
                $mirror = Get-Content -LiteralPath $mirrorFile -Raw -ErrorAction SilentlyContinue
                Write-Host "mirror after grow: [$mirror]"
                $mirror | Should -Match 'explorer=1' -Because 'the next copy follows the grown file'
                Add-Content -LiteralPath $localFile -Value 'probe_done=1' -Encoding ascii
                $exited = $proc.WaitForExit(30000)
                if (-not $exited) { try { $proc.Kill($true) } catch { }; $proc.WaitForExit(10000) }
                $exited | Should -Be $true -Because 'the mirror must stop once the probe is done'
                $proc.ExitCode | Should -Be 0
                $mirror = Get-Content -LiteralPath $mirrorFile -Raw -ErrorAction SilentlyContinue
                $mirror | Should -Match 'probe_done=1' -Because 'the final copy runs on the stop'
            }
            finally {
                if (-not $proc.HasExited) { try { $proc.Kill($true) } catch { } }
            }
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'M2: exits quietly when probe_done=1 is already there, after a final copy' -Skip:(-not $IsWindows) {
        $workDir = & $script:NewWorkDir
        $localFile = Join-Path $workDir 'micpe-probe-local.txt'
        $mirrorDir = Join-Path $workDir 'mirror'
        New-Item -ItemType Directory -Path $mirrorDir -Force | Out-Null
        $mirrorFile = Join-Path $mirrorDir 'micpe-probe-local.txt'
        try {
            Set-Content -LiteralPath $localFile -Value @('boot=1', 'probe_done=1') -Encoding ascii
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = & $script:InvokeMirror $workDir $localFile $mirrorDir -TimeoutSec 60
            $sw.Stop()
            Write-Host "timed out: $($result.TimedOut); exit code: $($result.ExitCode); elapsed seconds: $($sw.Elapsed.TotalSeconds)"
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 0
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 15 -Because 'a finished probe ends the first check at once'
            $mirror = Get-Content -LiteralPath $mirrorFile -Raw -ErrorAction SilentlyContinue
            $mirror | Should -Match 'probe_done=1' -Because 'the final copy still runs'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'M3: stops when probe.cmd writes the stop flag before the deploy' -Skip:(-not $IsWindows) {
        $workDir = & $script:NewWorkDir
        $localFile = Join-Path $workDir 'micpe-probe-local.txt'
        $mirrorDir = Join-Path $workDir 'mirror'
        New-Item -ItemType Directory -Path $mirrorDir -Force | Out-Null
        try {
            Set-Content -LiteralPath $localFile -Value @('boot=1', 'share=1') -Encoding ascii
            New-Item -ItemType File -Path (Join-Path $workDir 'micpe-watchdog-stop.txt') -Force | Out-Null
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = & $script:InvokeMirror $workDir $localFile $mirrorDir -TimeoutSec 60
            $sw.Stop()
            Write-Host "timed out: $($result.TimedOut); exit code: $($result.ExitCode); elapsed seconds: $($sw.Elapsed.TotalSeconds)"
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 0
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 15 -Because 'a present stop flag ends the first check at once'
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'probe local mirror (static)' {
    It 'probe.cmd defines PROBE_LOCAL on %SystemDrive% next to PROBE_OUT' {
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'set "PROBE_LOCAL=%SystemDrive%\\micpe-probe-local\.txt"'
        $text.IndexOf('set "PROBE_OUT=') | Should -BeLessThan $text.IndexOf('set "PROBE_LOCAL=')
        $text.IndexOf('set "PROBE_LOCAL=') | Should -BeLessThan $text.IndexOf('echo boot=1')
    }

    It 'every non-poll section marker is written to the local file first, then the share' {
        # The poll markers fire every second and are deliberately
        # share-only; the section markers bracket the freeze points.
        $lines = Get-Content -LiteralPath $script:ProbePath -Encoding utf8
        $markers = @($lines | Where-Object { $_ -match '^echo mark_' -and $_ -notmatch 'mark_uwp_poll_' })
        $markers.Count | Should -Be 31 -Because '27 section markers plus the 4 installer before/after markers'
        foreach ($line in $markers) {
            $line | Should -Match '^echo mark_\w+=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_\w+=%TIME: =0% >> "%PROBE_OUT%"$'
        }
    }

    It 'boot, share and probe_done are mirrored to the local file' {
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match '> "%PROBE_LOCAL%" echo boot=1 & > "%PROBE_OUT%" echo boot=1'
        $text | Should -Match '>> "%PROBE_LOCAL%" echo share=%SHARE% & >> "%PROBE_OUT%" echo share=%SHARE%'
        $text | Should -Match 'echo probe_done=1 >> "%PROBE_LOCAL%" & echo probe_done=1 >> "%PROBE_OUT%"'
    }

    It 'probe.cmd starts probe-sync.cmd right after the watchdog' {
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'probe-sync\.cmd "%PROBE_LOCAL%"'
        $text.IndexOf('probe-watchdog.cmd "%PROBE_OUT%"') | Should -BeLessThan $text.IndexOf('probe-sync.cmd "%PROBE_LOCAL%"')
        $text.IndexOf('probe-sync.cmd "%PROBE_LOCAL%"') | Should -BeLessThan $text.IndexOf('--- pecmd markers')
    }

    It 'probe.cmd finds the mirror drive by its sentinel and records mirror=1/0 (run 44428428849)' {
        # The serial channel is dead, so the local mirror needs a
        # retrieval path that does not depend on the suspect share: a
        # second vvfat volume carrying a micpe-mirror.txt sentinel.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'if exist "%%D:\\micpe-mirror\.txt" set "MIRROR_DIR=%%D:\\"' -Because 'the mirror drive is found by sentinel, never by letter'
        $text | Should -Match 'echo mirror=1 >> "%PROBE_LOCAL%"'
        $text | Should -Match 'echo mirror=0 >> "%PROBE_OUT%"'
        $text | Should -Match 'echo mirror_drive=%MIRROR_DIR% >> "%PROBE_OUT%"'
        $text.IndexOf('set "PROBE_LOCAL=') | Should -BeLessThan $text.IndexOf('set "MIRROR_DIR="') -Because 'PROBE_LOCAL must be set before the mirror keys are written to it'
        $text.IndexOf('set "MIRROR_DIR="') | Should -BeLessThan $text.IndexOf('echo boot=1') -Because 'the mirror is identified before the first marker'
    }

    It 'probe.cmd starts probe-mirror.cmd right after probe-sync.cmd (run 44428428849)' {
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'probe-mirror\.cmd "%PROBE_LOCAL%" "%MIRROR_DIR%"'
        $text.IndexOf('probe-sync.cmd "%PROBE_LOCAL%"') | Should -BeLessThan $text.IndexOf('probe-mirror.cmd "%PROBE_LOCAL%"')
        $text.IndexOf('probe-mirror.cmd "%PROBE_LOCAL%"') | Should -BeLessThan $text.IndexOf('--- pecmd markers')
        $text | Should -Match 'if defined MIRROR_DIR' -Because 'without a mirror drive the companion is never started'
    }

    It 'probe-mirror.cmd copies the local file to the mirror drive' {
        $text = Get-Content -LiteralPath $script:MirrorPath -Raw -Encoding utf8
        $text | Should -Match 'set "MIRROR_DEST=%MIRROR_DIR%micpe-probe-local\.txt"'
        $text | Should -Match 'copy /y "%MIRROR_LOCAL%" "%MIRROR_DEST%"'
    }

    It 'probe-mirror.cmd stops on probe_done and on the stop flag' {
        $text = Get-Content -LiteralPath $script:MirrorPath -Raw -Encoding utf8
        $text | Should -Match 'findstr /b /c:"probe_done=1" "%MIRROR_LOCAL%"'
        $text | Should -Match 'if exist "%SystemDrive%\\micpe-watchdog-stop\.txt" goto :mirror_final'
        $text | Should -Match ':mirror_final'
    }

    It 'probe-mirror.cmd never writes to the share or the serial log' {
        # A share write is exactly the operation under suspicion, and
        # the serial channel is dead — the mirror must touch neither.
        # The header names COM1 in prose (why the serial path is dead),
        # so the assertion pins the write form, not the bare word.
        # The file must exist first: every assertion below is a
        # Not-Match, which would pass vacuously on a missing file.
        Test-Path -LiteralPath $script:MirrorPath | Should -Be $true
        $text = Get-Content -LiteralPath $script:MirrorPath -Raw -Encoding utf8
        $text | Should -Not -Match 'PROBE_OUT'
        $text | Should -Not -Match '> "?COM1"?'
        $text | Should -Not -Match 'SYNC_SERIAL'
        $text | Should -Not -Match 'probe_failed'
    }

    It 'probe.cmd diagnoses the serial enumeration: service states, Start values, ACPI device (run 44428428849)' {
        # serial.sys is in the image but the port was never enumerated
        # (run 42: serialcomm=0) — file present is not driver loaded.
        # These keys say which link is broken: the ACPI device, the
        # Serial service state, or its Start value.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'call :probe_svc Serial serial_svc "%PROBE_LOCAL%"' -Because 'the Serial service state says whether the driver is up'
        $text | Should -Match 'call :probe_svc Serenum serenum_svc "%PROBE_LOCAL%"' -Because 'Serenum is the enumerator the port depends on'
        $text | Should -Match 'reg query "HKLM\\SYSTEM\\CurrentControlSet\\Services\\Serial" /v Start' -Because 'the Start value says disabled vs manual vs auto'
        $text | Should -Match 'reg query "HKLM\\SYSTEM\\CurrentControlSet\\Services\\Serenum" /v Start'
        $text | Should -Match 'echo serial_start=%SERIAL_START%'
        $text | Should -Match 'echo serenum_start=%SERENUM_START%'
        $text | Should -Match 'reg query "HKLM\\SYSTEM\\CurrentControlSet\\Enum\\ACPI\\PNP0501" >nul 2>&1' -Because 'a bare query only sets errorlevel when the device is not enumerated'
        $text | Should -Match 'echo serial_enum=0 >> "%PROBE_LOCAL%"'
        $text | Should -Match 'echo serial_enum=1 >> "%PROBE_OUT%"'
        # Diagnosis only: no service is started in the probe.
        $text | Should -Not -Match 'sc start Serial'
        $text | Should -Not -Match 'sc start Serenum'
        # The block sits after the serialcomm read and before the
        # watchdog start, so it runs even if the probe dies later.
        $text.IndexOf('echo serialcomm=') | Should -BeLessThan $text.IndexOf('call :probe_svc Serial')
        $text.IndexOf('echo serial_enum=0') | Should -BeLessThan $text.IndexOf('probe-watchdog.cmd')
    }

    It ':probe_svc mirrors to the local file when a third argument is given (run 44428428849)' {
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'if not "%~3"=="" echo %~2=MISSING >> "%~3"'
        $text | Should -Match 'if not "%~3"=="" echo %~2=RUNNING >> "%~3"'
        $text | Should -Match 'if not "%~3"=="" echo %~2=STOPPED >> "%~3"'
        # The existing UWP calls stay two-argument (share-only).
        $text | Should -Match 'call :probe_svc AppXSVC appxsvc'
        $text | Should -Not -Match 'call :probe_svc AppXSVC appxsvc "'
    }

    It 'the build injects probe-mirror.cmd into System32 next to probe.cmd' {
        $build = Get-Content -LiteralPath $script:BuildPath -Raw -Encoding utf8
        $build | Should -Match 'Assert-PathExists -Path \$mirror -Label ''probe-mirror\.cmd'''
        $build | Should -Match 'Copy-Item -LiteralPath \$mirror -Destination \(Join-Path \$system32 ''probe-mirror\.cmd''\) -Force'
    }

    It 'the verify artifact collects the mirror copy of the local probe file' {
        $workflow = Get-Content -LiteralPath $script:WorkflowPath -Raw -Encoding utf8
        $workflow | Should -Match 'verify-out/mirror/micpe-probe-local\.txt'
    }

    It 'probe.cmd tests the serial channel with a sync_test write to COM1 (run 44410311576)' {
        # Run 41: probe-sync.cmd wrote zero sync lines although it lived
        # until the stop flag, so the channel itself is the suspect.
        # The write is the decisive test: it lands in micpe-serial.log
        # iff the channel works. The com1 key records whether cmd.exe
        # could open COM1 at all; serial_sys / serialcomm say whether
        # the driver and the port enumeration exist.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'echo sync_test=%TIME: =0% > COM1 2>nul' -Because 'the write is the end-to-end proof: it lands in micpe-serial.log iff the channel works'
        $text.IndexOf('echo sync_test=') | Should -BeLessThan $text.IndexOf('probe-watchdog.cmd') -Because 'the test must run even if the probe dies later'
        # The open itself is tested with copy, not with the redirect's
        # errorlevel: a failed redirect never sets errorlevel (CI run
        # 44425584830), so the redirect could never report com1=0.
        $text | Should -Match 'copy /y nul COM1 >nul 2>&1' -Because 'copy fails with errorlevel 1 when the port cannot be opened'
        $text.IndexOf('copy /y nul COM1') | Should -BeLessThan $text.IndexOf('echo com1=0') -Because 'the copy runs before the com1 key is recorded'
        $text | Should -Match 'echo com1=0 >> "%PROBE_LOCAL%"' -Because 'both branches of the open test record the result'
        $text | Should -Match 'echo com1=1 >> "%PROBE_OUT%"'
        $text | Should -Match 'serial\.sys' -Because 'a missing driver is the first suspect when COM1 cannot be opened'
        $text | Should -Match 'SERIALCOMM' -Because 'the enumeration is read from the SERIALCOMM device map'
        $text | Should -Match 'echo serialcomm=0 >> "%PROBE_LOCAL%"'
        # The enumeration reads the value directly with /v, not through
        # a find pipeline: a command missing from PATH inside a pipeline
        # kills the batch silently (run 44135105700), and reg.exe is not
        # on the restricted PATH of the mechanism test.
        $text | Should -Match 'reg query "HKLM\\HARDWARE\\DEVICEMAP\\SERIALCOMM" /v \\Device\\Serial0 >nul 2>&1' -Because 'the /v form needs no pipeline'
        $text | Should -Not -Match 'reg query "HKLM\\HARDWARE\\DEVICEMAP\\SERIALCOMM" 2>nul \| find' -Because 'the piped form died in CI run 44423069424'
    }

    It 'probe-sync.cmd echoes the local file last line to the serial device' {
        $text = Get-Content -LiteralPath $script:SyncPath -Raw -Encoding utf8
        $text | Should -Match 'echo sync_start='
        $text | Should -Match 'echo sync %TIME: =0% last=%SYNC_LAST%'
        $text | Should -Match 'if not defined SYNC_SERIAL set "SYNC_SERIAL=COM1"'
    }

    It 'probe-sync.cmd stops on probe_done and on the stop flag' {
        $text = Get-Content -LiteralPath $script:SyncPath -Raw -Encoding utf8
        $text | Should -Match 'findstr /b /c:"probe_done=1" "%SYNC_LOCAL%"'
        $text | Should -Match 'if exist "%SystemDrive%\\micpe-watchdog-stop\.txt" exit /b 0'
    }

    It 'probe-sync.cmd never writes to the share' {
        # A share write is exactly the operation under suspicion, so
        # the sync must not touch PROBE_OUT at all.
        $text = Get-Content -LiteralPath $script:SyncPath -Raw -Encoding utf8
        $text | Should -Not -Match 'PROBE_OUT'
        $text | Should -Not -Match 'probe_failed'
    }

    It 'the build injects probe-sync.cmd into System32 next to probe.cmd' {
        $build = Get-Content -LiteralPath $script:BuildPath -Raw -Encoding utf8
        # Single-quoted patterns: the $ in $sync / $system32 is a regex
        # escape, not a variable (a double-quoted pattern would try to
        # expand $sync under StrictMode and die).
        $build | Should -Match 'Assert-PathExists -Path \$sync -Label ''probe-sync\.cmd'''
        $build | Should -Match 'Copy-Item -LiteralPath \$sync -Destination \(Join-Path \$system32 ''probe-sync\.cmd''\) -Force'
    }

    It 'the verify artifact collects the serial log' {
        $workflow = Get-Content -LiteralPath $script:WorkflowPath -Raw -Encoding utf8
        $workflow | Should -Match 'verify-out/micpe-serial\.log'
    }

    It 'the installer scan and deploy calls are bracketed with before/after markers' {
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text.IndexOf('mark_installer_before') | Should -BeLessThan $text.IndexOf('MICPE_PROBE_FILE=%PROBE_OUT%')
        $text.IndexOf('MICPE_PROBE_FILE=%PROBE_OUT%') | Should -BeLessThan $text.IndexOf('mark_installer_after')
        $text.IndexOf('mark_installer_deploy_before') | Should -BeLessThan $text.IndexOf('micpe-watchdog-stop.txt')
        $text.IndexOf('mark_installer_deploy_after') | Should -BeLessThan $text.IndexOf('echo probe_done=1')
    }

    It 'the raw sc queryex output is redirected into the tasklist file' {
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'echo --- sc queryex AppXSVC --- >> "%TASKLIST_OUT%"'
        $text | Should -Match 'sc queryex AppXSVC >> "%TASKLIST_OUT%" 2>&1'
        $text | Should -Match 'sc queryex StateRepository >> "%TASKLIST_OUT%" 2>&1'
        # The raw dump must come before the parse that reads it, so a
        # different queryex layout in PE is visible instead of silently
        # swallowed.
        $text.IndexOf('sc queryex AppXSVC >> "%TASKLIST_OUT%"') | Should -BeLessThan $text.IndexOf("sc queryex AppXSVC 2^>nul")
    }

    It 'a second tasklist snapshot is taken at probe end, before probe_done' {
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'echo --- tasklist at probe end --- >> "%TASKLIST_OUT%"'
        $text.IndexOf('mark_installer_deploy_after') | Should -BeLessThan $text.IndexOf('--- tasklist at probe end ---')
        $text.IndexOf('--- tasklist at probe end ---') | Should -BeLessThan $text.IndexOf('echo probe_done=1')
    }

    It 'reverse control: without the PROBE_LOCAL definition the mirror test fails' {
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $mutated = $text.Replace('set "PROBE_LOCAL=%SystemDrive%\micpe-probe-local.txt"', 'set "PROBE_LOCAL="')
        $mutated | Should -Not -Match 'set "PROBE_LOCAL=%SystemDrive%\\micpe-probe-local\.txt"'
    }

    It 'reverse control: without the sync start the start test fails' {
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $mutated = $text.Replace('probe-sync.cmd "%PROBE_LOCAL%"', 'probe-sync.cmd "%PROBE_OUT%"')
        $mutated | Should -Not -Match 'probe-sync\.cmd "%PROBE_LOCAL%"'
    }
}
