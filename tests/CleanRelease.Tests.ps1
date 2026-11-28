BeforeAll {
    . "$PSScriptRoot/../src/ci/Publish-CleanRelease.ps1"
    $script:TempRoot = [System.IO.Path]::GetTempPath()

    # Helpers live in BeforeAll: Pester runs Describe blocks in their own
    # scope, so top-level function definitions are not visible inside It.
    function New-FakeGh {
        # A fake `gh` CLI: records every call and simulates success or
        # failure per test. Returned as a hashtable so the test can flip
        # behaviour after creation (the closure holds the same hashtable
        # reference, so mutations are visible to the fake).
        $state = @{
            Calls          = [System.Collections.Generic.List[object]]::new()
            ViewExit       = 1     # 1 = release does not exist, 0 = exists
            ViewExitQueue  = [System.Collections.Generic.Queue[int]]::new()
            FailCreate     = $false
            FailAllUploads = $false
            FailFiles      = @()   # leaf names whose upload fails
        }
        $invoker = {
            param([string[]] $GhArgs)
            $state.Calls.Add($GhArgs)
            if ($GhArgs[1] -eq 'view') {
                # A queued exit code wins (lets a test fail the first
                # view and succeed on the retry); otherwise ViewExit.
                if ($state.ViewExitQueue.Count -gt 0) { return [int]$state.ViewExitQueue.Dequeue() }
                return [int]$state.ViewExit
            }
            if ($GhArgs[1] -eq 'create') {
                if ($state.FailCreate) { return 1 }
                return 0
            }
            if ($GhArgs[1] -eq 'upload') {
                if ($state.FailAllUploads) { return 1 }
                foreach ($arg in $GhArgs) {
                    if ($state.FailFiles -contains (Split-Path -Leaf $arg)) { return 1 }
                }
                return 0
            }
            return 0
        }.GetNewClosure()
        return @{ State = $state; Invoker = $invoker }
    }

    function New-TestReleaseDir {
        # A temp dir with a non-empty ISO, boot.wim and checksums file.
        # Returns a hashtable with the dir and the three core paths.
        $dir = Join-Path $script:TempRoot "clean-release-$(Get-Random)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $iso = Join-Path $dir 'MICPE-clean.iso'
        $wim = Join-Path $dir 'boot.wim'
        $checksums = Join-Path $dir 'checksums.sha256'
        Set-Content -LiteralPath $iso -Value 'fake iso bytes' -Encoding ASCII
        Set-Content -LiteralPath $wim -Value 'fake wim bytes' -Encoding ASCII
        Set-Content -LiteralPath $checksums -Value 'fake checksums' -Encoding ASCII
        return @{ Dir = $dir; Iso = $iso; Wim = $wim; Checksums = $checksums }
    }

    function New-FakeAssetLister {
        # A fake asset lister: reports the given name -> size table, or
        # $null when $Assets is $null (release missing / unlistable).
        param($Assets)
        $table = $Assets
        $lister = {
            param([string] $Tag, [string] $Repository)
            return $table
        }.GetNewClosure()
        return $lister
    }
}

