# Fake takeown.exe for Pester: logs its arguments and pretends to take
# ownership, like the real `takeown /F <path> /A`. Invoked via
# -TakeownPath; never touches a real ACL.
#
# Env:
#   MICPE_FAKE_TAKEOWN_LOG    append one argument per line when set.
$ErrorActionPreference = 'Stop'

if ($env:MICPE_FAKE_TAKEOWN_LOG) {
    ($args -join "`n") | Add-Content -LiteralPath $env:MICPE_FAKE_TAKEOWN_LOG
}

$LASTEXITCODE = 0
