# Fake bcdedit for Pester: logs its arguments and simulates the /set and
# /enum behaviour the BCD experiment relies on. Invoked via -BcdeditPath;
# never touches a real BCD store.
#
# Env:
#   MICPE_FAKE_BCDEDIT_LOG            append one argument per line when set.
#   MICPE_FAKE_BCDEDIT_FAIL_SET=1     make `/set ... nointegritychecks on`
#                                     exit 1 (simulates a bcdedit failure);
#                                     the build's assertion must fail loudly.
#   MICPE_FAKE_BCDEDIT_ENUM_NO=1      make `/enum {default}` print
#                                     nointegritychecks No instead of Yes
#                                     (simulates a /set that did not stick).
$ErrorActionPreference = 'Stop'

if ($env:MICPE_FAKE_BCDEDIT_LOG) {
    ($args -join "`n") | Add-Content -LiteralPath $env:MICPE_FAKE_BCDEDIT_LOG
}

if ($args -contains '/set') {
    if ($env:MICPE_FAKE_BCDEDIT_FAIL_SET -eq '1') {
        Write-Output 'The specified entry could not be found.'
        $global:LASTEXITCODE = 1
        return
    }
    $global:LASTEXITCODE = 0
    return
}

if ($args -contains '/enum') {
    $value = if ($env:MICPE_FAKE_BCDEDIT_ENUM_NO -eq '1') { 'No' } else { 'Yes' }
    @(
        'Windows Boot Loader'
        '-------------------'
        'identifier              {7619dcc9-fafe-11d9-b411-000476eba25f}'
        'device                  ramdisk=[boot]\sources\boot.wim,{7619dcc8-fafe-11d9-b411-000476eba25f}'
        "nointegritychecks       $value"
    ) | Write-Output
    $global:LASTEXITCODE = 0
    return
}

$global:LASTEXITCODE = 0
