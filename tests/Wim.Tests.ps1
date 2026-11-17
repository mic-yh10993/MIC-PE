BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Wim.ps1"
    $script:TempRoot = [System.IO.Path]::GetTempPath()
    $script:fakeWimlib = Join-Path $PSScriptRoot 'Fake-Wimlib.ps1'
}

Describe 'ConvertTo-WimPathPattern' {
    It 'strips a leading backslash' {
        ConvertTo-WimPathPattern -Line '\Windows\explorer.exe' | Should -Be 'Windows\explorer.exe'
    }

    It 'keeps wildcards' {
        ConvertTo-WimPathPattern -Line '\Windows\WinSxS\x86_*\*.*' | Should -Be 'Windows\WinSxS\x86_*\*.*'
    }

    It 'trims trailing whitespace' {
        ConvertTo-WimPathPattern -Line '\Windows\a.dll   ' | Should -Be 'Windows\a.dll'
    }

    It 'ignores comment and blank lines' {
        ConvertTo-WimPathPattern -Line '; comment' | Should -BeNullOrEmpty
        ConvertTo-WimPathPattern -Line '# comment' | Should -BeNullOrEmpty
        ConvertTo-WimPathPattern -Line '' | Should -BeNullOrEmpty
        ConvertTo-WimPathPattern -Line '    ' | Should -BeNullOrEmpty
        ConvertTo-WimPathPattern -Line '\' | Should -BeNullOrEmpty
    }

    It 'leaves paths without a leading backslash alone' {
        ConvertTo-WimPathPattern -Line 'Program Files\WindowsApps' | Should -Be 'Program Files\WindowsApps'
    }
}

Describe 'Read-Whitelist' {
    It 'dedupes while keeping order' {
        $f = New-TemporaryFile
        Set-Content -LiteralPath $f -Value @('\Windows\a.dll', '\Windows\b.dll', '\Windows\a.dll', ';comment', '')
        Read-Whitelist -Path $f | Should -Be @('Windows\a.dll', 'Windows\b.dll')
    }

    It 'dedupes case-insensitively' {
        $f = New-TemporaryFile
        Set-Content -LiteralPath $f -Value @('\Windows\A.dll', '\windows\a.dll')
        Read-Whitelist -Path $f | Should -HaveCount 1
    }

    It 'throws when the file is missing' {
        { Read-Whitelist -Path (Join-Path $script:TempRoot 'micpe-absent-list.txt') } |
            Should -Throw '*not found*'
    }
}

Describe 'Assert-BootWimSize' {
    It 'rejects a file over 3 GB' {
        $f = Join-Path $script:TempRoot "micpe-big-$(Get-Random).wim"
        $stream = [System.IO.File]::Create($f)
        try { $stream.SetLength(3GB + 1) } finally { $stream.Dispose() }

        { Assert-BootWimSize -WimPath $f } | Should -Throw '*boot.wim*'
    }

    It 'accepts a file under 3 GB' {
        $f = Join-Path $script:TempRoot "micpe-ok-$(Get-Random).wim"
        $stream = [System.IO.File]::Create($f)
        try { $stream.SetLength(1MB) } finally { $stream.Dispose() }

        { Assert-BootWimSize -WimPath $f } | Should -Not -Throw
    }
}

Describe 'Export-WimFiles' {
    It 'warns and returns when no patterns are supplied' {
        $wim = Join-Path $script:TempRoot "micpe-empty-$(Get-Random).wim"
        Set-Content -LiteralPath $wim -Value 'x'
        { Export-WimFiles -WimPath $wim -Destination $script:TempRoot -Patterns @() } |
            Should -Not -Throw
    }

    It 'throws when the wim is missing' {
        { Export-WimFiles -WimPath (Join-Path $script:TempRoot 'absent.wim') -Destination $script:TempRoot -Patterns @('Windows\a') } |
            Should -Throw '*not found*'
    }

    It 'passes --preserve-dir-structure so files land at their nested paths' {
        # wimlib flattens PATH arguments into the destination by default
        # (Build run 44027407243 died on the SOFTWARE hive for exactly
        # this); the flag is what keeps the archive paths.
        $wim = Join-Path $script:TempRoot "micpe-flag-$(Get-Random).wim"
        Set-Content -LiteralPath $wim -Value 'x'
        $log = Join-Path $script:TempRoot "micpe-wimlib-log-$(Get-Random).txt"
        $env:MICPE_FAKE_WIMLIB_LOG = $log
        try {
            Export-WimFiles -WimPath $wim -Destination $script:TempRoot -Patterns @('Windows\explorer.exe') -WimlibPath $script:fakeWimlib
            $logged = Get-Content -LiteralPath $log -Raw
            $logged | Should -Match ([regex]::Escape('--preserve-dir-structure'))
            $logged | Should -Match ([regex]::Escape('--dest-dir='))
        }
        finally {
            Remove-Item Env:MICPE_FAKE_WIMLIB_LOG -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        }
    }
}
