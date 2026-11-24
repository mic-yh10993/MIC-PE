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
    It 'defaults to the 22621.1105 Enterprise reference build' {
        $script:CleanScriptText | Should -Match '\[string\] \$Build = ''22621\.1105'''
        $script:CleanScriptText | Should -Match '\[string\] \$Edition = ''enterprise'''
    }

    It 'takes the file list, shell release tag and pinned shell SHA256 as parameters' {
        $script:CleanScriptText | Should -Match '\[string\] \$FileList'
        $script:CleanScriptText | Should -Match "ShellReleaseTag = 'shell-20261124'"
        $script:CleanScriptText | Should -Match '8f94801470e20b94129d0b7e294d1c6b413b060dcf6b70f8e9409cee3a94b0bd'
    }

    It 'warns that the file list is a placeholder until the 15:15 diff lands' {
        $script:CleanScriptText | Should -Match 'PLACEHOLDER'
        $script:CleanScriptText | Should -Match '15:15'
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

    It '20-clean-start11.reg carries Start11 settings but no pinned-item groups' {
        $text = $script:RegTexts['20-clean-start11.reg']
        $text | Should -Match 'PE-DEF\\Software\\Stardock\\Start8\\Start8\.ini'
        $text | Should -Match 'System32\\\\MICPE\\\\Start11'
        $text | Should -Not -Match 'Start8\.ini\\Groups'
        $text | Should -Not -Match 'Start8\.ini\\GroupContents'
    }

    It '30-clean-author.reg brands the image SYSTEM-Intel-MIC and drops the Ramos motto' {
        $text = $script:RegTexts['30-clean-author.reg']
        $text | Should -Match '"RegisteredOwner"="SYSTEM-Intel-MIC"'
        $text | Should -Match '"RegisteredOrganization"=-'
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
    It 'the placeholder file list exists, is the reference list minus the deleted apps, and says so' {
        $list = Join-Path $script:DataDir 'clean-22621.1105-enterprise-files.txt'
        Test-Path -LiteralPath $list | Should -Be $true
        $patterns = Read-Whitelist -Path $list
        $patterns.Count | Should -Be 9580
        $patterns | Should -Not -Contain 'Program Files (x86)\Tencent\QQ\Bin\QQ.exe'
        foreach ($excluded in 'Program Files (x86)\Tencent\', 'Program Files (x86)\360Chrome\', 'Program Files (x86)\Thunder\', 'Program Files\Office2010\', 'Program Files\PhotoshopCS3\', 'Program Files\7-Zip\', 'Program Files\PENetwork\', 'Program Files\StartAllBack\', 'Program Files (x86)\Stardock\') {
            @($patterns | Where-Object { $_.StartsWith($excluded, [System.StringComparison]::OrdinalIgnoreCase) }).Count | Should -Be 0 -Because "$excluded must be excluded"
        }
        $header = (Get-Content -LiteralPath $list -TotalCount 12) -join "`n"
        $header | Should -Match 'PLACEHOLDER'
        $header | Should -Match '15:15'
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
        $script:Workflow | Should -Match "Build-CleanPe\.ps1 -Build '22621\.1105' -Edition 'enterprise'"
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
