# Fake wimlib-imagex for Pester: logs its arguments and simulates the
# extract semantics that matter to the build (flatten vs preserve).
# Invoked via -WimlibPath; never touches a real WIM.
#
# Env:
#   MICPE_FAKE_WIMLIB_LOG            append one argument per line when set.
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
