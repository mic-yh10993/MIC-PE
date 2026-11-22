@echo off
rem ==========================================================================
rem  Phase 25 - give the shell a real logon token
rem
rem  WHY THIS PHASE EXISTS
rem
rem  A shell that runs with the SYSTEM token is not a real shell: it has no
rem  logon session, no user profile and no interactive desktop ownership, so
rem  the parts of Explorer that need one (opening a folder window, the
rem  Recycle Bin, the shell namespace) silently do nothing. WimBuilder2 does
rem  not have this problem because its image is Client-based and boots
rem  through a real logon: Winlogon logs Administrator on and then starts
rem  Shell=explorer.exe inside that session.
rem
rem  In a WinPE image the logon path is not reachable the normal way (the
rem  session boots in Setup mode), so the token is created directly through
rem  the Secondary Logon service (seclogon): runas.exe -> CreateProcessWithLogonW
rem  -> an LSA logon session for Administrator. The new process inherits this
rem  console's desktop (WinSta0\Default), so the shell is visible.
rem
rem  Everything here is best effort. If any step fails the phase leaves no
rem  flag behind and phase 30 starts Explorer the old way (SYSTEM token),
rem  which still yields a desktop - just not a fully functional one.
rem
rem  Order matters:
rem    1. the logon services must exist and run (seclogon, Themes, SENS,
rem       Appinfo) - their definitions come from reg/values/60-logon-services.reg
rem    2. the built-in Administrator must be enabled and have a password;
rem       in the PE SAM the account does not exist until SamSs has run
rem    3. the profile template is cloned from config\Default, so the shell
rem       reads the same per-user values the image carries
rem    4. only then is Explorer launched with that token
rem ==========================================================================

set "LOG=%MICPE%\logs\boot.log"
set "FLAG=%MICPE%\logs\logon-token.flag"
set "SYS32=%SystemRoot%\System32"

rem Phase 25 is skipped when the shell is already up (a re-run of the chain).
if exist "%FLAG%" goto :EOF

call :LOG "phase 25-logon: start"

rem -- 1. services the logon path needs ---------------------------------------
rem The start order matters: SamSs carries the SAM database, seclogon needs
rem RPCSS. A service that is already running prints an error line (1056) and
rem that is not a failure, so the output is only logged.
rem Order follows WimBuilder2 LogonAdmin.bat: seclogon first, then the AppX
rem chain (SENS, CoreMessagingRegistrar, UserManager, BrokerInfrastructure,
rem StateRepository, Schedule, AppReadiness), then the shell services
rem (Themes, Appinfo, ShellHWDetection, ProfSvc). ProfSvc loads the user
rem profile for the logon token; without it the logon falls back to a
rem temporary profile.
for %%S in (SamSs RPCSS seclogon SENS CoreMessagingRegistrar UserManager BrokerInfrastructure StateRepository Schedule AppReadiness Themes Appinfo ShellHWDetection ProfSvc) do (
    sc.exe start %%S >>"%LOG%" 2>&1
    call :LOG "  sc start %%S rc=%errorlevel%"
)

rem -- 1b. wait for seclogon to be RUNNING ------------------------------------
rem runas.exe calls CreateProcessWithLogonW, which fails at once when the
rem Secondary Logon service is not up yet. sc start returns before the
rem service finishes starting, so poll for the RUNNING state (15s max).
rem A timeout is not fatal: the runas attempt below still runs, and a
rem failure there falls back to the SYSTEM shell in phase 30.
set /a SECLOGON_WAIT=0
:SECLOGON_POLL
sc.exe query seclogon 2>nul | find /i "RUNNING" >nul 2>&1
if not errorlevel 1 goto :SECLOGON_UP
set /a SECLOGON_WAIT+=1
if %SECLOGON_WAIT% GEQ 15 goto :SECLOGON_TIMEOUT
ping -n 2 127.0.0.1 >nul 2>&1
goto :SECLOGON_POLL
:SECLOGON_UP
call :LOG "  seclogon is RUNNING"
goto :SECLOGON_DONE
:SECLOGON_TIMEOUT
call :LOG "  seclogon did not reach RUNNING in 15s - runas may fail"
:SECLOGON_DONE

