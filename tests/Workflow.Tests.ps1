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
}