Describe 'Select-NonEmptyReleaseFile' {
    It 'keeps existing non-empty files and returns them in order' {
        $dir = Join-Path $script:TempRoot "clean-release-keep-$(Get-Random)"
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $a = Join-Path $dir 'a.txt'
            $b = Join-Path $dir 'b.txt'
            Set-Content -LiteralPath $a -Value 'a' -Encoding ASCII
            Set-Content -LiteralPath $b -Value 'b' -Encoding ASCII
            $kept = @(Select-NonEmptyReleaseFile -Paths @($a, $b))
            $kept.Count | Should -Be 2
            $kept[0] | Should -Be $a
            $kept[1] | Should -Be $b
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'skips a 0-byte file and warns with its name (run 45448778057)' {
        # GitHub's release-asset upload rejects 0-byte files with HTTP 400
        # Bad Content-Length; run 45448778057 lost the whole release
        # because micpe-qemu.log was empty and rode a combined upload.
        $dir = Join-Path $script:TempRoot "clean-release-empty-$(Get-Random)"
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $good = Join-Path $dir 'shot-01.png'
            $empty = Join-Path $dir 'micpe-qemu.log'
            Set-Content -LiteralPath $good -Value 'fake png' -Encoding ASCII
            New-Item -ItemType File -Path $empty -Force | Out-Null
            $kept = @(Select-NonEmptyReleaseFile -Paths @($good, $empty) -WarningVariable warnings)
            $kept.Count | Should -Be 1
            $kept[0] | Should -Be $good
            $warnings.Count | Should -Be 1
            "$warnings" | Should -Match 'micpe-qemu\.log'
            "$warnings" | Should -Match 'empty'
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'skips a missing file and warns with its name' {
        $dir = Join-Path $script:TempRoot "clean-release-missing-$(Get-Random)"
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $good = Join-Path $dir 'shot-01.png'
            Set-Content -LiteralPath $good -Value 'fake png' -Encoding ASCII
            $missing = Join-Path $dir 'does-not-exist.log'
            $kept = @(Select-NonEmptyReleaseFile -Paths @($good, $missing) -WarningVariable warnings)
            $kept.Count | Should -Be 1
            $kept[0] | Should -Be $good
            $warnings.Count | Should -Be 1
            "$warnings" | Should -Match 'does-not-exist\.log'
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns empty for an empty list' {
        $kept = @(Select-NonEmptyReleaseFile -Paths @())
        $kept.Count | Should -Be 0
    }
}

Describe 'Publish-CleanRelease' {
    It 'creates the release with core files when it does not exist, then uploads extras one by one' {
        $rel = New-TestReleaseDir
        try {
            $fake = New-FakeGh
            $extra1 = Join-Path $rel.Dir 'shot-01.png'
            $extra2 = Join-Path $rel.Dir 'shot-02.png'
            Set-Content -LiteralPath $extra1 -Value 'fake png 1' -Encoding ASCII
            Set-Content -LiteralPath $extra2 -Value 'fake png 2' -Encoding ASCII
            Publish-CleanRelease -Tag 'micpe-clean-22621.1105-20261125-r83' `
                -CoreFiles @($rel.Iso, $rel.Wim, $rel.Checksums) `
                -ExtraFiles @($extra1, $extra2) `
                -Title 'MICPE clean 22621.1105 (20261125)' -Notes 'test notes' `
                -Repository 'mic-yh10993/MIC-PE' -GhInvoker $fake.Invoker
            $fake.State.Calls.Count | Should -Be 4
            ($fake.State.Calls[0] -join ' ') | Should -Be 'release view micpe-clean-22621.1105-20261125-r83 --repo mic-yh10993/MIC-PE'
            ($fake.State.Calls[1] -join ' ') | Should -Be "release create micpe-clean-22621.1105-20261125-r83 $($rel.Iso) $($rel.Wim) $($rel.Checksums) --repo mic-yh10993/MIC-PE --title MICPE clean 22621.1105 (20261125) --notes test notes"
            ($fake.State.Calls[2] -join ' ') | Should -Be "release upload micpe-clean-22621.1105-20261125-r83 $extra1 --repo mic-yh10993/MIC-PE --clobber"
            ($fake.State.Calls[3] -join ' ') | Should -Be "release upload micpe-clean-22621.1105-20261125-r83 $extra2 --repo mic-yh10993/MIC-PE --clobber"
        }
        finally {
            Remove-Item -LiteralPath $rel.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'uploads core files into an existing release instead of creating one' {
        $rel = New-TestReleaseDir
        try {
            $fake = New-FakeGh
            $fake.State.ViewExit = 0
            Publish-CleanRelease -Tag 'micpe-clean-22621.1105-20261125-r83' `
                -CoreFiles @($rel.Iso, $rel.Wim, $rel.Checksums) `
                -Title 'MICPE clean 22621.1105 (20261125)' -Notes 'test notes' `
                -Repository 'mic-yh10993/MIC-PE' -GhInvoker $fake.Invoker
            $fake.State.Calls.Count | Should -Be 2
            ($fake.State.Calls[1] -join ' ') | Should -Be "release upload micpe-clean-22621.1105-20261125-r83 $($rel.Iso) $($rel.Wim) $($rel.Checksums) --repo mic-yh10993/MIC-PE --clobber"
            ($fake.State.Calls -join "`n") | Should -Not -Match 'release create'
        }
        finally {
            Remove-Item -LiteralPath $rel.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'skips a 0-byte extra and still uploads the rest (run 45448778057)' {
        $rel = New-TestReleaseDir
        try {
            $fake = New-FakeGh
            $good = Join-Path $rel.Dir 'shot-01.png'
            $emptyLog = Join-Path $rel.Dir 'micpe-qemu.log'
            Set-Content -LiteralPath $good -Value 'fake png' -Encoding ASCII
            New-Item -ItemType File -Path $emptyLog -Force | Out-Null
            Publish-CleanRelease -Tag 'micpe-clean-22621.1105-20261125-r83' `
                -CoreFiles @($rel.Iso, $rel.Wim, $rel.Checksums) `
                -ExtraFiles @($good, $emptyLog) `
                -Repository 'mic-yh10993/MIC-PE' -GhInvoker $fake.Invoker -WarningVariable warnings
            # The empty log never reaches gh: view + create + one extra upload.
            $fake.State.Calls.Count | Should -Be 3
            ($fake.State.Calls -join "`n") | Should -Not -Match 'micpe-qemu\.log'
            ($fake.State.Calls[2] -join ' ') | Should -Be "release upload micpe-clean-22621.1105-20261125-r83 $good --repo mic-yh10993/MIC-PE --clobber"
            "$warnings" | Should -Match 'micpe-qemu\.log'
        }
        finally {
            Remove-Item -LiteralPath $rel.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'a failing extra only warns and the remaining extras still upload' {
        $rel = New-TestReleaseDir
        try {
            $fake = New-FakeGh
            $fake.State.FailFiles = @('shot-01.png')
            $bad = Join-Path $rel.Dir 'shot-01.png'
            $good1 = Join-Path $rel.Dir 'shot-02.png'
            $good2 = Join-Path $rel.Dir 'micpe-serial.log'
            Set-Content -LiteralPath $bad -Value 'fake png 1' -Encoding ASCII
            Set-Content -LiteralPath $good1 -Value 'fake png 2' -Encoding ASCII
            Set-Content -LiteralPath $good2 -Value 'fake serial log' -Encoding ASCII
            Publish-CleanRelease -Tag 'micpe-clean-22621.1105-20261125-r83' `
                -CoreFiles @($rel.Iso, $rel.Wim, $rel.Checksums) `
                -ExtraFiles @($bad, $good1, $good2) `
                -Repository 'mic-yh10993/MIC-PE' -GhInvoker $fake.Invoker -WarningVariable warnings
            # view + create + three extra uploads: no throw, all attempted.
            $fake.State.Calls.Count | Should -Be 5
            ($fake.State.Calls[4] -join ' ') | Should -Be "release upload micpe-clean-22621.1105-20261125-r83 $good2 --repo mic-yh10993/MIC-PE --clobber"
            "$warnings" | Should -Match 'shot-01\.png'
        }
        finally {
            Remove-Item -LiteralPath $rel.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'a missing or empty core file still throws' {
        $rel = New-TestReleaseDir
        try {
            $fake = New-FakeGh
            $emptyIso = Join-Path $rel.Dir 'empty.iso'
            New-Item -ItemType File -Path $emptyIso -Force | Out-Null
            {
                Publish-CleanRelease -Tag 'micpe-clean-22621.1105-20261125-r83' `
                    -CoreFiles @($emptyIso, $rel.Wim, $rel.Checksums) `
                    -Repository 'mic-yh10993/MIC-PE' -GhInvoker $fake.Invoker
            } | Should -Throw -ExpectedMessage '*core file missing or empty*'
            # Nothing reached gh: the release must not be created half-empty.
            $fake.State.Calls.Count | Should -Be 0
        }
        finally {
            Remove-Item -LiteralPath $rel.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'a failing create whose release and core files already landed still uploads the extras (run 45463045449)' {
        # Run 45463045449: `gh release create` returned non-zero even
        # though the release and all three core files had landed, and
        # the old code threw there — which skipped the extras loop and
        # lost all 7 screenshots a third time. A failed create is now
        # verified first; when the release is really there, the extras
        # still go up.
        $rel = New-TestReleaseDir
        try {
            $fake = New-FakeGh
            $fake.State.FailCreate = $true
            $lister = New-FakeAssetLister -Assets @{
                'MICPE-clean.iso'  = (Get-Item -LiteralPath $rel.Iso).Length
                'boot.wim'         = (Get-Item -LiteralPath $rel.Wim).Length
                'checksums.sha256' = (Get-Item -LiteralPath $rel.Checksums).Length
            }
            $extra1 = Join-Path $rel.Dir 'shot-01.png'
            $extra2 = Join-Path $rel.Dir 'shot-02.png'
            Set-Content -LiteralPath $extra1 -Value 'fake png 1' -Encoding ASCII
            Set-Content -LiteralPath $extra2 -Value 'fake png 2' -Encoding ASCII
            Publish-CleanRelease -Tag 'micpe-clean-22621.1105-20261125-r83' `
                -CoreFiles @($rel.Iso, $rel.Wim, $rel.Checksums) `
                -ExtraFiles @($extra1, $extra2) `
                -Repository 'mic-yh10993/MIC-PE' -GhInvoker $fake.Invoker -AssetLister $lister `
                -WarningVariable warnings
            # view + create (failed) + two extra uploads: no throw, all attempted.
            $fake.State.Calls.Count | Should -Be 4
            ($fake.State.Calls[2] -join ' ') | Should -Be "release upload micpe-clean-22621.1105-20261125-r83 $extra1 --repo mic-yh10993/MIC-PE --clobber"
            ($fake.State.Calls[3] -join ' ') | Should -Be "release upload micpe-clean-22621.1105-20261125-r83 $extra2 --repo mic-yh10993/MIC-PE --clobber"
            "$warnings" | Should -Match 'already in place'
        }
        finally {
            Remove-Item -LiteralPath $rel.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'a failing create whose first view failed retries the view and uploads into the existing release (round 42 rerun 17)' {
        # Run 46159374271 attempt 3: the first `gh release view` failed
        # transiently, so the code took the create path; the create then
        # failed on the duplicate tag, and the size check said "not
        # landed" because the re-run had rebuilt the files. The release
        # itself was there all along -- re-checking the view finds it,
        # and the rebuilt core files go up with --clobber.
        $rel = New-TestReleaseDir
        try {
            $fake = New-FakeGh
            $fake.State.ViewExitQueue.Enqueue(1)
            $fake.State.ViewExitQueue.Enqueue(0)
            $fake.State.FailCreate = $true
            $lister = New-FakeAssetLister -Assets $null
            $extra1 = Join-Path $rel.Dir 'shot-01.png'
            Set-Content -LiteralPath $extra1 -Value 'fake png 1' -Encoding ASCII
            Publish-CleanRelease -Tag 'micpe-clean-22621.1105-20261128-r133' `
                -CoreFiles @($rel.Iso, $rel.Wim, $rel.Checksums) `
                -ExtraFiles @($extra1) `
                -Repository 'mic-yh10993/MIC-PE' -GhInvoker $fake.Invoker -AssetLister $lister `
                -WarningVariable warnings
            # view (failed) + create (failed) + view (retry, found) + core upload + extra upload.
            $fake.State.Calls.Count | Should -Be 5
            ($fake.State.Calls[3] -join ' ') | Should -Be "release upload micpe-clean-22621.1105-20261128-r133 $($rel.Iso) $($rel.Wim) $($rel.Checksums) --repo mic-yh10993/MIC-PE --clobber"
            ($fake.State.Calls[4] -join ' ') | Should -Be "release upload micpe-clean-22621.1105-20261128-r133 $extra1 --repo mic-yh10993/MIC-PE --clobber"
            "$warnings" | Should -Match 'already exists'
        }
        finally {
            Remove-Item -LiteralPath $rel.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'a failing create with no release behind it throws "create failed", not "upload failed" (run 45463045449)' {
        $rel = New-TestReleaseDir
        try {
            $fake = New-FakeGh
            $fake.State.FailCreate = $true
            $lister = New-FakeAssetLister -Assets $null
            $caught = $null
            try {
                Publish-CleanRelease -Tag 'micpe-clean-22621.1105-20261125-r83' `
                    -CoreFiles @($rel.Iso, $rel.Wim, $rel.Checksums) `
                    -Repository 'mic-yh10993/MIC-PE' -GhInvoker $fake.Invoker -AssetLister $lister
            }
            catch {
                $caught = $_.Exception.Message
            }
            $caught | Should -Not -BeNullOrEmpty
            $caught | Should -Match 'gh release create failed'
            $caught | Should -Not -Match 'upload failed'
            # view + create + retry view: no extra uploads were attempted.
            $fake.State.Calls.Count | Should -Be 3
        }
        finally {
            Remove-Item -LiteralPath $rel.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'a failing create with a wrong-sized core file still throws (run 45463045449)' {
        $rel = New-TestReleaseDir
        try {
            $fake = New-FakeGh
            $fake.State.FailCreate = $true
            $lister = New-FakeAssetLister -Assets @{
                'MICPE-clean.iso'  = (Get-Item -LiteralPath $rel.Iso).Length
                'boot.wim'         = (Get-Item -LiteralPath $rel.Wim).Length + 1
                'checksums.sha256' = (Get-Item -LiteralPath $rel.Checksums).Length
            }
            {
                Publish-CleanRelease -Tag 'micpe-clean-22621.1105-20261125-r83' `
                    -CoreFiles @($rel.Iso, $rel.Wim, $rel.Checksums) `
                    -Repository 'mic-yh10993/MIC-PE' -GhInvoker $fake.Invoker -AssetLister $lister
            } | Should -Throw -ExpectedMessage '*gh release create failed*'
            # view + create + retry view (the retry also finds no release).
            $fake.State.Calls.Count | Should -Be 3
        }
        finally {
            Remove-Item -LiteralPath $rel.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'a failing create with a core file missing from the release still throws (run 45463045449)' {
        $rel = New-TestReleaseDir
        try {
            $fake = New-FakeGh
            $fake.State.FailCreate = $true
            $lister = New-FakeAssetLister -Assets @{
                'MICPE-clean.iso'  = (Get-Item -LiteralPath $rel.Iso).Length
                'checksums.sha256' = (Get-Item -LiteralPath $rel.Checksums).Length
            }
            {
                Publish-CleanRelease -Tag 'micpe-clean-22621.1105-20261125-r83' `
                    -CoreFiles @($rel.Iso, $rel.Wim, $rel.Checksums) `
                    -Repository 'mic-yh10993/MIC-PE' -GhInvoker $fake.Invoker -AssetLister $lister
            } | Should -Throw -ExpectedMessage '*gh release create failed*'
            # view + create + retry view (the retry also finds no release).
            $fake.State.Calls.Count | Should -Be 3
        }
        finally {
            Remove-Item -LiteralPath $rel.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'a failing core upload into an existing release still throws' {
        $rel = New-TestReleaseDir
        try {
            $fake = New-FakeGh
            $fake.State.ViewExit = 0
            $fake.State.FailAllUploads = $true
            {
                Publish-CleanRelease -Tag 'micpe-clean-22621.1105-20261125-r83' `
                    -CoreFiles @($rel.Iso, $rel.Wim, $rel.Checksums) `
                    -Repository 'mic-yh10993/MIC-PE' -GhInvoker $fake.Invoker
            } | Should -Throw -ExpectedMessage '*gh release upload failed*'
        }
        finally {
            Remove-Item -LiteralPath $rel.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Publish-CleanRelease wiring' {
    BeforeAll {
        $script:publishScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/ci/Publish-CleanRelease.ps1') -Raw
        $script:buildYml = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../.github/workflows/build.yml') -Raw
    }

    It 'creates and uploads releases through gh' {
        # The subcommands are array elements passed to the GhInvoker,
        # not a literal "gh release create" string.
        $script:publishScript | Should -Match "'release', 'create'"
        $script:publishScript | Should -Match "'release', 'upload'"
        $script:publishScript | Should -Match "'release', 'view'"
        $script:publishScript | Should -Match '& gh @GhArgs'
    }

    It 'build.yml calls Publish-CleanRelease with core and extra files split' {
        $script:buildYml | Should -Match 'Publish-CleanRelease'
        $script:buildYml | Should -Match '-CoreFiles'
        $script:buildYml | Should -Match '-ExtraFiles'
        $script:buildYml | Should -Not -Match '@releaseFiles'
    }

    It 'verifies a failed create by listing release assets before giving up (run 45463045449)' {
        $script:publishScript | Should -Match 'Test-CoreFilesLanded'
        $script:publishScript | Should -Match '--json assets'
        $script:publishScript | Should -Match "gh release create failed"
    }
}
