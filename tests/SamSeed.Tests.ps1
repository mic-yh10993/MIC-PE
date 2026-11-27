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
        # Extract the real Assert-SeedBcdbootPrerequisites and its
        # helper Get-SeedDiskpartVolumeNumber (brace-counting scan,
        # same pattern as the diskpart tests), so the tests exercise
        # the shipped functions, not copies. run 45988904072 died
        # at bcdboot: host bcdboot 26100 failed on the 22621 image,
        # exit 193, and the log never proved S: was readable.
        function Extract-SeedFunction {
            param([string] $Name)
            $start = $script:SeedScriptText.IndexOf("function $Name")
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
            return $script:SeedScriptText.Substring($start, $end - $start + 1)
        }
        $script:SeedDiskpartVolumeFuncText = Extract-SeedFunction -Name 'Get-SeedDiskpartVolumeNumber'
        . ([scriptblock]::Create($script:SeedDiskpartVolumeFuncText))
        $script:SeedBcdbootPrereqFuncText = Extract-SeedFunction -Name 'Assert-SeedBcdbootPrerequisites'
        . ([scriptblock]::Create($script:SeedBcdbootPrereqFuncText))

        # Mock the Windows-only probes (Storage cmdlets, CIM, diskpart,
        # fsutil) with global functions shadowing the real commands;
        # state lives in globals so each test can break exactly one
        # thing. The mocks are (re)defined by every behavior test
        # itself: AfterEach removes them after each test, so defining
        # them once in BeforeAll would leave the later tests unmocked.
        # Run 46004055968: the gate no longer asks Get-Volume /
        # Get-Partition -DriveLetter S (the Storage provider is blind
        # to ESP drive letters) -- S: is proven via Win32_Volume with
        # a Test-Path fallback, and the GPT type via diskpart. Run
        # 46017835896: `convert gpt` auto-creates an MSR as partition
        # 1, so the ESP is partition 2 (S:, Volume 3) and the primary
        # is partition 3 (V:, Volume 4, label SEED) -- the mocks
        # reproduce that layout, and the diskpart mock dispatches on
        # the piped commands: a `select partition 1` probe gets the
        # MSR detail (the old gate's mistake), a `list volume` probe
        # gets the volume table, anything else gets the ESP detail.
        # The default mocks reproduce the CI state: Win32_Volume does
        # NOT list S: (empty MockSeedCimVolumes), so the default pass
        # path is the Test-Path fallback + the diskpart volume-letter
        # lookup + detail parse.
        function Set-SeedBcdbootMocksOk {
            $global:MockSeedVolumes = @{
                S = [pscustomobject]@{ DriveLetter = 'S'; FileSystem = 'FAT32'; HealthStatus = 'Healthy'; Size = 272629760 }
                V = [pscustomobject]@{ DriveLetter = 'V'; FileSystem = 'NTFS'; HealthStatus = 'Healthy'; Size = 34359738368 }
            }
            $global:MockSeedCimVolumes = @{}
            $global:MockSeedDiskpartListVolume = @(
                '  Disk ###  Status      Size     Free     Dyn  Gpt'
                '  --------  ----------  -------  -------  ---  ---'
                '  Disk 0    Online       127 GB      0 B        *'
                '  Disk 1    Online        32 GB      0 B        *'
                '  Volume ###  Ltr  Label        Fs     Type        Size     Status     Info'
                '  ----------  ---  -----------  -----  ----------  -------  ---------  --------'
                '  Volume 0     C                NTFS   Partition    127 GB  Healthy    Boot'
                '  Volume 3     S   SYSTEM       FAT32  Partition    260 MB  Healthy'
                '  Volume 4     V   SEED         NTFS   Partition     31 GB  Healthy'
            )
            $global:MockSeedDiskpartDetail = @(
                'Partition 2'
                'Type    : c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
                'Hidden  : Yes'
                'Required: Yes'
                'Attribute : 0X8000000000000001'
                'Offset in Bytes: 1024 KB'
                '  Volume ###  Ltr  Label        Fs     Type        Size     Status     Info'
                '  ----------  ---  -----------  -----  ----------  -------  ---------  --------'
                '* Volume 3     S  SYSTEM       FAT32  Partition    260 MB  Healthy    Hidden'
            )
            $global:MockSeedDiskpartMsrDetail = @(
                'Partition 1'
                'Type    : e3c9e316-0b5c-4db8-817d-f92df00215ae'
                'Hidden  : Yes'
                'Required: Yes'
                'Attrib  : 0000000000000000'
                'Offset  : 1024 KB'
            )
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
            function global:Get-CimInstance {
                [CmdletBinding()]
                param([string] $ClassName, [string] $Filter)
                if ($ClassName -eq 'Win32_Volume' -and $Filter -like "*DriveLetter='S:'*" -and $global:MockSeedCimVolumes.ContainsKey('S')) {
                    return $global:MockSeedCimVolumes['S']
                }
                return $null
            }
            function global:diskpart {
                [CmdletBinding()]
                param([Parameter(ValueFromPipeline = $true)] $InputObject)
                begin { $global:MockSeedDiskpartInput = '' }
                process { $global:MockSeedDiskpartInput += "$InputObject`n" }
                end {
                    if ($global:MockSeedDiskpartInput -match 'select partition 1') { return $global:MockSeedDiskpartMsrDetail }
                    if ($global:MockSeedDiskpartInput -match 'list volume') { return $global:MockSeedDiskpartListVolume }
                    return $global:MockSeedDiskpartDetail
                }
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
        Remove-Item function:Get-CimInstance -ErrorAction SilentlyContinue
        Remove-Item function:diskpart -ErrorAction SilentlyContinue
        Remove-Item function:Test-Path -ErrorAction SilentlyContinue
        Remove-Item function:Get-ChildItem -ErrorAction SilentlyContinue
        Remove-Item function:fsutil.exe -ErrorAction SilentlyContinue
    }

    It 'defines the gate and calls it between DISM apply and the bcdboot invocation' {
        $script:SeedScriptText | Should -Match 'function Assert-SeedBcdbootPrerequisites'
        $dism = $script:SeedScriptText.IndexOf('dism.exe /Apply-Image')
        $dism | Should -BeGreaterThan 0
        $gateCall = [regex]::Match($script:SeedScriptText, '(?m)^\s+Assert-SeedBcdbootPrerequisites -VhdPath \$vhdx\s*$')
        $gateCall.Success | Should -BeTrue
        $gateCall.Index | Should -BeGreaterThan $dism
        $boot = $script:SeedScriptText.IndexOf('& $imageBcdboot V:\Windows /s S: /f UEFI')
        $boot | Should -BeGreaterThan 0
        $gateCall.Index | Should -BeLessThan $boot
    }

    It 'checks S: readability explicitly (user question: is the EFI partition attached?)' {
        $script:SeedBcdbootPrereqFuncText | Should -Match "Test-Path -LiteralPath 'S:\\'"
        $script:SeedBcdbootPrereqFuncText | Should -Match 'Win32_Volume'
        $script:SeedBcdbootPrereqFuncText | Should -Match "Get-ChildItem -LiteralPath 'S:\\'"
        $script:SeedBcdbootPrereqFuncText | Should -Match 'fsutil\.exe fsinfo volumeinfo S:'
        $script:SeedBcdbootPrereqFuncText | Should -Match 'is the EFI partition actually attached'
    }

    It 'checks the S: GPT type is the EFI System Partition (selected by volume letter, never by partition number)' {
        $script:SeedBcdbootPrereqFuncText | Should -Match 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
        $script:SeedBcdbootPrereqFuncText | Should -Match 'detail partition'
        $script:SeedBcdbootPrereqFuncText | Should -Match 'select volume'
        $script:SeedBcdbootPrereqFuncText | Should -Match 'list partition'
        $script:SeedBcdbootPrereqFuncText | Should -Match 'detail disk'
        $script:SeedBcdbootPrereqFuncText | Should -Not -Match 'select partition 1'
        # The list disk / list volume probe lives in the helper the
        # gate calls (Get-SeedDiskpartVolumeNumber), not in the gate.
        $script:SeedDiskpartVolumeFuncText | Should -Match 'list disk'
        $script:SeedDiskpartVolumeFuncText | Should -Match 'list volume'
    }

    It 'never asks the Storage provider by drive letter for S: (run 46004055968: blind to the ESP)' {
        $script:SeedBcdbootPrereqFuncText | Should -Not -Match 'Get-Volume -DriveLetter S'
        $script:SeedBcdbootPrereqFuncText | Should -Not -Match 'Get-Partition -DriveLetter S'
    }

    It 'checks the source boot files including the image bcdboot.exe' {
        $script:SeedBcdbootPrereqFuncText | Should -Match 'V:\\Windows\\Boot\\EFI\\bootmgfw\.efi'
        $script:SeedBcdbootPrereqFuncText | Should -Match 'V:\\Windows\\System32\\config\\BCD-Template'
        $script:SeedBcdbootPrereqFuncText | Should -Match 'V:\\Windows\\System32\\bcdboot\.exe'
    }

    It 'runs the applied image bcdboot, not the host bcdboot (round 42: host 26100 failed on the 22621 image, exit 193)' {
        $script:SeedScriptText | Should -Match '\$imageBcdboot = ''V:\\Windows\\System32\\bcdboot\.exe'''
        $script:SeedScriptText | Should -Match '& \$imageBcdboot V:\\Windows /s S: /f UEFI'
        $script:SeedScriptText | Should -Not -Match '& bcdboot\.exe V:\\Windows /s S: /f UEFI'
    }

    It 'passes when everything is present (S: attached, FAT32, ESP, readable; boot files present)' {
        Set-SeedBcdbootMocksOk
        $result = Assert-SeedBcdbootPrerequisites -VhdPath 'C:\seed\seed.vhdx'
        $result.SReadable | Should -BeTrue
        $result.SFileSystem | Should -Be 'FAT32'
        $result.SGptType | Should -Be '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
        $result.SVolumeNumber | Should -Be '3'
        $result.BootmgfwExists | Should -BeTrue
        $result.BcdTemplateExists | Should -BeTrue
        $result.ImageBcdbootExists | Should -BeTrue
    }

    It 'passes when the volume providers are blind to S: (run 46004055968 repro: Win32_Volume lists nothing, Test-Path + fsutil + diskpart detail prove S:)' {
        Set-SeedBcdbootMocksOk
        # Default mocks already reproduce the CI state: Win32_Volume
        # has no S: entry (empty MockSeedCimVolumes), while Test-Path
        # S:\, fsutil FAT32 and the diskpart detail ESP parse all
        # pass. The old gate threw here (S: volume not found; S:
        # partition not found); the fixed gate must pass.
        $global:MockSeedCimVolumes = @{}
        $result = Assert-SeedBcdbootPrerequisites -VhdPath 'C:\seed\seed.vhdx'
        $result.SReadable | Should -BeTrue
        $result.SFileSystem | Should -Be 'FAT32'
        $result.SGptType | Should -Be '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    }

    It 'passes via Win32_Volume when it does list S: (primary path, FAT32)' {
        Set-SeedBcdbootMocksOk
        $global:MockSeedCimVolumes['S'] = [pscustomobject]@{ DriveLetter = 'S'; FileSystem = 'FAT32'; Capacity = 272629760 }
        $result = Assert-SeedBcdbootPrerequisites -VhdPath 'C:\seed\seed.vhdx'
        $result.SFileSystem | Should -Be 'FAT32'
        $result.SGptType | Should -Be '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    }

    It 'fails naming S: when the EFI partition is not readable at bcdboot time' {
        Set-SeedBcdbootMocksOk
        $global:MockSeedPaths['S:\'] = $false
        { Assert-SeedBcdbootPrerequisites -VhdPath 'C:\seed\seed.vhdx' } | Should -Throw '*S:*readable*'
    }

    It 'fails naming the GPT type when S: is not an EFI System Partition' {
        Set-SeedBcdbootMocksOk
        $global:MockSeedDiskpartDetail = @(
            'Partition 2'
            'Type    : ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'
            'Hidden  : No'
        )
        { Assert-SeedBcdbootPrerequisites -VhdPath 'C:\seed\seed.vhdx' } | Should -Throw '*GPT type*'
    }

    It 'fails naming the GPT type when diskpart detail returns no Type GUID' {
        Set-SeedBcdbootMocksOk
        $global:MockSeedDiskpartDetail = @('Partition 2', 'Hidden  : No')
        { Assert-SeedBcdbootPrerequisites -VhdPath 'C:\seed\seed.vhdx' } | Should -Throw '*GPT type*'
    }

    It 'fails naming the file when bootmgfw.efi is missing' {
        Set-SeedBcdbootMocksOk
        $global:MockSeedPaths['V:\Windows\Boot\EFI\bootmgfw.efi'] = $false
        { Assert-SeedBcdbootPrerequisites -VhdPath 'C:\seed\seed.vhdx' } | Should -Throw '*bootmgfw.efi*'
    }

    It 'fails naming the file when the image bcdboot.exe is missing' {
        Set-SeedBcdbootMocksOk
        $global:MockSeedPaths['V:\Windows\System32\bcdboot.exe'] = $false
        { Assert-SeedBcdbootPrerequisites -VhdPath 'C:\seed\seed.vhdx' } | Should -Throw '*bcdboot.exe*'
    }

    It 'passes when convert gpt auto-created an MSR as partition 1 (run 46017835896 repro: ESP is partition 2, found by volume S:)' {
        Set-SeedBcdbootMocksOk
        # Default mocks reproduce the run 46017835896 layout: partition
        # 1 is the MSR (MockSeedDiskpartMsrDetail), the ESP is partition
        # 2 (S:, Volume 3). The old gate hard-coded partition 1 and
        # threw the MSR GUID; the fixed gate selects by volume letter
        # and must pass. The pre-fix failure is proven by
        # ~/workspace/micpe-r42-seed/msr-probe.ps1 (old gate throws
        # the exact CI error on the same mocks).
        $result = Assert-SeedBcdbootPrerequisites -VhdPath 'C:\seed\seed.vhdx'
        $result.SReadable | Should -BeTrue
        $result.SFileSystem | Should -Be 'FAT32'
        $result.SGptType | Should -Be '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
        $result.SVolumeNumber | Should -Be '3'
    }

    It 'fails naming the GPT type when diskpart list volume has no S: volume' {
        Set-SeedBcdbootMocksOk
        $global:MockSeedDiskpartListVolume = @(
            '  Volume ###  Ltr  Label        Fs     Type        Size     Status     Info'
            '  Volume 0     C                NTFS   Partition    127 GB  Healthy    Boot'
            '  Volume 4     V   SEED         NTFS   Partition     31 GB  Healthy'
        )
        { Assert-SeedBcdbootPrerequisites -VhdPath 'C:\seed\seed.vhdx' } | Should -Throw '*list volume*'
    }

    It 'finds the S: volume number from diskpart list volume' {
        Set-SeedBcdbootMocksOk
        Get-SeedDiskpartVolumeNumber -DriveLetter 'S' | Should -Be '3'
    }

    It 'finds the SEED volume number from diskpart list volume' {
        Set-SeedBcdbootMocksOk
        Get-SeedDiskpartVolumeNumber -Label 'SEED' | Should -Be '4'
    }

    It 'returns null when no volume has the drive letter' {
        Set-SeedBcdbootMocksOk
        $n = Get-SeedDiskpartVolumeNumber -DriveLetter 'Q'
        Should -BeNullOrEmpty -Actual $n
    }

    It 'returns null when no volume has the label' {
        Set-SeedBcdbootMocksOk
        $n = Get-SeedDiskpartVolumeNumber -Label 'NOPE'
        Should -BeNullOrEmpty -Actual $n
    }
}

Describe 'seed harvest finds the Windows volume by label (round 42 MSR fix)' {
    It 'does not select a partition by number for the harvest attach (run 46017835896: convert gpt auto-creates an MSR as partition 1, so the primary is partition 3, not 2)' {
        $script:SeedScriptText | Should -Not -Match 'select partition 2'
        $script:SeedScriptText | Should -Not -Match 'select partition 1'
    }

    It 'finds the SEED volume by label and assigns V: to it' {
        $script:SeedScriptText | Should -Match "Get-SeedDiskpartVolumeNumber -Label 'SEED'"
        $script:SeedScriptText | Should -Match 'select volume \$seedVolumeNumber'
        $script:SeedScriptText | Should -Match "'assign letter=V'"
    }
}

Describe 'seed verifier helpers are loaded before first use (round 42 rerun)' {
    BeforeAll {
        # Extract the real Get-CleanQemuImgPath from the verifier
        # (brace-counting scan, same pattern as the diskpart tests),
        # so the tests exercise the shipped function, not a copy.
        $start = $script:VerifyScriptText.IndexOf('function Get-CleanQemuImgPath')
        $open = $script:VerifyScriptText.IndexOf('{', $start)
        $depth = 0
        $end = $open
        for ($i = $open; $i -lt $script:VerifyScriptText.Length; $i++) {
            $ch = $script:VerifyScriptText[$i]
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') {
                $depth--
                if ($depth -eq 0) { $end = $i; break }
            }
        }
        $script:QemuImgPathFuncText = $script:VerifyScriptText.Substring($start, $end - $start + 1)
        . ([scriptblock]::Create($script:QemuImgPathFuncText))
    }

    It 'dot-sources the clean verifier before the qcow2 conversion calls its helper (run 46033515034: the call ran 24 lines before the load, "not recognized")' {
        $dotSource = [regex]::Match($script:SeedScriptText, '(?m)^\. \(Join-Path \$repoRoot ''src\\ci\\Invoke-CleanQemuVerify\.ps1''\)')
        $dotSource.Success | Should -BeTrue
        $call = [regex]::Match($script:SeedScriptText, '(?m)^\$qemuImgPath = Get-CleanQemuImgPath')
        $call.Success | Should -BeTrue
        $dotSource.Index | Should -BeLessThan $call.Index
    }

    It 'has no verifier-helper call before the dot-source (the seed script only uses Get-CleanQemuImgPath and Find-CleanOvmfVars from the verifier)' {
        $dotSource = [regex]::Match($script:SeedScriptText, '(?m)^\. \(Join-Path \$repoRoot ''src\\ci\\Invoke-CleanQemuVerify\.ps1''\)')
        $dotSource.Success | Should -BeTrue
        $before = $script:SeedScriptText.Substring(0, $dotSource.Index)
        $before | Should -Not -Match 'Get-CleanQemuImgPath'
        $before | Should -Not -Match 'Find-CleanOvmfVars'
    }

    It 'resolves qemu-img.exe next to qemu-system-x86_64.exe' {
        Get-CleanQemuImgPath -QemuPath 'C:\Program Files\qemu\qemu-system-x86_64.exe' | Should -Be 'C:\Program Files\qemu\qemu-img.exe'
    }

    It 'falls back to bare qemu-img when QemuPath has no directory part' {
        Get-CleanQemuImgPath -QemuPath 'qemu-system-x86_64' | Should -Be 'qemu-img'
    }

    It 'passes the seed QEMU full path through the dot-source (run 46043894030: the verifier default bare name clobbered the workflow path, "qemu-img not recognized")' {
        $dotLine = [regex]::Match($script:SeedScriptText, '(?m)^\. \(Join-Path \$repoRoot ''src\\ci\\Invoke-CleanQemuVerify\.ps1''\)(.*)$')
        $dotLine.Success | Should -BeTrue
        $dotLine.Groups[1].Value | Should -Match '-QemuPath \$QemuPath'
    }

    It 'passes through the other shared verifier parameters the seed script uses after the load (MemoryMb/CpuCount/MonitorPort coincide with the verifier defaults today, but the same bind would silently reset a future workflow value)' {
        $dotLine = [regex]::Match($script:SeedScriptText, '(?m)^\. \(Join-Path \$repoRoot ''src\\ci\\Invoke-CleanQemuVerify\.ps1''\)(.*)$')
        $dotLine.Success | Should -BeTrue
        $argsText = $dotLine.Groups[1].Value
        $argsText | Should -Match '-MemoryMb \$MemoryMb'
        $argsText | Should -Match '-CpuCount \$CpuCount'
        $argsText | Should -Match '-MonitorPort \$MonitorPort'
    }

    It 'keeps the workflow QEMU full path after the dot-source (run 46043894030: the load rebound $QemuPath to the verifier default)' {
        # Extract the verifier's real param block and dot-source it with
        # exactly the arguments the seed line passes, so this fails while
        # the line omits -QemuPath and passes once it is added.
        $paramStart = $script:VerifyScriptText.IndexOf('[CmdletBinding()]')
        $tail = $script:VerifyScriptText.Substring($paramStart)
        $close = [regex]::Match($tail, '(?m)^\)\s*$')
        $close.Success | Should -BeTrue
        $paramBlock = [scriptblock]::Create($tail.Substring(0, $close.Index + $close.Length))
        $dotLine = [regex]::Match($script:SeedScriptText, '(?m)^\. \(Join-Path \$repoRoot ''src\\ci\\Invoke-CleanQemuVerify\.ps1''\)(.*)$')
        $dotLine.Success | Should -BeTrue
        $argsText = $dotLine.Groups[1].Value
        $QemuPath = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
        $installWim = 'C:\fake\install.wim'
        $OvmfPath = 'C:\fake\OVMF_CODE.fd'
        $WorkDir = 'C:\fake\work'
        $MemoryMb = 4096
        $CpuCount = 4
        $MonitorPort = '4444'
        $splat = @{}
        if ($argsText -match '-IsoPath') { $splat['IsoPath'] = $installWim }
        if ($argsText -match '-OvmfPath') { $splat['OvmfPath'] = $OvmfPath }
        if ($argsText -match '-WorkDir') { $splat['WorkDir'] = $WorkDir }
        if ($argsText -match '-QemuPath') { $splat['QemuPath'] = $QemuPath }
        if ($argsText -match '-MemoryMb') { $splat['MemoryMb'] = $MemoryMb }
        if ($argsText -match '-CpuCount') { $splat['CpuCount'] = $CpuCount }
        if ($argsText -match '-MonitorPort') { $splat['MonitorPort'] = $MonitorPort }
        if ($argsText -match '-ParseOnly') { $splat['ParseOnly'] = $true }
        . $paramBlock @splat
        $QemuPath | Should -Be 'C:\Program Files\qemu\qemu-system-x86_64.exe'
    }
}

Describe 'seed harvest recovers the QEMU-written disk (round 42 rerun 7)' {
    It 'converts the qcow2 back to VHDX after QEMU exits, before the harvest (run 46051050523: the harvest attached the stale pre-QEMU VHD and read the empty 8 KB SAM)' {
        # The convert-back uses the resolved qemu-img path and writes a
        # NEW file (the original VHD stays untouched until the
        # conversion succeeds).
        $script:SeedScriptText | Should -Match '& \$qemuImgPath convert -f qcow2 -O vhdx \$qcow2 \$harvestVhdx'
        $convertBack = $script:SeedScriptText.IndexOf('convert -f qcow2 -O vhdx')
        $convertBack | Should -BeGreaterThan 0
        # It runs after QEMU has exited (past the desktop guard, which
        # sits right after the shutdown finally block) and before the
        # harvest step -- the disk must be quiesced and the harvest must
        # read the converted-back disk, not the pre-QEMU one.
        $desktopGuard = $script:SeedScriptText.IndexOf('OOBE desktop was never reached')
        $desktopGuard | Should -BeGreaterThan 0
        $convertBack | Should -BeGreaterThan $desktopGuard
        $harvest = $script:SeedScriptText.IndexOf("Write-Step 'harvesting")
        $harvest | Should -BeGreaterThan 0
        $convertBack | Should -BeLessThan $harvest
    }

    It 'harvests from the converted-back disk, never from the original pre-QEMU VHD' {
        $harvestSection = (($script:SeedScriptText -split "Write-Step 'harvesting")[1] -split "Write-Step 'verifying")[0]
        $harvestSection | Should -Match 'select vdisk file=`"\$harvestVhdx`"'
        $harvestSection | Should -Not -Match 'select vdisk file=`"\$vhdx`"'
    }

    It 'fails hard if the convert-back fails (never silently harvest the stale VHD)' {
        $script:SeedScriptText | Should -Match 'convert back failed'
        $script:SeedScriptText | Should -Match 'refusing to harvest the stale pre-QEMU VHD'
    }
}

Describe 'seed desktop detection rejects the OOBE getting-ready screens (round 42 rerun 7)' {
    BeforeAll {
        # Extract the real Test-SeedScreenshotHasDesktopDetail from the
        # seed script (brace-counting scan, same pattern as the other
        # Describes), so the tests exercise the shipped function, not a
        # copy. On HEAD the function does not exist yet, so this
        # BeforeAll throws and every test below fails -- that is the
        # intended fail-on-HEAD signal.
        $start = $script:SeedScriptText.IndexOf('function Test-SeedScreenshotHasDesktopDetail')
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
        $script:SeedDetailFuncText = $script:SeedScriptText.Substring($start, $end - $start + 1)
        . ([scriptblock]::Create($script:SeedDetailFuncText))

        # The real shot-34/35 PPMs are 3 MB each; they live gzipped in
        # tests/fixtures (bytes exact) and are expanded here. The
        # reconstructed desktop is the shipped Bloom wallpaper
        # (Windows\Web\Wallpaper\Windows\img0.jpg, same 22621.1105
        # build) scaled to the 1280x800 QEMU display plus the solid
        # dark taskbar -- a reconstruction, not a screenshot, used only
        # to prove the new detector still accepts a real desktop.
        $script:SeedFixtures = Join-Path $PSScriptRoot 'fixtures'
        function Expand-SeedFixtureGzip {
            param([string] $Source, [string] $Destination)
            $inStream = [System.IO.File]::OpenRead($Source)
            try {
                $outStream = [System.IO.File]::Create($Destination)
                try {
                    $gzip = [System.IO.Compression.GZipStream]::new($inStream, [System.IO.Compression.CompressionMode]::Decompress)
                    try { $gzip.CopyTo($outStream) } finally { $gzip.Dispose() }
                } finally { $outStream.Dispose() }
            } finally { $inStream.Dispose() }
        }
        $script:SeedShot34 = Join-Path $TestDrive 'shot-34.ppm'
        $script:SeedShot35 = Join-Path $TestDrive 'shot-35.ppm'
        $script:SeedDesktop = Join-Path $TestDrive 'seed-desktop.ppm'
        Expand-SeedFixtureGzip -Source (Join-Path $script:SeedFixtures 'seed-oobe-shot-34.ppm.gz') -Destination $script:SeedShot34
        Expand-SeedFixtureGzip -Source (Join-Path $script:SeedFixtures 'seed-oobe-shot-35.ppm.gz') -Destination $script:SeedShot35
        Expand-SeedFixtureGzip -Source (Join-Path $script:SeedFixtures 'seed-desktop-reconstructed.ppm.gz') -Destination $script:SeedDesktop
    }

    It 'pins the confuser: the color rule alone accepts the OOBE screens (passes on HEAD by design -- it proves the old detector was fooled, the gate tests below are the ones that must fail on HEAD)' {
        # Extract the real Test-CleanScreenshot from the verifier and
        # run it on the actual shot-34 pixels.
        $start = $script:VerifyScriptText.IndexOf('function Test-CleanScreenshot')
        $open = $script:VerifyScriptText.IndexOf('{', $start)
        $depth = 0
        $end = $open
        for ($i = $open; $i -lt $script:VerifyScriptText.Length; $i++) {
            $ch = $script:VerifyScriptText[$i]
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') {
                $depth--
                if ($depth -eq 0) { $end = $i; break }
            }
        }
        . ([scriptblock]::Create($script:VerifyScriptText.Substring($start, $end - $start + 1)))
        $class = Test-CleanScreenshot -Path $script:SeedShot34
        $class.Classification | Should -Be 'Other'
        $class.BlackFraction | Should -BeLessThan 0.4
    }

    It 'rejects shot-34 (run 46051050523: "确保一切都已准备就绪" -- OOBE, not a desktop)' {
        Test-SeedScreenshotHasDesktopDetail -Path $script:SeedShot34 | Should -BeFalse
    }

    It 'rejects shot-35 (run 46051050523: "仍在处理一些问题" -- OOBE, not a desktop)' {
        Test-SeedScreenshotHasDesktopDetail -Path $script:SeedShot35 | Should -BeFalse
    }

    It 'accepts the reconstructed first-logon desktop (real Bloom wallpaper + taskbar -- the new detector must not become always-false)' {
        Test-SeedScreenshotHasDesktopDetail -Path $script:SeedDesktop | Should -BeTrue
    }

    It 'the poll loop requires the detail check in addition to the color rule' {
        $script:SeedScriptText | Should -Match 'Test-SeedScreenshotHasDesktopDetail -Path \$ppm'
        $detail = $script:SeedScriptText.IndexOf('Test-SeedScreenshotHasDesktopDetail -Path $ppm')
        $detail | Should -BeGreaterThan 0
        $streak = $script:SeedScriptText.IndexOf('$streak++')
        $streak | Should -BeGreaterThan 0
        $detail | Should -BeLessThan $streak
    }
}

Describe 'seed QEMU log actually records guest errors (round 42 rerun 7)' {
    # Run 46051050523: micpe-seed-qemu.log was 0 bytes. QEMU's -D only
    # names the log file; nothing is written unless -d enables a log
    # category, so the parameter was dead. -d guest_errors makes the
    # log real (guest errors during specialize/OOBE are the useful
    # signal); a still-empty file then means "no guest errors", not
    # "logging was off".
    BeforeAll {
        $script:SeedScriptText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'src' 'build' 'Invoke-CleanSamSeedRun.ps1') -Raw
        $start = $script:SeedScriptText.IndexOf('function Get-SeedQemuArgList')
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
        $func = $script:SeedScriptText.Substring($start, $end - $start + 1)
        . ([scriptblock]::Create($func))
    }

    It 'enables a log category with -d so -D writes something' {
        $args = Get-SeedQemuArgList -DiskQcow2 'C:\seed-out\seed.qcow2' -OvmfCodePath 'C:\qemu\OVMF_CODE.fd' -VarsPath 'C:\seed-out\vars.fd' -QemuLogPath 'C:\seed-out\micpe-seed-qemu.log'
        $dIndex = [Array]::IndexOf($args, '-d')
        $dIndex | Should -BeGreaterThan -1
        $args[$dIndex + 1] | Should -Be 'guest_errors'
        $args | Should -Contain '-D'
    }
}

