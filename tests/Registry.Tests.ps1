BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Registry.ps1"
    $script:TempRoot = [System.IO.Path]::GetTempPath()
}

Describe 'hive map' {
    It 'maps the four hives the PE needs' {
        $map = Get-PeHiveMap
        $map.Count | Should -Be 4
        ($map.File -join ',') | Should -Be 'DEFAULT,DRIVERS,SOFTWARE,SYSTEM'
        ($map.Key -join ',') | Should -Be 'PE-DEF,PE-DRV,PE-SOFT,PE-SYS'
    }
}

Describe 'Import-RegFile' {
    It 'throws when the file is missing' {
        { Import-RegFile -RegFile (Join-Path $script:TempRoot 'micpe-absent.reg') } |
            Should -Throw '*not found*'
    }
}

Describe 'Get-RegistryValue' {
    It 'returns null for a key that does not exist' {
        Get-RegistryValue -KeyName 'MICPE-NOT-MOUNTED' -SubKey '' -Name '' | Should -BeNullOrEmpty
    }

    It 'returns null for a missing value name on an existing key' {
        Get-RegistryValue -KeyName 'SOFTWARE' -SubKey 'Microsoft' -Name 'MicpeNotAValue' |
            Should -BeNullOrEmpty
    }
}

Describe 'Registry patch files' {
    It 'every .reg file declares the Windows Registry Editor header' {
        $dir = Join-Path $PSScriptRoot '../src/registry'
        if (-not (Test-Path -LiteralPath $dir)) { Set-ItResult -Skipped -Because 'no patch files yet'; return }

        $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.reg' -File)
        foreach ($file in $files) {
            $head = (Get-Content -LiteralPath $file.FullName -TotalCount 1)
            $head | Should -Match 'Windows Registry Editor Version 5\.00'
        }
    }
}
