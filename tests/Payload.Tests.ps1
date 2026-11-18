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
        Set-Content -LiteralPath (Join-Path $root 'chrome-slim.7z') -Value 'fake-7z'
        Set-Content -LiteralPath (Join-Path $root 'office2016-slim.7z') -Value 'fake-7z'
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

    It 'fails on an unslimmed Chrome (WidevineCdm or extra locales)' {
        $m = New-FakeMount
        $pay = New-FakePayloadDir
        Install-Payload -MountDir $m -PayloadDir $pay
        $app = "$m/Program Files/Google/Chrome/Application/151.0.7922.138"
        New-Item -ItemType Directory -Force -Path $app | Out-Null
        Set-Content -LiteralPath "$app/chrome.exe" -Value 'x'
        New-Item -ItemType Directory -Force -Path "$app/WidevineCdm" | Out-Null
        $msg = try { Assert-PayloadInstalled -MountDir $m -Chrome } catch { $_.Exception.Message }
        $msg | Should -Match 'WidevineCdm'

        Remove-Item -LiteralPath "$app/WidevineCdm" -Recurse -Force
        New-Item -ItemType Directory -Force -Path "$app/Locales" | Out-Null
        Set-Content -LiteralPath "$app/Locales/en-US.pak" -Value 'x'
        Set-Content -LiteralPath "$app/Locales/fr-FR.pak" -Value 'x'
        $msg = try { Assert-PayloadInstalled -MountDir $m -Chrome } catch { $_.Exception.Message }
        $msg | Should -Match 'fr-FR'

        Remove-Item -LiteralPath "$app/Locales/fr-FR.pak" -Force
        { Assert-PayloadInstalled -MountDir $m -Chrome } | Should -Not -Throw
    }

    It 'fails on an unslimmed Office (MSACCESS.EXE or vendor scripts)' {
        $m = New-FakeMount
        $pay = New-FakePayloadDir
        Install-Payload -MountDir $m -PayloadDir $pay
        $dir = "$m/Program Files/Office2016/Office16"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath "$dir/WINWORD.EXE" -Value 'x'
        Set-Content -LiteralPath "$dir/MSACCESS.EXE" -Value 'x'
        $msg = try { Assert-PayloadInstalled -MountDir $m -Office } catch { $_.Exception.Message }
        $msg | Should -Match 'MSACCESS'

        Remove-Item -LiteralPath "$dir/MSACCESS.EXE" -Force
        Set-Content -LiteralPath "$m/Program Files/Office2016/!)inst.cmd" -Value 'x'
        $msg = try { Assert-PayloadInstalled -MountDir $m -Office } catch { $_.Exception.Message }
        $msg | Should -Match 'inst\.cmd'

        Remove-Item -LiteralPath "$m/Program Files/Office2016/!)inst.cmd" -Force
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

Describe 'app packages (packaging round: committed in app/, no Release downloads)' {
    It 'maps each package to its joined-archive name' {
        Get-AppPackageArchiveName -Name 'payload' | Should -Be 'micpe-payload.7z'
        Get-AppPackageArchiveName -Name 'chrome'  | Should -Be 'chrome-slim.7z'
        Get-AppPackageArchiveName -Name 'office'  | Should -Be 'office2016-slim.7z'
    }

    It 'maps each package to its committed volumes, in join order' {
        $chrome = Get-AppPackageVolumePaths -Name 'chrome' -RepoRoot $script:RepoRoot
        ($chrome | ForEach-Object { Split-Path -Leaf $_ }) -join ',' |
            Should -Be 'chrome-slim.7z.001,chrome-slim.7z.002'
        $office = Get-AppPackageVolumePaths -Name 'office' -RepoRoot $script:RepoRoot
        ($office | ForEach-Object { Split-Path -Leaf $_ }) -join ',' |
            Should -Be 'office2016-slim.7z.001,office2016-slim.7z.002'
        (Get-AppPackageVolumePaths -Name 'payload' -RepoRoot $script:RepoRoot).Count |
            Should -Be 1
    }

    It 'every committed volume exists and fits GitHub single-file limit (100 MB)' {
        foreach ($name in 'payload', 'chrome', 'office') {
            foreach ($volume in (Get-AppPackageVolumePaths -Name $name -RepoRoot $script:RepoRoot)) {
                $volume | Should -Exist -Because "$name volume $volume must be committed in app/"
                (Get-Item -LiteralPath $volume).Length | Should -BeLessOrEqual 100000000
            }
        }
    }

    It 'rejects an unknown package name' {
        { Get-AppPackageArchiveName -Name 'nope' } | Should -Throw
        { Get-AppPackageVolumePaths -Name 'nope' -RepoRoot $script:RepoRoot } | Should -Throw
        { Get-PayloadExpectedHash -Name 'nope' } | Should -Throw
    }

    It 'pins a SHA256 for every package (joined archive, not a volume)' {
        Get-PayloadExpectedHash -Name 'payload' | Should -Be 'c95737c250d34244a548d12c983f8c73aa479271d4889201429fac5c9960319e'
        Get-PayloadExpectedHash -Name 'chrome'  | Should -Be 'df82dc28b2e0615656dae8b362eab15dd0d8efea7941a78a5e79d0f1a95ca626'
        Get-PayloadExpectedHash -Name 'office'  | Should -Be '8a5ec5d7d8b77303029769f2f9e043b5f6c98e0cdd7cf5d6b56dc8e2ef6301f7'
    }

    It 'the committed volumes join to the pinned hash' {
        foreach ($name in 'chrome', 'office') {
            $staging = Join-Path $script:TempRoot "join-$(Get-Random)"
            try {
                $file = Get-AppPackageArchive -Name $name -RepoRoot $script:RepoRoot -StagingDir $staging
                (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower() |
                    Should -Be (Get-PayloadExpectedHash -Name $name)
            }
            finally {
                # The joined archives are 125-167 MB each; /tmp is a small
                # tmpfs, so never leave them behind after the check.
                Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Join-AppPackageVolumes' {
    It 'concatenates volumes byte-exactly, in order' {
        $dir = Join-Path $script:TempRoot "vol-$(Get-Random)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'a.001'), [byte[]](65, 66, 67))
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'a.002'), [byte[]](68, 69))
        $out = Join-Path $dir 'joined.bin'
        Join-AppPackageVolumes -Volumes @((Join-Path $dir 'a.001'), (Join-Path $dir 'a.002')) -OutFile $out
        [System.IO.File]::ReadAllBytes($out) -join ',' | Should -Be '65,66,67,68,69'
    }

    It 'fails loudly on a missing volume instead of joining a truncated file' {
        $dir = Join-Path $script:TempRoot "vol2-$(Get-Random)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'a.001') -Value 'x' -NoNewline
        { Join-AppPackageVolumes -Volumes @((Join-Path $dir 'a.001'), (Join-Path $dir 'a.002')) -OutFile (Join-Path $dir 'out') } |
            Should -Throw '*volume*'
    }

    It 'reverse control: swapping the volume order changes the bytes' {
        $dir = Join-Path $script:TempRoot "vol3-$(Get-Random)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'a.001'), [byte[]](65, 66))
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'a.002'), [byte[]](67, 68))
        $fwd = Join-Path $dir 'fwd.bin'
        $rev = Join-Path $dir 'rev.bin'
        Join-AppPackageVolumes -Volumes @((Join-Path $dir 'a.001'), (Join-Path $dir 'a.002')) -OutFile $fwd
        Join-AppPackageVolumes -Volumes @((Join-Path $dir 'a.002'), (Join-Path $dir 'a.001')) -OutFile $rev
        (Get-FileHash -LiteralPath $fwd -Algorithm SHA256).Hash |
            Should -Not -Be (Get-FileHash -LiteralPath $rev -Algorithm SHA256).Hash
    }
}

Describe 'Get-AppPackageArchive hash gate' {
    It 'refuses a joined archive whose hash does not match the pin' {
        # Build a fake repo tree with volumes that join to the wrong bytes.
        $fakeRepo = Join-Path $script:TempRoot "fakeapp-$(Get-Random)"
        foreach ($name in 'chrome') {
            $dir = New-Item -ItemType Directory -Path (Join-Path $fakeRepo "app/$name") -Force
            Set-Content -LiteralPath (Join-Path $dir 'chrome-slim.7z.001') -Value 'tampered-1' -NoNewline
            Set-Content -LiteralPath (Join-Path $dir 'chrome-slim.7z.002') -Value 'tampered-2' -NoNewline
        }
        $staging = Join-Path $script:TempRoot "stage-$(Get-Random)"
        { Get-AppPackageArchive -Name 'chrome' -RepoRoot $fakeRepo -StagingDir $staging } |
            Should -Throw '*hash mismatch*'
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

    It 'invokes the chrome install.bat with the staged chrome-slim.7z' {
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
        Test-Path -LiteralPath (Join-Path $script:RepoRoot 'app/chrome/chrome-slim.7z') | Should -BeTrue
        # The staged archive is build-workspace residue, not a repo file
        # (*.7z is git-ignored); clean it up so the tree stays tidy.
        Remove-Item -LiteralPath (Join-Path $script:RepoRoot 'app/chrome/chrome-slim.7z') -Force -ErrorAction SilentlyContinue
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
        Test-Path -LiteralPath (Join-Path $script:RepoRoot 'app/office/office2016-slim.7z') | Should -BeTrue
        Remove-Item -LiteralPath (Join-Path $script:RepoRoot 'app/office/office2016-slim.7z') -Force -ErrorAction SilentlyContinue
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
        Remove-Item -LiteralPath (Join-Path $pay 'chrome-slim.7z') -Force
        { Install-Payload -MountDir $m -PayloadDir $pay -Chrome -RepoRoot $script:RepoRoot } | Should -Throw '*chrome asset*'
    }
}

Describe 'component install.bat files' {
    It 'chrome install.bat extracts the slimmed 7z into Google\Chrome\Application' {
        $bat = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'app/chrome/install.bat') -Raw
        $bat | Should -Match '7z x'
        $bat | Should -Match 'chrome-slim\.7z'
        $bat | Should -Match 'Chrome-bin'
        $bat | Should -Match 'Program Files\\Google\\Chrome'
        $bat | Should -Match 'Application'
        $bat | Should -Match 'chrome\.exe'
        $bat | Should -Match 'exit /b 0'
        $bat | Should -Match 'NEVER runs inside the PE'
        # No msiexec anymore: the MSI route died with the Release downloads.
        $bat | Should -Not -Match 'msiexec'
        $bat | Should -Not -Match 'TARGETDIR'
    }

    It 'office install.bat extracts the slimmed 7z into Office2016 and checks WINWORD.EXE' {
        $bat = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'app/office/install.bat') -Raw
        $bat | Should -Match '7z x'
        $bat | Should -Match 'office2016-slim\.7z'
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
