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
        # Round 42 rerun 14: Members is a direct child of Aliases,
        # not of the 00000220 alias key (which has no subkeys, only
        # a C value), and members are keyed by hex RID under the
        # domain SID, not by decimal '-1000'.
        $script:SeedScriptText | Should -Match '00000220'
        $script:SeedScriptText | Should -Match 'Builtin\\Aliases\\Members'
        $script:SeedScriptText | Should -Match "RidHex '000003E8'"
        $script:SeedScriptText | Should -Not -Match '00000220\\Members'
        $script:SeedScriptText | Should -Not -Match "'-1000'"
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
        # conversion succeeds). Round 42 rerun 11: the conversion goes
        # through ConvertTo-CleanDeSparseDisk, not a bare qemu-img
        # call -- the bare output is sparse and diskpart refuses to
        # attach it (run 46093144284 rerun).
        $script:SeedScriptText | Should -Match 'ConvertTo-CleanDeSparseDisk -QemuImgPath \$qemuImgPath -Qcow2Path \$qcow2 -Format ''vhdx'' -OutPath \$harvestVhdx'
        $convertBack = [regex]::Match($script:SeedScriptText, 'ConvertTo-CleanDeSparseDisk -QemuImgPath').Index
        $convertBack | Should -BeGreaterThan 0
        # It runs after QEMU has exited (past the shutdown-timer guard,
        # which sits right after the shutdown finally block) and before
        # the harvest step -- the disk must be quiesced and the harvest
        # must read the converted-back disk, not the pre-QEMU one.
        $desktopGuard = $script:SeedScriptText.IndexOf('shutdown timer never fired')
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

    It 'the classifier still flags a real flat-blue failure screen (round 42 rerun 10: the fail-fast throw is gone from the seed poll loop by user instruction, but the uniformity gate stays in the verifier)' {
        $script:VerifyScriptText | Should -Match 'BlueUniform'
        $script:SeedScriptText | Should -Not -Match 'specialize failed: guest shows'
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

Describe 'seed shutdown is on a timer, not on screenshot gates (round 42 rerun 10)' {
    BeforeAll {
        $timingPath = Join-Path $PSScriptRoot 'fixtures/seed-startmenu-timing.json'
        $script:SeedTiming = Get-Content -LiteralPath $timingPath -Raw | ConvertFrom-Json
        $script:SeedStartMenuMinutes = ([DateTime]::Parse($script:SeedTiming.startMenuAtUtc) - [DateTime]::Parse($script:SeedTiming.qemuStartedAtUtc)).TotalMinutes
        $m = [regex]::Match($script:SeedScriptText, '\$ShutdownAfterMin\s*=\s*(\d+)')
        $script:SeedShutdownAfterMin = if ($m.Success) { [int]$m.Groups[1].Value } else { -1 }
        $mt = [regex]::Match($script:SeedScriptText, '\$SpecializeTimeoutMin\s*=\s*(\d+)')
        $script:SeedSpecializeTimeoutMin = if ($mt.Success) { [int]$mt.Groups[1].Value } else { -1 }
    }

    It 'the timing fixture records the measured Start-menu time (about 53.4 min after QEMU start)' {
        $script:SeedStartMenuMinutes | Should -BeGreaterOrEqual 50
        $script:SeedStartMenuMinutes | Should -BeLessThan 60
    }

    It 'the shutdown timer is 90 minutes (user 2026-11-28 15:19: "延长到90分钟吧")' {
        $script:SeedShutdownAfterMin | Should -Be 90
        $script:SeedScriptText | Should -Match '\$ShutdownAfterMin = 90'
    }

    It 'the shutdown timer covers the measured time plus a 10-minute buffer, with room for the round-11 slowdown' {
        # Round 42 rerun 12: the user overrode the 64 min formula
        # (53.43 + 10) with 90 min -- in run 46105769251 specialize
        # alone ran ~60 min, so the single specialize->OOBE reboot
        # landed at ~60-61 min and OOBE had only ~3 min when the
        # 64 min timer fired. The upper bound from the old formula
        # no longer applies; the outer timeout is the ceiling now.
        $script:SeedShutdownAfterMin | Should -BeGreaterOrEqual ($script:SeedStartMenuMinutes + 10)
        $script:SeedShutdownAfterMin | Should -BeLessThan $script:SeedSpecializeTimeoutMin
    }

    It 'the timer is anchored at QEMU start' {
        $anchor = $script:SeedScriptText.IndexOf('$qemuStartedAt = Get-Date')
        $start = $script:SeedScriptText.IndexOf('Start-Process -FilePath $QemuPath')
        $anchor | Should -BeGreaterOrEqual 0
        $start | Should -BeGreaterOrEqual 0
        $anchor | Should -BeLessThan $start
        $script:SeedScriptText | Should -Match '\$qemuStartedAt\.AddMinutes\(\$ShutdownAfterMin\)'
    }

    It 'the poll loop takes screenshots as evidence only, with no detection' {
        $script:SeedScriptText | Should -Not -Match 'Test-CleanScreenshot'
        $script:SeedScriptText | Should -Not -Match 'Test-SeedScreenshotHasDesktopDetail'
        $script:SeedScriptText | Should -Not -Match 'Test-SeedScreenshotIsDesktop'
        $script:SeedScriptText | Should -Not -Match 'Test-SeedScreenshotHasStartMenu'
        $script:SeedScriptText | Should -Not -Match 'specialize failed: guest shows'
        $script:SeedScriptText | Should -Not -Match 'desktop-like'
        $script:SeedScriptText.IndexOf('$streak') | Should -Be -1
        $script:SeedScriptText | Should -Match 'Save-CleanScreenshot'
        $script:SeedScriptText | Should -Match 'specialize poll'
    }

    It 'the timer firing is what leads to shutdown, and the outer timeout still guards it' {
        $script:SeedScriptText | Should -Match '\$shutdownTimerFired = \$true'
        $script:SeedScriptText | Should -Match 'shutdown timer reached'
        $script:SeedScriptText | Should -Match 'shutdown timer did not fire within \$SpecializeTimeoutMin minutes'
        $timer = $script:SeedScriptText.IndexOf('shutdown timer reached')
        $powerdown = $script:SeedScriptText.IndexOf('system_powerdown')
        $timer | Should -BeGreaterOrEqual 0
        $timer | Should -BeLessThan $powerdown
    }

    It 'the poll loop keeps the display awake so the evidence screenshots stay readable' {
        $count = ([regex]::Matches($script:SeedScriptText, 'Send-CleanKey')).Count
        $count | Should -Be 1
        $script:SeedScriptText | Should -Match 'Send-CleanKey -Port \$MonitorPort -Key ''ctrl'''
    }

    It 'the 100-minute timeout is still the outer backstop (above the 90 min timer)' {
        $script:SeedSpecializeTimeoutMin | Should -Be 100
        $script:SeedScriptText | Should -Match '\$SpecializeTimeoutMin = 100'
        $script:SeedSpecializeTimeoutMin | Should -BeGreaterThan $script:SeedShutdownAfterMin
    }

    It 'the harvest path is unchanged (convert-back, empty-hive assertion)' {
        $script:SeedScriptText | Should -Match 'seed-harvest.vhdx'
        $script:SeedScriptText | Should -Match 'refusing to harvest the stale pre-QEMU VHD'
        $script:SeedScriptText | Should -Match 'harvested SAM is still an empty hive'
    }
}

Describe 'seed harvest de-sparses the converted-back disk before attaching (round 42 rerun 11)' {
    # Run 46093144284 rerun: the timer fired, QEMU exited 0, the
    # qcow2 converted back -- then the harvest attach failed because
    # the converted-back seed-harvest.vhdx is sparse ("Virtual hard
    # disk files must be uncompressed and unencrypted and must not be
    # sparse"), list volume showed only the runner's own disks, and
    # the script threw "harvest failed: SEED volume not found".
    # Round 23 already fixed the same failure on the main build's
    # dump disk with ConvertTo-CleanDeSparseDisk (plain copy loses
    # the sparse attribute; fsutil sparse setflag 0 on an
    # already-sparse file may corrupt it, so the copy -- not setflag
    # -- is the fix). Reuse that helper here.
    BeforeAll {
        # Extract the real ConvertTo-CleanDeSparseDisk from the
        # verifier (same brace-matching extraction as the round-8
        # classifier tests).
        $start = $script:VerifyScriptText.IndexOf('function ConvertTo-CleanDeSparseDisk')
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
        $script:DeSparseFunc = $script:VerifyScriptText.Substring($start, $end - $start + 1)
        . ([scriptblock]::Create($script:DeSparseFunc))
    }

    It 'no bare qemu-img convert-back to the harvest VHDX remains (the bare output is sparse)' {
        $script:SeedScriptText | Should -Not -Match '& \$qemuImgPath convert -f qcow2 -O vhdx \$qcow2 \$harvestVhdx'
    }

    It 'reuses the verifier helper: the seed script dot-sources the verifier above the convert-back and defines no copy of it' {
        $script:SeedScriptText | Should -Not -Match 'function ConvertTo-CleanDeSparseDisk'
        $script:VerifyScriptText | Should -Match 'function ConvertTo-CleanDeSparseDisk'
        $dotSource = $script:SeedScriptText.IndexOf("Invoke-CleanQemuVerify.ps1') -IsoPath")
        $call = [regex]::Match($script:SeedScriptText, 'ConvertTo-CleanDeSparseDisk -QemuImgPath').Index
        $dotSource | Should -BeGreaterThan 0
        $call | Should -BeGreaterThan 0
        $dotSource | Should -BeLessThan $call
    }

    It 'the helper materializes the converted file with a plain copy and logs the fsutil queryflag as proof' {
        # A fake qemu-img: a shell script that copies its last two
        # args (input -> tmp output), so the convert step is real but
        # the sparse attribute never enters the picture on the Linux
        # test host; the property under test is the plain-copy
        # materialization, not the NTFS flag itself (there is no NTFS
        # here). fsutil does not exist on Linux, so the helper takes
        # its "did not run" branch -- on the CI Windows runner the
        # same line carries the queryflag output.
        $dir = Join-Path $TestDrive 'desparse'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $qcow2 = Join-Path $dir 'seed.qcow2'
        [System.IO.File]::WriteAllText($qcow2, 'fake-qcow2-bytes')
        $stub = Join-Path $dir 'qemu-img'
        $stubText = @'
#!/bin/sh
cp "$6" "$7"
'@
        [System.IO.File]::WriteAllText($stub, $stubText)
        & chmod +x $stub
        $out = Join-Path $dir 'seed-harvest.vhdx'
        $lines = [System.Collections.Generic.List[string]]::new()
        $result = ConvertTo-CleanDeSparseDisk -QemuImgPath $stub -Qcow2Path $qcow2 -Format 'vhdx' -OutPath $out -Lines $lines
        $result | Should -Be $out
        Test-Path -LiteralPath $out | Should -BeTrue
        Get-Content -LiteralPath $out -Raw | Should -Be 'fake-qcow2-bytes'
        Test-Path -LiteralPath ($out + '.convert') | Should -BeFalse
        ($lines -join "`n") | Should -Match 'convert: qemu-img convert -f qcow2 -O vhdx'
        ($lines -join "`n") | Should -Match 'de-sparse: copied to'
        ($lines -join "`n") | Should -Match 'fsutil sparse queryflag'
    }

    It 'the helper copies instead of clearing the flag in place (the copy is the fix)' {
        $script:DeSparseFunc | Should -Match 'Copy-Item -LiteralPath \$tmpPath -Destination \$OutPath -Force'
        $script:DeSparseFunc | Should -Match 'fsutil sparse queryflag'
    }
}

Describe 'seed harvest failure still leaves numbers (round 42 rerun 12)' {
    # Run 46105769251 failed at the Names check (SAM Users\Names
    # empty) and the log never got the SAM size, hash or .LOG state:
    # the throw at line 545 happened before the Write-VerifyLine
    # calls, so the empty-Names failure could not be told apart
    # from an unflushed/torn hive (that run's shutdown was unclean
    # too: powerdown ignored for 180 s, monitor quit). Log the
    # numbers first, then rethrow; record the shutdown path and the
    # registry log files' state. The .LOG files are diagnostics
    # only -- never copied out, never uploaded.
    BeforeAll {
        $script:WorkflowText = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/build.yml') -Raw
    }

    It 'verification failure logs the hive numbers before throwing (log-then-throw)' {
        $call = $script:SeedScriptText.IndexOf('$observed = Get-SeedHiveVerification')
        $diag = $script:SeedScriptText.IndexOf('harvested hive diagnostics')
        $rethrow = $script:SeedScriptText.IndexOf("`n    throw`n", $diag)
        $call | Should -BeGreaterOrEqual 0
        $diag | Should -BeGreaterThan $call
        $rethrow | Should -BeGreaterThan $diag
        $block = $script:SeedScriptText.Substring($diag, $rethrow - $diag)
        $block | Should -Match 'SHA256'
        $block | Should -Match 'Get-FileHash'
        $block | Should -Match 'hive log files: not captured'
        $block | Should -Match 'Write-Host \("shutdown path: \{0\}"'
        $script:SeedScriptText | Should -Match 'harvested hive diagnostics \(verification failed\)'
    }

    It 'the harvest records the registry log files while the volume is still mounted' {
        $script:SeedScriptText | Should -Match 'SAM\.LOG1'
        $script:SeedScriptText | Should -Match 'SAM\.LOG2'
        $script:SeedScriptText | Should -Match 'SECURITY\.LOG1'
        $script:SeedScriptText | Should -Match 'SECURITY\.LOG2'
        $script:SeedScriptText | Should -Match 'hive log \{0\}: \{1:N0\} bytes'
        $script:SeedScriptText | Should -Match 'hive log \{0\}: not present'
        $log = $script:SeedScriptText.IndexOf('SAM.LOG1')
        $detach = $script:SeedScriptText.IndexOf('detaching the converted-back VHD after harvest')
        $log | Should -BeGreaterThan 0
        $detach | Should -BeGreaterThan 0
        $log | Should -BeLessThan $detach
        $script:SeedScriptText | Should -Not -Match 'Copy-Item.*\.LOG'
    }

    It 'the shutdown path is recorded in the verification report' {
        $script:SeedScriptText | Should -Match '\$seedShutdownPath = ''not-attempted'''
        $script:SeedScriptText | Should -Match '\$seedShutdownPath = ''clean-powerdown'''
        $script:SeedScriptText | Should -Match '\$seedShutdownPath = ''monitor-quit'''
        $script:SeedScriptText | Should -Match '\$seedShutdownPath = ''force-kill'''
        $script:SeedScriptText | Should -Match '\$seedShutdownPath = ''kill-failed'''
        $script:SeedScriptText | Should -Match 'Write-VerifyLine \("shutdown path: \{0\}"'
    }

    It 'the hives artifact takes only SAM, SECURITY and the verification report (no .LOG files)' {
        $script:WorkflowText | Should -Match 'name: micpe-sam-seed-hives'
        $script:WorkflowText | Should -Match 'seed-out/SAM\s+seed-out/SECURITY\s+seed-out/micpe-seed-verify\.txt\s+retention-days'
    }
}

Describe 'seed hive log recording never breaks the harvest (round 42 rerun 13)' {
    # Run 46123377266 died on the .LOG diagnostics themselves: after
    # the hives were copied, Test-Path said SAM.LOG1 was there and
    # the very next Get-Item said it was not ("Could not find item
    # V:\Windows\System32\config\SAM.LOG1", line 1071), and
    # $ErrorActionPreference = 'Stop' turned that into exit 1 -- the
    # harvest died on its own diagnostics and the hives were lost
    # with the runner. The recording is now one helper call per file
    # (Get-Item -ErrorAction SilentlyContinue, $null means "not
    # present") and the whole recording is best-effort.
    BeforeAll {
        # Extract the real Get-SeedHiveLogLines from the seed script
        # (brace-counting scan, same pattern as the diskpart tests),
        # so the tests exercise the shipped function, not a copy.
        $start = $script:SeedScriptText.IndexOf('function Get-SeedHiveLogLines')
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
        $script:SeedHiveLogFuncText = $script:SeedScriptText.Substring($start, $end - $start + 1)
        . ([scriptblock]::Create($script:SeedHiveLogFuncText))
    }

    AfterEach {
        Remove-Item function:Get-Item -ErrorAction SilentlyContinue
    }

    It 'records "not present" four times when no log file exists, without throwing' {
        $dir = Join-Path $TestDrive 'logs-empty'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $lines = Get-SeedHiveLogLines -ConfigDir $dir
        $lines.Count | Should -Be 4
        $lines[0] | Should -Be 'hive log SAM.LOG1: not present'
        $lines[1] | Should -Be 'hive log SAM.LOG2: not present'
        $lines[2] | Should -Be 'hive log SECURITY.LOG1: not present'
        $lines[3] | Should -Be 'hive log SECURITY.LOG2: not present'
    }

    It 'records byte counts for the files that exist and "not present" for the rest' {
        $dir = Join-Path $TestDrive 'logs-partial'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'SAM.LOG1'), [byte[]]::new(1234))
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'SECURITY.LOG2'), [byte[]]::new(56))
        $lines = Get-SeedHiveLogLines -ConfigDir $dir
        $lines.Count | Should -Be 4
        $lines[0] | Should -Be ("hive log {0}: {1:N0} bytes" -f 'SAM.LOG1', 1234)
        $lines[1] | Should -Be 'hive log SAM.LOG2: not present'
        $lines[2] | Should -Be 'hive log SECURITY.LOG1: not present'
        $lines[3] | Should -Be ("hive log {0}: {1:N0} bytes" -f 'SECURITY.LOG2', 56)
    }

    It 'records "not present" when Get-Item returns $null for a file that exists (run 46123377266 repro: Test-Path said yes, Get-Item said no)' {
        $dir = Join-Path $TestDrive 'logs-race'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'SAM.LOG1'), [byte[]]::new(100))
        # The CI failure, reproduced: the file is on disk, but the
        # Get-Item call sees nothing (the live mount changed under
        # it). The old Test-Path + Get-Item pair threw here; the
        # single non-throwing call must not.
        function global:Get-Item {
            [CmdletBinding()]
            param([string] $LiteralPath, [string] $Path)
            $key = if ($LiteralPath) { $LiteralPath } else { $Path }
            if ($key -like '*SAM.LOG1') { return $null }
            return Microsoft.PowerShell.Management\Get-Item -LiteralPath $key -ErrorAction $ErrorActionPreference
        }
        $lines = Get-SeedHiveLogLines -ConfigDir $dir
        $lines.Count | Should -Be 4
        Test-Path -LiteralPath (Join-Path $dir 'SAM.LOG1') | Should -BeTrue
        $lines[0] | Should -Be 'hive log SAM.LOG1: not present'
    }

    It 'a throwing Get-Item yields one warning line and never throws (diagnostics must not break the harvest)' {
        $dir = Join-Path $TestDrive 'logs-broken'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        function global:Get-Item {
            [CmdletBinding()]
            param([string] $LiteralPath, [string] $Path)
            throw 'simulated provider failure'
        }
        # A throw here fails the test outright, which is exactly the
        # "never throws" requirement (a Should -Not -Throw scriptblock
        # cannot hand the result back: its assignment stays in the
        # scriptblock's scope). The assertions below pin the
        # best-effort result to one warning line. @(...) keeps the
        # single line an array: a one-element return unwraps to a
        # scalar, and $lines[0] would then be the first character.
        $lines = @(Get-SeedHiveLogLines -ConfigDir $dir)
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match 'hive log files: could not be recorded'
    }
}

