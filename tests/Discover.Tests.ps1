BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/installer/Discover.ps1"
    $script:TempRoot = [System.IO.Path]::GetTempPath()

    function New-FakeVolume {
        $root = Join-Path $script:TempRoot "vol-$(Get-Random)"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return $root
    }

    function New-SparseWim {
        param(
            [Parameter(Mandatory = $true)] [string] $Path,
            [long] $Bytes = 600MB
        )
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        $f = [System.IO.File]::Create($Path)
        $f.SetLength($Bytes)
        $f.Close()
    }
}

Describe 'Find-InstallSource' {
    BeforeEach {
        $script:r = @()
        1..3 | ForEach-Object { $script:r += (New-FakeVolume) }
    }

    It 'prefers a volume with install.mic over one with only install.wim' {
        # vol1: bare sources\install.wim (600MB sparse)
        New-SparseWim -Path (Join-Path $script:r[0] 'sources/install.wim')
        # vol2: install.mic + sources\install.wim
        Set-Content -LiteralPath (Join-Path $script:r[1] 'install.mic') -Value 'MICPE 定制系统 v1'
        New-SparseWim -Path (Join-Path $script:r[1] 'sources/install.wim')

        $res = Find-InstallSource -Roots $script:r
        $res[0].Root | Should -Be $script:r[1]
        $res[0].DisplayName | Should -Be 'MICPE 定制系统 v1'
        $res[0].HasMarker | Should -BeTrue
    }

    It 'reports a marker volume whose image is missing as a broken entry' {
        Set-Content -LiteralPath (Join-Path $script:r[2] 'install.mic') -Value 'Broken'
        $res = Find-InstallSource -Roots $script:r
        $b = $res | Where-Object Root -EQ $script:r[2]
        $b.HasMarker | Should -BeTrue
        $b.ImagePath | Should -BeNullOrEmpty
        $b.Broken | Should -BeTrue
    }

    It 'ignores tiny or wrong-extension files' {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:r[0] 'sources') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:r[0] 'sources/install.wim') -Value 'tiny'
        (Find-InstallSource -Roots @($script:r[0])).Count | Should -Be 0
    }

    It 'skips a root that throws instead of failing the whole scan' {
        # Deviation from plan.md: the plan test reads r[1] with no setup,
        # which only passes if state leaks across It blocks — but BeforeEach
        # recreates the volumes, so the test sets up its own good volume.
        Set-Content -LiteralPath (Join-Path $script:r[1] 'install.mic') -Value 'MICPE 定制系统 v1'
        New-SparseWim -Path (Join-Path $script:r[1] 'sources/install.wim')
        $bad = 'Z:\definitely-not-a-volume'
        (Find-InstallSource -Roots @($bad, $script:r[1])).Count | Should -Be 1
    }

    It 'sorts marker first, then sources fallback, then root order' {
        # vol1: bare install.wim at the root (no sources\)
        New-SparseWim -Path (Join-Path $script:r[0] 'install.wim')
        # vol2: bare sources\install.wim
        New-SparseWim -Path (Join-Path $script:r[1] 'sources/install.wim')
        # vol3: marker + image
        Set-Content -LiteralPath (Join-Path $script:r[2] 'install.mic') -Value 'Marked'
        New-SparseWim -Path (Join-Path $script:r[2] 'sources/install.wim')

        $res = Find-InstallSource -Roots $script:r
        $res.Count | Should -Be 3
        $res[0].Root | Should -Be $script:r[2]
        $res[1].Root | Should -Be $script:r[1]
        $res[2].Root | Should -Be $script:r[0]
    }

    It 'falls back to a root *.esd when no wim exists' {
        New-SparseWim -Path (Join-Path $script:r[0] 'custom.esd')
        $res = Find-InstallSource -Roots @($script:r[0])
        $res.Count | Should -Be 1
        $res[0].HasMarker | Should -BeFalse
        $res[0].ImagePath | Should -Match 'custom\.esd'
    }

    It 'returns nothing for empty roots' {
        (Find-InstallSource -Roots @()).Count | Should -Be 0
    }
}

Describe 'Read-InstallMic' {
    It 'reads the first line and trims it' {
        $p = Join-Path $script:TempRoot "mic-$(Get-Random).txt"
        Set-Content -LiteralPath $p -Value @('  MICPE 定制系统 v1  ', 'second line')
        Read-InstallMic -Path $p | Should -Be 'MICPE 定制系统 v1'
    }

    It 'returns null for a missing file, an empty file, or a blank first line' {
        Read-InstallMic -Path (Join-Path $script:TempRoot 'no-such-mic.txt') | Should -BeNullOrEmpty
        $empty = Join-Path $script:TempRoot "mic-empty-$(Get-Random).txt"
        Set-Content -LiteralPath $empty -Value ''
        Read-InstallMic -Path $empty | Should -BeNullOrEmpty
        $blank = Join-Path $script:TempRoot "mic-blank-$(Get-Random).txt"
        Set-Content -LiteralPath $blank -Value @('', 'name on line two')
        Read-InstallMic -Path $blank | Should -BeNullOrEmpty
    }
}

Describe 'Test-InstallImage' {
    It 'accepts wim and esd over 512 MB only' {
        $wim = Join-Path $script:TempRoot "img-$(Get-Random).wim"
        New-SparseWim -Path $wim -Bytes (512MB + 1)
        Test-InstallImage -Path $wim | Should -BeTrue

        $exact = Join-Path $script:TempRoot "img-$(Get-Random).wim"
        New-SparseWim -Path $exact -Bytes 512MB
        Test-InstallImage -Path $exact | Should -BeFalse

        $esd = Join-Path $script:TempRoot "img-$(Get-Random).esd"
        New-SparseWim -Path $esd -Bytes 600MB
        Test-InstallImage -Path $esd | Should -BeTrue

        $txt = Join-Path $script:TempRoot "img-$(Get-Random).txt"
        New-SparseWim -Path $txt -Bytes 600MB
        Test-InstallImage -Path $txt | Should -BeFalse

        Test-InstallImage -Path (Join-Path $script:TempRoot 'no-such.wim') | Should -BeFalse
    }
}
