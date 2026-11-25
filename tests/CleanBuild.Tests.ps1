BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Wim.ps1"
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:CleanScript = Join-Path $script:RepoRoot 'src/build/Build-CleanPe.ps1'
    $script:CleanScriptText = Get-Content -LiteralPath $script:CleanScript -Raw
    $script:RegDir = Join-Path $script:RepoRoot 'src/build/reg'
    $script:DataDir = Join-Path $script:RepoRoot 'src/build/data'
    $script:TempRoot = [System.IO.Path]::GetTempPath()
    $script:fakeWimlib = Join-Path $PSScriptRoot 'Fake-Wimlib.ps1'
}

Describe 'Build-CleanPe.ps1 parameters' {
    It 'defaults to the 22621.1105 Professional rebuild (reference PE is Enterprise)' {
        $script:CleanScriptText | Should -Match '\[string\] \$Build = ''22621\.1105'''
        $script:CleanScriptText | Should -Match '\[string\] \$Edition = ''professional'''
    }

    It 'takes the file list, in-repo shell.zip and pinned shell SHA256 as parameters' {
        $script:CleanScriptText | Should -Match '\[string\] \$FileList'
        $script:CleanScriptText | Should -Match 'src/build/data/shell\.zip'
        $script:CleanScriptText | Should -Match '8f94801470e20b94129d0b7e294d1c6b413b060dcf6b70f8e9409cee3a94b0bd'
        # No Release download: the repo is private, shell.zip lives in git.
        $script:CleanScriptText | Should -Not -Match 'ShellReleaseTag'
        $script:CleanScriptText | Should -Not -Match 'releases/download'
    }

    It 'ships shell.zip in-repo with the pinned SHA256' {
        $zip = Join-Path $script:DataDir 'shell.zip'
        Test-Path -LiteralPath $zip | Should -Be $true
        (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash | Should -Be '8F94801470E20B94129D0B7E294D1C6B413B060DCF6B70F8E9409CEE3A94B0BD'
    }

    It 'treats the file list as final (no placeholder, no 15:15 diff)' {
        $script:CleanScriptText | Should -Not -Match 'PLACEHOLDER'
        $script:CleanScriptText | Should -Not -Match '15:15'
        $script:CleanScriptText | Should -Match 'no hash diff'
        $script:CleanScriptText | Should -Match 'source of truth'
    }

    It 'pins the same aria2 hash as Build-Micpe.ps1 and BaseImage.ps1' {
        $lib = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src/build/lib/BaseImage.ps1') -Raw
        $match = [regex]::Match($lib, "Aria2ExpectedHash = '([0-9a-f]{64})'")
        $match.Success | Should -Be $true
        $script:CleanScriptText | Should -Match $match.Groups[1].Value
        $script:CleanScriptText | Should -Match 'uupdump\.net/misc/aria2c\.exe'
        $script:CleanScriptText | Should -Match 'hash mismatch'
    }

    It 'dot-sources the libs it needs (and only those)' {
        foreach ($lib in 'Common', 'Disk', 'Wim', 'Registry', 'AdminAccount', 'BaseImage', 'Iso') {
            $script:CleanScriptText | Should -Match "'$lib'"
        }
        # The clean build assembles from install.wim; it does not patch a
        # boot.wim with the m* stage installers.
        $script:CleanScriptText | Should -Not -Match 'Install-ExplorerShell'
        $script:CleanScriptText | Should -Not -Match 'Install-UwpApps'
    }
}

Describe 'Build-CleanPe.ps1 pipeline' {
    It 'extracts only the file-list paths from the official install.wim' {
        $script:CleanScriptText | Should -Match 'Get-WimImageIndexByEdition'
        $script:CleanScriptText | Should -Match 'Export-WimFiles'
        $script:CleanScriptText | Should -Match 'Read-Whitelist'
    }

    It 'clears the read-only attributes the WIM extraction leaves, before any step writes into the tree' {
        # run 45359151127: the shell step's StartAllBack.xml copy into the
        # WIM-extracted icsxml directory was denied (the directory carries
        # the install.wim's read-only attribute), while the copy into the
        # script-created MICPE directory succeeded. The extract step must
        # make the staging tree writable right after extraction, or the
        # shell and registry steps hit the same wall.
        $script:CleanScriptText | Should -Match 'Clear-StagingReadOnly'
        $extractPos = $script:CleanScriptText.IndexOf('Export-WimFiles')
        $clearPos = $script:CleanScriptText.IndexOf('Clear-StagingReadOnly')
        $clearPos | Should -BeGreaterThan $extractPos
    }

    It 'prints the raw write state after extraction, grants write access, and diagnoses before the icsxml copy' {
        # run 45368774235: the attrib fix ran without error and the
        # icsxml copy was still denied -- a directory's read-only flag
        # does not block creating files inside it, so the blocker is
        # the ACL (TrustedInstaller ownership). The pipeline must (a)
        # print the raw state right after extraction, (b) grant write
        # access to every place the build writes into, and (c) print
        # the icsxml state right before the copy that was denied, so
        # the next run's log shows whether the grant actually took
        # instead of assuming it did.
        $script:CleanScriptText | Should -Match 'Show-StagingWriteState'
        $script:CleanScriptText | Should -Match 'Grant-StagingWriteAccess'
        $extractPos = $script:CleanScriptText.IndexOf('Export-WimFiles')
        $rawStatePos = $script:CleanScriptText.IndexOf("Show-StagingWriteState -Path `$paths.Staging")
        $rawStatePos | Should -BeGreaterThan $extractPos
        $grantPos = $script:CleanScriptText.IndexOf('Grant-StagingWriteAccess')
        $grantPos | Should -BeGreaterThan $extractPos
        $copyPos = $script:CleanScriptText.IndexOf("Copy-Item -LiteralPath (Join-Path `$repoRoot 'src\build\data\StartAllBack.xml')")
        $diagPos = $script:CleanScriptText.IndexOf("Show-StagingWriteState -Path `$icsxmlDir")
        $diagPos | Should -BeGreaterThan 0
        $diagPos | Should -BeLessThan $copyPos
    }

    It 'asserts the critical staged files (boot loader, shell, hives)' {
        foreach ($critical in 'winload\.exe', 'explorer\.exe', 'config\\SYSTEM', 'config\\SOFTWARE', 'config\\DEFAULT', 'config\\SAM', 'config\\SECURITY') {
            $script:CleanScriptText | Should -Match $critical
        }
    }

    It 'lays StartAllBack and Start11 out under Windows\System32\MICPE' {
        $script:CleanScriptText | Should -Match 'Windows\\System32\\MICPE'
        $script:CleanScriptText | Should -Match "Start11\\Links"
        $script:CleanScriptText | Should -Match 'StartAllBackX64\.dll'
        $script:CleanScriptText | Should -Match 'StartAllBackLoaderX64\.dll'
        $script:CleanScriptText | Should -Match 'Start11Config\.exe'
    }

    It 'imports the four clean .reg patches and enables Administrator in the staging SAM' {
        foreach ($reg in '10-clean-boot\.reg', '20-clean-start11\.reg', '30-clean-author\.reg', '40-clean-startallback\.reg') {
            $script:CleanScriptText | Should -Match $reg
        }
        $script:CleanScriptText | Should -Match 'Invoke-RegistryScript'
        $script:CleanScriptText | Should -Match 'Set-OfflineAdminState'
        $script:CleanScriptText | Should -Match 'Assert-CleanRegistry'
    }

    It 'does not fail the build on an empty staging SAM (install.wim ships one by design)' {
        # Run 45390017855: the official install.wim SAM is an EMPTY hive
        # (8 KB, no subkeys, no Administrator record) -- verified against
        # the exact UUP source (professional_zh-cn.esd image 3). The SAM
        # service creates the built-in accounts at boot, so the offline
        # enable step is skipped, not fatal.
        $script:CleanScriptText | Should -Match 'Set-OfflineAdminState'
        $script:CleanScriptText | Should -Not -Match 'the file-list extract lost it'
        $script:CleanScriptText | Should -Match 'empty hive'
        $script:CleanScriptText | Should -Match 'SAM service creates the built-in accounts at boot'
    }

    It 'relaxes the registry read-back to warnings (early debugging: a failed check must not block QEMU)' {
        # User decision 2026-11-24 23:18 (reply to the round 5 failure
        # report): the clean rebuild is in early debugging, so a
        # read-back mismatch is logged loudly and the build continues to
        # the ISO and the QEMU screenshot verification. Only the
        # read-back section is relaxed; the extract / copy / registry
        # import / SAM steps keep their hard Assert-True failures.
        $readBack = ($script:CleanScriptText -split 'function Assert-CleanRegistry')[1] -split 'function Invoke-CleanCaptureStep' | Select-Object -First 1
        $readBack | Should -Match 'Assert-ReadBack'
        $readBack | Should -Not -Match 'Assert-True'
        $readBack | Should -Match 'readBackFailures'
        # The helper (defined just above Assert-CleanRegistry) logs the
        # failure loudly and keeps going instead of throwing.
        $script:CleanScriptText | Should -Match 'read-back FAILED \(warning only, build continues\)'
        $script:CleanScriptText | Should -Match 'Assert-ReadBack'
        # The hard failures outside the read-back section are untouched.
        $script:CleanScriptText | Should -Match 'Assert-True -Condition \(\$bootIndex -eq 1\)'
    }

    It 'reads back cdrom and exfat Start=0 after the registry import (round 10)' {
        # The read-back section must verify the boot-driver fix landed:
        # cdrom and exfat at Start=0 (BOOT_START) like the reference PE.
        $readBack = ($script:CleanScriptText -split 'function Assert-CleanRegistry')[1] -split 'function Invoke-CleanCaptureStep' | Select-Object -First 1
        $readBack | Should -Match "ControlSet001\\Services\\cdrom"
        $readBack | Should -Match "cdrom\['Start'\] -eq '0x0'"
        $readBack | Should -Match "ControlSet001\\Services\\exfat"
        $readBack | Should -Match "exfat\['Start'\] -eq '0x0'"
    }

    It 'reads back the 9 missing boot drivers as disabled (Start=4, round 11)' {
        # Round 11 still died in winload on cdrom.sys 0xc0000428 even
        # with cdrom/exfat at Start=0. The r85 boot.wim SYSTEM hive
        # lists 9 Start=0 drivers whose .sys files are not in the
        # image (WdBoot, WdFilter, MsSecFlt, SgrmAgent, IntelPMT,
        # intelpep, cnghwassist, iorate, rdyboost); the Ramos reference
        # PE has none of these services. The read-back must verify all
        # 9 are disabled (Start=4) after the registry import.
        $readBack = ($script:CleanScriptText -split 'function Assert-CleanRegistry')[1] -split 'function Invoke-CleanCaptureStep' | Select-Object -First 1
        foreach ($name in 'WdBoot', 'WdFilter', 'MsSecFlt', 'SgrmAgent', 'IntelPMT', 'intelpep', 'cnghwassist', 'iorate', 'rdyboost') {
            $readBack | Should -Match ([regex]::Escape($name))
        }
        $readBack | Should -Match "\['Start'\] -eq '0x4'"
    }

    It 'captures the staging tree into a fresh boot.wim and packages a boot.wim-only ISO' {
        $script:CleanScriptText | Should -Match 'New-WimCapture'
        $script:CleanScriptText | Should -Match 'Set-WimBootIndex'
        $script:CleanScriptText | Should -Match 'Remove-InstallWimFromMedia'
        $script:CleanScriptText | Should -Match 'New-MicpeIso'
        $script:CleanScriptText | Should -Match 'Assert-BootWimSize'
    }

    It 'exports the ISO / boot.wim paths for the workflow upload and Release steps' {
        $script:CleanScriptText | Should -Match 'ISO_PATH='
        $script:CleanScriptText | Should -Match 'BOOT_WIM_PATH='
        $script:CleanScriptText | Should -Match 'INSTALL_WIM_PATH='
    }
}

Describe 'Set-CleanBcdNoIntegrityChecks (BCD experiment, temporary branch only)' {
    BeforeAll {
        $script:fakeBcdedit = Join-Path $PSScriptRoot 'Fake-Bcdedit.ps1'
        # Pull the function definition out of Build-CleanPe.ps1 via the AST
        # (the script cannot be dot-sourced: its dispatch section runs on load).
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:CleanScript, [ref] $tokens, [ref] $errors)
        $errors.Count | Should -Be 0
        $fn = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Set-CleanBcdNoIntegrityChecks'
            }, $true)
        @($fn).Count | Should -Be 1
        . ([scriptblock]::Create($fn[0].Extent.Text))
    }

    It 'exists and uses bcdedit /store /set {default} nointegritychecks on, then verifies with /enum' {
        $script:CleanScriptText | Should -Match 'function Set-CleanBcdNoIntegrityChecks'
        $script:CleanScriptText | Should -Match "bcdedit.* /store .* /set '\{default\}' nointegritychecks on"
        $script:CleanScriptText | Should -Match "bcdedit.* /store .* /enum '\{default\}'"
        $script:CleanScriptText | Should -Match 'nointegritychecks'
    }

    It 'is called by the ISO step before oscdimg packages the media tree' {
        $isoStep = ($script:CleanScriptText -split 'function Invoke-CleanIsoStep')[1] -split '# ---' | Select-Object -First 1
        $isoStep | Should -Match 'Set-CleanBcdNoIntegrityChecks'
        $isoStep.IndexOf('Set-CleanBcdNoIntegrityChecks') | Should -BeLessThan $isoStep.IndexOf('New-MicpeIso')
    }

    It 'sets nointegritychecks on both BCD stores and verifies each one' {
        $media = Join-Path $script:TempRoot ("micpe-bcd-media-{0}" -f [guid]::NewGuid())
        $efiDir = Join-Path $media 'efi\microsoft\boot'
        $biosDir = Join-Path $media 'boot'
        New-Item -ItemType Directory -Path $efiDir -Force | Out-Null
        New-Item -ItemType Directory -Path $biosDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $efiDir 'bcd') -Value 'FAKE-BCD' -NoNewline
        Set-Content -LiteralPath (Join-Path $biosDir 'bcd') -Value 'FAKE-BCD' -NoNewline
        $log = Join-Path $script:TempRoot ("micpe-bcd-log-{0}.txt" -f [guid]::NewGuid())
        try {
            $env:MICPE_FAKE_BCDEDIT_LOG = $log
            { Set-CleanBcdNoIntegrityChecks -MediaDir $media -BcdeditPath $script:fakeBcdedit } | Should -Not -Throw
            $calls = Get-Content -LiteralPath $log
            # Two /set calls (one per store) and two /enum calls.
            @($calls | Where-Object { $_ -eq '/set' }).Count | Should -Be 2
            @($calls | Where-Object { $_ -eq '/enum' }).Count | Should -Be 2
            @($calls | Where-Object { $_ -eq 'nointegritychecks' }).Count | Should -Be 2
            $efiBcd = Join-Path $media 'efi\microsoft\boot\bcd'
            $biosBcd = Join-Path $media 'boot\bcd'
            $calls | Should -Contain $efiBcd
            $calls | Should -Contain $biosBcd
        }
        finally {
            Remove-Item -LiteralPath $env:MICPE_FAKE_BCDEDIT_LOG -ErrorAction SilentlyContinue
            $env:MICPE_FAKE_BCDEDIT_LOG = $null
            Remove-Item -LiteralPath $media -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws when neither BCD store exists in the media tree' {
        $media = Join-Path $script:TempRoot ("micpe-bcd-empty-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $media -Force | Out-Null
        try {
            { Set-CleanBcdNoIntegrityChecks -MediaDir $media -BcdeditPath $script:fakeBcdedit } | Should -Throw '*no BCD store*'
        }
        finally {
            Remove-Item -LiteralPath $media -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws loudly when bcdedit /set fails (the experiment must not silently proceed)' {
        $media = Join-Path $script:TempRoot ("micpe-bcd-fail-{0}" -f [guid]::NewGuid())
        $efiDir = Join-Path $media 'efi\microsoft\boot'
        New-Item -ItemType Directory -Path $efiDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $efiDir 'bcd') -Value 'FAKE-BCD' -NoNewline
        try {
            $env:MICPE_FAKE_BCDEDIT_FAIL_SET = '1'
            { Set-CleanBcdNoIntegrityChecks -MediaDir $media -BcdeditPath $script:fakeBcdedit } | Should -Throw '*bcdedit /set nointegritychecks failed*'
        }
        finally {
            $env:MICPE_FAKE_BCDEDIT_FAIL_SET = $null
            Remove-Item -LiteralPath $media -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws loudly when /enum does not confirm nointegritychecks (a /set that did not stick)' {
        $media = Join-Path $script:TempRoot ("micpe-bcd-enum-{0}" -f [guid]::NewGuid())
        $efiDir = Join-Path $media 'efi\microsoft\boot'
        New-Item -ItemType Directory -Path $efiDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $efiDir 'bcd') -Value 'FAKE-BCD' -NoNewline
        try {
            $env:MICPE_FAKE_BCDEDIT_ENUM_NO = '1'
            { Set-CleanBcdNoIntegrityChecks -MediaDir $media -BcdeditPath $script:fakeBcdedit } | Should -Throw '*nointegritychecks not confirmed*'
        }
        finally {
            $env:MICPE_FAKE_BCDEDIT_ENUM_NO = $null
            Remove-Item -LiteralPath $media -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'New-WimCapture' {
    It 'captures with LZX compression, --boot and an integrity table' {
        $src = Join-Path $script:TempRoot ("micpe-cap-src-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'a.txt') -Value 'x' -NoNewline
        $dest = Join-Path $script:TempRoot ("micpe-cap-{0}.wim" -f [guid]::NewGuid())
        $log = Join-Path $script:TempRoot ("micpe-cap-log-{0}.txt" -f [guid]::NewGuid())
        $env:MICPE_FAKE_WIMLIB_LOG = $log
        try {
            $out = New-WimCapture -SourceDir $src -WimPath $dest -Name 'MICPE' -WimlibPath $script:fakeWimlib
            $out | Should -Be $dest
            Test-Path -LiteralPath $dest | Should -Be $true
            $logged = Get-Content -LiteralPath $log -Raw
            $logged | Should -Match 'capture'
            $logged | Should -Match 'MICPE'
            $logged | Should -Match '--compress=LZX'
            $logged | Should -Match '--boot'
            $logged | Should -Match '--check'
        }
        finally {
            Remove-Item Env:MICPE_FAKE_WIMLIB_LOG -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $src -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws when the source directory is missing' {
        { New-WimCapture -SourceDir (Join-Path $script:TempRoot 'micpe-absent-src') -WimPath (Join-Path $script:TempRoot 'x.wim') -WimlibPath $script:fakeWimlib } |
            Should -Throw '*not found*'
    }
}

Describe 'clean .reg patches' {
    BeforeAll {
        $script:RegTexts = @{}
        foreach ($name in '10-clean-boot.reg', '20-clean-start11.reg', '30-clean-author.reg', '40-clean-startallback.reg') {
            $path = Join-Path $script:RegDir $name
            $bytes = [System.IO.File]::ReadAllBytes($path)
            # UTF-16LE BOM
            $bytes[0] | Should -Be 0xFF
            $bytes[1] | Should -Be 0xFE
            $script:RegTexts[$name] = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
        }
    }

    It 'all four patches exist and start with the registry editor header' {
        foreach ($name in $script:RegTexts.Keys) {
            $script:RegTexts[$name] | Should -Match '^Windows Registry Editor Version 5\.00'
        }
    }

    It '10-clean-boot.reg carries the LogonUI boot chain and X:\Windows SystemRoot' {
        $text = $script:RegTexts['10-clean-boot.reg']
        $text | Should -Match 'PE-SYS\\Setup'
        $text | Should -Match '"SetupType"=dword:00000002'
        $text | Should -Match '"CmdLine"="LogonUI"'
        $text | Should -Match '"SystemSetupInProgress"=dword:00000000'
        $text | Should -Match '"Shell"="explorer\.exe"'
        $text | Should -Match '"AutoRestartShell"=dword:00000001'
        $text | Should -Match '"SystemRoot"="X:\\\\Windows"'
    }

    It '10-clean-boot.reg sets cdrom and exfat to boot-start (Start=0, round 10)' {
        # Round 10 died in winload on cdrom.sys 0xc0000428. The full
        # service Start comparison (r84 SYSTEM hive vs the Ramos
        # reference PE) shows exactly two kernel boot-driver
        # differences: cdrom (r84 Start=1, reference Start=0) and exfat
        # (r84 Start=3, reference Start=0). Align both with the
        # reference so winload loads them as boot drivers.
        $text = $script:RegTexts['10-clean-boot.reg']
        $text | Should -Match 'PE-SYS\\ControlSet001\\Services\\cdrom'
        $text | Should -Match 'PE-SYS\\ControlSet001\\Services\\exfat'
        # Both keys carry Start=0; assert the value sits under each key.
        $cdrom = ($text -split 'ControlSet001\\Services\\cdrom')[1]
        $cdrom | Should -Match '"Start"=dword:00000000'
        $exfat = ($text -split 'ControlSet001\\Services\\exfat')[1]
        $exfat | Should -Match '"Start"=dword:00000000'
    }

    It '10-clean-boot.reg does not add .cat files (round 10: the .cat theory is disproven)' {
        # cdrom.sys and every boot driver it depends on carry embedded
        # signatures, and no .cat in the reference PE contains their
        # hashes -- so a missing .cat cannot be the 0xc0000428 cause.
        # Guard against "fixing" it by padding the whitelist with .cat
        # files; the fix is the boot-driver Start values above. Only
        # non-comment lines count: the header comment explains why no
        # .cat is added, so it mentions the word.
        $text = $script:RegTexts['10-clean-boot.reg']
        $valueLines = ($text -split "`r`n|`n") | Where-Object { $_ -and -not $_.TrimStart().StartsWith(';') }
        ($valueLines -join "`n") | Should -Not -Match 'CatRoot'
        ($valueLines -join "`n") | Should -Not -Match '\.cat'
    }

    It '10-clean-boot.reg disables the 9 boot drivers whose files are missing (round 11)' {
        # Round 11 still died in winload on cdrom.sys 0xc0000428 with
        # cdrom/exfat already at Start=0. The r85 boot.wim SYSTEM hive
        # lists 9 Start=0 drivers whose .sys files are not in the
        # image at all (verified against the captured boot.wim file
        # list); the Ramos reference PE has none of these 9 services.
        # Two are ErrorControl=3 (critical): iorate and rdyboost.
        # WdBoot is the Early-Launch (ELAM) driver; its file and the
        # ELAMBKUP backup dir are both missing. All 9 must be disabled
        # (Start=4) so winload never tries to load a boot driver that
        # is not in the image. WindowsTrustedRTProxy is deliberately
        # NOT disabled: the reference PE also lists it at Start=0 with
        # its file missing, and it boots -- winload tolerates it.
        $text = $script:RegTexts['10-clean-boot.reg']
        foreach ($name in 'WdBoot', 'WdFilter', 'MsSecFlt', 'SgrmAgent', 'IntelPMT', 'intelpep', 'cnghwassist', 'iorate', 'rdyboost') {
            $text | Should -Match "PE-SYS\\ControlSet001\\Services\\$name"
            $section = ($text -split "ControlSet001\\Services\\$name")[1]
            $section | Should -Match '"Start"=dword:00000004'
        }
        $text | Should -Not -Match 'ControlSet001\\Services\\WindowsTrustedRTProxy'
    }

    It '20-clean-start11.reg carries Start11 settings but no pinned-item groups' {
        $text = $script:RegTexts['20-clean-start11.reg']
        $text | Should -Match 'PE-DEF\\Software\\Stardock\\Start8\\Start8\.ini'
        $text | Should -Match 'System32\\\\MICPE\\\\Start11'
        $text | Should -Not -Match 'Start8\.ini\\Groups'
        $text | Should -Not -Match 'Start8\.ini\\GroupContents'
    }

    It '30-clean-author.reg brands the image SYSTEM-Intel-MIC (incl. OEMInformation) and drops the Ramos motto' {
        $text = $script:RegTexts['30-clean-author.reg']
        $text | Should -Match '"RegisteredOwner"="SYSTEM-Intel-MIC"'
        $text | Should -Match '"RegisteredOrganization"=-'
        # OEMInformation is the second SYSTEM-RAMOS mark in SOFTWARE
        # (full-hive scan found exactly two); same author brand, shown
        # in System Properties. The personal support URL goes with it.
        $text | Should -Match 'CurrentVersion\\OEMInformation'
        $text | Should -Match '"Manufacturer"="SYSTEM-Intel-MIC"'
        $text | Should -Match '"SupportURL"=-'
        # The header comment names the reference value it replaces; the
        # registry VALUES themselves must not carry the Ramos branding.
        $valueLines = ($text -split "`r`n|`n") | Where-Object { $_ -and -not $_.TrimStart().StartsWith(';') }
        ($valueLines -join "`n") | Should -Not -Match 'RAMOS'
    }

    It '40-clean-startallback.reg carries the 9 CLSIDs with MICPE paths and the per-user settings' {
        $text = $script:RegTexts['40-clean-startallback.reg']
        $text | Should -Match 'PE-SOFT\\Classes\\CLSID\\\{117E3954-5034-453A-A18B-7B79493646E6\}'
        $text | Should -Match 'StartAllBackLoaderX64\.dll'
        $text | Should -Match 'System32\\\\MICPE\\\\StartAllBack'
        $text | Should -Not -Match 'Program Files\\\\StartAllBack'
        $text | Should -Match 'PE-SOFT\\Classes\\StartIsBack\.AppsFolder'
        $script:RegTexts['40-clean-startallback.reg'] | Should -Match 'PE-DEF\\Software\\StartIsBack'
        # The dangling LocalizedString (nonexistent StartIsBack64.dll) is dropped.
        $text | Should -Not -Match '"LocalizedString"'
    }
}

Describe 'clean data files' {
    It 'the final file list exists, is the reference list minus the deleted apps, and says so' {
        $list = Join-Path $script:DataDir 'clean-22621.1105-enterprise-files.txt'
        Test-Path -LiteralPath $list | Should -Be $true
        $patterns = Read-Whitelist -Path $list
        $patterns.Count | Should -Be 9405
        $patterns | Should -Not -Contain 'Program Files (x86)\Tencent\QQ\Bin\QQ.exe'
        foreach ($excluded in 'Program Files (x86)\Tencent\', 'Program Files (x86)\360Chrome\', 'Program Files (x86)\Thunder\', 'Program Files\Office2010\', 'Program Files\PhotoshopCS3\', 'Program Files\7-Zip\', 'Program Files\PENetwork\', 'Program Files\StartAllBack\', 'Program Files (x86)\Stardock\') {
            @($patterns | Where-Object { $_.StartsWith($excluded, [System.StringComparison]::OrdinalIgnoreCase) }).Count | Should -Be 0 -Because "$excluded must be excluded"
        }
        $header = (Get-Content -LiteralPath $list -TotalCount 12) -join "`n"
        $header | Should -Match 'No hash diff'
        $header | Should -Match 'source of truth'
        $header | Should -Not -Match 'PLACEHOLDER'
        $header | Should -Not -Match '15:15'
    }

    It 'the rewritten StartAllBack.xml points at MICPE, not Program Files' {
        $xml = Get-Content -LiteralPath (Join-Path $script:DataDir 'StartAllBack.xml') -Raw
        $xml | Should -Match 'System32\\MICPE\\StartAllBack\\StartAllBackCfg\.exe'
        $xml | Should -Match 'System32\\MICPE\\Start11\\Start11Config\.exe'
        $xml | Should -Not -Match '%ProgramFiles%'
    }

    It 'unattend.xml is the reference windowsPE pass (WINXPE, no network, no firewall)' {
        $xml = Get-Content -LiteralPath (Join-Path $script:DataDir 'unattend.xml') -Raw
        $xml | Should -Match '<ComputerName>WINXPE</ComputerName>'
        $xml | Should -Match '<EnableNetwork>false</EnableNetwork>'
        $xml | Should -Match '<EnableFirewall>false</EnableFirewall>'
        $xml | Should -Match 'pass="windowsPE"'
    }
}

Describe 'clean app auto-discovery' {
    BeforeAll {
        $script:AppRoot = Join-Path $script:RepoRoot 'app'
        $script:AppRegTexts = @{}
        foreach ($pair in @(
                @{ App = 'office'; File = 'office.reg' },
                @{ App = 'chrome'; File = 'chrome.reg' }
            )) {
            $path = Join-Path (Join-Path $script:AppRoot $pair.App) $pair.File
            $bytes = [System.IO.File]::ReadAllBytes($path)
            # UTF-16LE BOM
            $bytes[0] | Should -Be 0xFF
            $bytes[1] | Should -Be 0xFE
            $script:AppRegTexts["$($pair.App)/$($pair.File)"] =
                [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
        }
    }

    It 'dot-sources Payload.ps1 (join + verify + install.bat reuse)' {
        $script:CleanScriptText | Should -Match "'Payload'"
    }

    It 'discovers app directories instead of hardcoding software names' {
        $script:CleanScriptText | Should -Match 'Get-CleanAppDirs'
        $script:CleanScriptText | Should -Match 'Invoke-CleanAppStep'
        # The discovery scans app/ for install.bat + top-level .reg and
        # skips '_' directories; no literal office/chrome list.
        $script:CleanScriptText | Should -Match "install\.bat"
        $script:CleanScriptText | Should -Match "'\*\.reg'"
        $script:CleanScriptText | Should -Match "-notlike '_\*'"
        $script:CleanScriptText | Should -Not -Match "@\('office',\s*'chrome'\)"
        $script:CleanScriptText | Should -Not -Match "@\('chrome',\s*'office'\)"
    }

    It 'runs the app step between shell and registry, and imports app .reg with the clean patches' {
        $script:CleanScriptText | Should -Match 'Invoke-CleanAppStep'
        $script:CleanScriptText | Should -Match 'Invoke-CleanRegistryStep -AppRegFiles'
        $script:CleanScriptText | Should -Match 'Assert-CleanRegistry -AppNames'
        # Dispatch order: shell, then app, then registry.
        $shellAt = $script:CleanScriptText.IndexOf('Invoke-CleanShellStep')
        $appAt = $script:CleanScriptText.IndexOf('$apps = Invoke-CleanAppStep')
        $regAt = $script:CleanScriptText.IndexOf('Invoke-CleanRegistryStep -AppRegFiles')
        $shellAt | Should -BeGreaterThan 0
        $appAt | Should -BeGreaterThan $shellAt
        $regAt | Should -BeGreaterThan $appAt
        # The app step reuses the payload join + verify + install.bat.
        $script:CleanScriptText | Should -Match 'Get-AppPackageArchive'
        $script:CleanScriptText | Should -Match 'Invoke-ComponentInstall'
    }

    It 'discovers office and chrome (and only them) from the app/ tree' {
        # Mirror the script's discovery filter against the real tree:
        # install.bat + at least one top-level .reg, name not starting
        # with '_'. _template has no .reg, payload has no install.bat,
        # start11/startallback are shell-step apps (no top-level .reg).
        $found = @(Get-ChildItem -LiteralPath $script:AppRoot -Directory |
            Where-Object { $_.Name -notlike '_*' } |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'install.bat') } |
            Where-Object { @(Get-ChildItem -LiteralPath $_.FullName -Filter '*.reg' -File).Count -gt 0 } |
            Sort-Object Name | ForEach-Object { $_.Name })
        $found | Should -Be @('chrome', 'office')
    }

    It 'both app .reg files exist and start with the registry editor header' {
        foreach ($key in $script:AppRegTexts.Keys) {
            $script:AppRegTexts[$key] | Should -Match '^Windows Registry Editor Version 5\.00'
        }
    }

    It 'both app .reg files address only the mounted SOFTWARE hive (PE-SOFT)' {
        foreach ($key in $script:AppRegTexts.Keys) {
            $text = $script:AppRegTexts[$key]
            # Section headers end with ]\r\n, so $ does not anchor after ];
            # match the bracketed path without a trailing anchor.
            $sections = @([regex]::Matches($text, '(?m)^\[([^\]]+)\]') | ForEach-Object { $_.Groups[1].Value })
            $sections.Count | Should -BeGreaterThan 0
            foreach ($section in $sections) {
                $section | Should -Match '^HKEY_LOCAL_MACHINE\\PE-SOFT\\'
            }
        }
    }

    It 'office.reg carries App Paths, the six file associations and InstallRoot' {
        $text = $script:AppRegTexts['office/office.reg']
        foreach ($exe in 'WINWORD\.EXE', 'EXCEL\.EXE', 'POWERPNT\.EXE') {
            $text | Should -Match "App Paths\\$exe"
        }
        # Values carry doubled backslashes in .reg syntax, so the regex
        # needs \\\\ to match them.
        $text | Should -Match 'Office2016\\\\Office16\\\\WINWORD\.EXE'
        foreach ($ext in '\.doc\]', '\.docx\]', '\.xls\]', '\.xlsx\]', '\.ppt\]', '\.pptx\]') {
            $text | Should -Match "Classes\\$ext"
        }
        $text | Should -Match 'Word\.Document\.12'
        $text | Should -Match 'Excel\.Sheet\.12'
        $text | Should -Match 'PowerPoint\.Show\.12'
        $text | Should -Match 'Microsoft\\Office\\16\.0\\Common\\InstallRoot'
        # The header comment names what was excluded (Ramos / Office 2010);
        # the registry VALUES themselves must not carry it.
        $valueText = (($text -split "`r`n|`n") | Where-Object { $_ -and -not $_.TrimStart().StartsWith(';') }) -join "`n"
        $valueText | Should -Not -Match 'Office14'
        $valueText | Should -Not -Match 'Office2010'
        $valueText | Should -Not -Match 'RAMOS'
    }

    It 'chrome.reg carries App Paths, ChromeHTML, protocols and StartMenuInternet' {
        $text = $script:AppRegTexts['chrome/chrome.reg']
        $text | Should -Match 'App Paths\\chrome\.exe'
        # Values carry doubled backslashes in .reg syntax.
        $text | Should -Match 'Google\\\\Chrome\\\\Application\\\\chrome\.exe'
        $text | Should -Match 'Classes\\ChromeHTML'
        foreach ($ext in '\.html\]', '\.htm\]') {
            $text | Should -Match "Classes\\$ext"
        }
        $text | Should -Match 'Classes\\http\\shell\\open\\command'
        $text | Should -Match 'Classes\\https\\shell\\open\\command'
        $text | Should -Match 'Clients\\StartMenuInternet\\Google Chrome'
        $text | Should -Match 'RegisteredApplications'
        $text | Should -Match '"Google Chrome"="Software\\\\Clients\\\\StartMenuInternet\\\\Google Chrome\\\\Capabilities"'
        # The header comment names what was excluded (Ramos / 360Chrome);
        # the registry VALUES themselves must not carry it.
        $valueText = (($text -split "`r`n|`n") | Where-Object { $_ -and -not $_.TrimStart().StartsWith(';') }) -join "`n"
        $valueText | Should -Not -Match '360Chrome'
        $valueText | Should -Not -Match 'RAMOS'
    }

    It 'both app .reg files parse through the repo registry parser' {
        . "$PSScriptRoot/../src/build/lib/Common.ps1"
        . "$PSScriptRoot/../src/build/lib/Registry.ps1"
        foreach ($pair in @(
                @{ App = 'office'; File = 'office.reg' },
                @{ App = 'chrome'; File = 'chrome.reg' }
            )) {
            $path = Join-Path (Join-Path $script:AppRoot $pair.App) $pair.File
            $entries = Get-RegFileDeclaredEntries -RegFile $path
            $entries.Count | Should -BeGreaterThan 0
        }
    }
}

Describe 'build.yml clean wiring' {
    BeforeAll {
        $script:Workflow = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/build.yml') -Raw
        $script:CleanVerify = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src/ci/Invoke-CleanQemuVerify.ps1') -Raw
    }

    It 'accepts a clean boolean input' {
        $script:Workflow | Should -Match "(?m)^\s{6}clean:"
        $script:Workflow | Should -Match "(?s)clean:\s*\n\s*description:.*\n\s*type: boolean\s*\n\s*default: false"
    }

    It 'runs Build-CleanPe.ps1 for clean builds and Build-Micpe.ps1 otherwise' {
        $script:Workflow | Should -Match 'IN_CLEAN:'
        $script:Workflow | Should -Match "Build-CleanPe\.ps1 -Build '22621\.1105' -Edition 'professional'"
        $script:Workflow | Should -Match 'Build-Micpe\.ps1 @buildArgs'
    }

    It 'runs the screenshot verifier (not the probe verifier) for clean builds' {
        $script:Workflow | Should -Match 'Invoke-CleanQemuVerify\.ps1'
        $script:Workflow | Should -Match "inputs\.verify == 'full' && inputs\.clean == true"
        $script:Workflow | Should -Match 'micpe-clean-verify'
    }

    It 'tags clean Releases as micpe-clean-22621.1105' {
        $script:Workflow | Should -Match "MICPE_CLEAN"
        $script:Workflow | Should -Match '\$stage = ''clean''; \$build = ''22621\.1105'''
    }

    It 'the clean verifier logs in at LogonUI and opens the Start menu by keypress' {
        # The monitor command is built as "sendkey $Key"; the keys sent are
        # ret (Enter at LogonUI), meta_l (Windows key, Start menu) and esc.
        $script:CleanVerify | Should -Match 'sendkey \$Key'
        $script:CleanVerify | Should -Match "-Key 'ret'"
        $script:CleanVerify | Should -Match "-Key 'meta_l'"
        $script:CleanVerify | Should -Match "-Key 'esc'"
        $script:CleanVerify | Should -Match 'screendump'
        $script:CleanVerify | Should -Match 'shot-'
    }
}
