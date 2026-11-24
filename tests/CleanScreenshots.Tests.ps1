BeforeAll {
    . "$PSScriptRoot/../src/ci/Export-CleanScreenshots.ps1"
    $script:TempRoot = [System.IO.Path]::GetTempPath()

    # Helpers live in BeforeAll: Pester runs Describe blocks in their own
    # scope, so top-level function definitions are not visible inside It.
    function New-TestPpmBytes {
        param(
            [int] $Width,
            [int] $Height,
            [byte[]] $Rgb,
            [string] $Header = $null
        )
        # A [string] parameter defaulting to $null binds as "" (empty),
        # not $null, so test for empty rather than for $null.
        if ([string]::IsNullOrEmpty($Header)) { $Header = "P6`n$Width $Height`n255`n" }
        $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($Header)
        $ppm = [byte[]]::new($headerBytes.Length + $Rgb.Length)
        [System.Buffer]::BlockCopy($headerBytes, 0, $ppm, 0, $headerBytes.Length)
        [System.Buffer]::BlockCopy($Rgb, 0, $ppm, $headerBytes.Length, $Rgb.Length)
        return $ppm
    }

    function Read-PngPixels {
        param([string] $PngPath)
        $bytes = [System.IO.File]::ReadAllBytes($PngPath)
        $signature = [byte[]]@(137, 80, 78, 71, 13, 10, 26, 10)
        for ($i = 0; $i -lt 8; $i++) {
            if ($bytes[$i] -ne $signature[$i]) { throw "not a PNG file: '$PngPath'" }
        }
        $pos = 8
        $idat = [System.Collections.Generic.List[byte]]::new()
        $width = 0
        $height = 0
        $bitDepth = 0
        $colorType = 0
        while ($pos -lt $bytes.Length) {
            # Array slices come back as Object[] in PowerShell, so cast
            # them back to byte[] before handing them to .NET APIs.
            $lenBytes = [byte[]]$bytes[$pos..($pos + 3)]
            if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($lenBytes) }
            $length = [System.BitConverter]::ToInt32($lenBytes, 0)
            $type = [System.Text.Encoding]::ASCII.GetString($bytes, $pos + 4, 4)
            $data = [byte[]]$bytes[($pos + 8)..($pos + 8 + $length - 1)]
            if ($type -eq 'IHDR') {
                $wBytes = [byte[]]$data[0..3]; $hBytes = [byte[]]$data[4..7]
                if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($wBytes); [Array]::Reverse($hBytes) }
                $width = [System.BitConverter]::ToInt32($wBytes, 0)
                $height = [System.BitConverter]::ToInt32($hBytes, 0)
                $bitDepth = $data[8]
                $colorType = $data[9]
            }
            elseif ($type -eq 'IDAT') {
                $idat.AddRange($data)
            }
            elseif ($type -eq 'IEND') { break }
            $pos += 12 + $length
        }
        $compressed = [System.IO.MemoryStream]::new($idat.ToArray())
        $zlib = [System.IO.Compression.ZLibStream]::new($compressed, [System.IO.Compression.CompressionMode]::Decompress)
        $out = [System.IO.MemoryStream]::new()
        $zlib.CopyTo($out)
        $zlib.Dispose()
        $compressed.Dispose()
        return @{
            Width      = $width
            Height     = $height
            BitDepth   = $bitDepth
            ColorType  = $colorType
            Scanlines  = $out.ToArray()
        }
    }
}

