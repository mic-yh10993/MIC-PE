@echo off
rem ==========================================================================
rem  Phase 10 - OS init
rem
rem  Runs before any user environment exists. Keep it short: anything that
rem  needs the shell, the taskbar or a user profile belongs to a later phase.
rem
rem  Steps
rem    1. wpeinit.exe                 brings up devices and the network stack;
rem                                   without it there is no DHCP, no audio and
rem                                   no Plug and Play enumeration at all.
rem    1b. Fix-DriveLetters.cmd       keeps the installed Windows on C: (WinPE
rem                                   hands C: to the boot media otherwise).
rem    2. hide the Startup folders    they are empty in this image and would
rem                                   otherwise show up in Explorer.
rem    3. WinXShell -regist -noaction writes WinXShell's own shell integration
rem                                   keys. It is the same binary that later
rem                                   hides the console and waits for the
rem                                   taskbar, and it expects these keys.
rem    4. hooks\osinit\*.cmd          your own additions, name order.
rem
rem  This file runs inside startnet.cmd's setlocal scope on purpose: no
rem  setlocal / endlocal here, so variables set in phases stay visible to the
rem  phases that follow and to explorer.exe.
rem ==========================================================================

set "LOG=%MICPE%\logs\boot.log"
if not exist "%MICPE%\logs" md "%MICPE%\logs%" >nul 2>&1
call :LOG "phase 10-osinit: start"

rem -- 1. devices and network -------------------------------------------------
call :LOG "wpeinit.exe"
wpeinit.exe >>"%LOG%" 2>&1
call :LOG "wpeinit.exe done (errorlevel=%errorlevel%)"

rem -- 1b. keep the installed Windows on C: ------------------------------------
rem WinPE letters volumes in enumeration order, so the boot stick often takes C:
rem and the installed Windows ends up on D:. This project's fix swaps them back;
rem it has to run before anything reads a path on the installed system. It is
rem installed by the runtimes step (src/shell/Fix-DriveLetters.cmd).
if exist "%MICPE%\Fix-DriveLetters.cmd" (
    call "%MICPE%\Fix-DriveLetters.cmd" >>"%LOG%" 2>&1
    call :LOG "Fix-DriveLetters.cmd done (errorlevel=%errorlevel%)"
) else (
    call :LOG "Fix-DriveLetters.cmd not installed - drive letters untouched"
)

rem -- 2. keep the empty Startup folders out of the UI ------------------------
attrib +s +h "%ProgramData%\Microsoft\Windows\Start Menu\Programs\Startup" >nul 2>&1

rem -- 3. WinXShell integration keys -------------------------------------------
rem Guarded: the image is still usable without WinXShell, only the console
rem window then stays visible and the taskbar is not awaited.
if exist "%ProgramFiles%\WinXShell\WinXShell.exe" (
    "%ProgramFiles%\WinXShell\WinXShell.exe" -regist -noaction >>"%LOG%" 2>&1
    call :LOG "WinXShell -regist -noaction done"
) else (
    call :LOG "WinXShell not installed - skipping -regist"
)

rem -- 4. user hooks -----------------------------------------------------------
call :HOOKS osinit

call :LOG "phase 10-osinit: end"
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