Describe 'seed harvest records the log files best-effort (round 42 rerun 13)' {
    # The call site must use the helper (one non-throwing call per
    # file, $null means "not present") and the old Test-Path +
    # Get-Item pair must be gone; the recording happens while V: is
    # still mounted, before the detach in the finally block.
    It 'the harvest calls the helper with the mounted config directory, before the detach' {
        $script:SeedScriptText | Should -Match "Get-SeedHiveLogLines -ConfigDir 'V:\\Windows\\System32\\config'"
        $call = $script:SeedScriptText.IndexOf('Get-SeedHiveLogLines -ConfigDir')
        $detach = $script:SeedScriptText.IndexOf('detaching the converted-back VHD after harvest')
        $call | Should -BeGreaterThan 0
        $detach | Should -BeGreaterThan $call
    }

    It 'the helper makes one non-throwing Get-Item call per file and treats $null as not present' {
        $script:SeedScriptText | Should -Match 'Get-Item -LiteralPath \$logPath -ErrorAction SilentlyContinue'
        $script:SeedScriptText | Should -Match '\$null -ne \$logItem'
        $script:SeedScriptText | Should -Match 'hive log files: could not be recorded'
    }

    It 'the old Test-Path then Get-Item pair is gone (the two calls have no atomicity guarantee)' {
        $script:SeedScriptText | Should -Not -Match 'Test-Path -LiteralPath \$logPath'
        $script:SeedScriptText | Should -Not -Match '\(Get-Item -LiteralPath \$logPath\)\.Length'
    }
}

