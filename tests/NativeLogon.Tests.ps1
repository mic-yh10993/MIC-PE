BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:Boot = Get-Content -LiteralPath (Join-Path $script:Repo 'src/shell/startnet-native-logon.cmd') -Raw
    $script:Session = Get-Content -LiteralPath (Join-Path $script:Repo 'src/shell/logon-admin.cmd') -Raw
    # .NET detects the UTF-16 BOM of the .reg files; Get-Content -Raw does too.
    $script:Overlay = [System.IO.File]::ReadAllText((Join-Path $script:Repo 'src/registry/25-native-logon-experiment.reg'))
    $script:SystemOverlay = [System.IO.File]::ReadAllText((Join-Path $script:Repo 'src/registry/26-native-logon.reg'))
    $script:TextInputOverlay = [System.IO.File]::ReadAllText((Join-Path $script:Repo 'src/registry/27-textinput-service.reg'))
    $script:Build = Get-Content -LiteralPath (Join-Path $script:Repo 'src/build/Build-Micpe.ps1') -Raw
    $script:ShellLib = Get-Content -LiteralPath (Join-Path $script:Repo 'src/build/lib/Shell.ps1') -Raw
    $script:WimLib = Get-Content -LiteralPath (Join-Path $script:Repo 'src/build/lib/Wim.ps1') -Raw
}

