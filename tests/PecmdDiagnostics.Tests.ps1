BeforeAll {
    $root = "$PSScriptRoot/.."
    $script:Ini = Get-Content "$root/src/shell/PECMD.INI" -Raw
    $script:Startnet = Get-Content "$root/src/shell/startnet.cmd" -Raw
    $script:Probe = Get-Content "$root/src/ci/probe.cmd" -Raw
    # $env:SystemRoot does not exist on Linux, and Join-Path throws on a
    # null first argument. The two Windows-only mechanism tests skip there,
    # but BeforeAll still runs, so keep the Windows path out of it on Linux.
    if ($IsWindows) {
        $script:CmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    }
    else {
        $script:CmdExe = $null
    }
}

Describe 'PECMD chain diagnostics (run 44267918861)' {
    It 'PECMD.INI records a marker before EXEC explorer.exe' {
        $script:Ini | Should -Match 'mark_pecmd_init=1'
        $script:Ini.IndexOf('mark_pecmd_init') | Should -BeLessThan $script:Ini.IndexOf('EXEC %SystemRoot%\explorer.exe')
    }

    It 'PECMD.INI records a marker after EXEC explorer.exe and before WAIT' {
        $script:Ini | Should -Match 'mark_pecmd_after_explorer=1'
        $script:Ini.IndexOf('mark_pecmd_after_explorer') | Should -BeGreaterThan $script:Ini.IndexOf('EXEC %SystemRoot%\explorer.exe')
        $script:Ini.IndexOf('mark_pecmd_after_explorer') | Should -BeLessThan $script:Ini.IndexOf('WAIT 3000')
    }

    It 'PECMD.INI records markers after ctfmon and after the shortcuts call' {
        $script:Ini | Should -Match 'mark_pecmd_after_ctfmon=1'
        $script:Ini.IndexOf('mark_pecmd_after_ctfmon') | Should -BeGreaterThan $script:Ini.IndexOf('EXEC %SystemRoot%\System32\ctfmon.exe')
        $script:Ini | Should -Match 'mark_pecmd_after_shortcuts=1'
        $script:Ini.IndexOf('mark_pecmd_after_shortcuts') | Should -BeGreaterThan $script:Ini.IndexOf('CALL %SystemRoot%\System32\Pin-Shortcuts.wcs')
        $script:Ini.IndexOf('mark_pecmd_after_shortcuts') | Should -BeLessThan $script:Ini.IndexOf('EXEC -wait -hide cmd.exe /c %SystemRoot%\System32\probe.cmd')
    }

    It 'PECMD.INI runs probe.cmd through EXEC cmd.exe, not CALL (run 44285721257)' {
        # PECMD's CALL only calls PECMD scripts and labels: the old CALL
        # probe.cmd silently did nothing and the probe only ran from
        # startnet's control call. EXEC cmd.exe /c runs the batch for
        # real, and -wait keeps the probe before the installer scan.
        $script:Ini | Should -Match 'EXEC -wait -hide cmd\.exe /c %SystemRoot%\\System32\\probe\.cmd'
        $script:Ini | Should -Not -Match 'CALL %SystemRoot%\\System32\\probe\.cmd'
    }

    It 'PECMD.INI markers all go to the same marks file on X:' {
        $markerLines = @($script:Ini -split "`r?`n" | Where-Object { $_ -match 'mark_pecmd_' })
        $markerLines.Count | Should -Be 4
        foreach ($line in $markerLines) {
            $line | Should -Match 'X:\\micpe-pecmd-marks\.txt'
        }
    }

    It 'PECMD.INI marker EXECs wait so the order is preserved' {
        $markerLines = @($script:Ini -split "`r?`n" | Where-Object { $_ -match 'mark_pecmd_' })
        foreach ($line in $markerLines) {
            $line | Should -Match '^EXEC -wait -hide cmd\.exe /c echo mark_pecmd_'
        }
    }

    It 'startnet.cmd records the PECMD launch before and after' {
        $script:Startnet | Should -Match 'mark_startnet_pecmd_before=1'
        $script:Startnet | Should -Match 'mark_startnet_after_pecmd_launch=1'
        $script:Startnet.IndexOf('mark_startnet_pecmd_before') | Should -BeLessThan $script:Startnet.IndexOf('PECMD.EXE" LOAD')
        $script:Startnet.IndexOf('mark_startnet_after_pecmd_launch') | Should -BeGreaterThan $script:Startnet.IndexOf('PECMD.EXE" LOAD')
    }

    It 'startnet.cmd waits about 45 seconds after launching PECMD, before the control probe' {
        $script:Startnet | Should -Match 'ping -n 46 127\.0\.0\.1'
        $script:Startnet.IndexOf('ping -n 46') | Should -BeGreaterThan $script:Startnet.IndexOf('mark_startnet_after_pecmd_launch')
        $script:Startnet.IndexOf('ping -n 46') | Should -BeLessThan $script:Startnet.IndexOf('MICPE_PROBE_FOUND')
    }

    It 'startnet.cmd only runs the control probe when no probe file exists yet' {
        $script:Startnet | Should -Match 'MICPE_PROBE_FOUND'
        $script:Startnet | Should -Match 'if not defined MICPE_PROBE_FOUND if exist "%SystemRoot%\\System32\\probe\.cmd" call probe\.cmd'
        $script:Startnet.IndexOf('if not defined MICPE_PROBE_FOUND') | Should -BeGreaterThan $script:Startnet.IndexOf('ping -n 46')
    }

    It 'startnet.cmd still falls back to the cmd shell when PECMD.EXE is missing' {
        $script:Startnet | Should -Match 'PECMD\.EXE not found - falling back to the command shell\.'
    }

    It 'probe.cmd copies the marks file into the probe output before the drive-letters section' {
        $script:Probe | Should -Match 'micpe-pecmd-marks\.txt'
        $script:Probe.IndexOf('micpe-pecmd-marks.txt') | Should -BeLessThan $script:Probe.IndexOf('--- drive letters')
        $script:Probe.IndexOf('micpe-pecmd-marks.txt') | Should -BeGreaterThan $script:Probe.IndexOf('share_drive=')
    }

    It 'M2 warning no longer claims the finished image boots to the cmd fallback' {
        $shell = Get-Content "$root/src/build/lib/Shell.ps1" -Raw
        $shell | Should -Not -Match 'the image will boot to the cmd fallback'
        $shell | Should -Match 'this M2 step leaves the cmd fallback in place until a later step supplies the PECMD binary'
    }
}

