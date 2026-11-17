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

Describe 'IME filelist entries' {
    It '40-components.txt carries the InputMethod directory trees' {
        $all = Read-Whitelist -Path (Join-Path $script:RepoRoot 'src/filelists/40-components.txt')
        $all | Should -Contain 'Windows\System32\InputMethod'
        $all | Should -Contain 'Windows\System32\ime'
    }
}
