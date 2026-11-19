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
        $script:reg60.Contains('"DumpFolder"="X:\CrashDumps"') | Should -BeTrue -Because 'the dump folder is the PE system drive'
        $script:reg60.Contains('"DumpFolder"="X:\\CrashDumps"') | Should -BeFalse -Because 'a doubled backslash would point at a literal backslash folder'
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
        # hive (HKLM\SYSTEM would hit the runner).
        foreach ($group in '0', '15', '9') {
            $script:reg70 | Should -Match "HKEY_LOCAL_MACHINE\\PE-SYS\\ControlSet001\\Control\\FeatureManagement\\Overrides\\$group\\42537950\]" -Because "group $group must carry the override"
        }
        ([regex]::Matches($script:reg70, '"EnabledState"=dword:00000000')).Count | Should -Be 3 -Because 'one Disabled value per group'
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
            $entry[0].Values['EnabledState'] | Should -Be 0 -Because 'EnabledState 0 disables the feature'
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

    It 'writes a key whose DACL gives SYSTEM only KEY_READ, where the SYSTEM import fails (run 51)' -Skip:(-not $IsWindows) {
        # Mirror of the Appx SYSTEM-import test, with the run 51 DACL
        # shape instead: the group key gives SYSTEM only ReadKey, so
        # both the plain admin import and the SYSTEM import must fail,
        # and only the backup/restore write lands the values. The
        # restriction lives only inside the throwaway test hive; the
        # temp dir is deleted after.
        $work = Join-Path $script:TempRoot "priv-sys-$(Get-Random)"
        New-Item -ItemType Directory -Force -Path "$work/Windows/System32/config" | Out-Null
        $hiveCopy = "$work/Windows/System32/config/SOFTWARE"
        $null = & reg.exe save 'HKLM\SOFTWARE' $hiveCopy /y 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'reg save SOFTWARE failed' }
        $keyName = 'MICPE-PRIV-TEST'
        $groupSub = 'Control\FeatureManagement\Overrides\0'
        $testReg = Join-Path $work 'priv-test.reg'
        $regText = @(
            'Windows Registry Editor Version 5.00',
            '',
            ('[HKEY_LOCAL_MACHINE\{0}\{1}\42537950]' -f $keyName, $groupSub),
            '"EnabledState"=dword:00000000',
            '"EnabledStateOptions"=dword:00000000',
            ''
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($testReg, $regText, [System.Text.Encoding]::Unicode)
        try {
            Mount-RegistryHive -HiveFile $hiveCopy -KeyName $keyName
            try {
                $addOut = & reg.exe add "HKLM\$keyName\$groupSub" /f 2>&1
                if ($LASTEXITCODE -ne 0) { throw "reg add group key failed: $addOut" }

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

                # Admin import must fail on the restricted key (run 51:
                # the group key gives nobody a write right except the
                # Feature Management service account).
                $null = & reg.exe import $testReg 2>&1
                $LASTEXITCODE | Should -Not -Be 0 -Because 'the restricted DACL must block the admin import, or this test proves nothing'

                # SYSTEM import must fail the same way (run 51 repro:
                # SYSTEM has only KEY_READ on the group key).
                { Invoke-RegImportAsSystem -RegFile $testReg } | Should -Throw '*Error accessing the registry*'

                # The backup/restore write must succeed through the
                # same DACL, without changing it.
                { Invoke-RegImportPrivileged -RegFile $testReg -HiveKey $keyName } | Should -Not -Throw

                $values = Get-RegistryKeyValues -KeyName $keyName -SubKey "$groupSub\42537950"
                $values | Should -Not -BeNullOrEmpty
                $values['EnabledState'] | Should -Match '^0x0*0$'
                $values['EnabledStateOptions'] | Should -Match '^0x0*0$'
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
