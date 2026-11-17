BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Payload.ps1"
    $script:TempRoot = [System.IO.Path]::GetTempPath()
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path

    function New-FakeMount {
        $root = Join-Path $script:TempRoot "mnt-$(Get-Random)"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return $root
    }

    function New-FakePayloadTree {
        # Minimal tree with the files Expand-Payload and
        # Assert-PayloadInstalled care about.
        $root = Join-Path $script:TempRoot "tree-$(Get-Random)"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        foreach ($rel in '7-zip/7z.exe',
                        'MICPE/PENetwork/PENetwork.exe',
                        'MICPE/PECMD.EXE',
                        'DiskGenius.exe',
                        'WinNTSetup/unattend/Win10_x64.xml') {
            $file = Join-Path $root $rel
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
            Set-Content -LiteralPath $file -Value 'x'
        }
        return $root
    }

    function New-FakePayloadDir {
        # A staging dir as Expand-Payload leaves it: ProgramFiles/ + the
        # two installer assets next to it.
        $root = Join-Path $script:TempRoot "pay-$(Get-Random)"
        $tree = New-FakePayloadTree
        $programFiles = Join-Path $root 'ProgramFiles'
        New-Item -ItemType Directory -Path $programFiles -Force | Out-Null
        Copy-Item -Path (Join-Path $tree '*') -Destination $programFiles -Recurse -Force
        Set-Content -LiteralPath (Join-Path $root 'chrome-enterprise-x64.msi') -Value 'fake-msi'
        Set-Content -LiteralPath (Join-Path $root 'office2016-green.7z') -Value 'fake-7z'
        return $root
    }
}

Describe 'Assert-PayloadInstalled' {
    It 'names every missing required item' {
        $m = New-FakeMount
        $msg = try { Assert-PayloadInstalled -MountDir $m } catch { $_.Exception.Message }
        # Match on file names only: the separator in the message is
        # Join-Path's, i.e. '/' on Linux and '\' on Windows.
        $msg | Should -Match '7z\.exe'
        $msg | Should -Match 'PENetwork\.exe'
        $msg | Should -Match 'PECMD\.EXE'
        $msg | Should -Match 'DiskGenius\.exe'
        $msg | Should -Match 'Win10_x64\.xml'
    }

    It 'passes when all artifacts exist' {
        $m = New-FakeMount
        $pay = New-FakePayloadDir
        Install-Payload -MountDir $m -PayloadDir $pay
        { Assert-PayloadInstalled -MountDir $m } | Should -Not -Throw
    }

    It 'requires chrome.exe under Google\Chrome when -Chrome' {
        $m = New-FakeMount
        $pay = New-FakePayloadDir
        Install-Payload -MountDir $m -PayloadDir $pay
        $msg = try { Assert-PayloadInstalled -MountDir $m -Chrome } catch { $_.Exception.Message }
        $msg | Should -Match 'chrome\.exe'

        New-Item -ItemType Directory -Force -Path "$m/Program Files/Google/Chrome/Application" | Out-Null
        Set-Content -LiteralPath "$m/Program Files/Google/Chrome/Application/chrome.exe" -Value 'x'
        { Assert-PayloadInstalled -MountDir $m -Chrome } | Should -Not -Throw
    }

    It 'requires WINWORD.EXE when -Office' {
        $m = New-FakeMount
        $pay = New-FakePayloadDir
        Install-Payload -MountDir $m -PayloadDir $pay
        $msg = try { Assert-PayloadInstalled -MountDir $m -Office } catch { $_.Exception.Message }
        $msg | Should -Match 'WINWORD\.EXE'

        New-Item -ItemType Directory -Force -Path "$m/Program Files/Office2016/Office16" | Out-Null
        Set-Content -LiteralPath "$m/Program Files/Office2016/Office16/WINWORD.EXE" -Value 'x'
        { Assert-PayloadInstalled -MountDir $m -Office } | Should -Not -Throw
    }

    It 'does not require MICPE-Setup.wcs (M6 owns that file)' {
        # The plan interface lists it, but no .wcs file exists anywhere in
        # the recovered materials and probe.cmd does not check it either.
        $m = New-FakeMount
        $pay = New-FakePayloadDir
        Install-Payload -MountDir $m -PayloadDir $pay
        { Assert-PayloadInstalled -MountDir $m } | Should -Not -Throw
    }
}

