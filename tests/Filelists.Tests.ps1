BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Wim.ps1"
    $script:ListDir = Join-Path $PSScriptRoot '../src/filelists'
}

Describe 'whitelists' {
    It '<_>.txt exists and parses' -ForEach @('10-cmdpe', '20-explorer', '30-runtimes', '40-components') {
        $path = Join-Path $script:ListDir "$_.txt"
        Test-Path -LiteralPath $path | Should -BeTrue
        (Read-Whitelist -Path $path).Count | Should -BeGreaterThan 10
    }

    It 'every entry is a relative Windows path without a drive letter' {
        $bad = [System.Collections.Generic.List[string]]::new()
        foreach ($name in '10-cmdpe', '20-explorer', '30-runtimes', '40-components', '50-uwp', '60-framehost', '70-logon') {
            $entries = Read-Whitelist -Path (Join-Path $script:ListDir "$name.txt")
            foreach ($entry in $entries) {
                if ($entry -match '^[A-Za-z]:') { $bad.Add("$name drive: $entry") }
                elseif ($entry -notmatch '^[A-Za-z0-9_\. ]+\\') { $bad.Add("$name shape: $entry") }
                elseif ($entry -match '/') { $bad.Add("$name slash: $entry") }
            }
        }
        $bad | Should -BeNullOrEmpty
    }

    It 'does not carry the winre.wim base image' {
        $found = [System.Collections.Generic.List[string]]::new()
        foreach ($name in '10-cmdpe', '20-explorer', '30-runtimes', '40-components', '50-uwp', '60-framehost', '70-logon') {
            Read-Whitelist -Path (Join-Path $script:ListDir "$name.txt") |
                Where-Object { $_ -like '*Recovery\Winre.wim' } |
                ForEach-Object { $found.Add("$name $_") }
        }
        $found | Should -BeNullOrEmpty
    }

    It 'does not contain patterns known absent from the 25H2 install.wim' {
        # Build runs 44027407243 (hive flatten) and 44032090523
        # (SettingSyncCore.dll, exit 49) died on whitelist entries that do
        # not exist in the 25H2 26200 install.wim index 1. The full list was
        # audited against the real image (see micpe-m7fix-eval-card.md);
        # these 32 must not come back: 31 removed outright, plus the
        # comctl32 zh-CN entry, which exists only as a .mui (fixed, not
        # removed, and pinned by the next test).
        $stale = @(
            'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}\Package_*',
            'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}\Microsoft-Windows-BusinessScanning-Feature-Package-admin~*.cat',
            'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}\Microsoft-Windows-Common-Modem-Drivers-Package~*.cat',
            'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}\Microsoft-Windows-PeerToPeer-Full-Package~*.cat',
            'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}\Microsoft-Windows-OneCoreUAP-WCN-Package~*.cat',
            'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}\Microsoft-Windows-OneCoreUAP-WCN-WOW64-Package~*.cat',
            'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}\Microsoft-Windows-WCN-net-Package~*.cat',
            'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}\Microsoft-Windows-WCN-WOW64-net-Package~*.cat',
            'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}\Microsoft-Windows-SecureStartup-Subsystem-base-Package~*.cat',
            'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}\Microsoft-Windows-Desktop-Shared-Drivers-merged-Package*.cat',
            'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}\Microsoft-Windows-Media-Format-multimedia-Package~*.cat',
            'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}\Microsoft-Windows-Multimedia-RestrictedCodecs-multimedia-Package~*.cat',
            'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}\Microsoft-Windows-Multimedia-RestrictedCodecs-WOW64-multimedia-Package~*.cat',
            'Windows\System32\SettingSyncCore.dll',
            'Windows\System32\SharedStartModel.dll',
            'Windows\System32\coloradapterclient.dll',
            'Windows\System32\VEEventDispatcher.dll',
            'Windows\System32\Windows.UI.FileExplorer.WASDK.dll',
            'Windows\System32\provsvc.dll',
            'Windows\SysWOW64\zh-CN\comctl32.dll',
            'Windows\SysWOW64\zh-CN\comdlg32.dll',
            'Windows\SysWOW64\zh-CN\mlang.dll',
            'Windows\SysWOW64\clb.dll',
            'Windows\SysWOW64\run64.exe',
            'Windows\System32\msvcrt20.dll',
            'Windows\System32\msvcrt40.dll',
            'Windows\System32\msvcp110.dll',
            'Windows\System32\msvcr110.dll',
            'Windows\System32\Windows.Shell.Search.UriHandler.dll',
            'Windows\System32\prm*.dll',
            'Windows\System32\MLS*.dll'
        )
        $found = [System.Collections.Generic.List[string]]::new()
        foreach ($name in '10-cmdpe', '20-explorer', '30-runtimes', '40-components', '50-uwp', '60-framehost', '70-logon') {
            Read-Whitelist -Path (Join-Path $script:ListDir "$name.txt") |
                Where-Object { $stale -contains $_ } |
                ForEach-Object { $found.Add("$name $_") }
        }
        $found | Should -BeNullOrEmpty
    }

    It 'the runtimes list carries the comctl32 zh-CN MUI by its real name' {
        $entries = Read-Whitelist -Path (Join-Path $script:ListDir '30-runtimes.txt')
        $entries | Should -Contain 'Windows\SysWOW64\zh-CN\comctl32.dll.mui'
    }

    It 'the cmdpe list carries tasklist.exe and its en-US/zh-CN MUIs (probe shell section, run 44135105700)' {
        $entries = Read-Whitelist -Path (Join-Path $script:ListDir '10-cmdpe.txt')
        $entries | Should -Contain 'Windows\System32\tasklist.exe'
        $entries | Should -Contain 'Windows\System32\en-US\tasklist.exe.mui'
        $entries | Should -Contain 'Windows\System32\zh-CN\tasklist.exe.mui'
    }

    It 'the cmdpe list carries mountvol.exe and its en-US/zh-CN MUIs (drive-letter fix, user decision 2026-11-17 23:43)' {
        $entries = Read-Whitelist -Path (Join-Path $script:ListDir '10-cmdpe.txt')
        $entries | Should -Contain 'Windows\System32\mountvol.exe'
        $entries | Should -Contain 'Windows\System32\en-US\mountvol.exe.mui'
        $entries | Should -Contain 'Windows\System32\zh-CN\mountvol.exe.mui'
    }

    It 'the explorer list contains explorer.exe and the StateRepository family' {
        $entries = Read-Whitelist -Path (Join-Path $script:ListDir '20-explorer.txt')
        ($entries -contains 'Windows\explorer.exe') | Should -BeTrue
        @($entries | Where-Object { $_ -match 'Windows\.StateRepository' }).Count | Should -BeGreaterThan 3
    }

    It 'the explorer list carries the desktop wallpaper' {
        $entries = Read-Whitelist -Path (Join-Path $script:ListDir '20-explorer.txt')
        @($entries | Where-Object { $_ -match 'Web\\Wallpaper' }).Count | Should -BeGreaterThan 0
    }

    It 'the runtimes list contains the WOW64 core' {
        $entries = Read-Whitelist -Path (Join-Path $script:ListDir '30-runtimes.txt')
        @($entries | Where-Object { $_ -match 'SysWOW64\\ntdll\.dll$' }).Count | Should -Be 1
        @($entries | Where-Object { $_ -match 'System32\\wow64\.dll$' }).Count | Should -Be 1
    }

    It 'the components list contains DWM and the input method files' {
        $entries = Read-Whitelist -Path (Join-Path $script:ListDir '40-components.txt')
        @($entries | Where-Object { $_ -match '\\dwm\.exe$' }).Count | Should -BeGreaterThan 0
        @($entries | Where-Object { $_ -match 'InputMethod' }).Count | Should -BeGreaterThan 0
    }

    It 'the uwp list contains the AppX deployment stack' {
        # 50-uwp.txt is a small hand-written stack list, not one of the big
        # tutorial-derived whitelists, so it is exempt from the >10-entry
        # threshold above and checked on its own here.
        $path = Join-Path $script:ListDir '50-uwp.txt'
        Test-Path -LiteralPath $path | Should -BeTrue
        $entries = Read-Whitelist -Path $path
        $entries.Count | Should -BeGreaterThan 0
        $entries | Should -Contain 'Windows\System32\AppXDeploymentClient.dll'
        $entries | Should -Contain 'Windows\System32\Windows.UI.Xaml.dll'
    }

    It 'the framehost list contains the UWP frame host chain (run 45)' {
        # 60-framehost.txt is the same kind of small hand-written list as
        # 50-uwp.txt. Every entry was verified against the real 25H2
        # install.wim (wimlib dir listing) before this round.
        $path = Join-Path $script:ListDir '60-framehost.txt'
        Test-Path -LiteralPath $path | Should -BeTrue
        $entries = Read-Whitelist -Path $path
        $entries.Count | Should -Be 5
        $entries | Should -Contain 'Windows\System32\ApplicationFrameHost.exe'
        $entries | Should -Contain 'Windows\System32\RuntimeBroker.exe'
        $entries | Should -Contain 'Windows\System32\AppReadiness.dll'
        $entries | Should -Contain 'Windows\SystemApps\ShellExperienceHost_cw5n1h2txyewy*'
        $entries | Should -Contain 'Windows\SystemApps\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy*'
    }

    It 'the logon list contains the admin logon stack (Phase 1)' {
        # 70-logon.txt is the same kind of small hand-written list as
        # 50-uwp.txt and 60-framehost.txt. Every entry was verified
        # against the real 26200 install.wim file list (the original 9
        # before the Phase 1 round, the 11 experiment additions during
        # the native-logon experiment patch); the 26300 list is not
        # available locally yet, so existence in 26300 is verified at CI
        # build time (a missing entry fails the build; the assertion is
        # not weakened).
        $path = Join-Path $script:ListDir '70-logon.txt'
        Test-Path -LiteralPath $path | Should -BeTrue
        $entries = Read-Whitelist -Path $path
        $entries.Count | Should -Be 20
        $entries | Should -Contain 'Windows\System32\LogonUI.exe'
        $entries | Should -Contain 'Windows\System32\winlogon.exe'
        $entries | Should -Contain 'Windows\System32\userinit.exe'
        $entries | Should -Contain 'Windows\System32\authui.dll'
        $entries | Should -Contain 'Windows\System32\SmartcardCredentialProvider.dll'
        $entries | Should -Contain 'Windows\System32\lsasrv.dll'
        $entries | Should -Contain 'Windows\System32\samsrv.dll'
        $entries | Should -Contain 'Windows\System32\samlib.dll'
        $entries | Should -Contain 'Windows\System32\msv1_0.dll'
        $entries | Should -Contain 'Windows\System32\secur32.dll'
        $entries | Should -Contain 'Windows\System32\userenv.dll'
        $entries | Should -Contain 'Windows\System32\profsvc.dll'
        $entries | Should -Contain 'Windows\System32\seclogon.dll'
        $entries | Should -Contain 'Windows\System32\Windows.UI.Logon.dll'
        $entries | Should -Contain 'Windows\System32\sihost.exe'
        $entries | Should -Contain 'Windows\System32\ShellAppRuntime.exe'
        $entries | Should -Contain 'Windows\System32\whoami.exe'
        $entries | Should -Contain 'Windows\SystemResources\Windows.UI.Logon\Windows.UI.Logon.pri'
        $entries | Should -Contain 'Windows\SystemResources\Windows.UI.Logon\pris\Windows.UI.Logon.zh-CN.pri'
        $entries | Should -Contain 'Windows\System32\zh-CN\seclogon.dll.mui'
        # whoami has no MUI on purpose: without one it falls back to its
        # embedded English resources, which the probe's `whoami /priv`
        # parsing (find "Enabled") depends on; a zh-CN MUI would break it.
        $entries | Should -Not -Contain 'Windows\System32\zh-CN\whoami.exe.mui'
        $entries | Should -Not -Contain 'Windows\System32\en-US\whoami.exe.mui'
    }
}
