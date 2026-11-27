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

    It 'grants write access to the staging CatRoot before any .cat injection (round 38)' {
        # Round 37 died at Build-CleanPe.ps1:840: the first cdrom.sys
        # .cat copy into staging CatRoot\{F750E6C3-...} was denied --
        # the serviced 22621.1105 image (DISM integration) leaves
        # CatRoot with a tighter ACL than the RTM source, and CatRoot
        # was never in the base step's write-access list. The grant
        # must cover the whole CatRoot (both .cat steps -- cdrom
        # round 13 and GdiPlus round 36 -- write into the same GUID
        # directory), and it must run before either of them.
        $listStart = $script:CleanScriptText.IndexOf('foreach ($writeTarget')
        $listStart | Should -BeGreaterThan 0
        $catRootPos = $script:CleanScriptText.IndexOf('Windows\System32\CatRoot')
        $catRootPos | Should -BeGreaterThan $listStart
        $grantCallPos = $script:CleanScriptText.IndexOf('Grant-StagingWriteAccess -Path')
        $grantCallPos | Should -BeGreaterThan $catRootPos
        # Runtime order (dispatch section): base step grants first,
        # then the cdrom .cat step, then the GdiPlus .cat step.
        $baseCallPos = $script:CleanScriptText.IndexOf('$base = Invoke-CleanBaseStep')
        $catFixCallPos = $script:CleanScriptText.IndexOf('$catFix = Invoke-CleanCatFixStep')
        $gdiPlusCallPos = $script:CleanScriptText.IndexOf('$gdiPlusFix = Invoke-CleanGdiPlusCatFixStep')
        $baseCallPos | Should -BeGreaterThan 0
        $catFixCallPos | Should -BeGreaterThan $baseCallPos
        $gdiPlusCallPos | Should -BeGreaterThan $catFixCallPos
    }

    It 'probes the CatRoot GUID subdir right after the grant, before any .cat injection (round 39)' {
        # Round 38: the CatRoot grant printed cleanly and the first
        # .cat copy was still denied ten seconds later -- takeown was
        # not recursive, icacls failed on the GUID subdir under /C,
        # and nothing checked. The base step must probe the GUID
        # directory with -AssertWritable right after the grants, so a
        # grant that did not take fails the build at the grant instead
        # of at Copy-Item.
        $probePos = $script:CleanScriptText.IndexOf('CatRoot GUID subdir (after grant)')
        $probePos | Should -BeGreaterThan 0
        $probeLine = ($script:CleanScriptText -split "`n" | Where-Object { $_ -match 'CatRoot GUID subdir \(after grant\)' })
        $probeLine | Should -HaveCount 1
        $probeLine | Should -Match 'Show-StagingWriteState'
        $probeLine | Should -Match '\{F750E6C3-38EE-11D1-85E5-00C04FC295EE\}'
        $probeLine | Should -Match '-AssertWritable'
        $grantCallPos = $script:CleanScriptText.IndexOf('Grant-StagingWriteAccess -Path')
        $probePos | Should -BeGreaterThan $grantCallPos
        # Runtime order: base step (grant + probe) runs before either
        # .cat step.
        $catFixCallPos = $script:CleanScriptText.IndexOf('$catFix = Invoke-CleanCatFixStep')
        $probePos | Should -BeLessThan $catFixCallPos
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
        # the exact UUP source (professional_zh-cn.esd image 3). Round 41
        # corrected the old assumption: the SAM service does NOT create
        # the built-in accounts at boot (round 40: 0xc00002e3 SAM
        # initialization failed on the empty hive), so the offline enable
        # step is skipped until the SAM/SECURITY databases are seeded.
        $script:CleanScriptText | Should -Match 'Set-OfflineAdminState'
        $script:CleanScriptText | Should -Not -Match 'the file-list extract lost it'
        $script:CleanScriptText | Should -Match 'empty hive'
        $script:CleanScriptText | Should -Match 'SAM service does NOT create the built-in accounts at boot'
        $script:CleanScriptText | Should -Not -Match 'the SAM service creates the built-in accounts at boot, so the offline enable step is skipped'
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

    It 'reads back FileCrypt and the 7 cleanup services as disabled (Start=4, round 16)' {
        # Round 16 root cause: FileCrypt is Start=1 + ErrorControl=3 in
        # the install.wim SYSTEM hive but its file is not in the image;
        # the kernel bugchecks 0x5A when it cannot load it. FileCrypt
        # joins the round-11 disabled-drivers list; the 7 cleanup
        # services are the same defect class with ErrorControl <= 1.
        # The read-back must verify all 8 are disabled (Start=4) after
        # the registry import.
        $readBack = ($script:CleanScriptText -split 'function Assert-CleanRegistry')[1] -split 'function Invoke-CleanCaptureStep' | Select-Object -First 1
        foreach ($name in 'FileCrypt', 'afunix', 'bam', 'CimFS', 'CSC', 'dam', 'Psched', 'Vid') {
            $readBack | Should -Match ([regex]::Escape($name))
        }
        $readBack | Should -Match "\['Start'\] -eq '0x4'"
    }

    It 'reads back the Volume class LowerFilters as fvevol only (round 16, second suspect)' {
        # Round 11 disabled iorate and rdyboost as services but never
        # cleaned the Volume class filter list, so r91 still listed both
        # in LowerFilters while the reference lists fvevol only. The
        # read-back must verify fvevol is present and neither disabled
        # filter appears; it is deliberately loose about reg.exe's
        # REG_MULTI_SZ rendering (fvevol vs fvevol\0).
        $readBack = ($script:CleanScriptText -split 'function Assert-CleanRegistry')[1] -split 'function Invoke-CleanCaptureStep' | Select-Object -First 1
        $readBack | Should -Match ([regex]::Escape('ControlSet001\Control\Class\{71a27cdd-812a-11d0-bec7-08002be2092f}'))
        $readBack | Should -Match "LowerFilters.*-match 'fvevol'"
        $readBack | Should -Match "LowerFilters.*-notmatch 'iorate'"
        $readBack | Should -Match "LowerFilters.*-notmatch 'rdyboost'"
    }

    It 'reads back the CrashControl dump capture values (round 21)' {
        # Round 21: the 0x5A parameters must come from a crash dump, so
        # the read-back must verify CrashDumpEnabled=1, the dedicated
        # dump file path, the DumpFile path and AutoReboot=0 landed.
        $readBack = ($script:CleanScriptText -split 'function Assert-CleanRegistry')[1] -split 'function Invoke-CleanCaptureStep' | Select-Object -First 1
        $readBack | Should -Match ([regex]::Escape('ControlSet001\Control\CrashControl'))
        $readBack | Should -Match "CrashDumpEnabled.*-eq '0x1'"
        $readBack | Should -Match "DedicatedDumpFile.*-eq 'C:\\dedicateddumpfile\.sys'"
        $readBack | Should -Match "DumpFile.*-eq 'C:\\MEMORY\.DMP'"
        $readBack | Should -Match "AutoReboot.*-eq '0x0'"
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

    It '10-clean-boot.reg lifts the blank-password restriction (round 41)' {
        # Round 41 SAM research: the reference PE has
        # Control\Lsa\LimitBlankPasswordUse = 0; the serviced install.wim
        # source carries 1, and no .reg in the clean rebuild line ever
        # changed it (the old Build-CleanPe.ps1 comment claiming this
        # file already lifted it was wrong -- the file had no LSA key).
        # The built-in Administrator logs on with an empty password, so
        # the restriction must be off or LogonUI refuses the logon even
        # once SAM works. This is the second hurdle after the SAM
        # database, not the 0xc00002e3 fix.
        $text = $script:RegTexts['10-clean-boot.reg']
        $text | Should -Match 'PE-SYS\\ControlSet001\\Control\\Lsa'
        $lsa = ($text -split 'ControlSet001\\Control\\Lsa')[1]
        $lsa | Should -Match '\"LimitBlankPasswordUse\"=dword:00000000'
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

    It '10-clean-boot.reg does not add .cat files (round 13: the catalogs come from the build step, not the registry)' {
        # Round 12 proved the .cat theory after all: cdrom.sys is the only
        # boot driver with NO embedded signature, and its hash lives only
        # in two 22621.900 .cat files. But the fix is NOT a registry patch:
        # the catalogs are fetched from UUP dump and injected into the
        # staging CatRoot by Invoke-CleanCatFixStep (round 13). Guard
        # against "fixing" it by padding the .reg with .cat paths; the
        # .reg only carries the boot-driver Start values above. Only
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

    It '10-clean-boot.reg disables FileCrypt and the 7 non-critical missing drivers (round 16: 0x5A)' {
        # Round 16 root cause: FileCrypt is Start=1 + ErrorControl=3 in
        # the install.wim SYSTEM hive but filecrypt.sys is not in the
        # image at all; the kernel bugchecks CRITICAL_SERVICE_FAILED
        # (0x5A) when it cannot load it. The Ramos reference PE has no
        # FileCrypt service and no service depends on it, so it is
        # disabled like the round-11 drivers. The 7 cleanup services
        # (afunix, bam, CimFS, CSC, dam, Psched, Vid) are the same
        # defect class with ErrorControl <= 1 -- they cannot cause 0x5A,
        # only a failed load -- and the reference has none of them.
        # BasicRender is deliberately NOT disabled: the reference lists
        # it at Start=1 (its DriverStore path just differs). The
        # WindowsTrustedRTProxy exclusion is already asserted above.
        $text = $script:RegTexts['10-clean-boot.reg']
        foreach ($name in 'FileCrypt', 'afunix', 'bam', 'CimFS', 'CSC', 'dam', 'Psched', 'Vid') {
            $text | Should -Match "PE-SYS\\ControlSet001\\Services\\$name"
            $section = ($text -split "ControlSet001\\Services\\$name")[1]
            $section | Should -Match '"Start"=dword:00000004'
        }
        $text | Should -Not -Match 'ControlSet001\\Services\\BasicRender'
    }

    It '10-clean-boot.reg trims the Volume class LowerFilters to fvevol only (round 16, second suspect)' {
        # Round 11 disabled iorate and rdyboost as services but never
        # cleaned the Volume class filter list, so r91 still listed both
        # while the reference lists fvevol only; PnP still tries to load
        # the two missing filter drivers when it builds the volume device
        # stack. The value is REG_MULTI_SZ (hex(7)) with the single entry
        # 'fvevol' -- 66,00,76,00,65,00,76,00,6f,00,6c,00 plus the double
        # null terminator 00,00,00,00.
        $text = $script:RegTexts['10-clean-boot.reg']
        $text | Should -Match 'PE-SYS\\ControlSet001\\Control\\Class\\\{71a27cdd-812a-11d0-bec7-08002be2092f\}'
        $section = ($text -split 'Control\\Class\\\{71a27cdd-812a-11d0-bec7-08002be2092f\}')[1]
        $section | Should -Match '"LowerFilters"=hex\(7\):66,00,76,00,65,00,76,00,6f,00,6c,00,00,00,00,00'
        $section | Should -Not -Match 'iorate'
        $section | Should -Not -Match 'rdyboost'
    }

    It '10-clean-boot.reg enables the crash-dump capture for the 0x5A parameters (round 21)' {
        # Round 21: the 0x5A page has no Parameters section and the blue
        # screen prints only the stop code, so the parameters must come
        # from a crash dump; the offline analysis exhausted every static
        # hypothesis. CrashDumpEnabled=1 (Complete) + DedicatedDumpFile
        # on the QEMU second disk (C:) writes the dump straight to that
        # disk at bugcheck time; AutoReboot=0 parks QEMU on the blue
        # screen. DumpFile is REG_EXPAND_SZ (hex(2)) to match the native
        # type; DedicatedDumpFile is REG_SZ (plain string).
        $text = $script:RegTexts['10-clean-boot.reg']
        $text | Should -Match 'PE-SYS\\ControlSet001\\Control\\CrashControl'
        $section = ($text -split 'Control\\CrashControl')[1]
        $section | Should -Match '"CrashDumpEnabled"=dword:00000001'
        $section | Should -Match '"DedicatedDumpFile"="C:\\\\dedicateddumpfile\.sys"'
        $section | Should -Match '"DumpFile"=hex\(2\):43,00,3a,00,5c,00,4d,00,45,00,4d,00,4f,00,52,00,59,00,2e,00,44,00,4d,00,50,00,00,00'
        $section | Should -Match '"AutoReboot"=dword:00000000'
        $section | Should -Match '"LogEvent"=dword:00000001'
        $section | Should -Match '"Overwrite"=dword:00000001'
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

Describe 'Invoke-CleanCatFixStep (round 13: the two 22621.900 .cat files for cdrom.sys)' {
    BeforeAll {
        $script:fake7z = Join-Path $PSScriptRoot 'Fake-7z.ps1'
        $script:fakeWimlib = Join-Path $PSScriptRoot 'Fake-Wimlib.ps1'
        $script:fakeAttrib = Join-Path $PSScriptRoot 'Fake-Attrib.ps1'
        $script:fakeIcacls = Join-Path $PSScriptRoot 'Fake-Icacls.ps1'
        $script:fixtures = Join-Path $PSScriptRoot 'fixtures'
        . "$PSScriptRoot/../src/build/lib/BaseImage.ps1"
        # Pull the catalog-fix functions out of Build-CleanPe.ps1 via the
        # AST (the script cannot be dot-sourced: its dispatch section runs
        # on load). Same pattern as the BCD experiment tests.
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:CleanScript, [ref] $tokens, [ref] $errors)
        $errors.Count | Should -Be 0
        $allFns = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)
        foreach ($name in @('Find-ByteSequence', 'Test-CleanCatHasAuthenticodeHash', 'Test-CleanCatHasCdromHash', 'Assert-CleanCatFiles', 'Find-CleanCatLcuCab', 'Get-CleanCatFixFileList', 'Invoke-CleanCatFixStep', 'Assert-CleanCatFilesInBootWim')) {
            $fn = @($allFns | Where-Object { $_.Name -eq $name })
            $fn.Count | Should -Be 1
            . ([scriptblock]::Create($fn[0].Extent.Text))
        }
        # Expected table built from the fixture catalogs (their own
        # size/SHA256 -- the production pinned values are asserted
        # statically below, the fixtures stand in for them functionally).
        $script:fixtureCats = @(
            'Microsoft-Windows-Client-Desktop-Required-Package0110~31bf3856ad364e35~amd64~~10.0.22621.900.cat',
            'Microsoft-Windows-Common-Drivers-merged-Package~31bf3856ad364e35~amd64~~10.0.22621.900.cat'
        ) | ForEach-Object {
            $f = Get-Item -LiteralPath (Join-Path $script:fixtures $_)
            [pscustomobject]@{
                Name   = $f.Name
                Size   = $f.Length
                Sha256 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            }
        }
        $script:aria2Text = Get-Content -LiteralPath (Join-Path $script:fixtures 'catfix-aria2.txt') -Raw
    }

    It 'pins the two 22621.900 catalog files (names, sizes, SHA256) in the step defaults' {
        $script:CleanScriptText | Should -Match 'Microsoft-Windows-Client-Desktop-Required-Package0110~31bf3856ad364e35~amd64~~10\.0\.22621\.900\.cat'
        $script:CleanScriptText | Should -Match 'Microsoft-Windows-Common-Drivers-merged-Package~31bf3856ad364e35~amd64~~10\.0\.22621\.900\.cat'
        $script:CleanScriptText | Should -Match 'e09905c4319b6194def5c9b33f53688234ef1fd80cc5a568c486e8843143dd8d'
        $script:CleanScriptText | Should -Match '0a614b442f4c3a85c3f5a4615f748c5b94b2f3f401802e46f7bb2101adc03f62'
        $script:CleanScriptText | Should -Match '205062'
        $script:CleanScriptText | Should -Match '137452'
    }

    It 'fetches from the official UUP dump 22621.900 build (KB5020044) via the file list, never from Ramos' {
        $script:CleanScriptText | Should -Match "22621\.900"
        $script:CleanScriptText | Should -Match 'KB5020044'
        $script:CleanScriptText | Should -Match 'Get-UupBuild -Build'
        $script:CleanScriptText | Should -Match 'https://uupdump\.net'
        $script:CleanScriptText | Should -Match 'get\.php'
        $script:CleanScriptText | Should -Match 'aria2=2'
        # Round 13 died on autodl=1: it returns a downloader-script ZIP
        # with no file list in it, so the matcher found 0 cabs. The
        # endpoint must stay aria2=2, which returns the plain-text list.
        $script:CleanScriptText | Should -Not -Match "autodl = '1'"
        $script:CleanScriptText | Should -Match 'F750E6C3-38EE-11D1-85E5-00C04FC295EE'
    }

    It 'runs the catalog step after extract and before capture, and reads back after capture' {
        $dispatch = ($script:CleanScriptText -split '# Dispatch')[1]
        $dispatch.IndexOf('Invoke-CleanCatFixStep') | Should -BeGreaterThan $dispatch.IndexOf('Invoke-CleanExtractStep')
        $dispatch.IndexOf('Invoke-CleanCatFixStep') | Should -BeLessThan $dispatch.IndexOf('Invoke-CleanCaptureStep')
        $dispatch.IndexOf('Assert-CleanCatFilesInBootWim') | Should -BeGreaterThan $dispatch.IndexOf('Invoke-CleanCaptureStep')
        $dispatch.IndexOf('Assert-CleanCatFilesInBootWim') | Should -BeLessThan $dispatch.IndexOf('Invoke-CleanIsoStep')
    }

    It 'Find-CleanCatLcuCab returns the KB5020044 cab from an aria2 file list' {
        $lcu = Find-CleanCatLcuCab -FileListText $script:aria2Text -Kb 'KB5020044'
        $lcu.FileName | Should -Be 'windows11.0-kb5020044-x64_0123456789abcdef.cab'
        $lcu.Url | Should -Be 'https://download.windowsupdate.com/c/msdownload/update/software/defu/2022/11/windows11.0-kb5020044-x64_0123456789abcdef.cab'
    }

    It 'Find-CleanCatLcuCab throws when no KB5020044 cab is listed' {
        $text = @'
https://download.windowsupdate.com/x/windows11.0-kb5020061-x64_abcdef0123456789.cab
  out=windows11.0-kb5020061-x64_abcdef0123456789.cab
'@
        { Find-CleanCatLcuCab -FileListText $text -Kb 'KB5020044' } | Should -Throw '*expected exactly one KB5020044*'
    }

    It 'Find-CleanCatLcuCab throws when two KB5020044 cabs are listed (never guess)' {
        $text = @'
https://download.windowsupdate.com/x/windows11.0-kb5020044-x64_aaaa.cab
  out=windows11.0-kb5020044-x64_aaaa.cab
https://download.windowsupdate.com/x/windows11.0-kb5020044-x64_bbbb.cab
  out=windows11.0-kb5020044-x64_bbbb.cab
'@
        { Find-CleanCatLcuCab -FileListText $text -Kb 'KB5020044' } | Should -Throw '*expected exactly one KB5020044*'
    }

    It 'Get-CleanCatFixFileList fetches the plain-text aria2 list (aria2=2), not the autodl=1 script ZIP (round 14)' {
        $work = Join-Path $script:TempRoot ("micpe-catfix-list-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $fakeUup = {
            param($url)
            @{
                response = @{
                    builds = @{
                        '2858' = [pscustomobject]@{ uuid = '5d5ef944-1ba0-436b-b7d3-571d59a15cbb'; build = '22621.900'; arch = 'amd64'; title = 'Windows 11, version 22H2 (22621.900)' }
                    }
                }
            }
        }
        try {
            Mock Invoke-WebRequest {
                param($Uri, $OutFile)
                $script:capturedListUri = $Uri
                Set-Content -LiteralPath $OutFile -Value $script:aria2Text -NoNewline
            }
            $listDir = Get-CleanCatFixFileList -Build '22621.900' -Lang 'zh-cn' -Edition 'professional' -WorkDir $work -UupInvoke $fakeUup
            $script:capturedListUri | Should -Match 'aria2=2'
            $script:capturedListUri | Should -Not -Match 'autodl'
            $script:capturedListUri | Should -Match '5d5ef944-1ba0-436b-b7d3-571d59a15cbb'
            $listFile = Join-Path $listDir 'uup-filelist.txt'
            Test-Path -LiteralPath $listFile | Should -BeTrue
            (Get-Content -LiteralPath $listFile -Raw) | Should -Be $script:aria2Text
            (Find-CleanCatLcuCab -FileListText (Get-Content -LiteralPath $listFile -Raw) -Kb 'KB5020044').FileName |
                Should -Be 'windows11.0-kb5020044-x64_0123456789abcdef.cab'
        }
        finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Get-CleanCatFixFileList throws loudly when the fetched content is not an aria2 list (round 14)' {
        $work = Join-Path $script:TempRoot ("micpe-catfix-badlist-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $fakeUup = {
            param($url)
            @{
                response = @{
                    builds = @{
                        '2858' = [pscustomobject]@{ uuid = '5d5ef944-1ba0-436b-b7d3-571d59a15cbb'; build = '22621.900'; arch = 'amd64'; title = 'Windows 11, version 22H2 (22621.900)' }
                    }
                }
            }
        }
        try {
            Mock Invoke-WebRequest {
                param($Uri, $OutFile)
                Set-Content -LiteralPath $OutFile -Value 'not a list at all' -NoNewline
            }
            { Get-CleanCatFixFileList -Build '22621.900' -Lang 'zh-cn' -Edition 'professional' -WorkDir $work -UupInvoke $fakeUup } |
                Should -Throw '*not an aria2 list*'
        }
        finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Test-CleanCatHasCdromHash finds the cdrom.sys hash in a fixture catalog and not in a plain file' {
        $cat = Join-Path $script:fixtures 'Microsoft-Windows-Client-Desktop-Required-Package0110~31bf3856ad364e35~amd64~~10.0.22621.900.cat'
        Test-CleanCatHasCdromHash -CatPath $cat | Should -BeTrue
        $plain = Join-Path $script:fixtures 'catfix-aria2.txt'
        Test-CleanCatHasCdromHash -CatPath $plain | Should -BeFalse
    }

    It 'Test-CleanCatHasCdromHash requires both hashes, not just the SHA1' {
        $onlySha1 = Join-Path $script:TempRoot ("micpe-catfix-sha1only-{0}.cat" -f [guid]::NewGuid())
        try {
            [System.IO.File]::WriteAllBytes($onlySha1, [System.Convert]::FromHexString('8f19637e8381f4406a72e06276a609bde11ef4e5'))
            Test-CleanCatHasCdromHash -CatPath $onlySha1 | Should -BeFalse
        }
        finally {
            Remove-Item -LiteralPath $onlySha1 -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Assert-CleanCatFiles passes for the fixture catalogs' {
        { Assert-CleanCatFiles -CatDir $script:fixtures -ExpectedCats $script:fixtureCats } | Should -Not -Throw
    }

    It 'Assert-CleanCatFiles throws when a catalog is missing or its hash is wrong' {
        $oneOnly = Join-Path $script:TempRoot ("micpe-catfix-one-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $oneOnly -Force | Out-Null
        try {
            Copy-Item -LiteralPath (Join-Path $script:fixtures 'Microsoft-Windows-Client-Desktop-Required-Package0110~31bf3856ad364e35~amd64~~10.0.22621.900.cat') -Destination $oneOnly -Force
            { Assert-CleanCatFiles -CatDir $oneOnly -ExpectedCats $script:fixtureCats } | Should -Throw '*not found exactly once*'
            $wrong = @($script:fixtureCats | ForEach-Object {
                    [pscustomobject]@{ Name = $_.Name; Size = $_.Size; Sha256 = '0000000000000000000000000000000000000000000000000000000000000000' }
                })
            { Assert-CleanCatFiles -CatDir $script:fixtures -ExpectedCats $wrong } | Should -Throw '*SHA256 mismatch*'
        }
        finally {
            Remove-Item -LiteralPath $oneOnly -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Invoke-CleanCatFixStep injects both catalogs into the staging CatRoot (fakes)' {
        $staging = Join-Path $script:TempRoot ("micpe-catfix-staging-{0}" -f [guid]::NewGuid())
        $work = Join-Path $script:TempRoot ("micpe-catfix-work-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $zipPath = Join-Path $work 'filelist.zip'
        Compress-Archive -LiteralPath (Join-Path $script:fixtures 'catfix-aria2.txt') -DestinationPath $zipPath -Force
        $cabPath = Join-Path $work 'windows11.0-kb5020044-x64_0123456789abcdef.cab'
        Set-Content -LiteralPath $cabPath -Value 'FAKE-CAB' -NoNewline
        try {
            $env:MICPE_FAKE_7Z_SOURCE_DIR = $script:fixtures
            $result = Invoke-CleanCatFixStep -StagingDir $staging -WorkDir (Join-Path $work 'catfix') -FileListZipPath $zipPath -CabPath $cabPath -SevenZipPath $script:fake7z -ExpectedCats $script:fixtureCats
            $result.Injected.Count | Should -Be 2
            foreach ($cat in $script:fixtureCats) {
                $staged = Join-Path $staging "Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}\$($cat.Name)"
                Test-Path -LiteralPath $staged | Should -BeTrue
                (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash | Should -Be $cat.Sha256
            }
        }
        finally {
            $env:MICPE_FAKE_7Z_SOURCE_DIR = $null
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Invoke-CleanCatFixStep skips a catalog already staged with matching SHA256 (round 40)' {
        # Round 39 rerun: the serviced image already ships the
        # Package0110 22621.900 .cat, so the copy overwrites an
        # existing file -- and three rounds died on exactly that
        # overwrite. Same bytes means no copy is needed: skip only
        # that file, never the whole step.
        $staging = Join-Path $script:TempRoot ("micpe-catfix-skip-{0}" -f [guid]::NewGuid())
        $work = Join-Path $script:TempRoot ("micpe-catfix-skipwork-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $catRootDir = Join-Path $staging 'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}'
        New-Item -ItemType Directory -Path $catRootDir -Force | Out-Null
        $staged0110 = Join-Path $catRootDir $script:fixtureCats[0].Name
        Copy-Item -LiteralPath (Join-Path $script:fixtures $script:fixtureCats[0].Name) -Destination $staged0110 -Force
        $zipPath = Join-Path $work 'filelist.zip'
        Compress-Archive -LiteralPath (Join-Path $script:fixtures 'catfix-aria2.txt') -DestinationPath $zipPath -Force
        $cabPath = Join-Path $work 'windows11.0-kb5020044-x64_0123456789abcdef.cab'
        Set-Content -LiteralPath $cabPath -Value 'FAKE-CAB' -NoNewline
        $attribLog = Join-Path $script:TempRoot "micpe-attrib-$(Get-Random).log"
        $icaclsLog = Join-Path $script:TempRoot "micpe-icacls-$(Get-Random).log"
        $env:MICPE_FAKE_ATTRIB_LOG = $attribLog
        $env:MICPE_FAKE_ICACLS_LOG = $icaclsLog
        try {
            $env:MICPE_FAKE_7Z_SOURCE_DIR = $script:fixtures
            $result = Invoke-CleanCatFixStep -StagingDir $staging -WorkDir (Join-Path $work 'catfix') -FileListZipPath $zipPath -CabPath $cabPath -SevenZipPath $script:fake7z -AttribPath $script:fakeAttrib -IcaclsPath $script:fakeIcacls -ExpectedCats $script:fixtureCats
            $result.Skipped | Should -Contain $script:fixtureCats[0].Name
            $result.Injected.Count | Should -Be 1
            $result.Injected | Should -Contain $script:fixtureCats[1].Name
            # The skipped file is untouched (same bytes as before).
            (Get-FileHash -LiteralPath $staged0110 -Algorithm SHA256).Hash | Should -Be $script:fixtureCats[0].Sha256
            # The diagnostic ran on the staged file, but no -R: a skip
            # never touches the target.
            $attrib = @(Get-Content -LiteralPath $attribLog)
            $attrib[0] | Should -Be $staged0110
            $attrib | Should -Not -Contain '-R'
            $icacls = @(Get-Content -LiteralPath $icaclsLog)
            $icacls[0] | Should -Be $staged0110
        }
        finally {
            $env:MICPE_FAKE_7Z_SOURCE_DIR = $null
            Remove-Item Env:MICPE_FAKE_ATTRIB_LOG -ErrorAction SilentlyContinue
            Remove-Item Env:MICPE_FAKE_ICACLS_LOG -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $attribLog -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $icaclsLog -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Invoke-CleanCatFixStep clears the read-only flag before overwriting a staged catalog with different bytes (round 40)' {
        # Round 39 rerun prime hypothesis: the staged .cat carries the
        # read-only attribute from the WIM extract and Copy-Item
        # -Force is denied on the overwrite. The step must clear the
        # flag on the target itself (attrib -R, not Remove-Item: a
        # failed remove+copy would leave staging without a .cat the
        # serviced source shipped).
        $staging = Join-Path $script:TempRoot ("micpe-catfix-ro-{0}" -f [guid]::NewGuid())
        $work = Join-Path $script:TempRoot ("micpe-catfix-rowork-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $catRootDir = Join-Path $staging 'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}'
        New-Item -ItemType Directory -Path $catRootDir -Force | Out-Null
        $stagedMerged = Join-Path $catRootDir $script:fixtureCats[1].Name
        Set-Content -LiteralPath $stagedMerged -Value 'NOT-THE-REAL-CATALOG' -NoNewline
        (Get-Item -LiteralPath $stagedMerged -Force).Attributes = [IO.FileAttributes]::ReadOnly
        $zipPath = Join-Path $work 'filelist.zip'
        Compress-Archive -LiteralPath (Join-Path $script:fixtures 'catfix-aria2.txt') -DestinationPath $zipPath -Force
        $cabPath = Join-Path $work 'windows11.0-kb5020044-x64_0123456789abcdef.cab'
        Set-Content -LiteralPath $cabPath -Value 'FAKE-CAB' -NoNewline
        $attribLog = Join-Path $script:TempRoot "micpe-attrib-$(Get-Random).log"
        $icaclsLog = Join-Path $script:TempRoot "micpe-icacls-$(Get-Random).log"
        $env:MICPE_FAKE_ATTRIB_LOG = $attribLog
        $env:MICPE_FAKE_ICACLS_LOG = $icaclsLog
        try {
            $env:MICPE_FAKE_7Z_SOURCE_DIR = $script:fixtures
            $result = Invoke-CleanCatFixStep -StagingDir $staging -WorkDir (Join-Path $work 'catfix') -FileListZipPath $zipPath -CabPath $cabPath -SevenZipPath $script:fake7z -AttribPath $script:fakeAttrib -IcaclsPath $script:fakeIcacls -ExpectedCats $script:fixtureCats
            $result.Injected.Count | Should -Be 2
            $result.Skipped.Count | Should -Be 0
            # Overwritten with the fixture bytes, flag cleared.
            (Get-FileHash -LiteralPath $stagedMerged -Algorithm SHA256).Hash | Should -Be $script:fixtureCats[1].Sha256
            ((Get-Item -LiteralPath $stagedMerged -Force).Attributes -band [IO.FileAttributes]::ReadOnly) | Should -Be 0
            # Diagnostic first, then the -R clear, both on the target.
            $attrib = @(Get-Content -LiteralPath $attribLog)
            $attrib[0] | Should -Be $stagedMerged
            $attrib[1] | Should -Be '-R'
            $attrib[2] | Should -Be $stagedMerged
            $icacls = @(Get-Content -LiteralPath $icaclsLog)
            $icacls[0] | Should -Be $stagedMerged
        }
        finally {
            $env:MICPE_FAKE_7Z_SOURCE_DIR = $null
            Remove-Item Env:MICPE_FAKE_ATTRIB_LOG -ErrorAction SilentlyContinue
            Remove-Item Env:MICPE_FAKE_ICACLS_LOG -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $attribLog -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $icaclsLog -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Invoke-CleanCatFixStep throws loudly when attrib -R fails (round 40)' {
        # The -R clear is the fix for the round 39 rerun overwrite
        # denial: if it fails, the copy would fail anyway, so the
        # step must fail here with the target file in the message,
        # not at Copy-Item.
        $staging = Join-Path $script:TempRoot ("micpe-catfix-attribfail-{0}" -f [guid]::NewGuid())
        $work = Join-Path $script:TempRoot ("micpe-catfix-attribfailwork-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $catRootDir = Join-Path $staging 'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}'
        New-Item -ItemType Directory -Path $catRootDir -Force | Out-Null
        $stagedMerged = Join-Path $catRootDir $script:fixtureCats[1].Name
        Set-Content -LiteralPath $stagedMerged -Value 'NOT-THE-REAL-CATALOG' -NoNewline
        $zipPath = Join-Path $work 'filelist.zip'
        Compress-Archive -LiteralPath (Join-Path $script:fixtures 'catfix-aria2.txt') -DestinationPath $zipPath -Force
        $cabPath = Join-Path $work 'windows11.0-kb5020044-x64_0123456789abcdef.cab'
        Set-Content -LiteralPath $cabPath -Value 'FAKE-CAB' -NoNewline
        try {
            $env:MICPE_FAKE_7Z_SOURCE_DIR = $script:fixtures
            $env:MICPE_FAKE_ATTRIB_FAIL = '1'
            { Invoke-CleanCatFixStep -StagingDir $staging -WorkDir (Join-Path $work 'catfix') -FileListZipPath $zipPath -CabPath $cabPath -SevenZipPath $script:fake7z -AttribPath $script:fakeAttrib -IcaclsPath $script:fakeIcacls -ExpectedCats $script:fixtureCats } | Should -Throw '*attrib -R failed*'
        }
        finally {
            $env:MICPE_FAKE_7Z_SOURCE_DIR = $null
            $env:MICPE_FAKE_ATTRIB_FAIL = $null
            $global:LASTEXITCODE = 0
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'the catalog step prints the target file state before overwriting, clears read-only, and skips hash-matching targets (round 40)' {
        $script:CleanScriptText | Should -Match 'target state for'
        $script:CleanScriptText | Should -Match 'already present with matching SHA256'
        $script:CleanScriptText | Should -Match 'attrib -R failed with exit code'
        $script:CleanScriptText | Should -Match 'Skipped\s+= @\(\$skipped'
    }

    It 'Invoke-CleanCatFixStep throws loudly when 7z fails (must not silently proceed)' {
        $staging = Join-Path $script:TempRoot ("micpe-catfix-fail-{0}" -f [guid]::NewGuid())
        $work = Join-Path $script:TempRoot ("micpe-catfix-failwork-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $zipPath = Join-Path $work 'filelist.zip'
        Compress-Archive -LiteralPath (Join-Path $script:fixtures 'catfix-aria2.txt') -DestinationPath $zipPath -Force
        $cabPath = Join-Path $work 'windows11.0-kb5020044-x64_0123456789abcdef.cab'
        Set-Content -LiteralPath $cabPath -Value 'FAKE-CAB' -NoNewline
        try {
            $env:MICPE_FAKE_7Z_SOURCE_DIR = $script:fixtures
            $env:MICPE_FAKE_7Z_FAIL = '1'
            { Invoke-CleanCatFixStep -StagingDir $staging -WorkDir (Join-Path $work 'catfix') -FileListZipPath $zipPath -CabPath $cabPath -SevenZipPath $script:fake7z -ExpectedCats $script:fixtureCats } | Should -Throw '*7z failed*'
        }
        finally {
            $env:MICPE_FAKE_7Z_SOURCE_DIR = $null
            $env:MICPE_FAKE_7Z_FAIL = $null
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Assert-CleanCatFilesInBootWim reads both catalogs back from boot.wim (fake wimlib)' {
        $bootWim = Join-Path $script:TempRoot ("micpe-catfix-boot-{0}.wim" -f [guid]::NewGuid())
        Set-Content -LiteralPath $bootWim -Value 'FAKE-WIM' -NoNewline
        $work = Join-Path $script:TempRoot ("micpe-catfix-rb-{0}" -f [guid]::NewGuid())
        try {
            $env:MICPE_FAKE_WIMLIB_CAT_SOURCE_DIR = $script:fixtures
            { Assert-CleanCatFilesInBootWim -BootWim $bootWim -ExpectedCats $script:fixtureCats -WorkDir $work -WimlibPath $script:fakeWimlib } | Should -Not -Throw
        }
        finally {
            $env:MICPE_FAKE_WIMLIB_CAT_SOURCE_DIR = $null
            Remove-Item -LiteralPath $bootWim -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Assert-CleanCatFilesInBootWim throws when a catalog is missing from boot.wim' {
        $bootWim = Join-Path $script:TempRoot ("micpe-catfix-boot2-{0}.wim" -f [guid]::NewGuid())
        Set-Content -LiteralPath $bootWim -Value 'FAKE-WIM' -NoNewline
        $work = Join-Path $script:TempRoot ("micpe-catfix-rb2-{0}" -f [guid]::NewGuid())
        $oneOnly = Join-Path $script:TempRoot ("micpe-catfix-one2-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $oneOnly -Force | Out-Null
        try {
            Copy-Item -LiteralPath (Join-Path $script:fixtures 'Microsoft-Windows-Client-Desktop-Required-Package0110~31bf3856ad364e35~amd64~~10.0.22621.900.cat') -Destination $oneOnly -Force
            $env:MICPE_FAKE_WIMLIB_CAT_SOURCE_DIR = $oneOnly
            { Assert-CleanCatFilesInBootWim -BootWim $bootWim -ExpectedCats $script:fixtureCats -WorkDir $work -WimlibPath $script:fakeWimlib } | Should -Throw '*not found exactly once*'
        }
        finally {
            $env:MICPE_FAKE_WIMLIB_CAT_SOURCE_DIR = $null
            Remove-Item -LiteralPath $bootWim -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $oneOnly -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-CleanGdiPlusCatFixStep (round 36: GdiPlus.dll catalog for smss)' {
    BeforeAll {
        $script:fixtures = Join-Path $PSScriptRoot 'fixtures'
        $script:fakeWimlib = Join-Path $PSScriptRoot 'Fake-Wimlib.ps1'
        # Pull the GdiPlus functions out of Build-CleanPe.ps1 via the
        # AST (the script cannot be dot-sourced: its dispatch section
        # runs on load). Same pattern as the catfix tests.
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:CleanScript, [ref] $tokens, [ref] $errors)
        $errors.Count | Should -Be 0
        $allFns = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)
        foreach ($name in @('Find-ByteSequence', 'Get-CleanAuthenticodeHash', 'Test-CleanCatHasAuthenticodeHash', 'Test-CleanCatHasCdromHash', 'Assert-CleanCatFiles', 'Invoke-CleanGdiPlusCatFixStep', 'Assert-CleanCatFilesInBootWim')) {
            $fn = @($allFns | Where-Object { $_.Name -eq $name })
            $fn.Count | Should -Be 1
            . ([scriptblock]::Create($fn[0].Extent.Text))
        }
        # The fixture PE (tests/fixtures/gdiplus-fixture.dll) is a
        # minimal valid PE64; its Authenticode hashes were computed
        # with the independent Python oracle
        # (~/workspace/micpe-catfix/authenticode_hash.py) and are
        # pinned here. The covering fixture .cat embeds both hashes;
        # the sha1-only one embeds only the SHA1 (must be rejected:
        # both digests are required for coverage).
        $script:fixtureDllSha1 = '3de19f46bdaf5e3596ceba0659b3149524d34168'
        $script:fixtureDllSha256 = '8b73fcb60a1e9906da521230f201aa7eb920f29c28fa8ab8bc6d35a18f32d863'
        $script:fixtureCats = @('gdiplus-covering.cat', 'gdiplus-sha1only.cat')
        $script:buildYml = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/build.yml') -Raw
    }

    It 'Get-CleanAuthenticodeHash reproduces the Python oracle on the fixture PE' {
        $h = Get-CleanAuthenticodeHash -Path (Join-Path $script:fixtures 'gdiplus-fixture.dll')
        $h.Sha1 | Should -Be $script:fixtureDllSha1
        $h.Sha256 | Should -Be $script:fixtureDllSha256
    }

    It 'Get-CleanAuthenticodeHash throws on a non-PE file' {
        { Get-CleanAuthenticodeHash -Path (Join-Path $script:fixtures 'catfix-aria2.txt') } | Should -Throw '*not a PE file*'
    }

    It 'Test-CleanCatHasAuthenticodeHash requires both hashes, not just the SHA1' {
        $covering = Join-Path $script:fixtures 'gdiplus-covering.cat'
        Test-CleanCatHasAuthenticodeHash -CatPath $covering -Sha1 $script:fixtureDllSha1 -Sha256 $script:fixtureDllSha256 | Should -BeTrue
        $sha1only = Join-Path $script:fixtures 'gdiplus-sha1only.cat'
        Test-CleanCatHasAuthenticodeHash -CatPath $sha1only -Sha1 $script:fixtureDllSha1 -Sha256 $script:fixtureDllSha256 | Should -BeFalse
        $plain = Join-Path $script:fixtures 'catfix-aria2.txt'
        Test-CleanCatHasAuthenticodeHash -CatPath $plain -Sha1 $script:fixtureDllSha1 -Sha256 $script:fixtureDllSha256 | Should -BeFalse
    }

    It 'pins the RTM 22621.1 candidate catalogs (same packages as the 22621.1105 ones covering the reference file)' {
        # The reference (22621.819) GdiPlus.dll is covered by the
        # 22621.1105 Package0518 and WinPE-SKU-Foundation-merged
        # catalogs; the RTM file in the image needs their 22621.1
        # counterparts, from the source install.wim -- never Ramos.
        $script:CleanScriptText | Should -Match 'Microsoft-Windows-Client-Desktop-Required-Package0518~31bf3856ad364e35~amd64~~10\.0\.22621\.1\.cat'
        $script:CleanScriptText | Should -Match 'Microsoft-Windows-WinPE-SKU-Foundation-merged-Package~31bf3856ad364e35~amd64~~10\.0\.22621\.1\.cat'
        $script:CleanScriptText | Should -Match 'Invoke-CleanGdiPlusCatFixStep'
    }

    It 'pins AddUpdates = 1 in the clean base step (round 37: serviced 22621.1105 source, not RTM)' {
        # Rounds 13/14 (cdrom.sys), 35/36 (GdiPlus.dll) and 36
        # (difxapi.dll) all died on the same skew: the RTM source
        # lacks the 22621.1105 catalogs the whitelist -- built from
        # the 22621.1105 reference -- lists (1,167 of 1,911
        # whitelisted .cats missing from the RTM Professional source
        # in the round 36 log). AddUpdates=1 makes the source a
        # serviced 22621.1105 image so the whitelisted catalogs
        # match it. Build-Micpe.ps1 keeps its own '0' (non-clean
        # path, untouched by this round); this pin is
        # Build-CleanPe.ps1 only.
        $script:CleanScriptText | Should -Match "AddUpdates = '1'"
        $script:CleanScriptText | Should -Not -Match "AddUpdates = '0'"
    }

    It 'Invoke-CleanGdiPlusCatFixStep injects the covering catalog and writes the diagnosis (seam)' {
        $staging = Join-Path $script:TempRoot ("micpe-gdiplus-staging-{0}" -f [guid]::NewGuid())
        $work = Join-Path $script:TempRoot ("micpe-gdiplus-work-{0}" -f [guid]::NewGuid())
        $pre = Join-Path $script:TempRoot ("micpe-gdiplus-pre-{0}" -f [guid]::NewGuid())
        try {
            $stagingDllDir = Join-Path $staging 'Windows\System32'
            New-Item -ItemType Directory -Path $stagingDllDir -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:fixtures 'gdiplus-fixture.dll') -Destination (Join-Path $stagingDllDir 'GdiPlus.dll') -Force
            $preDllDir = Join-Path $pre 'Windows\System32'
            New-Item -ItemType Directory -Path $preDllDir -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:fixtures 'gdiplus-fixture.dll') -Destination (Join-Path $preDllDir 'GdiPlus.dll') -Force
            $preCatDir = Join-Path $pre 'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}'
            New-Item -ItemType Directory -Path $preCatDir -Force | Out-Null
            foreach ($cat in $script:fixtureCats) {
                Copy-Item -LiteralPath (Join-Path $script:fixtures $cat) -Destination (Join-Path $preCatDir $cat) -Force
            }
            $result = Invoke-CleanGdiPlusCatFixStep -StagingDir $staging -InstallWim (Join-Path $pre 'fake-install.wim') -WorkDir $work -CandidateCats $script:fixtureCats -PreExtractedInstallWimDir $pre
            $result.InjectedCats.Count | Should -Be 1
            $result.InjectedCats[0].Name | Should -Be 'gdiplus-covering.cat'
            $result.AlreadyCovered | Should -BeFalse
            $result.CoveringCats.Count | Should -Be 1
            $result.CoveringCats[0].Name | Should -Be 'gdiplus-covering.cat'
            $result.CoveringCats[0].Sha256 | Should -Be $result.InjectedCats[0].Sha256
            $result.OfficialMatch | Should -BeTrue
            $result.GdiPlusAuthSha1 | Should -Be $script:fixtureDllSha1
            $result.GdiPlusAuthSha256 | Should -Be $script:fixtureDllSha256
            $staged = Join-Path $staging 'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}\gdiplus-covering.cat'
            Test-Path -LiteralPath $staged | Should -BeTrue
            (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash | Should -Be $result.InjectedCats[0].Sha256
            # The sha1-only candidate must NOT be injected.
            Test-Path -LiteralPath (Join-Path $staging 'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}\gdiplus-sha1only.cat') | Should -BeFalse
            # The diagnosis records every item: hash, version (empty
            # for the fixture: it has no version resource), official
            # comparison, per-candidate verdict, injected list.
            Test-Path -LiteralPath $result.DiagPath | Should -BeTrue
            $diag = Get-Content -LiteralPath $result.DiagPath -Raw
            $diag | Should -Match $script:fixtureDllSha256
            $diag | Should -Match 'matches official install.wim file: True'
            $diag | Should -Match 'COVERS the file'
            $diag | Should -Match 'does NOT cover the file'
            $diag | Should -Match 'KnownDLLs'
        }
        finally {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $pre -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Invoke-CleanGdiPlusCatFixStep returns early when the staged CatRoot already covers the file (round 37 coverage-first)' {
        $staging = Join-Path $script:TempRoot ("micpe-gdiplus-covered-{0}" -f [guid]::NewGuid())
        $work = Join-Path $script:TempRoot ("micpe-gdiplus-coveredwork-{0}" -f [guid]::NewGuid())
        $pre = Join-Path $script:TempRoot ("micpe-gdiplus-coveredpre-{0}" -f [guid]::NewGuid())
        try {
            $stagingDllDir = Join-Path $staging 'Windows\System32'
            New-Item -ItemType Directory -Path $stagingDllDir -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:fixtures 'gdiplus-fixture.dll') -Destination (Join-Path $stagingDllDir 'GdiPlus.dll') -Force
            # The staged CatRoot already holds the covering catalog
            # (this is what the whitelist copy delivers after the
            # round 37 AddUpdates flip); the sha1-only one must NOT
            # count as covering.
            $stagedCatDir = Join-Path $staging 'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}'
            New-Item -ItemType Directory -Path $stagedCatDir -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:fixtures 'gdiplus-covering.cat') -Destination (Join-Path $stagedCatDir 'gdiplus-covering.cat') -Force
            Copy-Item -LiteralPath (Join-Path $script:fixtures 'gdiplus-sha1only.cat') -Destination (Join-Path $stagedCatDir 'gdiplus-sha1only.cat') -Force
            # The pre-extracted "install.wim" dir is EMPTY -- no
            # GdiPlus.dll, no catalogs: if the step touched it at
            # all, the official comparison would fail. The early
            # return must skip it entirely.
            New-Item -ItemType Directory -Path $pre -Force | Out-Null
            $result = Invoke-CleanGdiPlusCatFixStep -StagingDir $staging -InstallWim (Join-Path $pre 'fake-install.wim') -WorkDir $work -CandidateCats $script:fixtureCats -PreExtractedInstallWimDir $pre
            $result.AlreadyCovered | Should -BeTrue
            $result.InjectedCats.Count | Should -Be 0
            $result.CoveringCats.Count | Should -Be 1
            $result.CoveringCats[0].Name | Should -Be 'gdiplus-covering.cat'
            $result.OfficialMatch | Should -BeNull
            $diag = Get-Content -LiteralPath $result.DiagPath -Raw
            $diag | Should -Match 'already covers the file'
            $diag | Should -Match 'KnownDLLs'
            $diag | Should -Match '0 \(none needed'
        }
        finally {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $pre -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Invoke-CleanGdiPlusCatFixStep throws loudly when no candidate covers the file' {
        $staging = Join-Path $script:TempRoot ("micpe-gdiplus-nocover-{0}" -f [guid]::NewGuid())
        $work = Join-Path $script:TempRoot ("micpe-gdiplus-nocoverwork-{0}" -f [guid]::NewGuid())
        $pre = Join-Path $script:TempRoot ("micpe-gdiplus-nocoverpre-{0}" -f [guid]::NewGuid())
        try {
            $stagingDllDir = Join-Path $staging 'Windows\System32'
            New-Item -ItemType Directory -Path $stagingDllDir -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:fixtures 'gdiplus-fixture.dll') -Destination (Join-Path $stagingDllDir 'GdiPlus.dll') -Force
            $preDllDir = Join-Path $pre 'Windows\System32'
            New-Item -ItemType Directory -Path $preDllDir -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:fixtures 'gdiplus-fixture.dll') -Destination (Join-Path $preDllDir 'GdiPlus.dll') -Force
            $preCatDir = Join-Path $pre 'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}'
            New-Item -ItemType Directory -Path $preCatDir -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:fixtures 'gdiplus-sha1only.cat') -Destination (Join-Path $preCatDir 'gdiplus-sha1only.cat') -Force
            { Invoke-CleanGdiPlusCatFixStep -StagingDir $staging -InstallWim (Join-Path $pre 'fake-install.wim') -WorkDir $work -CandidateCats @('gdiplus-sha1only.cat') -PreExtractedInstallWimDir $pre } |
                Should -Throw '*no candidate catalog*'
            # The diagnosis is still written: the next round needs
            # the version and hashes to find the covering catalog.
            $diagPath = Join-Path $work 'micpe-gdiplus-diag.txt'
            Test-Path -LiteralPath $diagPath | Should -BeTrue
            (Get-Content -LiteralPath $diagPath -Raw) | Should -Match 'NO catalog covers'
        }
        finally {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $pre -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'runs the GdiPlus step after the cdrom catalog fix and reads both back after capture' {
        $dispatch = ($script:CleanScriptText -split '# Dispatch')[1]
        $dispatch.IndexOf('Invoke-CleanGdiPlusCatFixStep') | Should -BeGreaterThan $dispatch.IndexOf('Invoke-CleanCatFixStep')
        $dispatch.IndexOf('Invoke-CleanGdiPlusCatFixStep') | Should -BeLessThan $dispatch.IndexOf('Invoke-CleanCaptureStep')
        $dispatch | Should -Match 'gdiPlusFix\.CoveringCats'
        $dispatch | Should -Match 'micpe-gdiplus-diag\.txt'
    }

    It 'the Release picks up the GdiPlus diagnosis from the repo root' {
        $script:buildYml | Should -Match 'micpe-gdiplus-diag\.txt'
    }

    It 'Assert-CleanCatFilesInBootWim reads a combined cdrom + GdiPlus list back (fake wimlib)' {
        $bootWim = Join-Path $script:TempRoot ("micpe-gdiplus-boot-{0}.wim" -f [guid]::NewGuid())
        Set-Content -LiteralPath $bootWim -Value 'FAKE-WIM' -NoNewline
        $work = Join-Path $script:TempRoot ("micpe-gdiplus-rb-{0}" -f [guid]::NewGuid())
        try {
            $covering = Get-Item -LiteralPath (Join-Path $script:fixtures 'gdiplus-covering.cat')
            $combined = @(
                [pscustomobject]@{ Name = 'Microsoft-Windows-Client-Desktop-Required-Package0110~31bf3856ad364e35~amd64~~10.0.22621.900.cat'; Size = (Get-Item -LiteralPath (Join-Path $script:fixtures 'Microsoft-Windows-Client-Desktop-Required-Package0110~31bf3856ad364e35~amd64~~10.0.22621.900.cat')).Length; Sha256 = (Get-FileHash -LiteralPath (Join-Path $script:fixtures 'Microsoft-Windows-Client-Desktop-Required-Package0110~31bf3856ad364e35~amd64~~10.0.22621.900.cat') -Algorithm SHA256).Hash }
                [pscustomobject]@{ Name = 'gdiplus-covering.cat'; Size = $covering.Length; Sha256 = (Get-FileHash -LiteralPath $covering.FullName -Algorithm SHA256).Hash }
            )
            $env:MICPE_FAKE_WIMLIB_CAT_SOURCE_DIR = $script:fixtures
            { Assert-CleanCatFilesInBootWim -BootWim $bootWim -ExpectedCats $combined -WorkDir $work -WimlibPath $script:fakeWimlib } | Should -Not -Throw
        }
        finally {
            $env:MICPE_FAKE_WIMLIB_CAT_SOURCE_DIR = $null
            Remove-Item -LiteralPath $bootWim -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-CleanWimBootStep (round 15: IO1 INITIALIZATION FAILED, WIM boot stack)' {
    BeforeAll {
        # Pull the boot-critical guard functions out of ClientBase.ps1 via
        # the AST (ClientBase cannot be dot-sourced in the test session:
        # it sets StrictMode 2.0 and defines Write-Step, both of which
        # would leak into the session; Build-CleanPe.ps1 loads it first
        # so Common wins both). Same AST pattern as the catfix tests.
        $tokens = $null
        $errors = $null
        $clientBase = Join-Path $script:RepoRoot 'src/build/lib/ClientBase.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($clientBase, [ref] $tokens, [ref] $errors)
        $errors.Count | Should -Be 0
        $allFns = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)
        foreach ($name in @('Resolve-CleanDriverImagePath', 'Get-CleanRegistryValue', 'Test-CleanCriticalDriverFiles', 'Test-BootCriticalFiles', 'Assert-BootCritical', 'Invoke-RegExe', 'Test-CleanHiveFileReadable', 'Dismount-OfflineHive', 'ConvertTo-CleanRegDword', 'ConvertFrom-CleanServicesRegQuery', 'Get-CleanServicesViaRegQuery')) {
            $fn = @($allFns | Where-Object { $_.Name -eq $name })
            $fn.Count | Should -Be 1
            . ([scriptblock]::Create($fn[0].Extent.Text))
        }

        # Fake reg.exe for the Dismount-OfflineHive tests (round 19):
        # a function wins over a native command, and it must set
        # $global:LASTEXITCODE (a function never sets the caller's
        # value by itself -- the Fake-Bcdedit lesson).
        # $script:fakeRegFailuresRemaining counts down how many more
        # unload calls fail before succeeding; -1 means "always fail".
        # Each It resets both counters before calling Dismount.
        $script:fakeRegFailuresRemaining = 0
        $script:fakeRegCalls = 0
        # Round 20: a canned `reg query /s` dump for the
        # Get-CleanServicesViaRegQuery tests. Only query calls see it;
        # unload calls still go through the failure countdown below.
        $script:fakeRegQueryOutput = $null
        function reg.exe {
            $script:fakeRegCalls++
            if ($args.Count -ge 1 -and $args[0] -eq 'query' -and $null -ne $script:fakeRegQueryOutput) {
                $global:LASTEXITCODE = 0
                return $script:fakeRegQueryOutput
            }
            if ($script:fakeRegFailuresRemaining -eq -1 -or $script:fakeRegFailuresRemaining -gt 0) {
                if ($script:fakeRegFailuresRemaining -gt 0) { $script:fakeRegFailuresRemaining-- }
                $global:LASTEXITCODE = 1
                'ERROR: The parameter is incorrect.'
            }
            else {
                $global:LASTEXITCODE = 0
                'The operation completed successfully.'
            }
        }
    }

    AfterAll {
        Remove-Item function:reg.exe -ErrorAction SilentlyContinue
    }

    It 'loads ClientBase first so Common wins Write-Step and StrictMode Latest' {
        # ClientBase defines Write-Step ("  -> ") and sets StrictMode 2.0;
        # loading it before Common keeps the build log format ("==> ") and
        # the dispatch under Latest. Round 15: it was never loaded at all.
        $script:CleanScriptText | Should -Match "'ClientBase', 'Common'"
    }

    It 'defines the WimBoot transplant and the boot-critical guard in ClientBase.ps1' {
        $libText = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src/build/lib/ClientBase.ps1') -Raw
        $libText | Should -Match 'function Enable-WimBootStack'
        $libText | Should -Match 'function Test-BootCriticalFiles'
        $libText | Should -Match 'function Assert-BootCritical'
        # The guard's manifest must cover the WIM boot stack itself.
        $libText | Should -Match 'Windows\\System32\\drivers\\wimfsf\.sys'
        $libText | Should -Match 'Windows\\System32\\drivers\\fbwf\.sys'
        $libText | Should -Match "'WimFsf', 'FBWF', 'FltMgr', 'Ramdisk'"
    }

    It 'runs the WimBoot transplant after the registry step and before capture, and guards before capture' {
        $dispatch = ($script:CleanScriptText -split '# Dispatch')[1]
        $dispatch.IndexOf('Invoke-CleanWimBootStep') | Should -BeGreaterThan $dispatch.IndexOf('Invoke-CleanRegistryStep')
        $dispatch.IndexOf('Invoke-CleanWimBootStep') | Should -BeLessThan $dispatch.IndexOf('Invoke-CleanCaptureStep')
        $dispatch.IndexOf('Assert-BootCritical') | Should -BeGreaterThan $dispatch.IndexOf('Invoke-CleanWimBootStep')
        $dispatch.IndexOf('Assert-BootCritical') | Should -BeLessThan $dispatch.IndexOf('Invoke-CleanCaptureStep')
    }

    It 'transplants from the stock install-media boot.wim, not from Ramos' {
        $script:CleanScriptText | Should -Match 'Invoke-CleanWimBootStep -StagingDir \$paths\.Staging -PeDonorWim \$base\.BootWim'
        # The donor is the stock boot.wim the base step extracts from the
        # UUP ISO; Ramos is a comparison reference only, never a source.
        $script:CleanScriptText | Should -Not -Match 'PeDonorWim.*[Rr]amos'
    }

    It 'Test-BootCriticalFiles reports wimfsf.sys and fbwf.sys missing on an empty image root' {
        $root = Join-Path $script:TempRoot ("micpe-wimboot-empty-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $root 'Windows/System32/drivers') -Force | Out-Null
        try {
            $r = Test-BootCriticalFiles -ImageRoot $root
            $r.IsBootable | Should -Be $false
            $r.Missing | Should -Contain 'Windows\System32\drivers\wimfsf.sys'
            $r.Missing | Should -Contain 'Windows\System32\drivers\fbwf.sys'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Assert-BootCritical throws on an image root without the WIM boot stack' {
        $root = Join-Path $script:TempRoot ("micpe-wimboot-nostack-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $root 'Windows/System32/drivers') -Force | Out-Null
        try {
            { Assert-BootCritical -ImageRoot $root } | Should -Throw '*not bootable*'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Resolve-CleanDriverImagePath handles every ImagePath spelling (round 16 guard)' {
        $root = Join-Path $script:TempRoot ("micpe-driverpath-{0}" -f [guid]::NewGuid())
        # Round 18: the remainder is relative to the Windows directory
        # under the staging root, so every spelling resolves under
        # Windows\... -- the old expectations (no Windows\) were the
        # wrong-path bug that killed run 45628441308 with 28 EC=3 +
        # 83 non-critical false positives.
        Resolve-CleanDriverImagePath -ImagePath 'system32\drivers\filecrypt.sys' -ServiceName 'FileCrypt' -ImageRoot $root |
            Should -Be (Join-Path $root 'Windows\system32\drivers\filecrypt.sys')
        Resolve-CleanDriverImagePath -ImagePath '\SystemRoot\system32\drivers\filecrypt.sys' -ServiceName 'FileCrypt' -ImageRoot $root |
            Should -Be (Join-Path $root 'Windows\system32\drivers\filecrypt.sys')
        Resolve-CleanDriverImagePath -ImagePath '%SystemRoot%\System32\drivers\filecrypt.sys' -ServiceName 'FileCrypt' -ImageRoot $root |
            Should -Be (Join-Path $root 'Windows\System32\drivers\filecrypt.sys')
        Resolve-CleanDriverImagePath -ImagePath 'System32\DriverStore\FileRepository\basicrender.inf_amd64_x\BasicRender.sys' -ServiceName 'BasicRender' -ImageRoot $root |
            Should -Be (Join-Path $root 'Windows\System32\DriverStore\FileRepository\basicrender.inf_amd64_x\BasicRender.sys')
        Resolve-CleanDriverImagePath -ImagePath '\??\C:\Windows\System32\drivers\disk.sys' -ServiceName 'disk' -ImageRoot $root |
            Should -Be (Join-Path $root 'Windows\System32\drivers\disk.sys')
        Resolve-CleanDriverImagePath -ImagePath 'C:\Windows\System32\drivers\disk.sys' -ServiceName 'disk' -ImageRoot $root |
            Should -Be (Join-Path $root 'Windows\System32\drivers\disk.sys')
        # No ImagePath defaults to System32\drivers\<ServiceName>.sys.
        Resolve-CleanDriverImagePath -ImagePath $null -ServiceName 'CimFS' -ImageRoot $root |
            Should -Be (Join-Path $root 'Windows\System32\drivers\CimFS.sys')
        Resolve-CleanDriverImagePath -ImagePath '' -ServiceName 'CimFS' -ImageRoot $root |
            Should -Be (Join-Path $root 'Windows\System32\drivers\CimFS.sys')
    }

    It 'the guard finds drivers under a staging root and still catches a truly missing EC=3 driver (round 18 guard fix)' {
        # Round 18 regression: production calls the guard with
        # -ImageRoot $paths.Staging, whose files live under
        # Windows\System32\drivers\, not directly under the root.
        # The old resolver dropped the Windows\ segment, so every
        # driver looked missing (run 45628441308). The file must sit
        # exactly where the ImagePath resolves: the test host (Linux)
        # is case-sensitive, so 'system32' in the ImagePath and
        # 'System32' in the fixture path are different directories
        # there (on Windows they are the same).
        $root = Join-Path $script:TempRoot ("micpe-stagingroot-{0}" -f [guid]::NewGuid())
        $fltMgrPath = Join-Path $root 'Windows/system32/drivers/fltmgr.sys'
        New-Item -ItemType Directory -Path (Split-Path -Parent $fltMgrPath) -Force | Out-Null
        Set-Content -LiteralPath $fltMgrPath -Value 'FAKE' -NoNewline
        try {
            # The resolved path must be the staging-root file that
            # actually exists -- not a path one level too high.
            Test-Path -LiteralPath $fltMgrPath | Should -Be $true
            Resolve-CleanDriverImagePath -ImagePath 'system32\drivers\fltmgr.sys' -ServiceName 'FltMgr' -ImageRoot $root |
                Should -Be $fltMgrPath
            $services = @(
                [pscustomobject]@{ Name = 'FltMgr'; Start = 0; ErrorControl = 3; Type = 2; ImagePath = 'system32\drivers\fltmgr.sys' }
                [pscustomobject]@{ Name = 'FileCrypt'; Start = 1; ErrorControl = 3; Type = 2; ImagePath = 'system32\drivers\filecrypt.sys' }
            )
            # Present EC=3 driver: no false positive; genuinely
            # missing EC=3 driver: still caught.
            $r = Test-CleanCriticalDriverFiles -ImageRoot $root -Services $services
            $r.CriticalMissing | Should -Be @('FileCrypt')
            # Remove the file: the guard must now flag FltMgr too,
            # or the fix turned the guard into a no-op.
            Remove-Item -LiteralPath $fltMgrPath -Force
            $r2 = Test-CleanCriticalDriverFiles -ImageRoot $root -Services $services
            $r2.CriticalMissing | Should -Contain 'FltMgr'
            $r2.CriticalMissing | Should -Contain 'FileCrypt'
            $r2.CriticalMissing.Count | Should -Be 2
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Test-CleanCriticalDriverFiles flags a missing ErrorControl=3 driver and only warns on the rest (round 16 guard)' {
        # Round 16: FileCrypt (Start=1, Type=2, ErrorControl=3, file
        # missing) is a guaranteed 0x5A; the same missing file at
        # ErrorControl=1, at Start=3, or on a Win32 service (Type=32)
        # must not fail the guard.
        $root = Join-Path $script:TempRoot ("micpe-critdrv-{0}" -f [guid]::NewGuid())
        # The present file must sit exactly where the ImagePath resolves:
        # the test host (Linux) is case-sensitive, so 'system32' in the
        # ImagePath and 'System32' in the fixture path are different
        # directories there (on Windows they are the same).
        $fltMgrPath = Resolve-CleanDriverImagePath -ImagePath 'system32\drivers\fltmgr.sys' -ServiceName 'FltMgr' -ImageRoot $root
        New-Item -ItemType Directory -Path (Split-Path -Parent $fltMgrPath) -Force | Out-Null
        Set-Content -LiteralPath $fltMgrPath -Value 'FAKE' -NoNewline
        try {
            $services = @(
                [pscustomobject]@{ Name = 'FileCrypt'; Start = 1; ErrorControl = 3; Type = 2; ImagePath = 'system32\drivers\filecrypt.sys' }
                [pscustomobject]@{ Name = 'FltMgr'; Start = 0; ErrorControl = 3; Type = 2; ImagePath = 'system32\drivers\fltmgr.sys' }
                [pscustomobject]@{ Name = 'CimFS'; Start = 1; ErrorControl = 1; Type = 2; ImagePath = $null }
                [pscustomobject]@{ Name = 'BasicRender'; Start = 1; ErrorControl = 0; Type = 1; ImagePath = 'System32\DriverStore\FileRepository\basicrender.inf_amd64_x\BasicRender.sys' }
                [pscustomobject]@{ Name = 'ManualSvc'; Start = 3; ErrorControl = 3; Type = 2; ImagePath = 'system32\drivers\manualsvc.sys' }
                [pscustomobject]@{ Name = 'Win32Svc'; Start = 1; ErrorControl = 3; Type = 32; ImagePath = 'System32\svchost.exe -k LocalService' }
            )
            $r = Test-CleanCriticalDriverFiles -ImageRoot $root -Services $services
            $r.CriticalMissing | Should -Be @('FileCrypt')
            $r.NonCriticalMissing | Should -Contain 'CimFS'
            $r.NonCriticalMissing | Should -Contain 'BasicRender'
            $r.NonCriticalMissing.Count | Should -Be 2
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Test-BootCriticalFiles runs the critical-driver guard on the mounted hive (round 16)' {
        # The hive enumeration itself needs Windows (reg.exe load), so
        # this is a wiring assertion: the guard call must sit inside
        # Test-BootCriticalFiles, after the required-services check.
        $libText = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src/build/lib/ClientBase.ps1') -Raw
        $guard = ($libText -split 'function Test-BootCriticalFiles')[1] -split 'function Assert-BootCritical' | Select-Object -First 1
        $guard | Should -Match 'Test-CleanCriticalDriverFiles'
        $guard | Should -Match 'CriticalMissing'
        $guard | Should -Match 'ErrorControl=3'
    }

    It 'enables kernel debugging over kdnet on the default boot entry before packaging the ISO (round 34)' {
        # Round 34: the serial transport drops the moment kd.exe hits
        # the initial breakpoint (identical on the pipe and on TCP),
        # so the BCD now carries kdnet settings instead of the serial
        # ones (round 16's COM1/115200 wiring is history). The NIC
        # side is verified: QEMU's default NIC is the Intel 82540EM
        # (8086:100e) at PCI 00:03.0, on Microsoft's kdnet supported
        # list, and kdnet.dll + kdnic.sys are in the image.
        $script:CleanScriptText | Should -Match 'function Set-CleanBcdKernelDebug'
        $script:CleanScriptText | Should -Match "debug on"
        $script:CleanScriptText | Should -Match 'dbgsettings net hostip:'
        $script:CleanScriptText | Should -Match 'port:'
        $script:CleanScriptText | Should -Match 'key:'
        $script:CleanScriptText | Should -Match 'busparams'
        $script:CleanScriptText | Should -Not -Match 'dbgsettings serial debugport:1 baudrate:115200'
        $isoStep = ($script:CleanScriptText -split 'function Invoke-CleanIsoStep')[1] -split '# Dispatch' | Select-Object -First 1
        $isoStep | Should -Match 'Set-CleanBcdKernelDebug'
        $isoStep.IndexOf('Set-CleanBcdKernelDebug') | Should -BeLessThan $isoStep.IndexOf('New-MicpeIso')
    }

    It 'enables the bootlog on the default boot entry (round 26)' {
        # Round 26: ntbtlog.txt lands on the WIM RAM disk and vanishes
        # when QEMU exits (the round 16 reason for rejecting it), but
        # the ELF scan reads it out of the guest-memory dump taken
        # while the guest is halted on the blue screen, so the file's
        # bytes in RAM are enough. The bootlog line is set and
        # asserted in the same function as the kernel-debug lines.
        $bcdFn = ($script:CleanScriptText -split 'function Set-CleanBcdKernelDebug')[1] -split 'function Invoke-CleanIsoStep' | Select-Object -First 1
        $bcdFn | Should -Match "bootlog Yes"
        $bcdFn | Should -Match '\^bootlog\\s\+Yes'
        $bcdFn.IndexOf("bootlog Yes") | Should -BeLessThan $bcdFn.IndexOf("BCD bootlog: bootlog not confirmed")
    }

    It 'Get-CleanRegistryValue returns $null for a missing value instead of throwing (round 17 guard fix)' {
        # Round 16 build died in Test-BootCriticalFiles with "The
        # property 'Start' cannot be found on this object": 43 of the
        # 679 r91 service keys have no Start value, and a direct
        # $props.Start read throws under StrictMode 2.0/Latest.
        $props = [pscustomobject]@{ Type = 1; ErrorControl = 1 }
        Get-CleanRegistryValue -Properties $props -Name 'Start' | Should -BeNullOrEmpty
        Get-CleanRegistryValue -Properties $props -Name 'Type' | Should -Be 1
        $propsWithStart = [pscustomobject]@{ Start = 0; Type = 2 }
        Get-CleanRegistryValue -Properties $propsWithStart -Name 'Start' | Should -Be 0
    }

    It 'a direct property read throws under StrictMode, pinning the round 16 crash mechanism (round 17 guard fix)' {
        # Proves the mechanism, not just the helper: under StrictMode
        # 2.0 the same read that killed the round 16 build throws the
        # exact error from run 45616930244. Scoped to a child
        # scriptblock so the StrictMode setting cannot leak into the
        # rest of the test session.
        $props = [pscustomobject]@{ Type = 1 }
        $threw = $false
        $errMsg = ''
        try {
            & { Set-StrictMode -Version 2.0; $props.Start } | Out-Null
        }
        catch {
            $threw = $true
            $errMsg = $_.Exception.Message
        }
        $threw | Should -Be $true
        $errMsg | Should -Match "The property 'Start' cannot be found"
    }

    It 'Test-CleanCriticalDriverFiles skips a service with no Start and still flags a missing EC=3 driver (round 17 guard fix)' {
        # Round 17: the r91 hive has 43 service keys with no Start
        # value (perf counters, .NET providers, Winsock, ...). The
        # guard must skip them, not crash -- and must still catch a
        # real EC=3 hole like FileCrypt, or the guard is a no-op.
        $root = Join-Path $script:TempRoot ("micpe-nostart-{0}" -f [guid]::NewGuid())
        try {
            $services = @(
                [pscustomobject]@{ Name = '.NET CLR Data'; Start = $null; ErrorControl = $null; Type = $null; ImagePath = $null }
                [pscustomobject]@{ Name = 'Winsock'; Start = $null; ErrorControl = $null; Type = $null; ImagePath = $null }
                [pscustomobject]@{ Name = 'FileCrypt'; Start = 1; ErrorControl = 3; Type = 2; ImagePath = 'system32\drivers\filecrypt.sys' }
            )
            $r = Test-CleanCriticalDriverFiles -ImageRoot $root -Services $services
            $r.CriticalMissing | Should -Be @('FileCrypt')
            $r.NonCriticalMissing.Count | Should -Be 0
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Test-BootCriticalFiles reads hive service values through reg.exe, never the provider (round 20 guard fix)' {
        # Round 19: the guard enumerated the hive with Get-ChildItem +
        # Get-ItemProperty, the provider kept an open handle, and the
        # guard's own `reg unload` failed 10/10 with Access is denied
        # (run 45656051010). Round 20 reads the Services tree with one
        # `reg.exe query /s` call instead. The hive enumeration itself
        # needs Windows (reg.exe load), so this is a wiring assertion:
        # no provider access to the mounted hive may remain in the
        # guard -- no HKLM:\ paths, no Get-ChildItem, no
        # Get-ItemProperty -- and the services must come from
        # Get-CleanServicesViaRegQuery. (Round 17 pinned
        # Get-CleanRegistryValue here; the provider read it wrapped is
        # what round 20 removes. The helper itself stays, tested.)
        $libText = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src/build/lib/ClientBase.ps1') -Raw
        $enum = ($libText -split 'function Test-BootCriticalFiles')[1] -split 'function Assert-BootCritical' | Select-Object -First 1
        $enum | Should -Match 'Get-CleanServicesViaRegQuery'
        $enum | Should -Not -Match 'HKLM:\\'
        $enum | Should -Not -Match 'Get-ChildItem'
        $enum | Should -Not -Match 'Get-ItemProperty'
        $enum | Should -Not -Match 'Get-CleanRegistryValue'
    }

    It 'Assert-CleanRegistry prints every disabled-service and LowerFilters read-back value (round 17 evidence)' {
        # Round 16's log had no line at all mentioning FileCrypt or
        # LowerFilters, so the landing could not be confirmed.
        # Assert-ReadBack is silent on success, so each read-back
        # must print its actual value.
        $registryFn = ($script:CleanScriptText -split 'function Assert-CleanRegistry')[1] -split 'function Invoke-CleanCaptureStep' | Select-Object -First 1
        # Single quotes: $name must stay literal in the regex, not
        # interpolate to the (empty) test-scope variable.
        $registryFn | Should -Match 'read-back: \$name Start is'
        $registryFn | Should -Match "read-back: Volume LowerFilters is"
    }

    It 'Dismount-OfflineHive retries a failed unload and succeeds when the handle is released (round 19 capture lock)' {
        # Round 18: the guard's SYSTEM unload sits ~10 ms before
        # capture; the old Dismount ignored reg.exe's exit code, so a
        # failed unload (PS provider still holding a handle after
        # enumerating 679 services) was invisible -- the hive stayed
        # mounted, its file stayed locked, and wimlib capture died
        # with error 47/84. The retry must actually retry.
        $hiveFile = Join-Path $script:TempRoot ("micpe-dismount-{0}.hiv" -f [guid]::NewGuid())
        Set-Content -LiteralPath $hiveFile -Value 'FAKE' -NoNewline
        try {
            $script:fakeRegFailuresRemaining = 2
            $script:fakeRegCalls = 0
            Dismount-OfflineHive -Key 'MICPEV_TEST' -HivePath $hiveFile -MaxUnloadAttempts 5 -UnloadRetryDelaySeconds 0 -HiveFreeTimeoutSeconds 0
            $script:fakeRegCalls | Should -Be 3
        }
        finally {
            Remove-Item -LiteralPath $hiveFile -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Dismount-OfflineHive throws loudly when the unload never succeeds (round 19 capture lock)' {
        # A hive that never unloads must fail the build at the unload
        # point with a clear message -- not silently proceed to a
        # capture that dies with error 47/84.
        $script:fakeRegFailuresRemaining = -1
        $script:fakeRegCalls = 0
        { Dismount-OfflineHive -Key 'MICPEV_TEST' -MaxUnloadAttempts 3 -UnloadRetryDelaySeconds 0 } | Should -Throw '*could not unload hive*'
        $script:fakeRegCalls | Should -Be 3
    }

    It 'Test-CleanHiveFileReadable returns $false for a locked file and $true once it is free (round 19 capture lock)' {
        # A still-mounted hive is opened by the kernel with no
        # sharing, so a read open fails; a free file opens. The lock
        # is held by a background job (a real OS lock, not a mock):
        # .NET enforces FileShare on Linux too (verified: an open
        # with FileShare.None makes a Read open throw).
        $hiveFile = Join-Path $script:TempRoot ("micpe-locked-{0}.hiv" -f [guid]::NewGuid())
        Set-Content -LiteralPath $hiveFile -Value 'FAKE' -NoNewline
        $job = $null
        try {
            $job = Start-Job -ScriptBlock {
                param($p)
                $s = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                Start-Sleep -Seconds 4
                $s.Dispose()
            } -ArgumentList $hiveFile
            $lockedBy = (Get-Date).AddSeconds(10)
            while (Test-CleanHiveFileReadable -Path $hiveFile) {
                if ((Get-Date) -ge $lockedBy) { throw 'test setup: the lock job never acquired the file lock' }
                Start-Sleep -Milliseconds 200
            }
            Test-CleanHiveFileReadable -Path $hiveFile | Should -Be $false
            Wait-Job $job | Out-Null
            Test-CleanHiveFileReadable -Path $hiveFile | Should -Be $true
        }
        finally {
            if ($job) { Remove-Job $job -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $hiveFile -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Dismount-OfflineHive waits for a locked hive file after a successful unload (round 19 capture lock)' {
        # The unload itself succeeds (fake reg.exe exits 0), but the
        # file is still locked -- Dismount must wait for it to become
        # readable instead of returning into a capture that cannot
        # open it. The job holds the lock for 4 s; Dismount must take
        # at least 2 s (a return in ~0 s would prove the poll never
        # waited).
        $hiveFile = Join-Path $script:TempRoot ("micpe-locked-wait-{0}.hiv" -f [guid]::NewGuid())
        Set-Content -LiteralPath $hiveFile -Value 'FAKE' -NoNewline
        $job = $null
        try {
            $job = Start-Job -ScriptBlock {
                param($p)
                $s = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                Start-Sleep -Seconds 4
                $s.Dispose()
            } -ArgumentList $hiveFile
            $lockedBy = (Get-Date).AddSeconds(10)
            while (Test-CleanHiveFileReadable -Path $hiveFile) {
                if ((Get-Date) -ge $lockedBy) { throw 'test setup: the lock job never acquired the file lock' }
                Start-Sleep -Milliseconds 200
            }
            $script:fakeRegFailuresRemaining = 0
            $script:fakeRegCalls = 0
            $start = Get-Date
            Dismount-OfflineHive -Key 'MICPEV_TEST' -HivePath $hiveFile -MaxUnloadAttempts 1 -UnloadRetryDelaySeconds 0 -HiveFreeTimeoutSeconds 10
            $elapsed = (Get-Date) - $start
            $elapsed.TotalSeconds | Should -BeGreaterThan 2
            $script:fakeRegCalls | Should -Be 1
            Wait-Job $job | Out-Null
            Test-CleanHiveFileReadable -Path $hiveFile | Should -Be $true
        }
        finally {
            if ($job) { Remove-Job $job -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $hiveFile -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Test-BootCriticalFiles and Enable-WimBootStack pass -HivePath to Dismount-OfflineHive (round 19 capture lock)' {
        # The readability poll after unload only runs when the caller
        # passes the hive file: both finally blocks must pass it, or
        # the guard's SYSTEM -- the last unload before capture -- is
        # never checked.
        $libText = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src/build/lib/ClientBase.ps1') -Raw
        $libText | Should -Match 'Dismount-OfflineHive -Key \$key -HivePath \$systemHive'
        $libText | Should -Match 'Dismount-OfflineHive -Key \$imageKey -HivePath \$imageSystem'
        $libText | Should -Match 'Dismount-OfflineHive -Key \$donorKey -HivePath \$donorSystem'
        $libText | Should -Match 'could not unload hive'
        $dismount = ($libText -split 'function Dismount-OfflineHive')[1] -split 'function Enable-WimBootStack' | Select-Object -First 1
        $dismount | Should -Match '\$r\.ExitCode'
        $dismount | Should -Match 'lastExit -ne 0'
        $dismount | Should -Match 'MaxUnloadAttempts'
    }

    It 'ConvertFrom-CleanServicesRegQuery parses a reg.exe query /s dump into service rows (round 20 guard fix)' {
        # Round 19: the guard enumerated the hive with Get-ChildItem +
        # Get-ItemProperty, the provider kept an open handle, and the
        # guard's own `reg unload` failed 10/10 with Access is denied.
        # Round 20 reads the Services tree with one `reg.exe query /s`
        # call instead. The fixture models the real dump: a service
        # with all four values, one with no values at all (43 of the
        # 679 r91 keys have no Start), a REG_MULTI_SZ whose
        # continuation line must not be mistaken for a value, a nested
        # Parameters block that is not a service, and a name with
        # spaces and dots. The full 679-service real-hive check lives
        # in ~/workspace/micpe-r20-verify/verify_parser.ps1.
        $lines = @(
            'HKEY_LOCAL_MACHINE\MICPEV_TEST\ControlSet001\Services',
            '',
            'HKEY_LOCAL_MACHINE\MICPEV_TEST\ControlSet001\Services\ACPI',
            '    Description    REG_SZ    Microsoft ACPI Driver',
            '    ErrorControl    REG_DWORD    0x3',
            '    Group    REG_SZ    Boot Bus Extender',
            '    ImagePath    REG_EXPAND_SZ    System32\drivers\ACPI.sys',
            '    Start    REG_DWORD    0x0',
            '    Type    REG_DWORD    0x1',
            '',
            'HKEY_LOCAL_MACHINE\MICPEV_TEST\ControlSet001\Services\.NET CLR Data',
            '',
            'HKEY_LOCAL_MACHINE\MICPEV_TEST\ControlSet001\Services\FileCrypt',
            '    DependOnService    REG_MULTI_SZ    FltMgr',
            '    Tcpip',
            '    ErrorControl    REG_DWORD    0x3',
            '    ImagePath    REG_SZ    system32\drivers\filecrypt.sys',
            '    Start    REG_DWORD    0x1',
            '    Type    REG_DWORD    0x2',
            '',
            'HKEY_LOCAL_MACHINE\MICPEV_TEST\ControlSet001\Services\Tcpip',
            '    ErrorControl    REG_DWORD    0x1',
            '    ImagePath    REG_EXPAND_SZ    System32\drivers\tcpip.sys',
            '    Start    REG_DWORD    0x0',
            '    Type    REG_DWORD    0x1',
            '',
            'HKEY_LOCAL_MACHINE\MICPEV_TEST\ControlSet001\Services\Tcpip\Parameters',
            '    DataBasePath    REG_EXPAND_SZ    %SystemRoot%\System32\drivers\etc',
            ''
        )
        $services = ConvertFrom-CleanServicesRegQuery -Lines $lines -ServicesPath 'HKEY_LOCAL_MACHINE\MICPEV_TEST\ControlSet001\Services'
        @($services).Count | Should -Be 4
        $acpi = @($services | Where-Object { $_.Name -eq 'ACPI' })[0]
        $acpi.Start | Should -Be 0
        $acpi.ErrorControl | Should -Be 3
        $acpi.Type | Should -Be 1
        $acpi.ImagePath | Should -Be 'System32\drivers\ACPI.sys'
        $clr = @($services | Where-Object { $_.Name -eq '.NET CLR Data' })[0]
        $clr.Start | Should -BeNullOrEmpty
        $clr.ErrorControl | Should -BeNullOrEmpty
        $clr.Type | Should -BeNullOrEmpty
        $clr.ImagePath | Should -BeNullOrEmpty
        $fc = @($services | Where-Object { $_.Name -eq 'FileCrypt' })[0]
        $fc.Start | Should -Be 1
        $fc.ErrorControl | Should -Be 3
        $fc.Type | Should -Be 2
        $fc.ImagePath | Should -Be 'system32\drivers\filecrypt.sys'
        # The nested Parameters block is not a service, and the
        # DependOnService continuation line never became a value.
        # @() around Where-Object: an empty result is $null, and
        # $null.Count throws under StrictMode.
        @($services | Where-Object { $_.Name -eq 'Parameters' }).Count | Should -Be 0
        @($services | Where-Object { $_.Name -eq 'Tcpip' }).Count | Should -Be 1
    }

    It 'ConvertTo-CleanRegDword converts hex DWORD strings and returns $null for missing or garbage (round 20 guard fix)' {
        ConvertTo-CleanRegDword -Raw '0x0' | Should -Be 0
        ConvertTo-CleanRegDword -Raw '0x3' | Should -Be 3
        ConvertTo-CleanRegDword -Raw '0x4' | Should -Be 4
        ConvertTo-CleanRegDword -Raw $null | Should -BeNullOrEmpty
        ConvertTo-CleanRegDword -Raw '' | Should -BeNullOrEmpty
        ConvertTo-CleanRegDword -Raw 'not-a-number' | Should -BeNullOrEmpty
    }

    It 'Get-CleanServicesViaRegQuery returns the services from one reg.exe query /s call (round 20 guard fix)' {
        # The 2-service count pins the HKLM/HKEY_LOCAL_MACHINE
        # trap: reg.exe takes HKLM in the query but prints
        # HKEY_LOCAL_MACHINE in every output header -- passing the
        # short form to the parser matches nothing and the guard
        # sees zero services.
        $script:fakeRegQueryOutput = @(
            'HKEY_LOCAL_MACHINE\MICPEV_TEST\ControlSet001\Services',
            '',
            'HKEY_LOCAL_MACHINE\MICPEV_TEST\ControlSet001\Services\FltMgr',
            '    ErrorControl    REG_DWORD    0x3',
            '    ImagePath    REG_SZ    system32\drivers\fltmgr.sys',
            '    Start    REG_DWORD    0x0',
            '    Type    REG_DWORD    0x2',
            '',
            'HKEY_LOCAL_MACHINE\MICPEV_TEST\ControlSet001\Services\FileCrypt',
            '    ErrorControl    REG_DWORD    0x3',
            '    ImagePath    REG_SZ    system32\drivers\filecrypt.sys',
            '    Start    REG_DWORD    0x1',
            '    Type    REG_DWORD    0x2',
            ''
        )
        try {
            $script:fakeRegFailuresRemaining = 0
            $script:fakeRegCalls = 0
            $services = Get-CleanServicesViaRegQuery -Key 'MICPEV_TEST'
            # @() around $services: a function returning an empty array
            # unrolls to $null, and $null.Count throws under StrictMode.
            @($services).Count | Should -Be 2
            $script:fakeRegCalls | Should -Be 1
            $fc = @($services | Where-Object { $_.Name -eq 'FileCrypt' })[0]
            $fc.Start | Should -Be 1
            $fc.ErrorControl | Should -Be 3
        }
        finally { $script:fakeRegQueryOutput = $null }
    }

    It 'Get-CleanServicesViaRegQuery returns an empty list when the Services key is absent (round 20 guard fix)' {
        # Same as the old Test-Path guard: a missing Services key means
        # "no services to check", not a crash.
        $script:fakeRegQueryOutput = $null
        $script:fakeRegFailuresRemaining = -1
        try {
            $services = Get-CleanServicesViaRegQuery -Key 'MICPEV_TEST'
            @($services).Count | Should -Be 0
        }
        finally { $script:fakeRegFailuresRemaining = 0 }
    }
}
