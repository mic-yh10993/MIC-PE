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
