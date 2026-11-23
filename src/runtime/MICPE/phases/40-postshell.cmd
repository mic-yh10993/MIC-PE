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
rem Round 6: time the unbounded Taskbar:WaitForReady() call. Single-line
rem ifs on purpose: %TIME% inside a parenthesised block expands once at
rem parse time, so start and end would read the same. The probe copies
rem this file into micpe-probe.txt (see probe-wb2.cmd).
if exist "%ProgramFiles%\WinXShell\WinXShell.exe" echo taskbar_wait_start=%TIME: =0% > "%MICPE%\logs\taskbar-wait.txt"
if exist "%ProgramFiles%\WinXShell\WinXShell.exe" call :WAIT_TASKBAR
if exist "%ProgramFiles%\WinXShell\WinXShell.exe" echo taskbar_wait_end=%TIME: =0% >> "%MICPE%\logs\taskbar-wait.txt"

rem Round 9 (A9): t0 window snapshot, seconds after WaitForReady returns.
rem This closes the ~22 s gap between the WaitForReady return and the
rem probe's first possible sample (mark_probe_start). Single-line ifs:
rem %TIME% is not used here, but the file's no-delayed-expansion rule
rem still applies -- no delayed-expansion syntax anywhere. WINPROBE_PREFIX
rem is cleared right after the call: the hooks below inherit this
rem session's environment, and a leaked t0_ prefix would rename the
rem probe's own keys.
if exist "%ProgramFiles%\WinXShell\WinXShell.exe" if exist "%MICPE%\winprobe.lua" set "WINPROBE_PREFIX=t0_"
if exist "%ProgramFiles%\WinXShell\WinXShell.exe" if exist "%MICPE%\winprobe.lua" "%ProgramFiles%\WinXShell\WinXShell.exe" -script "%MICPE%\winprobe.lua" >>"%LOG%" 2>&1
if exist "%SystemDrive%\micpe-winprobe.txt" copy /y "%SystemDrive%\micpe-winprobe.txt" "%MICPE%\logs\winprobe-t0.txt" >nul 2>&1
set "WINPROBE_PREFIX="

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

:WAIT_TASKBAR
rem Round 9 (A9): capture the WaitForReady exit code and output size.
rem No delayed expansion in this file (phases run under startnet.cmd
rem without it), so the call lives in a subroutine: each line is parsed
rem at execution time, and %errorlevel% on the line right after the
rem call is WinXShell's own exit code.
rem Output goes to taskbar-wait-out.txt first, then into boot.log, so
rem boot.log keeps its old content AND the probe can size/copy the raw
rem output. Only numeric keys go into taskbar-wait.txt: raw output may
rem contain '=' and would inject junk keys into the probe file.
"%ProgramFiles%\WinXShell\WinXShell.exe" -luacode Taskbar:WaitForReady() > "%MICPE%\logs\taskbar-wait-out.txt" 2>&1
set "WAIT_RC=%errorlevel%"
type "%MICPE%\logs\taskbar-wait-out.txt" >> "%LOG%" 2>nul
set "WAIT_OUT_SIZE=missing"
for %%F in ("%MICPE%\logs\taskbar-wait-out.txt") do set "WAIT_OUT_SIZE=%%~zF"
echo taskbar_wait_rc=%WAIT_RC% >> "%MICPE%\logs\taskbar-wait.txt"
echo taskbar_wait_out_size=%WAIT_OUT_SIZE% >> "%MICPE%\logs\taskbar-wait.txt"
if "%WAIT_RC%"=="0" (call :LOG "taskbar ready") else (call :LOG "taskbar wait FAILED rc=%WAIT_RC%")
goto :EOF
