BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Wim.ps1"
    . "$PSScriptRoot/../src/build/lib/Registry.ps1"
    . "$PSScriptRoot/../src/build/lib/Uwp.ps1"
    $script:TempRoot = [System.IO.Path]::GetTempPath()
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path

    function New-FakeMount {
        $root = Join-Path $script:TempRoot "mnt-$(Get-Random)"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return $root
    }
}

Describe 'Assert-UwpReady' {
    It 'reports each missing uwp artifact by name' {
        $m = New-FakeMount
        $msg = try { Assert-UwpReady -MountDir $m } catch { $_.Exception.Message }
        $msg | Should -Match 'AppXDeploymentClient'
        $msg | Should -Match 'Windows.UI.Xaml'
        $msg | Should -Match 'Windows.StateRepository'
    }

    It 'passes when all artifacts exist' {
        $m = New-FakeMount
        New-Item -ItemType Directory -Force -Path "$m/Windows/System32" | Out-Null
        Set-Content -LiteralPath "$m/Windows/System32/AppXDeploymentClient.dll" -Value 'x'
        Set-Content -LiteralPath "$m/Windows/System32/Windows.UI.Xaml.dll" -Value 'x'
        1..4 | ForEach-Object {
            Set-Content -LiteralPath "$m/Windows/System32/Windows.StateRepository$_.dll" -Value 'x'
        }
        New-Item -ItemType Directory -Force -Path "$m/ProgramData/Microsoft/Windows/AppRepository" | Out-Null
        foreach ($name in Get-UwpDefaults) {
            New-Item -ItemType Directory -Force -Path "$m/Program Files/WindowsApps/${name}_1.0.0.0_x64__8wekyb3d8bbwe" | Out-Null
        }

        { Assert-UwpReady -MountDir $m } | Should -Not -Throw
    }

    It 'names the default app whose WindowsApps directory is missing' {
        $m = New-FakeMount
        New-Item -ItemType Directory -Force -Path "$m/Windows/System32" | Out-Null
        Set-Content -LiteralPath "$m/Windows/System32/AppXDeploymentClient.dll" -Value 'x'
        Set-Content -LiteralPath "$m/Windows/System32/Windows.UI.Xaml.dll" -Value 'x'
        1..4 | ForEach-Object {
            Set-Content -LiteralPath "$m/Windows/System32/Windows.StateRepository$_.dll" -Value 'x'
        }
        New-Item -ItemType Directory -Force -Path "$m/ProgramData/Microsoft/Windows/AppRepository" | Out-Null
        New-Item -ItemType Directory -Force -Path "$m/Program Files/WindowsApps/Microsoft.Windows.Photos_1.0.0.0_x64__8wekyb3d8bbwe" | Out-Null
        New-Item -ItemType Directory -Force -Path "$m/Program Files/WindowsApps/Microsoft.ZuneMusic_1.0.0.0_x64__8wekyb3d8bbwe" | Out-Null

        $msg = try { Assert-UwpReady -MountDir $m } catch { $_.Exception.Message }
        $msg | Should -Match 'Microsoft.WindowsCalculator'
    }
}

Describe 'Get-UwpDefaults' {
    It 'includes photos, media player and calculator' {
        $d = Get-UwpDefaults
        $d | Should -Contain 'Microsoft.Windows.Photos'
        $d | Should -Contain 'Microsoft.ZuneMusic'
        $d | Should -Contain 'Microsoft.WindowsCalculator'
    }

    It 'excludes the Settings app and the Store (user decision 2026-11-16)' {
        # UWP 仅保留核心文件：系统自带设置应用太重不要；Store 不是装机盘
        # 的离线核心能力，也不带进来。Pin both so a later edit cannot
        # silently re-add either.
        $d = Get-UwpDefaults
        $d | Should -Not -Contain 'Microsoft.Windows.Settings'
        $d | Should -Not -Contain 'Microsoft.WindowsStore'
    }
}

Describe 'Get-UwpFrameworkPatterns' {
    It 'covers the four framework families from plan T12' {
        $p = Get-UwpFrameworkPatterns
        $p | Should -Contain 'Program Files\WindowsApps\Microsoft.VCLibs.140.00*'
        $p | Should -Contain 'Program Files\WindowsApps\Microsoft.NET.Native.*'
        $p | Should -Contain 'Program Files\WindowsApps\Microsoft.UI.Xaml.*'
        $p | Should -Contain 'Program Files\WindowsApps\Microsoft.WindowsAppRuntime*'
    }
}

Describe 'Install-AppxFramework preconditions' {
    It 'throws when the install.wim is missing' {
        { Install-AppxFramework -MountDir $script:TempRoot `
                -InstallWim (Join-Path $script:TempRoot 'absent.wim') `
                -RepoRoot $script:RepoRoot } | Should -Throw '*not found*'
    }

    It 'throws when the mount directory is missing' {
        { Install-AppxFramework -MountDir (Join-Path $script:TempRoot 'micpe-absent-mount') `
                -InstallWim (Join-Path $script:TempRoot 'absent.wim') `
                -RepoRoot $script:RepoRoot } | Should -Throw '*not found*'
    }
}

Describe 'Install-UwpApps preconditions' {
    It 'throws when the install.wim is missing' {
        { Install-UwpApps -MountDir $script:TempRoot `
                -InstallWim (Join-Path $script:TempRoot 'absent.wim') `
                -RepoRoot $script:RepoRoot } | Should -Throw '*not found*'
    }
}

