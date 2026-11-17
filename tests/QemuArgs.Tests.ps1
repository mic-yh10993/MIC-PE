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
