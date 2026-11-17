BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Wim.ps1"
    . "$PSScriptRoot/../src/build/lib/Registry.ps1"
    . "$PSScriptRoot/../src/build/lib/Shell.ps1"
    $script:TempRoot = [System.IO.Path]::GetTempPath()

    function New-FakeMount {
        $root = Join-Path $script:TempRoot "mnt-$(Get-Random)"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return $root
    }
}

Describe 'Assert-ExplorerPresent' {
    It 'lists every missing artifact rather than stopping at the first' {
        $mount = New-FakeMount
        $message = try { Assert-ExplorerPresent -MountDir $mount } catch { $_.Exception.Message }

        $message | Should -Match 'explorer\.exe'
        $message | Should -Match 'AppRepository'
        $message | Should -Match 'SystemTemp'
        $message | Should -Match 'StateRepository'
    }

    It 'passes when all artifacts exist' {
        $mount = New-FakeMount
        New-Item -ItemType Directory -Force -Path "$mount/Windows/System32" | Out-Null
        Set-Content -LiteralPath "$mount/Windows/explorer.exe" -Value 'x'
        foreach ($dll in 'CoreMessaging.dll', 'twinapi.appcore.dll', 'twinui.pcshell.dll') {
            Set-Content -LiteralPath "$mount/Windows/System32/$dll" -Value 'x'
        }
        1..4 | ForEach-Object {
            Set-Content -LiteralPath "$mount/Windows/System32/Windows.StateRepository$_.dll" -Value 'x'
        }
        New-Item -ItemType Directory -Force -Path "$mount/ProgramData/Microsoft/Windows/AppRepository" | Out-Null
        New-Item -ItemType Directory -Force -Path "$mount/Windows/SystemTemp" | Out-Null

        { Assert-ExplorerPresent -MountDir $mount } | Should -Not -Throw
    }

    It 'requires at least four StateRepository DLLs' {
        $mount = New-FakeMount
        New-Item -ItemType Directory -Force -Path "$mount/Windows/System32" | Out-Null
        Set-Content -LiteralPath "$mount/Windows/explorer.exe" -Value 'x'
        foreach ($dll in 'CoreMessaging.dll', 'twinapi.appcore.dll', 'twinui.pcshell.dll') {
            Set-Content -LiteralPath "$mount/Windows/System32/$dll" -Value 'x'
        }
        Set-Content -LiteralPath "$mount/Windows/System32/Windows.StateRepository.dll" -Value 'x'
        New-Item -ItemType Directory -Force -Path "$mount/ProgramData/Microsoft/Windows/AppRepository" | Out-Null
        New-Item -ItemType Directory -Force -Path "$mount/Windows/SystemTemp" | Out-Null

        { Assert-ExplorerPresent -MountDir $mount } | Should -Throw '*StateRepository*'
    }
}

Describe 'Install-ExplorerShell preconditions' {
    It 'throws when the mount directory is missing' {
        { Install-ExplorerShell -MountDir (Join-Path $script:TempRoot 'micpe-absent-mount') `
                -InstallWim (Join-Path $script:TempRoot 'absent.wim') `
                -RepoRoot (Resolve-Path "$PSScriptRoot/..").Path } | Should -Throw '*not found*'
    }
}

Describe 'Install-Runtimes preconditions' {
    It 'throws when the install.wim is missing' {
        { Install-Runtimes -MountDir $script:TempRoot -InstallWim (Join-Path $script:TempRoot 'absent.wim') `
                -RepoRoot (Resolve-Path "$PSScriptRoot/..").Path } | Should -Throw '*not found*'
    }
}

Describe 'Set-BootShell' {
    It 'copies startnet.cmd and removes winpeshl.ini' {
        $mount = New-FakeMount
        New-Item -ItemType Directory -Force -Path "$mount/Windows/System32" | Out-Null
        Set-Content -LiteralPath "$mount/Windows/System32/winpeshl.ini" -Value '[LaunchApps]'
        $repoRoot = (Resolve-Path "$PSScriptRoot/..").Path

        Set-BootShell -MountDir $mount -RepoRoot $repoRoot

        Test-Path -LiteralPath "$mount/Windows/System32/startnet.cmd" | Should -BeTrue
        Test-Path -LiteralPath "$mount/Windows/System32/winpeshl.ini" | Should -BeFalse
        Test-Path -LiteralPath "$mount/Program Files/MICPE" | Should -BeTrue
    }

    It 'copies PECMD.INI and Pin-Shortcuts.wcs when present in src/shell' {
        $mount = New-FakeMount
        New-Item -ItemType Directory -Force -Path "$mount/Windows/System32" | Out-Null
        $repoRoot = (Resolve-Path "$PSScriptRoot/..").Path

        Set-BootShell -MountDir $mount -RepoRoot $repoRoot

        Test-Path -LiteralPath "$mount/Program Files/MICPE/PECMD.INI" | Should -BeTrue
        Test-Path -LiteralPath "$mount/Windows/System32/Pin-Shortcuts.wcs" | Should -BeTrue
    }
}

Describe 'Explorer registry patches' {
    BeforeAll {
        $script:reg10 = Get-Content -LiteralPath "$PSScriptRoot/../src/registry/10-pe-base.reg" -Raw
        $script:reg20 = Get-Content -LiteralPath "$PSScriptRoot/../src/registry/20-explorer.reg" -Raw
    }

    It '10-pe-base.reg points the Winlogon shell at PECMD' {
        $script:reg10.Contains('"Shell"="PECMD.EXE"') | Should -BeTrue
    }

    It '20-explorer.reg overrides the shell with explorer.exe' {
        $script:reg20.Contains('"Shell"="explorer.exe"') | Should -BeTrue
        $script:reg20.Contains('"Userinit"=""') | Should -BeTrue
    }

    It '20-explorer.reg points the desktop at the PE default profile' {
        $script:reg20.Contains('X:\\Users\\Default\\Desktop') | Should -BeTrue
    }

    It '20-explorer.reg disables the first-logon animation' {
        $script:reg20.Contains('"EnableFirstLogonAnimation"=dword:00000000') | Should -BeTrue
    }

    It '20-explorer.reg is imported after 10-pe-base.reg by the build' {
        $build = Get-Content -LiteralPath "$PSScriptRoot/../src/build/Build-Micpe.ps1" -Raw
        # Assert on the array literal itself, not raw IndexOf: the step's
        # comment mentions 20-explorer.reg before the array does.
        $build | Should -Match "@\('10-pe-base\.reg', '20-explorer\.reg'\)"
    }
}

Describe 'Assert-ImeRegistered preconditions' {
    It 'throws when the SOFTWARE hive is missing' {
        $mount = New-FakeMount
        { Assert-ImeRegistered -MountDir $mount } | Should -Throw '*SOFTWARE*'
    }
}
