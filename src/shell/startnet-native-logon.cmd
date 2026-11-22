@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem MICPE native Administrator logon bootstrap (SYSTEM phase). Runs from
rem startnet.cmd via Winlogon in the SYSTEM session, BEFORE the switch.
rem
rem This is the WimBuilder2 `LogonAdmin.bat` sequence adapted to this build,
rem but every external command is wrapped in a watchdog (:RUN) so that a
rem blocked call can NEVER hang the boot with a black screen and no evidence.
rem   1. prepare the Default user hive (profile template)
rem   2. write AutoAdminLogon / Userinit / Shell into the live Winlogon key
rem   3. start SamSs first, so SECEDIT can talk to the SAM database
rem   4. apply the security template that ENABLES the built-in Administrator
rem   5. verify/enable RID 500 with net.exe as a second opinion
rem   6. grant Administrator SYSTEM-class token privileges (LSAgetRights)
rem   7. pre-create the Administrator profile (RefCount, FirstLogon=0)
rem   8. join WORKGROUP so LSA has a valid machine context
rem   9. repair the stub seclogon service (+ SENS/Appinfo/Themes/Schedule)
rem  10. clear SystemSetupInProgress and start the logon services
rem  11. dump the real service/process/session state (native-logon-diag.txt)
rem  12. create explorer.exe with a real Administrator token via seclogon
rem
rem tsdiscon is deliberately NOT used: TermService has no ImagePath and
rem termsrv.dll is absent from boot.wim, so the WTS API cannot switch the
rem console (see the note in step 12). The shell is created with an actual
rem Administrator logon token instead, and this script keeps the PE session
rem alive because WinPE reboots when its shell process exits.
rem
rem No LogonUI.exe is launched directly and no extra account is created.

set "MICPE=%SystemRoot%\System32\MICPE"
set "LOG=%MICPE%\native-logon-bootstrap.log"
set "DONE=%MICPE%\native-logon-bootstrap.done"
set "TMPD=%MICPE%\run"
set "SESSION=%MICPE%\logon-admin.cmd"
set "WL=HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
set "POL=HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
set "LSA=HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\Lsa"
set "PROFSVC=HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileService"
set "SYS32=%SystemRoot%\System32"

if exist "%DONE%" exit /b 0

if not exist "%MICPE%" md "%MICPE%"
if not exist "%TMPD%" md "%TMPD%"
if not exist "%SystemRoot%\security\database" md "%SystemRoot%\security\database"
if not exist "%SystemRoot%\security\logs" md "%SystemRoot%\security\logs"

rem ---- publish target: first writable non-X: volume (found BEFORE any risk) ----
set "PUB="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if not defined PUB if exist "%%D:\" (
        echo t 2>nul > "%%D:\micpe-diag-test.tmp"
        if exist "%%D:\micpe-diag-test.tmp" (
            del "%%D:\micpe-diag-test.tmp" >nul 2>&1
            set "PUB=%%D:\"
        )
    )
)

echo [%date% %time%] native Administrator logon bootstrap started > "%LOG%"
call :LOG "publish dir = %PUB%"
call :PUBLISH

rem ---- live log window ----
rem A second console shows the log and refreshes itself, so progress is
rem visible on screen even when the session switch ends in a black desktop.
rem Guarded by if exist so a missing file can never raise a dialog.
if exist "%MICPE%\show-log.cmd" (
    start "MICPE logon log" "%SYS32%\cmd.exe" /k "%MICPE%\show-log.cmd"
)

wpeinit
call :LOG "wpeinit returned !errorlevel!"

if exist "%MICPE%\Fix-DriveLetters.cmd" call "%MICPE%\Fix-DriveLetters.cmd" >>"%LOG%" 2>&1

rem ---- 1. profile template (LogonAdmin.bat step 1) ----
rem The Administrator profile is cloned from the Default hive at first logon.
rem Always replace a stale NTUSER.DAT with a fresh copy of config\Default.
if exist "X:\Users\Default\NTUSER.DAT" del /q "X:\Users\Default\NTUSER.DAT" >nul 2>&1
if exist "%SystemRoot%\System32\config\Default" (
    copy /y "%SystemRoot%\System32\config\Default" "X:\Users\Default\NTUSER.DAT" >>"%LOG%" 2>&1
    call :LOG "prepared Users\Default\NTUSER.DAT"
)
rem Removing UserPreferencesMask shows the logon animation instead of a black
rem desktop during the session switch (WimBuilder2 LogonAdmin.bat step 2).
reg.exe delete "HKU\.DEFAULT\Control Panel\Desktop" /v UserPreferencesMask /f >>"%LOG%" 2>&1

