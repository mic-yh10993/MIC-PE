BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/BaseImage.ps1"
    $script:TempRoot = [System.IO.Path]::GetTempPath()
}

Describe 'Set-ConvertConfig' {
    BeforeAll {
        $script:RealIni = @'
; this is a comment
[convert-UUP]
AutoStart    =1
AddUpdates   =0
ResetBase    =0
SkipEdge     =0

[Store_Apps]
SkipApps     =0
'@
    }

    It 'replaces existing keys and preserves comments' {
        $f = New-TemporaryFile
        Set-Content -LiteralPath $f -Value $script:RealIni

        $out = Set-ConvertConfig -IniPath $f -Overrides @{ ResetBase = '1'; SkipApps = '1' }
        $out | Should -Match '^; this is a comment'
        ($out -split "`r?`n" | Where-Object { $_ -match '^ResetBase' }) | Should -Match '1'
        ($out -split "`r?`n" | Where-Object { $_ -match '^SkipApps' }) | Should -Match '1'
    }

    It 'keeps a key inside its own section' {
        $f = New-TemporaryFile
        Set-Content -LiteralPath $f -Value $script:RealIni

        $out = Set-ConvertConfig -IniPath $f -Overrides @{ SkipApps = '1' }
        $lines = $out -split "`r?`n"
        $storeIndex = [Array]::IndexOf($lines, '[Store_Apps]')
        $skipIndex = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^SkipApps') { $skipIndex = $i; break }
        }
        $skipIndex | Should -BeGreaterThan $storeIndex
    }

    It 'inserts an unknown key into the first section rather than the file end' {
        $f = New-TemporaryFile
        Set-Content -LiteralPath $f -Value $script:RealIni

        $out = Set-ConvertConfig -IniPath $f -Overrides @{ NeverSeen = '7' }
        $lines = $out -split "`r?`n"
        $firstSection = [Array]::IndexOf($lines, '[convert-UUP]')
        $secondSection = [Array]::IndexOf($lines, '[Store_Apps]')
        $inserted = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^NeverSeen') { $inserted = $i; break }
        }
        $inserted | Should -BeGreaterThan $firstSection
        $inserted | Should -BeLessThan $secondSection
    }

    It 'does not duplicate a key that already exists' {
        $f = New-TemporaryFile
        Set-Content -LiteralPath $f -Value $script:RealIni

        $out = Set-ConvertConfig -IniPath $f -Overrides @{ SkipEdge = '1' }
        @($out -split "`r?`n" | Where-Object { $_ -match '^SkipEdge' }).Count | Should -Be 1
    }

    It 'throws when the ini is missing' {
        { Set-ConvertConfig -IniPath (Join-Path $script:TempRoot 'micpe-absent.ini') -Overrides @{} } |
            Should -Throw '*not found*'
    }
}

