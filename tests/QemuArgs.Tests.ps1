BeforeAll {
    . "$PSScriptRoot/../src/ci/Invoke-QemuVerify.ps1" -ParseOnly
    $script:TempRoot = [System.IO.Path]::GetTempPath()
}

Describe 'Get-QemuArgs' {
    BeforeAll {
        $script:args = Get-QemuArgs -Iso 'C:\x\MICPE.iso' -ShareDir 'C:\x\share' -MonitorPort 4444
        $script:joined = $script:args -join ' '
    }

    It 'maps the share directory as a writable fat disk' {
        $script:args | Should -Contain 'file=fat:rw:C:\x\share,format=raw,media=disk,if=ide'
    }

    It 'exposes the monitor on tcp' {
        $script:args | Should -Contain 'tcp:127.0.0.1:4444,server,nowait'
    }

    It 'gives the PE enough memory for a 2.3GB ramdisk' {
        $script:args | Should -Contain '4096'
        $script:args | Should -Contain '-m'
    }

    It 'passes -cpu max so the 25H2 kernel does not triple-fault under TCG' {
        # run 44062469206: the default qemu64 CPU lacks instructions the
        # 25H2 kernel needs, so the guest triple-faults about a minute
        # after the WIM is read (local TCG repro); -cpu max lets the
        # kernel boot and the spinner appear.
        $script:args | Should -Contain '-cpu'
        $script:args | Should -Contain 'max'
    }

    It 'does not require a display' {
        $script:args | Should -Contain 'none'
        $script:args | Should -Contain '-display'
    }

    It 'boots from the CD-ROM' {
        $script:args | Should -Contain '-cdrom'
        $script:args | Should -Contain 'C:\x\MICPE.iso'
        $script:args[$script:args.Count - 1] | Should -Be 'd'
    }

    It 'never reboots or shuts down on its own' {
        $script:args | Should -Contain '-no-reboot'
        $script:args | Should -Contain '-no-shutdown'
    }

    It 'attaches extra data disks as qcow2' {
        $args2 = Get-QemuArgs -Iso 'C:\x\MICPE.iso' -ShareDir 'C:\x\share' `
            -DataDisks @('C:\x\d2.qcow2', 'C:\x\d3.qcow2')
        ($args2 -join ' ') | Should -Match 'C:\\x\\d2\.qcow2,format=qcow2'
        ($args2 -join ' ') | Should -Match 'C:\\x\\d3\.qcow2,format=qcow2'
    }

    It 'attaches the mirror drive as a second vvfat volume when MirrorDir is given (run 44428428849)' {
        # The serial channel is dead, so the local mirror file needs a
        # retrieval path that does not depend on the suspect share: a
        # second independent vvfat volume the probe-mirror companion
        # copies the local file to.
        $args2 = Get-QemuArgs -Iso 'C:\x\MICPE.iso' -ShareDir 'C:\x\share' -MirrorDir 'C:\x\mirror'
        $args2 | Should -Contain 'file=fat:rw:C:\x\mirror,format=raw,media=disk,if=ide'
    }

    It 'attaches the mirror drive after the share drive' {
        $args2 = Get-QemuArgs -Iso 'C:\x\MICPE.iso' -ShareDir 'C:\x\share' -MirrorDir 'C:\x\mirror'
        $joined = $args2 -join ' '
        $joined.IndexOf('file=fat:rw:C:\x\share,') | Should -BeLessThan $joined.IndexOf('file=fat:rw:C:\x\mirror,') -Because 'the mirror must letter after the share'
    }

    It 'does not attach a mirror drive when MirrorDir is empty' {
        ($script:joined) | Should -Not -Match 'file=fat:rw:C:\\x\\mirror'
        @($script:args | Where-Object { $_ -like 'file=fat:rw:*' }).Count | Should -Be 1 -Because 'only the share drive is a vvfat volume without a mirror'
    }

    It 'uses the supplied firmware when given' {
        $args3 = Get-QemuArgs -Iso 'C:\x\a.iso' -ShareDir 'C:\x\s' -FirmwarePath 'C:\x\OVMF.fd'
        $args3 | Should -Contain '-bios'
        $args3 | Should -Contain 'C:\x\OVMF.fd'
    }

    It 'boots split OVMF images from pflash drives when a vars path is given' {
        # -bios rejects the split 3,653,632-byte code file (run 43989280052:
        # "could not load PC BIOS"); QEMU's own firmware descriptor pairs
        # the code with a vars template, so boot from pflash instead.
        $args4 = Get-QemuArgs -Iso 'C:\x\a.iso' -ShareDir 'C:\x\s' `
            -FirmwarePath 'C:\Program Files\qemu\share\edk2-x86_64-code.fd' `
            -FirmwareVarsPath 'C:\x\work\edk2-x86_64-vars.fd'
        $args4 | Should -Not -Contain '-bios'
        $args4 | Should -Contain 'if=pflash,format=raw,unit=0,readonly=on,file=C:\Program Files\qemu\share\edk2-x86_64-code.fd'
        $args4 | Should -Contain 'if=pflash,format=raw,unit=1,file=C:\x\work\edk2-x86_64-vars.fd'
    }

    It 'puts the serial log next to the -D log so the verify upload can collect it' {
        $serialArgs = Get-QemuArgs -Iso 'C:\x\MICPE.iso' -ShareDir 'C:\x\share' -LogPath '/tmp/verify-out/qemu.log'
        $serial = @($serialArgs | Where-Object { $_ -like 'file:*micpe-serial.log*' })
        $serial.Count | Should -Be 1
        $serial[0] | Should -Match 'verify-out'
    }
}

Describe 'ConvertTo-NativeArgumentString' {
    It 'quotes arguments containing spaces and leaves the rest bare' {
        $line = ConvertTo-NativeArgumentString -Arguments @(
            '-m', '4096', '-bios', 'C:\Program Files\qemu\share\edk2-x86_64-code.fd', '-boot', 'd'
        )
        $line | Should -Be '-m 4096 -bios "C:\Program Files\qemu\share\edk2-x86_64-code.fd" -boot d'
    }

    It 'keeps the -bios firmware path as one quoted token (run 43989280052)' {
        # The runner's QEMU lives under C:\Program Files, so the -bios value
        # contains a space; Start-Process split it into two arguments and
        # QEMU died with "Could not open 'Files\qemu\share\...fd'".
        $args = Get-QemuArgs -Iso 'C:\x\a.iso' -ShareDir 'C:\x\s' `
            -FirmwarePath 'C:\Program Files\qemu\share\edk2-x86_64-code.fd'
        $line = ConvertTo-NativeArgumentString -Arguments $args
        $line | Should -Match '-bios "C:\\Program Files\\qemu\\share\\edk2-x86_64-code\.fd"'
        $line | Should -Not -Match '-bios C:\\Program Files'
    }
}

Describe 'ConvertTo-MonitorPath' {
    It 'turns Windows backslashes into forward slashes for the QEMU monitor' {
        ConvertTo-MonitorPath -Path 'D:\a\MIC-PE\verify-out\shots\shot-01.ppm' |
            Should -Be 'D:/a/MIC-PE/verify-out/shots/shot-01.ppm'
    }

    It 'leaves a path without backslashes alone' {
        ConvertTo-MonitorPath -Path 'D:/a/b.ppm' | Should -Be 'D:/a/b.ppm'
    }
}

Describe 'Save-QemuScreenshot wiring' {
    BeforeAll {
        $script:qemuVerify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/ci/Invoke-QemuVerify.ps1') -Raw
    }

    It 'sends screendump paths through the monitor-path conversion' {
        $script:qemuVerify | Should -Match 'ConvertTo-MonitorPath'
        $script:qemuVerify | Should -Match 'screendump'
    }

    It 'takes periodic screenshots while waiting for the probe' {
        $script:qemuVerify | Should -Match 'Save-QemuScreenshot'
        $script:qemuVerify | Should -Match 'AddMinutes\(10\)'
    }

    It 'does not leak monitor replies into the pipeline from Save-QemuScreenshot' {
        # Run 44046530462: the bare Invoke-MonitorCommand call returned the
        # '(qemu) ' reply string into the pipeline, Invoke-QemuVerify's
        # return value became an Object[], and Test-Stage.ps1 threw
        # "The property 'ProbeSeen' cannot be found on this object".
        # The reply must be discarded with $null =.
        Mock Invoke-MonitorCommand { return '(qemu) ' }
        $dir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) "micpe-shots-$(Get-Random)") -Force
        $(Save-QemuScreenshot -Port '4444' -ScreenshotDir $dir.FullName -ShotIndex 1) |
            Should -BeNullOrEmpty
    }

    It 'has no bare Invoke-MonitorCommand statement that could leak a reply' {
        # Every Invoke-MonitorCommand call must assign its return value or
        # discard it with $null =; a bare call leaks the reply string into
        # the caller's output stream (run 44046530462).
        $bare = $script:qemuVerify -split "`n" | Where-Object { $_ -match '^\s*Invoke-MonitorCommand\b' }
        $bare | Should -BeNullOrEmpty
    }

    It 'collects PPM evidence: screendump writes P6 PPM whatever the suffix is' {
        $script:qemuVerify | Should -Match 'shot-\{0:d2\}\.ppm'
        $script:qemuVerify | Should -Not -Match 'shot-\{0:d2\}\.png'
    }

    It 'keeps the PPM file as the uploaded evidence instead of deleting it' {
        $script:qemuVerify | Should -Not -Match 'MICPE_KEEP_PPM'
    }
}

Describe 'Send-QemuBootKey' {
    It 'answers the boot prompt with Enter over the monitor' {
        Mock Invoke-MonitorCommand {}
        Send-QemuBootKey -Port '4444'
        Should -Invoke Invoke-MonitorCommand -Times 1 -Exactly -ParameterFilter {
            $Command -eq 'sendkey ret'
        }
    }

    It 'reads the monitor reply back instead of fire-and-forget' {
        Mock Invoke-MonitorCommand { return '(qemu) ' }
        Send-QemuBootKey -Port '4444'
        Should -Invoke Invoke-MonitorCommand -Times 1 -Exactly -ParameterFilter {
            $ReadResponse -eq $true
        }
    }

    It 'never fails the run when the monitor is unreachable' {
        Mock Invoke-MonitorCommand { throw 'no monitor' }
        { Send-QemuBootKey -Port '4444' } | Should -Not -Throw
    }

    It 'never fails the run when the monitor rejects the key' {
        Mock Invoke-MonitorCommand { return 'Error: invalid key' }
        { Send-QemuBootKey -Port '4444' } | Should -Not -Throw
    }
}

Describe 'Save-QemuBlockInfo' {
    It 'asks the monitor for the attached block devices' {
        Mock Invoke-MonitorCommand {}
        Save-QemuBlockInfo -Port '4444'
        Should -Invoke Invoke-MonitorCommand -Times 1 -Exactly -ParameterFilter {
            $Command -eq 'info block'
        }
    }

    It 'reads the monitor reply back instead of fire-and-forget' {
        Mock Invoke-MonitorCommand { return '(qemu) ' }
        Save-QemuBlockInfo -Port '4444'
        Should -Invoke Invoke-MonitorCommand -Times 1 -Exactly -ParameterFilter {
            $ReadResponse -eq $true
        }
    }

    It 'never fails the run when the monitor is unreachable' {
        Mock Invoke-MonitorCommand { throw 'no monitor' }
        { Save-QemuBlockInfo -Port '4444' } | Should -Not -Throw
    }

    It 'never fails the run when the monitor rejects the query' {
        Mock Invoke-MonitorCommand { return 'Error: unknown command' }
        { Save-QemuBlockInfo -Port '4444' } | Should -Not -Throw
    }
}

Describe 'Invoke-QemuVerify block info (run 47)' {
    BeforeAll {
        $script:qemuVerify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/ci/Invoke-QemuVerify.ps1') -Raw
    }

    It 'queries the attached block devices once, right after QEMU starts' {
        # Run 46: the guest enumerates only C/D/X although the harness
        # attaches a second vvfat volume. The probe reports truthfully,
        # so the gap is between QEMU and the guest — log what QEMU
        # actually attached before the guest has any chance to enumerate.
        $script:qemuVerify | Should -Match 'Save-QemuBlockInfo'
        $script:qemuVerify | Should -Match "'info block'"
        $start = $script:qemuVerify.IndexOf('Start-Process -FilePath $QemuPath')
        $call = $script:qemuVerify.IndexOf('Save-QemuBlockInfo -Port $MonitorPort')
        $start | Should -BeGreaterThan -1 -Because 'QEMU must be started before its block devices can be queried'
        $call | Should -BeGreaterThan $start -Because 'the query runs after QEMU starts'
        $deadline = $script:qemuVerify.IndexOf('$deadline = (Get-Date).AddMinutes($TimeoutMin)')
        $call | Should -BeLessThan $deadline -Because 'the query runs before the verify loop starts'
    }
}

Describe 'Find-OvmfCode' {
    BeforeAll {
        $script:fakeQemuDir = Join-Path ([System.IO.Path]::GetTempPath()) "qemu-fake-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:fakeQemuDir -Force | Out-Null
        $script:fakeQemu = Join-Path $script:fakeQemuDir 'qemu-system-x86_64.exe'
        New-Item -ItemType File -Path $script:fakeQemu -Force | Out-Null
    }

    It 'returns null when no OVMF file is anywhere near the QEMU install' {
        Find-OvmfCode -QemuPath $script:fakeQemu | Should -BeNullOrEmpty
    }

    It 'finds OVMF_CODE.fd under the share directory' {
        $shareDir = Join-Path $script:fakeQemuDir 'share'
        New-Item -ItemType Directory -Path $shareDir -Force | Out-Null
        $ovmf = Join-Path $shareDir 'OVMF_CODE.fd'
        New-Item -ItemType File -Path $ovmf -Force | Out-Null
        Find-OvmfCode -QemuPath $script:fakeQemu | Should -Be $ovmf
    }

    It 'finds edk2-x86_64-code.fd under the share directory' {
        # QEMU renamed its bundled UEFI firmware from OVMF_CODE.fd to
        # edk2-x86_64-code.fd in 9.0; the runner's QEMU 11.1.0 ships only
        # the new name (verified against the official 11.1.0 installer,
        # SHA-512 matched). A fresh fake install is used here because the
        # shared one above already has an OVMF_CODE.fd in it.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "qemu-edk2-$(Get-Random)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $exe = Join-Path $dir 'qemu-system-x86_64.exe'
        New-Item -ItemType File -Path $exe -Force | Out-Null
        $shareDir = Join-Path $dir 'share'
        New-Item -ItemType Directory -Path $shareDir -Force | Out-Null
        $edk2 = Join-Path $shareDir 'edk2-x86_64-code.fd'
        New-Item -ItemType File -Path $edk2 -Force | Out-Null
        Find-OvmfCode -QemuPath $exe | Should -Be $edk2
    }

    It 'prefers OVMF_CODE.fd when both names are present' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "qemu-both-$(Get-Random)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $exe = Join-Path $dir 'qemu-system-x86_64.exe'
        New-Item -ItemType File -Path $exe -Force | Out-Null
        $shareDir = Join-Path $dir 'share'
        New-Item -ItemType Directory -Path $shareDir -Force | Out-Null
        $ovmf = Join-Path $shareDir 'OVMF_CODE.fd'
        New-Item -ItemType File -Path $ovmf -Force | Out-Null
        $edk2 = Join-Path $shareDir 'edk2-x86_64-code.fd'
        New-Item -ItemType File -Path $edk2 -Force | Out-Null
        Find-OvmfCode -QemuPath $exe | Should -Be $ovmf
    }

    It 'does not mistake the secure-code variant for bootable firmware' {
        # edk2-x86_64-secure-code.fd only runs on q35 with SMM; the
        # verifier uses the default i440fx machine, so it must not count.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "qemu-secure-$(Get-Random)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $exe = Join-Path $dir 'qemu-system-x86_64.exe'
        New-Item -ItemType File -Path $exe -Force | Out-Null
        $shareDir = Join-Path $dir 'share'
        New-Item -ItemType Directory -Path $shareDir -Force | Out-Null
        $secure = Join-Path $shareDir 'edk2-x86_64-secure-code.fd'
        New-Item -ItemType File -Path $secure -Force | Out-Null
        Find-OvmfCode -QemuPath $exe | Should -BeNullOrEmpty
    }

    It 'finds edk2-x86_64-code.fd through the recursive fallback' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "qemu-deep-$(Get-Random)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $exe = Join-Path $dir 'qemu-system-x86_64.exe'
        New-Item -ItemType File -Path $exe -Force | Out-Null
        $deepDir = Join-Path (Join-Path $dir 'share') 'firmware'
        New-Item -ItemType Directory -Path $deepDir -Force | Out-Null
        $edk2 = Join-Path $deepDir 'edk2-x86_64-code.fd'
        New-Item -ItemType File -Path $edk2 -Force | Out-Null
        Find-OvmfCode -QemuPath $exe | Should -Be $edk2
    }
}