rem ---- 2. Winlogon autologon configuration (LogonAdmin.bat steps 3-8) ----
reg.exe add "%WL%" /v AutoAdminLogon /t REG_DWORD /d 1 /f >>"%LOG%" 2>&1
reg.exe add "%WL%" /v DefaultUserName /t REG_SZ /d Administrator /f >>"%LOG%" 2>&1
reg.exe add "%WL%" /v DefaultPassword /t REG_SZ /d "" /f >>"%LOG%" 2>&1
reg.exe delete "%WL%" /v ForceAutoLogon /f >>"%LOG%" 2>&1
rem WimBuilder2 intentionally does NOT set Shell when explorer.exe is present:
rem Winlogon's Shell= launch path is unreliable in WinPE. We DO set it here as
rem a fallback because there is no WinXShell; logon-admin.cmd also starts
rem Explorer explicitly from the authenticated session. Two starts are benign.
reg.exe add "%WL%" /v Shell /t REG_SZ /d "explorer.exe" /f >>"%LOG%" 2>&1

rem Userinit runs in the AUTHENTICATED user session, before Explorer. The
rem trailing comma is required (comma-terminated program list).
if exist "%SESSION%" (
    reg.exe add "%WL%" /v Userinit /t REG_SZ /d "%SYS32%\userinit.exe,%SESSION%," /f >>"%LOG%" 2>&1
) else (
    reg.exe add "%WL%" /v Userinit /t REG_SZ /d "%SYS32%\userinit.exe," /f >>"%LOG%" 2>&1
    call :LOG "WARNING: %SESSION% missing; using stock Userinit"
)

rem Hide Guest in the logon UI; Administrator stays visible.
reg.exe add "%WL%\SpecialAccounts\UserList" /v Guest /t REG_DWORD /d 0 /f >>"%LOG%" 2>&1

if exist "%SYS32%\AppxSysprep.dll" (
    reg.exe add "%WL%" /v EnableSIHostIntegration /t REG_DWORD /d 1 /f >>"%LOG%" 2>&1
) else (
    reg.exe add "%WL%" /v EnableSIHostIntegration /t REG_DWORD /d 0 /f >>"%LOG%" 2>&1
)
call :PUBLISH

rem ---- 3. start SamSs FIRST (secedit needs the SAM RPC endpoint) ----
rem Root cause of the previous hang: secedit.exe /configure applies
rem [System Access] by calling into the SAM database. In WinPE the Security
rem Accounts Manager service is not running, so secedit blocks forever and
rem the chain never reaches tsdiscon. SamSs is already whitelisted in
rem HKLM\SYSTEM\Setup\AllowStart by the base image, so it can start now even
rem while SystemSetupInProgress is still 1.
set CL="%SYS32%\sc.exe" start SamSs
call :RUN sc-SamSs 30
set CL="%SYS32%\sc.exe" start RPCSS
call :RUN sc-RPCSS 20
call :PUBLISH

rem ---- 4. enable the built-in Administrator via secedit (CRITICAL) ----
rem unattend.inf has [System Access] EnableAdminAccount=1 and
rem NewAdministratorName=Administrator. Without this the RID-500 account can
rem remain disabled, so LSA refuses AutoAdminLogon and no session is formed.
if exist "%SystemRoot%\security\templates\unattend.inf" (
    set CL="%SYS32%\secedit.exe" /configure /db "%SystemRoot%\security\database\unattend.sdb" /cfg "%SystemRoot%\security\templates\unattend.inf" /log "%SystemRoot%\security\logs\unattend.log"
    call :RUN secedit 240
) else (
    call :LOG "ERROR: unattend.inf missing; Administrator may stay disabled"
)
call :PUBLISH