Describe 'Invoke-UupApi retry' {
    It 'retries a transient failure and succeeds on a later attempt' {
        # Run 43977562519 died on a single UUP dump 504, 60 seconds into
        # the build: one transient gateway error must not burn a build.
        $script:calls = 0
        $fake = {
            param($url)
            $script:calls++
            if ($script:calls -lt 3) { throw 'error code: 504' }
            return @{ response = @{ builds = @{} } }
        }
        $null = Invoke-UupApi -Url 'https://api.uupdump.net/listid.php?search=26200' `
            -Invoke $fake -MaxAttempts 3 -RetryDelaySec 0
        $script:calls | Should -Be 3
    }

    It 'throws after the last attempt when the failure persists' {
        $script:calls = 0
        $fake = {
            param($url)
            $script:calls++
            throw 'error code: 504'
        }
        { Invoke-UupApi -Url 'https://api.uupdump.net/listid.php?search=26200' `
            -Invoke $fake -MaxAttempts 3 -RetryDelaySec 0 } | Should -Throw '*504*'
        $script:calls | Should -Be 3
    }

    It 'does not retry when the first attempt succeeds' {
        $script:calls = 0
        $fake = {
            param($url)
            $script:calls++
            return @{ response = @{ builds = @{} } }
        }
        $null = Invoke-UupApi -Url 'https://api.uupdump.net/listid.php?search=26200' `
            -Invoke $fake -MaxAttempts 3 -RetryDelaySec 0
        $script:calls | Should -Be 1
    }
}

Describe 'New-UupDownloadPackage retry' {
    It 'downloads the conversion package through the network retry helper' {
        # The package download (uupdump.net/get.php) can hit the same
        # transient 504 as the list API, so it must retry too.
        $baseImage = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/build/lib/BaseImage.ps1') -Raw
        $baseImage | Should -Match 'Invoke-NetworkWithRetry -Action \{\s+Invoke-WebRequest -Uri \$url'
    }
}

Describe 'Get-UupBuild' {
    It 'throws a message containing the request url when nothing matches' {
        $fake = { param($url) @{ response = @{ builds = @{} } } }
        { Get-UupBuild -Build '1' -Arch 'amd64' -Channel 'stable' -Invoke $fake } |
            Should -Throw '*uupdump*'
    }

    It 'picks the highest matching stable amd64 build' {
        $fake = {
            param($url)
            @{
                response = @{
                    builds = [ordered]@{
                        '1' = [pscustomobject]@{ uuid = 'low';  build = '26200.100'; arch = 'amd64'; title = 'Windows 11, version 25H2' }
                        '2' = [pscustomobject]@{ uuid = 'high'; build = '26200.900'; arch = 'amd64'; title = 'Windows 11, version 25H2' }
                        '3' = [pscustomobject]@{ uuid = 'arm';  build = '26200.999'; arch = 'arm64'; title = 'Windows 11, version 25H2' }
                        '4' = [pscustomobject]@{ uuid = 'ins';  build = '26200.999'; arch = 'amd64'; title = 'Windows 11 Insider Preview' }
                    }
                }
            }
        }
        $result = Get-UupBuild -Build '26200' -Arch 'amd64' -Channel 'stable' -Invoke $fake
        $result.Uuid | Should -Be 'high'
    }

    It 'filters out non Windows 11 titles' {
        $fake = {
            param($url)
            @{
                response = @{
                    builds = @{
                        '1' = [pscustomobject]@{ uuid = 'x'; build = '1'; arch = 'amd64'; title = 'Windows 10, version 22H2' }
                    }
                }
            }
        }
        { Get-UupBuild -Build '1' -Arch 'amd64' -Channel 'stable' -Invoke $fake } | Should -Throw
    }
}

Describe 'Build-Micpe.ps1 aria2 pre-seeding' {
    It 'verifies aria2c against a pinned hash instead of trusting get_aria2.ps1' {
        $build = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/build/Build-Micpe.ps1') -Raw
        $build | Should -Match 'b9cd71b275af11b63c33457b0f43f2f2675937070c563e195f223efd7fa4c74b'
        $build | Should -Match 'uupdump\.net/misc/aria2c\.exe'
        $build | Should -Match 'hash mismatch'
    }

    It 'drains the downloader pause by feeding stdin' {
        $build = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/build/Build-Micpe.ps1') -Raw
        $build | Should -Match 'echo\. \|'
    }
}

Describe 'Build-Micpe.ps1 converter retry' {
    It 'runs uup_download_windows.cmd through the network retry helper' {
        # Run 43985086793 died on a 504 inside the converter itself, after
        # every UUP file was already downloaded: the converter fetches from
        # UUP dump too, so it needs the same retry as the API calls.
        $build = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/build/Build-Micpe.ps1') -Raw
        $build | Should -Match 'Invoke-NetworkWithRetry -Action \{[\s\S]*?uup_download_windows\.cmd'
        $build | Should -Match "-Label 'uup converter'"
    }
}

Describe 'Repair-UupAria2Script' {
    It 'replaces the bundled verifier and removes Get-FileHash' {
        $pkg = Join-Path ([System.IO.Path]::GetTempPath()) ("micpe-uup-{0}" -f [guid]::NewGuid())
        $files = New-Item -ItemType Directory -Path (Join-Path $pkg 'files') -Force
        Set-Content -LiteralPath (Join-Path $files 'get_aria2.ps1') -Value @'
# bundled verifier (simulated)
Get-FileHash -Path files\aria2c.exe -Algorithm SHA256
'@
        $result = Repair-UupAria2Script -PackageDir $pkg
        $result | Should -Be $true
        $patched = Join-Path $files 'get_aria2.ps1'
        Test-ScriptInvokesCommand -Path $patched -CommandName 'Get-FileHash' |
            Should -Be $false
        $patchedContent = Get-Content -LiteralPath $patched -Raw
        $patchedContent | Should -Match 'Verifying aria2c.exe'
    }

    It 'refuses a replacement that actually calls Get-FileHash' {
        $pkg = Join-Path ([System.IO.Path]::GetTempPath()) ("micpe-uup-{0}" -f [guid]::NewGuid())
        $files = New-Item -ItemType Directory -Path (Join-Path $pkg 'files') -Force
        Set-Content -LiteralPath (Join-Path $files 'get_aria2.ps1') -Value '# bundled'
        $bad = Join-Path ([System.IO.Path]::GetTempPath()) ("micpe-bad-{0}.ps1" -f [guid]::NewGuid())
        Set-Content -LiteralPath $bad -Value @'
# mentions Get-FileHash in a comment, but also calls it:
Get-FileHash -Path x -Algorithm SHA256
'@
        { Repair-UupAria2Script -PackageDir $pkg -ReplacementScript $bad } |
            Should -Throw '*Get-FileHash*'
    }

    It 'returns false without throwing when the bundled script is absent' {
        $pkg = Join-Path ([System.IO.Path]::GetTempPath()) ("micpe-uup-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $pkg -Force | Out-Null
        $result = Repair-UupAria2Script -PackageDir $pkg
        $result | Should -Be $false
    }
}

Describe 'aria2c verifier replacement script' {
    BeforeAll {
        $script:Verifier = Join-Path $PSScriptRoot '../src/build/uup/get_aria2.ps1'
        $script:Pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    }

    It 'exits 0 without downloading when the binary matches the pinned hash' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("micpe-aria2-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $scriptCopy = Join-Path $dir 'get_aria2.ps1'
        Copy-Item -LiteralPath $script:Verifier -Destination $scriptCopy
        $bin = Join-Path $dir 'aria2c.exe'
        [System.IO.File]::WriteAllText($bin, 'fake aria2 binary')
        $hash = (Get-FileHash -LiteralPath $bin -Algorithm SHA256).Hash

        $out = & $script:Pwsh -NoProfile -File $scriptCopy -ExpectedHash $hash -DownloadUrl 'https://example.invalid/aria2c.exe' 2>&1
        $code = $LASTEXITCODE
        $code | Should -Be 0
        ($out -join "`n") | Should -Match 'Verifying aria2c.exe'
    }

    It 'exits 1 with the tampered message when the download still mismatches' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("micpe-aria2-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $scriptCopy = Join-Path $dir 'get_aria2.ps1'
        Copy-Item -LiteralPath $script:Verifier -Destination $scriptCopy
        $bin = Join-Path $dir 'aria2c.exe'
        [System.IO.File]::WriteAllText($bin, 'fake aria2 binary')
        $wrong = Join-Path $dir 'wrong.bin'
        [System.IO.File]::WriteAllText($wrong, 'different content')
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $expected = ([System.BitConverter]::ToString(
            $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes('expected but absent'))) -replace '-', '').ToLower()
        $url = ([System.Uri]::new($wrong)).AbsoluteUri

        $out = & $script:Pwsh -NoProfile -File $scriptCopy -ExpectedHash $expected -DownloadUrl $url 2>&1
        $code = $LASTEXITCODE
        $code | Should -Be 1
        ($out -join "`n") | Should -Match 'tampered'
    }

    It 'pins the same hash as Build-Micpe.ps1 and BaseImage.ps1' {
        $lib = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/build/lib/BaseImage.ps1') -Raw
        $match = [regex]::Match($lib, "Aria2ExpectedHash = '([0-9a-f]{64})'")
        $match.Success | Should -Be $true
        $hash = $match.Groups[1].Value
        $build = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/build/Build-Micpe.ps1') -Raw
        $build | Should -Match $hash
        $scriptText = Get-Content -LiteralPath $script:Verifier -Raw
        $scriptText | Should -Match $hash
        Test-ScriptInvokesCommand -Path $script:Verifier -CommandName 'Get-FileHash' |
            Should -Be $false
    }
}

Describe 'Get-BaseWims' {
    It 'throws when the iso is missing' {
        { Get-BaseWims -IsoPath (Join-Path $script:TempRoot 'micpe-absent.iso') -OutDir $script:TempRoot } |
            Should -Throw '*not found*'
    }
}