rem -- 2. the Administrator account ------------------------------------------
rem In this PE the SAM database is created by the SAM service when it starts,
rem so the built-in accounts only exist after step 1. The account is created
rem disabled, so it is enabled here; a password is set because the Secondary
rem Logon path refuses a blank one (net user is a SYSTEM-only operation).
if exist "%SYS32%\net.exe" (
    "%SYS32%\net.exe" user Administrator /active:yes >>"%LOG%" 2>&1
    call :LOG "  net user /active:yes rc=%errorlevel%"
    "%SYS32%\net.exe" user Administrator micpe >>"%LOG%" 2>&1
    call :LOG "  net user (set password) rc=%errorlevel%"
) else (
    call :LOG "  net.exe missing - cannot enable the Administrator account"
)

rem -- 3. profile template ----------------------------------------------------
rem The Administrator profile is cloned from the Default hive, exactly like
rem WimBuilder2's LogonAdmin.bat does. Without it the logon creates a profile
rem from scratch and the per-user values in the image are not applied.
if not exist "%SystemDrive%\Users\Administrator" md "%SystemDrive%\Users\Administrator" >nul 2>&1
if exist "%SYS32%\config\Default" (
    copy /y "%SYS32%\config\Default" "%SystemDrive%\Users\Administrator\NTUSER.DAT" >>"%LOG%" 2>&1
    call :LOG "  cloned config\Default to the Administrator profile"
)
if not exist "%SystemDrive%\Users\Administrator\AppData\Local\Microsoft\Windows" (
    md "%SystemDrive%\Users\Administrator\AppData\Local\Microsoft\Windows" >nul 2>&1
)
if exist "%MICPE%\UsrClass.dat" (
    copy /y "%MICPE%\UsrClass.dat" "%SystemDrive%\Users\Administrator\AppData\Local\Microsoft\Windows\UsrClass.dat" >>"%LOG%" 2>&1
)

rem -- 4. Explorer with a real token ------------------------------------------
rem runas.exe reads the password from the console, so the credentials are fed
rem through a generated script (a pipe cannot be passed through a variable
rem without breaking the parser). The script starts Explorer, so the shell
rem comes up in the authenticated session.
if not exist "%SYS32%\runas.exe" (
    call :LOG "  runas.exe missing - falling back to the SYSTEM shell"
    goto :EOF
)

call :LOG "  launching Explorer with an Administrator token (runas/seclogon)"
> "%MICPE%\runas-explorer.cmd" echo @echo off
>>"%MICPE%\runas-explorer.cmd" echo echo micpe^|%SYS32%\runas.exe /user:Administrator /env %SYS32%\explorer.exe ^>^> "%LOG%" 2^>^&1
start "" /b "%SYS32%\cmd.exe" /c "%MICPE%\runas-explorer.cmd"

rem -- 5. did the shell come up? ---------------------------------------------
set /a TRY=0
:WAIT
set /a TRY+=1
tasklist /fi "imagename eq explorer.exe" 2>nul | find /i "explorer.exe" >nul 2>&1
if not errorlevel 1 goto :UP
if %TRY% GEQ 20 goto :DOWN
ping -n 2 127.0.0.1 >nul 2>&1
goto :WAIT

:UP
echo ok>"%FLAG%"
call :LOG "  Explorer is running with an Administrator token"
call :DIAG
goto :EOF

:DOWN
call :LOG "  Explorer did not come up with a token - the SYSTEM shell takes over"
call :DIAG
goto :EOF

rem -- helpers ----------------------------------------------------------------

:DIAG
rem Evidence of what actually runs. If the token route fails, this is the only
rem place that says why.
>>"%LOG%" echo ---- 25-logon state ----
tasklist /v /fi "imagename eq explorer.exe" >>"%LOG%" 2>&1
sc.exe query seclogon >>"%LOG%" 2>&1
reg.exe query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" >>"%LOG%" 2>&1
goto :EOF

:LOG
>>"%LOG%" echo [%DATE% %TIME%] %~1
goto :EOF