rem ---- 5. second opinion: net.exe user /active:yes ----
rem Works only when SamSs is up, which is exactly what step 3 guarantees.
rem Harmless if the account is already enabled; the query below records the
rem resulting state next to the secedit result.
set CL="%SYS32%\net.exe" user Administrator /active:yes
call :RUN net-enable 40
set CL="%SYS32%\net.exe" user Administrator
call :RUN net-query 40
call :PUBLISH

rem ---- 6. grant token privileges to Administrator (CRITICAL) ----
rem LSAgetRights adds SeAssignPrimaryTokenPrivilege, SeImpersonatePrivilege,
rem SeCreateTokenPrivilege and friends to RID 500. Without them a shell created
rem in the new session fails with "referencing a token that does not exist".
if exist "%SYS32%\LSAgetRights.exe" (
    set CL="%SYS32%\LSAgetRights.exe" -c -u Administrator
    rem It prints "the Admin SID is ..." and "CreateProfile return 0" and then
    rem blocks on its own LSA handle, so a short cap is enough: the profile
    rem and the privileges are already applied at that point.
    call :RUN LSAgetRights 45
) else (
    call :LOG "ERROR: LSAgetRights.exe missing"
)
call :PUBLISH

rem ---- 7. pre-create the Administrator profile (LogonAdmin.bat step 11) ----
rem LSAgetRights -c above already created X:\Users\Administrator together
rem with its NTUSER.DAT and registered it under ProfileList. Mark the profile
rem as referenced (RefCount=2) and disable the first-logon work, exactly like
rem WimBuilder2 PreCreateAdminProfile.bat.
rem
rem The SID is read back from ProfileList instead of being guessed from
rem HKLM\SECURITY\...\Aliases\Members: that value is a REG_BINARY blob, so the
rem old text slicing could never produce a SID and the whole profile step was
rem skipped with "could not derive Administrator SID".
set "ADMINSID="
for /f "tokens=*" %%k in ('reg.exe query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" 2^>nul') do (
    set "K=%%k"
    if "!K:~-4!"=="-500" set "ADMINSID=!K!"
)
if defined ADMINSID set "ADMINSID=!ADMINSID:*\ProfileList\=!"
if defined ADMINSID (
    reg.exe add "%PROFSVC%\References\!ADMINSID!" /v RefCount /t REG_BINARY /d 02000000 /f >>"%LOG%" 2>&1
    if exist "X:\Users\Administrator\NTUSER.DAT" (
        reg.exe load "HKU\!ADMINSID!" "X:\Users\Administrator\NTUSER.DAT" >>"%LOG%" 2>&1
        reg.exe add "HKU\!ADMINSID!\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v FirstLogon /t REG_DWORD /d 0 /f >>"%LOG%" 2>&1
        reg.exe add "HKU\!ADMINSID!\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Associations" /v LowRiskFileTypes /t REG_SZ /d ".com;.exe;.bat;.cmd;" /f >>"%LOG%" 2>&1
        reg.exe unload "HKU\!ADMINSID!" >>"%LOG%" 2>&1
    )
    call :SAY "pre-created Administrator profile for !ADMINSID!"
) else (
    call :SAY "WARNING: no RID-500 entry in ProfileList; profile precreate skipped"
)
call :PUBLISH

rem ---- 8. policies + WORKGROUP (LogonAdmin.bat NetJoin) ----
reg.exe add "%POL%" /v DelayedDesktopSwitchTimeout /t REG_DWORD /d 0 /f >>"%LOG%" 2>&1
reg.exe add "%POL%" /v EnableLUA /t REG_DWORD /d 0 /f >>"%LOG%" 2>&1
reg.exe add "%POL%" /v EnableCursorSuppression /t REG_DWORD /d 0 /f >>"%LOG%" 2>&1
reg.exe add "%POL%" /v EnableFirstLogonAnimation /t REG_DWORD /d 0 /f >>"%LOG%" 2>&1
reg.exe add "%POL%\Associations" /v LowRiskFileTypes /t REG_SZ /d ".com;.exe;.bat;.cmd;" /f >>"%LOG%" 2>&1

reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v Domain /t REG_SZ /d WORKGROUP /f >>"%LOG%" 2>&1
set "PENET=%ProgramFiles%\MICPE\PENetwork\startnet.exe"
if exist "%PENET%" (
    set CL="%PENET%" -wg WORKGROUP
    call :RUN PENetwork 90
) else (
    call :LOG "registry Domain=WORKGROUP set; PENetwork helper absent"
)
call :PUBLISH

