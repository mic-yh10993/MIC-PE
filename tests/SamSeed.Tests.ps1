BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:SeedScript = Join-Path $script:RepoRoot 'src/build/Invoke-CleanSamSeedRun.ps1'
    $script:SeedScriptText = Get-Content -LiteralPath $script:SeedScript -Raw
    $script:SeedUnattendPath = Join-Path $script:RepoRoot 'src/build/data/sam-seed-unattend.xml'
    $script:SeedUnattendText = Get-Content -LiteralPath $script:SeedUnattendPath -Raw
    $script:CleanScriptText = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src/build/Build-CleanPe.ps1') -Raw
    $script:AdminAccountText = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src/build/lib/AdminAccount.ps1') -Raw
    $script:VerifyScriptText = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src/ci/Invoke-CleanQemuVerify.ps1') -Raw
}

Describe 'seed QEMU has no network (round 42)' {
    It 'passes -nic none to QEMU (user: never give the seed VM network, updates would stall it)' {
        $script:SeedScriptText | Should -Match "'-nic', 'none'"
        $script:SeedScriptText | Should -Not -Match "'-nic', 'user,model=e1000'"
    }

    It 'keeps the verify QEMU on e1000 (kdnet needs the NIC -- only the seed VM goes offline)' {
        $script:VerifyScriptText | Should -Match "'-nic', 'user,model=e1000'"
    }
}

Describe 'seed unattend builds MICPE via OOBE (round 42)' {
    BeforeAll {
        # Parsed here (not in the file-level BeforeAll) so a malformed
        # unattend fails only this Describe, not the NIC / build tests.
        $script:SeedUnattendXml = [xml]$script:SeedUnattendText
    }

    It 'is well-formed XML with an unattend root' {
        $script:SeedUnattendXml.unattend | Should -Not -BeNullOrEmpty
    }

    It 'does not reseal to audit mode (OOBE runs UserAccounts)' {
        $script:SeedUnattendText | Should -Not -Match '<Mode>Audit</Mode>'
        $script:SeedUnattendText | Should -Not -Match '<Reseal>'
    }

    It 'creates MICPE as an Administrators local account with a blank password' {
        $account = $script:SeedUnattendXml.SelectNodes("//*[local-name()='LocalAccount']")
        $account.Count | Should -Be 1
        $account[0].SelectSingleNode("*[local-name()='Name']").InnerText | Should -Be 'MICPE'
        $account[0].SelectSingleNode("*[local-name()='DisplayName']").InnerText | Should -Be 'MICPE'
        $account[0].SelectSingleNode("*[local-name()='Group']").InnerText | Should -Be 'Administrators'
        $account[0].SelectSingleNode("*[local-name()='Password']/*[local-name()='Value']").InnerText | Should -Be ''
        $account[0].SelectSingleNode("*[local-name()='Password']/*[local-name()='PlainText']").InnerText | Should -Be 'true'
    }

    It 'auto-logs on as MICPE with a blank password (the desktop is the blank-password proof)' {
        $auto = $script:SeedUnattendXml.SelectNodes("//*[local-name()='AutoLogon']")
        $auto.Count | Should -Be 1
        $auto[0].SelectSingleNode("*[local-name()='Username']").InnerText | Should -Be 'MICPE'
        $auto[0].SelectSingleNode("*[local-name()='Enabled']").InnerText | Should -Be 'true'
        $auto[0].SelectSingleNode("*[local-name()='LogonCount']").InnerText | Should -Be '1'
        $auto[0].SelectSingleNode("*[local-name()='Password']/*[local-name()='Value']").InnerText | Should -Be ''
        $auto[0].SelectSingleNode("*[local-name()='Password']/*[local-name()='PlainText']").InnerText | Should -Be 'true'
    }

    It 'skips every other OOBE page (winbuild SkipOobe shape, offline: no network or MS account screens)' {
        $oobe = $script:SeedUnattendXml.SelectNodes("//*[local-name()='OOBE']")
        $oobe.Count | Should -Be 1
        $oobe[0].SelectSingleNode("*[local-name()='HideEULAPage']").InnerText | Should -Be 'true'
        $oobe[0].SelectSingleNode("*[local-name()='SkipMachineOOBE']").InnerText | Should -Be 'true'
        $oobe[0].SelectSingleNode("*[local-name()='SkipUserOOBE']").InnerText | Should -Be 'true'
        $oobe[0].SelectSingleNode("*[local-name()='HideOnlineAccountScreens']").InnerText | Should -Be 'true'
        $oobe[0].SelectSingleNode("*[local-name()='HideWirelessSetupInOOBE']").InnerText | Should -Be 'true'
    }

    It 'still targets 22621.1105 (winbuild defaults to 28020 26H1 Beta -- never use it for the seed)' {
        $script:SeedScriptText | Should -Match '\[string\] \$Build = ''22621\.1105'''
        $script:SeedScriptText | Should -Not -Match '28020'
    }

    It 'does not slim, install Office, or activate (user forbids: too slow, not needed for a seed)' {
        # The header comment names the forbidden things to say they are
        # NOT done; strip comments so the assertion covers the XML body.
        # MAS/Office are matched case-sensitively as whole words: the
        # unattend namespace URI itself contains "schemas" (mas).
        $body = $script:SeedUnattendText -replace '(?s)<!--.*?-->', ''
        [regex]::IsMatch($body, '\bMAS\b') | Should -BeFalse
        [regex]::IsMatch($body, '\bOffice\b') | Should -BeFalse
        $body | Should -Not -Match 'Activate'
        $body | Should -Not -Match 'slim'
    }

    It 'keeps ComputerName SEEDVM in specialize' {
        $name = $script:SeedUnattendXml.SelectNodes("//*[local-name()='ComputerName']")
        $name.Count | Should -Be 1
        $name[0].InnerText | Should -Be 'SEEDVM'
    }
}

