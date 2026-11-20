BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Registry.ps1"
    . "$PSScriptRoot/../src/build/lib/Invoke-PrivilegedRegImport.ps1"
    $script:TempRoot = [System.IO.Path]::GetTempPath()
}

Describe 'hive map' {
    It 'maps the four hives the PE needs' {
        $map = Get-PeHiveMap
        $map.Count | Should -Be 4
        ($map.File -join ',') | Should -Be 'DEFAULT,DRIVERS,SOFTWARE,SYSTEM'
        ($map.Key -join ',') | Should -Be 'PE-DEF,PE-DRV,PE-SOFT,PE-SYS'
    }
}

Describe 'Import-RegFile' {
    It 'throws when the file is missing' {
        { Import-RegFile -RegFile (Join-Path $script:TempRoot 'micpe-absent.reg') } |
            Should -Throw '*not found*'
    }
}

Describe 'ConvertFrom-RegQueryOutput' {
    It 'parses name, type and data rows' {
        $lines = @(
            'HKEY_LOCAL_MACHINE\PE-IME\Microsoft\Windows NT\CurrentVersion\Keyboard Layout\Preload',
            '    1    REG_SZ    00000804',
            '    2    REG_SZ    00000409'
        )
        $values = ConvertFrom-RegQueryOutput -Lines $lines
        $values['1'] | Should -Be '00000804'
        $values['2'] | Should -Be '00000409'
    }

    It 'keeps data containing spaces' {
        $lines = @(
            'HKEY_LOCAL_MACHINE\PE-IME\Microsoft\Windows NT\CurrentVersion\Keyboard Layouts\00000804',
            '    Layout Text    REG_SZ    Chinese (Simplified) - US Keyboard',
            '    IME File    REG_SZ    ChsIME.exe'
        )
        $values = ConvertFrom-RegQueryOutput -Lines $lines
        $values['Layout Text'] | Should -Be 'Chinese (Simplified) - US Keyboard'
        $values['IME File'] | Should -Be 'ChsIME.exe'
    }

    It 'returns empty for a header-only listing' {
        $values = ConvertFrom-RegQueryOutput -Lines @(
            'HKEY_LOCAL_MACHINE\PE-IME\Microsoft\Windows NT\CurrentVersion\Keyboard Layout\Preload'
        )
        $values.Count | Should -Be 0
    }
}

Describe 'Get-RegistryValue' {
    It 'returns null for a key that does not exist' {
        Get-RegistryValue -KeyName 'MICPE-NOT-MOUNTED' -SubKey '' -Name '' | Should -BeNullOrEmpty
    }

    It 'returns null for a missing value name on an existing key' {
        Get-RegistryValue -KeyName 'SOFTWARE' -SubKey 'Microsoft' -Name 'MicpeNotAValue' |
            Should -BeNullOrEmpty
    }
}

Describe 'Registry patch files' {
    It 'every .reg file declares the Windows Registry Editor header' {
        $dir = Join-Path $PSScriptRoot '../src/registry'
        if (-not (Test-Path -LiteralPath $dir)) { Set-ItResult -Skipped -Because 'no patch files yet'; return }

        $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.reg' -File)
        foreach ($file in $files) {
            $head = (Get-Content -LiteralPath $file.FullName -TotalCount 1)
            $head | Should -Match 'Windows Registry Editor Version 5\.00'
        }
    }
}

Describe 'WER local dumps registry patch (run 49)' {
    BeforeAll {
        $script:reg60 = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/registry/60-werdumps.reg') -Raw
    }

    It 'writes a WER LocalDumps entry for explorer.exe (mini dump, three kept)' {
        # Run 48: Report.wer alone cannot locate the 0x1181ea call
        # stack — only a minidump can. The LocalDumps key makes
        # WerFault write explorer's dump to X:\CrashDumps when it
        # crashes, so the probe can copy it to the share. CI-time
        # import only (user decision 2026-11-17 23:43); nothing is
        # written to the registry inside PE.
        $script:reg60 | Should -Match 'Windows Error Reporting\\LocalDumps\\explorer\.exe\]' -Because 'the entry is scoped to explorer.exe'
        $script:reg60.Contains('"DumpFolder"="X:\\CrashDumps"') | Should -BeTrue -Because '.reg string syntax needs a doubled backslash for a literal backslash — a lone backslash makes reg.exe silently skip the value while exiting 0 (run 55)'
        $script:reg60.Contains('"DumpFolder"="X:\CrashDumps"') | Should -BeFalse -Because 'a lone backslash is an invalid .reg escape: reg.exe drops the DumpFolder value and the DWORDs land alone (run 55 repro: key existed with DumpCount, DumpType, no DumpFolder)'
        $script:reg60.Contains('"DumpType"=dword:00000001') | Should -BeTrue -Because 'DumpType 1 is a mini dump'
        $script:reg60.Contains('"DumpCount"=dword:00000003') | Should -BeTrue -Because 'DumpCount 3 keeps at most three dumps on the RAM disk'
    }
}

Describe 'feature 42537950 override registry patch (run 50, run 51)' {
    BeforeAll {
        $script:reg70 = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/registry/70-feature-42537950.reg') -Raw
        $script:reg60b = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/registry/60-werdumps.reg') -Raw
    }

    It 'forces DisableWin10Taskbar (42537950) off in all three FeatureManagement groups' {
        # Run 49 root cause: CTray::Init failfasts while this feature is
        # enabled. The image's offline SYSTEM hive holds 330 Overrides
        # and none is 42537950, so the feature runs at its built-in
        # default (enabled). Run 50 wrote the override FLAT under
        # Overrides and the loader ignored it (§36.5.1 — it reads
        # grouped entries only), so run 51 writes it into all three
        # groups (the feature's group is not known offline; writing
        # all three is harmless). PE-SYS addresses the mounted SYSTEM
        # hive (HKLM\SYSTEM would hit the runner). Run 54: run 53
        # wrote EnabledState=0, which is Default, not Disabled
        # (featurestagingapi.h: 0=Default, 1=Disabled, 2=Enabled) —
        # the feature stayed enabled and explorer still died. The
        # patch now writes 1 (Disabled) in all three groups; the
        # disassembly of explorer.exe 10.0.26100.1 confirms IsEnabled
        # is TRUE exactly when the evaluated state is 0 or 2.
        foreach ($group in '0', '15', '9') {
            $script:reg70 | Should -Match "HKEY_LOCAL_MACHINE\\PE-SYS\\ControlSet001\\Control\\FeatureManagement\\Overrides\\$group\\42537950\]" -Because "group $group must carry the override"
        }
        ([regex]::Matches($script:reg70, '"EnabledState"=dword:00000001')).Count | Should -Be 3 -Because 'one Disabled value per group'
        ([regex]::Matches($script:reg70, '"EnabledState"=dword:00000000')).Count | Should -Be 0 -Because '0 is Default, not Disabled — run 53 proved writing 0 leaves the feature enabled'
        ([regex]::Matches($script:reg70, '"EnabledStateOptions"=dword:00000000')).Count | Should -Be 3 -Because 'one options value per group, matching the stock entries'
        $script:reg70 | Should -Not -Match 'HKEY_LOCAL_MACHINE\\PE-SYS\\ControlSet001\\Control\\FeatureManagement\\Overrides\\42537950\]' -Because 'the flat entry is gone on purpose — the loader ignores it'
    }

    It 'addresses the WER LocalDumps key at PE-SOFT, not the runner hive (run 50 correction)' {
        # Run 49: 60-werdumps.reg said HKLM\SOFTWARE, which a plain
        # reg.exe import writes into the RUNNER's live hive — the image
        # never got the LocalDumps key and no dump was written. PE-SOFT
        # addresses the mounted SOFTWARE hive.
        $script:reg60b | Should -Match 'HKEY_LOCAL_MACHINE\\PE-SOFT\\Microsoft\\Windows\\Windows Error Reporting\\LocalDumps\\explorer\.exe\]' -Because 'the key must land in the mounted SOFTWARE hive'
        $script:reg60b | Should -Not -Match 'HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\Windows Error Reporting\\LocalDumps' -Because 'HKLM\SOFTWARE would hit the runner, not the image'
    }
}