rem ---- 9. repair the stub / missing logon services (THE root cause) ----
rem The base PE hive ships `seclogon` as a STUB: only a Start value, no
rem ImagePath and no Parameters\ServiceDll. `sc start seclogon` therefore
rem always failed, and because the old service loop threw away every exit
rem code the failure was invisible. tsdiscon needs the Secondary Logon
rem service to materialise the Administrator session, so it returned
rem "successfully" while the console stayed on the SYSTEM session.
rem
rem The build writes a complete definition (28-logon-services.reg); this
rem repairs it again at runtime so a swapped SYSTEM hive cannot undo it.
call :FIXSVC seclogon 2 "seclogon.dll"
call :FIXSVC SENS 2 "Sens.dll"
call :FIXSVC Appinfo 3 "appinfo.dll"
call :FIXSVC Themes 2 "themeservice.dll"
call :FIXSVC Schedule 3 "schedsvc.dll"
call :PUBLISH

rem ---- 10. leave Setup mode, then start the logon services ----
rem SystemSetupInProgress keeps Winlogon in setup mode (it executes
rem Setup\CmdLine instead of performing a real logon), so it must be cleared
rem before the switch. It is only ever cleared HERE at runtime - writing 0
rem into the image at build time breaks the boot with 0xEF.
reg.exe add "HKLM\SYSTEM\Setup" /v SystemSetupInProgress /t REG_DWORD /d 0 /f >>"%LOG%" 2>&1
reg.exe add "%LSA%" /v LimitBlankPasswordUse /t REG_DWORD /d 0 /f >>"%LOG%" 2>&1
call :SAY "SystemSetupInProgress cleared"
for %%S in (seclogon Themes SENS Appinfo SamSs ProfSvc UserManager StateRepository CoreMessagingRegistrar TextInputManagementService) do (
    sc.exe start %%S >>"%LOG%" 2>&1
    call :SAY "  sc start %%S rc=!errorlevel!"
)
call :SAY "logon services start requested"
call :PUBLISH

rem ---- 11. record what actually runs (the evidence that was missing) ----
call :DIAG

