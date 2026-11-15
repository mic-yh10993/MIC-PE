BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/BaseImage.ps1"
    $script:TempRoot = [System.IO.Path]::GetTempPath()
}

Describe 'Set-ConvertConfig' {
    It 'replaces existing keys and preserves comments and order' {
        $f = New-TemporaryFile
        @'
; this is a comment
[Convert]
Edition=Professional
ResetBase=1
'@ | Set-Content -LiteralPath $f

        $out = Set-ConvertConfig -IniPath $f -Overrides @{ Edition = 'Professional'; ResetBase = '0'; SkipEdge = '1' }
        $out | Should -Match '^; this is a comment'
        $out | Should -Match 'ResetBase=0'
        $out | Should -Match 'SkipEdge=1'
        ($out -split "`r?`n" | Where-Object { $_ -match '^Edition=' }) | Should -Be 'Edition=Professional'
    }

    It 'appends missing keys under the Convert section' {
        $f = New-TemporaryFile
        @'
[Convert]
Edition=Professional
'@ | Set-Content -LiteralPath $f

        $out = Set-ConvertConfig -IniPath $f -Overrides @{ SkipApps = '1' }
        $out | Should -Match 'SkipApps=1'
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
