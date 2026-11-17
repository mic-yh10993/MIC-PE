BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/installer/Deploy.ps1"
}

Describe 'Select-DefaultIndex' {
    It 'picks exact name match' {
        $ix = @(
            [pscustomobject]@{ Index = 1; Name = 'Windows 11 家庭版' },
            [pscustomobject]@{ Index = 2; Name = 'MICPE 定制系统 v1' }
        )
        Select-DefaultIndex -Indexes $ix -DisplayName 'MICPE 定制系统 v1' | Should -Be 2
    }

    It 'picks a name containing the display name when there is no exact match' {
        $ix = @(
            [pscustomobject]@{ Index = 1; Name = 'Windows 11 家庭版' },
            [pscustomobject]@{ Index = 2; Name = 'MICPE 定制系统 v1 专业版' }
        )
        Select-DefaultIndex -Indexes $ix -DisplayName 'MICPE 定制系统 v1' | Should -Be 2
    }

    It 'falls back to first when nothing matches' {
        $ix = @([pscustomobject]@{ Index = 3; Name = 'A' }, [pscustomobject]@{ Index = 7; Name = 'B' })
        Select-DefaultIndex -Indexes $ix -DisplayName 'nothing' | Should -Be 3
    }

    It 'throws when there are no indexes at all' {
        { Select-DefaultIndex -Indexes @() -DisplayName 'x' } | Should -Throw
    }
}

Describe 'Test-TargetSpace' {
    It 'requires 15 percent headroom over reported size' {
        $r = Test-TargetSpace -RequiredBytes 1000 -AvailableBytes 1100
        $r.Ok | Should -BeFalse
        $r.Required | Should -Be 1150
    }

    It 'passes with enough room' {
        (Test-TargetSpace -RequiredBytes 1000 -AvailableBytes 2000).Ok | Should -BeTrue
    }

    It 'passes exactly at the headroom boundary' {
        (Test-TargetSpace -RequiredBytes 1000 -AvailableBytes 1150).Ok | Should -BeTrue
    }
}

Describe 'Test-TargetSafety' {
    It 'refuses when target equals the image volume' {
        $r = Test-TargetSafety -TargetRoot 'D:\' -ImageRoot 'D:\' -PeRoot 'X:\'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match '镜像'
    }

    It 'refuses when target is the running PE volume' {
        $r = Test-TargetSafety -TargetRoot 'X:\' -ImageRoot 'D:\' -PeRoot 'X:\'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'PE'
    }

    It 'allows a normal target' {
        (Test-TargetSafety -TargetRoot 'C:\' -ImageRoot 'D:\' -PeRoot 'X:\').Ok | Should -BeTrue
    }

    It 'refuses a target that is not a volume root' {
        $r = Test-TargetSafety -TargetRoot 'C:\Windows' -ImageRoot 'D:\' -PeRoot 'X:\'
        $r.Ok | Should -BeFalse
    }

    It 'compares roots case-insensitively' {
        (Test-TargetSafety -TargetRoot 'd:\' -ImageRoot 'D:\' -PeRoot 'X:\').Ok | Should -BeFalse
    }
}

Describe 'ConvertFrom-WimInfoOutput' {
    It 'parses wimlib-imagex info output into indexes' {
        $lines = @(
            'Image "install.wim" (WIM version 0.0.0)',
            'Index:                  1',
            'Name:                   Windows 11 家庭版',
            'Description:            Windows 11 家庭版',
            'Total Bytes:            12345678901',
            'Index:                  2',
            'Name:                   MICPE 定制系统 v1',
            'Description:            Custom image',
            'Total Bytes:            9876543210'
        )
        $ix = ConvertFrom-WimInfoOutput -Lines $lines
        $ix.Count | Should -Be 2
        $ix[0].Index | Should -Be 1
        $ix[0].Name | Should -Be 'Windows 11 家庭版'
        $ix[0].SizeBytes | Should -Be 12345678901
        $ix[1].Index | Should -Be 2
        $ix[1].Description | Should -Be 'Custom image'
    }

    It 'returns an empty array for output without indexes' {
        (ConvertFrom-WimInfoOutput -Lines @('nothing here')).Count | Should -Be 0
    }
}

Describe 'Get-WimIndexes' {
    It 'throws when the wim file is missing' {
        { Get-WimIndexes -WimPath '/no/such/install.wim' } | Should -Throw
    }

    It 'throws when wimlib exits non-zero' {
        $wim = Join-Path ([System.IO.Path]::GetTempPath()) "fake-$(Get-Random).wim"
        Set-Content -LiteralPath $wim -Value 'fake'
        # 'false' is a real command on Linux that always exits 1.
        { Get-WimIndexes -WimPath $wim -WimlibPath 'false' } | Should -Throw
    }
}

Describe 'Invoke-Deploy command sequence' {
    It 'unmounts, formats NTFS, then applies the selected index' {
        $wim = Join-Path ([System.IO.Path]::GetTempPath()) "fake-$(Get-Random).wim"
        Set-Content -LiteralPath $wim -Value 'fake'
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $runner = {
            param($exe, $arguments)
            $script:calls.Add("$exe $($arguments -join ' ')")
            return 0
        }
        $code = Invoke-Deploy -WimPath $wim -Index 2 -TargetRoot 'C:\' -CommandRunner $runner
        $code | Should -Be 0
        $script:calls.Count | Should -Be 3
        $script:calls[0] | Should -Match 'mountvol'
        $script:calls[1] | Should -Match 'format\.com C: /FS:NTFS /Q /Y'
        $script:calls[2] | Should -Match 'apply'
        $script:calls[2] | Should -Match ' 2 C:\\'
    }

    It 'throws when format fails instead of applying anyway' {
        $wim = Join-Path ([System.IO.Path]::GetTempPath()) "fake-$(Get-Random).wim"
        Set-Content -LiteralPath $wim -Value 'fake'
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $runner = {
            param($exe, $arguments)
            $script:calls.Add($exe)
            if ($exe -match 'format') { return 1 }
            return 0
        }
        { Invoke-Deploy -WimPath $wim -Index 1 -TargetRoot 'C:\' -CommandRunner $runner } | Should -Throw
        $script:calls -notcontains 'wimlib-imagex' | Should -BeTrue
    }
}

Describe 'Repair-Boot' {
    It 'calls bcdboot with UEFI and BIOS flags' {
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $runner = {
            param($exe, $arguments)
            $script:calls.Add("$exe $($arguments -join ' ')")
            return 0
        }
        $code = Repair-Boot -TargetRoot 'C:\' -BootRoot 'S:\' -CommandRunner $runner
        $code | Should -Be 0
        $script:calls.Count | Should -Be 1
        $script:calls[0] | Should -Match 'bcdboot'
        $script:calls[0] | Should -Match 'C:\\Windows /s S:\\ /f ALL'
    }

    It 'defaults the boot volume to the target volume' {
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $runner = {
            param($exe, $arguments)
            $script:calls.Add("$exe $($arguments -join ' ')")
            return 0
        }
        Repair-Boot -TargetRoot 'C:\' -CommandRunner $runner | Out-Null
        $script:calls[0] | Should -Match '/s C:\\'
    }
}
