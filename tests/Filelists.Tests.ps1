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
        foreach ($name in '10-cmdpe', '20-explorer', '30-runtimes', '40-components', '50-uwp') {
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
        foreach ($name in '10-cmdpe', '20-explorer', '30-runtimes', '40-components', '50-uwp') {
            Read-Whitelist -Path (Join-Path $script:ListDir "$name.txt") |
                Where-Object { $_ -like '*Recovery\Winre.wim' } |
                ForEach-Object { $found.Add("$name $_") }
        }
        $found | Should -BeNullOrEmpty
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
}