Describe 'registry imports happen only at CI build time (user decision 2026-11-17 23:43)' {
    BeforeAll {
        $script:RuntimeFiles = @(
            'src/ci/probe.cmd',
            'src/ci/probe-watchdog.cmd',
            'src/shell/startnet.cmd',
            'src/shell/PECMD.INI',
            'src/shell/Pin-Shortcuts.wcs',
            'src/installer/MICPE-Setup.wcs'
        )
    }

    It 'no PE runtime file imports a .reg or writes the registry' {
        foreach ($rel in $script:RuntimeFiles) {
            $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot "../$rel") -Raw
            $text | Should -Not -Match 'reg import' -Because "$rel runs inside PE and must never import registry patches"
            $text | Should -Not -Match 'reg add' -Because "$rel runs inside PE and must never write registry values"
            $text | Should -Not -Match 'regedit' -Because "$rel runs inside PE and must never invoke regedit"
        }
    }

    It 'probe.cmd only reads the registry (reg query for ime preload and brand OEM values)' {
        $probe = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/ci/probe.cmd') -Raw
        $probe | Should -Match 'reg query'
        $probe | Should -Not -Match 'reg import'
        $probe | Should -Not -Match 'reg add'
    }

    It 'build-time registry writes live only in Registry.ps1 (import) and Uwp.ps1 (mounted-hive reg add)' {
        # DISM /Apply-Image in the installer writes the *target* offline
        # image, not the running PE; it never appears as a reg command.
        $hits = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../src/build') -Recurse -Filter '*.ps1' |
            ForEach-Object {
                $content = Get-Content -LiteralPath $_.FullName -Raw
                if ($content -match '(?m)^\s*\$output = & reg\.exe (import|add)\b') { $_.Name }
            })
        @($hits | Sort-Object -Unique) | Should -Be @('Registry.ps1', 'Uwp.ps1')
    }
}