Describe 'startnet control-probe block under a real cmd.exe' {
    # The control probe lives inside a parenthesised IF block and uses a FOR
    # scan plus chained IFs. Batch parsing of such blocks is brittle (run
    # 44135105700: a comment with parens inside a block broke parsing), so
    # this test runs the exact construct under a real cmd.exe on Windows.
    # It mirrors the startnet.cmd block with stubbed commands; the static
    # tests above pin the real file's lines.
    BeforeAll {
        $script:BlockLines = @(
            '@echo off'
            'if exist "%~dp0probe-stub.cmd" ('
            '    ping -n 2 127.0.0.1 >nul 2>&1'
            '    set "MICPE_PROBE_FOUND="'
            '    for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist "%%D:\micpe-probe.txt" set "MICPE_PROBE_FOUND=1"'
            '    if not defined MICPE_PROBE_FOUND call "%~dp0probe-stub.cmd"'
            ')'
        ) -join "`r`n"
    }

    It 'runs the control probe when no probe file exists' -Skip:(-not $IsWindows) {
        $work = Join-Path ([System.IO.Path]::GetTempPath()) "micpe-pecmd-diag-$(Get-Random)"
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        try {
            $stub = Join-Path $work 'probe-stub.cmd'
            Set-Content -LiteralPath $stub -Value "@echo off`r`necho control-probe-ran > `"%~dp0ran.txt`"" -Encoding ascii
            $batch = Join-Path $work 'block.cmd'
            Set-Content -LiteralPath $batch -Value $script:BlockLines -Encoding ascii
            & $script:CmdExe /c "`"$batch`""
            Test-Path -LiteralPath (Join-Path $work 'ran.txt') | Should -BeTrue
        }
        finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'skips the control probe when a probe file already exists' -Skip:(-not $IsWindows) {
        $work = Join-Path ([System.IO.Path]::GetTempPath()) "micpe-pecmd-diag-$(Get-Random)"
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $drive = (Get-Item -LiteralPath $work).PSDrive.Name
        $rootProbe = Join-Path "$($drive):\" 'micpe-probe.txt'
        $createdRootProbe = $false
        try {
            $stub = Join-Path $work 'probe-stub.cmd'
            Set-Content -LiteralPath $stub -Value "@echo off`r`necho control-probe-ran > `"%~dp0ran.txt`"" -Encoding ascii
            $batch = Join-Path $work 'block.cmd'
            Set-Content -LiteralPath $batch -Value $script:BlockLines -Encoding ascii
            Set-Content -LiteralPath $rootProbe -Value 'boot=1' -Encoding ascii
            $createdRootProbe = $true
            & $script:CmdExe /c "`"$batch`""
            Test-Path -LiteralPath (Join-Path $work 'ran.txt') | Should -BeFalse
        }
        finally {
            if ($createdRootProbe) {
                Remove-Item -LiteralPath $rootProbe -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
