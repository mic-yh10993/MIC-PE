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

Describe 'Get-WimBootIndex / Set-WimBootIndex' {
    It 'reads the boot index back from wimlib info output' {
        # The fake answers a plain `info` with a stock two-image header
        # whose boot index is 2, i.e. the UUP media default (Windows Setup).
        $wim = Join-Path $script:TempRoot "micpe-bootidx-$(Get-Random).wim"
        Set-Content -LiteralPath $wim -Value 'x'
        Get-WimBootIndex -WimPath $wim -WimlibPath $script:fakeWimlib | Should -Be 2
    }

    It 'sets the boot image with wimlib info --boot' {
        $wim = Join-Path $script:TempRoot "micpe-bootset-$(Get-Random).wim"
        Set-Content -LiteralPath $wim -Value 'x'
        $log = Join-Path $script:TempRoot "micpe-wimlib-log-$(Get-Random).txt"
        $env:MICPE_FAKE_WIMLIB_LOG = $log
        try {
            Set-WimBootIndex -WimPath $wim -Index 1 -WimlibPath $script:fakeWimlib
            $logged = Get-Content -LiteralPath $log -Raw
            $logged | Should -Match 'info'
            $logged | Should -Match ([regex]::Escape('--boot'))
            # The fake logs one argument per line; Add-Content writes CRLF
            # on Windows, so split on either ending before matching the
            # bare '1' (a (?m)^1$ match fails on the trailing \r).
            @($logged -split "`r?`n") | Should -Contain '1'
        }
        finally {
            Remove-Item Env:MICPE_FAKE_WIMLIB_LOG -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws when the wim is missing' {
        { Get-WimBootIndex -WimPath (Join-Path $script:TempRoot 'absent.wim') -WimlibPath $script:fakeWimlib } |
            Should -Throw '*not found*'
        { Set-WimBootIndex -WimPath (Join-Path $script:TempRoot 'absent.wim') -Index 1 -WimlibPath $script:fakeWimlib } |
            Should -Throw '*not found*'
    }
}

Describe 'Get-WimImageIndexByEdition' {
    BeforeAll {
        # Realistic wimlib-imagex info output for a freshly generated UUP
        # install.wim: the header carries "Boot Index: 0" (no boot image
        # assigned yet) and the image blocks follow. The old regex matched
        # the "Index:" inside "Boot Index:" and returned 0, which wimlib
        # rejects (error 18, indexes start at 1); run 45349073419 died
        # on exactly that (241 batches, 0/12021 files).
        $script:singleProInfo = @(
            'WIM Information:',
            'Image Count:    1',
            'Boot Index:     0',
            '',
            'Available Images:',
            'Index:                  1',
            'Name:                   Windows 11 Pro',
            'Description:            Windows 11 Pro',
            'Edition ID:             Professional'
        ) -join "`n"
        $script:twoImageInfo = @(
            'WIM Information:',
            'Image Count:    2',
            'Boot Index:     0',
            '',
            'Available Images:',
            'Index:                  1',
            'Name:                   Windows 11 Pro',
            'Edition ID:             Professional',
            '',
            'Index:                  2',
            'Name:                   Windows 11 Home',
            'Edition ID:             Core'
        ) -join "`n"
    }

    It 'does not mistake Boot Index 0 for image index 0 (single image)' {
        $wim = Join-Path $script:TempRoot "micpe-idx-$(Get-Random).wim"
        Set-Content -LiteralPath $wim -Value 'x'
        $env:MICPE_FAKE_WIMLIB_INFO = $script:singleProInfo
        try {
            Get-WimImageIndexByEdition -WimPath $wim -Edition 'Professional' -WimlibPath $script:fakeWimlib | Should -Be 1
        }
        finally {
            Remove-Item Env:MICPE_FAKE_WIMLIB_INFO -ErrorAction SilentlyContinue
        }
    }

    It 'finds the right index by edition when two images share Boot Index 0' {
        $wim = Join-Path $script:TempRoot "micpe-idx2-$(Get-Random).wim"
        Set-Content -LiteralPath $wim -Value 'x'
        $env:MICPE_FAKE_WIMLIB_INFO = $script:twoImageInfo
        try {
            Get-WimImageIndexByEdition -WimPath $wim -Edition 'Professional' -WimlibPath $script:fakeWimlib | Should -Be 1
            Get-WimImageIndexByEdition -WimPath $wim -Edition 'Core' -WimlibPath $script:fakeWimlib | Should -Be 2
        }
        finally {
            Remove-Item Env:MICPE_FAKE_WIMLIB_INFO -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-IsoStep boot image' {
    BeforeAll {
        $script:buildScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/build/Build-Micpe.ps1') -Raw
    }

    It 'points the boot image at index 1 before packaging' {
        # run 44062469206: the UUP media boots image 2 (Setup) unless told
        # otherwise, while every build step customises image 1 (PE). The
        # boot image must be set (and read back) in the ISO step, after the
        # last mount/commit, or winload starts Setup and the probe never runs.
        $script:buildScript | Should -Match 'Set-WimBootIndex -WimPath \$bootWim -Index 1'
        $script:buildScript | Should -Match 'Get-WimBootIndex -WimPath \$bootWim'
        $script:buildScript | Should -Match 'bootIndex -eq 1'
    }
}