Describe 'seed classifier must not mistake the welcome screen for Recovery (round 42 rerun 8)' {
    # Run 46066624370: shot-46 is the Windows 11 welcome screen (Bloom
    # wallpaper, avatar, "MICPE", spinner, "欢迎") -- MICPE created,
    # auto-logon reached the welcome screen, the furthest the seed has
    # ever got. The old classifier called it Recovery on blue fraction
    # alone (blue 57%) and the poll loop threw at line 1022, about 60 s
    # before the desktop would have loaded. A blue screen is only a
    # failure screen when the blue is FLAT: real Recovery (32,103,178)
    # and BSOD blues fill the frame with one color (uniformity
    # 0.985-1.000, measured on the real round-10 Recovery and round-14
    # BSOD frames, text included); the welcome screen's Bloom wallpaper
    # is textured (uniformity 0.20) and the desktop's is 0.00. The 0.90
    # threshold has margin on both sides.
    BeforeAll {
        $script:WelcomeFixtures = Join-Path $PSScriptRoot 'fixtures'
        function Expand-SeedFixtureGzip {
            param([string] $Source, [string] $Destination)
            $inStream = [System.IO.File]::OpenRead($Source)
            try {
                $outStream = [System.IO.File]::Create($Destination)
                try {
                    $gzip = [System.IO.Compression.GZipStream]::new($inStream, [System.IO.Compression.CompressionMode]::Decompress)
                    try { $gzip.CopyTo($outStream) } finally { $gzip.Dispose() }
                } finally { $outStream.Dispose() }
            } finally { $inStream.Dispose() }
        }
        $script:SeedWelcome46 = Join-Path $TestDrive 'shot-46.ppm'
        $script:SeedTiano45 = Join-Path $TestDrive 'shot-45.ppm'
        $script:SeedDesktopWelcome = Join-Path $TestDrive 'seed-desktop-welcome.ppm'
        Expand-SeedFixtureGzip -Source (Join-Path $script:WelcomeFixtures 'seed-welcome-shot-46.ppm.gz') -Destination $script:SeedWelcome46
        Expand-SeedFixtureGzip -Source (Join-Path $script:WelcomeFixtures 'seed-tianocore-shot-45.ppm.gz') -Destination $script:SeedTiano45
        Expand-SeedFixtureGzip -Source (Join-Path $script:WelcomeFixtures 'seed-desktop-reconstructed.ppm.gz') -Destination $script:SeedDesktopWelcome
        # Extract the real Test-CleanScreenshot from the verifier (same
        # brace-matching extraction as the round-8 OOBE tests).
        $start = $script:VerifyScriptText.IndexOf('function Test-CleanScreenshot')
        $open = $script:VerifyScriptText.IndexOf('{', $start)
        $depth = 0
        $end = $open
        for ($i = $open; $i -lt $script:VerifyScriptText.Length; $i++) {
            $ch = $script:VerifyScriptText[$i]
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') {
                $depth--
                if ($depth -eq 0) { $end = $i; break }
            }
        }
        . ([scriptblock]::Create($script:VerifyScriptText.Substring($start, $end - $start + 1)))
    }

    It 'pins the confuser: shot-46 is blue-dominant (blue 57%) -- the fact that tripped the old rule' {
        $class = Test-CleanScreenshot -Path $script:SeedWelcome46
        $class.BlueFraction | Should -BeGreaterThan 0.5
        $class.BlackFraction | Should -BeLessThan 0.1
    }

    It 'rejects shot-46 as a failure screen: the welcome screen is progress, not Recovery' {
        $class = Test-CleanScreenshot -Path $script:SeedWelcome46
        $class.Classification | Should -Be 'Other'
        $class.BlueUniform | Should -BeLessThan 0.9
    }

    It 'treats shot-46 as progress: the poll loop fail-fast condition does not fire on it' {
        $class = Test-CleanScreenshot -Path $script:SeedWelcome46
        ($class.Classification -eq 'BlueScreen' -or $class.Classification -eq 'Recovery') | Should -BeFalse
    }

    It 'the poll loop still fails fast on a real blue failure screen (the throw is conditioned on the classification, not deleted)' {
        $script:VerifyScriptText | Should -Match 'BlueUniform'
        $script:SeedScriptText | Should -Match "if \(\`$class\.Classification -eq 'BlueScreen' -or \`$class\.Classification -eq 'Recovery'\)"
        $script:SeedScriptText | Should -Match 'specialize failed: guest shows'
    }

    It 'still classifies shot-45 (TianoCore) as Boot' {
        $class = Test-CleanScreenshot -Path $script:SeedTiano45
        $class.Classification | Should -Be 'Boot'
        $class.BlackFraction | Should -BeGreaterThan 0.9
        $class.BlueFraction | Should -Be 0
    }

    It 'still classifies the real round-10 Recovery screen as Recovery (flat blue is still a failure)' {
        $class = Test-CleanScreenshot -Path (Join-Path $script:WelcomeFixtures 'r84-shot-04-recovery.ppm')
        $class.Classification | Should -Be 'Recovery'
        $class.BlueFraction | Should -BeGreaterThan 0.9
        $class.BlueUniform | Should -BeGreaterOrEqual 0.9
    }

    It 'still classifies the real round-14 BSOD as BlueScreen (flat blue is still a failure)' {
        $class = Test-CleanScreenshot -Path (Join-Path $script:WelcomeFixtures 'r90-shot-02-bsod.ppm')
        $class.Classification | Should -Be 'BlueScreen'
        $class.BlueFraction | Should -BeGreaterThan 0.9
        $class.BlueUniform | Should -BeGreaterOrEqual 0.9
    }

    It 'the reconstructed desktop is not a failure screen either (blue 0.89, uniformity 0.00 -- the old rule would have killed the run at the desktop too)' {
        $class = Test-CleanScreenshot -Path $script:SeedDesktopWelcome
        $class.Classification | Should -Be 'Other'
        $class.BlueFraction | Should -BeGreaterThan 0.5
        $class.BlueUniform | Should -BeLessThan 0.9
    }
}
