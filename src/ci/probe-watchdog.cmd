@echo off
rem MICPE probe watchdog (run 44285721257).
rem
rem Watches the probe file probe.cmd writes. The probe records its own
rem probe_done=1 at the end, but a stall or crash mid-run (Photos hung
rem the UWP launch in run 44285721257) writes nothing, and the CI host
rem then waits out the full 45 minutes for a line that will never come.
rem This watcher runs detached alongside the probe: when the probe file
rem stops growing for 5 minutes, it records probe_failed=1 itself, so
rem the host stops waiting early. probe_failed still fails the run,
rem see Assert-Probe; it only shortens the wait, it never passes one.
rem The watcher stops on its own when it sees probe_done=1, or when
rem probe.cmd writes the stop flag before the long installer deploy.
rem
rem Usage: probe-watchdog.cmd <probe-file> [stall-limit] [wait-seconds]
rem Defaults: 5 quiet checks of 60 seconds each. The two optional
rem arguments exist only so the Pester mechanism tests can run the
rem same script with small numbers; the PE call passes just the file.
setlocal
set "WD_FILE=%~1"
if not defined WD_FILE exit /b 2
set "WD_LIMIT=%~2"
if not defined WD_LIMIT set "WD_LIMIT=5"
set "WD_WAIT=%~3"
if not defined WD_WAIT set "WD_WAIT=60"
set "WD_STOP=%SystemDrive%\micpe-watchdog-stop.txt"
set "WD_SIZE="
set "WD_QUIET=0"
:watchdog_loop
findstr /b /c:"probe_done=1" "%WD_FILE%" >nul 2>&1
if not errorlevel 1 exit /b 0
if exist "%WD_STOP%" exit /b 0
for %%F in ("%WD_FILE%") do set "WD_NOW=%%~zF"
if "%WD_NOW%"=="%WD_SIZE%" (
    set /a WD_QUIET+=1
) else (
    set "WD_SIZE=%WD_NOW%"
    set "WD_QUIET=0"
)
if %WD_QUIET% geq %WD_LIMIT% goto :watchdog_fail
ping -n %WD_WAIT% 127.0.0.1 >nul 2>&1
goto :watchdog_loop
:watchdog_fail
if not exist "%WD_FILE%" exit /b 1
findstr /b /c:"probe_done=1" "%WD_FILE%" >nul 2>&1
if not errorlevel 1 exit /b 0
echo probe_failed=1 >> "%WD_FILE%"
exit /b 1
