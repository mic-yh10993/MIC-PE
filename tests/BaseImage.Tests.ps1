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

Describe 'Get-BaseWims' {
    It 'throws when the iso is missing' {
        { Get-BaseWims -IsoPath (Join-Path $script:TempRoot 'micpe-absent.iso') -OutDir $script:TempRoot } |
            Should -Throw '*not found*'
    }
}
