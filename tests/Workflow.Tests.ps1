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

    It 'uploads the serial log with the verify artifacts' {
        $script:buildYml | Should -Match 'micpe-serial\.log'
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

    It 'passes the ISO path to the QEMU verifier through a step-level env mapping' {
        # run 43884981629 showed the runner's env display listing ISO_PATH
        # while the pwsh process saw an empty string, so the path is now
        # resolved by the runner into IN_ISO at step setup (the same
        # mechanism that already carries IN_STAGE and the upload steps).
        $script:buildYml | Should -Match 'IN_ISO:'
        $script:buildYml | Should -Match '\$\{\{ env\.ISO_PATH \}\}'
        $script:buildYml | Should -Match '-Iso \$iso'
        $script:buildYml | Should -Not -Match '-Iso \$env:ISO_PATH'
    }

    It 'fails fast in the verify step when the ISO path is empty or missing' {
        $script:buildYml | Should -Match 'no ISO path was passed'
        $script:buildYml | Should -Match "ISO file not found at"
    }

    It 'exports artifact paths whenever GITHUB_ENV is set, even without a step summary' {
        $script:buildScript | Should -Match 'if \(\$env:GITHUB_ENV\)'
        $script:buildScript | Should -Match 'Add-Content -LiteralPath \$env:GITHUB_ENV'
    }

    It 'ensures the OVMF firmware exists before the QEMU verifier runs' {
        $script:buildYml | Should -Match 'Ensure OVMF firmware'
        $script:buildYml | Should -Match 'Find-OvmfCode'
        $script:buildYml | Should -Match 'OVMF_PATH='
        $script:buildYml | Should -Match 'No UEFI firmware found'
    }

    It 'forces UEFI boot in the QEMU verifier with the resolved firmware path' {
        $script:buildYml | Should -Match '-Firmware uefi'
        $script:buildYml | Should -Match '-FirmwarePath'
        $script:buildYml | Should -Match 'IN_OVMF:'
    }

    It 'fails fast in the verify step when the OVMF path is empty or missing' {
        $script:buildYml | Should -Match 'no OVMF path was passed'
        $script:buildYml | Should -Match "OVMF firmware file not found at"
    }

    It 'saves and restores -Iso across the dot-source of the QEMU helper' {
        # Dot-sourcing Invoke-QemuVerify.ps1 binds its param block in the
        # caller scope and resets $Iso/$TimeoutMin/$QemuPath to their
        # defaults; Test-Stage.ps1 must save them first and restore them
        # after, or $Iso comes back empty and the verifier dies on
        # parameter binding (runs 43884981629 and 43891758991).
        $dotIdx = $script:testStage.IndexOf("Invoke-QemuVerify.ps1') -ParseOnly")
        $dotIdx | Should -BeGreaterThan 0
        $saveIdx = $script:testStage.IndexOf('$dotSourceParams = @{ Iso = $Iso;')
        $saveIdx | Should -BeGreaterThan 0
        $saveIdx | Should -BeLessThan $dotIdx
        $restoreIdx = $script:testStage.IndexOf('$Iso = $dotSourceParams.Iso')
        $restoreIdx | Should -BeGreaterThan $dotIdx
        # $Firmware is declared by the helper too, so it needs the same
        # save/restore treatment, or it silently resets to 'auto'.
        $script:testStage | Should -Match 'Firmware = \$Firmware'
        $script:testStage | Should -Match '\$Firmware = \$dotSourceParams\.Firmware'
        # $FirmwarePath is declared by the helper too, so it needs the
        # same treatment, or it silently resets to '' and the verifier
        # falls back to searching for the firmware itself.
        $script:testStage | Should -Match 'FirmwarePath = \$FirmwarePath'
        $script:testStage | Should -Match '\$FirmwarePath = \$dotSourceParams\.FirmwarePath'
    }

    It 'does not nest the GITHUB_ENV exports inside the step-summary block' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repoRoot 'src/build/Build-Micpe.ps1'), [ref] $tokens, [ref] $errors)
        $errors.Count | Should -Be 0
        $summaryIf = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses.Count -gt 0 -and
                    $node.Clauses[0].Item1.Extent.Text -eq '$env:GITHUB_STEP_SUMMARY'
            }, $true)
        @($summaryIf).Count | Should -Be 1
        $summaryIf[0].Extent.Text | Should -Not -Match 'GITHUB_ENV'
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

    It 'tries the PECMD desktop shell before falling back to cmd' {
        $script = Get-Content -LiteralPath (Join-Path $repoRoot 'src/shell/startnet.cmd') -Raw
        $script | Should -Match 'PECMD\.EXE'
        $script | Should -Match 'PECMD\.INI'
        $script.IndexOf('PECMD.EXE') | Should -BeLessThan $script.IndexOf('probe.cmd')
    }
}

Describe 'M2/M3 step wiring' {
    BeforeAll {
        $script:buildScript = Get-Content -LiteralPath (Join-Path $repoRoot 'src/build/Build-Micpe.ps1') -Raw
    }

    It 'loads Shell.ps1' {
        # The dot-source loop appends '.ps1' to each name, so assert on the
        # library list entry rather than a literal 'Shell.ps1'.
        $script:buildScript | Should -Match "'Registry', 'Shell', 'Uwp', 'BaseImage'"
    }

    It 'dispatches the explorer, runtimes and components steps' {
        foreach ($step in 'explorer', 'runtimes', 'components') {
            $script:buildScript | Should -Match "'$step'\s*\{" -Because "step $step must be dispatched"
        }
    }

    It 'imports the M2 registry patches in order' {
        $script:buildScript | Should -Match '10-pe-base\.reg'
        $script:buildScript | Should -Match '20-explorer\.reg'
        # Assert on the array literal itself, not raw IndexOf: the step's
        # comment mentions 20-explorer.reg before the array does.
        $script:buildScript | Should -Match "@\('10-pe-base\.reg', '20-explorer\.reg'\)"
    }

    It 'asserts the Explorer shell and the IME registration in their steps' {
        $script:buildScript | Should -Match 'Assert-ExplorerPresent'
        $script:buildScript | Should -Match 'Assert-ImeRegistered'
        $script:buildScript | Should -Match '30-components\.reg'
    }

    It 'mounts and commits boot.wim around each M2/M3 step' {
        $script:buildScript | Should -Match 'Invoke-ExplorerStep'
        $script:buildScript | Should -Match 'Invoke-RuntimesStep'
        $script:buildScript | Should -Match 'Invoke-ComponentsStep'
    }
}

Describe 'M4 step wiring' {
    BeforeAll {
        $script:buildScript = Get-Content -LiteralPath (Join-Path $repoRoot 'src/build/Build-Micpe.ps1') -Raw
    }

    It 'loads Uwp.ps1' {
        $script:buildScript | Should -Match "'Shell', 'Uwp', 'BaseImage'"
    }

    It 'dispatches the uwp step' {
        $script:buildScript | Should -Match "'uwp'\s*\{"
    }

    It 'imports the M4 registry patch' {
        $script:buildScript | Should -Match '40-uwp\.reg'
    }

    It 'installs the framework and apps, registers and asserts them in the step' {
        $script:buildScript | Should -Match 'Install-AppxFramework'
        $script:buildScript | Should -Match 'Install-UwpApps'
        $script:buildScript | Should -Match 'Register-ProvisionedAppx'
        $script:buildScript | Should -Match 'Assert-UwpReady'
    }

    It 'mounts and commits boot.wim around the uwp step' {
        $script:buildScript | Should -Match 'Invoke-UwpStep'
    }
}
