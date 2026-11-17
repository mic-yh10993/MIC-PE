BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Wim.ps1"
    . "$PSScriptRoot/../src/build/lib/Registry.ps1"
    . "$PSScriptRoot/../src/build/lib/Shell.ps1"
    $script:TempRoot = [System.IO.Path]::GetTempPath()
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path
}

Describe 'Get-ImePatterns' {
    It 'keeps exactly the plan T11 filter set' {
        $patterns = @(
            'Windows\System32\InputMethod\CHS\ChsIME.exe',
            'Windows\System32\InputMethod',
            'Windows\System32\ime',
            'Windows\System32\msctf.dll',
            'Windows\System32\msctfime.ime',
            'Windows\System32\TextInputFramework.dll',
            'Windows\System32\Winlangdb.dll',
            'Windows\System32\dwm.exe',
            'Windows\System32\explorer.exe'
        )
        $kept = Get-ImePatterns -Patterns $patterns
        $kept.Count | Should -Be 7
        $kept | Should -Contain 'Windows\System32\InputMethod\CHS\ChsIME.exe'
        $kept | Should -Contain 'Windows\System32\Winlangdb.dll'
        $kept | Should -Not -Contain 'Windows\System32\dwm.exe'
        $kept | Should -Not -Contain 'Windows\System32\explorer.exe'
    }

    It 'returns empty when nothing matches' {
        Get-ImePatterns -Patterns @('Windows\System32\dwm.exe', 'Windows\System32\notepad.exe') |
            Should -BeNullOrEmpty
    }

    It 'matches entries in the real 40-components.txt' {
        $all = Read-Whitelist -Path (Join-Path $script:RepoRoot 'src/filelists/40-components.txt')
        $kept = Get-ImePatterns -Patterns $all
        $kept.Count | Should -BeGreaterThan 5
        $kept | Should -Contain 'Windows\System32\InputMethod'
        $kept | Should -Contain 'Windows\System32\ime'
        $kept | Should -Contain 'Windows\System32\msctf.dll'
    }
}

Describe 'Install-Ime preconditions' {
    It 'throws when the install.wim is missing' {
        { Install-Ime -MountDir $script:TempRoot `
                -InstallWim (Join-Path $script:TempRoot 'absent.wim') `
                -RepoRoot $script:RepoRoot } | Should -Throw '*not found*'
    }

    It 'throws when the mount directory is missing' {
        { Install-Ime -MountDir (Join-Path $script:TempRoot 'micpe-absent-mount') `
                -InstallWim (Join-Path $script:TempRoot 'absent.wim') `
                -RepoRoot $script:RepoRoot } | Should -Throw '*not found*'
    }
}

Describe 'IME registry patch' {
    BeforeAll {
        $script:reg30 = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src/registry/30-components.reg') -Raw
    }

    It 'pins Preload 1 to 0804 (Microsoft Pinyin)' {
        $script:reg30.Contains('"1"="00000804"') | Should -BeTrue
    }

    It 'declares the 0804 layout with its IME file' {
        $script:reg30 | Should -Match 'Keyboard Layouts\\00000804'
        $script:reg30.Contains('"IME File"="ChsIME.exe"') | Should -BeTrue
    }
}

Describe 'Assert-ImeRegistered against a real hive' {
    It 'throws naming 0804 when the hive preload lacks it' {
        if (-not $IsWindows) { Set-ItResult -Skipped -Because 'needs reg.exe and a real SOFTWARE hive'; return }

        $mount = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot "mnt-$(Get-Random)") -Force
        New-Item -ItemType Directory -Force -Path "$($mount.FullName)\Windows\System32\config" | Out-Null
        # The live SOFTWARE hive file is locked by the running OS, so a plain
        # Copy-Item fails; reg save snapshots it instead.
        $hiveCopy = "$($mount.FullName)\Windows\System32\config\SOFTWARE"
        $null = & reg.exe save 'HKLM\SOFTWARE' $hiveCopy /y 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'reg save SOFTWARE failed' }
        try {
            { Assert-ImeRegistered -MountDir $mount.FullName } | Should -Throw '*0804*'
        }
        finally {
            Remove-Item -LiteralPath $mount.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'passes once Preload 1 is set to 0804 in the hive copy' {
        if (-not $IsWindows) { Set-ItResult -Skipped -Because 'needs reg.exe and a real SOFTWARE hive'; return }

        $mount = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot "mnt-$(Get-Random)") -Force
        New-Item -ItemType Directory -Force -Path "$($mount.FullName)\Windows\System32\config" | Out-Null
        $hiveCopy = "$($mount.FullName)\Windows\System32\config\SOFTWARE"
        # The live SOFTWARE hive file is locked by the running OS, so a plain
        # Copy-Item fails; reg save snapshots it instead.
        $null = & reg.exe save 'HKLM\SOFTWARE' $hiveCopy /y 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'reg save SOFTWARE failed' }
        try {
            Mount-RegistryHive -HiveFile $hiveCopy -KeyName 'MICPE-IME-TEST'
            try {
                $null = & reg.exe add 'HKLM\MICPE-IME-TEST\Microsoft\Windows NT\CurrentVersion\Keyboard Layout\Preload' /v 1 /t REG_SZ /d 00000804 /f 2>&1
                if ($LASTEXITCODE -ne 0) { throw 'reg add preload failed' }
                # Verify the write while the hive is still mounted: if this
                # fails, the write (not the later read) is broken.
                $verify = & reg.exe query 'HKLM\MICPE-IME-TEST\Microsoft\Windows NT\CurrentVersion\Keyboard Layout\Preload' 2>&1
                ($verify -join "`n") | Should -Match '0804'
            }
            finally {
                Dismount-RegistryHive -KeyName 'MICPE-IME-TEST'
            }
            { Assert-ImeRegistered -MountDir $mount.FullName } | Should -Not -Throw
        }
        finally {
            Remove-Item -LiteralPath $mount.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'IME filelist entries' {
    It '40-components.txt carries the InputMethod directory trees' {
        $all = Read-Whitelist -Path (Join-Path $script:RepoRoot 'src/filelists/40-components.txt')
        $all | Should -Contain 'Windows\System32\InputMethod'
        $all | Should -Contain 'Windows\System32\ime'
    }
}