Describe 'seed hive verification expects MICPE (round 42)' {
    It 'requires MICPE in Users\Names (not the built-in Administrator)' {
        $script:SeedScriptText | Should -Match "notcontains 'MICPE'"
        $script:SeedScriptText | Should -Not -Match "notcontains 'Administrator'"
    }

    It 'reads the F value of RID 1000 (000003E8), not RID 500' {
        $script:SeedScriptText | Should -Match 'Users\\000003E8'
        $script:SeedScriptText | Should -Not -Match 'Users\\000001F4'
    }

    It 'requires MICPE enabled (ACB_DISABLED clear -- a UserAccounts admin is enabled by construction)' {
        $script:SeedScriptText | Should -Match 'MICPE is flagged disabled'
    }

    It 'requires MICPE in the Administrators alias (00000220) membership' {
        $script:SeedScriptText | Should -Match '00000220'
        $script:SeedScriptText | Should -Match '-1000'
    }
}

Describe 'build seeds SAM/SECURITY before the registry step (round 42)' {
    It 'defines Invoke-CleanSamSeedStep reading the seed inputs and manifest' {
        $script:CleanScriptText | Should -Match 'function Invoke-CleanSamSeedStep'
        $script:CleanScriptText | Should -Match 'sam-seed'
        $script:CleanScriptText | Should -Match 'manifest'
        $script:CleanScriptText | Should -Match 'SHA256'
    }

    It 'calls the seed step before the registry step' {
        $callSeed = $script:CleanScriptText.LastIndexOf('Invoke-CleanSamSeedStep -StagingDir')
        $callSeed | Should -BeGreaterThan 0
        $callReg = $script:CleanScriptText.LastIndexOf('Invoke-CleanRegistryStep -AppRegFiles')
        $callReg | Should -BeGreaterThan 0
        $callSeed | Should -BeLessThan $callReg
    }

    It 'enables MICPE (RID 1000) in the staging SAM' {
        $registryStep = ($script:CleanScriptText -split 'function Invoke-CleanRegistryStep')[1] -split 'function Assert-ReadBack' | Select-Object -First 1
        $registryStep | Should -Match "-AccountName 'MICPE'"
        $registryStep | Should -Match "-RidHex '000003E8'"
    }

    It 'fails the build if the staging SAM is still empty after seeding (round 41: the SAM service does NOT create accounts at boot)' {
        $registryStep = ($script:CleanScriptText -split 'function Invoke-CleanRegistryStep')[1] -split 'function Assert-ReadBack' | Select-Object -First 1
        $registryStep | Should -Match 'still empty after the seed step'
        $registryStep | Should -Match 'SAM service does NOT create the built-in accounts at boot'
        $registryStep | Should -Not -Match 'the SAM service creates the built-in accounts at boot, so the offline enable step is skipped'
    }
}

