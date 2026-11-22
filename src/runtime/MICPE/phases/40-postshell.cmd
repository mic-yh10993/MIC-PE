@echo off
rem ==========================================================================
rem  Phase 40 - post-shell
rem
rem  Runs after the shell has been started and polled. Two outcomes only:
rem
rem    shell up    wait for the taskbar to finish loading, remove the leftover
rem                desktop.ini files, then hide this console window so the
rem                desktop is usable. A healthy boot shows no window at all.
rem
rem    shell down  keep the console on screen and print where the logs are.
rem                A black desktop with no text is the one state that makes a
rem                failed boot impossible to diagnose from a photo.
rem
rem  hooks\postshell\*.cmd runs before the window is hidden, name order.
rem ==========================================================================

set "LOG=%MICPE%\logs\boot.log"

if not defined SHELL_OK goto :NO_SHELL

rem -- shell is up -------------------------------------------------------------
rem The taskbar is a separate XAML process: waiting for it here is what makes
rem the first paint look finished instead of an empty bar for a few seconds.
if exist "%ProgramFiles%\WinXShell\WinXShell.exe" (
    "%ProgramFiles%\WinXShell\WinXShell.exe" -luacode Taskbar:WaitForReady() >>"%LOG%" 2>&1
    call :LOG "taskbar ready"
)

rem Leave no desktop.ini behind: Explorer would show it as a file on the
rem desktop of a RAM-disk profile.
del /a /q "%USERPROFILE%\Desktop\desktop.ini" >nul 2>&1
del /a /q "X:\Users\Public\Desktop\desktop.ini" >nul 2>&1

call :HOOKS postshell
call :LOG "phase 40-postshell: shell up, hiding the console"

rem -- hide the console --------------------------------------------------------
rem Last action on purpose: everything above may still print. Without
rem WinXShell the window simply stays, which is harmless.
if exist "%ProgramFiles%\WinXShell\WinXShell.exe" (
    "%ProgramFiles%\WinXShell\WinXShell.exe" -code "HideWindow('ConsoleWindowClass')"
)
goto :EOF

rem -- shell is down -----------------------------------------------------------
:NO_SHELL
call :HOOKS postshell
call :LOG "phase 40-postshell: shell down, keeping the console"

echo.
echo ============================================================
echo  MICPE: the desktop shell did not start.
echo.
echo  boot log : %LOG%
echo  shell log: %MICPE%\logs\uwp-shell.log
echo.
echo  Run  %MICPE%\uwp-diag.cmd  for services, packages and
echo  registry state, or uwp-start-shell.cmd to retry the shell
echo  alone and get its exit code.
echo ============================================================
echo.
goto :EOF

rem -- helpers -----------------------------------------------------------------

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