Describe 'UWP registry patch' {
    BeforeAll {
        $script:reg40 = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src/registry/40-uwp.reg') -Raw
    }

    It 'allows all trusted apps and developer sideloading' {
        $script:reg40.Contains('"AllowAllTrustedApps"=dword:00000001') | Should -BeTrue
        $script:reg40.Contains('"AllowDevelopmentWithoutDevLicense"=dword:00000001') | Should -BeTrue
    }

    It 'pins the StateRepository service to manual start' {
        $script:reg40 | Should -Match 'Services\\StateRepository'
        $script:reg40.Contains('"Start"=dword:00000003') | Should -BeTrue
    }
}

Describe 'New-UwpProvisionRegContent' {
    It 'writes CRLF line endings (reg.exe rejects LF-only .reg files)' {
        $content = New-UwpProvisionRegContent -Resolved @{
            'Microsoft.Windows.Photos' = 'Microsoft.Windows.Photos_1.0.0.0_x64__8wekyb3d8bbwe'
        } -HiveKey 'PE-UWP'
        $content | Should -Match "`r`n"
        $content | Should -Not -Match "(?<!`r)`n"
    }

    It 'writes the registry header and both keys per app' {
        $content = New-UwpProvisionRegContent -Resolved @{
            'Microsoft.Windows.Photos' = 'Microsoft.Windows.Photos_1.0.0.0_x64__8wekyb3d8bbwe'
        } -HiveKey 'PE-UWP'
        $content | Should -Match 'Windows Registry Editor Version 5.00'
        $content | Should -Match 'AppxAllUserStore\\Applications\\Microsoft\.Windows\.Photos_1\.0\.0\.0_x64__8wekyb3d8bbwe'
        $content | Should -Match 'AppxAllUserStore\\InboxApplications\\Microsoft\.Windows\.Photos'
        $content.Contains('"Path"="X:\\Program Files\\WindowsApps\\Microsoft.Windows.Photos_1.0.0.0_x64__8wekyb3d8bbwe"') |
            Should -BeTrue
    }
}

Describe 'Register-ProvisionedAppx against a real hive' {
    It 'writes the InboxApplications Path for each default app' {
        if (-not $IsWindows) { Set-ItResult -Skipped -Because 'needs reg.exe and a real SOFTWARE hive'; return }

        $mount = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot "mnt-$(Get-Random)") -Force
        New-Item -ItemType Directory -Force -Path "$($mount.FullName)\Windows\System32\config" | Out-Null
        foreach ($name in Get-UwpDefaults) {
            New-Item -ItemType Directory -Force -Path "$($mount.FullName)\Program Files\WindowsApps\${name}_1.0.0.0_x64__8wekyb3d8bbwe" | Out-Null
        }
        # The live SOFTWARE hive file is locked by the running OS, so a plain
        # Copy-Item fails; reg save snapshots it instead.
        $hiveCopy = "$($mount.FullName)\Windows\System32\config\SOFTWARE"
        $null = & reg.exe save 'HKLM\SOFTWARE' $hiveCopy /y 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'reg save SOFTWARE failed' }
        try {
            { Register-ProvisionedAppx -MountDir $mount.FullName -PackageNames (Get-UwpDefaults) } | Should -Not -Throw

            # Verify the write through an independent read of the hive copy.
            Mount-RegistryHive -HiveFile $hiveCopy -KeyName 'MICPE-UWP-TEST'
            try {
                foreach ($name in Get-UwpDefaults) {
                    $values = Get-RegistryKeyValues -KeyName 'MICPE-UWP-TEST' `
                        -SubKey "Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications\$name"
                    $null -eq $values | Should -BeFalse -Because "InboxApplications\$name must exist"
                    $values['Path'] | Should -Match ([regex]::Escape($name))
                }
            }
            finally {
                Dismount-RegistryHive -KeyName 'MICPE-UWP-TEST'
            }
        }
        finally {
            Remove-Item -LiteralPath $mount.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws naming the app when its WindowsApps directory is missing' {
        if (-not $IsWindows) { Set-ItResult -Skipped -Because 'needs reg.exe and a real SOFTWARE hive'; return }

        $mount = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot "mnt-$(Get-Random)") -Force
        New-Item -ItemType Directory -Force -Path "$($mount.FullName)\Windows\System32\config" | Out-Null
        $hiveCopy = "$($mount.FullName)\Windows\System32\config\SOFTWARE"
        $null = & reg.exe save 'HKLM\SOFTWARE' $hiveCopy /y 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'reg save SOFTWARE failed' }
        try {
            { Register-ProvisionedAppx -MountDir $mount.FullName -PackageNames @('Microsoft.Windows.Photos') } |
                Should -Throw '*Microsoft.Windows.Photos*'
        }
        finally {
            Remove-Item -LiteralPath $mount.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'UWP filelist entries' {
    It '50-uwp.txt carries the AppX stack DLLs the assert checks' {
        $all = Read-Whitelist -Path (Join-Path $script:RepoRoot 'src/filelists/50-uwp.txt')
        $all | Should -Contain 'Windows\System32\AppXDeploymentClient.dll'
        $all | Should -Contain 'Windows\System32\Windows.UI.Xaml.dll'
    }
}