Describe 'native Administrator logon bootstrap' {
    It 'creates the Administrator shell via seclogon instead of switching sessions' {
        # MEASURED on the built image: TermService has no ImagePath and
        # termsrv.dll is absent from boot.wim, so WTSDisconnectSession has no
        # provider. tsdiscon therefore returned immediately and the console
        # stayed on the SYSTEM session. The shell is created with a genuine
        # Administrator logon token (runas -> CreateProcessWithLogonW ->
        # seclogon) instead, which is what gives explorer a real LSA logon
        # session rather than a duplicated SYSTEM token.
        $script:Boot | Should -Match 'runas\.exe'
        $script:Boot | Should -Match '/user:Administrator'
        $script:Boot | Should -Match 'seclogon'
        $script:Boot | Should -Not -Match '(?im)^\s*shutdown\.exe\s+/l'
        $script:Boot | Should -Not -Match '(?im)^\s*logoff\.exe'
    }

    It 'does not start LogonUI directly and does not create an account' {
        $script:Boot | Should -Not -Match '(?im)^\s*LogonUI\.exe'
        $script:Boot | Should -Not -Match '(?im)^\s*net\.exe\s+user\s+\S+\s+/add'
    }

    It 'configures autologon for the built-in Administrator with an empty password' {
        $script:Boot | Should -Match 'AutoAdminLogon\s+/t REG_DWORD\s+/d 1'
        $script:Boot | Should -Match 'DefaultUserName\s+/t REG_SZ\s+/d Administrator'
        $script:Boot | Should -Match 'DefaultPassword\s+/t REG_SZ\s+/d ""'
        $script:Boot | Should -Match 'ForceAutoLogon\s*/f'
    }

    It 'points Userinit at the authenticated-session script' {
        $script:Boot | Should -Match 'Userinit\s+/t REG_SZ'
        $script:Boot | Should -Match 'logon-admin\.cmd'
    }

    It 'prepares the user hive and the AppX service chain' {
        $script:Boot | Should -Match 'System32\\config\\Default'
        $script:Boot | Should -Match 'NTUSER\.DAT'
        $script:Boot | Should -Match 'SystemSetupInProgress\s+/t REG_DWORD\s+/d 0'
        foreach ($svc in 'seclogon', 'Themes', 'SENS', 'Appinfo', 'SamSs', 'ProfSvc', 'UserManager', 'StateRepository', 'CoreMessagingRegistrar', 'TextInputManagementService') {
            $script:Boot | Should -Match ([regex]::Escape($svc))
        }
    }

    It 'enables the RID-500 account with secedit (EnableAdminAccount)' {
        # The decisive fix: AutoAdminLogon silently fails when the built-in
        # Administrator is disabled in SAM. WimBuilder2 applies unattend.inf
        # ([System Access] EnableAdminAccount=1) via secedit before tsdiscon.
        $script:Boot | Should -Match 'secedit\.exe"?\s+/configure'
        $script:Boot | Should -Match 'unattend\.sdb'
        $script:Boot | Should -Match 'unattend\.inf'
    }

    It 'starts SamSs before secedit so the SAM RPC endpoint exists' {
        # secedit /configure applies [System Access] through the SAM database.
        # With SamSs down it blocks forever, which is exactly where the boot
        # used to hang: log stopped after 'secedit exit=' and no session formed.
        $script:Boot | Should -Match 'start SamSs'
        $startPos = $script:Boot.IndexOf('start SamSs')
        $seceditPos = $script:Boot.IndexOf('secedit.exe')
        $startPos | Should -BeLessThan $seceditPos
    }

    It 'time-boxes every external command so nothing can hang the boot' {
        $script:Boot | Should -Match '(?m)^:RUN'
        $script:Boot | Should -Match 'TIMEOUT after'
        $script:Boot | Should -Match 'taskkill /f /im'
        $script:Boot | Should -Match ':COUNTDOWN'
    }

    It 'prints the log on screen and pops a live log console' {
        # A black desktop with no readable evidence is untestable; the log is
        # mirrored to the console and show-log.cmd opens its own window.
        $script:Boot | Should -Match 'show-log\.cmd'
        $script:Boot | Should -Match 'native-logon-bootstrap\.log'
        Test-Path -LiteralPath (Join-Path $script:Repo 'src/shell/show-log.cmd') | Should -BeTrue
        $script:ShellLib | Should -Match 'show-log\.cmd'
    }

    It 'grants Administrator token privileges via LSAgetRights' {
        # Without SeAssignPrimaryTokenPrivilege / SeImpersonatePrivilege /
        # SeCreateTokenPrivilege the shell in the new session fails with
        # "referencing a token that does not exist" (STATUS_NO_SUCH_LOGON_SESSION).
        $script:Boot | Should -Match 'LSAgetRights\.exe'
        $script:Boot | Should -Match '\-c\s+-u\s+Administrator'
    }

    It 'pre-creates the Administrator profile (RefCount + FirstLogon=0)' {
        $script:Boot | Should -Match 'ProfileService'
        $script:Boot | Should -Match 'RefCount\s+/t REG_BINARY\s+/d 02000000'
        $script:Boot | Should -Match 'FirstLogon\s+/t REG_DWORD\s+/d 0'
        $script:Boot | Should -Match 'Users\\Administrator\\NTUSER\.DAT'
    }

    It 'repairs the stub seclogon service before the session switch' {
        # boot.wim ships seclogon with only a Start value: no ImagePath and no
        # Parameters\ServiceDll. `sc start seclogon` therefore always failed,
        # and without the Secondary Logon service tsdiscon returns without
        # switching, leaving the console on the SYSTEM session. The bootstrap
        # must rewrite the full definition at runtime (the build also ships
        # 28-logon-services.reg, but a swapped SYSTEM hive must not undo it).
        $script:Boot | Should -Match '(?m)^:FIXSVC'
        $script:Boot | Should -Match '(?m)^call :FIXSVC seclogon'
        $script:Boot | Should -Match 'svchost\.exe -k netsvcs -p -s'
        $script:Boot | Should -Match 'ServiceDll'
        $script:Boot | Should -Match 'Setup\\AllowStart'
    }

    It 'waits for explorer.exe and then keeps the PE session alive' {
        # runas returns before the new process has initialised, so success is
        # only proven once explorer.exe is actually running. And winpeshl.exe
        # launched the bootstrap as the PE shell - WinPE reboots as soon as it
        # exits - so the script must hold after the shell is up and keep
        # watching it, or a dying explorer looks like an unexplained black
        # screen.
        $script:Boot | Should -Match '(?m)^:WAITEXPLORER'
        $script:Boot | Should -Match '(?m)^:HOLD'
        $script:Boot | Should -Match 'imagename eq explorer\.exe'
        $script:Boot | Should -Match '(?m)^:DIAG'
    }

    It 'ships a security template that actually grants interactive logon' {
        # The WimBuilder2 template only sets EnableAdminAccount=1. A
        # programmatic logon also needs SeInteractiveLogonRight for the account
        # and LimitBlankPasswordUse=0, or the blank-password Administrator is
        # refused even though the account is enabled.
        $inf = Join-Path $script:Repo 'assets/logon/unattend-logon.inf'
        Test-Path -LiteralPath $inf | Should -BeTrue
        $t = [System.IO.File]::ReadAllText($inf)
        $t | Should -Match 'EnableAdminAccount\s*=\s*1'
        $t | Should -Match 'SeInteractiveLogonRight'
        $t | Should -Match 'LimitBlankPasswordUse'
        # and the build must overlay it over the cab-extracted donor template
        $script:WimLib | Should -Match 'unattend-logon\.inf'
    }

    It 'keeps a done-marker so the bootstrap is idempotent' {
        $script:Boot | Should -Match 'native-logon-bootstrap\.done'
        $script:Boot | Should -Match 'if exist "%DONE%" exit /b 0'
    }
}

