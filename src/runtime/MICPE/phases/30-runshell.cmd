@echo off
rem ==========================================================================
rem  Phase 30 - start the shell
rem
rem  The shell is whatever Winlogon says: with the "explorer" profile slot that
rem  is %SystemRoot%\explorer.exe, the Win11 shell (XAML taskbar, needs DWM).
rem  WinXShell is started next to it only as a helper daemon: it hides the boot
rem  console and waits for the taskbar, it is not the shell in this profile.
rem
rem  Boot runs as SYSTEM, so no logon happens and explorer is started directly
rem  with this session's token - exactly the "PE_LOADER=SYSTEM" model.
rem
rem  explorer.exe is started detached and then polled: a broken image starts it
rem  and loses it again within a second (missing DLL, DWM not running, AppX
rem  activation refused), and the poll is what turns that into a log line
rem  instead of a black desktop.
rem ==========================================================================

set "LOG=%MICPE%\logs\boot.log"
set "SHELL_OK="

rem -- what does Winlogon want? ------------------------------------------------
rem Filter on REG_SZ: Winlogon also holds AutoRestartShell (a DWORD whose name
rem contains "Shell"), and a plain find would pick its 0x1 up as the shell name.
set "SHELL_CMD=explorer.exe"
for /f "tokens=3" %%S in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell 2^>nul ^| find /i "REG_SZ"') do set "SHELL_CMD=%%~S"
call :LOG "phase 30-runshell: Winlogon Shell=%SHELL_CMD%"

rem -- explorer profile --------------------------------------------------------
echo %SHELL_CMD% | find /i "explorer.exe" >nul 2>&1
if errorlevel 1 goto :WINSHELL

if not exist "%SystemRoot%\explorer.exe" (
    call :LOG "explorer.exe missing under %SystemRoot% - falling back to WinXShell"
    goto :WINSHELL
)

rem Phase 25 may already have started Explorer with a real logon token. Two
rem Explorer processes fight over the shell (the first one owns the desktop,
rem the second fails to initialise and dies), so a second one is never started.
if exist "%MICPE%\logs\logon-token.flag" (
    call :LOG "Explorer already runs with a logon token - not starting a second one"
    goto :WAIT
)

call :LOG "starting %SystemRoot%\explorer.exe"
start "shell" "%SystemRoot%\explorer.exe"
goto :WAIT

rem -- WinXShell profile -------------------------------------------------------
:WINSHELL
if not exist "%ProgramFiles%\WinXShell\WinXShell.exe" (
    call :LOG "no usable shell: WinXShell.exe is not installed either"
    goto :END
)
call :LOG "starting WinXShell as the shell"
start "shell" "%ProgramFiles%\WinXShell\WinXShell.exe" -regist -shell

rem -- poll for the shell, up to ~20 s ----------------------------------------
:WAIT
set /a SHELL_TRIES=0
:WAIT_LOOP
set /a SHELL_TRIES+=1
call :POLL >nul 2>&1
if defined SHELL_OK goto :STARTED
if %SHELL_TRIES% GEQ 20 goto :NOT_STARTED
ping -n 2 127.0.0.1 >nul 2>&1
goto :WAIT_LOOP

:STARTED
call :LOG "shell is running after %SHELL_TRIES%s"
echo ok>"%MICPE%\logs\shell-ok.flag"
goto :END

:NOT_STARTED
call :LOG "shell is NOT running after %SHELL_TRIES%s - leaving the console up"
if exist "%MICPE%\logs\shell-ok.flag" del /q "%MICPE%\logs\shell-ok.flag" >nul 2>&1

rem explorer exits immediately when a static import or a service is missing and
rem prints nothing at all, so do not retry here: a retry loop is what made an
rem earlier image flash windows on the screen forever. 40-postshell.cmd leaves
rem this console open with the dump instead, and uwp-start-shell.cmd can be run
rem by hand - it uses start /wait and prints explorer's exit code:
rem     0xC0000135 -1073741515  STATUS_DLL_NOT_FOUND
rem     0xC0000142 -1073741502  STATUS_DLL_INIT_FAILED
rem     0xC0000005 -1073741819  STATUS_ACCESS_VIOLATION

:END
call :HOOKS shell
call :LOG "phase 30-runshell: end (SHELL_OK=%SHELL_OK%)"
goto :EOF

rem -- helpers -----------------------------------------------------------------

:POLL
tasklist /fi "imagename eq explorer.exe" 2>nul | find /i "explorer.exe" >nul 2>&1
if not errorlevel 1 set "SHELL_OK=1"
if not defined SHELL_OK (
    tasklist /fi "imagename eq WinXShell.exe" 2>nul | find /i "WinXShell.exe" >nul 2>&1
    if not errorlevel 1 set "SHELL_OK=1"
)
goto :EOF

:HOOKS
if not exist "%MICPE%\hooks\%~1\*.cmd" goto :EOF
for %%F in ("%MICPE%\hooks\%~1\*.cmd") do (
    call :LOG "hook %~1: %%~nxF"
    call "%%~fF"
)
goto :EOF

:LOG
>>"%LOG%" echo [%DATE% %TIME%] %~1
goto :EOF
