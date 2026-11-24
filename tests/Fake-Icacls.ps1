# Fake icacls.exe for Pester: logs its arguments and prints a canned ACL
# line, like the real `icacls <path>`. Invoked via -IcaclsPath; never
# touches a real ACL.
#
# Env:
#   MICPE_FAKE_ICACLS_LOG    append one argument per line when set.
$ErrorActionPreference = 'Stop'

if ($env:MICPE_FAKE_ICACLS_LOG) {
    ($args -join "`n") | Add-Content -LiteralPath $env:MICPE_FAKE_ICACLS_LOG
}

# Canned ACL output, so Show-StagingWriteState has something to print.
if ($args.Count -gt 0) {
    Write-Output "$($args[0]) BUILTIN\Administrators:(OI)(CI)(F)"
}

$LASTEXITCODE = 0