Describe 'seed hives are uploaded even when the run fails (round 42 rerun 13)' {
    # User 2026-11-28 18:13: even a crashed run must upload the
    # harvested registry files -- run 46123377266 lost good hives
    # because the upload only ran on success, and the hives died
    # with the runner (another 2-hour round wasted). The upload step
    # runs always; missing files only warn, so a harvest that never
    # ran (UUP 504, QEMU never started) does not mask the real
    # failure; a real upload failure still fails the job (no
    # continue-on-error).
    BeforeAll {
        $script:WorkflowText = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/build.yml') -Raw
        $start = $script:WorkflowText.IndexOf('name: Upload seed hives')
        $next = $script:WorkflowText.IndexOf('name: Upload seed evidence', $start)
        $script:HivesUploadBlock = $script:WorkflowText.Substring($start, $next - $start)
    }

    It 'the hives upload runs even when the seed script step failed (if: always())' {
        $script:HivesUploadBlock | Should -Match 'if: always\(\)'
    }

    It 'missing files only warn and never mask the real failure (if-no-files-found: warn, no continue-on-error)' {
        $script:HivesUploadBlock | Should -Match 'if-no-files-found: warn'
        $script:HivesUploadBlock | Should -Not -Match 'continue-on-error'
    }

    It 'the upload list is still explicit files only (no glob, no .LOG files)' {
        $script:HivesUploadBlock | Should -Match 'seed-out/SAM\s+seed-out/SECURITY\s+seed-out/micpe-seed-verify\.txt'
        $script:HivesUploadBlock | Should -Not -Match '\*'
        $script:HivesUploadBlock | Should -Not -Match '\.LOG'
    }
}

