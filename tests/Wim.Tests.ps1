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

Describe 'Clear-StagingReadOnly' {
    BeforeAll {
        $script:fakeAttrib = Join-Path $PSScriptRoot 'Fake-Attrib.ps1'
    }

    It 'invokes attrib twice (root, then wildcard recursive) and leaves the tree writable' {
        # run 45359151127: the shell step's StartAllBack.xml copy into
        # the WIM-extracted icsxml directory was denied (the directory
        # carries the install.wim's read-only attribute), while the copy
        # into the script-created MICPE directory succeeded.
        # run 45368774235: the bare-path spelling (`attrib -R <path>
        # /S /D`) ran without error but the copy was still denied --
        # /S only applies to "matching files", and the documented
        # recursive spelling is the wildcard form
        # (`attrib -r b:\public\*.* /s`), so the root is cleared first
        # and then everything under it with the wildcard.
        $dir = Join-Path $script:TempRoot "micpe-ro-$(Get-Random)"
        $sub = New-Item -ItemType Directory -Path (Join-Path $dir 'icsxml') -Force
        $file = Join-Path $sub 'cmnicfg.xml'
        Set-Content -LiteralPath $file -Value 'x'
        # Mark the directory and the file read-only, as wimlib extraction
        # leaves them (DOS attributes restored from the install.wim).
        $subItem = Get-Item -LiteralPath $sub -Force
        $subItem.Attributes = $subItem.Attributes -bor [IO.FileAttributes]::ReadOnly
        $fileItem = Get-Item -LiteralPath $file -Force
        $fileItem.Attributes = $fileItem.Attributes -bor [IO.FileAttributes]::ReadOnly
        ((Get-Item -LiteralPath $sub -Force).Attributes -band [IO.FileAttributes]::ReadOnly) | Should -Not -Be 0
        $log = Join-Path $script:TempRoot "micpe-attrib-$(Get-Random).log"
        $env:MICPE_FAKE_ATTRIB_LOG = $log
        try {
            Clear-StagingReadOnly -Path $dir -AttribPath $script:fakeAttrib
            $logged = Get-Content -LiteralPath $log
            # Call 1: clear the root directory itself.
            $logged[0] | Should -Be '-R'
            $logged[1] | Should -Be $dir
            $logged[2] | Should -Be '/D'
            # Call 2: clear everything under it, wildcard recursive.
            $logged[3] | Should -Be '-R'
            $logged[4] | Should -Be "$dir\*.*"
            $logged[5] | Should -Be '/S'
            $logged[6] | Should -Be '/D'
            # The tree is writable again (the fake stands in for attrib).
            ((Get-Item -LiteralPath $sub -Force).Attributes -band [IO.FileAttributes]::ReadOnly) | Should -Be 0
            ((Get-Item -LiteralPath $file -Force).Attributes -band [IO.FileAttributes]::ReadOnly) | Should -Be 0
        }
        finally {
            Remove-Item Env:MICPE_FAKE_ATTRIB_LOG -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws when the staging path does not exist' {
        { Clear-StagingReadOnly -Path (Join-Path $script:TempRoot 'micpe-absent-staging') -AttribPath $script:fakeAttrib } | Should -Throw '*staging tree*'
    }

    # No test for the non-zero exit-code path: $LASTEXITCODE is not set
    # inside a function on Linux pwsh (verified: a native command exiting
    # 1 leaves $LASTEXITCODE 0 in a function, 1 at the top level), so a
    # failing attrib cannot be simulated here. The check follows the
    # codebase pattern (Export-WimFiles, Get-WimBootIndex) and works on
    # the Windows CI runner, where the build actually runs.
}

Describe 'Grant-StagingWriteAccess' {
    BeforeAll {
        $script:fakeTakeown = Join-Path $PSScriptRoot 'Fake-Takeown.ps1'
        $script:fakeIcacls = Join-Path $PSScriptRoot 'Fake-Icacls.ps1'
        $script:fakeAttrib = Join-Path $PSScriptRoot 'Fake-Attrib.ps1'
    }

    It 'takes ownership and grants Administrators full control on a directory' {
        # run 45368774235: Clear-StagingReadOnly ran without error and
        # the icsxml copy was still denied -- a directory's read-only
        # flag does not block creating files inside it, so the blocker
        # is the ACL (TrustedInstaller ownership). Same takeown +
        # icacls pattern as Grant-FolderWriteAccess (UwpChain.ps1).
        $dir = Join-Path $script:TempRoot "micpe-grant-$(Get-Random)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $takeownLog = Join-Path $script:TempRoot "micpe-takeown-$(Get-Random).log"
        $icaclsLog = Join-Path $script:TempRoot "micpe-icacls-$(Get-Random).log"
        $attribLog = Join-Path $script:TempRoot "micpe-attrib-$(Get-Random).log"
        $env:MICPE_FAKE_TAKEOWN_LOG = $takeownLog
        $env:MICPE_FAKE_ICACLS_LOG = $icaclsLog
        $env:MICPE_FAKE_ATTRIB_LOG = $attribLog
        try {
            Grant-StagingWriteAccess -Path $dir -TakeownPath $script:fakeTakeown -IcaclsPath $script:fakeIcacls -AttribPath $script:fakeAttrib
            $takeown = @(Get-Content -LiteralPath $takeownLog)
            $takeown[0] | Should -Be '/F'
            $takeown[1] | Should -Be $dir
            $takeown[2] | Should -Be '/A'
            # Round 39: takeown must recurse, or the GUID subdirs and
            # .cat files underneath stay owned by TrustedInstaller and
            # the icacls grant cannot land on them (round 38).
            $takeown[3] | Should -Be '/R'
            $takeown[4] | Should -Be '/D'
            $takeown[5] | Should -Be 'Y'
            $icacls = @(Get-Content -LiteralPath $icaclsLog)
            $icacls[0] | Should -Be $dir
            $icacls[1] | Should -Be '/Grant'
            $icacls[2] | Should -Be '*S-1-5-32-544:(OI)(CI)F'
            $icacls[3] | Should -Be '/T'
            $icacls[4] | Should -Be '/C'
            $attrib = @(Get-Content -LiteralPath $attribLog)
            $attrib[0] | Should -Be '-R'
            $attrib[1] | Should -Be "$dir\*.*"
            $attrib[2] | Should -Be '/S'
            $attrib[3] | Should -Be '/D'
        }
        finally {
            Remove-Item Env:MICPE_FAKE_TAKEOWN_LOG -ErrorAction SilentlyContinue
            Remove-Item Env:MICPE_FAKE_ICACLS_LOG -ErrorAction SilentlyContinue
            Remove-Item Env:MICPE_FAKE_ATTRIB_LOG -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $takeownLog -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $icaclsLog -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $attribLog -Force -ErrorAction SilentlyContinue
        }
    }

    It 'grants on the file itself (no recursion) for a file' {
        $dir = Join-Path $script:TempRoot "micpe-grant-$(Get-Random)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $file = Join-Path $dir 'SYSTEM'
        Set-Content -LiteralPath $file -Value 'x'
        $takeownLog = Join-Path $script:TempRoot "micpe-takeown-$(Get-Random).log"
        $icaclsLog = Join-Path $script:TempRoot "micpe-icacls-$(Get-Random).log"
        $attribLog = Join-Path $script:TempRoot "micpe-attrib-$(Get-Random).log"
        $env:MICPE_FAKE_TAKEOWN_LOG = $takeownLog
        $env:MICPE_FAKE_ICACLS_LOG = $icaclsLog
        $env:MICPE_FAKE_ATTRIB_LOG = $attribLog
        try {
            Grant-StagingWriteAccess -Path $file -TakeownPath $script:fakeTakeown -IcaclsPath $script:fakeIcacls -AttribPath $script:fakeAttrib
            $takeown = @(Get-Content -LiteralPath $takeownLog)
            $takeown[0] | Should -Be '/F'
            $takeown[1] | Should -Be $file
            $takeown[2] | Should -Be '/A'
            # Files have no children: no recursion (round 39).
            $takeown | Should -HaveCount 3
            $icacls = @(Get-Content -LiteralPath $icaclsLog)
            $icacls[0] | Should -Be $file
            $icacls[1] | Should -Be '/Grant'
            $icacls[2] | Should -Be '*S-1-5-32-544:F'
            $icacls[3] | Should -Be '/C'
            $attrib = @(Get-Content -LiteralPath $attribLog)
            $attrib[0] | Should -Be '-R'
            $attrib[1] | Should -Be $file
        }
        finally {
            Remove-Item Env:MICPE_FAKE_TAKEOWN_LOG -ErrorAction SilentlyContinue
            Remove-Item Env:MICPE_FAKE_ICACLS_LOG -ErrorAction SilentlyContinue
            Remove-Item Env:MICPE_FAKE_ATTRIB_LOG -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $takeownLog -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $icaclsLog -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $attribLog -Force -ErrorAction SilentlyContinue
        }
    }

    It 'is a no-op when the path does not exist' {
        { Grant-StagingWriteAccess -Path (Join-Path $script:TempRoot 'micpe-absent-grant') -TakeownPath $script:fakeTakeown -IcaclsPath $script:fakeIcacls -AttribPath $script:fakeAttrib } | Should -Not -Throw
    }

    # No test for the takeown/icacls failure path: $LASTEXITCODE is
    # not set inside a function on Linux pwsh (verified: a native
    # command exiting 3 leaves $LASTEXITCODE 0 in a function, 3 at
    # the top level, and a .ps1 fake's assignment does not propagate
    # either), so a failing takeown cannot be simulated here. The
    # check follows the codebase pattern (Clear-StagingReadOnly) and
    # works on the Windows CI runner, where the build actually runs.
    # The write probe (Show-StagingWriteState -AssertWritable) is the
    # locally testable arbiter of whether a grant took.
}

Describe 'Show-StagingWriteState' {
    BeforeAll {
        $script:fakeAttrib = Join-Path $PSScriptRoot 'Fake-Attrib.ps1'
        $script:fakeIcacls = Join-Path $PSScriptRoot 'Fake-Icacls.ps1'
    }

    It 'invokes attrib and icacls on the path and leaves no probe file behind' {
        # run 45368774235: the diagnostic that must run before the
        # icsxml copy -- attrib + icacls state plus a write probe, so
        # the log shows whether the grant actually took.
        $dir = Join-Path $script:TempRoot "micpe-state-$(Get-Random)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $attribLog = Join-Path $script:TempRoot "micpe-attrib-$(Get-Random).log"
        $icaclsLog = Join-Path $script:TempRoot "micpe-icacls-$(Get-Random).log"
        $env:MICPE_FAKE_ATTRIB_LOG = $attribLog
        $env:MICPE_FAKE_ICACLS_LOG = $icaclsLog
        try {
            Show-StagingWriteState -Path $dir -Label 'test' -AttribPath $script:fakeAttrib -IcaclsPath $script:fakeIcacls
            $attrib = @(Get-Content -LiteralPath $attribLog)
            $attrib[0] | Should -Be $dir
            $icacls = @(Get-Content -LiteralPath $icaclsLog)
            $icacls[0] | Should -Be $dir
            # The write probe is deleted immediately, never left behind.
            (Test-Path -LiteralPath (Join-Path $dir 'micpe-write-probe.tmp')) | Should -Be $false
        }
        finally {
            Remove-Item Env:MICPE_FAKE_ATTRIB_LOG -ErrorAction SilentlyContinue
            Remove-Item Env:MICPE_FAKE_ICACLS_LOG -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $attribLog -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $icaclsLog -Force -ErrorAction SilentlyContinue
        }
    }

    It 'lists the directory contents with -ShowContents' {
        $dir = Join-Path $script:TempRoot "micpe-state-$(Get-Random)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'a.xml') -Value 'x'
        $attribLog = Join-Path $script:TempRoot "micpe-attrib-$(Get-Random).log"
        $icaclsLog = Join-Path $script:TempRoot "micpe-icacls-$(Get-Random).log"
        $env:MICPE_FAKE_ATTRIB_LOG = $attribLog
        $env:MICPE_FAKE_ICACLS_LOG = $icaclsLog
        try {
            Show-StagingWriteState -Path $dir -Label 'test' -ShowContents -AttribPath $script:fakeAttrib -IcaclsPath $script:fakeIcacls
            $attrib = @(Get-Content -LiteralPath $attribLog)
            # Call 1: the directory itself. Call 2: its contents (wildcard).
            $attrib[0] | Should -Be $dir
            $attrib[1] | Should -Be "$dir\*.*"
        }
        finally {
            Remove-Item Env:MICPE_FAKE_ATTRIB_LOG -ErrorAction SilentlyContinue
            Remove-Item Env:MICPE_FAKE_ICACLS_LOG -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $attribLog -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $icaclsLog -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports a missing path instead of throwing' {
        { Show-StagingWriteState -Path (Join-Path $script:TempRoot 'micpe-absent-state') -Label 'test' -AttribPath $script:fakeAttrib -IcaclsPath $script:fakeIcacls } | Should -Not -Throw
    }

    It 'passes -AssertWritable on a writable directory and leaves no probe file behind' {
        $dir = Join-Path $script:TempRoot "micpe-state-$(Get-Random)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            { Show-StagingWriteState -Path $dir -Label 'test' -AssertWritable -AttribPath $script:fakeAttrib -IcaclsPath $script:fakeIcacls } | Should -Not -Throw
            (Test-Path -LiteralPath (Join-Path $dir 'micpe-write-probe.tmp')) | Should -Be $false
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws -AssertWritable on a missing path' {
        # Round 39: the base step probes the CatRoot GUID directory
        # right after the grant; if it is not there the .cat copy
        # would fail anyway, so the probe must fail loudly here.
        { Show-StagingWriteState -Path (Join-Path $script:TempRoot 'micpe-absent-state') -Label 'test' -AssertWritable -AttribPath $script:fakeAttrib -IcaclsPath $script:fakeIcacls } | Should -Throw '*does not exist*'
    }

    # No test for the DENIED write probe: on Linux the tests run as
    # root, which bypasses directory permissions, so a read-only
    # directory still accepts the probe file. The probe logic is a
    # try/catch around a single WriteAllText call; the OK path above
    # covers the create + delete flow. The -AssertWritable DENIED
    # path is likewise untestable here and is covered by the missing-
    # path throw above plus the CI run itself.
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