Describe 'Convert-PpmToPng' {
    It 'writes a valid PNG with the same pixels as the PPM' {
        $dir = Join-Path $script:TempRoot "clean-shots-valid-$(Get-Random)"
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            # 3x2, distinct colours per pixel: red, green, blue / white, black, yellow.
            $rgb = [byte[]]@(255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 0, 0, 0, 255, 255, 0)
            $ppmPath = Join-Path $dir 'shot-01.ppm'
            [System.IO.File]::WriteAllBytes($ppmPath, (New-TestPpmBytes -Width 3 -Height 2 -Rgb $rgb))
            $pngPath = Join-Path $dir 'shot-01.png'
            Convert-PpmToPng -PpmPath $ppmPath -PngPath $pngPath
            $png = Read-PngPixels -PngPath $pngPath
            $png.Width | Should -Be 3
            $png.Height | Should -Be 2
            $png.BitDepth | Should -Be 8
            $png.ColorType | Should -Be 2
            # Filter byte 0 + raw RGB per row, in row order.
            $expected = [byte[]]@(0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 255, 255, 255, 0, 0, 0, 255, 255, 0)
            [System.Linq.Enumerable]::SequenceEqual($png.Scanlines, $expected) | Should -BeTrue
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'accepts a PPM header with a comment line' {
        $dir = Join-Path $script:TempRoot "clean-shots-comment-$(Get-Random)"
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $rgb = [byte[]]@(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)
            $ppmPath = Join-Path $dir 'shot-01.ppm'
            [System.IO.File]::WriteAllBytes($ppmPath, (New-TestPpmBytes -Width 2 -Height 2 -Rgb $rgb -Header "P6`n# QEMU screendump`n2 2`n255`n"))
            $pngPath = Join-Path $dir 'shot-01.png'
            Convert-PpmToPng -PpmPath $ppmPath -PngPath $pngPath
            (Read-PngPixels -PngPath $pngPath).Width | Should -Be 2
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects a P3 (ASCII) PPM' {
        $dir = Join-Path $script:TempRoot "clean-shots-p3-$(Get-Random)"
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $ppmPath = Join-Path $dir 'shot-01.ppm'
            [System.IO.File]::WriteAllBytes($ppmPath, (New-TestPpmBytes -Width 1 -Height 1 -Rgb ([byte[]]@(0, 0, 0)) -Header "P3`n1 1`n255`n"))
            { Convert-PpmToPng -PpmPath $ppmPath -PngPath (Join-Path $dir 'shot-01.png') } | Should -Throw '*P6*'
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects a maxval other than 255' {
        $dir = Join-Path $script:TempRoot "clean-shots-maxval-$(Get-Random)"
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $ppmPath = Join-Path $dir 'shot-01.ppm'
            [System.IO.File]::WriteAllBytes($ppmPath, (New-TestPpmBytes -Width 1 -Height 1 -Rgb ([byte[]]@(0, 0, 0)) -Header "P6`n1 1`n65535`n"))
            { Convert-PpmToPng -PpmPath $ppmPath -PngPath (Join-Path $dir 'shot-01.png') } | Should -Throw '*maxval*255*'
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects a truncated raster' {
        $dir = Join-Path $script:TempRoot "clean-shots-trunc-$(Get-Random)"
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $ppmPath = Join-Path $dir 'shot-01.ppm'
            # Header claims 2x2 (12 raster bytes) but only 3 are present.
            [System.IO.File]::WriteAllBytes($ppmPath, (New-TestPpmBytes -Width 2 -Height 2 -Rgb ([byte[]]@(1, 2, 3))))
            { Convert-PpmToPng -PpmPath $ppmPath -PngPath (Join-Path $dir 'shot-01.png') } | Should -Throw '*truncated*'
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects an empty file' {
        $dir = Join-Path $script:TempRoot "clean-shots-empty-$(Get-Random)"
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $ppmPath = Join-Path $dir 'shot-01.ppm'
            [System.IO.File]::WriteAllBytes($ppmPath, [byte[]]@())
            { Convert-PpmToPng -PpmPath $ppmPath -PngPath (Join-Path $dir 'shot-01.png') } | Should -Throw '*truncated*'
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-PngCrc32' {
    It 'matches the known CRC32 check value' {
        # CRC32("123456789") = 0xCBF43926 = 3421780262. The check value is
        # written decimal: a 0xCBF43926 hex literal parses as a negative
        # Int32 in PowerShell and would fail the comparison.
        $crc = Get-PngCrc32 -Data ([System.Text.Encoding]::ASCII.GetBytes('123456789'))
        $crc | Should -Be ([uint32]3421780262)
    }
}

Describe 'Export-CleanScreenshots' {
    It 'converts every shot-*.ppm to a PNG and returns the PNG paths' {
        $dir = Join-Path $script:TempRoot "clean-shots-export-$(Get-Random)"
        try {
            $shotDir = Join-Path $dir 'screenshots'
            New-Item -ItemType Directory -Path $shotDir -Force | Out-Null
            $rgb = [byte[]]@(10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120)
            [System.IO.File]::WriteAllBytes((Join-Path $shotDir 'shot-01.ppm'), (New-TestPpmBytes -Width 2 -Height 2 -Rgb $rgb))
            [System.IO.File]::WriteAllBytes((Join-Path $shotDir 'shot-02.ppm'), (New-TestPpmBytes -Width 2 -Height 2 -Rgb $rgb))
            # A non-screenshot file must be ignored.
            Set-Content -LiteralPath (Join-Path $shotDir 'notes.txt') -Value 'not a screenshot'
            $outDir = Join-Path $dir 'png'
            $files = @(Export-CleanScreenshots -ScreenshotDir $shotDir -OutputDir $outDir)
            $files.Count | Should -Be 2
            foreach ($file in $files) {
                $file | Should -Match '\.png$'
                Test-Path -LiteralPath $file | Should -BeTrue
                (Read-PngPixels -PngPath $file).Width | Should -Be 2
            }
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'falls back to the original PPM when one file is corrupt (run 45432615549)' {
        # A conversion bug must never lose the evidence: the corrupt shot
        # still lands in the Release as its original PPM.
        $dir = Join-Path $script:TempRoot "clean-shots-fallback-$(Get-Random)"
        try {
            $shotDir = Join-Path $dir 'screenshots'
            New-Item -ItemType Directory -Path $shotDir -Force | Out-Null
            $rgb = [byte[]]@(10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120)
            [System.IO.File]::WriteAllBytes((Join-Path $shotDir 'shot-01.ppm'), (New-TestPpmBytes -Width 2 -Height 2 -Rgb $rgb))
            Set-Content -LiteralPath (Join-Path $shotDir 'shot-02.ppm') -Value 'this is not a PPM at all' -Encoding ASCII
            $outDir = Join-Path $dir 'png'
            $files = @(Export-CleanScreenshots -ScreenshotDir $shotDir -OutputDir $outDir -WarningVariable warnings)
            $files.Count | Should -Be 2
            # @() around the filter: under StrictMode, .Count on a $null
            # (no match) or a bare scalar throws instead of returning 0/1.
            @($files | Where-Object { $_ -match '\.png$' }).Count | Should -Be 1
            @($files | Where-Object { $_ -match 'shot-02\.ppm$' }).Count | Should -Be 1
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns empty when the directory has no screenshots' {
        $dir = Join-Path $script:TempRoot "clean-shots-none-$(Get-Random)"
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $files = @(Export-CleanScreenshots -ScreenshotDir $dir -OutputDir (Join-Path $dir 'png') -WarningVariable warnings)
            $files.Count | Should -Be 0
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns empty when the directory does not exist' {
        $dir = Join-Path $script:TempRoot "clean-shots-missing-$(Get-Random)"
        $files = @(Export-CleanScreenshots -ScreenshotDir $dir -OutputDir (Join-Path $dir 'png') -WarningVariable warnings)
        $files.Count | Should -Be 0
    }
}