Describe 'seed hive verification queries the right Members key (round 42 rerun 14)' {
    # Run 46134591088 never reached the Members check (it died at
    # Names first), but the check as written could never pass:
    # 00000220 has no subkeys, only a C value -- Members is a direct
    # child of Aliases, and members are keyed by hex RID under the
    # domain SID (...\Members\S-1-5-21-<domain>\000003E8). The old
    # query ...\00000220\Members does not exist, and '-1000' matches
    # no Members line. Verified with regipy on the harvested SAM.
    It 'queries Aliases\Members, not the alias key 00000220\Members' {
        $script:SeedScriptText | Should -Match 'Builtin\\Aliases\\Members'
        $script:SeedScriptText | Should -Not -Match '00000220\\Members'
    }

    It 'checks the hex RID 000003E8, not the decimal -1000' {
        $script:SeedScriptText | Should -Match "RidHex '000003E8'"
        $script:SeedScriptText | Should -Not -Match "'-1000'"
    }
}

Describe 'seed hive verification parses real reg.exe output (round 42 rerun 14)' {
    # Run 46134591088 failed at the Names check ("has no MICPE
    # (found: )") on a SAM that regipy proves contains MICPE, and
    # the old tests only checked the script text -- they never
    # executed the parsing, so a parse bug could hide behind a green
    # suite. These tests run the real parse helpers against
    # realistic single-backslash reg.exe /s listings canned from the
    # harvested hive's structure, with MICPE present and absent.
    BeforeAll {
        # Extract the real parse helpers from the seed script
        # (brace-counting scan, same pattern as the .LOG tests), so
        # the tests exercise the shipped functions, not copies.
        function script:Get-ParseHelperText($name) {
            $start = $script:SeedScriptText.IndexOf("function $name")
            if ($start -lt 0) { throw "function $name not found in the seed script" }
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
        . ([scriptblock]::Create((Get-ParseHelperText 'Get-SeedNamesFromRegOutput')))
        . ([scriptblock]::Create((Get-ParseHelperText 'Get-SeedSecurityAccountsFromRegOutput')))
        . ([scriptblock]::Create((Get-ParseHelperText 'Test-SeedMembersHasRid')))

        $script:NamesPrefix = 'HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Account\Users\Names\'
        $script:SecPrefix = 'HKEY_LOCAL_MACHINE\MICPE_SEED_SEC_ab12cd34\Policy\Accounts\'
        $script:NamesOut = @'
HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Account\Users\Names
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Account\Users\Names\Administrator
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Account\Users\Names\DefaultAccount
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Account\Users\Names\Guest
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Account\Users\Names\MICPE
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Account\Users\Names\WDAGUtilityAccount
    (Default)    REG_NONE
'@
        $script:NamesOutNoMicpe = @'
HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Account\Users\Names
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Account\Users\Names\Administrator
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Account\Users\Names\DefaultAccount
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Account\Users\Names\Guest
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Account\Users\Names\WDAGUtilityAccount
    (Default)    REG_NONE
'@
        $script:SecOut = @'
HKEY_LOCAL_MACHINE\MICPE_SEED_SEC_ab12cd34\Policy\Accounts
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SEC_ab12cd34\Policy\Accounts\S-1-1-0
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SEC_ab12cd34\Policy\Accounts\S-1-5-19
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SEC_ab12cd34\Policy\Accounts\S-1-5-20
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SEC_ab12cd34\Policy\Accounts\S-1-5-21-57546213-1521319697-4108371156-501
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SEC_ab12cd34\Policy\Accounts\S-1-5-32-544
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SEC_ab12cd34\Policy\Accounts\S-1-5-32-545
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SEC_ab12cd34\Policy\Accounts\S-1-5-32-551
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SEC_ab12cd34\Policy\Accounts\S-1-5-32-555
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SEC_ab12cd34\Policy\Accounts\S-1-5-32-559
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SEC_ab12cd34\Policy\Accounts\S-1-5-6
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SEC_ab12cd34\Policy\Accounts\S-1-5-80-0
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SEC_ab12cd34\Policy\Accounts\S-1-5-80-3139157870-2983391045-3678747466-658725712-1809340420
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SEC_ab12cd34\Policy\Accounts\S-1-5-90-0
    (Default)    REG_NONE
'@
        $script:SecOutFew = @'
HKEY_LOCAL_MACHINE\MICPE_SEED_SEC_ab12cd34\Policy\Accounts
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SEC_ab12cd34\Policy\Accounts\S-1-1-0
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SEC_ab12cd34\Policy\Accounts\S-1-5-19
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SEC_ab12cd34\Policy\Accounts\S-1-5-20
    (Default)    REG_NONE
'@
        $script:MembersOut = @'
HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5\00000004
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5\0000000B
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5\00000011
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5-21-57546213-1521319697-4108371156
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5-21-57546213-1521319697-4108371156\000001F4
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5-21-57546213-1521319697-4108371156\000001F5
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5-21-57546213-1521319697-4108371156\000001F7
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5-21-57546213-1521319697-4108371156\000003E8
    (Default)    REG_NONE
'@
        $script:MembersOutNoMicpe = @'
HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5\00000004
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5\0000000B
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5\00000011
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5-21-57546213-1521319697-4108371156
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5-21-57546213-1521319697-4108371156\000001F4
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5-21-57546213-1521319697-4108371156\000001F5
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5-21-57546213-1521319697-4108371156\000001F7
    (Default)    REG_NONE
'@
        $script:MembersOutOtherDomain = @'
HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5-21-1111111111-2222222222-3333333333
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_SEED_SAM_ab12cd34\SAM\Domains\Builtin\Aliases\Members\S-1-5-21-1111111111-2222222222-3333333333\000003E8
    (Default)    REG_NONE
'@
    }

    It 'parses all five account names from a realistic Names listing, including MICPE' {
        $names = @(Get-SeedNamesFromRegOutput -RegOutput $script:NamesOut -Prefix $script:NamesPrefix)
        $names.Count | Should -Be 5
        $names | Should -Contain 'MICPE'
        $names | Should -Contain 'Administrator'
        $names | Should -Contain 'DefaultAccount'
        $names | Should -Contain 'Guest'
        $names | Should -Contain 'WDAGUtilityAccount'
    }

    It 'returns the four other accounts when MICPE is absent (the caller then throws "has no MICPE")' {
        $names = @(Get-SeedNamesFromRegOutput -RegOutput $script:NamesOutNoMicpe -Prefix $script:NamesPrefix)
        $names.Count | Should -Be 4
        $names | Should -Not -Contain 'MICPE'
    }

    It 'parses all thirteen SECURITY account SIDs from a realistic Accounts listing' {
        $accounts = @(Get-SeedSecurityAccountsFromRegOutput -RegOutput $script:SecOut -Prefix $script:SecPrefix)
        $accounts.Count | Should -Be 13
        $accounts | Should -Contain 'S-1-5-21-57546213-1521319697-4108371156-501'
        $accounts | Should -Contain 'S-1-5-32-544'
    }

    It 'returns only three accounts from a sparse Accounts listing (the caller then throws "expected >= 10")' {
        $accounts = @(Get-SeedSecurityAccountsFromRegOutput -RegOutput $script:SecOutFew -Prefix $script:SecPrefix)
        $accounts.Count | Should -Be 3
    }

    It 'finds MICPE (hex RID 000003E8) in a realistic Members listing' {
        Test-SeedMembersHasRid -RegOutput $script:MembersOut -RidHex '000003E8' | Should -BeTrue
    }

    It 'does not find MICPE when the Members listing has no 000003E8 entry' {
        Test-SeedMembersHasRid -RegOutput $script:MembersOutNoMicpe -RidHex '000003E8' | Should -BeFalse
    }


Describe 'seed SAM verification reads the hive as SYSTEM (round 42 rerun 15)' {
    BeforeAll {
        $script:RegistryLibText = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src/build/lib/Registry.ps1') -Raw

        function script:Get-RegistryLibFunctionText($name) {
            $start = $script:RegistryLibText.IndexOf("function $name")
            if ($start -lt 0) { throw "function $name not found in lib/Registry.ps1" }
            $open = $script:RegistryLibText.IndexOf('{', $start)
            $depth = 0
            $end = $open
            for ($i = $open; $i -lt $script:RegistryLibText.Length; $i++) {
                $ch = $script:RegistryLibText[$i]
                if ($ch -eq '{') { $depth++ }
                elseif ($ch -eq '}') {
                    $depth--
                    if ($depth -eq 0) { $end = $i; break }
                }
            }
            return $script:RegistryLibText.Substring($start, $end - $start + 1)
        }
        . ([scriptblock]::Create((Get-RegistryLibFunctionText 'Test-CleanRegOutputHasError')))
        . ([scriptblock]::Create((Get-RegistryLibFunctionText 'Get-CleanSystemRegQueryScript')))

        # The exact shape run 46146459319 produced: reg.exe printed
        # "ERROR: Access is denied." and still exited 0, so the
        # Names parse saw an empty list. The output splits into 3
        # lines (the failure message said "reg output had 3 line(s)").
        $script:AccessDeniedOut = "ERROR: Access is denied.`r`n`r`n"
        $script:KeyNotFoundOut = "ERROR: The system was unable to find the specified registry key or value.`r`n"
        $script:CleanNamesOut = @'
HKEY_LOCAL_MACHINE\MICPE_BUILD_SAM_ab12cd34\SAM\Domains\Account\Users\Names
    (Default)    REG_NONE

HKEY_LOCAL_MACHINE\MICPE_BUILD_SAM_ab12cd34\SAM\Domains\Account\Users\Names\MICPE
    (Default)    REG_NONE
'@
        # A value that mentions ERROR: mid-line must NOT count as a
        # failed query -- only a line that starts with ERROR: does
        # (reg.exe puts its own errors at the start of a line).
        $script:ErrorWordInValueOut = @'
HKEY_LOCAL_MACHINE\MICPE_BUILD_SAM_ab12cd34\SAM\Domains\Account\Users\Names\MICPE
    Note    REG_SZ    ERROR: not a real error
'@
    }

    It 'treats the run 46146459319 access-denied output as a failed query, not an empty database' {
        Test-CleanRegOutputHasError -RegOutput $script:AccessDeniedOut | Should -BeTrue
    }

    It 'treats a key-not-found error line as a failed query' {
        Test-CleanRegOutputHasError -RegOutput $script:KeyNotFoundOut | Should -BeTrue
    }

    It 'treats a clean Names listing as a successful query' {
        Test-CleanRegOutputHasError -RegOutput $script:CleanNamesOut | Should -BeFalse
    }

    It 'treats empty output as a successful (empty) query' {
        Test-CleanRegOutputHasError -RegOutput '' | Should -BeFalse
    }

    It 'does not mistake ERROR: inside a value for a failed query' {
        Test-CleanRegOutputHasError -RegOutput $script:ErrorWordInValueOut | Should -BeFalse
    }

    It 'generates a SYSTEM task script that loads, queries and unloads the hive and records both exit codes' {
        $generated = Get-CleanSystemRegQueryScript -HiveFile 'D:\micpe\staging\Windows\System32\config\SAM' -HiveKey 'MICPE_BUILD_SAM_ab12cd34' -QuerySubKey 'SAM\Domains\Account\Users\Names' -LoadOutputFile 'C:\ProgramData\MICPE-SysRegQuery-test\load.log' -QueryOutputFile 'C:\ProgramData\MICPE-SysRegQuery-test\query.log' -CodesFile 'C:\ProgramData\MICPE-SysRegQuery-test\codes.txt' -Recurse
        $generated | Should -Match 'reg\.exe load'
        $generated | Should -Match 'D:\\micpe\\staging\\Windows\\System32\\config\\SAM'
        $generated | Should -Match 'MICPE_BUILD_SAM_ab12cd34'
        $generated | Should -Match 'SAM\\Domains\\Account\\Users\\Names'
        $generated | Should -Match 'reg\.exe query.* /s'
        $generated | Should -Match 'reg\.exe unload'
        $generated | Should -Match 'loadExit='
        $generated | Should -Match 'queryExit='
        $generated | Should -Match 'unloadExit='
        $generated | Should -Match 'C:\\ProgramData\\MICPE-SysRegQuery-test\\load\.log'
        $generated | Should -Match 'C:\\ProgramData\\MICPE-SysRegQuery-test\\query\.log'
        $generated | Should -Match 'C:\\ProgramData\\MICPE-SysRegQuery-test\\codes\.txt'
    }

    It 'omits /s from the generated query when the caller does not ask to recurse' {
        $generated = Get-CleanSystemRegQueryScript -HiveFile 'D:\micpe\staging\Windows\System32\config\SAM' -HiveKey 'MICPE_BUILD_SAM_ab12cd34' -QuerySubKey 'SAM\Domains\Account\Users\000003E8' -LoadOutputFile 'C:\ProgramData\MICPE-SysRegQuery-test\load.log' -QueryOutputFile 'C:\ProgramData\MICPE-SysRegQuery-test\query.log' -CodesFile 'C:\ProgramData\MICPE-SysRegQuery-test\codes.txt'
        $generated | Should -Match 'reg\.exe query'
        $generated | Should -Not -Match '/s'
    }

    It 'seed step queries the staged SAM as SYSTEM instead of running reg.exe as the admin' {
        $script:CleanScriptText | Should -Match 'Invoke-CleanSystemRegQuery'
        $start = $script:CleanScriptText.IndexOf('function Invoke-CleanSamSeedStep')
        $step = $script:CleanScriptText.Substring($start, $script:CleanScriptText.IndexOf('function Invoke-CleanRegistryStep', $start) - $start)
        $step | Should -Not -Match '& reg\.exe query'
        $step | Should -Not -Match '& reg\.exe load'
        $step | Should -Not -Match 'namesPreview'
    }

    It 'seed step logs the manifest hashes and the copy before verifying (the run 46146459319 log had neither)' {
        $script:CleanScriptText | Should -Match 'seed manifest SAM'
        $script:CleanScriptText | Should -Match 'seed manifest SECURITY'
        $script:CleanScriptText | Should -Match 'seed copy'
    }

    It 'seed step failure message distinguishes a failed reg load from a failed reg query' {
        $start = $script:CleanScriptText.IndexOf('function Invoke-CleanSamSeedStep')
        $step = $script:CleanScriptText.Substring($start, $script:CleanScriptText.IndexOf('function Invoke-CleanRegistryStep', $start) - $start)
        $step | Should -Match 'reg load failed for staged SAM'
        $step | Should -Match 'reg query failed for staged SAM Users\\Names'
        $step | Should -Match 'full reg output'
    }

    It 'seed-side verification queries the harvested hives as SYSTEM too (run 46134591088 died the same way)' {
        $script:SeedScriptText | Should -Match 'Invoke-CleanSystemRegQuery'
        $script:SeedScriptText | Should -Match 'full reg output'
    }
}

    It 'finds MICPE under a different domain SID (the check must not depend on the machine SID)' {
        Test-SeedMembersHasRid -RegOutput $script:MembersOutOtherDomain -RidHex '000003E8' | Should -BeTrue
    }
}
