#Requires -Version 7.0
<#
.SYNOPSIS
    Export QEMU clean-verify screenshots (PPM) as PNG files for Release upload.

.DESCRIPTION
    The clean verifier (Invoke-CleanQemuVerify.ps1) captures screenshots
    with QEMU's monitor `screendump`, which writes binary PPM (P6) files:
    shot-01..07.ppm, about 3 MB each. PPM is not viewable in a browser or
    in Windows Photos, so the reviewer cannot just click a Release asset
    and look at it.

    This script converts each shot-*.ppm to a PNG with a pure-PowerShell
    encoder (no ImageMagick, ffmpeg, or PIL: none of those is guaranteed
    on the windows-2025 runner, and the encoder runs on Linux dev machines
    too). The PNGs are uploaded to the same Release as the ISO and boot.wim
    by the "Upload finished build to Release" step in build.yml.

    Why the Release, not just the artifact: run 45432615549 captured all
    7 screenshots, but the `micpe-clean-verify` artifact upload hit the
    GitHub storage-quota counter ("Artifact storage quota has been hit")
    and the runner was destroyed with the screenshots on it — no copy
    survived. The ISO and boot.wim survived exactly because they rode the
    Release. The artifact upload stays as a backup; the Release is the
    durable channel.

    Conversion failures fall back to the original PPM (warned, not fatal):
    the evidence still lands in the Release, and the Release step must
    never fail just because one screenshot would not convert.
#>

[CmdletBinding()]
param(
    # Dot-source only (tests): the script only defines functions, so
    # dot-sourcing it is side-effect free with or without this switch.
    [switch] $ParseOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function ConvertTo-BigEndianUInt32 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [uint32] $Value
    )
    $bytes = [System.BitConverter]::GetBytes($Value)
    if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    # The comma keeps the byte array intact: a bare `return $bytes`
    # enumerates it into the pipeline and the caller gets an Object[].
    return ,$bytes
}

function Get-PngCrc32 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]] $Data
    )
    # IEEE CRC-32 (PNG chunk CRC). The polynomial is written decimal:
    # a 0xEDB88320 hex literal parses as a negative Int32 in PowerShell
    # and breaks the table build.
    $polynomial = [uint32]3988292384
    $table = [uint32[]]::new(256)
    for ($i = 0; $i -lt 256; $i++) {
        $c = [uint32]$i
        for ($k = 0; $k -lt 8; $k++) {
            if (($c -band 1) -eq 1) { $c = [uint32]($polynomial -bxor ($c -shr 1)) }
            else { $c = [uint32]($c -shr 1) }
        }
        $table[$i] = $c
    }
    $crc = [uint32]::MaxValue
    for ($i = 0; $i -lt $Data.Length; $i++) {
        $index = [int](($crc -bxor $Data[$i]) -band 0xFF)
        $crc = [uint32]($table[$index] -bxor ($crc -shr 8))
    }
    return [uint32]($crc -bxor [uint32]::MaxValue)
}

function Write-PngChunk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.BinaryWriter] $Writer,

        [Parameter(Mandatory = $true)]
        [string] $Type,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]] $Data
    )
    $typeBytes = [System.Text.Encoding]::ASCII.GetBytes($Type)
    $Writer.Write((ConvertTo-BigEndianUInt32 -Value ([uint32]$Data.Length)))
    $Writer.Write($typeBytes)
    if ($Data.Length -gt 0) { $Writer.Write($Data) }
    $crcInput = [byte[]]::new($typeBytes.Length + $Data.Length)
    [System.Buffer]::BlockCopy($typeBytes, 0, $crcInput, 0, $typeBytes.Length)
    if ($Data.Length -gt 0) { [System.Buffer]::BlockCopy($Data, 0, $crcInput, $typeBytes.Length, $Data.Length) }
    $Writer.Write((ConvertTo-BigEndianUInt32 -Value (Get-PngCrc32 -Data $crcInput)))
}

