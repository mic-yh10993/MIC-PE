BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Registry.ps1"
    . "$PSScriptRoot/../src/build/lib/Brand.ps1"
    $script:TempRoot = [System.IO.Path]::GetTempPath()
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path

    function New-FakeMount {
        $root = Join-Path $script:TempRoot "mnt-$(Get-Random)"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return $root
    }

    function New-FakeBrandMount {
        # A fake mount with the files Set-Brand lays down.
        $m = New-FakeMount
        New-Item -ItemType Directory -Force -Path "$m/Windows/System32" | Out-Null
        New-Item -ItemType Directory -Force -Path "$m/Windows/Web/Wallpaper/Windows" | Out-Null
        New-Item -ItemType Directory -Force -Path "$m/Program Files/MICPE" | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'assets/logo.bmp') -Destination "$m/Windows/System32/oemlogo.bmp" -Force
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'assets/wallpaper.jpg') -Destination "$m/Windows/Web/Wallpaper/Windows/img0.jpg" -Force
        $utf8Bom = [System.Text.UTF8Encoding]::new($true)
        [System.IO.File]::WriteAllText("$m/Program Files/MICPE/说明.txt", (Get-BrandReadmeContent), $utf8Bom)
        return $m
    }
}

Describe 'brand registry patch' {
    BeforeAll {
        $script:r = Get-BrandRegContent -Version '1.0.0' -BuildNumber '26200.10066'
    }

    It 'writes OEMInformation under PE-SOFT' {
        $script:r | Should -Match 'HKEY_LOCAL_MACHINE\\PE-SOFT\\Microsoft\\Windows\\CurrentVersion\\OEMInformation'
        $script:r | Should -Match '"Manufacturer"="MICPE"'
        $script:r | Should -Match '"Model"="SYSTEM-Intel-MIC"'
        $script:r | Should -Match '"SupportProvider"="SYSTEM-Intel-MIC"'
        $script:r | Should -Match '"SupportURL"="https://space\.bilibili\.com/1978487514"'
    }

    It 'points Logo at oemlogo.bmp' {
        # Doubled backslashes inside the string value: reg.exe import
        # un-escapes them (same convention as 20-explorer.reg). The dot
        # before bmp is a plain dot, not an escaped backslash.
        $script:r | Should -Match 'Logo"="%SystemRoot%\\\\System32\\\\oemlogo\.bmp"'
    }

    It 'registers the author as owner and organization' {
        $script:r | Should -Match 'HKEY_LOCAL_MACHINE\\PE-SOFT\\Microsoft\\Windows NT\\CurrentVersion'
        $script:r | Should -Match '"RegisteredOwner"="SYSTEM-Intel-MIC"'
        $script:r | Should -Match '"RegisteredOrganization"="MICPE"'
    }

    It 'stamps version, build and computer name' {
        $script:r | Should -Match '; Version 1\.0\.0 build 26200\.10066'
        $script:r | Should -Match 'HKEY_LOCAL_MACHINE\\PE-SYS\\ControlSet001\\Control\\ComputerName\\ComputerName'
        $script:r | Should -Match '"ComputerName"="MICPE-XXXX"'
    }

    It 'honours the version and computer name parameters' {
        $custom = Get-BrandRegContent -Version '9.9.9' -BuildNumber '26300.1' -ComputerName 'MICPE-TEST'
        $custom | Should -Match '; Version 9\.9\.9 build 26300\.1'
        $custom | Should -Match '"ComputerName"="MICPE-TEST"'
    }

    It 'is the exact text committed as src/registry/50-brand.reg' {
        # 50-brand.reg is a generated file: the committed copy must match
        # Get-BrandRegContent for the default inputs, or it has drifted.
        $committed = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src/registry/50-brand.reg') -Raw -Encoding Unicode
        $committed | Should -Be (Get-BrandRegContent)
    }
}

Describe 'brand readme' {
    It 'names the version, build, author and homepage' {
        $t = Get-BrandReadmeContent -Version '1.0.0' -BuildNumber '26200.10066'
        $t | Should -Match 'MICPE'
        $t | Should -Match '1\.0\.0'
        $t | Should -Match '26200\.10066'
        $t | Should -Match 'SYSTEM-Intel-MIC'
        $t | Should -Match 'space\.bilibili\.com/1978487514'
    }
}

