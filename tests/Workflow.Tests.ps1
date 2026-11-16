BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
}

Describe 'build workflow' {
    BeforeAll {
        $script:workflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/build.yml') -Raw
    }

    It 'runs on windows-2025 with the 6 hour ceiling' {
        $script:workflow | Should -Match 'windows-2025'
        $script:workflow | Should -Match 'timeout-minutes:\s*360'
    }

    It 'accepts the stage, build, office, chrome and verify inputs' {
        foreach ($name in 'stage', 'build', 'office', 'chrome', 'verify') {
            $script:workflow | Should -Match "(?m)^\s{6}${name}:" -Because "input $name must exist"
        }
    }

    It 'passes inputs through environment variables, never inline interpolation' {
        $script:workflow | Should -Match 'IN_STAGE:'
        $script:workflow | Should -Match 'IN_BUILD:'
        $script:workflow | Should -Not -Match "Stage = '\$\{\{ inputs\.stage \}\}'"
    }

    It 'installs wimlib and oscdimg' {
        $script:workflow | Should -Match 'wimlib'
        $script:workflow | Should -Match 'oscdimg'
    }

    It 'uploads the ISO and the boot.wim as artifacts' {
        $script:workflow | Should -Match 'actions/upload-artifact'
        $script:workflow | Should -Match 'BOOT_WIM_PATH'
    }
}

Describe 'build.yml verify wiring' {
    BeforeAll {
        $script:buildYml = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/build.yml') -Raw
        $script:testStage = Get-Content -LiteralPath (Join-Path $repoRoot 'src/ci/Test-Stage.ps1') -Raw
        $script:buildScript = Get-Content -LiteralPath (Join-Path $repoRoot 'src/build/Build-Micpe.ps1') -Raw
    }

    It 'runs the QEMU verifier when verify=full' {
        $script:buildYml | Should -Match 'Test-Stage.ps1'
        $script:buildYml | Should -Match "inputs.verify == 'full'"
        $script:buildYml | Should -Match 'qemu'
    }

    It 'uploads probe artifacts even when verification fails' {
        $script:buildYml | Should -Match 'micpe-probe.txt'
        $script:buildYml | Should -Match "if: always\(\) && inputs.verify == 'full'"
    }

    It 'patches the bundled aria2 verifier before the converter runs' {
        $script:buildScript | Should -Match 'Repair-UupAria2Script'
    }

    It 'injects startnet.cmd and probe.cmd into the media boot.wim' {
        $script:buildScript | Should -Match 'Mount-WimImage'
        $script:buildScript | Should -Match 'probe.cmd'
        $script:buildScript | Should -Match 'startnet.cmd'
    }

    It 'fails fast when oscdimg is missing after the ADK install' {
        $script:buildYml | Should -Match 'oscdimg not found after installing windows-adk'
    }

    It 'passes the resolved oscdimg path to the ISO step' {
        $script:buildScript | Should -Match 'Get-OscdimgPath'
        $script:buildScript | Should -Match '-OscdimgPath \(Get-OscdimgPath\)'
    }

    It 'loads the shared logging helpers in Test-Stage.ps1 before using them' {
        $script:testStage | Should -Match 'Common.ps1'
        $script:testStage.IndexOf('Common.ps1') | Should -BeLessThan $script:testStage.IndexOf('Write-Step')
    }
}

Describe 'test workflow' {
    It 'runs the syntax check and Pester through the CI entry point' {
        $workflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/test.yml') -Raw
        $workflow | Should -Match 'Invoke-Ci\.ps1 -Task syntax'
        $workflow | Should -Match 'Invoke-Ci\.ps1 -Task test'
    }
}

Describe 'startnet.cmd' {
    It 'runs wpeinit and leaves the user at a prompt' {
        $script = Get-Content -LiteralPath (Join-Path $repoRoot 'src/shell/startnet.cmd') -Raw
        $script | Should -Match 'wpeinit'
        $script | Should -Match 'cmd\.exe'
    }

    It 'starts the probe from startnet.cmd when present' {
        $script = Get-Content -LiteralPath (Join-Path $repoRoot 'src/shell/startnet.cmd') -Raw
        $script | Should -Match 'probe.cmd'
    }
}
