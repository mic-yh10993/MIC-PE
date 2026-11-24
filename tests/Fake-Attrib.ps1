# Fake attrib.exe for Pester: logs its arguments and clears the read-only
# attribute on the target tree, like the real `attrib -R <path> /S /D`.
# Invoked via -AttribPath; never touches a real WIM.
#
# Env:
#   MICPE_FAKE_ATTRIB_LOG    append one argument per line when set.
$ErrorActionPreference = 'Stop'

if ($env:MICPE_FAKE_ATTRIB_LOG) {
    ($args -join "`n") | Add-Content -LiteralPath $env:MICPE_FAKE_ATTRIB_LOG
}

# Simulate `attrib -R <path> /S /D`: clear ReadOnly on the target and
# everything under it, so the test can assert the tree is writable after
# Clear-StagingReadOnly runs. Args are: -R <path> /S /D.
$target = $args[1]
if ($target -and (Test-Path -LiteralPath $target)) {
    $item = Get-Item -LiteralPath $target -Force
    $item.Attributes = $item.Attributes -band -bnot [IO.FileAttributes]::ReadOnly
    Get-ChildItem -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $_.Attributes = $_.Attributes -band -bnot [IO.FileAttributes]::ReadOnly
    }
}

$LASTEXITCODE = 0