Describe 'BMP dimensions' {
    It 'reads the committed logo.bmp as 120x120x24bpp' {
        $dims = Get-BmpDimensions -Path (Join-Path $script:RepoRoot 'assets/logo.bmp')
        $dims.Width | Should -Be 120
        $dims.Height | Should -Be 120
        $dims.BitsPerPixel | Should -Be 24
    }

    It 'rejects a non-BMP file' {
        $f = Join-Path $script:TempRoot "notbmp-$(Get-Random).bmp"
        Set-Content -LiteralPath $f -Value 'not a bitmap at all, just text padding..................'
        { Get-BmpDimensions -Path $f } | Should -Throw '*not a BMP*'
    }
}

Describe 'Assert-BrandApplied' {
    It 'names every missing artifact' {
        $m = New-FakeMount
        $msg = try { Assert-BrandApplied -MountDir $m } catch { $_.Exception.Message }
        $msg | Should -Match 'oemlogo\.bmp'
        $msg | Should -Match 'img0\.jpg'
        $msg | Should -Match '说明\.txt'
    }

    It 'passes when all artifacts exist' {
        $m = New-FakeBrandMount
        { Assert-BrandApplied -MountDir $m } | Should -Not -Throw
    }

    It 'rejects a wrong-size logo' {
        $m = New-FakeBrandMount
        # Shrink the logo in place: patch the width/height fields in the
        # BMP header (bytes 18..26) to 100x100 and re-check.
        $logo = "$m/Windows/System32/oemlogo.bmp"
        $bytes = [System.IO.File]::ReadAllBytes($logo)
        [System.BitConverter]::GetBytes([int]100).CopyTo($bytes, 18)
        [System.BitConverter]::GetBytes([int]100).CopyTo($bytes, 22)
        [System.IO.File]::WriteAllBytes($logo, $bytes)
        $msg = try { Assert-BrandApplied -MountDir $m } catch { $_.Exception.Message }
        $msg | Should -Match '100x100'
    }

    It 'rejects a readme missing the author marker' {
        $m = New-FakeBrandMount
        Set-Content -LiteralPath "$m/Program Files/MICPE/说明.txt" -Value 'MICPE' -Encoding UTF8
        $msg = try { Assert-BrandApplied -MountDir $m } catch { $_.Exception.Message }
        $msg | Should -Match 'SYSTEM-Intel-MIC'
    }
}

Describe 'Set-Brand against a real hive' {
    It 'installs wallpaper, logo, readme and registry into the mount' {
        if (-not $IsWindows) { Set-ItResult -Skipped -Because 'needs reg.exe and a real SOFTWARE hive'; return }

        $m = New-FakeMount
        New-Item -ItemType Directory -Force -Path "$m/Windows/System32/config" | Out-Null
        # Snapshot both hives the brand patch touches: 50-brand.reg has
        # PE-SOFT (SOFTWARE) and PE-SYS (SYSTEM) keys, and reg.exe import
        # fails the whole file when a referenced root key is not mounted.
        $hiveCopy = "$m/Windows/System32/config/SOFTWARE"
        $null = & reg.exe save 'HKLM\SOFTWARE' $hiveCopy /y 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'reg save SOFTWARE failed' }
        $systemCopy = "$m/Windows/System32/config/SYSTEM"
        $null = & reg.exe save 'HKLM\SYSTEM' $systemCopy /y 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'reg save SYSTEM failed' }
        try {
            Set-Brand -MountDir $m -RepoRoot $script:RepoRoot
            { Assert-BrandApplied -MountDir $m } | Should -Not -Throw

            # Registry landed in the hive copy, not the live registry:
            # read it back through a fresh mount of the same file.
            Mount-RegistryHive -HiveFile $hiveCopy -KeyName 'MICPE-BRAND-TEST'
            try {
                $oem = & reg.exe query 'HKLM\MICPE-BRAND-TEST\Microsoft\Windows\CurrentVersion\OEMInformation' 2>&1
                ($oem -join "`n") | Should -Match 'MICPE'
                ($oem -join "`n") | Should -Match '1978487514'
            }
            finally {
                Dismount-RegistryHive -KeyName 'MICPE-BRAND-TEST'
            }
        }
        finally {
            Remove-Item -LiteralPath $m -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