Describe 'Find-OvmfVars' {
    It 'finds the i386 vars template next to the x86_64 code file' {
        # QEMU's firmware descriptor 60-edk2-x86_64.json pairs
        # edk2-x86_64-code.fd with edk2-i386-vars.fd as its NVRAM template.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "qemu-vars-$(Get-Random)"
        $shareDir = Join-Path $dir 'share'
        New-Item -ItemType Directory -Path $shareDir -Force | Out-Null
        $code = Join-Path $shareDir 'edk2-x86_64-code.fd'
        New-Item -ItemType File -Path $code -Force | Out-Null
        $vars = Join-Path $shareDir 'edk2-i386-vars.fd'
        New-Item -ItemType File -Path $vars -Force | Out-Null
        Find-OvmfVars -CodePath $code | Should -Be $vars
    }

    It 'returns null when no vars template sits next to the code file' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "qemu-novars-$(Get-Random)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $code = Join-Path $dir 'edk2-x86_64-code.fd'
        New-Item -ItemType File -Path $code -Force | Out-Null
        Find-OvmfVars -CodePath $code | Should -BeNullOrEmpty
    }
}

Describe 'Find-CleanOvmfVars' {
    BeforeAll {
        # The clean verifier launches QEMU on load, so dot-source it with
        # -ParseOnly (same pattern as Invoke-QemuVerify.ps1). The
        # mandatory paths must exist: the top-level Assert-PathExists
        # runs even under -ParseOnly, so hand it real temp files.
        $script:cleanDir = Join-Path ([System.IO.Path]::GetTempPath()) "clean-ovmf-$(Get-Random)"
        $script:cleanShare = Join-Path $script:cleanDir 'share'
        New-Item -ItemType Directory -Path $script:cleanShare -Force | Out-Null
        $script:cleanIso = Join-Path $script:cleanDir 'test.iso'
        New-Item -ItemType File -Path $script:cleanIso -Force | Out-Null
        $script:cleanWork = Join-Path $script:cleanDir 'work'
        New-Item -ItemType Directory -Path $script:cleanWork -Force | Out-Null
        $script:cleanCode = Join-Path $script:cleanShare 'edk2-x86_64-code.fd'
        [System.IO.File]::WriteAllBytes($script:cleanCode, (New-Object byte[] 3653632))
        . "$PSScriptRoot/../src/ci/Invoke-CleanQemuVerify.ps1" -ParseOnly -IsoPath $script:cleanIso -OvmfPath $script:cleanCode -WorkDir $script:cleanWork
    }

    AfterAll {
        Remove-Item -LiteralPath $script:cleanDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'prefers the i386 vars template next to the x86_64 code file, even when the 64 MB aarch64 template sorts first' {
        # Run 45416116043: the old first-*vars*.fd-by-name pick took
        # edk2-aarch64-vars.fd (64 MB); code + vars then exceeded QEMU's
        # 8 MiB firmware cap and QEMU refused to start with "combined
        # size of system firmware exceeds 8388608 bytes". QEMU's firmware
        # descriptor 60-edk2-x86_64.json pairs edk2-x86_64-code.fd with
        # edk2-i386-vars.fd (540,672 bytes; combined 4 MiB exactly).
        # The files are sparse (SetLength): they report their real size
        # but take no disk -- /tmp is a 512 MB tmpfs and a real 64 MB
        # vars file per run fills it.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "clean-ovmf-aarch64-$(Get-Random)"
        try {
            $shareDir = Join-Path $dir 'share'
            New-Item -ItemType Directory -Path $shareDir -Force | Out-Null
            $code = Join-Path $shareDir 'edk2-x86_64-code.fd'
            $fs = [System.IO.File]::Create($code); $fs.SetLength(3653632); $fs.Close()
            $vars = Join-Path $shareDir 'edk2-i386-vars.fd'
            $fs = [System.IO.File]::Create($vars); $fs.SetLength(540672); $fs.Close()
            $aarch64 = Join-Path $shareDir 'edk2-aarch64-vars.fd'
            $fs = [System.IO.File]::Create($aarch64); $fs.SetLength(67108864); $fs.Close()
            Find-CleanOvmfVars -CodePath $code | Should -Be $vars
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'falls back to OVMF_VARS.fd when the i386 template is absent' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "clean-ovmf-fallback-$(Get-Random)"
        try {
            $shareDir = Join-Path $dir 'share'
            New-Item -ItemType Directory -Path $shareDir -Force | Out-Null
            $code = Join-Path $shareDir 'edk2-x86_64-code.fd'
            $fs = [System.IO.File]::Create($code); $fs.SetLength(3653632); $fs.Close()
            $vars = Join-Path $shareDir 'OVMF_VARS.fd'
            $fs = [System.IO.File]::Create($vars); $fs.SetLength(540672); $fs.Close()
            Find-CleanOvmfVars -CodePath $code | Should -Be $vars
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'refuses a code + vars pair over the 8 MiB firmware cap instead of letting QEMU die on it' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "clean-ovmf-oversize-$(Get-Random)"
        try {
            $shareDir = Join-Path $dir 'share'
            New-Item -ItemType Directory -Path $shareDir -Force | Out-Null
            $code = Join-Path $shareDir 'edk2-x86_64-code.fd'
            $fs = [System.IO.File]::Create($code); $fs.SetLength(3653632); $fs.Close()
            $vars = Join-Path $shareDir 'edk2-aarch64-vars.fd'
            $fs = [System.IO.File]::Create($vars); $fs.SetLength(67108864); $fs.Close()
            { Find-CleanOvmfVars -CodePath $code } | Should -Throw '*exceed the 8 MiB*'
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws when no vars template sits next to the code file' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "clean-ovmf-novars-$(Get-Random)"
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $code = Join-Path $dir 'edk2-x86_64-code.fd'
            $fs = [System.IO.File]::Create($code); $fs.SetLength(3653632); $fs.Close()
            { Find-CleanOvmfVars -CodePath $code } | Should -Throw '*no OVMF vars template*'
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Format-MonitorReply' {
    It 'strips ANSI colour and cursor escapes from the monitor reply' {
        $reply = "$([char]27)[31;1mQEMU 11.1.0 monitor$([char]27)[0m (qemu) "
        Format-MonitorReply -Reply $reply | Should -Be 'QEMU 11.1.0 monitor (qemu)'
    }

    It 'collapses newlines and repeated whitespace' {
        Format-MonitorReply -Reply "sendkey ret`n`n  (qemu)   (qemu)" |
            Should -Be 'sendkey ret (qemu) (qemu)'
    }

    It 'truncates a long reply instead of flooding the build log' {
        $long = 'x' * 250
        $out = Format-MonitorReply -Reply $long
        $out.Length | Should -Be 203
        $out | Should -Match '\.\.\.$'
    }

    It 'returns an empty string for an empty reply' {
        Format-MonitorReply -Reply '' | Should -Be ''
        Format-MonitorReply -Reply $null | Should -Be ''
    }

    It 'keeps the error words Send-QemuBootKey looks for' {
        Format-MonitorReply -Reply "Error: unknown command`n(qemu) " |
            Should -Match 'Error: unknown command'
    }
}

Describe 'Invoke-QemuVerify firmware selection' {
    BeforeAll {
        $script:qemuVerify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/ci/Invoke-QemuVerify.ps1') -Raw
    }

    It 'prefers UEFI boot when OVMF is installed' {
        $script:qemuVerify | Should -Match 'Find-OvmfCode'
        $script:qemuVerify | Should -Match "Firmware = 'auto'"
    }

    It 'fails fast when UEFI is forced but OVMF is missing' {
        $script:qemuVerify | Should -Match 'Firmware=uefi but no OVMF_CODE.fd was found'
    }

    It 'can still force SeaBIOS with the sendkey fallback' {
        $script:qemuVerify | Should -Match "'bios'"
        $script:qemuVerify | Should -Match 'SeaBIOS \(forced\)'
    }

    It 'boots UEFI from pflash with a per-run copy of the vars template' {
        # -bios cannot load the split code image (run 43989280052), so the
        # verifier must resolve the vars template and copy it per run.
        $script:qemuVerify | Should -Match 'Find-OvmfVars'
        $script:qemuVerify | Should -Match 'edk2-x86_64-vars\.fd'
        $script:qemuVerify | Should -Match 'if=pflash,format=raw,unit=0,readonly=on'
        $script:qemuVerify | Should -Match 'if=pflash,format=raw,unit=1'
    }

    It 'fails fast when UEFI is forced but the vars template is missing' {
        $script:qemuVerify | Should -Match 'no OVMF vars template'
    }
}

Describe 'Invoke-QemuVerify mirror drive (run 44428428849)' {
    BeforeAll {
        $script:qemuVerify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/ci/Invoke-QemuVerify.ps1') -Raw
    }

    It 'creates the mirror dir and drops the sentinel before QEMU starts' {
        # The probe finds the mirror drive by this file, not by letter.
        $script:qemuVerify | Should -Match 'Join-Path \$MirrorDir ''micpe-mirror\.txt'''
    }

    It 'passes the mirror dir through to Get-QemuArgs' {
        $script:qemuVerify | Should -Match '-MirrorDir \$MirrorDir'
    }
}

Describe 'Invoke-QemuVerify boot key' {
    BeforeAll {
        $script:qemuVerify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/ci/Invoke-QemuVerify.ps1') -Raw
    }

    It 'sends the boot key every 3 seconds, at most 4 times' {
        # User decision 2026-11-17: the "Press any key" prompt times out
        # after about 10 seconds, so the old every-30-seconds-forever
        # rhythm is replaced by a short burst: 3s apart, 4 presses.
        $script:qemuVerify | Should -Match 'Send-QemuBootKey'
        $script:qemuVerify | Should -Match 'BootKeyDelaySec'
        $script:qemuVerify | Should -Match 'BootKeyIntervalSec = 3'
        $script:qemuVerify | Should -Match 'BootKeyMaxSends = 4'
        $script:qemuVerify | Should -Match 'bootKeysSent -lt \$BootKeyMaxSends'
        $script:qemuVerify | Should -Match 'bootKeysSent'
    }

    It 'brings a screenshot forward after the first keypress for early evidence' {
        $script:qemuVerify | Should -Match 'earlyShotAt'
    }

    It 'returns PPM screenshots, not PNG' {
        $script:qemuVerify | Should -Match "\-Filter '\*\.ppm'"
        $script:qemuVerify | Should -Not -Match "\-Filter '\*\.png'"
    }
}

Describe 'Measure-PpmNonBlackRatio' {
    BeforeAll {
        function New-TestPpm {
            param([int] $Width, [int] $Height, [byte] $R, [byte] $G, [byte] $B, [string] $Path)
            $header = [System.Text.Encoding]::ASCII.GetBytes("P6`n$Width $Height`n255`n")
            $pixels = [byte[]]::new($Width * $Height * 3)
            for ($i = 0; $i -lt $pixels.Length; $i += 3) {
                $pixels[$i] = $R
                $pixels[$i + 1] = $G
                $pixels[$i + 2] = $B
            }
            $all = [byte[]]::new($header.Length + $pixels.Length)
            [System.Array]::Copy($header, 0, $all, 0, $header.Length)
            [System.Array]::Copy($pixels, 0, $all, $header.Length, $pixels.Length)
            [System.IO.File]::WriteAllBytes($Path, $all)
        }
    }

    It 'reads the dimensions from the header' {
        $path = Join-Path $script:TempRoot "ppm-$(Get-Random).ppm"
        New-TestPpm -Width 32 -Height 16 -R 0 -G 0 -B 0 -Path $path
        $image = Read-Ppm -PpmPath $path
        $image.Width | Should -Be 32
        $image.Height | Should -Be 16
    }

    It 'returns 0 for an all-black image' {
        $path = Join-Path $script:TempRoot "black-$(Get-Random).ppm"
        New-TestPpm -Width 64 -Height 64 -R 0 -G 0 -B 0 -Path $path
        Measure-PpmNonBlackRatio -PpmPath $path | Should -Be 0
    }

    It 'returns 1 for an all-white image' {
        $path = Join-Path $script:TempRoot "white-$(Get-Random).ppm"
        New-TestPpm -Width 64 -Height 64 -R 255 -G 255 -B 255 -Path $path
        Measure-PpmNonBlackRatio -PpmPath $path | Should -Be 1
    }

    It 'counts a single lit pixel out of the sample set' {
        $path = Join-Path $script:TempRoot "one-$(Get-Random).ppm"
        New-TestPpm -Width 8 -Height 8 -R 0 -G 0 -B 0 -Path $path
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $headerLen = $bytes.Length - (8 * 8 * 3)
        $bytes[$headerLen] = 255
        [System.IO.File]::WriteAllBytes($path, $bytes)
        (Measure-PpmNonBlackRatio -PpmPath $path -Step 1) | Should -Be (1 / 64)
    }

    It 'rejects a non-PPM file' {
        $path = Join-Path $script:TempRoot "bogus-$(Get-Random).ppm"
        Set-Content -LiteralPath $path -Value 'not a ppm'
        { Read-Ppm -PpmPath $path } | Should -Throw
    }
}

Describe 'Invoke-QemuVerify preconditions' {
    It 'throws when the ISO is missing' {
        { Invoke-QemuVerify -Iso (Join-Path $script:TempRoot 'micpe-absent.iso') -ShareDir $script:TempRoot } |
            Should -Throw '*not found*'
    }
}

Describe 'Test-ProbeComplete' {
    It 'is false for probe text without the done marker' {
        Test-ProbeComplete -Content "boot=1`r`nexplorer=1`r`n" | Should -BeFalse
    }

    It 'is false when boot=1 is present but the probe is still running' {
        # The old loop broke on boot=1 and returned a partial probe: boot=1
        # is the FIRST line probe.cmd writes, minutes before the rest.
        Test-ProbeComplete -Content "boot=1`r`nshare=1`r`nexplorer=1`r`n" | Should -BeFalse
    }

    It 'is true only when probe_done=1 is the last line' {
        Test-ProbeComplete -Content "boot=1`r`nprobe_done=1`r`n" | Should -BeTrue
    }

    It 'is false for empty content and for probe_done=0' {
        Test-ProbeComplete -Content '' | Should -BeFalse
        Test-ProbeComplete -Content "probe_done=0`r`n" | Should -BeFalse
    }

    It 'is true when probe_failed=1 is present (the watchdog ended a stalled probe)' {
        # Run 44285721257: probe_failed ends the wait early, the same way
        # probe_done does. The verdict is still a failure, see
        # Assert-ProbeResult; this only shortens the wait.
        Test-ProbeComplete -Content "boot=1`r`nprobe_failed=1`r`n" | Should -BeTrue
    }

    It 'is false for probe_failed=0' {
        Test-ProbeComplete -Content "boot=1`r`nprobe_failed=0`r`n" | Should -BeFalse
    }
}

Describe 'Test-ScreenshotFrozen' {
    It 'is false when there is no probe file yet (still booting)' {
        Test-ScreenshotFrozen -PreviousHash 'aaa' -CurrentHash 'aaa' -PreviousProbeLength 0 -CurrentProbeLength 0 -ProbeExists $false -ProbeContent '' | Should -BeFalse
    }

    It 'is false on the first screenshot (no previous hash)' {
        Test-ScreenshotFrozen -PreviousHash '' -CurrentHash 'aaa' -PreviousProbeLength -1 -CurrentProbeLength 100 -ProbeExists $true -ProbeContent "boot=1`r`n" | Should -BeFalse
    }

    It 'is false when the screenshots differ' {
        Test-ScreenshotFrozen -PreviousHash 'aaa' -CurrentHash 'bbb' -PreviousProbeLength 100 -CurrentProbeLength 100 -ProbeExists $true -ProbeContent "boot=1`r`nexplorer=1`r`n" | Should -BeFalse
    }

    It 'is false when the probe grew between screenshots' {
        Test-ScreenshotFrozen -PreviousHash 'aaa' -CurrentHash 'aaa' -PreviousProbeLength 100 -CurrentProbeLength 150 -ProbeExists $true -ProbeContent "boot=1`r`nexplorer=1`r`n" | Should -BeFalse
    }

    It 'is true when the screen is frozen and the probe is silent' {
        # Run 44386689307: the guest froze with the screen and the probe
        # both silent, and the harness still waited out the full 45
        # minutes. Two identical shots plus an ungrown probe is a
        # frozen guest, not a slow one.
        Test-ScreenshotFrozen -PreviousHash 'aaa' -CurrentHash 'aaa' -PreviousProbeLength 100 -CurrentProbeLength 100 -ProbeExists $true -ProbeContent "boot=1`r`nexplorer=1`r`n" | Should -BeTrue
    }

    It 'is false during the installer deploy (a long quiet deploy is legitimate)' {
        Test-ScreenshotFrozen -PreviousHash 'aaa' -CurrentHash 'aaa' -PreviousProbeLength 100 -CurrentProbeLength 100 -ProbeExists $true -ProbeContent "boot=1`r`nmark_installer_deploy=20:31:02.39`r`n" | Should -BeFalse
    }

    It 'is false when the probe already completed' {
        Test-ScreenshotFrozen -PreviousHash 'aaa' -CurrentHash 'aaa' -PreviousProbeLength 100 -CurrentProbeLength 100 -ProbeExists $true -ProbeContent "boot=1`r`nprobe_done=1`r`n" | Should -BeFalse
    }

    It 'is false when the watchdog heartbeat grew between screenshots (run 48)' {
        # Run 47: identical screenshots and a share probe that had
        # not grown since the last shot — but the guest was alive and
        # the watchdog was still ticking (quiet=0 the whole run). A
        # growing heartbeat vetoes the frozen verdict.
        Test-ScreenshotFrozen -PreviousHash 'aaa' -CurrentHash 'aaa' -PreviousProbeLength 100 -CurrentProbeLength 100 -ProbeExists $true -ProbeContent "boot=1`r`nexplorer=1`r`n" -PreviousHeartbeatLength 100 -CurrentHeartbeatLength 150 -HeartbeatExists $true | Should -BeFalse
    }

    It 'is true when the screen is frozen, the probe is silent, and the heartbeat is silent too (run 48)' {
        # Run 46, the true freeze: the guest wedged so hard the
        # watchdog died with it, so the heartbeat stops growing as
        # well. All three signals still together means frozen.
        Test-ScreenshotFrozen -PreviousHash 'aaa' -CurrentHash 'aaa' -PreviousProbeLength 100 -CurrentProbeLength 100 -ProbeExists $true -ProbeContent "boot=1`r`nexplorer=1`r`n" -PreviousHeartbeatLength 100 -CurrentHeartbeatLength 100 -HeartbeatExists $true | Should -BeTrue
    }

    It 'falls back to the old behaviour when no heartbeat file exists yet (run 48)' {
        # The watchdog starts mid-run, so early screenshots have no
        # heartbeat file at all — the frozen verdict then rests on
        # the screenshots and the probe alone, as before.
        Test-ScreenshotFrozen -PreviousHash 'aaa' -CurrentHash 'aaa' -PreviousProbeLength 100 -CurrentProbeLength 100 -ProbeExists $true -ProbeContent "boot=1`r`nexplorer=1`r`n" -HeartbeatExists $false | Should -BeTrue
    }
}

Describe 'dot-sourcing the helper' {
    It 'binds the helper param block in the caller scope, resetting same-named variables' {
        # This is the trap that killed runs 43884981629 and 43891758991:
        # Test-Stage.ps1 dot-sources this file for its functions, and the
        # param block silently reset its $Iso to ''. Callers must save and
        # restore any same-named variable around the dot-source.
        $Iso = 'C:\sentinel\MICPE.iso'
        . "$PSScriptRoot/../src/ci/Invoke-QemuVerify.ps1" -ParseOnly
        $Iso | Should -Be ''
    }
}

Describe 'Invoke-QemuVerify sc start second-marker wait (run 54)' {
    BeforeAll {
        $script:qemuVerify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/ci/Invoke-QemuVerify.ps1') -Raw
    }

    It 'Test-ScStartComplete is true only when scstart_done=1 is present' {
        Test-ScStartComplete -Content "probe_done=1`r`nscstart_done=1`r`n" | Should -BeTrue
        Test-ScStartComplete -Content "probe_done=1`r`n" | Should -BeFalse
        Test-ScStartComplete -Content '' | Should -BeFalse
        Test-ScStartComplete -Content $null | Should -BeFalse
    }

    It 'Test-ProbeWaitDone never ends the wait before probe_done is seen' {
        Test-ProbeWaitDone -ShareContent 'probe_done=1' -LocalContent '' -ProbeDoneAt $null | Should -BeFalse
    }

    It 'Test-ProbeWaitDone ends the wait when probe_failed is present' {
        # The watchdog says the probe died — never wait for an
        # experiment that cannot run.
        Test-ProbeWaitDone -ShareContent 'probe_failed=1' -LocalContent '' -ProbeDoneAt (Get-Date) | Should -BeTrue
    }

    It 'Test-ProbeWaitDone ends the wait when scstart_done is seen in either file' {
        Test-ProbeWaitDone -ShareContent 'probe_done=1' -LocalContent "scstart_done=1`r`n" -ProbeDoneAt (Get-Date) | Should -BeTrue
        Test-ProbeWaitDone -ShareContent "probe_done=1`r`nscstart_done=1" -LocalContent '' -ProbeDoneAt (Get-Date) | Should -BeTrue
    }

    It 'Test-ProbeWaitDone keeps waiting while the experiment is still running' {
        Test-ProbeWaitDone -ShareContent 'probe_done=1' -LocalContent '' -ProbeDoneAt (Get-Date) | Should -BeFalse
    }

    It 'Test-ProbeWaitDone ends the wait when the bounded wait after probe_done elapses' {
        Test-ProbeWaitDone -ShareContent 'probe_done=1' -LocalContent '' -ProbeDoneAt (Get-Date).AddSeconds(-200) | Should -BeTrue
    }

    It 'the wait loop records probe_done time and consults Test-ProbeWaitDone before breaking' {
        $script:qemuVerify | Should -Match '\$probeDoneAt = \$null'
        $script:qemuVerify | Should -Match 'Test-ProbeWaitDone -ShareContent \$probe -LocalContent \$probeLocal -ProbeDoneAt \$probeDoneAt'
    }
}

Describe 'Test-CleanScreenshot' {
    BeforeAll {
        # Same -ParseOnly dot-source pattern as Find-CleanOvmfVars: the
        # verifier launches QEMU on load, so hand it real temp files for
        # the mandatory paths (Assert-PathExists runs even under -ParseOnly).
        $script:shotDir = Join-Path ([System.IO.Path]::GetTempPath()) "clean-shots-$(Get-Random)"
        $script:shotShare = Join-Path $script:shotDir 'share'
        New-Item -ItemType Directory -Path $script:shotShare -Force | Out-Null
        $script:shotIso = Join-Path $script:shotDir 'test.iso'
        New-Item -ItemType File -Path $script:shotIso -Force | Out-Null
        $script:shotWork = Join-Path $script:shotDir 'work'
        New-Item -ItemType Directory -Path $script:shotWork -Force | Out-Null
        $script:shotCode = Join-Path $script:shotShare 'edk2-x86_64-code.fd'
        [System.IO.File]::WriteAllBytes($script:shotCode, (New-Object byte[] 3653632))
        . "$PSScriptRoot/../src/ci/Invoke-CleanQemuVerify.ps1" -ParseOnly -IsoPath $script:shotIso -OvmfPath $script:shotCode -WorkDir $script:shotWork
        $script:fixtures = Join-Path $PSScriptRoot 'fixtures'

        # Helper lives in BeforeAll: Pester runs Describe blocks in their
        # own scope, so a function defined in the Describe body is not
        # visible inside It.
        function New-SolidPpm {
            param([int] $Width, [int] $Height, [byte] $R, [byte] $G, [byte] $B)
            $header = [System.Text.Encoding]::ASCII.GetBytes("P6`n$Width $Height`n255`n")
            $raster = [byte[]]::new($Width * $Height * 3)
            for ($i = 0; $i -lt $raster.Length; $i += 3) {
                $raster[$i] = $R; $raster[$i + 1] = $G; $raster[$i + 2] = $B
            }
            $ppm = [byte[]]::new($header.Length + $raster.Length)
            [System.Buffer]::BlockCopy($header, 0, $ppm, 0, $header.Length)
            [System.Buffer]::BlockCopy($raster, 0, $ppm, $header.Length, $raster.Length)
            return $ppm
        }
    }

    AfterAll {
        Remove-Item -LiteralPath $script:shotDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'classifies the real round-10 shot-01 (TianoCore boot screen) as Boot' {
        # Fixture is a 64x40 crop of the real r84 shot-01.png, taken from
        # the top-left corner: pure black, the TianoCore screen. Round 10
        # shot-01..03 were all this screen (the system never got past the
        # firmware boot screen before dying on Recovery).
        $ppm = Join-Path $script:fixtures 'r84-shot-01-boot.ppm'
        $c = Test-CleanScreenshot -Path $ppm
        $c.Classification | Should -Be 'Boot'
        $c.BlackFraction | Should -BeGreaterThan 0.9
        $c.BlueFraction | Should -Be 0
    }

    It 'classifies the real round-10 shot-04 (Windows Recovery screen) as Recovery' {
        # Fixture is a 64x40 crop of the real r84 shot-04.png, taken from
        # the top-left corner: pure Windows Recovery blue (32,103,178).
        # Round 10 shot-04..07 were all this screen (cdrom.sys 0xc0000428);
        # the old count-only gate passed 7 of 7 on exactly this input.
        $ppm = Join-Path $script:fixtures 'r84-shot-04-recovery.ppm'
        $c = Test-CleanScreenshot -Path $ppm
        $c.Classification | Should -Be 'Recovery'
        $c.BlueFraction | Should -BeGreaterThan 0.9
        $c.BlackFraction | Should -Be 0
    }

    It 'classifies a varied desktop-like frame as Other, not Recovery' {
        $ppm = Join-Path $script:fixtures 'synthetic-desktop.ppm'
        $c = Test-CleanScreenshot -Path $ppm
        $c.Classification | Should -Be 'Other'
    }

    It 'classifies a solid BSOD blue (0,120,215) frame as BlueScreen, not Recovery' {
        # The classic bugcheck blue must trip the same gate as the
        # Recovery blue, but must not be reported as Recovery: round 14
        # died on a BSOD (IO1 INITIALIZATION FAILED) and the old code
        # blamed 0xc0000428 for it.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "clean-shots-bsod-$(Get-Random)"
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $ppm = Join-Path $dir 'bsod.ppm'
            [System.IO.File]::WriteAllBytes($ppm, (New-SolidPpm -Width 64 -Height 40 -R 0 -G 120 -B 215))
            $c = Test-CleanScreenshot -Path $ppm
            $c.Classification | Should -Be 'BlueScreen'
            $c.BlueMeanR | Should -Be 0
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'classifies a solid Recovery blue (32,103,178) frame as Recovery' {
        # The Recovery blue has red 32, so the mean-red rule must keep it
        # on the Recovery side of the 16 midpoint.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "clean-shots-rec-$(Get-Random)"
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $ppm = Join-Path $dir 'rec.ppm'
            [System.IO.File]::WriteAllBytes($ppm, (New-SolidPpm -Width 64 -Height 40 -R 32 -G 103 -B 178))
            $c = Test-CleanScreenshot -Path $ppm
            $c.Classification | Should -Be 'Recovery'
            $c.BlueMeanR | Should -Be 32
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'classifies the real round-14 shot-02 (BSOD, IO1 INITIALIZATION FAILED) as BlueScreen' {
        # Fixture is a 64x40 crop of the real r90 shot-02.ppm, taken from
        # the top-left corner: pure BSOD blue as rendered in QEMU
        # (0,61,146), mean red ~1. Round 14 shot-02..07 were all this
        # screen; the old code called it Recovery and blamed 0xc0000428.
        $ppm = Join-Path $script:fixtures 'r90-shot-02-bsod.ppm'
        $c = Test-CleanScreenshot -Path $ppm
        $c.Classification | Should -Be 'BlueScreen'
        $c.BlueFraction | Should -BeGreaterThan 0.9
        $c.BlueMeanR | Should -BeLessThan 16
    }

    It 'does not mistake a dark LogonUI-like background for Recovery' {
        # LogonUI sits on a dark blue gradient (roughly (30,40,80)): blue
        # is present but dark and desaturated, so it must not trip the
        # bright-blue Recovery rule, or every healthy boot would fail.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "clean-shots-logon-$(Get-Random)"
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $ppm = Join-Path $dir 'logon.ppm'
            [System.IO.File]::WriteAllBytes($ppm, (New-SolidPpm -Width 64 -Height 40 -R 30 -G 40 -B 80))
            $c = Test-CleanScreenshot -Path $ppm
            $c.Classification | Should -Be 'Other'
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws on a non-PPM file instead of silently classifying it' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "clean-shots-bad-$(Get-Random)"
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $ppm = Join-Path $dir 'bad.ppm'
            [System.IO.File]::WriteAllText($ppm, 'this is not a PPM file')
            { Test-CleanScreenshot -Path $ppm } | Should -Throw '*not a P6 PPM*'
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws on a truncated PPM raster instead of reading past the buffer' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "clean-shots-trunc-$(Get-Random)"
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $ppm = Join-Path $dir 'trunc.ppm'
            $header = [System.Text.Encoding]::ASCII.GetBytes("P6`n64 40`n255`n")
            [System.IO.File]::WriteAllBytes($ppm, $header)
            { Test-CleanScreenshot -Path $ppm } | Should -Throw '*truncated PPM*'
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'the verifier fails the run when any screenshot is a blue failure screen, and names its kind' {
        $script:cleanVerify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\\src\\ci\\Invoke-CleanQemuVerify.ps1') -Raw
        $script:cleanVerify | Should -Match 'Test-CleanScreenshot -Path'
        $script:cleanVerify | Should -Match "QEMU screen check failed"
        $script:cleanVerify | Should -Match 'bugcheck blue screen'
        $script:cleanVerify | Should -Match 'Windows Recovery screen'
        $script:cleanVerify | Should -Not -Match 'e\.g\. 0xc0000428'
        $script:cleanVerify | Should -Match 'every screenshot is a black screen'
    }
}

Describe 'Round 21 crash-dump capture helpers' {
    BeforeAll {
        # Same dot-source pattern as Find-CleanOvmfVars: the clean
        # verifier launches QEMU on load, so dot-source it with
        # -ParseOnly and hand it real temp files for the mandatory paths.
        $script:capDir = Join-Path ([System.IO.Path]::GetTempPath()) "clean-cap-$(Get-Random)"
        $script:capShare = Join-Path $script:capDir 'share'
        New-Item -ItemType Directory -Path $script:capShare -Force | Out-Null
        $script:capIso = Join-Path $script:capDir 'test.iso'
        New-Item -ItemType File -Path $script:capIso -Force | Out-Null
        $script:capWork = Join-Path $script:capDir 'work'
        New-Item -ItemType Directory -Path $script:capWork -Force | Out-Null
        $script:capCode = Join-Path $script:capShare 'edk2-x86_64-code.fd'
        [System.IO.File]::WriteAllBytes($script:capCode, (New-Object byte[] 3653632))
        . "$PSScriptRoot/../src/ci/Invoke-CleanQemuVerify.ps1" -ParseOnly -IsoPath $script:capIso -OvmfPath $script:capCode -WorkDir $script:capWork
    }

    AfterAll {
        Remove-Item -LiteralPath $script:capDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'parses a real 0x5A i~bugcheck output into code and four parameters' {
        # Example A from the round 21 research (Tom's Hardware, filecrypt):
        # Arg2/Arg3 are kernel pointers to UNICODE_STRINGs, Arg4 is the
        # NTSTATUS that failed the load.
        $out = @'
bugcheck=0x0000005a (CRITICAL_SERVICE_FAILED)
bugcheck.arg1=0x0000000000000001
bugcheck.arg2=0xffffba8f4e9f8c50
bugcheck.arg3=0xffffce06bf0caa90
bugcheck.arg4=0xffffffffc0000428
'@
        $parsed = ConvertFrom-CleanRizinBugCheck -Output $out
        $parsed.BugCheckCode | Should -Be '0x0000005a'
        $parsed.Arg1 | Should -Be '0x0000000000000001'
        $parsed.Arg2 | Should -Be '0xffffba8f4e9f8c50'
        $parsed.Arg3 | Should -Be '0xffffce06bf0caa90'
        $parsed.Arg4 | Should -Be '0xffffffffc0000428'
    }

    It 'parses the CmBootLastKnownGood example (round 21 research, example B)' {
        $out = @'
bugcheck=0x0000005a (CRITICAL_SERVICE_FAILED)
bugcheck.arg1=0x0000000000000001
bugcheck.arg2=0xffffdd8d275d1fd0
bugcheck.arg3=0xffffa202e8dfd6c0
bugcheck.arg4=0xfffffffc0e90002
'@
        $parsed = ConvertFrom-CleanRizinBugCheck -Output $out
        $parsed.BugCheckCode | Should -Be '0x0000005a'
        $parsed.Arg4 | Should -Be '0xfffffffc0e90002'
    }

    It 'returns null when Rizin printed no bugcheck line' {
        ConvertFrom-CleanRizinBugCheck -Output 'no dump loaded' | Should -BeNullOrEmpty
        ConvertFrom-CleanRizinBugCheck -Output '' | Should -BeNullOrEmpty
    }

    It 'tolerates a partial i~bugcheck (missing parameters stay empty)' {
        $out = @'
bugcheck=0x0000005a (CRITICAL_SERVICE_FAILED)
bugcheck.arg1=0x0000000000000001
'@
        $parsed = ConvertFrom-CleanRizinBugCheck -Output $out
        $parsed.BugCheckCode | Should -Be '0x0000005a'
        $parsed.Arg1 | Should -Be '0x0000000000000001'
        $parsed.Arg2 | Should -BeNullOrEmpty
        $parsed.Arg4 | Should -BeNullOrEmpty
    }

    It 'builds a diskpart script that creates an expandable VHDX, attaches, partitions and quick-formats NTFS' {
        $script = New-CleanDiskpartScript -VhdxPath 'C:\x\micpe-dumpdisk.vhdx' -SizeMb 8192 -Letter 'Z'
        $script | Should -Match 'create vdisk file="C:\\x\\micpe-dumpdisk\.vhdx" maximum=8192 type=expandable'
        $script | Should -Match 'select vdisk file="C:\\x\\micpe-dumpdisk\.vhdx"'
        $script | Should -Match 'attach vdisk'
        $script | Should -Match 'create partition primary'
        $script | Should -Match 'format fs=ntfs quick'
        $script | Should -Match 'assign letter=Z'
    }

    It 'returns the first free drive letter from Z Y X W V U T' {
        Find-CleanFreeDriveLetter -UsedLetters @('C', 'D') | Should -Be 'Z'
        Find-CleanFreeDriveLetter -UsedLetters @('C', 'Z', 'Y') | Should -Be 'X'
        Find-CleanFreeDriveLetter -UsedLetters @('Z', 'Y', 'X', 'W', 'V', 'U', 'T') | Should -BeNullOrEmpty
    }

    It 'resolves qemu-img next to qemu-system-x86_64' {
        Get-CleanQemuImgPath -QemuPath 'C:\Program Files\qemu\qemu-system-x86_64.exe' | Should -Be 'C:\Program Files\qemu\qemu-img.exe'
        Get-CleanQemuImgPath -QemuPath 'qemu-system-x86_64' | Should -Be 'qemu-img'
        # The separator found is kept (the function must not depend on
        # Split-Path/Join-Path, which are platform-specific: on the Linux
        # test host Join-Path throws DriveNotFoundException on 'C:').
        Get-CleanQemuImgPath -QemuPath '/usr/bin/qemu-system-x86_64' | Should -Be '/usr/bin/qemu-img.exe'
    }

    It 'attaches the crash-dump disk as ide index 0 (primary master, before the CD-ROM)' {
        $verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ci\Invoke-CleanQemuVerify.ps1') -Raw
        $verify | Should -Match 'if=ide,index=0'
        $verify | Should -Match 'format=qcow2'
        $verify | Should -Match 'New-CleanCrashDumpDisk'
    }

    It 'captures the dump after QEMU exits, even when the screen gate threw, and writes micpe-bugcheck.txt' {
        $verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ci\Invoke-CleanQemuVerify.ps1') -Raw
        $verify | Should -Match 'Invoke-CleanCrashDumpCapture'
        $verify | Should -Match 'micpe-bugcheck\.txt'
        $verify | Should -Match 'Get-CleanRizinPath'
        $verify | Should -Match 'i~bugcheck'
    }
}

Describe 'Round 22 crash-dump capture read-back fix' {
    BeforeAll {
        # Same dot-source pattern as the round 21 block: the clean
        # verifier launches QEMU on load, so dot-source it with
        # -ParseOnly and hand it real temp files for the mandatory paths.
        $script:rbDir = Join-Path ([System.IO.Path]::GetTempPath()) "clean-rb-$(Get-Random)"
        $script:rbShare = Join-Path $script:rbDir 'share'
        New-Item -ItemType Directory -Path $script:rbShare -Force | Out-Null
        $script:rbIso = Join-Path $script:rbDir 'test.iso'
        New-Item -ItemType File -Path $script:rbIso -Force | Out-Null
        $script:rbWork = Join-Path $script:rbDir 'work'
        New-Item -ItemType Directory -Path $script:rbWork -Force | Out-Null
        $script:rbCode = Join-Path $script:rbShare 'edk2-x86_64-code.fd'
        [System.IO.File]::WriteAllBytes($script:rbCode, (New-Object byte[] 3653632))
        . "$PSScriptRoot/../src/ci/Invoke-CleanQemuVerify.ps1" -ParseOnly -IsoPath $script:rbIso -OvmfPath $script:rbCode -WorkDir $script:rbWork
    }

    AfterAll {
        Remove-Item -LiteralPath $script:rbDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'selects the partition before assigning the drive letter (round 21 root cause)' {
        # Round 21 failed with "crash-dump disk attached but drive Z:
        # never appeared" because the attach script ran `assign` with
        # no volume selected: `attach vdisk` selects the disk, not a
        # volume, and `assign` works on the volume with focus. The
        # disk was created with exactly one primary partition, so
        # partition 1 is the volume.
        $script = New-CleanDiskpartAttachScript -DiskPath 'C:\x\micpe-dumpdisk-read.vhdx' -Letter 'Z'
        $script | Should -Match 'select vdisk file="C:\\x\\micpe-dumpdisk-read\.vhdx"'
        $script | Should -Match 'attach vdisk'
        $script | Should -Match 'select partition 1'
        $script | Should -Match 'assign letter=Z'
        # The partition select must come between the attach and the
        # assign -- the order is the fix, not just the presence.
        $script.IndexOf('attach vdisk') | Should -BeLessThan $script.IndexOf('select partition 1')
        $script.IndexOf('select partition 1') | Should -BeLessThan $script.IndexOf('assign letter=Z')
    }

    It 'converts the dump disk back to VHDX and falls back to VHD (vpc) when the attach fails' {
        $verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ci\Invoke-CleanQemuVerify.ps1') -Raw
        # Round 23: the conversion moved into ConvertTo-CleanDeSparseDisk
        # (plain copy after convert, so the output is not sparse) and is
        # parameterised by -Format; the two call sites still try VHDX
        # first and VHD (vpc) on attach failure.
        $verify | Should -Match 'convert -f qcow2 -O \$Format'
        $verify | Should -Match "-Format 'vhdx'"
        $verify | Should -Match "-Format 'vpc'"
        $verify | Should -Match 'VHDX attach failed; retrying as VHD \(vpc\)'
        $verify | Should -Match 'Invoke-CleanDiskAttach'
    }

    It 'polls for the drive letter and accepts a letter Windows automounted instead' {
        $verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ci\Invoke-CleanQemuVerify.ps1') -Raw
        # A single 3-second sleep plus one check was the round 21
        # failure mode (the letter never appeared in that window).
        $verify | Should -Match 'WaitSec = 30'
        $verify | Should -Match 'new letter.*showed up after the attach'
        $verify | Should -Match 'never appeared within'
    }

    It 'records diskpart output and the runner volumes in bugcheck.txt when the attach fails' {
        $verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ci\Invoke-CleanQemuVerify.ps1') -Raw
        $verify | Should -Match 'attach diskpart output:'
        $verify | Should -Match 'volumes on the runner:'
        $verify | Should -Match 'There is no volume selected'
    }

    It 'preserves the converted disk file for upload instead of deleting it' {
        $verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ci\Invoke-CleanQemuVerify.ps1') -Raw
        $verify | Should -Match 'preserved disk file for upload:'
        $verify | Should -Match 'DiskPath = \$diskFile'
        # The qcow2 (the intermediate) is still deleted; the converted
        # VHDX/VHD is what survives for upload.
        $verify | Should -Match 'Remove-Item -LiteralPath \$Qcow2Path'
    }

    It 'uploads the dump disk as an artifact (backup when Rizin could not parse it)' {
        $workflow = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\.github\workflows\build.yml') -Raw
        $workflow | Should -Match 'verify-clean-out/micpe-dumpdisk-read\.vhdx'
        $workflow | Should -Match 'verify-clean-out/micpe-dumpdisk-read\.vhd'
    }

    It 'uploads the dump disk to the Release only under the 2 GB asset limit' {
        $workflow = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\.github\workflows\build.yml') -Raw
        $workflow | Should -Match "micpe-dumpdisk-read\.vhdx"
        $workflow | Should -Match "micpe-dumpdisk-read\.vhd"
        # A complete dump of a 4 GB VM is ~4.3 GB; GitHub caps release
        # assets at 2 GB, so an oversize disk must be skipped with a
        # log line instead of failing the upload.
        $workflow | Should -Match '1900MB'
        $workflow | Should -Match 'over the ~1\.9 GB Release asset limit'
    }
}

Describe 'Round 23 guest-memory ELF scan and de-sparse read-back' {
    BeforeAll {
        # Same dot-source pattern as the round 21/22 blocks: the clean
        # verifier launches QEMU on load, so dot-source it with
        # -ParseOnly and hand it real temp files for the mandatory paths.
        $script:r23Dir = Join-Path ([System.IO.Path]::GetTempPath()) "clean-r23-$(Get-Random)"
        $script:r23Share = Join-Path $script:r23Dir 'share'
        New-Item -ItemType Directory -Path $script:r23Share -Force | Out-Null
        $script:r23Iso = Join-Path $script:r23Dir 'test.iso'
        New-Item -ItemType File -Path $script:r23Iso -Force | Out-Null
        $script:r23Work = Join-Path $script:r23Dir 'work'
        New-Item -ItemType Directory -Path $script:r23Work -Force | Out-Null
        $script:r23Code = Join-Path $script:r23Share 'edk2-x86_64-code.fd'
        [System.IO.File]::WriteAllBytes($script:r23Code, (New-Object byte[] 3653632))
        . "$PSScriptRoot/../src/ci/Invoke-CleanQemuVerify.ps1" -ParseOnly -IsoPath $script:r23Iso -OvmfPath $script:r23Code -WorkDir $script:r23Work

        # Get-Volume does not exist on the Linux test host, and
        # Add-CleanVolumeList is the function under test, so stub it
        # here (same scope the production functions were dot-sourced
        # into, so the call resolves to this stub). The stub reads
        # script variables, so each test can pick its volumes or make
        # it throw.
        $script:volData = @(
            [pscustomobject]@{ DriveLetter = 'C'; FileSystemLabel = 'System'; FileSystem = 'NTFS'; Size = 8589417920 }
            [pscustomobject]@{ DriveLetter = 'D'; FileSystemLabel = ''; FileSystem = 'NTFS'; Size = 107374182400 }
        )
        $script:volThrow = $false
        function Get-Volume {
            if ($script:volThrow) { throw 'no storage module' }
            return $script:volData
        }

        # Hex literals above Int64.MaxValue parse as NEGATIVE Int64 in
        # PowerShell (0xffffba8f4e9f8c50 becomes -76350314542000) and
        # cannot bind to a [UInt64] parameter, so build those values
        # with an explicit parse instead of a literal.
        function U64([string]$Hex) {
            [UInt64]::Parse($Hex, [System.Globalization.NumberStyles]::HexNumber)
        }

        # Loopback TCP from PowerShell is blocked on the sandboxed Linux
        # dev VM (verified 2026-11-26): TcpClient.Connect "succeeds"
        # but the connection never reaches the listener -- the sandbox
        # answers with a policy message instead -- while a Python
        # client connects fine. The fake-monitor test below therefore
        # probes first and skips here; it runs for real on the CI
        # Windows runner, where the QEMU monitor connection happens.
        function Test-CleanLoopbackTcp {
            $port = 45200 + (Get-Random -Maximum 2000)
            $listener = $null
            $client = $null
            $serverSide = $null
            try {
                $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
                $listener.Start()
                $acceptTask = $listener.AcceptTcpClientAsync()
                $client = [System.Net.Sockets.TcpClient]::new()
                try { $client.Connect('127.0.0.1', $port) } catch { return $false }
                if (-not $acceptTask.Wait(2000)) { return $false }
                $serverSide = $acceptTask.Result
                $writer = [System.IO.StreamWriter]::new($serverSide.GetStream())
                $writer.AutoFlush = $true
                $writer.Write('ping')
                $client.GetStream().ReadTimeout = 2000
                $buf = [byte[]]::new(16)
                $n = $client.GetStream().Read($buf, 0, $buf.Length)
                if ($n -le 0) { return $false }
                return ([System.Text.Encoding]::ASCII.GetString($buf, 0, $n) -eq 'ping')
            }
            catch {
                return $false
            }
            finally {
                if ($serverSide) { $serverSide.Dispose() }
                if ($client) { $client.Dispose() }
                if ($listener) { $listener.Stop() }
            }
        }
    }

    AfterAll {
        Remove-Item -LiteralPath $script:r23Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'lists the runner volumes on every attach failure path, including the diskpart-error path' {
        # Round 22 lesson: the volume listing only ran on the
        # poll-timeout path, so the diskpart-error path (the one round
        # 22 actually hit) wrote no volume listing at all, even though
        # the RESULT line claimed "the diskpart output and volume
        # listing above are the evidence".
        $lines = [System.Collections.Generic.List[string]]::new()
        Add-CleanVolumeList -Lines $lines
        ($lines -join "`n") | Should -Match 'volumes on the runner: C: System NTFS'
        ($lines -join "`n") | Should -Match 'D:  NTFS'
        $verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ci\Invoke-CleanQemuVerify.ps1') -Raw
        # Every failure return in Invoke-CleanDiskAttach must list the
        # volumes: no free letter, diskpart error, and poll timeout.
        (@([regex]::Matches($verify, 'Add-CleanVolumeList -Lines \$Lines')).Count) | Should -BeGreaterOrEqual 3
    }

    It 'writes a diagnostics line instead of throwing when Get-Volume fails' {
        $script:volThrow = $true
        try {
            $lines = [System.Collections.Generic.List[string]]::new()
            { Add-CleanVolumeList -Lines $lines } | Should -Not -Throw
            ($lines -join "`n") | Should -Match 'could not list volumes: no storage module'
        }
        finally {
            $script:volThrow = $false
        }
    }

    It 'parses real Rizin /x search output into hit addresses, ignoring the ANSI erase-line prefix' {
        # Captured from Rizin 0.9.1 against the synthetic ELF core
        # (micpe-r23/fixture-guest-memory.elf): the real KDBG OwnerTag
        # at 0x102010 and the decoy at 0x108010.
        $out = "$([char]27)[2K`r0x00102010 4 hit.bytes.0`n0x00108010 4 hit.bytes.1`n"
        $hits = @(ConvertFrom-CleanRizinSearchHits -Output $out)
        $hits.Count | Should -Be 2
        $hits[0] | Should -Be 0x102010
        $hits[1] | Should -Be 0x108010
    }

    It 'returns no hits for an empty search output' {
        @(ConvertFrom-CleanRizinSearchHits -Output '') | Should -BeNullOrEmpty
        @(ConvertFrom-CleanRizinSearchHits -Output "$([char]27)[2K`r`n") | Should -BeNullOrEmpty
    }

    It 'parses real Rizin pv8 output into the five bugcheck qwords, in order' {
        # Captured from Rizin 0.9.1: the planted KiBugCheckData at
        # 0x104000 (round 21 research example A values).
        $out = @'
0x000000000000005a
0x0000000000000001
0xffffba8f4e9f8c50
0xffffce06bf0caa90
0xffffffffc0000428
'@
        $vals = @(ConvertFrom-CleanRizinValues -Output $out)
        $vals.Count | Should -Be 5
        $vals[0] | Should -Be 0x5A
        $vals[1] | Should -Be 1
        # The three pointers are above Int64.MaxValue: compare their
        # hex rendering, not a literal (a literal would parse as a
        # negative Int64 and never equal the UInt64 value).
        $vals[2].ToString('x16') | Should -Be 'ffffba8f4e9f8c50'
        $vals[3].ToString('x16') | Should -Be 'ffffce06bf0caa90'
        $vals[4].ToString('x16') | Should -Be 'ffffffffc0000428'
    }

    It 'skips non-value lines when parsing pv output' {
        $out = "WARNING: something`n0x000000000000005a`n`n0x0000000000000001`n"
        $vals = @(ConvertFrom-CleanRizinValues -Output $out)
        $vals.Count | Should -Be 2
        $vals[0] | Should -Be 0x5A
    }

    It 'accepts the real KiBugCheckData candidate (round 21 example A)' {
        $c = Test-CleanBugCheckCandidate -Code 0x5A -Arg1 1 `
            -Arg2 (U64 'ffffba8f4e9f8c50') -Arg3 (U64 'ffffce06bf0caa90') -Arg4 (U64 'ffffffffc0000428')
        $c.Valid | Should -BeTrue
    }

    It 'accepts the sign-extended NTSTATUS from the CmBootLastKnownGood example (round 21 example B)' {
        $c = Test-CleanBugCheckCandidate -Code 0x5A -Arg1 1 `
            -Arg2 (U64 'ffffdd8d275d1fd0') -Arg3 (U64 'ffffa202e8dfd6c0') -Arg4 (U64 'fffffffc0e90002')
        $c.Valid | Should -BeTrue
    }

    It 'rejects the decoy pattern whose pointers are not kernel addresses' {
        # The synthetic ELF decoy at 0x106000: 0x5A, 1, 0x401000,
        # 0x402000, 0xC0000428 -- the pointers are user-mode addresses.
        # (0xC0000428 also needs U64: as a literal it parses as a
        # negative [int] and cannot bind to [UInt64].)
        $c = Test-CleanBugCheckCandidate -Code 0x5A -Arg1 1 `
            -Arg2 0x401000 -Arg3 0x402000 -Arg4 (U64 'c0000428')
        $c.Valid | Should -BeFalse
        $c.Reason | Should -Match 'not a canonical kernel address'
    }

    It 'rejects a candidate with the wrong bugcheck code' {
        $c = Test-CleanBugCheckCandidate -Code 0x69 -Arg1 1 `
            -Arg2 (U64 'ffffba8f4e9f8c50') -Arg3 (U64 'ffffce06bf0caa90') -Arg4 (U64 'ffffffffc0000428')
        $c.Valid | Should -BeFalse
        $c.Reason | Should -Match 'not 0x5A'
    }

    It 'accepts a real KDBG (Size 0x3b0, canonical KernBase)' {
        $c = Test-CleanKdbgCandidate -Size 0x3b0 -KernBase (U64 'fffff80001234000')
        $c.Valid | Should -BeTrue
    }

    It 'rejects a KDBG decoy with a non-canonical KernBase' {
        $c = Test-CleanKdbgCandidate -Size 0x3b0 -KernBase 0x400000
        $c.Valid | Should -BeFalse
        $c.Reason | Should -Match 'not a canonical kernel address'
    }

    It 'rejects a KDBG hit with an implausible Size' {
        $c = Test-CleanKdbgCandidate -Size 0x10 -KernBase (U64 'fffff80001234000')
        $c.Valid | Should -BeFalse
    }

    It 'materializes the converted disk with a plain copy and verifies it is not sparse' {
        # Round 22: diskpart refused both the VHDX and the VHD with
        # "must be uncompressed and unencrypted and must not be
        # sparse" because qemu-img's output is sparse. A plain copy
        # loses the sparse attribute (Microsoft Q&A); fsutil sparse
        # setflag 0 on an already-sparse file may corrupt it, so the
        # copy -- not setflag -- is the fix.
        $verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ci\Invoke-CleanQemuVerify.ps1') -Raw
        $verify | Should -Match 'ConvertTo-CleanDeSparseDisk'
        $verify | Should -Match 'Copy-Item -LiteralPath \$tmpPath -Destination \$OutPath'
        $verify | Should -Match 'fsutil sparse queryflag'
        $verify | Should -Match "convert: qemu-img convert -f qcow2 -O \{0\}"
    }

    It 'keeps the .vhdx when falling back to VHD instead of deleting it' {
        # Round 22 deleted the .vhdx in the fallback branch, so the
        # artifact and the Release only ever got the .vhd even though
        # the upload lists both. Scope the check to the capture
        # function: New-CleanCrashDumpDisk (the creation step) still
        # deletes ITS .vhdx after converting it to qcow2 for QEMU,
        # which is correct -- only the capture must keep both.
        $verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ci\Invoke-CleanQemuVerify.ps1') -Raw
        $capture = $verify.Substring($verify.IndexOf('function Invoke-CleanCrashDumpCapture'))
        $capture | Should -Not -Match 'Remove-Item -LiteralPath \$vhdx'
        $capture | Should -Match 'preserved disk file for upload:'
    }

    It 'dumps guest memory through the monitor before quitting QEMU on a blue screen' {
        $verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ci\Invoke-CleanQemuVerify.ps1') -Raw
        $verify | Should -Match 'Invoke-CleanGuestMemoryDump'
        $verify | Should -Match 'dump-guest-memory'
        $verify | Should -Match 'guest-memory\.elf'
        # The dump must happen before 'quit': once QEMU exits the
        # memory is gone.
        $verify.IndexOf('Invoke-CleanGuestMemoryDump') | Should -BeLessThan $verify.IndexOf("Invoke-CleanMonitorCommand -Port `$MonitorPort -Command 'quit'")
        # ... and only when the guest died on a bugcheck blue screen.
        $verify | Should -Match 'blueScreenSeen'
    }

    It 'scans the guest-memory ELF with Rizin when the disk produced no parameters' {
        $verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ci\Invoke-CleanQemuVerify.ps1') -Raw
        $verify | Should -Match 'Invoke-CleanElfBugCheckScan'
        $verify | Should -Match '/x 4b444247'
        $verify | Should -Match '/x 5a000000000000000100000000000000'
        $verify | Should -Match 'Invoke-CleanRizinFile'
        # The ELF is deleted after the scan: 4 GB cannot leave the
        # runner (Release caps assets at ~1.9 GB).
        $verify | Should -Match 'guest-memory ELF dump deleted after scan'
    }

    It 'passes arguments with spaces as single argv entries (no shell splitting)' {
        # Regression test for the round 23 Rizin failure:
        # Start-Process -ArgumentList split '/x 4b444247' into two
        # arguments on Linux, so Rizin failed with "Wrong number of
        # arguments passed to /x" and the ELF scan found zero hits.
        # Invoke-CleanProcessToFile must pass each entry as exactly
        # one argv element: if 'a b' were split, the child would see
        # 'a|b|c|d|e' instead of 'a b|c d e'. (A -File probe script is
        # used, not -Command: pwsh -Command joins all following
        # arguments into the command string, so it cannot observe
        # argv splitting at all.)
        $pwsh = (Get-Process -Id $PID).Path
        $probeScript = Join-Path $script:r23Work 'argv-probe.ps1'
        Set-Content -LiteralPath $probeScript -Value 'Write-Output ($args -join "|")' -Encoding utf8
        $outFile = Join-Path $script:r23Work 'argv-out.txt'
        $errFile = Join-Path $script:r23Work 'argv-err.txt'
        $run = Invoke-CleanProcessToFile -FilePath $pwsh `
            -ArgumentList @('-NoProfile', '-File', $probeScript, 'a b', 'c d e') `
            -OutFile $outFile -ErrFile $errFile -TimeoutSec 60
        $run.ExitCode | Should -Be 0
        (Get-Content -LiteralPath $outFile -Raw).Trim() | Should -Be 'a b|c d e'
    }

    It 'runs Rizin through the exact-argv helper instead of Start-Process' {
        $verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ci\Invoke-CleanQemuVerify.ps1') -Raw
        $verify | Should -Match 'Invoke-CleanProcessToFile -FilePath \$RizinPath'
        $verify | Should -Match 'ArgumentList\.Add'
        # The QEMU launch still uses Start-Process (its arguments
        # contain no spaces); only the Rizin calls must not.
        $verify | Should -Not -Match 'Start-Process -FilePath \$RizinPath'
    }

    It 'reads the monitor stream until the (qemu) prompt, without any TCP' {
        # Read-CleanMonitorUntilPrompt takes any [System.IO.Stream], so
        # the prompt-matching logic is testable on a MemoryStream even
        # where loopback TCP is blocked (see the probe above).
        $bytes = [System.Text.Encoding]::ASCII.GetBytes("QEMU 9.2.0 monitor - type 'help' for more information`r`n(qemu) ")
        $stream = [System.IO.MemoryStream]::new($bytes)
        $text = Read-CleanMonitorUntilPrompt -Stream $stream -TimeoutSec 5
        $text | Should -Match '\(qemu\)'
        $text | Should -Match 'QEMU 9.2.0 monitor'
    }

    It 'returns what arrived when the monitor goes away without a prompt' {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes('partial output, no prompt')
        $stream = [System.IO.MemoryStream]::new($bytes)
        $text = Read-CleanMonitorUntilPrompt -Stream $stream -TimeoutSec 5
        $text | Should -Be 'partial output, no prompt'
    }

    It 'returns an empty string when the stream is already at end-of-stream' {
        $stream = [System.IO.MemoryStream]::new()
        $text = Read-CleanMonitorUntilPrompt -Stream $stream -TimeoutSec 5
        $text | Should -Be ''
    }

    It 'waits for the monitor prompt instead of returning after the first read gap' {
        if (-not (Test-CleanLoopbackTcp)) {
            Set-ItResult -Skipped -Because 'loopback TCP from PowerShell is blocked in this environment (sandbox other_tcp policy); this test runs on the CI Windows runner'
        }
        # A fake QEMU human monitor on TCP: banner + prompt, then a
        # 3 s "dump" before the completion prompt. The old read loop
        # returned after the first 2 s gap, while QEMU was still
        # writing the dump; the wait-for-prompt loop must sit through
        # the silence and return the completion text.
        $port = 45200 + (Get-Random -Maximum 2000)
        $job = Start-Job -ScriptBlock {
            param($Port)
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
            $listener.Start()
            try {
                # Accept in a loop: the test probes the port once to
                # confirm the listener is up, and that probe must not
                # consume the only accept.
                $handled = 0
                while ($handled -lt 5) {
                    $client = $listener.AcceptTcpClient()
                    $handled++
                    try {
                        $stream = $client.GetStream()
                        $writer = [System.IO.StreamWriter]::new($stream)
                        $writer.AutoFlush = $true
                        $writer.Write("QEMU 9.2.0 monitor - type 'help' for more information`r`n(qemu) ")
                        $reader = [System.IO.StreamReader]::new($stream)
                        $line = $reader.ReadLine()
                        if ([string]::IsNullOrEmpty($line)) { continue }
                        Start-Sleep -Seconds 3
                        $writer.Write("dump complete`r`n(qemu) ")
                        Start-Sleep -Milliseconds 500
                    }
                    catch {
                    }
                    finally {
                        $client.Close()
                    }
                }
            }
            finally {
                $listener.Stop()
            }
        } -ArgumentList $port
        try {
            # Wait for the listener before connecting (job start is slow).
            $up = $false
            $deadline = (Get-Date).AddSeconds(15)
            while ((Get-Date) -lt $deadline) {
                try {
                    $probe = [System.Net.Sockets.TcpClient]::new()
                    $probe.Connect('127.0.0.1', $port)
                    $probe.Dispose()
                    $up = $true
                    break
                }
                catch {
                    Start-Sleep -Milliseconds 200
                }
            }
            $up | Should -BeTrue -Because 'the fake monitor must be listening before the call'
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $reply = Invoke-CleanMonitorCommand -Port "$port" `
                -Command 'dump-guest-memory "C:/x/guest-memory.elf"' -WaitForPromptSec 30
            $sw.Stop()
            $reply | Should -Match 'dump complete'
            $reply | Should -Match '\(qemu\)'
            $sw.Elapsed.TotalSeconds | Should -BeGreaterThan 2.5 -Because 'the 3 s dump must have been waited out'
        }
        finally {
            $job | Stop-Job -ErrorAction SilentlyContinue
            $job | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Round 24 crash-dump capture: null-safe read-back, volume listing, MBR signature, ELF validation' {
    BeforeAll {
        # Same dot-source pattern as the round 21/22/23 blocks: the
        # clean verifier launches QEMU on load, so dot-source it with
        # -ParseOnly and hand it real temp files for the mandatory paths.
        $script:r24Dir = Join-Path ([System.IO.Path]::GetTempPath()) "clean-r24-$(Get-Random)"
        $script:r24Share = Join-Path $script:r24Dir 'share'
        New-Item -ItemType Directory -Path $script:r24Share -Force | Out-Null
        $script:r24Iso = Join-Path $script:r24Dir 'test.iso'
        New-Item -ItemType File -Path $script:r24Iso -Force | Out-Null
        $script:r24Work = Join-Path $script:r24Dir 'work'
        New-Item -ItemType Directory -Path $script:r24Work -Force | Out-Null
        $script:r24Code = Join-Path $script:r24Share 'edk2-x86_64-code.fd'
        [System.IO.File]::WriteAllBytes($script:r24Code, (New-Object byte[] 3653632))
        . "$PSScriptRoot/../src/ci/Invoke-CleanQemuVerify.ps1" -ParseOnly -IsoPath $script:r24Iso -OvmfPath $script:r24Code -WorkDir $script:r24Work

        # Get-Volume does not exist on the Linux test host, and
        # Add-CleanVolumeList is the function under test, so stub it
        # here (same scope the production functions were dot-sourced
        # into, so the call resolves to this stub). Same pattern as
        # the round 23 block.
        $script:r24VolData = @(
            [pscustomobject]@{ DriveLetter = 'C'; FileSystemLabel = 'System'; FileSystem = 'NTFS'; Size = 8589417920 }
            [pscustomobject]@{ DriveLetter = 'Z'; FileSystemLabel = 'MICPE-DUMP'; FileSystem = 'NTFS'; Size = 8589417920 }
        )
        $script:r24VolThrow = $false
        function Get-Volume {
            if ($script:r24VolThrow) { throw 'no storage module' }
            return $script:r24VolData
        }

        # Builds a minimal ELF64 core: a 64-byte header plus PT_LOAD
        # program headers. DeclaredSizes (when given) is what the
        # header claims; SegmentSizes is what is actually allocated,
        # so a 4 GiB declared segment can be tested from a ~4 KB file
        # (Test-CleanElfCore only reads the header + program headers).
        function New-R24ElfFixture {
            param(
                [string] $Path,
                [UInt64[]] $SegmentSizes = @(4096),
                [UInt64[]] $DeclaredSizes,
                [switch] $BadMagic,
                [switch] $NotCore,
                [switch] $NoLoad,
                [switch] $TruncateHeader
            )
            $phnum = $SegmentSizes.Count
            if ($NoLoad) { $phnum = 0 }
            $hdr = [byte[]]::new(64)
            $hdr[0] = 0x7F; $hdr[1] = 0x45; $hdr[2] = 0x4C; $hdr[3] = 0x46
            if ($BadMagic) { $hdr[1] = 0x58 }
            $hdr[4] = 2; $hdr[5] = 1; $hdr[6] = 1
            $type = if ($NotCore) { [UInt16]2 } else { [UInt16]4 }
            [Array]::Copy([BitConverter]::GetBytes($type), 0, $hdr, 16, 2)
            [Array]::Copy([BitConverter]::GetBytes([UInt16]62), 0, $hdr, 18, 2)
            [Array]::Copy([BitConverter]::GetBytes([UInt32]1), 0, $hdr, 20, 4)
            [Array]::Copy([BitConverter]::GetBytes([UInt64]64), 0, $hdr, 32, 8)
            [Array]::Copy([BitConverter]::GetBytes([UInt16]64), 0, $hdr, 52, 2)
            [Array]::Copy([BitConverter]::GetBytes([UInt16]56), 0, $hdr, 54, 2)
            [Array]::Copy([BitConverter]::GetBytes([UInt16]$phnum), 0, $hdr, 56, 2)
            $phdrs = [byte[]]::new(56 * $phnum)
            $off = 64
            for ($i = 0; $i -lt $phnum; $i++) {
                $p = $i * 56
                $declared = if ($DeclaredSizes) { $DeclaredSizes[$i] } else { $SegmentSizes[$i] }
                [Array]::Copy([BitConverter]::GetBytes([UInt32]1), 0, $phdrs, $p + 0, 4)
                [Array]::Copy([BitConverter]::GetBytes([UInt32]6), 0, $phdrs, $p + 4, 4)
                [Array]::Copy([BitConverter]::GetBytes([UInt64]$off), 0, $phdrs, $p + 8, 8)
                [Array]::Copy([BitConverter]::GetBytes([UInt64]0), 0, $phdrs, $p + 16, 8)
                [Array]::Copy([BitConverter]::GetBytes([UInt64]0), 0, $phdrs, $p + 24, 8)
                [Array]::Copy([BitConverter]::GetBytes([UInt64]$declared), 0, $phdrs, $p + 32, 8)
                [Array]::Copy([BitConverter]::GetBytes([UInt64]$declared), 0, $phdrs, $p + 40, 8)
                [Array]::Copy([BitConverter]::GetBytes([UInt64]0x1000), 0, $phdrs, $p + 48, 8)
                $off += $SegmentSizes[$i]
            }
            $total = 64 + 56 * $phnum
            foreach ($s in $SegmentSizes) { $total += $s }
            $file = [byte[]]::new($total)
            [Array]::Copy($hdr, 0, $file, 0, 64)
            if ($phnum -gt 0) { [Array]::Copy($phdrs, 0, $file, 64, $phdrs.Length) }
            if ($TruncateHeader) {
                $short = [byte[]]::new(32)
                [Array]::Copy($file, 0, $short, 0, 32)
                $file = $short
            }
            [System.IO.File]::WriteAllBytes($Path, $file)
            return $Path
        }

        # Mocked Rizin for the loose-cap and signature tests: the scan
        # calls Invoke-CleanRizinFile; this stub answers from a script
        # table instead of a real binary, so the tests prove the scan
        # examines hits past position 10 without needing a real ELF.
        # 15 loose hits at 0x1000 apart from 0x10000; the first 14 are
        # decoys (Arg2 not a canonical kernel address), the 15th is
        # the real candidate with Arg1=2 -- which the strict search
        # (Arg1=1) can never find.
        $script:r24LooseHits = @(0..14 | ForEach-Object { 0x10000 + ($_ * 0x1000) })
        function Invoke-CleanRizinFile {
            param(
                [string] $RizinPath,
                [string] $FilePath,
                [string] $Commands,
                [string] $WorkDir
            )
            if ($Commands -match '4b444247') { return '' }
            if ($Commands -match '5a000000000000000100000000000000') { return '' }
            if ($Commands -match '5a00000000000000') {
                return (($script:r24LooseHits | ForEach-Object { ('0x{0:x} 4 hit.bytes.0' -f $_) }) -join "`n")
            }
            if ($Commands -match 'pv8 @') {
                $out = [System.Collections.Generic.List[string]]::new()
                foreach ($m in [regex]::Matches($Commands, 'pv8 @ 0x([0-9a-fA-F]+)')) {
                    $addr = [Convert]::ToUInt64($m.Groups[1].Value, 16)
                    $val = [UInt64]0
                    foreach ($h in $script:r24LooseHits) {
                        $off = $addr - $h
                        if ($off -ge 0 -and $off -le 32 -and ($off % 8) -eq 0) {
                            $field = [int]($off / 8)
                            $idx = [int](($h - 0x10000) / 0x1000)
                            if ($field -eq 0) { $val = 0x5a }
                            elseif ($field -eq 1) { $val = 2 }
                            elseif ($field -eq 2) {
                                if ($idx -eq 14) { $val = [Convert]::ToUInt64('ffffba8f4e9f8c50', 16) } else { $val = 0x1234 }
                            }
                            elseif ($field -eq 3) {
                                if ($idx -eq 14) { $val = [Convert]::ToUInt64('ffffce06bf0caa90', 16) } else { $val = 0x1234 }
                            }
                            elseif ($field -eq 4) { $val = [Convert]::ToUInt64('ffffffffc0000428', 16) }
                            break
                        }
                    }
                    $out.Add(('0x{0:x16}' -f $val))
                }
                return ($out -join "`n")
            }
            return ''
        }
    }

    It 'formats volume contents without touching .Length on directories (round 23 regression)' {
        # The round 23 failure, reproduced: a freshly formatted NTFS
        # root always contains "System Volume Information", and the
        # old inline format read .Length on every entry; under
        # StrictMode the directory entry threw "The property 'Length'
        # cannot be found on this object" before the volume-contents
        # line was written, so the capture died after a successful
        # attach.
        $dir = Join-Path $script:r24Work 'vol'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $dir 'System Volume Information') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'dedicateddumpfile.sys'), 'x')
        $entries = @(Get-ChildItem -LiteralPath $dir -Force)
        $out = Format-CleanVolumeContents -Entries $entries
        $out | Should -Match 'System Volume Information \(directory\)'
        $out | Should -Match 'dedicateddumpfile\.sys \(1 bytes\)'
    }

    It 'formats an empty volume listing as an empty string' {
        (Format-CleanVolumeContents -Entries @()) | Should -Be ''
    }

    It 'returns the MBR disk signature as a little-endian UInt32' {
        $mbr = [byte[]]::new(512)
        $mbr[510] = 0x55; $mbr[511] = 0xAA
        $mbr[0x1B8] = 0x78; $mbr[0x1B9] = 0x56; $mbr[0x1BA] = 0x34; $mbr[0x1BB] = 0x12
        (ConvertFrom-CleanMbrSignature -MbrBytes $mbr) | Should -Be 0x12345678
    }

    It 'returns null for a short or unsigned MBR' {
        (ConvertFrom-CleanMbrSignature -MbrBytes ([byte[]]::new(100))) | Should -BeNullOrEmpty
        $mbr = [byte[]]::new(512)
        (ConvertFrom-CleanMbrSignature -MbrBytes $mbr) | Should -BeNullOrEmpty
    }

    It 'reads the disk signature from the qcow2 MBR with qemu-img dd' {
        if ($IsWindows) {
            Set-ItResult -Skipped -Because 'the fake qemu-img is a Python script with a shebang; it only executes directly on Linux. The success path runs for real on the CI Windows runner with the real qemu-img'
        }
        $fake = Join-Path $script:r24Work 'fake-qemu-img.py'
        Set-Content -LiteralPath $fake -Value @'
#!/usr/bin/env python3
import sys
of = None
for a in sys.argv[1:]:
    if a.startswith('of='):
        of = a[3:]
if of is None:
    sys.exit(2)
mbr = bytearray(512)
mbr[0x1B8:0x1BC] = bytes([0x78, 0x56, 0x34, 0x12])
mbr[510] = 0x55
mbr[511] = 0xAA
with open(of, 'wb') as f:
    f.write(mbr)
'@ -Encoding utf8
        chmod +x $fake
        $qcow2 = Join-Path $script:r24Work 'fake.qcow2'
        New-Item -ItemType File -Path $qcow2 -Force | Out-Null
        $lines = [System.Collections.Generic.List[string]]::new()
        $sig = Get-CleanDiskSignature -QemuImgPath $fake -Qcow2Path $qcow2 -WorkDir $script:r24Work -Lines $lines
        $sig | Should -Be 0x12345678
        ($lines -join "`n") | Should -Match 'disk MBR signature: 0x12345678'
        # The temp MBR/out/err files are cleaned up.
        (Test-Path -LiteralPath (Join-Path $script:r24Work 'micpe-dumpdisk-mbr.bin')) | Should -BeFalse
    }

    It 'returns 0 when qemu-img dd fails' {
        # The current pwsh, given qemu-img's argv, exits non-zero on
        # both platforms (Linux: /usr/bin/dd rejects -f; Windows: dd
        # is not a command). Probe first: if it ever exits 0 here,
        # the failure path cannot be observed this way and the test
        # skips instead of asserting on a platform quirk.
        $pwsh = (Get-Process -Id $PID).Path
        $probeOut = Join-Path $script:r24Work 'dd-probe.out'
        $probeErr = Join-Path $script:r24Work 'dd-probe.err'
        $probe = Invoke-CleanProcessToFile -FilePath $pwsh `
            -ArgumentList @('dd', '-f', 'qcow2', '-O', 'raw', 'if=x', ('of={0}' -f (Join-Path $script:r24Work 'dd-probe-y')), 'bs=512', 'count=1') `
            -OutFile $probeOut -ErrFile $probeErr -TimeoutSec 60
        if ($probe.ExitCode -eq 0) {
            Set-ItResult -Skipped -Because 'pwsh exits 0 on the dd argv here, so the dd-failure path cannot be observed; it runs on the CI Windows runner'
        }
        $lines = [System.Collections.Generic.List[string]]::new()
        $sig = Get-CleanDiskSignature -QemuImgPath $pwsh -Qcow2Path (Join-Path $script:r24Work 'nope.qcow2') -WorkDir $script:r24Work -Lines $lines
        $sig | Should -Be 0
        ($lines -join "`n") | Should -Match 'qemu-img dd failed'
    }

    It 'returns 0 when qemu-img cannot start' {
        $lines = [System.Collections.Generic.List[string]]::new()
        $sig = Get-CleanDiskSignature -QemuImgPath (Join-Path $script:r24Work 'no-such-qemu-img.exe') -Qcow2Path (Join-Path $script:r24Work 'nope.qcow2') -WorkDir $script:r24Work -Lines $lines
        $sig | Should -Be 0
        ($lines -join "`n") | Should -Match 'could not read the MBR'
    }

    It 'validates a well-formed ELF64 core and reports its PT_LOAD segments' {
        $elf = Join-Path $script:r24Work 'core-valid.elf'
        New-R24ElfFixture -Path $elf -SegmentSizes @(4096, 8192)
        $check = Test-CleanElfCore -ElfPath $elf
        $check.Valid | Should -BeTrue
        $check.Segments | Should -Be 2
        $check.MappedBytes | Should -Be 12288
    }

    It 'reports a 4 GiB declared segment without reading the whole file' {
        # The parser only reads the header + program-header table, so
        # a multi-GB dump is cheap to validate; the declared size is
        # what matters for the "did Rizin cover the whole file"
        # question. The file itself is ~4 KB.
        $elf = Join-Path $script:r24Work 'core-huge.elf'
        New-R24ElfFixture -Path $elf -SegmentSizes @(4096) -DeclaredSizes @(4294967296)
        $check = Test-CleanElfCore -ElfPath $elf
        $check.Valid | Should -BeTrue
        $check.Segments | Should -Be 1
        $check.MappedBytes | Should -Be 4294967296
    }

    It 'rejects a bad magic, a non-core type, no PT_LOAD, a truncated file, and a missing file' {
        $bad = Join-Path $script:r24Work 'core-badmagic.elf'
        New-R24ElfFixture -Path $bad -BadMagic
        (Test-CleanElfCore -ElfPath $bad).Valid | Should -BeFalse
        $exec = Join-Path $script:r24Work 'core-exec.elf'
        New-R24ElfFixture -Path $exec -NotCore
        (Test-CleanElfCore -ElfPath $exec).Valid | Should -BeFalse
        (Test-CleanElfCore -ElfPath $exec).Reason | Should -Match 'ET_CORE'
        $noload = Join-Path $script:r24Work 'core-noload.elf'
        New-R24ElfFixture -Path $noload -NoLoad
        (Test-CleanElfCore -ElfPath $noload).Valid | Should -BeFalse
        $trunc = Join-Path $script:r24Work 'core-trunc.elf'
        New-R24ElfFixture -Path $trunc -TruncateHeader
        (Test-CleanElfCore -ElfPath $trunc).Valid | Should -BeFalse
        (Test-CleanElfCore -ElfPath (Join-Path $script:r24Work 'does-not-exist.elf')).Valid | Should -BeFalse
    }

    It 'writes the Get-Volume listing into the report lines' {
        $lines = [System.Collections.Generic.List[string]]::new()
        Add-CleanVolumeList -Lines $lines
        ($lines -join "`n") | Should -Match 'volumes on the runner:'
        ($lines -join "`n") | Should -Match 'MICPE-DUMP'
    }

    It 'writes a failure line when the volume listing itself fails' {
        $script:r24VolThrow = $true
        try {
            $lines = [System.Collections.Generic.List[string]]::new()
            Add-CleanVolumeList -Lines $lines
            ($lines -join "`n") | Should -Match 'could not list volumes'
        }
        finally {
            $script:r24VolThrow = $false
        }
    }

    It 'finds a loose candidate past the old 10-hit cap (Arg1=2, mocked Rizin)' {
        # Round 23 examined only the first 10 of 125 loose hits; a
        # real candidate at position 15 was never seen. Here Arg1=2,
        # so the strict search (which requires Arg1=1) finds nothing
        # and the loose search must reach hit 15 of 15 to accept it.
        # The real end-to-end proof is e2e_arg1_2_elf.ps1 with real
        # Rizin; this test proves the same cap logic in the suite.
        $elf = Join-Path $script:r24Work 'core-loose.elf'
        New-R24ElfFixture -Path $elf -SegmentSizes @(65536)
        $lines = [System.Collections.Generic.List[string]]::new()
        $result = Invoke-CleanElfBugCheckScan -RizinPath 'C:\fake\rizin.exe' -ElfPath $elf -WorkDir $script:r24Work -Lines $lines
        $result.BugCheck | Should -Not -BeNullOrEmpty
        $result.BugCheck.BugCheckCode | Should -Be '0x5a'
        $result.BugCheck.Arg1 | Should -Be '0x2'
        $result.BugCheck.Arg2 | Should -Be '0xffffba8f4e9f8c50'
        ($lines -join "`n") | Should -Match 'ELF core: 1 PT_LOAD segment'
        ($lines -join "`n") | Should -Match 'strict KiBugCheckData search: 0 hit'
        ($lines -join "`n") | Should -Match 'loose search: examined 15 of 15 hit\(s\) \(1 accepted, 14 rejected\)'
        ($lines -join "`n") | Should -Match 'RESULT \(loose, unconfirmed\)'
    }

    It 'searches guest memory for the dump-disk MBR signature (mocked Rizin)' {
        $elf = Join-Path $script:r24Work 'core-sig.elf'
        New-R24ElfFixture -Path $elf -SegmentSizes @(65536)
        $lines = [System.Collections.Generic.List[string]]::new()
        $result = Invoke-CleanElfBugCheckScan -RizinPath 'C:\fake\rizin.exe' -ElfPath $elf -WorkDir $script:r24Work -DiskSignature 0x12345678 -Lines $lines
        $result.DiskSignatureHits | Should -Be 0
        ($lines -join "`n") | Should -Match 'disk signature 0x12345678: 0 hit'
        ($lines -join "`n") | Should -Match 'disk signature NOT found in guest memory'
    }

    It 'scans anyway when the ELF core header is invalid, and says so' {
        # The validation is diagnostic, not a gate: a truncated or
        # unmapped dump still gets scanned, because Rizin may still
        # find hits the header check cannot see.
        $bad = Join-Path $script:r24Work 'core-scan-bad.elf'
        New-R24ElfFixture -Path $bad -BadMagic
        $lines = [System.Collections.Generic.List[string]]::new()
        $result = Invoke-CleanElfBugCheckScan -RizinPath 'C:\fake\rizin.exe' -ElfPath $bad -WorkDir $script:r24Work -Lines $lines
        ($lines -join "`n") | Should -Match 'ELF core validation failed'
        $result.BugCheck | Should -Not -BeNullOrEmpty
    }

    It 'skips the scan when there is no guest-memory dump file' {
        $lines = [System.Collections.Generic.List[string]]::new()
        $result = Invoke-CleanElfBugCheckScan -RizinPath 'C:\fake\rizin.exe' -ElfPath (Join-Path $script:r24Work 'no-such.elf') -WorkDir $script:r24Work -Lines $lines
        $result.BugCheck | Should -BeNullOrEmpty
        ($lines -join "`n") | Should -Match 'ELF memory scan skipped'
    }

    It 'lists volume contents without .Length on directories and lists volumes on attach success and in the catch' {
        $verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ci\Invoke-CleanQemuVerify.ps1') -Raw
        $capture = $verify.Substring($verify.IndexOf('function Invoke-CleanCrashDumpCapture'))
        $capture.Contains('Format-CleanVolumeContents -Entries $volEntries') | Should -BeTrue
        # The round 23 bug: the old inline format read .Length on
        # every entry, including directories.
        $verify.Contains("'{0} ({1:N0} bytes)' -f `$_.Name, `$_.Length") | Should -BeFalse
        # Add-CleanVolumeList: 3 attach-failure paths + attach success
        # + catch = 5 call sites (round 22's test asserted >= 3).
        ([regex]::Matches($verify, 'Add-CleanVolumeList -Lines', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count | Should -BeGreaterOrEqual 5
        $capture.Contains('if (-not $volumesListed) { Add-CleanVolumeList -Lines $lines }') | Should -BeTrue
        # The dump-file read is guarded: Test-Path before .Length, so
        # a missing dump file writes "NO DUMP FILE" instead of throwing.
        $capture.IndexOf('Test-Path -LiteralPath $dumpFile') | Should -BeLessThan $capture.IndexOf('(Get-Item -LiteralPath $dumpFile).Length')
        $capture.Contains('RESULT: NO DUMP FILE') | Should -BeTrue
    }

    It 'reads the MBR signature before converting and passes it to the ELF scan' {
        $verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ci\Invoke-CleanQemuVerify.ps1') -Raw
        $capture = $verify.Substring($verify.IndexOf('function Invoke-CleanCrashDumpCapture'))
        # The qcow2 is deleted once an image attaches, so the
        # signature must be read before the conversion. (Match the
        # call sites, not the bare names: both names also appear in
        # the header comments above the code.)
        $capture.IndexOf('$sig = Get-CleanDiskSignature') | Should -BeLessThan $capture.IndexOf('$null = ConvertTo-CleanDeSparseDisk')
        $capture.Contains('-DiskSignature $diskSignature') | Should -BeTrue
        # The expected drive letter is stated as a design expectation,
        # not an observation; the volume listing and the signature
        # search are the observation that tests it.
        $capture.Contains('expected drive letter: C:') | Should -BeTrue
        $scan = $verify.Substring($verify.IndexOf('function Invoke-CleanElfBugCheckScan'))
        $scan.Contains('DiskSignatureHits') | Should -BeTrue
        $scan.Contains('disk signature 0x') | Should -BeTrue
        $scan.Contains('disk signature found in guest memory') | Should -BeTrue
        $scan.Contains('disk signature NOT found in guest memory') | Should -BeTrue
    }

    It 'validates the ELF core before scanning and examines more hits' {
        $verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ci\Invoke-CleanQemuVerify.ps1') -Raw
        $scan = $verify.Substring($verify.IndexOf('function Invoke-CleanElfBugCheckScan'))
        $scan.Contains('Test-CleanElfCore -ElfPath $ElfPath') | Should -BeTrue
        $scan.Contains('ELF core:') | Should -BeTrue
        $scan.Contains('ELF core validation failed:') | Should -BeTrue
        $scan.Contains('[Math]::Min(200, $looseHits.Count)') | Should -BeTrue
        $scan.Contains('[Math]::Min(50, $strictHits.Count)') | Should -BeTrue
        $scan.Contains('[Math]::Min(20, $kdbgHits.Count)') | Should -BeTrue
        $scan.Contains('strict search: examined') | Should -BeTrue
        $scan.Contains('loose search: examined') | Should -BeTrue
    }
}

Describe 'Round 26 live KD session and bootlog search' {
    BeforeAll {
        # Same dot-source pattern as the round 21/22/23/24 blocks: the
        # clean verifier launches QEMU on load, so dot-source it with
        # -ParseOnly and hand it real temp files for the mandatory paths.
        $script:r26Dir = Join-Path ([System.IO.Path]::GetTempPath()) "clean-r26-$(Get-Random)"
        $script:r26Share = Join-Path $script:r26Dir 'share'
        New-Item -ItemType Directory -Path $script:r26Share -Force | Out-Null
        $script:r26Iso = Join-Path $script:r26Dir 'test.iso'
        New-Item -ItemType File -Path $script:r26Iso -Force | Out-Null
        $script:r26Work = Join-Path $script:r26Dir 'work'
        New-Item -ItemType Directory -Path $script:r26Work -Force | Out-Null
        $script:r26Code = Join-Path $script:r26Share 'edk2-x86_64-code.fd'
        [System.IO.File]::WriteAllBytes($script:r26Code, (New-Object byte[] 3653632))
        . "$PSScriptRoot/../src/ci/Invoke-CleanQemuVerify.ps1" -ParseOnly -IsoPath $script:r26Iso -OvmfPath $script:r26Code -WorkDir $script:r26Work

        # A synthetic cdb -logo transcript of a 0x5A bugcheck caught
        # live: connect line, the bu command echo (which contains the
        # marker text inside its quotes -- the parser must not mistake
        # it for the .echo output), the breakpoint hit with the register
        # dump and the two `du` strings, then the bugcheck banner.
        $script:r26KdLog = @'
Microsoft (R) Windows Debugger Version 10.0.26100.1 AMD64
Copyright (c) Microsoft Corporation. All rights reserved.

Connected to Windows 10 22621 x64 target at (Thu Nov 26 12:00:00 2026), ptr64 TRUE
Kernel Debugger connection established.
kd> bu nt!KeBugCheckEx ".echo *** KEBUGCHECKEX HIT ***; r; du poi(@r8+8); du poi(@r9+8); ? poi(@rsp+0x20); g"
kd> g
*** KEBUGCHECKEX HIT ***
rax=0000000000000000 rbx=ffffba8f4e9f8c50 rcx=000000000000005a rdx=0000000000000001
r8=ffffba8f4e9f8c50  r9=ffffce06bf0caa90 r10=0000000000000000
\Registry\Machine\SYSTEM\CurrentControlSet\Services\SomeDriver
\SystemRoot\System32\drivers\SomeDriver.sys
Evaluate expression: 18446744073709551640 = ffffffffc0000428
*** Fatal System Error: 0x0000005a
      (0x0000000000000001,0xffffba8f4e9f8c50,0xffffce06bf0caa90,0xffffffffc0000428)
'@

        # Mocked Rizin for the bootlog search: three "Loaded driver"
        # hits, one "Did not load driver" hit at the highest address,
        # and a `ps` read that returns the tail of the log from there.
        $script:r26LoadedHits = @(0x20000, 0x21000, 0x22000)
        $script:r26NotLoadedHits = @(0x23000)
        $script:r26BootlogEmpty = $false
        $script:r26PsOutput = @(
            'Did not load driver \SystemRoot\System32\drivers\fltMgr.sys'
            'Loaded driver \SystemRoot\System32\drivers\lastgood.sys'
        ) -join "`r`n"
        function Invoke-CleanRizinFile {
            param(
                [string] $RizinPath,
                [string] $FilePath,
                [string] $Commands,
                [string] $WorkDir
            )
            if ($script:r26BootlogEmpty) { return '' }
            if ($Commands -match '4c6f6164656420647269766572') {
                return (($script:r26LoadedHits | ForEach-Object { ('0x{0:x} 4 hit.bytes.0' -f $_) }) -join "`n")
            }
            if ($Commands -match '446964206e6f74206c6f616420647269766572') {
                return (($script:r26NotLoadedHits | ForEach-Object { ('0x{0:x} 4 hit.bytes.0' -f $_) }) -join "`n")
            }
            if ($Commands -match 'ps @') { return $script:r26PsOutput }
            return ''
        }
    }

    It 'parses the bugcheck banner and the two du strings out of a live KD log' {
        $parsed = ConvertFrom-CleanKdLog -Content $script:r26KdLog
        $parsed.BugCheck.BugCheckCode | Should -Be '0x0000005a'
        $parsed.BugCheck.Arg1 | Should -Be '0x0000000000000001'
        $parsed.BugCheck.Arg2 | Should -Be '0xffffba8f4e9f8c50'
        $parsed.BugCheck.Arg3 | Should -Be '0xffffce06bf0caa90'
        $parsed.BugCheck.Arg4 | Should -Be '0xffffffffc0000428'
        $parsed.Arg2String | Should -Be '\Registry\Machine\SYSTEM\CurrentControlSet\Services\SomeDriver'
        $parsed.Arg3String | Should -Be '\SystemRoot\System32\drivers\SomeDriver.sys'
        $parsed.Connected | Should -BeTrue
        $parsed.BrokeIn | Should -BeTrue
    }

    It 'does not mistake the bu command echo for the breakpoint firing' {
        # The `kd> bu ...` line contains the marker text inside its
        # quotes; a log that ends there must report BrokeIn false.
        $log = @'
Connected to Windows 10 22621 x64 target at (Thu Nov 26 12:00:00 2026), ptr64 TRUE
kd> bu nt!KeBugCheckEx ".echo *** KEBUGCHECKEX HIT ***; r; du poi(@r8+8); du poi(@r9+8); ? poi(@rsp+0x20); g"
kd> g
'@
        $parsed = ConvertFrom-CleanKdLog -Content $log
        $parsed.BrokeIn | Should -BeFalse
        $parsed.BugCheck | Should -BeNullOrEmpty
        $parsed.Reason | Should -Match 'breakpoint never fired'
    }

    It 'reports an empty KD log as empty instead of inventing parameters' {
        $parsed = ConvertFrom-CleanKdLog -Content ''
        $parsed.BugCheck | Should -BeNullOrEmpty
        $parsed.Connected | Should -BeFalse
        $parsed.Reason | Should -Match 'empty'
    }

    It 'reports a KD log that never connected (timeout branch)' {
        # cdb retries the TCP connect and logs "Waiting to reconnect"
        # until it is killed; the parser must say the session never
        # connected, not guess at parameters.
        $log = @'
Microsoft (R) Windows Debugger Version 10.0.26100.1 AMD64
Waiting to reconnect...
Waiting to reconnect...
'@
        $parsed = ConvertFrom-CleanKdLog -Content $log
        $parsed.BugCheck | Should -BeNullOrEmpty
        $parsed.Connected | Should -BeFalse
        $parsed.Reason | Should -Match 'never connected'
    }

    It 'reports a connected KD session whose breakpoint never fired' {
        $log = @'
Connected to Windows 10 22621 x64 target at (Thu Nov 26 12:00:00 2026), ptr64 TRUE
kd> g
'@
        $parsed = ConvertFrom-CleanKdLog -Content $log
        $parsed.BugCheck | Should -BeNullOrEmpty
        $parsed.Connected | Should -BeTrue
        $parsed.Reason | Should -Match 'breakpoint never fired'
    }

    It 'reports a fired breakpoint with no banner instead of inventing parameters' {
        $log = @'
Connected to Windows 10 22621 x64 target at (Thu Nov 26 12:00:00 2026), ptr64 TRUE
*** KEBUGCHECKEX HIT ***
rax=0000000000000000 rcx=000000000000005a
'@
        $parsed = ConvertFrom-CleanKdLog -Content $log
        $parsed.BrokeIn | Should -BeTrue
        $parsed.BugCheck | Should -BeNullOrEmpty
        $parsed.Reason | Should -Match 'no bugcheck banner'
    }

    It 'returns null from Get-CleanCdbPath on a host without cdb' {
        if ($IsWindows) {
            Set-ItResult -Skipped -Because 'cdb.exe may genuinely be installed on a Windows host (the CI runner image ships it); the not-found branch is covered by the Linux run, and the Windows run covers the parser and wiring instead'
        }
        (Get-CleanCdbPath) | Should -BeNullOrEmpty
    }

    It 'Start-CleanKdSession returns null without throwing when cdb is missing (wiring failure branch)' {
        if ($IsWindows) {
            Set-ItResult -Skipped -Because 'same as the Get-CleanCdbPath test: cdb.exe may exist on Windows, and starting a real session here would leak a debugger process that retries its TCP connect forever'
        }
        $kdLog = Join-Path $script:r26Work 'micpe-kd.log'
        $kdInit = Join-Path $script:r26Work 'kd-init.txt'
        $proc = Start-CleanKdSession -KdPort '50001' -WorkDir $script:r26Work -KdLogPath $kdLog -InitScriptPath $kdInit
        $proc | Should -BeNullOrEmpty
        # The init script is only written once cdb is found.
        (Test-Path -LiteralPath $kdInit) | Should -BeFalse
    }

    It 'wires the serial port to the KD TCP server instead of a file' {
        $verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ci\Invoke-CleanQemuVerify.ps1') -Raw
        $verify.Contains("'-serial', `"tcp:127.0.0.1:`$KdPort,server,nowait`"") | Should -BeTrue
        $verify.Contains("'file:`$serialLog'") | Should -BeFalse
        $verify | Should -Match "\[string\] \`$KdPort = '50001'"
        $verify | Should -Match '\[switch\] \$NoKdSession'
    }

    It 'starts the KD session after the monitor is up and kills it before the capture parses its log' {
        $verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ci\Invoke-CleanQemuVerify.ps1') -Raw
        $verify.IndexOf("'QEMU monitor is up; booting'") | Should -BeLessThan $verify.IndexOf('Start-CleanKdSession -KdPort')
        $verify.IndexOf('Start-CleanKdSession -KdPort') | Should -BeLessThan $verify.IndexOf('Start-Sleep -Seconds $BootWaitSec')
        # The kill sits in the finally block, after QEMU exits and
        # before the capture call (so the -logo file is flushed when
        # it is parsed).
        $verify.IndexOf('$script:kdProc.Kill()') | Should -BeLessThan $verify.IndexOf('Invoke-CleanCrashDumpCapture -Qcow2Path')
        $verify.Contains('-KdLogPath $kdLog') | Should -BeTrue
        # The capture also runs when a KD log exists even if the disk
        # and the ELF are both gone.
        $verify.Contains('(Test-Path -LiteralPath $kdLog)') | Should -BeTrue
    }

    It 'uploads the KD log with the clean verify artifacts and the Release' {
        $buildYml = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\.github\workflows\build.yml') -Raw
        $buildYml | Should -Match 'verify-clean-out/micpe-kd\.log'
        $buildYml | Should -Match "'micpe-kd\.log'"
        # The old serial log is gone from the clean paths (the
        # non-clean verify still produces it, so its entry stays).
        $buildYml.Contains('verify-clean-out/micpe-serial.log') | Should -BeFalse
    }

    It 'writes the live KD parameters into micpe-bugcheck.txt when the disk and ELF are both absent' {
        # The integration proof for the KD path: no qcow2, no ELF, only
        # a KD log -- the capture must still parse it and write the
        # RESULT line (the early return still runs the finally, which
        # writes the report).
        $kdLog = Join-Path $script:r26Work 'micpe-kd.log'
        Set-Content -LiteralPath $kdLog -Value $script:r26KdLog -Encoding utf8
        $result = Invoke-CleanCrashDumpCapture -QemuImgPath 'C:\fake\qemu-img.exe' -WorkDir $script:r26Work -KdLogPath $kdLog
        $result.BugCheck.BugCheckCode | Should -Be '0x0000005a'
        $result.BugCheck.Arg2 | Should -Be '0xffffba8f4e9f8c50'
        $report = Get-Content -LiteralPath (Join-Path $script:r26Work 'micpe-bugcheck.txt') -Raw
        $report | Should -Match 'RESULT \(live KD\): BugCheckCode=0x0000005a'
        $report | Should -Match 'Arg2 \(service registry path, live KD\): \\Registry\\Machine\\SYSTEM\\CurrentControlSet\\Services\\SomeDriver'
        $report | Should -Match 'Arg3 \(driver image path, live KD\): \\SystemRoot\\System32\\drivers\\SomeDriver\.sys'
    }

    It 'writes the KD failure reason into micpe-bugcheck.txt when the log has no bugcheck' {
        $kdLog = Join-Path $script:r26Work 'micpe-kd-empty.log'
        Set-Content -LiteralPath $kdLog -Value 'Waiting to reconnect...' -Encoding utf8
        $result = Invoke-CleanCrashDumpCapture -QemuImgPath 'C:\fake\qemu-img.exe' -WorkDir $script:r26Work -KdLogPath $kdLog
        $result.BugCheck | Should -BeNullOrEmpty
        $report = Get-Content -LiteralPath (Join-Path $script:r26Work 'micpe-bugcheck.txt') -Raw
        $report | Should -Match 'live KD produced no bugcheck parameters: KD never connected'
    }

    It 'reads the bootlog tail out of guest memory (mocked Rizin)' {
        $lines = [System.Collections.Generic.List[string]]::new()
        $found = Invoke-CleanBootlogSearch -RizinPath 'C:\fake\rizin.exe' -ElfPath (Join-Path $script:r26Work 'guest.elf') -WorkDir $script:r26Work -Lines $lines
        $found.Found | Should -BeTrue
        $found.LoadedCount | Should -Be 3
        $found.NotLoadedCount | Should -Be 1
        $found.LastLines.Count | Should -Be 2
        ($lines -join "`n") | Should -Match 'bootlog tail \(highest hit, 0x23000, NotLoaded\)'
        ($lines -join "`n") | Should -Match 'last driver loaded before the crash: \\SystemRoot\\System32\\drivers\\lastgood\.sys'
    }

    It 'reports the bootlog as missing when neither pattern hits' {
        $script:r26BootlogEmpty = $true
        $lines = [System.Collections.Generic.List[string]]::new()
        $found = Invoke-CleanBootlogSearch -RizinPath 'C:\fake\rizin.exe' -ElfPath (Join-Path $script:r26Work 'guest.elf') -WorkDir $script:r26Work -Lines $lines
        $script:r26BootlogEmpty = $false
        $found.Found | Should -BeFalse
        ($lines -join "`n") | Should -Match 'bootlog NOT found in guest memory'
    }

    It 'calls the bootlog search from the ELF scan' {
        $verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ci\Invoke-CleanQemuVerify.ps1') -Raw
        $scan = $verify.Substring($verify.IndexOf('function Invoke-CleanElfBugCheckScan'))
        $scan.Contains('Invoke-CleanBootlogSearch -RizinPath $RizinPath -ElfPath $ElfPath -WorkDir $WorkDir -Lines $Lines') | Should -BeTrue
    }
}

Describe 'Round 27 KD launch probe' {
    BeforeAll {
        # Same dot-source pattern as the round 26 block: the clean
        # verifier launches QEMU on load, so dot-source it with
        # -ParseOnly and hand it real temp files for the mandatory paths.
        $script:r27Dir = Join-Path ([System.IO.Path]::GetTempPath()) "clean-r27-$(Get-Random)"
        $script:r27Share = Join-Path $script:r27Dir 'share'
        New-Item -ItemType Directory -Path $script:r27Share -Force | Out-Null
        $script:r27Iso = Join-Path $script:r27Dir 'test.iso'
        New-Item -ItemType File -Path $script:r27Iso -Force | Out-Null
        $script:r27Work = Join-Path $script:r27Dir 'work'
        New-Item -ItemType Directory -Path $script:r27Work -Force | Out-Null
        $script:r27Code = Join-Path $script:r27Share 'edk2-x86_64-code.fd'
        [System.IO.File]::WriteAllBytes($script:r27Code, (New-Object byte[] 3653632))
        . "$PSScriptRoot/../src/ci/Invoke-CleanQemuVerify.ps1" -ParseOnly -IsoPath $script:r27Iso -OvmfPath $script:r27Code -WorkDir $script:r27Work
        $script:r27Pwsh = (Get-Process -Id $PID).Path
        $script:r27KdLog = Join-Path $script:r27Work 'micpe-kd.log'
        $script:r27KdInit = Join-Path $script:r27Work 'kd-init.txt'
    }

    It 'builds the exact round 26 argv for the baseline variant' {
        $argv = Get-CleanKdArgList -KdPort '50001' -WorkDir $script:r27Work -KdLogPath $script:r27KdLog -InitScriptPath $script:r27KdInit -Variant 'baseline'
        $argv.Count | Should -Be 8
        $argv[0] | Should -Be '-k'
        $argv[1] | Should -Be 'com:ipport=50001,port=127.0.0.1'
        $argv[2] | Should -Be '-y'
        $argv[3] | Should -Be ('SRV*{0}\kd-symbols*https://msdl.microsoft.com/download/symbols' -f $script:r27Work)
        $argv[4] | Should -Be '-logo'
        $argv[5] | Should -Be $script:r27KdLog
        $argv[6] | Should -Be '-c'
        $argv[7] | Should -Be ('$$><{0}' -f $script:r27KdInit)
    }

    It 'adds baud=115200 only for the baud variant' {
        $base = Get-CleanKdArgList -KdPort '50001' -WorkDir $script:r27Work -KdLogPath $script:r27KdLog -InitScriptPath $script:r27KdInit -Variant 'baseline'
        $baud = Get-CleanKdArgList -KdPort '50001' -WorkDir $script:r27Work -KdLogPath $script:r27KdLog -InitScriptPath $script:r27KdInit -Variant 'baud'
        $base[1] | Should -Be 'com:ipport=50001,port=127.0.0.1'
        $baud[1] | Should -Be 'com:ipport=50001,port=127.0.0.1,baud=115200'
        ($baud.Count - $base.Count) | Should -Be 0
    }

    It 'drops the symbol path for the nosymbols variant and the log for nologo' {
        $nosym = Get-CleanKdArgList -KdPort '50001' -WorkDir $script:r27Work -KdLogPath $script:r27KdLog -InitScriptPath $script:r27KdInit -Variant 'nosymbols'
        $nosym | Should -Not -Contain '-y'
        $nosym | Should -Contain '-c'
        $nolog = Get-CleanKdArgList -KdPort '50001' -WorkDir $script:r27Work -KdLogPath $script:r27KdLog -InitScriptPath $script:r27KdInit -Variant 'nologo'
        $nolog | Should -Not -Contain '-logo'
        $nolog | Should -Contain '-c'
    }

    It 'uses the inline breakpoint command (no script file) for inline-c and drops -c for noc' {
        $inline = Get-CleanKdArgList -KdPort '50001' -WorkDir $script:r27Work -KdLogPath $script:r27KdLog -InitScriptPath $script:r27KdInit -Variant 'inline-c'
        $inline | Should -Contain '-c'
        ($inline -join ' ') | Should -Match 'bu nt!KeBugCheckEx'
        ($inline -join ' ') | Should -Not -Match '\$\$>'
        $noc = Get-CleanKdArgList -KdPort '50001' -WorkDir $script:r27Work -KdLogPath $script:r27KdLog -InitScriptPath $script:r27KdInit -Variant 'noc'
        $noc | Should -Not -Contain '-c'
    }

    It 'rejects kd as an argv variant (kd is a binary choice, not an argv shape)' {
        { Get-CleanKdArgList -KdPort '50001' -WorkDir $script:r27Work -KdLogPath $script:r27KdLog -InitScriptPath $script:r27KdInit -Variant 'kd' } | Should -Throw
    }

    It 'writes the two-line init script (breakpoint + go)' {
        Write-CleanKdInitScript -InitScriptPath $script:r27KdInit
        $lines = Get-Content -LiteralPath $script:r27KdInit
        $lines.Count | Should -Be 2
        $lines[0] | Should -Match 'bu nt!KeBugCheckEx'
        $lines[1] | Should -Be 'g'
    }

    It 'finds kd.exe next to cdb.exe and returns null when it is absent' {
        $fakeDir = Join-Path $script:r27Work 'fake-sdk'
        New-Item -ItemType Directory -Path $fakeDir -Force | Out-Null
        $fakeCdb = Join-Path $fakeDir 'cdb.exe'
        New-Item -ItemType File -Path $fakeCdb -Force | Out-Null
        (Get-CleanKdPath -CdbPath $fakeCdb) | Should -BeNullOrEmpty
        $fakeKd = Join-Path $fakeDir 'kd.exe'
        New-Item -ItemType File -Path $fakeKd -Force | Out-Null
        (Get-CleanKdPath -CdbPath $fakeCdb) | Should -Be $fakeKd
        (Get-CleanKdPath -CdbPath $null) | Should -BeNullOrEmpty
    }

    It 'returns null for the debugger version of a missing file' {
        (Get-CleanDebuggerVersion -Path (Join-Path $script:r27Work 'no-such-debugger.exe')) | Should -BeNullOrEmpty
    }

    It 'reports a listening TCP port as up' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        try {
            $listener.Start()
            $port = ([string]$listener.LocalEndpoint.Port)
            (Test-CleanTcpPort -Port $port -TimeoutSec 3) | Should -BeTrue
        }
        finally { $listener.Stop() }
    }

    It 'returns false when nothing listens (unless the sandbox fakes TCP connects)' {
        # Probe first: this sandbox fakes .NET TcpClient.Connect as
        # success even with no listener (round 23 lesson); if it lies
        # here, the negative branch cannot be observed locally and
        # the test skips instead of asserting on the lie.
        $probeClient = [System.Net.Sockets.TcpClient]::new()
        try {
            $probeTask = $probeClient.ConnectAsync('127.0.0.1', 59998)
            $probeDone = $probeTask.Wait(3000)
            $lies = $probeDone -and -not $probeTask.IsFaulted -and -not $probeTask.IsCanceled -and $probeClient.Connected
        }
        finally { $probeClient.Dispose() }
        if ($lies) {
            Set-ItResult -Skipped -Because 'this sandbox fakes .NET TCP connects as success; the negative branch runs for real on the CI Windows runner'
        }
        (Test-CleanTcpPort -Port '59998' -TimeoutSec 3) | Should -BeFalse
    }

    It 'writes the drained console tasks to the console files' {
        $outTask = [System.Threading.Tasks.Task[string]]::FromResult('hello stdout')
        $errTask = [System.Threading.Tasks.Task[string]]::FromResult('hello stderr')
        $fakeProc = [pscustomobject]@{}
        $fakeProc | Add-Member -NotePropertyName 'KdOutTask' -NotePropertyValue $outTask
        $fakeProc | Add-Member -NotePropertyName 'KdErrTask' -NotePropertyValue $errTask
        $outFile = Join-Path $script:r27Work 'console.out'
        $errFile = Join-Path $script:r27Work 'console.err'
        Save-CleanKdConsoleOutput -Process $fakeProc -OutFile $outFile -ErrFile $errFile
        (Get-Content -LiteralPath $outFile -Raw) | Should -Be 'hello stdout'
        (Get-Content -LiteralPath $errFile -Raw) | Should -Be 'hello stderr'
    }

    It 'does nothing when the process has no console tasks' {
        $fakeProc = [pscustomobject]@{}
        $outFile = Join-Path $script:r27Work 'n1.out'
        $errFile = Join-Path $script:r27Work 'n1.err'
        { Save-CleanKdConsoleOutput -Process $fakeProc -OutFile $outFile -ErrFile $errFile } | Should -Not -Throw
        (Test-Path -LiteralPath $outFile) | Should -BeFalse
        (Test-Path -LiteralPath $errFile) | Should -BeFalse
        { Save-CleanKdConsoleOutput -Process $null -OutFile $outFile -ErrFile $errFile } | Should -Not -Throw
    }

    It 'reports a probe attempt alive when the debugger is still running at the timeout (fake pwsh sleep)' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        try {
            $listener.Start()
            $attempt = Invoke-CleanKdProbeAttempt -DebuggerPath $script:r27Pwsh `
                -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep 30') `
                -Listener $listener -WorkDir $script:r27Work -Label 'alive' -ObserveSeconds 2
            $attempt.Alive | Should -BeTrue
            $attempt.ExitCode | Should -BeNullOrEmpty
        }
        finally { $listener.Stop() }
    }

    It 'reports a probe attempt dead with its exit code when the debugger exits fast (fake pwsh exit 57)' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        try {
            $listener.Start()
            $attempt = Invoke-CleanKdProbeAttempt -DebuggerPath $script:r27Pwsh `
                -ArgumentList @('-NoProfile', '-Command', 'exit 57') `
                -Listener $listener -WorkDir $script:r27Work -Label 'dead' -ObserveSeconds 5
            $attempt.Alive | Should -BeFalse
            $attempt.ExitCode | Should -Be 57
            (Test-Path -LiteralPath $attempt.OutFile) | Should -BeTrue
            (Test-Path -LiteralPath $attempt.ErrFile) | Should -BeTrue
        }
        finally { $listener.Stop() }
    }

    It 'writes the console files when the debugger exits immediately (fake pwsh debugger)' {
        # pwsh rejects the unknown -k switch in ~0.3 s (exit 64), so
        # the immediate-exit branch runs; the error text lands in one
        # of the two console files (which one is pwsh-version
        # dependent -- at least one must be non-empty).
        $outFile = Join-Path $script:r27Work 'micpe-kd-console.out'
        $errFile = Join-Path $script:r27Work 'micpe-kd-console.err'
        $proc = Start-CleanKdSession -KdPort '50001' -WorkDir $script:r27Work -KdLogPath $script:r27KdLog -InitScriptPath $script:r27KdInit `
            -DebuggerPath $script:r27Pwsh -Variant 'baseline' -ConsoleOutPath $outFile -ConsoleErrPath $errFile -StartupWaitSec 3
        try {
            $proc | Should -BeNullOrEmpty
        }
        finally {
            if ($null -ne $proc) { try { $proc.Kill() } catch {} }
        }
        (Test-Path -LiteralPath $outFile) | Should -BeTrue
        (Test-Path -LiteralPath $errFile) | Should -BeTrue
        $combined = ((Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue) + (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue))
        $combined.Trim().Length | Should -BeGreaterThan 0
    }

    It 'refuses the noc variant for the real session (probe-only)' {
        $proc = Start-CleanKdSession -KdPort '50001' -WorkDir $script:r27Work -KdLogPath $script:r27KdLog -InitScriptPath $script:r27KdInit `
            -DebuggerPath $script:r27Pwsh -Variant 'noc' -StartupWaitSec 1
        $proc | Should -BeNullOrEmpty
    }

    It 'runs every variant and reports none alive when the debugger always exits (fake pwsh cdb)' {
        # pwsh as the "cdb": every KD argv dies on the unknown -k
        # switch in ~0.3 s, so all six binary-present variants fail
        # fast (kd.exe is absent next to pwsh, so 'kd' is skipped).
        $result = Invoke-CleanKdProbe -WorkDir $script:r27Work -KdLogPath $script:r27KdLog -InitScriptPath $script:r27KdInit `
            -ProbePort 50199 -ObserveSeconds 2 -CdbPath $script:r27Pwsh
        $result.Variant | Should -BeNullOrEmpty
        ($result.Attempts | ForEach-Object { $_.Label }) -join ',' | Should -Be 'baseline,baud,nosymbols,nologo,inline-c,noc'
        foreach ($a in $result.Attempts) { $a.Alive | Should -BeFalse }
        (Test-Path -LiteralPath $result.SummaryPath) | Should -BeTrue
        $summary = Get-Content -LiteralPath $result.SummaryPath -Raw
        $summary | Should -Match 'no variant stays alive'
        foreach ($a in $result.Attempts) {
            (Test-Path -LiteralPath $a.OutFile) | Should -BeTrue
            (Test-Path -LiteralPath $a.ErrFile) | Should -BeTrue
        }
    }

    It 'returns null from the probe when cdb is missing' {
        # No -CdbPath and no real cdb on this Linux host: the probe
        # is inconclusive, not a failure.
        $result = Invoke-CleanKdProbe -WorkDir $script:r27Work -KdLogPath $script:r27KdLog -InitScriptPath $script:r27KdInit -ProbePort 50198 -ObserveSeconds 1
        $result | Should -BeNullOrEmpty
    }

    It 'runs the probe before QEMU starts and uses the winning variant for the real session' {
        $verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ci\Invoke-CleanQemuVerify.ps1') -Raw
        $verify.IndexOf('Invoke-CleanKdProbe -WorkDir') | Should -BeLessThan $verify.IndexOf('starting QEMU:')
        $verify.IndexOf('Test-CleanTcpPort -Port $KdPort') | Should -BeLessThan $verify.IndexOf('Start-CleanKdSession -KdPort')
        $verify.Contains('-Variant $probeVariant') | Should -BeTrue
        $verify.Contains('-DebuggerPath $probeDebugger') | Should -BeTrue
        $verify.Contains('Save-CleanKdConsoleOutput -Process $script:kdProc -OutFile $kdConsoleOut -ErrFile $kdConsoleErr') | Should -BeTrue
    }

    It 'uploads the probe summary and console files with the clean verify artifacts and the Release' {
        $buildYml = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\.github\workflows\build.yml') -Raw
        $buildYml | Should -Match 'verify-clean-out/micpe-kd-probe\.txt'
        $buildYml | Should -Match 'verify-clean-out/micpe-kd-console\.out'
        $buildYml | Should -Match 'verify-clean-out/micpe-kd-console\.err'
        $buildYml | Should -Match 'verify-clean-out/micpe-kd-probe-\*'
        $buildYml | Should -Match "'micpe-kd-probe\.txt'"
        $buildYml | Should -Match "'micpe-kd-console\.out'"
    }

    It 'writes the probe summary and console tails into micpe-bugcheck.txt when the KD log is missing' {
        $probe = Join-Path $script:r27Work 'micpe-kd-probe.txt'
        Set-Content -LiteralPath $probe -Value @('KD launch probe (round 27, fake TCP listener)', 'variant baseline: EXITED fast (exit -2147024809)') -Encoding ASCII
        $cout = Join-Path $script:r27Work 'micpe-kd-console.out'
        Set-Content -LiteralPath $cout -Value @('Microsoft (R) Windows Debugger Version 10.0.26100.1 AMD64', 'Waiting to reconnect...') -Encoding utf8
        $cerr = Join-Path $script:r27Work 'micpe-kd-console.err'
        Set-Content -LiteralPath $cerr -Value @('') -Encoding utf8
        $missingLog = Join-Path $script:r27Work 'no-such-kd.log'
        $result = Invoke-CleanCrashDumpCapture -QemuImgPath 'C:\fake\qemu-img.exe' -WorkDir $script:r27Work `
            -KdLogPath $missingLog -KdProbePath $probe -KdConsoleOutPath $cout -KdConsoleErrPath $cerr
        $result.BugCheck | Should -BeNullOrEmpty
        $report = Get-Content -LiteralPath (Join-Path $script:r27Work 'micpe-bugcheck.txt') -Raw
        $report | Should -Match 'KD launch probe \(round 27, fake TCP listener\)'
        $report | Should -Match 'variant baseline: EXITED fast \(exit -2147024809\)'
        $report | Should -Match 'KD console tail \(micpe-kd-console\.out'
        $report | Should -Match 'Waiting to reconnect'
    }
}

Describe 'Round 28 KD probe winner wiring' {
    BeforeAll {
        # Same dot-source pattern as the round 27 block: the clean
        # verifier launches QEMU on load, so dot-source it with
        # -ParseOnly and hand it real temp files for the mandatory paths.
        $script:r28Dir = Join-Path ([System.IO.Path]::GetTempPath()) "clean-r28-$(Get-Random)"
        $script:r28Share = Join-Path $script:r28Dir 'share'
        New-Item -ItemType Directory -Path $script:r28Share -Force | Out-Null
        $script:r28Iso = Join-Path $script:r28Dir 'test.iso'
        New-Item -ItemType File -Path $script:r28Iso -Force | Out-Null
        $script:r28Work = Join-Path $script:r28Dir 'work'
        New-Item -ItemType Directory -Path $script:r28Work -Force | Out-Null
        $script:r28Code = Join-Path $script:r28Share 'edk2-x86_64-code.fd'
        [System.IO.File]::WriteAllBytes($script:r28Code, (New-Object byte[] 3653632))
        . "$PSScriptRoot/../src/ci/Invoke-CleanQemuVerify.ps1" -ParseOnly -IsoPath $script:r28Iso -OvmfPath $script:r28Code -WorkDir $script:r28Work
        $script:r28Pwsh = (Get-Process -Id $PID).Path
        $script:r28KdLog = Join-Path $script:r28Work 'micpe-kd.log'
        $script:r28KdInit = Join-Path $script:r28Work 'kd-init.txt'
    }

    It 'returns the argv variant (not the probe label) when kd.exe wins' {
        # Round 27 bug: the probe returned the winning LABEL ('kd')
        # as Variant, and Start-CleanKdSession's ValidateSet rightly
        # rejected it ('kd' is a binary choice, not an argv shape),
        # so the real session never started. The probe must return
        # the argv variant ('baseline' for the kd winner) with the
        # kd.exe path -- the exact value that reaches the session.
        if ($IsWindows) {
            Set-ItResult -Skipped -Because 'the fake kd.exe is a Python script with a shebang; it only executes directly on Linux. The wiring is still covered by the session-variant rejection test below'
        }
        $sdk = Join-Path $script:r28Work 'fake-sdk'
        New-Item -ItemType Directory -Path $sdk -Force | Out-Null
        # Fake cdb.exe: a symlink to pwsh, which rejects the unknown
        # -k switch and exits fast (round 27 behaviour). Fake kd.exe:
        # a Python script that ignores its argv and sleeps, so the
        # kd variant is the first survivor.
        $fakeCdb = Join-Path $sdk 'cdb.exe'
        New-Item -ItemType SymbolicLink -Path $fakeCdb -Target $script:r28Pwsh | Out-Null
        $fakeKd = Join-Path $sdk 'kd.exe'
        Set-Content -LiteralPath $fakeKd -Value @('#!/usr/bin/env python3', 'import time', 'time.sleep(30)') -Encoding ascii
        chmod +x $fakeKd
        $result = Invoke-CleanKdProbe -WorkDir $script:r28Work -KdLogPath $script:r28KdLog -InitScriptPath $script:r28KdInit `
            -ProbePort 50197 -ObserveSeconds 2 -CdbPath $fakeCdb
        $result.Label | Should -Be 'kd'
        $result.Variant | Should -Be 'baseline'
        $result.DebuggerPath | Should -Be $fakeKd
        $summary = Get-Content -LiteralPath $result.SummaryPath -Raw
        $summary | Should -Match 'result: variant kd \(.*kd\.exe\) selected for the real session'
        # The returned Variant must be accepted downstream: this is
        # the exact value Start-CleanKdSession hands to
        # Get-CleanKdArgList, so it must not throw here.
        { Get-CleanKdArgList -KdPort '50001' -WorkDir $script:r28Work -KdLogPath $script:r28KdLog -InitScriptPath $script:r28KdInit -Variant $result.Variant } | Should -Not -Throw
    }

    It 'rejects the kd label as a session variant (the probe translates it first)' {
        # The session takes an argv variant; 'kd' is a probe label
        # (binary choice), not an argv shape. If the probe ever
        # handed 'kd' to the session again, this must fail loudly
        # instead of dying silently in CI.
        { Start-CleanKdSession -KdPort '50001' -WorkDir $script:r28Work -KdLogPath $script:r28KdLog -InitScriptPath $script:r28KdInit `
            -DebuggerPath $script:r28Pwsh -Variant 'kd' -StartupWaitSec 1 } | Should -Throw
    }

    It 'uses the real ISO file name in checksums.sha256' {
        # Round 27: checksums.sha256 said MICPE.iso while the
        # Release asset is MICPE-clean.iso (hashes matched, names
        # did not). The name must come from the built ISO path, not
        # a hardcoded string.
        $buildYml = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\.github\workflows\build.yml') -Raw
        $buildYml.Contains('$(Split-Path -Leaf $iso)') | Should -BeTrue
        $buildYml.Contains('"$isoHash  MICPE.iso"') | Should -BeFalse
    }
}
