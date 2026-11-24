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

    It 'accepts the stage, build, office, chrome, probe, nativeLogonExperiment and verify inputs' {
        foreach ($name in 'stage', 'build', 'office', 'chrome', 'probe', 'nativeLogonExperiment', 'verify') {
            $script:workflow | Should -Match "(?m)^\s{6}${name}:" -Because "input $name must exist"
        }
    }

    It 'accepts the probe boolean input, defaulting to true (debug interactive image)' {
        $script:workflow | Should -Match "(?s)probe:\s*\n\s*description:.*\n\s*type: boolean\s*\n\s*default: true"
    }

    It 'passes the probe flag through IN_PROBE to Build-Micpe.ps1' {
        $script:workflow | Should -Match 'IN_PROBE:'
        $script:workflow | Should -Match 'IN_PROBE -eq ''false'''
        $script:workflow | Should -Match 'buildArgs\.Probe = \$false'
    }

    It 'passes the native logon experiment flag through IN_NATIVE_LOGON_EXPERIMENT to Build-Micpe.ps1' {
        $script:workflow | Should -Match 'IN_NATIVE_LOGON_EXPERIMENT:'
        $script:workflow | Should -Match 'IN_NATIVE_LOGON_EXPERIMENT -eq ''true'''
        $script:workflow | Should -Match 'buildArgs\.NativeLogonExperiment = \$true'
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

    It 'skips the full QEMU verify chain when probe=false (no probe.txt to wait for)' {
        $script:buildYml | Should -Match "inputs\.verify == 'full' && inputs\.probe != false"
        $script:buildYml | Should -Match "if: always\(\) && inputs\.verify == 'full' && inputs\.probe != false"
    }

    It 'leaves probe.cmd out of the image when Probe is off (debug interactive image)' {
        $script:buildScript | Should -Match '\[bool\] \$Probe = \$true'
        $script:buildScript | Should -Match 'if \(\$Probe\)'
        $script:buildScript.IndexOf('if ($Probe)') | Should -BeLessThan $script:buildScript.IndexOf("Copy-Item -LiteralPath `$probe")
        $script:buildScript | Should -Match 'probe disabled: leaving probe.cmd'
    }

    It 'does not shadow the Probe parameter with a local $probe variable in the reseed step (r59)' {
        # PowerShell variables are case-insensitive: a local `$probe = ...`
        # assignment inside Invoke-ReseedStep shadows the script parameter
        # $Probe, so `if ($Probe)` reads the non-empty path string and is
        # always truthy. r59 shipped exactly that way: probe=false was
        # passed correctly, yet probe.cmd was injected anyway.
        $script:buildScript | Should -Not -Match '(?m)^\s*\$probe\s*='
        $script:buildScript | Should -Match '\$probeFile = Join-Path \$repoRoot'
    }

    It 'uploads probe artifacts even when verification fails' {
        $script:buildYml | Should -Match 'micpe-probe.txt'
        $script:buildYml | Should -Match "if: always\(\) && inputs.verify == 'full'"
    }

    It 'uploads the serial log with the verify artifacts' {
        $script:buildYml | Should -Match 'micpe-serial\.log'
    }

    It 'uploads the tasklist dump with the verify artifacts (run 44349189039)' {
        $script:buildYml | Should -Match 'verify-out/share/micpe-tasklist\.txt'
    }

    It 'uploads the mirror copy of the local probe file with the verify artifacts (run 44428428849)' {
        $script:buildYml | Should -Match 'verify-out/mirror/micpe-probe-local\.txt'
    }

    It 'uploads the share copy of the local probe file with the verify artifacts (run 47)' {
        # Run 46: the live probe file came back with a 724-byte NUL
        # hole that ate the Calculator launch result. The probe now
        # copies its local file to the share at the end of every
        # section, and that copy must be uploaded too.
        $script:buildYml | Should -Match 'verify-out/share/micpe-probe-local\.txt'
    }

    It 'uploads the per-segment evtx copies with the verify artifacts (run 47)' {
        # The WER/evtx snapshot is now taken three times mid-run, each
        # copy suffixed by segment, so a wedge cannot take the
        # breakpoint evidence with it.
        $script:buildYml | Should -Match 'verify-out/share/micpe-system-diag\.evtx'
        $script:buildYml | Should -Match 'verify-out/share/micpe-application-diag\.evtx'
        $script:buildYml | Should -Match 'verify-out/share/micpe-system-uwp\.evtx'
        $script:buildYml | Should -Match 'verify-out/share/micpe-application-uwp\.evtx'
        $script:buildYml | Should -Match 'verify-out/share/micpe-system-xcheck\.evtx'
        $script:buildYml | Should -Match 'verify-out/share/micpe-application-xcheck\.evtx'
    }

    It 'uploads the WER report copies with the verify artifacts (run 48)' {
        # Run 47: the Report.wer content never reached the host, so
        # the faulting module is still blank. The probe now copies
        # each explorer Report.wer straight to the share, and the
        # glob must pick them up.
        $script:buildYml | Should -Match 'verify-out/share/micpe-wer-explorer\*\.wer'
    }

    It 'uploads the minidump copies with the verify artifacts (run 49)' {
        # Run 48: Report.wer alone cannot locate the 0x1181ea call
        # stack — only a minidump can. The probe copies every dump
        # to the share under micpe-minidump-<section>-<name>, and
        # the glob must pick them up.
        $script:buildYml | Should -Match 'verify-out/share/micpe-minidump\*'
    }

    It 'wires 60-werdumps.reg into the UWP step as a SYSTEM import and 70-feature-42537950.reg as a privileged write (run 49, run 50, run 51, run 52)' {
        # 60-werdumps.reg rode the plain $regFiles path with 40-uwp.reg
        # through run 50 on the assumption its WER LocalDumps key is
        # admin-writable — but run 50 proved the plain path does not
        # land the key even with the right PE-SOFT address
        # (wer_localdumps_folder=missing while both SYSTEM imports
        # landed), so run 51 moves it to the SYSTEM path with 40-uwp.reg
        # and 70-feature-42537950.reg. Run 52 moves 70-feature out of
        # the SYSTEM path again: run 51 proved even SYSTEM cannot write
        # the FeatureManagement group keys (SYSTEM has only KEY_READ on
        # Overrides\0, \15, \9), so the feature patch goes through the
        # privileged backup/restore write instead. CI-time import only
        # (user decision 2026-11-17 23:43). Run 58 adds
        # 80-etc-42537950.reg to the privileged write: the active
        # EnterpriseTempControls config also gives SYSTEM only
        # KEY_READ, so it rides the same DACL save/write/restore flow.
        $script:buildScript | Should -Match "'40-uwp\.reg', '60-werdumps\.reg', '70-feature-42537950\.reg', '80-etc-42537950\.reg'" -Because 'the ETC patch is imported with the UWP patch'
        $script:buildScript.Contains("-SystemRegFiles @('40-uwp.reg', '60-werdumps.reg')") | Should -BeTrue -Because '40-uwp.reg and 60-werdumps.reg go through the SYSTEM import'
        $script:buildScript.Contains("-PrivilegedRegFiles @('70-feature-42537950.reg', '80-etc-42537950.reg')") | Should -BeTrue -Because '70-feature-42537950.reg and 80-etc-42537950.reg go through the privileged backup/restore write'
        $script:buildScript | Should -Not -Match "SystemRegFiles @\([^)]*70-feature" -Because 'the feature patch must not ride the SYSTEM import anymore'
        $script:buildScript | Should -Not -Match "SystemRegFiles @\([^)]*80-etc" -Because 'the ETC patch must not ride the SYSTEM import either'
    }

    It 'derives the mirror dir from the work dir in Test-Stage.ps1 (run 44428428849)' {
        $script:testStage | Should -Match 'Join-Path \$WorkDir ''mirror'''
        $script:testStage | Should -Match '-MirrorDir \$mirrorDir'
        $script:testStage | Should -Match 'MirrorDir = \$MirrorDir' -Because 'the dot-source trap resets same-named variables, so MirrorDir is saved and restored like DataDisks'
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

    It 'fails fast when wimlib-imagex is missing after the wimlib install' {
        $script:buildYml | Should -Match 'wimlib-imagex not found on PATH after installing wimlib'
    }

    It 'fails fast when 7z is missing after the 7zip install' {
        $script:buildYml | Should -Match '7z not found on PATH after installing 7zip'
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
        $script:buildYml | Should -Match 'Iso\s*=\s*\$iso'
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
        $script:buildYml | Should -Match "Firmware\s*=\s*'uefi'"
        $script:buildYml | Should -Match 'FirmwarePath'
        $script:buildYml | Should -Match 'IN_OVMF:'
    }

    It 'prepares the Task 17 Step 6 data disks for m6/m7 full runs' {
        $script:buildYml | Should -Match 'Prepare data disks'
        $script:buildYml | Should -Match "inputs.verify == 'full'"
        $script:buildYml | Should -Match 'diskpart'
        $script:buildYml | Should -Match 'qemu-img convert'
        $script:buildYml | Should -Match 'install\.mic'
        $script:buildYml | Should -Match 'MICPE 定制系统 v1'
        $script:buildYml | Should -Match 'DATA_DISKS='
    }

    It 'prepares data disks from the base install.wim, not from the ISO' {
        # Packaging round (user decision 2026-11-17 15:09): the ISO no
        # longer carries install.wim, so the data disks must use the
        # build step's INSTALL_WIM_PATH export.
        $script:buildYml | Should -Match 'INSTALL_WIM_PATH'
        $script:buildYml | Should -Match "install\.wim not found at"
        $script:buildYml | Should -Not -Match 'failed to extract sources\\install\.wim'
    }

    It 'uploads every finished manual build as a Release' {
        # Long-term rule (user decision 2026-11-17 14:16). Tag scheme
        # micpe-<stage>-<build>-<yyyymmdd>-r<run_number>: never 'v*',
        # because the workflow triggers on v* tag pushes.
        $script:buildYml | Should -Match 'Upload finished build to Release'
        $script:buildYml | Should -Match "github\.event_name == 'workflow_dispatch'"
        $script:buildYml | Should -Match '\$tag = "micpe-'
        $script:buildYml | Should -Match 'gh release create' -Because 'the base inventory step still uploads inline'
        $script:buildYml | Should -Match 'gh release upload' -Because 'the base inventory step still uploads inline'
        # The finished-build gh calls live in Publish-CleanRelease.ps1
        # (run 45448778057: the upload was extracted so core and extra
        # files can be split); build.yml only wires the call.
        $script:buildYml | Should -Match 'Publish-CleanRelease'
        $script:buildYml | Should -Match 'checksums\.sha256'
        $script:buildYml | Should -Match 'install\.wim is NOT included'
    }

    It 'uploads the clean QEMU screenshots to the Release as PNGs (run 45432615549)' {
        # Run 45432615549 captured all 7 screenshots, but the
        # `micpe-clean-verify` artifact upload hit the storage-quota
        # counter and the runner was destroyed with the screenshots on
        # it — no copy survived. The Release is the durable channel:
        # the screenshots are converted to PNG and attached to the same
        # release as the ISO and boot.wim (the artifact upload stays
        # as a backup).
        $script:buildYml | Should -Match 'Export-CleanScreenshots'
        $script:buildYml | Should -Match 'screenshots-png'
        $script:buildYml | Should -Match 'release extras'
        # The combined @releaseFiles upload died in run 45448778057 (one
        # empty log failed the whole release); extras now ride
        # Publish-CleanRelease -ExtraFiles, one by one.
        $script:buildYml | Should -Match 'Publish-CleanRelease'
        $script:buildYml | Should -Match '-ExtraFiles'
        $script:buildYml | Should -Match 'Screenshots go to the Release for this run'
    }

    It 'passes the data disks to the verifier and gives the deploy run two hours' {
        $script:buildYml | Should -Match 'DataDisks'
        $script:buildYml | Should -Match 'TimeoutMin\s*=\s*120'
        $script:testStage | Should -Match 'DataDisks'
    }

    It 'saves and restores DataDisks around the dot-source like the other colliding names' {
        # Invoke-QemuVerify.ps1 declares $DataDisks too, so the bare
        # dot-source would reset Test-Stage's own value to empty (the same
        # trap that killed runs 43884981629 and 43891758991 for $Iso).
        $script:testStage | Should -Match 'DataDisks = \$DataDisks'
        $script:testStage | Should -Match '-DataDisks \$DataDisks'
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

    It 'guards the verify result before reading .ProbeSeen' {
        # Run 44046530462: a leaked monitor reply turned Invoke-QemuVerify's
        # return value into an Object[], and Test-Stage.ps1 read .ProbeSeen
        # off the array under Set-StrictMode, throwing "The property
        # 'ProbeSeen' cannot be found on this object" instead of a clean
        # probe-timeout failure. Anything that is not the result object
        # must take the probe-timeout branch.
        $script:testStage | Should -Match '\$null -eq \$result'
        $script:testStage | Should -Match '\$result -isnot \[pscustomobject\]'
        $script:testStage | Should -Not -Match '(?m)^if \(-not \$result\.ProbeSeen\)'
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
        # One summary block per mode: the normal ISO build and fetch-only.
        # Neither may contain a GITHUB_ENV export: on a runner without
        # GITHUB_STEP_SUMMARY the exports would silently never be written.
        @($summaryIf).Count | Should -Be 2
        foreach ($block in $summaryIf) {
            $block.Extent.Text | Should -Not -Match 'GITHUB_ENV'
        }
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
        $script:buildScript | Should -Match "'Registry', 'Shell', 'Uwp', 'Payload', 'Brand', 'Installer', 'BaseImage'"
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
        $script:buildScript | Should -Match "'Shell', 'Uwp', 'Payload', 'Brand', 'Installer', 'BaseImage'"
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

    It 'reads back the WER LocalDumps key after the registry imports (run 54)' {
        # Runs 50/53: the 60-werdumps.reg SYSTEM import logged success
        # while the running PE still read wer_localdumps_folder=missing
        # — the import only checks reg.exe's exit code and never reads
        # the values back. Assert-WerLocalDumps turns that silent miss
        # into a loud build failure, right after Assert-AppxPolicy.
        $script:buildScript | Should -Match 'Assert-WerLocalDumps'
        $script:buildScript.IndexOf('Assert-WerLocalDumps') | Should -BeGreaterThan $script:buildScript.IndexOf('Invoke-RegistryScript') -Because 'the read-back runs after the imports'
        $script:buildScript.IndexOf('Assert-WerLocalDumps') | Should -BeGreaterThan $script:buildScript.IndexOf('Assert-AppxPolicy') -Because 'it sits next to the Appx read-back'
    }

    It 'mounts and commits boot.wim around the uwp step' {
        $script:buildScript | Should -Match 'Invoke-UwpStep'
    }
}

Describe 'M5 step wiring' {
    BeforeAll {
        $script:buildScript = Get-Content -LiteralPath (Join-Path $repoRoot 'src/build/Build-Micpe.ps1') -Raw
    }

    It 'loads Payload.ps1 and Brand.ps1' {
        $script:buildScript | Should -Match "'Uwp', 'Payload', 'Brand', 'Installer', 'BaseImage'"
    }

    It 'dispatches the payload and brand steps' {
        foreach ($step in 'payload', 'brand') {
            $script:buildScript | Should -Match "'$step'\s*\{" -Because "step $step must be dispatched"
        }
    }

    It 'stages, expands, installs and asserts the payload in the step' {
        $script:buildScript | Should -Match 'Get-AppPackageArchive'
        $script:buildScript | Should -Match 'Expand-Payload'
        $script:buildScript | Should -Match 'Install-Payload'
        $script:buildScript | Should -Match 'Assert-PayloadInstalled'
    }

    It 'brands and asserts the image in the step' {
        $script:buildScript | Should -Match 'Set-Brand'
        $script:buildScript | Should -Match 'Assert-BrandApplied'
    }

    It 'mounts and commits boot.wim around the payload and brand steps' {
        $script:buildScript | Should -Match 'Invoke-PayloadStep'
        $script:buildScript | Should -Match 'Invoke-BrandStep'
    }
}

Describe 'M6 step wiring' {
    BeforeAll {
        $script:buildScript = Get-Content -LiteralPath (Join-Path $repoRoot 'src/build/Build-Micpe.ps1') -Raw
    }

    It 'loads Installer.ps1' {
        $script:buildScript | Should -Match "'Brand', 'Installer', 'BaseImage'"
    }

    It 'dispatches the installer step' {
        $script:buildScript | Should -Match "'installer'\s*\{"
    }

    It 'installs and asserts the installer in the step' {
        $script:buildScript | Should -Match 'Install-Installer'
        $script:buildScript | Should -Match 'Assert-InstallerInstalled'
    }

    It 'mounts and commits boot.wim around the installer step' {
        $script:buildScript | Should -Match 'Invoke-InstallerStep'
    }
}