Describe 'authenticated session initialization' {
    It 'writes whoami evidence instead of claiming success blindly' {
        $script:Session | Should -Match 'whoami\s*/user'
        $script:Session | Should -Match 'session_non_system'
        $script:Session | Should -Match 'native-logon-probe\.txt'
    }

    It 'does not depend on PECMD in the native logon path' {
        # Only reject executable lines; a comment explaining the absence
        # of PECMD is fine and useful documentation.
        $script:Session | Should -Not -Match '(?im)^\s*(?:call\s+)?PECMD\.EXE'
    }

    It 'explicitly starts Explorer in the authenticated session (black-screen fix)' {
        # Winlogon's Shell=explorer.exe path is unreliable in a fresh PE
        # session; WimBuilder2's RunShell starts it explicitly. Without this
        # the session forms but stays black with no taskbar/Start menu.
        $script:Session | Should -Match '(?im)^\s*start\s+""\s+.*explorer\.exe'
        $script:Session | Should -Match 'SHELL_STARTED'
    }
}

Describe 'native logon registry overlays' {
    It 'sets a real autologon and leaves Userinit with the stock chain' {
        $script:Overlay | Should -Match '"AutoAdminLogon"="1"'
        $script:Overlay | Should -Match '"DefaultPassword"=""'
        $script:Overlay | Should -Match '"DefaultUserName"="Administrator"'
        # Path separators must be single backslashes in the registry
        # (\\ in .reg text). Forward slashes (X://Windows//) broke userinit.
        $script:Overlay | Should -Match 'userinit\.exe'
        $script:Overlay | Should -Not -Match 'X://'
        $script:Overlay | Should -Match '"Shell"="explorer\.exe"'
        $script:Overlay | Should -Match '"EnableSIHostIntegration"=dword:00000001'
    }

    It 'runs the session init from Run through a hidden launcher' {
        # Winlogon starts the shell itself now, so the script is no longer
        # chained onto Userinit; it must still run without painting a console
        # over the new desktop, hence the script host with a hidden window.
        $script:Overlay | Should -Match 'MICPEInit'
        $script:Overlay | Should -Match 'run-hidden\.vbs'
        Test-Path -LiteralPath (Join-Path $script:Repo 'src/shell/run-hidden.vbs') | Should -BeTrue
        $script:ShellLib | Should -Match 'run-hidden\.vbs'
        $script:RunHidden = Get-Content -LiteralPath (Join-Path $script:Repo 'src/shell/run-hidden.vbs') -Raw
        $script:RunHidden | Should -Match 'logon-admin\.cmd'
        $script:RunHidden | Should -Match 'Run cmd, 0, False'
    }

    It 'allows blank-password local logon and sets service start types' {
        $script:SystemOverlay | Should -Match '"LimitBlankPasswordUse"=dword:00000000'
        $script:SystemOverlay | Should -Match 'Services\\seclogon'
    }

    It 'adds TextInputManagementService + AllowStart for Ctrl+Alt+Del / logon UI' {
        # 24H2 PE lacks this service; without it SAS (Ctrl+Alt+Del) and the
        # interactive logon UI fail. Both reference builds add it.
        $script:TextInputOverlay | Should -Match 'TextInputManagementService'
        $script:TextInputOverlay | Should -Match 'Setup\\AllowStart'
        $script:Boot | Should -Match 'TextInputManagementService'
        $script:Session | Should -Match 'TextInputManagementService'
        $script:Build | Should -Match '27-textinput-service\.reg'
    }

    It 'joins WORKGROUP at runtime (required for logon per the 24H2 guide)' {
        $script:Boot | Should -Match 'PENetwork'
        $script:Boot | Should -Match '\-wg WORKGROUP'
    }

    It 'sets the Client-style Setup state so Winlogon shows LogonUI' {
        # MEASURED on the user's image: WinPE ships CmdLine=winpeshl.exe,
        # SetupType=1, SystemSetupInProgress=1, FactoryPreInstallInProgress=1,
        # so Winlogon runs startnet as the session shell and never draws
        # LogonUI. A working reference RAMOS (Client base, real LogonUI)
        # carries CmdLine=LogonUI, SetupType=2, SystemSetupInProgress=0,
        # FactoryPreInstallInProgress=0 - those exact four values are the fix.
        $script:SystemOverlay | Should -Match '"SystemSetupInProgress"=dword:00000000'
        $script:SystemOverlay | Should -Match '"SetupType"=dword:00000002'
        $script:SystemOverlay | Should -Match '"CmdLine"="LogonUI"'
        $script:SystemOverlay | Should -Match '"FactoryPreInstallInProgress"=dword:00000000'
    }
}