Describe 'offline admin enable targets a RID (round 42)' {
    It 'takes a RidHex parameter defaulting to the built-in Administrator (000001F4)' {
        $script:AdminAccountText | Should -Match '\[string\] \$RidHex = ''000001F4'''
    }

    It 'builds the SAM key from the RID parameter, not a hardcoded RID' {
        $loaderBody = ($script:AdminAccountText -split "body = @'")[1] -split "'@" | Select-Object -First 1
        $loaderBody | Should -Match '__RID__'
        $loaderBody | Should -Not -Match '000001F4'
        $script:AdminAccountText | Should -Match 'Replace\(''__RID__'', \$RidHex\)'
    }
}

Describe 'seed diskpart accepts a string array (round 42 rerun)' {
    BeforeAll {
        # Extract the real Invoke-SeedDiskpart from the seed script
        # (brace-counting scan), so the tests exercise the shipped
        # function, not a copy. run 45981633632 died here: the 4 call
        # sites pass @(...) but -Script was [string].
        $start = $script:SeedScriptText.IndexOf('function Invoke-SeedDiskpart')
        $open = $script:SeedScriptText.IndexOf('{', $start)
        $depth = 0
        $end = $open
        for ($i = $open; $i -lt $script:SeedScriptText.Length; $i++) {
            $ch = $script:SeedScriptText[$i]
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') {
                $depth--
                if ($depth -eq 0) { $end = $i; break }
            }
        }
        $script:SeedDiskpartFuncText = $script:SeedScriptText.Substring($start, $end - $start + 1)

        # Mock diskpart: capture exactly what the function pipes to it,
        # and report success so the exit-code check passes.
        function diskpart {
            $global:SeedDiskpartCaptured = @($input)
            $global:LASTEXITCODE = 0
        }
        . ([scriptblock]::Create($script:SeedDiskpartFuncText))
    }

    AfterEach {
        $global:SeedDiskpartCaptured = @()
    }

    It 'accepts a string array argument (the 4 call sites pass @(...) -- [string] rejected it in run 45981633632)' {
        { Invoke-SeedDiskpart -Label 'test' -Script @('select vdisk file="x"', 'detach vdisk') } | Should -Not -Throw
    }

    It 'joins the array into a single script before feeding diskpart' {
        Invoke-SeedDiskpart -Label 'test' -Script @('select vdisk file="x"', 'detach vdisk')
        $global:SeedDiskpartCaptured.Count | Should -Be 1
        $global:SeedDiskpartCaptured[0] | Should -Be "select vdisk file=`"x`"`ndetach vdisk"
    }

    It 'declares -Script as [string[]] (not [string])' {
        $script:SeedDiskpartFuncText | Should -Match '\[string\[\]\] \$Script'
        $script:SeedDiskpartFuncText | Should -Not -Match '\[string\] \$Script'
    }

    It 'has no trailing -join at the call sites (it parses as a -join parameter and fails binding)' {
        $script:SeedScriptText | Should -Not -Match '\) -join "`n"'
    }
}

