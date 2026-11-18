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

Describe 'Get-OscdimgPath' {
    It 'finds oscdimg under a given ADK root' {
        $root = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ("micpe-adk-{0}" -f [guid]::NewGuid())) -Force
        $dir = New-Item -ItemType Directory -Path (Join-Path $root 'Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg') -Force
        $exe = Join-Path $dir 'oscdimg.exe'
        Set-Content -LiteralPath $exe -Value 'fake'
        Get-OscdimgPath -AdkRoot $root.FullName | Should -Be $exe
    }

    It 'prefers oscdimg from PATH' {
        $dir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ("micpe-oscdimg-{0}" -f [guid]::NewGuid())) -Force
        $name = if ($IsWindows) { 'oscdimg.cmd' } else { 'oscdimg' }
        $fake = Join-Path $dir $name
        Set-Content -LiteralPath $fake -Value '@echo off'
        if (-not $IsWindows) { & chmod +x $fake }
        $oldPath = $env:PATH
        try {
            $env:PATH = "$($dir.FullName)$([System.IO.Path]::PathSeparator)$env:PATH"
            Get-OscdimgPath -AdkRoot (Join-Path ([System.IO.Path]::GetTempPath()) 'micpe-no-adk') |
                Should -Be $fake
        }
        finally {
            $env:PATH = $oldPath
        }
    }

    It 'throws a clear error when oscdimg is nowhere to be found' {
        { Get-OscdimgPath -AdkRoot (Join-Path ([System.IO.Path]::GetTempPath()) 'micpe-no-adk') } |
            Should -Throw '*oscdimg not found*'
    }
}

Describe 'New-MicpeIso boot image selection' {
    BeforeAll {
        $script:isoSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/build/lib/Iso.ps1') -Raw
    }

    It 'packs the no-prompt EFI image, not the prompting one' {
        # Run 44046530462: the prompting efisys.bin's cdboot.efi times out
        # after ~3 s and no harness key can land in that window, so the
        # firmware reported "BdsDxe: failed to start Boot0001: Time out".
        $script:isoSource | Should -Match 'efisys_noprompt\.bin'
    }

    It 'rejects a media tree that only has the prompting EFI image' {
        $dir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) "media-prompt-$(Get-Random)") -Force
        $bootDir = New-Item -ItemType Directory -Path (Join-Path $dir.FullName 'boot') -Force
        $efiDir = New-Item -ItemType Directory -Path (Join-Path $dir.FullName 'efi' 'microsoft' 'boot') -Force
        Set-Content -LiteralPath (Join-Path $bootDir 'etfsboot.com') -Value 'fake'
        Set-Content -LiteralPath (Join-Path $efiDir 'efisys.bin') -Value 'fake'
        { New-MicpeIso -MediaDir $dir.FullName -OutIso (Join-Path $dir.FullName 'x.iso') } |
            Should -Throw '*boot*'
    }

    It 'accepts a media tree with the no-prompt EFI image and reaches the oscdimg lookup' {
        $dir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) "media-noprompt-$(Get-Random)") -Force
        $bootDir = New-Item -ItemType Directory -Path (Join-Path $dir.FullName 'boot') -Force
        $efiDir = New-Item -ItemType Directory -Path (Join-Path $dir.FullName 'efi' 'microsoft' 'boot') -Force
        Set-Content -LiteralPath (Join-Path $bootDir 'etfsboot.com') -Value 'fake'
        Set-Content -LiteralPath (Join-Path $efiDir 'efisys_noprompt.bin') -Value 'fake'
        # The test runner has no ADK, so the next failure is the oscdimg
        # lookup -- which proves the boot-file assertions passed.
        { New-MicpeIso -MediaDir $dir.FullName -OutIso (Join-Path $dir.FullName 'x.iso') } |
            Should -Throw '*oscdimg*'
    }
}

Describe 'New-MicpeIso' {
    It 'enforces the 3.2 GB product target as the size gate' {
        # Packaging round (user decision 2026-11-17 15:09): the ISO carries
        # only boot.wim, so the media fits the product target and the gate
        # is the target itself. The old 5 GB runaway guard (full 26200
        # media ~4.5 GiB) died with that layout.
        $script:IsoMaxBytes | Should -Be ([long](3.2 * 1GB))
    }

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

Describe 'Remove-InstallWimFromMedia' {
    BeforeAll {
        $script:mediaDir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) "media-nowim-$(Get-Random)") -Force
        $sources = New-Item -ItemType Directory -Path (Join-Path $script:mediaDir 'sources') -Force
        Set-Content -LiteralPath (Join-Path $sources 'install.wim') -Value 'fake install.wim'
        Set-Content -LiteralPath (Join-Path $sources 'boot.wim') -Value 'fake boot.wim'
    }

    It 'removes sources\install.wim and keeps sources\boot.wim' {
        Remove-InstallWimFromMedia -MediaDir $script:mediaDir
        (Join-Path $script:mediaDir 'sources\install.wim') | Should -Not -Exist
        (Join-Path $script:mediaDir 'sources\boot.wim') | Should -Exist
    }

    It 'is a no-op when install.wim is already gone (still requires boot.wim)' {
        # Second call: install.wim already removed above; must not throw,
        # and must still refuse a media tree with no boot.wim.
        { Remove-InstallWimFromMedia -MediaDir $script:mediaDir } | Should -Not -Throw
        Remove-Item -LiteralPath (Join-Path $script:mediaDir 'sources\boot.wim') -Force
        { Remove-InstallWimFromMedia -MediaDir $script:mediaDir } | Should -Throw '*boot.wim*'
    }

    It 'reverse control: a tree with install.wim present must lose it' {
        $dir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) "media-wim-$(Get-Random)") -Force
        $sources = New-Item -ItemType Directory -Path (Join-Path $dir 'sources') -Force
        Set-Content -LiteralPath (Join-Path $sources 'install.wim') -Value 'fake'
        Set-Content -LiteralPath (Join-Path $sources 'boot.wim') -Value 'fake'
        Remove-InstallWimFromMedia -MediaDir $dir
        (Join-Path $dir 'sources\install.wim') | Should -Not -Exist
    }
}
