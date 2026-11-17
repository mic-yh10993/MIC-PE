BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Installer.ps1"
    $script:TempRoot = [System.IO.Path]::GetTempPath()
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path

    function New-FakeMount {
        $root = Join-Path $script:TempRoot "mnt-$(Get-Random)"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return $root
    }
}

Describe 'Install-Installer' {
    It 'copies the wizard, ini, scripts and lang strings into the image' {
        $m = New-FakeMount
        Install-Installer -MountDir $m -RepoRoot $script:RepoRoot
        foreach ($rel in 'Program Files/MICPE/MICPE-Setup/MICPE-Setup.wcs',
                        'Program Files/MICPE/MICPE-Setup/MICPE-Setup.ini',
                        'Program Files/MICPE/MICPE-Setup/Deploy.ps1',
                        'Program Files/MICPE/MICPE-Setup/Discover.ps1',
                        'Program Files/MICPE/MICPE-Setup/lang/zh-CN.txt') {
            Test-Path -LiteralPath (Join-Path $m $rel) | Should -BeTrue -Because "$rel must be installed"
        }
    }

    It 'throws when the installer sources are missing' {
        $m = New-FakeMount
        $empty = Join-Path $script:TempRoot "repo-$(Get-Random)"
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        { Install-Installer -MountDir $m -RepoRoot $empty } | Should -Throw
    }
}

Describe 'Assert-InstallerInstalled' {
    It 'names every missing installer file' {
        $m = New-FakeMount
        $msg = try { Assert-InstallerInstalled -MountDir $m } catch { $_.Exception.Message }
        $msg | Should -Match 'MICPE-Setup\.wcs'
        $msg | Should -Match 'MICPE-Setup\.ini'
        $msg | Should -Match 'Deploy\.ps1'
        $msg | Should -Match 'Discover\.ps1'
        $msg | Should -Match 'zh-CN\.txt'
    }

    It 'passes when all installer files exist' {
        $m = New-FakeMount
        Install-Installer -MountDir $m -RepoRoot $script:RepoRoot
        { Assert-InstallerInstalled -MountDir $m } | Should -Not -Throw
    }
}