Describe 'Invoke-RegistryScript SYSTEM routing' {
    It 'imports SystemRegFiles as SYSTEM and the rest as admin' {
        # Mock the hive mount and both import paths; the routing decision
        # is the unit under test, not reg.exe itself.
        Mock Mount-RegistryHive { }
        Mock Dismount-RegistryHive { }
        Mock Import-RegFile { }
        Mock Invoke-RegImportAsSystem { }

        $mount = Join-Path $script:TempRoot "regroute-$(Get-Random)"
        New-Item -ItemType Directory -Force -Path "$mount/Windows/System32/config" | Out-Null
        $regA = Join-Path $mount '10-pe-base.reg'
        $regB = Join-Path $mount '40-uwp.reg'
        Set-Content -LiteralPath $regA -Value 'Windows Registry Editor Version 5.00'
        Set-Content -LiteralPath $regB -Value 'Windows Registry Editor Version 5.00'
        try {
            Invoke-RegistryScript -MountDir $mount -RegFiles @($regA, $regB) -SystemRegFiles @('40-uwp.reg')
            Should -Invoke Invoke-RegImportAsSystem -Times 1 -ParameterFilter { $RegFile -eq $regB }
            Should -Invoke Import-RegFile -Times 1 -ParameterFilter { $RegFile -eq $regA }
        }
        finally {
            Remove-Item -LiteralPath $mount -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reverse control: without the SYSTEM flag the Appx file takes the admin path' {
        Mock Mount-RegistryHive { }
        Mock Dismount-RegistryHive { }
        Mock Import-RegFile { }
        Mock Invoke-RegImportAsSystem { }

        $mount = Join-Path $script:TempRoot "regroute-$(Get-Random)"
        New-Item -ItemType Directory -Force -Path "$mount/Windows/System32/config" | Out-Null
        $regB = Join-Path $mount '40-uwp.reg'
        Set-Content -LiteralPath $regB -Value 'Windows Registry Editor Version 5.00'
        try {
            Invoke-RegistryScript -MountDir $mount -RegFiles @($regB)
            Should -Invoke Invoke-RegImportAsSystem -Times 0
            Should -Invoke Import-RegFile -Times 1 -ParameterFilter { $RegFile -eq $regB }
        }
        finally {
            Remove-Item -LiteralPath $mount -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-RegImportAsSystem' {
    It 'throws a clear error without schtasks.exe (Linux)' -Skip:$IsWindows {
        $reg = Join-Path $script:TempRoot "micpe-sysimport-$(Get-Random).reg"
        Set-Content -LiteralPath $reg -Value 'Windows Registry Editor Version 5.00'
        try {
            { Invoke-RegImportAsSystem -RegFile $reg } | Should -Throw '*schtasks*'
        }
        finally {
            Remove-Item -LiteralPath $reg -Force -ErrorAction SilentlyContinue
        }
    }

    It 'writes a key whose DACL gives Administrators only KEY_READ, where a plain admin import fails (CI run 44040699722)' -Skip:(-not $IsWindows) {
        # Mirror of the real Appx key: snapshot SOFTWARE, mount it, create
        # the Appx key, restrict its DACL (SYSTEM full, Administrators
        # read-only), prove the admin import fails, prove the SYSTEM
        # import succeeds and the values land. The restriction lives only
        # inside the throwaway test hive; the temp dir is deleted after.
        $work = Join-Path $script:TempRoot "appx-sys-$(Get-Random)"
        New-Item -ItemType Directory -Force -Path "$work/Windows/System32/config" | Out-Null
        $hiveCopy = "$work/Windows/System32/config/SOFTWARE"
        $null = & reg.exe save 'HKLM\SOFTWARE' $hiveCopy /y 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'reg save SOFTWARE failed' }
        $keyName = 'MICPE-APPX-TEST'
        # A fresh key name, not the real Appx key: the SOFTWARE snapshot
        # already contains Microsoft\Windows\CurrentVersion\Appx with its
        # live restrictive DACL (run 22), so reg add on it fails for the
        # runner admin before the test can set its own DACL. The DACL
        # shape applied below is the same one (SYSTEM full, Administrators
        # read-only), so the mechanism is still what is being proved.
        $appxSub = 'Microsoft\Windows\CurrentVersion\MicpeAppxTest'
        $testReg = Join-Path $work 'appx-test.reg'
        $regText = @(
            'Windows Registry Editor Version 5.00',
            '',
            ('[HKEY_LOCAL_MACHINE\{0}\{1}]' -f $keyName, $appxSub),
            '"AllowAllTrustedApps"=dword:00000001',
            '"AllowDevelopmentWithoutDevLicense"=dword:00000001',
            ''
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($testReg, $regText, [System.Text.Encoding]::Unicode)
        try {
            Mount-RegistryHive -HiveFile $hiveCopy -KeyName $keyName
            try {
                $addOut = & reg.exe add "HKLM\$keyName\$appxSub" /f 2>&1
                if ($LASTEXITCODE -ne 0) { throw "reg add Appx key failed: $addOut" }

                $regKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
                    "$keyName\$appxSub",
                    [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                    [System.Security.AccessControl.RegistryRights]::ChangePermissions)
                $acl = New-Object System.Security.AccessControl.RegistrySecurity
                $acl.SetAccessRuleProtection($true, $false)
                $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule(
                    'NT AUTHORITY\SYSTEM',
                    [System.Security.AccessControl.RegistryRights]::FullControl,
                    [System.Security.AccessControl.InheritanceFlags]::None,
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow)))
                $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule(
                    'BUILTIN\Administrators',
                    [System.Security.AccessControl.RegistryRights]::ReadKey,
                    [System.Security.AccessControl.InheritanceFlags]::None,
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow)))
                $regKey.SetAccessControl($acl)
                $regKey.Close()

                # Admin import must fail on the restricted key (run 22).
                $null = & reg.exe import $testReg 2>&1
                $LASTEXITCODE | Should -Not -Be 0 -Because 'the restricted DACL must block the admin import, or this test proves nothing'

                # SYSTEM import must succeed through the same DACL.
                { Invoke-RegImportAsSystem -RegFile $testReg } | Should -Not -Throw

                $values = Get-RegistryKeyValues -KeyName $keyName -SubKey $appxSub
                $values | Should -Not -BeNullOrEmpty
                $values['AllowAllTrustedApps'] | Should -Match '^0x0*1$'
                $values['AllowDevelopmentWithoutDevLicense'] | Should -Match '^0x0*1$'
            }
            finally {
                Dismount-RegistryHive -KeyName $keyName
            }
        }
        finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-RegFileDeclaredEntries (.reg section parser, run 55)' {
    It 'parses the real 60-werdumps.reg into one section with three value names' {
        $entries = Get-RegFileDeclaredEntries -RegFile (Join-Path $PSScriptRoot '../src/registry/60-werdumps.reg')
        $entries.Count | Should -Be 1
        $entries[0].KeyPath | Should -Be 'PE-SOFT\Microsoft\Windows\Windows Error Reporting\LocalDumps\explorer.exe'
        $entries[0].Values | Should -Be @('DumpFolder', 'DumpCount', 'DumpType')
    }

    It 'parses the real 40-uwp.reg into six sections, including multi-line hex values' {
        $entries = Get-RegFileDeclaredEntries -RegFile (Join-Path $PSScriptRoot '../src/registry/40-uwp.reg')
        $entries.Count | Should -Be 6
        ($entries | Where-Object { $_.KeyPath -like '*StateRepository\Security' }).Values | Should -Be @('Security')
        ($entries | Where-Object { $_.KeyPath -like '*CurrentVersion\Appx' }).Values |
            Should -Be @('AllowAllTrustedApps', 'AllowDevelopmentWithoutDevLicense')
    }

    It 'records the default value name for @= lines and skips comments and blank lines' {
        $reg = Join-Path $script:TempRoot "micpe-declared-$(Get-Random).reg"
        $text = @(
            'Windows Registry Editor Version 5.00',
            '',
            '; a comment',
            '[HKEY_LOCAL_MACHINE\PE-SOFT\Microsoft\Windows\Test]',
            '@="default data"',
            '"Named"=dword:00000001',
            ''
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($reg, $text, [System.Text.Encoding]::Unicode)
        try {
            $entries = Get-RegFileDeclaredEntries -RegFile $reg
            $entries.Count | Should -Be 1
            $entries[0].Values | Should -Be @('(Default)', 'Named')
        }
        finally {
            Remove-Item -LiteralPath $reg -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws on a section addressing a live hive root (run 50 lesson)' {
        $reg = Join-Path $script:TempRoot "micpe-declared-live-$(Get-Random).reg"
        $text = @(
            'Windows Registry Editor Version 5.00',
            '',
            '[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\Test]',
            '"Named"=dword:00000001',
            ''
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($reg, $text, [System.Text.Encoding]::Unicode)
        try {
            { Get-RegFileDeclaredEntries -RegFile $reg } | Should -Throw '*live*'
        }
        finally {
            Remove-Item -LiteralPath $reg -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'SYSTEM import of the real 60-werdumps.reg lands the values (run 55 repro)' {
    BeforeAll {
        $script:werReg60 = Join-Path $PSScriptRoot '../src/registry/60-werdumps.reg'
        $script:werSub = 'Microsoft\Windows\Windows Error Reporting\LocalDumps\explorer.exe'
        $script:werParent = 'Microsoft\Windows\Windows Error Reporting\LocalDumps'
    }

    It 'imports the real 60-werdumps.reg as SYSTEM into a scratch hive and reads all three values back' -Skip:(-not $IsWindows) {
        # Run 54: the import exited 0 while the values never landed
        # (key existed, DumpFolder did not). Run 55 reproduced it
        # here and pinned the mechanism: the file's DumpFolder line
        # had a lone backslash ("X:\CrashDumps"), which reg.exe
        # silently skips while writing the DWORDs and exiting 0.
        # The file now doubles the backslash, so this test is the
        # regression test that the fixed file lands all three values.
        # Same call shape the Build makes — a snapshot of the runner
        # SOFTWARE hive mounted as PE-SOFT, LocalDumps removed first
        # so the import must create the intermediate keys, exactly
        # like the stock image where LocalDumps does not exist.
        $work = Join-Path $script:TempRoot "wer-sys-$(Get-Random)"
        New-Item -ItemType Directory -Force -Path "$work/Windows/System32/config" | Out-Null
        $hiveCopy = "$work/Windows/System32/config/SOFTWARE"
        $null = & reg.exe save 'HKLM\SOFTWARE' $hiveCopy /y 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'reg save SOFTWARE failed' }
        try {
            Mount-RegistryHive -HiveFile $hiveCopy -KeyName 'PE-SOFT'
            try {
                $null = & reg.exe delete "HKLM\PE-SOFT\$($script:werParent)" /f 2>&1
                (Get-RegistryKeyValues -KeyName 'PE-SOFT' -SubKey $script:werSub) | Should -BeNullOrEmpty -Because 'the test hive must match the stock image: no LocalDumps key before the import'

                $importError = $null
                try { Invoke-RegImportAsSystem -RegFile $script:werReg60 } catch { $importError = $_ }
                $dump = & reg.exe query "HKLM\PE-SOFT\$($script:werParent)" /s 2>&1 | Out-String
                Write-Host "LocalDumps subtree after SYSTEM import:`n$($dump.Trim())"
                if ($importError) { throw $importError }

                $values = Get-RegistryKeyValues -KeyName 'PE-SOFT' -SubKey $script:werSub
                $values | Should -Not -BeNullOrEmpty -Because 'the key must exist after the import'
                $values['DumpFolder'] | Should -Be 'X:\CrashDumps'
                $values['DumpCount'] | Should -Match '^0x0*3$'
                $values['DumpType'] | Should -Match '^0x0*1$'
            }
            finally {
                Dismount-RegistryHive -KeyName 'PE-SOFT'
            }
        }
        finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'admin import of the same file lands the values (bisect: SYSTEM task vs reg.exe)' -Skip:(-not $IsWindows) {
        # If the admin import lands while the SYSTEM import does
        # not, the mechanism lives in the scheduled-task path; if
        # both fail, it lives in reg.exe plus the file/hive shape.
        $work = Join-Path $script:TempRoot "wer-admin-$(Get-Random)"
        New-Item -ItemType Directory -Force -Path "$work/Windows/System32/config" | Out-Null
        $hiveCopy = "$work/Windows/System32/config/SOFTWARE"
        $null = & reg.exe save 'HKLM\SOFTWARE' $hiveCopy /y 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'reg save SOFTWARE failed' }
        try {
            Mount-RegistryHive -HiveFile $hiveCopy -KeyName 'PE-SOFT'
            try {
                $null = & reg.exe delete "HKLM\PE-SOFT\$($script:werParent)" /f 2>&1
                $importOut = & reg.exe import $script:werReg60 2>&1 | Out-String
                $LASTEXITCODE | Should -Be 0 -Because "the admin import must succeed: $importOut"
                $dump = & reg.exe query "HKLM\PE-SOFT\$($script:werParent)" /s 2>&1 | Out-String
                Write-Host "LocalDumps subtree after admin import:`n$($dump.Trim())"
                $values = Get-RegistryKeyValues -KeyName 'PE-SOFT' -SubKey $script:werSub
                $values | Should -Not -BeNullOrEmpty
                $values['DumpFolder'] | Should -Be 'X:\CrashDumps'
                $values['DumpCount'] | Should -Match '^0x0*3$'
                $values['DumpType'] | Should -Match '^0x0*1$'
            }
            finally {
                Dismount-RegistryHive -KeyName 'PE-SOFT'
            }
        }
        finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'SYSTEM import lands the values when the parent keys already exist (bisect: missing parents)' -Skip:(-not $IsWindows) {
        # If pre-creating LocalDumps\explorer.exe makes the SYSTEM
        # import land while the repro fails, the mechanism is the
        # creation of the intermediate keys, not the values.
        $work = Join-Path $script:TempRoot "wer-parents-$(Get-Random)"
        New-Item -ItemType Directory -Force -Path "$work/Windows/System32/config" | Out-Null
        $hiveCopy = "$work/Windows/System32/config/SOFTWARE"
        $null = & reg.exe save 'HKLM\SOFTWARE' $hiveCopy /y 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'reg save SOFTWARE failed' }
        try {
            Mount-RegistryHive -HiveFile $hiveCopy -KeyName 'PE-SOFT'
            try {
                $null = & reg.exe delete "HKLM\PE-SOFT\$($script:werParent)" /f 2>&1
                $addOut = & reg.exe add "HKLM\PE-SOFT\$($script:werSub)" /f 2>&1
                if ($LASTEXITCODE -ne 0) { throw "reg add explorer.exe key failed: $addOut" }
                { Invoke-RegImportAsSystem -RegFile $script:werReg60 } | Should -Not -Throw
                $values = Get-RegistryKeyValues -KeyName 'PE-SOFT' -SubKey $script:werSub
                $values | Should -Not -BeNullOrEmpty
                $values['DumpFolder'] | Should -Be 'X:\CrashDumps'
                $values['DumpCount'] | Should -Match '^0x0*3$'
                $values['DumpType'] | Should -Match '^0x0*1$'
            }
            finally {
                Dismount-RegistryHive -KeyName 'PE-SOFT'
            }
        }
        finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'SYSTEM import of a line-ending-normalized copy lands (bisect: mixed CRLF/LF)' -Skip:(-not $IsWindows) {
        # 60-werdumps.reg mixes CRLF (13 lines) with LF (6 lines);
        # 40-uwp.reg is LF-only and lands. If the normalized copy
        # lands while the real file fails, the endings are the
        # mechanism; if both fail the same way, endings are excluded.
        $work = Join-Path $script:TempRoot "wer-eol-$(Get-Random)"
        New-Item -ItemType Directory -Force -Path "$work/Windows/System32/config" | Out-Null
        $hiveCopy = "$work/Windows/System32/config/SOFTWARE"
        $null = & reg.exe save 'HKLM\SOFTWARE' $hiveCopy /y 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'reg save SOFTWARE failed' }
        $normReg = Join-Path $work '60-werdumps-lf.reg'
        $text = [System.IO.File]::ReadAllText($script:werReg60, [System.Text.Encoding]::Unicode)
        [System.IO.File]::WriteAllText($normReg, ($text -split "`r`n|`n" -join "`n"), [System.Text.Encoding]::Unicode)
        try {
            Mount-RegistryHive -HiveFile $hiveCopy -KeyName 'PE-SOFT'
            try {
                $null = & reg.exe delete "HKLM\PE-SOFT\$($script:werParent)" /f 2>&1
                { Invoke-RegImportAsSystem -RegFile $normReg } | Should -Not -Throw
                $values = Get-RegistryKeyValues -KeyName 'PE-SOFT' -SubKey $script:werSub
                $values | Should -Not -BeNullOrEmpty
                $values['DumpFolder'] | Should -Be 'X:\CrashDumps'
                $values['DumpCount'] | Should -Match '^0x0*3$'
                $values['DumpType'] | Should -Match '^0x0*1$'
            }
            finally {
                Dismount-RegistryHive -KeyName 'PE-SOFT'
            }
        }
        finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'a lone backslash in a REG_SZ value is silently dropped by reg.exe (mechanism, run 55)' -Skip:(-not $IsWindows) {
        # The rule the repro pinned: in .reg string values a
        # backslash must be doubled for a literal backslash. A file
        # with a lone backslash ("X:\CrashDumps") imports with exit
        # 0, writes the DWORDs, and silently drops the string value
        # — the read-back in Invoke-RegImportAsSystem is what turns
        # that into a loud failure instead of a silent miss.
        $work = Join-Path $script:TempRoot "wer-bs-$(Get-Random)"
        New-Item -ItemType Directory -Force -Path "$work/Windows/System32/config" | Out-Null
        $hiveCopy = "$work/Windows/System32/config/SOFTWARE"
        $null = & reg.exe save 'HKLM\SOFTWARE' $hiveCopy /y 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'reg save SOFTWARE failed' }
        $singleReg = Join-Path $work 'single-bs.reg'
        $regText = @(
            'Windows Registry Editor Version 5.00',
            '',
            '[HKEY_LOCAL_MACHINE\PE-SOFT\Microsoft\Windows\Windows Error Reporting\LocalDumps\explorer.exe]',
            '"DumpFolder"="X:\CrashDumps"',
            '"DumpCount"=dword:00000003',
            '"DumpType"=dword:00000001',
            ''
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($singleReg, $regText, [System.Text.Encoding]::Unicode)
        try {
            Mount-RegistryHive -HiveFile $hiveCopy -KeyName 'PE-SOFT'
            try {
                $null = & reg.exe delete "HKLM\PE-SOFT\$($script:werParent)" /f 2>&1
                { Invoke-RegImportAsSystem -RegFile $singleReg } | Should -Throw '*DumpFolder*missing*'
                # The DWORDs still land — only the string is dropped,
                # which is why the miss stayed silent until the
                # read-back existed.
                $values = Get-RegistryKeyValues -KeyName 'PE-SOFT' -SubKey $script:werSub
                $values | Should -Not -BeNullOrEmpty
                $values['DumpCount'] | Should -Match '^0x0*3$'
                $values['DumpType'] | Should -Match '^0x0*1$'
                $values.Contains('DumpFolder') | Should -BeFalse
            }
            finally {
                Dismount-RegistryHive -KeyName 'PE-SOFT'
            }
        }
        finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Assert-RegImportLanded throws when a declared value is missing' -Skip:(-not $IsWindows) {
        # The read-back must fail loudly on a miss, not pass a
        # half-landed import. No import runs here: the declared key
        # simply does not exist in the scratch hive.
        $work = Join-Path $script:TempRoot "wer-assert-$(Get-Random)"
        New-Item -ItemType Directory -Force -Path "$work/Windows/System32/config" | Out-Null
        $hiveCopy = "$work/Windows/System32/config/SOFTWARE"
        $null = & reg.exe save 'HKLM\SOFTWARE' $hiveCopy /y 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'reg save SOFTWARE failed' }
        $testReg = Join-Path $work 'missing.reg'
        $regText = @(
            'Windows Registry Editor Version 5.00',
            '',
            '[HKEY_LOCAL_MACHINE\PE-SOFT\Microsoft\Windows\MicpeNotThere]',
            '"NoSuchValue"=dword:00000001',
            ''
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($testReg, $regText, [System.Text.Encoding]::Unicode)
        try {
            Mount-RegistryHive -HiveFile $hiveCopy -KeyName 'PE-SOFT'
            try {
                { Assert-RegImportLanded -RegFile $testReg } | Should -Throw '*does not exist*'
            }
            finally {
                Dismount-RegistryHive -KeyName 'PE-SOFT'
            }
        }
        finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'ConvertFrom-RegFile (privileged registry writer, run 52)' {
    It 'parses the real 70-feature patch into three grouped overrides, all disabled' {
        # The .reg file is the single source of truth for the privileged
        # writer: it parses the patch instead of duplicating the values
        # in code, so a drift between file and writer cannot land half
        # a patch.
        $entries = ConvertFrom-RegFile -Path (Join-Path $PSScriptRoot '../src/registry/70-feature-42537950.reg') -HiveKey 'PE-SYS'
        $entries.Count | Should -Be 3 -Because 'one override per group (0, 15, 9)'
        foreach ($group in '0', '15', '9') {
            $entry = @($entries | Where-Object { $_.KeyPath -eq "PE-SYS\ControlSet001\Control\FeatureManagement\Overrides\$group\42537950" })
            $entry.Count | Should -Be 1 -Because "group $group must carry the override"
            $entry[0].Values['EnabledState'] | Should -Be 1 -Because 'EnabledState 1 disables the feature (0 is Default, not Disabled — run 54)'
            $entry[0].Values['EnabledStateOptions'] | Should -Be 0 -Because 'options 0 matches the stock entries'
        }
    }

    It 'throws on a non-DWORD value instead of silently skipping it' {
        $reg = Join-Path $script:TempRoot "micpe-privparse-$(Get-Random).reg"
        $text = @(
            'Windows Registry Editor Version 5.00',
            '',
            '[HKEY_LOCAL_MACHINE\PE-SYS\ControlSet001\Control\FeatureManagement\Overrides\0\42537950]',
            '"EnabledState"="0"',
            ''
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($reg, $text, [System.Text.Encoding]::Unicode)
        try {
            { ConvertFrom-RegFile -Path $reg -HiveKey 'PE-SYS' } | Should -Throw '*unsupported*'
        }
        finally {
            Remove-Item -LiteralPath $reg -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws on a section outside the mounted hive (never write the runner hive)' {
        # Run 50 lesson: 60-werdumps.reg once said HKLM\SOFTWARE and a
        # plain import wrote into the runner's live hive instead of the
        # image. The privileged writer refuses any section that does not
        # address the mounted hive.
        $reg = Join-Path $script:TempRoot "micpe-privparse-$(Get-Random).reg"
        $text = @(
            'Windows Registry Editor Version 5.00',
            '',
            '[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\0\42537950]',
            '"EnabledState"=dword:00000000',
            ''
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($reg, $text, [System.Text.Encoding]::Unicode)
        try {
            { ConvertFrom-RegFile -Path $reg -HiveKey 'PE-SYS' } | Should -Throw '*outside the mounted hive*'
        }
        finally {
            Remove-Item -LiteralPath $reg -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws when the patch file is missing' {
        { ConvertFrom-RegFile -Path (Join-Path $script:TempRoot 'micpe-absent.reg') -HiveKey 'PE-SYS' } |
            Should -Throw '*not found*'
    }

    It 'compiles the backup/restore P/Invoke helper (advapi32, run 52)' {
        # The C# only declares DllImports; compiling it on Linux proves
        # the signatures are well-formed without needing a Windows host
        # or the privileges. The actual write is proven by the
        # Windows-only test below and by the Build verification.
        Initialize-PrivilegedRegistryApi
        ([System.Management.Automation.PSTypeName]'MicpePrivilegedRegistry').Type |
            Should -Not -BeNullOrEmpty
    }
}

Describe 'MicpePrivilegedRegistry struct layouts (run 53)' {
    It 'SECURITY_DESCRIPTOR is 40 bytes on x64 (the run 52 heap corruption)' {
        # Absolute-format SECURITY_DESCRIPTOR: 4-byte header + 4
        # pointers. The run 52 code allocated 20 bytes (the x86 size),
        # so InitializeSecurityDescriptor wrote 20 bytes past the
        # buffer on every CreateKeyWithDacl and corrupted the heap;
        # run 53 reproduced it deterministically, crashing on the third
        # call with STATUS_HEAP_CORRUPTION. The writer now sizes the
        # buffer from this struct.
        Initialize-PrivilegedRegistryApi
        $apiType = ([System.Management.Automation.PSTypeName]'MicpePrivilegedRegistry').Type
        # The [type] cast matters: without it PowerShell binds
        # Marshal.SizeOf to the object overload and fails.
        $size = [System.Runtime.InteropServices.Marshal]::SizeOf([type]$apiType.GetNestedType('SECURITY_DESCRIPTOR'))
        if ([System.IntPtr]::Size -eq 8) { $size | Should -Be 40 } else { $size | Should -Be 20 }
    }

    It 'SECURITY_ATTRIBUTES is 24 bytes on x64 (audit of the same call)' {
        Initialize-PrivilegedRegistryApi
        $apiType = ([System.Management.Automation.PSTypeName]'MicpePrivilegedRegistry').Type
        # The [type] cast matters: without it PowerShell binds
        # Marshal.SizeOf to the object overload and fails.
        $size = [System.Runtime.InteropServices.Marshal]::SizeOf([type]$apiType.GetNestedType('SECURITY_ATTRIBUTES'))
        if ([System.IntPtr]::Size -eq 8) { $size | Should -Be 24 } else { $size | Should -Be 12 }
    }
}

Describe 'Write-PrivProgress (crash breadcrumbs, run 53)' {
    It 'appends progress lines to the progress file when MICPE_PRIV_PROGRESS is set' {
        # The writer's host output is lost when its process crashes
        # (run 52: heap corruption, empty import log), so each step
        # also lands in the progress file as a synchronous write.
        $progress = Join-Path $script:TempRoot "micpe-privprogress-$(Get-Random).txt"
        try {
            $env:MICPE_PRIV_PROGRESS = $progress
            Write-PrivProgress 'test breadcrumb'
            Test-Path -LiteralPath $progress | Should -Be $true
            (Get-Content -LiteralPath $progress -Raw) | Should -Match 'test breadcrumb'
        }
        finally {
            Remove-Item Env:MICPE_PRIV_PROGRESS -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $progress -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reverse control: without MICPE_PRIV_PROGRESS no file is created' {
        Remove-Item Env:MICPE_PRIV_PROGRESS -ErrorAction SilentlyContinue
        $progress = Join-Path $script:TempRoot "micpe-privprogress-$(Get-Random).txt"
        Write-PrivProgress 'test breadcrumb'
        Test-Path -LiteralPath $progress | Should -Be $false
    }
}

Describe 'Invoke-RegistryScript privileged routing' {
    It 'routes privileged files to the privileged writer, SYSTEM files to SYSTEM, the rest to admin' {
        # Mock the hive mount and all three import paths; the routing
        # decision is the unit under test, not reg.exe itself.
        Mock Mount-RegistryHive { }
        Mock Dismount-RegistryHive { }
        Mock Import-RegFile { }
        Mock Invoke-RegImportAsSystem { }
        Mock Invoke-RegImportPrivileged { }

        $mount = Join-Path $script:TempRoot "regpriv-$(Get-Random)"
        New-Item -ItemType Directory -Force -Path "$mount/Windows/System32/config" | Out-Null
        $regA = Join-Path $mount '10-pe-base.reg'
        $regB = Join-Path $mount '40-uwp.reg'
        $regC = Join-Path $mount '70-feature-42537950.reg'
        Set-Content -LiteralPath $regA -Value 'Windows Registry Editor Version 5.00'
        Set-Content -LiteralPath $regB -Value 'Windows Registry Editor Version 5.00'
        Set-Content -LiteralPath $regC -Value 'Windows Registry Editor Version 5.00'
        try {
            Invoke-RegistryScript -MountDir $mount -RegFiles @($regA, $regB, $regC) -SystemRegFiles @('40-uwp.reg') -PrivilegedRegFiles @('70-feature-42537950.reg')
            Should -Invoke Invoke-RegImportPrivileged -Times 1 -ParameterFilter { $RegFile -eq $regC -and $HiveKey -eq 'PE-SYS' }
            Should -Invoke Invoke-RegImportAsSystem -Times 1 -ParameterFilter { $RegFile -eq $regB }
            Should -Invoke Import-RegFile -Times 1 -ParameterFilter { $RegFile -eq $regA }
        }
        finally {
            Remove-Item -LiteralPath $mount -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reverse control: without the privileged flag the feature file takes the SYSTEM path' {
        Mock Mount-RegistryHive { }
        Mock Dismount-RegistryHive { }
        Mock Import-RegFile { }
        Mock Invoke-RegImportAsSystem { }
        Mock Invoke-RegImportPrivileged { }

        $mount = Join-Path $script:TempRoot "regpriv-$(Get-Random)"
        New-Item -ItemType Directory -Force -Path "$mount/Windows/System32/config" | Out-Null
        $regC = Join-Path $mount '70-feature-42537950.reg'
        Set-Content -LiteralPath $regC -Value 'Windows Registry Editor Version 5.00'
        try {
            Invoke-RegistryScript -MountDir $mount -RegFiles @($regC) -SystemRegFiles @('70-feature-42537950.reg')
            Should -Invoke Invoke-RegImportPrivileged -Times 0
            Should -Invoke Invoke-RegImportAsSystem -Times 1 -ParameterFilter { $RegFile -eq $regC }
            Should -Invoke Import-RegFile -Times 0
        }
        finally {
            Remove-Item -LiteralPath $mount -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-RegImportPrivileged' {
    It 'throws a clear error without schtasks.exe (Linux)' -Skip:$IsWindows {
        $reg = Join-Path $script:TempRoot "micpe-privimport-$(Get-Random).reg"
        Set-Content -LiteralPath $reg -Value 'Windows Registry Editor Version 5.00'
        try {
            { Invoke-RegImportPrivileged -RegFile $reg -HiveKey 'PE-SYS' } | Should -Throw '*schtasks*'
        }
        finally {
            Remove-Item -LiteralPath $reg -Force -ErrorAction SilentlyContinue
        }
    }

    It 'writes all three groups whose DACL gives SYSTEM only KEY_READ, where the SYSTEM import fails (run 51, heap-corruption triage run 53)' -Skip:(-not $IsWindows) {
        # Mirror of the Appx SYSTEM-import test, with the run 51 DACL
        # shape instead: the group key gives SYSTEM only ReadKey, so
        # both the plain admin import and the SYSTEM import must fail,
        # and only the backup/restore write lands the values. The
        # restriction lives only inside the throwaway test hive; the
        # temp dir is deleted after.
        #
        # Run 53: the patch carries all three groups (0, 15, 9) — the
        # real 70-feature shape, not one group. Production calls
        # CreateKeyWithDacl three times in one privileged import and
        # run 52 died with STATUS_HEAP_CORRUPTION before the first
        # value landed, while the 1-group test only ever made one
        # call; this test makes the call shape match production so a
        # deterministic heap bug reproduces here instead of in a Build.
        $work = Join-Path $script:TempRoot "priv-sys-$(Get-Random)"
        New-Item -ItemType Directory -Force -Path "$work/Windows/System32/config" | Out-Null
        $hiveCopy = "$work/Windows/System32/config/SOFTWARE"
        $null = & reg.exe save 'HKLM\SOFTWARE' $hiveCopy /y 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'reg save SOFTWARE failed' }
        $keyName = 'MICPE-PRIV-TEST'
        $groupBase = 'Control\FeatureManagement\Overrides'
        $groups = @('0', '15', '9')
        $regLines = @('Windows Registry Editor Version 5.00', '')
        foreach ($group in $groups) {
            $regLines += ('[HKEY_LOCAL_MACHINE\{0}\{1}\{2}\42537950]' -f $keyName, $groupBase, $group)
            $regLines += '"EnabledState"=dword:00000000'
            $regLines += '"EnabledStateOptions"=dword:00000000'
            $regLines += ''
        }
        $testReg = Join-Path $work 'priv-test.reg'
        [System.IO.File]::WriteAllText($testReg, ($regLines -join "`r`n"), [System.Text.Encoding]::Unicode)
        try {
            Mount-RegistryHive -HiveFile $hiveCopy -KeyName $keyName
            try {
                foreach ($group in $groups) {
                    $groupSub = "$groupBase\$group"
                    $addOut = & reg.exe add "HKLM\$keyName\$groupSub" /f 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "reg add group key $group failed: $addOut" }

                    $regKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
                        "$keyName\$groupSub",
                        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                        [System.Security.AccessControl.RegistryRights]::ChangePermissions)
                    $acl = New-Object System.Security.AccessControl.RegistrySecurity
                    $acl.SetAccessRuleProtection($true, $false)
                    $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule(
                        'NT AUTHORITY\SYSTEM',
                        [System.Security.AccessControl.RegistryRights]::ReadKey,
                        [System.Security.AccessControl.InheritanceFlags]::None,
                        [System.Security.AccessControl.PropagationFlags]::None,
                        [System.Security.AccessControl.AccessControlType]::Allow)))
                    $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule(
                        'BUILTIN\Administrators',
                        [System.Security.AccessControl.RegistryRights]::ReadKey,
                        [System.Security.AccessControl.InheritanceFlags]::None,
                        [System.Security.AccessControl.PropagationFlags]::None,
                        [System.Security.AccessControl.AccessControlType]::Allow)))
                    $regKey.SetAccessControl($acl)
                    $regKey.Close()
                }

                # Admin import must fail on the restricted keys (run 51:
                # the group keys give nobody a write right except the
                # Feature Management service account).
                $null = & reg.exe import $testReg 2>&1
                $LASTEXITCODE | Should -Not -Be 0 -Because 'the restricted DACLs must block the admin import, or this test proves nothing'

                # SYSTEM import must fail the same way (run 51 repro:
                # SYSTEM has only KEY_READ on the group keys).
                { Invoke-RegImportAsSystem -RegFile $testReg } | Should -Throw '*Error accessing the registry*'

                # The backup/restore write must succeed through the
                # same DACLs, without changing them — three
                # CreateKeyWithDacl calls in one process, like the real
                # Build (run 52 heap-corruption triage).
                { Invoke-RegImportPrivileged -RegFile $testReg -HiveKey $keyName } | Should -Not -Throw

                # Diagnostic: show exactly what exists under the
                # Overrides key after the privileged write, so a
                # read-back miss says whether the write went elsewhere
                # (or nowhere).
                $dump = & reg.exe query "HKLM\$keyName\$groupBase" /s 2>&1 | Out-String
                Write-Host "Overrides subtree after privileged import:`n$dump"

                foreach ($group in $groups) {
                    $values = Get-RegistryKeyValues -KeyName $keyName -SubKey "$groupBase\$group\42537950"
                    $values | Should -Not -BeNullOrEmpty -Because "group $group must carry the override"
                    $values['EnabledState'] | Should -Match '^0x0*0$'
                    $values['EnabledStateOptions'] | Should -Match '^0x0*0$'
                }
            }
            finally {
                Dismount-RegistryHive -KeyName $keyName
            }
        }
        finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'EnterpriseTempControls 42537950 patch (run 58)' {
    BeforeAll {
        $script:etcReg = Join-Path $PSScriptRoot '../src/registry/80-etc-42537950.reg'
        $script:etcSub = 'ControlSet001\Control\FeatureManagement\EnterpriseTempControls\2208259724'
    }

    It 'parses the real 80-etc patch into one entry: feature 42537950 = 1 (Disabled) in the active temp config' {
        # The .reg file is the single source of truth for the privileged
        # writer: it parses the patch instead of duplicating the values
        # in code, so a drift between file and writer cannot land half
        # a patch. One entry only — the active config 2208259724 is
        # empty in the stock image, so this feature has no entry there
        # until the writer adds it. Value 1 = Disabled per
        # FEATURE_ENABLED_STATE (0 = Default, 1 = Disabled,
        # 2 = Enabled — run 54, Microsoft Learn); the enum match is
        # the best-supported hypothesis, and the Build result
        # (fm_etc_feature read-back + explorer's fate) is the test.
        $entries = ConvertFrom-RegFile -Path $script:etcReg -HiveKey 'PE-SYS'
        $entries.Count | Should -Be 1 -Because 'the patch writes exactly one value into the active temp config'
        $entries[0].KeyPath | Should -Be "PE-SYS\ControlSet001\Control\FeatureManagement\EnterpriseTempControls\2208259724"
        $entries[0].Values.Count | Should -Be 1 -Because 'one value only; no string values, so no lone-backslash risk (run 55)'
        $entries[0].Values['42537950'] | Should -Be 1 -Because '42537950 = 1 disables DisableWin10Taskbar in the temp layer'
    }

    It 'the DACL save/write/restore API is compiled (GetKeySecurityDacl / SetKeySecurityDacl / SetTransientSystemDacl)' {
        # The C# only declares DllImports and methods; compiling it on
        # Linux proves the signatures are well-formed without needing a
        # Windows host or the privileges. The actual write is proven by
        # the Windows-only test below and by the Build verification.
        Initialize-PrivilegedRegistryApi
        $apiType = ([System.Management.Automation.PSTypeName]'MicpePrivilegedRegistry').Type
        $apiType.GetMethod('GetKeySecurityDacl') | Should -Not -BeNullOrEmpty -Because 'the save step reads the stock DACL'
        $apiType.GetMethod('SetKeySecurityDacl') | Should -Not -BeNullOrEmpty -Because 'the restore step writes the saved DACL back'
        $apiType.GetMethod('SetTransientSystemDacl') | Should -Not -BeNullOrEmpty -Because 'the transient step grants SYSTEM while the value is written'
    }

    It 'Test-RegistryDaclEqual ignores the auto-inherited flag but not ACEs or protection' {
        # Pure string logic, runs on Linux. CI run 44709227930: the
        # kernel cleared AI when it stored a protected DACL (saved
        # D:PAI, restored D:P, same ACEs) — that restore is identical.
        # A different ACE, or a dropped protection flag, is not.
        Test-RegistryDaclEqual -SavedSddl 'D:PAI(A;;KR;;;SY)(A;;KR;;;BA)' -RestoredSddl 'D:P(A;;KR;;;SY)(A;;KR;;;BA)' | Should -BeTrue -Because 'only the auto-inherited flag differs; the policy is the same'
        Test-RegistryDaclEqual -SavedSddl 'D:P(A;;KR;;;SY)(A;;KR;;;BA)' -RestoredSddl 'D:P(A;;KR;;;SY)' | Should -BeFalse -Because 'a missing ACE changes the policy'
        Test-RegistryDaclEqual -SavedSddl 'D:P(A;;KR;;;SY)(A;;KR;;;BA)' -RestoredSddl 'D:AI(A;;KR;;;SY)(A;;KR;;;BA)' | Should -BeFalse -Because 'dropping protection would let the key inherit its parent DACL'
        Test-RegistryDaclEqual -SavedSddl 'D:P(A;;KR;;;SY)(A;;KR;;;BA)' -RestoredSddl 'D:P(A;;KR;;;BA)(A;;KR;;;SY)' | Should -BeFalse -Because 'ACE order is part of the policy'
    }

    It 'writes the value into a SYSTEM ReadKey-only ETC key through the DACL flow and restores the stock DACL (same ACEs and protection)' -Skip:(-not $IsWindows) {
        # Mirror of the run 51 privileged test, with the run 58 ETC
        # shape: the active temp config key gives SYSTEM only ReadKey
        # (0x00020019, verified against the stock SYSTEM hive), so
        # both the plain admin import and the SYSTEM import must fail,
        # and only the DACL save/write/restore flow lands the value.
        # The real 80-etc file runs here, against a scratch hive
        # mounted as PE-SYS — the production key name — so the file,
        # the writer and the read-back assert all take the production
        # path. The DACL is compared before and after as SDDL: the
        # shipped image must keep the stock DACL, with only the one
        # DWORD new.
        $work = Join-Path $script:TempRoot "etc-priv-$(Get-Random)"
        New-Item -ItemType Directory -Force -Path "$work/Windows/System32/config" | Out-Null
        $hiveCopy = "$work/Windows/System32/config/SOFTWARE"
        $null = & reg.exe save 'HKLM\SOFTWARE' $hiveCopy /y 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'reg save SOFTWARE failed' }
        $keyName = 'PE-SYS'
        try {
            Mount-RegistryHive -HiveFile $hiveCopy -KeyName $keyName
            try {
                $addOut = & reg.exe add "HKLM\$keyName\$($script:etcSub)" /f 2>&1
                if ($LASTEXITCODE -ne 0) { throw "reg add ETC key failed: $addOut" }

                $regKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
                    "$keyName\$($script:etcSub)",
                    [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                    [System.Security.AccessControl.RegistryRights]::ChangePermissions)
                $acl = New-Object System.Security.AccessControl.RegistrySecurity
                $acl.SetAccessRuleProtection($true, $false)
                $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule(
                    'NT AUTHORITY\SYSTEM',
                    [System.Security.AccessControl.RegistryRights]::ReadKey,
                    [System.Security.AccessControl.InheritanceFlags]::None,
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow)))
                $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule(
                    'BUILTIN\Administrators',
                    [System.Security.AccessControl.RegistryRights]::ReadKey,
                    [System.Security.AccessControl.InheritanceFlags]::None,
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow)))
                $regKey.SetAccessControl($acl)
                $sddlBefore = $regKey.GetAccessControl().GetSecurityDescriptorSddlForm('Access')
                $regKey.Close()

                # Admin import must fail on the restricted key (the
                # stock ETC key gives nobody a write right except the
                # Feature Management service account).
                $null = & reg.exe import $script:etcReg 2>&1
                $LASTEXITCODE | Should -Not -Be 0 -Because 'the restricted DACL must block the admin import, or this test proves nothing'

                # SYSTEM import must fail the same way (run 51 repro:
                # SYSTEM has only KEY_READ on the ETC key).
                { Invoke-RegImportAsSystem -RegFile $script:etcReg } | Should -Throw '*Error accessing the registry*'

                # The DACL save/write/restore flow must succeed
                # through the same DACL, and the read-back assert
                # inside the privileged import must pass.
                { Invoke-RegImportPrivileged -RegFile $script:etcReg -HiveKey $keyName } | Should -Not -Throw

                $dump = & reg.exe query "HKLM\$keyName\$($script:etcSub)" /s 2>&1 | Out-String
                Write-Host "ETC key after privileged import:`n$dump"

                $values = Get-RegistryKeyValues -KeyName $keyName -SubKey $script:etcSub
                $values | Should -Not -BeNullOrEmpty -Because 'the active temp config must carry the value after the import'
                $values['42537950'] | Should -Match '^0x0*1$' -Because '42537950 = 1 disables the feature'

                $regKeyAfter = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
                    "$keyName\$($script:etcSub)",
                    [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree,
                    [System.Security.AccessControl.RegistryRights]::ReadPermissions)
                $sddlAfter = $regKeyAfter.GetAccessControl().GetSecurityDescriptorSddlForm('Access')
                $regKeyAfter.Close()
                # Same comparison the writer uses: the ACE list plus
                # the protection flag. A raw SDDL string comparison
                # would fail on the auto-inherited flag the kernel
                # clears when it stores a protected DACL (CI run
                # 44709227930: saved D:PAI, restored D:P, same ACEs).
                (Test-RegistryDaclEqual -SavedSddl $sddlBefore -RestoredSddl $sddlAfter) | Should -BeTrue -Because 'the DACL save/write/restore flow must leave the stock DACL identical; only the value is new'
            }
            finally {
                Dismount-RegistryHive -KeyName $keyName
            }
        }
        finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-RegistryScript privileged routing for the ETC patch (run 58)' {
    It 'routes the 80-etc file to the privileged writer' {
        # Mock the hive mount and all three import paths; the routing
        # decision is the unit under test, not reg.exe itself.
        Mock Mount-RegistryHive { }
        Mock Dismount-RegistryHive { }
        Mock Import-RegFile { }
        Mock Invoke-RegImportAsSystem { }
        Mock Invoke-RegImportPrivileged { }

        $mount = Join-Path $script:TempRoot "regpriv-etc-$(Get-Random)"
        New-Item -ItemType Directory -Force -Path "$mount/Windows/System32/config" | Out-Null
        $regEtc = Join-Path $mount '80-etc-42537950.reg'
        Set-Content -LiteralPath $regEtc -Value 'Windows Registry Editor Version 5.00'
        try {
            Invoke-RegistryScript -MountDir $mount -RegFiles @($regEtc) -PrivilegedRegFiles @('80-etc-42537950.reg')
            Should -Invoke Invoke-RegImportPrivileged -Times 1 -ParameterFilter { $RegFile -eq $regEtc -and $HiveKey -eq 'PE-SYS' }
            Should -Invoke Invoke-RegImportAsSystem -Times 0
            Should -Invoke Import-RegFile -Times 0
        }
        finally {
            Remove-Item -LiteralPath $mount -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