function Convert-PpmToPng {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $PpmPath,

        [Parameter(Mandatory = $true)]
        [string] $PngPath
    )
    $bytes = [System.IO.File]::ReadAllBytes($PpmPath)

    # P6 header: magic, width, height, maxval, each separated by
    # whitespace; '#' comments may appear wherever whitespace is allowed.
    # QEMU writes "P6\n<width> <height>\n255\n" then the raw raster.
    $pos = 0
    $tokens = @()
    while ($tokens.Count -lt 4) {
        while ($pos -lt $bytes.Length) {
            $b = $bytes[$pos]
            if ($b -eq 35) {
                # '#' comment: skip to end of line.
                while ($pos -lt $bytes.Length -and $bytes[$pos] -ne 10) { $pos++ }
            }
            elseif ($b -in 9, 10, 11, 12, 13, 32) { $pos++ }
            else { break }
        }
        if ($pos -ge $bytes.Length) { throw "PPM header truncated in '$PpmPath'" }
        $start = $pos
        while ($pos -lt $bytes.Length -and $bytes[$pos] -notin 9, 10, 11, 12, 13, 32 -and $bytes[$pos] -ne 35) { $pos++ }
        $tokens += [System.Text.Encoding]::ASCII.GetString($bytes, $start, $pos - $start)
    }
    if ($tokens[0] -ne 'P6') { throw "not a binary P6 PPM file: '$PpmPath' (magic '$($tokens[0])')" }
    $width = 0
    $height = 0
    if (-not [int]::TryParse($tokens[1], [ref] $width) -or $width -le 0) {
        throw "PPM header has an invalid width ('$($tokens[1])') in '$PpmPath'"
    }
    if (-not [int]::TryParse($tokens[2], [ref] $height) -or $height -le 0) {
        throw "PPM header has an invalid height ('$($tokens[2])') in '$PpmPath'"
    }
    $maxval = 0
    if (-not [int]::TryParse($tokens[3], [ref] $maxval) -or $maxval -ne 255) {
        throw "PPM maxval must be 255 (got '$($tokens[3])') in '$PpmPath'"
    }

    # Exactly one whitespace byte separates maxval from the raster
    # (a CRLF pair counts as one separator).
    if ($pos -ge $bytes.Length) { throw "PPM header truncated in '$PpmPath'" }
    if ($bytes[$pos] -eq 13 -and ($pos + 1) -lt $bytes.Length -and $bytes[$pos + 1] -eq 10) { $pos += 2 }
    elseif ($bytes[$pos] -in 9, 10, 11, 12, 13, 32) { $pos++ }
    else { throw "PPM header: expected whitespace after maxval in '$PpmPath'" }
    $rasterStart = $pos
    $stride = [long]$width * 3
    $needed = [long]$height * $stride
    if (([long]$bytes.Length - $rasterStart) -lt $needed) {
        throw "PPM raster truncated in '$PpmPath' (need $needed bytes, have $([long]$bytes.Length - $rasterStart))"
    }

    # Scanlines: filter byte 0 (None) + raw RGB per row. BlockCopy keeps
    # this fast even for a 1280x800 screendump (~3 MB of raster).
    $scanlines = [byte[]]::new([long]$height * ($stride + 1))
    for ($row = 0; $row -lt $height; $row++) {
        $scanlines[[long]$row * ($stride + 1)] = 0
        [System.Buffer]::BlockCopy($bytes, [int]($rasterStart + [long]$row * $stride), $scanlines, [int]([long]$row * ($stride + 1) + 1), [int]$stride)
    }

    # zlib stream (RFC 1950): ZLibStream writes the header, the raw
    # deflate payload, and the Adler-32 trailer natively.
    $compressed = [System.IO.MemoryStream]::new()
    try {
        $zlib = [System.IO.Compression.ZLibStream]::new($compressed, [System.IO.Compression.CompressionLevel]::Optimal, $true)
        $zlib.Write($scanlines, 0, $scanlines.Length)
        $zlib.Dispose()
        $idat = $compressed.ToArray()
    }
    finally {
        $compressed.Dispose()
    }

    $png = [System.IO.MemoryStream]::new()
    try {
        $writer = [System.IO.BinaryWriter]::new($png)
        $writer.Write([byte[]]@(137, 80, 78, 71, 13, 10, 26, 10))
        $ihdr = [byte[]]::new(13)
        [System.Buffer]::BlockCopy((ConvertTo-BigEndianUInt32 -Value ([uint32]$width)), 0, $ihdr, 0, 4)
        [System.Buffer]::BlockCopy((ConvertTo-BigEndianUInt32 -Value ([uint32]$height)), 0, $ihdr, 4, 4)
        $ihdr[8] = 8   # bit depth
        $ihdr[9] = 2   # color type: truecolor RGB
        $ihdr[10] = 0  # compression method
        $ihdr[11] = 0  # filter method
        $ihdr[12] = 0  # interlace method
        Write-PngChunk -Writer $writer -Type 'IHDR' -Data $ihdr
        Write-PngChunk -Writer $writer -Type 'IDAT' -Data $idat
        Write-PngChunk -Writer $writer -Type 'IEND' -Data ([byte[]]@())
        $writer.Flush()
        [System.IO.File]::WriteAllBytes($PngPath, $png.ToArray())
    }
    finally {
        $png.Dispose()
    }
}

function Export-CleanScreenshots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ScreenshotDir,

        [Parameter(Mandatory = $true)]
        [string] $OutputDir
    )
    $ppms = @(Get-ChildItem -LiteralPath $ScreenshotDir -File -Filter 'shot-*.ppm' -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($ppms.Count -eq 0) {
        Write-Warning "Export-CleanScreenshots: no shot-*.ppm files in '$ScreenshotDir'"
        return @()
    }
    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    $files = @()
    foreach ($ppm in $ppms) {
        $png = Join-Path $OutputDir ([System.IO.Path]::ChangeExtension($ppm.Name, '.png'))
        try {
            Convert-PpmToPng -PpmPath $ppm.FullName -PngPath $png
            Write-Host ("screenshot: {0} -> {1}" -f $ppm.Name, (Split-Path -Leaf $png))
            $files += $png
        }
        catch {
            # Never lose the evidence over a conversion bug: the
            # original PPM still lands in the Release.
            Write-Warning ("screenshot convert failed for '{0}' ({1}); uploading the original PPM instead" -f $ppm.FullName, $_.Exception.Message)
            $files += $ppm.FullName
        }
    }
    return $files
}