Describe 'seed bcdboot prerequisites are verified before bcdboot (round 42 bcdboot fix)' {
    BeforeAll {
        # Extract the real Assert-SeedBcdbootPrerequisites (brace-counting
        # scan, same pattern as the diskpart tests), so the tests
        # exercise the shipped function, not a copy. run 45988904072
        # died at bcdboot: host bcdboot 26100 failed on the 22621
        # image, exit 193, and the log never proved S: was readable.
        $start = $script:SeedScriptText.IndexOf('function Assert-SeedBcdbootPrerequisites')
        $open = $script:SeedScriptText.IndexOf('{', $start)
        $depth = 0
        $end = $open
        for ($i = $open; $i -lt $script:SeedScriptText.Length; $i++) {
            $ch = $script:SeedScriptText[$i]
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') {
                $depth--
                if ($depth -eq 0) { $end = $i; break }
            }
        }
        $script:SeedBcdbootPrereqFuncText = $script:SeedScriptText.Substring($start, $end - $start + 1)
        . ([scriptblock]::Create($script:SeedBcdbootPrereqFuncText))

        # Mock the Windows-only probes (Storage cmdlets, fsutil) with
        # global functions shadowing the real commands; state lives in
        # globals so each test can break exactly one thing. The mocks
        # are (re)defined by every behavior test itself: AfterEach
        # removes them after each test, so defining them once in
        # BeforeAll would leave the later tests unmocked.
        function Set-SeedBcdbootMocksOk {
            $global:MockSeedVolumes = @{
                S = [pscustomobject]@{ DriveLetter = 'S'; FileSystem = 'FAT32'; HealthStatus = 'Healthy'; Size = 272629760 }
                V = [pscustomobject]@{ DriveLetter = 'V'; FileSystem = 'NTFS'; HealthStatus = 'Healthy'; Size = 34359738368 }
            }
            $global:MockSeedPartitions = @{
                S = [pscustomobject]@{ DriveLetter = 'S'; PartitionNumber = 1; GptType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }
            }
            $global:MockSeedPaths = @{
                'S:\'                                      = $true
                'V:\Windows'                               = $true
                'V:\Windows\Boot\EFI\bootmgfw.efi'         = $true
                'V:\Windows\System32\config\BCD-Template' = $true
                'V:\Windows\System32\bcdboot.exe'          = $true
            }
            function global:Get-Volume {
                [CmdletBinding()]
                param([string] $DriveLetter)
                if ($global:MockSeedVolumes.ContainsKey($DriveLetter)) { return $global:MockSeedVolumes[$DriveLetter] }
                throw "No MSFT_Volume objects found with property 'DriveLetter' equal to '$DriveLetter'"
            }
            function global:Get-Partition {
                [CmdletBinding()]
                param([string] $DriveLetter)
                if ($global:MockSeedPartitions.ContainsKey($DriveLetter)) { return $global:MockSeedPartitions[$DriveLetter] }
                throw "No MSFT_Partition objects found with property 'DriveLetter' equal to '$DriveLetter'"
            }
            function global:Test-Path {
                [CmdletBinding()]
                param([string] $LiteralPath, [string] $Path)
                $key = if ($LiteralPath) { $LiteralPath } else { $Path }
                if ($null -ne $key -and $global:MockSeedPaths.ContainsKey($key)) { return $global:MockSeedPaths[$key] }
                return $false
            }
            function global:Get-ChildItem {
                [CmdletBinding()]
                param([string] $LiteralPath, [string] $Path, [switch] $Force)
                return @()
            }
            function global:fsutil.exe {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments = $true)] $Args)
                return @('Volume ###  ...', 'File System Name : FAT32', '... ')
            }
        }
    }

    AfterEach {
        Remove-Item function:Get-Volume -ErrorAction SilentlyContinue
        Remove-Item function:Get-Partition -ErrorAction SilentlyContinue
        Remove-Item function:Test-Path -ErrorAction SilentlyContinue
        Remove-Item function:Get-ChildItem -ErrorAction SilentlyContinue
        Remove-Item function:fsutil.exe -ErrorAction SilentlyContinue
    }

    It 'defines the gate and calls it between DISM apply and the bcdboot invocation' {
        $script:SeedScriptText | Should -Match 'function Assert-SeedBcdbootPrerequisites'
        $dism = $script:SeedScriptText.IndexOf('dism.exe /Apply-Image')
        $dism | Should -BeGreaterThan 0
        $gateCall = [regex]::Match($script:SeedScriptText, '(?m)^\s+Assert-SeedBcdbootPrerequisites\s*$')
        $gateCall.Success | Should -BeTrue
        $gateCall.Index | Should -BeGreaterThan $dism
        $boot = $script:SeedScriptText.IndexOf('& $imageBcdboot V:\Windows /s S: /f UEFI')
        $boot | Should -BeGreaterThan 0
        $gateCall.Index | Should -BeLessThan $boot
    }

    It 'checks S: readability explicitly (user question: is the EFI partition attached?)' {
        $script:SeedBcdbootPrereqFuncText | Should -Match "Test-Path -LiteralPath 'S:\\'"
        $script:SeedBcdbootPrereqFuncText | Should -Match 'Get-Volume -DriveLetter S'
        $script:SeedBcdbootPrereqFuncText | Should -Match "Get-ChildItem -LiteralPath 'S:\\'"
        $script:SeedBcdbootPrereqFuncText | Should -Match 'fsutil\.exe fsinfo volumeinfo S:'
        $script:SeedBcdbootPrereqFuncText | Should -Match 'is the EFI partition actually attached'
    }

    It 'checks the S: GPT type is the EFI System Partition' {
        $script:SeedBcdbootPrereqFuncText | Should -Match 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
        $script:SeedBcdbootPrereqFuncText | Should -Match 'Get-Partition -DriveLetter S'
    }

    It 'checks the source boot files including the image bcdboot.exe' {
        $script:SeedBcdbootPrereqFuncText | Should -Match 'V:\\Windows\\Boot\\EFI\\bootmgfw\.efi'
        $script:SeedBcdbootPrereqFuncText | Should -Match 'V:\\Windows\\System32\\config\\BCD-Template'
        $script:SeedBcdbootPrereqFuncText | Should -Match 'V:\\Windows\\System32\\bcdboot\.exe'
    }

    It 'runs the applied image bcdboot, not the host bcdboot (round 42: host 26100 failed on the 22621 image, exit 193)' {
        $script:SeedScriptText | Should -Match "\$imageBcdboot = 'V:\\Windows\\System32\\bcdboot\.exe'"
        $script:SeedScriptText | Should -Match '& \$imageBcdboot V:\\Windows /s S: /f UEFI'
        $script:SeedScriptText | Should -Not -Match '& bcdboot\.exe V:\\Windows /s S: /f UEFI'
    }

    It 'passes when everything is present (S: attached, FAT32, ESP, readable; boot files present)' {
        Set-SeedBcdbootMocksOk
        $result = Assert-SeedBcdbootPrerequisites
        $result.SReadable | Should -BeTrue
        $result.SFileSystem | Should -Be 'FAT32'
        $result.BootmgfwExists | Should -BeTrue
        $result.BcdTemplateExists | Should -BeTrue
        $result.ImageBcdbootExists | Should -BeTrue
    }

    It 'fails naming S: when the EFI partition is not readable at bcdboot time' {
        Set-SeedBcdbootMocksOk
        $global:MockSeedPaths['S:\'] = $false
        { Assert-SeedBcdbootPrerequisites } | Should -Throw '*S:*readable*'
    }

    It 'fails naming the GPT type when S: is not an EFI System Partition' {
        Set-SeedBcdbootMocksOk
        $global:MockSeedPartitions['S'].GptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
        { Assert-SeedBcdbootPrerequisites } | Should -Throw '*GPT type*'
    }

    It 'fails naming the file when bootmgfw.efi is missing' {
        Set-SeedBcdbootMocksOk
        $global:MockSeedPaths['V:\Windows\Boot\EFI\bootmgfw.efi'] = $false
        { Assert-SeedBcdbootPrerequisites } | Should -Throw '*bootmgfw.efi*'
    }

    It 'fails naming the file when the image bcdboot.exe is missing' {
        Set-SeedBcdbootMocksOk
        $global:MockSeedPaths['V:\Windows\System32\bcdboot.exe'] = $false
        { Assert-SeedBcdbootPrerequisites } | Should -Throw '*bcdboot.exe*'
    }
}
