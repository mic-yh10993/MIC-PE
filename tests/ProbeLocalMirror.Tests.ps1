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
        # probe.cmd tests it with `echo sync_test > COM1` and records
        # com1=1/0 from the redirect's errorlevel. This test proves the
        # errorlevel logic on real cmd.exe: a redirect to an existing
        # device succeeds, a redirect to a device that does not exist
        # fails.
        $workDir = & $script:NewWorkDir
        $outFile = Join-Path $workDir 'com1-test.txt'
        $deviceFile = Join-Path $workDir 'serial-device.log'
        $bat = Join-Path $workDir 'com1-test.bat'
        try {
            & $script:WriteBatchCrlf $bat @(
                '@echo off',
                ('echo sync_test > "{0}" 2>nul' -f $deviceFile),
                ('if errorlevel 1 (echo com1=0 >> "{0}") else (echo com1=1 >> "{0}")' -f $outFile),
                'echo sync_test > COM99 2>nul',
                ('if errorlevel 1 (echo com1_missing=0 >> "{0}") else (echo com1_missing=1 >> "{0}")' -f $outFile)
            )
            $result = & $script:InvokeCmdTimed $bat $workDir -TimeoutSec 60
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 0
            $text = Get-Content -LiteralPath $outFile -Raw
            Write-Host "com1 test: [$text]"
            $text | Should -Match 'com1=1' -Because 'a redirect to an existing device succeeds'
            $text | Should -Match 'com1_missing=0' -Because 'a redirect to a device that does not exist fails'
            (Get-Content -LiteralPath $deviceFile -Raw) | Should -Match 'sync_test' -Because 'the successful write lands in the device file'
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

    It 'probe.cmd tests the serial channel with a sync_test write to COM1 (run 44410311576)' {
        # Run 41: probe-sync.cmd wrote zero sync lines although it lived
        # until the stop flag, so the channel itself is the suspect.
        # The write is the decisive test: it lands in micpe-serial.log
        # iff the channel works. The com1 key records whether cmd.exe
        # could open COM1 at all; serial_sys / serialcomm say whether
        # the driver and the port enumeration exist.
        $text = Get-Content -LiteralPath $script:ProbePath -Raw -Encoding utf8
        $text | Should -Match 'echo sync_test=%TIME: =0% > COM1 2>nul' -Because 'the write itself is the decisive test'
        $text.IndexOf('echo sync_test=') | Should -BeLessThan $text.IndexOf('probe-watchdog.cmd') -Because 'the test must run even if the probe dies later'
        $text | Should -Match 'echo com1=0 >> "%PROBE_LOCAL%"' -Because 'both branches of the open test record the result'
        $text | Should -Match 'echo com1=1 >> "%PROBE_OUT%"'
        $text | Should -Match 'serial\.sys' -Because 'a missing driver is the first suspect when COM1 cannot be opened'
        $text | Should -Match 'SERIALCOMM' -Because 'the enumeration is read from the SERIALCOMM device map'
        $text | Should -Match 'echo serialcomm=0 >> "%PROBE_LOCAL%"'
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
