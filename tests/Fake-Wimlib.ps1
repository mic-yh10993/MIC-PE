# Fake wimlib-imagex for Pester: logs its arguments and simulates the
# extract semantics that matter to the build (flatten vs preserve).
# Invoked via -WimlibPath; never touches a real WIM.
#
# Env:
#   MICPE_FAKE_WIMLIB_LOG            append one argument per line when set.
#   MICPE_FAKE_WIMLIB_INFO           LF-separated wimlib `info` output to
#                                    print instead of the stock header (lets
#                                    a test feed a realistic header, e.g.
#                                    Boot Index 0 plus image blocks).
#   MICPE_FAKE_WIMLIB_FLATTEN_ALWAYS=1
#                                    ignore --preserve-dir-structure and
#                                    always flatten (simulates a broken
#                                    extractor, or a regression that drops
#                                    the flag); the build's assertion must
#                                    still fail loudly in that case.
$ErrorActionPreference = 'Stop'

if ($env:MICPE_FAKE_WIMLIB_LOG) {
    ($args -join "`n") | Add-Content -LiteralPath $env:MICPE_FAKE_WIMLIB_LOG
}

# `info` (no --boot): print a stock two-image header so Get-WimBootIndex
# has a 'Boot Index' line to parse. `info --boot N` only marks the image
# bootable; the header rewrite is not simulated, the call itself is the
# assertion (the log above records it).
if ($args -contains 'info') {
    if ($args -contains '--boot') {
        $LASTEXITCODE = 0
        return
    }
    if ($env:MICPE_FAKE_WIMLIB_INFO) {
        ($env:MICPE_FAKE_WIMLIB_INFO -split "`n") | Write-Output
        $LASTEXITCODE = 0
        return
    }
    @('WIM Information:', 'Image Count:    2', 'Boot Index:     2') | Write-Output
    $LASTEXITCODE = 0
    return
}

# `capture <source> <dest> [name] ...`: the clean rebuild captures a
# staging tree into a fresh boot.wim. The fake cannot build a real WIM,
# but it creates the dest file so the caller's Assert-PathExists passes
# and the argument log records the capture flags (--boot, --compress,
# --check, image name) for the test to assert on.
if ($args -contains 'capture') {
    $captureIdx = [Array]::IndexOf($args, 'capture')
    $dest = $args[$captureIdx + 2]
    if ($dest) {
        $parent = Split-Path -Parent $dest
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Set-Content -LiteralPath $dest -Value 'FAKE-WIM' -NoNewline
    }
    $LASTEXITCODE = 0
    return
}

$destArg = @($args | Where-Object { $_ -like '--dest-dir=*' }) | Select-Object -First 1
$hasHive = $args -contains 'Windows/System32/config/SOFTWARE'
if ($destArg -and $hasHive) {
    $dir = $destArg.Substring('--dest-dir='.Length)
    $preserve = ($args -contains '--preserve-dir-structure') -and ($env:MICPE_FAKE_WIMLIB_FLATTEN_ALWAYS -ne '1')
    if ($preserve) {
        $nested = Join-Path $dir 'Windows/System32/config'
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $nested 'SOFTWARE') -Value 'FAKE-HIVE' -NoNewline
    }
    else {
        Set-Content -LiteralPath (Join-Path $dir 'SOFTWARE') -Value 'FAKE-HIVE' -NoNewline
    }
}

$LASTEXITCODE = 0
