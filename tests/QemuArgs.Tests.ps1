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