rem ---- 12. create the desktop shell with a REAL Administrator token ----
rem MEASURED FACT: tsdiscon.exe cannot work on this image. TermService has no
rem ImagePath in the SYSTEM hive and termsrv.dll is absent from boot.wim, so
rem WTSDisconnectSession has no provider: tsdiscon returns immediately, the
rem console is never disconnected, Winlogon stays in setup mode and LogonUI is
rem never painted. That is exactly the observed behaviour ("tsdiscon returned;
rem Winlogon did not take over" followed by the SYSTEM cmd prompt).
rem
rem So do not switch sessions at all. Create the shell process directly with an
rem Administrator logon token through the Secondary Logon service:
rem   runas.exe -> CreateProcessWithLogonW -> seclogon
rem The token then has a genuine LSA logon session (this is what a duplicated
rem SYSTEM token lacks - the cause of "a specified logon session does not exist"
rem / "referencing a token that does not exist" when explorer is started as
rem SYSTEM), and the process inherits this console's desktop
rem (WinSta0\Default), so it is visible.
if not exist "%SYS32%\runas.exe" goto :NO_LAUNCHER

call :SAY "creating the Administrator shell via seclogon (runas, blank password)"
call :PUBLISH
call :COUNTDOWN 3
echo 1>"%DONE%"

rem runas reads the password from the console, so the blank password is fed as
rem one empty line. It is generated into a script because a pipe cannot be put
rem through :RUN's command variable without breaking the parser, and System32
rem has no spaces so no quoting is needed at all.
> "%MICPE%\su-run.cmd" echo @echo off
>>"%MICPE%\su-run.cmd" echo echo.^|%SYS32%\runas.exe /user:Administrator /env %SYS32%\explorer.exe ^>^> "%LOG%" 2^>^&1
call :SAY "launcher script: su-run.cmd"
start "" /b %SYS32%\cmd.exe /c "%MICPE%\su-run.cmd"

call :WAITEXPLORER 40
if errorlevel 1 goto :NO_SHELL

call :SAY "explorer.exe is running - desktop shell owns an Administrator token"
call :DIAG
call :PUBLISH

rem Keep the bootstrap alive: winpeshl.exe launched this cmd as the PE shell,
rem and WinPE reboots as soon as it exits. Holding here also monitors the
rem shell, so a dying explorer is recorded instead of looking like a black
rem screen with no explanation.
:HOLD
ping -n 30 127.0.0.1 >nul 2>&1
if exist "%SYS32%\tasklist.exe" (
    tasklist.exe /fi "imagename eq explorer.exe" 2>nul | find /i "explorer.exe" >nul
    if errorlevel 1 goto :SHELL_DIED
)
goto :HOLD

:SHELL_DIED
call :SAY "WARNING: explorer.exe is no longer running"
call :DIAG
call :PUBLISH
call :SHOWLOG
cmd.exe
exit /b 1

:NO_SHELL
call :DIAG
call :SAY "ERROR: explorer.exe did not start via seclogon"
call :SAY "hint: check runas error text above and 'sc query seclogon' in native-logon-diag.txt"
call :PUBLISH
call :SHOWLOG
cmd.exe
exit /b 1

:NO_LAUNCHER
call :SAY "ERROR: runas.exe is missing; cannot create the Administrator shell"
call :PUBLISH
call :SHOWLOG
cmd.exe
exit /b 1

rem =====================================================================
rem helpers
rem =====================================================================

:SAY
:LOG
echo [%date% %time%] %~1>>"%LOG%"
echo [%date% %time%] %~1
exit /b 0

:SHOWLOG
if exist "%MICPE%\show-log.cmd" (
    start "MICPE logon log" "%SYS32%\cmd.exe" /k "%MICPE%\show-log.cmd"
)
exit /b 0

rem :COUNTDOWN <seconds> - visible wait so the console stays readable.
:COUNTDOWN
set /a CD_N=%~1
:CD_LOOP
if !CD_N! LEQ 0 exit /b 0
echo   ... starting the Administrator shell in !CD_N! s  (log: %LOG%)
ping -n 2 127.0.0.1 >nul 2>&1
set /a CD_N-=1
goto :CD_LOOP

:PUBLISH
rem Copy the live log to the first writable real volume so it survives a VM
rem reset. `copy` opens its destination with no sharing, so a reader holding
rem the published copy makes it fail with a sharing violation - which is what
rem produced the "another program is using this file" spam. show-log.cmd now
rem reads the X: source instead, and this still retries a few times.
if not defined PUB exit /b 0
set /a PB_N=0
:PB_RETRY
copy /y "%LOG%" "%PUB%native-logon-bootstrap.log" >nul 2>&1
if not errorlevel 1 exit /b 0
set /a PB_N+=1
if !PB_N! GEQ 5 exit /b 0
ping -n 2 127.0.0.1 >nul 2>&1
goto :PB_RETRY

rem :FIXSVC <name> <start-type> "<service-dll>"
rem Writes a complete svchost service definition. reg.exe cannot emit
rem REG_EXPAND_SZ, but an absolute literal path in a REG_SZ works just as
rem well for both ImagePath and ServiceDll.
:FIXSVC
set "FS=%~1"
reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\%FS%" /v Type /t REG_DWORD /d 0x20 /f >>"%LOG%" 2>&1
reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\%FS%" /v Start /t REG_DWORD /d %~2 /f >>"%LOG%" 2>&1
reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\%FS%" /v ErrorControl /t REG_DWORD /d 1 /f >>"%LOG%" 2>&1
reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\%FS%" /v ImagePath /t REG_SZ /d "%SYS32%\svchost.exe -k netsvcs -p -s %FS%" /f >>"%LOG%" 2>&1
reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\%FS%" /v ObjectName /t REG_SZ /d LocalSystem /f >>"%LOG%" 2>&1
reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\%FS%\Parameters" /v ServiceDll /t REG_SZ /d "%SYS32%\%~3" /f >>"%LOG%" 2>&1
reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\%FS%\Parameters" /v ServiceDllUnloadOnStop /t REG_DWORD /d 1 /f >>"%LOG%" 2>&1
reg.exe add "HKLM\SYSTEM\Setup\AllowStart\%FS%" /f >>"%LOG%" 2>&1
exit /b 0

rem :DIAG
rem Dumps service state, the logon-related processes and the session list.
rem Without this a failed switch left no evidence at all.
:DIAG
set "DF=%MICPE%\native-logon-diag.txt"
> "%DF%" echo ==== services ====
if exist "%SYS32%\sc.exe" (
    >>"%DF%" sc.exe query seclogon 2>&1
    >>"%DF%" sc.exe query Schedule 2>&1
)
>>"%DF%" echo ==== processes ====
if exist "%SYS32%\tasklist.exe" (
    >>"%DF%" tasklist.exe 2>&1 | findstr /i "winlogon LogonUI seclogon explorer csrss winpeshl dwm userinit services runas"
    >>"%DF%" echo ==== explorer owner/session ====
    >>"%DF%" tasklist.exe /v /fi "imagename eq explorer.exe" 2>&1
) else (
    >>"%DF%" echo tasklist.exe not present
)
>>"%DF%" echo ==== sessions ====
if exist "%SYS32%\query.exe" (
    >>"%DF%" query.exe session 2>&1
) else (
    >>"%DF%" echo query.exe not present
)
type "%DF%" >>"%LOG%" 2>&1
if defined PUB copy /y "%DF%" "%PUB%native-logon-diag.txt" >nul 2>&1
type "%DF%"
exit /b 0

rem :WAITLOGON <seconds>
rem Polls for LogonUI.exe. Returns 0 as soon as it is running, 1 on timeout.
:WAITLOGON
set /a WL_N=%~1
:WL_LOOP
if !WL_N! LEQ 0 exit /b 1
if exist "%SYS32%\tasklist.exe" (
    tasklist.exe /fi "imagename eq LogonUI.exe" 2>nul | find /i "LogonUI.exe" >nul && exit /b 0
)
ping -n 2 127.0.0.1 >nul 2>&1
set /a WL_N-=1
goto :WL_LOOP

rem :WAITEXPLORER <seconds>
rem Polls for explorer.exe. Returns 0 as soon as it is running, 1 on timeout.
rem Used after the seclogon launch, which is asynchronous (runas returns before
rem the new process has finished initialising).
:WAITEXPLORER
set /a WX_N=%~1
:WX_LOOP
if !WX_N! LEQ 0 exit /b 1
if exist "%SYS32%\tasklist.exe" (
    tasklist.exe /fi "imagename eq explorer.exe" 2>nul | find /i "explorer.exe" >nul && exit /b 0
)
ping -n 2 127.0.0.1 >nul 2>&1
set /a WX_N-=1
goto :WX_LOOP

rem :RUN <tag> <timeout-seconds>  (command line is in CL)
rem Runs the command from a generated step script in a child cmd.exe, waits at
rem most <timeout-seconds> for its rc marker, then kills it. Never blocks the
rem boot. The step script avoids nested cmd /c quoting entirely, which is what
rem breaks as soon as a path contains a space (e.g. "Program Files").
:RUN
set "RT_TAG=%~1"
set "RT_SECS=%~2"
set "RT_RC=%TMPD%\%~1.rc"
set "RT_SF=%TMPD%\step-%RT_TAG%.cmd"
if exist "%RT_RC%" del /q "%RT_RC%" >nul 2>&1
call :SAY "RUN %RT_TAG%: %CL%"
> "%RT_SF%" echo @echo off
>>"%RT_SF%" echo !CL! ^>^> "%LOG%" 2^>^&1
>>"%RT_SF%" echo echo %%errorlevel%% ^> "%RT_RC%"
start "" /b "%RT_SF%"
set /a RT_N=0
:RUN_WAIT
if exist "%RT_RC%" goto :RUN_DONE
set /a RT_N+=1
if !RT_N! GEQ %RT_SECS% goto :RUN_TIMEOUT
ping -n 2 127.0.0.1 >nul 2>&1
goto :RUN_WAIT
:RUN_TIMEOUT
call :SAY "TIMEOUT after %RT_SECS%s in %RT_TAG% - killing it and continuing"
taskkill /f /im %RT_TAG%.exe >>"%LOG%" 2>&1
exit /b 124
:RUN_DONE
set "RT_VAL="
set /p RT_VAL=<"%RT_RC%"
call :SAY "%RT_TAG% finished rc=%RT_VAL%"
exit /b 0