Describe 'payload releases' {
    It 'maps each package to its own release tag' {
        Get-PayloadRelease -Name 'payload' | Should -Be 'payload-v1'
        Get-PayloadRelease -Name 'chrome'  | Should -Be 'chrome-v1'
        Get-PayloadRelease -Name 'office'  | Should -Be 'office-v1'
    }

    It 'maps each package to its own asset name' {
        Get-PayloadAsset -Name 'payload' | Should -Be 'micpe-payload.7z'
        Get-PayloadAsset -Name 'chrome'  | Should -Be 'chrome-enterprise-x64.msi'
        Get-PayloadAsset -Name 'office'  | Should -Be 'office2016-green.7z'
    }

    It 'rejects an unknown package name' {
        { Get-PayloadRelease -Name 'nope' } | Should -Throw
        { Get-PayloadAsset -Name 'nope' } | Should -Throw
        { Get-PayloadExpectedHash -Name 'nope' } | Should -Throw
    }

    It 'pins a SHA256 for every package' {
        Get-PayloadExpectedHash -Name 'payload' | Should -Be 'c95737c250d34244a548d12c983f8c73aa479271d4889201429fac5c9960319e'
        Get-PayloadExpectedHash -Name 'chrome'  | Should -Be '0ec77319d917eb232f1b1b52e0f6f6178eacb2d5abff1517f5c17d50a0a2db1a'
        Get-PayloadExpectedHash -Name 'office'  | Should -Be '8bb9a924b72e5d70968121d1ed88df8bea74823e4f8aed1598d766b2a3cb7caf'
    }
}

Describe 'Test-PayloadFileHash' {
    It 'accepts a matching file and rejects a different one' {
        $f = Join-Path $script:TempRoot "hash-$(Get-Random).bin"
        Set-Content -LiteralPath $f -Value 'micpe-payload-test' -NoNewline
        $good = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
        Test-PayloadFileHash -Path $f -ExpectedHash $good | Should -BeTrue
        Test-PayloadFileHash -Path $f -ExpectedHash ('0' * 64) | Should -BeFalse
    }
}

