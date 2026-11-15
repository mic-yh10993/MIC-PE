BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Disk.ps1"
    $script:TempRoot = [System.IO.Path]::GetTempPath()
}

Describe 'Get-BuildDrive' {
    It 'picks the drive with the most free space' {
        $drives = @(
            [pscustomobject]@{ Root = 'C:\'; Free = 5GB }
            [pscustomobject]@{ Root = 'D:\'; Free = 40GB }
            [pscustomobject]@{ Root = 'E:\'; Free = 12GB }
        )
        (Get-BuildDrive -Drives $drives).Root | Should -Be 'D:\'
    }

    It 'ignores drives reporting zero free space' {
        $drives = @(
            [pscustomobject]@{ Root = 'C:\'; Free = 0 }
            [pscustomobject]@{ Root = 'D:\'; Free = 3GB }
        )
        (Get-BuildDrive -Drives $drives).Root | Should -Be 'D:\'
    }

    It 'throws when no drive is usable' {
        { Get-BuildDrive -Drives @() } | Should -Throw
        { Get-BuildDrive -Drives @([pscustomobject]@{ Root = 'C:\'; Free = 0 }) } | Should -Throw
    }
}

Describe 'Remove-RunnerBloat' {
    It 'counts only paths that existed' {
        $dir = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot "bloat-$(Get-Random)")
        $result = Remove-RunnerBloat -Paths @($dir.FullName, (Join-Path $script:TempRoot 'micpe-definitely-absent'))
        $result | Should -Be 1
        Test-Path -LiteralPath $dir.FullName | Should -BeFalse
    }

    It 'is a no-op when nothing matches' {
        Remove-RunnerBloat -Paths @((Join-Path $script:TempRoot 'micpe-absent-a'), (Join-Path $script:TempRoot 'micpe-absent-b')) |
            Should -Be 0
    }

    It 'skips empty entries' {
        Remove-RunnerBloat -Paths @('', $null) | Should -Be 0
    }
}

Describe 'Get-BuildWorkspace' {
    It 'creates a micpe directory under the chosen drive' {
        $dir = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot "ws-$(Get-Random)")
        $drives = @([pscustomobject]@{ Root = $dir.FullName; Free = 1GB })
        $ws = Get-BuildWorkspace -Drives $drives
        Test-Path -LiteralPath $ws | Should -BeTrue
        Split-Path -Leaf $ws | Should -Be 'micpe'
    }

    It 'is idempotent' {
        $dir = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot "ws-$(Get-Random)")
        $drives = @([pscustomobject]@{ Root = $dir.FullName; Free = 1GB })
        (Get-BuildWorkspace -Drives $drives) | Should -Be (Get-BuildWorkspace -Drives $drives)
    }
}
