# Fake 7z for Pester: logs its arguments and simulates the `x` (extract)
# behaviour the catalog fix relies on. Invoked via -SevenZipPath; never
# touches a real archive.
#
# Env:
#   MICPE_FAKE_7Z_LOG            append one argument per line when set.
#   MICPE_FAKE_7Z_SOURCE_DIR     directory of fixture files to "extract".
#                                Files whose leaf name matches a wildcard
#                                argument (e.g. *Package0110*.cat) are
#                                copied into the -o<dir> destination.
#   MICPE_FAKE_7Z_FAIL=1         exit 1 (simulates a 7z failure); the
#                                build's assertion must fail loudly.
$ErrorActionPreference = 'Stop'

if ($env:MICPE_FAKE_7Z_LOG) {
    ($args -join "`n") | Add-Content -LiteralPath $env:MICPE_FAKE_7Z_LOG
}

if ($env:MICPE_FAKE_7Z_FAIL -eq '1') {
    Write-Output 'ERROR: Can not open the file as archive'
    $global:LASTEXITCODE = 1
    return
}

if ($args -contains 'x') {
    $destArg = @($args | Where-Object { $_ -like '-o*' }) | Select-Object -First 1
    if ($destArg -and $env:MICPE_FAKE_7Z_SOURCE_DIR) {
        $dest = $destArg.Substring(2)
        if (-not (Test-Path -LiteralPath $dest)) {
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
        }
        $wildcards = @($args | Where-Object { $_ -like '*cat' })
        foreach ($file in (Get-ChildItem -LiteralPath $env:MICPE_FAKE_7Z_SOURCE_DIR -File)) {
            $matched = $false
            foreach ($pattern in $wildcards) {
                if ($file.Name -like $pattern) { $matched = $true; break }
            }
            if ($matched) {
                Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $dest $file.Name) -Force
            }
        }
    }
}

$global:LASTEXITCODE = 0
