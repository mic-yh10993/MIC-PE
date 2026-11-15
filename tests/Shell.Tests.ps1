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
}

Describe 'Assert-ImeRegistered preconditions' {
    It 'throws when the SOFTWARE hive is missing' {
        $mount = New-FakeMount
        { Assert-ImeRegistered -MountDir $mount } | Should -Throw '*SOFTWARE*'
    }
}