Describe 'Expand-Payload' {
    It 'expands the archive and verifies the required files' {
        if (-not (Get-Command '7z' -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'needs 7z on PATH'; return
        }

        $tree = New-FakePayloadTree

        # Expand-Payload expects the archive to contain ProgramFiles/ at
        # the top, so build the fixture that way.
        $staging = Join-Path $script:TempRoot "stage-$(Get-Random)"
        New-Item -ItemType Directory -Path "$staging/ProgramFiles" -Force | Out-Null
        Copy-Item -Path (Join-Path $tree '*') -Destination "$staging/ProgramFiles" -Recurse -Force
        $archive2 = Join-Path $script:TempRoot "payload2-$(Get-Random).7z"
        Push-Location $staging
        try {
            $null = & 7z a -mx=5 $archive2 ProgramFiles 2>&1
            if ($LASTEXITCODE -ne 0) { throw 'fixture 7z build failed' }
        }
        finally {
            Pop-Location
        }

        $dest = Join-Path $script:TempRoot "exp-$(Get-Random)"
        Expand-Payload -Archive $archive2 -Destination $dest
        Test-Path -LiteralPath "$dest/ProgramFiles/7-zip/7z.exe" | Should -BeTrue
        Test-Path -LiteralPath "$dest/ProgramFiles/MICPE/PENetwork/PENetwork.exe" | Should -BeTrue
    }

    It 'fails when the archive lacks the required files' {
        if (-not (Get-Command '7z' -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'needs 7z on PATH'; return
        }

        $empty = Join-Path $script:TempRoot "empty-$(Get-Random)"
        New-Item -ItemType Directory -Path "$empty/ProgramFiles" -Force | Out-Null
        $archive = Join-Path $script:TempRoot "empty-$(Get-Random).7z"
        Push-Location $empty
        try {
            $null = & 7z a -mx=5 $archive ProgramFiles 2>&1
            if ($LASTEXITCODE -ne 0) { throw 'fixture 7z build failed' }
        }
        finally {
            Pop-Location
        }

        $dest = Join-Path $script:TempRoot "exp2-$(Get-Random)"
        { Expand-Payload -Archive $archive -Destination $dest } | Should -Throw '*7z.exe*'
    }
}

Describe 'New-PayloadArchive' {
    It 'fails loudly when PECMD.EXE is missing' {
        # Old packaging used `2>/dev/null || true` and silently shipped a
        # payload without PECMD; the image only fell back to cmd at boot.
        $tree = New-FakePayloadTree
        $out = Join-Path $script:TempRoot "nop-$(Get-Random).7z"
        { New-PayloadArchive -PayloadTreeDir $tree -PecmdExe (Join-Path $script:TempRoot 'absent-pecmd.exe') -OutArchive $out } | Should -Throw '*PECMD.EXE*'
    }

    It 'builds a reproducible archive with PECMD.EXE inside' {
        if (-not (Get-Command '7z' -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'needs 7z on PATH'; return
        }

        $tree = New-FakePayloadTree
        $pecmd = Join-Path $script:TempRoot "pecmd-$(Get-Random).exe"
        Set-Content -LiteralPath $pecmd -Value 'fake-pecmd-binary'
        $out1 = Join-Path $script:TempRoot "arc1-$(Get-Random).7z"
        $out2 = Join-Path $script:TempRoot "arc2-$(Get-Random).7z"
        $r1 = New-PayloadArchive -PayloadTreeDir $tree -PecmdExe $pecmd -OutArchive $out1
        $r2 = New-PayloadArchive -PayloadTreeDir $tree -PecmdExe $pecmd -OutArchive $out2
        $r1.Sha256 | Should -Be $r2.Sha256

        $listing = & 7z l $out1 2>&1 | Out-String
        # 7z prints paths with the host separator ('/' on Linux, '\'
        # on Windows); accept either.
        $listing | Should -Match 'ProgramFiles[/\\]MICPE[/\\]PECMD\.EXE'
        $listing | Should -Match 'ProgramFiles[/\\]7-zip[/\\]7z\.exe'
    }
}

Describe 'Install-Payload component installers' {
    It 'copies the payload tree without any switches' {
        $m = New-FakeMount
        $pay = New-FakePayloadDir
        Install-Payload -MountDir $m -PayloadDir $pay
        Test-Path -LiteralPath "$m/Program Files/7-zip/7z.exe" | Should -BeTrue
        Test-Path -LiteralPath "$m/Program Files/MICPE/PECMD.EXE" | Should -BeTrue
        Test-Path -LiteralPath "$m/Program Files/Google/Chrome" | Should -BeFalse
    }

    It 'invokes the chrome install.bat with the staged MSI' {
        $m = New-FakeMount
        $pay = New-FakePayloadDir
        $script:called = $null
        $runner = {
            param($bat, $mount, $repo)
            $script:called = [pscustomobject]@{ Bat = $bat; Mount = $mount; Repo = $repo }
        }
        Install-Payload -MountDir $m -PayloadDir $pay -Chrome -RepoRoot $script:RepoRoot -ComponentRunner $runner
        $script:called.Bat | Should -Be (Join-Path $script:RepoRoot 'app/chrome/install.bat')
        $script:called.Mount | Should -Be $m
        Test-Path -LiteralPath (Join-Path $script:RepoRoot 'app/chrome/chrome-enterprise-x64.msi') | Should -BeTrue
        # The staged asset is build-workspace residue, not a repo file
        # (*.msi is git-ignored); clean it up so the tree stays tidy.
        Remove-Item -LiteralPath (Join-Path $script:RepoRoot 'app/chrome/chrome-enterprise-x64.msi') -Force -ErrorAction SilentlyContinue
    }

    It 'invokes the office install.bat with the staged 7z' {
        $m = New-FakeMount
        $pay = New-FakePayloadDir
        $script:called = $null
        $runner = {
            param($bat, $mount, $repo)
            $script:called = [pscustomobject]@{ Bat = $bat; Mount = $mount; Repo = $repo }
        }
        Install-Payload -MountDir $m -PayloadDir $pay -Office -RepoRoot $script:RepoRoot -ComponentRunner $runner
        $script:called.Bat | Should -Be (Join-Path $script:RepoRoot 'app/office/install.bat')
        Test-Path -LiteralPath (Join-Path $script:RepoRoot 'app/office/office2016-green.7z') | Should -BeTrue
        Remove-Item -LiteralPath (Join-Path $script:RepoRoot 'app/office/office2016-green.7z') -Force -ErrorAction SilentlyContinue
    }

    It 'requires -RepoRoot when a component switch is set' {
        $m = New-FakeMount
        $pay = New-FakePayloadDir
        { Install-Payload -MountDir $m -PayloadDir $pay -Chrome } | Should -Throw '*RepoRoot*'
        { Install-Payload -MountDir $m -PayloadDir $pay -Office } | Should -Throw '*RepoRoot*'
    }

    It 'fails when the staged installer asset is missing' {
        $m = New-FakeMount
        $pay = New-FakePayloadDir
        Remove-Item -LiteralPath (Join-Path $pay 'chrome-enterprise-x64.msi') -Force
        { Install-Payload -MountDir $m -PayloadDir $pay -Chrome -RepoRoot $script:RepoRoot } | Should -Throw '*chrome asset*'
    }
}

Describe 'component install.bat files' {
    It 'chrome install.bat unpacks the MSI with msiexec /a into Google\Chrome' {
        $bat = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'app/chrome/install.bat') -Raw
        $bat | Should -Match 'msiexec /a'
        $bat | Should -Match 'TARGETDIR='
        $bat | Should -Match 'Program Files\\Google\\Chrome'
        $bat | Should -Match 'googlechromestandaloneenterprise64\.msi'
        $bat | Should -Match 'exit /b 0'
        $bat | Should -Match 'NEVER runs inside the PE'
    }

    It 'office install.bat extracts the 7z into Office2016 and checks WINWORD.EXE' {
        $bat = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'app/office/install.bat') -Raw
        $bat | Should -Match '7z x'
        $bat | Should -Match 'office2016-green\.7z'
        $bat | Should -Match 'Program Files\\Office2016'
        $bat | Should -Match 'WINWORD\.EXE'
        $bat | Should -Match 'exit /b 0'
        $bat | Should -Match 'NEVER runs inside the PE'
    }

    It 'both install.bats are idempotent (remove the destination first)' {
        foreach ($component in 'chrome', 'office') {
            $bat = Get-Content -LiteralPath (Join-Path $script:RepoRoot "app/$component/install.bat") -Raw
            $bat | Should -Match 'rmdir /s /q'
        }
    }
}
