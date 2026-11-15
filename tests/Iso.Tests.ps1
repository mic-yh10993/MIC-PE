BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Iso.ps1"
}

Describe 'Get-OscdimgArgs' {
    BeforeAll {
        $script:args = Get-OscdimgArgs -MediaDir 'C:\media' -OutIso 'C:\out\MICPE.iso' `
            -BiosBootFile 'C:\media\boot\etfsboot.com' `
            -EfiBootFile 'C:\media\efi\microsoft\boot\efisys.bin' `
            -Label 'MICPE'
    }

    It 'produces UDF with UEFI-friendly options' {
        $script:args | Should -Contain '-u2'
        $script:args | Should -Contain '-udfver102'
        $script:args | Should -Contain '-m'
        $script:args | Should -Contain '-o'
    }

    It 'wires both boot entries' {
        ($script:args -join ' ') | Should -Match 'bootdata:2'
        ($script:args -join ' ') | Should -Match 'p0,e,bC:\\media\\boot\\etfsboot\.com'
        ($script:args -join ' ') | Should -Match 'pEF,e,bC:\\media\\efi\\microsoft\\boot\\efisys\.bin'
    }

    It 'sets the volume label' {
        $script:args | Should -Contain '-lMICPE'
    }

    It 'passes the media dir then the output path' {
        $script:args[-2] | Should -Be 'C:\media'
        $script:args[-1] | Should -Be 'C:\out\MICPE.iso'
    }
}

Describe 'New-MicpeIso' {
    It 'throws when the media directory is missing' {
        { New-MicpeIso -MediaDir '/nonexistent/micpe-media' -OutIso '/tmp/x.iso' } |
            Should -Throw '*not found*'
    }

    It 'throws when boot files are missing' {
        $dir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) "media-$(Get-Random)")
        { New-MicpeIso -MediaDir $dir.FullName -OutIso (Join-Path $dir.FullName 'x.iso') } |
            Should -Throw '*boot*'
    }
}