Describe 'native logon build wiring' {
    It 'imports the SYSTEM-hive overlay in the Explorer step' {
        # The file must be in RegFiles to be imported at all, and its leaf
        # name (not a full path) must be in SystemRegFiles for SYSTEM routing.
        $script:Build | Should -Match 'regFiles \+= Join-Path .*26-native-logon\.reg'
        $script:Build | Should -Match "systemRegFiles \+= '26-native-logon\.reg'"
        $script:Build | Should -Match '-SystemRegFiles \$systemRegFiles'
    }

    It 'installs the logon script into the image' {
        $script:ShellLib | Should -Match 'logon-admin\.cmd'
    }

    It 'places Microsoft-signed tsdiscon/tscon tools into System32' {
        # 26300 exposes these only as DCS-compressed WinSxS streams, so the
        # build must use the signed host binaries and assert the final path.
        $script:WimLib | Should -Match 'function Copy-SignedHostToolsToSystem32'
        $script:WimLib | Should -Match 'Get-AuthenticodeSignature'
        $script:Build | Should -Match '(?s)Copy-SignedHostToolsToSystem32.*tsdiscon\.exe'
        $script:Build | Should -Match "(?s)Assert-PathExists.*System32.*tsdiscon\.exe"
    }

    It 'installs the WimBuilder2 account/security assets (secedit template, LSAgetRights, UsrClass.dat)' {
        # These are the assets that make the real Administrator logon work on
        # the same image that WimBuilder2 boots. Copying a few Winlogon values
        # into SOFTWARE is not sufficient.
        $script:WimLib | Should -Match 'function Install-NativeLogonAssets'
        $script:WimLib | Should -Match "Security\.cab"
        $script:WimLib | Should -Match 'EnableAdminAccount'
        $script:WimLib | Should -Match 'LSAgetRights_x64\.exe'
        $script:WimLib | Should -Match 'UsrClass\.dat'
        $script:Build | Should -Match 'Install-NativeLogonAssets\s+-MountDir'
    }

    It 'enables Administrator in the offline SAM (runtime net user cannot work)' {
        # A real Winlogon logon needs the account enabled in the image: the
        # wim overlay discards runtime registry writes on reboot.
        $script:AdminLib = Get-Content -LiteralPath (Join-Path $script:Repo 'src/build/lib/AdminAccount.ps1') -Raw
        $script:AdminLib | Should -Match 'function Set-OfflineAdminState'
        $script:AdminLib | Should -Match 'ACB_DISABLED'
        $script:AdminLib | Should -Match '0x38'
        $script:AdminLib | Should -Match 'schtasks\.exe'
        $script:Build | Should -Match 'AdminAccount'
        $script:Build | Should -Match 'Set-OfflineAdminState\s+-SamPath'
    }

    It 'ships the WimBuilder2 donor assets in the repository' {
        $assetDir = Join-Path $script:Repo 'assets\logon'
        Test-Path -LiteralPath (Join-Path $assetDir 'LSAgetRights_x64.exe') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $assetDir 'Security.cab') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $assetDir 'UsrClass.dat') | Should -BeTrue
    }
}
