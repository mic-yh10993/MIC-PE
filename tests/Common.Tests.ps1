BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    $script:TempRoot = [System.IO.Path]::GetTempPath()
}

Describe 'Assert-FileSize' {
    It 'passes when under limit' {
        $f = New-TemporaryFile
        Set-Content -LiteralPath $f -Value 'abc'
        { Assert-FileSize -Path $f -MaxBytes 10 -Label 'wim' } | Should -Not -Throw
    }

    It 'throws with the label when over limit' {
        $f = New-TemporaryFile
        [System.IO.File]::WriteAllBytes($f, (New-Object byte[] 2048))
        { Assert-FileSize -Path $f -MaxBytes 1024 -Label 'boot.wim' } |
            Should -Throw '*boot.wim*'
    }

    It 'throws when the file is missing' {
        { Assert-FileSize -Path (Join-Path $script:TempRoot 'micpe-does-not-exist.bin') -MaxBytes 10 -Label 'boot.wim' } |
            Should -Throw '*not found*'
    }

    It 'reports the overflow amount' {
        $f = New-TemporaryFile
        [System.IO.File]::WriteAllBytes($f, (New-Object byte[] 1536))
        { Assert-FileSize -Path $f -MaxBytes 1024 -Label 'wim' } |
            Should -Throw '*512 B*'
    }
}

Describe 'Assert-True' {
    It 'throws on false' {
        { Assert-True -Condition $false -Message 'synthetic failure' } |
            Should -Throw '*synthetic failure*'
    }

    It 'is silent on true' {
        { Assert-True -Condition $true -Message 'x' } | Should -Not -Throw
    }
}

Describe 'Assert-PathExists' {
    It 'throws with the path in the message' {
        { Assert-PathExists -Path 'C:\micpe\nope.txt' } | Should -Throw '*nope.txt*'
    }

    It 'uses the custom label when supplied' {
        { Assert-PathExists -Path 'C:\micpe\nope.txt' -Label 'install.wim' } |
            Should -Throw '*install.wim*'
    }
}

Describe 'Format-ByteSize' {
    It 'formats gigabytes with two decimals' {
        Format-ByteSize -Bytes 3GB | Should -Be '3.00 GB'
    }

    It 'formats megabytes with one decimal' {
        Format-ByteSize -Bytes (512MB) | Should -Be '512.0 MB'
    }

    It 'formats small values as bytes' {
        Format-ByteSize -Bytes 42 | Should -Be '42 B'
    }
}

Describe 'Get-MicpeTempDir' {
    It 'creates the directory under the given root' {
        $root = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot "micpe-root-$(Get-Random)")
        $dir = Get-MicpeTempDir -Root $root.FullName
        $dir | Should -Be (Join-Path $root.FullName 'micpe-tmp')
        Test-Path -LiteralPath $dir | Should -BeTrue
    }

    It 'is idempotent' {
        $root = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot "micpe-root-$(Get-Random)")
        $first = Get-MicpeTempDir -Root $root.FullName
        $second = Get-MicpeTempDir -Root $root.FullName
        $first | Should -Be $second
    }
}
